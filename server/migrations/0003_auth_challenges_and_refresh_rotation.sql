CREATE TABLE auth_challenges (
    id UUID PRIMARY KEY,
    provider TEXT NOT NULL CHECK (provider IN ('google', 'apple')),
    purpose TEXT NOT NULL CHECK (purpose IN ('sign_in', 'link_identity', 'reauthenticate', 'delete_account')),
    platform TEXT NOT NULL CHECK (platform IN ('macos', 'ios', 'android', 'windows', 'web')),
    flow TEXT NOT NULL CHECK (flow IN ('native', 'browser')),
    redirect_uri TEXT,
    client_id TEXT NOT NULL,
    state_hash BYTEA NOT NULL,
    nonce TEXT NOT NULL,
    device_id UUID NOT NULL,
    pkce_challenge TEXT,
    account_id UUID REFERENCES accounts(id) ON DELETE CASCADE,
    session_id UUID REFERENCES sessions(id) ON DELETE CASCADE,
    expires_at TIMESTAMPTZ NOT NULL,
    consumed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (
        (purpose = 'sign_in' AND account_id IS NULL AND session_id IS NULL)
        OR (purpose <> 'sign_in' AND account_id IS NOT NULL AND session_id IS NOT NULL)
    ),
    CHECK ((flow = 'browser' AND redirect_uri IS NOT NULL) OR (flow = 'native' AND redirect_uri IS NULL))
);

CREATE INDEX auth_challenges_expiry_idx ON auth_challenges(expires_at);

CREATE TABLE session_refresh_tokens (
    token_hash BYTEA PRIMARY KEY,
    session_id UUID NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    refresh_family_id UUID NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    consumed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX session_refresh_tokens_session_idx ON session_refresh_tokens(session_id);
CREATE INDEX session_refresh_tokens_expiry_idx ON session_refresh_tokens(expires_at);

CREATE TABLE reauthentication_proofs (
    token_hash BYTEA PRIMARY KEY,
    account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    session_id UUID NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    purpose TEXT NOT NULL CHECK (purpose IN ('link_identity', 'delete_account')),
    expires_at TIMESTAMPTZ NOT NULL,
    consumed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX reauthentication_proofs_expiry_idx ON reauthentication_proofs(expires_at);
