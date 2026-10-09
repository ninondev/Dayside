#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# 自证「诊断包」在沙盒里读得到上一次启动的日志：把 Debug 产物复制出来、重签
# （与 Tools/ax_dump_pages.sh 同一套），用 MEANTIME_UI_TEST_DIAGNOSTICS=1 连跑两次；每次启动都写一条带 pid 的
# 探针日志，两秒后把完整诊断包打到标准输出。第二次的诊断包里若有第一次的 pid，OSLogStore 跨启动可读就证实了。
# 用法: Tools/diagnostics_probe.sh [输出目录]   默认 backup/diagnostics-probe-<时间>；MEANTIME_PROBE_SKIP_BUILD=1 跳过构建。
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
source "$root/Tools/test_screen_guard.sh"
out="${1:-$root/backup/diagnostics-probe-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$out"; out="$(cd "$out" && pwd)"
cd "$root"
if [[ "${MEANTIME_PROBE_SKIP_BUILD:-0}" != 1 ]]; then
  xcodebuild -project Dayside.xcodeproj -scheme Dayside -configuration Debug build > "$out/build.log" 2>&1 \
    || { grep -E ': error:|\*\* ' "$out/build.log" | sort -u | head >&2; echo "构建失败，见 $out/build.log" >&2; exit 1; }
fi
products="$(xcodebuild -project Dayside.xcodeproj -scheme Dayside -configuration Debug -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR = /{print $3; exit}')"
app="$products/Dayside.app"
[[ -d "$app" ]] || { echo "没有 Debug 产物：$app" >&2; exit 1; }
copy="$out/Dayside.app"; "$root/Tools/trash.sh" "$copy"; ditto "$app" "$copy"
"$root/Tools/trash.sh" "$copy/Contents/PlugIns/"*.xctest
ent="$out/debug.entitlements"; cp "$root/Dayside/Dayside-signing-Debug.entitlements" "$ent"
sign() { /usr/bin/codesign --force --sign - --timestamp=none "$@" 2>/dev/null; }
for dylib in "$copy"/Contents/MacOS/*.dylib; do [[ -e "$dylib" ]] && sign "$dylib"; done
for framework in "$copy"/Contents/Frameworks/*.framework; do [[ -e "$framework" ]] && sign "$framework"; done
for appex in "$copy"/Contents/PlugIns/*.appex; do
  [[ -e "$appex" ]] || continue
  for dylib in "$appex"/Contents/MacOS/*.dylib; do [[ -e "$dylib" ]] && sign "$dylib"; done
  name="$(basename "$appex" .appex)"
  sign --entitlements "$root/$name/Extension.entitlements" "$appex"
done
sign --entitlements "$ent" "$copy"
/usr/bin/codesign --verify --deep --strict "$copy"

run() {
  local tag="$1"
  /bin/bash "$root/Tools/owner_away.sh" --wait || exit "$?"
  dayside_require_launch_window "Diagnostics probe launch" || exit "$?"
  MEANTIME_TEST_HOST=1 MEANTIME_UI_TEST_FEATURE=planner MEANTIME_UI_TEST_DIAGNOSTICS=1 \
    "$copy/Contents/MacOS/Dayside" > "$out/$tag.stdout" 2> "$out/$tag.stderr" &
  local pid=$!
  for _ in $(seq 1 60); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
  if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null || true; echo "$tag: 30 秒未退出，已结束" >&2; fi
  awk '/^MEANTIME_DIAGNOSTICS_BEGIN$/{f=1;next}/^MEANTIME_DIAGNOSTICS_END$/{f=0}f' "$out/$tag.stdout" > "$out/$tag.txt"
  echo "$pid"
}
"$root/Tools/ls_unregister_copies.sh" >/dev/null 2>&1 || true
pid1="$(run run1)"
sleep 1
pid2="$(run run2)"
echo "run1 pid=$pid1 → $out/run1.txt ($(wc -l < "$out/run1.txt") 行)"
echo "run2 pid=$pid2 → $out/run2.txt ($(wc -l < "$out/run2.txt") 行)"
"$root/Tools/ls_unregister_copies.sh" >/dev/null 2>&1 || true
if grep -q "diagnostics-probe pid=$pid1" "$out/run2.txt"; then
  echo "PASS：第二次启动的诊断包里有第一次的探针日志（pid=$pid1）——沙盒里跨启动读自己的日志可行"
  exit 0
else
  echo "FAIL：第二次启动的诊断包里没有第一次的探针（pid=$pid1）；看 $out/run2.txt 的 [log] 节与 log unavailable 行" >&2
  grep -n "log unavailable\|\[log" "$out/run2.txt" >&2 || true
  exit 2
fi
