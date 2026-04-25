package models

import (
	"time"

	"github.com/google/uuid"
)

// ── Users ──────────────────────────────────────────────────────
type User struct {
	ID          uuid.UUID  `json:"id" db:"id"`
	BusinessID  uuid.UUID  `json:"business_id" db:"business_id"`
	Email       string     `json:"email" db:"email"`
	Phone       *string    `json:"phone,omitempty" db:"phone"`
	FirstName   string     `json:"first_name" db:"first_name"`
	LastName    string     `json:"last_name" db:"last_name"`
	Role        string     `json:"role" db:"role"`
	AvatarURL   *string    `json:"avatar_url,omitempty" db:"avatar_url"`
	IsActive    bool       `json:"is_active" db:"is_active"`
	IsVerified  bool       `json:"is_verified" db:"is_verified"`
	LastLoginAt *time.Time `json:"last_login_at,omitempty" db:"last_login_at"`
	CreatedAt   time.Time  `json:"created_at" db:"created_at"`
	UpdatedAt   time.Time  `json:"updated_at" db:"updated_at"`
}

func (u *User) FullName() string { return u.FirstName + " " + u.LastName }

// ── Business ───────────────────────────────────────────────────
type Business struct {
	ID          uuid.UUID  `json:"id" db:"id"`
	Name        string     `json:"name" db:"name"`
	Slug        string     `json:"slug" db:"slug"`
	ABN         *string    `json:"abn,omitempty" db:"abn"`
	Phone       *string    `json:"phone,omitempty" db:"phone"`
	Email       *string    `json:"email,omitempty" db:"email"`
	Address     *string    `json:"address_line1,omitempty" db:"address_line1"`
	City        *string    `json:"city,omitempty" db:"city"`
	State       *string    `json:"state,omitempty" db:"state"`
	Postcode    *string    `json:"postcode,omitempty" db:"postcode"`
	Country     string     `json:"country" db:"country"`
	Timezone    string     `json:"timezone" db:"timezone"`
	LogoURL     *string    `json:"logo_url,omitempty" db:"logo_url"`
	IsActive    bool       `json:"is_active" db:"is_active"`
	TrialEndsAt *time.Time `json:"trial_ends_at,omitempty" db:"trial_ends_at"`
	CreatedAt   time.Time  `json:"created_at" db:"created_at"`
	UpdatedAt   time.Time  `json:"updated_at" db:"updated_at"`
}

// ── Customer ───────────────────────────────────────────────────
type Customer struct {
	ID          uuid.UUID  `json:"id" db:"id"`
	BusinessID  uuid.UUID  `json:"business_id" db:"business_id"`
	FirstName   string     `json:"first_name" db:"first_name"`
	LastName    *string    `json:"last_name,omitempty" db:"last_name"`
	CompanyName *string    `json:"company_name,omitempty" db:"company_name"`
	Email       *string    `json:"email,omitempty" db:"email"`
	Phone       *string    `json:"phone,omitempty" db:"phone"`
	Mobile      *string    `json:"mobile,omitempty" db:"mobile"`
	Notes       *string    `json:"notes,omitempty" db:"notes"`
	Tags        []string   `json:"tags" db:"tags"`
	IsActive    bool       `json:"is_active" db:"is_active"`
	Source      *string    `json:"source,omitempty" db:"source"`
	CreatedAt   time.Time  `json:"created_at" db:"created_at"`
	UpdatedAt   time.Time  `json:"updated_at" db:"updated_at"`
}

// ── Job ────────────────────────────────────────────────────────
type Job struct {
	ID             uuid.UUID  `json:"id" db:"id"`
	BusinessID     uuid.UUID  `json:"business_id" db:"business_id"`
	JobNumber      string     `json:"job_number" db:"job_number"`
	Title          string     `json:"title" db:"title"`
	Description    *string    `json:"description,omitempty" db:"description"`
	Status         string     `json:"status" db:"status"`
	Priority       string     `json:"priority" db:"priority"`
	CustomerID     *uuid.UUID `json:"customer_id,omitempty" db:"customer_id"`
	Lat            *float64   `json:"lat,omitempty" db:"lat"`
	Lng            *float64   `json:"lng,omitempty" db:"lng"`
	ScheduledStart *time.Time `json:"scheduled_start,omitempty" db:"scheduled_start"`
	ScheduledEnd   *time.Time `json:"scheduled_end,omitempty" db:"scheduled_end"`
	ActualStart    *time.Time `json:"actual_start,omitempty" db:"actual_start"`
	ActualEnd      *time.Time `json:"actual_end,omitempty" db:"actual_end"`
	IsRecurring    bool       `json:"is_recurring" db:"is_recurring"`
	CreatedBy      *uuid.UUID `json:"created_by,omitempty" db:"created_by"`
	CreatedAt      time.Time  `json:"created_at" db:"created_at"`
	UpdatedAt      time.Time  `json:"updated_at" db:"updated_at"`
}

// ── Quote ──────────────────────────────────────────────────────
type Quote struct {
	ID             uuid.UUID  `json:"id" db:"id"`
	BusinessID     uuid.UUID  `json:"business_id" db:"business_id"`
	QuoteNumber    string     `json:"quote_number" db:"quote_number"`
	Status         string     `json:"status" db:"status"`
	CustomerID     uuid.UUID  `json:"customer_id" db:"customer_id"`
	Title          string     `json:"title" db:"title"`
	Subtotal       float64    `json:"subtotal" db:"subtotal"`
	DiscountAmount float64    `json:"discount_amount" db:"discount_amount"`
	GSTAmount      float64    `json:"gst_amount" db:"gst_amount"`
	Total          float64    `json:"total" db:"total"`
	ValidUntil     *time.Time `json:"valid_until,omitempty" db:"valid_until"`
	CreatedAt      time.Time  `json:"created_at" db:"created_at"`
	UpdatedAt      time.Time  `json:"updated_at" db:"updated_at"`
}

// ── Invoice ────────────────────────────────────────────────────
type Invoice struct {
	ID            uuid.UUID  `json:"id" db:"id"`
	BusinessID    uuid.UUID  `json:"business_id" db:"business_id"`
	InvoiceNumber string     `json:"invoice_number" db:"invoice_number"`
	Status        string     `json:"status" db:"status"`
	CustomerID    uuid.UUID  `json:"customer_id" db:"customer_id"`
	JobID         *uuid.UUID `json:"job_id,omitempty" db:"job_id"`
	Subtotal      float64    `json:"subtotal" db:"subtotal"`
	GSTAmount     float64    `json:"gst_amount" db:"gst_amount"`
	Total         float64    `json:"total" db:"total"`
	AmountPaid    float64    `json:"amount_paid" db:"amount_paid"`
	AmountDue     float64    `json:"amount_due" db:"amount_due"`
	DueDate       *time.Time `json:"due_date,omitempty" db:"due_date"`
	SentAt        *time.Time `json:"sent_at,omitempty" db:"sent_at"`
	PaidAt        *time.Time `json:"paid_at,omitempty" db:"paid_at"`
	Notes         *string    `json:"notes,omitempty" db:"notes"`
	CustomerName  string     `json:"customer_name,omitempty" db:"-"`
	CreatedAt     time.Time  `json:"created_at" db:"created_at"`
	UpdatedAt     time.Time  `json:"updated_at" db:"updated_at"`
}

// ── InvoiceLineItem ────────────────────────────────────────────
type InvoiceLineItem struct {
	ID          uuid.UUID `json:"id" db:"id"`
	InvoiceID   uuid.UUID `json:"invoice_id" db:"invoice_id"`
	Description string    `json:"description" db:"description"`
	Quantity    float64   `json:"quantity" db:"quantity"`
	UnitPrice   float64   `json:"unit_price" db:"unit_price"`
	TaxRate     float64   `json:"tax_rate" db:"tax_rate"`
	LineTotal   float64   `json:"line_total" db:"line_total"`
}

// ── InvoicePayment ─────────────────────────────────────────────
type InvoicePayment struct {
	ID            uuid.UUID `json:"id" db:"id"`
	InvoiceID     uuid.UUID `json:"invoice_id" db:"invoice_id"`
	BusinessID    uuid.UUID `json:"business_id" db:"business_id"`
	Amount        float64   `json:"amount" db:"amount"`
	PaymentMethod string    `json:"payment_method" db:"payment_method"`
	Reference     *string   `json:"reference,omitempty" db:"reference"`
	PaidAt        time.Time `json:"paid_at" db:"paid_at"`
}

// ── CreditNote ─────────────────────────────────────────────────
type CreditNote struct {
	ID         uuid.UUID `json:"id" db:"id"`
	InvoiceID  uuid.UUID `json:"invoice_id" db:"invoice_id"`
	BusinessID uuid.UUID `json:"business_id" db:"business_id"`
	Amount     float64   `json:"amount" db:"amount"`
	Reason     *string   `json:"reason,omitempty" db:"reason"`
	IssuedBy   uuid.UUID `json:"issued_by" db:"issued_by"`
	IssuedAt   time.Time `json:"issued_at" db:"issued_at"`
}

// ── API Key ────────────────────────────────────────────────────
type APIKey struct {
	ID         uuid.UUID  `json:"id"`
	BusinessID uuid.UUID  `json:"business_id"`
	Name       string     `json:"name"`
	KeyPrefix  string     `json:"key_prefix"`  // first 8 chars + "..." for display
	Scopes     []string   `json:"scopes"`
	LastUsedAt *time.Time `json:"last_used_at,omitempty"`
	CreatedBy  uuid.UUID  `json:"created_by"`
	CreatedAt  time.Time  `json:"created_at"`
}

// ── Audit Log ──────────────────────────────────────────────────
type AuditLog struct {
	ID         uuid.UUID  `json:"id"`
	BusinessID uuid.UUID  `json:"business_id"`
	UserID     *uuid.UUID `json:"user_id,omitempty"`
	UserName   string     `json:"user_name,omitempty"`
	Action     string     `json:"action"`
	EntityType string     `json:"entity_type"`
	EntityID   *uuid.UUID `json:"entity_id,omitempty"`
	IPAddress  *string    `json:"ip_address,omitempty"`
	CreatedAt  time.Time  `json:"created_at"`
}

// ── Session ────────────────────────────────────────────────────
type Session struct {
	ID           uuid.UUID  `json:"id"`
	UserID       uuid.UUID  `json:"user_id"`
	BusinessID   uuid.UUID  `json:"business_id"`
	IPAddress    string     `json:"ip_address"`
	UserAgent    string     `json:"user_agent"`
	DeviceInfo   string     `json:"device_info"`
	Location     *string    `json:"location,omitempty"`
	IsCurrent    bool       `json:"is_current"`
	LastActiveAt time.Time  `json:"last_active_at"`
	CreatedAt    time.Time  `json:"created_at"`
}

// ── CustomerAddress ────────────────────────────────────────────
type CustomerAddress struct {
	ID           uuid.UUID `json:"id"`
	CustomerID   uuid.UUID `json:"customer_id"`
	BusinessID   uuid.UUID `json:"business_id"`
	Label        string    `json:"label"`
	AddressLine1 string    `json:"address_line1"`
	AddressLine2 *string   `json:"address_line2,omitempty"`
	City         string    `json:"city"`
	State        *string   `json:"state,omitempty"`
	Postcode     *string   `json:"postcode,omitempty"`
	Country      string    `json:"country"`
	IsPrimary    bool      `json:"is_primary"`
	CreatedAt    time.Time `json:"created_at"`
}

// ── CustomerContact ────────────────────────────────────────────
type CustomerContact struct {
	ID         uuid.UUID  `json:"id"`
	CustomerID uuid.UUID  `json:"customer_id"`
	BusinessID uuid.UUID  `json:"business_id"`
	Name       string     `json:"name"`
	Role       *string    `json:"role,omitempty"`
	Email      *string    `json:"email,omitempty"`
	Phone      *string    `json:"phone,omitempty"`
	IsPrimary  bool       `json:"is_primary"`
	CreatedAt  time.Time  `json:"created_at"`
}

// ── CustomerNote ───────────────────────────────────────────────
type CustomerNote struct {
	ID         uuid.UUID  `json:"id"`
	CustomerID uuid.UUID  `json:"customer_id"`
	BusinessID uuid.UUID  `json:"business_id"`
	Content    string     `json:"content"`
	CreatedBy  *uuid.UUID `json:"created_by,omitempty"`
	Author     *string    `json:"author,omitempty"`
	CreatedAt  time.Time  `json:"created_at"`
}

// ── Lead ───────────────────────────────────────────────────────
type Lead struct {
	ID         uuid.UUID  `json:"id"`
	BusinessID uuid.UUID  `json:"business_id"`
	FirstName  string     `json:"first_name"`
	LastName   *string    `json:"last_name,omitempty"`
	Email      *string    `json:"email,omitempty"`
	Phone      *string    `json:"phone,omitempty"`
	Status     string     `json:"status"`
	Source     *string    `json:"source,omitempty"`
	Notes      *string    `json:"notes,omitempty"`
	AssignedTo *uuid.UUID `json:"assigned_to,omitempty"`
	CreatedAt  time.Time  `json:"created_at"`
	UpdatedAt  time.Time  `json:"updated_at"`
}

// ── Job Notes ──────────────────────────────────────────────────
type JobNote struct {
	ID         uuid.UUID  `json:"id"`
	JobID      uuid.UUID  `json:"job_id"`
	BusinessID uuid.UUID  `json:"business_id"`
	Content    string     `json:"content"`
	IsInternal bool       `json:"is_internal"`
	CreatedBy  *uuid.UUID `json:"created_by,omitempty"`
	Author     string     `json:"author,omitempty"`
	CreatedAt  time.Time  `json:"created_at"`
}

// ── Job Photos ─────────────────────────────────────────────────
type JobPhoto struct {
	ID           uuid.UUID  `json:"id"`
	JobID        uuid.UUID  `json:"job_id"`
	BusinessID   uuid.UUID  `json:"business_id"`
	URL          string     `json:"url"`
	ThumbnailURL *string    `json:"thumbnail_url,omitempty"`
	Caption      *string    `json:"caption,omitempty"`
	Phase        string     `json:"phase"` // before, during, after
	UploadedBy   *uuid.UUID `json:"uploaded_by,omitempty"`
	CreatedAt    time.Time  `json:"created_at"`
}

// ── Job Materials ──────────────────────────────────────────────
type JobMaterial struct {
	ID         uuid.UUID  `json:"id"`
	JobID      uuid.UUID  `json:"job_id"`
	BusinessID uuid.UUID  `json:"business_id"`
	Name       string     `json:"name"`
	Quantity   float64    `json:"quantity"`
	Unit       *string    `json:"unit,omitempty"`
	UnitCost   float64    `json:"unit_cost"`
	TotalCost  float64    `json:"total_cost"`
	Supplier   *string    `json:"supplier,omitempty"`
	CreatedAt  time.Time  `json:"created_at"`
}

// ── Pagination ─────────────────────────────────────────────────
type ListMeta struct {
	Total int `json:"total"`
	Page  int `json:"page"`
	Limit int `json:"limit"`
	Pages int `json:"pages"`
}

type ListResponse[T any] struct {
	Data []T      `json:"data"`
	Meta ListMeta `json:"meta"`
}
