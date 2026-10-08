#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# 用法:Tools/make_dmg.sh <Dayside*.app> <out.dmg> <ReadMe.txt> [卷名]
# 把一个已签名的 .app 连同 LICENSE、COPYING、THIRD_PARTY_NOTICES.md、应用内的 ThirdPartyNotices.txt、ReadMe 和 Applications 链接
# 打成 LZMA(ULMO)/APFS 只读 DMG,然后 hdiutil verify、只读挂载、逐文件 SHA-256 对照源 app、严格验签,
# 把结果写到 <out.dmg>.sha256 与 <out.dmg>.validation.json;任一步失败即非零退出。不覆盖已存在的 DMG。
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP=$1; OUT=$2; README=$3; VOL=${4:-Dayside}
[ -d "$APP/Contents" ] || { echo "不是应用包: $APP" >&2; exit 1; }
[ -f "$README" ] || { echo "缺 ReadMe: $README" >&2; exit 1; }
[ ! -e "$OUT" ] || { echo "已存在,不覆盖: $OUT" >&2; exit 1; }
case "$(basename "$OUT")" in
  Dayside-All-tools-local-preview-*.dmg) ;;
  *)
    python3 "$ROOT/Tools/check_release_identity.py" "$APP" --asset-name "$(basename "$OUT")"
    ;;
esac
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/dayside-dmg-stage.XXXXXX")
MNT=$(mktemp -d "${TMPDIR:-/tmp}/dayside-dmg-mount.XXXXXX")
trap 'hdiutil detach "$MNT" >/dev/null 2>&1 || true; "$ROOT/Tools/trash.sh" "$STAGE"; "$ROOT/Tools/trash.sh" "$MNT" 2>/dev/null || true' EXIT
ditto "$APP" "$STAGE/$(basename "$APP")"
cp "$ROOT/LICENSE" "$ROOT/COPYING" "$ROOT/THIRD_PARTY_NOTICES.md" "$STAGE/"
cp "$APP/Contents/Resources/ThirdPartyNotices.txt" "$STAGE/ThirdPartyNotices.txt"
cp "$README" "$STAGE/ReadMe.txt"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -fs APFS -format ULMO -ov "$OUT" >/dev/null
hdiutil verify "$OUT" >/dev/null
hdiutil attach -readonly -nobrowse -mountpoint "$MNT" "$OUT" >/dev/null
/usr/bin/python3 - "$MNT/$(basename "$APP")" "$APP" "$OUT" <<'PY'
import sys, os, hashlib, json, subprocess
mounted, source, dmg = sys.argv[1:4]
def digests(root):
    out = {}
    for dp, _, files in os.walk(root):
        for f in files:
            p = os.path.join(dp, f); rel = os.path.relpath(p, root)
            out[rel] = 'symlink:' + os.readlink(p) if os.path.islink(p) else hashlib.sha256(open(p, 'rb').read()).hexdigest()
    return out
a, b = digests(mounted), digests(source)
strict = subprocess.run(['codesign', '--verify', '--deep', '--strict', mounted], capture_output=True, text=True).returncode == 0
sha = hashlib.sha256(open(dmg, 'rb').read()).hexdigest()
rec = {'path': os.path.abspath(dmg), 'bytes': os.path.getsize(dmg), 'sha256': sha, 'format': 'ULMO (LZMA), APFS',
       'mountedFilesCompared': len(a), 'mountedFilesEqualSourceBundle': a == b, 'strictSignature': strict,
       'applicationsLink': os.path.islink(os.path.join(os.path.dirname(mounted), 'Applications'))}
json.dump(rec, open(dmg + '.validation.json', 'w'), ensure_ascii=False, indent=1)
open(dmg + '.sha256', 'w').write(f'{sha}  {os.path.basename(dmg)}\n')
print(json.dumps(rec, ensure_ascii=False))
ok = a == b and strict and rec['applicationsLink']
sys.exit(0 if ok else 1)
PY
