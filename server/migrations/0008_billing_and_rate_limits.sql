-- Paddle webhook and reconciliation events need idempotency rows like the
-- other billing providers.
ALTER TABLE billing_events DROP CONSTRAINT billing_events_billing_provider_check;
ALTER TABLE billing_events
    ADD CONSTRAINT billing_events_billing_provider_check
    CHECK (billing_provider IN ('apple', 'google', 'paddle', 'stripe'));

-- Provider status, ordering, and cancellation bookkeeping for each subscription.
ALTER TABLE subscriptions
    ADD COLUMN provider_status TEXT,
    ADD COLUMN provider_updated_at TIMESTAMPTZ,
    ADD COLUMN cancel_requested_at TIMESTAMPTZ,
    ADD COLUMN cancelled_at TIMESTAMPTZ,
    ADD COLUMN cancel_attempts INTEGER NOT NULL DEFAULT 0 CHECK (cancel_attempts >= 0),
    ADD COLUMN cancel_next_attempt_at TIMESTAMPTZ;

CREATE INDEX subscriptions_cancel_pending_idx
    ON subscriptions (cancel_next_attempt_at)
    WHERE cancel_requested_at IS NOT NULL AND cancelled_at IS NULL;

-- Persistent fixed-window counters so limits survive restarts and apply to
-- every server instance sharing the database.
CREATE TABLE auth_rate_limits (
    bucket TEXT PRIMARY KEY,
    window_started_at TIMESTAMPTZ NOT NULL,
    hits INTEGER NOT NULL CHECK (hits >= 0)
);
