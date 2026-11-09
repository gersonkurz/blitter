# Build automation for Blitter (macOS only)
# Requires: just, xcodegen, xcbeautify, swiftformat, swiftlint

set shell := ["bash", "-euo", "pipefail", "-c"]

project := "Blitter.xcodeproj"
scheme := "Blitter"
derived_data := "build/DerivedData"
destination := "platform=macOS,arch=arm64"

# Version from project.yml (MARKETING_VERSION)
version := `grep -E '^\s*MARKETING_VERSION:' project.yml | head -1 | sed -E 's/.*: *//'`

# Show the available recipes
default:
    @just --list

# Generate Blitter.xcodeproj from project.yml
generate:
    xcodegen generate --quiet

# Render the app icon (docs/logo/*.svg) into Sources/BlitterApp/AppIcon.icns
icon:
    #!/usr/bin/env bash
    set -euo pipefail
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    swiftc -O tools/render-icon.swift -o "$work/render-icon"
    "$work/render-icon" docs/logo/blitter-chip.svg docs/logo/blitter-chip-small.svg "$work/AppIcon.iconset"
    iconutil -c icns "$work/AppIcon.iconset" -o Sources/BlitterApp/AppIcon.icns

# Build the app (Debug or Release): `just build Release`. Arguments are positional, so
# `just build config=Release` would pass "config=Release" — refused here with a clear message
# instead of a misleading package-resolution error from xcodebuild.
build config="Debug": generate
    @config={{quote(config)}}; case "$config" in Debug|Release) ;; *) printf 'error: unknown configuration "%s" — use: just build Debug | just build Release\n' "$config" >&2; exit 2;; esac
    xcodebuild build -project {{project}} -scheme {{scheme}} -configuration {{quote(config)}} \
        -destination "{{destination}}" -derivedDataPath {{derived_data}} | xcbeautify --quiet

# Make the manual's screenshots from the app (docs/manual/images); see docs/PLAN.md, Manual.
# In English (US), whatever this Mac's language: sizes read "3.3 MB" as the manual does.
screenshots: generate
    TEST_RUNNER_BLITTER_SCREENSHOTS=1 xcodebuild test -project {{project}} -scheme {{scheme}} -configuration Debug \
        -destination "{{destination}}" -derivedDataPath {{derived_data}} \
        -testLanguage en -testRegion US -only-testing:BlitterAppTests/ManualScreenshots | xcbeautify --quiet

# The manual's pictures of open menus (#69): the real app, isolated (BLITTER_PROFILE), on demo
# folders, driven over its automation socket. Needs Screen Recording for this terminal.
menu-screenshots: (build "Debug")
    #!/usr/bin/env bash
    set -euo pipefail
    app="{{derived_data}}/Build/Products/Debug/Blitter.app"
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    swiftc -O tools/menu-window.swift -o "$work/menu-window"
    set +e
    "$work/menu-window" $$ >/dev/null 2>"$work/check" # 2: no Screen Recording permission
    check=$?
    set -e
    if [ "$check" -eq 2 ]; then cat "$work/check" >&2; exit 2; fi
    # Made by this run, or not at all: a folder of that name that is already there is left alone.
    demo="/Users/Shared/Blitter Demo"
    if ! mkdir "$demo" 2>/dev/null; then echo "$demo is already there; remove it first." >&2; exit 1; fi
    trap 'rm -rf "$work" "$demo"' EXIT
    stamp() { touch -t "$1" "$2"; }
    file() { mkdir -p "$(dirname "$demo/$1")"; mkfile -n "$2" "$demo/$1"; stamp "$3" "$demo/$1"; }
    file "Projects/blitter/README.md" 4812 202610281412
    file "Projects/blitter/justfile" 3406 202610271412
    file "Projects/blitter/project.yml" 2210 202610211412
    file "Projects/blitter/LICENSE" 1067 202610021412
    file "Projects/blitter/Sources/App.swift" 2048 202610300912
    file "Projects/blitter/Tests/AppTests.swift" 1024 202610300912
    file "Projects/blitter/docs/manual.md" 1024 202610280912
    for number in 1 2 3 4 5 6; do
        file "Pictures/Iceland 2026/IMG_$((4100 + number * 7)).jpg" $((3100000 + number * 211337)) 2026100$((3 + number))1412
    done
    # The folders' own dates, set after their files were made (which changed them).
    stamp 202610300912 "$demo/Projects/blitter/Sources"
    stamp 202610300912 "$demo/Projects/blitter/Tests"
    stamp 202610280912 "$demo/Projects/blitter/docs"
    profile="$demo/.profile"
    mkdir -m 700 "$profile"
    printf '[favorites]\nfolders = ["%s/Projects", "%s/Pictures", "/Applications"]\n' "$demo" "$demo" > "$profile/settings.toml"
    BLITTER_PROFILE="$profile" "$app/Contents/MacOS/Blitter" >/dev/null 2>&1 &
    pid=$!
    trap 'kill $pid 2>/dev/null || true; rm -rf "$work" "$demo"' EXIT # never another Blitter
    export BLITTER_SOCKET="$profile/automation.sock"
    cli="$app/Contents/Helpers/blitter"
    for _ in $(seq 50); do "$cli" state >/dev/null 2>&1 && break; sleep 0.2; done
    "$cli" navigate left "$demo/Projects/blitter" >/dev/null
    "$cli" navigate right "$demo/Pictures/Iceland 2026" >/dev/null
    "$cli" activate left >/dev/null
    shoot() { # name, params
        "$cli" call showMenu "$2" >/dev/null
        sleep 1.5
        bounds=$("$work/menu-window" "$pid")
        screencapture -x -R "$bounds" "docs/manual/images/$1.png"
        sleep 3 # until it closed
    }
    "$cli" select left README.md >/dev/null
    shoot menu-items '{"menu": "context", "side": "left", "seconds": 4}'
    "$cli" select left >/dev/null # nothing selected: the folder's menu
    shoot menu-folder '{"menu": "context", "side": "left", "seconds": 4}'
    # Not Go: macOS shows ⌘[ and ⌘] as the keyboard layout types them (⌘Ö, ⌘Ä on a German one).
    for menu in File Edit; do
        shoot "menu-$(echo "$menu" | tr '[:upper:]' '[:lower:]')" "{\"menu\": \"$menu\", \"seconds\": 4}"
    done
    echo "Pictures of open menus in docs/manual/images (menu-*.png)."

# Write the manual's generated reference pages (docs/manual/reference) from the code
manual: generate
    TEST_RUNNER_BLITTER_WRITE_MANUAL=1 xcodebuild test -project {{project}} -scheme {{scheme}} -configuration Debug \
        -destination "{{destination}}" -derivedDataPath {{derived_data}} \
        -only-testing:BlitterModelTests/ManualReferenceTests | xcbeautify --quiet

# Build and launch the Debug app
run: (build "Debug")
    open "{{derived_data}}/Build/Products/Debug/Blitter.app"

# Run all unit tests. xcodebuild always executes them; there is no test result cache.
test: generate
    xcodebuild test -project {{project}} -scheme {{scheme}} -configuration Debug \
        -destination "{{destination}}" -derivedDataPath {{derived_data}} | xcbeautify

# Check formatting, lint rules and module boundaries without changing anything
lint: check-boundaries
    swiftformat --lint .
    swiftlint lint --strict --quiet

# BlitterCore, BlitterModel and BlitterGit must not depend on UI frameworks; Core and Model
# not on BlitterGit either
check-boundaries:
    #!/usr/bin/env bash
    set -euo pipefail
    # Covers attributes (@testable, @preconcurrency), access levels (public import), kind imports
    # (import class AppKit.NSView), submodules and several imports on one line separated by ';'.
    pattern='(^|;)\s*((@[A-Za-z_]+(\([^)]*\))?|open|public|package|internal|fileprivate|private)\s+)*import\s+((typealias|struct|class|enum|protocol|let|var|func)\s+)?(AppKit|Cocoa|SwiftUI)\b'
    if grep -rnE "$pattern" Sources/BlitterCore Sources/BlitterModel Sources/BlitterGit; then
        echo "error: BlitterCore, BlitterModel and BlitterGit must not import AppKit, Cocoa or SwiftUI" >&2
        exit 1
    fi
    git_pattern="${pattern/(AppKit|Cocoa|SwiftUI)/BlitterGit}"
    if grep -rnE "$git_pattern" Sources/BlitterCore Sources/BlitterModel; then
        echo "error: BlitterCore and BlitterModel must not import BlitterGit" >&2
        exit 1
    fi
    echo "Module boundaries OK"

# Format all sources in place
format:
    swiftformat .

# Everything that must pass before review: generate, lint, build and test
verify: generate lint test

# Build a Developer ID signed Release app and wrap it in a DMG under releases/.
# Everything is staged in build/ first; existing artifacts in releases/ are only touched on success.
package: generate
    #!/usr/bin/env bash
    set -euo pipefail
    stage=build/package
    rm -rf "$stage"
    mkdir -p "$stage/root"
    xcodebuild build -project {{project}} -scheme {{scheme}} -configuration Release \
        -destination "{{destination}}" -derivedDataPath {{derived_data}} | xcbeautify --quiet
    app="{{derived_data}}/Build/Products/Release/Blitter.app"
    codesign --verify --strict --deep "$app"
    cp -R "$app" "$stage/root/"
    ln -s /Applications "$stage/root/Applications"
    name="Blitter-{{version}}.dmg"
    diskutil image create from --format ULFO --volumeName "Blitter {{version}}" "$stage/root" "$stage/$name"
    codesign --sign "Developer ID Application" --identifier com.p-nand-q.blitter.dmg --timestamp "$stage/$name"
    mkdir -p releases
    mv -f "$stage/$name" "releases/$name"
    (cd releases && shasum -a 256 *.dmg > checksums.txt)
    echo "Created releases/$name"

# Notarize and staple the DMG. Store credentials once with: xcrun notarytool store-credentials <profile>
notarize profile="blitter-notary":
    xcrun notarytool submit "releases/Blitter-{{version}}.dmg" --keychain-profile "{{profile}}" --wait
    xcrun stapler staple "releases/Blitter-{{version}}.dmg"
    (cd releases && shasum -a 256 *.dmg > checksums.txt)

# Remove build output and the generated project
clean:
    rm -rf build releases {{project}}

# Show build information
info:
    @echo "Blitter {{version}}"
    @echo "Xcode: $(xcodebuild -version | head -1)"
    @echo "Swift: $(swift --version 2>&1 | head -1)"

# Run the timing probes (large temporary folders; takes a while)
bench: generate
    TEST_RUNNER_BLITTER_BENCHMARK=1 xcodebuild test -project {{project}} -scheme {{scheme}} -configuration Release ENABLE_TESTABILITY=YES \
        -destination "{{destination}}" -derivedDataPath {{derived_data}} \
        -only-testing:BlitterCoreTests/DirectoryListingBenchmark -only-testing:BlitterModelTests/ListingBenchmark | grep -E "BENCHMARK|passed|failed|error"
