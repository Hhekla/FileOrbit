#!/bin/bash
# Runs every repository XCTest test body using an explicit assertion adapter on Macs
# with Command Line Tools but no XCTest. No dependencies are installed and no files deleted.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
command -v python3 >/dev/null || { echo "Python 3 is required; this script does not install it." >&2; exit 1; }
command -v swift >/dev/null || { echo "Apple Swift / Command Line Tools are required." >&2; exit 1; }
mkdir -p "$ROOT/.build"
RUN_DIR="$(mktemp -d "$ROOT/.build/verification.XXXXXX")"
mkdir -p "$RUN_DIR/fixtures"
export TMPDIR="$RUN_DIR/fixtures/"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT/.build/verify-clang-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$ROOT/.build/verify-swift-cache}"
BUILD_ARGS=(--disable-sandbox --configuration debug --scratch-path "$ROOT/.build/verify-core-build"
    --cache-path "$ROOT/.build/verify-cache" --config-path "$ROOT/.build/verify-config"
    --security-path "$ROOT/.build/verify-security")
echo "Verification artifacts and generated fixtures: $RUN_DIR"
python3 "$ROOT/scripts/verify_core.py" --snapshot-core "$RUN_DIR/core-sources.json"
echo "Building KumquatCore (debug, testable); build log: $RUN_DIR/build.log"
if ! swift build "${BUILD_ARGS[@]}" --target KumquatCore > "$RUN_DIR/build.log" 2>&1; then
    cat "$RUN_DIR/build.log" >&2
    exit 1
fi
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
python3 "$ROOT/scripts/verify_core.py" --bin-dir "$BIN_DIR" --run-dir "$RUN_DIR" --core-manifest "$RUN_DIR/core-sources.json"
