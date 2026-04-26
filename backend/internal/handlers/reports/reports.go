package reports

import (
	"encoding/csv"
	"encoding/json"
	"fmt"
	"net/http"
	"time"

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

// ── Dashboard ─────────────────────────────────────────────────────

func (h *Handler) Dashboard(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())

	// ── Scalar KPIs ─────────────────────────────────────────────
	var jobsToday, jobsInProgress, pendingQuotes, overdueInvoices, activeWorkers, tasksDue int
	var revenueMonth, unpaidInvoices float64

	_ = h.db.QueryRow(r.Context(),
		`SELECT COUNT(*) FROM jobs
		 WHERE business_id=$1 AND DATE(scheduled_start AT TIME ZONE 'UTC')=CURRENT_DATE
		 AND status IN ('scheduled','in_progress')`, bizID,
	).Scan(&jobsToday)

	_ = h.db.QueryRow(r.Context(),
		`SELECT COUNT(*) FROM jobs WHERE business_id=$1 AND status='in_progress'`, bizID,
	).Scan(&jobsInProgress)

	_ = h.db.QueryRow(r.Context(),
		`SELECT COALESCE(SUM(total_amount),0) FROM invoices
		 WHERE business_id=$1 AND status='paid'
		 AND paid_at >= DATE_TRUNC('month', NOW())`, bizID,
	).Scan(&revenueMonth)

	_ = h.db.QueryRow(r.Context(),
		`SELECT COUNT(*) FROM quotes WHERE business_id=$1 AND status='sent'`, bizID,
	).Scan(&pendingQuotes)

	_ = h.db.QueryRow(r.Context(),
		`SELECT COALESCE(SUM(amount_due),0) FROM invoices
		 WHERE business_id=$1 AND status IN ('sent','overdue','partial')`, bizID,
	).Scan(&unpaidInvoices)

	_ = h.db.QueryRow(r.Context(),
		`SELECT COUNT(*) FROM invoices WHERE business_id=$1 AND status='overdue'`, bizID,
	).Scan(&overdueInvoices)

	_ = h.db.QueryRow(r.Context(),
		`SELECT COUNT(*) FROM users WHERE business_id=$1 AND role!='customer' AND is_active=true AND deleted_at IS NULL`, bizID,
	).Scan(&activeWorkers)

	_ = h.db.QueryRow(r.Context(),
		`SELECT COUNT(*) FROM tasks WHERE business_id=$1 AND status='pending' AND due_date <= NOW() + INTERVAL '24 hours'`, bizID,
	).Scan(&tasksDue)

	// ── Revenue trend — last 6 months ───────────────────────────
	revRows, _ := h.db.Query(r.Context(),
		`SELECT TO_CHAR(DATE_TRUNC('month', paid_at), 'Mon') AS month,
		        COALESCE(SUM(total_amount), 0) AS revenue
		 FROM invoices
		 WHERE business_id=$1 AND status='paid'
		   AND paid_at >= DATE_TRUNC('month', NOW()) - INTERVAL '5 months'
		 GROUP BY DATE_TRUNC('month', paid_at)
		 ORDER BY DATE_TRUNC('month', paid_at)`, bizID)
	defer revRows.Close()
	revTrend := make([]map[string]interface{}, 0, 6)
	for revRows.Next() {
		var month string
		var revenue float64
		_ = revRows.Scan(&month, &revenue)
		revTrend = append(revTrend, map[string]interface{}{"month": month, "revenue": revenue})
	}

	// ── Jobs trend — last 7 days ─────────────────────────────────
	jobRows, _ := h.db.Query(r.Context(),
		`SELECT TO_CHAR(day, 'Dy') AS label, COALESCE(cnt, 0) AS count
		 FROM generate_series(
		        CURRENT_DATE - INTERVAL '6 days',
		        CURRENT_DATE,
		        '1 day'::interval
		      ) AS day
		 LEFT JOIN (
		   SELECT DATE(scheduled_start AT TIME ZONE 'UTC') AS d, COUNT(*) AS cnt
		   FROM jobs WHERE business_id=$1
		     AND scheduled_start >= NOW() - INTERVAL '7 days'
		   GROUP BY d
		 ) j ON j.d = day::date
		 ORDER BY day`, bizID)
	defer jobRows.Close()
	jobsTrend := make([]map[string]interface{}, 0, 7)
	for jobRows.Next() {
		var label string
		var count int
		_ = jobRows.Scan(&label, &count)
		jobsTrend = append(jobsTrend, map[string]interface{}{"day": label, "count": count})
	}

	// ── Today's jobs ─────────────────────────────────────────────
	todayRows, _ := h.db.Query(r.Context(),
		`SELECT j.id, j.title, j.status,
		        TO_CHAR(j.scheduled_start AT TIME ZONE 'UTC', 'HH12:MI AM') AS time,
		        c.first_name || ' ' || c.last_name AS customer,
		        j.address_line1 || COALESCE(', ' || j.city, '') AS address,
		        u.first_name || ' ' || u.last_name AS worker
		 FROM jobs j
		 LEFT JOIN customers c ON c.id=j.customer_id
		 LEFT JOIN job_assignments ja ON ja.job_id=j.id AND ja.is_primary=true
		 LEFT JOIN users u ON u.id=ja.user_id
		 WHERE j.business_id=$1
		   AND DATE(j.scheduled_start AT TIME ZONE 'UTC')=CURRENT_DATE
		 ORDER BY j.scheduled_start
		 LIMIT 10`, bizID)
	defer todayRows.Close()
	todayJobs := make([]map[string]interface{}, 0, 10)
	for todayRows.Next() {
		var id, title, status, t, customer, address, worker interface{}
		_ = todayRows.Scan(&id, &title, &status, &t, &customer, &address, &worker)
		todayJobs = append(todayJobs, map[string]interface{}{
			"id": id, "title": title, "status": status,
			"time": t, "customer": customer, "address": address, "worker": worker,
		})
	}

	// ── Pending tasks ────────────────────────────────────────────
	taskRows, _ := h.db.Query(r.Context(),
		`SELECT id, title, priority,
		        TO_CHAR(due_date AT TIME ZONE 'UTC', 'DD Mon') AS due,
		        due_date < NOW() AS overdue
		 FROM tasks
		 WHERE business_id=$1 AND status='pending'
		 ORDER BY
		   CASE priority WHEN 'urgent' THEN 1 WHEN 'high' THEN 2 WHEN 'medium' THEN 3 ELSE 4 END,
		   due_date NULLS LAST
		 LIMIT 5`, bizID)
	defer taskRows.Close()
	pendingTasks := make([]map[string]interface{}, 0, 5)
	for taskRows.Next() {
		var id, title, priority, due interface{}
		var overdue bool
		_ = taskRows.Scan(&id, &title, &priority, &due, &overdue)
		pendingTasks = append(pendingTasks, map[string]interface{}{
			"id": id, "title": title, "priority": priority, "due": due, "overdue": overdue,
		})
	}

	// ── Recent activity ──────────────────────────────────────────
	actRows, _ := h.db.Query(r.Context(),
		`SELECT al.id, al.user_id,
		        u.first_name || ' ' || u.last_name AS user_name,
		        al.action, al.entity_type, al.entity_id, al.created_at
		 FROM audit_logs al
		 LEFT JOIN users u ON u.id=al.user_id
		 WHERE al.business_id=$1
		 ORDER BY al.created_at DESC
		 LIMIT 15`, bizID)
	defer actRows.Close()
	activity := make([]map[string]interface{}, 0, 15)
	for actRows.Next() {
		var id, userID, userName, action, entityType, entityID interface{}
		var createdAt time.Time
		_ = actRows.Scan(&id, &userID, &userName, &action, &entityType, &entityID, &createdAt)
		activity = append(activity, map[string]interface{}{
			"id": id, "user_id": userID, "user_name": userName,
			"action": action, "entity_type": entityType, "entity_id": entityID,
			"created_at": createdAt,
		})
	}

	respond(w, 200, map[string]interface{}{
		// KPIs
		"jobs_today":       jobsToday,
		"jobs_in_progress": jobsInProgress,
		"revenue_month":    revenueMonth,
		"pending_quotes":   pendingQuotes,
		"unpaid_invoices":  unpaidInvoices,
		"overdue_invoices": overdueInvoices,
		"active_workers":   activeWorkers,
		"tasks_due":        tasksDue,
		// Trends
		"revenue_trend": revTrend,
		"jobs_trend":    jobsTrend,
		// Lists
		"today_jobs":    todayJobs,
		"pending_tasks": pendingTasks,
		"activity":      activity,
	})
}

// ── Revenue report ────────────────────────────────────────────────

func (h *Handler) Revenue(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	period := r.URL.Query().Get("period")
	if period == "" {
		period = "month"
	}

	var interval string
	var groupBy string
	switch period {
	case "week":
		interval = "7 days"
		groupBy = "TO_CHAR(paid_at, 'Dy')"
	case "year":
		interval = "12 months"
		groupBy = "TO_CHAR(DATE_TRUNC('month', paid_at), 'Mon YYYY')"
	default:
		interval = "1 month"
		groupBy = "TO_CHAR(DATE_TRUNC('week', paid_at), 'DD Mon')"
	}

	rows, _ := h.db.Query(r.Context(),
		`SELECT `+groupBy+` AS label, COALESCE(SUM(total_amount),0) AS revenue
		 FROM invoices
		 WHERE business_id=$1 AND status='paid' AND paid_at >= NOW() - INTERVAL '`+interval+`'
		 GROUP BY 1 ORDER BY MIN(paid_at)`, bizID)
	defer rows.Close()

	data := make([]map[string]interface{}, 0)
	for rows.Next() {
		var label string
		var revenue float64
		_ = rows.Scan(&label, &revenue)
		data = append(data, map[string]interface{}{"label": label, "revenue": revenue})
	}

	var total float64
	_ = h.db.QueryRow(r.Context(),
		`SELECT COALESCE(SUM(total_amount),0) FROM invoices
		 WHERE business_id=$1 AND status='paid' AND paid_at >= NOW() - INTERVAL '`+interval+`'`, bizID,
	).Scan(&total)

	respond(w, 200, map[string]interface{}{"data": data, "total": total, "period": period})
}

// ── Jobs report ───────────────────────────────────────────────────

func (h *Handler) Jobs(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())

	rows, _ := h.db.Query(r.Context(),
		`SELECT status, COUNT(*) FROM jobs WHERE business_id=$1 GROUP BY status`, bizID)
	defer rows.Close()

	byStatus := make(map[string]int)
	for rows.Next() {
		var status string
		var count int
		_ = rows.Scan(&status, &count)
		byStatus[status] = count
	}

	// Completion rate last 30 days
	var completed, total30 int
	_ = h.db.QueryRow(r.Context(),
		`SELECT
		   SUM(CASE WHEN status='completed' THEN 1 ELSE 0 END),
		   COUNT(*)
		 FROM jobs WHERE business_id=$1 AND created_at >= NOW() - INTERVAL '30 days'`, bizID,
	).Scan(&completed, &total30)

	rate := 0.0
	if total30 > 0 {
		rate = float64(completed) / float64(total30) * 100
	}

	respond(w, 200, map[string]interface{}{
		"by_status":        byStatus,
		"completion_rate":  rate,
		"completed_30d":    completed,
		"total_30d":        total30,
	})
}

// ── Worker performance ────────────────────────────────────────────

func (h *Handler) WorkerPerformance(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	rows, _ := h.db.Query(r.Context(),
		`SELECT u.id, u.first_name||' '||u.last_name AS name,
		        COUNT(ja.job_id) AS jobs_assigned,
		        SUM(CASE WHEN j.status='completed' THEN 1 ELSE 0 END) AS jobs_completed,
		        COALESCE(AVG(EXTRACT(EPOCH FROM (j.completed_at - j.scheduled_start))/3600), 0) AS avg_hours
		 FROM users u
		 LEFT JOIN job_assignments ja ON ja.user_id=u.id
		 LEFT JOIN jobs j ON j.id=ja.job_id AND j.created_at >= NOW() - INTERVAL '30 days'
		 WHERE u.business_id=$1 AND u.role IN ('worker','admin','manager')
		   AND u.deleted_at IS NULL
		 GROUP BY u.id, u.first_name, u.last_name
		 ORDER BY jobs_completed DESC
		 LIMIT 20`, bizID)
	defer rows.Close()

	workers := make([]map[string]interface{}, 0)
	for rows.Next() {
		var id, name interface{}
		var assigned, completed int
		var avgHours float64
		_ = rows.Scan(&id, &name, &assigned, &completed, &avgHours)
		workers = append(workers, map[string]interface{}{
			"id": id, "name": name,
			"jobs_assigned": assigned, "jobs_completed": completed,
			"avg_hours": avgHours,
		})
	}
	respond(w, 200, workers)
}

// ── Unpaid invoices ───────────────────────────────────────────────

func (h *Handler) UnpaidInvoices(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	rows, _ := h.db.Query(r.Context(),
		`SELECT i.id, i.invoice_number, c.first_name||' '||c.last_name AS customer,
		        i.amount_due, i.due_date,
		        CASE WHEN i.due_date < NOW() THEN true ELSE false END AS is_overdue,
		        EXTRACT(DAY FROM NOW()-i.due_date)::int AS days_overdue
		 FROM invoices i
		 LEFT JOIN customers c ON c.id=i.customer_id
		 WHERE i.business_id=$1 AND i.status IN ('sent','overdue','partial')
		 ORDER BY i.due_date ASC
		 LIMIT 50`, bizID)
	defer rows.Close()

	var list []map[string]interface{}
	for rows.Next() {
		var id, num, customer interface{}
		var amount float64
		var dueDate interface{}
		var overdue bool
		var daysOverdue int
		_ = rows.Scan(&id, &num, &customer, &amount, &dueDate, &overdue, &daysOverdue)
		list = append(list, map[string]interface{}{
			"id": id, "invoice_number": num, "customer": customer,
			"amount_due": amount, "due_date": dueDate,
			"is_overdue": overdue, "days_overdue": daysOverdue,
		})
	}
	if list == nil {
		list = []map[string]interface{}{}
	}
	respond(w, 200, list)
}

// ── Customer retention ────────────────────────────────────────────

func (h *Handler) CustomerRetention(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	var total, returning int
	_ = h.db.QueryRow(r.Context(),
		`SELECT COUNT(DISTINCT customer_id),
		        SUM(CASE WHEN job_count > 1 THEN 1 ELSE 0 END)
		 FROM (
		   SELECT customer_id, COUNT(*) AS job_count
		   FROM jobs WHERE business_id=$1 AND status='completed'
		   GROUP BY customer_id
		 ) t`, bizID,
	).Scan(&total, &returning)
	rate := 0.0
	if total > 0 {
		rate = float64(returning) / float64(total) * 100
	}
	respond(w, 200, map[string]interface{}{"total_customers": total, "returning": returning, "retention_rate": rate})
}

// ── Income vs Expense ─────────────────────────────────────────────

func (h *Handler) IncomeExpense(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())

	rows, _ := h.db.Query(r.Context(),
		`SELECT TO_CHAR(DATE_TRUNC('month', m), 'Mon') AS month,
		        COALESCE(income, 0) AS income,
		        COALESCE(expense, 0) AS expense
		 FROM generate_series(
		   DATE_TRUNC('month', NOW()) - INTERVAL '5 months',
		   DATE_TRUNC('month', NOW()),
		   '1 month'::interval
		 ) AS m
		 LEFT JOIN (
		   SELECT DATE_TRUNC('month', paid_at) AS mo, SUM(total_amount) AS income
		   FROM invoices WHERE business_id=$1 AND status='paid'
		   GROUP BY mo
		 ) i ON i.mo=m
		 LEFT JOIN (
		   SELECT DATE_TRUNC('month', date) AS mo, SUM(amount) AS expense
		   FROM expenses WHERE business_id=$1
		   GROUP BY mo
		 ) e ON e.mo=m
		 ORDER BY m`, bizID)
	defer rows.Close()

	data := make([]map[string]interface{}, 0)
	for rows.Next() {
		var month string
		var income, expense float64
		_ = rows.Scan(&month, &income, &expense)
		data = append(data, map[string]interface{}{"month": month, "income": income, "expense": expense, "profit": income - expense})
	}
	respond(w, 200, data)
}

// ── GST / BAS ─────────────────────────────────────────────────────

func (h *Handler) GSTBAS(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	var gstCollected, gstPaid float64
	_ = h.db.QueryRow(r.Context(),
		`SELECT COALESCE(SUM(tax_amount),0) FROM invoices
		 WHERE business_id=$1 AND status='paid'
		   AND paid_at >= DATE_TRUNC('quarter', NOW())`, bizID,
	).Scan(&gstCollected)
	_ = h.db.QueryRow(r.Context(),
		`SELECT COALESCE(SUM(tax_amount),0) FROM expenses
		 WHERE business_id=$1 AND date >= DATE_TRUNC('quarter', NOW())`, bizID,
	).Scan(&gstPaid)
	respond(w, 200, map[string]interface{}{
		"gst_collected": gstCollected,
		"gst_paid":      gstPaid,
		"gst_owing":     gstCollected - gstPaid,
		"quarter":       quarterLabel(),
	})
}

func (h *Handler) QuarterlyTax(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	var income, expense float64
	_ = h.db.QueryRow(r.Context(),
		`SELECT COALESCE(SUM(total_amount),0) FROM invoices
		 WHERE business_id=$1 AND status='paid' AND paid_at >= DATE_TRUNC('quarter', NOW())`, bizID,
	).Scan(&income)
	_ = h.db.QueryRow(r.Context(),
		`SELECT COALESCE(SUM(amount),0) FROM expenses
		 WHERE business_id=$1 AND date >= DATE_TRUNC('quarter', NOW())`, bizID,
	).Scan(&expense)
	respond(w, 200, map[string]interface{}{
		"income": income, "expense": expense, "profit": income - expense,
		"estimated_tax": (income - expense) * 0.275,
	})
}

// ── ExportCSV ─────────────────────────────────────────────────────

func (h *Handler) ExportCSV(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	exportType := r.URL.Query().Get("type")
	start := r.URL.Query().Get("start")
	end := r.URL.Query().Get("end")
	if end == "" {
		end = time.Now().Format("2006-01-02")
	}
	if start == "" {
		start = time.Now().AddDate(0, -1, 0).Format("2006-01-02")
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     "REPORT_EXPORT_CSV",
		EntityType: "report",
		NewData:    map[string]interface{}{"type": exportType, "start": start, "end": end},
	})

	w.Header().Set("Content-Type", "text/csv; charset=utf-8")
	w.Header().Set("Content-Disposition", `attachment; filename="`+exportType+`_export.csv"`)

	cw := csv.NewWriter(w)
	defer cw.Flush()

	switch exportType {
	case "invoices":
		_ = cw.Write([]string{"invoice_number", "customer", "status", "total_amount", "amount_paid", "amount_due", "due_date", "paid_at"})
		rows, err := h.db.Query(r.Context(),
			`SELECT i.invoice_number,
			        c.first_name||' '||COALESCE(c.last_name,'') AS customer,
			        i.status,
			        i.total_amount, i.amount_paid, i.amount_due,
			        COALESCE(i.due_date::text,''), COALESCE(i.paid_at::text,'')
			 FROM invoices i
			 LEFT JOIN customers c ON c.id=i.customer_id
			 WHERE i.business_id=$1
			   AND i.created_at BETWEEN $2::date AND $3::date
			   AND i.deleted_at IS NULL
			 ORDER BY i.created_at DESC
			 LIMIT 5000`, bizID, start, end)
		if err != nil {
			h.log.Error("export_csv invoices query", zap.Error(err))
			return
		}
		defer rows.Close()
		for rows.Next() {
			var num, customer, status, dueDate, paidAt string
			var total, paid, due float64
			if err := rows.Scan(&num, &customer, &status, &total, &paid, &due, &dueDate, &paidAt); err != nil {
				continue
			}
			_ = cw.Write([]string{
				num, customer, status,
				fmt.Sprintf("%.2f", total),
				fmt.Sprintf("%.2f", paid),
				fmt.Sprintf("%.2f", due),
				dueDate, paidAt,
			})
		}

	case "customers":
		_ = cw.Write([]string{"name", "company", "email", "phone", "source", "created_at", "total_jobs", "total_invoiced"})
		rows, err := h.db.Query(r.Context(),
			`SELECT c.first_name||' '||COALESCE(c.last_name,'') AS name,
			        COALESCE(c.company_name,''),
			        COALESCE(c.email,''), COALESCE(c.phone,''),
			        COALESCE(c.source,''), c.created_at::text,
			        COUNT(DISTINCT j.id) AS total_jobs,
			        COALESCE(SUM(i.total_amount),0) AS total_invoiced
			 FROM customers c
			 LEFT JOIN jobs j ON j.customer_id=c.id AND j.deleted_at IS NULL
			 LEFT JOIN invoices i ON i.customer_id=c.id AND i.deleted_at IS NULL
			 WHERE c.business_id=$1 AND c.deleted_at IS NULL
			 GROUP BY c.id, c.first_name, c.last_name, c.company_name,
			          c.email, c.phone, c.source, c.created_at
			 ORDER BY total_jobs DESC
			 LIMIT 5000`, bizID)
		if err != nil {
			h.log.Error("export_csv customers query", zap.Error(err))
			return
		}
		defer rows.Close()
		for rows.Next() {
			var name, company, email, phone, source, createdAt string
			var totalJobs int
			var totalInvoiced float64
			if err := rows.Scan(&name, &company, &email, &phone, &source, &createdAt, &totalJobs, &totalInvoiced); err != nil {
				continue
			}
			_ = cw.Write([]string{
				name, company, email, phone, source, createdAt,
				fmt.Sprintf("%d", totalJobs),
				fmt.Sprintf("%.2f", totalInvoiced),
			})
		}

	default: // "jobs"
		_ = cw.Write([]string{"job_number", "title", "status", "priority", "customer", "scheduled_start", "completed_at", "worker"})
		rows, err := h.db.Query(r.Context(),
			`SELECT j.job_number, j.title, j.status, j.priority,
			        COALESCE(c.first_name||' '||COALESCE(c.last_name,''),'') AS customer,
			        COALESCE(j.scheduled_start::text,''),
			        COALESCE(j.actual_end::text,''),
			        COALESCE(u.first_name||' '||u.last_name,'') AS worker
			 FROM jobs j
			 LEFT JOIN customers c ON c.id=j.customer_id
			 LEFT JOIN job_assignments ja ON ja.job_id=j.id AND ja.is_primary=true
			 LEFT JOIN users u ON u.id=ja.user_id
			 WHERE j.business_id=$1
			   AND j.created_at BETWEEN $2::date AND $3::date
			   AND j.deleted_at IS NULL
			 ORDER BY j.created_at DESC
			 LIMIT 5000`, bizID, start, end)
		if err != nil {
			h.log.Error("export_csv jobs query", zap.Error(err))
			return
		}
		defer rows.Close()
		for rows.Next() {
			var jobNum, title, status, priority, customer, scheduledStart, completedAt, worker string
			if err := rows.Scan(&jobNum, &title, &status, &priority, &customer, &scheduledStart, &completedAt, &worker); err != nil {
				continue
			}
			_ = cw.Write([]string{jobNum, title, status, priority, customer, scheduledStart, completedAt, worker})
		}
	}
}

// ── ExportPDF ─────────────────────────────────────────────────────

func (h *Handler) ExportPDF(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	reportType := r.URL.Query().Get("type")

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     "REPORT_EXPORT_PDF",
		EntityType: "report",
		NewData:    map[string]interface{}{"type": reportType},
	})

	var data interface{}

	switch reportType {
	case "jobs":
		var byStatus map[string]int
		var completed, total30 int
		var rate float64

		rows, err := h.db.Query(r.Context(),
			`SELECT status, COUNT(*) FROM jobs WHERE business_id=$1 GROUP BY status`, bizID)
		if err == nil {
			byStatus = make(map[string]int)
			defer rows.Close()
			for rows.Next() {
				var s string
				var c int
				_ = rows.Scan(&s, &c)
				byStatus[s] = c
			}
		}
		_ = h.db.QueryRow(r.Context(),
			`SELECT
			   SUM(CASE WHEN status='completed' THEN 1 ELSE 0 END),
			   COUNT(*)
			 FROM jobs WHERE business_id=$1 AND created_at >= NOW() - INTERVAL '30 days'`, bizID,
		).Scan(&completed, &total30)
		if total30 > 0 {
			rate = float64(completed) / float64(total30) * 100
		}
		data = map[string]interface{}{
			"by_status":       byStatus,
			"completion_rate": rate,
			"completed_30d":   completed,
			"total_30d":       total30,
		}

	default: // "revenue"
		revRows, err := h.db.Query(r.Context(),
			`SELECT TO_CHAR(DATE_TRUNC('month', paid_at), 'Mon') AS month,
			        COALESCE(SUM(total_amount), 0) AS revenue
			 FROM invoices
			 WHERE business_id=$1 AND status='paid'
			   AND paid_at >= DATE_TRUNC('month', NOW()) - INTERVAL '11 months'
			 GROUP BY DATE_TRUNC('month', paid_at)
			 ORDER BY DATE_TRUNC('month', paid_at)`, bizID)
		if err == nil {
			defer revRows.Close()
			trend := make([]map[string]interface{}, 0, 12)
			for revRows.Next() {
				var month string
				var revenue float64
				_ = revRows.Scan(&month, &revenue)
				trend = append(trend, map[string]interface{}{"month": month, "revenue": revenue})
			}
			var total float64
			_ = h.db.QueryRow(r.Context(),
				`SELECT COALESCE(SUM(total_amount),0) FROM invoices
				 WHERE business_id=$1 AND status='paid'
				   AND paid_at >= DATE_TRUNC('year', NOW())`, bizID,
			).Scan(&total)
			data = map[string]interface{}{"trend": trend, "total_ytd": total}
		}
	}

	respond(w, 200, map[string]interface{}{
		"report_type":  reportType,
		"generated_at": time.Now(),
		"data":         data,
	})
}

// ── YearEnd ───────────────────────────────────────────────────────

func (h *Handler) YearEnd(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	yearStr := r.URL.Query().Get("year")
	if yearStr == "" {
		yearStr = fmt.Sprintf("%d", time.Now().Year())
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     "REPORT_EXPORT_YEAR_END",
		EntityType: "report",
		NewData:    map[string]interface{}{"year": yearStr},
	})

	var revenue, expenses float64
	var jobsCompleted, newCustomers int

	_ = h.db.QueryRow(r.Context(),
		`SELECT COALESCE(SUM(total_amount),0) FROM invoices
		 WHERE business_id=$1 AND status='paid'
		   AND EXTRACT(YEAR FROM paid_at) = $2::int`, bizID, yearStr,
	).Scan(&revenue)

	_ = h.db.QueryRow(r.Context(),
		`SELECT COALESCE(SUM(amount),0) FROM expenses
		 WHERE business_id=$1
		   AND EXTRACT(YEAR FROM date) = $2::int`, bizID, yearStr,
	).Scan(&expenses)

	_ = h.db.QueryRow(r.Context(),
		`SELECT COUNT(*) FROM jobs
		 WHERE business_id=$1 AND status='completed'
		   AND EXTRACT(YEAR FROM actual_end) = $2::int`, bizID, yearStr,
	).Scan(&jobsCompleted)

	_ = h.db.QueryRow(r.Context(),
		`SELECT COUNT(*) FROM customers
		 WHERE business_id=$1 AND deleted_at IS NULL
		   AND EXTRACT(YEAR FROM created_at) = $2::int`, bizID, yearStr,
	).Scan(&newCustomers)

	// Monthly breakdown
	monthlyRows, err := h.db.Query(r.Context(),
		`SELECT TO_CHAR(month, 'Mon') AS label,
		        COALESCE(inc.income, 0)   AS income,
		        COALESCE(exp.expense, 0)  AS expense
		 FROM generate_series(
		        ($2::text || '-01-01')::date,
		        ($2::text || '-12-01')::date,
		        '1 month'::interval
		      ) AS month
		 LEFT JOIN (
		   SELECT DATE_TRUNC('month', paid_at) AS mo, SUM(total_amount) AS income
		   FROM invoices
		   WHERE business_id=$1 AND status='paid'
		     AND EXTRACT(YEAR FROM paid_at) = $2::int
		   GROUP BY mo
		 ) inc ON inc.mo = month
		 LEFT JOIN (
		   SELECT DATE_TRUNC('month', date) AS mo, SUM(amount) AS expense
		   FROM expenses
		   WHERE business_id=$1
		     AND EXTRACT(YEAR FROM date) = $2::int
		   GROUP BY mo
		 ) exp ON exp.mo = month
		 ORDER BY month`, bizID, yearStr)

	monthly := make([]map[string]interface{}, 0, 12)
	if err == nil {
		defer monthlyRows.Close()
		for monthlyRows.Next() {
			var label string
			var income, expense float64
			_ = monthlyRows.Scan(&label, &income, &expense)
			monthly = append(monthly, map[string]interface{}{
				"label":   label,
				"income":  income,
				"expense": expense,
				"profit":  income - expense,
			})
		}
	}

	respond(w, 200, map[string]interface{}{
		"year":           yearStr,
		"revenue":        revenue,
		"expenses":       expenses,
		"profit":         revenue - expenses,
		"jobs_completed": jobsCompleted,
		"new_customers":  newCustomers,
		"monthly":        monthly,
	})
}

// ── Helpers ───────────────────────────────────────────────────────

func respond(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if data != nil {
		json.NewEncoder(w).Encode(data)
	}
}

func quarterLabel() string {
	m := time.Now().Month()
	switch {
	case m <= 3:
		return "Q3 (Jan-Mar)"
	case m <= 6:
		return "Q4 (Apr-Jun)"
	case m <= 9:
		return "Q1 (Jul-Sep)"
	default:
		return "Q2 (Oct-Dec)"
	}
}
