#!/usr/bin/env bash
# Server-side deploy for defencexinso.com.
#
# Idempotent. Safe to re-run. Run from the project root on the server:
#   bash infra/scripts/deploy.sh
#
# Assumes:
#   - infra/docker-compose.prod.yml in place
#   - backend/.env.production filled in (NOT committed)
#   - Flutter web build copied to infra/web/ (or build it here, see below)
#   - API_IMAGE env var or default in compose points at a pulled image

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
COMPOSE_FILE="$REPO_ROOT/infra/docker-compose.prod.yml"
ENV_FILE="$REPO_ROOT/backend/.env.production"
WEB_DIR="$REPO_ROOT/infra/web"

if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: $ENV_FILE not found. Copy backend/.env.production.example and fill it in." >&2
  exit 1
fi

if [ ! -d "$WEB_DIR" ] || [ -z "$(ls -A "$WEB_DIR" 2>/dev/null)" ]; then
  echo "WARN: $WEB_DIR is empty. Building Flutter web locally would fail on a server without Flutter."
  echo "      Build on your dev machine: cd mobile && flutter build web --release"
  echo "      Then copy: scp -r mobile/build/web/* server:$REPO_ROOT/infra/web/"
fi

echo "→ Pulling latest API image…"
docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" pull api

echo "→ Running migrations…"
# Use the API image's psql availability — fall back to running migrations
# from a separate ephemeral container.
docker run --rm --env-file "$ENV_FILE" \
  -v "$REPO_ROOT/backend/migrations:/migrations:ro" \
  -e DB_URL="$(grep -E '^DATABASE_URL=' "$ENV_FILE" | cut -d= -f2-)" \
  postgres:16-alpine \
  sh -c 'for f in $(ls /migrations/*.up.sql | sort); do echo "applying $f"; psql "$DB_URL" -v ON_ERROR_STOP=1 -f "$f" || exit 1; done'

echo "→ Restarting API (rolling)…"
docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d --no-deps api

echo "→ Reloading Caddy (picks up Caddyfile + web/ changes)…"
docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d caddy
docker compose -f "$COMPOSE_FILE" exec caddy caddy reload --config /etc/caddy/Caddyfile || true

echo "→ Health check…"
sleep 3
if curl -fsS https://tradie.defencexinso.com/health >/dev/null; then
  echo "✓ live"
else
  echo "✗ /health did not respond — check 'docker compose logs api' and 'docker compose logs caddy'"
  exit 1
fi
