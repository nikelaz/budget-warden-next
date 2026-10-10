# Cloud sync Phase 3 server implementation

Status: encrypted-envelope snapshot API implemented and its acceptance gate
verified against PostgreSQL 17.

The API now accepts and returns the encrypted `BudgetEnvelope` defined in the
[OpenAPI contract](openapi/cloud-sync-v1.openapi.yaml) instead of plaintext
snapshots. `server/src/envelope.rs` validates envelope version, the
`xchacha20poly1305-x25519-v1` suite, base64 field sizes (24-byte nonces, a
16-byte tag minimum, 48-byte wrapped data keys), the positive schema version,
and byte limits. The service never decrypts. The budget title is inside the
ciphertext, so the catalog no longer returns it; migration `0007` drops the
plaintext `title` column. Rows written before that migration hold plaintext
snapshots and must be purged before cloud writes are enabled.

The acceptance gate is verified by `server/tests/phase3_gates.rs` against
PostgreSQL 17 (run with `BW_TEST_DATABASE_URL` set, see the server README). It
covers: one winner for concurrent conditional writes; retries that replay the
original result without duplicating budgets or changes; key reuse rejected;
bootstrap followed by changes without missed updates; deletes that stay deleted;
foreign accounts that get `not_found` on read and write and no catalog entry;
expired change cursors returning `cursor_expired`; and plaintext or wrong-suite
bodies rejected. The envelope validator should move into the shared core protocol
module during Phase 5. See the [encryption design](cloud-sync-encryption.md).

The service crate lives in [`server/`](../server/README.md), independently of
the existing core build. [`compose.yaml`](../server/compose.yaml) starts PostgreSQL and the server for
local development. On startup, SQLx applies the versioned migrations and the
server begins a graceful HTTP listener. A periodic job purges snapshots after
their read window, emits retention deletion events, and prunes expired mutation
receipts, feed rows, and recovery snapshots. It locks the account and
entitlement rows before checking the deadline, so a renewed account is not
purged by a stale job.

The implemented API covers capabilities, account-scoped catalog/bootstrap,
whole-snapshot create/read/replace/delete, and the ordered change feed. Snapshot
validation calls `bw_core::codec::decode_portable_budget`, so it uses the
server-safe Phase 2 decoder and does not initialize client-global clock state.
The database schema reserves the identity, device, session, subscription,
entitlement, and billing-event records needed by Phase 4.

All account mutations lock the account row until commit. The transaction writes
the budget snapshot or deletion marker, server version, account sequence/feed
entry, and content-free idempotency receipt together. Catalog bootstrap captures
the feed sequence while holding a read lock against those writes. Signed opaque
cursors are account-bound; catalog pages expire after 24 hours and feed cursors
expire when their sequence falls behind the retained feed floor. A complete
catalog rescan is then required.

The local bearer token and entitlement bypass exist only when
`BW_ENV=development`. This phase's baseline did not include provider
authentication, token issuance/refresh, verified billing, production rate
limiting, or account deletion. Authentication work is tracked separately in
[`cloud-sync-phase-4.md`](cloud-sync-phase-4.md); verified billing and the other
items remain outstanding. The OpenAPI contract describes the full v1 surface;
only implemented routes are available from the server.

Review validation: server unit tests cover quota decisions after history
eviction, unsupported schema versions, and signed-token tampering. PostgreSQL
transaction/concurrency tests and a Docker image build remain required; neither
runtime is installed in the current development environment.

Phase 4 renewal handlers must purge resources whose previous read deadline has
passed **before** extending the entitlement, under the same account lock. Merely
updating the entitlement could otherwise revive snapshots awaiting the periodic
purge. The current baseline has no production renewal handler.
