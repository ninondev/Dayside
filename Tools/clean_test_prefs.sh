#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# 清掉测试宿主留在 App 容器里的一次性偏好域 plist。
# 原因：测试进程内已 removePersistentDomain + 删文件，但 cfprefsd 在进程退出约 15–20 秒后
# 会把它还记着的空 domain 再落一次盘（42 字节空 plist），进程内无法阻止；进程退出后从外部删就不会再回来。
# 用法: Tools/clean_test_prefs.sh [--wait 秒]   默认先等 30 秒再清；只删下面前缀开头、形如 <前缀>.<UUID>.plist 的文件。
set -uo pipefail
wait=30
[[ "${1:-}" == "--wait" && -n "${2:-}" ]] && wait="$2"
dir="$HOME/Library/Containers/com.dayside.Dayside/Data/Library/Preferences"
[[ -d "$dir" ]] || exit 0
sleep "$wait"
prefixes='com\.dayside\.entitlement-tests|meantime\.feature-hub\.tests|meantime\.agenda\.tests|com\.dayside\.tests\.lenses|com\.dayside\.planner-tests|com\.dayside\.test-host|meantime\.people\.tests|meantime\.travel\.tests|meantime\.sharing\.tests|com\.dayside\.storekit-tests|meantime\.hub\.identity|TimeInputTests|diagnostics-tests|swift-fuzz|meantime\.tests'
n=0
while IFS= read -r f; do "$(dirname "$0")/trash.sh" "$f" && n=$((n+1)); done < <(ls "$dir" 2>/dev/null | grep -E "^($prefixes)[.-][0-9A-Fa-f-]{36}\.plist$" | sed "s|^|$dir/|")
echo "清掉测试残留偏好文件 $n 个（等了 $wait 秒）"
