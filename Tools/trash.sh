#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# 将副本、构建产物和临时文件移进废纸篓，便于恢复；清空废纸篓由用户主动操作。
# 用法：Tools/trash.sh 路径…   不存在的路径跳过（没匹配上的通配符原样传进来也一样）；有一个挪不动就非零退出。
# 走系统自带的 /usr/bin/trash（与 Finder 同一条路，废纸篓里能「放回原处」，重名由系统处理）；没有它时退回 mv。
# App 包（.app）先从 LaunchServices 注销、原地改名加时间再挪：改名后不再是 App 包，废纸篓里同 bundle id 的旧副本
# 避免 dayside:// 深链被系统路由到另一份 App 副本。
set -u
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
status=0
for path in "$@"; do
  [[ -e "$path" || -L "$path" ]] || continue
  target="$path"
  name="$(basename "$path")"
  if [[ "$name" == *.app && -d "$path" ]]; then
    "$lsregister" -u "$path" >/dev/null 2>&1 || true
    target="$(dirname "$path")/$name $(date +%Y%m%d-%H%M%S)-$$-$RANDOM"
    mv "$path" "$target" || { echo "trash.sh: 改不了名：$path" >&2; status=1; continue; }
  fi
  if [[ -x /usr/bin/trash ]]; then
    /usr/bin/trash "$target" >/dev/null || { echo "trash.sh: 挪不进废纸篓：$target" >&2; status=1; }
  else
    dest="$HOME/.Trash/$(basename "$target")"
    [[ -e "$dest" || -L "$dest" ]] && dest="$dest $(date +%Y%m%d-%H%M%S)-$$-$RANDOM"
    mv "$target" "$dest" || { echo "trash.sh: 挪不进废纸篓：$target" >&2; status=1; }
  fi
done
exit $status
