#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# 全局快捷键自证探针：Debug 副本在测试宿主下启动，
# 2 秒后自己点一下菜单栏项，把窗口清单与结果写到标准输出。用法: Tools/hotkey_probe.sh [输出目录]
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
source "$root/Tools/test_screen_guard.sh"
out="${1:-$root/backup/hotkey-probe-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$out"; out="$(cd "$out" && pwd)"
cd "$root"
if [[ "${MEANTIME_HOTKEY_SKIP_BUILD:-0}" != 1 ]]; then
  xcodebuild -project TahoeTime.xcodeproj -scheme TahoeTime -configuration Debug build > "$out/build.log" 2>&1 \
    || { grep -E ': error:|\*\* ' "$out/build.log" | sort -u | head >&2; echo "构建失败，见 $out/build.log" >&2; exit 1; }
fi
products="$(xcodebuild -project TahoeTime.xcodeproj -scheme TahoeTime -configuration Debug -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR = /{print $3; exit}')"
app="$products/Dayside.app"
copy="$out/Dayside.app"; "$root/Tools/trash.sh" "$copy"; ditto "$app" "$copy"
"$root/Tools/trash.sh" "$copy/Contents/PlugIns/"*.xctest
ent="$out/debug-no-group.entitlements"; cp "$root/TahoeTime/TahoeTime-signing-Debug.entitlements" "$ent"
sign() { /usr/bin/codesign --force --sign - --timestamp=none "$@"; }
for dylib in "$copy"/Contents/MacOS/*.dylib; do [[ -e "$dylib" ]] && sign "$dylib"; done
for framework in "$copy"/Contents/Frameworks/*.framework; do [[ -e "$framework" ]] && sign "$framework"; done
for appex in "$copy"/Contents/PlugIns/*.appex; do
  [[ -e "$appex" ]] || continue
  for dylib in "$appex"/Contents/MacOS/*.dylib; do [[ -e "$dylib" ]] && sign "$dylib"; done
  name="$(basename "$appex" .appex)"
  sign --entitlements "$root/$name/Extension.entitlements" "$appex"
done
sign --entitlements "$ent" "$copy"
/bin/bash "$root/Tools/owner_away.sh" --wait || exit "$?"
dayside_require_launch_window "Hotkey probe launch" || exit "$?"
MEANTIME_TEST_HOST=1 MEANTIME_UI_TEST_HOTKEY_PROBE=1 MEANTIME_UI_TEST_FIXTURE=store \
  "$copy/Contents/MacOS/Dayside" > "$out/probe.stdout" 2> "$out/probe.stderr" &
pid=$!
for _ in $(seq 1 40); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
"$root/Tools/trash.sh" "$copy"
( "$root/Tools/clean_test_prefs.sh" --wait 30 >/dev/null 2>&1 & )
"$root/Tools/ls_unregister_copies.sh" >/dev/null 2>&1 || true
grep -o 'MEANTIME_HOTKEY[^ ]*.*' "$out/probe.stdout" || { echo "探针没有输出，见 $out/probe.stdout 与 probe.stderr" >&2; exit 1; }
