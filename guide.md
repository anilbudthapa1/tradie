
● Here's exactly how to run your app:

  ---
  Running Tradie Job Manager

  Step 1 — Start the backend services (Docker)

  Open a terminal in C:\Users\Anil Budthapa\Desktop\Tradie\infra\ and run:

  docker compose up -d

  This starts PostgreSQL (port 5432), Redis (6379), MinIO (9000), and the Go API (8080).

  To check they're all healthy:
  docker compose ps

  To view API logs:
  docker compose logs -f api

  Step 2 — Create a .env file for the backend

  The API needs backend/.env. Create it:

  DATABASE_URL=postgres://tradie:tradie_secret@localhost:5432/tradie?sslmode=disable
  REDIS_URL=redis://:redis_secret@localhost:6379
  JWT_SECRET=your-secret-key-here
  PORT=8080
  MINIO_ENDPOINT=localhost:9000
  MINIO_ACCESS_KEY=tradie_minio
  MINIO_SECRET_KEY=tradie_minio_secret

  Step 3 — Run the Go backend directly (without Docker, for development)

  cd C:\Users\Anil Budthapa\Desktop\Tradie\backend
  go run ./cmd/api/main.go

  Or build and run:
  go build -o tradie-api ./cmd/api && ./tradie-api

  Step 4 — Run the Flutter mobile app

  cd C:\Users\Anil Budthapa\Desktop\Tradie\mobile

  # Install dependencies
  flutter pub get

  # List available devices
  flutter devices

  # Run on Android emulator or connected device
  flutter run

  # Run on a specific device
  flutter run -d <device-id>

  # Run in debug mode with hot reload
  flutter run --debug

  ---
  Quick summary

  ┌───────────────────────┬──────────────────────────────────────┬──────┐
  │         What          │               Command                │ Port │
  ├───────────────────────┼──────────────────────────────────────┼──────┤
  │ All services (Docker) │ docker compose up -d in infra/       │ —    │
  ├───────────────────────┼──────────────────────────────────────┼──────┤
  │ API only              │ go run ./cmd/api/main.go in backend/ │ 8080 │
  ├───────────────────────┼──────────────────────────────────────┼──────┤
  │ Flutter app           │ flutter run in mobile/               │ —    │
  ├───────────────────────┼──────────────────────────────────────┼──────┤
  │ API health check      │ curl http://localhost:8080/health    │ 8080 │
  └───────────────────────┴──────────────────────────────────────┴──────┘

  The Flutter app's API base URL should point to http://10.0.2.2:8080 for Android emulator (which maps to your
  localhost), or http://localhost:8080 for desktop/web.