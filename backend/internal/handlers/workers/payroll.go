// Module 28 (Payroll) — spec-compliance shim layered over the
// existing pay-run / payslip / superannuation methods.
//
// Adds:
//   - requirePayrollPermission()  payroll.view / .process / .export
//   - Spec audit names PAYROLL_MODULE_*
//   - payrollAuditAction() shared audit emitter
//   - MePayrollView()    GET /api/v1/me/payroll_module
//   - CancelPayRun()     POST /api/v1/payroll/runs/{id}/cancel
//   - MarkPayRunPaid()   POST /api/v1/payroll/runs/{id}/pay
//   - ExportPayRuns()    GET /api/v1/payroll/runs/export.csv
//   - decodeStrictPayroll() DisallowUnknownFields + 16 KiB body cap
//
// Also overwrites the legacy ProcessPayRun in workers.go to:
//   - Wrap the calculation + insert + update in a transaction
//   - Read per-worker hourly_rate from business_employee_details
//     (fallback to default_work_hours-derived rate)
//   - Read super_rate + tax_rate from business_payroll_settings
//   - Stop discarding errors with `_, _ =`
//   - Emit PAYROLL_MODULE_UPDATED with old/new totals
package workers

import (
	"context"
	"encoding/csv"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"go.uber.org/zap"

	"github.com/tradie/api/internal/middleware"
)

// ── Audit event names (spec §Audit Events) ───────────────────────
const (
	AuditPayrollViewed       = "PAYROLL_MODULE_VIEWED"
	AuditPayrollCreated      = "PAYROLL_MODULE_CREATED"
	AuditPayrollUpdated      = "PAYROLL_MODULE_UPDATED"
	AuditPayrollDeleted      = "PAYROLL_MODULE_DELETED"
	AuditPayrollAccessDenied = "PAYROLL_MODULE_ACCESS_DENIED"
	AuditPayrollExported     = "PAYROLL_MODULE_EXPORTED"

	maxPayrollBodyBytes = 16 * 1024

	// Fallback rates if a tenant hasn't filled in business_payroll_settings
	// or a worker has no hourly_rate on business_employee_details.
	defaultHourlyRate = 35.00 // matches the legacy hardcoded value
	defaultTaxRate    = 19.0
	defaultSuperRate  = 11.0
)

var allowedPayRunStatus = map[string]bool{
	"draft": true, "processed": true, "paid": true, "cancelled": true,
}

// ── Permission enforcement ──────────────────────────────────────

func (h *Handler) requirePayrollPermission(w http.ResponseWriter, r *http.Request, key string) bool {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if claims == nil {
		respond(w, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
		return false
	}

	var allowed bool
	err := h.db.QueryRow(r.Context(),
		`SELECT EXISTS(
		   SELECT 1
		   FROM role_permissions rp
		   JOIN permissions p ON p.id = rp.permission_id
		   WHERE rp.role=$1 AND p.key=$2
		     AND (rp.business_id=$3 OR
		          (rp.business_id IS NULL AND NOT EXISTS (
		             SELECT 1 FROM role_permissions rp2 WHERE rp2.role=$1 AND rp2.business_id=$3
		          )))
		 )`,
		claims.Role, key, bizID).Scan(&allowed)
	if err != nil {
		h.log.Error("payroll permission check", zap.String("key", key), zap.Error(err))
		respond(w, http.StatusInternalServerError, map[string]string{"error": "permission_check_failed"})
		return false
	}
	if !allowed {
		h.audit.Log(r.Context(), middleware.AuditEntry{
			BusinessID: bizID,
			UserID:     claims.UserID,
			Action:     AuditPayrollAccessDenied,
			EntityType: "pay_run",
			NewData:    map[string]interface{}{"required": key, "role": claims.Role},
			IPAddress:  r.RemoteAddr,
		})
		respond(w, http.StatusForbidden, map[string]string{"error": "forbidden:" + key})
		return false
	}
	return true
}

func (h *Handler) payrollAuditAction(r *http.Request, action string, id uuid.UUID, oldData, newData interface{}) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if claims == nil {
		return
	}
	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     action,
		EntityType: "pay_run",
		EntityID:   id,
		OldData:    oldData,
		NewData:    newData,
		IPAddress:  r.RemoteAddr,
	})
}

// ── Self-service ────────────────────────────────────────────────

// MePayrollView returns the calling worker's payslips in the last 12
// months plus aggregate gross / net / super.
func (h *Handler) MePayrollView(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	// Use payroll.view for elevated callers; workers always see own
	// regardless of catalogue grant (the /me endpoint is theirs by design).
	if middleware.IsAtLeast(claims.Role, "manager") {
		if !h.requirePayrollPermission(w, r, "payroll.view") {
			return
		}
	}

	rows, err := h.db.Query(r.Context(),
		`SELECT id, pay_run_id, gross_pay, tax_withheld, net_pay, super_amount,
		        period_start, period_end, status, created_at
		 FROM payslips
		 WHERE business_id=$1 AND worker_id=$2 AND deleted_at IS NULL
		   AND period_start >= NOW() - INTERVAL '12 months'
		 ORDER BY period_start DESC LIMIT 50`,
		bizID, claims.UserID)
	if err != nil {
		respond(w, http.StatusInternalServerError, map[string]string{"error": "query_failed"})
		return
	}
	defer rows.Close()

	type slip struct {
		ID          uuid.UUID `json:"id"`
		PayRunID    uuid.UUID `json:"pay_run_id"`
		GrossPay    float64   `json:"gross_pay"`
		TaxWithheld float64   `json:"tax_withheld"`
		NetPay      float64   `json:"net_pay"`
		SuperAmount float64   `json:"super_amount"`
		PeriodStart time.Time `json:"period_start"`
		PeriodEnd   time.Time `json:"period_end"`
		Status      string    `json:"status"`
		CreatedAt   time.Time `json:"created_at"`
	}
	out := []slip{}
	var totalGross, totalNet, totalSuper float64
	for rows.Next() {
		var s slip
		if err := rows.Scan(&s.ID, &s.PayRunID, &s.GrossPay, &s.TaxWithheld, &s.NetPay,
			&s.SuperAmount, &s.PeriodStart, &s.PeriodEnd, &s.Status, &s.CreatedAt); err == nil {
			totalGross += s.GrossPay
			totalNet += s.NetPay
			totalSuper += s.SuperAmount
			out = append(out, s)
		}
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditPayrollViewed,
		EntityType: "pay_run.me",
		IPAddress:  r.RemoteAddr,
	})

	respond(w, http.StatusOK, map[string]interface{}{
		"payslips":      out,
		"total_gross":   totalGross,
		"total_net":     totalNet,
		"total_super":   totalSuper,
		"window_months": 12,
	})
}

// UpdatePayRun (PATCH /api/v1/payroll_module/{id}) edits an unprocessed
// draft pay run. Processed/paid runs are immutable except lifecycle
// transitions.
func (h *Handler) UpdatePayRun(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePayrollPermission(w, r, "payroll.process") {
		return
	}

	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		respond(w, http.StatusBadRequest, map[string]string{"error": "invalid_id"})
		return
	}

	var req struct {
		PeriodStart *string `json:"period_start"`
		PeriodEnd   *string `json:"period_end"`
		PayDate     *string `json:"pay_date"`
	}
	if err := decodeStrictPayroll(r, &req); err != nil {
		respond(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}
	if req.PeriodStart == nil && req.PeriodEnd == nil && req.PayDate == nil {
		respond(w, http.StatusBadRequest, map[string]string{"error": "empty_patch"})
		return
	}

	var currentStatus string
	var curStart, curEnd, curPay time.Time
	err = h.db.QueryRow(r.Context(),
		`SELECT status, period_start, period_end, pay_date
		 FROM pay_runs
		 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID,
	).Scan(&currentStatus, &curStart, &curEnd, &curPay)
	if err != nil {
		respond(w, http.StatusNotFound, map[string]string{"error": "not_found"})
		return
	}
	if currentStatus != "draft" {
		respond(w, http.StatusConflict, map[string]string{
			"error":  "cannot_edit",
			"status": currentStatus,
		})
		return
	}

	nextStart := curStart
	nextEnd := curEnd
	nextPay := curPay
	if req.PeriodStart != nil {
		nextStart, err = time.Parse("2006-01-02", strings.TrimSpace(*req.PeriodStart))
		if err != nil {
			respond(w, http.StatusBadRequest, map[string]string{"error": "invalid_period_start"})
			return
		}
	}
	if req.PeriodEnd != nil {
		nextEnd, err = time.Parse("2006-01-02", strings.TrimSpace(*req.PeriodEnd))
		if err != nil {
			respond(w, http.StatusBadRequest, map[string]string{"error": "invalid_period_end"})
			return
		}
	}
	if req.PayDate != nil {
		nextPay, err = time.Parse("2006-01-02", strings.TrimSpace(*req.PayDate))
		if err != nil {
			respond(w, http.StatusBadRequest, map[string]string{"error": "invalid_pay_date"})
			return
		}
	}
	if nextEnd.Before(nextStart) {
		respond(w, http.StatusBadRequest, map[string]string{"error": "end_before_start"})
		return
	}
	if nextPay.Before(nextStart) {
		respond(w, http.StatusBadRequest, map[string]string{"error": "pay_date_before_period_start"})
		return
	}

	var conflictID uuid.UUID
	err = h.db.QueryRow(r.Context(),
		`SELECT id FROM pay_runs
		 WHERE business_id=$1 AND id<>$2 AND deleted_at IS NULL AND status <> 'cancelled'
		   AND daterange(period_start, period_end, '[]') && daterange($3::DATE, $4::DATE, '[]')
		 LIMIT 1`,
		bizID, id, nextStart.Format("2006-01-02"), nextEnd.Format("2006-01-02"),
	).Scan(&conflictID)
	if err == nil {
		respond(w, http.StatusConflict, map[string]string{
			"error":          "overlapping_pay_run",
			"conflicts_with": conflictID.String(),
		})
		return
	}

	tag, err := h.db.Exec(r.Context(),
		`UPDATE pay_runs
		   SET period_start=$3::DATE,
		       period_end=$4::DATE,
		       pay_date=$5::DATE,
		       updated_by=$6,
		       updated_at=NOW()
		 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL AND status='draft'`,
		id, bizID,
		nextStart.Format("2006-01-02"),
		nextEnd.Format("2006-01-02"),
		nextPay.Format("2006-01-02"),
		claims.UserID,
	)
	if err != nil {
		respond(w, http.StatusInternalServerError, map[string]string{"error": "update_failed"})
		return
	}
	if tag.RowsAffected() == 0 {
		respond(w, http.StatusNotFound, map[string]string{"error": "not_found"})
		return
	}

	h.payrollAuditAction(r, AuditPayrollUpdated, id,
		map[string]interface{}{
			"period_start": curStart.Format("2006-01-02"),
			"period_end":   curEnd.Format("2006-01-02"),
			"pay_date":     curPay.Format("2006-01-02"),
		},
		map[string]interface{}{
			"period_start": nextStart.Format("2006-01-02"),
			"period_end":   nextEnd.Format("2006-01-02"),
			"pay_date":     nextPay.Format("2006-01-02"),
		})

	h.GetPayRun(w, r)
}

// DeletePayRun soft deletes draft/cancelled pay runs. Processed and paid
// runs are retained for payroll audit integrity.
func (h *Handler) DeletePayRun(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePayrollPermission(w, r, "payroll.process") {
		return
	}

	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		respond(w, http.StatusBadRequest, map[string]string{"error": "invalid_id"})
		return
	}

	var status string
	err = h.db.QueryRow(r.Context(),
		`SELECT status FROM pay_runs
		 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID,
	).Scan(&status)
	if err != nil {
		respond(w, http.StatusNotFound, map[string]string{"error": "not_found"})
		return
	}
	if status != "draft" && status != "cancelled" {
		respond(w, http.StatusConflict, map[string]string{
			"error":  "cannot_delete",
			"status": status,
		})
		return
	}

	tx, err := h.db.Begin(r.Context())
	if err != nil {
		respond(w, http.StatusInternalServerError, map[string]string{"error": "tx_failed"})
		return
	}
	defer tx.Rollback(r.Context())

	if _, err := tx.Exec(r.Context(),
		`UPDATE payslips
		 SET deleted_at=NOW(), updated_by=$3, updated_at=NOW()
		 WHERE pay_run_id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID, claims.UserID); err != nil {
		respond(w, http.StatusInternalServerError, map[string]string{"error": "delete_payslips_failed"})
		return
	}
	tag, err := tx.Exec(r.Context(),
		`UPDATE pay_runs
		 SET deleted_at=NOW(), updated_by=$3, updated_at=NOW()
		 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID, claims.UserID)
	if err != nil {
		respond(w, http.StatusInternalServerError, map[string]string{"error": "delete_failed"})
		return
	}
	if tag.RowsAffected() == 0 {
		respond(w, http.StatusNotFound, map[string]string{"error": "not_found"})
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		respond(w, http.StatusInternalServerError, map[string]string{"error": "commit_failed"})
		return
	}

	h.payrollAuditAction(r, AuditPayrollDeleted, id,
		map[string]interface{}{"status": status},
		map[string]interface{}{"deleted_at": "now"})

	w.WriteHeader(http.StatusNoContent)
}

// ── Cancel / Mark paid ──────────────────────────────────────────

// CancelPayRun (POST /api/v1/payroll/runs/{id}/cancel) — only valid
// from `draft` or `processed`. `paid` is terminal.
func (h *Handler) CancelPayRun(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePayrollPermission(w, r, "payroll.process") {
		return
	}

	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		respond(w, http.StatusBadRequest, map[string]string{"error": "invalid_id"})
		return
	}

	tag, err := h.db.Exec(r.Context(),
		`UPDATE pay_runs
		   SET status='cancelled', updated_by=$3, updated_at=NOW()
		 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL
		   AND status IN ('draft','processed')`,
		id, bizID, claims.UserID)
	if err != nil {
		if strings.Contains(err.Error(), "invalid_status_transition") {
			respond(w, http.StatusConflict, map[string]string{"error": "invalid_status_transition"})
			return
		}
		respond(w, http.StatusInternalServerError, map[string]string{"error": "cancel_failed"})
		return
	}
	if tag.RowsAffected() == 0 {
		respond(w, http.StatusConflict, map[string]string{"error": "not_found_or_already_terminal"})
		return
	}

	h.payrollAuditAction(r, AuditPayrollDeleted, id, nil,
		map[string]interface{}{"status": "cancelled"})

	respond(w, http.StatusOK, map[string]string{"id": id.String(), "status": "cancelled"})
}

// MarkPayRunPaid (POST /api/v1/payroll/runs/{id}/pay) — flips
// processed → paid. Terminal once paid (financial integrity).
func (h *Handler) MarkPayRunPaid(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePayrollPermission(w, r, "payroll.process") {
		return
	}

	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		respond(w, http.StatusBadRequest, map[string]string{"error": "invalid_id"})
		return
	}

	tx, err := h.db.Begin(r.Context())
	if err != nil {
		respond(w, http.StatusInternalServerError, map[string]string{"error": "tx_failed"})
		return
	}
	defer tx.Rollback(r.Context())

	tag, err := tx.Exec(r.Context(),
		`UPDATE pay_runs
		   SET status='paid', paid_at=NOW(), updated_by=$3, updated_at=NOW()
		 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL AND status='processed'`,
		id, bizID, claims.UserID)
	if err != nil {
		if strings.Contains(err.Error(), "invalid_status_transition") {
			respond(w, http.StatusConflict, map[string]string{"error": "invalid_status_transition"})
			return
		}
		respond(w, http.StatusInternalServerError, map[string]string{"error": "pay_failed"})
		return
	}
	if tag.RowsAffected() == 0 {
		respond(w, http.StatusConflict, map[string]string{"error": "not_found_or_invalid_state"})
		return
	}

	// Lock all payslips on this run.
	if _, err := tx.Exec(r.Context(),
		`UPDATE payslips SET status='paid', updated_by=$3, updated_at=NOW()
		 WHERE pay_run_id=$1 AND business_id=$2 AND deleted_at IS NULL AND status IN ('draft','locked')`,
		id, bizID, claims.UserID); err != nil {
		respond(w, http.StatusInternalServerError, map[string]string{"error": "lock_payslips_failed"})
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		respond(w, http.StatusInternalServerError, map[string]string{"error": "commit_failed"})
		return
	}

	h.payrollAuditAction(r, AuditPayrollUpdated, id, nil,
		map[string]interface{}{"status": "paid"})

	respond(w, http.StatusOK, map[string]string{"id": id.String(), "status": "paid"})
}

// ── Export ──────────────────────────────────────────────────────

func (h *Handler) ExportPayRuns(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if !h.requirePayrollPermission(w, r, "payroll.export") {
		return
	}

	rows, err := h.db.Query(r.Context(),
		`SELECT pr.id, pr.period_start, pr.period_end, pr.pay_date, pr.status,
		        pr.total_gross, pr.total_tax, pr.total_net,
		        (SELECT COUNT(*) FROM payslips ps
		         WHERE ps.pay_run_id=pr.id AND ps.deleted_at IS NULL) AS payslip_count,
		        pr.created_at, pr.processed_at, pr.paid_at
		 FROM pay_runs pr
		 WHERE pr.business_id=$1 AND pr.deleted_at IS NULL
		 ORDER BY pr.period_start DESC LIMIT 5000`,
		bizID)
	if err != nil {
		respond(w, http.StatusInternalServerError, map[string]string{"error": "query_failed"})
		return
	}
	defer rows.Close()

	w.Header().Set("Content-Type", "text/csv; charset=utf-8")
	w.Header().Set("Content-Disposition",
		fmt.Sprintf(`attachment; filename="pay-runs-%s.csv"`, time.Now().Format("2006-01-02")))

	cw := csv.NewWriter(w)
	defer cw.Flush()
	_ = cw.Write([]string{"id", "period_start", "period_end", "pay_date", "status",
		"total_gross", "total_tax", "total_net", "payslip_count",
		"created_at", "processed_at", "paid_at"})

	for rows.Next() {
		var id uuid.UUID
		var periodStart, periodEnd, payDate time.Time
		var status string
		var gross, tax, net float64
		var count int
		var createdAt time.Time
		var processedAt, paidAt *time.Time
		if err := rows.Scan(&id, &periodStart, &periodEnd, &payDate, &status,
			&gross, &tax, &net, &count, &createdAt, &processedAt, &paidAt); err != nil {
			continue
		}
		processedStr := ""
		if processedAt != nil {
			processedStr = processedAt.UTC().Format(time.RFC3339)
		}
		paidStr := ""
		if paidAt != nil {
			paidStr = paidAt.UTC().Format(time.RFC3339)
		}
		_ = cw.Write([]string{
			id.String(),
			periodStart.Format("2006-01-02"),
			periodEnd.Format("2006-01-02"),
			payDate.Format("2006-01-02"),
			status,
			fmt.Sprintf("%.2f", gross),
			fmt.Sprintf("%.2f", tax),
			fmt.Sprintf("%.2f", net),
			fmt.Sprintf("%d", count),
			createdAt.UTC().Format(time.RFC3339),
			processedStr, paidStr,
		})
	}

	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     AuditPayrollExported,
		EntityType: "pay_run",
		IPAddress:  r.RemoteAddr,
	})
}

// ── Tenant payroll rates loader ─────────────────────────────────

// payrollRates resolves the per-tenant tax + super rates with
// fallbacks, and returns a per-worker rate resolver. Called once per
// pay-run processing so we hit the settings table only twice rather
// than once per worker.
type payrollRates struct {
	taxRatePct   float64 // e.g. 19.0
	superRatePct float64 // e.g. 11.0
}

func (h *Handler) loadPayrollRates(ctx context.Context, bizID uuid.UUID) payrollRates {
	rates := payrollRates{taxRatePct: defaultTaxRate, superRatePct: defaultSuperRate}
	var taxRate, superRate *float64
	_ = h.db.QueryRow(ctx,
		`SELECT tax_rate::float8, super_rate::float8
		 FROM business_payroll_settings
		 WHERE business_id=$1`, bizID,
	).Scan(&taxRate, &superRate)
	if taxRate != nil {
		rates.taxRatePct = *taxRate
	}
	if superRate != nil {
		rates.superRatePct = *superRate
	}
	return rates
}

// hourlyRateFor reads the worker's per-hour rate from
// business_employee_details. Returns the default if absent.
func (h *Handler) hourlyRateFor(ctx context.Context, workerID, bizID uuid.UUID) float64 {
	var rate *float64
	_ = h.db.QueryRow(ctx,
		`SELECT hourly_rate::float8 FROM business_employee_details
		 WHERE user_id=$1 AND business_id=$2`,
		workerID, bizID).Scan(&rate)
	if rate == nil || *rate <= 0 {
		return defaultHourlyRate
	}
	return *rate
}

// ── Strict decoding ─────────────────────────────────────────────

func decodeStrictPayroll(r *http.Request, dst interface{}) error {
	r.Body = http.MaxBytesReader(nil, r.Body, maxPayrollBodyBytes)
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(dst); err != nil {
		var maxErr *http.MaxBytesError
		if errors.As(err, &maxErr) {
			return errors.New("body_too_large")
		}
		if errors.Is(err, io.EOF) {
			return errors.New("empty_body")
		}
		return errors.New("invalid_request")
	}
	if dec.More() {
		return errors.New("trailing_data")
	}
	return nil
}
