#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# 九个工具页的系统无障碍审计：XCUITest 在真实 Debug 构建上逐页调用 performAccessibilityAudit
#（对比度、元素可检测、点击区域、元素描述），产出每页截图与 audit.tsv。
# 用法: Tools/audit_accessibility.sh [输出目录]   （默认 backup/accessibility-audit-<时间>）
# 前提: 本机已启用 UI 自动化模式（macOS 26 一次性、需管理员认证，状态在 /var/db/com.apple.dt.automationmode/）。
#   首次运行会弹「Enable UI Automation」认证框，60 秒内输入管理员密码；或先执行
#   sudo /usr/bin/automationmodetool enable-automationmode-without-authentication
# 被测 app 走 MEANTIME_TEST_HOST=1 的一次性偏好域与 Debug-only 假日历/通讯录/通知（UITestFixture），不碰安装版数据。
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
source "$root/Tools/test_screen_guard.sh"
out="${1:-$root/backup/accessibility-audit-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$out"
status="$(/usr/bin/automationmodetool 2>&1 || true)"
if echo "$status" | grep -qi 'disabled'; then
  echo "自动化模式状态：$status"
  echo "首次运行会弹「Enable UI Automation」认证框（60 秒内输入管理员密码），或先执行："
  echo "  sudo /usr/bin/automationmodetool enable-automationmode-without-authentication"
fi
cd "$root"
if ! xcodebuild build-for-testing -project TahoeTime.xcodeproj -scheme TahoeTimeUITests -configuration Debug > "$out/build.log" 2>&1; then
  grep -E ': error:|\*\* .* \*\*' "$out/build.log" | sort -u | head -20 >&2
  echo "构建失败，完整日志：$out/build.log" >&2
  exit 1
fi
"$root/Tools/trash.sh" "$out/run.xcresult"
/bin/bash "$root/Tools/owner_away.sh" --wait || exit "$?"
dayside_require_launch_window "Accessibility audit launch" || exit "$?"
set +e
xcodebuild test-without-building -project TahoeTime.xcodeproj -scheme TahoeTimeUITests \
  -resultBundlePath "$out/run.xcresult" > "$out/test.log" 2>&1
code=$?
set -e
if grep -q 'Timed out while enabling automation mode' "$out/test.log"; then
  echo "未能启用 UI 自动化模式（60 秒内无人完成认证），审计没有运行。按上面的提示启用后重跑。" >&2
  exit 2
fi
report_dir="$(grep -o 'MEANTIME_UI_AUDIT_DIR=.*' "$out/test.log" | head -1 | cut -d= -f2- || true)"
if [[ -n "$report_dir" && -d "$report_dir" ]]; then
  cp "$report_dir"/*.png "$report_dir"/audit.tsv "$out/" 2>/dev/null || true
fi
# 附件（截图）也留在 xcresult 里，作第二来源。
xcrun xcresulttool export attachments --path "$out/run.xcresult" --output-path "$out/attachments" >/dev/null 2>&1 || true
if [[ -f "$out/audit.tsv" ]]; then
  echo "审计报告：$out/audit.tsv"
  for page in planner agenda people convert timers dstWatch astronomy travel sharing; do
    n=$(awk -F'\t' -v p="$page" 'NR>1 && $1==p' "$out/audit.tsv" | wc -l | tr -d ' ')
    printf '  %-10s %s 条\n' "$page" "$n"
  done
else
  echo "没有生成 audit.tsv，见 $out/test.log" >&2
fi
grep -E 'Executed .* tests?, with .* failures' "$out/test.log" | tail -1 || true
exit $code
