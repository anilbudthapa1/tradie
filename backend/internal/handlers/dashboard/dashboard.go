// Package dashboard implements Module 11 — Dashboard Module.
//
// Three logical services collaborate inside this package:
//   - DashboardService — composes payloads (List, MeView, KPIs)
//   - KPIService       — owner / employee KPI queries
//   - AlertService     — CRUD on dashboard_alerts (owner-managed)
//
// Every endpoint enforces zero-trust: BusinessIDFromCtx is the only
// trusted tenant value, role + permission keys gate writes/exports,
// and sensitive actions emit audit events. Inputs go through a
// strict allow-list validator; unknown JSON fields are rejected.
package dashboard

import (
	"context"
	"encoding/csv"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"go.uber.org/zap"

	"github.com/tradie/api/internal/config"
	"github.com/tradie/api/internal/middleware"
)

// ── Audit event names (spec §Audit Events) ───────────────────────
const (
	AuditViewed       = "DASHBOARD_VIEWED"
	AuditCreated      = "DASHBOARD_CREATED"
	AuditUpdated      = "DASHBOARD_UPDATED"
	AuditDeleted      = "DASHBOARD_DELETED"
	AuditAccessDenied = "DASHBOARD_ACCESS_DENIED"
	AuditExported     = "DASHBOARD_EXPORTED"

	maxBodyBytes = 64 * 1024 // 64 KiB cap on alert payloads
)

// Allow-listed enums (spec §Validation Rules).
var (
	allowedSeverity   = map[string]bool{"info": true, "warning": true, "critical": true}
	allowedAlertType  = map[string]bool{"custom": true, "kpi_threshold": true, "overdue": true, "compliance": true, "system": true}
	allowedStatus     = map[string]bool{"active": true, "acknowledged": true, "resolved": true, "dismissed": true}
	allowedTransition = map[[2]string]bool{
		{"active", "acknowledged"}:       true,
		{"active", "dismissed"}:          true,
		{"active", "resolved"}:           true,
		{"acknowledged", "resolved"}:     true,
		{"acknowledged", "dismissed"}:    true,
	}
)

// ── Handler / wiring ─────────────────────────────────────────────

type Handler struct {
	cfg   *config.Config
	db    *pgxpool.Pool
	log   *zap.Logger
	audit *middleware.AuditService
}

func NewHandler(cfg *config.Config, db *pgxpool.Pool, log *zap.Logger, audit *middleware.AuditService) *Handler {
	return &Handler{cfg: cfg, db: db, log: log, audit: audit}
}

// ── DashboardService — composed views ────────────────────────────

// OwnerView (GET /api/v1/dashboard) returns the owner-facing combined
// payload: KPIs + active alerts + the same trends/lists the legacy
// /reports/dashboard endpoint provides.
func (h *Handler) OwnerView(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())

	if !h.requirePermission(w, r, "dashboard.owner_view", uuid.Nil) {
		return
	}

	kpis := h.ownerKPIs(r.Context(), bizID)
	alerts := h.activeAlerts(r.Context(), bizID, nil)

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditViewed,
		EntityType: "dashboard",
		IPAddress:  r.RemoteAddr,
	})

	respond(w, http.StatusOK, map[string]interface{}{
		"kpis":   kpis,
		"alerts": alerts,
	})
}

// MeView (GET /api/v1/me/dashboard) is the explicit safe endpoint
// for non-owner / employee callers. It only exposes the calling
// user's assigned work and the alerts targeted at them.
func (h *Handler) MeView(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())

	if !h.requirePermission(w, r, "dashboard.employee_view", uuid.Nil) {
		return
	}

	kpis := h.employeeKPIs(r.Context(), bizID, claims.UserID)
	alerts := h.activeAlerts(r.Context(), bizID, &claims.UserID)

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditViewed,
		EntityType: "dashboard.me",
		IPAddress:  r.RemoteAddr,
	})

	respond(w, http.StatusOK, map[string]interface{}{
		"kpis":   kpis,
		"alerts": alerts,
	})
}

// ── KPIService ───────────────────────────────────────────────────

func (h *Handler) ownerKPIs(ctx context.Context, bizID uuid.UUID) map[string]interface{} {
	out := map[string]interface{}{
		"jobs_today": 0, "jobs_in_progress": 0, "pending_quotes": 0,
		"overdue_invoices": 0, "active_workers": 0, "tasks_due": 0,
		"revenue_month": 0.0, "unpaid_invoices": 0.0,
	}
	scanInt := func(q string, dst string) {
		var v int
		if err := h.db.QueryRow(ctx, q, bizID).Scan(&v); err != nil {
			h.log.Warn("kpi query failed", zap.String("metric", dst), zap.Error(err))
			return
		}
		out[dst] = v
	}
	scanFloat := func(q string, dst string) {
		var v float64
		if err := h.db.QueryRow(ctx, q, bizID).Scan(&v); err != nil {
			h.log.Warn("kpi query failed", zap.String("metric", dst), zap.Error(err))
			return
		}
		out[dst] = v
	}

	scanInt(`SELECT COUNT(*) FROM jobs
	         WHERE business_id=$1 AND DATE(scheduled_start AT TIME ZONE 'UTC')=CURRENT_DATE
	           AND status IN ('scheduled','in_progress')`, "jobs_today")
	scanInt(`SELECT COUNT(*) FROM jobs WHERE business_id=$1 AND status='in_progress'`, "jobs_in_progress")
	scanInt(`SELECT COUNT(*) FROM quotes WHERE business_id=$1 AND status='sent'`, "pending_quotes")
	scanInt(`SELECT COUNT(*) FROM invoices WHERE business_id=$1 AND status='overdue'`, "overdue_invoices")
	scanInt(`SELECT COUNT(*) FROM users
	         WHERE business_id=$1 AND role!='customer' AND is_active=true AND deleted_at IS NULL`, "active_workers")
	scanInt(`SELECT COUNT(*) FROM tasks
	         WHERE business_id=$1 AND status='pending' AND due_date <= NOW() + INTERVAL '24 hours'`, "tasks_due")
	scanFloat(`SELECT COALESCE(SUM(total_amount),0) FROM invoices
	           WHERE business_id=$1 AND status='paid' AND paid_at >= DATE_TRUNC('month', NOW())`, "revenue_month")
	scanFloat(`SELECT COALESCE(SUM(amount_due),0) FROM invoices
	           WHERE business_id=$1 AND status IN ('sent','overdue','partial')`, "unpaid_invoices")

	return out
}

func (h *Handler) employeeKPIs(ctx context.Context, bizID, userID uuid.UUID) map[string]interface{} {
	out := map[string]interface{}{
		"my_jobs_today": 0, "my_jobs_in_progress": 0,
		"my_tasks_pending": 0, "my_tasks_overdue": 0,
	}
	scanInt := func(q string, dst string, args ...interface{}) {
		var v int
		if err := h.db.QueryRow(ctx, q, args...).Scan(&v); err != nil {
			h.log.Warn("emp kpi query failed", zap.String("metric", dst), zap.Error(err))
			return
		}
		out[dst] = v
	}

	scanInt(`SELECT COUNT(DISTINCT j.id) FROM jobs j
	         JOIN job_assignments ja ON ja.job_id=j.id
	         WHERE j.business_id=$1 AND ja.user_id=$2
	           AND DATE(j.scheduled_start AT TIME ZONE 'UTC')=CURRENT_DATE`, "my_jobs_today", bizID, userID)
	scanInt(`SELECT COUNT(DISTINCT j.id) FROM jobs j
	         JOIN job_assignments ja ON ja.job_id=j.id
	         WHERE j.business_id=$1 AND ja.user_id=$2 AND j.status='in_progress'`, "my_jobs_in_progress", bizID, userID)
	scanInt(`SELECT COUNT(*) FROM tasks
	         WHERE business_id=$1 AND assigned_to=$2 AND status='pending'`, "my_tasks_pending", bizID, userID)
	scanInt(`SELECT COUNT(*) FROM tasks
	         WHERE business_id=$1 AND assigned_to=$2 AND status='pending'
	           AND due_date IS NOT NULL AND due_date < NOW()`, "my_tasks_overdue", bizID, userID)

	return out
}

// ── AlertService — CRUD ──────────────────────────────────────────

type alertRow struct {
	ID              uuid.UUID  `json:"id"`
	BusinessID      uuid.UUID  `json:"-"`
	CreatedBy       *uuid.UUID `json:"created_by"`
	UpdatedBy       *uuid.UUID `json:"updated_by"`
	TargetUserID    *uuid.UUID `json:"target_user_id"`
	Title           string     `json:"title"`
	Message         string     `json:"message"`
	Severity        string     `json:"severity"`
	AlertType       string     `json:"alert_type"`
	Status          string     `json:"status"`
	Metadata        []byte     `json:"-"`
	AcknowledgedAt  *time.Time `json:"acknowledged_at"`
	AcknowledgedBy  *uuid.UUID `json:"acknowledged_by"`
	CreatedAt       time.Time  `json:"created_at"`
	UpdatedAt       time.Time  `json:"updated_at"`
}

func (a *alertRow) MarshalJSON() ([]byte, error) {
	type alias alertRow
	meta := json.RawMessage(a.Metadata)
	if len(meta) == 0 {
		meta = json.RawMessage("{}")
	}
	return json.Marshal(struct {
		*alias
		Metadata json.RawMessage `json:"metadata"`
	}{(*alias)(a), meta})
}

// List (GET /api/v1/dashboard/alerts) — owner / manager scoped to tenant.
func (h *Handler) ListAlerts(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	if !h.requirePermission(w, r, "dashboard.view", uuid.Nil) {
		return
	}

	statusFilter := strings.TrimSpace(r.URL.Query().Get("status"))
	if statusFilter != "" && !allowedStatus[statusFilter] {
		respondErr(w, http.StatusBadRequest, "invalid_status")
		return
	}
	limit := 50
	if v := r.URL.Query().Get("limit"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 && n <= 200 {
			limit = n
		}
	}

	rows, err := h.db.Query(r.Context(),
		`SELECT id, business_id, created_by, updated_by, target_user_id,
		        title, message, severity, alert_type, status, metadata,
		        acknowledged_at, acknowledged_by, created_at, updated_at
		 FROM dashboard_alerts
		 WHERE business_id=$1 AND deleted_at IS NULL
		   AND ($2='' OR status=$2)
		 ORDER BY
		   CASE severity WHEN 'critical' THEN 1 WHEN 'warning' THEN 2 ELSE 3 END,
		   created_at DESC
		 LIMIT $3`,
		bizID, statusFilter, limit,
	)
	if err != nil {
		h.log.Error("list alerts", zap.Error(err))
		respondErr(w, http.StatusInternalServerError, "query_failed")
		return
	}
	defer rows.Close()

	out := []*alertRow{}
	for rows.Next() {
		a := &alertRow{}
		if err := rows.Scan(
			&a.ID, &a.BusinessID, &a.CreatedBy, &a.UpdatedBy, &a.TargetUserID,
			&a.Title, &a.Message, &a.Severity, &a.AlertType, &a.Status, &a.Metadata,
			&a.AcknowledgedAt, &a.AcknowledgedBy, &a.CreatedAt, &a.UpdatedAt,
		); err == nil {
			out = append(out, a)
		}
	}
	respond(w, http.StatusOK, out)
}

// CreateAlert (POST /api/v1/dashboard/alerts) — alert_manage required.
func (h *Handler) CreateAlert(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "dashboard.alert_manage", uuid.Nil) {
		return
	}

	var req struct {
		Title        string                 `json:"title"`
		Message      string                 `json:"message"`
		Severity     string                 `json:"severity"`
		AlertType    string                 `json:"alert_type"`
		TargetUserID *string                `json:"target_user_id"`
		Metadata     map[string]interface{} `json:"metadata"`
	}
	if err := decodeStrict(r, &req); err != nil {
		respondErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if strings.TrimSpace(req.Title) == "" {
		respondErr(w, http.StatusBadRequest, "title_required")
		return
	}
	if req.Severity == "" {
		req.Severity = "info"
	}
	if req.AlertType == "" {
		req.AlertType = "custom"
	}
	if !allowedSeverity[req.Severity] {
		respondErr(w, http.StatusBadRequest, "invalid_severity")
		return
	}
	if !allowedAlertType[req.AlertType] {
		respondErr(w, http.StatusBadRequest, "invalid_alert_type")
		return
	}

	var targetID *uuid.UUID
	if req.TargetUserID != nil && *req.TargetUserID != "" {
		uid, err := uuid.Parse(*req.TargetUserID)
		if err != nil {
			respondErr(w, http.StatusBadRequest, "invalid_target_user_id")
			return
		}
		// Cross-tenant check — target must belong to caller's business.
		var ok bool
		if err := h.db.QueryRow(r.Context(),
			`SELECT EXISTS(SELECT 1 FROM users WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL)`,
			uid, bizID,
		).Scan(&ok); err != nil || !ok {
			respondErr(w, http.StatusBadRequest, "target_not_in_tenant")
			return
		}
		targetID = &uid
	}

	metaBytes, _ := json.Marshal(req.Metadata)
	if len(metaBytes) == 0 || string(metaBytes) == "null" {
		metaBytes = []byte("{}")
	}

	var newID uuid.UUID
	err := h.db.QueryRow(r.Context(),
		`INSERT INTO dashboard_alerts
		   (business_id, created_by, target_user_id, title, message, severity, alert_type, metadata)
		 VALUES ($1,$2,$3,$4,$5,$6,$7,$8::jsonb)
		 RETURNING id`,
		bizID, claims.UserID, targetID,
		strings.TrimSpace(req.Title), req.Message, req.Severity, req.AlertType, metaBytes,
	).Scan(&newID)
	if err != nil {
		h.log.Error("create alert", zap.Error(err))
		respondErr(w, http.StatusInternalServerError, "create_failed")
		return
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditCreated,
		EntityType: "dashboard_alert",
		EntityID:   newID,
		NewData: map[string]interface{}{
			"title": req.Title, "severity": req.Severity, "alert_type": req.AlertType,
			"target_user_id": req.TargetUserID,
		},
		IPAddress: r.RemoteAddr,
	})

	respond(w, http.StatusCreated, map[string]interface{}{"id": newID})
}

// GetAlert (GET /api/v1/dashboard/alerts/:id).
func (h *Handler) GetAlert(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	if !h.requirePermission(w, r, "dashboard.view", uuid.Nil) {
		return
	}

	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		respondErr(w, http.StatusBadRequest, "invalid_id")
		return
	}

	a := &alertRow{}
	err = h.db.QueryRow(r.Context(),
		`SELECT id, business_id, created_by, updated_by, target_user_id,
		        title, message, severity, alert_type, status, metadata,
		        acknowledged_at, acknowledged_by, created_at, updated_at
		 FROM dashboard_alerts WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID,
	).Scan(&a.ID, &a.BusinessID, &a.CreatedBy, &a.UpdatedBy, &a.TargetUserID,
		&a.Title, &a.Message, &a.Severity, &a.AlertType, &a.Status, &a.Metadata,
		&a.AcknowledgedAt, &a.AcknowledgedBy, &a.CreatedAt, &a.UpdatedAt)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			respondErr(w, http.StatusNotFound, "not_found")
			return
		}
		respondErr(w, http.StatusInternalServerError, "query_failed")
		return
	}
	respond(w, http.StatusOK, a)
}

// UpdateAlert (PATCH /api/v1/dashboard/alerts/:id).
func (h *Handler) UpdateAlert(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "dashboard.alert_manage", uuid.Nil) {
		return
	}

	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		respondErr(w, http.StatusBadRequest, "invalid_id")
		return
	}

	var req struct {
		Title     *string                `json:"title"`
		Message   *string                `json:"message"`
		Severity  *string                `json:"severity"`
		AlertType *string                `json:"alert_type"`
		Status    *string                `json:"status"`
		Metadata  map[string]interface{} `json:"metadata"`
	}
	if err := decodeStrict(r, &req); err != nil {
		respondErr(w, http.StatusBadRequest, err.Error())
		return
	}

	if req.Severity != nil && !allowedSeverity[*req.Severity] {
		respondErr(w, http.StatusBadRequest, "invalid_severity")
		return
	}
	if req.AlertType != nil && !allowedAlertType[*req.AlertType] {
		respondErr(w, http.StatusBadRequest, "invalid_alert_type")
		return
	}

	// Load current row for transition validation + audit old data.
	var current alertRow
	err = h.db.QueryRow(r.Context(),
		`SELECT id, status, severity, alert_type, title, message
		 FROM dashboard_alerts WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID,
	).Scan(&current.ID, &current.Status, &current.Severity, &current.AlertType, &current.Title, &current.Message)
	if err != nil {
		respondErr(w, http.StatusNotFound, "not_found")
		return
	}

	if req.Status != nil {
		if !allowedStatus[*req.Status] {
			respondErr(w, http.StatusBadRequest, "invalid_status")
			return
		}
		if *req.Status != current.Status && !allowedTransition[[2]string{current.Status, *req.Status}] {
			respondErr(w, http.StatusConflict, "invalid_status_transition")
			return
		}
	}

	// Build the UPDATE dynamically — coalesce-style — preserving fields not sent.
	var meta []byte
	if req.Metadata != nil {
		meta, _ = json.Marshal(req.Metadata)
	}
	tag, err := h.db.Exec(r.Context(),
		`UPDATE dashboard_alerts SET
		   title       = COALESCE($3, title),
		   message     = COALESCE($4, message),
		   severity    = COALESCE($5, severity),
		   alert_type  = COALESCE($6, alert_type),
		   status      = COALESCE($7, status),
		   metadata    = COALESCE($8::jsonb, metadata),
		   updated_by  = $9,
		   updated_at  = NOW(),
		   acknowledged_at = CASE WHEN $7='acknowledged' AND status='active'
		                          THEN NOW() ELSE acknowledged_at END,
		   acknowledged_by = CASE WHEN $7='acknowledged' AND status='active'
		                          THEN $9 ELSE acknowledged_by END
		 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID, req.Title, req.Message, req.Severity, req.AlertType, req.Status, meta, claims.UserID,
	)
	if err != nil {
		h.log.Error("update alert", zap.Error(err))
		respondErr(w, http.StatusInternalServerError, "update_failed")
		return
	}
	if tag.RowsAffected() == 0 {
		respondErr(w, http.StatusNotFound, "not_found")
		return
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditUpdated,
		EntityType: "dashboard_alert",
		EntityID:   id,
		OldData:    map[string]interface{}{"status": current.Status, "severity": current.Severity, "title": current.Title},
		NewData:    map[string]interface{}{"status": derefStr(req.Status), "severity": derefStr(req.Severity), "title": derefStr(req.Title)},
		IPAddress:  r.RemoteAddr,
	})

	respond(w, http.StatusOK, map[string]string{"message": "updated"})
}

// DeleteAlert (DELETE /api/v1/dashboard/alerts/:id) — soft delete.
func (h *Handler) DeleteAlert(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "dashboard.alert_manage", uuid.Nil) {
		return
	}

	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		respondErr(w, http.StatusBadRequest, "invalid_id")
		return
	}

	tag, err := h.db.Exec(r.Context(),
		`UPDATE dashboard_alerts SET deleted_at=NOW(), updated_by=$3, updated_at=NOW()
		 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID, claims.UserID,
	)
	if err != nil {
		respondErr(w, http.StatusInternalServerError, "delete_failed")
		return
	}
	if tag.RowsAffected() == 0 {
		respondErr(w, http.StatusNotFound, "not_found")
		return
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditDeleted,
		EntityType: "dashboard_alert",
		EntityID:   id,
		IPAddress:  r.RemoteAddr,
	})

	w.WriteHeader(http.StatusNoContent)
}

// ── Export ───────────────────────────────────────────────────────

// Export (GET /api/v1/dashboard/export.csv) — KPIs + alerts as CSV.
func (h *Handler) Export(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "dashboard.export", uuid.Nil) {
		return
	}

	kpis := h.ownerKPIs(r.Context(), bizID)
	alerts := h.activeAlerts(r.Context(), bizID, nil)

	w.Header().Set("Content-Type", "text/csv; charset=utf-8")
	w.Header().Set("Content-Disposition",
		fmt.Sprintf(`attachment; filename="dashboard-%s.csv"`, time.Now().Format("2006-01-02")))

	cw := csv.NewWriter(w)
	defer cw.Flush()

	_ = cw.Write([]string{"section", "key", "value"})
	for k, v := range kpis {
		_ = cw.Write([]string{"kpi", k, fmt.Sprintf("%v", v)})
	}
	_ = cw.Write([]string{})
	_ = cw.Write([]string{"alert_id", "title", "severity", "type", "status", "created_at"})
	for _, a := range alerts {
		_ = cw.Write([]string{
			a.ID.String(), a.Title, a.Severity, a.AlertType, a.Status,
			a.CreatedAt.UTC().Format(time.RFC3339),
		})
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditExported,
		EntityType: "dashboard",
		IPAddress:  r.RemoteAddr,
	})
}

// ── Internal helpers ─────────────────────────────────────────────

// activeAlerts returns alerts visible to the caller. If targetUser
// is non-nil, only tenant-wide alerts (target NULL) and alerts
// targeted at that user are returned.
func (h *Handler) activeAlerts(ctx context.Context, bizID uuid.UUID, targetUser *uuid.UUID) []*alertRow {
	q := `SELECT id, business_id, created_by, updated_by, target_user_id,
	             title, message, severity, alert_type, status, metadata,
	             acknowledged_at, acknowledged_by, created_at, updated_at
	      FROM dashboard_alerts
	      WHERE business_id=$1 AND deleted_at IS NULL AND status='active'`
	args := []interface{}{bizID}
	if targetUser != nil {
		q += ` AND (target_user_id IS NULL OR target_user_id=$2)`
		args = append(args, *targetUser)
	}
	q += ` ORDER BY CASE severity WHEN 'critical' THEN 1 WHEN 'warning' THEN 2 ELSE 3 END, created_at DESC LIMIT 50`

	rows, err := h.db.Query(ctx, q, args...)
	if err != nil {
		h.log.Warn("alerts query", zap.Error(err))
		return []*alertRow{}
	}
	defer rows.Close()

	out := []*alertRow{}
	for rows.Next() {
		a := &alertRow{}
		if err := rows.Scan(
			&a.ID, &a.BusinessID, &a.CreatedBy, &a.UpdatedBy, &a.TargetUserID,
			&a.Title, &a.Message, &a.Severity, &a.AlertType, &a.Status, &a.Metadata,
			&a.AcknowledgedAt, &a.AcknowledgedBy, &a.CreatedAt, &a.UpdatedAt,
		); err == nil {
			out = append(out, a)
		}
	}
	return out
}

// requirePermission checks the role_permissions catalog and emits a
// DASHBOARD_ACCESS_DENIED audit event on rejection. Returns false
// after writing the 403 response.
func (h *Handler) requirePermission(w http.ResponseWriter, r *http.Request, key string, _ uuid.UUID) bool {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if claims == nil {
		respondErr(w, http.StatusUnauthorized, "unauthorized")
		return false
	}

	var allowed bool
	err := h.db.QueryRow(r.Context(),
		`SELECT EXISTS(
		   SELECT 1
		   FROM role_permissions rp
		   JOIN permissions p ON p.id = rp.permission_id
		   WHERE rp.role=$1 AND p.key=$2
		     AND (rp.business_id=$3 OR
		          (rp.business_id IS NULL AND NOT EXISTS (
		             SELECT 1 FROM role_permissions rp2 WHERE rp2.role=$1 AND rp2.business_id=$3
		          )))
		 )`,
		claims.Role, key, bizID,
	).Scan(&allowed)
	if err != nil {
		h.log.Error("permission check", zap.String("key", key), zap.Error(err))
		respondErr(w, http.StatusInternalServerError, "permission_check_failed")
		return false
	}
	if !allowed {
		h.audit.Log(r.Context(), middleware.AuditEntry{
			BusinessID: bizID,
			UserID:     claims.UserID,
			Action:     AuditAccessDenied,
			EntityType: "dashboard",
			NewData:    map[string]interface{}{"required": key, "role": claims.Role},
			IPAddress:  r.RemoteAddr,
		})
		respondErr(w, http.StatusForbidden, "forbidden:"+key)
		return false
	}
	return true
}

// decodeStrict enforces the spec's "reject unknown fields" + body-size rules.
func decodeStrict(r *http.Request, dst interface{}) error {
	r.Body = http.MaxBytesReader(nil, r.Body, maxBodyBytes)
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(dst); err != nil {
		var maxErr *http.MaxBytesError
		if errors.As(err, &maxErr) {
			return errors.New("body_too_large")
		}
		if errors.Is(err, io.EOF) {
			return errors.New("empty_body")
		}
		return errors.New("invalid_request")
	}
	if dec.More() {
		return errors.New("trailing_data")
	}
	return nil
}

func derefStr(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}

func respond(w http.ResponseWriter, status int, body interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if body != nil {
		_ = json.NewEncoder(w).Encode(body)
	}
}

func respondErr(w http.ResponseWriter, status int, msg string) {
	respond(w, status, map[string]string{"error": msg})
}
