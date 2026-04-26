package jobs

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
	"github.com/tradie/api/internal/models"
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

// ── List ───────────────────────────────────────────────────────

func (h *Handler) List(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	q := r.URL.Query()
	status := q.Get("status")
	page := 1
	limit := 20

	query := `SELECT id, business_id, job_number, title, description, status, priority,
		customer_id, lat, lng, scheduled_start, scheduled_end, actual_start, actual_end,
		is_recurring, created_by, created_at, updated_at
		FROM jobs WHERE business_id=$1 AND deleted_at IS NULL`
	args := []interface{}{bizID}
	if status != "" {
		query += ` AND status=$2`
		args = append(args, status)
	}
	query += ` ORDER BY scheduled_start DESC NULLS LAST LIMIT $` + fmt.Sprintf("%d", len(args)+1) + ` OFFSET $` + fmt.Sprintf("%d", len(args)+2)
	args = append(args, limit, (page-1)*limit)

	rows, err := h.db.Query(r.Context(), query, args...)
	if err != nil {
		respond(w, 500, map[string]string{"error": "server_error"})
		return
	}
	defer rows.Close()

	var jobs []models.Job
	for rows.Next() {
		var j models.Job
		_ = rows.Scan(&j.ID, &j.BusinessID, &j.JobNumber, &j.Title, &j.Description, &j.Status,
			&j.Priority, &j.CustomerID, &j.Lat, &j.Lng, &j.ScheduledStart, &j.ScheduledEnd,
			&j.ActualStart, &j.ActualEnd, &j.IsRecurring, &j.CreatedBy, &j.CreatedAt, &j.UpdatedAt)
		jobs = append(jobs, j)
	}
	if jobs == nil {
		jobs = []models.Job{}
	}
	respond(w, 200, jobs)
}

// ── Create ─────────────────────────────────────────────────────

func (h *Handler) Create(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())

	var req struct {
		Title          string     `json:"title"`
		Description    string     `json:"description"`
		Priority       string     `json:"priority"`
		CustomerID     *uuid.UUID `json:"customer_id"`
		ScheduledStart *string    `json:"scheduled_start"`
		ScheduledEnd   *string    `json:"scheduled_end"`
		Lat            *float64   `json:"lat"`
		Lng            *float64   `json:"lng"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Title == "" {
		respond(w, 400, map[string]string{"error": "invalid_request"})
		return
	}
	if req.Priority == "" {
		req.Priority = "normal"
	}

	if req.CustomerID != nil && !h.customerInTenant(r, *req.CustomerID, bizID) {
		respond(w, 404, map[string]string{"error": "customer_not_found"})
		return
	}

	var nextNum int
	_ = h.db.QueryRow(r.Context(), `SELECT COUNT(*)+1001 FROM jobs WHERE business_id=$1`, bizID).Scan(&nextNum)
	jobNumber := fmt.Sprintf("JOB-%04d", nextNum)

	var job models.Job
	err := h.db.QueryRow(r.Context(),
		`INSERT INTO jobs (business_id, job_number, title, description, priority, customer_id, scheduled_start, scheduled_end, lat, lng, created_by)
		 VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)
		 RETURNING id, business_id, job_number, title, status, priority, created_at, updated_at`,
		bizID, jobNumber, req.Title, nullStr(req.Description), req.Priority, req.CustomerID,
		req.ScheduledStart, req.ScheduledEnd, req.Lat, req.Lng, claims.UserID,
	).Scan(&job.ID, &job.BusinessID, &job.JobNumber, &job.Title, &job.Status, &job.Priority, &job.CreatedAt, &job.UpdatedAt)
	if err != nil {
		h.log.Error("create job", zap.Error(err))
		respond(w, 500, map[string]string{"error": "server_error"})
		return
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID, UserID: claims.UserID,
		Action: "create", EntityType: "job", EntityID: job.ID,
	})
	respond(w, 201, job)
}

// ── Get ────────────────────────────────────────────────────────

func (h *Handler) Get(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	id := chi.URLParam(r, "id")

	var j models.Job
	err := h.db.QueryRow(r.Context(),
		`SELECT id, business_id, job_number, title, description, status, priority,
		 customer_id, lat, lng, scheduled_start, scheduled_end, actual_start, actual_end, created_at, updated_at
		 FROM jobs WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID,
	).Scan(&j.ID, &j.BusinessID, &j.JobNumber, &j.Title, &j.Description, &j.Status, &j.Priority,
		&j.CustomerID, &j.Lat, &j.Lng, &j.ScheduledStart, &j.ScheduledEnd,
		&j.ActualStart, &j.ActualEnd, &j.CreatedAt, &j.UpdatedAt)
	if err != nil {
		respond(w, 404, map[string]string{"error": "not_found"})
		return
	}
	respond(w, 200, j)
}

// ── Update ─────────────────────────────────────────────────────

func (h *Handler) Update(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	id := chi.URLParam(r, "id")

	var req struct {
		Title          string     `json:"title"`
		Description    string     `json:"description"`
		Priority       string     `json:"priority"`
		CustomerID     *uuid.UUID `json:"customer_id"`
		ScheduledStart *string    `json:"scheduled_start"`
		ScheduledEnd   *string    `json:"scheduled_end"`
		Lat            *float64   `json:"lat"`
		Lng            *float64   `json:"lng"`
		Status         string     `json:"status"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respond(w, 400, map[string]string{"error": "invalid_request"})
		return
	}

	if req.CustomerID != nil && !h.customerInTenant(r, *req.CustomerID, bizID) {
		respond(w, 404, map[string]string{"error": "customer_not_found"})
		return
	}

	var j models.Job
	err := h.db.QueryRow(r.Context(),
		`UPDATE jobs
		    SET title=$1, description=$2, priority=$3, customer_id=$4,
		        scheduled_start=$5, scheduled_end=$6, lat=$7, lng=$8, updated_at=NOW()
		WHERE id=$9 AND business_id=$10 AND deleted_at IS NULL
		RETURNING id, job_number, title, description, status, priority, customer_id, lat, lng, scheduled_start, scheduled_end, updated_at`,
		req.Title, nullStr(req.Description), req.Priority, req.CustomerID,
		req.ScheduledStart, req.ScheduledEnd, req.Lat, req.Lng, id, bizID,
	).Scan(&j.ID, &j.JobNumber, &j.Title, &j.Description, &j.Status, &j.Priority,
		&j.CustomerID, &j.Lat, &j.Lng, &j.ScheduledStart, &j.ScheduledEnd, &j.UpdatedAt)
	if err != nil {
		h.log.Error("update job", zap.Error(err))
		respond(w, 404, map[string]string{"error": "not_found"})
		return
	}
	respond(w, 200, j)
}

// ── Delete ─────────────────────────────────────────────────────

func (h *Handler) Delete(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	id := chi.URLParam(r, "id")
	_, _ = h.db.Exec(r.Context(), `UPDATE jobs SET deleted_at=NOW() WHERE id=$1 AND business_id=$2`, id, bizID)
	respond(w, 204, nil)
}

// ── Assign ─────────────────────────────────────────────────────

func (h *Handler) Assign(w http.ResponseWriter, r *http.Request) {
	var req struct{ WorkerIDs []uuid.UUID `json:"worker_ids"` }
	_ = json.NewDecoder(r.Body).Decode(&req)
	jobID := chi.URLParam(r, "id")
	bizID := middleware.BusinessIDFromCtx(r.Context())

	// Verify the job belongs to this tenant before any inserts.
	if !h.jobInTenant(r, jobID, bizID) {
		respond(w, 404, map[string]string{"error": "job_not_found"})
		return
	}

	for _, wid := range req.WorkerIDs {
		// Skip workers that don't belong to this tenant rather than 404
		// the whole batch — matches the existing ON CONFLICT DO NOTHING
		// "best effort" semantics.
		if !h.workerInTenant(r, wid, bizID) {
			continue
		}
		_, _ = h.db.Exec(r.Context(),
			`INSERT INTO job_assignments (job_id, business_id, worker_id) VALUES ($1,$2,$3) ON CONFLICT (job_id, worker_id) DO NOTHING`,
			jobID, bizID, wid)
	}
	respond(w, 200, map[string]string{"message": "assigned"})
}

// ── UpdateStatus ───────────────────────────────────────────────

func (h *Handler) UpdateStatus(w http.ResponseWriter, r *http.Request) {
	var req struct{ Status string `json:"status"` }
	_ = json.NewDecoder(r.Body).Decode(&req)
	jobID := chi.URLParam(r, "id")
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	jobUUID, _ := uuid.Parse(jobID)

	var oldStatus string
	_ = h.db.QueryRow(r.Context(),
		`SELECT status FROM jobs WHERE id=$1 AND business_id=$2`, jobID, bizID).Scan(&oldStatus)

	_, _ = h.db.Exec(r.Context(),
		`UPDATE jobs SET status=$1, updated_at=NOW() WHERE id=$2 AND business_id=$3`, req.Status, jobID, bizID)

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     "JOB_STATUS_UPDATED",
		EntityType: "job",
		EntityID:   jobUUID,
		OldData:    map[string]interface{}{"status": oldStatus},
		NewData:    map[string]interface{}{"status": req.Status},
	})
	respond(w, 200, map[string]string{"status": req.Status})
}

// ── GetNotes ───────────────────────────────────────────────────
// Schema: job_notes(id, job_id, business_id, created_by, content, is_private, created_at)

func (h *Handler) GetNotes(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	jobID := chi.URLParam(r, "id")

	rows, err := h.db.Query(r.Context(),
		`SELECT n.id, n.job_id, n.content, n.created_by,
		    COALESCE(u.first_name||' '||u.last_name, '') AS author,
		    n.is_private, n.created_at
		FROM job_notes n
		LEFT JOIN users u ON u.id = n.created_by
		WHERE n.job_id=$1 AND n.business_id=$2
		ORDER BY n.created_at DESC`,
		jobID, bizID,
	)
	if err != nil {
		respond(w, 500, map[string]string{"error": "server_error"})
		return
	}
	defer rows.Close()

	var notes []models.JobNote
	for rows.Next() {
		var n models.JobNote
		_ = rows.Scan(&n.ID, &n.JobID, &n.Content, &n.CreatedBy, &n.Author, &n.IsInternal, &n.CreatedAt)
		notes = append(notes, n)
	}
	if notes == nil {
		notes = []models.JobNote{}
	}
	respond(w, 200, notes)
}

// ── AddNote ────────────────────────────────────────────────────

func (h *Handler) AddNote(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	jobID := chi.URLParam(r, "id")

	var req struct {
		Content    string `json:"content"`
		IsInternal bool   `json:"is_internal"` // stored as is_private in DB
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Content == "" {
		respond(w, 400, map[string]string{"error": "content_required"})
		return
	}

	var n models.JobNote
	err := h.db.QueryRow(r.Context(),
		`INSERT INTO job_notes (job_id, business_id, content, created_by, is_private)
		VALUES ($1,$2,$3,$4,$5)
		RETURNING id, content, is_private, created_at`,
		jobID, bizID, req.Content, claims.UserID, req.IsInternal,
	).Scan(&n.ID, &n.Content, &n.IsInternal, &n.CreatedAt)
	if err != nil {
		h.log.Error("add note", zap.Error(err))
		respond(w, 500, map[string]string{"error": "server_error"})
		return
	}
	n.JobID, _ = uuid.Parse(jobID)
	respond(w, 201, n)
}

// ── GetPhotos ──────────────────────────────────────────────────
// Schema: job_photos(id, job_id, business_id, uploaded_by, file_id, type, caption, created_at)
// 'type' maps to phase (before/during/after). No url column — url comes from files table.

func (h *Handler) GetPhotos(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	jobID := chi.URLParam(r, "id")

	rows, err := h.db.Query(r.Context(),
		`SELECT p.id, p.job_id, COALESCE(f.url, '') AS url,
		    p.caption, p.type AS phase, p.uploaded_by, p.created_at
		FROM job_photos p
		LEFT JOIN files f ON f.id = p.file_id
		WHERE p.job_id=$1 AND p.business_id=$2
		ORDER BY p.type, p.created_at`,
		jobID, bizID,
	)
	if err != nil {
		respond(w, 500, map[string]string{"error": "server_error"})
		return
	}
	defer rows.Close()

	grouped := map[string][]models.JobPhoto{
		"before": {},
		"during": {},
		"after":  {},
	}
	for rows.Next() {
		var p models.JobPhoto
		_ = rows.Scan(&p.ID, &p.JobID, &p.URL, &p.Caption, &p.Phase, &p.UploadedBy, &p.CreatedAt)
		if _, ok := grouped[p.Phase]; ok {
			grouped[p.Phase] = append(grouped[p.Phase], p)
		} else {
			grouped["during"] = append(grouped["during"], p)
		}
	}
	respond(w, 200, grouped)
}

// ── UploadPhoto ────────────────────────────────────────────────
// MVP: insert into files (s3_key=url for now) then reference via file_id.

func (h *Handler) UploadPhoto(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	jobID := chi.URLParam(r, "id")

	var req struct {
		URL     string  `json:"url"`
		Caption *string `json:"caption"`
		Phase   string  `json:"phase"` // before/during/after → stored as job_photos.type
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.URL == "" {
		respond(w, 400, map[string]string{"error": "url_required"})
		return
	}
	if req.Phase == "" {
		req.Phase = "during"
	}

	// Create a files record (s3_key = url for MVP; name derived from URL)
	var fileID uuid.UUID
	fileName := req.URL
	if len(fileName) > 100 {
		fileName = fileName[len(fileName)-100:]
	}
	_ = h.db.QueryRow(r.Context(),
		`INSERT INTO files (business_id, uploaded_by, entity_type, entity_id, name, s3_key, url)
		VALUES ($1,$2,'job',$3,$4,$5,$5)
		RETURNING id`,
		bizID, claims.UserID, jobID, fileName, req.URL,
	).Scan(&fileID)

	// Insert job_photos row
	var p models.JobPhoto
	var err error
	if fileID != uuid.Nil {
		err = h.db.QueryRow(r.Context(),
			`INSERT INTO job_photos (job_id, business_id, uploaded_by, file_id, type, caption)
			VALUES ($1,$2,$3,$4,$5,$6)
			RETURNING id, type, caption, created_at`,
			jobID, bizID, claims.UserID, fileID, req.Phase, req.Caption,
		).Scan(&p.ID, &p.Phase, &p.Caption, &p.CreatedAt)
	} else {
		// file insert failed — insert photo row without file reference
		err = h.db.QueryRow(r.Context(),
			`INSERT INTO job_photos (job_id, business_id, uploaded_by, type, caption)
			VALUES ($1,$2,$3,$4,$5)
			RETURNING id, type, caption, created_at`,
			jobID, bizID, claims.UserID, req.Phase, req.Caption,
		).Scan(&p.ID, &p.Phase, &p.Caption, &p.CreatedAt)
	}
	if err != nil {
		h.log.Error("upload photo", zap.Error(err))
		respond(w, 500, map[string]string{"error": "server_error"})
		return
	}
	p.JobID, _ = uuid.Parse(jobID)
	p.URL = req.URL

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     "JOB_PHOTO_UPLOADED",
		EntityType: "job_photo",
		EntityID:   p.ID,
		NewData:    map[string]interface{}{"job_id": jobID, "phase": req.Phase, "file_id": fileID.String()},
	})
	respond(w, 201, p)
}

// ── GetMaterials ───────────────────────────────────────────────
// Schema: job_materials(id, job_id, business_id, name, quantity, unit, unit_cost, total_cost GENERATED, supplier, created_at)

func (h *Handler) GetMaterials(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	jobID := chi.URLParam(r, "id")

	rows, err := h.db.Query(r.Context(),
		`SELECT id, job_id, name, quantity, unit, unit_cost, total_cost, supplier, created_at
		FROM job_materials
		WHERE job_id=$1 AND business_id=$2
		ORDER BY created_at`,
		jobID, bizID,
	)
	if err != nil {
		respond(w, 500, map[string]string{"error": "server_error"})
		return
	}
	defer rows.Close()

	var materials []models.JobMaterial
	for rows.Next() {
		var m models.JobMaterial
		_ = rows.Scan(&m.ID, &m.JobID, &m.Name, &m.Quantity, &m.Unit, &m.UnitCost, &m.TotalCost, &m.Supplier, &m.CreatedAt)
		materials = append(materials, m)
	}
	if materials == nil {
		materials = []models.JobMaterial{}
	}

	var total float64
	_ = h.db.QueryRow(r.Context(),
		`SELECT COALESCE(SUM(total_cost), 0) FROM job_materials WHERE job_id=$1 AND business_id=$2`,
		jobID, bizID,
	).Scan(&total)

	respond(w, 200, map[string]interface{}{
		"materials": materials,
		"total":     total,
	})
}

// ── AddMaterial ────────────────────────────────────────────────
// total_cost is GENERATED ALWAYS — do NOT insert it.

func (h *Handler) AddMaterial(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	jobID := chi.URLParam(r, "id")

	var req struct {
		Name     string  `json:"name"`
		Quantity float64 `json:"quantity"`
		Unit     *string `json:"unit"`
		UnitCost float64 `json:"unit_cost"`
		Supplier *string `json:"supplier"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Name == "" {
		respond(w, 400, map[string]string{"error": "name_required"})
		return
	}
	if req.Quantity == 0 {
		req.Quantity = 1
	}

	var m models.JobMaterial
	err := h.db.QueryRow(r.Context(),
		`INSERT INTO job_materials (job_id, business_id, name, quantity, unit, unit_cost, supplier)
		VALUES ($1,$2,$3,$4,$5,$6,$7)
		RETURNING id, name, quantity, unit, unit_cost, total_cost, created_at`,
		jobID, bizID, req.Name, req.Quantity, req.Unit, req.UnitCost, req.Supplier,
	).Scan(&m.ID, &m.Name, &m.Quantity, &m.Unit, &m.UnitCost, &m.TotalCost, &m.CreatedAt)
	if err != nil {
		h.log.Error("add material", zap.Error(err))
		respond(w, 500, map[string]string{"error": "server_error"})
		return
	}
	m.JobID, _ = uuid.Parse(jobID)
	respond(w, 201, m)
}

// ── Complete ───────────────────────────────────────────────────

func (h *Handler) Complete(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	jobID := chi.URLParam(r, "id")

	var result struct {
		ID        uuid.UUID  `json:"id"`
		Status    string     `json:"status"`
		ActualEnd *time.Time `json:"actual_end"`
	}
	err := h.db.QueryRow(r.Context(),
		`UPDATE jobs
		    SET status='completed', actual_end=NOW(), updated_at=NOW()
		WHERE id=$1 AND business_id=$2 AND status!='completed'
		RETURNING id, status, actual_end`,
		jobID, bizID,
	).Scan(&result.ID, &result.Status, &result.ActualEnd)
	if err != nil {
		respond(w, 404, map[string]string{"error": "not_found_or_already_completed"})
		return
	}

	jobUUID, _ := uuid.Parse(jobID)
	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID, UserID: claims.UserID,
		Action: "complete", EntityType: "job", EntityID: jobUUID,
	})
	respond(w, 200, result)
}

// ── SignOff ────────────────────────────────────────────────────
// Schema: sign-off stored on jobs row (sign_off_by, sign_off_at, sign_off_url).
// No separate job_signoffs table in DB.

func (h *Handler) SignOff(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	jobID := chi.URLParam(r, "id")

	var req struct {
		SignerName       string `json:"signer_name"`
		SignerRole       string `json:"signer_role"`
		SignatureDataURL string `json:"signature_data_url"`
		Notes            string `json:"notes"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.SignerName == "" {
		respond(w, 400, map[string]string{"error": "signer_name_required"})
		return
	}

	// Combine signer_name + role into sign_off_by; store sig URL
	signedBy := req.SignerName
	if req.SignerRole != "" {
		signedBy = req.SignerName + " (" + req.SignerRole + ")"
	}

	var signedAt time.Time
	err := h.db.QueryRow(r.Context(),
		`UPDATE jobs
		    SET sign_off_by=$1, sign_off_at=NOW(), sign_off_url=$2,
		        completion_notes=COALESCE(NULLIF($3,''), completion_notes),
		        updated_at=NOW()
		WHERE id=$4 AND business_id=$5
		RETURNING sign_off_at`,
		signedBy, nullStr(req.SignatureDataURL), req.Notes, jobID, bizID,
	).Scan(&signedAt)
	if err != nil {
		h.log.Error("sign off", zap.Error(err))
		respond(w, 404, map[string]string{"error": "not_found"})
		return
	}

	respond(w, 200, map[string]interface{}{
		"signer_name": req.SignerName,
		"signer_role": req.SignerRole,
		"signed_at":   signedAt,
	})
}

// ── Calendar ───────────────────────────────────────────────────

func (h *Handler) Calendar(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	q := r.URL.Query()
	start := q.Get("start")
	end := q.Get("end")
	if start == "" || end == "" {
		respond(w, 400, map[string]string{"error": "start_and_end_required"})
		return
	}

	rows, err := h.db.Query(r.Context(),
		`SELECT id, job_number, title, status, priority, customer_id,
		    scheduled_start, scheduled_end, lat, lng
		FROM jobs
		WHERE business_id=$1
		  AND scheduled_start IS NOT NULL
		  AND scheduled_start >= $2 AND scheduled_start <= $3
		  AND deleted_at IS NULL
		ORDER BY scheduled_start`,
		bizID, start, end,
	)
	if err != nil {
		respond(w, 500, map[string]string{"error": "server_error"})
		return
	}
	defer rows.Close()

	var jobs []models.Job
	for rows.Next() {
		var j models.Job
		_ = rows.Scan(&j.ID, &j.JobNumber, &j.Title, &j.Status, &j.Priority,
			&j.CustomerID, &j.ScheduledStart, &j.ScheduledEnd, &j.Lat, &j.Lng)
		jobs = append(jobs, j)
	}
	if jobs == nil {
		jobs = []models.Job{}
	}
	respond(w, 200, jobs)
}

// ── ScheduleJob is a richer read model for schedule endpoints ─

type ScheduleJob struct {
	ID             uuid.UUID  `json:"id"`
	JobNumber      string     `json:"job_number"`
	Title          string     `json:"title"`
	Status         string     `json:"status"`
	Priority       string     `json:"priority"`
	ScheduledStart *time.Time `json:"scheduled_start"`
	ScheduledEnd   *time.Time `json:"scheduled_end"`
	SiteAddress    *string    `json:"site_address,omitempty"` // JSONB as text
	CustomerName   string     `json:"customer_name"`
	Workers        []string   `json:"workers"`
}

// ── DailySchedule ──────────────────────────────────────────────

func (h *Handler) DailySchedule(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	date := r.URL.Query().Get("date")
	if date == "" {
		date = time.Now().UTC().Format("2006-01-02")
	}

	rows, err := h.db.Query(r.Context(),
		`SELECT j.id, j.job_number, j.title, j.status, j.priority,
		    j.scheduled_start, j.scheduled_end,
		    j.site_address::text,
		    COALESCE(c.first_name||' '||COALESCE(c.last_name,''), '') AS customer_name,
		    array_agg(u.first_name||' '||u.last_name) FILTER (WHERE u.id IS NOT NULL) AS workers
		FROM jobs j
		LEFT JOIN customers c ON c.id = j.customer_id
		LEFT JOIN job_assignments ja ON ja.job_id = j.id
		LEFT JOIN users u ON u.id = ja.worker_id
		WHERE j.business_id=$1
		  AND DATE(j.scheduled_start AT TIME ZONE 'UTC') = $2::date
		  AND j.deleted_at IS NULL
		GROUP BY j.id, c.first_name, c.last_name
		ORDER BY j.scheduled_start`,
		bizID, date,
	)
	if err != nil {
		respond(w, 500, map[string]string{"error": "server_error"})
		return
	}
	defer rows.Close()

	var jobs []ScheduleJob
	for rows.Next() {
		var j ScheduleJob
		_ = rows.Scan(&j.ID, &j.JobNumber, &j.Title, &j.Status, &j.Priority,
			&j.ScheduledStart, &j.ScheduledEnd, &j.SiteAddress,
			&j.CustomerName, &j.Workers)
		if j.Workers == nil {
			j.Workers = []string{}
		}
		jobs = append(jobs, j)
	}
	if jobs == nil {
		jobs = []ScheduleJob{}
	}
	respond(w, 200, map[string]interface{}{"date": date, "jobs": jobs})
}

// ── WeeklySchedule ─────────────────────────────────────────────

func (h *Handler) WeeklySchedule(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	weekStart := r.URL.Query().Get("week_start")
	if weekStart == "" {
		now := time.Now().UTC()
		offset := int(time.Monday - now.Weekday())
		if offset > 0 {
			offset -= 7
		}
		weekStart = now.AddDate(0, 0, offset).Format("2006-01-02")
	}

	start, err := time.Parse("2006-01-02", weekStart)
	if err != nil {
		respond(w, 400, map[string]string{"error": "invalid_week_start"})
		return
	}
	weekEnd := start.AddDate(0, 0, 6).Format("2006-01-02")

	rows, err := h.db.Query(r.Context(),
		`SELECT j.id, j.job_number, j.title, j.status, j.priority,
		    j.scheduled_start, j.scheduled_end,
		    j.site_address::text,
		    COALESCE(c.first_name||' '||COALESCE(c.last_name,''), '') AS customer_name,
		    array_agg(u.first_name||' '||u.last_name) FILTER (WHERE u.id IS NOT NULL) AS workers
		FROM jobs j
		LEFT JOIN customers c ON c.id = j.customer_id
		LEFT JOIN job_assignments ja ON ja.job_id = j.id
		LEFT JOIN users u ON u.id = ja.worker_id
		WHERE j.business_id=$1
		  AND DATE(j.scheduled_start AT TIME ZONE 'UTC') >= $2::date
		  AND DATE(j.scheduled_start AT TIME ZONE 'UTC') <= $3::date
		  AND j.deleted_at IS NULL
		GROUP BY j.id, c.first_name, c.last_name
		ORDER BY j.scheduled_start`,
		bizID, weekStart, weekEnd,
	)
	if err != nil {
		respond(w, 500, map[string]string{"error": "server_error"})
		return
	}
	defer rows.Close()

	grouped := map[string][]ScheduleJob{}
	for rows.Next() {
		var j ScheduleJob
		_ = rows.Scan(&j.ID, &j.JobNumber, &j.Title, &j.Status, &j.Priority,
			&j.ScheduledStart, &j.ScheduledEnd, &j.SiteAddress,
			&j.CustomerName, &j.Workers)
		if j.Workers == nil {
			j.Workers = []string{}
		}
		day := ""
		if j.ScheduledStart != nil {
			day = j.ScheduledStart.UTC().Format("2006-01-02")
		}
		grouped[day] = append(grouped[day], j)
	}

	respond(w, 200, map[string]interface{}{
		"week_start": weekStart,
		"week_end":   weekEnd,
		"days":       grouped,
	})
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

// ── tenant ownership helpers ───────────────────────────────────
//
// Cheap EXISTS lookups used to verify that an ID supplied via
// request body / URL belongs to the caller's business before any
// INSERT/UPDATE references it. Without these, a caller could
// poison their own joins by referencing another tenant's row.

func (h *Handler) customerInTenant(r *http.Request, customerID, bizID interface{}) bool {
	var ok bool
	_ = h.db.QueryRow(r.Context(),
		`SELECT EXISTS(SELECT 1 FROM customers
		                 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL)`,
		customerID, bizID,
	).Scan(&ok)
	return ok
}

func (h *Handler) jobInTenant(r *http.Request, jobID, bizID interface{}) bool {
	var ok bool
	_ = h.db.QueryRow(r.Context(),
		`SELECT EXISTS(SELECT 1 FROM jobs
		                 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL)`,
		jobID, bizID,
	).Scan(&ok)
	return ok
}

func (h *Handler) workerInTenant(r *http.Request, workerID, bizID interface{}) bool {
	var ok bool
	_ = h.db.QueryRow(r.Context(),
		`SELECT EXISTS(SELECT 1 FROM users
		                 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL)`,
		workerID, bizID,
	).Scan(&ok)
	return ok
}
