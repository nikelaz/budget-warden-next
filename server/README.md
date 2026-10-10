# Budget Warden Cloud Server

This crate provides the encrypted cloud snapshot API, PostgreSQL storage,
provider sign-in, sessions, entitlements, billing integrations, and account
deletion. Desktop and web subscriptions use Stripe Managed Payments. Apple App
Store and Google Play subscriptions continue through their store APIs.

## Local development

From the repository root, start PostgreSQL and the API with Docker Compose:

```sh
docker compose -f server/compose.yaml up --build
```

The API listens at `http://localhost:8080`. The development-only bearer token is
`local-only-dev-token-change-this`; the seeded development account has a local
write entitlement. These development credentials are enabled only by
`BW_ENV=development`, and the server rejects `BW_DEV_*` settings in staging or
production.

The first server start applies the migrations. `GET /healthz` checks the
database connection. `GET /v1/capabilities` reports the configured limits.
Cloud catalog, snapshot, and change-feed routes require
`Authorization: Bearer <token>` and `Budget-Warden-Protocol: 1`.

Example capability request:

```sh
curl -i http://localhost:8080/v1/capabilities
```

The local PostgreSQL port is `54329`. The Compose volume is named
`budgetwarden-cloud-postgres` and can be removed with `docker compose -f server/compose.yaml down -v`
when local data should be discarded.

## Tests

Unit tests run without a database:

```sh
cargo test
```

Phase 3 acceptance tests start the server binary against PostgreSQL. With the
Compose database running (`podman compose -f server/compose.yaml up -d postgres`
or the Docker equivalent), run:

```sh
BW_TEST_DATABASE_URL=postgres://budgetwarden:budgetwarden@127.0.0.1:54329/budgetwarden \
  cargo test --test phase3_gates -- --ignored --test-threads=1
```

The tests create their own cloud budgets and a second test account; the
expired-cursor test moves the development account's retained change floor.

## Configuration

The server reads environment variables with the `BW_` prefix. `BW_DATABASE_URL`
is always required. Outside development, `BW_CURSOR_SECRET` is also required
and must contain at least 32 bytes. Set `BW_LISTEN_ADDR` to the desired socket
address. The recorded storage limits can be tuned for staging with the variables
below.

`BW_MAX_SNAPSHOT_BYTES` defaults to 250 MiB, and
`BW_ACCOUNT_STORAGE_LIMIT_BYTES` defaults to 5 GiB. `BW_MAX_REQUEST_BODY_BYTES`
defaults to the snapshot limit plus 64 KiB. Other important limits are
`BW_CATALOG_PAGE_SIZE`, `BW_CHANGE_PAGE_SIZE`, `BW_HISTORY_RETENTION_DAYS`,
`BW_HISTORY_VERSIONS_PER_BUDGET`, `BW_FEED_RETENTION_DAYS`, and
`BW_RECEIPT_RETENTION_DAYS`.
Feed retention must be at least 90 days and receipt retention at least 400 days.
Recovery history is limited to 1–30 days and zero to two previous snapshots.
Turning off `BW_DEV_ENTITLEMENT` revokes the seeded grant on the next startup,
with the normal 90-day read window.

Production access tokens are looked up by SHA-256 digest in `sessions`; refresh
token material is not used by the request middleware. Never log request bodies,
authorization headers, snapshot contents, or billing credentials.

Provider sign-in is configured with per-platform client IDs:
`BW_GOOGLE_CLIENT_ID_MACOS`, `BW_GOOGLE_CLIENT_ID_IOS`,
`BW_GOOGLE_CLIENT_ID_ANDROID`, `BW_GOOGLE_CLIENT_ID_WINDOWS`, and
`BW_GOOGLE_CLIENT_ID_WEB`; Apple uses the matching `BW_APPLE_CLIENT_ID_*`
variables. Browser flows also require comma-separated provider-specific
`BW_GOOGLE_REDIRECT_URIS` or `BW_APPLE_REDIRECT_URIS` allowlists and S256 PKCE.
The Compose setup forwards these variables when they are exported in the shell
before `docker compose up`.
Google browser code exchange accepts `BW_GOOGLE_CLIENT_SECRET` when using a
confidential web client. Apple browser code exchange requires
`BW_APPLE_TEAM_ID`, `BW_APPLE_KEY_ID`, and `BW_APPLE_PRIVATE_KEY`; the private
key may use literal `\n` separators. Native flows return a challenge nonce for
the platform sign-in SDK and accept its identity token. Apple clients should
send the SHA-256 hex form of that nonce to Authentication Services; the server
accepts either the raw or hashed nonce claim.

## Implemented routes

- `GET /v1/capabilities`
- `POST /v1/auth/{provider}/start` and `/complete`
- `POST /v1/sessions/refresh` and `/revoke`
- `GET /v1/me` and `/v1/entitlement`
- `POST /v1/account/identities/link`
- `DELETE /v1/account` for reauthenticated deletion scheduling
- `GET /v1/budgets` and `POST /v1/budgets`
- `GET /v1/budgets/{budget_id}`, `PUT`, and `DELETE`
- `GET /v1/sync/changes`
- `GET /healthz` for deployment health checks
- `POST /v1/billing/stripe/checkout` creates a hosted Stripe Managed Payments checkout
- `POST /v1/billing/stripe/portal` creates a short-lived Stripe customer portal session
- `POST /v1/billing/stripe/webhook` receives signed Stripe subscription events
- `POST /v1/billing/apple/verify` verifies a StoreKit 2 transaction or restore
- `POST /v1/billing/apple/notifications` receives App Store Server Notifications V2
- `POST /v1/billing/google/verify` verifies a Play purchase token
- `POST /v1/billing/google/notifications` receives Play Pub/Sub push notifications
- `POST /v1/auth/apple/server-notifications` receives Sign in with Apple events

## Billing configuration

Each store is optional. An unconfigured store returns `503 service_unavailable`
and never grants access.

- **Stripe Managed Payments (desktop and web):** set `BW_STRIPE_SECRET_KEY` to a
  Stripe test or live secret key, `BW_STRIPE_WEBHOOK_SECRET` to the endpoint
  signing secret, and `BW_STRIPE_PRICE_ID` to the recurring monthly Price ID.
  Configure `BW_STRIPE_SUCCESS_URL`, `BW_STRIPE_CANCEL_URL`, and
  `BW_STRIPE_PORTAL_RETURN_URL`. Enable Managed Payments and the customer portal
  in the Stripe Dashboard. Checkout enables Managed Payments and associates the
  subscription with the Budget Warden account. Set the webhook destination to
  `https://<host>/v1/billing/stripe/webhook` and subscribe to
  `customer.subscription.created`, `.updated`, `.deleted`, `.paused`, and
  `.resumed`. Signature tolerance defaults to five minutes and can be adjusted
  with `BW_STRIPE_WEBHOOK_TOLERANCE_SECONDS`.
- **App Store:** `BW_STOREKIT_ISSUER_ID`, `BW_STOREKIT_BUNDLE_ID`,
  `BW_STOREKIT_KEY_ID`, and `BW_STOREKIT_PRIVATE_KEY` (the App Store Connect API
  key, not the Sign in with Apple key). The apps must set the transaction's
  `appAccountToken` to the Budget Warden account ID. Signed data is trusted only
  if its certificate chain ends at the pinned Apple Root CA - G3.
- **Google Play:** `BW_GOOGLE_PLAY_PACKAGE_NAME`,
  `BW_GOOGLE_PLAY_SERVICE_ACCOUNT_EMAIL`, and `BW_GOOGLE_PLAY_PRIVATE_KEY` for the
  Play Developer API service account. Pub/Sub push needs
  `BW_GOOGLE_PLAY_PUBSUB_AUDIENCE` and `BW_GOOGLE_PLAY_PUBSUB_SERVICE_ACCOUNT`.
  The apps must set `obfuscatedAccountId` to the Budget Warden account ID.

Entitlements are recomputed from every subscription on each change, and a
background worker reconciles live subscriptions every five minutes. Stripe
subscriptions queued by account deletion are canceled with exponential
backoff; account data is not purged while cancellation is still pending.

Sign-in and session routes are limited to `BW_AUTH_RATE_LIMIT_PER_MINUTE`
requests per client address per route (default 30). Set
`BW_TRUST_PROXY_HEADERS=true` only behind a proxy that overwrites
`X-Forwarded-For`.

Writes are scoped to the authenticated account, require an active entitlement,
and commit the snapshot, opaque version, account change entry, and idempotency
receipt in one PostgreSQL transaction. Delete and replacement use strong ETags.
The account row lock serializes all change sequence allocation through commit.
The API returns the same 404 for unknown and foreign resource IDs.

Provider identity tokens are checked against cached Google or Apple public keys,
issuer, configured audience, expiry, authorized presenter, and the one-time
challenge nonce. Refresh tokens rotate once and spent hashes remain until expiry
so reuse can revoke the session family. Provider configuration is optional at
startup; an unconfigured provider returns `503 service_unavailable`.

Account deletion immediately blocks cloud access and revokes all sessions. The
retention worker schedules live account-data removal for day 29, allowing
retries before the 30-day maximum, and preserves only a
minimal account/subscription link when billing records remain. The response
includes App Store and Google Play subscription-management links and the
scheduled data and backup purge deadlines. Auto-renewing Stripe subscriptions
are canceled by the billing worker before account data is purged.
