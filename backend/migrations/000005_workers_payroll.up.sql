-- ── Worker availability ────────────────────────────────────────
CREATE TABLE worker_availability (
    id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id  UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    user_id      UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    day_of_week  INT NOT NULL CHECK (day_of_week BETWEEN 0 AND 6),
    start_time   TIME NOT NULL DEFAULT '07:00',
    end_time     TIME NOT NULL DEFAULT '17:00',
    is_available BOOLEAN NOT NULL DEFAULT true,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (business_id, user_id, day_of_week)
);

-- ── Worker locations ───────────────────────────────────────────
CREATE TABLE worker_locations (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    lat         FLOAT NOT NULL,
    lng         FLOAT NOT NULL,
    accuracy    FLOAT,
    recorded_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── Check-ins ──────────────────────────────────────────────────
CREATE TABLE worker_check_ins (
    id               UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id      UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    user_id          UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    job_id           UUID REFERENCES jobs(id) ON DELETE SET NULL,
    lat              FLOAT,
    lng              FLOAT,
    notes            TEXT,
    checked_in_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    checked_out_at   TIMESTAMPTZ,
    duration_minutes INT
);

-- ── Timesheets ─────────────────────────────────────────────────
CREATE TABLE timesheets (
    id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id  UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    worker_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    job_id       UUID REFERENCES jobs(id) ON DELETE SET NULL,
    date         DATE NOT NULL,
    start_time   TIME NOT NULL,
    end_time     TIME NOT NULL,
    break_minutes INT NOT NULL DEFAULT 0,
    total_hours  FLOAT NOT NULL DEFAULT 0,
    notes        TEXT,
    status       TEXT NOT NULL DEFAULT 'pending'
                 CHECK (status IN ('pending','approved','rejected')),
    approved_by  UUID REFERENCES users(id) ON DELETE SET NULL,
    approved_at  TIMESTAMPTZ,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── Leave requests ─────────────────────────────────────────────
CREATE TABLE leave_requests (
    id               UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id      UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    worker_id        UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    leave_type       TEXT NOT NULL DEFAULT 'annual'
                     CHECK (leave_type IN ('annual','sick','personal','unpaid','other')),
    start_date       DATE NOT NULL,
    end_date         DATE NOT NULL,
    days_count       INT NOT NULL DEFAULT 1,
    reason           TEXT,
    status           TEXT NOT NULL DEFAULT 'pending'
                     CHECK (status IN ('pending','approved','rejected')),
    approved_by      UUID REFERENCES users(id) ON DELETE SET NULL,
    approved_at      TIMESTAMPTZ,
    rejection_reason TEXT,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── Pay runs ───────────────────────────────────────────────────
CREATE TABLE pay_runs (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    period_start DATE NOT NULL,
    period_end   DATE NOT NULL,
    pay_date     DATE NOT NULL,
    status       TEXT NOT NULL DEFAULT 'draft'
                 CHECK (status IN ('draft','processed','paid')),
    total_gross  FLOAT NOT NULL DEFAULT 0,
    total_tax    FLOAT NOT NULL DEFAULT 0,
    total_net    FLOAT NOT NULL DEFAULT 0,
    created_by   UUID REFERENCES users(id) ON DELETE SET NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── Payslips ───────────────────────────────────────────────────
CREATE TABLE payslips (
    id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id  UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    pay_run_id   UUID NOT NULL REFERENCES pay_runs(id) ON DELETE CASCADE,
    worker_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    gross_pay    FLOAT NOT NULL DEFAULT 0,
    tax_withheld FLOAT NOT NULL DEFAULT 0,
    net_pay      FLOAT NOT NULL DEFAULT 0,
    super_amount FLOAT NOT NULL DEFAULT 0,
    period_start DATE NOT NULL,
    period_end   DATE NOT NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (pay_run_id, worker_id)
);

-- ── Superannuation ─────────────────────────────────────────────
CREATE TABLE superannuation (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    worker_id   UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    pay_run_id  UUID REFERENCES pay_runs(id) ON DELETE SET NULL,
    amount      FLOAT NOT NULL DEFAULT 0,
    quarter     TEXT NOT NULL,
    status      TEXT NOT NULL DEFAULT 'pending'
                CHECK (status IN ('pending','paid')),
    due_date    DATE,
    paid_at     TIMESTAMPTZ,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── Indexes ────────────────────────────────────────────────────
CREATE INDEX idx_worker_availability_user_id ON worker_availability(business_id, user_id);
CREATE INDEX idx_worker_locations_user_id ON worker_locations(business_id, user_id);
CREATE INDEX idx_worker_locations_recorded_at ON worker_locations(recorded_at DESC);
CREATE INDEX idx_worker_check_ins_user_id ON worker_check_ins(business_id, user_id);
CREATE INDEX idx_timesheets_business_id ON timesheets(business_id);
CREATE INDEX idx_timesheets_worker_id ON timesheets(worker_id);
CREATE INDEX idx_timesheets_date ON timesheets(date);
CREATE INDEX idx_leave_requests_business_id ON leave_requests(business_id);
CREATE INDEX idx_leave_requests_worker_id ON leave_requests(worker_id);
CREATE INDEX idx_pay_runs_business_id ON pay_runs(business_id);
CREATE INDEX idx_payslips_pay_run_id ON payslips(pay_run_id);
CREATE INDEX idx_payslips_worker_id ON payslips(worker_id);
