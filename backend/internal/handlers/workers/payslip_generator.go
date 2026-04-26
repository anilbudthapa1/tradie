// Module 29 (Payslip Generator) — secure payslip PDF generation and
// employee access over the existing payslips table.
package workers

import (
	"bytes"
	"encoding/csv"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"go.uber.org/zap"

	"github.com/tradie/api/internal/middleware"
)

const (
	AuditPayslipViewed       = "PAYSLIP_GENERATOR_MODULE_VIEWED"
	AuditPayslipCreated      = "PAYSLIP_GENERATOR_MODULE_CREATED"
	AuditPayslipUpdated      = "PAYSLIP_GENERATOR_MODULE_UPDATED"
	AuditPayslipDeleted      = "PAYSLIP_GENERATOR_MODULE_DELETED"
	AuditPayslipAccessDenied = "PAYSLIP_GENERATOR_MODULE_ACCESS_DENIED"
	AuditPayslipExported     = "PAYSLIP_GENERATOR_MODULE_EXPORTED"

	maxPayslipBodyBytes = 16 * 1024
)

var allowedPayslipStatus = map[string]bool{
	"draft": true, "locked": true, "paid": true, "cancelled": true,
}

type payslipRow struct {
	ID               uuid.UUID  `json:"id"`
	WorkerID         uuid.UUID  `json:"worker_id"`
	WorkerName       string     `json:"worker_name"`
	PayRunID         uuid.UUID  `json:"pay_run_id"`
	GrossPay         float64    `json:"gross_pay"`
	TaxWithheld      float64    `json:"tax_withheld"`
	NetPay           float64    `json:"net_pay"`
	SuperAmount      float64    `json:"super_amount"`
	HoursWorked      float64    `json:"hours_worked"`
	HourlyRate       float64    `json:"hourly_rate"`
	PeriodStart      time.Time  `json:"period_start"`
	PeriodEnd        time.Time  `json:"period_end"`
	Status           string     `json:"status"`
	PDFGeneratedAt   *time.Time `json:"pdf_generated_at"`
	PDFDownloadCount int        `json:"pdf_download_count"`
	CreatedAt        time.Time  `json:"created_at"`
}

func (h *Handler) requirePayslipPermission(w http.ResponseWriter, r *http.Request, key string) bool {
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
		h.log.Error("payslip permission check", zap.String("key", key), zap.Error(err))
		respond(w, http.StatusInternalServerError, map[string]string{"error": "permission_check_failed"})
		return false
	}
	if !allowed {
		h.audit.Log(r.Context(), middleware.AuditEntry{
			BusinessID: bizID,
			UserID:     claims.UserID,
			Action:     AuditPayslipAccessDenied,
			EntityType: "payslip",
			NewData:    map[string]interface{}{"required": key, "role": claims.Role},
			IPAddress:  r.RemoteAddr,
		})
		respond(w, http.StatusForbidden, map[string]string{"error": "forbidden:" + key})
		return false
	}
	return true
}

func (h *Handler) payslipAuditAction(r *http.Request, action string, id uuid.UUID, oldData, newData interface{}) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	if claims == nil {
		return
	}
	h.audit.Log(r.Context(), middleware.AuditEntry{
		BusinessID: bizID,
		UserID:     claims.UserID,
		Action:     action,
		EntityType: "payslip",
		EntityID:   id,
		OldData:    oldData,
		NewData:    newData,
		IPAddress:  r.RemoteAddr,
	})
}

func (h *Handler) canAccessPayslip(w http.ResponseWriter, r *http.Request, id uuid.UUID, manage bool) (*payslipRow, bool) {
	claims := middleware.ClaimsFromCtx(r.Context())
	if manage {
		if !h.requirePayslipPermission(w, r, "payslips.generate") {
			return nil, false
		}
	} else if middleware.IsAtLeast(claims.Role, "manager") || claims.Role == "accountant" {
		if !h.requirePayslipPermission(w, r, "payslips.generate") {
			return nil, false
		}
	} else if !h.requirePayslipPermission(w, r, "payslips.view_own") {
		return nil, false
	}

	row, err := h.loadPayslip(r, id)
	if err != nil {
		respond(w, http.StatusNotFound, map[string]string{"error": "not_found"})
		return nil, false
	}
	if !manage && !middleware.IsAtLeast(claims.Role, "manager") && claims.Role != "accountant" && row.WorkerID != claims.UserID {
		respond(w, http.StatusForbidden, map[string]string{"error": "forbidden:not_owner"})
		return nil, false
	}
	return row, true
}

func (h *Handler) ListPayslipGenerator(w http.ResponseWriter, r *http.Request) {
	claims := middleware.ClaimsFromCtx(r.Context())
	bizID := middleware.BusinessIDFromCtx(r.Context())
	elevated := middleware.IsAtLeast(claims.Role, "manager") || claims.Role == "accountant"
	if elevated {
		if !h.requirePayslipPermission(w, r, "payslips.generate") {
			return
		}
	} else if !h.requirePayslipPermission(w, r, "payslips.view_own") {
		return
	}

	status := strings.TrimSpace(r.URL.Query().Get("status"))
	if status != "" && !allowedPayslipStatus[status] {
		respond(w, http.StatusBadRequest, map[string]string{"error": "invalid_status"})
		return
	}
	workerID := strings.TrimSpace(r.URL.Query().Get("worker_id"))
	if !elevated {
		workerID = claims.UserID.String()
	}

	args := []interface{}{bizID}
	filters := []string{"ps.business_id=$1", "ps.deleted_at IS NULL"}
	next := 2
	if status != "" {
		filters = append(filters, "ps.status=$"+strconv.Itoa(next))
		args = append(args, status)
		next++
	}
	if workerID != "" {
		if _, err := uuid.Parse(workerID); err != nil {
			respond(w, http.StatusBadRequest, map[string]string{"error": "invalid_worker_id"})
			return
		}
		filters = append(filters, "ps.worker_id=$"+strconv.Itoa(next))
		args = append(args, workerID)
		next++
	}

	rows, err := h.db.Query(r.Context(),
		payslipSelectSQL+` WHERE `+strings.Join(filters, " AND ")+`
		 ORDER BY ps.period_start DESC LIMIT 300`, args...)
	if err != nil {
		respond(w, http.StatusInternalServerError, map[string]string{"error": "query_failed"})
		return
	}
	defer rows.Close()

	out := []payslipRow{}
	for rows.Next() {
		var row payslipRow
		if err := scanPayslip(rows, &row); err == nil {
			out = append(out, row)
		}
	}
	respond(w, http.StatusOK, out)
}

func (h *Handler) MePayslipGeneratorView(w http.ResponseWriter, r *http.Request) {
	if !h.requirePayslipPermission(w, r, "payslips.view_own") {
		return
	}
	q := r.URL.Query()
	q.Set("worker_id", middleware.ClaimsFromCtx(r.Context()).UserID.String())
	r.URL.RawQuery = q.Encode()
	h.ListPayslipGenerator(w, r)
}

func (h *Handler) GetPayslipGenerator(w http.ResponseWriter, r *http.Request) {
	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		respond(w, http.StatusBadRequest, map[string]string{"error": "invalid_id"})
		return
	}
	row, ok := h.canAccessPayslip(w, r, id, false)
	if !ok {
		return
	}
	h.payslipAuditAction(r, AuditPayslipViewed, id, nil, nil)
	respond(w, http.StatusOK, row)
}

// GeneratePayslipRecord marks an existing payslip as PDF-generated. The
// payroll process creates the financial row; this module generates the
// secure document representation.
func (h *Handler) GeneratePayslipRecord(w http.ResponseWriter, r *http.Request) {
	var req struct {
		PayslipID string `json:"payslip_id"`
	}
	if err := decodeStrictPayslip(r, &req); err != nil {
		respond(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}
	id, err := uuid.Parse(req.PayslipID)
	if err != nil {
		respond(w, http.StatusBadRequest, map[string]string{"error": "invalid_payslip_id"})
		return
	}
	if _, ok := h.canAccessPayslip(w, r, id, true); !ok {
		return
	}
	if err := h.markPayslipGenerated(r, id, false); err != nil {
		respond(w, http.StatusInternalServerError, map[string]string{"error": "generate_failed"})
		return
	}
	row, _ := h.loadPayslip(r, id)
	h.payslipAuditAction(r, AuditPayslipCreated, id, nil, map[string]interface{}{"pdf_generated_at": "now"})
	respond(w, http.StatusCreated, row)
}

func (h *Handler) UpdatePayslipGenerator(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		respond(w, http.StatusBadRequest, map[string]string{"error": "invalid_id"})
		return
	}
	current, ok := h.canAccessPayslip(w, r, id, true)
	if !ok {
		return
	}
	var req struct {
		Status string `json:"status"`
	}
	if err := decodeStrictPayslip(r, &req); err != nil {
		respond(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}
	if !allowedPayslipStatus[req.Status] {
		respond(w, http.StatusBadRequest, map[string]string{"error": "invalid_status"})
		return
	}
	if current.Status == "paid" && req.Status != "paid" {
		respond(w, http.StatusConflict, map[string]string{"error": "paid_is_terminal"})
		return
	}

	tag, err := h.db.Exec(r.Context(),
		`UPDATE payslips
		 SET status=$3, updated_by=$4, updated_at=NOW()
		 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID, req.Status, claims.UserID)
	if err != nil {
		respond(w, http.StatusInternalServerError, map[string]string{"error": "update_failed"})
		return
	}
	if tag.RowsAffected() == 0 {
		respond(w, http.StatusNotFound, map[string]string{"error": "not_found"})
		return
	}
	h.payslipAuditAction(r, AuditPayslipUpdated, id,
		map[string]interface{}{"status": current.Status},
		map[string]interface{}{"status": req.Status})
	row, _ := h.loadPayslip(r, id)
	respond(w, http.StatusOK, row)
}

func (h *Handler) DeletePayslipGenerator(w http.ResponseWriter, r *http.Request) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	claims := middleware.ClaimsFromCtx(r.Context())
	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		respond(w, http.StatusBadRequest, map[string]string{"error": "invalid_id"})
		return
	}
	current, ok := h.canAccessPayslip(w, r, id, true)
	if !ok {
		return
	}
	if current.Status == "paid" {
		respond(w, http.StatusConflict, map[string]string{"error": "cannot_delete_paid"})
		return
	}
	tag, err := h.db.Exec(r.Context(),
		`UPDATE payslips
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
	h.payslipAuditAction(r, AuditPayslipDeleted, id,
		map[string]interface{}{"status": current.Status},
		map[string]interface{}{"deleted_at": "now"})
	w.WriteHeader(http.StatusNoContent)
}

func (h *Handler) ExportPayslipGenerator(w http.ResponseWriter, r *http.Request) {
	if !h.requirePayslipPermission(w, r, "payslips.generate") {
		return
	}
	bizID := middleware.BusinessIDFromCtx(r.Context())
	rows, err := h.db.Query(r.Context(),
		payslipSelectSQL+` WHERE ps.business_id=$1 AND ps.deleted_at IS NULL
		 ORDER BY ps.period_start DESC LIMIT 5000`, bizID)
	if err != nil {
		respond(w, http.StatusInternalServerError, map[string]string{"error": "query_failed"})
		return
	}
	defer rows.Close()

	w.Header().Set("Content-Type", "text/csv; charset=utf-8")
	w.Header().Set("Content-Disposition",
		fmt.Sprintf(`attachment; filename="payslips-%s.csv"`, time.Now().Format("2006-01-02")))

	cw := csv.NewWriter(w)
	defer cw.Flush()
	_ = cw.Write([]string{"id", "worker_id", "worker", "pay_run_id", "gross_pay", "tax_withheld", "net_pay", "super_amount", "period_start", "period_end", "status", "pdf_generated_at", "pdf_download_count"})
	for rows.Next() {
		var row payslipRow
		if err := scanPayslip(rows, &row); err != nil {
			continue
		}
		gen := ""
		if row.PDFGeneratedAt != nil {
			gen = row.PDFGeneratedAt.UTC().Format(time.RFC3339)
		}
		_ = cw.Write([]string{
			row.ID.String(), row.WorkerID.String(), row.WorkerName, row.PayRunID.String(),
			fmt.Sprintf("%.2f", row.GrossPay), fmt.Sprintf("%.2f", row.TaxWithheld),
			fmt.Sprintf("%.2f", row.NetPay), fmt.Sprintf("%.2f", row.SuperAmount),
			row.PeriodStart.Format("2006-01-02"), row.PeriodEnd.Format("2006-01-02"),
			row.Status, gen, strconv.Itoa(row.PDFDownloadCount),
		})
	}
	h.payslipAuditAction(r, AuditPayslipExported, uuid.Nil, nil, nil)
}

func (h *Handler) DownloadPayslipPDF(w http.ResponseWriter, r *http.Request) {
	id, err := uuid.Parse(chi.URLParam(r, "id"))
	if err != nil {
		respond(w, http.StatusBadRequest, map[string]string{"error": "invalid_id"})
		return
	}
	row, ok := h.canAccessPayslip(w, r, id, false)
	if !ok {
		return
	}
	if err := h.markPayslipGenerated(r, id, true); err != nil {
		respond(w, http.StatusInternalServerError, map[string]string{"error": "generate_failed"})
		return
	}

	pdf := renderSimplePayslipPDF(row)
	w.Header().Set("Content-Type", "application/pdf")
	w.Header().Set("Content-Disposition", fmt.Sprintf(`attachment; filename="payslip-%s.pdf"`, row.ID.String()))
	w.Header().Set("Cache-Control", "private, no-store")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(pdf)
	h.payslipAuditAction(r, AuditPayslipExported, id, nil, map[string]interface{}{"format": "pdf"})
}

func (h *Handler) markPayslipGenerated(r *http.Request, id uuid.UUID, increment bool) error {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	if increment {
		_, err := h.db.Exec(r.Context(),
			`UPDATE payslips
			 SET pdf_generated_at=COALESCE(pdf_generated_at, NOW()),
			     pdf_download_count=pdf_download_count+1,
			     updated_at=NOW()
			 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
			id, bizID)
		return err
	}
	_, err := h.db.Exec(r.Context(),
		`UPDATE payslips
		 SET pdf_generated_at=COALESCE(pdf_generated_at, NOW()),
		     updated_at=NOW()
		 WHERE id=$1 AND business_id=$2 AND deleted_at IS NULL`,
		id, bizID)
	return err
}

const payslipSelectSQL = `SELECT ps.id, ps.worker_id,
       COALESCE(u.first_name||' '||COALESCE(u.last_name,''), '') AS worker_name,
       ps.pay_run_id, ps.gross_pay, ps.tax_withheld, ps.net_pay, ps.super_amount,
       ps.hours_worked, ps.hourly_rate, ps.period_start, ps.period_end, ps.status,
       ps.pdf_generated_at, ps.pdf_download_count, ps.created_at
 FROM payslips ps
 JOIN users u ON u.id=ps.worker_id`

type payslipScanner interface {
	Scan(dest ...interface{}) error
}

func scanPayslip(s payslipScanner, row *payslipRow) error {
	return s.Scan(&row.ID, &row.WorkerID, &row.WorkerName, &row.PayRunID,
		&row.GrossPay, &row.TaxWithheld, &row.NetPay, &row.SuperAmount,
		&row.HoursWorked, &row.HourlyRate, &row.PeriodStart, &row.PeriodEnd,
		&row.Status, &row.PDFGeneratedAt, &row.PDFDownloadCount, &row.CreatedAt)
}

func (h *Handler) loadPayslip(r *http.Request, id uuid.UUID) (*payslipRow, error) {
	bizID := middleware.BusinessIDFromCtx(r.Context())
	var row payslipRow
	err := h.db.QueryRow(r.Context(),
		payslipSelectSQL+` WHERE ps.id=$1 AND ps.business_id=$2 AND ps.deleted_at IS NULL`,
		id, bizID).Scan(&row.ID, &row.WorkerID, &row.WorkerName, &row.PayRunID,
		&row.GrossPay, &row.TaxWithheld, &row.NetPay, &row.SuperAmount,
		&row.HoursWorked, &row.HourlyRate, &row.PeriodStart, &row.PeriodEnd,
		&row.Status, &row.PDFGeneratedAt, &row.PDFDownloadCount, &row.CreatedAt)
	if err != nil {
		return nil, err
	}
	return &row, nil
}

func decodeStrictPayslip(r *http.Request, dst interface{}) error {
	r.Body = http.MaxBytesReader(nil, r.Body, maxPayslipBodyBytes)
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
	if dec.Decode(&struct{}{}) != io.EOF {
		return errors.New("trailing_data")
	}
	return nil
}

func renderSimplePayslipPDF(row *payslipRow) []byte {
	lines := []string{
		"Tradie Job Manager Payslip",
		"Payslip ID: " + row.ID.String(),
		"Employee: " + row.WorkerName,
		"Period: " + row.PeriodStart.Format("2006-01-02") + " to " + row.PeriodEnd.Format("2006-01-02"),
		fmt.Sprintf("Hours: %.2f", row.HoursWorked),
		fmt.Sprintf("Hourly rate: $%.2f", row.HourlyRate),
		fmt.Sprintf("Gross pay: $%.2f", row.GrossPay),
		fmt.Sprintf("Tax withheld: $%.2f", row.TaxWithheld),
		fmt.Sprintf("Superannuation: $%.2f", row.SuperAmount),
		fmt.Sprintf("Net pay: $%.2f", row.NetPay),
		"Status: " + row.Status,
	}
	var text bytes.Buffer
	text.WriteString("BT /F1 14 Tf 50 780 Td ")
	for i, line := range lines {
		if i > 0 {
			text.WriteString("0 -24 Td ")
		}
		text.WriteString("(" + pdfEscape(line) + ") Tj ")
	}
	text.WriteString("ET")
	stream := text.String()
	objects := []string{
		"<< /Type /Catalog /Pages 2 0 R >>",
		"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
		"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
		"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
		fmt.Sprintf("<< /Length %d >>\nstream\n%s\nendstream", len(stream), stream),
	}
	var out bytes.Buffer
	out.WriteString("%PDF-1.4\n")
	offsets := make([]int, 0, len(objects)+1)
	offsets = append(offsets, 0)
	for i, obj := range objects {
		offsets = append(offsets, out.Len())
		out.WriteString(fmt.Sprintf("%d 0 obj\n%s\nendobj\n", i+1, obj))
	}
	xref := out.Len()
	out.WriteString(fmt.Sprintf("xref\n0 %d\n", len(objects)+1))
	out.WriteString("0000000000 65535 f \n")
	for _, off := range offsets[1:] {
		out.WriteString(fmt.Sprintf("%010d 00000 n \n", off))
	}
	out.WriteString(fmt.Sprintf("trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n", len(objects)+1, xref))
	return out.Bytes()
}

func pdfEscape(s string) string {
	s = strings.ReplaceAll(s, `\`, `\\`)
	s = strings.ReplaceAll(s, "(", `\(`)
	s = strings.ReplaceAll(s, ")", `\)`)
	return s
}
