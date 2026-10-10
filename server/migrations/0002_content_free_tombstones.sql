-- Scrub existing tombstones as well as enforcing the invariant on new deletes.
UPDATE budgets SET title = '', current_bytes = 0 WHERE deleted_at IS NOT NULL;
ALTER TABLE budgets ADD CONSTRAINT budgets_content_free_tombstone
    CHECK (deleted_at IS NULL OR (title = '' AND current_bytes = 0));
