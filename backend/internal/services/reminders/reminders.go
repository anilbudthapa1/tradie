// Package reminders provides task-reminder dispatch for Module 13.
//
// Phase A status: there is no background scheduler in this batch.
// Reminders run on demand via POST /api/v1/internal/reminders/run
// (RequireOwnerOrAdmin), which scans for tasks whose reminder_at has
// elapsed and forwards them to a ReminderDispatcher.
//
// In production the cron/worker tier would call /reminders/run on a
// short cadence and swap NoopDispatcher for one backed by Twilio +
// FCM/APNs. The interface boundary is here precisely so that swap is
// a one-line wiring change in main.go.
package reminders

import (
	"context"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"go.uber.org/zap"
)

// Reminder is the small payload passed to a dispatcher.
type Reminder struct {
	TaskID      uuid.UUID
	BusinessID  uuid.UUID
	AssignedTo  *uuid.UUID
	Title       string
	Description string
	DueDate     *time.Time
	ReminderAt  time.Time
}

// ReminderDispatcher is the seam that real notification providers
// (push, SMS, email) implement. Returning an error is non-fatal —
// the caller logs and moves on so a single failed dispatch does not
// block the rest of the batch.
type ReminderDispatcher interface {
	Dispatch(ctx context.Context, r Reminder) error
}

// NoopDispatcher logs the reminder but does not deliver anything.
// This is the safe default until M88-M90 (push/SMS infra) ships.
type NoopDispatcher struct {
	log *zap.Logger
}

func NewNoopDispatcher(log *zap.Logger) *NoopDispatcher {
	return &NoopDispatcher{log: log}
}

func (n *NoopDispatcher) Dispatch(_ context.Context, r Reminder) error {
	n.log.Info("reminder dispatch (noop)",
		zap.String("task_id", r.TaskID.String()),
		zap.String("business_id", r.BusinessID.String()),
		zap.String("title", r.Title),
		zap.Time("reminder_at", r.ReminderAt),
	)
	return nil
}

// Runner scans tasks whose reminder_at has elapsed and forwards each
// to the configured dispatcher. It returns the count of reminders
// processed.
type Runner struct {
	db         *pgxpool.Pool
	log        *zap.Logger
	dispatcher ReminderDispatcher
}

func NewRunner(db *pgxpool.Pool, log *zap.Logger, dispatcher ReminderDispatcher) *Runner {
	if dispatcher == nil {
		dispatcher = NewNoopDispatcher(log)
	}
	return &Runner{db: db, log: log, dispatcher: dispatcher}
}

// Run claims due reminders by clearing reminder_at in the same UPDATE
// statement (so concurrent runners cannot double-fire) and dispatches
// each one. Optionally scoped to a single business.
func (r *Runner) Run(ctx context.Context, bizID uuid.UUID) (int, error) {
	var (
		rows interface {
			Next() bool
			Scan(...interface{}) error
			Close()
		}
	)

	if bizID == uuid.Nil {
		q, err := r.db.Query(ctx,
			`UPDATE tasks
			   SET reminder_at = NULL, updated_at = NOW()
			 WHERE reminder_at IS NOT NULL
			   AND reminder_at <= NOW()
			   AND status = 'pending'
			 RETURNING id, business_id, assigned_to, title, COALESCE(description, ''), due_date, NOW()`)
		if err != nil {
			return 0, err
		}
		rows = q
	} else {
		q, err := r.db.Query(ctx,
			`UPDATE tasks
			   SET reminder_at = NULL, updated_at = NOW()
			 WHERE business_id = $1
			   AND reminder_at IS NOT NULL
			   AND reminder_at <= NOW()
			   AND status = 'pending'
			 RETURNING id, business_id, assigned_to, title, COALESCE(description, ''), due_date, NOW()`,
			bizID)
		if err != nil {
			return 0, err
		}
		rows = q
	}
	defer rows.Close()

	count := 0
	for rows.Next() {
		var rem Reminder
		var assignedTo *uuid.UUID
		var dueDate *time.Time
		if err := rows.Scan(&rem.TaskID, &rem.BusinessID, &assignedTo, &rem.Title, &rem.Description, &dueDate, &rem.ReminderAt); err != nil {
			r.log.Warn("reminder scan", zap.Error(err))
			continue
		}
		rem.AssignedTo = assignedTo
		rem.DueDate = dueDate
		if err := r.dispatcher.Dispatch(ctx, rem); err != nil {
			r.log.Warn("reminder dispatch failed",
				zap.String("task_id", rem.TaskID.String()),
				zap.Error(err),
			)
		}
		count++
	}
	return count, nil
}
