#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# 一键打包：两架构 Release → 隔离预览 → 发布验证 → 打包归档。
# DMG（挂载逐文件对照 + 严格验签）→ 峰值量尺（arm64）→ 内存巡回连地球窗（arm64）→ 注销 LaunchServices 副本 → 删构建产物。
# 用法：Tools/package_release.sh <标签，如 20260919a> [--install]
#   产物：仓根 Dayside-All-tools-local-preview-<标签>-{arm64,x86_64}.dmg（+ .sha256 / .validation.json）；
#   日志与门在 backup/pkg-<标签>/；--install 把 arm64 完整候选装到 /Applications/Dayside.app（会先退出运行中的 Dayside）。
# 前提：verify_all 已过；机器安静（swap 用满时 x86_64 的门会虚高）；磁盘 ≥ 20 GB。
# 随盘 ReadMe 在 Tools/dmg/ReadMe-<arch>.txt，打包前改它的第一段。
set -uo pipefail
tag=${1:?用法: Tools/package_release.sh <标签> [--install]}
install=${2:-}
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source "$root/Tools/test_screen_guard.sh"
pkg=$root/backup/pkg-$tag
mkdir -p "$pkg"
cd "$root"
# 机器上有生产任务时（雷达 12:00–15:45 的模型服务）编译要限并行：MEANTIME_BUILD_JOBS=3 时 xcodebuild 带 -jobs、cargo 跟着限，
# 整条命令再套 nice -n 10，让构建为前台任务让出 CPU。不设就照旧。
jobs_args=()
if [[ -n "${MEANTIME_BUILD_JOBS:-}" ]]; then
  jobs_args=(-jobs "$MEANTIME_BUILD_JOBS")
  export CARGO_BUILD_JOBS=$MEANTIME_BUILD_JOBS
fi
echo "== 磁盘"; df -h /System/Volumes/Data | tail -1
status=0
for arch in arm64 x86_64; do
  "$root/Tools/trash.sh" "$pkg/dd-$arch"
  xcodebuild -project TahoeTime.xcodeproj -scheme TahoeTime -configuration Release ARCHS=$arch ONLY_ACTIVE_ARCH=NO ${jobs_args[@]+"${jobs_args[@]}"} \
    -derivedDataPath "$pkg/dd-$arch" build > "$pkg/build-$arch.log" 2>&1 || { echo "build $arch 失败，看 $pkg/build-$arch.log"; exit 1; }
  echo "build $arch ok"
  app="$pkg/dd-$arch/Build/Products/Release/Dayside.app"
  "$root/Tools/trash.sh" "$pkg/preview-$arch"; mkdir -p "$pkg/preview-$arch"
  preview="$pkg/preview-$arch/Dayside Local Preview.app"
  Tools/make_local_preview.sh "$app" "$preview" > "$pkg/preview-$arch.log" 2>&1 || { echo "preview $arch 失败"; tail -5 "$pkg/preview-$arch.log"; exit 1; }
  for run in 1 2; do
    Tools/release_gate.sh --skip-build --app "$preview" > "$pkg/gate-$arch-$run.log" 2>&1; code=$?
    echo "gate $arch #$run exit=$code"
    grep -E "CPU|footprint|RSS|包体|映射" "$pkg/gate-$arch-$run.log" | head -5
    [[ $code -eq 0 ]] || status=1
  done
  out="$root/Dayside-All-tools-local-preview-$tag-$arch.dmg"
  "$root/Tools/trash.sh" "$out" "$out.sha256" "$out.validation.json"
  Tools/make_dmg.sh "$preview" "$out" "$root/Tools/dmg/ReadMe-$arch.txt" Dayside > "$pkg/dmg-$arch.log" 2>&1 && echo "dmg $arch ok" || { echo "dmg $arch 失败"; tail -5 "$pkg/dmg-$arch.log"; status=1; }
  python3 -c "import json;d=json.load(open('$out.validation.json'));print('$arch', d['bytes'], d['sha256'][:8], d['mountedFilesCompared'], d['mountedFilesEqualSourceBundle'], d['strictSignature'])" 2>/dev/null
done
Tools/peak_gate.sh --app "$pkg/preview-arm64/Dayside Local Preview.app" > "$pkg/peak-arm64.log" 2>&1; echo "peak exit=$?"
# 内存巡回：面板 → 工具窗十页 → 地球窗（拖动六次 + 离屏渲染一次地图海报）→ 关 → 静置，
# 每个阶段一个 footprint（Release 隔离预览）。只记录不设门：地球窗拖动时的图形缓冲是窗口尺寸决定的。
MEANTIME_TOUR_EARTH=1 Tools/memory_tour_probe.sh "$pkg/tour-arm64" --app "$pkg/preview-arm64/Dayside Local Preview.app" > "$pkg/tour-arm64.log" 2>&1
echo "tour exit=$?"; awk 'NF>=3' "$pkg/tour-arm64/table.txt" 2>/dev/null | grep -E "阶段|launched|closed|earth|done"
if [[ "$install" == "--install" ]]; then
  src="$pkg/dd-arm64/Build/Products/Release/Dayside.app"
  codesign --verify --strict --deep "$src" || { echo "装机前验签失败"; exit 1; }
  # 装之前在跑就装完再打开，别把它关掉不管（0927a 装完菜单栏空着查出）。
  was_running=0; pgrep -x Dayside >/dev/null && { was_running=1; killall Dayside; }; sleep 2
  "$root/Tools/trash.sh" /Applications/Dayside.app && ditto "$src" /Applications/Dayside.app && echo "已装到 /Applications/Dayside.app（$(du -sk /Applications/Dayside.app | cut -f1) KB）"
  if [[ "$was_running" == 1 ]]; then
    /bin/bash "$root/Tools/owner_away.sh" --wait || exit "$?"
    dayside_require_launch_window "Installed app reopen" || exit "$?"
    open /Applications/Dayside.app && echo "已重新打开"
  fi
fi
Tools/ls_unregister_copies.sh >/dev/null 2>&1
"$root/Tools/trash.sh" "$pkg"/dd-* "$pkg"/preview-*
echo "PACKAGE_DONE status=$status（0 = 门全过）"
exit $status
