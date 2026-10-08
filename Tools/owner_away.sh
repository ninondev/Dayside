#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# 启动前等键鼠空闲五分钟；测试输入只在显式单元测试模式下读取。
set -euo pipefail
export LC_ALL=C
mode=${1:---wait}
[[ $# -le 1 ]] || exit 2
strict=0
case "$mode" in
  --wait|--check) testing=0; unset DAYSIDE_OWNER_AWAY_TEST_HID_IDLE_NS DAYSIDE_OWNER_AWAY_TEST_POLL_SECONDS DAYSIDE_OWNER_AWAY_TEST_FLAG ;;
  --strict-check) testing=0; strict=1; unset DAYSIDE_OWNER_AWAY_TEST_HID_IDLE_NS DAYSIDE_OWNER_AWAY_TEST_POLL_SECONDS DAYSIDE_OWNER_AWAY_TEST_FLAG ;;
  --unit-test-check|--unit-test-wait) testing=1 ;;
  --unit-test-strict-check) testing=1; strict=1 ;;
  *) exit 2 ;;
esac
flag="$HOME/.dayside-launch-while-present"
if [[ "$testing" == 1 ]]; then
  flag=${DAYSIDE_OWNER_AWAY_TEST_FLAG-$flag}
fi

parse_idle() {
  /usr/bin/awk '
    /"HIDIdleTime"/ {
      count++
      value=$0
      sub(/^.*"HIDIdleTime"[[:space:]]*=[[:space:]]*/, "", value)
      sub(/[[:space:]]*$/, "", value)
      if (value !~ /^[0-9]+$/) invalid=1
    }
    END { if (count != 1 || invalid) exit 1; print value }
  '
}
read_idle() {
  local raw
  if [[ "$testing" == 1 ]]; then
    [[ "${DAYSIDE_OWNER_AWAY_TEST_HID_IDLE_NS-READ_ERROR}" != READ_ERROR ]] || return 1
    [[ "$DAYSIDE_OWNER_AWAY_TEST_HID_IDLE_NS" =~ ^[0-9]+$ ]] || return 1
    raw="\"HIDIdleTime\" = ${DAYSIDE_OWNER_AWAY_TEST_HID_IDLE_NS}"
  else
    raw=$(/usr/sbin/ioreg -r -c IOHIDSystem -d 1 2>/dev/null) || return 1
  fi
  printf '%s\n' "$raw" | parse_idle
}
idle_enough() {
  local value="$1"
  [[ "$value" =~ ^[0-9]+$ ]] || return 1
  # 字符串比较避开整数溢出，也不把前导零当八进制。
  while [[ ${#value} -gt 1 && "$value" == 0* ]]; do value=${value#0}; done
  [[ ${#value} -gt 12 || ( ${#value} -eq 12 && ( "$value" == 300000000000 || "$value" > 300000000000 ) ) ]]
}
poll_seconds=30
if [[ "$testing" == 1 ]]; then
  poll_seconds=${DAYSIDE_OWNER_AWAY_TEST_POLL_SECONDS:-30}
  [[ "$poll_seconds" =~ ^[0-9]+$ ]] || exit 2
fi
while true; do
  if [[ "$strict" == 0 && -f "$flag" ]]; then
    printf 'ADMITTED: launches allowed while this Mac is in use\n' >&2
    exit 0
  fi
  if ! idle=$(read_idle); then
    printf 'DEFERRED: HIDIdleTime unavailable or malformed; launch blocked.\n' >&2
    exit 75
  fi
  while [[ ${#idle} -gt 1 && "$idle" == 0* ]]; do idle=${idle#0}; done
  if [[ ${#idle} -gt 20 || ( ${#idle} -eq 20 && "$idle" > 18446744073709551615 ) ]]; then
    printf 'DEFERRED: HIDIdleTime out of range; launch blocked.\n' >&2
    exit 75
  fi
  if idle_enough "$idle"; then exit 0; fi
  case "$mode" in --check|--strict-check|--unit-test-check|--unit-test-strict-check) exit 75 ;; esac
  if [[ "${DAYSIDE_OWNER_AWAY_LOCK_HELD:-}" == 1 ]]; then
    printf 'DEFERRED: HID idle below 300 seconds while CPU lock held; release lock and retry.\n' >&2
    exit 75
  fi
  printf 'DEFERRED: HID idle below 300 seconds; retry in %s seconds.\n' "$poll_seconds" >&2
  /bin/sleep "$poll_seconds"
done
