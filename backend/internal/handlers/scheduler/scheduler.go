package scheduler

import (
	"encoding/json"
	"math"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"

	"github.com/tradie/api/internal/config"
	"github.com/tradie/api/internal/middleware"
)

type Handler struct {
	cfg *config.Config
	db  *pgxpool.Pool
	rdb *redis.Client
	log *zap.Logger
}

func NewHandler(cfg *config.Config, db *pgxpool.Pool, rdb *redis.Client, log *zap.Logger) *Handler {
	return &Handler{cfg: cfg, db: db, rdb: rdb, log: log}
}

func respond(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if data != nil {
		json.NewEncoder(w).Encode(data)
	}
}

// haversineKm calculates the great-circle distance in kilometres between two lat/lng points.
func haversineKm(lat1, lng1, lat2, lng2 float64) float64 {
	const R = 6371.0
	dLat := (lat2 - lat1) * math.Pi / 180
	dLng := (lng2 - lng1) * math.Pi / 180
	a := math.Sin(dLat/2)*math.Sin(dLat/2) +
		math.Cos(lat1*math.Pi/180)*math.Cos(lat2*math.Pi/180)*
			math.Sin(dLng/2)*math.Sin(dLng/2)
	return R * 2 * math.Atan2(math.Sqrt(a), math.Sqrt(1-a))
}

// ─── CheckConflicts ──────────────────────────────────────────────────────────
// GET /api/v1/scheduler/conflicts?worker_id=UUID&start=RFC3339&end=RFC3339
//
// Returns whether a worker has any active job assignments that overlap the
// requested window.
func (h *Handler) CheckConflicts(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	q := r.URL.Query()

	workerID := q.Get("worker_id")
	startStr := q.Get("start")
	endStr := q.Get("end")

	if workerID == "" || startStr == "" || endStr == "" {
		respond(w, 400, map[string]string{"error": "worker_id, start and end are required"})
		return
	}

	start, err := time.Parse(time.RFC3339, startStr)
	if err != nil {
		respond(w, 400, map[string]string{"error": "invalid start time — use RFC3339"})
		return
	}
	end, err := time.Parse(time.RFC3339, endStr)
	if err != nil {
		respond(w, 400, map[string]string{"error": "invalid end time — use RFC3339"})
		return
	}

	rows, err := h.db.Query(r.Context(), `
		SELECT j.id, j.job_number, j.title, j.scheduled_start, j.scheduled_end,
		       c.first_name||' '||COALESCE(c.last_name,'') AS customer
		FROM jobs j
		LEFT JOIN job_assignments ja ON ja.job_id = j.id
		LEFT JOIN customers c ON c.id = j.customer_id
		WHERE ja.user_id = $1
		  AND j.business_id = $2
		  AND j.scheduled_end   > $3
		  AND j.scheduled_start < $4
		  AND j.status NOT IN ('cancelled','completed')
		  AND j.deleted_at IS NULL
	`, workerID, bizID, start, end)
	if err != nil {
		h.log.Error("check_conflicts query", zap.Error(err))
		respond(w, 500, map[string]string{"error": "server_error"})
		return
	}
	defer rows.Close()

	type conflict struct {
		ID             string  `json:"id"`
		JobNumber      string  `json:"job_number"`
		Title          string  `json:"title"`
		ScheduledStart *string `json:"scheduled_start"`
		ScheduledEnd   *string `json:"scheduled_end"`
		Customer       string  `json:"customer"`
	}

	var conflicts []conflict
	for rows.Next() {
		var c conflict
		var sStart, sEnd *time.Time
		if err := rows.Scan(&c.ID, &c.JobNumber, &c.Title, &sStart, &sEnd, &c.Customer); err != nil {
			continue
		}
		if sStart != nil {
			s := sStart.Format(time.RFC3339)
			c.ScheduledStart = &s
		}
		if sEnd != nil {
			e := sEnd.Format(time.RFC3339)
			c.ScheduledEnd = &e
		}
		conflicts = append(conflicts, c)
	}
	if conflicts == nil {
		conflicts = []conflict{}
	}

	respond(w, 200, map[string]interface{}{
		"has_conflicts": len(conflicts) > 0,
		"conflicts":     conflicts,
	})
}

// ─── DragDrop ────────────────────────────────────────────────────────────────
// POST /api/v1/scheduler/drag-drop
//
// Reschedules a job (and optionally re-assigns a worker) via a drag-and-drop
// action in the calendar UI.  Validates ownership, checks for worker conflicts,
// then commits the new schedule.
func (h *Handler) DragDrop(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())

	var req struct {
		JobID    string  `json:"job_id"`
		NewStart string  `json:"new_start"`
		NewEnd   string  `json:"new_end"`
		WorkerID *string `json:"worker_id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.JobID == "" || req.NewStart == "" || req.NewEnd == "" {
		respond(w, 400, map[string]string{"error": "job_id, new_start, and new_end are required"})
		return
	}

	newStart, err := time.Parse(time.RFC3339, req.NewStart)
	if err != nil {
		respond(w, 400, map[string]string{"error": "invalid new_start — use RFC3339"})
		return
	}
	newEnd, err := time.Parse(time.RFC3339, req.NewEnd)
	if err != nil {
		respond(w, 400, map[string]string{"error": "invalid new_end — use RFC3339"})
		return
	}

	// 1. Verify job belongs to this business.
	var exists bool
	_ = h.db.QueryRow(r.Context(),
		`SELECT EXISTS(SELECT 1 FROM jobs WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL)`,
		req.JobID, bizID,
	).Scan(&exists)
	if !exists {
		respond(w, 404, map[string]string{"error": "job_not_found"})
		return
	}

	// 2. If a worker_id was supplied, pre-flight conflict check.
	var conflictDetail interface{} = nil
	if req.WorkerID != nil && *req.WorkerID != "" {
		rows, err := h.db.Query(r.Context(), `
			SELECT j.id, j.job_number, j.title, j.scheduled_start, j.scheduled_end,
			       c.first_name||' '||COALESCE(c.last_name,'') AS customer
			FROM jobs j
			LEFT JOIN job_assignments ja ON ja.job_id = j.id
			LEFT JOIN customers c ON c.id = j.customer_id
			WHERE ja.user_id = $1
			  AND j.business_id = $2
			  AND j.id != $3
			  AND j.scheduled_end   > $4
			  AND j.scheduled_start < $5
			  AND j.status NOT IN ('cancelled','completed')
			  AND j.deleted_at IS NULL
		`, *req.WorkerID, bizID, req.JobID, newStart, newEnd)
		if err != nil {
			h.log.Error("drag_drop conflict check", zap.Error(err))
			respond(w, 500, map[string]string{"error": "server_error"})
			return
		}
		defer rows.Close()

		type cfItem struct {
			ID             string  `json:"id"`
			JobNumber      string  `json:"job_number"`
			Title          string  `json:"title"`
			ScheduledStart *string `json:"scheduled_start"`
			ScheduledEnd   *string `json:"scheduled_end"`
			Customer       string  `json:"customer"`
		}
		var cfList []cfItem
		for rows.Next() {
			var c cfItem
			var sStart, sEnd *time.Time
			if err := rows.Scan(&c.ID, &c.JobNumber, &c.Title, &sStart, &sEnd, &c.Customer); err != nil {
				continue
			}
			if sStart != nil {
				s := sStart.Format(time.RFC3339)
				c.ScheduledStart = &s
			}
			if sEnd != nil {
				e := sEnd.Format(time.RFC3339)
				c.ScheduledEnd = &e
			}
			cfList = append(cfList, c)
		}
		if len(cfList) > 0 {
			conflictDetail = cfList
		}
	}

	// 3. Update the job's scheduled window.
	type jobResult struct {
		ID             string  `json:"id"`
		JobNumber      string  `json:"job_number"`
		Title          string  `json:"title"`
		ScheduledStart *string `json:"scheduled_start"`
		ScheduledEnd   *string `json:"scheduled_end"`
		Status         string  `json:"status"`
	}

	var job jobResult
	var sStart, sEnd *time.Time
	err = h.db.QueryRow(r.Context(), `
		UPDATE jobs
		SET scheduled_start=$1, scheduled_end=$2, updated_at=NOW()
		WHERE id=$3 AND business_id=$4
		RETURNING id, job_number, title, scheduled_start, scheduled_end, status
	`, newStart, newEnd, req.JobID, bizID,
	).Scan(&job.ID, &job.JobNumber, &job.Title, &sStart, &sEnd, &job.Status)
	if err != nil {
		h.log.Error("drag_drop update", zap.Error(err))
		respond(w, 500, map[string]string{"error": "server_error"})
		return
	}
	if sStart != nil {
		s := sStart.Format(time.RFC3339)
		job.ScheduledStart = &s
	}
	if sEnd != nil {
		e := sEnd.Format(time.RFC3339)
		job.ScheduledEnd = &e
	}

	// 4. Upsert worker assignment only when there is no conflict.
	if req.WorkerID != nil && *req.WorkerID != "" && conflictDetail == nil {
		_, _ = h.db.Exec(r.Context(), `
			INSERT INTO job_assignments (job_id, business_id, user_id)
			VALUES ($1, $2, $3)
			ON CONFLICT (job_id, user_id) DO NOTHING
		`, req.JobID, bizID, *req.WorkerID)
	}

	respond(w, 200, map[string]interface{}{
		"job":      job,
		"conflict": conflictDetail,
	})
}

// ─── Route ───────────────────────────────────────────────────────────────────
// GET /api/v1/scheduler/route?date=YYYY-MM-DD&worker_id=UUID
//
// Returns all geo-tagged jobs for a given date, ordered by scheduled_start, so
// the mobile client can render a route map.
func (h *Handler) Route(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	q := r.URL.Query()

	dateStr := q.Get("date")
	if dateStr == "" {
		dateStr = time.Now().UTC().Format("2006-01-02")
	}

	// Validate date format.
	if _, err := time.Parse("2006-01-02", dateStr); err != nil {
		respond(w, 400, map[string]string{"error": "invalid date — use YYYY-MM-DD"})
		return
	}

	workerID := q.Get("worker_id")

	baseQuery := `
		SELECT j.id, j.job_number, j.title, j.lat, j.lng,
		       j.scheduled_start, j.scheduled_end, j.status,
		       j.address_line1, j.city,
		       c.first_name||' '||COALESCE(c.last_name,'') AS customer
		FROM jobs j
		LEFT JOIN customers c ON c.id = j.customer_id
	`

	var args []interface{}
	args = append(args, bizID, dateStr)

	whereClause := `
		WHERE j.business_id = $1
		  AND DATE(j.scheduled_start AT TIME ZONE 'UTC') = $2::date
		  AND j.lat IS NOT NULL
		  AND j.lng IS NOT NULL
		  AND j.deleted_at IS NULL
	`

	if workerID != "" {
		baseQuery += ` LEFT JOIN job_assignments ja ON ja.job_id = j.id `
		whereClause += ` AND ja.user_id = $3`
		args = append(args, workerID)
	}

	rows, err := h.db.Query(r.Context(), baseQuery+whereClause+` ORDER BY j.scheduled_start`, args...)
	if err != nil {
		h.log.Error("route query", zap.Error(err))
		respond(w, 500, map[string]string{"error": "server_error"})
		return
	}
	defer rows.Close()

	type waypoint struct {
		ID             string   `json:"id"`
		JobNumber      string   `json:"job_number"`
		Title          string   `json:"title"`
		Lat            *float64 `json:"lat"`
		Lng            *float64 `json:"lng"`
		ScheduledStart *string  `json:"scheduled_start"`
		ScheduledEnd   *string  `json:"scheduled_end"`
		Status         string   `json:"status"`
		AddressLine1   *string  `json:"address_line1"`
		City           *string  `json:"city"`
		Customer       string   `json:"customer"`
	}

	var waypoints []waypoint
	for rows.Next() {
		var wp waypoint
		var sStart, sEnd *time.Time
		if err := rows.Scan(
			&wp.ID, &wp.JobNumber, &wp.Title, &wp.Lat, &wp.Lng,
			&sStart, &sEnd, &wp.Status, &wp.AddressLine1, &wp.City, &wp.Customer,
		); err != nil {
			continue
		}
		if sStart != nil {
			s := sStart.Format(time.RFC3339)
			wp.ScheduledStart = &s
		}
		if sEnd != nil {
			e := sEnd.Format(time.RFC3339)
			wp.ScheduledEnd = &e
		}
		waypoints = append(waypoints, wp)
	}
	if waypoints == nil {
		waypoints = []waypoint{}
	}

	respond(w, 200, map[string]interface{}{
		"date":      dateStr,
		"waypoints": waypoints,
	})
}

// ─── ETA ─────────────────────────────────────────────────────────────────────
// GET /api/v1/scheduler/eta/{job_id}
//
// Estimates travel time for the assigned worker to reach the job site, using a
// straight-line Haversine distance at an assumed 50 km/h average speed.
func (h *Handler) ETA(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	jobID := chi.URLParam(r, "job_id")

	// 1. Fetch job location.
	var jobLat, jobLng *float64
	var jobTitle string
	err := h.db.QueryRow(r.Context(), `
		SELECT title, lat, lng
		FROM jobs
		WHERE id = $1 AND business_id = $2 AND deleted_at IS NULL
	`, jobID, bizID).Scan(&jobTitle, &jobLat, &jobLng)
	if err != nil {
		respond(w, 404, map[string]string{"error": "job_not_found"})
		return
	}
	if jobLat == nil || jobLng == nil {
		respond(w, 422, map[string]string{"error": "job_has_no_location"})
		return
	}

	// 2. Fetch the primary assigned worker's last known location.
	var workerLat, workerLng float64
	var workerID string
	err = h.db.QueryRow(r.Context(), `
		SELECT wl.user_id, wl.lat, wl.lng
		FROM worker_locations wl
		INNER JOIN job_assignments ja ON ja.user_id = wl.user_id
		WHERE ja.job_id = $1
		ORDER BY wl.recorded_at DESC
		LIMIT 1
	`, jobID).Scan(&workerID, &workerLat, &workerLng)
	if err != nil {
		respond(w, 404, map[string]string{"error": "worker_location_not_found"})
		return
	}

	// 3. Haversine + 50 km/h estimate.
	distKm := haversineKm(workerLat, workerLng, *jobLat, *jobLng)
	estimatedMinutes := int(math.Round(distKm / 50.0 * 60))

	respond(w, 200, map[string]interface{}{
		"job_id":            jobID,
		"estimated_minutes": estimatedMinutes,
		"distance_km":       math.Round(distKm*10) / 10,
		"worker_location": map[string]interface{}{
			"worker_id": workerID,
			"lat":       workerLat,
			"lng":       workerLng,
		},
		"job_location": map[string]interface{}{
			"lat":  *jobLat,
			"lng":  *jobLng,
			"name": jobTitle,
		},
	})
}
