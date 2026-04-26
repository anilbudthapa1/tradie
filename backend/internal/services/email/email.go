// Package email is the single email-sending seam used by all handlers
// and background workers. It wraps SendGrid when an API key is
// configured and falls back to a no-op log in development so every
// caller can be wired identically without provider-specific guards.
package email

import (
	"context"
	"fmt"

	"github.com/sendgrid/sendgrid-go"
	"github.com/sendgrid/sendgrid-go/helpers/mail"
	"go.uber.org/zap"

	"github.com/tradie/api/internal/config"
)

type Service struct {
	cfg *config.Config
	log *zap.Logger
}

func NewService(cfg *config.Config, log *zap.Logger) *Service {
	return &Service{cfg: cfg, log: log}
}

// Configured reports whether real email delivery is available. Useful
// for handlers that want to skip generating a payload when nothing
// will be sent.
func (s *Service) Configured() bool {
	return s.cfg.SendGridAPIKey != ""
}

// Send delivers an HTML email. In dev (no API key) it logs and returns
// nil so the caller's flow proceeds normally.
func (s *Service) Send(ctx context.Context, toEmail, toName, subject, htmlContent string) error {
	if toEmail == "" {
		return fmt.Errorf("email: empty recipient")
	}
	if !s.Configured() {
		s.log.Info("email send (no-op: SendGrid not configured)",
			zap.String("to", toEmail),
			zap.String("subject", subject),
		)
		return nil
	}
	from := mail.NewEmail(s.cfg.EmailFromName, s.cfg.EmailFrom)
	to := mail.NewEmail(toName, toEmail)
	msg := mail.NewSingleEmail(from, subject, to, "", htmlContent)
	resp, err := sendgrid.NewSendClient(s.cfg.SendGridAPIKey).SendWithContext(ctx, msg)
	if err != nil {
		return fmt.Errorf("sendgrid: %w", err)
	}
	if resp.StatusCode >= 400 {
		return fmt.Errorf("sendgrid status %d: %s", resp.StatusCode, resp.Body)
	}
	return nil
}
