CREATE TABLE accounts (
    id UUID PRIMARY KEY,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at TIMESTAMPTZ,
    next_change_seq BIGINT NOT NULL DEFAULT 0 CHECK (next_change_seq >= 0),
    retained_change_floor BIGINT NOT NULL DEFAULT 0 CHECK (retained_change_floor >= 0)
);

CREATE TABLE auth_identities (
    id UUID PRIMARY KEY,
    account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    provider TEXT NOT NULL CHECK (provider IN ('google', 'apple')),
    issuer TEXT NOT NULL,
    subject TEXT NOT NULL,
    display_email TEXT,
    linked_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (provider, issuer, subject),
    UNIQUE (account_id, provider)
);

CREATE TABLE devices (
    account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    device_id UUID NOT NULL,
    platform TEXT NOT NULL CHECK (platform IN ('macos', 'ios', 'android', 'windows', 'web')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (account_id, device_id)
);

CREATE TABLE sessions (
    id UUID PRIMARY KEY,
    account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    device_id UUID NOT NULL,
    access_token_hash BYTEA NOT NULL UNIQUE,
    refresh_token_hash BYTEA NOT NULL UNIQUE,
    refresh_family_id UUID NOT NULL,
    access_expires_at TIMESTAMPTZ NOT NULL,
    refresh_expires_at TIMESTAMPTZ NOT NULL,
    revoked_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    FOREIGN KEY (account_id, device_id) REFERENCES devices(account_id, device_id) ON DELETE CASCADE
);

CREATE INDEX sessions_account_active_idx ON sessions(account_id, access_expires_at)
    WHERE revoked_at IS NULL;

CREATE TABLE subscriptions (
    id UUID PRIMARY KEY,
    account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    billing_provider TEXT NOT NULL CHECK (billing_provider IN ('apple', 'google', 'stripe')),
    provider_subscription_id TEXT NOT NULL,
    state TEXT NOT NULL CHECK (state IN ('pending', 'active', 'grace', 'payment_retry', 'paused', 'expired', 'revoked')),
    access_until TIMESTAMPTZ,
    auto_renews BOOLEAN NOT NULL DEFAULT false,
    management_url TEXT,
    verified_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (billing_provider, provider_subscription_id)
);

CREATE TABLE entitlements (
    account_id UUID PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
    state TEXT NOT NULL CHECK (state IN ('none', 'active', 'grace', 'expired', 'revoked')),
    can_write BOOLEAN NOT NULL DEFAULT false,
    effective_expires_at TIMESTAMPTZ,
    read_access_until TIMESTAMPTZ,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE billing_events (
    id UUID PRIMARY KEY,
    billing_provider TEXT NOT NULL CHECK (billing_provider IN ('apple', 'google', 'stripe')),
    provider_event_id TEXT NOT NULL,
    received_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    processed_at TIMESTAMPTZ,
    payload_digest BYTEA NOT NULL,
    UNIQUE (billing_provider, provider_event_id)
);

CREATE TABLE budgets (
    account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    cloud_budget_id UUID NOT NULL,
    portable_budget_id UUID NOT NULL,
    schema_version INTEGER NOT NULL,
    title TEXT NOT NULL,
    snapshot_json TEXT,
    current_bytes BIGINT NOT NULL DEFAULT 0 CHECK (current_bytes >= 0),
    server_version TEXT NOT NULL,
    created_seq BIGINT NOT NULL CHECK (created_seq > 0),
    updated_at TIMESTAMPTZ NOT NULL,
    deleted_at TIMESTAMPTZ,
    deletion_reason TEXT CHECK (deletion_reason IN ('user_deleted', 'retention_expired')),
    PRIMARY KEY (account_id, cloud_budget_id),
    CHECK ((snapshot_json IS NULL) = (deleted_at IS NOT NULL)),
    CHECK ((deleted_at IS NULL) = (deletion_reason IS NULL))
);

CREATE INDEX budgets_account_catalog_idx ON budgets(account_id, cloud_budget_id)
    WHERE deleted_at IS NULL;

CREATE TABLE budget_versions (
    id UUID PRIMARY KEY,
    account_id UUID NOT NULL,
    cloud_budget_id UUID NOT NULL,
    server_version TEXT NOT NULL,
    snapshot_json TEXT NOT NULL,
    byte_size BIGINT NOT NULL CHECK (byte_size >= 0),
    archived_at TIMESTAMPTZ NOT NULL,
    FOREIGN KEY (account_id, cloud_budget_id)
        REFERENCES budgets(account_id, cloud_budget_id) ON DELETE CASCADE
);

CREATE INDEX budget_versions_account_age_idx ON budget_versions(account_id, archived_at);
CREATE INDEX budget_versions_resource_age_idx ON budget_versions(account_id, cloud_budget_id, archived_at DESC);

CREATE TABLE account_changes (
    account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    sequence BIGINT NOT NULL CHECK (sequence > 0),
    cloud_budget_id UUID NOT NULL,
    kind TEXT NOT NULL CHECK (kind IN ('upsert', 'deleted')),
    server_version TEXT,
    schema_version INTEGER,
    changed_at TIMESTAMPTZ NOT NULL,
    deletion_reason TEXT CHECK (deletion_reason IN ('user_deleted', 'retention_expired')),
    PRIMARY KEY (account_id, sequence),
    FOREIGN KEY (account_id, cloud_budget_id)
        REFERENCES budgets(account_id, cloud_budget_id) ON DELETE CASCADE,
    CHECK (
        (kind = 'upsert' AND server_version IS NOT NULL AND schema_version IS NOT NULL AND deletion_reason IS NULL)
        OR (kind = 'deleted' AND server_version IS NULL AND schema_version IS NULL AND deletion_reason IS NOT NULL)
    )
);

CREATE INDEX account_changes_resource_idx ON account_changes(account_id, cloud_budget_id, sequence DESC);
CREATE INDEX account_changes_retention_idx ON account_changes(account_id, changed_at, sequence);

CREATE TABLE mutation_receipts (
    account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    http_method TEXT NOT NULL,
    resource_route TEXT NOT NULL,
    mutation_id UUID NOT NULL,
    request_digest BYTEA NOT NULL,
    response_status SMALLINT NOT NULL,
    response_body TEXT,
    server_version TEXT,
    committed_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (account_id, http_method, resource_route, mutation_id)
);

CREATE INDEX mutation_receipts_retention_idx ON mutation_receipts(account_id, committed_at);
