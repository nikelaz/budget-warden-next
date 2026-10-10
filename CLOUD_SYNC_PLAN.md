# Cloud sync implementation plan

Status: active implementation plan. Phase 4 authentication and scheduled
account deletion are implemented; provider billing and native client
integrations remain in progress. See [the Phase 4 status](docs/cloud-sync-phase-4.md).
This document records the plan and does not implement cloud functionality itself.

## Outcome and initial scope

Add an optional paid monthly cloud service operated by Budget Warden. Users sign in with Google or Apple, subscribe once for their Budget Warden account, and access their cloud budgets from macOS, iOS, Android, Windows, and Linux. Local budgets remain usable without an account or subscription.

Cloud budgets retain an app-managed local cache so editing works offline. The shared Rust core owns the sync client, reconciliation, and end-to-end encryption. A Rust service using Tokio and Axum owns authentication, authorization, subscription entitlements, and encrypted cloud storage. Native apps own provider sign-in, purchases, secure credential storage, platform scheduling, and presentation.

The last implementation phase delivers the UI in every app:

- Welcome screens have separate **Cloud budgets** and **Local budgets** sections.
- Budget creation offers **Cloud** or **Local** storage.
- An open local budget has a **Move to Cloud** action.
- Cloud budgets show sync status and support export to a portable `.budget` file.

Initial scope is private budgets synced between one user's devices. Shared budgets, collaboration permissions, a browser budget editor, attachments, and delta sync are later work.

## Repository findings

| Existing area | Implication for this work |
| --- | --- |
| `core/src/models.rs`, `codec.rs` | Schema version 2 stores budget IDs, revision IDs, and CRDT state. `url` is excluded from serialized JSON. Keep cloud membership, encryption keys, and credentials outside the portable file. |
| `core/src/crdt.rs` | Existing field changes, hybrid logical clocks, and category/transaction tombstones provide a starting point. Merge currently mints a fresh revision and some fallback values depend on argument order; establish convergence before enabling sync. |
| `core/src/app_state.rs` | Device identity and clock state are process-global. Review this boundary for a concurrent server and persist the client's clock floor across restarts. |
| Apple `ViewModels/BWStore.swift` | Mutations currently assume local document URLs and save through local file flows. Introduce an explicit storage abstraction. |
| Android `data/BudgetRepository.kt` | Document-provider I/O and recovery snapshots already live behind a repository. Add a cloud cache implementation alongside it. |
| Windows `ViewModels/AppViewModel.Persistence.cs` | Windows also saves local files and consumes generated C# bindings. Include Windows in the FFI, persistence, and UI work. |
| `core/boltffi.toml`, `apple-core/` | Regenerate Swift, Kotlin, and C# bindings for exported API changes. Keep Apple convenience behavior in `BWAppleCore`. |

## Proposed architecture

```text
Native apps
  sign-in / purchases / secure token storage / lifecycle scheduling / UI
          |
Shared Rust core
  domain + codec + convergent merge
  sync client + durable queue/cache metadata + HTTPS transport
          |
Budget Warden Cloud: Tokio + Axum
  auth / sessions / ownership / entitlement checks / sync API
          |
PostgreSQL
  accounts + identities + sessions + entitlements
  budget snapshots + server versions + change feed + deletion markers
```

Use complete encrypted snapshots over HTTPS and PostgreSQL storage. Clients serialize ordinary schema-versioned `.budget` JSON, encrypt it before upload, and decrypt it after download; the local `.budget` format and exports remain portable plaintext. The service validates envelope metadata and encrypted payload bounds, but cannot inspect budget contents. Keep account/resource IDs and sync metadata outside the ciphertext. Avoid an external key service: clients generate and manage keys, with a deliberate multi-device enrollment and recovery flow. A lost recovery secret with no trusted device means the encrypted cloud data cannot be recovered. Finalize the cryptographic envelope, key hierarchy, rotation, recovery, and migration behavior before freezing the sync payload contract.

Keep the shared domain usable without network dependencies. Add a default-off `cloud-sync` feature to `core/Cargo.toml`, with protocol types and pure reconciliation separated from transport/runtime code. Enable it in app binding builds. The server consumes the domain and protocol modules with client networking disabled.

Use an app-owned `BudgetLocation`/`BudgetHandle` to distinguish a local document from an account-scoped cloud budget and its cache. Do not encode cloud identity into a fake filesystem URL. A cached budget may have a real cache path where existing helpers require one, but routing must use the explicit handle.

## Phase 1 — Specify the contract and product policies

Deliver an API specification, sync state machine, entitlement policy, and architecture decisions before implementing storage.

1. Define separate identifiers: portable budget UUID; cloud resource UUID scoped to its owner; device UUID; client mutation UUID; opaque server version; account change-feed cursor. Existing budget revisions are not server versions.
2. Define protocol and schema negotiation. Unsupported schemas fail without rewriting or downgrading a budget; clients preserve pending edits and request an upgrade.
3. Adopt encrypted snapshot sync, conditional writes, and client-side CRDT reconciliation for v1. The server validates the envelope and atomically stores ciphertext; clients validate plaintext locally and merge on version conflicts.
4. Define local/cloud membership separately from `.budget` contents. Cloud exports are normal local files; importing an export does not grant access or silently reconnect it to a cloud resource.
5. Specify ownership, idempotency retention, request limits, quota errors, deletion retention, and pagination/cursor expiry behavior.
6. Select hosting region, monthly price, storage limits, billing channels, cancellation/grace policy, and retention after subscription expiry.

Recommended starting policies, subject to product decisions:

- Signing in is free; creating or uploading cloud budgets and syncing edits requires an active entitlement, including any approved billing grace period.
- Cancellation keeps access until the paid-through date. Expiry pauses uploads; cached budgets remain editable and exportable. Allow cloud listing/download/export during a published retention period, proposed as 90 days, with clear notice before eventual deletion. Account deletion is a separate explicit action.
- Offline edits persist even when entitlement status cannot be refreshed. The server decides whether upload is permitted when connectivity returns.
- Require end-to-end encryption for cloud budget snapshots, using a reviewed cryptographic library and a key design owned by Budget Warden. TLS and server-side storage encryption remain defense in depth. Before Phase 5, specify key generation, per-account/device enrollment, recovery-key handling, device revocation, key rotation, encrypted metadata boundaries, and behavior when all recovery material is lost. Local `.budget` files and exports remain plaintext and portable.
- A move to cloud changes the app's active storage location after successful upload; the source file is retained as a backup. Actual deletion of that source is a separate user action.

**Completion gate:** the protocol covers concurrent edits, retries, subscription expiry, account switching, deletion, crash recovery, and the encrypted payload/key lifecycle; product decisions below are recorded.

## Phase 2 — Make the core safe for distributed reconciliation

Primary files: `core/src/crdt.rs`, `domain.rs`, `codec.rs`, `models.rs`, `validation.rs`, and `app_state.rs`.

1. Separate semantic reconciliation from revision stamping. Repeated reconciliation with identical content must not create perpetual new changes or uploads.
2. Audit every editable field and structural operation for CRDT coverage: titles, ordering, category types, planned/accumulated values, transactions, moves, and deletes. Define deterministic baselines for fields without change records, including imported and legacy budgets.
3. Define deterministic tie handling for equal timestamps and inconsistent payloads. Reject merges between different portable budget IDs. Derive totals from transactions using checked arithmetic and validate the merged result.
4. Specify delete-versus-edit and move-versus-delete behavior. Keep entity tombstones until a safe compaction protocol exists; an old offline device must not resurrect deleted entities.
5. Persist the device ID and clock floor with durable client state. Observe downloaded clocks before producing new mutations. Define handling for extreme future timestamps without silently rewriting causality.
6. Keep decoding, validation, and merge usable by the server without a per-user dependency on process-global client state. Move clock observation into client context where needed.
7. Preserve existing `.budget` compatibility. Any required schema change includes migration and fixtures, plus explicit behavior for older clients.

**Planned validation:** convergence under different merge orders; semantic associativity and idempotence; simultaneous edits; deletes and moves; legacy baselines; clock skew; restart recovery; overflow; and compatibility with existing files. Compare semantic state independently from save revision metadata.

**Completion gate:** multiple replicas converge without data loss or repeated uploads caused only by revision bookkeeping.

## Phase 3 — Build the Tokio/Axum server

Add `server/` as an independently deployable Rust crate with migrations, configuration, container packaging, and a local development setup. Keep existing `core/` build commands working; a repository Cargo workspace is optional.

Suggested modules: `auth`, `sessions`, `accounts`, `budgets`, `sync`, `billing`, `db`, `jobs`, and `config`. Use PostgreSQL migrations, structured logs, bounded request handling, and graceful shutdown. Choose dependency versions during implementation against their official documentation.

### Storage

| Table/group | Responsibility |
| --- | --- |
| `accounts`, `auth_identities` | Internal user ID; unique provider issuer/subject identities; explicit linked providers. |
| `sessions`, `devices` | Hashed rotating refresh tokens, revocation, device/session metadata. |
| `subscriptions`, `entitlements`, `billing_events` | Verified provider purchases, effective access, idempotent event processing. |
| `budgets`, `budget_versions` | Owner, cloud ID, portable ID, validated current snapshot, server version, bounded recovery history, deletion state. |
| `account_changes` | Ordered budget updates/deletes for incremental discovery across devices. |
| `mutation_receipts` | Account-scoped idempotency keys and original operation results. |

Use an account-scoped sequence/cursor allocation strategy that cannot expose a cursor before an earlier transaction becomes visible. Commit snapshot, server version, feed entry, and receipt atomically. Authorize every resource request using the authenticated account rather than trusting IDs supplied by the client.

### API outline

All application routes are under `/v1`; generate and maintain an OpenAPI contract.

| Endpoint | Purpose |
| --- | --- |
| `POST /auth/{provider}/start`, `/complete` | Create a short-lived sign-in challenge and verify Google/Apple authentication. |
| `POST /sessions/refresh`, `/sessions/revoke` | Rotate or revoke sessions. |
| `GET /me`, `GET /entitlement` | Account and effective subscription access. |
| `POST /account/identities/link` | Link another provider after authenticating both identities. |
| `DELETE /account` | Reauthenticated account deletion with provider cleanup and scheduled data removal. |
| `GET /budgets` | Paginated cloud catalog with a consistent bootstrap cursor. |
| `POST /budgets` | Idempotent cloud creation or upload of a local budget. |
| `GET /budgets/{id}` | Download current snapshot and version; support conditional reads. |
| `PUT /budgets/{id}` | Replace a snapshot conditionally using `If-Match` and a mutation ID. |
| `DELETE /budgets/{id}` | Conditional, idempotent cloud deletion and feed tombstone. |
| `GET /sync/changes?cursor=...` | Paginated updates/deletes since the last committed cursor. |
| `POST /billing/{provider}/verify` | Verify a native purchase or restore for this account. |
| `POST /billing/{provider}/webhook` | Verify and record provider notifications. |

Authentication route details differ by provider and platform. Provider tokens are exchanged for Budget Warden sessions and are not used as general API credentials.

For a write, validate authentication, ownership, entitlement, size, schema, budget identity, and expected server version. Return a typed conflict with the current version (and snapshot or download reference), allowing the client to merge and retry. Reusing an idempotency key with different content fails. Receipt lookup must resolve retries of an already committed operation without performing that operation again.

Never silently create a resource through `PUT`. A deleted cloud resource remains deleted; an old device receives a deletion result and preserves its unsynced work as an exportable recovery copy. Re-creation is an explicit new-resource operation.

**Completion gate:** concurrent conditional writes accept one winner; retries cannot duplicate budgets or changes; cross-account access fails; a fresh client can bootstrap without missing an update; expired cursors trigger a complete reconciliation rather than data loss.

## Phase 4 — Add Google/Apple auth and monthly entitlements

### Authentication

- Configure native clients and browser callback flows for Google and Apple across all four platforms. Use native provider APIs where available and system browser authorization elsewhere; use PKCE for authorization-code flows that support it, plus state and nonce validation.
- Validate provider signatures and permitted algorithms, issuer, audience/client ID, expiry, and nonce on the server. Cache provider signing keys with rotation support. Use issuer plus subject as identity; do not automatically link accounts by matching email addresses.
- Support Apple private relay addresses and first-login-only profile information. Group/configure Apple app identities deliberately so the apps resolve to the intended account.
- Issue short-lived Budget Warden access tokens and rotating opaque refresh tokens. Store refresh-token hashes on the server; detect reuse, revoke sessions, and support logout across devices.
- Native apps store credentials in Keychain, Android Keystore-backed secure storage, and Windows protected credential storage. Auth-provider secrets remain on the server.
- Require recent authentication for identity linking and account deletion. Process provider revocations and implement required account-deletion behavior.

Provider references: [Google OpenID Connect](https://developers.google.com/identity/openid-connect/openid-connect) and [Sign in with Apple authentication](https://developer.apple.com/documentation/signinwithapple/authenticating-users-with-sign-in-with-apple).

### Subscription service

- Define one logical monthly cloud plan and map platform product IDs to it. Entitlements belong to the internal account and work across devices and platforms.
- Plan StoreKit subscriptions for App Store distribution and Google Play Billing for Play distribution. Select a web billing provider for direct desktop sales if those are offered; resolve Windows Store purchase requirements for the chosen distribution channel before release.
- Verify purchases server-side and bind each purchase to one Budget Warden account. Use the platform's account correlation fields where supported. Implement restore purchases, ownership conflicts, and an explicit support path for transfers.
- Normalize active, grace, payment retry, expired, refunded, and revoked states, retaining paid-through timestamps. Process signed/authenticated notifications idempotently, handle reordered events, and periodically reconcile with provider APIs.
- Enforce upload/create access in the server. Purchases and local client flags never grant entitlement by themselves. Prevent unnecessary duplicate subscriptions when an account already has access through another provider.
- Expose billing provider, expiry, purchase restoration, and subscription management destination through the account API. Define how account deletion interacts with any ongoing provider subscription.

The proposed native billing defaults follow [Apple's multiplatform service guidance](https://developer.apple.com/app-store/review/guidelines/#multiplatform-services) and [Google Play's payments policy](https://support.google.com/googleplay/android-developer/answer/9858738?hl=en). Checkout links and alternative billing depend on distribution, storefront, and applicable programs; confirm the selected release flows against current rules before shipping.

**Completion gate:** either sign-in provider reaches the correct account; explicitly linked identities share budgets; a verified purchase on one platform grants access elsewhere; renewal, cancellation, grace, expiry, refunds, duplicate events, restoration, and revocation produce the expected entitlement.

## Phase 5 — Implement the shared Rust sync client

**Prerequisite:** complete an end-to-end encryption design review before implementing transport or durable cloud caches. The design must define the encrypted snapshot envelope, authenticated metadata, key hierarchy, device enrollment and revocation, recovery-key UX and backup rules, rotation, and unrecoverable-key-loss behavior. Encryption and decryption belong in shared Rust code so all clients use the same implementation. Never upload plaintext budget snapshots; local files and exports stay in the existing portable format.

Suggested modules under `core/src/sync/`: `protocol`, `client`, `transport`, `store`, `reconcile`, and `error`. Export a small FFI API for account-scoped catalog access, cloud create/open/move preparation, sync execution, cancellation, and typed status/results.

1. Add HTTPS transport and bounded Tokio runtime ownership appropriate to generated bindings. Never block native UI threads. Validate asynchronous exports/callbacks with BoltFFI on Swift, Kotlin, and C# before freezing the interface; an explicit worker-driven API is an alternative if async exports are unsuitable.
2. Keep token acquisition and secure storage in native adapters. Supply access tokens for requests; serialize native refresh attempts and retry authentication once after refresh. Scope in-flight work to an account/session generation so responses cannot cross account switches.
3. Implement a durable account-scoped sync store, preferably SQLite with transactions for metadata/outbox state and atomically written snapshot files. Provide startup recovery for interrupted file/database commits. Store cache version, dirty generation, pending mutation IDs, server versions, and catalog cursor. Do not store refresh tokens here.
4. Save every edit durably before acknowledging it in the UI. Coalesce pending snapshots per budget while retaining a stable identity for each actual upload attempt. A retry after an unknown network outcome must reuse the original request bytes and mutation ID.
5. Serialize synchronization per budget and coordinate multiple app windows/processes accessing a shared cache. Different budgets can sync concurrently within bounded limits.
6. Trigger sync on open, after debounced edits, foreground/reconnect, and manual refresh. Use bounded polling while active for changes from other devices. Platform background execution is opportunistic; v1 does not promise immediate closed-app delivery.
7. Retry transient errors with exponential backoff and jitter; honor server retry hints. Pause on auth, entitlement, quota, or upgrade errors while retaining all local work.

### Reconciliation cycle

1. Capture the current durable local generation and the last acknowledged server version.
2. Fetch remote state when changed and reconcile it with the latest local snapshot using the core merge rules. Persist the result before attempting upload.
3. Upload with the expected server version and a durable mutation ID. On conflict, fetch/merge/retry with a bounded attempt count.
4. Persist the acknowledged version and accepted generation atomically. If more local edits arrived during upload, keep the budget dirty and schedule another pass; never replace those edits with an older response.
5. Commit a change-feed cursor only after all entries through it have been durably processed. Restarting may replay entries, so processing must be idempotent.

Bootstrap catalogs using the server's consistent listing/cursor contract. An expired cursor starts a complete rescan, reconciling deletion state and retaining unsynced local snapshots. Never infer that a resource was deleted from one incomplete page.

**Completion gate:** two headless clients edit offline, reconnect, converge, and recover from crashes, dropped responses, concurrent local edits, deletion, logout, and expired subscriptions without losing accepted local edits.

## Phase 6 — Integrate native persistence and prepare the service

Complete the nonvisual app integration before the final UI phase.

- **Apple:** add shared sync/account helpers in `apple-core/src/`; adapt both `BWStore.swift` implementations to route local document writes and cloud cache writes through a storage interface. Preserve security-scoped access and coordinated local document I/O.
- **Android:** add account/cloud implementations beside `BudgetRepository.kt`, integrate `BudgetSessionViewModel.kt`, retain document-provider access for local budgets, and use platform background scheduling for eligible work.
- **Windows:** adapt `AppViewModel.Persistence.cs` through a storage service; add C# sign-in, purchase, credential, lifecycle, and sync adapters.
- Regenerate all three binding targets and verify cancellation, error propagation, runtime lifetime, and thread handoff on each platform. Generated artifacts remain unedited.
- Account-specific caches and pending writes survive logout. Warn before logout/account switching when edits are unsynced; stop requests, revoke/clear credentials, and prevent another account from seeing the prior cache. Cached files remain inside app-private protected storage.

Implement a recoverable local-to-cloud operation shared by app adapters:

1. Flush the local budget and persist a migration record identifying the source, snapshot generation, intended cloud ID, and idempotency key.
2. Require sign-in and entitlement, validate the snapshot, and create the cloud resource idempotently.
3. Reconcile edits made while upload was running, and durably initialize the cloud cache/version mapping. Serialize the final location change with budget mutations.
4. Switch the active handle and remove the source from the app's local recent list only after cloud creation and cache initialization are confirmed. Retain the original file as a backup and state that behavior in the UI.
5. Resume safely after a crash at any step. An uncertain response must not create duplicate cloud budgets. A failed operation leaves the local budget usable.

Cloud creation also begins with durable local state. If it cannot reach the server, show the budget as pending cloud creation; keep it recoverable, and never claim it is synced. Define how an existing cloud-linked budget imported again becomes a separate cloud copy or is explicitly reconciled with its original resource.

Prepare production operations: separate staging/production environments, secrets management, TLS, migrations, request limits, rate limits, storage quotas, database backups and restore drills, recovery-history pruning, published retention jobs, and account deletion. Record metrics for sync failures, conflicts, latency, queue age, and billing reconciliation; exclude budget contents and tokens from logs. Use feature flags for staged rollout and retain cached editing/export during outages.

**Completion gate:** each app can exercise local/cloud storage, sign-in, billing, migration, and offline recovery through service APIs; staging passes integration checks and a database restore drill.

## Phase 7 — Deliver the UI in every app (final implementation step)

| App | Main integration points |
| --- | --- |
| macOS | `Views/BWWindowWelcome.swift`, `Views/BWCreateBudget.swift`, open-budget toolbar/menu, `ViewModels/BWStore.swift`. |
| iOS | `Views/BWBudgetListView.swift`, `Views/BWCreateBudgetView.swift`, `Views/BWBudgetDetailView.swift`, `ViewModels/BWStore.swift`. |
| Android | `BudgetScreens.kt`, `BudgetDialogs.kt`, `BudgetSessionViewModel.kt`, account/settings screens. |
| Windows | `Views/WelcomeView.xaml`, `Views/BudgetDialogs.cs`, `Views/BudgetView.xaml`, settings, and app view models. |
| Linux | GTK4 client welcome, creation, budget, and account/settings views; use the shared Rust storage and sync interfaces. |

### Welcome and account screens

- Show separate Cloud budgets and Local budgets sections. Local recents continue working while signed out or offline.
- Signed-out Cloud section offers Google and Apple sign-in. Signed-in state shows the server catalog with cached entries usable offline and uncached entries requiring connectivity.
- Distinguish empty catalog, loading, offline cached results, pending creation, subscription expired, and actual failures. Do not hide budgets when an entitlement expires.
- Provide monthly subscription purchase, restore, management, account identity linking, logout, and account deletion. Show localized provider prices and paid-through/grace status.

### Creation and migration

- Add a Cloud/Local choice to each creation flow. Local invokes the existing file/location picker; cloud uses app-managed cache storage without a file picker.
- Cloud choice routes through sign-in/subscription when necessary while retaining the user's title/template inputs. Return to creation after success.
- Add Move to Cloud to an open local budget. Explain the backup behavior, show progress, and recover to the local budget on failure.
- Show the newly created or moved resource in Cloud budgets and stop presenting its old recent entry as the active local budget.

### Open cloud budget

- Show concise states: Saved on device, Syncing, Synced, Offline with pending changes, Sign-in required, Subscription required, or Sync failed. Make retry and local export available where relevant.
- Keep offline editing responsive. Incorporate remote changes without discarding active form input; reconcile by entity ID and surface deleted targets to the user before submission.
- Distinguish removing a downloaded cache from deleting the cloud budget. Cloud deletion affects all devices and requires an explicit destructive action; ordinary logout does not delete budgets.
- Export any cached budget as `.budget`, including pending edits. A later “Move to Local” operation should export successfully before any optional cloud deletion.

**Final acceptance checks, on all four apps:**

1. Create/open/edit a local budget without signing in.
2. Sign in with either provider and purchase/restore a monthly plan.
3. Create a cloud budget and open it on a second platform with the same account.
4. Move an existing local budget to cloud, including interrupted upload and app restart.
5. Edit the same budget offline on two devices, reconnect, and verify deterministic reconciliation.
6. Cancel/expire/refund the subscription and verify the defined access, pending-edit, and export behavior.
7. Switch accounts, delete a budget, and reconnect an old device without leaking data or resurrecting the deleted cloud resource.
8. Verify welcome sections, storage choice, status text, accessibility, and provider purchase flows before staged release.

## Delivery order and decisions remaining

Implement phases 1–7 in order, with headless integration proving the protocol before UI delivery. Each phase should be a reviewable change set; split auth, billing, server storage, and client runtime further where necessary.

Recorded product decisions: USD $1.99/month as a configurable reference price; no published fixed account storage quota, with unusually high or automated usage handled under a fair-use/support policy; EU hosting target; 90-day cloud read/export period after entitlement expiry; end-to-end encryption required for cloud snapshots; Apple App Store billing for Apple clients, Google Play billing for Play-distributed Android, and Paddle as the working desktop merchant of record for Windows and Linux. Provider choice remains behind a provider-neutral entitlement interface. Confirm final distribution/store rules, Paddle onboarding, and localized pricing before launch. The private-budget scope remains unchanged.
