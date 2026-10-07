#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""按 GeoNames ID 取 Wikidata 的各语言标签。

fetch：把 ID 列表按批（默认 300）送 SPARQL，取每个 GeoNames ID 挂着的全部条目、其站点链接数、
英文标签与目标语言标签，逐批追加成 JSONL（可续跑：已跑完的批按序号跳过）。
resolve：同一个 GeoNames ID 会挂在多个条目上（上海的 ID 也挂在一家医院上、北京的挂在「顺天府」上），
按「英文标签折叠后等于 GeoNames 主名或 ASCII 名」优先、其次站点链接数最多选一个条目，输出
`geonameid\tlang\tlabel` 的 TSV，语言码已归一到索引的九个槽位（zh-hans / zh-cn → zh-Hans，zh-hant / zh-tw / zh-hk → zh-Hant，
裸 zh 按字形归到简繁，pt / pt-br → pt-BR）。

用法：
  wikidata_labels.py fetch  <ids.tsv> <out.jsonl>        # ids.tsv 每行「geonameid\tname\tasciiname」
  wikidata_labels.py resolve <ids.tsv> <in.jsonl> <out.tsv>
  wikidata_labels.py nearby  <targets.tsv> <out.jsonl>      # 第二遍：按名字搜 + 30 km 坐标核（targets 每行多 lat、lon 两列）
  WIKIDATA_LANGS=it,nl wikidata_labels.py relabel <fetch.jsonl> <relabel.jsonl>   # 按已有对照用 wbgetentities 补新语言（2026-09-24）
  wikidata_labels.py merge-relabel <fetch.jsonl> <relabel.jsonl> <merged.jsonl>
  WIKIDATA_LANGS=it,nl wikidata_labels.py confirm <ids.tsv> <fetch.jsonl> <alternateNamesV2.txt> <out.tsv>   # 2026-09-27
"""
import json, sys, time, unicodedata, urllib.error, urllib.parse, urllib.request

ENDPOINT = "https://query.wikidata.org/sparql"
UA = "Dayside-index-builder/1.0 (https://github.com/dayside; index build only)"
LANGS = ["zh", "zh-hans", "zh-hant", "zh-cn", "zh-tw", "zh-hk", "ja", "ko", "ru", "de", "es", "fr", "pt", "pt-br", "en"]
# `WIKIDATA_LANGS=it,nl,pl,tr,vi,id` 只抓这几种；英文标签总是一起抓，strong / weak 靠它判。
if __import__("os").environ.get("WIKIDATA_LANGS"):
    LANGS = [l.strip() for l in __import__("os").environ["WIKIDATA_LANGS"].split(",") if l.strip()] + ["en"]
BATCH = 200


def read_ids(path):
    rows = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            p = line.rstrip("\n").split("\t")
            if len(p) >= 3:
                rows.append((p[0], p[1], p[2]))
    return rows


def query(ids):
    """一批 ID 的全部标签行。SPARQL 服务在响应约 139 KB 处会把 JSON 截断（HTTP 200、正文不完整，
    admin1 第 4 批稳定复现），所以解析失败就把批一分为二再查，直到 25 条；网络错误才原地退避重试。"""
    values = " ".join('"%s"' % i for i in ids)
    langs = ",".join('"%s"' % l for l in LANGS)
    q = ("SELECT ?gn ?item ?sitelinks ?label WHERE { VALUES ?gn { %s } ?item wdt:P1566 ?gn . "
         "OPTIONAL { ?item wikibase:sitelinks ?sitelinks } ?item rdfs:label ?label . FILTER(LANG(?label) IN (%s)) }") % (values, langs)
    req = urllib.request.Request(ENDPOINT + "?" + urllib.parse.urlencode({"query": q, "format": "json"}),
                                 headers={"User-Agent": UA, "Accept": "application/sparql-results+json"})
    for attempt in range(6):
        try:
            with urllib.request.urlopen(req, timeout=180) as r:
                raw = r.read()
            try:
                return json.loads(raw)["results"]["bindings"]
            except ValueError:
                if len(ids) <= 25:
                    raise
                half = len(ids) // 2
                print(f"  truncated response for {len(ids)} ids; splitting", file=sys.stderr)
                return query(ids[:half]) + query(ids[half:])
        except ValueError:
            raise
        except Exception as e:  # 429 / 5xx / 超时：退避重试
            wait = 10 * (attempt + 1)
            print(f"  batch failed ({e}); retry in {wait}s", file=sys.stderr)
            time.sleep(wait)
    raise SystemExit("Wikidata query kept failing")


def fetch(ids_path, out_path):
    rows = read_ids(ids_path)
    done = set()
    try:
        with open(out_path, encoding="utf-8") as f:
            for line in f:
                done.add(json.loads(line)["batch"])
    except FileNotFoundError:
        pass
    batches = [rows[i:i + BATCH] for i in range(0, len(rows), BATCH)]
    print(f"{len(rows)} ids, {len(batches)} batches, {len(done)} done", file=sys.stderr)
    with open(out_path, "a", encoding="utf-8") as out:
        for n, batch in enumerate(batches):
            if n in done:
                continue
            t = time.time()
            res = query([r[0] for r in batch])
            items = {}
            for b in res:
                gn = b["gn"]["value"]
                item = b["item"]["value"].rsplit("/", 1)[-1]
                entry = items.setdefault((gn, item), {"gn": gn, "item": item, "sitelinks": int(b.get("sitelinks", {}).get("value", 0)), "labels": {}})
                entry["labels"][b["label"]["xml:lang"]] = b["label"]["value"]
            out.write(json.dumps({"batch": n, "items": list(items.values())}, ensure_ascii=False) + "\n")
            out.flush()
            print(f"batch {n + 1}/{len(batches)}: {len(res)} labels, {time.time() - t:.1f}s", file=sys.stderr)
            time.sleep(0.5)


def fold(s):
    s = unicodedata.normalize("NFKD", s)
    return "".join(c for c in s if not unicodedata.combining(c)).casefold().replace("-", " ").replace("’", "'").strip()


LATIN_SLOTS = {"de", "es", "fr", "pt-BR", "it", "nl", "pl", "tr", "vi", "id"}


GENERIC_SUFFIXES = (" si", " gun", " gu", " shi", " city", " district", " county", " municipality", " ville")


def variants(s):
    """折叠形与去掉一个行政通名后缀的形：GeoNames 写「Seongnam-si」「Cebu City」，Wikidata 英文标签是「Seongnam」「Cebu」。"""
    f = fold(s)
    out = {f} if f else set()
    for suffix in GENERIC_SUFFIXES:
        if f.endswith(suffix) and len(f) > len(suffix) + 1:
            out.add(f[:-len(suffix)].strip())
    return out


def good(it):
    """像一座真城市的条目：至少两个站点链接，或我们九语里有三种以上的标签。P1566 常挂在 0–1 个站点链接的
    导入残条目上（Makassar、Guarulhos、Seongnam 各有一个只有英文标签的重复条目），它们只会挡住第二遍。"""
    return it["sitelinks"] >= 2 or sum(1 for k in it["labels"] if k != "en") >= 3


def best_item(items, name, ascii_name):
    """同一个 GeoNames ID 挂着的几个条目里挑一个：（是否 strong, 站点链接数）最大的；返回（条目, 是否 strong）。"""
    wanted = variants(name) | variants(ascii_name)

    def score(it):
        en = it["labels"].get("en", "")
        same = sum(1 for v in it["labels"].values() if name and v == name)
        strong = (en and variants(en) & wanted) or (not en and same >= 1)
        return (1 if strong else 0, it["sitelinks"])
    best = max(items, key=score)
    return best, score(best)[0] == 1


SLOT_OF = {"it": "it", "nl": "nl", "pl": "pl", "tr": "tr", "vi": "vi", "id": "id", "de": "de", "es": "es", "fr": "fr",
           "ja": "ja", "ko": "ko", "ru": "ru"}


def confirm(ids_path, in_path, alternates_path, out_path):
    """「确认」行：条目是 strong、它在某种语言的标签逐字等于 GeoNames 主名，说明这种语言就这么写
    （维基百科该语言的条目名）；GeoNames 别名表里这种语言却另有一个名字（常是去掉变音符号的「Kirikkale」「Bac Ninh」，
    或意译「Hổ phách」、撞名「Pekin」）。输出 `geonameid\tlang\tlabel\tsame`，只输出别名表里真有别的名字的那些
    （其余的不影响结果，白占字节）；生成器「加语言」时，有确认的城市不让别名表改名。语言按 WIKIDATA_LANGS。"""
    langs = [l for l in LANGS if l != "en" and l in SLOT_OF]
    names = {r[0]: (r[1], r[2]) for r in read_ids(ids_path)}
    by_gn = {}
    with open(in_path, encoding="utf-8") as f:
        for line in f:
            for it in json.loads(line)["items"]:
                by_gn.setdefault(it["gn"], []).append(it)
    confirmed = {}
    for gn, items in by_gn.items():
        name, ascii_name = names.get(gn, ("", ""))
        best, strong = best_item(items, name, ascii_name)
        if not strong or not name:
            continue
        for lang in langs:
            if best["labels"].get(lang) == name:
                confirmed[(gn, lang)] = name
    rival = set()
    with open(alternates_path, encoding="utf-8") as f:
        for line in f:
            p = line.rstrip("\n").split("\t")
            if len(p) < 4 or (p[1], p[2]) not in confirmed:
                continue
            if (len(p) > 6 and p[6] == "1") or (len(p) > 7 and p[7] == "1"):
                continue   # 口语名、历史名：生成器本来就不收
            if p[3] != confirmed[(p[1], p[2])]:
                rival.add((p[1], p[2]))
    with open(out_path, "w", encoding="utf-8") as out:
        out.write("# geonameid\tlang\tlabel\tstrength\n")
        for gn, lang in sorted(rival, key=lambda k: (int(k[0]), k[1])):
            out.write(f"{gn}\t{SLOT_OF[lang]}\t{confirmed[(gn, lang)]}\tsame\n")
    print(f"{len(confirmed)} confirmations, {len(rival)} with a rival GeoNames name", file=sys.stderr)


def resolve(ids_path, in_path, out_path):
    """输出 `geonameid\tlang\tlabel\tstrength`。strength：strong = 条目的英文标签折叠后等于 GeoNames 主名或 ASCII 名，
    或 GeoNames 主名逐字出现在条目的某个标签里（本地写法）；否则 weak。生成器里 strong 标签压过 GeoNames 的名字，
    weak 只填空缺（同一个 GeoNames ID 挂错条目时，错条目的标签不会盖掉对的名字）。裸 zh 标签不分简繁，一律 weak。
    与 GeoNames 主名 / ASCII 名相同的标签不输出（显示不会变，白占字节）；拉丁语种首字母小写的标签（法语「district de …」）
    改成大写。"""
    names = {r[0]: (r[1], r[2]) for r in read_ids(ids_path)}
    by_gn = {}
    with open(in_path, encoding="utf-8") as f:
        for line in f:
            for it in json.loads(line)["items"]:
                by_gn.setdefault(it["gn"], []).append(it)
    written = strong_ids = 0
    with open(out_path, "w", encoding="utf-8") as out:
        out.write("# geonameid\tlang\tlabel\tstrength\n")
        for gn in sorted(by_gn, key=int):
            items = by_gn[gn]
            name, ascii_name = names.get(gn, ("", ""))
            wanted = variants(name) | variants(ascii_name)

            def score(it):
                # strong：英文标签对得上（允许一边多一个行政通名后缀，Seongnam-si / Seongnam）；没有英文标签时一个别的语言
                # 标签逐字等于主名也算。别的语言恰好等于主名不算（Coro 的世界遗产条目有「Коро」「코로」）。同为 strong 时
                # 站点链接多的赢：P1566 常挂在只有英文标签的残条目上，第二遍按名字找到的真条目要能压过它。
                en = it["labels"].get("en", "")
                same = sum(1 for v in it["labels"].values() if name and v == name)
                strong = (en and variants(en) & wanted) or (not en and same >= 1)
                return (1 if strong else 0, it["sitelinks"])
            items.sort(key=score, reverse=True)
            best = items[0]
            strong = score(best)[0] == 1
            if not strong and (len(items) > 1 or not good(best)):
                continue  # 几个条目抢一个 ID 没有一个像这座城，或只有一个没人链接的残条目（巴马科挂在「财政部大楼」上）：不猜
            strong_ids += strong
            labels = best["labels"]
            out_langs = {}
            # 繁体先取 zh-tw（台湾写法，「杜拜」「聖地牙哥」），再 zh-hant（常是机器从简体转的）、zh-hk。
            for code, slot in [("zh-hans", "zh-Hans"), ("zh-cn", "zh-Hans"), ("zh-tw", "zh-Hant"), ("zh-hant", "zh-Hant"), ("zh-hk", "zh-Hant"),
                               ("ja", "ja"), ("ko", "ko"), ("ru", "ru"), ("de", "de"), ("es", "es"), ("fr", "fr"), ("pt-br", "pt-BR"), ("pt", "pt-BR"),
                               ("it", "it"), ("nl", "nl"), ("pl", "pl"), ("tr", "tr"), ("vi", "vi"), ("id", "id")]:
                if code in labels and slot not in out_langs:
                    out_langs[slot] = (labels[code], strong)
            if "zh" in labels and "zh-Hans" not in out_langs:
                out_langs["zh-Hans"] = (labels["zh"], False)
            for slot, (label, is_strong) in out_langs.items():
                # 方向控制符、零宽字符这类格式字符（韩文标签「‎시에고데아빌라」开头有个 U+200E）去掉。
                label = "".join(c for c in label if unicodedata.category(c) != "Cf").strip()
                # 带括号的标签整条不要（葡文「Bac Giang (cidade)」是消歧后缀；去掉括号又会把「Frankfurt (Oder)」
                # 变成另一座城的「Frankfurt」），只有 GeoNames 主名自己就带括号时才照收。
                if "(" in label and "(" not in name and "(" not in ascii_name:
                    continue
                if not label or label == name or label == ascii_name or "\t" in label or "\n" in label:
                    continue
                if slot in LATIN_SLOTS and label[0].isalpha() and label[0].islower():
                    label = label[0].upper() + label[1:]
                out.write(f"{gn}\t{slot}\t{label}\t{'strong' if is_strong else 'weak'}\n")
                written += 1
    print(f"{written} labels for {len(by_gn)} ids ({strong_ids} strong)", file=sys.stderr)


def nearby(targets_path, out_path):
    """第二遍（没有 P1566 条目的城市）：按英文名搜条目（wbsearchentities），批量取候选的坐标与标签（wbgetentities），
    取离城市 30 km 内最近的一个。输入每行「geonameid\tname\tascii\tlat\tlon」，输出与 fetch 同样的 JSONL（batch 号按行号）。"""
    import math
    rows = []
    with open(targets_path, encoding="utf-8") as f:
        for line in f:
            p = line.rstrip("\n").split("\t")
            if len(p) >= 5:
                rows.append((p[0], p[1], p[2], float(p[3]), float(p[4])))
    done = set()
    try:
        with open(out_path, encoding="utf-8") as f:
            for line in f:
                done.add(json.loads(line)["batch"])
    except FileNotFoundError:
        pass
    api = "https://www.wikidata.org/w/api.php"

    def call(params):
        params = dict(params, format="json")
        req = urllib.request.Request(api + "?" + urllib.parse.urlencode(params), headers={"User-Agent": UA})
        for attempt in range(5):
            try:
                with urllib.request.urlopen(req, timeout=60) as r:
                    return json.load(r)
            except Exception as e:
                time.sleep(5 * (attempt + 1))
                print(f"  api failed ({e})", file=sys.stderr)
        return {}

    def distance_km(a, b, c, d):
        p = math.pi / 180
        h = 0.5 - math.cos((c - a) * p) / 2 + math.cos(a * p) * math.cos(c * p) * (1 - math.cos((d - b) * p)) / 2
        return 12742 * math.asin(math.sqrt(h))
    BATCH_ROWS = 25
    batches = [rows[i:i + BATCH_ROWS] for i in range(0, len(rows), BATCH_ROWS)]
    print(f"{len(rows)} targets, {len(batches)} batches, {len(done)} done", file=sys.stderr)
    with open(out_path, "a", encoding="utf-8") as out:
        for n, batch in enumerate(batches):
            if n in done:
                continue
            t = time.time()
            candidates = {}  # qid -> list of gn
            for gn, name, ascii_name, lat, lon in batch:
                seen = []
                for term in {name, ascii_name}:
                    res = call({"action": "wbsearchentities", "search": term, "language": "en", "type": "item", "limit": 10})
                    seen += [m["id"] for m in res.get("search", [])]
                for qid in dict.fromkeys(seen):
                    candidates.setdefault(qid, []).append(gn)
            entities = {}
            ids = list(candidates)
            for i in range(0, len(ids), 50):
                res = call({"action": "wbgetentities", "ids": "|".join(ids[i:i + 50]), "props": "claims|labels|sitelinks",
                            "languages": "|".join(LANGS)})
                entities.update(res.get("entities", {}))
            items = []
            for gn, name, ascii_name, lat, lon in batch:
                best = None
                for qid, gns in candidates.items():
                    if gn not in gns or qid not in entities:
                        continue
                    ent = entities[qid]
                    coords = ent.get("claims", {}).get("P625", [])
                    if not coords:
                        continue
                    v = coords[0].get("mainsnak", {}).get("datavalue", {}).get("value", {})
                    if "latitude" not in v:
                        continue
                    km = distance_km(lat, lon, v["latitude"], v["longitude"])
                    labels = {k: v["value"] for k, v in ent.get("labels", {}).items()}
                    en = labels.get("en", "")
                    exact = bool(en) and bool(variants(en) & (variants(name) | variants(ascii_name)))
                    sitelinks = len(ent.get("sitelinks", {}))
                    stub = sitelinks < 2 and sum(1 for k in labels if k != "en") < 3
                    # 名字对得上的排最前，其次站点链接多的（30 km 内同名的区 / 镇条目比市条目少得多），最后才是距离
                    # （埼玉的 GeoNames 点离超级竞技场 2.7 km、离市条目更远；望加锡 1.2 km 处有个同名的 7 链接条目）；残条目不要。
                    rank = (0 if exact else 1, -sitelinks, km)
                    if km <= 30 and not stub and (best is None or rank < best[0]):
                        best = (rank, qid, ent, km)
                if best is None:
                    continue
                _, qid, ent, km = best
                labels = {k: v["value"] for k, v in ent.get("labels", {}).items()}
                items.append({"gn": gn, "item": qid, "sitelinks": len(ent.get("sitelinks", {})), "labels": labels, "km": round(km, 1)})
            out.write(json.dumps({"batch": n, "items": items}, ensure_ascii=False) + "\n")
            out.flush()
            print(f"batch {n + 1}/{len(batches)}: {len(items)}/{len(batch)} matched, {time.time() - t:.1f}s", file=sys.stderr)


def nearby_sparql(targets_path, out_path):
    """第二遍的 SPARQL 版（API 版五路并发会被 429）：一批 120 座城，把主名 / ASCII 名 / 去掉通名后缀的写法（保留大小写）
    作为英文标签或别名精确匹配，条目带坐标且离城 30 km 内；候选按（站点链接数多、距离近）取一个。输出与 fetch 同样的 JSONL。"""
    import math
    rows = []
    with open(targets_path, encoding="utf-8") as f:
        for line in f:
            p = line.rstrip("\n").split("\t")
            if len(p) >= 5:
                rows.append((p[0], p[1], p[2], float(p[3]), float(p[4])))
    done = set()
    try:
        with open(out_path, encoding="utf-8") as f:
            for line in f:
                done.add(json.loads(line)["batch"])
    except FileNotFoundError:
        pass

    def cased_variants(name):
        out = {name}
        for suffix in (" City", " city", "-si", "-gun", "-gu", "-shi", " District", " County", " Municipality"):
            if name.endswith(suffix) and len(name) > len(suffix) + 1:
                out.add(name[:-len(suffix)].strip())
        return {v for v in out if v and '"' not in v and "\\" not in v}

    def distance_km(a, b, c, d):
        p = math.pi / 180
        h = 0.5 - math.cos((c - a) * p) / 2 + math.cos(a * p) * math.cos(c * p) * (1 - math.cos((d - b) * p)) / 2
        return 12742 * math.asin(math.sqrt(h))
    BATCH_ROWS = 80
    batches = [rows[i:i + BATCH_ROWS] for i in range(0, len(rows), BATCH_ROWS)]
    print(f"{len(rows)} targets, {len(batches)} batches, {len(done)} done", file=sys.stderr)
    langs = ",".join('"%s"' % l for l in LANGS)
    with open(out_path, "a", encoding="utf-8") as out:
        for n, batch in enumerate(batches):
            if n in done:
                continue
            t = time.time()
            values = []
            for gn, name, ascii_name, lat, lon in batch:
                for v in cased_variants(name) | cased_variants(ascii_name):
                    values.append('("%s" "%s"@en %.5f %.5f)' % (gn, v, lat, lon))
            q = ("SELECT ?gn ?item ?sitelinks ?coord ?label WHERE { VALUES (?gn ?name ?lat ?lon) { %s } "
                 "?item rdfs:label|skos:altLabel ?name . ?item wdt:P625 ?coord . "
                 "BIND(STRDT(CONCAT(\"Point(\", STR(?lon), \" \", STR(?lat), \")\"), geo:wktLiteral) AS ?center) "
                 "FILTER(geof:distance(?coord, ?center) < 30) "
                 "OPTIONAL { ?item wikibase:sitelinks ?sitelinks } ?item rdfs:label ?label . FILTER(LANG(?label) IN (%s)) }") % (" ".join(values), langs)
            # POST：一批的 VALUES 有几百行，GET 会 414。
            req = urllib.request.Request(ENDPOINT, data=urllib.parse.urlencode({"query": q, "format": "json"}).encode(),
                                         headers={"User-Agent": UA, "Accept": "application/sparql-results+json",
                                                  "Content-Type": "application/x-www-form-urlencoded"})
            res = None
            for attempt in range(6):
                try:
                    with urllib.request.urlopen(req, timeout=300) as r:
                        res = json.loads(r.read())["results"]["bindings"]
                    break
                except urllib.error.HTTPError as e:
                    if e.code != 429 and e.code < 500:
                        raise SystemExit(f"batch {n}: HTTP {e.code} (not retrying)")
                    print(f"  batch {n} failed ({e}); retry", file=sys.stderr)
                    time.sleep(15 * (attempt + 1))
                except Exception as e:
                    print(f"  batch {n} failed ({e}); retry", file=sys.stderr)
                    time.sleep(10 * (attempt + 1))
            if res is None:
                raise SystemExit("SPARQL kept failing")
            centers = {gn: (lat, lon) for gn, _, _, lat, lon in batch}
            cand = {}
            for b in res:
                gn = b["gn"]["value"]
                item = b["item"]["value"].rsplit("/", 1)[-1]
                entry = cand.setdefault((gn, item), {"gn": gn, "item": item, "sitelinks": int(b.get("sitelinks", {}).get("value", 0)), "labels": {}, "coord": b["coord"]["value"]})
                entry["labels"][b["label"]["xml:lang"]] = b["label"]["value"]
            best = {}
            for (gn, item), e in cand.items():
                try:
                    lon, lat = e["coord"].replace("Point(", "").rstrip(")").split()
                    km = distance_km(centers[gn][0], centers[gn][1], float(lat), float(lon))
                except Exception:
                    continue
                stub = e["sitelinks"] < 2 and sum(1 for k in e["labels"] if k != "en") < 3
                if stub:
                    continue
                rank = (-e["sitelinks"], km)
                if gn not in best or rank < best[gn][0]:
                    best[gn] = (rank, {"gn": gn, "item": item, "sitelinks": e["sitelinks"], "labels": e["labels"], "km": round(km, 1)})
            items = [v[1] for v in best.values()]
            out.write(json.dumps({"batch": n, "items": items}, ensure_ascii=False) + "\n")
            out.flush()
            print(f"batch {n + 1}/{len(batches)}: {len(items)}/{len(batch)} matched, {time.time() - t:.1f}s", file=sys.stderr)
            time.sleep(0.5)


def relabel(in_path, out_path, workers=3):
    """按已抓过的「GeoNames ID → 条目」对照（fetch 的 JSONL）补新语言的标签：
    用 `wbgetentities` 每次取 50 个条目号的 `WIKIDATA_LANGS` 标签；原来的英文标签、
    站点链接数原样保留，写成与 fetch 相同格式的 JSONL，resolve 照旧能读。可续跑（已写的批按序号跳过）。"""
    import concurrent.futures, threading
    want = [l for l in LANGS if l != "en"]
    entries = []
    for line in open(in_path, encoding="utf-8"):
        for it in json.loads(line)["items"]:
            entries.append({"gn": it["gn"], "item": it["item"], "sitelinks": it.get("sitelinks", 0),
                            "labels": {k: v for k, v in it.get("labels", {}).items() if k == "en"}})
    items = sorted({e["item"] for e in entries}, key=lambda q: int(q[1:]) if q[1:].isdigit() else 0)
    chunks = [items[i:i + 50] for i in range(0, len(items), 50)]
    done = set()
    try:
        for line in open(out_path, encoding="utf-8"):
            done.add(json.loads(line)["batch"])
    except FileNotFoundError:
        pass
    print(f"{len(entries)} entries, {len(items)} items, {len(chunks)} requests, {len(done)} done", file=sys.stderr)
    lock = threading.Lock()
    out = open(out_path, "a", encoding="utf-8")

    def get(n, chunk):
        chunk = list(chunk)
        for attempt in range(12):
            params = {"action": "wbgetentities", "ids": "|".join(chunk), "props": "labels", "languages": "|".join(want),
                      "format": "json", "maxlag": "5"}
            url = "https://www.wikidata.org/w/api.php?" + urllib.parse.urlencode(params)
            try:
                req = urllib.request.Request(url, headers={"User-Agent": UA})
                with urllib.request.urlopen(req, timeout=60) as r:
                    body = json.loads(r.read())
                if "error" in body:
                    # 条目已删除 / 合并：接口整批报 no-such-entity 并点名那一个，剔掉它再查（不算一次失败）。
                    bad = body["error"].get("id")
                    if body["error"].get("code") == "no-such-entity" and bad in chunk:
                        chunk.remove(bad)
                        if not chunk:
                            break
                        continue
                    raise RuntimeError(body["error"].get("code"))
                labels = {q: {l: v["value"] for l, v in e.get("labels", {}).items()} for q, e in body.get("entities", {}).items()}
                with lock:
                    out.write(json.dumps({"batch": n, "labels": labels}, ensure_ascii=False) + "\n")
                    out.flush()
                return
            except urllib.error.HTTPError as e:
                wait = int(e.headers.get("Retry-After", "0") or 0) or 5 * (attempt + 1)
            except Exception:
                wait = 5 * (attempt + 1)
            time.sleep(wait)
        with lock:
            out.write(json.dumps({"batch": n, "labels": {}}, ensure_ascii=False) + "\n")
            out.flush()
        print(f"request {n} gave up (written empty)", file=sys.stderr)

    todo = [(n, c) for n, c in enumerate(chunks) if n not in done]
    started = time.time()
    with concurrent.futures.ThreadPoolExecutor(workers) as pool:
        for k, _ in enumerate(pool.map(lambda job: get(*job), todo)):
            if k % 200 == 0:
                print(f"{k + len(done)}/{len(chunks)} in {time.time() - started:.0f}s", file=sys.stderr)
    out.close()


def merge_relabel(in_path, relabel_path, out_path):
    """把 relabel 取到的新标签并回 fetch 格式（每个 GeoNames ID 的每个条目：英文标签 + 新语言标签）。"""
    new = {}
    for line in open(relabel_path, encoding="utf-8"):
        new.update(json.loads(line)["labels"])
    with open(out_path, "w", encoding="utf-8") as out:
        for line in open(in_path, encoding="utf-8"):
            d = json.loads(line)
            items = []
            for it in d["items"]:
                labels = {k: v for k, v in it.get("labels", {}).items() if k == "en"}
                labels.update(new.get(it["item"], {}))
                items.append({"gn": it["gn"], "item": it["item"], "sitelinks": it.get("sitelinks", 0), "labels": labels})
            out.write(json.dumps({"batch": d["batch"], "items": items}, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    if len(sys.argv) >= 6 and sys.argv[1] == "confirm":
        confirm(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5])
    elif len(sys.argv) >= 4 and sys.argv[1] == "relabel":
        relabel(sys.argv[2], sys.argv[3])
    elif len(sys.argv) >= 5 and sys.argv[1] == "merge-relabel":
        merge_relabel(sys.argv[2], sys.argv[3], sys.argv[4])
    elif len(sys.argv) >= 4 and sys.argv[1] == "nearby-sparql":
        nearby_sparql(sys.argv[2], sys.argv[3])
    elif len(sys.argv) >= 4 and sys.argv[1] == "nearby":
        nearby(sys.argv[2], sys.argv[3])
    elif len(sys.argv) >= 4 and sys.argv[1] == "fetch":
        fetch(sys.argv[2], sys.argv[3])
    elif len(sys.argv) >= 5 and sys.argv[1] == "resolve":
        resolve(sys.argv[2], sys.argv[3], sys.argv[4])
    else:
        raise SystemExit(__doc__)
