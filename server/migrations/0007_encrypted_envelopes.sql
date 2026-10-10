-- Cloud snapshots are stored as encrypted envelopes. The title is budget
-- content and now lives only inside the ciphertext, so the plaintext column
-- is removed. Rows written before this migration held plaintext snapshots and
-- must be purged before cloud writes are enabled; this migration does not
-- delete them.
ALTER TABLE budgets DROP COLUMN title;
