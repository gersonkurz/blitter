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

# Build the app (Debug or Release)
build config="Debug": generate
    xcodebuild build -project {{project}} -scheme {{scheme}} -configuration {{config}} \
        -destination "{{destination}}" -derivedDataPath {{derived_data}} | xcbeautify --quiet

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

# BlitterCore and BlitterModel must not depend on UI frameworks
check-boundaries:
    #!/usr/bin/env bash
    set -euo pipefail
    # Covers attributes (@testable, @preconcurrency), access levels (public import), kind imports
    # (import class AppKit.NSView), submodules and several imports on one line separated by ';'.
    pattern='(^|;)\s*((@[A-Za-z_]+(\([^)]*\))?|open|public|package|internal|fileprivate|private)\s+)*import\s+((typealias|struct|class|enum|protocol|let|var|func)\s+)?(AppKit|Cocoa|SwiftUI)\b'
    if grep -rnE "$pattern" Sources/BlitterCore Sources/BlitterModel; then
        echo "error: BlitterCore and BlitterModel must not import AppKit, Cocoa or SwiftUI" >&2
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
