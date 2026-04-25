package middleware

import (
	"context"
	"net/http"
	"strings"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
	"github.com/tradie/api/internal/models"
)

type contextKey string

const (
	CtxUser       contextKey = "user"
	CtxBusiness   contextKey = "business"
	CtxBusinessID contextKey = "business_id"
)

type Claims struct {
	UserID     uuid.UUID `json:"sub"`
	BusinessID uuid.UUID `json:"bid"`
	Role       string    `json:"role"`
	jwt.RegisteredClaims
}

func Auth(jwtSecret string) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			token := extractBearerToken(r)
			if token == "" {
				http.Error(w, `{"error":"unauthorized"}`, http.StatusUnauthorized)
				return
			}

			claims := &Claims{}
			_, err := jwt.ParseWithClaims(token, claims, func(t *jwt.Token) (interface{}, error) {
				if _, ok := t.Method.(*jwt.SigningMethodHMAC); !ok {
					return nil, jwt.ErrSignatureInvalid
				}
				return []byte(jwtSecret), nil
			})
			if err != nil {
				http.Error(w, `{"error":"invalid_token"}`, http.StatusUnauthorized)
				return
			}

			ctx := context.WithValue(r.Context(), CtxUser, claims)
			ctx = context.WithValue(ctx, CtxBusinessID, claims.BusinessID)
			next.ServeHTTP(w, r.WithContext(ctx))
		})
	}
}

func RequireRole(roles ...string) func(http.Handler) http.Handler {
	allowed := make(map[string]bool, len(roles))
	for _, r := range roles {
		allowed[r] = true
	}
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			claims := ClaimsFromCtx(r.Context())
			if claims == nil || !allowed[claims.Role] {
				http.Error(w, `{"error":"forbidden"}`, http.StatusForbidden)
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}

func ClaimsFromCtx(ctx context.Context) *Claims {
	c, _ := ctx.Value(CtxUser).(*Claims)
	return c
}

func BusinessIDFromCtx(ctx context.Context) uuid.UUID {
	if c := ClaimsFromCtx(ctx); c != nil {
		return c.BusinessID
	}
	return uuid.Nil
}

func UserFromCtx(ctx context.Context) *models.User {
	u, _ := ctx.Value(CtxUser).(*models.User)
	return u
}

func extractBearerToken(r *http.Request) string {
	h := r.Header.Get("Authorization")
	if strings.HasPrefix(h, "Bearer ") {
		return strings.TrimPrefix(h, "Bearer ")
	}
	// also accept cookie for SSR/web
	if c, err := r.Cookie("access_token"); err == nil {
		return c.Value
	}
	return ""
}
