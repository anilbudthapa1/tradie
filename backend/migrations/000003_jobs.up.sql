-- ── Files (needed before jobs for photos) ─────────────────────
CREATE TABLE files (
    id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id   UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    uploaded_by   UUID REFERENCES users(id) ON DELETE SET NULL,
    filename      TEXT NOT NULL,
    original_name TEXT NOT NULL,
    mime_type     TEXT NOT NULL,
    size_bytes    BIGINT NOT NULL DEFAULT 0,
    storage_key   TEXT NOT NULL,
    url           TEXT NOT NULL,
    thumbnail_url TEXT,
    entity_type   TEXT,
    entity_id     UUID,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── Jobs ───────────────────────────────────────────────────────
CREATE TABLE jobs (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id     UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    job_number      TEXT NOT NULL,
    title           TEXT NOT NULL,
    description     TEXT,
    status          TEXT NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending','scheduled','in_progress','completed','cancelled','on_hold')),
    priority        TEXT NOT NULL DEFAULT 'normal'
                    CHECK (priority IN ('low','normal','high','urgent')),
    customer_id     UUID REFERENCES customers(id) ON DELETE SET NULL,
    site_address    JSONB,
    lat             FLOAT,
    lng             FLOAT,
    scheduled_start TIMESTAMPTZ,
    scheduled_end   TIMESTAMPTZ,
    actual_start    TIMESTAMPTZ,
    actual_end      TIMESTAMPTZ,
    is_recurring    BOOLEAN NOT NULL DEFAULT false,
    recurring_rule  JSONB,
    sign_off_signature JSONB,
    sign_off_by     UUID REFERENCES users(id) ON DELETE SET NULL,
    sign_off_at     TIMESTAMPTZ,
    created_by      UUID REFERENCES users(id) ON DELETE SET NULL,
    deleted_at      TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (job_number, business_id)
);

-- ── Job assignments ────────────────────────────────────────────
CREATE TABLE job_assignments (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    job_id      UUID NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
    business_id UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    worker_id   UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    assigned_by UUID REFERENCES users(id) ON DELETE SET NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (job_id, worker_id)
);

-- ── Job notes ──────────────────────────────────────────────────
CREATE TABLE job_notes (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    job_id      UUID NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
    business_id UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    content     TEXT NOT NULL,
    is_private  BOOLEAN NOT NULL DEFAULT false,
    created_by  UUID REFERENCES users(id) ON DELETE SET NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── Job photos ─────────────────────────────────────────────────
CREATE TABLE job_photos (
    id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    job_id        UUID NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
    business_id   UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    file_id       UUID REFERENCES files(id) ON DELETE SET NULL,
    url           TEXT NOT NULL,
    thumbnail_url TEXT,
    caption       TEXT,
    type          TEXT NOT NULL DEFAULT 'during'
                  CHECK (type IN ('before','during','after')),
    uploaded_by   UUID REFERENCES users(id) ON DELETE SET NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── Job materials ──────────────────────────────────────────────
CREATE TABLE job_materials (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    job_id      UUID NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
    business_id UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    name        TEXT NOT NULL,
    quantity    FLOAT NOT NULL DEFAULT 1,
    unit        TEXT,
    unit_cost   FLOAT NOT NULL DEFAULT 0,
    total_cost  FLOAT GENERATED ALWAYS AS (quantity * unit_cost) STORED,
    supplier    TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── Tasks ──────────────────────────────────────────────────────
CREATE TABLE tasks (
    id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id  UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    title        TEXT NOT NULL,
    description  TEXT,
    status       TEXT NOT NULL DEFAULT 'pending'
                 CHECK (status IN ('pending','in_progress','completed','cancelled')),
    priority     TEXT NOT NULL DEFAULT 'normal'
                 CHECK (priority IN ('low','normal','high','urgent')),
    assigned_to  UUID REFERENCES users(id) ON DELETE SET NULL,
    job_id       UUID REFERENCES jobs(id) ON DELETE SET NULL,
    due_date     TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    created_by   UUID REFERENCES users(id) ON DELETE SET NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── Indexes ────────────────────────────────────────────────────
CREATE INDEX idx_files_business_id ON files(business_id);
CREATE INDEX idx_files_entity ON files(entity_type, entity_id);
CREATE INDEX idx_jobs_business_id ON jobs(business_id);
CREATE INDEX idx_jobs_status ON jobs(business_id, status);
CREATE INDEX idx_jobs_customer_id ON jobs(customer_id);
CREATE INDEX idx_jobs_scheduled_start ON jobs(scheduled_start);
CREATE INDEX idx_jobs_deleted_at ON jobs(deleted_at) WHERE deleted_at IS NULL;
CREATE INDEX idx_job_assignments_job_id ON job_assignments(job_id);
CREATE INDEX idx_job_assignments_worker_id ON job_assignments(worker_id);
CREATE INDEX idx_job_notes_job_id ON job_notes(job_id);
CREATE INDEX idx_job_photos_job_id ON job_photos(job_id);
CREATE INDEX idx_job_materials_job_id ON job_materials(job_id);
CREATE INDEX idx_tasks_business_id ON tasks(business_id);
CREATE INDEX idx_tasks_assigned_to ON tasks(assigned_to);
