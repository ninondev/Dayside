#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
source "$root/Tools/test_screen_guard.sh"
test_home="$(mktemp -d)"
trap 'python3 -c "import shutil, sys; shutil.rmtree(sys.argv[1])" "$test_home"' EXIT
export HOME="$test_home/home"
mkdir -p "$HOME/.config/dayside"
pause_file="$HOME/.config/dayside/measure.state"

check_state() {
  local expected="$1" actual=0
  dayside_require_measurement_window "$2" 2>"$test_home/error" || actual=$?
  [[ "$actual" == "$expected" ]]
  if [[ "$expected" == 75 ]]; then
    /usr/bin/grep -q '^DEFERRED:' "$test_home/error"
  fi
}

[[ "$(dayside_measurement_state)" == FREE ]]
check_state 0 absent
printf 'FREE\n' > "$test_home/state"
ln -s "$test_home/state" "$pause_file"
[[ "$(dayside_measurement_state)" == FREE ]]
check_state 0 linked-free
printf 'TIMED test\n' > "$test_home/state"
check_state 75 linked-timed
python3 -c 'import pathlib, sys; pathlib.Path(sys.argv[1]).unlink()' "$test_home/state"
check_state 75 dangling-link
printf 'UNKNOWN\n' > "$test_home/state"
check_state 75 unknown
printf '\n' > "$test_home/state"
check_state 75 empty
python3 -c 'import pathlib, sys; pathlib.Path(sys.argv[1]).unlink(); pathlib.Path(sys.argv[1]).mkdir()' "$test_home/state"
check_state 75 unreadable-directory
printf 'pause-file shell tests passed (7 cases)\n'
