package search

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"

	"github.com/jackc/pgx/v5/pgxpool"
	"go.uber.org/zap"

	"github.com/tradie/api/internal/config"
	"github.com/tradie/api/internal/middleware"
)

type Handler struct {
	cfg *config.Config
	db  *pgxpool.Pool
	log *zap.Logger
}

func NewHandler(cfg *config.Config, db *pgxpool.Pool, log *zap.Logger) *Handler {
	return &Handler{cfg: cfg, db: db, log: log}
}

// SearchResult is a single matched record returned to the client.
type SearchResult struct {
	Type     string `json:"type"`
	ID       string `json:"id"`
	Title    string `json:"title"`
	Subtitle string `json:"subtitle"`
	Status   string `json:"status,omitempty"`
	URL      string `json:"url"`
}

// typeSet builds a set from the comma-separated ?types= query param.
// An empty types param means "all".
func typeSet(raw string) map[string]bool {
	if raw == "" {
		return nil // nil == all types
	}
	m := make(map[string]bool)
	for _, t := range strings.Split(raw, ",") {
		m[strings.TrimSpace(t)] = true
	}
	return m
}

func wantType(set map[string]bool, t string) bool {
	if set == nil {
		return true
	}
	return set[t]
}

// Search handles GET /api/v1/search?q=<query>&types=jobs,customers,invoices,quotes,workers
func (h *Handler) Search(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())

	q := strings.TrimSpace(r.URL.Query().Get("q"))
	if len(q) < 2 {
		respond(w, 200, map[string]interface{}{
			"results": []SearchResult{},
			"total":   0,
		})
		return
	}

	types := typeSet(r.URL.Query().Get("types"))
	like := "%" + q + "%"
	ctx := r.Context()

	var results []SearchResult

	// ── Customers ─────────────────────────────────────────────────
	if wantType(types, "customers") {
		rows, err := h.db.Query(ctx, `
			SELECT id,
			       COALESCE(first_name||' '||COALESCE(last_name,''), COALESCE(company_name, '')) AS title,
			       COALESCE(email, '') AS subtitle,
			       ''
			FROM customers
			WHERE business_id=$1
			  AND deleted_at IS NULL
			  AND (
			        (first_name||' '||COALESCE(last_name,'')) ILIKE $2
			        OR COALESCE(company_name,'') ILIKE $2
			        OR COALESCE(email,'') ILIKE $2
			      )
			ORDER BY created_at DESC
			LIMIT 5`,
			bizID, like,
		)
		if err != nil {
			h.log.Error("search.customers", zap.Error(err))
		} else {
			for rows.Next() {
				var id, title, subtitle, status string
				if err := rows.Scan(&id, &title, &subtitle, &status); err == nil {
					results = append(results, SearchResult{
						Type:     "customers",
						ID:       id,
						Title:    title,
						Subtitle: subtitle,
						Status:   status,
						URL:      fmt.Sprintf("/customers/%s", id),
					})
				}
			}
			rows.Close()
		}
	}

	// ── Jobs ──────────────────────────────────────────────────────
	if wantType(types, "jobs") {
		rows, err := h.db.Query(ctx, `
			SELECT j.id,
			       COALESCE(j.title, j.job_number) AS title,
			       j.job_number AS subtitle,
			       j.status
			FROM jobs j
			WHERE j.business_id=$1
			  AND j.deleted_at IS NULL
			  AND (
			        j.title ILIKE $2
			        OR j.job_number ILIKE $2
			        OR COALESCE(j.description,'') ILIKE $2
			      )
			ORDER BY j.created_at DESC
			LIMIT 5`,
			bizID, like,
		)
		if err != nil {
			h.log.Error("search.jobs", zap.Error(err))
		} else {
			for rows.Next() {
				var id, title, subtitle, status string
				if err := rows.Scan(&id, &title, &subtitle, &status); err == nil {
					results = append(results, SearchResult{
						Type:     "jobs",
						ID:       id,
						Title:    title,
						Subtitle: subtitle,
						Status:   status,
						URL:      fmt.Sprintf("/jobs/%s", id),
					})
				}
			}
			rows.Close()
		}
	}

	// ── Invoices ──────────────────────────────────────────────────
	if wantType(types, "invoices") {
		rows, err := h.db.Query(ctx, `
			SELECT i.id,
			       i.invoice_number AS title,
			       COALESCE(c.first_name||' '||COALESCE(c.last_name,''), '') AS subtitle,
			       i.status
			FROM invoices i
			LEFT JOIN customers c ON c.id=i.customer_id
			WHERE i.business_id=$1
			  AND i.deleted_at IS NULL
			  AND (
			        i.invoice_number ILIKE $2
			        OR (c.first_name||' '||COALESCE(c.last_name,'')) ILIKE $2
			      )
			ORDER BY i.created_at DESC
			LIMIT 5`,
			bizID, like,
		)
		if err != nil {
			h.log.Error("search.invoices", zap.Error(err))
		} else {
			for rows.Next() {
				var id, title, subtitle, status string
				if err := rows.Scan(&id, &title, &subtitle, &status); err == nil {
					results = append(results, SearchResult{
						Type:     "invoices",
						ID:       id,
						Title:    title,
						Subtitle: subtitle,
						Status:   status,
						URL:      fmt.Sprintf("/invoices/%s", id),
					})
				}
			}
			rows.Close()
		}
	}

	// ── Quotes ────────────────────────────────────────────────────
	if wantType(types, "quotes") {
		rows, err := h.db.Query(ctx, `
			SELECT id,
			       COALESCE(title, quote_number) AS title,
			       quote_number AS subtitle,
			       status
			FROM quotes
			WHERE business_id=$1
			  AND deleted_at IS NULL
			  AND (
			        quote_number ILIKE $2
			        OR COALESCE(title,'') ILIKE $2
			      )
			ORDER BY created_at DESC
			LIMIT 5`,
			bizID, like,
		)
		if err != nil {
			h.log.Error("search.quotes", zap.Error(err))
		} else {
			for rows.Next() {
				var id, title, subtitle, status string
				if err := rows.Scan(&id, &title, &subtitle, &status); err == nil {
					results = append(results, SearchResult{
						Type:     "quotes",
						ID:       id,
						Title:    title,
						Subtitle: subtitle,
						Status:   status,
						URL:      fmt.Sprintf("/quotes/%s", id),
					})
				}
			}
			rows.Close()
		}
	}

	// ── Workers ───────────────────────────────────────────────────
	if wantType(types, "workers") {
		rows, err := h.db.Query(ctx, `
			SELECT id,
			       first_name||' '||COALESCE(last_name,'') AS title,
			       COALESCE(email, '') AS subtitle,
			       COALESCE(role, '') AS status
			FROM workers
			WHERE business_id=$1
			  AND deleted_at IS NULL
			  AND role != 'customer'
			  AND (first_name||' '||COALESCE(last_name,'')) ILIKE $2
			ORDER BY created_at DESC
			LIMIT 5`,
			bizID, like,
		)
		if err != nil {
			h.log.Error("search.workers", zap.Error(err))
		} else {
			for rows.Next() {
				var id, title, subtitle, status string
				if err := rows.Scan(&id, &title, &subtitle, &status); err == nil {
					results = append(results, SearchResult{
						Type:     "workers",
						ID:       id,
						Title:    title,
						Subtitle: subtitle,
						Status:   status,
						URL:      fmt.Sprintf("/workers/%s", id),
					})
				}
			}
			rows.Close()
		}
	}

	// Cap total at 25
	if len(results) > 25 {
		results = results[:25]
	}

	respond(w, 200, map[string]interface{}{
		"results": results,
		"total":   len(results),
	})
}

// ── helpers ────────────────────────────────────────────────────
func respond(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if data != nil {
		json.NewEncoder(w).Encode(data)
	}
}
