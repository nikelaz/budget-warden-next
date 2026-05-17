#!/usr/bin/env bash
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_PATH="$APP_DIR/.build/Build/Products/Debug/BudgetWarden.app"

"$APP_DIR/build.sh"
open "$APP_PATH"
