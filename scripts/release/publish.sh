#!/usr/bin/env bash
# Release CI: attaches the DMG to the v<version> release that `changeset publish` created.
#
#   scripts/release/publish.sh 0.1.0
set -euo pipefail
cd "$(dirname "$0")/../.."
version="${1:?usage: scripts/release/publish.sh <version>}"

gh release upload "v$version" "build/PowerToys-$version.dmg" --clobber
