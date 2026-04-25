#!/bin/bash
# Run all SQL migrations in order
set -e

DB_URL="${DATABASE_URL:-postgres://tradie:tradie_secret@localhost:5432/tradie?sslmode=disable}"
MIGRATIONS_DIR="$(dirname "$0")/../backend/internal/db/migrations"

for f in $(ls "$MIGRATIONS_DIR"/*.sql | sort); do
  echo "Running migration: $f"
  psql "$DB_URL" -f "$f"
done

echo "All migrations complete."
