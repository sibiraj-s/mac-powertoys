#!/usr/bin/env bash
# Release CI: attaches the DMG and the Sparkle appcast to the v<version> release that
# `changeset publish` created. Installed copies read the appcast from the latest release.
#
#   scripts/release/publish.sh 1.3.0
set -euo pipefail
cd "$(dirname "$0")/../.."
version="${1:?usage: scripts/release/publish.sh <version>}"

gh release upload "v$version" "build/PowerToys-$version.dmg" build/appcast.xml --clobber
