#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
bundle="NMR Studio.app"
cache="${TMPDIR:-/tmp}/nmrstudio-modules-v1"
mkdir -p "$cache" .build "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos13.0 -module-cache-path "$cache" -parse-as-library Sources/*.swift -o .build/NMRStudio
install -m 755 .build/NMRStudio "$bundle/Contents/MacOS/NMRStudio"
install -m 644 Info.plist "$bundle/Contents/Info.plist"
install -m 644 OpenReadout-LICENSE-MIT.txt "$bundle/Contents/Resources/OpenReadout-LICENSE-MIT.txt"
install -m 644 Resources/NMRStudio.icns "$bundle/Contents/Resources/NMRStudio.icns"
codesign --force --sign - "$bundle"
