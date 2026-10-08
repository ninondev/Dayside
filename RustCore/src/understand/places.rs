// SPDX-License-Identifier: GPL-3.0-only
//! 地名 → 时区。国家名（十六语系统地区名 + 常用短称）在有线索时先认，赢过同名小镇（「9am in Brazil」此前读成美国
//! 印第安纳州的 Brazil 镇）；国家的时区取 tz 的 zone.tab（按人口前几座城凑会漏：印尼只剩雅加达）。城市只认索引里
//! 精确的键（不走拼音：「bali」是巴黎的拼音）；变格只收列出来的词尾，还原后的原形也要是精确的键（「Москвzz」不再
//! 被截成莫斯科）。
#[cfg(all(test, not(feature = "intents-only")))]
use crate::city_index::rules as index_builder_rules;
#[cfg(all(test, not(feature = "intents-only")))]
#[allow(dead_code)] // 测试复用构建器，部分入口只由命令行使用。
#[path = "../index_builder.rs"]
mod index_builder;

use super::types::ZoneRef;
use std::cell::Cell;
use std::collections::HashMap;
use std::sync::OnceLock;
#[cfg(not(feature = "intents-only"))]
use unicode_normalization::{char::canonical_combining_class, UnicodeNormalization};

pub(super) const BIG_CITY_LIMIT: usize = 2_000;

#[cfg(not(feature = "intents-only"))]
thread_local! {
    static NEARBY_INDEX: Cell<(bool, Option<u64>)> = const { Cell::new((false, None)) };
}

#[cfg(not(feature = "intents-only"))]
pub(super) struct NearbyParseScope((bool, Option<u64>));
#[cfg(not(feature = "intents-only"))]
impl Drop for NearbyParseScope {
    fn drop(&mut self) { NEARBY_INDEX.with(|index| index.set(self.0)); }
}
/// 索引身份只活过本次解析；嵌套调用与提前返回恢复外层身份。
#[cfg(not(feature = "intents-only"))]
pub(super) fn nearby_parse_scope() -> NearbyParseScope {
    NearbyParseScope(NEARBY_INDEX.with(|index| index.replace((true, None))))
}

pub(super) fn nearby_case(text: &str) -> String { text.chars().flat_map(char::to_lowercase).collect() }

/// 名字只允许主名、英文名和本句语言的名称，不去重音、不还原词尾。
pub(super) fn nearby_city_matches(zone: &ZoneRef, written: &str, language: &str) -> bool {
    let ZoneRef::City { city_index, name, iana, .. } = zone else { return false; };
    let matches = |name: &str| nearby_case(name) == written;
    if matches(name) { return true; }
    #[cfg(not(feature = "intents-only"))]
    {
        let Some(index) = NEARBY_INDEX.with(|index| index.get().1).and_then(crate::city_index::get) else { return false; };
        let Some(record) = index.city(*city_index) else { return false; };
        if record.name != *name || record.timezone_id != *iana { return false; }
        index.nearby_name_matches(*city_index, language, matches)
    }
    #[cfg(feature = "intents-only")]
    { let _ = (city_index, iana, language); false }
}

/// 国家名语言归属来自原表；没有归属证明的跨语言别名不进入附近规则。
pub(super) fn nearby_country_lookup(written: &str, language: &str) -> Option<ZoneRef> {
    static NAMES: OnceLock<HashMap<(&'static str, String), &'static str>> = OnceLock::new();
    let names = NAMES.get_or_init(|| {
        let countries: HashMap<_, Vec<_>> = COUNTRY_NAMES.lines().filter(|l| !l.starts_with('#') && !l.is_empty())
            .filter_map(|line| { let mut fields = line.split('\t'); Some((fields.next()?, fields.collect())) }).collect();
        let mut names = HashMap::new();
        for line in include_str!("../../data/nearby_country_languages.tsv").lines().filter(|l| !l.starts_with('#')) {
            let mut fields = line.split('\t');
            let (Some(code), Some(lang), Some(column)) = (fields.next(), fields.next(), fields.next()) else { continue; };
            if let Some(name) = column.parse::<usize>().ok().and_then(|column| countries.get(code)?.get(column)) {
                names.insert((lang, nearby_case(name)), code);
            }
        }
        // 原有英文短称；其它语言的短称只有系统表内的本语名字才可用。
        for (name, code) in COUNTRY_SHORT.iter().filter(|(name, _)| matches!(*name,
            "china" | "usa" | "u.s.a." | "u.s." | "america" | "uk" | "u.k." | "britain" | "great britain" | "england"
            | "uae" | "u.a.e." | "emirates" | "korea" | "holland" | "czechia" | "czech republic" | "viet nam")) {
            names.insert(("en", nearby_case(name)), *code);
        }
        for (language, name, code) in [("zh-Hans", "中国", "CN"), ("zh-Hant", "中國", "CN"),
            ("zh-Hans", "英格兰", "GB"), ("zh-Hant", "英格蘭", "GB"),
            ("zh-Hans", "阿联酋", "AE"), ("zh-Hant", "阿聯酋", "AE"),
            ("zh-Hant", "美國", "US"), ("ja", "アメリカ", "US"), ("ko", "한국", "KR"), ("ko", "미국", "US")] {
            names.insert((language, nearby_case(name)), code);
        }
        names
    });
    let own = if language.starts_with("zh-Hant") { "zh-Hant" } else if language.starts_with("zh") { "zh-Hans" }
        else if language.starts_with("pt") { "pt-BR" } else { language.split(['-', '_']).next().unwrap_or(language) };
    let code = names.get(&(own, written.to_owned()))
        .or_else(|| (language == "zh").then(|| names.get(&("zh-Hant", written.to_owned()))).flatten())
        .or_else(|| names.get(&("en", written.to_owned())))?;
    let zones = country_zones(code);
    match zones.as_slice() {
        [] => None,
        [only] => Some(ZoneRef::Region { iana: (*only).to_owned() }),
        _ => Some(ZoneRef::Options { reason: "country", options: zones.iter().map(|z| ZoneRef::Region { iana: (*z).to_owned() }).collect() }),
    }
}

thread_local! {
    static EXACT_CITY_SPELLING: Cell<bool> = const { Cell::new(false) };
}

/// Keep the existing lookup callback while requesting spelling metadata from
/// the city index. Nested calls and unwinding restore the caller's policy.
pub(super) fn with_exact_city_spelling<T>(lookup: impl FnOnce() -> T) -> T {
    struct Restore(bool);
    impl Drop for Restore {
        fn drop(&mut self) { EXACT_CITY_SPELLING.with(|flag| flag.set(self.0)); }
    }
    let _restore = Restore(EXACT_CITY_SPELLING.with(|flag| flag.replace(true)));
    lookup()
}

const COUNTRY_ZONES: &str = include_str!("../../data/country_zones.tsv");
const COUNTRY_NAMES: &str = include_str!("../../data/country_names.tsv");

/// 系统地区名里没有、人们却常这么写的短称（系统把 CN 叫「中国大陆 / China mainland」）。
const COUNTRY_SHORT: &[(&str, &str)] = &[
    ("china", "CN"), ("中国", "CN"), ("中國", "CN"), ("chine", "CN"), ("cina", "CN"), ("chiny", "CN"), ("китай", "CN"),
    ("중국", "CN"), ("trung quoc", "CN"), ("tiongkok", "CN"), ("cin", "CN"),
    ("usa", "US"), ("u.s.a.", "US"), ("u.s.", "US"), ("america", "US"), ("amerika", "US"), ("アメリカ", "US"), ("美國", "US"), ("미국", "US"),
    ("uk", "GB"), ("u.k.", "GB"), ("britain", "GB"), ("great britain", "GB"), ("england", "GB"), ("inglaterra", "GB"), ("angleterre", "GB"),
    ("inghilterra", "GB"), ("engeland", "GB"), ("anglia", "GB"), ("ingiltere", "GB"), ("англия", "GB"), ("英格兰", "GB"), ("英格蘭", "GB"),
    ("uae", "AE"), ("u.a.e.", "AE"), ("emirates", "AE"), ("阿联酋", "AE"), ("阿聯酋", "AE"),
    ("korea", "KR"), ("한국", "KR"), ("holland", "NL"), ("czechia", "CZ"), ("czech republic", "CZ"), ("viet nam", "VN"),
    ("соединенные штаты", "US"), ("соединенных штатах", "US"), ("сша", "US"),
    ("stanach zjednoczonych", "US"), ("chiny", "CN"),
];

/// 国家名表与查询用引擎自己的折叠（快捷指令进程也有）；城市索引的键用 `crate::catalog::fold`（见 `city_lookup`）。
fn fold(text: &str) -> String {
    super::text::fold_str(text)
}

/// 地名后的方位与全国修饰语属于封闭语法，不参与索引查询。
pub(super) fn place_modifier_stem(text: &str) -> &str {
    ["那边", "那邊", "全国", "全國"].iter()
        .find_map(|suffix| text.strip_suffix(suffix).filter(|stem| !stem.is_empty())).unwrap_or(text)
}

/// 折叠后的国家名 → 国家码；一个名字对上几个国家的不收（不猜）。
fn country_names() -> &'static HashMap<String, &'static str> {
    static NAMES: OnceLock<HashMap<String, &'static str>> = OnceLock::new();
    NAMES.get_or_init(|| {
        let mut seen: HashMap<String, Option<&'static str>> = HashMap::new();
        let mut add = |name: &str, code: &'static str| {
            let key = fold(name);
            if key.is_empty() {
                return;
            }
            match seen.get(&key) {
                Some(Some(existing)) if *existing != code => {
                    seen.insert(key, None);
                }
                Some(_) => {}
                None => {
                    seen.insert(key, Some(code));
                }
            }
        };
        for line in COUNTRY_NAMES.lines().filter(|l| !l.starts_with('#') && !l.is_empty()) {
            let mut fields = line.split('\t');
            let Some(code) = fields.next() else { continue };
            for name in fields {
                add(name, code);
            }
        }
        for (name, code) in COUNTRY_SHORT {
            add(name, code);
        }
        seen.into_iter().filter_map(|(k, v)| v.map(|code| (k, code))).collect()
    })
}

/// 官方只有一个时间、tz 却另列了地方习惯时区的国家：按官方时间给（中国全国用北京时间，Asia/Urumqi 是新疆民间
/// 另用的时间，「中国 9 点」不该弹出二选一）。
const COUNTRY_ZONE_OVERRIDES: &[(&str, &[&str])] = &[("CN", &["Asia/Shanghai"])];

/// 国家码 → 时区（zone.tab 的顺序）。
fn country_zones(code: &str) -> Vec<&'static str> {
    if let Some((_, zones)) = COUNTRY_ZONE_OVERRIDES.iter().find(|(c, _)| *c == code) {
        return zones.to_vec();
    }
    COUNTRY_ZONES
        .lines()
        .filter(|l| !l.starts_with('#'))
        .find_map(|l| l.split_once('\t').filter(|(c, _)| *c == code).map(|(_, zones)| zones.split(',').collect()))
        .unwrap_or_default()
}

/// 国家名 → 时区：一个时区的国家直接给那个时区，几个的给候选（同一个钟的几个标识由宿主按系统规则合并、排序）。
pub(super) fn country_code(text: &str) -> Option<&'static str> {
    let mut key = fold(place_modifier_stem(text));
    if let Some((stem, suffix)) = key.split_once('\'') {
        if ["da", "de", "ta", "te", "nda", "nde", "daki", "deki", "taki", "teki", "ndaki", "ndeki"].contains(&suffix) {
            key = stem.to_owned();
        }
    }
    let names = country_names();
    names.get(&key).copied().or_else(|| {
        // Only restore closed case endings, and require an exact country name.
        [("ах", "ы"), ("ях", "и"), ("ии", "ия"), ("ае", "ай"),
         ("ach", "y"), ("ii", "ia"), ("ji", "ja"), ("lii", "lia")]
            .iter().find_map(|(ending, restore)| key.strip_suffix(ending).and_then(|stem| names.get(&fold(&format!("{stem}{restore}")))).copied())
    }).or_else(|| ["에서는", "에서", "에는", "은", "는", "에", "의"].iter()
        .find_map(|ending| key.strip_suffix(ending).and_then(|stem| names.get(stem)).copied()))
}

pub(super) fn country_lookup(text: &str) -> Option<ZoneRef> {
    let code = country_code(text)?;
    let zones = country_zones(code);
    match zones.as_slice() {
        [] => None,
        [only] => Some(ZoneRef::Region { iana: (*only).to_owned() }),
        _ => Some(ZoneRef::Options { reason: "country", options: zones.iter().map(|z| ZoneRef::Region { iana: (*z).to_owned() }).collect() }),
    }
}

/// 有线索时认的变格：（词尾，还原成原形时补的词尾）。只收列出来的，还原后的原形还要是索引里精确的键。
/// 俄语方位格：в Москве → Москва、в Берлине → Берлин、в Казани → Казань、в Софии → София；
/// 波兰语方位格：w Warszawie → Warszawa、w Berlinie → Berlin、w Krakowie → Kraków、w Paryżu → Paryż、w Gdyni → Gdynia。
#[cfg(not(feature = "intents-only"))] // 只有城市索引那条路用
const INFLECTIONS: &[(&str, &[&str])] = &[
    ("ие", &["ия"]),
    // 俄语与格：по Новосибирску → Новосибирск、по Москве 已由方位格覆盖。
    ("у", &["", "а"]),
    ("ю", &["ь", "я"]),
    ("е", &["а", "я", ""]),
    ("и", &["ь", "я", "а", ""]),
    ("ie", &["a", ""]),
    ("u", &[""]),
    ("i", &["a", "ia"]),
];

/// 城市索引查地名：精确的键（主名或别名），零散词还要够有名（人口前 5 万座，≤ 3 个字母的前 5,000 座）。
#[cfg(not(feature = "intents-only"))]
pub(super) fn city_lookup(handle: Option<u64>, text: &str, strong: bool) -> Option<ZoneRef> {
    let text = place_modifier_stem(text);
    let fold = crate::catalog::fold;
    let folded = fold(text);
    if folded.is_empty() || folded.chars().count() > 40 {
        return None;
    }
    // IANA 标识符（Europe/London）原样交给宿主校验。
    if text.contains('/') {
        return Some(ZoneRef::Place { query: text.to_owned() });
    }
    let index = crate::city_index::get(handle?)?;
    NEARBY_INDEX.with(|state| { if state.get().0 { state.set((true, handle)); } });
    let spelling = text.split_once(['\'', '’']).filter(|(_, suffix)| ["da", "de", "ta", "te", "nda", "nde", "daki", "deki", "taki", "teki", "ndaki", "ndeki", "ya", "ye", "na", "ne", "dan", "den", "tan", "ten", "dayım", "deyim", "tayım", "teyim"].contains(suffix)).map_or(text, |(stem, _)| stem);
    let mut latin = false;
    let marked = EXACT_CITY_SPELLING.with(Cell::get) && spelling.nfd().any(|c| {
        if canonical_combining_class(c) == 0 { latin = c.is_ascii_alphabetic(); false } else { latin }
    });
    let written: String = if marked { spelling.nfc().flat_map(char::to_lowercase).collect() } else { String::new() };
    let spelling_fits = |city_index| {
        if !marked { return true; }
        let Some(record) = index.city(city_index) else { return false; };
        // Written Latin marks must not turn an ordinary inflected word into a
        // different spelling of the same city. Plain-letter aliases still work.
        if fold(spelling) != fold(&record.name) { return true; }
        let matches = |name: &str| name.nfc().flat_map(char::to_lowercase).eq(written.chars());
        matches(&record.name) || index.names(city_index, false).values().any(|name| matches(name))
    };
    // 同一个键在这次查找里会再查（先认主城，再列同名的别处城市）：索引只读一次。
    let exact_hits = std::cell::RefCell::new(Vec::<(String, Vec<crate::city_index::Hit>)>::new());
    let exact_all = |query: &str| {
        if let Some((_, hits)) = exact_hits.borrow().iter().find(|(key, _)| key == query) {
            return hits.clone();
        }
        let hits = index.exact_all(query);
        exact_hits.borrow_mut().push((query.to_owned(), hits.clone()));
        hits
    };
    let exact = |query: &str| -> Option<usize> {
        let hits = if marked { exact_all(query) } else { crate::city_index::CityIndex::exact_limited(exact_all(query), 8) };
        hits.into_iter().find(|hit| spelling_fits(hit.city_index)).map(|hit| hit.city_index)
    };
    // 有线索的国家名先认：「in Brazil」是巴西，不是美国印第安纳州的 Brazil 镇。同名的是大城（人口前 2,000 座）时城在前：
    // 「horário de Salvador」是巴西的萨尔瓦多市（法语里国家萨尔瓦多也叫 Salvador）。
    if strong {
        if let Some(zone) = country_lookup(text) {
            match exact(&folded).filter(|i| *i < BIG_CITY_LIMIT && country_names().contains_key(&super::text::fold_str(text))) {
                Some(city_index) => {
                    let record = index.city(city_index)?;
                    return Some(ZoneRef::City { city_index, name: record.name, iana: record.timezone_id, population: index.population(city_index) });
                }
                None => return Some(zone),
            }
        }
    }
    let latin_short = folded.chars().all(|c| c.is_ascii_alphabetic()) && folded.len() <= 3;
    // 零散的单个拉丁 / 西里尔词只认前 5,000 座（人口约十几万以上）：标题里大写的普通词常常恰好是某个小城的名字（「Vize」是
    // 土耳其一个镇）。多词的（Winston-Salem、Santa Cruz）与中日韩的照旧放宽到 5 万。
    let single_word = !folded.contains([' ', '-']) && folded.chars().all(|c| c.is_alphabetic() && (c as u32) < 0x2e80);
    let limit = if strong { usize::MAX } else if latin_short || single_word { 5_000 } else { 50_000 };
    // 时区就以它命名的城（Pacific/Apia、Atlantic/Reykjavik、America/Juneau）不受名次限制：人少，却正是写时间的人会写的地方。
    let within = |i: &usize| *i < limit || index.city(*i).is_some_and(|r| names_its_zone(&r.name, &r.timezone_id));
    let mut found = exact(&folded).filter(within);
    let mut matched_key = found.map(|_| folded.clone());
    // 土耳其语的格后缀用撇号隔开（İstanbul'da、Tokyo'ya、Londra'dan）：撇号前面就是地名，零散词也试。
    if found.is_none() {
        if let Some((stem, suffix)) = text.split_once(['\'', '’']).filter(|(_, suffix)| ["da", "de", "ta", "te", "nda", "nde", "daki", "deki", "ndaki", "ndeki", "ya", "ye", "na", "ne", "dan", "den", "tan", "ten", "dayım", "deyim", "tayım", "teyim"].contains(suffix)) {
            let _ = suffix;
            let key = fold(stem);
            found = exact(&key).filter(within);
            matched_key = found.map(|_| key);
        }
    }
    // 韩语的助词粘在地名后（도쿄는、서울에서、부산의、뉴욕처럼）：去掉再按精确的键找（「도쿄는 오후 3시」丢了地点；
    // 「뉴욕처럼」丢了纽约）。
    if found.is_none() && folded.chars().any(|c| ('\u{ac00}'..='\u{d7a3}').contains(&c)) {
        found = ["에서는", "에서", "에는", "으로", "처럼", "까지", "부터", "는", "은", "에", "의", "가", "이", "로", "과", "와", "도"]
            .iter()
            .filter_map(|particle| folded.strip_suffix(particle).filter(|s| s.chars().count() >= 2))
            .find_map(|stem| exact(stem).or_else(|| exact(&format!("{stem}시"))))
            .filter(within);
        // The localized index may store the administrative city form only
        // (오사카시). Require that complete exact key rather than fuzzy matching.
        if found.is_none() {
            found = exact(&format!("{folded}시")).filter(within);
        }
    }
    if found.is_none() && strong {
        // 德语、荷兰语的形容词（Berliner / Pariser / Wiener Zeit、Amsterdamse tijd）：去掉词尾后要是精确的键。
        // 只认大城（前 1 万座）：这种说法只有名城才有，「Seminer Saati」（研讨会时间）去掉 er 对上了捷克一个村子 Semín。
        found = ["er", "se", "sche", "ische"]
            .iter()
            .filter_map(|suffix| folded.strip_suffix(suffix).filter(|s| s.chars().count() >= 3))
            .find_map(exact)
            .filter(|i| *i < 10_000);
    }
    if found.is_none() && strong {
        found = INFLECTIONS.iter().find_map(|(ending, restores)| {
            let stem = folded.strip_suffix(ending).filter(|s| s.chars().count() >= 3)?;
            restores.iter().find_map(|r| exact(&format!("{stem}{r}")))
        });
    }
    let city_index = found?;
    let record = index.city(city_index)?;
    // 零散词（没有 in X 这类线索）只对上多词地名里的一个词时，只认大城（人口前 2,000 座：Rio、Frankfurt），而且不能是地名里的
    // 通用部分：常用词「place」是 University Place 的别名（「14:00 missing/place」此前读成了洛杉矶时间），全小写的
    // 「tanaka san 3pm」里的日语敬称 san 此前对上了加州一座 San 开头的城。
    // 有线索的也一样：「En ruso」（用俄语）对上了墨西哥的 Barrio el Ruso。
    let allowed_name = |city_index: usize, name: &str| {
        let name = fold(name);
        !(name != folded && name.split(|c: char| !c.is_alphanumeric()).any(|w| w == folded)
            && (city_index >= BIG_CITY_LIMIT || GENERIC_NAME_PARTS.contains(&folded.as_str())))
    };
    if !allowed_name(city_index, &record.name) {
        return None;
    }
    let primary_zone = record.timezone_id.clone();
    let primary_name = fold(&record.name);
    let primary = ZoneRef::City { city_index, name: record.name, iana: record.timezone_id, population: index.population(city_index) };
    let Some(matched_key) = matched_key else { return Some(primary) };
    // 先遍历全部倒排，再按时区合并，避免同一时区的小城挡住别的时区。
    let mut zones: HashMap<String, (usize, String, Option<u64>)> = HashMap::new();
    for hit in exact_all(&matched_key) {
        let candidate_index = hit.city_index;
        if !within(&candidate_index) || !spelling_fits(candidate_index) {
            continue;
        }
        let Some(candidate) = index.city(candidate_index) else { continue };
        if candidate.timezone_id == primary_zone || !allowed_name(candidate_index, &candidate.name) {
            continue;
        }
        let population = index.population(candidate_index);
        let replace = zones.get(&candidate.timezone_id).is_none_or(|(existing_index, _, existing_population)| {
            population > *existing_population || (population == *existing_population && candidate_index < *existing_index)
        });
        if !replace {
            continue;
        }
        // 同名候选用主名或显示名认身份，别名不能把另一座大城混进来。
        if hit.tier != 0 && fold(&candidate.name) != primary_name
            && !index.any_name_matches(candidate_index, |name| fold(name) == matched_key)
        {
            continue;
        }
        zones.insert(candidate.timezone_id, (candidate_index, candidate.name, population));
    }
    let mut others: Vec<_> = zones.into_iter().collect();
    others.sort_by(|(_, a), (_, b)| b.2.cmp(&a.2).then_with(|| a.0.cmp(&b.0)));
    if others.is_empty() {
        return Some(primary);
    }
    let mut options = vec![primary];
    options.extend(others.into_iter().take(7).map(|(iana, (city_index, name, population))| ZoneRef::City { city_index, name, iana, population }));
    Some(ZoneRef::Options { reason: "city", options })
}

/// 这座城的名字就是它所在时区标识符的最后一段（Pacific/Apia、America/Port_of_Spain）：IANA 拿它给时区起名。
#[cfg(not(feature = "intents-only"))]
pub(super) fn names_its_zone(name: &str, iana: &str) -> bool {
    let exemplar = iana.rsplit('/').next().unwrap_or("").replace('_', " ");
    !exemplar.is_empty() && crate::catalog::fold(name) == crate::catalog::fold(&exemplar)
}

/// 快捷指令进程没有城市索引，查不出城（只有国家与原样交宿主的地名）。
#[cfg(feature = "intents-only")]
pub(super) fn names_its_zone(_name: &str, _iana: &str) -> bool {
    false
}

/// 多词地名里的通用部分（折叠后）：单独出现时不是地名（san、new、saint、fort…）。
#[cfg(not(feature = "intents-only"))]
const GENERIC_NAME_PARTS: &[&str] = &[
    "san", "santa", "santo", "sao", "new", "los", "las", "la", "el", "le", "les", "saint", "sainte", "st", "fort", "port", "mount",
    "lake", "city", "north", "south", "east", "west", "nova", "novo", "nueva", "nuevo", "ciudad", "villa", "puerto", "bad", "old",
    "great", "little", "upper", "lower", "de", "del", "da", "do", "di", "du", "van", "von", "al", "ben", "son",
];

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn countries_have_all_their_zones_and_short_names() {
        let zones = |text: &str| match country_lookup(text) {
            Some(ZoneRef::Options { options, .. }) => options.iter().map(|o| match o { ZoneRef::Region { iana } => iana.clone(), _ => String::new() }).collect(),
            Some(ZoneRef::Region { iana }) => vec![iana],
            _ => vec![],
        };
        let id = zones("Indonesia");
        for z in ["Asia/Jakarta", "Asia/Pontianak", "Asia/Makassar", "Asia/Jayapura"] {
            assert!(id.iter().any(|x| x == z), "{z} in {id:?}");
        }
        let us = zones("United States");
        for z in ["America/New_York", "America/Chicago", "America/Denver", "America/Phoenix", "America/Los_Angeles", "America/Anchorage", "Pacific/Honolulu"] {
            assert!(us.iter().any(|x| x == z), "{z} in {us:?}");
        }
        assert_eq!(zones("USA"), us);
        assert_eq!(zones("Brasil"), zones("Brazil"));
        assert_eq!(zones("巴西"), zones("Бразилия"));
        assert_eq!(zones("Japan"), vec!["Asia/Tokyo".to_owned()]);
        assert_eq!(zones("中国"), vec!["Asia/Shanghai".to_owned()]);
        assert!(zones("Nowhere").is_empty());
    }

    #[cfg(not(feature = "intents-only"))]
    fn fixture_source() -> &'static str {
        include_str!("../../tests/fixtures/index_builder/same_name_cities.txt")
    }

    #[cfg(not(feature = "intents-only"))]
    fn fixture_dir() -> std::path::PathBuf {
        use std::sync::atomic::{AtomicU64, Ordering};
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("target/tt-same-name-city-fixture")
            .join(format!("{}-{}", std::process::id(), NEXT.fetch_add(1, Ordering::Relaxed)));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[cfg(not(feature = "intents-only"))]
    fn fixture_images(source: &str) -> (Vec<u8>, Vec<u8>) {
        let cities = fixture_dir().join("cities.txt");
        std::fs::write(&cities, source).unwrap();
        let admin = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/index_builder/admin1CodesASCII.txt");
        index_builder::build_with_population(&cities, &admin, None, false).unwrap()
    }

    #[cfg(not(feature = "intents-only"))]
    struct FixtureIndex {
        handle: u64,
    }

    #[cfg(not(feature = "intents-only"))]
    impl FixtureIndex {
        fn open(index: &[u8], population: Option<&[u8]>) -> Self {
            let path = fixture_dir().join("cities.ttcity");
            std::fs::write(&path, index).unwrap();
            if let Some(population) = population {
                std::fs::write(path.with_extension("ttpop"), population).unwrap();
            }
            let result = crate::city_index::dispatch("city.open", serde_json::json!({ "path": path })).unwrap();
            Self { handle: result["handle"].as_u64().unwrap() }
        }

        fn lookup(&self, query: &str, strong: bool) -> ZoneRef {
            city_lookup(Some(self.handle), query, strong).unwrap()
        }

        fn index(&self) -> std::sync::Arc<crate::city_index::CityIndex> {
            crate::city_index::get(self.handle).unwrap()
        }
    }

    #[cfg(not(feature = "intents-only"))]
    impl Drop for FixtureIndex {
        fn drop(&mut self) {
            crate::city_index::dispatch("city.close", serde_json::json!({ "handle": self.handle })).unwrap();
        }
    }

    #[cfg(not(feature = "intents-only"))]
    fn candidates(zone: &ZoneRef) -> Vec<(usize, &str, Option<u64>)> {
        match zone {
            ZoneRef::Options { reason, options } => {
                assert_eq!(*reason, "city");
                options.iter().map(|option| match option {
                    ZoneRef::City { city_index, iana, population, .. } => (*city_index, iana.as_str(), *population),
                    other => panic!("unexpected city option: {other:?}"),
                }).collect()
            }
            ZoneRef::City { city_index, iana, population, .. } => vec![(*city_index, iana, *population)],
            other => panic!("unexpected city lookup: {other:?}"),
        }
    }

    #[test]
    #[cfg(not(feature = "intents-only"))]
    fn same_name_cities_offer_every_zone_with_population() {
        let (index_bytes, population_bytes) = fixture_images(fixture_source());
        let fingerprint = crate::ttcity::FINGERPRINT_OFFSET..crate::ttcity::FINGERPRINT_OFFSET + crate::ttcity::FINGERPRINT_LEN;
        assert!(index_bytes[fingerprint.clone()].iter().any(|b| *b != 0));
        assert_eq!(&index_bytes[fingerprint], &population_bytes[12..24]);
        let fixture = FixtureIndex::open(&index_bytes, Some(&population_bytes));
        let index = fixture.index();
        assert_eq!(index.city_count(), 20);
        let london = index.exact_all("london")[0].city_index;
        assert_eq!(index.city(london).unwrap().country_code, "GB");
        assert!(index.population(london).unwrap().abs_diff(8_961_989) * 100 <= 8_961_989 * 5);
        for (name, expected) in [
            ("London", ["Europe/London", "America/Toronto"]),
            ("Paris", ["Europe/Paris", "America/Chicago"]),
            ("Portland", ["America/Los_Angeles", "America/New_York"]),
            ("Valencia", ["America/Caracas", "Europe/Madrid"]),
            ("Riverton", ["America/Denver", "America/New_York"]),
        ] {
            for strong in [false, true] {
                let lookup = fixture.lookup(name, strong);
                let actual = candidates(&lookup);
                assert_eq!(actual.iter().map(|(_, zone, _)| *zone).collect::<Vec<_>>(), expected, "{name}: {lookup:?}");
                assert!(actual.iter().all(|(_, _, population)| population.is_some()), "{name}: {lookup:?}");
            }
        }
        let springfield = fixture.lookup("Springfield", true);
        assert!(matches!(springfield, ZoneRef::City { population: Some(_), .. }));
        let primaries = index.exact("springfield", 8);
        assert_eq!(candidates(&springfield)[0].0, primaries[0].city_index);
        assert_eq!(candidates(&springfield).iter().map(|(_, zone, _)| *zone).collect::<Vec<_>>(), ["America/Chicago"]);
        let turkish = fixture.lookup("Londra'dan", true);
        assert_eq!(candidates(&turkish).iter().map(|(_, zone, _)| *zone).collect::<Vec<_>>(), ["Europe/London", "America/Toronto"]);
        for fallback in ["런던에서", "Londoner", "Лондоне"] {
            assert!(matches!(fixture.lookup(fallback, true), ZoneRef::City { population: Some(_), .. }), "{fallback}");
        }
    }

    #[test]
    #[cfg(not(feature = "intents-only"))]
    fn mismatched_or_missing_population_keeps_the_city_candidates() {
        let (index_bytes, population_bytes) = fixture_images(fixture_source());
        let swapped = fixture_source().replace("8961989", "SWAPPED").replace("422324", "8961989").replace("SWAPPED", "422324");
        let (_, mismatched) = fixture_images(&swapped);
        let mut wrong_count = population_bytes.clone();
        wrong_count[8..12].copy_from_slice(&21u32.to_le_bytes());
        let mut wrong_length = population_bytes.clone();
        wrong_length.push(0);
        let mut zero_header = index_bytes.clone();
        zero_header[crate::ttcity::FINGERPRINT_OFFSET..crate::ttcity::FINGERPRINT_OFFSET + crate::ttcity::FINGERPRINT_LEN].fill(0);
        for (bytes, companion) in [
            (&index_bytes, None),
            (&index_bytes, Some(mismatched.as_slice())),
            (&index_bytes, Some(wrong_count.as_slice())),
            (&index_bytes, Some(wrong_length.as_slice())),
            (&zero_header, Some(population_bytes.as_slice())),
        ] {
            let fixture = FixtureIndex::open(bytes, companion);
            let index = fixture.index();
            assert!((0..index.city_count()).all(|city| index.population(city).is_none()));
            for (name, expected) in [
                ("London", ["Europe/London", "America/Toronto"]),
                ("Paris", ["Europe/Paris", "America/Chicago"]),
                ("Portland", ["America/Los_Angeles", "America/New_York"]),
                ("Valencia", ["America/Caracas", "Europe/Madrid"]),
                ("Riverton", ["America/Denver", "America/New_York"]),
            ] {
                let lookup = fixture.lookup(name, true);
                let actual = candidates(&lookup);
                assert_eq!(actual.iter().map(|(_, zone, _)| *zone).collect::<Vec<_>>(), expected, "{name}: {lookup:?}");
                assert!(actual.iter().all(|(_, _, population)| population.is_none()));
            }
            let springfield = fixture.lookup("Springfield", true);
            assert!(matches!(springfield, ZoneRef::City { population: None, .. }));
            assert_eq!(candidates(&springfield).iter().map(|(_, zone, _)| *zone).collect::<Vec<_>>(), ["America/Chicago"]);
        }
    }

    #[test]
    #[cfg(not(feature = "intents-only"))]
    fn same_name_zone_limit_keeps_primary_and_orders_other_zones() {
        let zones = ["Europe/London", "America/Toronto", "Europe/Paris", "America/Chicago", "America/Los_Angeles", "America/New_York", "America/Caracas", "Europe/Madrid", "America/Denver", "Asia/Tokyo"];
        let source: String = zones.iter().enumerate().map(|(i, zone)| {
            format!("{}\tManytown\tManytown\t\t{}\t{}\tP\tPPL\tUS\t\tXX\t\t\t\t{}\t\t\t{}\t2026-10-01\n", 920000 + i, 30 + i, -70, 1_000_000 - i * 50_000, zone)
        }).collect();
        let (index_bytes, population_bytes) = fixture_images(&source);
        for companion in [None, Some(population_bytes.as_slice())] {
            let fixture = FixtureIndex::open(&index_bytes, companion);
            let lookup = fixture.lookup("Manytown", true);
            let actual = candidates(&lookup);
            assert_eq!(actual.len(), 8);
            assert_eq!(actual.iter().map(|(_, zone, _)| *zone).collect::<Vec<_>>(), &zones[..8]);
        }
        let mut buckets = population_bytes[24..].to_vec();
        buckets[9] = 255;
        let mut reordered_index = index_bytes;
        let population = index_builder::attach_population(&mut reordered_index, &buckets);
        let fixture = FixtureIndex::open(&reordered_index, Some(&population));
        let lookup = fixture.lookup("Manytown", true);
        let actual = candidates(&lookup);
        let expected_indices = [0, 9, 1, 2, 3, 4, 5, 6];
        assert_eq!(actual.iter().map(|(index, _, _)| *index).collect::<Vec<_>>(), expected_indices);
        assert_eq!(actual.iter().map(|(_, zone, _)| *zone).collect::<Vec<_>>(), expected_indices.map(|i| zones[i]));
    }


    #[test]
    #[cfg(not(feature = "intents-only"))]
    fn secondary_zones_choose_population_then_index_and_keep_primary() {
        let zones = ["Europe/London", "Europe/London", "America/Toronto", "America/Toronto", "America/Chicago", "America/New_York"];
        let source: String = zones.iter().enumerate().map(|(i, zone)| {
            format!("{}\tGroupville\tGroupville\t\t{}\t{}\tP\tPPL\tUS\t\tXX\t\t\t\t{}\t\t\t{}\t2026-10-01\n", 930000 + i, 30 + i, -70, 1_000_000 - i * 50_000, zone)
        }).collect();
        let (index_bytes, _) = fixture_images(&source);
        for (buckets, representatives) in [
            ([1, 255, 0, 101, 0, 0], [0, 3, 4, 5]),
            ([1, 255, 101, 101, 0, 0], [0, 2, 4, 5]),
            ([0, 0, 0, 0, 0, 0], [0, 2, 4, 5]),
        ] {
            let mut image = index_bytes.clone();
            let population = index_builder::attach_population(&mut image, &buckets);
            let fixture = FixtureIndex::open(&image, Some(&population));
            let lookup = fixture.lookup("Groupville", true);
            let actual = candidates(&lookup);
            assert_eq!(actual.iter().map(|(index, _, _)| *index).collect::<Vec<_>>(), representatives, "{lookup:?}");
            assert_eq!(actual.iter().map(|(_, zone, _)| *zone).collect::<Vec<_>>(), [zones[0], zones[2], zones[4], zones[5]]);
        }
    }

    #[test]
    #[cfg(not(feature = "intents-only"))]
    fn bundled_same_name_cities_rank_by_population() {
        let path = std::env::var("MEANTIME_TEST_INDEX").unwrap_or_else(|_| {
            concat!(env!("CARGO_MANIFEST_DIR"), "/../TahoeTime/Resources/cities.ttcity").to_owned()
        });
        let opened = crate::city_index::dispatch("city.open", serde_json::json!({ "path": path })).unwrap();
        let fixture = FixtureIndex { handle: opened["handle"].as_u64().unwrap() };
        let index = fixture.index();
        let london = fixture.lookup("London", true);
        let paris = fixture.lookup("Paris", true);
        let valencia = fixture.lookup("Valencia", true);
        for (query, lookup, expected) in [
            ("London", &london, &["Europe/London", "America/Toronto"][..]),
            ("Paris", &paris, &["Europe/Paris"][..]),
            ("Valencia", &valencia, &["America/Caracas", "Europe/Madrid"][..]),
        ] {
            let actual = candidates(lookup);
            assert!(actual.len() >= expected.len(), "{query}: {lookup:?}");
            assert_eq!(actual.iter().take(expected.len()).map(|(_, zone, _)| *zone).collect::<Vec<_>>(), expected);
            for (city, zone, population) in &actual {
                let record = index.city(*city).unwrap();
                println!("POPULATION {query}: {} / {} {} {zone} {population:?}", record.name, record.region, record.country_code);
            }
        }
        let london_candidates = candidates(&london);
        let england = index.city(london_candidates[0].0).unwrap();
        let ontario = index.city(london_candidates[1].0).unwrap();
        assert_eq!((england.country_code.as_str(), england.region.as_str()), ("GB", "England"));
        assert_eq!((ontario.country_code.as_str(), ontario.region.as_str()), ("CA", "Ontario"));
        assert_eq!(index.city(candidates(&paris)[0].0).unwrap().country_code, "FR");
        let valencia_candidates = candidates(&valencia);
        assert_eq!(index.city(valencia_candidates[0].0).unwrap().country_code, "VE");
        assert_eq!(index.city(valencia_candidates[1].0).unwrap().country_code, "ES");
        assert!(valencia_candidates[0].2.unwrap() > valencia_candidates[1].2.unwrap());
        // 输入转储中伦敦的原始人口，允许伴随文件的对数编码误差。
        let source_population = 8_961_989_u64;
        let actual = london_candidates[0].2.unwrap();
        assert!(actual.abs_diff(source_population) * 100 <= source_population * 5);
        println!("POPULATION London GB: decoded={actual} cities500={source_population}");
    }

    #[test]
    #[cfg(not(feature = "intents-only"))]
    fn same_name_candidates_exclude_another_citys_alias() {
        let source = format!("{}{}",
            fixture_source(),
            "910021\tEast London\tEast London\tLondon,Londra\t-33.02\t27.91\tP\tPPL\tZA\t\t05\t\t\t\t500000\t\t\tAfrica/Johannesburg\t2026-10-02\n");
        let (image, population) = fixture_images(&source);
        let fixture = FixtureIndex::open(&image, Some(&population));
        for query in ["London", "Londra'dan"] {
            let lookup = fixture.lookup(query, true);
            assert_eq!(candidates(&lookup).iter().map(|(_, zone, _)| *zone).collect::<Vec<_>>(),
                       ["Europe/London", "America/Toronto"]);
        }
        let lookup = fixture.lookup("East London", true);
        assert_eq!(candidates(&lookup).iter().map(|(_, zone, _)| *zone).collect::<Vec<_>>(), ["Africa/Johannesburg"]);
    }

}
