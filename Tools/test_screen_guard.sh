#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# 测量先等空闲；前台步骤还须显式授权且没有屏幕占用标记。
dayside_measurement_state() {
  local pause_file="$HOME/.config/dayside/measure.state"
  if [[ ! -e "$pause_file" && ! -L "$pause_file" ]]; then
    printf 'FREE\n'
  else
    cat "$pause_file"
  fi
}

dayside_require_measurement_window() {
  local step="$1" state
  state="$(dayside_measurement_state 2>/dev/null)" || state=""
  if [[ "$state" != FREE ]]; then
    printf 'DEFERRED: %s; measure.state=%s; wait for FREE.\n' "$step" "${state:-unavailable}" >&2
    return 75
  fi
}

dayside_require_foreground_window() {
  local step="$1"
  if [[ "${MEANTIME_UI_TEST_FOREGROUND:-0}" != 1 ]]; then
    printf 'DEFERRED: %s requires MEANTIME_UI_TEST_FOREGROUND=1.\n' "$step" >&2
    return 75
  fi
  dayside_require_measurement_window "$step" || return "$?"
  if [[ -e "$HOME/.dayside-screen-busy" ]]; then
    printf 'DEFERRED: %s; %s exists; retry when the screen is free.\n' "$step" "$HOME/.dayside-screen-busy" >&2
    return 75
  fi
}

dayside_require_launch_window() {
  dayside_require_measurement_window "$1" || return "$?"
  if [[ -n "${MEANTIME_UI_TEST_ROW_MENU:-}" ]]; then
    dayside_require_foreground_window "$1 (row menu fixture)" || return "$?"
  fi
  if [[ "${MEANTIME_UI_TEST_FOREGROUND:-0}" == 1 ]]; then
    dayside_require_foreground_window "$1" || return "$?"
  fi
}
