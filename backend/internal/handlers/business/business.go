package business

import (
	"encoding/json"
	"net/http"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"go.uber.org/zap"

	"github.com/tradie/api/internal/config"
	"github.com/tradie/api/internal/middleware"
	"github.com/tradie/api/internal/models"
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

// ── Business core ─────────────────────────────────────────────────

func (h *Handler) Get(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	var b models.Business
	err := h.db.QueryRow(r.Context(),
		`SELECT id, name, slug, abn, phone, email, address_line1, city, state, postcode, country,
		        timezone, logo_url, is_active, trial_ends_at, created_at, updated_at
		 FROM businesses WHERE id=$1`, bizID,
	).Scan(&b.ID, &b.Name, &b.Slug, &b.ABN, &b.Phone, &b.Email, &b.Address, &b.City, &b.State,
		&b.Postcode, &b.Country, &b.Timezone, &b.LogoURL, &b.IsActive, &b.TrialEndsAt, &b.CreatedAt, &b.UpdatedAt)
	if err != nil {
		respond(w, 404, map[string]string{"error": "not_found"})
		return
	}
	respond(w, 200, b)
}

func (h *Handler) Update(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	var req struct {
		Name     *string `json:"name"`
		ABN      *string `json:"abn"`
		Phone    *string `json:"phone"`
		Email    *string `json:"email"`
		Address  *string `json:"address_line1"`
		City     *string `json:"city"`
		State    *string `json:"state"`
		Postcode *string `json:"postcode"`
		Country  *string `json:"country"`
		Timezone *string `json:"timezone"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respond(w, 400, map[string]string{"error": "invalid_request"})
		return
	}
	_, err := h.db.Exec(r.Context(),
		`UPDATE businesses SET
		  name=COALESCE($2,name), abn=COALESCE($3,abn), phone=COALESCE($4,phone),
		  email=COALESCE($5,email), address_line1=COALESCE($6,address_line1),
		  city=COALESCE($7,city), state=COALESCE($8,state), postcode=COALESCE($9,postcode),
		  country=COALESCE($10,country), timezone=COALESCE($11,timezone),
		  updated_at=NOW()
		 WHERE id=$1`,
		bizID, req.Name, req.ABN, req.Phone, req.Email, req.Address,
		req.City, req.State, req.Postcode, req.Country, req.Timezone)
	if err != nil {
		h.log.Error("business update failed", zap.Error(err))
		respond(w, 500, map[string]string{"error": "server_error"})
		return
	}
	claims := middleware.ClaimsFromCtx(r.Context())
	h.audit.Log(r.Context(), middleware.AuditEntry{UserID: claims.UserID, BusinessID: bizID, Action: "business.updated"})
	h.Get(w, r)
}

// ── Business Profile ──────────────────────────────────────────────

func (h *Handler) GetProfile(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	var p struct {
		TradingName      *string    `json:"trading_name"`
		IndustryType     *string    `json:"industry_type"`
		Description      *string    `json:"description"`
		LicenceNumber    *string    `json:"licence_number"`
		InsurancePolicy  *string    `json:"insurance_policy"`
		InsuranceExpiry  *time.Time `json:"insurance_expiry"`
		UpdatedAt        time.Time  `json:"updated_at"`
	}
	err := h.db.QueryRow(r.Context(),
		`SELECT trading_name, industry_type, description, licence_number, insurance_policy, insurance_expiry, updated_at
		 FROM business_profiles WHERE business_id=$1`, bizID,
	).Scan(&p.TradingName, &p.IndustryType, &p.Description, &p.LicenceNumber, &p.InsurancePolicy, &p.InsuranceExpiry, &p.UpdatedAt)
	if err != nil {
		respond(w, 200, map[string]interface{}{}) // not yet created
		return
	}
	respond(w, 200, p)
}

func (h *Handler) UpdateProfile(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	var req struct {
		TradingName     *string `json:"trading_name"`
		IndustryType    *string `json:"industry_type"`
		Description     *string `json:"description"`
		LicenceNumber   *string `json:"licence_number"`
		InsurancePolicy *string `json:"insurance_policy"`
		InsuranceExpiry *string `json:"insurance_expiry"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respond(w, 400, map[string]string{"error": "invalid_request"})
		return
	}
	_, err := h.db.Exec(r.Context(),
		`INSERT INTO business_profiles (business_id, trading_name, industry_type, description, licence_number, insurance_policy)
		 VALUES ($1,$2,$3,$4,$5,$6)
		 ON CONFLICT (business_id) DO UPDATE SET
		   trading_name=COALESCE($2,business_profiles.trading_name),
		   industry_type=COALESCE($3,business_profiles.industry_type),
		   description=COALESCE($4,business_profiles.description),
		   licence_number=COALESCE($5,business_profiles.licence_number),
		   insurance_policy=COALESCE($6,business_profiles.insurance_policy),
		   updated_at=NOW()`,
		bizID, req.TradingName, req.IndustryType, req.Description, req.LicenceNumber, req.InsurancePolicy)
	if err != nil {
		respond(w, 500, map[string]string{"error": "server_error"})
		return
	}
	h.GetProfile(w, r)
}

// ── Business Settings ─────────────────────────────────────────────

func (h *Handler) GetSettings(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	var s struct {
		DateFormat                string `json:"date_format"`
		Currency                  string `json:"currency"`
		Language                  string `json:"language"`
		DefaultJobDurationMinutes int    `json:"default_job_duration_minutes"`
		AutoSendReminders         bool   `json:"auto_send_reminders"`
	}
	_ = h.db.QueryRow(r.Context(),
		`SELECT date_format, currency, language, default_job_duration_minutes, auto_send_reminders
		 FROM business_settings WHERE business_id=$1`, bizID,
	).Scan(&s.DateFormat, &s.Currency, &s.Language, &s.DefaultJobDurationMinutes, &s.AutoSendReminders)
	respond(w, 200, s)
}

func (h *Handler) UpdateSettings(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	var req struct {
		DateFormat                *string `json:"date_format"`
		Currency                  *string `json:"currency"`
		Language                  *string `json:"language"`
		DefaultJobDurationMinutes *int    `json:"default_job_duration_minutes"`
		AutoSendReminders         *bool   `json:"auto_send_reminders"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respond(w, 400, map[string]string{"error": "invalid_request"})
		return
	}
	_, _ = h.db.Exec(r.Context(),
		`UPDATE business_settings SET
		  date_format=COALESCE($2,date_format),
		  currency=COALESCE($3,currency),
		  language=COALESCE($4,language),
		  default_job_duration_minutes=COALESCE($5,default_job_duration_minutes),
		  auto_send_reminders=COALESCE($6,auto_send_reminders),
		  updated_at=NOW()
		 WHERE business_id=$1`,
		bizID, req.DateFormat, req.Currency, req.Language, req.DefaultJobDurationMinutes, req.AutoSendReminders)
	h.GetSettings(w, r)
}

// ── Tax Settings ──────────────────────────────────────────────────

func (h *Handler) GetTaxSettings(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	var s struct {
		GSTRegistered bool    `json:"gst_registered"`
		GSTRate       float64 `json:"gst_rate"`
		FiscalYearEnd string  `json:"fiscal_year_end"`
		BASFrequency  string  `json:"bas_frequency"`
	}
	_ = h.db.QueryRow(r.Context(),
		`SELECT gst_registered, gst_rate, fiscal_year_end, bas_frequency
		 FROM business_tax_settings WHERE business_id=$1`, bizID,
	).Scan(&s.GSTRegistered, &s.GSTRate, &s.FiscalYearEnd, &s.BASFrequency)
	respond(w, 200, s)
}

func (h *Handler) UpdateTaxSettings(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	var req struct {
		GSTRegistered *bool    `json:"gst_registered"`
		GSTRate       *float64 `json:"gst_rate"`
		FiscalYearEnd *string  `json:"fiscal_year_end"`
		BASFrequency  *string  `json:"bas_frequency"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respond(w, 400, map[string]string{"error": "invalid_request"})
		return
	}
	_, _ = h.db.Exec(r.Context(),
		`UPDATE business_tax_settings SET
		  gst_registered=COALESCE($2,gst_registered),
		  gst_rate=COALESCE($3,gst_rate),
		  fiscal_year_end=COALESCE($4,fiscal_year_end),
		  bas_frequency=COALESCE($5,bas_frequency),
		  updated_at=NOW()
		 WHERE business_id=$1`,
		bizID, req.GSTRegistered, req.GSTRate, req.FiscalYearEnd, req.BASFrequency)
	h.GetTaxSettings(w, r)
}

// ── Invoice Settings ──────────────────────────────────────────────

func (h *Handler) GetInvoiceSettings(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	var s struct {
		InvoicePrefix      string  `json:"invoice_prefix"`
		QuotePrefix        string  `json:"quote_prefix"`
		NextInvoiceNumber  int     `json:"next_invoice_number"`
		NextQuoteNumber    int     `json:"next_quote_number"`
		PaymentTermsDays   int     `json:"payment_terms_days"`
		DefaultNotes       *string `json:"default_notes"`
		DefaultFooter      *string `json:"default_footer"`
		BankBSB            *string `json:"bank_bsb"`
		BankAccount        *string `json:"bank_account"`
		BankName           *string `json:"bank_name"`
	}
	_ = h.db.QueryRow(r.Context(),
		`SELECT invoice_prefix, quote_prefix, next_invoice_number, next_quote_number,
		        payment_terms_days, default_notes, default_footer, bank_bsb, bank_account, bank_name
		 FROM business_invoice_settings WHERE business_id=$1`, bizID,
	).Scan(&s.InvoicePrefix, &s.QuotePrefix, &s.NextInvoiceNumber, &s.NextQuoteNumber,
		&s.PaymentTermsDays, &s.DefaultNotes, &s.DefaultFooter, &s.BankBSB, &s.BankAccount, &s.BankName)
	respond(w, 200, s)
}

func (h *Handler) UpdateInvoiceSettings(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	var req struct {
		InvoicePrefix    *string `json:"invoice_prefix"`
		QuotePrefix      *string `json:"quote_prefix"`
		PaymentTermsDays *int    `json:"payment_terms_days"`
		DefaultNotes     *string `json:"default_notes"`
		DefaultFooter    *string `json:"default_footer"`
		BankBSB          *string `json:"bank_bsb"`
		BankAccount      *string `json:"bank_account"`
		BankName         *string `json:"bank_name"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respond(w, 400, map[string]string{"error": "invalid_request"})
		return
	}
	_, _ = h.db.Exec(r.Context(),
		`UPDATE business_invoice_settings SET
		  invoice_prefix=COALESCE($2,invoice_prefix),
		  quote_prefix=COALESCE($3,quote_prefix),
		  payment_terms_days=COALESCE($4,payment_terms_days),
		  default_notes=COALESCE($5,default_notes),
		  default_footer=COALESCE($6,default_footer),
		  bank_bsb=COALESCE($7,bank_bsb),
		  bank_account=COALESCE($8,bank_account),
		  bank_name=COALESCE($9,bank_name),
		  updated_at=NOW()
		 WHERE business_id=$1`,
		bizID, req.InvoicePrefix, req.QuotePrefix, req.PaymentTermsDays,
		req.DefaultNotes, req.DefaultFooter, req.BankBSB, req.BankAccount, req.BankName)
	h.GetInvoiceSettings(w, r)
}

// ── Payroll Settings ──────────────────────────────────────────────

func (h *Handler) GetPayrollSettings(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	var s struct {
		PayrollFrequency  string  `json:"payroll_frequency"`
		PayDay            int     `json:"pay_day"`
		SuperRate         float64 `json:"super_rate"`
		DefaultWorkHours  float64 `json:"default_work_hours"`
	}
	_ = h.db.QueryRow(r.Context(),
		`SELECT payroll_frequency, pay_day, super_rate, default_work_hours
		 FROM business_payroll_settings WHERE business_id=$1`, bizID,
	).Scan(&s.PayrollFrequency, &s.PayDay, &s.SuperRate, &s.DefaultWorkHours)
	respond(w, 200, s)
}

func (h *Handler) UpdatePayrollSettings(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	var req struct {
		PayrollFrequency *string  `json:"payroll_frequency"`
		PayDay           *int     `json:"pay_day"`
		SuperRate        *float64 `json:"super_rate"`
		DefaultWorkHours *float64 `json:"default_work_hours"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respond(w, 400, map[string]string{"error": "invalid_request"})
		return
	}
	_, _ = h.db.Exec(r.Context(),
		`UPDATE business_payroll_settings SET
		  payroll_frequency=COALESCE($2,payroll_frequency),
		  pay_day=COALESCE($3,pay_day),
		  super_rate=COALESCE($4,super_rate),
		  default_work_hours=COALESCE($5,default_work_hours),
		  updated_at=NOW()
		 WHERE business_id=$1`,
		bizID, req.PayrollFrequency, req.PayDay, req.SuperRate, req.DefaultWorkHours)
	h.GetPayrollSettings(w, r)
}

// ── Branding ──────────────────────────────────────────────────────

func (h *Handler) GetBranding(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	var s struct {
		PrimaryColor   *string `json:"primary_color"`
		LogoURL        *string `json:"logo_url"`
		SettingsJSON   []byte  `json:"-"`
	}
	_ = h.db.QueryRow(r.Context(),
		`SELECT primary_color, logo_url FROM business_branding_settings WHERE business_id=$1`, bizID,
	).Scan(&s.PrimaryColor, &s.LogoURL)
	respond(w, 200, s)
}

func (h *Handler) UpdateBranding(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	var req struct {
		PrimaryColor *string `json:"primary_color"`
		LogoURL      *string `json:"logo_url"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respond(w, 400, map[string]string{"error": "invalid_request"})
		return
	}
	_, _ = h.db.Exec(r.Context(),
		`INSERT INTO business_branding_settings (business_id, primary_color, logo_url)
		 VALUES ($1,$2,$3)
		 ON CONFLICT (business_id) DO UPDATE SET
		   primary_color=COALESCE($2,business_branding_settings.primary_color),
		   logo_url=COALESCE($3,business_branding_settings.logo_url),
		   updated_at=NOW()`,
		bizID, req.PrimaryColor, req.LogoURL)
	h.GetBranding(w, r)
}

// ── Compliance ────────────────────────────────────────────────────

func (h *Handler) GetCompliance(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	var s struct {
		WorkSafeNumber  *string `json:"worksafe_number"`
		TFN             *string `json:"tfn"`
		ACN             *string `json:"acn"`
		LicenceClass    *string `json:"licence_class"`
	}
	_ = h.db.QueryRow(r.Context(),
		`SELECT worksafe_number, tfn, acn, licence_class
		 FROM business_compliance_details WHERE business_id=$1`, bizID,
	).Scan(&s.WorkSafeNumber, &s.TFN, &s.ACN, &s.LicenceClass)
	respond(w, 200, s)
}

func (h *Handler) UpdateCompliance(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	var req struct {
		WorkSafeNumber *string `json:"worksafe_number"`
		TFN            *string `json:"tfn"`
		ACN            *string `json:"acn"`
		LicenceClass   *string `json:"licence_class"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respond(w, 400, map[string]string{"error": "invalid_request"})
		return
	}
	_, _ = h.db.Exec(r.Context(),
		`INSERT INTO business_compliance_details (business_id, worksafe_number, tfn, acn, licence_class)
		 VALUES ($1,$2,$3,$4,$5)
		 ON CONFLICT (business_id) DO UPDATE SET
		   worksafe_number=COALESCE($2,business_compliance_details.worksafe_number),
		   tfn=COALESCE($3,business_compliance_details.tfn),
		   acn=COALESCE($4,business_compliance_details.acn),
		   licence_class=COALESCE($5,business_compliance_details.licence_class),
		   updated_at=NOW()`,
		bizID, req.WorkSafeNumber, req.TFN, req.ACN, req.LicenceClass)
	h.GetCompliance(w, r)
}

func respond(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if data != nil {
		json.NewEncoder(w).Encode(data)
	}
}
