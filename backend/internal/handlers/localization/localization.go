// Package localization implements Module 127 — Multi Language Module.
//
// It manages tenant-scoped localization entries and translated templates.
// business_id is always loaded from trusted request context; callers cannot
// provide or override it.
package localization

import (
	"encoding/csv"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"regexp"
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

const (
	AuditViewed       = "MULTI_LANGUAGE_MODULE_VIEWED"
	AuditCreated      = "MULTI_LANGUAGE_MODULE_CREATED"
	AuditUpdated      = "MULTI_LANGUAGE_MODULE_UPDATED"
	AuditDeleted      = "MULTI_LANGUAGE_MODULE_DELETED"
	AuditAccessDenied = "MULTI_LANGUAGE_MODULE_ACCESS_DENIED"
	AuditExported     = "MULTI_LANGUAGE_MODULE_EXPORTED"

	maxBodyBytes = 32 * 1024
)

var (
	allowedLanguage = map[string]bool{
		"en": true, "en-AU": true, "zh": true, "vi": true, "ar": true,
	}
	allowedTemplateType = map[string]bool{
		"ui": true, "email": true, "sms": true, "push": true,
		"document": true, "customer_portal": true,
	}
	allowedStatus     = map[string]bool{"draft": true, "active": true, "archived": true}
	allowedTransition = map[[2]string]bool{
		{"draft", "active"}:    true,
		{"draft", "archived"}:  true,
		{"active", "archived"}: true,
		{"archived", "draft"}:  true,
		{"archived", "active"}: true,
	}
	namePattern = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9_.:-]{0,119}$`)
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

type entryRow struct {
	ID             uuid.UUID  `json:"id"`
	BusinessID     uuid.UUID  `json:"-"`
	CreatedBy      *uuid.UUID `json:"created_by"`
	UpdatedBy      *uuid.UUID `json:"updated_by"`
	Namespace      string     `json:"namespace"`
	TranslationKey string     `json:"translation_key"`
	Language       string     `json:"language"`
	Value          string     `json:"value"`
	TemplateType   string     `json:"template_type"`
	Status         string     `json:"status"`
	Metadata       []byte     `json:"-"`
	CreatedAt      time.Time  `json:"created_at"`
	UpdatedAt      time.Time  `json:"updated_at"`
}

func (e *entryRow) MarshalJSON() ([]byte, error) {
	type alias entryRow
	mm := json.RawMessage(e.Metadata)
	if len(mm) == 0 {
		mm = json.RawMessage("{}")
	}
	return json.Marshal(struct {
		*alias
		Metadata json.RawMessage `json:"metadata"`
	}{(*alias)(e), mm})
}

func (h *Handler) List(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	if !h.requirePermission(w, r, "localization.manage") {
		return
	}

	status := strings.TrimSpace(r.URL.Query().Get("status"))
	if status != "" && status != "all" && !allowedStatus[status] {
		respondErr(w, http.StatusBadRequest, "invalid_status")
		return
	}
	language := strings.TrimSpace(r.URL.Query().Get("language"))
	if language != "" && !allowedLanguage[language] {
		respondErr(w, http.StatusBadRequest, "unsupported_language")
		return
	}
	templateType := strings.TrimSpace(r.URL.Query().Get("template_type"))
	if templateType != "" && !allowedTemplateType[templateType] {
		respondErr(w, http.StatusBadRequest, "invalid_template_type")
		return
	}
	search := strings.TrimSpace(r.URL.Query().Get("q"))
	limit := parseLimit(r.URL.Query().Get("limit"), 300)

	args := []interface{}{bizID}
	filters := []string{"business_id=$1", "deleted_at IS NULL"}
	next := 2
	if status != "" && status != "all" {
		filters = append(filters, "status=$"+strconv.Itoa(next))
		args = append(args, status)
		next++
	}
	if language != "" {
		filters = append(filters, "language=$"+strconv.Itoa(next))
		args = append(args, language)
		next++
	}
	if templateType != "" {
		filters = append(filters, "template_type=$"+strconv.Itoa(next))
		args = append(args, templateType)
		next++
	}
	if search != "" {
		filters = append(filters, "(namespace ILIKE $"+strconv.Itoa(next)+" OR translation_key ILIKE $"+strconv.Itoa(next)+" OR value ILIKE $"+strconv.Itoa(next)+")")
		args = append(args, "%"+search+"%")
		next++
	}
	args = append(args, limit)

	rows, err := h.db.Query(r.Context(),
		`SELECT id, business_id, created_by, updated_by, namespace, translation_key,
		        language, value, template_type, status, metadata, created_at, updated_at
		 FROM localization_entries
		 WHERE `+strings.Join(filters, " AND ")+`
		 ORDER BY namespace, translation_key, language
		 LIMIT $`+strconv.Itoa(next), args...)
	if err != nil {
		h.log.Error("list localization entries", zap.Error(err))
		respondErr(w, http.StatusInternalServerError, "query_failed")
		return
	}
	defer rows.Close()

	out := []*entryRow{}
	for rows.Next() {
		row := &entryRow{}
		if err := scanEntry(rows, row); err == nil {
			out = append(out, row)
		}
	}
	respond(w, http.StatusOK, out)
}

func (h *Handler) Create(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "localization.manage") {
		return
	}

	var req struct {
		Namespace      string                 `json:"namespace"`
		TranslationKey string                 `json:"translation_key"`
		Language       string                 `json:"language"`
		Value          string                 `json:"value"`
		TemplateType   string                 `json:"template_type"`
		Status         string                 `json:"status"`
		Metadata       map[string]interface{} `json:"metadata"`
	}
	if err := decodeStrict(r, &req); err != nil {
		respondErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if err := validateEntry(req.Namespace, req.TranslationKey, req.Language, req.Value, req.TemplateType, req.Status, false); err != nil {
		respondErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if req.Namespace == "" {
		req.Namespace = "common"
	}
	if req.TemplateType == "" {
		req.TemplateType = "ui"
	}
	if req.Status == "" {
		req.Status = "draft"
	}

	var id uuid.UUID
	err := h.db.QueryRow(r.Context(),
		`INSERT INTO localization_entries
		   (business_id, created_by, namespace, translation_key, language, value,
		    template_type, status, metadata)
		 VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9::jsonb)
		 RETURNING id`,
		bizID, claims.UserID, strings.TrimSpace(req.Namespace),
		strings.TrimSpace(req.TranslationKey), req.Language, strings.TrimSpace(req.Value),
		req.TemplateType, req.Status, jsonOrEmpty(req.Metadata),
	).Scan(&id)
	if err != nil {
		if isDuplicate(err) {
			respondErr(w, http.StatusConflict, "translation_already_exists")
			return
		}
		h.log.Error("create localization entry", zap.Error(err))
		respondErr(w, http.StatusInternalServerError, "create_failed")
		return
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditCreated,
		EntityType: "localization_entry",
		EntityID:   id,
		NewData: map[string]interface{}{
			"namespace": req.Namespace, "translation_key": req.TranslationKey,
			"language": req.Language, "status": req.Status,
		},
		IPAddress: r.RemoteAddr,
	})
	h.respondOne(w, r, id, http.StatusCreated)
}

func (h *Handler) Get(w http.ResponseWriter, r *http.Request) {
	if !h.requirePermission(w, r, "localization.manage") {
		return
	}
	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		respondErr(w, http.StatusBadRequest, "invalid_id")
		return
	}
	h.respondOne(w, r, id, http.StatusOK)
}

func (h *Handler) Update(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "localization.manage") {
		return
	}
	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		respondErr(w, http.StatusBadRequest, "invalid_id")
		return
	}

	var req struct {
		Namespace      *string                `json:"namespace"`
		TranslationKey *string                `json:"translation_key"`
		Language       *string                `json:"language"`
		Value          *string                `json:"value"`
		TemplateType   *string                `json:"template_type"`
		Status         *string                `json:"status"`
		Metadata       map[string]interface{} `json:"metadata"`
	}
	if err := decodeStrict(r, &req); err != nil {
		respondErr(w, http.StatusBadRequest, err.Error())
		return
	}

	var current entryRow
	err = h.db.QueryRow(r.Context(),
		`SELECT id, business_id, created_by, updated_by, namespace, translation_key,
		        language, value, template_type, status, metadata, created_at, updated_at
		 FROM localization_entries
		 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`, id, bizID,
	).Scan(&current.ID, &current.BusinessID, &current.CreatedBy, &current.UpdatedBy,
		&current.Namespace, &current.TranslationKey, &current.Language, &current.Value,
		&current.TemplateType, &current.Status, &current.Metadata,
		&current.CreatedAt, &current.UpdatedAt)
	if err != nil {
		respondErr(w, http.StatusNotFound, "not_found")
		return
	}
	if err := validatePatch(req.Namespace, req.TranslationKey, req.Language, req.Value, req.TemplateType, req.Status); err != nil {
		respondErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if req.Status != nil && *req.Status != current.Status &&
		!allowedTransition[[2]string{current.Status, *req.Status}] {
		respondErr(w, http.StatusConflict, "invalid_status_transition")
		return
	}

	var meta []byte
	if req.Metadata != nil {
		meta, _ = json.Marshal(req.Metadata)
	}
	tag, err := h.db.Exec(r.Context(),
		`UPDATE localization_entries SET
		   namespace       = COALESCE($3, namespace),
		   translation_key = COALESCE($4, translation_key),
		   language        = COALESCE($5, language),
		   value           = COALESCE($6, value),
		   template_type   = COALESCE($7, template_type),
		   status          = COALESCE($8, status),
		   metadata        = COALESCE($9::jsonb, metadata),
		   updated_by      = $10,
		   updated_at      = NOW()
		 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID, req.Namespace, req.TranslationKey, req.Language, req.Value,
		req.TemplateType, req.Status, meta, claims.UserID)
	if err != nil {
		if isDuplicate(err) {
			respondErr(w, http.StatusConflict, "translation_already_exists")
			return
		}
		h.log.Error("update localization entry", zap.Error(err))
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
		EntityType: "localization_entry",
		EntityID:   id,
		OldData: map[string]interface{}{
			"namespace": current.Namespace, "translation_key": current.TranslationKey,
			"language": current.Language, "status": current.Status,
		},
		NewData: map[string]interface{}{
			"namespace": derefStr(req.Namespace), "translation_key": derefStr(req.TranslationKey),
			"language": derefStr(req.Language), "status": derefStr(req.Status),
		},
		IPAddress: r.RemoteAddr,
	})
	h.respondOne(w, r, id, http.StatusOK)
}

func (h *Handler) Delete(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "localization.manage") {
		return
	}
	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		respondErr(w, http.StatusBadRequest, "invalid_id")
		return
	}
	tag, err := h.db.Exec(r.Context(),
		`UPDATE localization_entries
		 SET deleted_at=NOW(), updated_by=$3, updated_at=NOW()
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
		EntityType: "localization_entry",
		EntityID:   id,
		IPAddress:  r.RemoteAddr,
	})
	w.WriteHeader(http.StatusNoContent)
}

func (h *Handler) MeView(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "localization.view") {
		return
	}
	lang := strings.TrimSpace(r.URL.Query().Get("language"))
	if lang != "" && !allowedLanguage[lang] {
		respondErr(w, http.StatusBadRequest, "unsupported_language")
		return
	}
	args := []interface{}{bizID}
	filter := "business_id=$1 AND deleted_at IS NULL AND status='active'"
	if lang != "" {
		filter += " AND language=$2"
		args = append(args, lang)
	}
	rows, err := h.db.Query(r.Context(),
		`SELECT namespace, translation_key, language, value, template_type
		 FROM localization_entries
		 WHERE `+filter+`
		 ORDER BY namespace, translation_key, language`, args...)
	if err != nil {
		respondErr(w, http.StatusInternalServerError, "query_failed")
		return
	}
	defer rows.Close()

	items := []map[string]string{}
	for rows.Next() {
		var ns, key, language, value, templateType string
		if err := rows.Scan(&ns, &key, &language, &value, &templateType); err == nil {
			items = append(items, map[string]string{
				"namespace": ns, "translation_key": key, "language": language,
				"value": value, "template_type": templateType,
			})
		}
	}
	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditViewed,
		EntityType: "localization_entry.me",
		IPAddress:  r.RemoteAddr,
	})
	respond(w, http.StatusOK, items)
}

func (h *Handler) Export(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePermission(w, r, "localization.export") {
		return
	}
	rows, err := h.db.Query(r.Context(),
		`SELECT id, namespace, translation_key, language, value, template_type, status, created_at, updated_at
		 FROM localization_entries
		 WHERE business_id=$1 AND deleted_at IS NULL
		 ORDER BY namespace, translation_key, language`, bizID)
	if err != nil {
		respondErr(w, http.StatusInternalServerError, "query_failed")
		return
	}
	defer rows.Close()

	w.Header().Set("Content-Type", "text/csv; charset=utf-8")
	w.Header().Set("Content-Disposition",
		fmt.Sprintf(`attachment; filename="localization-%s.csv"`, time.Now().Format("2006-01-02")))

	cw := csv.NewWriter(w)
	defer cw.Flush()
	_ = cw.Write([]string{"id", "namespace", "translation_key", "language", "value", "template_type", "status", "created_at", "updated_at"})
	for rows.Next() {
		var id uuid.UUID
		var ns, key, language, value, templateType, status string
		var createdAt, updatedAt time.Time
		if err := rows.Scan(&id, &ns, &key, &language, &value, &templateType, &status, &createdAt, &updatedAt); err != nil {
			continue
		}
		_ = cw.Write([]string{id.String(), ns, key, language, value, templateType, status, createdAt.UTC().Format(time.RFC3339), updatedAt.UTC().Format(time.RFC3339)})
	}
	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditExported,
		EntityType: "localization_entry",
		IPAddress:  r.RemoteAddr,
	})
}

func (h *Handler) respondOne(w http.ResponseWriter, r *http.Request, id uuid.UUID, code int) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	row := &entryRow{}
	err := h.db.QueryRow(r.Context(),
		`SELECT id, business_id, created_by, updated_by, namespace, translation_key,
		        language, value, template_type, status, metadata, created_at, updated_at
		 FROM localization_entries
		 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID,
	).Scan(&row.ID, &row.BusinessID, &row.CreatedBy, &row.UpdatedBy,
		&row.Namespace, &row.TranslationKey, &row.Language, &row.Value,
		&row.TemplateType, &row.Status, &row.Metadata, &row.CreatedAt, &row.UpdatedAt)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			respondErr(w, http.StatusNotFound, "not_found")
			return
		}
		respondErr(w, http.StatusInternalServerError, "query_failed")
		return
	}
	respond(w, code, row)
}

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
			EntityType: "localization_entry",
			NewData:    map[string]interface{}{"required": key, "role": claims.Role},
			IPAddress:  r.RemoteAddr,
		})
		respondErr(w, http.StatusForbidden, "forbidden:"+key)
		return false
	}
	return true
}

type rowScanner interface {
	Scan(dest ...interface{}) error
}

func scanEntry(rs rowScanner, row *entryRow) error {
	return rs.Scan(&row.ID, &row.BusinessID, &row.CreatedBy, &row.UpdatedBy,
		&row.Namespace, &row.TranslationKey, &row.Language, &row.Value,
		&row.TemplateType, &row.Status, &row.Metadata, &row.CreatedAt, &row.UpdatedAt)
}

func validateEntry(namespace, key, language, value, templateType, status string, patch bool) error {
	if namespace == "" {
		namespace = "common"
	}
	if templateType == "" {
		templateType = "ui"
	}
	if status == "" {
		status = "draft"
	}
	if !namePattern.MatchString(strings.TrimSpace(namespace)) {
		return errors.New("invalid_namespace")
	}
	if !namePattern.MatchString(strings.TrimSpace(key)) {
		return errors.New("invalid_translation_key")
	}
	if !allowedLanguage[language] {
		return errors.New("unsupported_language")
	}
	if strings.TrimSpace(value) == "" {
		return errors.New("value_required")
	}
	if len(value) > 10000 {
		return errors.New("value_too_large")
	}
	if !allowedTemplateType[templateType] {
		return errors.New("invalid_template_type")
	}
	if !allowedStatus[status] {
		return errors.New("invalid_status")
	}
	return nil
}

func validatePatch(namespace, key, language, value, templateType, status *string) error {
	if namespace != nil && !namePattern.MatchString(strings.TrimSpace(*namespace)) {
		return errors.New("invalid_namespace")
	}
	if key != nil && !namePattern.MatchString(strings.TrimSpace(*key)) {
		return errors.New("invalid_translation_key")
	}
	if language != nil && !allowedLanguage[*language] {
		return errors.New("unsupported_language")
	}
	if value != nil && (strings.TrimSpace(*value) == "" || len(*value) > 10000) {
		return errors.New("invalid_value")
	}
	if templateType != nil && !allowedTemplateType[*templateType] {
		return errors.New("invalid_template_type")
	}
	if status != nil && !allowedStatus[*status] {
		return errors.New("invalid_status")
	}
	return nil
}

func parseLimit(raw string, fallback int) int {
	if raw == "" {
		return fallback
	}
	n, err := strconv.Atoi(raw)
	if err != nil || n <= 0 || n > 1000 {
		return fallback
	}
	return n
}

func isDuplicate(err error) bool {
	if err == nil {
		return false
	}
	return strings.Contains(err.Error(), "uq_localization_entries_business_key_language") ||
		strings.Contains(err.Error(), "duplicate key value")
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
	if dec.Decode(&struct{}{}) != io.EOF {
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

func respond(w http.ResponseWriter, code int, body interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	if body != nil {
		_ = json.NewEncoder(w).Encode(body)
	}
}

func respondErr(w http.ResponseWriter, code int, msg string) {
	respond(w, code, map[string]string{"error": msg})
}
