ALTER TABLE accounts ADD COLUMN deletion_purge_at TIMESTAMPTZ;

UPDATE accounts
SET deletion_purge_at = deleted_at + interval '30 days'
WHERE deleted_at IS NOT NULL;

ALTER TABLE accounts
    ADD CONSTRAINT accounts_deletion_deadline_check
    CHECK ((deleted_at IS NULL) = (deletion_purge_at IS NULL));
