#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# 用 Debug 副本 + 夹具数据，默认在屏外缓存窗口内容的浅色与深色位图。
# 与 ax_dump_pages.sh 同一套启动方式（MEANTIME_TEST_HOST=1 + 夹具），外观由 Debug 钩子 MEANTIME_UI_TEST_APPEARANCE 切。
# 用法: Tools/shoot_app_pages.sh [输出目录]；MEANTIME_SHOOT_PAGES="planner agenda" 选页；MEANTIME_SHOOT_APPEARANCES="dark" 选外观；
#       MEANTIME_SKIP_BUILD=1 跳过构建；MEANTIME_SHOOT_LANG=en 换界面语言（默认跟随夹具/系统）；MEANTIME_SHOOT_EARTH_PROBE=28.61,77.21 让地球窗假装指针停在那里；
#       MEANTIME_SHOOT_PANEL_REMOVE_FIRST=1 让面板先删掉第一个地点（拍「已删除 X · 撤销」那一行）；
#       MEANTIME_SHOOT_WINDOW=1280x800 把工具窗放成商店截图尺寸（Retina 下 2560×1600；AppKit 会把整窗钳到屏幕可见区，
#       本机程序坞在时可见高只有 861 pt，1440x900 会被钳成 861，实际尺寸见 *.stdout 的「MEANTIME_UI_TEST_WINDOW applied」），
#       MEANTIME_SHOOT_FIXTURE=store 让排会页有结果（东京不参加）；MEANTIME_SHOOT_PRO_GATE=enforced 看门控启用时的付费墙；
#       MEANTIME_SHOOT_REGION=1 连同附着的 sheet / 确认框一起拍（这个进程的每个窗口各按 ID 截，再按位置拼合，别的 App 的对话框进不来）。
#       MEANTIME_SHOOT_NATIVE_CAPTURE=1 拍真实窗口；原生与 REGION 模式都须 MEANTIME_UI_TEST_FOREGROUND=1。
#       MEANTIME_DERIVED_DATA_PATH 指定构建缓存，MEANTIME_DEBUG_APP 指定已有 Debug 产物。
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
source "$root/Tools/test_screen_guard.sh"
dayside_require_launch_window "Page capture"
native_capture="${MEANTIME_SHOOT_NATIVE_CAPTURE:-0}"
if [[ "${MEANTIME_SHOOT_REGION:-0}" == 1 ]]; then native_capture=1; fi
if [[ "$native_capture" == 1 ]]; then dayside_require_foreground_window "Native page capture"; fi
out="${1:-$root/backup/app-shots-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$out"; out="$(cd "$out" && pwd)"
cd "$root"
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
cache = folder / "module-cache"
if cache.exists():
    shutil.rmtree(cache)
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
copy_dir="$(mktemp -d "$out/.shoot-app.XXXXXX")"
copy="$copy_dir/Dayside.app"
"$root/Tools/make_debug_copy.sh" "$copy_dir" > "$out/copy.stdout"
pages=(${MEANTIME_SHOOT_PAGES:-planner agenda people convert timers dstWatch astronomy markets travel sharing panel settings settingsAppearance settingsShortcuts settingsHelp earth})
appearances=(${MEANTIME_SHOOT_APPEARANCES:-light dark})
for page in "${pages[@]}"; do
  tab=""; panelSort="${MEANTIME_UI_TEST_PANEL_SORT:-}"; fixture="${MEANTIME_SHOOT_FIXTURE:-}"
  travel="${MEANTIME_SHOOT_TRAVEL:-}"; alarmText="${MEANTIME_SHOOT_ALARM_TEXT:-}"; alarmChoice="${MEANTIME_SHOOT_ALARM_CHOICE:-}"; alarmSet="${MEANTIME_SHOOT_ALARM_SET:-}"; timerMode="${MEANTIME_SHOOT_TIMER_MODE:-}"
  case "$page" in
    panel|settings|welcome|earth) surface="$page"; feature="";;
    panelCallable) surface="panel"; feature=""; panelSort="callable";;
    panelEmpty) surface="panel"; feature=""; fixture="empty";;
    panelEmptyCallable) surface="panel"; feature=""; panelSort="callable"; fixture="empty";;
    settingsAppearance) surface="settings"; feature=""; tab="appearance";;
    settingsHelp) surface="settings"; feature=""; tab="help";;
    settingsShortcuts) surface="settings"; feature=""; tab="shortcuts";;
    travelEast) surface=""; feature="travel"; travel="east";;
    timersPomodoro) surface=""; feature="timers"; timerMode="pomodoro";;
    timersAlarm|timersAlarmRunning) surface=""; feature="timers"; timerMode="alarm"; alarmText="${alarmText:-example}"; [[ "$page" != timersAlarmRunning ]] || alarmSet=1;;
    timersAlarmTwice) surface=""; feature="timers"; timerMode="alarm"; alarmText="${alarmText:-twice}";;
    *) surface=""; feature="$page";;
  esac
  for appearance in "${appearances[@]}"; do
    case "$appearance" in light|dark) ;; *) echo "Unknown capture appearance: $appearance" >&2; exit 1;; esac
    dayside_require_launch_window "Page launch for $page-$appearance"
    cached_dump=0
    if [[ "$native_capture" != 1 ]]; then cached_dump=1; fi
    earth_state="${MEANTIME_SHOOT_EARTH_STATE:-${MEANTIME_UI_TEST_EARTH_STATE:-}}"
    /bin/bash "$root/Tools/owner_away.sh" --wait || exit "$?"
    dayside_require_launch_window "Page launch for $page-$appearance" || exit "$?"
    env MEANTIME_TEST_HOST=1 MEANTIME_UI_TEST_CAPTURE="${MEANTIME_SHOOT_CAPTURE:-1}" MEANTIME_UI_TEST_FOREGROUND="${MEANTIME_UI_TEST_FOREGROUND:-0}" MEANTIME_AX_DUMP="$cached_dump" MEANTIME_AX_NATIVE_CAPTURE=0 MEANTIME_AX_APPEARANCE_POLICY=forced-native MEANTIME_UI_TEST_FEATURE="$feature" MEANTIME_UI_TEST_SURFACE="$surface" MEANTIME_UI_TEST_SETTINGS_TAB="$tab" \
      MEANTIME_UI_TEST_APPEARANCE="$appearance" MEANTIME_UI_TEST_TEXT_SIZE="${MEANTIME_SHOOT_TEXT_SIZE:-}" MEANTIME_UI_TEST_FIXTURE="$fixture" MEANTIME_UI_TEST_PANEL_SORT="$panelSort" MEANTIME_UI_TEST_TZDATA="${MEANTIME_SHOOT_TZDATA:-}" MEANTIME_UI_TEST_PANEL_REMOVE_FIRST="${MEANTIME_SHOOT_PANEL_REMOVE_FIRST:-}" MEANTIME_UI_TEST_PANEL_EXPAND_AFTER="${MEANTIME_SHOOT_PANEL_EXPAND_AFTER:-}" MEANTIME_UI_TEST_PLANNER_FEEDBACK="${MEANTIME_SHOOT_PLANNER_FEEDBACK:-}" MEANTIME_UI_TEST_PEOPLE_REMOVE_FIRST="${MEANTIME_SHOOT_PEOPLE_REMOVE_FIRST:-}" MEANTIME_UI_TEST_PEOPLE_EDIT_FIRST="${MEANTIME_SHOOT_PEOPLE_EDIT_FIRST:-}" MEANTIME_UI_TEST_PURCHASE_STATE="${MEANTIME_SHOOT_PURCHASE_STATE:-}" \
      MEANTIME_UI_TEST_LANGUAGE="${MEANTIME_SHOOT_LANG:-}" MEANTIME_UI_TEST_WINDOW="${MEANTIME_SHOOT_WINDOW:-}" MEANTIME_UI_TEST_PRO_GATE="${MEANTIME_SHOOT_PRO_GATE:-}" MEANTIME_UI_TEST_CONVERT_TEXT="${MEANTIME_SHOOT_CONVERT_TEXT:-}" MEANTIME_UI_TEST_TIMER_MODE="$timerMode" \
      MEANTIME_UI_TEST_TRAVEL="$travel" MEANTIME_UI_TEST_ALARM_TEXT="$alarmText" MEANTIME_UI_TEST_ALARM_CHOICE="$alarmChoice" MEANTIME_UI_TEST_ALARM_SET="$alarmSet" \
      MEANTIME_UI_TEST_JUMP_HOURS="${MEANTIME_SHOOT_JUMP_HOURS:-}" MEANTIME_UI_TEST_CONTRAST="${MEANTIME_SHOOT_CONTRAST:-}" MEANTIME_UI_TEST_NO_COLOR="${MEANTIME_SHOOT_NO_COLOR:-}" MEANTIME_UI_TEST_WELCOME_ADDED="${MEANTIME_SHOOT_WELCOME_ADDED:-}" \
      MEANTIME_UI_TEST_WELCOME_NO_COORDINATE="${MEANTIME_SHOOT_WELCOME_NO_COORDINATE:-${MEANTIME_UI_TEST_WELCOME_NO_COORDINATE:-}}" MEANTIME_UI_TEST_WELCOME_DRAGGED="${MEANTIME_SHOOT_WELCOME_DRAGGED:-${MEANTIME_UI_TEST_WELCOME_DRAGGED:-}}" \
      MEANTIME_UI_TEST_PANEL_MAP_DRAGS="${MEANTIME_SHOOT_PANEL_MAP_DRAGS:-${MEANTIME_UI_TEST_PANEL_MAP_DRAGS:-}}" MEANTIME_UI_TEST_SETTINGS_SCROLL_FRACTION="${MEANTIME_SHOOT_SETTINGS_SCROLL_FRACTION:-${MEANTIME_UI_TEST_SETTINGS_SCROLL_FRACTION:-}}" \
      MEANTIME_UI_TEST_EARTH_STATE="$earth_state" MEANTIME_UI_TEST_LOGIN_ISSUE="${MEANTIME_SHOOT_LOGIN_ISSUE:-${MEANTIME_UI_TEST_LOGIN_ISSUE:-}}" \
      MEANTIME_UI_TEST_SHORTCUT_ERROR="${MEANTIME_SHOOT_SHORTCUT_ERROR:-${MEANTIME_UI_TEST_SHORTCUT_ERROR:-}}" MEANTIME_UI_TEST_HELP_EXPANDED="${MEANTIME_SHOOT_HELP_EXPANDED:-${MEANTIME_UI_TEST_HELP_EXPANDED:-}}" \
      MEANTIME_UI_TEST_SETTINGS_EXPANDED="${MEANTIME_SHOOT_SETTINGS_EXPANDED:-${MEANTIME_UI_TEST_SETTINGS_EXPANDED:-}}" \
      MEANTIME_UI_TEST_EARTH_PROBE="${MEANTIME_SHOOT_EARTH_PROBE:-}" "$copy/Contents/MacOS/Dayside" > "$out/$page-$appearance.stdout" 2> "$out/$page-$appearance.stderr" &
    pid=$!
    window_query_args=("pid:$pid")
    [[ "$earth_state" != "fullscreen" ]] || window_query_args+=(--all-spaces)
    if [[ "$native_capture" != 1 ]]; then
      for _ in $(seq 1 90); do
        kill -0 "$pid" 2>/dev/null || break
        dayside_require_launch_window "Page render for $page-$appearance"
        sleep 0.5
      done
      if kill -0 "$pid" 2>/dev/null; then
        echo "$page-$appearance: cached render did not finish within 45 seconds" >&2
        exit 1
      fi
      wait "$pid" 2>/dev/null || true
      pid=""
      path="$(sed -n 's/^MEANTIME_AX_DUMP_PATH=//p' "$out/$page-$appearance.stdout" | head -1)"
      if [[ -z "$path" || ! -s "${path%.json}-$appearance.png" ]]; then
        echo "$page-$appearance: missing cached bitmap; see $out/$page-$appearance.stderr" >&2
        exit 1
      fi
      cp "${path%.json}-$appearance.png" "$out/$page-$appearance.png"
      echo "$page-$appearance: cachedView → $out/$page-$appearance.png"
      continue
    fi
    wid=""
    for _ in $(seq 1 30); do
      dayside_require_foreground_window "Native page wait for $page-$appearance"
      sleep 0.5
      wid="$(swift -module-cache-path "$copy_dir/module-cache" "$root/Tools/feature_window_id.swift" "${window_query_args[@]}" 2>/dev/null | head -1 | awk '{print $1}')"
      [[ -n "$wid" ]] && break
    done
    if [[ -n "$wid" ]]; then
      if [[ "$earth_state" == "fullscreen" ]]; then
        for _ in $(seq 1 40); do
          [[ -n "$(sed -n '/CHROME_REVIEW_FULLSCREEN=/p' "$out/$page-$appearance.stdout")" ]] && break
          kill -0 "$pid" 2>/dev/null || break
          sleep 0.5
        done
        actual_window="$(sed -n 's/^CHROME_REVIEW_FULLSCREEN_WINDOW_ID=//p' "$out/$page-$appearance.stdout" | tail -1)"
        wid="$(swift -module-cache-path "$copy_dir/module-cache" "$root/Tools/feature_window_id.swift" "${window_query_args[@]}" 2>/dev/null | awk -v id="$actual_window" '$1 == id { print $1; exit }')"
      fi
      sleep 1.5
      dayside_require_foreground_window "Native page capture for $page-$appearance"
      if [[ "${MEANTIME_SHOOT_REGION:-0}" == 1 ]]; then
        # 连同附着在窗口上的 sheet / 确认框一起拍：这个进程的每个窗口各按 ID 截一张（只有自己的图层，别的 App 的
        # 对话框进不来——按屏幕区域截时装机版没人答的 TCC 对话框会压在中间），再按各自的屏幕位置拼成一张。
        "$root/Tools/trash.sh" "$out/.parts"; mkdir -p "$out/.parts"; manifest="$out/.parts/manifest.txt"; : > "$manifest"
        while read -r id w h _ x y; do
          [[ -n "$id" ]] || continue
          dayside_require_foreground_window "Native sheet capture for $page-$appearance"
          if ! screencapture -x -o -l "$id" "$out/.parts/$id.png" 2>/dev/null; then
            echo "$page-$appearance: native capture failed for window $id" >&2
            exit 1
          fi
          echo "$out/.parts/$id.png $x $y $w $h" >> "$manifest"
        done < <(swift -module-cache-path "$copy_dir/module-cache" "$root/Tools/feature_window_id.swift" "pid:$pid" 2>/dev/null)
        python3 "$root/Tools/compose_windows.py" "$manifest" "$out/$page-$appearance.png"
        echo "$page-$appearance: $(wc -l < "$manifest" | tr -d ' ') 个窗口拼合 → $out/$page-$appearance.png"
        [[ "${MEANTIME_SHOOT_KEEP_PARTS:-0}" == 1 ]] || "$root/Tools/trash.sh" "$out/.parts"
      else
        if ! screencapture -x -o -l "$wid" "$out/$page-$appearance.png"; then
          echo "$page-$appearance: native capture failed" >&2
          exit 1
        fi
        echo "$page-$appearance: window $wid → $out/$page-$appearance.png"
      fi
    else
      echo "$page-$appearance: 15 秒内没等到窗口" >&2
      exit 1
    fi
    kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
    pid=""
    sleep 0.5
  done
done
echo "截图目录：$out"
# 一次性偏好域由测试宿主清理；不扫描其它测试会话的文件。
