#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

submodule_status="$(git submodule status --recursive)"
if printf '%s\n' "$submodule_status" | grep -Eq '^[+U-]'; then
    printf '%s\n' "Submodule state is missing, conflicted, or differs from the lockfile:" >&2
    printf '%s\n' "$submodule_status" >&2
    exit 1
fi

git submodule foreach --recursive --quiet \
    'if test -n "$(git status --porcelain)"; then echo "dirty submodule: $name" >&2; exit 1; fi'

tracked_sensitive_paths="$(
    git ls-files | awk '
        /(^|\/)\.env\.(example|sample|template)$/ { next }
        /(^|\/)\.env($|\.)/ ||
        /(^|\/)broadcast\// ||
        /(^|\/)cache\// ||
        /\.pem$/ ||
        /\.(key|p12|pfx)$/ ||
        /(^|\/)(keystore|keystores)\// ||
        /(^|\/)\.gstack\/security-reports\// { print }
    '
)"
if [[ -n "$tracked_sensitive_paths" ]]; then
    printf '%s\n' "Sensitive or ephemeral files are tracked:" >&2
    printf '%s\n' "$tracked_sensitive_paths" >&2
    exit 1
fi

expected_legacy_manifest_sha="e35253ff1c1aaa16e67cf6543942332031ac1691392bb578a07ca6fa2c5aa7e2"
actual_legacy_manifest_sha="$(shasum -a 256 deployments/arbitrum-sepolia-latest.json | awk '{print $1}')"
if [[ "$actual_legacy_manifest_sha" != "$expected_legacy_manifest_sha" ]]; then
    printf '%s\n' "Legacy deployment manifest changed unexpectedly." >&2
    printf 'expected=%s\nactual=%s\n' \
        "$expected_legacy_manifest_sha" "$actual_legacy_manifest_sha" >&2
    exit 1
fi

git diff --check
