package safety

import (
	"encoding/json"
	"fmt"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"go.uber.org/zap"

	"github.com/tradie/api/internal/config"
	"github.com/tradie/api/internal/middleware"
)

type Handler struct {
	cfg   *config.Config
	db    *pgxpool.Pool
	log   *zap.Logger
	audit *middleware.AuditService
}

func NewHandler(cfg *config.Config, db *pgxpool.Pool, log *zap.Logger, audit *middleware.AuditService) *Handler {
	return &Handler{cfg: cfg, db: db, log: log, audit: audit}
}

// ── Helpers ────────────────────────────────────────────────────

func respond(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if data != nil {
		json.NewEncoder(w).Encode(data)
	}
}

func nullStr(s string) interface{} {
	if s == "" {
		return nil
	}
	return s
}

// ══════════════════════════════════════════════════════════════
// CHECKLISTS
// ══════════════════════════════════════════════════════════════

// ListChecklists GET /safety/checklists
// Query params: ?job_id=, ?status=
func (h *Handler) ListChecklists(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	q := r.URL.Query()
	jobID := q.Get("job_id")
	status := q.Get("status")

	query := `
		SELECT id, business_id, job_id, template_id, title, status,
		       items, completed_by, completed_at, signature, created_by, created_at, updated_at
		FROM safety_checklists
		WHERE business_id = $1`
	args := []interface{}{bizID}

	if jobID != "" {
		args = append(args, jobID)
		query += fmt.Sprintf(" AND job_id = $%d", len(args))
	}
	if status != "" {
		args = append(args, status)
		query += fmt.Sprintf(" AND status = $%d", len(args))
	}
	query += " ORDER BY created_at DESC LIMIT 100"

	rows, err := h.db.Query(r.Context(), query, args...)
	if err != nil {
		h.log.Error("list checklists", zap.Error(err))
		respond(w, 500, map[string]string{"error": "server_error"})
		return
	}
	defer rows.Close()

	type checklistRow struct {
		ID          uuid.UUID        `json:"id"`
		BusinessID  uuid.UUID        `json:"business_id"`
		JobID       *uuid.UUID       `json:"job_id"`
		TemplateID  *uuid.UUID       `json:"template_id"`
		Title       string           `json:"title"`
		Status      string           `json:"status"`
		Items       *json.RawMessage `json:"items"`
		CompletedBy *uuid.UUID       `json:"completed_by"`
		CompletedAt *time.Time       `json:"completed_at"`
		Signature   *json.RawMessage `json:"signature"`
		CreatedBy   uuid.UUID        `json:"created_by"`
		CreatedAt   time.Time        `json:"created_at"`
		UpdatedAt   time.Time        `json:"updated_at"`
	}

	var list []checklistRow
	for rows.Next() {
		var c checklistRow
		if err := rows.Scan(
			&c.ID, &c.BusinessID, &c.JobID, &c.TemplateID, &c.Title, &c.Status,
			&c.Items, &c.CompletedBy, &c.CompletedAt, &c.Signature,
			&c.CreatedBy, &c.CreatedAt, &c.UpdatedAt,
		); err != nil {
			continue
		}
		// Compute item count and completion % from JSONB
		list = append(list, c)
	}
	if list == nil {
		list = []checklistRow{}
	}
	respond(w, 200, list)
}

// CreateChecklist POST /safety/checklists
func (h *Handler) CreateChecklist(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())

	var req struct {
		Title      string          `json:"title"`
		TemplateID *uuid.UUID      `json:"template_id"`
		JobID      *uuid.UUID      `json:"job_id"`
		Items      json.RawMessage `json:"items"` // [{description, is_required}]
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Title == "" {
		respond(w, 400, map[string]string{"error": "title_required"})
		return
	}
	if len(req.Items) == 0 {
		req.Items = json.RawMessage(`[]`)
	}

	type result struct {
		ID        uuid.UUID        `json:"id"`
		Title     string           `json:"title"`
		Status    string           `json:"status"`
		Items     *json.RawMessage `json:"items"`
		CreatedAt time.Time        `json:"created_at"`
	}
	var row result
	err := h.db.QueryRow(r.Context(),
		`INSERT INTO safety_checklists
		    (business_id, template_id, job_id, title, items, created_by)
		 VALUES ($1, $2, $3, $4, $5, $6)
		 RETURNING id, title, status, items, created_at`,
		bizID, req.TemplateID, req.JobID, req.Title, req.Items, claims.UserID,
	).Scan(&row.ID, &row.Title, &row.Status, &row.Items, &row.CreatedAt)
	if err != nil {
		h.log.Error("create checklist", zap.Error(err))
		respond(w, 500, map[string]string{"error": "server_error"})
		return
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID, UserID: claims.UserID,
		Action: "create", EntityType: "safety_checklist", EntityID: row.ID,
	})
	respond(w, 201, row)
}

// GetChecklist GET /safety/checklists/{id}
func (h *Handler) GetChecklist(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	id := chi.URLParam(r, "id")

	type result struct {
		ID          uuid.UUID        `json:"id"`
		BusinessID  uuid.UUID        `json:"business_id"`
		JobID       *uuid.UUID       `json:"job_id"`
		TemplateID  *uuid.UUID       `json:"template_id"`
		Title       string           `json:"title"`
		Status      string           `json:"status"`
		Items       *json.RawMessage `json:"items"`
		CompletedBy *uuid.UUID       `json:"completed_by"`
		CompletedAt *time.Time       `json:"completed_at"`
		Signature   *json.RawMessage `json:"signature"`
		CreatedBy   uuid.UUID        `json:"created_by"`
		CreatedAt   time.Time        `json:"created_at"`
		UpdatedAt   time.Time        `json:"updated_at"`
	}
	var c result
	err := h.db.QueryRow(r.Context(),
		`SELECT id, business_id, job_id, template_id, title, status,
		        items, completed_by, completed_at, signature, created_by, created_at, updated_at
		 FROM safety_checklists
		 WHERE id = $1 AND business_id = $2`,
		id, bizID,
	).Scan(
		&c.ID, &c.BusinessID, &c.JobID, &c.TemplateID, &c.Title, &c.Status,
		&c.Items, &c.CompletedBy, &c.CompletedAt, &c.Signature,
		&c.CreatedBy, &c.CreatedAt, &c.UpdatedAt,
	)
	if err != nil {
		respond(w, 404, map[string]string{"error": "not_found"})
		return
	}
	respond(w, 200, c)
}

// CompleteChecklist POST /safety/checklists/{id}/complete
func (h *Handler) CompleteChecklist(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	id := chi.URLParam(r, "id")

	var req struct {
		Signature json.RawMessage `json:"signature"` // {signer_name, data_url, signed_at}
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || len(req.Signature) == 0 {
		respond(w, 400, map[string]string{"error": "signature_required"})
		return
	}

	// Mark all items as checked by updating the items JSONB array,
	// then set status=completed, completed_by, completed_at, signature.
	var result struct {
		ID          uuid.UUID  `json:"id"`
		Status      string     `json:"status"`
		CompletedBy uuid.UUID  `json:"completed_by"`
		CompletedAt time.Time  `json:"completed_at"`
	}
	err := h.db.QueryRow(r.Context(),
		`UPDATE safety_checklists
		 SET status        = 'completed',
		     completed_by  = $1,
		     completed_at  = NOW(),
		     signature     = $2,
		     items         = (
		         SELECT jsonb_agg(item || '{"checked": true}')
		         FROM jsonb_array_elements(items) AS item
		     ),
		     updated_at    = NOW()
		 WHERE id = $3 AND business_id = $4 AND status != 'completed'
		 RETURNING id, status, completed_by, completed_at`,
		claims.UserID, req.Signature, id, bizID,
	).Scan(&result.ID, &result.Status, &result.CompletedBy, &result.CompletedAt)
	if err != nil {
		respond(w, 404, map[string]string{"error": "not_found_or_already_completed"})
		return
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID, UserID: claims.UserID,
		Action: "complete", EntityType: "safety_checklist", EntityID: result.ID,
	})
	respond(w, 200, result)
}

// ══════════════════════════════════════════════════════════════
// SWMS — Safe Work Method Statements
// ══════════════════════════════════════════════════════════════

// ListSWMS GET /safety/swms
func (h *Handler) ListSWMS(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	jobID := r.URL.Query().Get("job_id")

	query := `
		SELECT id, business_id, job_id, title, job_type, high_risk_activities,
		       control_measures, responsible_person, review_date, status, created_by, created_at, updated_at
		FROM swms_documents
		WHERE business_id = $1`
	args := []interface{}{bizID}
	if jobID != "" {
		args = append(args, jobID)
		query += fmt.Sprintf(" AND job_id = $%d", len(args))
	}
	query += " ORDER BY created_at DESC LIMIT 100"

	rows, err := h.db.Query(r.Context(), query, args...)
	if err != nil {
		h.log.Error("list swms", zap.Error(err))
		respond(w, 500, map[string]string{"error": "server_error"})
		return
	}
	defer rows.Close()

	type swmsRow struct {
		ID                  uuid.UUID        `json:"id"`
		BusinessID          uuid.UUID        `json:"business_id"`
		JobID               *uuid.UUID       `json:"job_id"`
		Title               string           `json:"title"`
		JobType             string           `json:"job_type"`
		HighRiskActivities  *json.RawMessage `json:"high_risk_activities"`
		ControlMeasures     *json.RawMessage `json:"control_measures"`
		ResponsiblePerson   string           `json:"responsible_person"`
		ReviewDate          *string          `json:"review_date"`
		Status              string           `json:"status"`
		CreatedBy           uuid.UUID        `json:"created_by"`
		CreatedAt           time.Time        `json:"created_at"`
		UpdatedAt           time.Time        `json:"updated_at"`
	}

	var list []swmsRow
	for rows.Next() {
		var s swmsRow
		if err := rows.Scan(
			&s.ID, &s.BusinessID, &s.JobID, &s.Title, &s.JobType,
			&s.HighRiskActivities, &s.ControlMeasures, &s.ResponsiblePerson,
			&s.ReviewDate, &s.Status, &s.CreatedBy, &s.CreatedAt, &s.UpdatedAt,
		); err != nil {
			continue
		}
		list = append(list, s)
	}
	if list == nil {
		list = []swmsRow{}
	}
	respond(w, 200, list)
}

// CreateSWMS POST /safety/swms
func (h *Handler) CreateSWMS(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())

	var req struct {
		Title               string          `json:"title"`
		JobID               *uuid.UUID      `json:"job_id"`
		JobType             string          `json:"job_type"`
		HighRiskActivities  json.RawMessage `json:"high_risk_activities"`
		ControlMeasures     json.RawMessage `json:"control_measures"`
		ResponsiblePerson   string          `json:"responsible_person"`
		ReviewDate          *string         `json:"review_date"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Title == "" || req.ResponsiblePerson == "" {
		respond(w, 400, map[string]string{"error": "title_and_responsible_person_required"})
		return
	}
	if len(req.HighRiskActivities) == 0 {
		req.HighRiskActivities = json.RawMessage(`[]`)
	}
	if len(req.ControlMeasures) == 0 {
		req.ControlMeasures = json.RawMessage(`[]`)
	}

	type result struct {
		ID                uuid.UUID        `json:"id"`
		Title             string           `json:"title"`
		JobType           string           `json:"job_type"`
		ResponsiblePerson string           `json:"responsible_person"`
		Status            string           `json:"status"`
		CreatedAt         time.Time        `json:"created_at"`
	}
	var row result
	err := h.db.QueryRow(r.Context(),
		`INSERT INTO swms_documents
		    (business_id, job_id, title, job_type, high_risk_activities, control_measures,
		     responsible_person, review_date, created_by)
		 VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
		 RETURNING id, title, job_type, responsible_person, status, created_at`,
		bizID, req.JobID, req.Title, req.JobType, req.HighRiskActivities,
		req.ControlMeasures, req.ResponsiblePerson, req.ReviewDate, claims.UserID,
	).Scan(&row.ID, &row.Title, &row.JobType, &row.ResponsiblePerson, &row.Status, &row.CreatedAt)
	if err != nil {
		h.log.Error("create swms", zap.Error(err))
		respond(w, 500, map[string]string{"error": "server_error"})
		return
	}
	respond(w, 201, row)
}

// GetSWMS GET /safety/swms/{id}
func (h *Handler) GetSWMS(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	id := chi.URLParam(r, "id")

	type result struct {
		ID                 uuid.UUID        `json:"id"`
		BusinessID         uuid.UUID        `json:"business_id"`
		JobID              *uuid.UUID       `json:"job_id"`
		Title              string           `json:"title"`
		JobType            string           `json:"job_type"`
		HighRiskActivities *json.RawMessage `json:"high_risk_activities"`
		ControlMeasures    *json.RawMessage `json:"control_measures"`
		ResponsiblePerson  string           `json:"responsible_person"`
		ReviewDate         *string          `json:"review_date"`
		Status             string           `json:"status"`
		CreatedBy          uuid.UUID        `json:"created_by"`
		CreatedAt          time.Time        `json:"created_at"`
		UpdatedAt          time.Time        `json:"updated_at"`
	}
	var s result
	err := h.db.QueryRow(r.Context(),
		`SELECT id, business_id, job_id, title, job_type, high_risk_activities,
		        control_measures, responsible_person, review_date, status,
		        created_by, created_at, updated_at
		 FROM swms_documents
		 WHERE id = $1 AND business_id = $2`,
		id, bizID,
	).Scan(
		&s.ID, &s.BusinessID, &s.JobID, &s.Title, &s.JobType,
		&s.HighRiskActivities, &s.ControlMeasures, &s.ResponsiblePerson,
		&s.ReviewDate, &s.Status, &s.CreatedBy, &s.CreatedAt, &s.UpdatedAt,
	)
	if err != nil {
		respond(w, 404, map[string]string{"error": "not_found"})
		return
	}
	respond(w, 200, s)
}

// GenerateSWMSPDF GET /safety/swms/{id}/pdf
// Returns structured JSON formatted for client-side PDF rendering.
func (h *Handler) GenerateSWMSPDF(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	id := chi.URLParam(r, "id")

	type swmsDoc struct {
		ID                 uuid.UUID        `json:"id"`
		BusinessID         uuid.UUID        `json:"business_id"`
		JobID              *uuid.UUID       `json:"job_id"`
		Title              string           `json:"title"`
		JobType            string           `json:"job_type"`
		HighRiskActivities *json.RawMessage `json:"high_risk_activities"`
		ControlMeasures    *json.RawMessage `json:"control_measures"`
		ResponsiblePerson  string           `json:"responsible_person"`
		ReviewDate         *string          `json:"review_date"`
		Status             string           `json:"status"`
		CreatedBy          uuid.UUID        `json:"created_by"`
		CreatedAt          time.Time        `json:"created_at"`
	}
	var s swmsDoc
	err := h.db.QueryRow(r.Context(),
		`SELECT id, business_id, job_id, title, job_type, high_risk_activities,
		        control_measures, responsible_person, review_date, status,
		        created_by, created_at
		 FROM swms_documents
		 WHERE id = $1 AND business_id = $2`,
		id, bizID,
	).Scan(
		&s.ID, &s.BusinessID, &s.JobID, &s.Title, &s.JobType,
		&s.HighRiskActivities, &s.ControlMeasures, &s.ResponsiblePerson,
		&s.ReviewDate, &s.Status, &s.CreatedBy, &s.CreatedAt,
	)
	if err != nil {
		respond(w, 404, map[string]string{"error": "not_found"})
		return
	}

	// Structured PDF payload: includes metadata and a section layout
	// that the Flutter PDF renderer can consume directly.
	pdf := map[string]interface{}{
		"document_type": "swms",
		"generated_at":  time.Now().UTC().Format(time.RFC3339),
		"metadata": map[string]interface{}{
			"id":                 s.ID,
			"title":              s.Title,
			"job_type":           s.JobType,
			"responsible_person": s.ResponsiblePerson,
			"review_date":        s.ReviewDate,
			"status":             s.Status,
			"created_at":         s.CreatedAt.Format("02 Jan 2006"),
		},
		"sections": []map[string]interface{}{
			{
				"heading": "High Risk Activities",
				"type":    "list",
				"data":    s.HighRiskActivities,
			},
			{
				"heading": "Control Measures",
				"type":    "table",
				"columns": []string{"hazard", "control", "responsible", "risk_level"},
				"data":    s.ControlMeasures,
			},
		},
		"footer": map[string]interface{}{
			"disclaimer": "This Safe Work Method Statement must be read and signed by all workers before commencing the listed high-risk construction work.",
			"legislation": "Work Health and Safety Act 2011 (Cth)",
		},
	}
	respond(w, 200, pdf)
}

// ══════════════════════════════════════════════════════════════
// INCIDENTS
// ══════════════════════════════════════════════════════════════

// ListIncidents GET /safety/incidents
// Query: ?severity=, ?status=, ?date_from=
func (h *Handler) ListIncidents(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	q := r.URL.Query()
	severity := q.Get("severity")
	status := q.Get("status")
	dateFrom := q.Get("date_from")

	query := `
		SELECT id, business_id, job_id, incident_type, severity, description,
		       location, injured_person, treatment_provided, reported_by, status,
		       investigation_notes, corrective_actions, closed_at, created_at, updated_at
		FROM incident_reports
		WHERE business_id = $1`
	args := []interface{}{bizID}

	if severity != "" {
		args = append(args, severity)
		query += fmt.Sprintf(" AND severity = $%d", len(args))
	}
	if status != "" {
		args = append(args, status)
		query += fmt.Sprintf(" AND status = $%d", len(args))
	}
	if dateFrom != "" {
		args = append(args, dateFrom)
		query += fmt.Sprintf(" AND created_at >= $%d", len(args))
	}
	query += " ORDER BY created_at DESC LIMIT 100"

	rows, err := h.db.Query(r.Context(), query, args...)
	if err != nil {
		h.log.Error("list incidents", zap.Error(err))
		respond(w, 500, map[string]string{"error": "server_error"})
		return
	}
	defer rows.Close()

	type incidentRow struct {
		ID                 uuid.UUID        `json:"id"`
		BusinessID         uuid.UUID        `json:"business_id"`
		JobID              *uuid.UUID       `json:"job_id"`
		IncidentType       string           `json:"incident_type"`
		Severity           string           `json:"severity"`
		Description        string           `json:"description"`
		Location           *string          `json:"location"`
		InjuredPerson      *string          `json:"injured_person"`
		TreatmentProvided  *string          `json:"treatment_provided"`
		ReportedBy         uuid.UUID        `json:"reported_by"`
		Status             string           `json:"status"`
		InvestigationNotes *string          `json:"investigation_notes"`
		CorrectiveActions  *json.RawMessage `json:"corrective_actions"`
		ClosedAt           *time.Time       `json:"closed_at"`
		CreatedAt          time.Time        `json:"created_at"`
		UpdatedAt          time.Time        `json:"updated_at"`
	}

	var list []incidentRow
	for rows.Next() {
		var inc incidentRow
		if err := rows.Scan(
			&inc.ID, &inc.BusinessID, &inc.JobID, &inc.IncidentType, &inc.Severity,
			&inc.Description, &inc.Location, &inc.InjuredPerson, &inc.TreatmentProvided,
			&inc.ReportedBy, &inc.Status, &inc.InvestigationNotes,
			&inc.CorrectiveActions, &inc.ClosedAt, &inc.CreatedAt, &inc.UpdatedAt,
		); err != nil {
			continue
		}
		list = append(list, inc)
	}
	if list == nil {
		list = []incidentRow{}
	}
	respond(w, 200, list)
}

// CreateIncident POST /safety/incidents
func (h *Handler) CreateIncident(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())

	var req struct {
		IncidentType      string     `json:"incident_type"`  // injury|near_miss|property_damage|other
		Severity          string     `json:"severity"`        // low|medium|high|critical
		JobID             *uuid.UUID `json:"job_id"`
		Description       string     `json:"description"`
		Location          string     `json:"location"`
		InjuredPerson     string     `json:"injured_person"`
		TreatmentProvided string     `json:"treatment_provided"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil ||
		req.IncidentType == "" || req.Severity == "" || req.Description == "" {
		respond(w, 400, map[string]string{"error": "incident_type_severity_description_required"})
		return
	}

	validTypes := map[string]bool{"injury": true, "near_miss": true, "property_damage": true, "other": true}
	validSev := map[string]bool{"low": true, "medium": true, "high": true, "critical": true}
	if !validTypes[req.IncidentType] || !validSev[req.Severity] {
		respond(w, 400, map[string]string{"error": "invalid_incident_type_or_severity"})
		return
	}

	type result struct {
		ID           uuid.UUID `json:"id"`
		IncidentType string    `json:"incident_type"`
		Severity     string    `json:"severity"`
		Status       string    `json:"status"`
		ReportedBy   uuid.UUID `json:"reported_by"`
		CreatedAt    time.Time `json:"created_at"`
	}
	var row result
	err := h.db.QueryRow(r.Context(),
		`INSERT INTO incident_reports
		    (business_id, job_id, incident_type, severity, description, location,
		     injured_person, treatment_provided, reported_by)
		 VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
		 RETURNING id, incident_type, severity, status, reported_by, created_at`,
		bizID, req.JobID, req.IncidentType, req.Severity, req.Description,
		nullStr(req.Location), nullStr(req.InjuredPerson), nullStr(req.TreatmentProvided),
		claims.UserID,
	).Scan(&row.ID, &row.IncidentType, &row.Severity, &row.Status, &row.ReportedBy, &row.CreatedAt)
	if err != nil {
		h.log.Error("create incident", zap.Error(err))
		respond(w, 500, map[string]string{"error": "server_error"})
		return
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID, UserID: claims.UserID,
		Action: "create", EntityType: "incident_report", EntityID: row.ID,
		NewData: map[string]string{"severity": req.Severity, "type": req.IncidentType},
	})
	respond(w, 201, row)
}

// GetIncident GET /safety/incidents/{id}
func (h *Handler) GetIncident(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	id := chi.URLParam(r, "id")

	type result struct {
		ID                 uuid.UUID        `json:"id"`
		BusinessID         uuid.UUID        `json:"business_id"`
		JobID              *uuid.UUID       `json:"job_id"`
		IncidentType       string           `json:"incident_type"`
		Severity           string           `json:"severity"`
		Description        string           `json:"description"`
		Location           *string          `json:"location"`
		InjuredPerson      *string          `json:"injured_person"`
		TreatmentProvided  *string          `json:"treatment_provided"`
		ReportedBy         uuid.UUID        `json:"reported_by"`
		Status             string           `json:"status"`
		InvestigationNotes *string          `json:"investigation_notes"`
		CorrectiveActions  *json.RawMessage `json:"corrective_actions"`
		ClosedAt           *time.Time       `json:"closed_at"`
		CreatedAt          time.Time        `json:"created_at"`
		UpdatedAt          time.Time        `json:"updated_at"`
	}
	var inc result
	err := h.db.QueryRow(r.Context(),
		`SELECT id, business_id, job_id, incident_type, severity, description,
		        location, injured_person, treatment_provided, reported_by, status,
		        investigation_notes, corrective_actions, closed_at, created_at, updated_at
		 FROM incident_reports
		 WHERE id = $1 AND business_id = $2`,
		id, bizID,
	).Scan(
		&inc.ID, &inc.BusinessID, &inc.JobID, &inc.IncidentType, &inc.Severity,
		&inc.Description, &inc.Location, &inc.InjuredPerson, &inc.TreatmentProvided,
		&inc.ReportedBy, &inc.Status, &inc.InvestigationNotes,
		&inc.CorrectiveActions, &inc.ClosedAt, &inc.CreatedAt, &inc.UpdatedAt,
	)
	if err != nil {
		respond(w, 404, map[string]string{"error": "not_found"})
		return
	}
	respond(w, 200, inc)
}

// UpdateIncident PATCH /safety/incidents/{id}
func (h *Handler) UpdateIncident(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	id := chi.URLParam(r, "id")

	var req struct {
		Status             string          `json:"status"`              // open|investigating|closed
		InvestigationNotes string          `json:"investigation_notes"`
		CorrectiveActions  json.RawMessage `json:"corrective_actions"`  // [{action, owner, due_date, completed}]
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respond(w, 400, map[string]string{"error": "invalid_request"})
		return
	}

	validStatus := map[string]bool{"open": true, "investigating": true, "closed": true}
	if req.Status != "" && !validStatus[req.Status] {
		respond(w, 400, map[string]string{"error": "invalid_status"})
		return
	}

	// Build dynamic SET clause: only update provided fields.
	setClauses := []string{"updated_at = NOW()"}
	args := []interface{}{}
	argIdx := 1

	if req.Status != "" {
		setClauses = append(setClauses, fmt.Sprintf("status = $%d", argIdx))
		args = append(args, req.Status)
		argIdx++
		if req.Status == "closed" {
			setClauses = append(setClauses, "closed_at = NOW()")
		}
	}
	if req.InvestigationNotes != "" {
		setClauses = append(setClauses, fmt.Sprintf("investigation_notes = $%d", argIdx))
		args = append(args, req.InvestigationNotes)
		argIdx++
	}
	if len(req.CorrectiveActions) > 0 {
		setClauses = append(setClauses, fmt.Sprintf("corrective_actions = $%d", argIdx))
		args = append(args, req.CorrectiveActions)
		argIdx++
	}

	args = append(args, id, bizID)
	setSQL := ""
	for i, c := range setClauses {
		if i > 0 {
			setSQL += ", "
		}
		setSQL += c
	}

	type result struct {
		ID        uuid.UUID  `json:"id"`
		Status    string     `json:"status"`
		ClosedAt  *time.Time `json:"closed_at"`
		UpdatedAt time.Time  `json:"updated_at"`
	}
	var row result
	err := h.db.QueryRow(r.Context(),
		fmt.Sprintf(`UPDATE incident_reports
		 SET %s
		 WHERE id = $%d AND business_id = $%d
		 RETURNING id, status, closed_at, updated_at`, setSQL, argIdx, argIdx+1),
		args...,
	).Scan(&row.ID, &row.Status, &row.ClosedAt, &row.UpdatedAt)
	if err != nil {
		h.log.Error("update incident", zap.Error(err))
		respond(w, 404, map[string]string{"error": "not_found"})
		return
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID, UserID: claims.UserID,
		Action: "update", EntityType: "incident_report", EntityID: row.ID,
		NewData: map[string]string{"status": row.Status},
	})
	respond(w, 200, row)
}

// ══════════════════════════════════════════════════════════════
// RISK ASSESSMENTS
// ══════════════════════════════════════════════════════════════

// ListRiskAssessments GET /safety/risk-assessments
func (h *Handler) ListRiskAssessments(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	jobID := r.URL.Query().Get("job_id")

	query := `
		SELECT id, business_id, job_id, title, hazards, residual_risk_level,
		       created_by, created_at, updated_at
		FROM risk_assessments
		WHERE business_id = $1`
	args := []interface{}{bizID}
	if jobID != "" {
		args = append(args, jobID)
		query += fmt.Sprintf(" AND job_id = $%d", len(args))
	}
	query += " ORDER BY created_at DESC LIMIT 100"

	rows, err := h.db.Query(r.Context(), query, args...)
	if err != nil {
		h.log.Error("list risk assessments", zap.Error(err))
		respond(w, 500, map[string]string{"error": "server_error"})
		return
	}
	defer rows.Close()

	type raRow struct {
		ID               uuid.UUID        `json:"id"`
		BusinessID       uuid.UUID        `json:"business_id"`
		JobID            *uuid.UUID       `json:"job_id"`
		Title            string           `json:"title"`
		Hazards          *json.RawMessage `json:"hazards"`
		ResidualRiskLevel string          `json:"residual_risk_level"`
		CreatedBy        uuid.UUID        `json:"created_by"`
		CreatedAt        time.Time        `json:"created_at"`
		UpdatedAt        time.Time        `json:"updated_at"`
	}

	var list []raRow
	for rows.Next() {
		var ra raRow
		if err := rows.Scan(
			&ra.ID, &ra.BusinessID, &ra.JobID, &ra.Title, &ra.Hazards,
			&ra.ResidualRiskLevel, &ra.CreatedBy, &ra.CreatedAt, &ra.UpdatedAt,
		); err != nil {
			continue
		}
		list = append(list, ra)
	}
	if list == nil {
		list = []raRow{}
	}
	respond(w, 200, list)
}

// CreateRiskAssessment POST /safety/risk-assessments
func (h *Handler) CreateRiskAssessment(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())

	var req struct {
		Title             string          `json:"title"`
		JobID             *uuid.UUID      `json:"job_id"`
		Hazards           json.RawMessage `json:"hazards"` // [{description, likelihood:1-5, consequence:1-5, risk_score, controls}]
		ResidualRiskLevel string          `json:"residual_risk_level"` // low|medium|high
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Title == "" {
		respond(w, 400, map[string]string{"error": "title_required"})
		return
	}
	validRisk := map[string]bool{"low": true, "medium": true, "high": true}
	if req.ResidualRiskLevel != "" && !validRisk[req.ResidualRiskLevel] {
		respond(w, 400, map[string]string{"error": "invalid_residual_risk_level"})
		return
	}
	if len(req.Hazards) == 0 {
		req.Hazards = json.RawMessage(`[]`)
	}
	if req.ResidualRiskLevel == "" {
		req.ResidualRiskLevel = "medium"
	}

	type result struct {
		ID               uuid.UUID        `json:"id"`
		Title            string           `json:"title"`
		Hazards          *json.RawMessage `json:"hazards"`
		ResidualRiskLevel string          `json:"residual_risk_level"`
		CreatedAt        time.Time        `json:"created_at"`
	}
	var row result
	err := h.db.QueryRow(r.Context(),
		`INSERT INTO risk_assessments
		    (business_id, job_id, title, hazards, residual_risk_level, created_by)
		 VALUES ($1, $2, $3, $4, $5, $6)
		 RETURNING id, title, hazards, residual_risk_level, created_at`,
		bizID, req.JobID, req.Title, req.Hazards, req.ResidualRiskLevel, claims.UserID,
	).Scan(&row.ID, &row.Title, &row.Hazards, &row.ResidualRiskLevel, &row.CreatedAt)
	if err != nil {
		h.log.Error("create risk assessment", zap.Error(err))
		respond(w, 500, map[string]string{"error": "server_error"})
		return
	}
	respond(w, 201, row)
}

// ══════════════════════════════════════════════════════════════
// COMPLIANCE RECORDS
// ══════════════════════════════════════════════════════════════

// ListCompliance GET /safety/compliance
// Query: ?expiring_soon=true (within 30 days)
func (h *Handler) ListCompliance(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	expiringSoon := r.URL.Query().Get("expiring_soon") == "true"

	query := `
		SELECT id, business_id, type, name, holder_name, reference_number,
		       issue_date, expiry_date, reminder_days_before, status, created_at, updated_at
		FROM compliance_records
		WHERE business_id = $1 AND deleted_at IS NULL`
	args := []interface{}{bizID}

	if expiringSoon {
		args = append(args, 30)
		query += fmt.Sprintf(` AND expiry_date <= NOW() + ($%d || ' days')::interval`, len(args))
	}
	query += " ORDER BY expiry_date ASC LIMIT 100"

	rows, err := h.db.Query(r.Context(), query, args...)
	if err != nil {
		h.log.Error("list compliance", zap.Error(err))
		respond(w, 500, map[string]string{"error": "server_error"})
		return
	}
	defer rows.Close()

	type complianceRow struct {
		ID                uuid.UUID  `json:"id"`
		BusinessID        uuid.UUID  `json:"business_id"`
		Type              string     `json:"type"`
		Name              string     `json:"name"`
		HolderName        string     `json:"holder_name"`
		ReferenceNumber   *string    `json:"reference_number"`
		IssueDate         *string    `json:"issue_date"`
		ExpiryDate        string     `json:"expiry_date"`
		ReminderDaysBefore int       `json:"reminder_days_before"`
		Status            string     `json:"status"`
		CreatedAt         time.Time  `json:"created_at"`
		UpdatedAt         time.Time  `json:"updated_at"`
	}

	var list []complianceRow
	for rows.Next() {
		var c complianceRow
		if err := rows.Scan(
			&c.ID, &c.BusinessID, &c.Type, &c.Name, &c.HolderName,
			&c.ReferenceNumber, &c.IssueDate, &c.ExpiryDate,
			&c.ReminderDaysBefore, &c.Status, &c.CreatedAt, &c.UpdatedAt,
		); err != nil {
			continue
		}
		list = append(list, c)
	}
	if list == nil {
		list = []complianceRow{}
	}
	respond(w, 200, list)
}

// AddCompliance POST /safety/compliance
func (h *Handler) AddCompliance(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())

	var req struct {
		Type               string  `json:"type"`              // license|certification|insurance|registration
		Name               string  `json:"name"`
		HolderName         string  `json:"holder_name"`
		ReferenceNumber    string  `json:"reference_number"`
		IssueDate          string  `json:"issue_date"`        // YYYY-MM-DD or ""
		ExpiryDate         string  `json:"expiry_date"`       // YYYY-MM-DD required
		ReminderDaysBefore int     `json:"reminder_days_before"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil ||
		req.Name == "" || req.HolderName == "" || req.ExpiryDate == "" {
		respond(w, 400, map[string]string{"error": "name_holder_name_expiry_date_required"})
		return
	}
	validTypes := map[string]bool{"license": true, "certification": true, "insurance": true, "registration": true}
	if !validTypes[req.Type] {
		respond(w, 400, map[string]string{"error": "invalid_type"})
		return
	}
	if req.ReminderDaysBefore == 0 {
		req.ReminderDaysBefore = 30
	}

	type result struct {
		ID         uuid.UUID `json:"id"`
		Type       string    `json:"type"`
		Name       string    `json:"name"`
		HolderName string    `json:"holder_name"`
		ExpiryDate string    `json:"expiry_date"`
		Status     string    `json:"status"`
		CreatedAt  time.Time `json:"created_at"`
	}
	var row result
	err := h.db.QueryRow(r.Context(),
		`INSERT INTO compliance_records
		    (business_id, type, name, holder_name, reference_number,
		     issue_date, expiry_date, reminder_days_before)
		 VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
		 RETURNING id, type, name, holder_name, expiry_date, status, created_at`,
		bizID, req.Type, req.Name, req.HolderName,
		nullStr(req.ReferenceNumber), nullStr(req.IssueDate), req.ExpiryDate,
		req.ReminderDaysBefore,
	).Scan(&row.ID, &row.Type, &row.Name, &row.HolderName, &row.ExpiryDate, &row.Status, &row.CreatedAt)
	if err != nil {
		h.log.Error("add compliance", zap.Error(err))
		respond(w, 500, map[string]string{"error": "server_error"})
		return
	}
	respond(w, 201, row)
}

// UpdateCompliance PATCH /safety/compliance/{id}
func (h *Handler) UpdateCompliance(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	id := chi.URLParam(r, "id")

	var req struct {
		Name               string `json:"name"`
		HolderName         string `json:"holder_name"`
		ReferenceNumber    string `json:"reference_number"`
		IssueDate          string `json:"issue_date"`
		ExpiryDate         string `json:"expiry_date"`
		ReminderDaysBefore int    `json:"reminder_days_before"`
		Status             string `json:"status"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respond(w, 400, map[string]string{"error": "invalid_request"})
		return
	}

	setClauses := []string{"updated_at = NOW()"}
	args := []interface{}{}
	argIdx := 1

	if req.Name != "" {
		setClauses = append(setClauses, fmt.Sprintf("name = $%d", argIdx))
		args = append(args, req.Name)
		argIdx++
	}
	if req.HolderName != "" {
		setClauses = append(setClauses, fmt.Sprintf("holder_name = $%d", argIdx))
		args = append(args, req.HolderName)
		argIdx++
	}
	if req.ReferenceNumber != "" {
		setClauses = append(setClauses, fmt.Sprintf("reference_number = $%d", argIdx))
		args = append(args, req.ReferenceNumber)
		argIdx++
	}
	if req.IssueDate != "" {
		setClauses = append(setClauses, fmt.Sprintf("issue_date = $%d", argIdx))
		args = append(args, req.IssueDate)
		argIdx++
	}
	if req.ExpiryDate != "" {
		setClauses = append(setClauses, fmt.Sprintf("expiry_date = $%d", argIdx))
		args = append(args, req.ExpiryDate)
		argIdx++
	}
	if req.ReminderDaysBefore > 0 {
		setClauses = append(setClauses, fmt.Sprintf("reminder_days_before = $%d", argIdx))
		args = append(args, req.ReminderDaysBefore)
		argIdx++
	}
	if req.Status != "" {
		setClauses = append(setClauses, fmt.Sprintf("status = $%d", argIdx))
		args = append(args, req.Status)
		argIdx++
	}

	args = append(args, id, bizID)
	setSQL := ""
	for i, c := range setClauses {
		if i > 0 {
			setSQL += ", "
		}
		setSQL += c
	}

	type result struct {
		ID         uuid.UUID `json:"id"`
		Name       string    `json:"name"`
		Status     string    `json:"status"`
		ExpiryDate string    `json:"expiry_date"`
		UpdatedAt  time.Time `json:"updated_at"`
	}
	var row result
	err := h.db.QueryRow(r.Context(),
		fmt.Sprintf(`UPDATE compliance_records
		 SET %s
		 WHERE id = $%d AND business_id = $%d AND deleted_at IS NULL
		 RETURNING id, name, status, expiry_date, updated_at`, setSQL, argIdx, argIdx+1),
		args...,
	).Scan(&row.ID, &row.Name, &row.Status, &row.ExpiryDate, &row.UpdatedAt)
	if err != nil {
		h.log.Error("update compliance", zap.Error(err))
		respond(w, 404, map[string]string{"error": "not_found"})
		return
	}
	respond(w, 200, row)
}

// DeleteCompliance DELETE /safety/compliance/{id} — soft delete
func (h *Handler) DeleteCompliance(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	id := chi.URLParam(r, "id")
	_, _ = h.db.Exec(r.Context(),
		`UPDATE compliance_records SET deleted_at = NOW() WHERE id = $1 AND business_id = $2`,
		id, bizID)
	respond(w, 204, nil)
}

// ══════════════════════════════════════════════════════════════
// PPE CHECKLISTS
// ══════════════════════════════════════════════════════════════

// defaultPPEItems is the standard Australian tradie PPE template.
var defaultPPEItems = json.RawMessage(`[
  {"item":"Hard hat / safety helmet","checked":false,"required":true},
  {"item":"Safety boots (steel-capped)","checked":false,"required":true},
  {"item":"High-visibility vest","checked":false,"required":true},
  {"item":"Safety glasses / goggles","checked":false,"required":true},
  {"item":"Gloves (appropriate for task)","checked":false,"required":true},
  {"item":"Hearing protection (if required)","checked":false,"required":false},
  {"item":"Dust mask / respirator (if required)","checked":false,"required":false},
  {"item":"Safety harness (if working at height)","checked":false,"required":false},
  {"item":"Sun protection (hat, sunscreen)","checked":false,"required":false},
  {"item":"First aid kit present on site","checked":false,"required":true}
]`)

// GetPPEChecklist GET /safety/ppe
// Returns the business PPE template, creating a default one if none exists.
func (h *Handler) GetPPEChecklist(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())

	type result struct {
		ID         uuid.UUID        `json:"id"`
		BusinessID uuid.UUID        `json:"business_id"`
		WorkerID   uuid.UUID        `json:"worker_id"`
		JobID      *uuid.UUID       `json:"job_id"`
		Items      *json.RawMessage `json:"items"`
		AllClear   bool             `json:"all_clear"`
		Notes      *string          `json:"notes"`
		SubmittedAt time.Time       `json:"submitted_at"`
	}

	// Try to fetch the most recent PPE submission as the business template.
	var row result
	err := h.db.QueryRow(r.Context(),
		`SELECT id, business_id, worker_id, job_id, items, all_clear, notes, submitted_at
		 FROM ppe_submissions
		 WHERE business_id = $1
		 ORDER BY submitted_at DESC
		 LIMIT 1`,
		bizID,
	).Scan(&row.ID, &row.BusinessID, &row.WorkerID, &row.JobID,
		&row.Items, &row.AllClear, &row.Notes, &row.SubmittedAt)

	if err != nil {
		// No PPE record yet — create and return the default template.
		var defaultRow result
		insErr := h.db.QueryRow(r.Context(),
			`INSERT INTO ppe_submissions (business_id, worker_id, items, all_clear)
			 VALUES ($1, $2, $3, false)
			 RETURNING id, business_id, worker_id, job_id, items, all_clear, notes, submitted_at`,
			bizID, claims.UserID, defaultPPEItems,
		).Scan(&defaultRow.ID, &defaultRow.BusinessID, &defaultRow.WorkerID, &defaultRow.JobID,
			&defaultRow.Items, &defaultRow.AllClear, &defaultRow.Notes, &defaultRow.SubmittedAt)
		if insErr != nil {
			h.log.Error("create default ppe checklist", zap.Error(insErr))
			respond(w, 500, map[string]string{"error": "server_error"})
			return
		}
		respond(w, 200, map[string]interface{}{
			"template": defaultRow,
			"is_default": true,
		})
		return
	}

	respond(w, 200, map[string]interface{}{
		"template":   row,
		"is_default": false,
	})
}

// SubmitPPEChecklist POST /safety/ppe/submit
func (h *Handler) SubmitPPEChecklist(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())

	var req struct {
		WorkerID uuid.UUID       `json:"worker_id"`
		JobID    *uuid.UUID      `json:"job_id"`
		Items    json.RawMessage `json:"items"`   // [{item: string, checked: bool}]
		AllClear bool            `json:"all_clear"`
		Notes    string          `json:"notes"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.WorkerID == uuid.Nil {
		respond(w, 400, map[string]string{"error": "worker_id_required"})
		return
	}
	if len(req.Items) == 0 {
		req.Items = defaultPPEItems
	}

	type result struct {
		ID          uuid.UUID        `json:"id"`
		BusinessID  uuid.UUID        `json:"business_id"`
		WorkerID    uuid.UUID        `json:"worker_id"`
		JobID       *uuid.UUID       `json:"job_id"`
		Items       *json.RawMessage `json:"items"`
		AllClear    bool             `json:"all_clear"`
		Notes       *string          `json:"notes"`
		SubmittedAt time.Time        `json:"submitted_at"`
	}
	var row result
	err := h.db.QueryRow(r.Context(),
		`INSERT INTO ppe_submissions
		    (business_id, worker_id, job_id, items, all_clear, notes)
		 VALUES ($1, $2, $3, $4, $5, $6)
		 RETURNING id, business_id, worker_id, job_id, items, all_clear, notes, submitted_at`,
		bizID, req.WorkerID, req.JobID, req.Items, req.AllClear, nullStr(req.Notes),
	).Scan(
		&row.ID, &row.BusinessID, &row.WorkerID, &row.JobID,
		&row.Items, &row.AllClear, &row.Notes, &row.SubmittedAt,
	)
	if err != nil {
		h.log.Error("submit ppe checklist", zap.Error(err))
		respond(w, 500, map[string]string{"error": "server_error"})
		return
	}
	respond(w, 201, row)
}
