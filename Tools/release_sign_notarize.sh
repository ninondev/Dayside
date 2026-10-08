#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# 正式发布：把一个已完成的 Release 版 Dayside.app 用 Developer ID 重签，打 DMG，给 DMG 签名，公证，staple，Gatekeeper 评估。
# 用法：Tools/release_sign_notarize.sh <Release 版 Dayside.app> <arm64|x86_64> [--profile <notarytool 钥匙串配置名>] [--out <目录>] [--dry-run]
#   签名身份取 MEANTIME_SIGN_IDENTITY，形如 "Developer ID Application: <名字> (<TEAMID>)"（`security find-identity -v -p codesigning` 里那一行）。
#   公证凭据只从登录钥匙串读：先由开发者本人运行
#     xcrun notarytool store-credentials dayside-notary --apple-id <Apple ID> --team-id <TEAMID>
#   （App 专用密码在提示里输入；本脚本不接收、不打印、不保存任何密码）。默认配置名 dayside-notary。
#   产物：<目录>/Dayside-<版本>-<架构>.dmg 与 .sha256、.validation.json、.release.json；任一步失败即非零退出，已有文件不覆盖。
#   --dry-run 只检查参数并按顺序打印将要执行的命令（不需要 macOS），用来在别的机器上核对流程。
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app="" arch="" profile="dayside-notary" out_dir="$root" dry_run=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) profile="${2:?--profile 需要配置名}"; shift 2 ;;
    --out) out_dir="${2:?--out 需要目录}"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    -*) echo "未知选项：$1" >&2; exit 2 ;;
    *) if [[ -z "$app" ]]; then app="$1"; elif [[ -z "$arch" ]]; then arch="$1"; else echo "多余参数：$1" >&2; exit 2; fi; shift ;;
  esac
done
[[ -n "$app" && -n "$arch" ]] || { echo "用法：Tools/release_sign_notarize.sh <Dayside.app> <arm64|x86_64> [--profile 名] [--out 目录] [--dry-run]" >&2; exit 2; }
[[ "$arch" == arm64 || "$arch" == x86_64 ]] || { echo "架构只能是 arm64 或 x86_64：$arch" >&2; exit 2; }
[[ -d "$app/Contents" && -f "$app/Contents/Info.plist" ]] || { echo "不是应用包：$app" >&2; exit 1; }
identity="${MEANTIME_SIGN_IDENTITY:-}"
[[ "$identity" =~ ^Developer\ ID\ Application:\ .+\ \(([A-Z0-9]{10})\)$ ]] \
  || { echo "MEANTIME_SIGN_IDENTITY 必须是 \"Developer ID Application: <名字> (<TEAMID>)\"" >&2; exit 1; }
team="${BASH_REMATCH[1]}"
[[ "$profile" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "钥匙串配置名只能含字母、数字、点、下划线和连字符：$profile" >&2; exit 2; }
version=$(/usr/bin/python3 -c 'import plistlib,sys; print(plistlib.load(open(sys.argv[1],"rb"))["CFBundleShortVersionString"])' "$app/Contents/Info.plist")
[[ "$version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || { echo "CFBundleShortVersionString 不是发布版本号：$version" >&2; exit 1; }
readme="$root/Tools/dmg/ReadMe-$arch.txt"
[[ -f "$readme" ]] || { echo "缺 ReadMe：$readme" >&2; exit 1; }
dmg="$out_dir/Dayside-$version-$arch.dmg"
for path in "$dmg" "$dmg.sha256" "$dmg.validation.json" "$dmg.release.json"; do
  [[ ! -e "$path" ]] || { echo "已存在，不覆盖：$path" >&2; exit 1; }
done
log_dir="$out_dir/Dayside-$version-$arch.release-logs"

run() {
  if [[ $dry_run == 1 ]]; then printf 'DRY-RUN:'; printf ' %q' "$@"; printf '\n'; else "$@"; fi
}

echo "== 版本 $version，架构 $arch，团队 $team，公证配置 $profile"
run mkdir -p "$log_dir"

echo "== 1. Developer ID 重签（hardened runtime + 安全时间戳 + Release 签名策略）"
run env CONFIGURATION=Release MEANTIME_SIGN_IDENTITY="$identity" "$root/Tools/sign_bundle.sh" "$app"

echo "== 2. 验签与发布身份检查"
run /usr/bin/codesign --verify --deep --strict --verbose=2 "$app"
if [[ $dry_run == 0 ]]; then
  details=$(/usr/bin/codesign -dvvv "$app" 2>&1)
  printf '%s\n' "$details" > "$log_dir/codesign-app.txt"
  grep -q "^TeamIdentifier=$team\$" <<<"$details" || { echo "签名团队不是 $team" >&2; exit 1; }
  grep -q "^Authority=Developer ID Application: " <<<"$details" || { echo "签名机构不是 Developer ID Application" >&2; exit 1; }
  grep -Eq "^CodeDirectory .*flags=0x[0-9a-f]*\(.*runtime.*\)" <<<"$details" || { echo "没有 hardened runtime 标志" >&2; exit 1; }
  grep -q "^Timestamp=" <<<"$details" || { echo "没有安全时间戳" >&2; exit 1; }
else
  echo "DRY-RUN: codesign -dvvv 检查 TeamIdentifier=$team、Developer ID Application、runtime 标志与 Timestamp"
fi
run /usr/bin/python3 "$root/Tools/check_release_identity.py" "$app" --asset-name "$(basename "$dmg")"

echo "== 3. 打 DMG（逐文件对照、严格验签）并给 DMG 签名"
run "$root/Tools/make_dmg.sh" "$app" "$dmg" "$readme" Dayside
run /usr/bin/codesign --force --sign "$identity" --timestamp "$dmg"
run /usr/bin/codesign --verify --strict --verbose=2 "$dmg"

echo "== 4. 公证（等待结果）"
if [[ $dry_run == 0 ]]; then
  # 被拒时 notarytool 也可能非零退出：先留下结果和日志，再按状态判断。
  /usr/bin/xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait --output-format json > "$log_dir/notary-submit.json" || true
  submission=$(/usr/bin/python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("id",""), d.get("status",""))' "$log_dir/notary-submit.json")
  id=${submission%% *}; status=${submission#* }
  [[ -n "$id" ]] && /usr/bin/xcrun notarytool log "$id" --keychain-profile "$profile" "$log_dir/notary-log.json" || true
  [[ "$status" == Accepted ]] || { echo "公证未通过：$status（详情 $log_dir/notary-log.json）" >&2; exit 1; }
else
  run /usr/bin/xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait --output-format json
  echo "DRY-RUN: 状态必须是 Accepted；随后取 notarytool log 存到 $log_dir/notary-log.json"
fi

echo "== 5. staple 与 Gatekeeper 评估"
run /usr/bin/xcrun stapler staple "$dmg"
run /usr/bin/xcrun stapler validate "$dmg"
run /usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
if [[ $dry_run == 0 ]]; then
  mount=$(mktemp -d "${TMPDIR:-/tmp}/dayside-release-mount.XXXXXX")
  trap '/usr/bin/hdiutil detach "$mount" >/dev/null 2>&1 || true; rmdir "$mount" 2>/dev/null || true' EXIT
  /usr/bin/hdiutil attach -readonly -nobrowse -mountpoint "$mount" "$dmg" >/dev/null
  assessment=$(/usr/sbin/spctl --assess --type execute --verbose=2 "$mount/$(basename "$app")" 2>&1)
  printf '%s\n' "$assessment" > "$log_dir/spctl-app.txt"
  grep -q "source=Notarized Developer ID" <<<"$assessment" || { echo "Gatekeeper 没有认出公证：$assessment" >&2; exit 1; }
  /usr/bin/hdiutil detach "$mount" >/dev/null
else
  echo "DRY-RUN: 挂载 DMG，spctl 评估其中的 app 必须是 source=Notarized Developer ID"
fi

echo "== 6. 重写校验和（签名与 staple 改了 DMG 字节）"
if [[ $dry_run == 0 ]]; then
  /usr/bin/python3 - "$dmg" "$team" "$version" "$arch" <<'PY'
import hashlib, json, os, sys
dmg, team, version, arch = sys.argv[1:5]
sha = hashlib.sha256(open(dmg, "rb").read()).hexdigest()
open(dmg + ".sha256", "w").write(f"{sha}  {os.path.basename(dmg)}\n")
validation = json.load(open(dmg + ".validation.json"))
validation.update(sha256=sha, bytes=os.path.getsize(dmg))
json.dump(validation, open(dmg + ".validation.json", "w"), ensure_ascii=False, indent=1)
record = {"dmg": os.path.abspath(dmg), "sha256": sha, "bytes": os.path.getsize(dmg), "version": version, "arch": arch,
          "teamIdentifier": team, "developerIDSigned": True, "notarized": True, "stapled": True, "gatekeeper": "Notarized Developer ID"}
json.dump(record, open(dmg + ".release.json", "w"), ensure_ascii=False, indent=1)
print(json.dumps(record, ensure_ascii=False))
PY
else
  echo "DRY-RUN: 重算 $dmg.sha256，更新 .validation.json 的 sha256/bytes，写 .release.json"
fi
echo "== 完成：$dmg"
