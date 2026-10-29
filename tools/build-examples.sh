#!/bin/sh
# Compile-smoke the examples: assemble a build root with the library modules
# next to each example and `zap build` it (compile + link). Catches API/type
# drift in the examples.
#
# Usage: tools/build-examples.sh
# Set $ZAP to override the zap binary (default: `zap` on PATH).
set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
zap="${ZAP:-zap}"

for ex in "$here"/examples/*.zap; do
    name=$(basename "$ex" .zap)
    build="$here/build/example-$name"
    rm -rf "$build"
    mkdir -p "$build"
    cp "$here/src/validation.zap" "$build/"
    cp -r "$here/src/validation" "$build/"
    cp "$ex" "$build/"
    echo "building example: $name"
    "$zap" build "$build/$(basename "$ex")" -o "$build/$name"
    test -x "$build/$name"
    echo "  ok"
done
echo "examples: BUILD OK"
