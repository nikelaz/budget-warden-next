# Cloud sync Phase 4 authentication and entitlement foundation

Status: the server implements authentication, entitlements, all three billing
paths (Stripe Managed Payments, Apple, Google Play), provider webhook and notification
ingestion, background reconciliation, persistent sign-in rate limits, and
account deletion with provider cancellation. Native client adapters remain
outstanding, and store-side behavior has not been verified against live
providers yet (see Verification).

The service supports Google and Apple challenge flows for native identity
tokens and browser authorization codes. Challenges expire after five minutes
and bind provider, configured audience, platform, device, redirect URI, nonce,
and purpose. Browser redirects are exact-match allowlisted and require S256
PKCE. Provider credentials are exchanged for opaque Budget Warden sessions; the
service stores only access-token and refresh-token hashes.

Authentication routes:

- `POST /v1/auth/{provider}/start` and `/complete`
- `POST /v1/sessions/refresh` and `/revoke`
- `GET /v1/me` and `/v1/entitlement`
- `POST /v1/account/identities/link`
- `DELETE /v1/account`

Identity linking requires a recent provider reauthentication proof bound to the
current session. A link challenge cannot be consumed by ordinary sign-in.
Refresh tokens rotate once; replaying an unexpired spent token revokes its
session family. Session revocation is checked for every protected request, so
an old access token cannot outlive its server-side session.

Provider ID tokens are verified using the provider's fixed JWKS endpoint,
RS256, issuer, configured client ID, expiry, authorized presenter where
required, and challenge nonce. Google email is stored only when Google marks it
verified. Apple email is optional because Apple may provide it only on first
authorization. Apple browser client secrets are signed server-side from
configured credentials; native clients do not receive provider secrets.

The entitlement read route reflects server-side `entitlements` and
`subscriptions` rows, including storage usage. Existing cloud-budget writes
continue to consult the same server-owned entitlement row. No client purchase
assertion grants access.

Account deletion consumes a purpose-bound, five-minute reauthentication proof,
revokes all sessions immediately, and schedules live account-data removal after
29 days, leaving a day for retries before the published 30-day maximum. Existing
requests are moved earlier by migration without postponing any deadline.
Normal snapshot and history retention continues while deletion is pending.
The retention worker removes snapshots, change history, identities,
sessions, and entitlements; it retains a minimal account/subscription link when
billing records still need late provider notifications. The response includes
App Store and Google Play subscription-management links and the scheduled data
and backup purge deadlines (29 and 64 days, within the 30/65-day maxima).
Account maintenance failures are isolated and retried on the next pass; overdue
live-data purges produce structured error logs. A retained billing shell has a
separate data-purge marker so it does not trigger false overdue reports.
Account-bound authentication locks the account before challenges and proofs,
matching deletion and retention lock order.
Auto-renewing Stripe subscriptions are queued for cancellation during account
deletion, with provider failures retried by the billing worker. Apple and
Google Play subscriptions remain managed by their storefronts.

## Implemented billing

- **Stripe Managed Payments:** hosted subscription Checkout with server-owned
  Price and return URLs, Managed Payments enabled, and the account ID in
  Checkout and subscription metadata; Stripe-Signature verification
  (HMAC-SHA256 over `timestamp.body`, five-minute tolerance, rotation-aware);
  subscription event mapping with out-of-order protection; reconciliation by
  fetching the subscription; customer portal sessions; cancellation with
  exponential backoff for account deletion.
- **Apple:** StoreKit 2 signed transactions and App Store Server Notifications V2
  verified through the x5c chain to the pinned Apple Root CA - G3 and then ES256;
  correlation by `appAccountToken`; grace and billing-retry states; reconciliation
  through the App Store Server API.
- **Google Play:** purchase state read from the Play Developer API with a
  service-account token (cached); Pub/Sub push authenticated by a Google OIDC
  token for the configured audience and service account; correlation by
  `obfuscatedAccountId`.
- **Sign in with Apple events:** `consent-revoked` ends the linked account's
  sessions; `account-delete` schedules deletion.
- **Entitlements:** recomputed from every subscription on each change and every
  five minutes. A renewal after the read window purges expired snapshots before
  access returns. The development grant is never overwritten.
- **Ownership:** a subscription cannot move between accounts. A conflicting claim
  is acknowledged for webhooks and rejected for verification.
- **Limits:** sign-in and session routes use a persistent per-client,
  per-route fixed window (`BW_AUTH_RATE_LIMIT_PER_MINUTE`).

## Verification

- Unit tests cover entitlement rules, Google state mapping, and StoreKit JWS
  handling. Apple chain verification is tested
  against a real ECDSA certificate chain generated by
  `server/src/billing/testdata/generate.sh`, including tampered payloads and
  signatures and a chain that does not end at the pinned root.
- `server/tests/billing_gates.rs` runs against PostgreSQL 17: signed Stripe
  webhooks grant and end access, duplicate and stale events are handled,
  bad signatures change nothing, a subscription cannot be claimed by a second
  account, checkout requires a session and refuses duplicate subscriptions,
  the development entitlement is preserved, and sign-in routes are rate limited.

Not yet verified:

- Live Stripe test-mode calls (checkout, cancellation, and subscription fetch)
  and webhook delivery from Stripe.
- App Store Server API calls and real Apple-signed notifications.
- Google Play Developer API calls, service-account tokens, and Pub/Sub delivery.
- Sign in with Apple server-to-server payload format (the endpoint accepts a
  JSON body with `payload`; confirm against Apple's current documentation).

## Remaining Phase 4 work

- Apple token revocation at account deletion needs stored Apple refresh tokens,
  which the service does not keep yet.
- Provider integration tests against sandboxes once credentials are in place.
- Refund and dispute events are not yet mapped to entitlement changes; decide
  the account-access policy for Stripe Managed Payments refunds and disputes.

## Configuration

Set one client ID for each provider/platform pair using the variable names in
[`server/README.md`](../server/README.md). Browser flows also require exact
provider-specific redirect allowlists. Apple browser code exchange additionally
requires its team ID, key ID, and private key. Provider endpoints return
`503 service_unavailable` when their configuration is absent.

## Implementation review corrections

The review corrected the refresh query's account-deletion column alias, scoped
same-device session replacement to the signed-in account, required issuer and
other standard JWT claims, and bound reauthentication completion to a live
bearer session. Missing accounts are rejected, challenge purposes are checked
before provider code exchange, provider response bodies are bounded while
streaming, and provider outages return service-unavailable errors. Apple browser
callbacks use `form_post`; configured callback handlers must accept POST bodies.
Google account selection uses `select_account` with `max_age=0` for sensitive
flows. Provider sandbox verification remains outstanding.

Validation: PostgreSQL and live provider integration scenarios remain
unverified.
