#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# 「用完之后内存回不回得去」探针：复制 Debug 产物、重签（与 window_close_probe.sh 同法），
# 用 MEANTIME_UI_TEST_MEMORY_TOUR=1 让 App 自己走一遍：就绪 → 开面板 3 秒 → 关 → 开工具窗走完十页 → 关 → 静置 60 秒，
# 每个阶段量一次 vmmap 的 Physical footprint，打印成表。Debug 产物的绝对值比 Release 大，看的是「关窗之后回不回去」的相对量。
# 用法: Tools/memory_tour_probe.sh [输出目录] [--app <Dayside.app>]；MEANTIME_PROBE_SKIP_BUILD=1 跳过构建。
#   --app：量给定的产物（Release 隔离预览，数字才是真的）。复制一份再跑，原件不动。
#   --in-place：直接量指定的隔离预览，不复制产物。
#   MEANTIME_TOUR_EARTH_ONLY=1：跳过面板与工具窗；MEANTIME_TOUR_ANIMATION=0：跳转不动画。
#   MEANTIME_TOUR_FORCE_ANIMATION=1：隔离量尺忽略系统减弱动态效果，让跳转逐帧动。
#   --app 的产物不保证支持屏外测试，须 MEANTIME_UI_TEST_FOREGROUND=1；默认 Debug 巡回在屏外运行。
#   MEANTIME_DERIVED_DATA_PATH 指定构建缓存，MEANTIME_DEBUG_APP 指定已有 Debug 产物。
#   MEANTIME_TOUR_EARTH=1：关掉工具窗之后再走一遍地球窗（开 3 秒 → 跳六次时刻 → 离屏渲染一次地图海报 → 关）。
#   内存巡回使用隔离夹具；MEANTIME_TOUR_FIXTURE（默认 store）选择夹具数据。
#   MEANTIME_TOUR_PANEL_ONLY=1：只开关面板，关上后直接静置 60 秒（不走工具窗），量面板关着时的空闲 CPU。
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
source "$root/Tools/test_screen_guard.sh"
out="" app="" in_place=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --in-place) in_place=1; shift ;;
    --app) app="${2:?--app 要跟产物路径}"; shift 2 ;;
    *) out="$1"; shift ;;
  esac
done
[[ "$in_place" != 1 || -n "$app" ]] || exit 2
dayside_require_launch_window "Memory tour"
if [[ -n "$app" ]]; then dayside_require_foreground_window "Memory tour --app (foreground support required)"; fi
out="${out:-$root/backup/memory-tour-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$out"; out="$(cd "$out" && pwd)"
cd "$root"
copy="" pid="" sampler="" idle_watcher=""
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
cleanup() {
  status=$?
  trap - EXIT HUP INT TERM
  if [[ -n "$idle_watcher" ]]; then kill "$idle_watcher" 2>/dev/null || true; wait "$idle_watcher" 2>/dev/null || true; fi
  if [[ -n "$sampler" ]]; then kill "$sampler" 2>/dev/null || true; wait "$sampler" 2>/dev/null || true; fi
  if [[ -n "$pid" ]]; then
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
  if [[ -n "$copy" && "$in_place" != 1 ]]; then
    "$lsregister" -u "$copy" >/dev/null 2>&1 || true
    # 本轮生成的副本原地删除，不留同身份的构建产物。
    if python3 - "$copy" <<'CLEANUP'
import pathlib
import shutil
import sys

app = pathlib.Path(sys.argv[1])
if app.is_symlink() or app.is_file():
    app.unlink()
elif app.exists():
    shutil.rmtree(app)
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
if [[ -n "$app" ]]; then
  [[ -d "$app" ]] || { echo "没有这个产物：$app" >&2; exit 1; }
  if [[ "$in_place" == 1 ]]; then
    copy="$app"
  else
    copy="$out/Dayside.app"; [[ ! -e "$copy" ]] || { echo "副本路径已存在：$copy" >&2; exit 1; }; ditto "$app" "$copy"
  fi
  /usr/bin/codesign --verify --deep --strict "$copy"
else
  if [[ "${MEANTIME_PROBE_SKIP_BUILD:-0}" != 1 ]]; then
    build_args=()
    if [[ -n "${MEANTIME_DERIVED_DATA_PATH:-}" ]]; then build_args=(-derivedDataPath "$MEANTIME_DERIVED_DATA_PATH"); fi
    dayside_require_measurement_window "Memory tour build"
    xcodebuild -project TahoeTime.xcodeproj -scheme TahoeTime -configuration Debug ${build_args[@]+"${build_args[@]}"} -jobs 3 CODE_SIGNING_ALLOWED=NO build > "$out/build.log" 2>&1 \
      || { grep -E ': error:|\*\* ' "$out/build.log" | sort -u | head >&2; echo "构建失败，见 $out/build.log" >&2; exit 1; }
  fi
  copy="$out/Dayside.app"
  MEANTIME_SKIP_BUILD=1 "$root/Tools/make_debug_copy.sh" "$out" > "$out/copy.stdout"
fi
dayside_require_launch_window "Memory tour launch"
/bin/bash "$root/Tools/owner_away.sh" --wait || exit "$?"
dayside_require_launch_window "Memory tour launch" || exit "$?"
MEANTIME_TEST_HOST=1 MEANTIME_UI_TEST_FOREGROUND="${MEANTIME_UI_TEST_FOREGROUND:-0}" MEANTIME_UI_TEST_MEMORY_TOUR=1 MEANTIME_UI_TEST_FIXTURE="${MEANTIME_TOUR_FIXTURE:-store}" \
  MEANTIME_UI_TEST_MEMORY_RELIEF="${MEANTIME_TOUR_RELIEF:-0}" MEANTIME_UI_TEST_MEMORY_CYCLES="${MEANTIME_TOUR_CYCLES:-0}" \
  MEANTIME_UI_TEST_MEMORY_EARTH_ONLY="${MEANTIME_TOUR_EARTH_ONLY:-0}" MEANTIME_UI_TEST_MEMORY_ANIMATION="${MEANTIME_TOUR_ANIMATION:-1}" \
  MEANTIME_UI_TEST_FORCE_ANIMATION="${MEANTIME_TOUR_FORCE_ANIMATION:-0}" \
  MEANTIME_UI_TEST_MEMORY_EARTH="${MEANTIME_TOUR_EARTH:-0}" \
  MEANTIME_UI_TEST_MEMORY_PANEL_ONLY="${MEANTIME_TOUR_PANEL_ONLY:-0}" \
  "$copy/Contents/MacOS/Dayside" > "$out/probe.stdout" 2> "$out/probe.stderr" &
pid=$!
printf '%s\n' "$pid" > "$out/probe.pid"
# 外部量尺按真实关窗时刻计时，不把巡回里的阶段名当秒数。
if [[ -n "${MEANTIME_TOUR_IDLE60_HELPER:-}" ]]; then
  "$MEANTIME_TOUR_IDLE60_HELPER" "$pid" "$out/probe.stdout" "$out/idle60-wall.json" > "$out/idle60-wall.stdout" 2> "$out/idle60-wall.stderr" &
  idle_watcher=$!
fi
# 每一行 `MEANTIME_TOUR <阶段> fp=… peak=… cpu_ns=… energy_nj=… gpu=…` 都从内核记账读取资源用量
# （`ProcessMeter`，不受采样时机影响），这里按阶段相减：本阶段 CPU（毫秒）、能耗（毫焦）、本进程 GPU 时间（内核原值）。
# 合成与显示在窗口服务器里做，本进程的数看不见：另记整机 GPU 占用（`ioreg` 的 Device Utilization %，每 0.25 秒一次，
# 取这一阶段里的最高与平均）与 WindowServer 这一阶段的 CPU（`ps`，秒）。两者都是整机的，机器上别的东西也算在里面，只作 A/B。
# vmmap 仍每阶段量一次，用来拆分区（App 在每行之后停 2.5 秒，vmmap 量到的是这一步做完、下一步还没开始的样子）。
cpu_seconds() { ps -o time= -p "$1" 2>/dev/null | awk -F: '{ if (NF == 3) print $1 * 3600 + $2 * 60 + $3; else if (NF == 2) print $1 * 60 + $2; else print $1 }'; }
field() { echo "$1" | tr ' ' '\n' | awk -F= -v k="$2" '$1 == k {print $2; exit}'; }
gpu_log="$out/gpu.log"; : > "$gpu_log"
( while kill -0 "$pid" 2>/dev/null; do
    ioreg -r -d 1 -w 0 -c IOAccelerator 2>/dev/null | grep -o '"Device Utilization %"=[0-9]*' | head -1 | cut -d= -f2
    sleep 0.25
  done ) >> "$gpu_log" &
sampler=$!
ws=$(pgrep -x WindowServer | head -1)
last_ws=$(cpu_seconds "$ws"); last_ws=${last_ws:-0}
last_cpu=0 last_energy=0 last_gpu=0 gpu_seen=0
printf '%-12s %8s %8s %9s %9s %8s %9s %8s %8s %9s %9s\n' 阶段 footprint 峰值 small空 图形 CPU毫秒 能耗毫焦 GPU本进程 整机GPU峰 整机GPU均 WS_CPU秒 | tee "$out/table.txt"
seen=0 tour_done=0
for _ in $(seq 1 480); do
  dayside_require_launch_window "Running memory tour"
  sleep 0.5
  kill -0 "$pid" 2>/dev/null || break
  count=$(grep -c '^MEANTIME_TOUR ' "$out/probe.stdout" 2>/dev/null || true)
  while [[ "$seen" -lt "$count" ]]; do
    seen=$((seen + 1))
    line=$(grep '^MEANTIME_TOUR ' "$out/probe.stdout" | sed -n "${seen}p")
    phase=$(echo "$line" | awk '{print $2}')
    ws_now=$(cpu_seconds "$ws"); ws_now=${ws_now:-0}
    lines=$(wc -l < "$gpu_log" | tr -d ' ')
    gpu_stats=$(sed -n "$((gpu_seen + 1)),${lines}p" "$gpu_log" | awk 'NF { if ($1 > m) m = $1; s += $1; n++ } END { if (n) printf "%d %.0f", m, s / n; else print "- -" }')
    gpu_seen=$lines
    summary=$(vmmap --summary "$pid" 2>/dev/null || true)
    echo "$summary" > "$out/vm-$phase.txt"
    empty=$(echo "$summary" | awk '$1 == "MALLOC_SMALL" && $2 == "(empty)" {print $5; exit}')
    gfx=$(echo "$summary" | awk '/^owned unmapped \(graphics\)/{print $5}')
    fp=$(field "$line" fp); peak=$(field "$line" peak); cpu=$(field "$line" cpu_ns); energy=$(field "$line" energy_nj); gpu=$(field "$line" gpu)
    printf '%-12s %8s %8s %9s %9s %8s %9s %8s %8s %9s %9s\n' "$phase" \
      "$(awk -v v="${fp:-0}" 'BEGIN { printf "%.1fM", v / 1048576 }')" "$(awk -v v="${peak:-0}" 'BEGIN { printf "%.1fM", v / 1048576 }')" \
      "${empty:--}" "${gfx:--}" \
      "$(awk -v a="${cpu:-0}" -v b="$last_cpu" 'BEGIN { printf "%.0f", (a - b) / 1e6 }')" \
      "$(awk -v a="${energy:-0}" -v b="$last_energy" 'BEGIN { printf "%.0f", (a - b) / 1e6 }')" \
      "$(awk -v a="${gpu:-0}" -v b="$last_gpu" 'BEGIN { printf "%.0f", a - b }')" \
      $gpu_stats "$(awk -v a="$ws_now" -v b="$last_ws" 'BEGIN { printf "%.2f", a - b }')" | tee -a "$out/table.txt"
    last_cpu=${cpu:-0} last_energy=${energy:-0} last_gpu=${gpu:-0} last_ws=$ws_now
    [[ "$phase" == done ]] && { tour_done=1; kill "$pid" 2>/dev/null || true; break 2; }
  done
done
kill "$pid" "$sampler" 2>/dev/null || true
wait "$pid" "$sampler" 2>/dev/null || true
pid="" sampler=""
if [[ "$tour_done" != 1 ]]; then
  echo "Memory tour did not reach done; partial measurements: $out/table.txt" >&2
  exit 1
fi
if [[ -n "$idle_watcher" ]]; then
  if wait "$idle_watcher"; then idle_watcher=""; else status=$?; idle_watcher=""; exit "$status"; fi
fi
echo "结果：$out/table.txt"
