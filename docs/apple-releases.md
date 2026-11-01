# Apple releases

The [Apple App Store release workflow](../.github/workflows/apple-app-store.yml)
runs when a tag such as `v3.0.1` is pushed. It builds the tagged Rust core and Apple
bindings, archives both apps, signs them for the App Store, saves the signed iOS
IPA and macOS installer package as GitHub Actions artifacts, and uploads both
builds to App Store Connect. App Review submission is done in App Store Connect
after processing finishes.

## Apple setup

Use the existing Apple Developer team `KCDH4VF88Y` and bundle identifier
`com.lazarovco.budgetwarden`, with iOS and macOS platforms enabled in App Store
Connect. Accept any outstanding Apple agreements before running a release.

Create or export these signing assets with their private keys:

- An **Apple Distribution** certificate used by both App Store provisioning
  profiles. Export the certificate and private key from Keychain Access as a
  password-protected `.p12` file. If the profiles use separate certificates, export
  both identities together into the same `.p12` file.
- A **Mac Installer Distribution** certificate and private key, exported as a
  second `.p12` file. Use the same export password for both files.
- An **App Store Connect distribution profile for iOS**, and a **Mac App Store
  distribution profile for macOS**. Both must be for the app's bundle ID and
  include the iCloud Documents capability and container
  `iCloud.com.lazarovco.BudgetWarden`. The profiles must reference an application
  signing certificate included in the first `.p12` file.
- An **App Store Connect team API key** with permission to upload builds (for
  example, the Developer role and access to this app). Download its `.p8` private
  key and record its Key ID and Issuer ID.

Apple documents the [certificate types](https://developer.apple.com/help/account/certificates/certificates-overview/),
[API key setup](https://developer.apple.com/documentation/AppStoreConnectAPI/creating-api-keys-for-app-store-connect-api),
and [build upload requirements](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/).

## GitHub secrets

In the repository, open **Settings → Secrets and variables → Actions** and add
these repository secrets:

| Secret | Value |
| --- | --- |
| `APP_STORE_CONNECT_KEY_ID` | API key's Key ID |
| `APP_STORE_CONNECT_ISSUER_ID` | API key's Issuer ID |
| `APP_STORE_CONNECT_PRIVATE_KEY` | Entire `.p8` file, including its header, footer, and newlines |
| `APPLE_DISTRIBUTION_P12_BASE64` | Base64 of the application signing `.p12` file |
| `MAC_INSTALLER_P12_BASE64` | Base64 of the Mac Installer Distribution `.p12` file |
| `APPLE_CERTIFICATE_PASSWORD` | Export password used for both `.p12` files |
| `IOS_APP_STORE_PROFILE_BASE64` | Base64 of the iOS App Store provisioning profile |
| `MACOS_APP_STORE_PROFILE_BASE64` | Base64 of the macOS App Store provisioning profile |

To copy a file as a single base64 line on macOS:

```sh
base64 -i Distribution.p12 | tr -d '\n' | pbcopy
```

Optional repository variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `APPLE_TEAM_ID` | `KCDH4VF88Y` | Team used for signing and upload |
| `APPLE_BUILD_NUMBER_OFFSET` | `1000` | Added to this workflow's run number; raise it if existing uploaded builds have a higher build number |

The workflow uses GitHub's `macos-26` runner, Xcode 26.6, and Rust 1.97.1. Update
the pinned Xcode path in the workflow when changing the release SDK. The runner
must have the selected Xcode installed; Apple's current upload SDK requirements
also apply.

## Release a version

Commit the app changes, workflow, and scripts before tagging. For example:

```sh
git tag v3.0.1
git push origin v3.0.1
```

Only `vMAJOR.MINOR.PATCH` tags are accepted. Prerelease suffixes are rejected. The
tag sets `MARKETING_VERSION` for both apps without editing the Xcode projects.
The build number is `<offset + workflow run number>.<run attempt>`: the first
run is normally `1001.1`, and rerunning that release produces `1001.2`. Both
platforms use the same build number. Apple limits the major component to 9999
and the attempt component to 99; validation fails before building if exceeded.

Watch the **Apple App Store release** run in Actions. Each platform independently
produces an artifact containing its signed package and zipped dSYMs, retained for
14 days. Artifacts are saved before uploading, so an upload failure does not lose
the package. The artifacts are App Store distribution packages, not installers
for general distribution outside the store.

If one platform fails, fix the cause and choose **Re-run failed jobs**. To rerun
both, choose **Re-run all jobs**. The optional **Run workflow** button requires
selecting an existing version tag; branch runs fail validation. App Store Connect
can reject an upload if its marketing version is no longer eligible for updates.

The workflow checks profile expiration, team, bundle ID, platform, iCloud
containers, and the matching signing identity before archiving. Credentials are
installed in a temporary keychain and removed in an `always()` cleanup step.
No Apple credentials are included in artifacts. GitHub's
[signing guide](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications)
describes the temporary keychain approach.

After Apple processes the builds, choose the appropriate iOS and macOS builds
for the version in App Store Connect, complete the store metadata, and
[submit for App Review](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-app).

## Regenerate Apple bindings locally

With Rust, the full Xcode toolchain, and its license set up:

```sh
bash scripts/apple/build-core.sh
```

This builds the BoltFFI revision pinned in `core/Cargo.toml` and regenerates the
release Swift package and universal XCFramework under `core/dist/apple`.
