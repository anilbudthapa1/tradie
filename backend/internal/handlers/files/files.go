package files

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
	"github.com/jackc/pgx/v5/pgxpool"
	"go.uber.org/zap"

	"github.com/tradie/api/internal/config"
	"github.com/tradie/api/internal/middleware"
)

const maxUploadSize = 50 << 20 // 50 MB

// allowedMimeTypes is the upload allowlist (M120). Anything outside this set
// is rejected at the upload boundary. Add to this list when a new business
// case is approved — never widen it casually.
var allowedMimeTypes = map[string]bool{
	"image/jpeg":      true,
	"image/jpg":       true,
	"image/png":       true,
	"image/heic":      true,
	"image/heif":      true,
	"application/pdf": true,
	"text/csv":        true,
}

type Handler struct {
	cfg    *config.Config
	db     *pgxpool.Pool
	log    *zap.Logger
	s3     *s3.Client
	bucket string
	audit  *middleware.AuditService
}

// NewHandler accepts an optional *middleware.AuditService as the first variadic
// argument. The router currently calls NewHandler(cfg, db, log) without an
// audit service — when one isn't passed we lazily construct one from the DB
// pool so FILE_UPLOADED events are still recorded.
func NewHandler(cfg *config.Config, db *pgxpool.Pool, log *zap.Logger, args ...interface{}) *Handler {
	s3Client := buildS3Client(cfg)
	h := &Handler{cfg: cfg, db: db, log: log, s3: s3Client, bucket: cfg.S3Bucket}
	for _, a := range args {
		if svc, ok := a.(*middleware.AuditService); ok && svc != nil {
			h.audit = svc
		}
	}
	if h.audit == nil {
		h.audit = middleware.NewAuditService(db, log)
	}
	return h
}

func buildS3Client(cfg *config.Config) *s3.Client {
	creds := credentials.NewStaticCredentialsProvider(cfg.S3AccessKey, cfg.S3SecretKey, "")
	awsCfg, err := awscfg.LoadDefaultConfig(context.Background(),
		awscfg.WithRegion(cfg.S3Region),
		awscfg.WithCredentialsProvider(creds),
	)
	if err != nil {
		panic(fmt.Sprintf("s3 config: %v", err))
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

func respond(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if data != nil {
		json.NewEncoder(w).Encode(data)
	}
}

func respondErr(w http.ResponseWriter, status int, msg string) {
	respond(w, status, map[string]string{"error": msg})
}

// Upload — POST /api/v1/files/upload
// Multipart field "file", optional field "entity_type" and "entity_id".
func (h *Handler) Upload(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())

	if err := r.ParseMultipartForm(maxUploadSize); err != nil {
		respondErr(w, http.StatusBadRequest, "file too large or invalid form")
		return
	}

	file, header, err := r.FormFile("file")
	if err != nil {
		respondErr(w, http.StatusBadRequest, "file field required")
		return
	}
	defer file.Close()

	if header.Size > maxUploadSize {
		respondErr(w, http.StatusRequestEntityTooLarge, "file exceeds 50 MB limit")
		return
	}

	ext := strings.ToLower(filepath.Ext(header.Filename))
	contentType := header.Header.Get("Content-Type")
	if contentType == "" {
		contentType = "application/octet-stream"
	}
	// Normalise: the multipart header sometimes carries parameters
	// (e.g. "image/jpeg; charset=...") — split on ';' and lower-case.
	mimeKey := strings.ToLower(strings.TrimSpace(strings.SplitN(contentType, ";", 2)[0]))
	if !allowedMimeTypes[mimeKey] {
		respondErr(w, http.StatusUnsupportedMediaType, "unsupported file type")
		return
	}

	entityType := r.FormValue("entity_type")
	entityIDStr := r.FormValue("entity_id")

	fileID := uuid.New()
	key := fmt.Sprintf("%s/%s/%s%s", bizID, entityType, fileID, ext)

	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()

	_, err = h.s3.PutObject(ctx, &s3.PutObjectInput{
		Bucket:        aws.String(h.bucket),
		Key:           aws.String(key),
		Body:          file,
		ContentType:   aws.String(contentType),
		ContentLength: aws.Int64(header.Size),
	})
	if err != nil {
		h.log.Error("s3 put object", zap.Error(err))
		respondErr(w, http.StatusInternalServerError, "upload failed")
		return
	}

	var entityID *uuid.UUID
	if entityIDStr != "" {
		parsed, err := uuid.Parse(entityIDStr)
		if err == nil {
			entityID = &parsed
		}
	}

	var fileURL string
	if h.cfg.S3Endpoint != "" && h.cfg.S3UsePathStyle {
		fileURL = fmt.Sprintf("%s/%s/%s", h.cfg.S3Endpoint, h.bucket, key)
	} else {
		fileURL = fmt.Sprintf("https://%s.s3.%s.amazonaws.com/%s", h.bucket, h.cfg.S3Region, key)
	}

	row := h.db.QueryRow(ctx, `
		INSERT INTO files (id, business_id, uploaded_by, entity_type, entity_id,
		                   name, url, size, mime_type, storage_key)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
		RETURNING id, business_id, entity_type, entity_id, name, url, size, mime_type, created_at`,
		fileID, bizID, claims.UserID, entityType, entityID,
		header.Filename, fileURL, header.Size, contentType, key,
	)

	var result struct {
		ID         uuid.UUID  `json:"id"`
		BusinessID uuid.UUID  `json:"business_id"`
		EntityType string     `json:"entity_type"`
		EntityID   *uuid.UUID `json:"entity_id"`
		Name       string     `json:"name"`
		URL        string     `json:"url"`
		Size       int64      `json:"size"`
		MimeType   string     `json:"mime_type"`
		CreatedAt  time.Time  `json:"created_at"`
	}
	if err := row.Scan(&result.ID, &result.BusinessID, &result.EntityType, &result.EntityID,
		&result.Name, &result.URL, &result.Size, &result.MimeType, &result.CreatedAt); err != nil {
		h.log.Error("insert file record", zap.Error(err))
		// Still return the URL even if DB insert fails — but we still audit
		// the upload because the bytes are now in S3.
		h.auditUpload(r, bizID, claims.UserID, fileID, entityType, entityID, header.Size, mimeKey)
		respond(w, http.StatusCreated, map[string]interface{}{
			"id":  fileID,
			"url": fileURL,
			"key": key,
		})
		return
	}

	h.auditUpload(r, bizID, claims.UserID, fileID, entityType, entityID, header.Size, mimeKey)
	respond(w, http.StatusCreated, result)
}

// auditUpload records a FILE_UPLOADED entry. Scope kept minimal so we don't
// store filename / URL — just enough for forensics + storage attribution.
func (h *Handler) auditUpload(r *http.Request, bizID, userID, fileID uuid.UUID, entityType string, entityID *uuid.UUID, size int64, mime string) {
	if h.audit == nil {
		return
	}
	new := map[string]interface{}{
		"size":        size,
		"mime":        mime,
		"entity_type": entityType,
	}
	if entityID != nil {
		new["entity_id"] = entityID.String()
	}
	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     userID,
		Action:     "FILE_UPLOADED",
		EntityType: "file",
		EntityID:   fileID,
		IPAddress:  r.RemoteAddr,
		NewData:    new,
	})
}

// Get — GET /api/v1/files/{id}
// Returns a presigned URL valid for 1 hour.
func (h *Handler) Get(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	fileIDStr := chi.URLParam(r, "id")
	fileID, err := uuid.Parse(fileIDStr)
	if err != nil {
		respondErr(w, http.StatusBadRequest, "invalid file id")
		return
	}

	var storageKey, name, mimeType string
	var size int64
	var createdAt time.Time
	err = h.db.QueryRow(r.Context(), `
		SELECT storage_key, name, mime_type, size, created_at
		FROM files WHERE id = $1 AND business_id = $2 AND deleted_at IS NULL`,
		fileID, bizID,
	).Scan(&storageKey, &name, &mimeType, &size, &createdAt)
	if err != nil {
		respondErr(w, http.StatusNotFound, "file not found")
		return
	}

	presigner := s3.NewPresignClient(h.s3)
	presigned, err := presigner.PresignGetObject(r.Context(), &s3.GetObjectInput{
		Bucket: aws.String(h.bucket),
		Key:    aws.String(storageKey),
	}, s3.WithPresignExpires(time.Hour))
	if err != nil {
		h.log.Error("presign get object", zap.Error(err))
		respondErr(w, http.StatusInternalServerError, "could not generate download URL")
		return
	}

	respond(w, http.StatusOK, map[string]interface{}{
		"id":         fileID,
		"name":       name,
		"mime_type":  mimeType,
		"size":       size,
		"url":        presigned.URL,
		"expires_at": time.Now().Add(time.Hour),
		"created_at": createdAt,
	})
}

// Delete — DELETE /api/v1/files/{id}
func (h *Handler) Delete(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	fileIDStr := chi.URLParam(r, "id")
	fileID, err := uuid.Parse(fileIDStr)
	if err != nil {
		respondErr(w, http.StatusBadRequest, "invalid file id")
		return
	}

	var storageKey string
	err = h.db.QueryRow(r.Context(), `
		UPDATE files SET deleted_at = NOW()
		WHERE id = $1 AND business_id = $2 AND deleted_at IS NULL
		RETURNING storage_key`,
		fileID, bizID,
	).Scan(&storageKey)
	if err != nil {
		respondErr(w, http.StatusNotFound, "file not found")
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
	defer cancel()

	_, err = h.s3.DeleteObject(ctx, &s3.DeleteObjectInput{
		Bucket: aws.String(h.bucket),
		Key:    aws.String(storageKey),
	})
	if err != nil {
		h.log.Warn("s3 delete object", zap.Error(err), zap.String("key", storageKey))
	}

	w.WriteHeader(http.StatusNoContent)
}

// ListForEntity — GET /api/v1/files?entity_type=job&entity_id=xxx
func (h *Handler) ListForEntity(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	entityType := r.URL.Query().Get("entity_type")
	entityIDStr := r.URL.Query().Get("entity_id")

	query := `SELECT id, entity_type, entity_id, name, url, size, mime_type, created_at
	          FROM files WHERE business_id = $1 AND deleted_at IS NULL`
	args := []interface{}{bizID}

	if entityType != "" {
		args = append(args, entityType)
		query += fmt.Sprintf(" AND entity_type = $%d", len(args))
	}
	if entityIDStr != "" {
		entityID, err := uuid.Parse(entityIDStr)
		if err == nil {
			args = append(args, entityID)
			query += fmt.Sprintf(" AND entity_id = $%d", len(args))
		}
	}
	query += " ORDER BY created_at DESC LIMIT 100"

	rows, err := h.db.Query(r.Context(), query, args...)
	if err != nil {
		h.log.Error("list files", zap.Error(err))
		respondErr(w, http.StatusInternalServerError, "query failed")
		return
	}
	defer rows.Close()

	type fileRow struct {
		ID         uuid.UUID  `json:"id"`
		EntityType string     `json:"entity_type"`
		EntityID   *uuid.UUID `json:"entity_id"`
		Name       string     `json:"name"`
		URL        string     `json:"url"`
		Size       int64      `json:"size"`
		MimeType   string     `json:"mime_type"`
		CreatedAt  time.Time  `json:"created_at"`
	}
	results := []fileRow{}
	for rows.Next() {
		var f fileRow
		if err := rows.Scan(&f.ID, &f.EntityType, &f.EntityID, &f.Name, &f.URL, &f.Size, &f.MimeType, &f.CreatedAt); err != nil {
			continue
		}
		results = append(results, f)
	}
	respond(w, http.StatusOK, map[string]interface{}{"files": results, "total": len(results)})
}
