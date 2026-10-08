#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# 九个工具页的进程内无障碍树转储与检查。真实 Debug 构建自己走一遍 NSAccessibility 树（VoiceOver 读的就是这棵树），
# 每页写一个 JSON，再由 Tools/ax_check.py 按规则检查。不需要 UI 自动化模式，无人值守可跑。
# 用法: Tools/ax_dump_pages.sh [输出目录]   默认 backup/ax-dump-<时间>；MEANTIME_AX_PAGES="earth panel" 选面，MEANTIME_AX_LANG=ru 换界面语言
# MEANTIME_AX_APPEARANCE_POLICY=forced-native 要求两遍原生外观真实切换。
# 默认 production 保留天色外观策略，分别记录请求与实测外观。
# 被测 app 是 DerivedData 里 Debug 构建的副本，
# 走 MEANTIME_TEST_HOST=1 的一次性偏好域与 UITestFixture 假数据，不碰安装版数据。转储写在 app 容器的 tmp 里。
# MEANTIME_AX_NATIVE_CAPTURE=1 或输出目录的 .native-capture 文件启用真实窗口采样。
# 它沿用截图工具已有的屏幕录制权限；默认仍用进程内位图，不改变权限。
# 原生截图须另设 MEANTIME_UI_TEST_FOREGROUND=1；屏幕忙时以 DEFERRED 退出。
# MEANTIME_DERIVED_DATA_PATH 指定构建缓存，MEANTIME_DEBUG_APP 可指定已有 Debug 产物。
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
source "$root/Tools/test_screen_guard.sh"
dayside_require_launch_window "AX dump"
out="${1:-$root/backup/ax-dump-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$out"; out="$(cd "$out" && pwd)"
native_capture=0
if [[ "${MEANTIME_AX_NATIVE_CAPTURE:-0}" == 1 || -f "$out/.native-capture" ]]; then native_capture=1; fi
if [[ "$native_capture" == 1 ]]; then dayside_require_foreground_window "Native AX capture"; fi
cd "$root"
build_args=()
if [[ -n "${MEANTIME_DERIVED_DATA_PATH:-}" ]]; then build_args=(-derivedDataPath "$MEANTIME_DERIVED_DATA_PATH"); fi
# 只清理本轮创建的副本，保留转储、截图和构建日志。
copy=""; copy_dir=""; pid=""
cleanup() {
  status=$?
  trap - EXIT HUP INT TERM
  if [[ -n "$pid" ]]; then
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
  if [[ -n "$copy" ]]; then
    lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
    "$lsregister" -u "$copy" >/dev/null 2>&1 || true
    if python3 - "$copy_dir" <<'CLEANUP'
import pathlib
import shutil
import sys

folder = pathlib.Path(sys.argv[1])
app = folder / "Dayside.app"
if app.is_symlink():
    app.unlink()
elif app.exists():
    shutil.rmtree(app)
try:
    folder.rmdir()
except OSError:
    pass
CLEANUP
    then cleanup_status=0; else cleanup_status=$?; fi
    if [[ "$cleanup_status" != 0 && "$status" == 0 ]]; then status=$cleanup_status; fi
  fi
  "$root/Tools/ls_unregister_copies.sh" >/dev/null 2>&1 || true
  exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
if [[ "${MEANTIME_AX_SKIP_BUILD:-0}" != 1 && -z "${DAYSIDE_DEBUG_APP:-${MEANTIME_DEBUG_APP:-}}" ]]; then
  dayside_require_measurement_window "AX build"
  xcodebuild -project TahoeTime.xcodeproj -scheme TahoeTime -configuration Debug ${build_args[@]+"${build_args[@]}"} -jobs 3 CODE_SIGNING_ALLOWED=NO build > "$out/build.log" 2>&1 \
    || { grep -E ': error:|\*\* ' "$out/build.log" | sort -u | head >&2; echo "构建失败，见 $out/build.log" >&2; exit 1; }
fi
app="${DAYSIDE_DEBUG_APP:-${MEANTIME_DEBUG_APP:-}}"
if [[ -z "$app" ]]; then
  products="$(xcodebuild -project TahoeTime.xcodeproj -scheme TahoeTime -configuration Debug ${build_args[@]+"${build_args[@]}"} -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR = /{print $3; exit}')"
  app="$products/Dayside.app"
fi
[[ -d "$app" ]] || { echo "没有 Debug 产物：$app" >&2; exit 1; }
copy_dir="$(mktemp -d "$out/.ax-app.XXXXXX")"
copy="$copy_dir/Dayside.app"
ditto "$app" "$copy"
# 测试包也是副本产物，直接删除，不挪进废纸篓。
python3 - "$copy" <<'TEST_BUNDLES'
import pathlib
import shutil
import sys

for bundle in (pathlib.Path(sys.argv[1]) / "Contents" / "PlugIns").glob("*.xctest"):
    if bundle.is_symlink() or bundle.is_file():
        bundle.unlink()
    else:
        shutil.rmtree(bundle)
TEST_BUNDLES
# 原生窗口自动保存写标准域，副本使用独立标识以隔离安装版。
audit_id="com.dayside.Dayside.audit.$(/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]')"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $audit_id" "$copy/Contents/Info.plist"
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
/usr/bin/codesign --verify --deep --strict "$copy"
appearance_policy="${MEANTIME_AX_APPEARANCE_POLICY:-production}"
case "$appearance_policy" in production|forced-native) ;; *) echo "Unknown AX appearance policy: $appearance_policy" >&2; exit 1;; esac
# 禁截图任务设 0：报告与对比度照常产出，只是不保存/拷贝 PNG；默认 1 保持原行为。
save_images="${MEANTIME_AX_SAVE_IMAGES:-1}"
case "$save_images" in 0|1) ;; *) echo "Unknown AX image saving option: $save_images" >&2; exit 1;; esac
pages=(${MEANTIME_AX_PAGES:-planner plannerResults agenda people convert convertResult convertCandidates timers timersPomodoro timersAlarm timersAlarmTwice timersAlarmRunning dstWatch astronomy markets travel travelEast sharing panel panelCallable panelEmpty settings settingsAppearance settingsShortcuts settingsHelp welcome earth})
capture_requests() {
  local request window_id capture_path staged_path
  while IFS= read -r request; do
    dayside_require_foreground_window "Native AX capture for $page" || return "$?"
    window_id="${request%%|*}"; capture_path="${request#*|}"
    if [[ "$request" != *'|'* || -z "$window_id" || "$window_id" == *[!0-9]* || "$window_id" == 0 || "$capture_path" != /* || "$capture_path" != *.png || "$capture_path" == *'|'* ]]; then
      echo "$page: 原生截图请求无效：$request" >&2; return 1
    fi
    [[ -e "$capture_path" ]] && continue
    # 完整截图成功后才交给 app，避免把半张图片当成完成信号。
    staged_path="${capture_path}.capture-${pid}.png"
    if /usr/sbin/screencapture -x -o -l "$window_id" "$staged_path" && [[ -s "$staged_path" ]]; then
      if ! mv "$staged_path" "$capture_path"; then
        echo "$page: 原生截图写入失败：$capture_path" >&2; return 1
      fi
    else
      echo "$page: 原生截图失败：窗口 $window_id，目标 $capture_path" >&2; return 1
    fi
  done < <(sed -n 's/^MEANTIME_AX_CAPTURE_REQUEST=//p' "$out/$page.stdout")
}
for page in "${pages[@]}"; do
  # 九个工具页走 MEANTIME_UI_TEST_FEATURE；菜单栏面板与设置窗走 MEANTIME_UI_TEST_SURFACE，设置的帮助页再加 MEANTIME_UI_TEST_SETTINGS_TAB=help。
  tab=""; panelSort=""; textSize="${MEANTIME_AX_TEXT_SIZE:-}"; convertText="${MEANTIME_AX_CONVERT_TEXT:-}"; fixture="${MEANTIME_AX_FIXTURE:-}"; timerMode="${MEANTIME_AX_TIMER_MODE:-}"
  travel="${MEANTIME_AX_TRAVEL:-}"; alarmText="${MEANTIME_AX_ALARM_TEXT:-}"; alarmChoice="${MEANTIME_AX_ALARM_CHOICE:-}"; alarmSet="${MEANTIME_AX_ALARM_SET:-}"
  case "$page" in
    panel|settings|welcome|earth) surface="$page"; feature="";;
    # 面板按「现在能打给谁」排序：多一行提示与排序菜单的选中态。
    panelCallable) surface="panel"; feature=""; panelSort="callable";;
    # 面板一个地点都没有（首启）：满幅地图、一句话与建议按钮（2026-10-02 起空态也画地图）。
    panelEmpty) surface="panel"; feature=""; fixture="empty";;
    panelEmptyCallable) surface="panel"; feature=""; panelSort="callable"; fixture="empty";;
    settingsAppearance) surface="settings"; feature=""; tab="appearance";;
    settingsHelp) surface="settings"; feature=""; tab="help";;
    settingsShortcuts) surface="settings"; feature=""; tab="shortcuts";;
    # 换算页带一条结果（来源 / 本机 / 各地点三行与复制按钮）：只转储空闲态时结果行的按钮从没进过树（才查出对比度与命中区两条）。
    # 换算页一段可能含几处时间说法；「读懂了」栏与结果行都应进无障碍树。
    convertResult) surface=""; feature="convert"; convertText="${convertText:-Kickoff tomorrow 9am PST, sync 18:00 Berlin, report due Oct 3.}";;
    # 有歧义的缩写：候选菜单进树。
    convertCandidates) surface=""; feature="convert"; convertText="${convertText:-10:00 IST}";;
    # 排会页带结果行（store 夹具：东京不参加排会才有时段；查出默认夹具从没让结果行的按钮进过树）与番茄钟表单（账本行）。
    plannerResults) surface=""; feature="planner"; fixture="${fixture:-store}";;
    timersPomodoro) surface=""; feature="timers"; timerMode="${timerMode:-pomodoro}";;
    travelEast) surface=""; feature="travel"; travel="east";;
    timersAlarm|timersAlarmRunning) surface=""; feature="timers"; timerMode="alarm"; alarmText="${alarmText:-example}"; [[ "$page" != timersAlarmRunning ]] || alarmSet=1;;
    timersAlarmTwice) surface=""; feature="timers"; timerMode="alarm"; alarmText="${alarmText:-twice}";;
    *) surface=""; feature="$page";;
  esac
  dayside_require_launch_window "AX launch for $page"
  /bin/bash "$root/Tools/owner_away.sh" --wait || exit "$?"
  dayside_require_launch_window "AX launch for $page" || exit "$?"
  MEANTIME_TEST_HOST=1 MEANTIME_UI_TEST_CAPTURE="${MEANTIME_AX_CAPTURE:-0}" MEANTIME_UI_TEST_FOREGROUND="${MEANTIME_UI_TEST_FOREGROUND:-0}" MEANTIME_UI_TEST_FEATURE="$feature" MEANTIME_UI_TEST_SURFACE="$surface" MEANTIME_UI_TEST_SETTINGS_TAB="$tab" MEANTIME_AX_DUMP=1 MEANTIME_AX_NATIVE_CAPTURE="$native_capture" MEANTIME_AX_APPEARANCE_POLICY="$appearance_policy" MEANTIME_AX_SAVE_IMAGES="$save_images" \
    MEANTIME_UI_TEST_TEXT_SIZE="$textSize" MEANTIME_UI_TEST_PANEL_SORT="$panelSort" MEANTIME_UI_TEST_FIXTURE="$fixture" MEANTIME_UI_TEST_TZDATA="${MEANTIME_AX_TZDATA:-}" MEANTIME_UI_TEST_PANEL_REMOVE_FIRST="${MEANTIME_AX_PANEL_REMOVE_FIRST:-}" MEANTIME_UI_TEST_CONVERT_TEXT="$convertText" MEANTIME_UI_TEST_PRO_GATE="${MEANTIME_AX_PRO_GATE:-}" MEANTIME_UI_TEST_TIMER_MODE="$timerMode" \
    MEANTIME_UI_TEST_TRAVEL="$travel" MEANTIME_UI_TEST_ALARM_TEXT="$alarmText" MEANTIME_UI_TEST_ALARM_CHOICE="$alarmChoice" MEANTIME_UI_TEST_ALARM_SET="$alarmSet" \
    MEANTIME_UI_TEST_JUMP_HOURS="${MEANTIME_AX_JUMP_HOURS:-}" MEANTIME_UI_TEST_CONTRAST="${MEANTIME_AX_CONTRAST:-}" MEANTIME_UI_TEST_NO_COLOR="${MEANTIME_AX_NO_COLOR:-}" MEANTIME_UI_TEST_WINDOW="${MEANTIME_AX_WINDOW:-}" \
    MEANTIME_UI_TEST_WELCOME_ADDED="${MEANTIME_AX_WELCOME_ADDED:-}" MEANTIME_UI_TEST_SETTINGS_EXPANDED="${MEANTIME_AX_SETTINGS_EXPANDED:-}" \
    MEANTIME_UI_TEST_WELCOME_NO_COORDINATE="${MEANTIME_AX_WELCOME_NO_COORDINATE:-${MEANTIME_UI_TEST_WELCOME_NO_COORDINATE:-}}" MEANTIME_UI_TEST_WELCOME_DRAGGED="${MEANTIME_AX_WELCOME_DRAGGED:-${MEANTIME_UI_TEST_WELCOME_DRAGGED:-}}" \
    MEANTIME_UI_TEST_PANEL_MAP_DRAGS="${MEANTIME_AX_PANEL_MAP_DRAGS:-${MEANTIME_UI_TEST_PANEL_MAP_DRAGS:-}}" MEANTIME_UI_TEST_SETTINGS_SCROLL_FRACTION="${MEANTIME_AX_SETTINGS_SCROLL_FRACTION:-${MEANTIME_UI_TEST_SETTINGS_SCROLL_FRACTION:-}}" \
    MEANTIME_UI_TEST_EARTH_STATE="${MEANTIME_AX_EARTH_STATE:-${MEANTIME_UI_TEST_EARTH_STATE:-}}" MEANTIME_UI_TEST_LOGIN_ISSUE="${MEANTIME_AX_LOGIN_ISSUE:-${MEANTIME_UI_TEST_LOGIN_ISSUE:-}}" \
    MEANTIME_UI_TEST_SHORTCUT_ERROR="${MEANTIME_AX_SHORTCUT_ERROR:-${MEANTIME_UI_TEST_SHORTCUT_ERROR:-}}" MEANTIME_UI_TEST_HELP_EXPANDED="${MEANTIME_AX_HELP_EXPANDED:-${MEANTIME_UI_TEST_HELP_EXPANDED:-}}" \
    MEANTIME_UI_TEST_LANGUAGE="${MEANTIME_AX_LANG:-}" "$copy/Contents/MacOS/Dayside" > "$out/$page.stdout" 2> "$out/$page.stderr" &
  pid=$!
  printf 'MEANTIME_AX_HOST page=%s pid=%s app=%s\n' "$page" "$pid" "$copy"
  for _ in $(seq 1 240); do
    kill -0 "$pid" 2>/dev/null || break
    dayside_require_launch_window "AX step for $page"
    if [[ "$native_capture" == 1 ]]; then capture_requests || exit "$?"; fi
    sleep 0.5
  done
  if kill -0 "$pid" 2>/dev/null; then
    echo "$page: 120 秒未退出，已结束" >&2
    exit 1
  fi
  if wait "$pid"; then :; else
    launch_status=$?
    pid=""
    echo "$page: 进程失败（见 $out/$page.stderr）" >&2
    exit "$launch_status"
  fi
  pid=""
  path="$(grep -o 'MEANTIME_AX_DUMP_PATH=.*' "$out/$page.stdout" | head -1 | cut -d= -f2- || true)"
  if [[ -n "$path" && -f "$path" ]]; then
    cp "$path" "$out/$page.json"
    if [[ "$save_images" == 1 ]]; then
      for shade in light dark; do [[ -f "${path%.json}-$shade.png" ]] && cp "${path%.json}-$shade.png" "$out/$page-$shade.png"; done
    fi
  else echo "$page: 没有转储（见 $out/$page.stderr）" >&2; exit 1; fi
done
echo "转储目录：$out"
# 一次性偏好域由测试宿主清理；不扫描其它测试会话的文件。
# 报告校验的可调用实现在 Tools/test_copy2_ax_output.py（--validate）：无图模式仍校验捕获状态、请求/实测外观与对比度，只免 images 路径与 PNG 文件。
python3 "$root/Tools/test_copy2_ax_output.py" --validate "$out" "$appearance_policy" "$save_images" "${pages[@]}"
check_args=()
[[ "$save_images" != 0 ]] || check_args=(--no-images)
python3 "$root/Tools/ax_check.py" "$out" ${check_args[@]+"${check_args[@]}"}
