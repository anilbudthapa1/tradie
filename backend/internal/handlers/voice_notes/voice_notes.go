// Package voicenotes implements M126: Voice Job Notes.
//
// Flow:
//   1. POST /api/v1/voice-notes/presign   -> returns presigned PUT URL + storage key
//   2. Client uploads the audio to S3 directly using that URL.
//   3. POST /api/v1/voice-notes           -> finalize: insert files + voice_notes rows
//   4. POST /api/v1/voice-notes/{id}/transcribe  -> kicks off async transcription
//   5. GET  /api/v1/voice-notes?job_id=... -> list (manager+ sees all, others self-only)
package voicenotes

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"path/filepath"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	awscfg "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"go.uber.org/zap"

	"github.com/tradie/api/internal/config"
	"github.com/tradie/api/internal/middleware"
	"github.com/tradie/api/internal/services/transcription"
)

const (
	maxAudioBytes      = 25 << 20 // 25 MB
	presignExpiry      = 15 * time.Minute
	transcriptionRoles = "manager,admin,owner"
)

// Handler implements voice-note CRUD + presign + transcription trigger.
type Handler struct {
	cfg          *config.Config
	db           *pgxpool.Pool
	log          *zap.Logger
	audit        *middleware.AuditService
	s3           *s3.Client
	bucket       string
	transcriber  transcription.Transcriber
}

func NewHandler(cfg *config.Config, db *pgxpool.Pool, log *zap.Logger, audit *middleware.AuditService) *Handler {
	return &Handler{
		cfg:         cfg,
		db:          db,
		log:         log,
		audit:       audit,
		s3:          buildS3(cfg),
		bucket:      cfg.S3Bucket,
		transcriber: transcription.NewFromConfig(cfg.AnthropicAPIKey),
	}
}

func buildS3(cfg *config.Config) *s3.Client {
	creds := credentials.NewStaticCredentialsProvider(cfg.S3AccessKey, cfg.S3SecretKey, "")
	awsCfg, err := awscfg.LoadDefaultConfig(context.Background(),
		awscfg.WithRegion(cfg.S3Region),
		awscfg.WithCredentialsProvider(creds),
	)
	if err != nil {
		// Don't panic — return nil and let presign fail with a clean error.
		return nil
	}
	opts := []func(*s3.Options){}
	if cfg.S3Endpoint != "" {
		opts = append(opts, func(o *s3.Options) {
			o.BaseEndpoint = aws.String(cfg.S3Endpoint)
			o.UsePathStyle = cfg.S3UsePathStyle
		})
	}
	return s3.NewFromConfig(awsCfg, opts...)
}

// ── POST /api/v1/voice-notes/presign ─────────────────────────────────────

type presignRequest struct {
	Filename    string `json:"filename"`
	ContentType string `json:"content_type"`
}

type presignResponse struct {
	UploadURL  string    `json:"upload_url"`
	StorageKey string    `json:"storage_key"`
	ExpiresAt  time.Time `json:"expires_at"`
}

func (h *Handler) Presign(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	if h.s3 == nil {
		respondErr(w, http.StatusServiceUnavailable, "storage_not_configured")
		return
	}

	var req presignRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respondErr(w, http.StatusBadRequest, "invalid_request")
		return
	}
	if req.Filename == "" {
		req.Filename = "voice-note.m4a"
	}
	if req.ContentType == "" {
		req.ContentType = "audio/m4a"
	}
	if !strings.HasPrefix(req.ContentType, "audio/") {
		respondErr(w, http.StatusBadRequest, "content_type_must_be_audio")
		return
	}

	ext := strings.ToLower(filepath.Ext(req.Filename))
	if ext == "" {
		ext = ".m4a"
	}
	storageKey := fmt.Sprintf("%s/voice-notes/%s%s", bizID, uuid.New(), ext)

	presigner := s3.NewPresignClient(h.s3)
	signed, err := presigner.PresignPutObject(r.Context(), &s3.PutObjectInput{
		Bucket:      aws.String(h.bucket),
		Key:         aws.String(storageKey),
		ContentType: aws.String(req.ContentType),
	}, s3.WithPresignExpires(presignExpiry))
	if err != nil {
		h.log.Error("voice-note presign", zap.Error(err))
		respondErr(w, http.StatusInternalServerError, "presign_failed")
		return
	}

	respond(w, http.StatusOK, presignResponse{
		UploadURL:  signed.URL,
		StorageKey: storageKey,
		ExpiresAt:  time.Now().Add(presignExpiry),
	})
}

// ── POST /api/v1/voice-notes ─────────────────────────────────────────────

type finalizeRequest struct {
	JobID           *uuid.UUID `json:"job_id,omitempty"`
	StorageKey      string     `json:"storage_key"`
	Filename        string     `json:"filename"`
	ContentType     string     `json:"content_type"`
	SizeBytes       int64      `json:"size_bytes"`
	DurationSeconds int        `json:"duration_seconds"`
}

func (h *Handler) Finalize(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	bizID := middleware.BusinessIDFromCtx(ctx)
	claims := middleware.ClaimsFromCtx(ctx)
	if claims == nil {
		respondErr(w, http.StatusUnauthorized, "unauthorized")
		return
	}

	var req finalizeRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respondErr(w, http.StatusBadRequest, "invalid_request")
		return
	}
	if req.StorageKey == "" {
		respondErr(w, http.StatusBadRequest, "storage_key required")
		return
	}
	if req.SizeBytes > maxAudioBytes {
		respondErr(w, http.StatusRequestEntityTooLarge, "audio exceeds 25MB limit")
		return
	}
	// Defence in depth: storage key must live under our business prefix.
	if !strings.HasPrefix(req.StorageKey, bizID.String()+"/voice-notes/") {
		respondErr(w, http.StatusForbidden, "storage_key_not_owned_by_tenant")
		return
	}

	// If a job_id was provided, ensure it belongs to this tenant.
	if req.JobID != nil {
		var dummy uuid.UUID
		err := h.db.QueryRow(ctx,
			`SELECT id FROM jobs WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
			*req.JobID, bizID,
		).Scan(&dummy)
		if err != nil {
			respondErr(w, http.StatusNotFound, "job_not_found")
			return
		}
	}

	if req.Filename == "" {
		req.Filename = filepath.Base(req.StorageKey)
	}
	if req.ContentType == "" {
		req.ContentType = "audio/m4a"
	}

	fileURL := h.publicURL(req.StorageKey)

	// Insert into files + voice_notes within a transaction.
	tx, err := h.db.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		respondErr(w, http.StatusInternalServerError, "db_begin_failed")
		return
	}
	defer tx.Rollback(ctx)

	fileID := uuid.New()
	_, err = tx.Exec(ctx,
		`INSERT INTO files
		   (id, business_id, uploaded_by, filename, original_name, mime_type,
		    size_bytes, storage_key, url, entity_type, entity_id)
		 VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)`,
		fileID, bizID, claims.UserID, filepath.Base(req.StorageKey), req.Filename,
		req.ContentType, req.SizeBytes, req.StorageKey, fileURL,
		"voice_note", req.JobID,
	)
	if err != nil {
		h.log.Error("voice-note insert file", zap.Error(err))
		respondErr(w, http.StatusInternalServerError, "file_insert_failed")
		return
	}

	noteID := uuid.New()
	_, err = tx.Exec(ctx,
		`INSERT INTO voice_notes
		   (id, business_id, job_id, user_id, file_id, duration_seconds, transcription_status)
		 VALUES ($1,$2,$3,$4,$5,$6,'pending')`,
		noteID, bizID, req.JobID, claims.UserID, fileID, req.DurationSeconds,
	)
	if err != nil {
		h.log.Error("voice-note insert", zap.Error(err))
		respondErr(w, http.StatusInternalServerError, "voice_note_insert_failed")
		return
	}

	if err := tx.Commit(ctx); err != nil {
		respondErr(w, http.StatusInternalServerError, "db_commit_failed")
		return
	}

	h.audit.Log(ctx, middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     "VOICE_NOTE_CREATED",
		EntityType: "voice_note",
		EntityID:   noteID,
		IPAddress:  r.RemoteAddr,
	})

	respond(w, http.StatusCreated, map[string]interface{}{
		"id":                   noteID,
		"file_id":              fileID,
		"job_id":               req.JobID,
		"duration_seconds":     req.DurationSeconds,
		"transcription_status": "pending",
		"created_at":           time.Now().UTC(),
	})
}

// ── GET /api/v1/voice-notes?job_id=... ───────────────────────────────────

type voiceNoteRow struct {
	ID                  uuid.UUID  `json:"id"`
	JobID               *uuid.UUID `json:"job_id"`
	UserID              uuid.UUID  `json:"user_id"`
	FileID              *uuid.UUID `json:"file_id"`
	DurationSeconds     int        `json:"duration_seconds"`
	Transcript          *string    `json:"transcript"`
	TranscriptionStatus string     `json:"transcription_status"`
	CreatedAt           time.Time  `json:"created_at"`
}

func (h *Handler) List(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	bizID := middleware.BusinessIDFromCtx(ctx)
	claims := middleware.ClaimsFromCtx(ctx)
	if claims == nil {
		respondErr(w, http.StatusUnauthorized, "unauthorized")
		return
	}

	jobIDStr := r.URL.Query().Get("job_id")
	q := `SELECT id, job_id, user_id, file_id, duration_seconds, transcript,
	             transcription_status, created_at
	      FROM voice_notes WHERE business_id=$1`
	args := []interface{}{bizID}

	// Self-only unless caller is manager+.
	if !isManagerPlus(claims.Role) {
		args = append(args, claims.UserID)
		q += fmt.Sprintf(" AND user_id=$%d", len(args))
	}
	if jobIDStr != "" {
		jobID, err := uuid.Parse(jobIDStr)
		if err != nil {
			respondErr(w, http.StatusBadRequest, "invalid_job_id")
			return
		}
		args = append(args, jobID)
		q += fmt.Sprintf(" AND job_id=$%d", len(args))
	}
	q += " ORDER BY created_at DESC LIMIT 200"

	rows, err := h.db.Query(ctx, q, args...)
	if err != nil {
		h.log.Error("voice-note list", zap.Error(err))
		respondErr(w, http.StatusInternalServerError, "query_failed")
		return
	}
	defer rows.Close()

	out := []voiceNoteRow{}
	for rows.Next() {
		var v voiceNoteRow
		if err := rows.Scan(&v.ID, &v.JobID, &v.UserID, &v.FileID, &v.DurationSeconds,
			&v.Transcript, &v.TranscriptionStatus, &v.CreatedAt); err != nil {
			continue
		}
		out = append(out, v)
	}
	respond(w, http.StatusOK, map[string]interface{}{"voice_notes": out, "total": len(out)})
}

// ── POST /api/v1/voice-notes/{id}/transcribe ─────────────────────────────

func (h *Handler) Transcribe(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	bizID := middleware.BusinessIDFromCtx(ctx)
	claims := middleware.ClaimsFromCtx(ctx)
	if claims == nil {
		respondErr(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	noteIDStr := chi.URLParam(r, "id")
	noteID, err := uuid.Parse(noteIDStr)
	if err != nil {
		respondErr(w, http.StatusBadRequest, "invalid_id")
		return
	}

	var (
		userID  uuid.UUID
		fileURL string
		status  string
	)
	err = h.db.QueryRow(ctx,
		`SELECT vn.user_id, COALESCE(f.url,''), vn.transcription_status
		 FROM voice_notes vn
		 LEFT JOIN files f ON f.id = vn.file_id
		 WHERE vn.id=$1 AND vn.business_id=$2`,
		noteID, bizID,
	).Scan(&userID, &fileURL, &status)
	if err != nil {
		respondErr(w, http.StatusNotFound, "not_found")
		return
	}
	// Either owner of the note or manager+ can trigger.
	if userID != claims.UserID && !isManagerPlus(claims.Role) {
		respondErr(w, http.StatusForbidden, "forbidden")
		return
	}
	if status == "processing" {
		respond(w, http.StatusAccepted, map[string]string{"status": "processing"})
		return
	}

	// Mark processing then fire the transcriber asynchronously.
	_, _ = h.db.Exec(ctx,
		`UPDATE voice_notes SET transcription_status='processing', updated_at=NOW() WHERE id=$1`,
		noteID,
	)

	go h.runTranscription(noteID, fileURL)

	h.audit.Log(ctx, middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     "VOICE_NOTE_TRANSCRIBE",
		EntityType: "voice_note",
		EntityID:   noteID,
		IPAddress:  r.RemoteAddr,
	})

	respond(w, http.StatusAccepted, map[string]string{"status": "processing"})
}

func (h *Handler) runTranscription(noteID uuid.UUID, fileURL string) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()

	transcript, err := h.transcriber.Transcribe(ctx, fileURL)
	if err != nil {
		_, _ = h.db.Exec(ctx,
			`UPDATE voice_notes
			 SET transcription_status='error', error_message=$2, updated_at=NOW()
			 WHERE id=$1`,
			noteID, err.Error(),
		)
		return
	}
	_, _ = h.db.Exec(ctx,
		`UPDATE voice_notes
		 SET transcript=$2, transcription_status='completed', updated_at=NOW()
		 WHERE id=$1`,
		noteID, transcript,
	)
}

// ── helpers ──────────────────────────────────────────────────────────────

func (h *Handler) publicURL(key string) string {
	if h.cfg.S3Endpoint != "" && h.cfg.S3UsePathStyle {
		return fmt.Sprintf("%s/%s/%s", h.cfg.S3Endpoint, h.bucket, key)
	}
	return fmt.Sprintf("https://%s.s3.%s.amazonaws.com/%s", h.bucket, h.cfg.S3Region, key)
}

func isManagerPlus(role string) bool {
	switch role {
	case "owner", "admin", "manager":
		return true
	}
	return false
}

// Routes returns a chi router subgroup that the parent router can mount.
//
//	r.Route("/api/v1/voice-notes", h.Routes())
func (h *Handler) Routes() func(r chi.Router) {
	return func(r chi.Router) {
		r.Post("/presign", h.Presign)
		r.Post("/", h.Finalize)
		r.Get("/", h.List)
		r.Post("/{id}/transcribe", h.Transcribe)
	}
}

// ── respond helpers ──────────────────────────────────────────────────────

func respond(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if data != nil {
		_ = json.NewEncoder(w).Encode(data)
	}
}

func respondErr(w http.ResponseWriter, status int, msg string) {
	respond(w, status, map[string]string{"error": msg})
}
