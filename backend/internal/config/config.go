package config

import (
	"os"
	"strconv"
	"time"
)

type Config struct {
	Env         string
	Port        string
	BaseURL     string
	FrontendURL string

	DatabaseURL string
	RedisURL    string

	JWTSecret     string
	JWTAccessTTL  time.Duration
	JWTRefreshTTL time.Duration

	S3Endpoint     string
	S3Region       string
	S3Bucket       string
	S3AccessKey    string
	S3SecretKey    string
	S3UsePathStyle bool

	StripeSecretKey      string
	StripeWebhookSecret  string
	StripePriceStarter   string
	StripePricePro       string
	StripePriceEnterprise string

	SendGridAPIKey string
	EmailFrom      string
	EmailFromName  string

	TwilioAccountSID string
	TwilioAuthToken  string
	TwilioFromNumber string

	GoogleMapsAPIKey string

	WebAuthnRPID      string
	WebAuthnRPName    string
	WebAuthnRPOrigins []string

	SentryDSN string

	AnthropicAPIKey string
}

func Load() *Config {
	accessTTL, _ := time.ParseDuration(getEnv("JWT_ACCESS_TTL", "15m"))
	refreshTTL, _ := time.ParseDuration(getEnv("JWT_REFRESH_TTL", "720h"))
	pathStyle, _ := strconv.ParseBool(getEnv("S3_USE_PATH_STYLE", "false"))

	origins := []string{getEnv("FRONTEND_URL", "http://localhost:3000")}

	return &Config{
		Env:         getEnv("APP_ENV", "development"),
		Port:        getEnv("PORT", "8080"),
		BaseURL:     getEnv("BASE_URL", "http://localhost:8080"),
		FrontendURL: getEnv("FRONTEND_URL", "http://localhost:3000"),

		DatabaseURL: mustEnv("DATABASE_URL"),
		RedisURL:    mustEnv("REDIS_URL"),

		JWTSecret:     mustEnv("JWT_SECRET"),
		JWTAccessTTL:  accessTTL,
		JWTRefreshTTL: refreshTTL,

		S3Endpoint:     getEnv("S3_ENDPOINT", ""),
		S3Region:       getEnv("S3_REGION", "ap-southeast-2"),
		S3Bucket:       getEnv("S3_BUCKET", "tradie"),
		S3AccessKey:    getEnv("S3_ACCESS_KEY", ""),
		S3SecretKey:    getEnv("S3_SECRET_KEY", ""),
		S3UsePathStyle: pathStyle,

		StripeSecretKey:       getEnv("STRIPE_SECRET_KEY", ""),
		StripeWebhookSecret:   getEnv("STRIPE_WEBHOOK_SECRET", ""),
		StripePriceStarter:    getEnv("STRIPE_PRICE_STARTER", ""),
		StripePricePro:        getEnv("STRIPE_PRICE_PRO", ""),
		StripePriceEnterprise: getEnv("STRIPE_PRICE_ENTERPRISE", ""),

		SendGridAPIKey: getEnv("SENDGRID_API_KEY", ""),
		EmailFrom:      getEnv("EMAIL_FROM", "noreply@tradiejobmanager.com.au"),
		EmailFromName:  getEnv("EMAIL_FROM_NAME", "Tradie Job Manager"),

		TwilioAccountSID: getEnv("TWILIO_ACCOUNT_SID", ""),
		TwilioAuthToken:  getEnv("TWILIO_AUTH_TOKEN", ""),
		TwilioFromNumber: getEnv("TWILIO_FROM_NUMBER", ""),

		GoogleMapsAPIKey: getEnv("GOOGLE_MAPS_API_KEY", ""),

		WebAuthnRPID:      getEnv("WEBAUTHN_RP_ID", "localhost"),
		WebAuthnRPName:    getEnv("WEBAUTHN_RP_NAME", "Tradie Job Manager"),
		WebAuthnRPOrigins: origins,

		SentryDSN: getEnv("SENTRY_DSN", ""),

		AnthropicAPIKey: getEnv("ANTHROPIC_API_KEY", ""),
	}
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func mustEnv(key string) string {
	v := os.Getenv(key)
	if v == "" {
		panic("required env var missing: " + key)
	}
	return v
}
