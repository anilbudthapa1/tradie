// Package analytics implements Module 12 — KPI Analytics Widgets.
//
// Two services live in this package:
//   - KPIWidgetService    — CRUD on persisted widget definitions (kpi_widgets table)
//   - MetricsQueryService — resolves the live numeric value of a widget
//                           by mapping its allow-listed metric_key to a
//                           tenant-scoped SQL query
//
// Every endpoint enforces zero-trust:
//   - business_id only ever comes from BusinessIDFromCtx
//   - permission key (analytics.view / .widget_manage / .export) checked
//     against role_permissions before any read/write
//   - JSON decoding rejects unknown fields and caps body size
//   - sensitive actions emit KPI_ANALYTICS_WIDGETS_* audit events
package analytics

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
	AuditViewed       = "KPI_ANALYTICS_WIDGETS_VIEWED"
	AuditCreated      = "KPI_ANALYTICS_WIDGETS_CREATED"
	AuditUpdated      = "KPI_ANALYTICS_WIDGETS_UPDATED"
	AuditDeleted      = "KPI_ANALYTICS_WIDGETS_DELETED"
	AuditAccessDenied = "KPI_ANALYTICS_WIDGETS_ACCESS_DENIED"
	AuditExported     = "KPI_ANALYTICS_WIDGETS_EXPORTED"

	maxBodyBytes = 64 * 1024
)

// Allow-listed enums (spec §Validation Rules).
var (
	allowedPeriod = map[string]bool{"today": true, "week": true, "month": true, "quarter": true, "year": true}
	allowedColor  = map[string]bool{"blue": true, "green": true, "red": true, "navy": true, "grey": true}
	allowedIcon   = map[string]bool{
		"chart_2": true, "dollar_circle": true, "briefcase": true, "document_text": true,
		"receipt": true, "wallet": true, "health": true, "warning_2": true, "people": true,
	}
	allowedStatus     = map[string]bool{"active": true, "archived": true}
	allowedTransition = map[[2]string]bool{
		{"active", "archived"}: true,
		{"archived", "active"}: true,
	}
)

// ── MetricsQueryService — registry ───────────────────────────────

// metricSpec defines one allow-listed metric. resolve runs a tenant-
// scoped query and returns a numeric value with its unit.
type metricSpec struct {
	Key          string
	Label        string
	Category     string // revenue, jobs, quotes, invoices, payroll, safety, personal
	Unit         string // count, aud, percent
	OwnerOnly    bool   // financial metrics restricted to owner_view-equivalent roles
	SupportsUser bool   // works in /me endpoint with user filter
	resolve      func(ctx context.Context, db *pgxpool.Pool, biz uuid.UUID, user uuid.UUID, period string) (float64, error)
}

// scanFloat is a small helper that runs a single-value query and
// returns 0 + the error if the row is missing.
func scanFloat(ctx context.Context, db *pgxpool.Pool, q string, args ...interface{}) (float64, error) {
	var v float64
	err := db.QueryRow(ctx, q, args...).Scan(&v)
	return v, err
}

// periodInterval translates an allow-listed period to a Postgres
// INTERVAL string. The result is concatenated into queries — only
// allow-listed values reach this function.
func periodInterval(p string) string {
	switch p {
	case "today":
		return "1 day"
	case "week":
		return "7 days"
	case "quarter":
		return "3 months"
	case "year":
		return "1 year"
	default:
		return "1 month"
	}
}

// metricRegistry is built lazily so test code can inspect it but the
// definitions are static.
var metricRegistry = map[string]*metricSpec{
	// ── Revenue ────────────────────────────────────────────────
	"revenue_period": {
		Key: "revenue_period", Label: "Revenue", Category: "revenue", Unit: "aud", OwnerOnly: true,
		resolve: func(ctx context.Context, db *pgxpool.Pool, biz, _ uuid.UUID, period string) (float64, error) {
			return scanFloat(ctx, db,
				fmt.Sprintf(`SELECT COALESCE(SUM(total_amount),0) FROM invoices
				             WHERE business_id=$1 AND status='paid'
				               AND paid_at >= NOW() - INTERVAL '%s'`, periodInterval(period)),
				biz)
		},
	},
	"revenue_month_to_date": {
		Key: "revenue_month_to_date", Label: "Revenue MTD", Category: "revenue", Unit: "aud", OwnerOnly: true,
		resolve: func(ctx context.Context, db *pgxpool.Pool, biz, _ uuid.UUID, _ string) (float64, error) {
			return scanFloat(ctx, db,
				`SELECT COALESCE(SUM(total_amount),0) FROM invoices
				 WHERE business_id=$1 AND status='paid' AND paid_at >= DATE_TRUNC('month', NOW())`,
				biz)
		},
	},
	// ── Jobs ───────────────────────────────────────────────────
	"jobs_in_progress": {
		Key: "jobs_in_progress", Label: "Jobs in progress", Category: "jobs", Unit: "count",
		resolve: func(ctx context.Context, db *pgxpool.Pool, biz, _ uuid.UUID, _ string) (float64, error) {
			return scanFloat(ctx, db,
				`SELECT COUNT(*) FROM jobs WHERE business_id=$1 AND status='in_progress'`, biz)
		},
	},
	"jobs_today": {
		Key: "jobs_today", Label: "Jobs today", Category: "jobs", Unit: "count",
		resolve: func(ctx context.Context, db *pgxpool.Pool, biz, _ uuid.UUID, _ string) (float64, error) {
			return scanFloat(ctx, db,
				`SELECT COUNT(*) FROM jobs
				 WHERE business_id=$1 AND DATE(scheduled_start AT TIME ZONE 'UTC')=CURRENT_DATE
				   AND status IN ('scheduled','in_progress')`, biz)
		},
	},
	"jobs_completed_period": {
		Key: "jobs_completed_period", Label: "Jobs completed", Category: "jobs", Unit: "count",
		resolve: func(ctx context.Context, db *pgxpool.Pool, biz, _ uuid.UUID, period string) (float64, error) {
			return scanFloat(ctx, db,
				fmt.Sprintf(`SELECT COUNT(*) FROM jobs
				             WHERE business_id=$1 AND status='completed'
				               AND updated_at >= NOW() - INTERVAL '%s'`, periodInterval(period)),
				biz)
		},
	},
	// ── Quotes ─────────────────────────────────────────────────
	"quotes_pending": {
		Key: "quotes_pending", Label: "Pending quotes", Category: "quotes", Unit: "count",
		resolve: func(ctx context.Context, db *pgxpool.Pool, biz, _ uuid.UUID, _ string) (float64, error) {
			return scanFloat(ctx, db,
				`SELECT COUNT(*) FROM quotes WHERE business_id=$1 AND status='sent'`, biz)
		},
	},
	"quote_acceptance_rate": {
		Key: "quote_acceptance_rate", Label: "Quote acceptance rate", Category: "quotes", Unit: "percent",
		resolve: func(ctx context.Context, db *pgxpool.Pool, biz, _ uuid.UUID, period string) (float64, error) {
			var accepted, total float64
			err := db.QueryRow(ctx,
				fmt.Sprintf(`SELECT
				   SUM(CASE WHEN status='accepted' THEN 1 ELSE 0 END),
				   COUNT(*)
				 FROM quotes WHERE business_id=$1 AND created_at >= NOW() - INTERVAL '%s'`,
					periodInterval(period)),
				biz).Scan(&accepted, &total)
			if err != nil || total == 0 {
				return 0, err
			}
			return (accepted / total) * 100, nil
		},
	},
	// ── Invoices ───────────────────────────────────────────────
	"invoices_overdue": {
		Key: "invoices_overdue", Label: "Overdue invoices", Category: "invoices", Unit: "count", OwnerOnly: true,
		resolve: func(ctx context.Context, db *pgxpool.Pool, biz, _ uuid.UUID, _ string) (float64, error) {
			return scanFloat(ctx, db,
				`SELECT COUNT(*) FROM invoices WHERE business_id=$1 AND status='overdue'`, biz)
		},
	},
	"invoices_unpaid_total": {
		Key: "invoices_unpaid_total", Label: "Unpaid total", Category: "invoices", Unit: "aud", OwnerOnly: true,
		resolve: func(ctx context.Context, db *pgxpool.Pool, biz, _ uuid.UUID, _ string) (float64, error) {
			return scanFloat(ctx, db,
				`SELECT COALESCE(SUM(amount_due),0) FROM invoices
				 WHERE business_id=$1 AND status IN ('sent','overdue','partial')`, biz)
		},
	},
	// ── Payroll ────────────────────────────────────────────────
	"active_workers": {
		Key: "active_workers", Label: "Active workers", Category: "payroll", Unit: "count",
		resolve: func(ctx context.Context, db *pgxpool.Pool, biz, _ uuid.UUID, _ string) (float64, error) {
			return scanFloat(ctx, db,
				`SELECT COUNT(*) FROM users
				 WHERE business_id=$1 AND role!='customer' AND is_active=true AND deleted_at IS NULL`,
				biz)
		},
	},
	// ── Safety ─────────────────────────────────────────────────
	"safety_compliance_expiring": {
		Key: "safety_compliance_expiring", Label: "Compliance expiring (30d)", Category: "safety", Unit: "count",
		resolve: func(ctx context.Context, db *pgxpool.Pool, biz, _ uuid.UUID, _ string) (float64, error) {
			// Tolerate missing table — safety module may not be installed.
			v, err := scanFloat(ctx, db,
				`SELECT COUNT(*) FROM compliance_documents
				 WHERE business_id=$1 AND expiry_date <= NOW() + INTERVAL '30 days'
				   AND expiry_date >= NOW()`, biz)
			if err != nil {
				return 0, nil
			}
			return v, nil
		},
	},
	// ── Personal (employee self-service) ──────────────────────
	"my_jobs_today": {
		Key: "my_jobs_today", Label: "My jobs today", Category: "personal", Unit: "count", SupportsUser: true,
		resolve: func(ctx context.Context, db *pgxpool.Pool, biz, user uuid.UUID, _ string) (float64, error) {
			return scanFloat(ctx, db,
				`SELECT COUNT(DISTINCT j.id) FROM jobs j
				 JOIN job_assignments ja ON ja.job_id=j.id
				 WHERE j.business_id=$1 AND ja.user_id=$2
				   AND DATE(j.scheduled_start AT TIME ZONE 'UTC')=CURRENT_DATE`, biz, user)
		},
	},
	"my_tasks_pending": {
		Key: "my_tasks_pending", Label: "My pending tasks", Category: "personal", Unit: "count", SupportsUser: true,
		resolve: func(ctx context.Context, db *pgxpool.Pool, biz, user uuid.UUID, _ string) (float64, error) {
			return scanFloat(ctx, db,
				`SELECT COUNT(*) FROM tasks
				 WHERE business_id=$1 AND assigned_to=$2 AND status='pending'`, biz, user)
		},
	},
}

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

// ── Catalog ──────────────────────────────────────────────────────

// Catalog (GET /api/v1/analytics/catalog) — list all metric keys
// the UI may pick from when building widgets. OwnerOnly metrics are
// filtered out for callers without dashboard.owner_view.
func (h *Handler) Catalog(w http.ResponseWriter, r *http.Request) {
	if !h.requirePermission(w, r, "analytics.view") {
		return
	}
	claims := middleware.ClaimsFromCtx(r.Context())
	elevated := middleware.IsAtLeast(claims.Role, "manager")

	type entry struct {
		Key      string `json:"key"`
		Label    string `json:"label"`
		Category string `json:"category"`
		Unit     string `json:"unit"`
		Personal bool   `json:"personal"`
	}
	out := []entry{}
	for _, m := range metricRegistry {
		if m.OwnerOnly && !elevated {
			continue
		}
		out = append(out, entry{
			Key: m.Key, Label: m.Label, Category: m.Category, Unit: m.Unit,
			Personal: m.SupportsUser,
		})
	}
	respond(w, http.StatusOK, out)
}

// ── KPIWidgetService — CRUD ──────────────────────────────────────

type widgetRow struct {
	ID             uuid.UUID  `json:"id"`
	BusinessID     uuid.UUID  `json:"-"`
	CreatedBy      *uuid.UUID `json:"created_by"`
	UpdatedBy      *uuid.UUID `json:"updated_by"`
	TargetUserID   *uuid.UUID `json:"target_user_id"`
	Title          string     `json:"title"`
	MetricKey      string     `json:"metric_key"`
	Period         string     `json:"period"`
	ColorToken     string     `json:"color_token"`
	IconToken      string     `json:"icon_token"`
	DisplayOrder   int        `json:"display_order"`
	Status         string     `json:"status"`
	IsPersonal     bool       `json:"is_personal"`
	FilterMetadata []byte     `json:"-"`
	Metadata       []byte     `json:"-"`
	CreatedAt      time.Time  `json:"created_at"`
	UpdatedAt      time.Time  `json:"updated_at"`
}

func (a *widgetRow) MarshalJSON() ([]byte, error) {
	type alias widgetRow
	fm := json.RawMessage(a.FilterMetadata)
	if len(fm) == 0 {
		fm = json.RawMessage("{}")
	}
	mm := json.RawMessage(a.Metadata)
	if len(mm) == 0 {
		mm = json.RawMessage("{}")
	}
	return json.Marshal(struct {
		*alias
		FilterMetadata json.RawMessage `json:"filter_metadata"`
		Metadata       json.RawMessage `json:"metadata"`
	}{(*alias)(a), fm, mm})
}

// List (GET /api/v1/analytics/widgets) — owner / manager scope.
func (h *Handler) ListWidgets(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	if !h.requirePermission(w, r, "analytics.view") {
		return
	}

	statusFilter := strings.TrimSpace(r.URL.Query().Get("status"))
	if statusFilter != "" && !allowedStatus[statusFilter] {
		respondErr(w, http.StatusBadRequest, "invalid_status")
		return
	}
	limit := 100
	if v := r.URL.Query().Get("limit"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 && n <= 500 {
			limit = n
		}
	}

	rows, err := h.db.Query(r.Context(),
		`SELECT id, business_id, created_by, updated_by, target_user_id,
		        title, metric_key, period, color_token, icon_token,
		        display_order, status, is_personal,
		        filter_metadata, metadata, created_at, updated_at
		 FROM kpi_widgets
		 WHERE business_id=$1 AND deleted_at IS NULL
		   AND ($2='' OR status=$2)
		 ORDER BY display_order, created_at
		 LIMIT $3`,
		bizID, statusFilter, limit)
	if err != nil {
		h.log.Error("list widgets", zap.Error(err))
		respondErr(w, http.StatusInternalServerError, "query_failed")
		return
	}
	defer rows.Close()

	out := []*widgetRow{}
	for rows.Next() {
		wr := &widgetRow{}
		if err := rows.Scan(&wr.ID, &wr.BusinessID, &wr.CreatedBy, &wr.UpdatedBy, &wr.TargetUserID,
			&wr.Title, &wr.MetricKey, &wr.Period, &wr.ColorToken, &wr.IconToken,
			&wr.DisplayOrder, &wr.Status, &wr.IsPersonal,
			&wr.FilterMetadata, &wr.Metadata, &wr.CreatedAt, &wr.UpdatedAt); err == nil {
			out = append(out, wr)
		}
	}
	respond(w, http.StatusOK, out)
}

// MeView (GET /api/v1/me/analytics/widgets) — explicit safe self-service
// endpoint per spec §API Endpoint Pattern. Only returns active widgets
// that are tenant-shared (target_user_id IS NULL) or targeted at the
// caller, with their current value precomputed.
func (h *Handler) MeView(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "analytics.view") {
		return
	}

	rows, err := h.db.Query(r.Context(),
		`SELECT id, business_id, created_by, updated_by, target_user_id,
		        title, metric_key, period, color_token, icon_token,
		        display_order, status, is_personal,
		        filter_metadata, metadata, created_at, updated_at
		 FROM kpi_widgets
		 WHERE business_id=$1 AND deleted_at IS NULL AND status='active'
		   AND (target_user_id IS NULL OR target_user_id=$2)
		 ORDER BY display_order, created_at`,
		bizID, claims.UserID)
	if err != nil {
		respondErr(w, http.StatusInternalServerError, "query_failed")
		return
	}
	defer rows.Close()

	type tile struct {
		*widgetRow
		Value *float64 `json:"value"`
		Unit  string   `json:"unit"`
		Error string   `json:"error,omitempty"`
	}
	out := []*tile{}
	for rows.Next() {
		wr := &widgetRow{}
		if err := rows.Scan(&wr.ID, &wr.BusinessID, &wr.CreatedBy, &wr.UpdatedBy, &wr.TargetUserID,
			&wr.Title, &wr.MetricKey, &wr.Period, &wr.ColorToken, &wr.IconToken,
			&wr.DisplayOrder, &wr.Status, &wr.IsPersonal,
			&wr.FilterMetadata, &wr.Metadata, &wr.CreatedAt, &wr.UpdatedAt); err != nil {
			continue
		}
		t := &tile{widgetRow: wr}
		spec, ok := metricRegistry[wr.MetricKey]
		if !ok {
			t.Error = "unknown_metric"
			out = append(out, t)
			continue
		}
		// Owner-only metrics in /me view: skip silently for non-elevated callers.
		if spec.OwnerOnly && !middleware.IsAtLeast(claims.Role, "manager") {
			continue
		}
		t.Unit = spec.Unit
		v, err := spec.resolve(r.Context(), h.db, bizID, claims.UserID, wr.Period)
		if err != nil {
			h.log.Warn("metric resolve", zap.String("key", wr.MetricKey), zap.Error(err))
			t.Error = "resolve_failed"
		} else {
			t.Value = &v
		}
		out = append(out, t)
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditViewed,
		EntityType: "kpi_widgets.me",
		IPAddress:  r.RemoteAddr,
	})

	respond(w, http.StatusOK, out)
}

// CreateWidget (POST /api/v1/analytics/widgets).
func (h *Handler) CreateWidget(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "analytics.widget_manage") {
		return
	}

	var req struct {
		Title          string                 `json:"title"`
		MetricKey      string                 `json:"metric_key"`
		Period         string                 `json:"period"`
		ColorToken     string                 `json:"color_token"`
		IconToken      string                 `json:"icon_token"`
		DisplayOrder   *int                   `json:"display_order"`
		IsPersonal     bool                   `json:"is_personal"`
		TargetUserID   *string                `json:"target_user_id"`
		FilterMetadata map[string]interface{} `json:"filter_metadata"`
		Metadata       map[string]interface{} `json:"metadata"`
	}
	if err := decodeStrict(r, &req); err != nil {
		respondErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if strings.TrimSpace(req.Title) == "" {
		respondErr(w, http.StatusBadRequest, "title_required")
		return
	}
	if _, ok := metricRegistry[req.MetricKey]; !ok {
		respondErr(w, http.StatusBadRequest, "invalid_metric_key")
		return
	}
	if req.Period == "" {
		req.Period = "month"
	}
	if !allowedPeriod[req.Period] {
		respondErr(w, http.StatusBadRequest, "invalid_period")
		return
	}
	if req.ColorToken == "" {
		req.ColorToken = "blue"
	}
	if !allowedColor[req.ColorToken] {
		respondErr(w, http.StatusBadRequest, "invalid_color_token")
		return
	}
	if req.IconToken == "" {
		req.IconToken = "chart_2"
	}
	if !allowedIcon[req.IconToken] {
		respondErr(w, http.StatusBadRequest, "invalid_icon_token")
		return
	}

	var targetID *uuid.UUID
	if req.TargetUserID != nil && *req.TargetUserID != "" {
		uid, err := uuid.Parse(*req.TargetUserID)
		if err != nil {
			respondErr(w, http.StatusBadRequest, "invalid_target_user_id")
			return
		}
		var ok bool
		if err := h.db.QueryRow(r.Context(),
			`SELECT EXISTS(SELECT 1 FROM users WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL)`,
			uid, bizID).Scan(&ok); err != nil || !ok {
			respondErr(w, http.StatusBadRequest, "target_not_in_tenant")
			return
		}
		targetID = &uid
	}

	displayOrder := 0
	if req.DisplayOrder != nil {
		displayOrder = *req.DisplayOrder
	}
	filterBytes := jsonOrEmpty(req.FilterMetadata)
	metaBytes := jsonOrEmpty(req.Metadata)

	var newID uuid.UUID
	err := h.db.QueryRow(r.Context(),
		`INSERT INTO kpi_widgets
		   (business_id, created_by, target_user_id, title, metric_key, period,
		    color_token, icon_token, display_order, is_personal, filter_metadata, metadata)
		 VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11::jsonb,$12::jsonb)
		 RETURNING id`,
		bizID, claims.UserID, targetID,
		strings.TrimSpace(req.Title), req.MetricKey, req.Period,
		req.ColorToken, req.IconToken, displayOrder, req.IsPersonal,
		filterBytes, metaBytes,
	).Scan(&newID)
	if err != nil {
		h.log.Error("create widget", zap.Error(err))
		respondErr(w, http.StatusInternalServerError, "create_failed")
		return
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditCreated,
		EntityType: "kpi_widget",
		EntityID:   newID,
		NewData: map[string]interface{}{
			"title": req.Title, "metric_key": req.MetricKey, "period": req.Period,
		},
		IPAddress: r.RemoteAddr,
	})

	respond(w, http.StatusCreated, map[string]interface{}{"id": newID})
}

// GetWidget (GET /api/v1/analytics/widgets/:id) — returns the row
// plus its currently-resolved value.
func (h *Handler) GetWidget(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "analytics.view") {
		return
	}

	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		respondErr(w, http.StatusBadRequest, "invalid_id")
		return
	}

	wr := &widgetRow{}
	err = h.db.QueryRow(r.Context(),
		`SELECT id, business_id, created_by, updated_by, target_user_id,
		        title, metric_key, period, color_token, icon_token,
		        display_order, status, is_personal,
		        filter_metadata, metadata, created_at, updated_at
		 FROM kpi_widgets WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID).Scan(&wr.ID, &wr.BusinessID, &wr.CreatedBy, &wr.UpdatedBy, &wr.TargetUserID,
		&wr.Title, &wr.MetricKey, &wr.Period, &wr.ColorToken, &wr.IconToken,
		&wr.DisplayOrder, &wr.Status, &wr.IsPersonal,
		&wr.FilterMetadata, &wr.Metadata, &wr.CreatedAt, &wr.UpdatedAt)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			respondErr(w, http.StatusNotFound, "not_found")
			return
		}
		respondErr(w, http.StatusInternalServerError, "query_failed")
		return
	}

	type out struct {
		*widgetRow
		Value *float64 `json:"value"`
		Unit  string   `json:"unit"`
		Error string   `json:"error,omitempty"`
	}
	o := &out{widgetRow: wr}
	spec, ok := metricRegistry[wr.MetricKey]
	if !ok {
		o.Error = "unknown_metric"
	} else if spec.OwnerOnly && !middleware.IsAtLeast(claims.Role, "manager") {
		respondErr(w, http.StatusForbidden, "forbidden:owner_only_metric")
		return
	} else {
		o.Unit = spec.Unit
		v, err := spec.resolve(r.Context(), h.db, bizID, claims.UserID, wr.Period)
		if err != nil {
			o.Error = "resolve_failed"
		} else {
			o.Value = &v
		}
	}

	respond(w, http.StatusOK, o)
}

// UpdateWidget (PATCH /api/v1/analytics/widgets/:id).
func (h *Handler) UpdateWidget(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "analytics.widget_manage") {
		return
	}

	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		respondErr(w, http.StatusBadRequest, "invalid_id")
		return
	}

	var req struct {
		Title          *string                `json:"title"`
		Period         *string                `json:"period"`
		ColorToken     *string                `json:"color_token"`
		IconToken      *string                `json:"icon_token"`
		DisplayOrder   *int                   `json:"display_order"`
		Status         *string                `json:"status"`
		MetricKey      *string                `json:"metric_key"`
		FilterMetadata map[string]interface{} `json:"filter_metadata"`
		Metadata       map[string]interface{} `json:"metadata"`
	}
	if err := decodeStrict(r, &req); err != nil {
		respondErr(w, http.StatusBadRequest, err.Error())
		return
	}

	if req.Period != nil && !allowedPeriod[*req.Period] {
		respondErr(w, http.StatusBadRequest, "invalid_period")
		return
	}
	if req.ColorToken != nil && !allowedColor[*req.ColorToken] {
		respondErr(w, http.StatusBadRequest, "invalid_color_token")
		return
	}
	if req.IconToken != nil && !allowedIcon[*req.IconToken] {
		respondErr(w, http.StatusBadRequest, "invalid_icon_token")
		return
	}
	if req.MetricKey != nil {
		if _, ok := metricRegistry[*req.MetricKey]; !ok {
			respondErr(w, http.StatusBadRequest, "invalid_metric_key")
			return
		}
	}

	// Load current row for status-transition + audit old data.
	var current widgetRow
	err = h.db.QueryRow(r.Context(),
		`SELECT id, status, title, metric_key, period
		 FROM kpi_widgets WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID).Scan(&current.ID, &current.Status, &current.Title, &current.MetricKey, &current.Period)
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

	var fmBytes, mmBytes []byte
	if req.FilterMetadata != nil {
		fmBytes, _ = json.Marshal(req.FilterMetadata)
	}
	if req.Metadata != nil {
		mmBytes, _ = json.Marshal(req.Metadata)
	}

	tag, err := h.db.Exec(r.Context(),
		`UPDATE kpi_widgets SET
		   title           = COALESCE($3, title),
		   metric_key      = COALESCE($4, metric_key),
		   period          = COALESCE($5, period),
		   color_token     = COALESCE($6, color_token),
		   icon_token      = COALESCE($7, icon_token),
		   display_order   = COALESCE($8, display_order),
		   status          = COALESCE($9, status),
		   filter_metadata = COALESCE($10::jsonb, filter_metadata),
		   metadata        = COALESCE($11::jsonb, metadata),
		   updated_by      = $12,
		   updated_at      = NOW()
		 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID, req.Title, req.MetricKey, req.Period, req.ColorToken, req.IconToken,
		req.DisplayOrder, req.Status, fmBytes, mmBytes, claims.UserID)
	if err != nil {
		h.log.Error("update widget", zap.Error(err))
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
		EntityType: "kpi_widget",
		EntityID:   id,
		OldData:    map[string]interface{}{"status": current.Status, "title": current.Title, "metric_key": current.MetricKey},
		NewData:    map[string]interface{}{"status": derefStr(req.Status), "title": derefStr(req.Title), "metric_key": derefStr(req.MetricKey)},
		IPAddress:  r.RemoteAddr,
	})

	respond(w, http.StatusOK, map[string]string{"message": "updated"})
}

// DeleteWidget (DELETE /api/v1/analytics/widgets/:id) — soft delete.
func (h *Handler) DeleteWidget(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "analytics.widget_manage") {
		return
	}

	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		respondErr(w, http.StatusBadRequest, "invalid_id")
		return
	}

	tag, err := h.db.Exec(r.Context(),
		`UPDATE kpi_widgets SET deleted_at=NOW(), updated_by=$3, updated_at=NOW()
		 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID, claims.UserID)
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
		EntityType: "kpi_widget",
		EntityID:   id,
		IPAddress:  r.RemoteAddr,
	})

	w.WriteHeader(http.StatusNoContent)
}

// Reorder (POST /api/v1/analytics/widgets/reorder) — bulk update of
// display_order. Body: {ordered_ids: [uuid, uuid, ...]}.
func (h *Handler) Reorder(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "analytics.widget_manage") {
		return
	}

	var req struct {
		OrderedIDs []string `json:"ordered_ids"`
	}
	if err := decodeStrict(r, &req); err != nil {
		respondErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if len(req.OrderedIDs) == 0 || len(req.OrderedIDs) > 200 {
		respondErr(w, http.StatusBadRequest, "invalid_count")
		return
	}

	tx, err := h.db.Begin(r.Context())
	if err != nil {
		respondErr(w, http.StatusInternalServerError, "tx_failed")
		return
	}
	defer tx.Rollback(r.Context())

	for i, raw := range req.OrderedIDs {
		uid, err := uuid.Parse(raw)
		if err != nil {
			respondErr(w, http.StatusBadRequest, "invalid_id:"+raw)
			return
		}
		if _, err := tx.Exec(r.Context(),
			`UPDATE kpi_widgets SET display_order=$3, updated_by=$4, updated_at=NOW()
			 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
			uid, bizID, i, claims.UserID); err != nil {
			respondErr(w, http.StatusInternalServerError, "update_failed")
			return
		}
	}
	if err := tx.Commit(r.Context()); err != nil {
		respondErr(w, http.StatusInternalServerError, "commit_failed")
		return
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditUpdated,
		EntityType: "kpi_widgets.reorder",
		NewData:    map[string]interface{}{"count": len(req.OrderedIDs)},
		IPAddress:  r.RemoteAddr,
	})

	respond(w, http.StatusOK, map[string]interface{}{"reordered": len(req.OrderedIDs)})
}

// ── Metric query ────────────────────────────────────────────────

// MetricValue (GET /api/v1/analytics/metrics/:key) — execute one
// allow-listed metric without requiring a stored widget. period is
// passed as a query param.
func (h *Handler) MetricValue(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "analytics.view") {
		return
	}

	key := chi.URLParam(r, "key")
	spec, ok := metricRegistry[key]
	if !ok {
		respondErr(w, http.StatusBadRequest, "invalid_metric_key")
		return
	}
	if spec.OwnerOnly && !middleware.IsAtLeast(claims.Role, "manager") {
		h.audit.Log(r.Context(), middleware.AuditEntry{
			BusinessID: bizID,
			UserID:     claims.UserID,
			Action:     AuditAccessDenied,
			EntityType: "kpi_widget.metric",
			NewData:    map[string]interface{}{"required": "owner_view", "metric": key},
			IPAddress:  r.RemoteAddr,
		})
		respondErr(w, http.StatusForbidden, "forbidden:owner_only_metric")
		return
	}

	period := strings.TrimSpace(r.URL.Query().Get("period"))
	if period == "" {
		period = "month"
	}
	if !allowedPeriod[period] {
		respondErr(w, http.StatusBadRequest, "invalid_period")
		return
	}

	v, err := spec.resolve(r.Context(), h.db, bizID, claims.UserID, period)
	if err != nil {
		h.log.Warn("metric resolve", zap.String("key", key), zap.Error(err))
		respondErr(w, http.StatusInternalServerError, "resolve_failed")
		return
	}

	respond(w, http.StatusOK, map[string]interface{}{
		"key": key, "value": v, "unit": spec.Unit, "period": period,
	})
}

// ── Export ──────────────────────────────────────────────────────

// Export (GET /api/v1/analytics/widgets.csv) — CSV of every active
// widget with its currently-resolved value.
func (h *Handler) Export(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "analytics.export") {
		return
	}

	rows, err := h.db.Query(r.Context(),
		`SELECT id, title, metric_key, period, status, display_order
		 FROM kpi_widgets
		 WHERE business_id=$1 AND deleted_at IS NULL AND status='active'
		 ORDER BY display_order, created_at`, bizID)
	if err != nil {
		respondErr(w, http.StatusInternalServerError, "query_failed")
		return
	}
	defer rows.Close()

	w.Header().Set("Content-Type", "text/csv; charset=utf-8")
	w.Header().Set("Content-Disposition",
		fmt.Sprintf(`attachment; filename="kpi-widgets-%s.csv"`, time.Now().Format("2006-01-02")))

	cw := csv.NewWriter(w)
	defer cw.Flush()
	_ = cw.Write([]string{"id", "title", "metric_key", "period", "status", "value", "unit"})

	for rows.Next() {
		var id uuid.UUID
		var title, metricKey, period, status string
		var displayOrder int
		if err := rows.Scan(&id, &title, &metricKey, &period, &status, &displayOrder); err != nil {
			continue
		}
		spec, ok := metricRegistry[metricKey]
		if !ok {
			_ = cw.Write([]string{id.String(), title, metricKey, period, status, "", ""})
			continue
		}
		if spec.OwnerOnly && !middleware.IsAtLeast(claims.Role, "manager") {
			continue
		}
		v, err := spec.resolve(r.Context(), h.db, bizID, claims.UserID, period)
		val := ""
		if err == nil {
			val = strconv.FormatFloat(v, 'f', 2, 64)
		}
		_ = cw.Write([]string{id.String(), title, metricKey, period, status, val, spec.Unit})
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditExported,
		EntityType: "kpi_widgets",
		IPAddress:  r.RemoteAddr,
	})
}

// ── Internal helpers ─────────────────────────────────────────────

func (h *Handler) requirePermission(w http.ResponseWriter, r *http.Request, key string) bool {
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
		claims.Role, key, bizID).Scan(&allowed)
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
			EntityType: "kpi_widget",
			NewData:    map[string]interface{}{"required": key, "role": claims.Role},
			IPAddress:  r.RemoteAddr,
		})
		respondErr(w, http.StatusForbidden, "forbidden:"+key)
		return false
	}
	return true
}

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

func jsonOrEmpty(v map[string]interface{}) []byte {
	if v == nil {
		return []byte("{}")
	}
	b, err := json.Marshal(v)
	if err != nil || len(b) == 0 {
		return []byte("{}")
	}
	return b
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
