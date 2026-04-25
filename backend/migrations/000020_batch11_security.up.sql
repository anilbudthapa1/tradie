-- ── Batch 11: Bulk import/update, permissions, saved filters ──────

-- Bulk import jobs
CREATE TABLE IF NOT EXISTS bulk_import_jobs (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id     UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    entity_type     TEXT NOT NULL
                    CHECK (entity_type IN ('customers','jobs','expenses')),
    file_id         UUID REFERENCES files(id) ON DELETE SET NULL,
    file_name       TEXT,
    status          TEXT NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending','processing','completed','failed_partial','failed')),
    total_rows      INTEGER NOT NULL DEFAULT 0,
    processed_rows  INTEGER NOT NULL DEFAULT 0,
    success_rows    INTEGER NOT NULL DEFAULT 0,
    error_log       JSONB NOT NULL DEFAULT '[]',
    created_by      UUID REFERENCES users(id) ON DELETE SET NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at    TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_bulk_import_jobs_business_id ON bulk_import_jobs(business_id);
CREATE INDEX IF NOT EXISTS idx_bulk_import_jobs_status ON bulk_import_jobs(business_id, status);

-- Permissions catalog
CREATE TABLE IF NOT EXISTS permissions (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    key         TEXT NOT NULL UNIQUE,
    description TEXT,
    category    TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Role -> permission mapping (built-in role names)
CREATE TABLE IF NOT EXISTS role_permissions (
    role          TEXT NOT NULL
                  CHECK (role IN ('owner','admin','manager','worker','accountant','customer')),
    permission_id UUID NOT NULL REFERENCES permissions(id) ON DELETE CASCADE,
    business_id   UUID REFERENCES businesses(id) ON DELETE CASCADE,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (role, permission_id, business_id)
);

CREATE INDEX IF NOT EXISTS idx_role_permissions_business_id ON role_permissions(business_id);

-- Seed canonical permission keys
INSERT INTO permissions (key, description, category) VALUES
    ('jobs.view',        'View jobs',                     'jobs'),
    ('jobs.create',      'Create jobs',                   'jobs'),
    ('jobs.update',      'Update jobs',                   'jobs'),
    ('jobs.delete',      'Delete jobs',                   'jobs'),
    ('jobs.assign',      'Assign workers to jobs',        'jobs'),
    ('customers.view',   'View customers',                'customers'),
    ('customers.create', 'Create customers',              'customers'),
    ('customers.update', 'Update customers',              'customers'),
    ('customers.delete', 'Delete customers',              'customers'),
    ('quotes.view',      'View quotes',                   'quotes'),
    ('quotes.create',    'Create quotes',                 'quotes'),
    ('quotes.send',      'Send quotes to customers',      'quotes'),
    ('invoices.view',    'View invoices',                 'invoices'),
    ('invoices.create',  'Create invoices',               'invoices'),
    ('invoices.send',    'Send invoices',                 'invoices'),
    ('invoices.delete',  'Delete invoices',               'invoices'),
    ('payments.view',    'View payments',                 'payments'),
    ('payments.record',  'Record manual payments',        'payments'),
    ('expenses.view',    'View expenses',                 'expenses'),
    ('expenses.create',  'Create expenses',               'expenses'),
    ('payroll.view',     'View payroll runs',             'payroll'),
    ('payroll.process',  'Process payroll runs',          'payroll'),
    ('reports.view',     'View reports',                  'reports'),
    ('reports.export',   'Export reports',                'reports'),
    ('workers.view',     'View workers',                  'workers'),
    ('workers.invite',   'Invite workers',                'workers'),
    ('workers.update',   'Update workers',                'workers'),
    ('settings.view',    'View settings',                 'settings'),
    ('settings.update',  'Update settings',               'settings'),
    ('imports.bulk',     'Run bulk imports',              'admin'),
    ('bulk.update',      'Run bulk updates',              'admin'),
    ('permissions.manage','Manage role permissions',      'admin'),
    ('audit.view',       'View audit logs',               'admin')
ON CONFLICT (key) DO NOTHING;

-- Seed default role -> permission mapping (business_id IS NULL = template)
INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'owner', id, NULL FROM permissions
ON CONFLICT DO NOTHING;

INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'admin', id, NULL FROM permissions
WHERE key NOT IN ('permissions.manage')
ON CONFLICT DO NOTHING;

INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'manager', id, NULL FROM permissions
WHERE key IN (
    'jobs.view','jobs.create','jobs.update','jobs.assign',
    'customers.view','customers.create','customers.update',
    'quotes.view','quotes.create','quotes.send',
    'invoices.view','invoices.create','invoices.send',
    'expenses.view','expenses.create',
    'reports.view','workers.view','settings.view'
)
ON CONFLICT DO NOTHING;

INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'worker', id, NULL FROM permissions
WHERE key IN (
    'jobs.view','customers.view','quotes.view','invoices.view',
    'expenses.view','expenses.create','settings.view'
)
ON CONFLICT DO NOTHING;

INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'accountant', id, NULL FROM permissions
WHERE key IN (
    'invoices.view','payments.view','expenses.view',
    'payroll.view','reports.view','reports.export','settings.view'
)
ON CONFLICT DO NOTHING;

INSERT INTO role_permissions (role, permission_id, business_id)
SELECT 'customer', id, NULL FROM permissions
WHERE key IN ('jobs.view','quotes.view','invoices.view')
ON CONFLICT DO NOTHING;

-- Saved filters (M102)
CREATE TABLE IF NOT EXISTS saved_filters (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    business_id UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    entity_type TEXT NOT NULL,
    name        TEXT NOT NULL,
    filter_spec JSONB NOT NULL DEFAULT '{}',
    is_shared   BOOLEAN NOT NULL DEFAULT false,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_saved_filters_user ON saved_filters(user_id, entity_type);
CREATE INDEX IF NOT EXISTS idx_saved_filters_business ON saved_filters(business_id, entity_type);
