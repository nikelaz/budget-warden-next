#!/usr/bin/env bash
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_PATH="$APP_DIR/.build/Build/Products/Debug/BudgetWarden.app"

"$APP_DIR/build.sh"

if [[ ! -d "$APP_PATH" ]]; then
  cat >&2 <<EOF
error: built app not found at:
  $APP_PATH
EOF
  exit 1
fi

open "$APP_PATH"
