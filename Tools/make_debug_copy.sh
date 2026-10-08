#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# 把 Debug 产物复制到 <outdir>/Dayside.app，重签，打印副本路径。
# 转储、探针、截图脚本共用；调用方负责用完删除本轮副本，并注销它的 LaunchServices 记录。
# 用法: Tools/make_debug_copy.sh <outdir>；MEANTIME_SKIP_BUILD=1 跳过 xcodebuild。
# MEANTIME_DERIVED_DATA_PATH 指定缓存；MEANTIME_DEBUG_APP 指定已有 Debug 产物。
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:?用法：make_debug_copy.sh <输出目录>}"
mkdir -p "$out"; out="$(cd "$out" && pwd)"
cd "$root"
build_args=()
if [[ -n "${MEANTIME_DERIVED_DATA_PATH:-}" ]]; then build_args=(-derivedDataPath "$MEANTIME_DERIVED_DATA_PATH"); fi
if [[ "${MEANTIME_SKIP_BUILD:-0}" != 1 && -z "${DAYSIDE_DEBUG_APP:-${MEANTIME_DEBUG_APP:-}}" ]]; then
  source "$root/Tools/test_screen_guard.sh"
  dayside_require_measurement_window "Debug copy build"
  xcodebuild -project TahoeTime.xcodeproj -scheme TahoeTime -configuration Debug ${build_args[@]+"${build_args[@]}"} -jobs 3 CODE_SIGNING_ALLOWED=NO build > "$out/build.log" 2>&1 \
    || { grep -E ': error:|\*\* ' "$out/build.log" | sort -u | head >&2; echo "构建失败，见 $out/build.log" >&2; exit 1; }
fi
app="${DAYSIDE_DEBUG_APP:-${MEANTIME_DEBUG_APP:-}}"
if [[ -z "$app" ]]; then
  products="$(xcodebuild -project TahoeTime.xcodeproj -scheme TahoeTime -configuration Debug ${build_args[@]+"${build_args[@]}"} -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR = /{print $3; exit}')"
  app="$products/Dayside.app"
fi
[[ -d "$app" ]] || { echo "没有 Debug 产物：$app" >&2; exit 1; }
copy="$out/Dayside.app"; "$root/Tools/trash.sh" "$copy"; ditto "$app" "$copy"
# 测试包也是副本产物，直接删除，不挪进废纸篓。
python3 - "$copy" <<'TEST_BUNDLES'
import pathlib
import shutil
import sys

for bundle in (pathlib.Path(sys.argv[1]) / "Contents" / "PlugIns").glob("*.xctest"):
    if bundle.is_symlink() or bundle.is_file():
        bundle.unlink()
    else:
        shutil.rmtree(bundle)
TEST_BUNDLES
# 原生窗口自动保存写标准域，副本使用独立标识以隔离安装版。
audit_id="com.dayside.Dayside.audit.$(/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]')"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $audit_id" "$copy/Contents/Info.plist"
ent="$out/debug-no-group.entitlements"; cp "$root/TahoeTime/TahoeTime-signing-Debug.entitlements" "$ent"
sign() { /usr/bin/codesign --force --sign - --timestamp=none "$@" 2>/dev/null; }
for dylib in "$copy"/Contents/MacOS/*.dylib; do [[ -e "$dylib" ]] && sign "$dylib"; done
for framework in "$copy"/Contents/Frameworks/*.framework; do [[ -e "$framework" ]] && sign "$framework"; done
for appex in "$copy"/Contents/PlugIns/*.appex; do
  [[ -e "$appex" ]] || continue
  for dylib in "$appex"/Contents/MacOS/*.dylib; do [[ -e "$dylib" ]] && sign "$dylib"; done
  name="$(basename "$appex" .appex)"
  sign --entitlements "$root/$name/Extension.entitlements" "$appex"
done
sign --entitlements "$ent" "$copy"
/usr/bin/codesign --verify --deep --strict "$copy"
echo "$copy"
