#!/usr/bin/env bash
# The release DMG around a signed Blitter.app (#99): the app and a link to /Applications, signed
# with $MACOS_CODESIGN_IDENTITY (default: the Developer ID Application certificate) and checked.
# `just package` makes it around the app it built; `just notarize` again around the app once
# that is notarized and stapled.
#
# usage: tools/make-dmg.sh APP VERSION OUT.dmg
set -euo pipefail
app=$1
version=$2
out=$3
identity="${MACOS_CODESIGN_IDENTITY:-Developer ID Application}"
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
ditto "$app" "$root/Blitter.app"
ln -s /Applications "$root/Applications"
rm -f "$out"
diskutil image create from --format ULFO --volumeName "Blitter $version" "$root" "$out" >/dev/null
codesign --sign "$identity" --identifier com.p-nand-q.blitter.dmg --timestamp "$out"
codesign --verify --strict "$out"
