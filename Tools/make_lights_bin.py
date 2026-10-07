#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""地球窗的城市灯火数据：只有人口足够多的城市在夜里亮灯。

资格：人口 ≥ 111 万才亮；欧洲（GeoNames countryInfo 的洲码 EU）与同样没有超级大都市的发达国家加拿大、澳大利亚、新西兰
降到 ≥ 100 万（酌情的口径写死在 LOWERED 里，改名单只改这一处）。亮度分三档，上两档按联合国《世界城市化展望》的规模线：
门槛–500 万、500–1000 万、≥ 1000 万（超大城市），越大的点越大越亮。人口取 GeoNames cities500 的 population 列（与城市索引同一份转储，CC BY 4.0，已在帮助页与
ThirdPartyNotices 署名）。按人口从大到小，离已收的任何一座都在 0.6° 以外才收（同一片都会区只点一盏）。

用法: Tools/make_lights_bin.py <cities500.txt> <countryInfo.txt> <输出 .bin>
格式（小端）：u16 点数；每点 i16 经度×100、i16 纬度×100、u8 档（1 = 门槛–500 万、2 = 500–1000 万、3 = ≥ 1000 万）。
来源：https://download.geonames.org/export/dump/cities500.zip
"""
import struct, sys

src, countries, out = sys.argv[1], sys.argv[2], sys.argv[3]
THRESHOLD, LOWERED_THRESHOLD = 1_110_000, 1_000_000
# 欧洲整洲 + 加拿大、澳大利亚、新西兰：发达、但没有千万级的超级大都市，百万城市就是当地最亮的灯。
LOWERED_EXTRA = {"CA", "AU", "NZ"}
continent = {}
with open(countries, encoding="utf-8") as f:
    for line in f:
        if not line.startswith("#") and line.strip():
            c = line.split("\t")
            continent[c[0]] = c[8]
lowered = {cc for cc, ct in continent.items() if ct == "EU"} | LOWERED_EXTRA
rows = []
with open(src, encoding="utf-8") as f:
    for line in f:
        c = line.rstrip("\n").split("\t")
        try:
            pop = int(c[14] or 0)
        except ValueError:
            continue
        if pop >= (LOWERED_THRESHOLD if c[8] in lowered else THRESHOLD):
            rows.append((pop, float(c[5]), float(c[4])))
rows.sort(key=lambda r: -r[0])
kept = []
for pop, lon, lat in rows:
    near = any(abs(k[2] - lat) < 0.6 and min(abs(k[1] - lon), 360 - abs(k[1] - lon)) < 0.6 for k in kept)
    if not near:
        kept.append((pop, lon, lat))
tier = lambda p: 3 if p >= 10_000_000 else 2 if p >= 5_000_000 else 1
blob = struct.pack("<H", len(kept))
for pop, lon, lat in kept:
    blob += struct.pack("<hhB", round(lon * 100), round(lat * 100), tier(pop))
open(out, "wb").write(blob)
counts = [sum(1 for k in kept if tier(k[0]) == t) for t in (1, 2, 3)]
print(f"{len(kept)} 盏（门槛–500 万 {counts[0]}、500–1000 万 {counts[1]}、≥ 1000 万 {counts[2]}），{len(blob)} 字节 → {out}")
