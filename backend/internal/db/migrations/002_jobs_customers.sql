-- ============================================================
-- Migration 002: Customers, Jobs, Quotes, Invoices
-- ============================================================

-- ── Customers ─────────────────────────────────────────────────
CREATE TABLE customers (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id     UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    first_name      TEXT NOT NULL,
    last_name       TEXT,
    company_name    TEXT,
    email           TEXT,
    phone           TEXT,
    mobile          TEXT,
    abn             TEXT,
    notes           TEXT,
    tags            TEXT[],
    is_active       BOOLEAN DEFAULT TRUE,
    source          TEXT,
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW(),
    deleted_at      TIMESTAMPTZ
);
CREATE INDEX idx_customers_business ON customers(business_id) WHERE deleted_at IS NULL;

CREATE TABLE customer_addresses (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    customer_id UUID NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
    business_id UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    label       TEXT DEFAULT 'Primary',
    line1       TEXT NOT NULL,
    line2       TEXT,
    suburb      TEXT,
    state       TEXT,
    postcode    TEXT,
    country     TEXT DEFAULT 'AU',
    lat         DOUBLE PRECISION,
    lng         DOUBLE PRECISION,
    is_default  BOOLEAN DEFAULT FALSE,
    created_at  TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE customer_contacts (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    customer_id UUID NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
    business_id UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    name        TEXT NOT NULL,
    role        TEXT,
    email       TEXT,
    phone       TEXT,
    is_primary  BOOLEAN DEFAULT FALSE,
    created_at  TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE customer_notes (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    customer_id UUID NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
    business_id UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    created_by  UUID REFERENCES users(id),
    content     TEXT NOT NULL,
    created_at  TIMESTAMPTZ DEFAULT NOW(),
    updated_at  TIMESTAMPTZ DEFAULT NOW()
);

-- ── Jobs ──────────────────────────────────────────────────────
CREATE TABLE jobs (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id     UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    job_number      TEXT NOT NULL,
    title           TEXT NOT NULL,
    description     TEXT,
    status          job_status NOT NULL DEFAULT 'draft',
    priority        TEXT DEFAULT 'normal',
    customer_id     UUID REFERENCES customers(id),
    address_id      UUID REFERENCES customer_addresses(id),
    site_address    JSONB,
    lat             DOUBLE PRECISION,
    lng             DOUBLE PRECISION,
    scheduled_start TIMESTAMPTZ,
    scheduled_end   TIMESTAMPTZ,
    actual_start    TIMESTAMPTZ,
    actual_end      TIMESTAMPTZ,
    estimated_hours NUMERIC(8,2),
    is_recurring    BOOLEAN DEFAULT FALSE,
    recurrence_rule TEXT,
    parent_job_id   UUID REFERENCES jobs(id),
    quote_id        UUID,
    invoice_id      UUID,
    completion_notes TEXT,
    sign_off_by     TEXT,
    sign_off_at     TIMESTAMPTZ,
    sign_off_url    TEXT,
    created_by      UUID REFERENCES users(id),
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW(),
    deleted_at      TIMESTAMPTZ,
    UNIQUE(business_id, job_number)
);
CREATE INDEX idx_jobs_business ON jobs(business_id, scheduled_start) WHERE deleted_at IS NULL;
CREATE INDEX idx_jobs_customer ON jobs(customer_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_jobs_status ON jobs(business_id, status) WHERE deleted_at IS NULL;

CREATE TABLE job_assignments (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    job_id      UUID NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
    business_id UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    worker_id   UUID NOT NULL REFERENCES users(id),
    role        TEXT DEFAULT 'worker',
    assigned_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(job_id, worker_id)
);

CREATE TABLE job_notes (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    job_id      UUID NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
    business_id UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    created_by  UUID REFERENCES users(id),
    content     TEXT NOT NULL,
    is_private  BOOLEAN DEFAULT FALSE,
    created_at  TIMESTAMPTZ DEFAULT NOW(),
    updated_at  TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE job_photos (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    job_id      UUID NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
    business_id UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    uploaded_by UUID REFERENCES users(id),
    file_id     UUID REFERENCES files(id),
    type        TEXT DEFAULT 'during',
    caption     TEXT,
    created_at  TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE job_materials (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    job_id      UUID NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
    business_id UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    name        TEXT NOT NULL,
    quantity    NUMERIC(10,3) NOT NULL DEFAULT 1,
    unit        TEXT DEFAULT 'each',
    unit_cost   NUMERIC(10,2) NOT NULL DEFAULT 0,
    total_cost  NUMERIC(10,2) GENERATED ALWAYS AS (quantity * unit_cost) STORED,
    supplier    TEXT,
    created_at  TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE job_status_history (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    job_id      UUID NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
    from_status job_status,
    to_status   job_status NOT NULL,
    changed_by  UUID REFERENCES users(id),
    note        TEXT,
    created_at  TIMESTAMPTZ DEFAULT NOW()
);

-- ── Quotes ────────────────────────────────────────────────────
CREATE TABLE quotes (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id     UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    quote_number    TEXT NOT NULL,
    status          quote_status NOT NULL DEFAULT 'draft',
    customer_id     UUID NOT NULL REFERENCES customers(id),
    address_id      UUID REFERENCES customer_addresses(id),
    title           TEXT NOT NULL,
    description     TEXT,
    notes           TEXT,
    footer          TEXT,
    subtotal        NUMERIC(10,2) DEFAULT 0,
    discount_type   TEXT DEFAULT 'none',
    discount_value  NUMERIC(10,2) DEFAULT 0,
    discount_amount NUMERIC(10,2) DEFAULT 0,
    gst_amount      NUMERIC(10,2) DEFAULT 0,
    total           NUMERIC(10,2) DEFAULT 0,
    valid_until     DATE,
    sent_at         TIMESTAMPTZ,
    viewed_at       TIMESTAMPTZ,
    approved_at     TIMESTAMPTZ,
    rejected_at     TIMESTAMPTZ,
    approved_by     TEXT,
    approved_sig    TEXT,
    converted_job_id UUID REFERENCES jobs(id),
    created_by      UUID REFERENCES users(id),
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(business_id, quote_number)
);

CREATE TABLE quote_line_items (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    quote_id    UUID NOT NULL REFERENCES quotes(id) ON DELETE CASCADE,
    type        TEXT DEFAULT 'labour',
    description TEXT NOT NULL,
    quantity    NUMERIC(10,3) NOT NULL DEFAULT 1,
    unit        TEXT DEFAULT 'hr',
    unit_price  NUMERIC(10,2) NOT NULL DEFAULT 0,
    total       NUMERIC(10,2) GENERATED ALWAYS AS (quantity * unit_price) STORED,
    sort_order  INT DEFAULT 0,
    created_at  TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE quote_templates (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    name        TEXT NOT NULL,
    description TEXT,
    line_items  JSONB DEFAULT '[]',
    notes       TEXT,
    created_at  TIMESTAMPTZ DEFAULT NOW(),
    updated_at  TIMESTAMPTZ DEFAULT NOW()
);

-- ── Invoices ──────────────────────────────────────────────────
CREATE TABLE invoices (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id     UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    invoice_number  TEXT NOT NULL,
    status          invoice_status NOT NULL DEFAULT 'draft',
    customer_id     UUID NOT NULL REFERENCES customers(id),
    job_id          UUID REFERENCES jobs(id),
    quote_id        UUID REFERENCES quotes(id),
    title           TEXT,
    notes           TEXT,
    footer          TEXT,
    subtotal        NUMERIC(10,2) DEFAULT 0,
    discount_amount NUMERIC(10,2) DEFAULT 0,
    gst_amount      NUMERIC(10,2) DEFAULT 0,
    total           NUMERIC(10,2) DEFAULT 0,
    amount_paid     NUMERIC(10,2) DEFAULT 0,
    amount_due      NUMERIC(10,2) GENERATED ALWAYS AS (total - amount_paid) STORED,
    due_date        DATE,
    is_recurring    BOOLEAN DEFAULT FALSE,
    recurrence_rule TEXT,
    sent_at         TIMESTAMPTZ,
    viewed_at       TIMESTAMPTZ,
    paid_at         TIMESTAMPTZ,
    overdue_reminder_sent_at TIMESTAMPTZ,
    stripe_payment_intent TEXT,
    stripe_payment_link   TEXT,
    created_by      UUID REFERENCES users(id),
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(business_id, invoice_number)
);
CREATE INDEX idx_invoices_business ON invoices(business_id, status);
CREATE INDEX idx_invoices_customer ON invoices(customer_id);

CREATE TABLE invoice_line_items (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    invoice_id  UUID NOT NULL REFERENCES invoices(id) ON DELETE CASCADE,
    type        TEXT DEFAULT 'labour',
    description TEXT NOT NULL,
    quantity    NUMERIC(10,3) NOT NULL DEFAULT 1,
    unit        TEXT DEFAULT 'hr',
    unit_price  NUMERIC(10,2) NOT NULL DEFAULT 0,
    total       NUMERIC(10,2) GENERATED ALWAYS AS (quantity * unit_price) STORED,
    sort_order  INT DEFAULT 0
);

CREATE TABLE payments (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id     UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    invoice_id      UUID NOT NULL REFERENCES invoices(id) ON DELETE CASCADE,
    amount          NUMERIC(10,2) NOT NULL,
    method          payment_method NOT NULL,
    reference       TEXT,
    notes           TEXT,
    stripe_charge_id TEXT,
    received_at     TIMESTAMPTZ DEFAULT NOW(),
    created_by      UUID REFERENCES users(id),
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE credit_notes (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id     UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    invoice_id      UUID NOT NULL REFERENCES invoices(id),
    amount          NUMERIC(10,2) NOT NULL,
    reason          TEXT,
    issued_at       TIMESTAMPTZ DEFAULT NOW(),
    created_by      UUID REFERENCES users(id),
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

-- ── Expenses ──────────────────────────────────────────────────
CREATE TABLE expenses (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id     UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    job_id          UUID REFERENCES jobs(id),
    category        TEXT NOT NULL,
    description     TEXT NOT NULL,
    amount          NUMERIC(10,2) NOT NULL,
    gst_amount      NUMERIC(10,2) DEFAULT 0,
    supplier        TEXT,
    receipt_file_id UUID REFERENCES files(id),
    date            DATE NOT NULL,
    is_billable     BOOLEAN DEFAULT FALSE,
    created_by      UUID REFERENCES users(id),
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_expenses_business ON expenses(business_id, date DESC);
