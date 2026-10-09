#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# 一键验证:RustCore 四步 + 应用测试,顺序执行,任一步失败立即非零退出。
# 最后打印一张汇总表(每步的通过数与耗时)。完整输出留在日志目录里。
#
#   Tools/verify_all.sh                       # 全跑
#   MEANTIME_VERIFY_LOGDIR=backup/x Tools/verify_all.sh   # 指定日志目录
#   MEANTIME_VERIFY_ROSETTA=1 Tools/verify_all.sh         # 追加 Intel 切片:Rust x86_64 测试 + 应用测试在 Rosetta 下再跑一遍(慢几分钟)
#   MEANTIME_VERIFY_AX=1 Tools/verify_all.sh              # 追加十三面进程内无障碍与对比度审计(Tools/ax_dump_pages.sh,期望 0 条;满负载下亮色一遍可能量不到,重跑即可)
#   MEANTIME_VERIFY_IOS=1 Tools/verify_all.sh             # 追加 iPhone 原型的模拟器构建(共享的模型文件改了别把 iOS target 弄断;不装不跑)
#
# 不含发布门:发布门要 Release 构建并独占同一个 bundle id,须与本脚本串行。
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
source "$root/Tools/test_screen_guard.sh"
test_arch="$(uname -m)"
logdir="${MEANTIME_VERIFY_LOGDIR:-$(mktemp -d "${TMPDIR:-/tmp}/dayside-verify.XXXXXX")}"
mkdir -p "$logdir"
logdir="$(cd "$logdir" && pwd)"
derived_data="${DAYSIDE_DERIVED_DATA:-$logdir/DerivedData}"

names=(); counts=(); durations=(); states=(); logs=()

# 汇总 cargo 的 "test result: ok. N passed" 行。一次 cargo test 会有多个二进制,各出一行。
count_cargo() { grep -Eo 'test result: ok\. [0-9]+ passed' "$1" | awk '{s+=$4} END{print s+0}'; }
# clippy 没有通过数,报警告条数(-D warnings 下只可能是 0)。
count_clippy() { printf '%s 警告' "$(grep -cE '^warning(:|\[)' "$1" || true)"; }
# 应用测试:XCTest 的 "Executed N tests" 与 Swift Testing 的 "Test run with N tests passed"。
count_xcode() {
    local xctest swifttesting
    xctest="$(grep -Eo 'Executed [0-9]+ tests?, with' "$1" | tail -1 | awk '{print $2}')"
    swifttesting="$(grep -Eo 'Test run with [0-9]+ tests?' "$1" | tail -1 | awk '{print $4}')"
    printf 'XCTest %s + Swift Testing %s' "${xctest:-?}" "${swifttesting:-?}"
}

# 汇总表。中文是全角,按字符数对齐会错位,故用 python3 按显示宽度补空格;没有 python3 时退回朴素排版。
summary() {
    local i rows=''
    for i in "${!names[@]}"; do
        rows+="${names[$i]}\t${counts[$i]}\t${durations[$i]}s\t${states[$i]}\n"
    done
    printf '\n'
    if command -v python3 >/dev/null 2>&1; then
        printf '%b' "$rows" | python3 -c '
import sys, unicodedata
def w(s): return sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in s)
rows = [l.rstrip("\n").split("\t") for l in sys.stdin if l.strip()]
head = ["步骤", "通过数", "耗时", "结果"]
cols = [max([w(head[i])] + [w(r[i]) for r in rows]) for i in range(4)]
def fmt(r): return "  ".join(r[i] + " " * (cols[i] - w(r[i])) for i in range(4)).rstrip()
rule = "-" * (sum(cols) + 6)
print(fmt(head)); print(rule)
for r in rows: print(fmt(r))
print(rule)
'
    else
        printf '%b' "$rows"
    fi
    printf '日志目录:%s\n' "$logdir"
}

step() {  # step <名称> <计数器> <工作目录> <命令...>
    local name="$1" counter="$2" dir="$3"; shift 3
    local slug log start rc dur
    slug="$(printf '%s' "$name" | tr ' /+-' '____')"
    log="$logdir/$slug.log"
    logs+=("$log")
    printf '\n==> %s\n' "$name"
    start=$SECONDS
    ( cd "$dir" && "$@" ) >"$log" 2>&1
    rc=$?
    dur=$((SECONDS - start))
    names+=("$name"); durations+=("$dur")
    if [[ $rc -eq 0 ]]; then
        counts+=("$("$counter" "$log")"); states+=('通过')
        printf '    通过,%ss\n' "$dur"
    else
        counts+=('—'); states+=("失败(退出码 $rc)")
        printf '    失败,退出码 %s\n' "$rc"
        printf '    最后 30 行:\n'
        tail -30 "$log" | sed 's/^/      /'
        summary
        exit "$rc"
    fi
}

# 编译不占屏幕；宿主复用已编译产物，启动前重新等键鼠空闲。
run_app_tests() {
    xcodebuild build-for-testing "$@" || return "$?"
    /bin/bash "$root/Tools/owner_away.sh" --wait || return "$?"
    dayside_require_launch_window "Swift suite launch" || return "$?"
    xcodebuild test-without-building "$@"
}

step 'cargo test --all-targets'            count_cargo  "$root/RustCore" cargo test --locked --all-targets
step 'cargo test --release --lib'          count_cargo  "$root/RustCore" cargo test --locked --release --lib
step 'cargo test --lib --features intents-only' count_cargo "$root/RustCore" cargo test --locked --lib --features intents-only
step 'cargo clippy --all-targets -D warnings'   count_clippy "$root/RustCore" cargo clippy --locked --all-targets -- -D warnings
step '应用测试 xcodebuild test'             count_xcode  "$root" \
    run_app_tests -project Dayside.xcodeproj -scheme Dayside \
    -destination "platform=macOS,arch=$test_arch" -derivedDataPath "$derived_data" -parallel-testing-enabled NO

# 签名策略：所有签名配置都禁止网络权限。
count_ent() { grep -c '签名策略检查通过' "$1"; }
step '签名策略 check_entitlements'         count_ent    "$root" Tools/check_entitlements.sh

# 十六语文案完整性：核对源码键、已翻译状态及所有变体；应用测试后还要求当前工作区的编译提取。
count_l10n() { grep -Eo '文案目录 [0-9]+ 键，[0-9]+ 种语言' "$1" | tail -1; }
step '文案完整性 l10n_check --check'   count_l10n   "$root" python3 Tools/l10n_check.py --check --require-compiler-data --derived-data "$derived_data" --arch "$test_arch"
count_copy() { grep -Eo '文案残留检查：.*' "$1"; }
step '文案旧术语 l10n_copy_gate'       count_copy   "$root" python3 Tools/l10n_copy_gate.py

# 许可标头：每个源文件都带 SPDX-License-Identifier: GPL-3.0-only（Tools/spdx_headers.py）。
count_spdx() { grep -Eo 'GPL-3.0-only: [0-9]+ files' "$1" | tail -1; }
step '许可标头 spdx_headers --check'       count_spdx   "$root" python3 Tools/spdx_headers.py --check

# 分享页脚本(site/when.html)在 Node 里用最小 DOM 跑真实脚本:解码、预约起点、邮件、.ics(Tools/site_tests)。本机没有 node 就跳过并说明。
count_site() { grep -Eo 'site tests: [0-9]+ passed' "$1" | tail -1 | sed 's/site tests: //'; }
if command -v node >/dev/null 2>&1; then
    step '分享页脚本测试 node'             count_site   "$root" node Tools/site_tests/when_test.mjs
else
    printf '\n==> 分享页脚本测试 node\n    跳过:本机没有 node\n'
fi

# 无障碍审计(可选):Debug 副本自己走十一面的无障碍树并量亮暗对比度,任何一条问题即失败。
count_ax() { grep -Eo '合计 [0-9]+ 条' "$1" | tail -1 | sed 's/合计 //'; }
if [[ "${MEANTIME_VERIFY_AX:-0}" == 1 ]]; then
    step '无障碍审计 ax_dump_pages'           count_ax     "$root" \
        Tools/ax_dump_pages.sh "$logdir/ax"
fi

# iPhone 原型(可选):只构建,不装不跑;用独立的 DerivedData,不碰主工程那份。
count_ios() { grep -c 'BUILD SUCCEEDED' "$1"; }
if [[ "${MEANTIME_VERIFY_IOS:-0}" == 1 ]]; then
    step 'iPhone 原型 xcodebuild build'      count_ios    "$root" \
        xcodebuild -project Dayside.xcodeproj -scheme DaysideiOS -configuration Debug \
        -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath "${TMPDIR:-/tmp}/dayside-ios-verify" build
fi

# Intel 切片(可选):Rust 在 x86_64 target 上跑全部测试,应用测试用 Rosetta 目的地重跑一遍。
if [[ "${MEANTIME_VERIFY_ROSETTA:-0}" == 1 ]]; then
    step 'cargo test x86_64(Rosetta)'       count_cargo  "$root/RustCore"         cargo test --locked --all-targets --target x86_64-apple-darwin
    step '应用测试 x86_64(Rosetta)'          count_xcode  "$root"         run_app_tests -project Dayside.xcodeproj -scheme Dayside         -destination 'platform=macOS,arch=x86_64' -derivedDataPath "$derived_data" -parallel-testing-enabled NO
fi

summary

# 构建与测试会让 LaunchServices 记住 DerivedData 里的副本，注销掉，只留 /Applications 的安装版（见 Tools/ls_unregister_copies.sh）。
"$root/Tools/ls_unregister_copies.sh" >/dev/null 2>&1 || true
# cfprefsd 会在测试进程退出十几秒后再落一次空 plist，等它写完再从外部清（Tools/clean_test_prefs.sh）。
( "$root/Tools/clean_test_prefs.sh" --wait 30 >/dev/null 2>&1 & )
