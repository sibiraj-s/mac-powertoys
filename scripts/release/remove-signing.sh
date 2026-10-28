#!/usr/bin/env bash
# Release CI: removes what install-signing.sh set up. Runs even when an earlier step
# failed, so either may not exist.
set -uo pipefail

[[ -n "${KEYCHAIN:-}" ]] && security delete-keychain "$KEYCHAIN"
[[ -n "${NOTARY_KEY_PATH:-}" ]] && rm -f "$NOTARY_KEY_PATH"
exit 0
