#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Run only after Xcode has emitted App Intents metadata and copied all extensions.
set -euo pipefail
root="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
app="${1:?Pass the complete Dayside.app path}"
configuration="${CONFIGURATION:-Release}"
app_policy="$root/TahoeTime/TahoeTime-signing-$configuration.entitlements"
[[ -f "$app_policy" ]] || { echo "Missing signing policy: $app_policy" >&2; exit 1; }
# Notarization requires the hardened runtime; Xcode would add it from ENABLE_HARDENED_RUNTIME, but this script signs instead.
runtime=()
[[ "$configuration" == Release ]] && runtime=(--options runtime)
[[ -d "$app/Contents" ]] || { echo "Missing application bundle: $app" >&2; exit 1; }

# Debug builds put __preview.dylib next to the executable. The arm64 linker ad-hoc signs it, the
# x86_64 linker does not, and codesign refuses a bundle with an unsigned nested code object.
sign_nested_dylibs() {
  local dylib
  for dylib in "$1"/Contents/MacOS/*.dylib; do
    [[ -e "$dylib" ]] && /usr/bin/codesign --force --sign - --timestamp=none "$dylib"
  done
  return 0
}

while IFS= read -r -d '' extension; do
  name="$(basename "$extension" .appex)"
  entitlements="$root/$name/Extension.entitlements"
  [[ -f "$entitlements" ]] || { echo "Missing extension signing policy: $name" >&2; exit 1; }
  if [[ "$configuration" == Release ]]; then
    executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$extension/Contents/Info.plist")"
    /usr/bin/strip -x -no_code_signature_warning "$extension/Contents/MacOS/$executable"
  fi
  sign_nested_dylibs "$extension"
  /usr/bin/codesign --force --sign - ${runtime[@]+"${runtime[@]}"} --timestamp=none --entitlements "$entitlements" "$extension"
done < <(find "$app/Contents" -name '*.appex' -type d -prune -print0)

if [[ "$configuration" == Debug && -d "$app/Contents/Frameworks" ]]; then
  # Xcode embeds test frameworks without their development headers, invalidating the SDK seal.
  # Only re-sign these build-product copies; the installed SDK remains untouched.
  while IFS= read -r -d '' framework; do
    /usr/bin/codesign --force --sign - --timestamp=none "$framework"
  done < <(find "$app/Contents/Frameworks" -mindepth 1 -maxdepth 1 -name '*.framework' -type d -print0)
fi

if [[ "$configuration" == Debug && -d "$app/Contents/PlugIns" ]]; then
  while IFS= read -r -d '' tests; do
    /usr/bin/codesign --force --sign - --timestamp=none "$tests"
  done < <(find "$app/Contents/PlugIns" -name '*.xctest' -type d -prune -print0)
fi

if [[ "$configuration" == Release ]]; then
  /usr/bin/strip -x -no_code_signature_warning "$app/Contents/MacOS/Dayside"
fi
sign_nested_dylibs "$app"
/usr/bin/codesign --force --sign - ${runtime[@]+"${runtime[@]}"} --timestamp=none \
  --entitlements "$app_policy" "$app"
/usr/bin/codesign --verify --deep --strict "$app"
