#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build/ui-checks
nmr_module_cache="${TMPDIR:-/tmp}/nmrstudio-modules-v1"
nmr_sources=()
for nmr_source_file in Sources/*.swift; do
  if [[ "$nmr_source_file" != Sources/Studio.swift ]]; then nmr_sources+=("$nmr_source_file"); fi
done
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos13.0 -module-cache-path "$nmr_module_cache" "${nmr_sources[@]}" Tools/CheckUI.swift -o .build/ui-checks/check
for nmr_theme in dark light; do
  for nmr_mode in integral solventReference zoom markPeaks; do
    .build/ui-checks/check --theme "$nmr_theme" --mode "$nmr_mode" --width 1280 --height 820 --output "$PWD/.build/ui-checks/$nmr_theme-$nmr_mode.png"
  done
  .build/ui-checks/check --theme "$nmr_theme" --mode integral --width 1040 --height 700 --output "$PWD/.build/ui-checks/$nmr_theme-integral-compact.png"
done
