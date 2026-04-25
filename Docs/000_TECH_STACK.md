# Tradie Job Manager — Technology Stack

| Item | Use |
|------|-----|
| Flutter | Mobile app for owners and employees on Android/iOS |
| Flutter Web or React | Desktop web dashboard for business owners/admin |
| Go | Backend API, business logic, authentication, jobs, invoices, payroll |
| PostgreSQL | Main database for users, businesses, jobs, invoices, payroll, tax, WorkSafe records |
| Redis | Sessions, refresh tokens, rate limiting, caching, queues |
| REST API | Main frontend-to-backend communication |
| WebSocket | Real-time updates: job status, worker location, notifications |
| gRPC | Later internal service-to-service communication |
| S3-compatible storage | Store job photos, invoices, receipts, payslips, WorkSafe documents |
| Docker | Run backend, database, Redis, and services consistently |
| Nginx / Caddy | Reverse proxy, HTTPS, routing traffic to backend/frontend |
| Stripe | Subscription billing and online payments |
| SendGrid / SMTP | Email verification, password reset, invoice emails |
| Twilio / SMS provider | SMS reminders, ETA messages, customer notifications |
| Google Maps API | Job address lookup, route planning, distance calculation |
| PDF Generator | Quotes, invoices, payslips, tax reports, WorkSafe reports |
| GitHub Actions | CI/CD: testing, building, deployment automation |
| Monitoring Tool | Error tracking, uptime alerts, backend health checks |

## Architecture Summary

- **Frontend**: Flutter (mobile) + Flutter Web or React (dashboard) + Customer Portal (web)
- **Backend**: Go REST API with WebSocket support, future gRPC for microservices
- **Data**: PostgreSQL (primary) + Redis (cache/sessions/queues)
- **Storage**: S3-compatible (photos, PDFs, documents)
- **Payments**: Stripe (subscriptions + invoices)
- **Comms**: SendGrid (email) + Twilio (SMS)
- **Maps**: Google Maps API
- **Infra**: Docker + Nginx/Caddy + GitHub Actions CI/CD
- **Monitoring**: Error tracking + uptime alerts
