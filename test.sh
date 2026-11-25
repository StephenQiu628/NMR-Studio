#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
cache="${TMPDIR:-/tmp}/nmrstudio-modules-v1"
mkdir -p .build "$cache"
sources=()
for file in Sources/*.swift; do
    [[ "$file" == Sources/Studio.swift ]] || sources+=("$file")
done
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos13.0 -module-cache-path "$cache" "${sources[@]}" Tests/Check.swift -o .build/check
.build/check "$@"
