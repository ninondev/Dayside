#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# 整条脚本由调用方持有 CPU 锁；默认跑完整后台测试，前台测试另行显式选择。
# 用法：MEANTIME_DERIVED_DATA_PATH=<缓存目录> Tools/test_swift_suite.sh [--foreground] [--without-building] [xcodebuild 参数…]
# --without-building 复用已完成 build-for-testing 的产物，测试范围与屏幕守卫不变。
# 日志目录由 MEANTIME_SWIFT_TEST_LOGDIR 指定，默认放在缓存目录旁。
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
source "$root/Tools/test_screen_guard.sh"
test_pid=""
derived_data=""
stop_test() {
  [[ -n "$test_pid" ]] || return 0
  # 独立进程组只包含本轮构建及其子进程。
  kill -TERM -- "-$test_pid" 2>/dev/null || true
  for _ in $(seq 1 50); do
    kill -0 "$test_pid" 2>/dev/null || break
    sleep 0.1
  done
  kill -KILL -- "-$test_pid" 2>/dev/null || true
  wait "$test_pid" 2>/dev/null || true
  test_pid=""
}
cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  stop_test
  if [[ -n "$derived_data" ]]; then
    if python3 "$root/Tools/stop_test_hosts.py" --derived-data "$derived_data"; then
      :
    else
      cleanup_status=$?
      printf 'Owned test host cleanup failed; original exit: %s; cleanup exit: %s\n' "$status" "$cleanup_status" >&2
      status=1
    fi
  fi
  "$root/Tools/ls_unregister_copies.sh" >/dev/null 2>&1 || true
  exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

foreground=0
action=test
while [[ $# -gt 0 ]]; do
  case "$1" in
    --foreground) foreground=1; shift;;
    --without-building) action=test-without-building; shift;;
    *) break;;
  esac
done
if [[ "$foreground" == 0 && ( -n "${MEANTIME_UI_TEST_ROW_MENU:-}" || -n "${TEST_RUNNER_MEANTIME_UI_TEST_ROW_MENU:-}" ) ]]; then
  printf 'DEFERRED: row menu fixtures require explicit --foreground and MEANTIME_UI_TEST_FOREGROUND=1.\n' >&2
  exit 75
fi
if [[ "$foreground" == 1 ]]; then
  dayside_require_foreground_window "Foreground Swift tests"
else
  dayside_require_measurement_window "Swift suite"
fi
derived_data="${MEANTIME_DERIVED_DATA_PATH:?Set MEANTIME_DERIVED_DATA_PATH to the scratch DerivedData directory}"
logdir="${MEANTIME_SWIFT_TEST_LOGDIR:-$(dirname "$derived_data")/swift-suite-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$logdir"
logdir="$(cd "$logdir" && pwd)"
log="$logdir/xcodebuild.log"
cd "$root"

# 完整运行的范围固定，调用方可补结果包、构建并发等参数。
for argument in "$@"; do
  case "$argument" in
    -only-testing*|-skip-testing*|test|test-without-building|build|build-for-testing|-xctestrun)
      printf 'Unsupported suite override: %s\n' "$argument" >&2
      exit 2
      ;;
  esac
done
selection=()
test_feature=""
if [[ "$foreground" == 1 ]]; then
  selection+=(-only-testing:TahoeTimeTests/PageShortcutTests
              -only-testing:TahoeTimeTests/EarthFullscreenTests
              -only-testing:TahoeTimeTests/QuietTestHostTests
              '-only-testing:TahoeTimeTests/MapScrubTests/earthCopyCommandWorksInNativeFullscreen()'
              '-only-testing:TahoeTimeTests/SettingsLayoutTests/russianLargestTextPageScrollsInAShortWindow()'
              '-only-testing:TahoeTimeTests/SettingsScrollReviewTests/largestTextScrollsToTheBottomInAShortWindow(page:language:)')
  test_feature=agenda
else
  selection+=(-skip-testing:TahoeTimeTests/PageShortcutTests)
fi
printf 'Swift test mode: %s; log: %s\n' "$([[ "$foreground" == 1 ]] && echo foreground || echo quiet)" "$log"
if [[ "$foreground" == 1 ]]; then
  dayside_require_foreground_window "Foreground Swift launch"
else
  dayside_require_measurement_window "Swift suite launch"
fi
# 后台命令单独成组，屏幕转忙时可以结束本轮而不碰其它工作。
set -m
run_xcodebuild() {
  local requested_action="$1"; shift
  env MEANTIME_TEST_HOST=1 MEANTIME_UI_TEST_FOREGROUND="$foreground" MEANTIME_UI_TEST_FEATURE="$test_feature" \
    TEST_RUNNER_MEANTIME_TEST_HOST=1 TEST_RUNNER_MEANTIME_UI_TEST_FOREGROUND="$foreground" TEST_RUNNER_MEANTIME_UI_TEST_FEATURE="$test_feature" \
    xcodebuild "$requested_action" "$@" -project TahoeTime.xcodeproj -scheme TahoeTime -configuration Debug \
      -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath "$derived_data" \
      -parallel-testing-enabled NO -jobs 3 CODE_SIGNING_ALLOWED=NO "${selection[@]}"
}
run_suite() {
  # 编译结束后才等主人离开，避免拿编译前的空闲状态启动宿主。
  if [[ "$action" == test ]]; then
    local build_arguments=() skip_bundle_path=0 argument
    for argument in "$@"; do
      if [[ "$skip_bundle_path" == 1 ]]; then skip_bundle_path=0; continue; fi
      case "$argument" in
        -resultBundlePath) skip_bundle_path=1 ;;
        -resultBundlePath=*) ;;
        *) build_arguments+=("$argument") ;;
      esac
    done
    # 结果包只给测试写；构建先占住同一路径会让测试拒绝启动。
    run_xcodebuild build-for-testing ${build_arguments[@]+"${build_arguments[@]}"} >> "$log" 2>&1 || return "$?"
  fi
  /bin/bash "$root/Tools/owner_away.sh" --wait || return "$?"
  if [[ "$foreground" == 1 ]]; then
    dayside_require_foreground_window "Foreground Swift launch" || return "$?"
  else
    dayside_require_measurement_window "Swift suite launch" || return "$?"
  fi
  run_xcodebuild test-without-building "$@" >> "$log" 2>&1
}
: > "$log"
# 本轮开始时刻：结束后把此后系统写下的测试宿主崩溃报告原样留进日志目录（成功的轮次也留，重跑通过不抹掉证据）。
suite_started="$(date +%s)"
run_suite "$@" &
test_pid=$!
while kill -0 "$test_pid" 2>/dev/null; do
  if [[ "$foreground" == 1 ]]; then
    dayside_require_foreground_window "Running foreground Swift tests" || exit "$?"
  else
    dayside_require_measurement_window "Running quiet Swift tests" || exit "$?"
  fi
  sleep 1
done
if wait "$test_pid"; then status=0; else status=$?; fi
test_pid=""
# 系统写崩溃报告有几秒延迟。
sleep 5
python3 "$root/Tools/collect_crash_reports.py" --since "$suite_started" --out "$logdir/crash-reports" \
  || printf 'Crash report collection failed; check ~/Library/Logs/DiagnosticReports manually\n' >&2
if [[ "$foreground" == 1 ]]; then dayside_require_foreground_window "Foreground Swift completion"; fi
if [[ "$status" != 0 ]]; then
  printf 'Swift tests failed (exit %s); log: %s\n' "$status" "$log" >&2
  exit "$status"
fi
if [[ "$foreground" == 1 ]]; then
  printf 'Foreground focus and page-shortcut tests completed; log: %s\n' "$log"
else
  printf 'Quiet Swift suite completed; log: %s\n' "$log"
  printf 'DEFERRED: foreground focus and page-shortcut tests require MEANTIME_UI_TEST_FOREGROUND=1 and --foreground while the screen is free.\n'
fi
