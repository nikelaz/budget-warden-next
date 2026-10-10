ALTER TABLE accounts ADD COLUMN deletion_data_purged_at TIMESTAMPTZ;

-- Existing deletion requests also get a day of retry margin. Never postpone
-- a deadline that was already scheduled earlier.
UPDATE accounts
SET deletion_purge_at = LEAST(deletion_purge_at, deleted_at + interval '29 days')
WHERE deleted_at IS NOT NULL;
