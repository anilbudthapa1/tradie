-- ── Safety checklists ──────────────────────────────────────────
CREATE TABLE safety_checklists (
    id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id  UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    job_id       UUID REFERENCES jobs(id) ON DELETE SET NULL,
    template_id  UUID,
    title        TEXT NOT NULL DEFAULT 'Safety Checklist',
    status       TEXT NOT NULL DEFAULT 'pending'
                 CHECK (status IN ('pending','in_progress','completed')),
    items        JSONB NOT NULL DEFAULT '[]',
    completed_by UUID REFERENCES users(id) ON DELETE SET NULL,
    completed_at TIMESTAMPTZ,
    signature    JSONB,
    created_by   UUID REFERENCES users(id) ON DELETE SET NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── SWMS documents ─────────────────────────────────────────────
CREATE TABLE swms_documents (
    id                   UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id          UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    job_id               UUID REFERENCES jobs(id) ON DELETE SET NULL,
    title                TEXT NOT NULL,
    job_type             TEXT NOT NULL,
    high_risk_activities JSONB NOT NULL DEFAULT '[]',
    control_measures     JSONB NOT NULL DEFAULT '[]',
    responsible_person   TEXT NOT NULL,
    review_date          DATE,
    status               TEXT NOT NULL DEFAULT 'draft'
                         CHECK (status IN ('draft','active','archived')),
    created_by           UUID REFERENCES users(id) ON DELETE SET NULL,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── Incident reports ───────────────────────────────────────────
CREATE TABLE incident_reports (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id         UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    job_id              UUID REFERENCES jobs(id) ON DELETE SET NULL,
    incident_type       TEXT NOT NULL DEFAULT 'other'
                        CHECK (incident_type IN ('injury','near_miss','property_damage','environmental','other')),
    severity            TEXT NOT NULL DEFAULT 'low'
                        CHECK (severity IN ('low','medium','high','critical')),
    description         TEXT NOT NULL,
    location            TEXT,
    injured_person      TEXT,
    treatment_provided  TEXT,
    reported_by         UUID REFERENCES users(id) ON DELETE SET NULL,
    status              TEXT NOT NULL DEFAULT 'open'
                        CHECK (status IN ('open','investigating','closed')),
    investigation_notes TEXT,
    corrective_actions  JSONB,
    closed_at           TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── Risk assessments ───────────────────────────────────────────
CREATE TABLE risk_assessments (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id         UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    job_id              UUID REFERENCES jobs(id) ON DELETE SET NULL,
    title               TEXT NOT NULL,
    hazards             JSONB NOT NULL DEFAULT '[]',
    residual_risk_level TEXT NOT NULL DEFAULT 'medium'
                        CHECK (residual_risk_level IN ('low','medium','high')),
    created_by          UUID REFERENCES users(id) ON DELETE SET NULL,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── Compliance records ─────────────────────────────────────────
CREATE TABLE compliance_records (
    id                   UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id          UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    type                 TEXT NOT NULL
                         CHECK (type IN ('license','certification','insurance','registration','other')),
    name                 TEXT NOT NULL,
    holder_name          TEXT NOT NULL,
    reference_number     TEXT,
    issue_date           DATE,
    expiry_date          DATE NOT NULL,
    reminder_days_before INT NOT NULL DEFAULT 30,
    status               TEXT NOT NULL DEFAULT 'active'
                         CHECK (status IN ('active','expired','archived')),
    deleted_at           TIMESTAMPTZ,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── PPE submissions ────────────────────────────────────────────
CREATE TABLE ppe_submissions (
    id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id  UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    worker_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    job_id       UUID REFERENCES jobs(id) ON DELETE SET NULL,
    items        JSONB NOT NULL DEFAULT '[]',
    all_clear    BOOLEAN NOT NULL DEFAULT false,
    notes        TEXT,
    submitted_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── Expenses ───────────────────────────────────────────────────
CREATE TABLE expenses (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id     UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    category        TEXT NOT NULL DEFAULT 'other'
                    CHECK (category IN ('fuel','materials','tools','insurance','rent','utilities','subcontractor','other')),
    description     TEXT NOT NULL,
    amount          FLOAT NOT NULL DEFAULT 0,
    gst_amount      FLOAT NOT NULL DEFAULT 0,
    date            DATE NOT NULL DEFAULT CURRENT_DATE,
    job_id          UUID REFERENCES jobs(id) ON DELETE SET NULL,
    supplier        TEXT,
    is_gst_inclusive BOOLEAN NOT NULL DEFAULT true,
    payment_method  TEXT NOT NULL DEFAULT 'card'
                    CHECK (payment_method IN ('cash','card','bank_transfer','bpay','other')),
    receipt_url     TEXT,
    status          TEXT NOT NULL DEFAULT 'approved'
                    CHECK (status IN ('pending','approved','rejected')),
    created_by      UUID REFERENCES users(id) ON DELETE SET NULL,
    deleted_at      TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── Indexes ────────────────────────────────────────────────────
CREATE INDEX idx_safety_checklists_business_id ON safety_checklists(business_id);
CREATE INDEX idx_safety_checklists_job_id ON safety_checklists(job_id);
CREATE INDEX idx_swms_business_id ON swms_documents(business_id);
CREATE INDEX idx_incidents_business_id ON incident_reports(business_id);
CREATE INDEX idx_incidents_severity ON incident_reports(business_id, severity);
CREATE INDEX idx_compliance_business_id ON compliance_records(business_id);
CREATE INDEX idx_compliance_expiry ON compliance_records(expiry_date);
CREATE INDEX idx_compliance_deleted ON compliance_records(deleted_at) WHERE deleted_at IS NULL;
CREATE INDEX idx_expenses_business_id ON expenses(business_id);
CREATE INDEX idx_expenses_date ON expenses(business_id, date);
CREATE INDEX idx_expenses_category ON expenses(business_id, category);
CREATE INDEX idx_expenses_deleted ON expenses(deleted_at) WHERE deleted_at IS NULL;
