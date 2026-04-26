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
	"github.com/tradie/api/internal/handlers/activity"
	aihandler "github.com/tradie/api/internal/handlers/ai"
	"github.com/tradie/api/internal/handlers/analytics"
	"github.com/tradie/api/internal/handlers/auth"
	"github.com/tradie/api/internal/handlers/availability_roster"
	"github.com/tradie/api/internal/handlers/bulk_import"
	"github.com/tradie/api/internal/handlers/bulk_update"
	"github.com/tradie/api/internal/handlers/business"
	"github.com/tradie/api/internal/handlers/chat"
	"github.com/tradie/api/internal/handlers/customer_addresses"
	"github.com/tradie/api/internal/handlers/customer_history"
	"github.com/tradie/api/internal/handlers/customers"
	"github.com/tradie/api/internal/handlers/dashboard"
	"github.com/tradie/api/internal/handlers/expenses"
	"github.com/tradie/api/internal/handlers/files"
	"github.com/tradie/api/internal/handlers/filters"
	"github.com/tradie/api/internal/handlers/integrations"
	"github.com/tradie/api/internal/handlers/invoices"
	"github.com/tradie/api/internal/handlers/jobs"
	leadshandler "github.com/tradie/api/internal/handlers/leads"
	"github.com/tradie/api/internal/handlers/localization"
	"github.com/tradie/api/internal/handlers/notifications"
	"github.com/tradie/api/internal/handlers/payments"
	"github.com/tradie/api/internal/handlers/quotes"
	"github.com/tradie/api/internal/handlers/referrals"
	remindershandler "github.com/tradie/api/internal/handlers/reminders"
	"github.com/tradie/api/internal/handlers/reports"
	"github.com/tradie/api/internal/handlers/reviews"
	"github.com/tradie/api/internal/handlers/safety"
	"github.com/tradie/api/internal/handlers/scheduler"
	"github.com/tradie/api/internal/handlers/search"
	"github.com/tradie/api/internal/handlers/settings"
	"github.com/tradie/api/internal/handlers/staff_roles"
	"github.com/tradie/api/internal/handlers/subscription"
	"github.com/tradie/api/internal/handlers/task_reminders"
	"github.com/tradie/api/internal/handlers/tasks"
	voicenotes "github.com/tradie/api/internal/handlers/voice_notes"
	"github.com/tradie/api/internal/handlers/workers"
	"github.com/tradie/api/internal/middleware"
	emailsvc "github.com/tradie/api/internal/services/email"
	remsvc "github.com/tradie/api/internal/services/reminders"
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
	emailService := emailsvc.NewService(cfg, log)

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

		// M21 — public review submission (token-gated, no auth).
		// Rate-limited by IP via the parent group's httprate.
		reviewsPubH := reviews.NewHandler(cfg, db, log, audit, emailService)
		r.Get("/api/v1/public/reviews/{token}", reviewsPubH.PublicGet)
		r.Post("/api/v1/public/reviews/{token}", reviewsPubH.PublicSubmit)

		// OAuth callback — provider redirects here after user consent. State
		// token in the query string carries the originating business/user, so
		// no JWT is available. Validation happens inside the handler against
		// the oauth_state table.
		oauthPubH := integrations.NewOAuthHandler(cfg, db, log, audit)
		r.Get("/api/v1/integrations/{provider}/callback", oauthPubH.Callback)
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

		// Team / Workers (M22) — permission keys (employees.view/.create/
		// .update/.delete/.export) are enforced inside the handler;
		// route-level RequireAtLeast / RequireOwnerOrAdmin remain as
		// defence in depth.
		workerH := workers.NewHandler(cfg, db, log, audit)
		r.Route("/api/v1/workers", func(r chi.Router) {
			// Self-service worker actions (any authenticated user)
			r.Post("/location", workerH.UpdateLocation)
			r.Post("/check-in", workerH.CheckIn)
			r.Post("/check-out", workerH.CheckOut)
			// M26 — read + management surface
			r.Get("/check-ins", workerH.ListCheckIns)
			r.Get("/check-ins/{id}", workerH.GetCheckIn)
			r.Post("/check-ins/{id}/cancel", workerH.CancelCheckIn)
			r.Get("/check-ins/export.csv", workerH.ExportCheckIns)
			r.Post("/timesheets", workerH.CreateTimesheet)
			r.Put("/timesheets/{id}", workerH.UpdateTimesheet)
			r.Patch("/timesheets/{id}", workerH.UpdateTimesheet)
			r.Get("/timesheets", workerH.ListTimesheets)
			r.Post("/timesheets/{id}/submit", workerH.SubmitTimesheet) // M25 lifecycle
			r.Post("/timesheets/{id}/cancel", workerH.CancelTimesheet) // M25 lifecycle
			r.Get("/timesheets/export.csv", workerH.ExportTimesheets)

			// Read access — manager+ (handler also enforces employees.view)
			r.Group(func(r chi.Router) {
				r.Use(middleware.RequireAtLeast("manager"))
				r.Get("/", workerH.List)
				r.Get("/export.csv", workerH.Export)
				r.Get("/{id}", workerH.Get)
				r.Get("/{id}/timesheets", workerH.GetTimesheets)
				r.Get("/{id}/payslips", workerH.GetPayslips)
				r.Get("/{id}/availability", workerH.GetAvailability)
				r.Put("/{id}/availability", workerH.UpdateAvailability)
				r.Get("/{id}/performance", workerH.GetPerformance)
				r.Get("/{id}/location", workerH.GetLocation)
			})

			// Write access — admin+ (handler also enforces employees.create/.update/.delete)
			r.Group(func(r chi.Router) {
				r.Use(middleware.RequireOwnerOrAdmin())
				r.Post("/", workerH.Create)
				r.Put("/{id}", workerH.Update)
				r.Patch("/{id}", workerH.Update)
				r.Delete("/{id}", workerH.Delete)
				r.Post("/{id}/status", workerH.SetStatus) // M22 lifecycle
				r.Post("/invite", workerH.Invite)
				r.Post("/timesheets/{id}/approve", workerH.ApproveTimesheet)
				r.Post("/timesheets/{id}/reject", workerH.RejectTimesheet) // M25
			})
		})
		// Self-service safe endpoints (spec §API Endpoint Pattern).
		r.Get("/api/v1/me/worker_management_module", workerH.MeView)
		r.Get("/api/v1/me/time_tracking_module", workerH.MeTimeView)         // M25
		r.Get("/api/v1/me/check_in_check_out_module", workerH.MeCheckInView) // M26
		r.Get("/api/v1/me/leave_management_module", workerH.MeLeaveView)     // M27
		r.Get("/api/v1/me/payroll_module", workerH.MePayrollView)            // M28

		// Availability + Roster (M24) — leave blocks, recurring weekly
		// pattern, and per-date roster shifts. Permission keys
		// (roster.view / .update / .approve / .export) are enforced
		// inside the handler.
		rosterH := availability_roster.NewHandler(cfg, db, log, audit)
		r.Route("/api/v1/availability_roster", func(r chi.Router) {
			r.Get("/", rosterH.ListBlocks)
			r.Post("/", rosterH.CreateBlock)
			r.Get("/export.csv", rosterH.Export)
			r.Get("/{id}", rosterH.GetBlock)
			r.Patch("/{id}", rosterH.UpdateBlock)
			r.Put("/{id}", rosterH.UpdateBlock)
			r.Delete("/{id}", rosterH.DeleteBlock)

			// Roster shifts (per-date assignments).
			r.Get("/roster", rosterH.ListRoster)
			r.Post("/roster", rosterH.CreateRoster)
			r.Patch("/roster/{id}", rosterH.UpdateRoster)
			r.Put("/roster/{id}", rosterH.UpdateRoster)
			r.Delete("/roster/{id}", rosterH.DeleteRoster)

			// Recurring weekly pattern (one row per user × day-of-week).
			r.Put("/recurring/{user_id}", rosterH.SetRecurring)
		})
		r.Get("/api/v1/me/availability_roster_module", rosterH.MeView)

		// Staff Roles (M23) — tenant-defined custom role labels /
		// designations. Permission keys (roles.manage / .view /
		// .assign / .export) are enforced inside the handler.
		staffRolesH := staff_roles.NewHandler(cfg, db, log, audit)
		r.Route("/api/v1/staff_roles", func(r chi.Router) {
			r.Get("/", staffRolesH.List)
			r.Post("/", staffRolesH.Create)
			r.Get("/export.csv", staffRolesH.Export)
			r.Get("/{id}", staffRolesH.Get)
			r.Patch("/{id}", staffRolesH.Update)
			r.Put("/{id}", staffRolesH.Update)
			r.Delete("/{id}", staffRolesH.Delete)
			r.Post("/{id}/status", staffRolesH.SetStatus)
			r.Post("/{id}/assign", staffRolesH.Assign)
			r.Post("/{id}/unassign", staffRolesH.Unassign)
		})
		r.Get("/api/v1/me/staff_roles_module", staffRolesH.MeView)

		// Multi Language (M127) — tenant-scoped localization entries
		// and translated templates. Permission keys
		// (localization.manage / .view / .export) are enforced inside
		// the handler; business_id is always sourced from context.
		localizationH := localization.NewHandler(cfg, db, log, audit)
		r.Route("/api/v1/multi_language_module", func(r chi.Router) {
			r.Get("/", localizationH.List)
			r.Post("/", localizationH.Create)
			r.Get("/export.csv", localizationH.Export)
			r.Get("/{id}", localizationH.Get)
			r.Patch("/{id}", localizationH.Update)
			r.Put("/{id}", localizationH.Update)
			r.Delete("/{id}", localizationH.Delete)
		})
		r.Get("/api/v1/me/multi_language_module", localizationH.MeView)

		// Customers (M15) — permission keys (customers.view/.create/
		// .update/.delete) are enforced inside the handler.
		custH := customers.NewHandler(cfg, db, log, audit)
		// Customer Addresses (M17) — own service, own permission key
		// (customers.addresses.manage). Wired both at the spec
		// top-level and at the legacy nested route so the existing
		// mobile flow keeps working.
		addrH := customer_addresses.NewHandler(cfg, db, log, audit)
		// Customer History (M19) — derived timeline + annotation CRUD.
		// Permission keys: customers.history.view / .create / .manage
		// / .export. Wired both at the spec top-level and at legacy
		// nested routes so the mobile UI keeps working.
		histH := customer_history.NewHandler(cfg, db, log, audit)

		r.Route("/api/v1/customers", func(r chi.Router) {
			r.Get("/", custH.List)
			r.Get("/export.csv", custH.Export)
			r.Post("/", custH.Create)
			r.Get("/{id}", custH.Get)
			r.Get("/{id}/addresses", addrH.List)    // M17 (legacy nested)
			r.Post("/{id}/addresses", addrH.Create) // M17 (legacy nested)
			r.Get("/{id}/contacts", custH.GetContacts)
			r.Post("/{id}/contacts", custH.AddContact)
			r.Get("/{id}/notes", histH.ListAnnotations)   // M19 (legacy nested)
			r.Post("/{id}/notes", histH.CreateAnnotation) // M19 (legacy nested)
			r.Get("/{id}/history", histH.Timeline)        // M19 — was dead code
			r.Get("/{id}/jobs", custH.GetJobs)
			r.Get("/{id}/quotes", custH.GetQuotes)
			r.Get("/{id}/invoices", custH.GetInvoices)
			r.Post("/{id}/status", custH.SetStatus) // M15 lifecycle transitions

			r.Group(func(r chi.Router) {
				r.Use(middleware.RequireAtLeast("manager"))
				r.Put("/{id}", custH.Update)
				r.Patch("/{id}", custH.Update)
				r.Delete("/{id}", custH.Delete)
				r.Put("/{id}/addresses/{aid}", addrH.Update)    // M17 (legacy nested)
				r.Patch("/{id}/addresses/{aid}", addrH.Update)  // M17 (legacy nested)
				r.Delete("/{id}/addresses/{aid}", addrH.Delete) // M17 (legacy nested)
			})
		})

		// M15 + M17 + M19 self-service safe endpoints (spec §API Endpoint Pattern).
		r.Get("/api/v1/me/customer_management_module", custH.MeView)
		r.Get("/api/v1/me/customer_address_module", addrH.MeView)
		r.Get("/api/v1/me/customer_history_module", histH.MeView)

		// M19 — top-level CRUD on history annotations per spec.
		r.Route("/api/v1/customer_history", func(r chi.Router) {
			r.Get("/", histH.ListAnnotations)
			r.Post("/", histH.CreateAnnotation)
			r.Get("/export.csv", histH.Export)
			r.Get("/{id}", histH.GetAnnotation)
			r.Patch("/{id}", histH.UpdateAnnotation)
			r.Put("/{id}", histH.UpdateAnnotation)
			r.Delete("/{id}", histH.DeleteAnnotation)
		})

		// M17 — top-level CRUD per spec.
		r.Route("/api/v1/customer_addresses", func(r chi.Router) {
			r.Get("/", addrH.List)
			r.Post("/", addrH.Create)
			r.Get("/export.csv", addrH.Export)
			r.Get("/{id}", addrH.Get)
			r.Patch("/{id}", addrH.Update)
			r.Put("/{id}", addrH.Update)
			r.Delete("/{id}", addrH.Delete)
			r.Post("/{id}/status", addrH.SetStatus)
		})

		// Jobs — reads + field-worker actions open; create/update/delete/assign manager+
		jobH := jobs.NewHandler(cfg, db, log, audit)
		r.Route("/api/v1/jobs", func(r chi.Router) {
			r.Get("/", jobH.List)
			r.Get("/{id}", jobH.Get)
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

			r.Group(func(r chi.Router) {
				r.Use(middleware.RequireAtLeast("manager"))
				r.Post("/", jobH.Create)
				r.Put("/{id}", jobH.Update)
				r.Delete("/{id}", jobH.Delete)
				r.Post("/{id}/assign", jobH.Assign)
			})
		})

		// Scheduler — conflict + ETA queries open; rescheduling + route planning manager+
		schedH := scheduler.NewHandler(cfg, db, rdb, log)
		r.Route("/api/v1/scheduler", func(r chi.Router) {
			r.Get("/conflicts", schedH.CheckConflicts)
			r.Get("/eta/{job_id}", schedH.ETA)

			r.Group(func(r chi.Router) {
				r.Use(middleware.RequireAtLeast("manager"))
				r.Post("/drag-drop", schedH.DragDrop)
				r.Get("/route", schedH.Route)
			})
		})

		// Quotes — reads + PDF open; mutations, send, conversion, template create manager+
		quoteH := quotes.NewHandler(cfg, db, log, audit)
		r.Route("/api/v1/quotes", func(r chi.Router) {
			r.Get("/", quoteH.List)
			r.Get("/{id}", quoteH.Get)
			r.Get("/{id}/pdf", quoteH.GeneratePDF)
			r.Get("/templates", quoteH.ListTemplates)

			r.Group(func(r chi.Router) {
				r.Use(middleware.RequireAtLeast("manager"))
				r.Post("/", quoteH.Create)
				r.Put("/{id}", quoteH.Update)
				r.Delete("/{id}", quoteH.Delete)
				r.Post("/{id}/send", quoteH.Send)
				r.Post("/{id}/convert", quoteH.ConvertToJob)
				r.Post("/templates", quoteH.CreateTemplate)
			})
		})
		// Public quote approval (customer-facing, no auth)
		r.Get("/api/v1/public/quotes/{token}", quoteH.PublicGet)
		r.Post("/api/v1/public/quotes/{token}/approve", quoteH.PublicApprove)
		r.Post("/api/v1/public/quotes/{token}/reject", quoteH.PublicReject)

		// Global search
		searchH := search.NewHandler(cfg, db, log)
		r.Get("/api/v1/search", searchH.Search)

		// Invoices — reads + PDF + receipt open; financial mutations manager+; recurring trigger admin+
		invH := invoices.NewHandler(cfg, db, log, audit, emailService)
		r.Route("/api/v1/invoices", func(r chi.Router) {
			r.Get("/", invH.List)
			r.Get("/{id}", invH.Get)
			r.Get("/{id}/pdf", invH.GeneratePDF)
			r.Get("/{id}/receipt", invH.GetReceipt)
			r.Get("/recurring", invH.ListRecurringRules)

			r.Group(func(r chi.Router) {
				r.Use(middleware.RequireAtLeast("manager"))
				r.Post("/", invH.Create)
				r.Put("/{id}", invH.Update)
				r.Delete("/{id}", invH.Delete)
				r.Post("/{id}/send", invH.Send)
				r.Post("/{id}/payment", invH.RecordPayment)
				r.Post("/{id}/credit-note", invH.IssueCreditNote)
				r.Post("/{id}/payment-link", invH.CreatePaymentLink)
				r.Post("/recurring", invH.CreateRecurringRule)
				r.Delete("/recurring/{id}", invH.DeleteRecurringRule)
			})

			// Internal: process due recurring invoices — owner/admin only (until cron worker exists)
			r.Group(func(r chi.Router) {
				r.Use(middleware.RequireOwnerOrAdmin())
				r.Post("/recurring/process", invH.ProcessDueRecurring)
			})
		})

		// Payments — financial data, manager+ only
		payH := payments.NewHandler(cfg, db, log, audit)
		r.Route("/api/v1/payments", func(r chi.Router) {
			r.Use(middleware.RequireAtLeast("manager"))
			r.Get("/", payH.List)
			r.Get("/{id}", payH.Get)
		})

		// Expenses — submission open; updates manager+; delete + accountant export admin+
		expH := expenses.NewHandler(cfg, db, log, audit)
		r.Route("/api/v1/expenses", func(r chi.Router) {
			r.Get("/", expH.List)
			r.Post("/", expH.Create)
			r.Get("/summary", expH.GetSummary)
			r.Post("/scan-receipt", expH.ScanReceipt)
			r.Get("/{id}", expH.Get)

			r.Group(func(r chi.Router) {
				r.Use(middleware.RequireAtLeast("manager"))
				r.Patch("/{id}", expH.Update)
				r.Put("/{id}", expH.Update)
			})

			r.Group(func(r chi.Router) {
				r.Use(middleware.RequireOwnerOrAdmin())
				r.Delete("/{id}", expH.Delete)
				r.Get("/export/accountant", expH.ExportAccountant)
			})
		})

		// Payroll
		workerH.RegisterPayrollRoutes(r)

		// Payroll Module (M28) — spec top-level API over pay runs.
		// Payslips remain available at /api/v1/payroll/payslips and
		// self-service at /api/v1/me/payroll_module.
		r.Route("/api/v1/payroll_module", func(r chi.Router) {
			r.Get("/", workerH.ListPayRuns)
			r.Post("/", workerH.CreatePayRun)
			r.Get("/export.csv", workerH.ExportPayRuns)
			r.Get("/{id}", workerH.GetPayRun)
			r.Patch("/{id}", workerH.UpdatePayRun)
			r.Put("/{id}", workerH.UpdatePayRun)
			r.Delete("/{id}", workerH.DeletePayRun)
			r.Post("/{id}/process", workerH.ProcessPayRun)
			r.Post("/{id}/pay", workerH.MarkPayRunPaid)
			r.Post("/{id}/cancel", workerH.CancelPayRun)
		})

		// Payslip Generator (M29) — secure payslip listing and PDF
		// generation. Employees use /me/payslip_generator_module for
		// own records; elevated users can generate tenant payslip PDFs.
		r.Route("/api/v1/payslip_generator_module", func(r chi.Router) {
			r.Get("/", workerH.ListPayslipGenerator)
			r.Post("/", workerH.GeneratePayslipRecord)
			r.Get("/export.csv", workerH.ExportPayslipGenerator)
			r.Get("/{id}", workerH.GetPayslipGenerator)
			r.Patch("/{id}", workerH.UpdatePayslipGenerator)
			r.Put("/{id}", workerH.UpdatePayslipGenerator)
			r.Delete("/{id}", workerH.DeletePayslipGenerator)
			r.Get("/{id}/pdf", workerH.DownloadPayslipPDF)
		})
		r.Get("/api/v1/me/payslip_generator_module", workerH.MePayslipGeneratorView)

		// Leave Management (M27) — spec top-level API aliases over
		// the hardened leave request service. Handler-level permission
		// checks enforce leave.request / leave.approve / leave.view /
		// leave.manage / leave.export, so managers with leave.approve
		// can approve here without the payroll route's owner/admin
		// grouping.
		r.Route("/api/v1/leave_management_module", func(r chi.Router) {
			r.Get("/", workerH.ListLeaveRequests)
			r.Post("/", workerH.CreateLeaveRequest)
			r.Get("/export.csv", workerH.ExportLeaveRequests)
			r.Get("/{id}", workerH.GetLeaveRequest)
			r.Patch("/{id}", workerH.UpdateLeaveRequest)
			r.Put("/{id}", workerH.UpdateLeaveRequest)
			r.Delete("/{id}", workerH.DeleteLeaveRequest)
			r.Post("/{id}/cancel", workerH.CancelLeaveRequest)
			r.Post("/{id}/approve", workerH.ApproveLeave)
			r.Post("/{id}/reject", workerH.RejectLeave)
		})

		// Safety — field submissions (incidents, PPE, checklists) open;
		// SWMS/risk-assessment authoring + compliance management manager+
		safetyH := safety.NewHandler(cfg, db, log, audit)
		r.Route("/api/v1/safety", func(r chi.Router) {
			r.Get("/checklists", safetyH.ListChecklists)
			r.Post("/checklists", safetyH.CreateChecklist)
			r.Get("/checklists/{id}", safetyH.GetChecklist)
			r.Post("/checklists/{id}/complete", safetyH.CompleteChecklist)
			r.Get("/swms", safetyH.ListSWMS)
			r.Get("/swms/{id}", safetyH.GetSWMS)
			r.Get("/swms/{id}/pdf", safetyH.GenerateSWMSPDF)
			r.Get("/incidents", safetyH.ListIncidents)
			r.Post("/incidents", safetyH.CreateIncident)
			r.Get("/incidents/{id}", safetyH.GetIncident)
			r.Get("/risk-assessments", safetyH.ListRiskAssessments)
			r.Get("/compliance", safetyH.ListCompliance)
			r.Get("/ppe/{job_id}", safetyH.GetPPEChecklist)
			r.Post("/ppe", safetyH.SubmitPPEChecklist)

			r.Group(func(r chi.Router) {
				r.Use(middleware.RequireAtLeast("manager"))
				r.Put("/incidents/{id}", safetyH.UpdateIncident)
				r.Post("/swms", safetyH.CreateSWMS)
				r.Post("/risk-assessments", safetyH.CreateRiskAssessment)
				r.Post("/compliance", safetyH.AddCompliance)
				r.Put("/compliance/{id}", safetyH.UpdateCompliance)
				r.Delete("/compliance/{id}", safetyH.DeleteCompliance)
			})
		})

		// Tasks / Reminders
		taskH := tasks.NewHandler(cfg, db, log)
		// Legacy reminders handler — covers the tasks.reminder_at flow
		// (snooze on a task row + drain due reminders for the tenant).
		// Real dispatcher emails the assignee; falls back to no-op log
		// in dev when SENDGRID_API_KEY is unset.
		dispatcher := remsvc.NewEmailDispatcher(db, log, emailService)
		legacyRemH := remindershandler.NewHandler(cfg, db, log, audit, dispatcher)
		r.Route("/api/v1/tasks", func(r chi.Router) {
			r.Get("/", taskH.List)
			r.Post("/", taskH.Create)
			r.Get("/{id}", taskH.Get)
			r.Put("/{id}", taskH.Update)
			r.Patch("/{id}", taskH.Update)
			r.Post("/{id}/complete", taskH.Complete)
			r.Post("/{id}/snooze", legacyRemH.Snooze) // M13 — was dead code
			r.Delete("/{id}", taskH.Delete)
		})

		// M13 — dedicated task_reminders CRUD entity. Permission keys
		// (reminders.view / .create / .manage / .export) are enforced
		// inside the handler.
		trH := task_reminders.NewHandler(cfg, db, log, audit, dispatcher)
		r.Route("/api/v1/task_reminders", func(r chi.Router) {
			r.Get("/", trH.List)
			r.Post("/", trH.Create)
			r.Post("/run", trH.Run)
			r.Get("/export.csv", trH.Export)
			r.Get("/{id}", trH.Get)
			r.Patch("/{id}", trH.Update)
			r.Put("/{id}", trH.Update)
			r.Delete("/{id}", trH.Delete)
			r.Post("/{id}/snooze", trH.Snooze)
			r.Post("/{id}/dismiss", trH.Dismiss)
		})
		// Self-service safe endpoint (spec §API Endpoint Pattern).
		r.Get("/api/v1/me/task_reminders", trH.MeView)

		// Internal reminder run — owner/admin only, used by ops cron.
		r.Group(func(r chi.Router) {
			r.Use(middleware.RequireOwnerOrAdmin())
			r.Post("/api/v1/internal/reminders/run", legacyRemH.Run)
		})

		// Reports — dashboard open; operational reports manager+; financial reports admin+
		// NOTE: mobile dashboard widgets that show revenue/unpaid will 403 for non-elevated
		// users — UI must conditionally render based on caller role.
		repH := reports.NewHandler(cfg, db, log, audit)
		r.Route("/api/v1/reports", func(r chi.Router) {
			r.Get("/dashboard", repH.Dashboard)

			r.Group(func(r chi.Router) {
				r.Use(middleware.RequireAtLeast("manager"))
				r.Get("/jobs", repH.Jobs)
				r.Get("/workers", repH.WorkerPerformance)
				r.Get("/customer-retention", repH.CustomerRetention)
				r.Get("/export/csv", repH.ExportCSV)
				r.Get("/export/pdf", repH.ExportPDF)
			})

			r.Group(func(r chi.Router) {
				r.Use(middleware.RequireOwnerOrAdmin())
				r.Get("/revenue", repH.Revenue)
				r.Get("/unpaid-invoices", repH.UnpaidInvoices)
				r.Get("/income-expense", repH.IncomeExpense)
				r.Get("/gst-bas", repH.GSTBAS)
				r.Get("/quarterly-tax", repH.QuarterlyTax)
				r.Get("/export/year-end", repH.YearEnd)
			})
		})

		// Activity Feed (M14) — activity.view / .create / .manage / .export
		actH := activity.NewHandler(cfg, db, log, audit)
		r.Route("/api/v1/activity", func(r chi.Router) {
			r.Get("/", actH.List) // audit-derived feed (read-only)
			r.Get("/export.csv", actH.Export)
			r.Route("/entries", func(r chi.Router) {
				r.Get("/", actH.ListEntries)
				r.Post("/", actH.CreateEntry)
				r.Get("/{id}", actH.GetEntry)
				r.Patch("/{id}", actH.UpdateEntry)
				r.Put("/{id}", actH.UpdateEntry)
				r.Delete("/{id}", actH.DeleteEntry)
			})
		})
		r.Get("/api/v1/me/activity_feed", actH.MeView)

		// KPI Analytics Widgets (M12) — analytics.view / .widget_manage / .export
		anaH := analytics.NewHandler(cfg, db, log, audit)
		r.Route("/api/v1/analytics", func(r chi.Router) {
			r.Get("/catalog", anaH.Catalog)
			r.Get("/metrics/{key}", anaH.MetricValue)
			r.Get("/widgets.csv", anaH.Export)
			r.Route("/widgets", func(r chi.Router) {
				r.Get("/", anaH.ListWidgets)
				r.Post("/", anaH.CreateWidget)
				r.Post("/reorder", anaH.Reorder)
				r.Get("/{id}", anaH.GetWidget)
				r.Patch("/{id}", anaH.UpdateWidget)
				r.Put("/{id}", anaH.UpdateWidget)
				r.Delete("/{id}", anaH.DeleteWidget)
			})
		})
		// Self-service safe endpoint (spec §API Endpoint Pattern).
		r.Get("/api/v1/me/analytics/widgets", anaH.MeView)

		// Dashboard Module (M11) — fine-grained permission keys
		// (dashboard.view / .owner_view / .employee_view / .alert_manage / .export)
		// are enforced inside the handler via h.requirePermission(). Route-level
		// auth + tenant guard is the same as everything else under /api/v1.
		dashH := dashboard.NewHandler(cfg, db, log, audit)
		r.Route("/api/v1/dashboard", func(r chi.Router) {
			r.Get("/", dashH.OwnerView)
			r.Get("/export.csv", dashH.Export)
			r.Route("/alerts", func(r chi.Router) {
				r.Get("/", dashH.ListAlerts)
				r.Post("/", dashH.CreateAlert)
				r.Get("/{id}", dashH.GetAlert)
				r.Patch("/{id}", dashH.UpdateAlert)
				r.Put("/{id}", dashH.UpdateAlert)
				r.Delete("/{id}", dashH.DeleteAlert)
			})
		})
		// Explicit safe self-service endpoint (spec §API Endpoint Pattern).
		r.Get("/api/v1/me/dashboard", dashH.MeView)

		// Notifications — user-facing inbox + own-preferences open;
		// template editing + delivery log access admin+
		notifH := notifications.NewHandler(cfg, db, rdb, log)
		r.Route("/api/v1/notifications", func(r chi.Router) {
			r.Get("/", notifH.List)
			r.Post("/{id}/read", notifH.MarkRead)
			r.Post("/read-all", notifH.MarkAllRead)
			r.Get("/preferences", notifH.GetPreferences)
			r.Put("/preferences", notifH.UpdatePreferences)
			r.Patch("/preferences", notifH.UpdatePreferences)

			r.Group(func(r chi.Router) {
				r.Use(middleware.RequireOwnerOrAdmin())
				r.Get("/templates", notifH.ListTemplates)
				r.Put("/templates/{id}", notifH.UpdateTemplate)
				r.Get("/delivery-logs", notifH.DeliveryLogs)
			})
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

		// Files — list + upload + get open (uploader-vs-caller still TODO at handler level);
		// destructive delete admin+
		fileH := files.NewHandler(cfg, db, log)
		r.Route("/api/v1/files", func(r chi.Router) {
			r.Get("/", fileH.ListForEntity)
			r.Post("/upload", fileH.Upload)
			r.Get("/{id}", fileH.Get)

			r.Group(func(r chi.Router) {
				r.Use(middleware.RequireOwnerOrAdmin())
				r.Delete("/{id}", fileH.Delete)
			})
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
		// Leads (M20) — permission keys (leads.view/.create/.update/
		// .convert/.delete/.export) are enforced inside the handler.
		leadsH := leadshandler.NewHandler(cfg, db, log, audit)
		r.Route("/api/v1/leads", leadsH.Routes())
		r.Get("/api/v1/me/lead_management_module", leadsH.MeView)

		// Reviews (M21) — permission keys (reviews.request/.view/
		// .manage/.export) are enforced inside the handler.
		reviewsH := reviews.NewHandler(cfg, db, log, audit, emailService)
		r.Route("/api/v1/reviews", func(r chi.Router) {
			r.Get("/", reviewsH.List)
			r.Post("/", reviewsH.Create)
			r.Get("/export.csv", reviewsH.Export)
			r.Get("/{id}", reviewsH.Get)
			r.Patch("/{id}", reviewsH.Update)
			r.Put("/{id}", reviewsH.Update)
			r.Delete("/{id}", reviewsH.Delete)
			r.Post("/{id}/remind", reviewsH.Remind)
		})
		r.Get("/api/v1/me/review_request_module", reviewsH.MeView)

		// Referrals (M123) — referrer creates code, sees own; admins
		// list all and mark payouts. Permission gating happens inside
		// the handler; route-level RequireOwnerOrAdmin / RequireOwner
		// remain as defence in depth per the handler's Routes() comment.
		referralsH := referrals.NewHandler(cfg, db, log, audit)
		r.Route("/api/v1/referrals", func(r chi.Router) {
			r.Post("/", referralsH.Create)
			r.Get("/", referralsH.ListOwn)

			r.Group(func(r chi.Router) {
				r.Use(middleware.RequireOwnerOrAdmin())
				r.Get("/all", referralsH.ListAll)
			})

			r.Group(func(r chi.Router) {
				r.Use(middleware.RequireOwner())
				r.Post("/{id}/payout", referralsH.Payout)
			})
		})

		// Voice Notes (M126) — presign upload to S3/MinIO, finalize
		// metadata, list, and trigger transcription. Premium feature.
		voiceH := voicenotes.NewHandler(cfg, db, log, audit)
		r.Route("/api/v1/voice-notes", func(r chi.Router) {
			r.Use(middleware.RequirePlan("pro"))
			voiceH.Routes()(r)
		})

		// Saved Filters (M102) — per-user named filter sets. Owner
		// scoping enforced inside the handler via the saved_filters
		// table's user_id column. Premium feature.
		filtersH := filters.NewHandler(cfg, db, log)
		r.Route("/api/v1/saved-filters", func(r chi.Router) {
			r.Use(middleware.RequirePlan("pro"))
			r.Get("/", filtersH.List)
			r.Post("/", filtersH.Create)
			r.Delete("/{id}", filtersH.Delete)
		})

		// Bulk Import (M105) — CSV upload for customers/jobs/expenses.
		// 10 MB cap enforced in handler; per-row error log returned.
		// Manager+; Premium plan.
		bulkImpH := bulk_import.NewHandler(cfg, db, log, audit)
		r.Route("/api/v1/bulk-imports", func(r chi.Router) {
			r.Use(middleware.RequirePlan("pro"))
			r.Use(middleware.RequireAtLeast("manager"))
			r.Get("/", bulkImpH.List)
			r.Post("/", bulkImpH.Create)
			r.Get("/{id}", bulkImpH.Get)
		})

		// Bulk Update (M106) — apply a patch to up to 500 rows of one
		// entity type (jobs/leads/customers/invoices). Manager+; Premium.
		bulkUpdH := bulk_update.NewHandler(cfg, db, log, audit)
		r.Route("/api/v1/bulk-updates", func(r chi.Router) {
			r.Use(middleware.RequirePlan("pro"))
			r.Use(middleware.RequireAtLeast("manager"))
			r.Post("/", bulkUpdH.Apply)
		})

		// Integrations OAuth — Xero, MYOB, Intuit/QBO, Google Calendar.
		// Connect starts the flow, status lists current connections,
		// disconnect revokes. The provider callback is registered in
		// the public group above (no JWT, validates state token).
		// Accountancy + calendar integrations are Premium.
		oauthH := integrations.NewOAuthHandler(cfg, db, log, audit)
		r.Route("/api/v1/integrations", func(r chi.Router) {
			r.Use(middleware.RequirePlan("pro"))
			r.Get("/status", oauthH.Status)
			r.Get("/{provider}/connect", oauthH.Connect)

			r.Group(func(r chi.Router) {
				r.Use(middleware.RequireOwnerOrAdmin())
				r.Delete("/{provider}", oauthH.Disconnect)
			})
		})

		// M111 — admin backup request (records intent in audit log;
		// actual backup is an infra-level concern).
		backupH := integrations.NewBackupHandler(cfg, db, log, audit)
		r.Group(func(r chi.Router) {
			r.Use(middleware.RequireOwner())
			r.Post("/api/v1/admin/backup", backupH.Request)
		})

		// AI Assistant — Premium feature (Claude API costs scale with use)
		aiH := aihandler.NewHandler(cfg, db, log)
		r.Route("/api/v1/ai", func(r chi.Router) {
			r.Use(middleware.RequirePlan("pro"))
			aiH.Routes()(r)
		})

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
