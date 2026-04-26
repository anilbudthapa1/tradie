package bulk_import

import (
	"context"
	"encoding/csv"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"go.uber.org/zap"

	"github.com/tradie/api/internal/config"
	"github.com/tradie/api/internal/middleware"
)

const maxUploadSize = 10 << 20 // 10 MB CSV cap
const maxRows = 5000

type Handler struct {
	cfg   *config.Config
	db    *pgxpool.Pool
	log   *zap.Logger
	audit *middleware.AuditService
}

func NewHandler(cfg *config.Config, db *pgxpool.Pool, log *zap.Logger, audit *middleware.AuditService) *Handler {
	return &Handler{cfg: cfg, db: db, log: log, audit: audit}
}

// allowedHeaders maps each entity to the columns we accept (header check).
var allowedHeaders = map[string]map[string]bool{
	"customers": {
		"first_name": true, "last_name": true, "company_name": true,
		"email": true, "phone": true, "mobile": true, "notes": true,
	},
	"jobs": {
		"job_number": true, "title": true, "description": true,
		"status": true, "priority": true, "customer_email": true,
	},
	"expenses": {
		"category": true, "description": true, "amount": true,
		"supplier": true, "date": true,
	},
}

// ── Endpoints ─────────────────────────────────────────────────────

// Create — POST /api/v1/bulk-import (multipart: file, entity_type)
func (h *Handler) Create(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())

	if err := r.ParseMultipartForm(maxUploadSize); err != nil {
		respondErr(w, http.StatusBadRequest, "file_too_large_or_invalid")
		return
	}

	entityType := strings.ToLower(strings.TrimSpace(r.FormValue("entity_type")))
	allow, ok := allowedHeaders[entityType]
	if !ok {
		respondErr(w, http.StatusBadRequest, "invalid_entity_type")
		return
	}

	file, header, err := r.FormFile("file")
	if err != nil {
		respondErr(w, http.StatusBadRequest, "file_field_required")
		return
	}
	defer file.Close()

	if header.Size > maxUploadSize {
		respondErr(w, http.StatusRequestEntityTooLarge, "file_too_large")
		return
	}

	// Read CSV fully into memory (capped at 10 MB by ParseMultipartForm)
	csvR := csv.NewReader(file)
	csvR.FieldsPerRecord = -1
	headers, err := csvR.Read()
	if err != nil {
		respondErr(w, http.StatusBadRequest, "csv_header_missing")
		return
	}

	// Validate headers strictly
	normHeaders := make([]string, len(headers))
	for i, h := range headers {
		normHeaders[i] = strings.ToLower(strings.TrimSpace(h))
		if !allow[normHeaders[i]] {
			respondErr(w, http.StatusBadRequest, fmt.Sprintf("unknown_column:%s", normHeaders[i]))
			return
		}
	}

	rows, err := csvR.ReadAll()
	if err != nil {
		respondErr(w, http.StatusBadRequest, "csv_parse_error")
		return
	}
	if len(rows) > maxRows {
		respondErr(w, http.StatusBadRequest, "too_many_rows")
		return
	}

	jobID := uuid.New()
	_, err = h.db.Exec(r.Context(),
		`INSERT INTO bulk_import_jobs
		 (id, business_id, entity_type, file_name, status, total_rows, created_by)
		 VALUES ($1,$2,$3,$4,'pending',$5,$6)`,
		jobID, bizID, entityType, header.Filename, len(rows), claims.UserID,
	)
	if err != nil {
		h.log.Error("bulk_import insert", zap.Error(err))
		respondErr(w, http.StatusInternalServerError, "create_failed")
		return
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     "BULK_IMPORT_CREATED",
		EntityType: "bulk_import_job",
		EntityID:   jobID,
		NewData:    map[string]interface{}{"entity_type": entityType, "rows": len(rows)},
		IPAddress:  r.RemoteAddr,
	})

	// Kick off async processing (goroutine — needs-scheduler in production)
	go h.process(jobID, bizID, claims.UserID, entityType, normHeaders, rows)

	respondJSON(w, http.StatusAccepted, map[string]interface{}{
		"id":         jobID,
		"status":     "pending",
		"total_rows": len(rows),
	})
}

// Get — GET /api/v1/bulk-import/{id}
func (h *Handler) Get(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	idStr := chi.URLParam(r, "id")
	id, err := uuid.Parse(idStr)
	if err != nil {
		respondErr(w, http.StatusBadRequest, "invalid_id")
		return
	}

	var (
		entityType   string
		fileName     string
		status       string
		totalRows    int
		processedRow int
		successRows  int
		errorLog     []byte
		createdAt    time.Time
		completedAt  *time.Time
	)
	err = h.db.QueryRow(r.Context(),
		`SELECT entity_type, COALESCE(file_name,''), status,
		        total_rows, processed_rows, success_rows,
		        error_log, created_at, completed_at
		 FROM bulk_import_jobs
		 WHERE id=$1 AND business_id=$2`,
		id, bizID,
	).Scan(&entityType, &fileName, &status, &totalRows, &processedRow, &successRows, &errorLog, &createdAt, &completedAt)
	if err != nil {
		respondErr(w, http.StatusNotFound, "not_found")
		return
	}

	var errs []map[string]interface{}
	_ = json.Unmarshal(errorLog, &errs)

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"id":             id,
		"entity_type":    entityType,
		"file_name":      fileName,
		"status":         status,
		"total_rows":     totalRows,
		"processed_rows": processedRow,
		"success_rows":   successRows,
		"errors":         errs,
		"created_at":     createdAt,
		"completed_at":   completedAt,
	})
}

// List — GET /api/v1/bulk-import
func (h *Handler) List(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	rows, err := h.db.Query(r.Context(),
		`SELECT id, entity_type, COALESCE(file_name,''), status,
		        total_rows, processed_rows, success_rows, created_at, completed_at
		 FROM bulk_import_jobs
		 WHERE business_id=$1
		 ORDER BY created_at DESC LIMIT 50`,
		bizID,
	)
	if err != nil {
		respondErr(w, http.StatusInternalServerError, "query_failed")
		return
	}
	defer rows.Close()

	out := []map[string]interface{}{}
	for rows.Next() {
		var (
			id          uuid.UUID
			entityType  string
			fileName    string
			status      string
			total       int
			processed   int
			success     int
			createdAt   time.Time
			completedAt *time.Time
		)
		if err := rows.Scan(&id, &entityType, &fileName, &status, &total, &processed, &success, &createdAt, &completedAt); err != nil {
			continue
		}
		out = append(out, map[string]interface{}{
			"id":             id,
			"entity_type":    entityType,
			"file_name":      fileName,
			"status":         status,
			"total_rows":     total,
			"processed_rows": processed,
			"success_rows":   success,
			"created_at":     createdAt,
			"completed_at":   completedAt,
		})
	}
	respondJSON(w, http.StatusOK, map[string]interface{}{"jobs": out, "total": len(out)})
}

// ── Async processing ──────────────────────────────────────────────

func (h *Handler) process(jobID, bizID, userID uuid.UUID, entityType string, headers []string, rows [][]string) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()

	_, _ = h.db.Exec(ctx, `UPDATE bulk_import_jobs SET status='processing' WHERE id=$1`, jobID)

	type rowErr struct {
		Row     int    `json:"row"`
		Message string `json:"message"`
	}
	errs := []rowErr{}
	successCount := 0

	for i, raw := range rows {
		rowNum := i + 2 // +1 for header, +1 for 1-indexed
		rec := map[string]string{}
		for j, h := range headers {
			if j < len(raw) {
				rec[h] = strings.TrimSpace(raw[j])
			}
		}

		var entityID uuid.UUID
		var perr error
		switch entityType {
		case "customers":
			entityID, perr = h.insertCustomer(ctx, bizID, rec)
		case "jobs":
			entityID, perr = h.insertJob(ctx, bizID, userID, rec)
		case "expenses":
			entityID, perr = h.insertExpense(ctx, bizID, userID, rec)
		default:
			perr = fmt.Errorf("unsupported entity")
		}

		if perr != nil {
			errs = append(errs, rowErr{Row: rowNum, Message: perr.Error()})
		} else {
			successCount++
			h.audit.Log(ctx, middleware.AuditEntry{
				BusinessID: bizID,
				UserID:     userID,
				Action:     "BULK_IMPORT_ROW",
				EntityType: entityType,
				EntityID:   entityID,
				NewData:    map[string]interface{}{"job_id": jobID, "row": rowNum},
			})
		}

		// Progress update every 50 rows or last row
		if (i+1)%50 == 0 || i == len(rows)-1 {
			_, _ = h.db.Exec(ctx,
				`UPDATE bulk_import_jobs SET processed_rows=$1, success_rows=$2 WHERE id=$3`,
				i+1, successCount, jobID)
		}
	}

	finalStatus := "completed"
	if len(errs) > 0 && successCount > 0 {
		finalStatus = "failed_partial"
	} else if len(errs) > 0 && successCount == 0 {
		finalStatus = "failed"
	}

	errLogJSON, _ := json.Marshal(errs)
	_, _ = h.db.Exec(ctx,
		`UPDATE bulk_import_jobs
		 SET status=$1, processed_rows=$2, success_rows=$3, error_log=$4, completed_at=NOW()
		 WHERE id=$5`,
		finalStatus, len(rows), successCount, errLogJSON, jobID)

	h.audit.Log(ctx, middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     userID,
		Action:     "BULK_IMPORT_COMPLETED",
		EntityType: "bulk_import_job",
		EntityID:   jobID,
		NewData:    map[string]interface{}{"status": finalStatus, "success": successCount, "errors": len(errs)},
	})
}

// ── Per-entity inserters ──────────────────────────────────────────

func (h *Handler) insertCustomer(ctx context.Context, bizID uuid.UUID, r map[string]string) (uuid.UUID, error) {
	first := r["first_name"]
	if first == "" {
		return uuid.Nil, fmt.Errorf("first_name required")
	}
	id := uuid.New()
	_, err := h.db.Exec(ctx,
		`INSERT INTO customers (id, business_id, first_name, last_name, company_name, email, phone, mobile, notes)
		 VALUES ($1,$2,$3,NULLIF($4,''),NULLIF($5,''),NULLIF($6,''),NULLIF($7,''),NULLIF($8,''),NULLIF($9,''))`,
		id, bizID, first, r["last_name"], r["company_name"], r["email"], r["phone"], r["mobile"], r["notes"],
	)
	if err != nil {
		return uuid.Nil, err
	}
	return id, nil
}

func (h *Handler) insertJob(ctx context.Context, bizID, userID uuid.UUID, r map[string]string) (uuid.UUID, error) {
	num := r["job_number"]
	title := r["title"]
	if num == "" || title == "" {
		return uuid.Nil, fmt.Errorf("job_number and title required")
	}
	status := r["status"]
	if status == "" {
		status = "pending"
	}
	priority := r["priority"]
	if priority == "" {
		priority = "normal"
	}
	// Resolve customer by email if provided (best-effort)
	var customerID *uuid.UUID
	if email := r["customer_email"]; email != "" {
		var cid uuid.UUID
		if err := h.db.QueryRow(ctx,
			`SELECT id FROM customers WHERE business_id=$1 AND email=$2 LIMIT 1`,
			bizID, email,
		).Scan(&cid); err == nil {
			customerID = &cid
		}
	}
	id := uuid.New()
	_, err := h.db.Exec(ctx,
		`INSERT INTO jobs (id, business_id, job_number, title, description, status, priority, customer_id, created_by)
		 VALUES ($1,$2,$3,$4,NULLIF($5,''),$6,$7,$8,$9)`,
		id, bizID, num, title, r["description"], status, priority, customerID, userID,
	)
	if err != nil {
		return uuid.Nil, err
	}
	return id, nil
}

func (h *Handler) insertExpense(ctx context.Context, bizID, userID uuid.UUID, r map[string]string) (uuid.UUID, error) {
	desc := r["description"]
	if desc == "" {
		return uuid.Nil, fmt.Errorf("description required")
	}
	amount, err := strconv.ParseFloat(r["amount"], 64)
	if err != nil {
		return uuid.Nil, fmt.Errorf("invalid amount")
	}
	cat := r["category"]
	if cat == "" {
		cat = "other"
	}
	expenseDate := r["date"]
	if expenseDate == "" {
		expenseDate = time.Now().Format("2006-01-02")
	}
	id := uuid.New()
	_, err = h.db.Exec(ctx,
		`INSERT INTO expenses (id, business_id, category, description, amount, supplier, date, created_by)
		 VALUES ($1,$2,$3,$4,$5,NULLIF($6,''),$7::date,$8)`,
		id, bizID, cat, desc, amount, r["supplier"], expenseDate, userID,
	)
	if err != nil {
		return uuid.Nil, err
	}
	return id, nil
}

// ── helpers ───────────────────────────────────────────────────────

func respondJSON(w http.ResponseWriter, code int, body interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	if body != nil {
		_ = json.NewEncoder(w).Encode(body)
	}
}

func respondErr(w http.ResponseWriter, code int, msg string) {
	respondJSON(w, code, map[string]string{"error": msg})
}

// _ = io.EOF // keep import in case Reader use changes
var _ = io.EOF
