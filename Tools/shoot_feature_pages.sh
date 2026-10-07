#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# 逐页启动预览 harness、定帧、按 CGWindowID 只截 harness 自己那个窗口。
#
#   MEANTIME_PREVIEW_APP=<harness.app> bash Tools/shoot_feature_pages.sh <输出目录> <宽x高> <语言,逗号分隔>
#
# 例：商店尺寸中英两套
#   MEANTIME_PREVIEW_APP=backup/reshoot/DaysideFeaturePreview.app \
#     bash Tools/shoot_feature_pages.sh backup/reshoot/store-shots 1440x900 zh,en
#
# harness 由 Tools/preview_features.sh 编出（MEANTIME_PREVIEW=<路径> 指定输出位置）。
#
# 为什么用 `screencapture -l<windowid>` 而不是 `-R<矩形>`：按矩形截会把压在上面的别家窗口
# 一起拍进去（实测：另一会话留在屏幕中央、无人应答的 TCC 授权对话框进了全部 18 张）。
# 按窗口 ID 截由系统单独合成该窗口图层，别家窗口不进画面，也不必去点那个对话框。
# `-o` 去掉窗口投影，出图恰是窗口点尺寸的 2 倍像素。
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
source "$root/Tools/test_screen_guard.sh"
app="${MEANTIME_PREVIEW_APP:-$root/backup/reshoot/DaysideFeaturePreview.app}"
[[ -x "$app/Contents/MacOS/DaysideFeaturePreview" ]] || {
  echo "找不到 harness：$app（先跑 Tools/preview_features.sh）" >&2; exit 1; }

out="${1:?用法：shoot_feature_pages.sh <输出目录> <宽x高> <语言,逗号分隔>}"
size="${2:?缺少尺寸，如 1440x900}"
langs="${3:?缺少语言，如 zh,en}"
want_w="${size%x*}"; want_h="${size#*x}"
mkdir -p "$out"
features="${MEANTIME_SHOOT_FEATURES:-planner agenda people convert timers dstWatch astronomy travel sharing}"
log="$out/shoot.log"
: > "$log"

work="$(mktemp -d "${TMPDIR:-/tmp}/dayside-shoot.XXXXXX")"
trap 'pkill -x DaysideFeaturePreview 2>/dev/null; "$root/Tools/trash.sh" "$work"' EXIT
xcrun swiftc -O "$root/Tools/feature_window_id.swift" -o "$work/window_id" || exit 1

shoot_one() {
  local feature="$1" lang="$2" attempt="$3"
  pkill -x DaysideFeaturePreview 2>/dev/null; sleep 1
  /bin/bash "$root/Tools/owner_away.sh" --wait || exit "$?"
  dayside_require_launch_window "Feature page launch" || exit "$?"
  MEANTIME_PREVIEW_SIZE="$size" MEANTIME_PREVIEW_FEATURE="$feature" MEANTIME_PREVIEW_LANGUAGE="$lang" \
    "$app/Contents/MacOS/DaysideFeaturePreview" >/dev/null 2>&1 &
  sleep 3
  osascript -e 'tell application "System Events" to set frontmost of process "DaysideFeaturePreview" to true' >/dev/null 2>&1
  local bounds="" i w h
  for i in $(seq 1 20); do
    sleep 1
    bounds=$(osascript -e 'tell application "System Events" to tell process "DaysideFeaturePreview" to get {position, size} of window 1' 2>/dev/null)
    [[ -z "$bounds" ]] && continue
    w=$(echo "$bounds" | awk -F', *' '{print $3}')
    h=$(echo "$bounds" | awk -F', *' '{print $4}')
    [[ "$w" == "$want_w" && "$h" == "$want_h" ]] && break
  done
  local front title id
  front=$(osascript -e 'tell application "System Events" to get name of first process whose frontmost is true' 2>/dev/null)
  title=$(osascript -e 'tell application "System Events" to tell process "DaysideFeaturePreview" to get name of window 1' 2>/dev/null)
  id=$("$work/window_id" DaysideFeaturePreview | awk -v w="$want_w" -v h="$want_h" '$2==w && $3==h {print $1; exit}')
  local png="$out/$feature-$lang.png"
  "$root/Tools/trash.sh" "$png"
  [[ -n "$id" ]] && screencapture -x -o -l"$id" "$png"
  local px py
  px=$(sips -g pixelWidth "$png" 2>/dev/null | awk '/pixelWidth/{print $2}')
  py=$(sips -g pixelHeight "$png" 2>/dev/null | awk '/pixelHeight/{print $2}')
  echo "$feature-$lang try=$attempt size=(${w:-?}x${h:-?}) front=[$front] title=[$title] winid=${id:-无} png=${px:-无}x${py:-无}" | tee -a "$log"
  pkill -x DaysideFeaturePreview 2>/dev/null
  # 四条自检同时成立才算这张过：窗口定帧到位、前台确是 harness、出图是 2 倍像素
  [[ "$w" == "$want_w" && "$h" == "$want_h" && "$front" == "DaysideFeaturePreview" \
     && "$px" == "$((want_w * 2))" && "$py" == "$((want_h * 2))" ]]
}

failed=0
for feature in $features; do
  for lang in ${langs//,/ }; do
    ok=0
    for attempt in 1 2 3; do
      if shoot_one "$feature" "$lang" "$attempt"; then ok=1; break; fi
      echo "  重试 $feature-$lang" | tee -a "$log"
      sleep 2
    done
    [[ $ok == 1 ]] || { echo "!! 失败 $feature-$lang" | tee -a "$log"; failed=1; }
  done
done
echo "日志：$log"
# 自检只管尺寸与前台，拍进别家窗口这类事仍要逐张目视。
exit $failed
