# Backup & Restore Runbook (M111)

This runbook is the source of truth for "I clicked Backup in the admin
screen, what actually happens?". The API endpoint `POST /api/v1/admin/backup`
does **not** perform a database backup. It records an `BACKUP_REQUESTED`
audit event and returns a pointer to this document. Backups themselves are
performed at the infrastructure layer.

## Why not in-app

In-app backup of a multi-tenant Postgres database is unsafe:
- A web process should not need shell access to `pg_dump`.
- A failed mid-flight backup can be hard to recover from.
- Cross-tenant data leakage risk if a backup is exposed via the API.

## Production (managed Postgres)

Use the cloud provider's automated snapshot feature.

- AWS RDS / Aurora: enable automated backups (≥ 7 day retention) and
  daily snapshots. Cross-region copy for disaster recovery.
- GCP Cloud SQL: enable automated backups + point-in-time recovery (PITR).
- Supabase / Neon: enable PITR on the project.

## Manual on-demand backup (DBA only)

Run from a bastion host with read-only DB credentials:

```sh
pg_dump --format=custom --no-owner --no-privileges \
        --file=tradie-$(date +%Y%m%d-%H%M).dump \
        "$DATABASE_URL"

# Upload to encrypted, versioned bucket
aws s3 cp tradie-*.dump s3://tradie-backups/ --sse AES256
```

## Restore (DBA only)

```sh
createdb tradie_restore
pg_restore --no-owner --no-privileges --dbname=tradie_restore tradie-YYYYMMDD-HHMM.dump
```

After restore, reconcile `subscriptions.status` against Stripe and replay
any audit log gaps.

## Testing

Run `pg_restore --list` against the latest backup at least monthly and
verify row counts on `audit_logs`, `invoices`, and `payments`.
