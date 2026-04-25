-- ============================================================
-- Migration 003: Payroll, Safety/WorkSafe, Scheduling
-- ============================================================

-- ── Payroll ──────────────────────────────────────────────────
CREATE TABLE timesheets (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id     UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    job_id          UUID REFERENCES jobs(id),
    clock_in        TIMESTAMPTZ NOT NULL,
    clock_out       TIMESTAMPTZ,
    break_minutes   INT DEFAULT 0,
    regular_hours   NUMERIC(6,2),
    overtime_hours  NUMERIC(6,2),
    notes           TEXT,
    status          TEXT DEFAULT 'pending',
    approved_by     UUID REFERENCES users(id),
    approved_at     TIMESTAMPTZ,
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_timesheets_user ON timesheets(user_id, clock_in DESC);
CREATE INDEX idx_timesheets_business ON timesheets(business_id, clock_in DESC);

CREATE TABLE check_ins (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    job_id      UUID REFERENCES jobs(id),
    type        TEXT NOT NULL DEFAULT 'check_in',
    lat         DOUBLE PRECISION,
    lng         DOUBLE PRECISION,
    address     TEXT,
    device_info JSONB,
    created_at  TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE leave_requests (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    type        TEXT NOT NULL,
    start_date  DATE NOT NULL,
    end_date    DATE NOT NULL,
    days        NUMERIC(4,1),
    reason      TEXT,
    status      leave_status NOT NULL DEFAULT 'pending',
    approved_by UUID REFERENCES users(id),
    approved_at TIMESTAMPTZ,
    created_at  TIMESTAMPTZ DEFAULT NOW(),
    updated_at  TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE availability (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    day_of_week INT,
    date        DATE,
    start_time  TIME,
    end_time    TIME,
    is_available BOOLEAN DEFAULT TRUE,
    notes       TEXT,
    created_at  TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE pay_runs (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id     UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    period_start    DATE NOT NULL,
    period_end      DATE NOT NULL,
    pay_date        DATE NOT NULL,
    status          TEXT DEFAULT 'draft',
    total_gross     NUMERIC(10,2) DEFAULT 0,
    total_tax       NUMERIC(10,2) DEFAULT 0,
    total_super     NUMERIC(10,2) DEFAULT 0,
    total_net       NUMERIC(10,2) DEFAULT 0,
    processed_at    TIMESTAMPTZ,
    processed_by    UUID REFERENCES users(id),
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE payslips (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id     UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    pay_run_id      UUID NOT NULL REFERENCES pay_runs(id) ON DELETE CASCADE,
    user_id         UUID NOT NULL REFERENCES users(id),
    period_start    DATE NOT NULL,
    period_end      DATE NOT NULL,
    regular_hours   NUMERIC(6,2) DEFAULT 0,
    overtime_hours  NUMERIC(6,2) DEFAULT 0,
    hourly_rate     NUMERIC(10,2) DEFAULT 0,
    gross_pay       NUMERIC(10,2) DEFAULT 0,
    tax_withheld    NUMERIC(10,2) DEFAULT 0,
    super_amount    NUMERIC(10,2) DEFAULT 0,
    net_pay         NUMERIC(10,2) DEFAULT 0,
    allowances      JSONB DEFAULT '[]',
    deductions      JSONB DEFAULT '[]',
    file_id         UUID REFERENCES files(id),
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE super_contributions (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id     UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    payslip_id      UUID NOT NULL REFERENCES payslips(id) ON DELETE CASCADE,
    user_id         UUID NOT NULL REFERENCES users(id),
    fund_name       TEXT,
    fund_usi        TEXT,
    member_number   TEXT,
    amount          NUMERIC(10,2) NOT NULL,
    quarter         TEXT,
    status          TEXT DEFAULT 'pending',
    paid_at         TIMESTAMPTZ,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE performance_reviews (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id     UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    user_id         UUID NOT NULL REFERENCES users(id),
    reviewed_by     UUID REFERENCES users(id),
    period_start    DATE,
    period_end      DATE,
    rating          INT CHECK (rating BETWEEN 1 AND 5),
    notes           TEXT,
    goals           JSONB DEFAULT '[]',
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

-- ── Safety / WorkSafe ────────────────────────────────────────
CREATE TABLE safety_checklists (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id     UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    job_id          UUID REFERENCES jobs(id),
    completed_by    UUID REFERENCES users(id),
    title           TEXT NOT NULL,
    items           JSONB NOT NULL DEFAULT '[]',
    status          TEXT DEFAULT 'pending',
    completed_at    TIMESTAMPTZ,
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE swms_documents (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id     UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    job_id          UUID REFERENCES jobs(id),
    title           TEXT NOT NULL,
    work_activities JSONB DEFAULT '[]',
    hazards         JSONB DEFAULT '[]',
    controls        JSONB DEFAULT '[]',
    ppe_required    TEXT[],
    reviewed_by     UUID REFERENCES users(id),
    reviewed_at     TIMESTAMPTZ,
    file_id         UUID REFERENCES files(id),
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE risk_assessments (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id     UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    job_id          UUID REFERENCES jobs(id),
    title           TEXT NOT NULL,
    hazards         JSONB DEFAULT '[]',
    likelihood      INT CHECK (likelihood BETWEEN 1 AND 5),
    consequence     INT CHECK (consequence BETWEEN 1 AND 5),
    risk_level      TEXT,
    controls        TEXT,
    assessed_by     UUID REFERENCES users(id),
    assessed_at     TIMESTAMPTZ DEFAULT NOW(),
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE incident_reports (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id     UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    job_id          UUID REFERENCES jobs(id),
    reported_by     UUID REFERENCES users(id),
    type            TEXT NOT NULL DEFAULT 'incident',
    severity        incident_severity NOT NULL DEFAULT 'low',
    title           TEXT NOT NULL,
    description     TEXT NOT NULL,
    injured_person  TEXT,
    witnesses       TEXT[],
    actions_taken   TEXT,
    corrective_actions TEXT,
    occurred_at     TIMESTAMPTZ NOT NULL,
    notified_worksafe BOOLEAN DEFAULT FALSE,
    worksafe_ref    TEXT,
    file_ids        UUID[],
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE ppe_records (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id     UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    job_id          UUID REFERENCES jobs(id),
    user_id         UUID REFERENCES users(id),
    items           JSONB NOT NULL DEFAULT '[]',
    checked_at      TIMESTAMPTZ DEFAULT NOW(),
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE compliance_documents (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id     UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    user_id         UUID REFERENCES users(id),
    type            TEXT NOT NULL,
    number          TEXT,
    issuer          TEXT,
    issued_date     DATE,
    expiry_date     DATE,
    file_id         UUID REFERENCES files(id),
    reminder_days   INT DEFAULT 30,
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

-- ── Leads ─────────────────────────────────────────────────────
CREATE TABLE leads (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id     UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    first_name      TEXT NOT NULL,
    last_name       TEXT,
    email           TEXT,
    phone           TEXT,
    source          TEXT,
    status          TEXT DEFAULT 'new',
    notes           TEXT,
    estimated_value NUMERIC(10,2),
    assigned_to     UUID REFERENCES users(id),
    converted_at    TIMESTAMPTZ,
    customer_id     UUID REFERENCES customers(id),
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

-- ── Worker location tracking ──────────────────────────────────
CREATE TABLE worker_locations (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    job_id      UUID REFERENCES jobs(id),
    lat         DOUBLE PRECISION NOT NULL,
    lng         DOUBLE PRECISION NOT NULL,
    accuracy    DOUBLE PRECISION,
    heading     DOUBLE PRECISION,
    speed       DOUBLE PRECISION,
    recorded_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_worker_locations_user ON worker_locations(user_id, recorded_at DESC);

-- ── API Keys ──────────────────────────────────────────────────
CREATE TABLE api_keys (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    created_by  UUID REFERENCES users(id),
    name        TEXT NOT NULL,
    key_hash    TEXT NOT NULL UNIQUE,
    prefix      TEXT NOT NULL,
    scopes      TEXT[],
    last_used   TIMESTAMPTZ,
    expires_at  TIMESTAMPTZ,
    revoked_at  TIMESTAMPTZ,
    created_at  TIMESTAMPTZ DEFAULT NOW()
);

-- ── Integrations ──────────────────────────────────────────────
CREATE TABLE integration_tokens (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id     UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    provider        TEXT NOT NULL,
    access_token    TEXT,
    refresh_token   TEXT,
    token_expiry    TIMESTAMPTZ,
    metadata        JSONB DEFAULT '{}',
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(business_id, provider)
);

-- ── Reviews ───────────────────────────────────────────────────
CREATE TABLE review_requests (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    customer_id UUID NOT NULL REFERENCES customers(id),
    job_id      UUID REFERENCES jobs(id),
    platform    TEXT DEFAULT 'google',
    sent_at     TIMESTAMPTZ,
    clicked_at  TIMESTAMPTZ,
    created_at  TIMESTAMPTZ DEFAULT NOW()
);
