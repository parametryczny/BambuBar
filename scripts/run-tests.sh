#!/bin/zsh
set -euo pipefail

# Runs the BambuBar test suite (swift-testing).
#
# On machines with only the Command Line Tools installed (no full Xcode) the
# swift-testing macro plugin and runtime framework are not on the default
# search paths, and building inside an iCloud-synced folder trips codesign on
# Finder metadata. This script papers over both so `swift test` just works,
# while staying a no-op on a normal full-Xcode setup.

PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"

ARGS=("$@")

# Build outside the (possibly iCloud-synced) project tree to avoid the
# "resource fork, Finder information, or similar detritus not allowed" codesign
# failure on the freshly built .xctest bundle.
SCRATCH="${TMPDIR:-/tmp}bambubar-tests"
ARGS+=(--scratch-path "$SCRATCH")

DEVELOPER_DIR="$(xcode-select -p)"
if [[ "$DEVELOPER_DIR" == *CommandLineTools* ]]; then
    PLUGIN_DIR="$DEVELOPER_DIR/usr/lib/swift/host/plugins/testing"
    FRAMEWORK_DIR="$DEVELOPER_DIR/Library/Developer/Frameworks"
    INTEROP_DIR="$DEVELOPER_DIR/Library/Developer/usr/lib"
    ARGS+=(
        -Xswiftc -plugin-path -Xswiftc "$PLUGIN_DIR"
        -Xlinker -rpath -Xlinker "$FRAMEWORK_DIR"
        -Xlinker -rpath -Xlinker "$INTEROP_DIR"
    )
fi

exec swift test "${ARGS[@]}"
