#!/usr/bin/env bash
# Release CI: checks that every signing secret is set, then installs the Developer ID
# certificate in a throwaway keychain and writes the notary key. Passes KEYCHAIN and
# NOTARY_KEY_PATH to later steps through $GITHUB_ENV; remove-signing.sh undoes it.
set -euo pipefail

# Releases are always Developer ID signed: fail rather than ship an ad hoc build.
missing=()
for var in APPLE_TEAM_ID SPARKLE_PUBLIC_KEY NOTARY_KEY_ID NOTARY_ISSUER_ID CERTIFICATE_P12 CERTIFICATE_PASSWORD NOTARY_KEY SPARKLE_PRIVATE_KEY; do
    [[ -n "${!var:-}" ]] || missing+=("$var")
done
if (( ${#missing[@]} )); then
    echo "::error::A signed release needs these, which are missing: ${missing[*]}"
    exit 1
fi

KEYCHAIN="$RUNNER_TEMP/signing.keychain-db"
NOTARY_KEY_PATH="$RUNNER_TEMP/notary-key.p8"
echo "KEYCHAIN=$KEYCHAIN" >> "$GITHUB_ENV"
echo "NOTARY_KEY_PATH=$NOTARY_KEY_PATH" >> "$GITHUB_ENV"

# A throwaway keychain holding only the Developer ID certificate.
password="$(uuidgen)"
security create-keychain -p "$password" "$KEYCHAIN"
security set-keychain-settings -lut 3600 "$KEYCHAIN"
security unlock-keychain -p "$password" "$KEYCHAIN"
base64 --decode <<<"$CERTIFICATE_P12" > "$RUNNER_TEMP/certificate.p12"
security import "$RUNNER_TEMP/certificate.p12" -k "$KEYCHAIN" -P "$CERTIFICATE_PASSWORD" -T /usr/bin/codesign
rm "$RUNNER_TEMP/certificate.p12"
security set-key-partition-list -S apple-tool:,apple: -s -k "$password" "$KEYCHAIN" >/dev/null
keychains=()
while IFS= read -r keychain; do keychains+=("$keychain"); done \
    < <(security list-keychains -d user | sed -E 's/^[[:space:]]*"(.*)"$/\1/')
security list-keychains -d user -s "$KEYCHAIN" "${keychains[@]}"
printf '%s' "$NOTARY_KEY" > "$NOTARY_KEY_PATH"
