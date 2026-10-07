#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# 所有签名策略都禁止网络权限。
set -euo pipefail
cd "$(dirname "$0")/.."
exec /usr/bin/python3 - <<'CHECK'
import pathlib, plistlib, sys
paths = sorted(pathlib.Path("TahoeTime").glob("*.entitlements"))
problems = []
for path in paths:
    with path.open("rb") as stream:
        values = plistlib.load(stream)
    offenders = [key for key in values if key.startswith("com.apple.security.network")]
    if offenders:
        problems.append("不该有网络权限：%s（%s）" % (path, "、".join(offenders)))
if problems:
    print("\n".join(problems), file=sys.stderr)
    sys.exit(1)
print("签名策略检查通过：%d 份策略，0 条网络权限" % len(paths))
CHECK
