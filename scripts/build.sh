#!/usr/bin/env bash
# Builds a Release of PowerToys (Apple Silicon) and packages it as build/PowerToys-<version>.dmg.
#
#   scripts/build.sh          version from the latest v* tag (fails if there is none)
#   scripts/build.sh 1.2.0    explicit version
#
# The build number is the commit's date in UTC (yyyyMMdd.HHmm), so it always goes up and
# rebuilding the same commit gives the same number.
#
# Environment (also read from .env):
#   APPLE_TEAM_ID      sign with this team's Developer ID certificate and notarize;
#                      without it the app is signed ad hoc
#   NOTARY_KEY_PATH    App Store Connect API key (.p8) used by notarytool
#   NOTARY_KEY_ID
#   NOTARY_ISSUER_ID
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -f .env ]]; then
    # Variables already in the environment take precedence over .env.
    exported="$(export -p)"
    set -a
    source .env
    set +a
    eval "$exported"
fi

version="${1:-$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)}"
if [[ -z "$version" ]]; then
    echo "error: no v* tag found; tag a release (git tag v1.0.0) or pass a version: scripts/build.sh 1.0.0" >&2
    exit 1
fi
version="${version#v}"
if [[ ! "$version" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    echo "error: version must look like 1.2.3 (got '$version')" >&2
    exit 1
fi
team="${APPLE_TEAM_ID:-}"
if [[ -n "$team" ]]; then
    for var in NOTARY_KEY_PATH NOTARY_KEY_ID NOTARY_ISSUER_ID; do
        [[ -n "${!var:-}" ]] || { echo "error: $var is required for a Developer ID build" >&2; exit 1; }
    done
fi
build_number="$(TZ=UTC git log -1 --format=%cd --date=format-local:%Y%m%d.%H%M)"

out=build
# Everything holding a copy of the app goes under one .noindex folder, which Spotlight
# skips, so built copies don't show up next to the installed PowerToys in app search.
work="$out/work.noindex"
derived="$work/DerivedData"
archive="$work/PowerToys.xcarchive"
export_dir="$work/export"
stage="$work/dmg"
dmg="$out/PowerToys-$version.dmg"
if [[ -n "$team" ]]; then
    app="$export_dir/PowerToys.app"
else
    app="$derived/Build/Products/Release/PowerToys.app"
fi
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# Built copies register with LaunchServices under the app's bundle ID; leftover ones can
# make the Dock show the wrong (blank) icon for the installed PowerToys. A signed build leaves
# copies in the archive and its intermediates too, so unregister every app under $out.
unregister() {
    [[ -d "$out" ]] || return 0
    find "$PWD/$out" -name '*.app' -type d | while IFS= read -r copy; do
        "$lsregister" -u "$copy" 2>/dev/null || true
    done
}
trap unregister EXIT

if [[ -n "$team" ]]; then
    # The SHA-1 of this team's Developer ID certificate, also used to sign the DMG.
    identity="$(security find-identity -v -p codesigning | awk -v team="($team)\"" \
        '/"Developer ID Application: / && index($0, team) { print $2; exit }')"
    [[ -n "$identity" ]] || { echo "error: no Developer ID Application certificate for team $team in the keychain" >&2; exit 1; }
    settings=(CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$team" CODE_SIGN_IDENTITY="$identity" OTHER_CODE_SIGN_FLAGS=--timestamp)
else
    settings=(CODE_SIGN_IDENTITY=-)
fi
settings+=(ARCHS=arm64 CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build_number")
xcodebuild=(xcodebuild -project PowerToys.xcodeproj -scheme PowerToys -configuration Release
    -destination 'generic/platform=macOS' -derivedDataPath "$derived" -quiet)

# xcodebuild warns about every installed simulator whose runtime is missing (common on CI
# images); xcbeautify drops that noise. Without it, the output goes through unchanged.
# NSUnbufferedIO stops xcodebuild from buffering its output into the pipe, so it streams.
export NSUnbufferedIO=YES
beautify() {
    if command -v xcbeautify >/dev/null; then
        xcbeautify ${GITHUB_ACTIONS:+--renderer github-actions}
    else
        cat
    fi
}

echo "==> Building PowerToys $version ($build_number)${team:+, signed for team $team}"
rm -rf "$stage" "$dmg" "$archive" "$export_dir" "$out/ExportOptions.plist"
if [[ -n "$team" ]]; then
    "${xcodebuild[@]}" -archivePath "$archive" "${settings[@]}" archive 2>&1 | beautify
    /usr/libexec/PlistBuddy -c "Add :method string developer-id" -c "Add :teamID string $team" \
        -c "Add :signingStyle string manual" -c "Add :signingCertificate string $identity" \
        "$out/ExportOptions.plist" >/dev/null
    xcodebuild -exportArchive -archivePath "$archive" -exportPath "$export_dir" \
        -exportOptionsPlist "$out/ExportOptions.plist" -quiet 2>&1 | beautify
    rm "$out/ExportOptions.plist"
else
    "${xcodebuild[@]}" "${settings[@]}" build 2>&1 | beautify
fi

echo "==> Verifying"
plist="$PWD/$app/Contents/Info.plist"
[[ "$(defaults read "$plist" CFBundleShortVersionString)" == "$version" ]] || { echo "error: version mismatch" >&2; exit 1; }
[[ "$(lipo -archs "$app/Contents/MacOS/PowerToys")" == "arm64" ]] || { echo "error: expected an arm64-only binary" >&2; exit 1; }
codesign --verify --deep --strict "$app"
if codesign -d --entitlements - --xml "$app" 2>/dev/null | grep -q get-task-allow; then
    echo "error: debug entitlement (get-task-allow) in the release build" >&2
    exit 1
fi
if [[ -n "$team" ]]; then
    # Notarization rejects code without the hardened runtime or a secure timestamp.
    details="$(codesign -dvv "$app" 2>&1)"
    grep -q "flags=.*runtime" <<<"$details" || { echo "error: no hardened runtime on $app" >&2; exit 1; }
    grep -q "^Timestamp=" <<<"$details" || { echo "error: no secure timestamp on $app" >&2; exit 1; }
fi

echo "==> Packaging $dmg"
# dmgbuild lays out the Finder window (background, icon positions) without scripting
# Finder, so it works the same on CI.
python3 -m venv "$work/venv"
"$work/venv/bin/pip" install -q --disable-pip-version-check dmgbuild==1.6.7
mkdir -p "$stage"
swift scripts/dmg/background.swift "$stage/background.png" 1
swift scripts/dmg/background.swift "$stage/background@2x.png" 2
tiffutil -cathidpicheck "$stage/background.png" "$stage/background@2x.png" -out "$stage/background.tiff" 2>/dev/null
# hdiutil needs absolute paths, and dmgbuild still uses the hdiutil commands macOS now
# marks as deprecated; hide those warnings.
"$work/venv/bin/dmgbuild" -s scripts/dmg/settings.py -D app="$PWD/$app" -D background="$PWD/$stage/background.tiff" PowerToys "$PWD/$dmg" \
    >/dev/null 2> >(grep -v "is deprecated" >&2 || true)
hdiutil verify "$dmg" -quiet
unregister
rm -rf "$stage"

if [[ -n "$team" ]]; then
    echo "==> Signing $dmg"
    codesign --sign "$identity" --timestamp "$dmg"

    # The DMG's ticket also covers the app inside it.
    echo "==> Notarizing (usually a few minutes)"
    notary=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
    # Read the result even when notarytool fails, so a rejection prints its log.
    result="$(xcrun notarytool submit "$dmg" "${notary[@]}" --wait --output-format json)" || true
    status="$(plutil -extract status raw - <<<"$result" 2>/dev/null)" || true
    if [[ "$status" != "Accepted" ]]; then
        echo "error: notarization failed (status: ${status:-none}): $result" >&2
        if id="$(plutil -extract id raw - <<<"$result" 2>/dev/null)"; then
            xcrun notarytool log "$id" "${notary[@]}" >&2 || true
        fi
        exit 1
    fi
    xcrun stapler staple -q "$dmg"
    xcrun stapler validate -q "$dmg"
    spctl --assess --type open --context context:primary-signature "$dmg"
fi

echo "==> Done: $dmg ($(du -h "$dmg" | cut -f1))"
