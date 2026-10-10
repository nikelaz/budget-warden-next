# Cloud sync Phase 2 core decisions

Phase 2 establishes the portable-snapshot rules that the server and sync client
must share. The portable schema remains version 2.

## Reconciliation

- `reconcile_budget_snapshots` merges snapshots with the same portable budget
  ID and returns a deterministic semantic result without advancing `revision`
  or creating a new `revision_id`. `merge_budget_for_save` is the local-save
  operation that stamps a new revision after reconciliation.
- Field conflicts use the complete HLC timestamp, then `change_id`, then the
  serialized change record as a deterministic final tie-break. Thus equal
  timestamps and inconsistent payloads have one winner on every replica.
- If a snapshot has no change record for a materialized field, reconciliation
  supplies a baseline with physical and logical time zero and the portable
  budget ID as its stable device component. The entity ID supplies the baseline
  change ID. Legacy migration records remain authoritative over these baselines.
- Category ordering ties resolve by category ID. Transactions are ordered by
  transaction ID in reconciled output. Category actuals are recomputed from
  transactions with checked arithmetic.
- Category and transaction tombstones are permanent. A category delete writes
  explicit transaction tombstones for the transactions it contains; those
  tombstones win over concurrent edits and moves, so an old replica cannot
  restore the deleted entities. Older category-deletion snapshots may lack
  those child tombstones; transactions still assigned to the deleted category
  stay in CRDT field records but are omitted from the live category tree. A
  later explicit move to a surviving category can materialize such a
  transaction.
- Reconciliation rejects different portable budget IDs and validates the
  merged domain state. `budget_content_is_equal` compares portable content
  without local revision bookkeeping.

## Snapshot validation and clocks

- Portable decoding accepts the current schema only, rejects duplicate JSON
  object keys, unknown model fields, duplicate entity IDs, invalid calendar
  dates, invalid CRDT references, malformed field payloads, and money overflow.
  It does not inspect or advance process-global client state. Legacy local-file
  migration remains in `decode_budget`.
- Native clients persist the device ID and clock floor in app settings. They
  initialize the core from that floor and store the updated floor with budget
  writes. Android commits the floor before publishing a snapshot. Downloaded snapshots can advance the initialized
  client clock with `observe_budget_clock`.
- HLC logical-counter exhaustion advances physical time by one millisecond to
  preserve ordering. If physical time itself cannot advance, local mutations
  return an error and retain the observed floor rather than rewriting it.

The client must use semantic reconciliation before upload and compare portable
content separately from local save metadata so repeated sync passes do not
create revisions or uploads by themselves.
