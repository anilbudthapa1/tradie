package auth

import (
	"context"
	"fmt"

	"github.com/sendgrid/sendgrid-go"
	"github.com/sendgrid/sendgrid-go/helpers/mail"
)

func (h *Handler) sendPasswordReset(email string) {
	token := generateSecureToken()
	hashed := hashToken(token)
	_, _ = h.db.Exec(context.Background(),
		`INSERT INTO password_reset_tokens (user_id, token_hash, expires_at)
		 SELECT id, $1, NOW()+INTERVAL '1 hour' FROM users WHERE email=$2 AND deleted_at IS NULL`,
		hashed, email)

	if h.cfg.SendGridAPIKey == "" {
		return
	}

	resetURL := fmt.Sprintf("%s/auth/reset-password?token=%s", h.cfg.FrontendURL, token)
	from := mail.NewEmail(h.cfg.EmailFromName, h.cfg.EmailFrom)
	to := mail.NewEmail("", email)
	plainText := fmt.Sprintf("Reset your Tradie password by visiting:\n\n%s\n\nThis link expires in 1 hour. If you didn't request this, ignore this email.", resetURL)
	htmlText := fmt.Sprintf(`
<!DOCTYPE html>
<html>
<body style="font-family:Inter,sans-serif;color:#1E293B;max-width:600px;margin:auto;padding:40px 20px">
  <div style="margin-bottom:32px">
    <div style="width:48px;height:48px;background:#1E40AF;border-radius:12px;display:inline-flex;align-items:center;justify-content:center">
      <span style="color:white;font-size:24px">🔧</span>
    </div>
  </div>
  <h1 style="font-size:24px;margin-bottom:8px">Reset your password</h1>
  <p style="color:#64748B;margin-bottom:32px">Click the button below to reset your Tradie account password. This link expires in 1 hour.</p>
  <a href="%s" style="display:inline-block;background:#1E40AF;color:white;padding:14px 28px;border-radius:10px;text-decoration:none;font-weight:600">Reset Password</a>
  <p style="color:#94A3B8;font-size:12px;margin-top:40px">If you didn't request a password reset, you can safely ignore this email.</p>
</body>
</html>`, resetURL)

	msg := mail.NewSingleEmail(from, "Reset your Tradie password", to, plainText, htmlText)
	client := sendgrid.NewSendClient(h.cfg.SendGridAPIKey)
	_, _ = client.Send(msg)
}

func (h *Handler) sendVerificationEmail(email string) {
	token := generateSecureToken()
	hashed := hashToken(token)
	_, _ = h.db.Exec(context.Background(),
		`INSERT INTO registration_tokens (email, token_hash, expires_at) VALUES ($1,$2,NOW()+INTERVAL '24 hours')
		 ON CONFLICT (token_hash) DO NOTHING`,
		email, hashed)

	if h.cfg.SendGridAPIKey == "" {
		return
	}

	verifyURL := fmt.Sprintf("%s/auth/verify-email?token=%s", h.cfg.FrontendURL, token)
	from := mail.NewEmail(h.cfg.EmailFromName, h.cfg.EmailFrom)
	to := mail.NewEmail("", email)
	plainText := fmt.Sprintf("Verify your Tradie account email by visiting:\n\n%s\n\nThis link expires in 24 hours.", verifyURL)
	htmlText := fmt.Sprintf(`
<!DOCTYPE html>
<html>
<body style="font-family:Inter,sans-serif;color:#1E293B;max-width:600px;margin:auto;padding:40px 20px">
  <div style="margin-bottom:32px">
    <div style="width:48px;height:48px;background:#1E40AF;border-radius:12px;display:inline-flex;align-items:center;justify-content:center">
      <span style="color:white;font-size:24px">🔧</span>
    </div>
  </div>
  <h1 style="font-size:24px;margin-bottom:8px">Verify your email</h1>
  <p style="color:#64748B;margin-bottom:32px">Welcome to Tradie Job Manager! Click the button below to verify your email address and activate your account.</p>
  <a href="%s" style="display:inline-block;background:#1E40AF;color:white;padding:14px 28px;border-radius:10px;text-decoration:none;font-weight:600">Verify Email</a>
  <p style="color:#94A3B8;font-size:12px;margin-top:40px">This link expires in 24 hours.</p>
</body>
</html>`, verifyURL)

	msg := mail.NewSingleEmail(from, "Verify your Tradie email address", to, plainText, htmlText)
	client := sendgrid.NewSendClient(h.cfg.SendGridAPIKey)
	_, _ = client.Send(msg)
}
