#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_CACHE_ROOT="${TMPDIR:-/tmp}/codex-pet-monitor-build-cache"

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$BUILD_CACHE_ROOT/clang}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$BUILD_CACHE_ROOT/swiftpm}"

BIN_DIR="$(cd "$PROJECT_ROOT" && swift build -c release --disable-sandbox --show-bin-path)"
APP_DIR="$PROJECT_ROOT/dist/CodexPetMonitor.app"
CONTENTS_DIR="$APP_DIR/Contents"

cd "$PROJECT_ROOT"
swift build -c release --disable-sandbox

rm -rf "$APP_DIR"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"

cp "$PROJECT_ROOT/AppBundle/Contents/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$BIN_DIR/CodexPetMonitor" "$CONTENTS_DIR/MacOS/CodexPetMonitor"
cp -R "$BIN_DIR/CodexPetMonitor_CodexPetMonitor.bundle" "$CONTENTS_DIR/Resources/"

codesign --force --deep --sign - "$APP_DIR"

echo "Built: $APP_DIR"
