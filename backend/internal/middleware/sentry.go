package middleware

import (
	"net/http"
	"runtime/debug"

	"go.uber.org/zap"
)

// RecoverWithSentry returns an HTTP middleware that recovers from panics,
// logs them via zap, and forwards them to Sentry when sentry-go is wired.
//
// Sentry init lives in cmd/main.go (added by the parent merge — see
// BATCH_12_MANIFEST.md for the exact snippet). This middleware is independent
// of init: when SENTRY_DSN is empty or sentry-go has not yet been imported,
// it falls back to the same behaviour as chi's Recoverer (5xx + structured log).
//
// To enable Sentry forwarding once `github.com/getsentry/sentry-go` is on the
// module graph, replace the body of the recover branch with:
//
//	hub := sentry.GetHubFromContext(r.Context())
//	if hub == nil {
//	    hub = sentry.CurrentHub().Clone()
//	}
//	hub.RecoverWithContext(r.Context(), rec)
//	hub.Flush(2 * time.Second)
//
// and add `sentryhttp.New(sentryhttp.Options{Repanic: true}).Handle(next)`
// upstream of this middleware in router.go.
func RecoverWithSentry(log *zap.Logger) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			defer func() {
				if rec := recover(); rec != nil {
					// Always log the panic locally so we have a record even
					// if Sentry is not configured.
					log.Error("panic recovered",
						zap.Any("error", rec),
						zap.String("path", r.URL.Path),
						zap.String("method", r.Method),
						zap.ByteString("stack", debug.Stack()),
					)

					// Sentry forwarding hook — implemented when sentry-go is
					// added to go.mod. Until then, this is a no-op so that
					// the middleware can be wired into the router safely.
					sentryCapture(r, rec)

					if w.Header().Get("Content-Type") == "" {
						w.Header().Set("Content-Type", "application/json")
					}
					w.WriteHeader(http.StatusInternalServerError)
					_, _ = w.Write([]byte(`{"error":"internal_server_error"}`))
				}
			}()
			next.ServeHTTP(w, r)
		})
	}
}

// sentryCapture is the swap point for sentry-go integration. The default
// implementation is a no-op so that this file compiles without an extra
// dependency. The Phase-B merge replaces the body with a call to
// `sentry.CurrentHub().Clone().RecoverWithContext(ctx, rec)`.
//
//nolint:unused // intentional swap point — body replaced when sentry-go lands.
func sentryCapture(r *http.Request, rec interface{}) {
	_ = r
	_ = rec
}
