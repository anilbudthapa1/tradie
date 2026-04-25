package integrations

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	sendgrid "github.com/sendgrid/sendgrid-go"
	"github.com/sendgrid/sendgrid-go/helpers/mail"
	"github.com/twilio/twilio-go"
	openapi "github.com/twilio/twilio-go/rest/api/v2010"
	"go.uber.org/zap"

	"github.com/tradie/api/internal/config"
	"github.com/tradie/api/internal/middleware"
)

// NotificationsHandler sends transactional emails (SendGrid) and SMS (Twilio).
type NotificationsHandler struct {
	cfg *config.Config
	db  *pgxpool.Pool
	log *zap.Logger
}

func NewNotificationsHandler(cfg *config.Config, db *pgxpool.Pool, log *zap.Logger) *NotificationsHandler {
	return &NotificationsHandler{cfg: cfg, db: db, log: log}
}

// ── Request / response types ──────────────────────────────────────────────────

type sendEmailReq struct {
	ToEmail   string `json:"to_email"`
	ToName    string `json:"to_name"`
	JobID     string `json:"job_id,omitempty"`
	InvoiceID string `json:"invoice_id,omitempty"`
	PaymentID string `json:"payment_id,omitempty"`
}

type sendSMSReq struct {
	ToPhone string `json:"to_phone"`
	JobID   string `json:"job_id"`
}

type sendOverdueReq struct {
	ToEmail string `json:"to_email"`
	ToName  string `json:"to_name"`
	ToPhone string `json:"to_phone,omitempty"`
	InvoiceID string `json:"invoice_id"`
}

// ── SendJobConfirmation ───────────────────────────────────────────────────────
// POST /integrations/notifications/job-confirmation
// Sends an email to the customer when a job is created.

func (h *NotificationsHandler) SendJobConfirmation(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())

	var req sendEmailReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.ToEmail == "" || req.JobID == "" {
		notifRespond(w, 400, map[string]string{"error": "invalid_request"})
		return
	}

	// Fetch job details for the email body.
	var jobTitle, jobDate, jobAddress string
	var jobRef string
	_ = h.db.QueryRow(r.Context(),
		`SELECT COALESCE(title,'Job') AS title,
		        TO_CHAR(scheduled_start AT TIME ZONE 'AEST', 'Day DD Mon YYYY HH12:MI AM') AS job_date,
		        COALESCE(site_address, '') AS address,
		        COALESCE(reference_number, id::text) AS ref
		 FROM jobs WHERE id=$1 AND business_id=$2`,
		req.JobID, bizID,
	).Scan(&jobTitle, &jobDate, &jobAddress, &jobRef)

	// Fetch business name for branding.
	var bizName string
	_ = h.db.QueryRow(r.Context(),
		`SELECT name FROM businesses WHERE id=$1`, bizID,
	).Scan(&bizName)

	subject := fmt.Sprintf("Job Confirmation — %s", jobTitle)
	htmlBody := fmt.Sprintf(`
<div style="font-family:sans-serif;max-width:560px;margin:0 auto;padding:32px 24px">
  <h2 style="color:#1A2332;margin-bottom:4px">Job Confirmed</h2>
  <p style="color:#64748B;margin-top:0">Your job has been scheduled with <strong>%s</strong>.</p>
  <div style="background:#F8FAFC;border-radius:12px;padding:20px;margin:24px 0">
    <p style="margin:0 0 8px"><strong>Job:</strong> %s</p>
    <p style="margin:0 0 8px"><strong>Reference:</strong> %s</p>
    <p style="margin:0 0 8px"><strong>Date &amp; Time:</strong> %s</p>
    %s
  </div>
  <p style="color:#64748B;font-size:13px">If you have any questions, please reply to this email.</p>
</div>`,
		bizName, jobTitle, jobRef, jobDate,
		func() string {
			if jobAddress != "" {
				return fmt.Sprintf(`<p style="margin:0"><strong>Location:</strong> %s</p>`, jobAddress)
			}
			return ""
		}(),
	)

	err := h.sendEmail(r.Context(), req.ToEmail, req.ToName, subject, htmlBody)
	if err != nil {
		h.log.Error("SendJobConfirmation email failed", zap.Error(err))
		notifRespond(w, 500, map[string]string{"error": "email_send_failed"})
		return
	}

	h.logNotification(r.Context(), bizID.String(), "job_confirmation", "email", req.ToEmail, req.JobID)
	notifRespond(w, 200, map[string]string{"message": "sent"})
}

// ── SendInvoiceEmail ──────────────────────────────────────────────────────────
// POST /integrations/notifications/invoice-email
// Sends an invoice email with PDF link to the customer.

func (h *NotificationsHandler) SendInvoiceEmail(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())

	var req sendEmailReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.ToEmail == "" || req.InvoiceID == "" {
		notifRespond(w, 400, map[string]string{"error": "invalid_request"})
		return
	}

	// Fetch invoice details.
	var invoiceNumber string
	var totalAmount float64
	var dueDate *time.Time
	var pdfURL *string
	_ = h.db.QueryRow(r.Context(),
		`SELECT invoice_number, total_amount, due_date, pdf_url
		 FROM invoices WHERE id=$1 AND business_id=$2`,
		req.InvoiceID, bizID,
	).Scan(&invoiceNumber, &totalAmount, &dueDate, &pdfURL)

	var bizName string
	_ = h.db.QueryRow(r.Context(),
		`SELECT name FROM businesses WHERE id=$1`, bizID,
	).Scan(&bizName)

	dueDateStr := "N/A"
	if dueDate != nil {
		dueDateStr = dueDate.Format("02 Jan 2006")
	}

	pdfLink := ""
	if pdfURL != nil && *pdfURL != "" {
		pdfLink = fmt.Sprintf(`<p style="margin:16px 0 0"><a href="%s" style="display:inline-block;background:#2563EB;color:#fff;padding:12px 20px;border-radius:8px;text-decoration:none;font-weight:600">Download Invoice PDF</a></p>`, *pdfURL)
	}

	subject := fmt.Sprintf("Invoice %s from %s", invoiceNumber, bizName)
	htmlBody := fmt.Sprintf(`
<div style="font-family:sans-serif;max-width:560px;margin:0 auto;padding:32px 24px">
  <h2 style="color:#1A2332;margin-bottom:4px">Invoice %s</h2>
  <p style="color:#64748B;margin-top:0">You have a new invoice from <strong>%s</strong>.</p>
  <div style="background:#F8FAFC;border-radius:12px;padding:20px;margin:24px 0">
    <p style="margin:0 0 8px"><strong>Invoice Number:</strong> %s</p>
    <p style="margin:0 0 8px"><strong>Amount Due:</strong> $%.2f AUD</p>
    <p style="margin:0"><strong>Due Date:</strong> %s</p>
  </div>
  %s
  <p style="color:#64748B;font-size:13px;margin-top:24px">Please ensure payment is made by the due date.</p>
</div>`,
		invoiceNumber, bizName, invoiceNumber, totalAmount, dueDateStr, pdfLink,
	)

	err := h.sendEmail(r.Context(), req.ToEmail, req.ToName, subject, htmlBody)
	if err != nil {
		h.log.Error("SendInvoiceEmail failed", zap.Error(err))
		notifRespond(w, 500, map[string]string{"error": "email_send_failed"})
		return
	}

	// Mark invoice as sent.
	_, _ = h.db.Exec(r.Context(),
		`UPDATE invoices SET last_sent_at=NOW() WHERE id=$1 AND business_id=$2`,
		req.InvoiceID, bizID,
	)

	h.logNotification(r.Context(), bizID.String(), "invoice_email", "email", req.ToEmail, req.InvoiceID)
	notifRespond(w, 200, map[string]string{"message": "sent"})
}

// ── SendPaymentReceipt ────────────────────────────────────────────────────────
// POST /integrations/notifications/payment-receipt
// Sends a receipt email when a payment is recorded.

func (h *NotificationsHandler) SendPaymentReceipt(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())

	var req sendEmailReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.ToEmail == "" || req.PaymentID == "" {
		notifRespond(w, 400, map[string]string{"error": "invalid_request"})
		return
	}

	// Fetch payment and invoice details.
	var invoiceNumber, paymentMethod string
	var amount float64
	var paidAt time.Time
	var reference *string
	_ = h.db.QueryRow(r.Context(),
		`SELECT i.invoice_number, p.amount, p.payment_method, p.reference, p.paid_at
		 FROM invoice_payments p
		 JOIN invoices i ON i.id=p.invoice_id
		 WHERE p.id=$1 AND p.business_id=$2`,
		req.PaymentID, bizID,
	).Scan(&invoiceNumber, &amount, &paymentMethod, &reference, &paidAt)

	var bizName string
	_ = h.db.QueryRow(r.Context(),
		`SELECT name FROM businesses WHERE id=$1`, bizID,
	).Scan(&bizName)

	refStr := ""
	if reference != nil && *reference != "" {
		refStr = fmt.Sprintf(`<p style="margin:0 0 8px"><strong>Reference:</strong> %s</p>`, *reference)
	}

	subject := fmt.Sprintf("Payment Receipt — Invoice %s", invoiceNumber)
	htmlBody := fmt.Sprintf(`
<div style="font-family:sans-serif;max-width:560px;margin:0 auto;padding:32px 24px">
  <div style="display:inline-block;background:#D1FAE5;border-radius:50%%;padding:12px;margin-bottom:16px">
    <span style="font-size:24px">✓</span>
  </div>
  <h2 style="color:#1A2332;margin-bottom:4px">Payment Received</h2>
  <p style="color:#64748B;margin-top:0">Thank you — your payment to <strong>%s</strong> has been recorded.</p>
  <div style="background:#F8FAFC;border-radius:12px;padding:20px;margin:24px 0">
    <p style="margin:0 0 8px"><strong>Invoice:</strong> %s</p>
    <p style="margin:0 0 8px"><strong>Amount Paid:</strong> $%.2f AUD</p>
    <p style="margin:0 0 8px"><strong>Payment Method:</strong> %s</p>
    %s
    <p style="margin:0"><strong>Date:</strong> %s</p>
  </div>
  <p style="color:#64748B;font-size:13px">Keep this email as your receipt.</p>
</div>`,
		bizName, invoiceNumber, amount, paymentMethod, refStr, paidAt.Format("02 Jan 2006 15:04"),
	)

	err := h.sendEmail(r.Context(), req.ToEmail, req.ToName, subject, htmlBody)
	if err != nil {
		h.log.Error("SendPaymentReceipt failed", zap.Error(err))
		notifRespond(w, 500, map[string]string{"error": "email_send_failed"})
		return
	}

	h.logNotification(r.Context(), bizID.String(), "payment_receipt", "email", req.ToEmail, req.PaymentID)
	notifRespond(w, 200, map[string]string{"message": "sent"})
}

// ── SendSMSReminder ───────────────────────────────────────────────────────────
// POST /integrations/notifications/sms-reminder
// Sends an SMS to the customer 24h before their job via Twilio.

func (h *NotificationsHandler) SendSMSReminder(w http.ResponseWriter, r *http.Request) {
	if h.cfg.TwilioAccountSID == "" || h.cfg.TwilioAuthToken == "" {
		notifRespond(w, 503, map[string]string{"error": "sms_not_configured"})
		return
	}

	bizID := middleware.BusinessIDFromCtx(r.Context())

	var req sendSMSReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.ToPhone == "" || req.JobID == "" {
		notifRespond(w, 400, map[string]string{"error": "invalid_request"})
		return
	}

	// Fetch job and business details for the SMS body.
	var jobTitle, jobDate, bizName string
	_ = h.db.QueryRow(r.Context(),
		`SELECT COALESCE(j.title,'your job') AS title,
		        TO_CHAR(j.scheduled_start AT TIME ZONE 'AEST', 'Day DD Mon at HH12:MI AM') AS job_date,
		        b.name AS biz_name
		 FROM jobs j
		 JOIN businesses b ON b.id=j.business_id
		 WHERE j.id=$1 AND j.business_id=$2`,
		req.JobID, bizID,
	).Scan(&jobTitle, &jobDate, &bizName)

	body := fmt.Sprintf(
		"Reminder from %s: Your appointment '%s' is tomorrow, %s. Reply STOP to opt out.",
		bizName, jobTitle, jobDate,
	)

	err := h.sendSMS(req.ToPhone, body)
	if err != nil {
		h.log.Error("SendSMSReminder failed", zap.Error(err))
		notifRespond(w, 500, map[string]string{"error": "sms_send_failed"})
		return
	}

	h.logNotification(r.Context(), bizID.String(), "sms_reminder", "sms", req.ToPhone, req.JobID)
	notifRespond(w, 200, map[string]string{"message": "sent"})
}

// ── SendOverdueReminder ───────────────────────────────────────────────────────
// POST /integrations/notifications/overdue-reminder
// Sends an overdue invoice reminder via email and optionally SMS.

func (h *NotificationsHandler) SendOverdueReminder(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())

	var req sendOverdueReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.ToEmail == "" || req.InvoiceID == "" {
		notifRespond(w, 400, map[string]string{"error": "invalid_request"})
		return
	}

	// Fetch invoice details.
	var invoiceNumber string
	var totalAmount float64
	var dueDate *time.Time
	_ = h.db.QueryRow(r.Context(),
		`SELECT invoice_number, total_amount, due_date
		 FROM invoices WHERE id=$1 AND business_id=$2`,
		req.InvoiceID, bizID,
	).Scan(&invoiceNumber, &totalAmount, &dueDate)

	var bizName string
	_ = h.db.QueryRow(r.Context(),
		`SELECT name FROM businesses WHERE id=$1`, bizID,
	).Scan(&bizName)

	dueDateStr := "overdue"
	daysOverdue := 0
	if dueDate != nil {
		dueDateStr = dueDate.Format("02 Jan 2006")
		daysOverdue = int(time.Since(*dueDate).Hours() / 24)
	}

	overdueStr := fmt.Sprintf("%d days overdue", daysOverdue)
	if daysOverdue <= 0 {
		overdueStr = "due"
	}

	// ── Email reminder ──
	subject := fmt.Sprintf("OVERDUE: Invoice %s — $%.2f AUD", invoiceNumber, totalAmount)
	htmlBody := fmt.Sprintf(`
<div style="font-family:sans-serif;max-width:560px;margin:0 auto;padding:32px 24px">
  <div style="background:#FEF2F2;border-left:4px solid #EF4444;padding:12px 16px;border-radius:0 8px 8px 0;margin-bottom:24px">
    <strong style="color:#EF4444">Overdue Invoice Notice</strong>
  </div>
  <h2 style="color:#1A2332;margin-bottom:4px">Payment Required</h2>
  <p style="color:#64748B;margin-top:0">This is a reminder that invoice <strong>%s</strong> from <strong>%s</strong> is %s.</p>
  <div style="background:#F8FAFC;border-radius:12px;padding:20px;margin:24px 0">
    <p style="margin:0 0 8px"><strong>Invoice Number:</strong> %s</p>
    <p style="margin:0 0 8px"><strong>Amount Due:</strong> $%.2f AUD</p>
    <p style="margin:0"><strong>Due Date:</strong> %s</p>
  </div>
  <p style="color:#64748B;font-size:13px">Please arrange payment immediately to avoid further action. Contact us if you have any questions.</p>
</div>`,
		invoiceNumber, bizName, overdueStr, invoiceNumber, totalAmount, dueDateStr,
	)

	emailErr := h.sendEmail(r.Context(), req.ToEmail, req.ToName, subject, htmlBody)
	if emailErr != nil {
		h.log.Error("SendOverdueReminder email failed", zap.Error(emailErr))
		notifRespond(w, 500, map[string]string{"error": "email_send_failed"})
		return
	}
	h.logNotification(r.Context(), bizID.String(), "overdue_reminder", "email", req.ToEmail, req.InvoiceID)

	// ── SMS reminder (optional) ──
	if req.ToPhone != "" && h.cfg.TwilioAccountSID != "" {
		smsBody := fmt.Sprintf(
			"%s: Invoice %s for $%.2f AUD is %s. Please pay immediately. Call us if you have questions.",
			bizName, invoiceNumber, totalAmount, overdueStr,
		)
		if smsErr := h.sendSMS(req.ToPhone, smsBody); smsErr != nil {
			h.log.Warn("SendOverdueReminder SMS failed", zap.Error(smsErr))
			// Don't fail the whole request if only SMS fails.
		} else {
			h.logNotification(r.Context(), bizID.String(), "overdue_reminder", "sms", req.ToPhone, req.InvoiceID)
		}
	}

	notifRespond(w, 200, map[string]string{"message": "sent"})
}

// ── GetNotificationLog ────────────────────────────────────────────────────────
// GET /integrations/notifications/log
// Lists sent notifications from audit_logs (channel: email | sms).

func (h *NotificationsHandler) GetNotificationLog(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())

	rows, err := h.db.Query(r.Context(),
		`SELECT id, action, channel, recipient, entity_id, created_at
		 FROM audit_logs
		 WHERE business_id=$1
		   AND action IN ('job_confirmation','invoice_email','payment_receipt','sms_reminder','overdue_reminder')
		 ORDER BY created_at DESC
		 LIMIT 100`,
		bizID,
	)
	if err != nil {
		h.log.Error("GetNotificationLog query failed", zap.Error(err))
		notifRespond(w, 500, map[string]string{"error": "internal_error"})
		return
	}
	defer rows.Close()

	type LogRow struct {
		ID        string    `json:"id"`
		Action    string    `json:"action"`
		Channel   string    `json:"channel"`
		Recipient string    `json:"recipient"`
		EntityID  *string   `json:"entity_id,omitempty"`
		SentAt    time.Time `json:"sent_at"`
	}

	var logs []LogRow
	for rows.Next() {
		var row LogRow
		if err := rows.Scan(&row.ID, &row.Action, &row.Channel, &row.Recipient, &row.EntityID, &row.SentAt); err != nil {
			continue
		}
		logs = append(logs, row)
	}
	if logs == nil {
		logs = []LogRow{}
	}

	notifRespond(w, 200, map[string]interface{}{"data": logs})
}

// ── Provider helpers ──────────────────────────────────────────────────────────

// sendEmail sends an HTML email via SendGrid.
func (h *NotificationsHandler) sendEmail(ctx context.Context, toEmail, toName, subject, htmlContent string) error {
	if h.cfg.SendGridAPIKey == "" {
		// Dev mode: log and succeed without sending.
		h.log.Info("sendEmail (no-op: SendGrid not configured)",
			zap.String("to", toEmail),
			zap.String("subject", subject))
		return nil
	}

	from := mail.NewEmail(h.cfg.EmailFromName, h.cfg.EmailFrom)
	to := mail.NewEmail(toName, toEmail)
	message := mail.NewSingleEmail(from, subject, to, "", htmlContent)

	client := sendgrid.NewSendClient(h.cfg.SendGridAPIKey)
	resp, err := client.Send(message)
	if err != nil {
		return fmt.Errorf("sendgrid send: %w", err)
	}
	if resp.StatusCode >= 400 {
		return fmt.Errorf("sendgrid returned status %d: %s", resp.StatusCode, resp.Body)
	}
	return nil
}

// sendSMS sends an SMS via Twilio.
func (h *NotificationsHandler) sendSMS(toPhone, body string) error {
	if h.cfg.TwilioAccountSID == "" || h.cfg.TwilioAuthToken == "" {
		h.log.Info("sendSMS (no-op: Twilio not configured)", zap.String("to", toPhone))
		return nil
	}

	client := twilio.NewRestClientWithParams(twilio.ClientParams{
		Username: h.cfg.TwilioAccountSID,
		Password: h.cfg.TwilioAuthToken,
	})

	params := &openapi.CreateMessageParams{}
	params.SetTo(toPhone)
	params.SetFrom(h.cfg.TwilioFromNumber)
	params.SetBody(body)

	_, err := client.Api.CreateMessage(params)
	if err != nil {
		return fmt.Errorf("twilio send: %w", err)
	}
	return nil
}

// logNotification writes a record to audit_logs for notification delivery tracking.
func (h *NotificationsHandler) logNotification(ctx context.Context, bizID, action, channel, recipient, entityID string) {
	_, _ = h.db.Exec(ctx,
		`INSERT INTO audit_logs (business_id, action, channel, recipient, entity_id, created_at)
		 VALUES ($1, $2, $3, $4, $5, NOW())
		 ON CONFLICT DO NOTHING`,
		bizID, action, channel, recipient, entityID,
	)
}

func notifRespond(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if data != nil {
		json.NewEncoder(w).Encode(data)
	}
}
