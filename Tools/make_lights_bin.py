#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""地球窗的城市灯火数据：只有人口足够多的都会区在夜里亮灯。

人口按都会区算：从人口最多的城市往下，每座 ≥ 10 万的城市把方圆 30 公里内还没算进别处的城镇连同自己加起来（GeoNames 的
城区 PPLX 与历史、废弃的地点不算）。只看市区人口时美国的大都会大多不亮：亚特兰大市区只有 51 万，连成一片的周边城镇都在
市界以外，美国只亮 8 盏，比墨西哥还少。
资格：合计 ≥ 111 万才亮；欧洲（GeoNames countryInfo 的洲码 EU）与同样没有超级大都市的发达国家加拿大、澳大利亚、新西兰
降到 ≥ 100 万（酌情的口径写死在 LOWERED 里，改名单只改这一处）。亮度分三档，按城市自己的人口，上两档按联合国《世界城市化
展望》的规模线：门槛–500 万、500–1000 万、≥ 1000 万（超大城市），越大的点越大越亮。人口取 GeoNames cities500 的 population 列
（CC BY 4.0，已在帮助页与 ThirdPartyNotices 署名）。按合计人口从大到小，离已收的任何一座都在 0.6° 以外才收（同一片都会区只点一盏）。

用法: Tools/make_lights_bin.py <cities500.txt> <countryInfo.txt> <输出 .bin>
格式（小端）：u16 点数；每点 i16 经度×100、i16 纬度×100、u8 档（1 = 门槛–500 万、2 = 500–1000 万、3 = ≥ 1000 万），按城市人口从大到小。
来源：https://download.geonames.org/export/dump/cities500.zip
"""
import math, struct, sys
from collections import defaultdict

src, countries, out = sys.argv[1], sys.argv[2], sys.argv[3]
THRESHOLD, LOWERED_THRESHOLD = 1_110_000, 1_000_000
RADIUS_KM, CENTER_MIN, PLACE_MIN = 30.0, 100_000, 1_000
# 城区是所属城市的一部分，历史、废弃、毁掉的地点没人住：都不算人口。
SKIP = {"PPLX", "PPLH", "PPLQ", "PPLW", "PPLCH"}
# 欧洲整洲 + 加拿大、澳大利亚、新西兰：发达、但没有千万级的超级大都市，百万城市就是当地最亮的灯。
LOWERED_EXTRA = {"CA", "AU", "NZ"}
continent = {}
with open(countries, encoding="utf-8") as f:
    for line in f:
        if not line.startswith("#") and line.strip():
            c = line.split("\t")
            continent[c[0]] = c[8]
lowered = {cc for cc, ct in continent.items() if ct == "EU"} | LOWERED_EXTRA
places = []
with open(src, encoding="utf-8") as f:
    for line in f:
        c = line.rstrip("\n").split("\t")
        try:
            pop = int(c[14] or 0)
        except ValueError:
            continue
        if c[7] not in SKIP and pop >= PLACE_MIN:
            places.append((pop, float(c[5]), float(c[4]), c[8]))
places.sort(key=lambda p: -p[0])
grid = defaultdict(list)
for i, (_, lon, lat, _) in enumerate(places):
    grid[(math.floor(lat), math.floor(lon))].append(i)
counted = [False] * len(places)
rows = []
for i, (pop, lon, lat, cc) in enumerate(places):
    if counted[i] or pop < CENTER_MIN:
        continue
    total, cos_lat = 0, math.cos(math.radians(lat))
    dlat, dlon = RADIUS_KM / 111.0, RADIUS_KM / (111.0 * max(0.2, cos_lat))
    for gy in range(math.floor(lat - dlat), math.floor(lat + dlat) + 1):
        for gx in range(math.floor(lon - dlon), math.floor(lon + dlon) + 1):
            for j in grid.get((gy, (gx + 180) % 360 - 180), []):
                if counted[j]:
                    continue
                dy, dx = (places[j][2] - lat) * 111.0, (places[j][1] - lon) * 111.0 * cos_lat
                if dx * dx + dy * dy <= RADIUS_KM * RADIUS_KM:
                    counted[j] = True
                    total += places[j][0]
    if total >= (LOWERED_THRESHOLD if cc in lowered else THRESHOLD):
        rows.append((total, pop, lon, lat))
rows.sort(key=lambda r: -r[0])
kept = []
for total, pop, lon, lat in rows:
    near = any(abs(k[3] - lat) < 0.6 and min(abs(k[2] - lon), 360 - abs(k[2] - lon)) < 0.6 for k in kept)
    if not near:
        kept.append((total, pop, lon, lat))
kept.sort(key=lambda k: -k[1])
tier = lambda p: 3 if p >= 10_000_000 else 2 if p >= 5_000_000 else 1
blob = struct.pack("<H", len(kept))
for _, pop, lon, lat in kept:
    blob += struct.pack("<hhB", round(lon * 100), round(lat * 100), tier(pop))
open(out, "wb").write(blob)
counts = [sum(1 for k in kept if tier(k[1]) == t) for t in (1, 2, 3)]
print(f"{len(kept)} 盏（门槛–500 万 {counts[0]}、500–1000 万 {counts[1]}、≥ 1000 万 {counts[2]}），{len(blob)} 字节 → {out}")
