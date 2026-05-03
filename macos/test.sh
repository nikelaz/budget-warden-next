#!/usr/bin/env bash
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_PATH="$APP_DIR/BudgetWarden.xcodeproj"
DERIVED_DATA_PATH="$APP_DIR/.build"

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

if ! xcodebuild -version >/dev/null 2>&1; then
  cat >&2 <<'EOF'
error: xcodebuild requires a full Xcode installation.

Install Xcode from the App Store or point this shell at Xcode:
  sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
EOF
  exit 1
fi

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme BudgetWarden \
  -configuration Debug \
  -destination "platform=macOS,arch=arm64" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  test
