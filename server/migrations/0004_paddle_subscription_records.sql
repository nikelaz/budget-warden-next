ALTER TABLE subscriptions
    DROP CONSTRAINT subscriptions_billing_provider_check;

ALTER TABLE subscriptions
    ADD CONSTRAINT subscriptions_billing_provider_check
    CHECK (billing_provider IN ('apple', 'google', 'paddle', 'stripe'));
