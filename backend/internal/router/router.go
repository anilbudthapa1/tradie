package router

import (
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	chimid "github.com/go-chi/chi/v5/middleware"
	"github.com/go-chi/cors"
	"github.com/go-chi/httprate"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"

	"github.com/tradie/api/internal/config"
	aihandler "github.com/tradie/api/internal/handlers/ai"
	"github.com/tradie/api/internal/handlers/auth"
	"github.com/tradie/api/internal/handlers/business"
	"github.com/tradie/api/internal/handlers/chat"
	"github.com/tradie/api/internal/handlers/customers"
	"github.com/tradie/api/internal/handlers/expenses"
	"github.com/tradie/api/internal/handlers/files"
	"github.com/tradie/api/internal/handlers/invoices"
	"github.com/tradie/api/internal/handlers/jobs"
	leadshandler "github.com/tradie/api/internal/handlers/leads"
	"github.com/tradie/api/internal/handlers/notifications"
	"github.com/tradie/api/internal/handlers/payments"
	"github.com/tradie/api/internal/handlers/quotes"
	"github.com/tradie/api/internal/handlers/reports"
	"github.com/tradie/api/internal/handlers/safety"
	"github.com/tradie/api/internal/handlers/tasks"
	"github.com/tradie/api/internal/handlers/scheduler"
	"github.com/tradie/api/internal/handlers/search"
	"github.com/tradie/api/internal/handlers/settings"
	"github.com/tradie/api/internal/handlers/subscription"
	"github.com/tradie/api/internal/handlers/workers"
	"github.com/tradie/api/internal/middleware"
	"github.com/tradie/api/internal/ws"
)

func New(cfg *config.Config, db *pgxpool.Pool, rdb *redis.Client, log *zap.Logger) http.Handler {
	r := chi.NewRouter()

	// ── Global middleware ────────────────────────────────────────
	r.Use(chimid.RealIP)
	r.Use(middleware.RequestLogger(log))
	r.Use(chimid.Recoverer)
	r.Use(chimid.Timeout(30 * time.Second))
	r.Use(cors.Handler(cors.Options{
		AllowedOrigins:   []string{cfg.FrontendURL, "http://localhost:3000", "http://localhost:3001"},
		AllowedMethods:   []string{"GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"},
		AllowedHeaders:   []string{"Accept", "Authorization", "Content-Type", "X-Business-ID"},
		AllowCredentials: true,
		MaxAge:           300,
	}))

	audit := middleware.NewAuditService(db, log)

	// ── Public routes ────────────────────────────────────────────
	r.Group(func(r chi.Router) {
		r.Use(httprate.LimitByIP(30, time.Minute))

		authH := auth.NewHandler(cfg, db, rdb, log, audit)
		r.Route("/api/v1/auth", func(r chi.Router) {
			r.Post("/register", authH.Register)
			r.Post("/login", authH.Login)
			r.Post("/refresh", authH.RefreshToken)
			r.Post("/forgot-password", authH.ForgotPassword)
			r.Post("/reset-password", authH.ResetPassword)
			r.Post("/verify-email", authH.VerifyEmail)
			r.Post("/mfa-login", authH.MFALogin)
			r.Post("/accept-invite", authH.AcceptInvite)
			r.Post("/passkey/begin-auth", authH.BeginPasskeyAuth)
			r.Post("/passkey/finish-auth", authH.FinishPasskeyAuth)
		})

		subH := subscription.NewHandler(cfg, db, rdb, log)
		r.Post("/api/v1/webhooks/stripe", subH.StripeWebhook)
	})

	// ── Authenticated routes ─────────────────────────────────────
	r.Group(func(r chi.Router) {
		r.Use(middleware.Auth(cfg.JWTSecret))
		r.Use(middleware.TenantGuard(db))

		// Auth management
		authH := auth.NewHandler(cfg, db, rdb, log, audit)
		r.Post("/api/v1/auth/logout", authH.Logout)
		r.Post("/api/v1/auth/mfa/enable", authH.EnableMFA)
		r.Post("/api/v1/auth/mfa/verify", authH.VerifyMFA)
		r.Post("/api/v1/auth/mfa/disable", authH.DisableMFA)
		r.Get("/api/v1/auth/sessions", authH.ListSessions)
		r.Delete("/api/v1/auth/sessions/{id}", authH.RevokeSession)
		r.Get("/api/v1/auth/me", authH.Me)
		r.Patch("/api/v1/auth/me", authH.UpdateMe)
		r.Post("/api/v1/auth/passkey/begin-register", authH.BeginPasskeyRegister)
		r.Post("/api/v1/auth/passkey/finish-register", authH.FinishPasskeyRegister)

		// Business — reads available to all roles; writes require admin+
		bizH := business.NewHandler(cfg, db, log, audit)
		r.Route("/api/v1/business", func(r chi.Router) {
			r.Get("/", bizH.Get)
			r.Get("/profile", bizH.GetProfile)
			r.Get("/settings", bizH.GetSettings)
			r.Get("/tax-settings", bizH.GetTaxSettings)
			r.Get("/invoice-settings", bizH.GetInvoiceSettings)
			r.Get("/payroll-settings", bizH.GetPayrollSettings)
			r.Get("/branding", bizH.GetBranding)
			r.Get("/compliance", bizH.GetCompliance)

			r.Group(func(r chi.Router) {
				r.Use(middleware.RequireOwnerOrAdmin())
				r.Put("/", bizH.Update)
				r.Patch("/", bizH.Update)
				r.Put("/profile", bizH.UpdateProfile)
				r.Patch("/profile", bizH.UpdateProfile)
				r.Put("/settings", bizH.UpdateSettings)
				r.Patch("/settings", bizH.UpdateSettings)
				r.Put("/tax-settings", bizH.UpdateTaxSettings)
				r.Patch("/tax-settings", bizH.UpdateTaxSettings)
				r.Put("/invoice-settings", bizH.UpdateInvoiceSettings)
				r.Patch("/invoice-settings", bizH.UpdateInvoiceSettings)
				r.Put("/payroll-settings", bizH.UpdatePayrollSettings)
				r.Patch("/payroll-settings", bizH.UpdatePayrollSettings)
				r.Put("/branding", bizH.UpdateBranding)
				r.Patch("/branding", bizH.UpdateBranding)
				r.Put("/compliance", bizH.UpdateCompliance)
				r.Patch("/compliance", bizH.UpdateCompliance)
			})
		})

		// Team / Workers
		workerH := workers.NewHandler(cfg, db, log, audit)
		r.Route("/api/v1/workers", func(r chi.Router) {
			// Self-service worker actions (any authenticated user)
			r.Post("/location", workerH.UpdateLocation)
			r.Post("/check-in", workerH.CheckIn)
			r.Post("/check-out", workerH.CheckOut)
			r.Post("/timesheets", workerH.CreateTimesheet)
			r.Put("/timesheets/{id}", workerH.UpdateTimesheet)
			r.Get("/timesheets", workerH.ListTimesheets)

			// Read access — manager+
			r.Group(func(r chi.Router) {
				r.Use(middleware.RequireAtLeast("manager"))
				r.Get("/", workerH.List)
				r.Get("/{id}", workerH.Get)
				r.Get("/{id}/timesheets", workerH.GetTimesheets)
				r.Get("/{id}/payslips", workerH.GetPayslips)
				r.Get("/{id}/availability", workerH.GetAvailability)
				r.Put("/{id}/availability", workerH.UpdateAvailability)
				r.Get("/{id}/performance", workerH.GetPerformance)
				r.Get("/{id}/location", workerH.GetLocation)
			})

			// Write access — admin+
			r.Group(func(r chi.Router) {
				r.Use(middleware.RequireOwnerOrAdmin())
				r.Post("/", workerH.Create)
				r.Put("/{id}", workerH.Update)
				r.Delete("/{id}", workerH.Delete)
				r.Post("/invite", workerH.Invite)
				r.Post("/timesheets/{id}/approve", workerH.ApproveTimesheet)
			})
		})

		// Customers
		custH := customers.NewHandler(cfg, db, log, audit)
		r.Route("/api/v1/customers", func(r chi.Router) {
			r.Get("/", custH.List)
			r.Post("/", custH.Create)
			r.Get("/{id}", custH.Get)
			r.Put("/{id}", custH.Update)
			r.Delete("/{id}", custH.Delete)
			r.Get("/{id}/addresses", custH.GetAddresses)
			r.Post("/{id}/addresses", custH.AddAddress)
			r.Put("/{id}/addresses/{aid}", custH.UpdateAddress)
			r.Delete("/{id}/addresses/{aid}", custH.DeleteAddress)
			r.Get("/{id}/contacts", custH.GetContacts)
			r.Post("/{id}/contacts", custH.AddContact)
			r.Get("/{id}/notes", custH.GetNotes)
			r.Post("/{id}/notes", custH.AddNote)
			r.Get("/{id}/jobs", custH.GetJobs)
			r.Get("/{id}/quotes", custH.GetQuotes)
			r.Get("/{id}/invoices", custH.GetInvoices)
		})

		// Jobs
		jobH := jobs.NewHandler(cfg, db, log, audit)
		r.Route("/api/v1/jobs", func(r chi.Router) {
			r.Get("/", jobH.List)
			r.Post("/", jobH.Create)
			r.Get("/{id}", jobH.Get)
			r.Put("/{id}", jobH.Update)
			r.Delete("/{id}", jobH.Delete)
			r.Post("/{id}/assign", jobH.Assign)
			r.Post("/{id}/status", jobH.UpdateStatus)
			r.Get("/{id}/notes", jobH.GetNotes)
			r.Post("/{id}/notes", jobH.AddNote)
			r.Get("/{id}/photos", jobH.GetPhotos)
			r.Post("/{id}/photos", jobH.UploadPhoto)
			r.Get("/{id}/materials", jobH.GetMaterials)
			r.Post("/{id}/materials", jobH.AddMaterial)
			r.Post("/{id}/complete", jobH.Complete)
			r.Post("/{id}/sign-off", jobH.SignOff)
			r.Get("/calendar", jobH.Calendar)
			r.Get("/schedule/daily", jobH.DailySchedule)
			r.Get("/schedule/weekly", jobH.WeeklySchedule)
		})

		// Scheduler
		schedH := scheduler.NewHandler(cfg, db, rdb, log)
		r.Route("/api/v1/scheduler", func(r chi.Router) {
			r.Get("/conflicts", schedH.CheckConflicts)
			r.Post("/drag-drop", schedH.DragDrop)
			r.Get("/route", schedH.Route)
			r.Get("/eta/{job_id}", schedH.ETA)
		})

		// Quotes
		quoteH := quotes.NewHandler(cfg, db, log, audit)
		r.Route("/api/v1/quotes", func(r chi.Router) {
			r.Get("/", quoteH.List)
			r.Post("/", quoteH.Create)
			r.Get("/{id}", quoteH.Get)
			r.Put("/{id}", quoteH.Update)
			r.Delete("/{id}", quoteH.Delete)
			r.Post("/{id}/send", quoteH.Send)
			r.Post("/{id}/convert", quoteH.ConvertToJob)
			r.Get("/{id}/pdf", quoteH.GeneratePDF)
			r.Get("/templates", quoteH.ListTemplates)
			r.Post("/templates", quoteH.CreateTemplate)
		})
		// Public quote approval (customer-facing, no auth)
		r.Get("/api/v1/public/quotes/{token}", quoteH.PublicGet)
		r.Post("/api/v1/public/quotes/{token}/approve", quoteH.PublicApprove)
		r.Post("/api/v1/public/quotes/{token}/reject", quoteH.PublicReject)

		// Global search
		searchH := search.NewHandler(cfg, db, log)
		r.Get("/api/v1/search", searchH.Search)

		// Invoices
		invH := invoices.NewHandler(cfg, db, log, audit)
		r.Route("/api/v1/invoices", func(r chi.Router) {
			r.Get("/", invH.List)
			r.Post("/", invH.Create)
			r.Get("/{id}", invH.Get)
			r.Put("/{id}", invH.Update)
			r.Delete("/{id}", invH.Delete)
			r.Post("/{id}/send", invH.Send)
			r.Get("/{id}/pdf", invH.GeneratePDF)
			r.Post("/{id}/payment", invH.RecordPayment)
			r.Post("/{id}/credit-note", invH.IssueCreditNote)
			r.Get("/{id}/receipt", invH.GetReceipt)
			r.Post("/{id}/payment-link", invH.CreatePaymentLink)
			// Recurring invoice rules
			r.Get("/recurring", invH.ListRecurringRules)
			r.Post("/recurring", invH.CreateRecurringRule)
			r.Delete("/recurring/{id}", invH.DeleteRecurringRule)
			// Internal: process due recurring invoices (restrict to admin/service role in production)
			r.Group(func(r chi.Router) {
				r.Use(middleware.RequireOwnerOrAdmin())
				r.Post("/recurring/process", invH.ProcessDueRecurring)
			})
		})

		// Payments
		payH := payments.NewHandler(cfg, db, log, audit)
		r.Route("/api/v1/payments", func(r chi.Router) {
			r.Get("/", payH.List)
			r.Get("/{id}", payH.Get)
		})

		// Expenses
		expH := expenses.NewHandler(cfg, db, log, audit)
		r.Route("/api/v1/expenses", func(r chi.Router) {
			r.Get("/", expH.List)
			r.Post("/", expH.Create)
			r.Get("/summary", expH.GetSummary)
			r.Get("/export/accountant", expH.ExportAccountant)
			r.Post("/scan-receipt", expH.ScanReceipt)
			r.Get("/{id}", expH.Get)
			r.Patch("/{id}", expH.Update)
			r.Put("/{id}", expH.Update)
			r.Delete("/{id}", expH.Delete)
		})

		// Payroll
		workerH.RegisterPayrollRoutes(r)

		// Safety
		safetyH := safety.NewHandler(cfg, db, log, audit)
		r.Route("/api/v1/safety", func(r chi.Router) {
			r.Get("/checklists", safetyH.ListChecklists)
			r.Post("/checklists", safetyH.CreateChecklist)
			r.Get("/checklists/{id}", safetyH.GetChecklist)
			r.Post("/checklists/{id}/complete", safetyH.CompleteChecklist)
			r.Get("/swms", safetyH.ListSWMS)
			r.Post("/swms", safetyH.CreateSWMS)
			r.Get("/swms/{id}", safetyH.GetSWMS)
			r.Get("/swms/{id}/pdf", safetyH.GenerateSWMSPDF)
			r.Get("/incidents", safetyH.ListIncidents)
			r.Post("/incidents", safetyH.CreateIncident)
			r.Get("/incidents/{id}", safetyH.GetIncident)
			r.Put("/incidents/{id}", safetyH.UpdateIncident)
			r.Get("/risk-assessments", safetyH.ListRiskAssessments)
			r.Post("/risk-assessments", safetyH.CreateRiskAssessment)
			r.Get("/compliance", safetyH.ListCompliance)
			r.Post("/compliance", safetyH.AddCompliance)
			r.Put("/compliance/{id}", safetyH.UpdateCompliance)
			r.Delete("/compliance/{id}", safetyH.DeleteCompliance)
			r.Get("/ppe/{job_id}", safetyH.GetPPEChecklist)
			r.Post("/ppe", safetyH.SubmitPPEChecklist)
		})

		// Tasks / Reminders
		taskH := tasks.NewHandler(cfg, db, log)
		r.Route("/api/v1/tasks", func(r chi.Router) {
			r.Get("/", taskH.List)
			r.Post("/", taskH.Create)
			r.Get("/{id}", taskH.Get)
			r.Put("/{id}", taskH.Update)
			r.Patch("/{id}", taskH.Update)
			r.Post("/{id}/complete", taskH.Complete)
			r.Delete("/{id}", taskH.Delete)
		})

		// Reports
		repH := reports.NewHandler(cfg, db, log)
		r.Route("/api/v1/reports", func(r chi.Router) {
			r.Get("/dashboard", repH.Dashboard)
			r.Get("/revenue", repH.Revenue)
			r.Get("/jobs", repH.Jobs)
			r.Get("/workers", repH.WorkerPerformance)
			r.Get("/unpaid-invoices", repH.UnpaidInvoices)
			r.Get("/customer-retention", repH.CustomerRetention)
			r.Get("/income-expense", repH.IncomeExpense)
			r.Get("/gst-bas", repH.GSTBAS)
			r.Get("/quarterly-tax", repH.QuarterlyTax)
			r.Get("/export/csv", repH.ExportCSV)
			r.Get("/export/pdf", repH.ExportPDF)
			r.Get("/export/year-end", repH.YearEnd)
		})

		// Notifications
		notifH := notifications.NewHandler(cfg, db, rdb, log)
		r.Route("/api/v1/notifications", func(r chi.Router) {
			r.Get("/", notifH.List)
			r.Post("/{id}/read", notifH.MarkRead)
			r.Post("/read-all", notifH.MarkAllRead)
			r.Get("/preferences", notifH.GetPreferences)
			r.Put("/preferences", notifH.UpdatePreferences)
			r.Patch("/preferences", notifH.UpdatePreferences)
			r.Get("/templates", notifH.ListTemplates)
			r.Put("/templates/{id}", notifH.UpdateTemplate)
			r.Get("/delivery-logs", notifH.DeliveryLogs)
		})

		// Subscription — reads available to all; billing actions owner only
		r.Route("/api/v1/subscription", func(r chi.Router) {
			subH := subscription.NewHandler(cfg, db, rdb, log)
			r.Get("/", subH.Get)
			r.Get("/usage", subH.Usage)
			r.Get("/plans", subH.ListPlans)

			r.Group(func(r chi.Router) {
				r.Use(middleware.RequireOwner())
				r.Post("/upgrade", subH.Upgrade)
				r.Post("/cancel", subH.Cancel)
			})
		})

		// Files
		fileH := files.NewHandler(cfg, db, log)
		r.Route("/api/v1/files", func(r chi.Router) {
			r.Get("/", fileH.ListForEntity)
			r.Post("/upload", fileH.Upload)
			r.Get("/{id}", fileH.Get)
			r.Delete("/{id}", fileH.Delete)
		})

		// Settings
		settH := settings.NewHandler(cfg, db, log)
		r.Route("/api/v1/settings", func(r chi.Router) {
			// Reads — any authenticated user
			r.Get("/", settH.Get)
			r.Get("/scheduling", settH.GetScheduling)
			r.Get("/jobs", settH.GetJobSettings)

			// Writes — admin+
			r.Group(func(r chi.Router) {
				r.Use(middleware.RequireOwnerOrAdmin())
				r.Put("/", settH.Update)
				r.Patch("/", settH.Update)
				r.Put("/scheduling", settH.UpdateScheduling)
				r.Patch("/scheduling", settH.UpdateScheduling)
				r.Put("/jobs", settH.UpdateJobSettings)
				r.Patch("/jobs", settH.UpdateJobSettings)
				r.Get("/api-keys", settH.ListAPIKeys)
				r.Post("/api-keys", settH.CreateAPIKey)
				r.Delete("/api-keys/{id}", settH.RevokeAPIKey)
				r.Get("/audit-log", settH.AuditLog)
			})

			// Security settings — owner only
			r.Group(func(r chi.Router) {
				r.Use(middleware.RequireOwner())
				r.Get("/security", settH.GetSecurity)
				r.Put("/security", settH.UpdateSecurity)
				r.Patch("/security", settH.UpdateSecurity)
			})
		})

		// Leads (CRM)
		leadsH := leadshandler.NewHandler(cfg, db, log, audit)
		r.Route("/api/v1/leads", leadsH.Routes())

		// AI Assistant
		aiH := aihandler.NewHandler(cfg, db, log)
		r.Route("/api/v1/ai", aiH.Routes())

		// Chat
		chatH := chat.NewHandler(cfg, db, log)
		r.Route("/api/v1/chat", func(r chi.Router) {
			r.Get("/rooms", chatH.ListRooms)
			r.Post("/rooms", chatH.CreateRoom)
			r.Get("/rooms/{id}", chatH.GetRoom)
			r.Get("/rooms/{id}/messages", chatH.GetMessages)
			r.Post("/rooms/{id}/messages", chatH.SendMessage)
		})
		// Chat WebSocket — JWT passed as query param, no bearer middleware needed
		r.Get("/chat/ws", chatH.WebSocket)

		// WebSocket hub (legacy general hub)
		wsHub := ws.NewHub()
		go wsHub.Run()
		r.Get("/ws", ws.Handler(wsHub, cfg.JWTSecret))
	})

	// ── Health check ─────────────────────────────────────────────
	r.Get("/health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"status":"ok"}`))
	})

	return r
}
