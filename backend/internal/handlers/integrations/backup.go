package integrations

import (
	"encoding/json"
	"net/http"

	"github.com/jackc/pgx/v5/pgxpool"
	"go.uber.org/zap"

	"github.com/tradie/api/internal/config"
	"github.com/tradie/api/internal/middleware"
)

// BackupHandler exposes the admin "request a backup" endpoint.
//
// We intentionally do NOT perform a database backup from inside the API
// process — that is an infrastructure concern (managed RDS snapshots,
// pg_dump on a bastion, or volume-level backups). This handler exists so
// that an owner can record the intent in the audit log and so the mobile
// admin screen can point operators at the runbook.
type BackupHandler struct {
	cfg   *config.Config
	db    *pgxpool.Pool
	log   *zap.Logger
	audit *middleware.AuditService
}

func NewBackupHandler(cfg *config.Config, db *pgxpool.Pool, log *zap.Logger, audit *middleware.AuditService) *BackupHandler {
	return &BackupHandler{cfg: cfg, db: db, log: log, audit: audit}
}

// POST /api/v1/admin/backup — owner only (gated in router.go).
func (h *BackupHandler) Request(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if claims == nil {
		w.WriteHeader(http.StatusUnauthorized)
		return
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     "BACKUP_REQUESTED",
		EntityType: "business",
		EntityID:   bizID,
		IPAddress:  r.RemoteAddr,
		NewData:    map[string]string{"channel": "manual"},
	})

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusAccepted)
	_ = json.NewEncoder(w).Encode(map[string]interface{}{
		"status":  "logged",
		"message": "manual database backup must be performed via DBA tooling — see ops runbook",
		"runbook": "docs/admin/backup_runbook.md",
	})
}
