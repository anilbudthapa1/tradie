-- ── Quotes ─────────────────────────────────────────────────────
CREATE TABLE quotes (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id         UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    quote_number        TEXT NOT NULL,
    status              TEXT NOT NULL DEFAULT 'draft'
                        CHECK (status IN ('draft','sent','approved','rejected','expired','converted')),
    customer_id         UUID REFERENCES customers(id) ON DELETE SET NULL,
    title               TEXT NOT NULL,
    description         TEXT,
    subtotal            FLOAT NOT NULL DEFAULT 0,
    discount_amount     FLOAT NOT NULL DEFAULT 0,
    gst_amount          FLOAT NOT NULL DEFAULT 0,
    total               FLOAT NOT NULL DEFAULT 0,
    valid_until         DATE,
    public_token        TEXT UNIQUE,
    approved_at         TIMESTAMPTZ,
    customer_signature  JSONB,
    rejection_reason    TEXT,
    converted_job_id    UUID REFERENCES jobs(id) ON DELETE SET NULL,
    sent_at             TIMESTAMPTZ,
    created_by          UUID REFERENCES users(id) ON DELETE SET NULL,
    deleted_at          TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (quote_number, business_id)
);

CREATE TABLE quote_line_items (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    quote_id    UUID NOT NULL REFERENCES quotes(id) ON DELETE CASCADE,
    business_id UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    description TEXT NOT NULL,
    quantity    FLOAT NOT NULL DEFAULT 1,
    unit_price  FLOAT NOT NULL DEFAULT 0,
    tax_rate    FLOAT NOT NULL DEFAULT 0.1,
    line_total  FLOAT NOT NULL DEFAULT 0,
    sort_order  INT NOT NULL DEFAULT 0,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE quote_templates (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    name        TEXT NOT NULL,
    description TEXT,
    items       JSONB NOT NULL DEFAULT '[]',
    created_by  UUID REFERENCES users(id) ON DELETE SET NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── Invoices ───────────────────────────────────────────────────
CREATE TABLE invoices (
    id             UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id    UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    invoice_number TEXT NOT NULL,
    status         TEXT NOT NULL DEFAULT 'draft'
                   CHECK (status IN ('draft','sent','partial','paid','overdue','cancelled')),
    customer_id    UUID REFERENCES customers(id) ON DELETE SET NULL,
    job_id         UUID REFERENCES jobs(id) ON DELETE SET NULL,
    subtotal       FLOAT NOT NULL DEFAULT 0,
    gst_amount     FLOAT NOT NULL DEFAULT 0,
    total          FLOAT NOT NULL DEFAULT 0,
    amount_paid    FLOAT NOT NULL DEFAULT 0,
    amount_due     FLOAT GENERATED ALWAYS AS (total - amount_paid) STORED,
    due_date       DATE,
    sent_at        TIMESTAMPTZ,
    paid_at        TIMESTAMPTZ,
    notes          TEXT,
    created_by     UUID REFERENCES users(id) ON DELETE SET NULL,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (invoice_number, business_id)
);

CREATE TABLE invoice_line_items (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    invoice_id  UUID NOT NULL REFERENCES invoices(id) ON DELETE CASCADE,
    business_id UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    description TEXT NOT NULL,
    quantity    FLOAT NOT NULL DEFAULT 1,
    unit_price  FLOAT NOT NULL DEFAULT 0,
    tax_rate    FLOAT NOT NULL DEFAULT 0.1,
    line_total  FLOAT NOT NULL DEFAULT 0,
    sort_order  INT NOT NULL DEFAULT 0,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE invoice_payments (
    id             UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    invoice_id     UUID NOT NULL REFERENCES invoices(id) ON DELETE CASCADE,
    business_id    UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    amount         FLOAT NOT NULL,
    payment_method TEXT NOT NULL DEFAULT 'bank_transfer'
                   CHECK (payment_method IN ('cash','card','bank_transfer','bpay','stripe','other')),
    reference      TEXT,
    paid_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by     UUID REFERENCES users(id) ON DELETE SET NULL,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE credit_notes (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    invoice_id  UUID NOT NULL REFERENCES invoices(id) ON DELETE CASCADE,
    business_id UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    amount      FLOAT NOT NULL,
    reason      TEXT,
    issued_by   UUID REFERENCES users(id) ON DELETE SET NULL,
    issued_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE payment_links (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    invoice_id  UUID NOT NULL REFERENCES invoices(id) ON DELETE CASCADE,
    business_id UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    token       TEXT NOT NULL UNIQUE,
    expires_at  TIMESTAMPTZ,
    used_at     TIMESTAMPTZ,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── Recurring invoices ─────────────────────────────────────────
CREATE TABLE recurring_invoice_rules (
    id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    business_id   UUID NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
    customer_id   UUID REFERENCES customers(id) ON DELETE SET NULL,
    template_data JSONB NOT NULL DEFAULT '{}',
    frequency     TEXT NOT NULL DEFAULT 'monthly'
                  CHECK (frequency IN ('weekly','fortnightly','monthly','quarterly','yearly')),
    next_run_at   TIMESTAMPTZ NOT NULL,
    last_run_at   TIMESTAMPTZ,
    is_active     BOOLEAN NOT NULL DEFAULT true,
    created_by    UUID REFERENCES users(id) ON DELETE SET NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── Indexes ────────────────────────────────────────────────────
CREATE INDEX idx_quotes_business_id ON quotes(business_id);
CREATE INDEX idx_quotes_status ON quotes(business_id, status);
CREATE INDEX idx_quotes_customer_id ON quotes(customer_id);
CREATE INDEX idx_quotes_deleted_at ON quotes(deleted_at) WHERE deleted_at IS NULL;
CREATE INDEX idx_quote_line_items_quote_id ON quote_line_items(quote_id);
CREATE INDEX idx_invoices_business_id ON invoices(business_id);
CREATE INDEX idx_invoices_status ON invoices(business_id, status);
CREATE INDEX idx_invoices_customer_id ON invoices(customer_id);
CREATE INDEX idx_invoices_due_date ON invoices(due_date);
CREATE INDEX idx_invoice_line_items_invoice_id ON invoice_line_items(invoice_id);
CREATE INDEX idx_invoice_payments_invoice_id ON invoice_payments(invoice_id);
CREATE INDEX idx_payment_links_token ON payment_links(token);
