#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# This preview never reads contacts/calendars or schedules system notifications.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
source "$root/Tools/test_screen_guard.sh"
if [[ -n "${MEANTIME_PRODUCTS:-}" ]]; then
  products="$MEANTIME_PRODUCTS"
else
  products="$(xcodebuild -project "$root/TahoeTime.xcodeproj" -scheme TahoeTime -configuration Debug -showBuildSettings -json 2>/dev/null | python3 -c 'import json,sys; print(next(x["buildSettings"]["BUILT_PRODUCTS_DIR"] for x in json.load(sys.stdin) if x["target"]=="TahoeTime"))')"
fi
preview="${MEANTIME_PREVIEW:-$root/build/DaysideFeaturePreview.app}"
[[ -f "$products/libdayside_core.a" ]] || { echo 'Build the Debug scheme first.' >&2; exit 1; }
preview_work="$(mktemp -d "${TMPDIR:-/tmp}/dayside-feature-build.XXXXXX")"
trap '"$root/Tools/trash.sh" "$preview_work"' EXIT
cp "$products/libdayside_core.a" "$preview_work/libdayside_core.a"
mkdir -p "$preview/Contents/MacOS" "$preview/Contents/Resources"
sources=()
while IFS= read -r -d '' source; do sources+=("$source"); done < <(find "$root/TahoeTime/Models" "$root/TahoeTime/Views" "$root/Shared" -name '*.swift' -print0)
xcrun swiftc -swift-version 6 -strict-concurrency=complete -target arm64-apple-macos26.0 \
  -parse-as-library -import-objc-header "$root/RustCore/include/dayside_core.h" \
  "${sources[@]}" "$root/Tools/FeaturePreview.swift" "$preview_work/libdayside_core.a" \
  -o "$preview/Contents/MacOS/DaysideFeaturePreview"
ditto "$products/Dayside.app/Contents/Resources" "$preview/Contents/Resources"
cat > "$preview/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.dayside.FeaturePreview</string><key>CFBundleName</key><string>DaysideFeaturePreview</string><key>CFBundleExecutable</key><string>DaysideFeaturePreview</string><key>CFBundlePackageType</key><string>APPL</string><key>LSMinimumSystemVersion</key><string>26.0</string><key>NSHighResolutionCapable</key><true/></dict></plist>
PLIST
/usr/bin/codesign --force --sign - --timestamp=none "$preview"
/bin/bash "$root/Tools/owner_away.sh" --wait || exit "$?"
dayside_require_launch_window "Feature preview launch" || exit "$?"
open "$preview"
