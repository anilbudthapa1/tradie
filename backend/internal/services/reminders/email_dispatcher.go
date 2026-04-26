package reminders

import (
	"context"
	"fmt"
	"html"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"go.uber.org/zap"

	"github.com/tradie/api/internal/services/email"
)

// EmailDispatcher delivers task reminders by emailing the assignee.
// If a reminder has no assignee or the assignee has no email on file
// it falls back to a structured log line so the run still succeeds.
type EmailDispatcher struct {
	db    *pgxpool.Pool
	log   *zap.Logger
	email *email.Service
}

func NewEmailDispatcher(db *pgxpool.Pool, log *zap.Logger, email *email.Service) *EmailDispatcher {
	return &EmailDispatcher{db: db, log: log, email: email}
}

func (d *EmailDispatcher) Dispatch(ctx context.Context, r Reminder) error {
	if r.AssignedTo == nil {
		d.log.Info("reminder dispatch skipped (no assignee)",
			zap.String("task_id", r.TaskID.String()))
		return nil
	}
	var (
		toEmail string
		toName  string
	)
	err := d.db.QueryRow(ctx,
		`SELECT email, COALESCE(NULLIF(TRIM(first_name || ' ' || last_name), ''), email)
		   FROM users WHERE id = $1`,
		*r.AssignedTo).Scan(&toEmail, &toName)
	if err == pgx.ErrNoRows || toEmail == "" {
		d.log.Info("reminder dispatch skipped (no email on file)",
			zap.String("task_id", r.TaskID.String()),
			zap.String("user_id", r.AssignedTo.String()))
		return nil
	}
	if err != nil {
		return fmt.Errorf("lookup assignee: %w", err)
	}
	subject := "Reminder: " + r.Title
	body := fmt.Sprintf(
		`<p>Hi %s,</p><p>This is a reminder for the task <strong>%s</strong>.</p>%s<p>— Tradie Job Manager</p>`,
		html.EscapeString(toName),
		html.EscapeString(r.Title),
		descBlock(r.Description),
	)
	return d.email.Send(ctx, toEmail, toName, subject, body)
}

func descBlock(desc string) string {
	if desc == "" {
		return ""
	}
	return "<p>" + html.EscapeString(desc) + "</p>"
}
