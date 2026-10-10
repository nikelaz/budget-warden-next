#!/bin/bash
set -euo pipefail

platform="${1:?Expected ios or macos}"
operation="${2:?Expected package or upload}"
case "$platform" in
    ios) scheme=BudgetWardenIOS; destination='generic/platform=iOS' ;;
    macos) scheme=BudgetWardenMac; destination='generic/platform=macOS' ;;
    *) echo 'Expected ios or macos.' >&2; exit 1 ;;
esac
case "$operation" in
    package|upload) ;;
    *) echo 'Expected package or upload.' >&2; exit 1 ;;
esac

repository_root="$(cd "$(dirname "$0")/../.." && pwd)"
output="$RUNNER_TEMP/apple-release/$platform"
archive="$output/BudgetWarden.xcarchive"
mkdir -p "$output"
export APPLE_RELEASE_PLATFORM="$platform" APPLE_RELEASE_OPERATION="$operation"
export APPLE_RELEASE_OUTPUT="$output"
python3 - <<'PY'
import os, pathlib, plistlib
options = {
    'method': 'app-store-connect',
    'destination': 'export' if os.environ['APPLE_RELEASE_OPERATION'] == 'package' else 'upload',
    'signingStyle': 'manual',
    'teamID': os.environ['APPLE_TEAM_ID'],
    'signingCertificate': os.environ['APPLE_SIGNING_IDENTITY'],
    'provisioningProfiles': {'com.lazarovco.budgetwarden': os.environ['APPLE_PROFILE_UUID']},
    'manageAppVersionAndBuildNumber': False,
    'uploadSymbols': True,
}
if os.environ['APPLE_RELEASE_PLATFORM'] == 'macos':
    options['installerSigningCertificate'] = 'Mac Installer Distribution'
path = pathlib.Path(os.environ['APPLE_RELEASE_OUTPUT']) / 'ExportOptions.plist'
path.write_bytes(plistlib.dumps(options))
PY

if [[ "$operation" == package ]]; then
    xcodebuild -workspace "$repository_root/BudgetWarden.xcworkspace" \
        -scheme "$scheme" -configuration Release -destination "$destination" \
        -derivedDataPath "$RUNNER_TEMP/apple-derived-data/$platform" \
        -archivePath "$archive" archive \
        MARKETING_VERSION="$APPLE_RELEASE_VERSION" \
        CURRENT_PROJECT_VERSION="$APPLE_RELEASE_BUILD" \
        DEVELOPMENT_TEAM="$APPLE_TEAM_ID" CODE_SIGN_STYLE=Manual \
        CODE_SIGN_IDENTITY="$APPLE_SIGNING_IDENTITY" \
        PROVISIONING_PROFILE_SPECIFIER="$APPLE_PROFILE_UUID" \
        OTHER_CODE_SIGN_FLAGS="--keychain $APPLE_KEYCHAIN"
    xcodebuild -exportArchive -archivePath "$archive" \
        -exportOptionsPlist "$output/ExportOptions.plist" -exportPath "$output/package"
    ditto -c -k --keepParent "$archive/dSYMs" "$output/dSYMs.zip"
else
    xcodebuild -exportArchive -archivePath "$archive" \
        -exportOptionsPlist "$output/ExportOptions.plist" -exportPath "$output/upload" \
        -allowProvisioningUpdates \
        -authenticationKeyPath "$APP_STORE_CONNECT_KEY_PATH" \
        -authenticationKeyID "$APP_STORE_CONNECT_KEY_ID" \
        -authenticationKeyIssuerID "$APP_STORE_CONNECT_ISSUER_ID"
fi
