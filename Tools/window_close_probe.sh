#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# 自证「关掉工具窗不会退出 App」：复制 Debug 产物、去掉 App Group 权限重签（与 ax_dump_pages.sh 同法），
# 用 MEANTIME_UI_TEST_FEATURE=planner 打开工具窗，MEANTIME_UI_TEST_CLOSE_TOOLS_AFTER=4 让它 4 秒后对工具窗 performClose，
# 再过 2 秒还活着就打印 MEANTIME_TOOLS_CLOSED_STILL_RUNNING。没有这一行 = 关窗把 App 退出了。
# 用法: Tools/window_close_probe.sh [输出目录]；MEANTIME_PROBE_SKIP_BUILD=1 跳过构建。结束时注销并删除副本，免得 LaunchServices 记住它。
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
source "$root/Tools/test_screen_guard.sh"
out="${1:-$root/backup/window-close-probe-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$out"; out="$(cd "$out" && pwd)"
cd "$root"
if [[ "${MEANTIME_PROBE_SKIP_BUILD:-0}" != 1 ]]; then
  xcodebuild -project TahoeTime.xcodeproj -scheme TahoeTime -configuration Debug build > "$out/build.log" 2>&1 \
    || { grep -E ': error:|\*\* ' "$out/build.log" | sort -u | head >&2; echo "构建失败，见 $out/build.log" >&2; exit 1; }
fi
products="$(xcodebuild -project TahoeTime.xcodeproj -scheme TahoeTime -configuration Debug -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR = /{print $3; exit}')"
app="$products/Dayside.app"
[[ -d "$app" ]] || { echo "没有 Debug 产物：$app" >&2; exit 1; }
copy="$out/Dayside.app"; "$root/Tools/trash.sh" "$copy"; ditto "$app" "$copy"
"$root/Tools/trash.sh" "$copy/Contents/PlugIns/"*.xctest
ent="$out/debug-no-group.entitlements"; cp "$root/TahoeTime/TahoeTime-signing-Debug.entitlements" "$ent"
/usr/libexec/PlistBuddy -c 'Delete :com.apple.security.application-groups' "$ent"
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
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
cleanup() { "$lsregister" -u "$copy" >/dev/null 2>&1 || true; "$root/Tools/trash.sh" "$copy"; "$root/Tools/ls_unregister_copies.sh" >/dev/null 2>&1 || true; }
trap cleanup EXIT

/bin/bash "$root/Tools/owner_away.sh" --wait || exit "$?"
dayside_require_launch_window "Window close probe launch" || exit "$?"
MEANTIME_TEST_HOST=1 MEANTIME_UI_TEST_FEATURE=planner MEANTIME_UI_TEST_CLOSE_TOOLS_AFTER=4 \
  "$copy/Contents/MacOS/Dayside" > "$out/probe.stdout" 2> "$out/probe.stderr" &
pid=$!
for _ in $(seq 1 40); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null || true; echo "20 秒未退出，已结束" >&2; fi
wait "$pid" 2>/dev/null; status=$?
echo "退出码 $status；stdout："; cat "$out/probe.stdout"
if grep -q "MEANTIME_TOOLS_WINDOWS=0" "$out/probe.stdout"; then echo "无效：工具窗根本没开（钩子没生效）" >&2; exit 3; fi
if grep -q "MEANTIME_TOOLS_CLOSED_STILL_RUNNING" "$out/probe.stdout"; then
  echo "PASS：关掉工具窗后 App 仍在运行"
else
  echo "FAIL：关掉工具窗后 App 退出了（stdout 里没有 MEANTIME_TOOLS_CLOSED_STILL_RUNNING）" >&2; exit 2
fi
