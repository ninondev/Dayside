#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# 同一把量尺交替测两个隔离产物，原始记录写进指定目录。
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "${1:-}" == --help ]]; then exec python3 "$root/Tools/perf_ruler.py" --help; fi
coordination_root=${DAYSIDE_PERF_COORDINATION_ROOT:?Set the shared measurement coordination directory for this host}
[[ "$coordination_root" == /* && -d "$coordination_root" && -r "$coordination_root/measure.state" ]] || exit 1
source "$root/Tools/test_screen_guard.sh"
cleanup() { "$root/Tools/ls_unregister_copies.sh" >/dev/null 2>&1 || true; }
trap cleanup EXIT
run_queued_under_cpu_lock() {
  local marker=$1 result
  shift
  while :; do
    while [[ "$(dayside_measurement_state)" != FREE || "$(cat "$coordination_root/measure.state")" != FREE ]]; do sleep 5; done
    if "$@"; then return 0; else result=$?; fi
    if [[ "$result" == 75 && ! -s "$marker" ]]; then
      echo 'CPU lock acquisition timed out before start; continuing to wait.' >&2
      continue
    fi
    return "$result"
  done
}
out=""
old_app=""
new_app=""
next_app=""
next_out=0
for argument in "$@"; do
  if [[ "$next_app" == old ]]; then old_app=$argument; next_app=""; continue; fi
  if [[ "$next_app" == new ]]; then new_app=$argument; next_app=""; continue; fi
  case "$argument" in --old-app) next_app=old ;; --new-app) next_app=new ;; --old-app=*) old_app=${argument#--old-app=} ;; --new-app=*) new_app=${argument#--new-app=} ;; esac
  if (( next_out )); then out=$argument; next_out=0; continue; fi
  case "$argument" in --out) next_out=1 ;; --out=*) out=${argument#--out=} ;; esac
done
while [[ "$out" == */ && "$out" != / ]]; do out=${out%/}; done
[[ -n "$out" && "$next_out" == 0 && ! -e "$out" ]] || { echo 'Choose a new output directory with --out.' >&2; exit 1; }
mkdir -p "$(dirname "$out")"
queue_marker="$(mktemp "$(dirname "$out")/.perf-ruler-queue.XXXXXXXX")"
run_queued_under_cpu_lock "$queue_marker" \
  /usr/bin/lockf -k -t 3600 "$coordination_root/cpu-turn.lock" nice -n 10 \
  /bin/bash -c 'set -euo pipefail; marker=$1; gate=$2; shift 2; printf "started\n" > "$marker"; /usr/bin/uptime; /usr/sbin/sysctl vm.swapusage; /bin/bash "$gate" --strict-check; exec "$@"' \
  perf-ruler "$queue_marker" "$root/Tools/owner_away.sh" python3 "$root/Tools/monitor_frontmost.py" \
  --output "${out}-frontmost.jsonl" --owned-app-root "$old_app" --owned-app-root "$new_app" -- \
  env DAYSIDE_PERF_CPU_LOCK_HELD=1 python3 "$root/Tools/perf_ruler.py" "$@"
