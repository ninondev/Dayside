#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# 把 LaunchServices 里除 /Applications/Dayside.app 之外的所有 com.dayside.Dayside(.localpreview) 副本注销掉。
# 原因：转储、探针、发布门、Xcode 构建都会让 LaunchServices 记住一份同 bundle id 的副本；
# Spotlight / Launchpad 会随机打开其中一份，而 TCC 的「访问其他 App 的数据」授权按代码签名（ad-hoc 即 cdhash）记，
# 换一份副本就再问一次，用户看到的「每次打开都要点允许」就是这么来的。各脚本结束时调用本脚本。
set -uo pipefail
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
keep="${MEANTIME_KEEP_APP:-/Applications/Dayside.app}"
n=0
while IFS= read -r path; do
  [[ -z "$path" || "$path" == "$keep" ]] && continue
  "$lsregister" -u "$path" >/dev/null 2>&1 && n=$((n+1))
done < <("$lsregister" -dump 2>/dev/null \
  | grep -B 12 -E '^[[:space:]]*identifier:[[:space:]]*com\.dayside\.Dayside(\.localpreview)?$' \
  | grep -E '^[[:space:]]*path:' | sed -E 's/^[[:space:]]*path:[[:space:]]*//; s/ \(0x[0-9a-f]+\)$//' | sort -u)
echo "LaunchServices：注销 $n 份 Dayside 副本（保留 ${keep}）"
