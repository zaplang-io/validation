#!/bin/sh
# Run the offline validation test suite.
#
# Usage: tools/run-tests.sh
#
# Zap resolves intra-project module imports relative to the entry file's own
# directory (D-0081, zaplang-io/zap#283), so this assembles a single build root
# that holds the library modules (src/validation.zap + src/validation/) next to
# the test driver (tests/validation_test.zap), then runs the driver with
# `zap run` and diffs its stdout against tests/validation_test.expected. This is
# real multi-module compilation — no source concatenation. Exits non-zero on any
# mismatch.
#
# Printing + golden comparison (rather than in-process asserts) is how the Zap
# compiler's own suite and the sibling non-core packages exercise values; it
# keeps the check deterministic and toolchain-version independent.
#
# Set $ZAP to override the zap binary (default: `zap` on PATH, e.g. inside the
# ghcr.io/zaplang-io/zap image). See the README "Build & test" section.
set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
zap="${ZAP:-zap}"

build="$here/build/test"
rm -rf "$build"
mkdir -p "$build"

# Library modules (the package itself).
cp "$here/src/validation.zap" "$build/"
cp -r "$here/src/validation" "$build/"
# Test driver.
cp "$here/tests/validation_test.zap" "$build/"

got="$here/build/validation_test.out"
"$zap" run "$build/validation_test.zap" > "$got"

if diff -u "$here/tests/validation_test.expected" "$got"; then
    echo "validation offline test: PASS"
else
    echo "validation offline test: FAIL (actual output differs from tests/validation_test.expected)" >&2
    exit 1
fi
