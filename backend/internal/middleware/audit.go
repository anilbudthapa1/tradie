package middleware

import (
	"context"
	"net/http"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"go.uber.org/zap"
)

type AuditEntry struct {
	BusinessID uuid.UUID
	UserID     uuid.UUID
	Action     string
	EntityType string
	EntityID   uuid.UUID
	OldData    interface{}
	NewData    interface{}
	IPAddress  string
}

type AuditService struct {
	db  *pgxpool.Pool
	log *zap.Logger
}

func NewAuditService(db *pgxpool.Pool, log *zap.Logger) *AuditService {
	return &AuditService{db: db, log: log}
}

func (a *AuditService) Log(ctx context.Context, entry AuditEntry) {
	go func() {
		_, err := a.db.Exec(context.Background(),
			`INSERT INTO audit_logs (business_id, user_id, action, entity_type, entity_id, old_data, new_data, ip_address)
			 VALUES ($1, $2, $3, $4, $5, $6, $7, $8)`,
			entry.BusinessID, entry.UserID, entry.Action, entry.EntityType,
			entry.EntityID, entry.OldData, entry.NewData, entry.IPAddress,
		)
		if err != nil {
			a.log.Error("audit log failed", zap.Error(err))
		}
	}()
}

// RequestLogger logs every HTTP request (latency, status, path).
func RequestLogger(log *zap.Logger) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			start := time.Now()
			rw := &responseWriter{ResponseWriter: w, status: 200}
			next.ServeHTTP(rw, r)
			log.Info("request",
				zap.String("method", r.Method),
				zap.String("path", r.URL.Path),
				zap.Int("status", rw.status),
				zap.Duration("latency", time.Since(start)),
				zap.String("ip", r.RemoteAddr),
			)
		})
	}
}

type responseWriter struct {
	http.ResponseWriter
	status int
}

func (rw *responseWriter) WriteHeader(code int) {
	rw.status = code
	rw.ResponseWriter.WriteHeader(code)
}
