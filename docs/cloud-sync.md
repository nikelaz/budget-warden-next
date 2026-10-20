# Cloud budgets: iCloud Drive and Google Drive

Budget Warden can keep budgets in iCloud Drive (macOS and iOS) and in Google Drive (every client: macOS, iOS, Android, Windows, Linux, and the CLI). Cloud budgets are listed next to local budgets on each app's welcome screen, budgets other people shared with the user are discovered automatically, and budgets can be shared from inside the app.

## How it works

### Google Drive

The Google Drive integration is implemented once, in `core/src/cloud/`, and every client uses it.

- **Working copies.** A Google Drive budget is mirrored to a `.budget` file in an app-private cache directory (`<cache>/google-drive/<file id>/<name>.budget`). Apps open, edit, and save that file exactly like a local budget, so every existing save path, the CRDT merge, and the MCP server keep working unchanged.
- **Sync.** After every save, every minute while a cloud budget is open, and when the budget is opened, the app calls `BWGoogleDrive::sync_budget`. Sync reads Drive's file `version`, downloads the content only when it changed, CRDT-merges the working copy with the newest remote copy, writes the merge back to the working copy if it gained anything, and uploads it if Drive lacks anything. The app reloads an open budget when sync rewrote its working copy. Concurrent syncs of one budget are coalesced, so the latest save always reaches Drive.
- **Concurrency.** Drive v3 has no conditional (compare-and-swap) uploads, so two devices can race and the later upload replaces the earlier one. Because every device always merges with the newest remote copy before uploading and keeps its own edits in its working copy, the device whose upload was overwritten re-uploads the union on its next sync. Edits converge instead of being lost (covered by `a_lost_upload_race_heals_on_the_next_sync`). Equivalent merges are compared as sets of categories and transactions, so they never cause spurious uploads.
- **Discovery.** `list_budgets` queries Drive for files with Budget Warden's MIME type (`application/vnd.lazarovco.budgetwarden.budget`) or its private app property, across everything the account can see, including files other people shared with it. Shared budgets are flagged `shared_with_me` with their owner, and budgets the user can only view never upload.
- **Sharing.** `share_budget` adds a Drive permission (`writer` or `reader`) for an email address and has Google send the invitation email. The recipient's Budget Warden lists the budget under budgets shared with them on its next refresh. `list_shares` and `remove_share` manage who has access.
- **New budgets** go to a `Budget Warden` folder in the user's My Drive, created on first use (and recreated if deleted).
- **Sign-in.** OAuth 2.0 authorization code flow with PKCE:
  - macOS and iOS: `ASWebAuthenticationSession` with an iOS-type OAuth client and its reversed-client-ID redirect (`com.googleusercontent.apps.<id>:/oauth2redirect`).
  - Windows, Linux, and the CLI: the system browser with a loopback redirect to `http://127.0.0.1:<random port>` (`BWGoogleLoopbackReceiver`) and a "Desktop app" OAuth client.
  - Android: Google Play services `AuthorizationClient` supplies access tokens directly (`BWGoogleTokenSource`); no client ID is compiled into the app.
- **Credentials.** The core never stores tokens itself. Each host supplies a `BWGoogleCredentialStore`: the Keychain on Apple platforms, the Windows Credential Locker, a `0600` file in the config directory on Linux and in the CLI, and SharedPreferences on Android (which only holds the account name; Play services holds the tokens). Signing out revokes the refresh token and deletes working copies.
- **Networking.** The host performs HTTP through `BWHttpClient` (URLSession, HttpURLConnection, HttpClient), so platform proxies and certificate trust apply. Rust hosts use `cloud::native::NativeHttpClient` (ureq with rustls) behind the core's `native-http` feature.

### iCloud Drive (macOS and iOS)

iCloud budgets are ordinary files in the app's iCloud container (`iCloud.com.lazarovco.BudgetWarden`), which appears as a **Budget Warden** folder in iCloud Drive. iCloud itself syncs them; `BWICloudBudgetLibrary` in `apple-core` adds:

- **Listing** with `NSMetadataQuery` over the app's container and over iCloud items shared with the user that the app can access.
- **Download before open** for items that are not yet on the device.
- **CRDT conflict resolution:** when iCloud reports conflicting versions of a budget, the versions are merged with the core CRDT instead of letting one device's edits win.
- **Live reload:** when iCloud delivers a change to the open budget, the app reloads it.
- **Sharing** through the system share sheet (`ShareLink`), which offers iCloud collaboration ("Collaborate" / "Share File in iCloud") for iCloud Drive files.

Shared-with-me discovery for iCloud is limited by Apple's APIs: there is no API that lists every iCloud Drive item shared with a user. An iCloud budget shared with you appears in Budget Warden after you accept and open the share link once (from Messages, Mail, Files, or Finder), and stays listed afterwards.

## Platform summary

| Client | Google Drive sign-in | Token storage | iCloud Drive |
| --- | --- | --- | --- |
| macOS | ASWebAuthenticationSession (iOS-type client) | Keychain | Yes |
| iOS | ASWebAuthenticationSession (iOS-type client) | Keychain | Yes |
| Android | Play services AuthorizationClient | Play services | — |
| Windows | Browser + loopback (Desktop client) | Credential Locker | — |
| Linux | Browser + loopback (Desktop client) | `~/.config/budget-warden/google-credentials.json` (0600) | — |
| CLI | Browser + loopback (Desktop client) | `<config dir>/google-credentials.json` (0600) | — |

## Setup before release

### 1. Google Cloud project

1. Create (or choose) a Google Cloud project and **enable the Google Drive API**.
2. Configure the **OAuth consent screen** (Google Auth Platform → Branding/Audience/Data access): app name, support email, logo, homepage, privacy policy, and terms URLs, authorized domains, and the scope `https://www.googleapis.com/auth/drive`.
3. **Verification.** `https://www.googleapis.com/auth/drive` is a *restricted* scope. While the app is in "Testing", only listed test users (up to 100) can sign in and refresh tokens expire after 7 days. Publishing to production requires Google's OAuth app verification **and an annual third-party security assessment (CASA)** for restricted scopes. Budget Warden needs the full `drive` scope to discover and edit budgets that other people shared with the user; `drive.file` only reaches files the app created or the user picked, so automatic discovery of shared budgets would not work with it.
4. Create the OAuth clients:
   - **iOS** client with bundle ID `com.lazarovco.budgetwarden` (used by both the macOS and iOS apps).
   - **Android** client with package `com.lazarovco.budgetwarden.android` and the SHA-1 fingerprint of **every** signing certificate (debug, upload, and the Google Play app signing key).
   - **Desktop app** client (used by Windows, Linux, and the CLI). Google issues a client secret for it; it is not confidential in a desktop app and is shipped in the binary, as Google's installed-app guidance expects.

### 2. Build configuration

| Client | Where the Google client goes |
| --- | --- |
| macOS / iOS | Build setting `BW_GOOGLE_CLIENT_ID` (iOS client ID) in the app targets or an `.xcconfig`; `Info.plist` reads it as `BWGoogleClientID`. Empty hides Google Drive. |
| Android | Nothing in code. Registration in the Cloud project is enough. `-Pbw.googleDrive=false` hides the feature. |
| Windows | `dotnet build -p:BWGoogleClientId=… -p:BWGoogleClientSecret=…` (Desktop client), or the environment variables below at run time. |
| Linux / CLI | `BUDGET_WARDEN_GOOGLE_CLIENT_ID` and `BUDGET_WARDEN_GOOGLE_CLIENT_SECRET` (Desktop client), read at compile time and overridable at run time. |

### 3. Apple capabilities

- The iCloud capability with **iCloud Documents** and the container `iCloud.com.lazarovco.BudgetWarden` must be enabled for both App IDs in the Apple Developer portal, and provisioning profiles regenerated. The entitlements files already request it.
- `NSUbiquitousContainers` in both `Info.plist` files makes the container visible in iCloud Drive as "Budget Warden". The container metadata only refreshes when `CFBundleVersion` increases, so bump the build number when shipping.
- The macOS app sandbox now has `com.apple.security.network.client` for Google Drive requests.
- Keychain items use the default access group; no keychain-sharing entitlement is required.

### 4. Store and privacy disclosures

- App Store privacy labels, the Google Play Data safety form, and the privacy policy must disclose that budget files are stored in and shared through the user's Google Drive and iCloud, and that the app accesses the user's Google account email address.
- Google requires the privacy policy to describe use of Google user data and to comply with the Google API Services User Data Policy, including the Limited Use requirements for restricted scopes.

## Testing

- `cargo test` in `core/` runs end-to-end tests against an in-memory Google Drive and OAuth server (`cloud::testing::FakeDrive`, also available to other crates through the `test-support` feature): PKCE sign-in, token refresh and revocation, multi-device convergence, a lost upload race, sharing with writers and readers, discovery, revocation, and folder recreation.
- `cargo test --manifest-path linux/Cargo.toml` drives the Linux cloud controller and app state through creation, editing, coalesced sync, sharing, discovery, and sign-out against the fake server.
- `cargo test --manifest-path cli/Cargo.toml` covers the `cloud` commands' configuration and sign-in errors.
- Android JVM tests (`CloudSyncTest`) cover sync coalescing, labels, and the HTTP client; `apple-core` Swift tests cover error mapping, labels, configuration, and conflict handling.
- `cargo test --features native-http -- --ignored` in `core/` checks that the native HTTP client reaches the real Drive API.
