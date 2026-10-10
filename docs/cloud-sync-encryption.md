# Cloud snapshot end-to-end encryption design

Status: required design baseline for Phase 5. This is a protocol proposal to
review before implementation; it is not yet a cryptographic implementation or
security audit.

## Goals and boundaries

- The service never receives plaintext budget snapshots or keys that decrypt
  them. Authenticated client devices encrypt before upload and decrypt after
  download.
- Keep `.budget` schema version 2 and local files/exports unchanged. Encryption
  wraps serialized portable JSON only for cloud transport and cache-at-rest.
- Do not use a third-party key escrow or hosted encryption service. Use
  reviewed, maintained cryptographic libraries for primitives; Budget Warden
  owns the envelope, lifecycle, UX, and recovery implementation.
- TLS, server-side encryption at rest, access control, and backup protection
  remain defense in depth. The server can still observe account/resource IDs,
  sizes, timestamps, versions, billing state, and access patterns.

## Proposed key hierarchy

1. A new account's first trusted device generates a random 256-bit vault key
   using the platform cryptographic random source through the shared Rust core.
2. Each cloud budget has a random 256-bit data key. The core uses the data key
   with an authenticated encryption scheme to encrypt the exact portable JSON
   bytes. AAD binds the envelope version, account ID, cloud budget ID, portable
   budget ID, and schema version. The data key is wrapped by the vault key.
3. The vault key is wrapped independently for every enrolled device's public
   encryption key and for the user's recovery secret. The server stores only
   public device keys and opaque encrypted wrappers; no plaintext key is sent.
4. Device private keys and unwrapped vault/data keys are stored in app-private
   protected storage where available (Keychain, Android Keystore-backed
   storage, Windows protected storage, and the Linux desktop secret service or
   an explicitly protected local file fallback). The app may keep decrypted
   working data locally to support offline editing; cloud cache protection is
   dependent on the platform's private-storage guarantees.

Use a standardized authenticated-encryption construction and a standard
public-key sealed-box/key-agreement construction from one reviewed library
family supported across the Rust targets. Do not design a cipher, KDF, random
number generator, or serialization-based signature scheme. Select exact
algorithms and supported library versions in the implementation review, with
published test vectors and cross-platform interoperability tests.

## Device enrollment and recovery

- The first device creates a high-entropy recovery secret once, displays it
  with a confirmation step, and stores only its encrypted vault-key wrapper
  remotely. It is not the Google/Apple sign-in password and cannot be reset by
  Budget Warden support.
- Adding a device uses either an authenticated, short-lived QR enrollment
  session between the new and an already trusted device, or the recovery
  secret. QR enrollment uses ephemeral authenticated key agreement and
  end-to-end transfer; the server relays opaque messages and cannot complete
  the exchange. Require explicit approval on the trusted device and show the
  new device in the account's device list.
- Recovery on a replacement device requires the recovery secret plus account
  sign-in. Derive a wrapping key with a memory-hard password KDF only if the
  recovery secret is human-entered; prefer a generated high-entropy secret so
  low-entropy passwords cannot be brute-forced offline. Store KDF parameters
  with the wrapper and allow versioned upgrades.
- Warn during setup that losing every trusted device and the recovery secret
  makes cloud content permanently unreadable. Support can restore account
  billing/access but cannot decrypt budget data.
- Revoking a device blocks future sync/session use. If the device may have
  copied plaintext or keys, revocation cannot erase that copy. Rotate the
  vault key and each active budget's data key, re-encrypt each current snapshot
  from a trusted device, then wrap the new budget keys for remaining devices
  and recovery. Ensure revoked devices cannot obtain newly wrapped keys.
  Document that previously downloaded ciphertext plus a compromised old key
  cannot be retroactively made secret.

## Envelope and server contract changes

- Replace raw budget JSON request/response bodies with a versioned encrypted
  envelope containing algorithm suite ID, envelope version, nonce, ciphertext,
  authentication tag (if not included in ciphertext), and opaque wrapped data
  key. Keep size/schema/protocol metadata needed for routing outside the
  ciphertext, but minimize it and document the privacy leakage.
- The client validates schema and domain invariants before encryption and
  after decryption. The server cannot validate plaintext schema, duplicate
  entity IDs, CRDT references, or checked totals. Server acceptance therefore
  validates identity/metadata consistency, envelope structure/version, size,
  authorization, entitlement, and idempotency only. Clients reject invalid
  decrypted snapshots without replacing their last good cache.
- The API must negotiate encryption suite/envelope versions separately from
  portable schema versions. Unsupported envelopes preserve ciphertext and
  pending local edits and require an upgraded client; the server never
  decrypts, downgrades, or rewrites an envelope.
- Change-feed, catalog, recovery-history, and conditional-write semantics stay
  unchanged. Server recovery history contains ciphertext only. Idempotency
  digests cover the exact ciphertext bytes and semantic headers.
- Existing server snapshot validation and plaintext API contract are not
  compatible with this requirement. Update OpenAPI, database naming/types,
  server validation, limits, and tests before enabling cloud writes.

## Local files and migration

Local `.budget` documents and exported files remain ordinary plaintext JSON
with no cloud identity or encryption keys embedded. A cloud export decrypts
the latest locally available snapshot and writes the portable format. Moving
a local budget to cloud validates it locally, encrypts its snapshot, uploads
the ciphertext, and retains the source file as the existing migration flow
requires. Importing an export does not restore cloud membership or keys.

## Required design review before Phase 5

- Select and pin the cross-platform crypto library and exact algorithms.
- Specify canonical envelope encoding, nonce/randomness requirements, AAD,
  version negotiation, and key-wrapper rotation.
- Decide recovery-secret format, display/confirmation, reset UX, and device
  transfer UX for all supported platforms, including Linux.
- Threat-model malicious server responses, account takeover, device loss,
  local malware, backups, and metadata leakage; document limits honestly.
- Add cryptographic test vectors, wrong-key/tamper tests, format migration
  tests, and cross-platform round-trip tests before enabling service writes.
- Review the design independently before making an end-to-end encryption
  security claim.
