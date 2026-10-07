#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""国家 → 时区表（「听懂时间」把「9am in Brazil」读成国家时用；按人口前八座城凑时区会漏，
印尼只剩雅加达、美国少了山地 / 阿拉斯加 / 夏威夷）。

读 tz 数据库的 zone.tab（macOS 自带 /usr/share/zoneinfo/zone.tab），每个国家一行：
`国家码 \t 时区,时区,…`（保持 zone.tab 里的顺序），写到 RustCore/data/country_zones.tsv。
同一个国家里走同样钟的几个标识由宿主按系统规则合并。

用法：python3 Tools/make_country_zones.py [zone.tab 路径]
"""
import sys
from collections import OrderedDict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
source = Path(sys.argv[1] if len(sys.argv) > 1 else "/usr/share/zoneinfo/zone.tab")
version_file = source.parent / "+VERSION"
zones: "OrderedDict[str, list[str]]" = OrderedDict()
for line in source.read_text().splitlines():
    if not line or line.startswith("#"):
        continue
    code, _coordinates, zone, *_ = line.split("\t")
    zones.setdefault(code, []).append(zone)
version = version_file.read_text().strip() if version_file.exists() else "?"
out = ROOT / "RustCore/data/country_zones.tsv"
lines = [f"# 由 Tools/make_country_zones.py 从 tz {version} 的 zone.tab 生成，不要手改"]
lines += [f"{code}\t{','.join(zs)}" for code, zs in sorted(zones.items())]
out.write_text("\n".join(lines) + "\n")
print(f"{out.relative_to(ROOT)}：{len(zones)} 个国家，{sum(len(z) for z in zones.values())} 个时区（tz {version}）")
