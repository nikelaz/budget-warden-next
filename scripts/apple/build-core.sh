#!/bin/bash
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/../.." && pwd)"
core_root="$repository_root/core"

# Use the same generator revision as the Rust dependency.
revision="$(python3 - "$core_root/Cargo.toml" <<'PY'
import json, subprocess, sys
from urllib.parse import parse_qs, urlsplit
metadata = json.loads(subprocess.check_output([
    'cargo', 'metadata', '--no-deps', '--offline', '--format-version', '1',
    '--manifest-path', sys.argv[1],
]))
package = next(package for package in metadata['packages'] if package['name'] == 'bw_core')
dependency = next(dependency for dependency in package['dependencies'] if dependency['name'] == 'boltffi')
revision = parse_qs(urlsplit(dependency['source']).query)['rev'][0]
if len(revision) != 40 or any(c not in '0123456789abcdef' for c in revision):
    raise SystemExit('BoltFFI must be pinned to a full Git commit.')
print(revision)
PY
)"
tool_root="$core_root/target/boltffi-apple-$revision"

if [[ ! -d "$tool_root/.git" ]]; then
    mkdir -p "$tool_root"
    git -C "$tool_root" init
    git -C "$tool_root" remote add origin https://github.com/boltffi/boltffi.git
    git -C "$tool_root" fetch --depth 1 origin "$revision"
    git -C "$tool_root" checkout --detach FETCH_HEAD
fi
[[ "$(git -C "$tool_root" rev-parse HEAD)" == "$revision" ]] || {
    echo 'The cached BoltFFI checkout does not match the pinned revision.' >&2
    exit 1
}

rustup target add aarch64-apple-darwin x86_64-apple-darwin \
    aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
cargo build --manifest-path "$tool_root/Cargo.toml" --package boltffi_cli --release
cd "$core_root"
"$tool_root/target/release/boltffi" pack apple --release --regenerate
test -f dist/apple/Package.swift
