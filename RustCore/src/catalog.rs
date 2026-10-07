// SPDX-License-Identifier: GPL-3.0-only
//! Platform-independent catalog policies. The host supplies Apple's available
//! time zones, current offsets and ICU display names as batched snapshots.
use crate::city_index::{self, CityIndex, CityRecord};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::{HashMap, HashSet},
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, Mutex, OnceLock,
    },
};
use unicode_normalization::{char::canonical_combining_class, UnicodeNormalization};
use unicode_segmentation::UnicodeSegmentation;

pub fn fold(s: &str) -> String {
    let decomposed: String =
        s.nfd()
            .filter(|c| canonical_combining_class(*c) == 0)
            .filter_map(|c| match c {
                '.' | '\'' | '\u{2019}' | '\u{02bc}' | ',' | '(' | ')' => None,
                '-' | '\u{2010}' | '\u{2011}' | '\u{2012}' | '\u{2013}' | '\u{2014}' | '_'
                | '/' => Some(' '),
                _ => Some(c),
            })
            .collect();
    decomposed
        .to_lowercase()
        .split(' ')
        .filter(|p| !p.is_empty())
        .collect::<Vec<_>>()
        .join(" ")
        .nfc()
        .collect()
}
pub fn tz_city(s: &str) -> String {
    s.split('/')
        .rfind(|s| !s.is_empty())
        .unwrap_or(s)
        .replace('_', " ")
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Coordinate {
    pub latitude: f64,
    pub longitude: f64,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ZoneOption {
    id: String,
    identifier: String,
    coordinate: Option<Coordinate>,
    city_name: String,
    admin_region: String,
    admin_index: i64,
    country_code: String,
    source: String,
    city_index: Option<usize>,
    /// 只给 Rust 侧的时区层搜索用，不进 JSON（Swift 从不读它们）。
    #[serde(skip)]
    folded_city: String,
    #[serde(skip)]
    folded_full: String,
}
impl ZoneOption {
    fn zone(identifier: String, coordinate: Option<Coordinate>) -> Self {
        let city_name = tz_city(&identifier);
        let folded_city = fold(&city_name);
        let folded_full = fold(&identifier.replace('_', " "));
        Self {
            id: format!("z:{identifier}"),
            identifier,
            coordinate,
            city_name,
            admin_region: String::new(),
            admin_index: -1,
            country_code: String::new(),
            source: "zone".into(),
            city_index: None,
            folded_city,
            folded_full,
        }
    }
    fn city(index: usize, r: CityRecord) -> Self {
        Self {
            id: format!("c:{index}"),
            identifier: r.timezone_id,
            coordinate: Some(Coordinate {
                latitude: r.latitude,
                longitude: r.longitude,
            }),
            city_name: r.name,
            admin_region: r.region,
            admin_index: r.admin_index,
            country_code: r.country_code,
            source: "city".into(),
            city_index: Some(index),
            folded_city: String::new(),
            folded_full: String::new(),
        }
    }
}
fn parse_offset(s: &str) -> Option<i64> {
    let s = s
        .strip_prefix("utc")
        .or_else(|| s.strip_prefix("gmt"))
        .unwrap_or(s)
        .trim_start_matches(' ');
    let (sign, s) = if let Some(s) = s.strip_prefix('+') {
        (1, s)
    } else {
        (-1, s.strip_prefix('-')?)
    };
    // Swift split omits empty segments, including a terminal colon.
    let mut parts = s
        .trim_start_matches(':')
        .splitn(2, ':')
        .filter(|s| !s.is_empty());
    let hours = parts.next()?.parse::<i64>().ok()?;
    if hours > 14 {
        return None;
    }
    let minutes = parts
        .next()
        .map(|s| s.parse::<i64>().ok())
        .unwrap_or(Some(0))?;
    if !(0..60).contains(&minutes) {
        return None;
    }
    hours
        .checked_mul(3600)?
        .checked_add(minutes * 60)?
        .checked_mul(sign)
}
fn parse_iso(s: &str) -> Option<Coordinate> {
    fn degrees(s: &str, degree_digits: usize) -> Option<f64> {
        let b = s.as_bytes();
        let sign = match b.first()? {
            b'+' => 1.,
            b'-' => -1.,
            _ => return None,
        };
        let d = &b[1..];
        if (d.len() != degree_digits + 2 && d.len() != degree_digits + 4)
            || !d.iter().all(u8::is_ascii_digit)
        {
            return None;
        }
        let number = |v: &[u8]| v.iter().fold(0., |n, c| n * 10. + (c - b'0') as f64);
        Some(
            sign * (number(&d[..degree_digits])
                + number(&d[degree_digits..degree_digits + 2]) / 60.
                + if d.len() == degree_digits + 4 {
                    number(&d[degree_digits + 2..]) / 3600.
                } else {
                    0.
                }),
        )
    }
    let split = s
        .char_indices()
        .skip(1)
        .find(|(_, c)| *c == '+' || *c == '-')?
        .0;
    let latitude = degrees(&s[..split], 2)?;
    let longitude = degrees(&s[split..], 3)?;
    if !(-90.0..=90.0).contains(&latitude) || !(-180.0..=180.0).contains(&longitude) {
        return None;
    }
    Some(Coordinate {
        latitude,
        longitude,
    })
}
fn load_coordinates(path: &str) -> HashMap<String, Coordinate> {
    let mut out = HashMap::new();
    if let Ok(data) = std::fs::read(path) {
        if let Ok(raw) = serde_json::from_slice::<HashMap<String, Vec<f64>>>(&data) {
            for (id, c) in raw {
                if c.len() == 2 {
                    out.insert(
                        id,
                        Coordinate {
                            latitude: c[0],
                            longitude: c[1],
                        },
                    );
                }
            }
        }
    }
    if let Ok(text) = std::fs::read_to_string("/usr/share/zoneinfo/zone.tab") {
        for line in text.lines().filter(|s| !s.starts_with('#')) {
            let p: Vec<_> = line.split('\t').collect();
            if p.len() >= 3 {
                if let Some(c) = parse_iso(p[1]) {
                    out.insert(p[2].to_owned(), c);
                }
            }
        }
    }
    out
}
fn language_slot(maximal: &str) -> Option<String> {
    let p: Vec<_> = maximal.split('-').collect();
    match p.first().copied()? {
        "zh" => Some(
            if p.contains(&"Hant") {
                "zh-Hant"
            } else {
                "zh-Hans"
            }
            .into(),
        ),
        "pt" => Some("pt-BR".into()),
        l if ["ja", "ko", "es", "fr", "de", "ru", "pt-BR", "it", "nl", "pl", "tr", "vi", "id"].contains(&l) => Some(l.to_owned()),
        _ => None,
    }
}
/// Taiwan has no region label in any interface language. Other region names come from the host
/// (Apple's frameworks, CLDR data) in the interface language.
fn region_override(code: &str, _slot: &str) -> Option<&'static str> {
    (code == "TW").then_some("")
}
/// Localities whose sovereignty is disputed show neither a region nor a country, only their own name;
/// their time zone is unchanged. This includes every GeoNames `TW` record and two groups under `IL`:
/// - every record in the first-level region "Judea and Samaria Area" (GeoNames admin1 `IL.WE`, the
///   settlements in the West Bank);
/// - twelve localities in the Golan Heights, which GeoNames files under the "Northern District" together
///   with places west of the 1967 line, so they are named one by one. The name must match the index's
///   main name exactly (including diacritics) and the coordinates must fall inside the Golan box, so a
///   place with the same name elsewhere (Ramot in Jerusalem) is not affected.
const GOLAN_LOCALITIES: [&str; 12] = [
    "Ghajar",
    "Al Buţayḩah",
    "H̱ad Nes",
    "Ramot",
    "Katzrin",
    "Fīq",
    "‘Ein Qunīya",
    "Mārom Golan",
    "Nov",
    "H̱ispin",
    "Ramat Magshimim",
    "Al Khushnīyah",
];
fn disputed_locality(
    code: &str,
    admin: &str,
    city: &str,
    latitude: Option<f64>,
    longitude: Option<f64>,
) -> bool {
    code == "TW" || (code == "IL"
        && (admin == "Judea and Samaria Area"
            || (GOLAN_LOCALITIES.contains(&city)
                && latitude.is_some_and(|lat| (32.70..=33.35).contains(&lat))
                && longitude.is_some_and(|lon| (35.60..=35.90).contains(&lon)))))
}
/// Saved entries do not persist administrative regions. Match the two West Bank records by
/// country, original name and the shipped coordinates (a 0.001-degree tolerance accommodates coordinate
/// rounding); never infer this policy from the shared Jerusalem time zone.
fn offset_only_zone_name(p: &Value) -> bool {
    let (code, admin, city) = (text(p, "code"), text(p, "admin"), text(p, "city"));
    let latitude = p.get("latitude").and_then(Value::as_f64);
    let longitude = p.get("longitude").and_then(Value::as_f64);
    text(p, "identifier") == "Asia/Taipei"
        || disputed_locality(code, admin, city, latitude, longitude)
        || (code == "IL" && admin.is_empty()
            && [("Ariel", 32.1065, 35.1845), ("Hashmonaim", 31.929725, 35.0215)]
                .iter().any(|(name, lat, lon)| city == *name
                    && latitude.is_some_and(|value| (value - lat).abs() <= 0.001)
                    && longitude.is_some_and(|value| (value - lon).abs() <= 0.001)))
}
/// Search keys for a country: the host's localized name and the English name, plus the Chinese
/// Taiwan names in both scripts so that 台湾 and 台灣 both find Taiwan in either Chinese interface.
fn search_region_names(
    code: &str,
    slot: &str,
    localized: Option<&str>,
    english: Option<&str>,
) -> Vec<String> {
    let mut out = vec![];
    if code == "TW" && slot.starts_with("zh") {
        out.extend(["台湾", "台灣"].map(str::to_owned));
    }
    out.extend(localized.into_iter().chain(english).map(str::to_owned));
    out
}
fn restore_chinese(source: &str, converted: &str) -> String {
    let source: Vec<_> = source.graphemes(true).collect();
    let result: Vec<_> = converted.graphemes(true).collect();
    if source.len() != result.len() {
        return converted.into();
    }
    source
        .iter()
        .zip(&result)
        .map(|(a, b)| {
            if a != b
                && (["阪", "俱", "乾", "份", "於", "于", "采"].contains(a)
                    || (a.chars().all(|c| c as u32 <= 0xffff)
                        && b.chars().any(|c| c as u32 > 0xffff)))
            {
                *a
            } else {
                *b
            }
        })
        .collect()
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct HostContext {
    countries: Option<Vec<HostCountry>>,
    localized_names: Option<HashMap<String, String>>,
    slot: Option<String>,
}
#[derive(Deserialize)]
struct HostCountry {
    code: String,
    localized: Option<String>,
    english: Option<String>,
}
struct Catalog {
    zones: Vec<ZoneOption>,
    abbreviations: HashMap<String, String>,
    countries: Vec<(String, String)>,
    localized_names: HashMap<String, String>,
    locale_id: Option<String>,
    countries_loaded: bool,
    names_loaded: bool,
}
impl Catalog {
    fn update(&mut self, context: HostContext) {
        if let Some(names) = context.localized_names {
            self.localized_names = names.into_iter().map(|(id, n)| (id, fold(&n))).collect();
            self.names_loaded = true;
        }
        if let Some(countries) = context.countries {
            let mut seen = HashSet::new();
            self.countries.clear();
            for c in countries {
                for name in search_region_names(
                    &c.code,
                    context.slot.as_deref().unwrap_or(""),
                    c.localized.as_deref(),
                    c.english.as_deref(),
                ) {
                    let key = (fold(&name), c.code.clone());
                    if seen.insert(key.clone()) {
                        self.countries.push(key);
                    }
                }
            }
            self.countries_loaded = true;
        }
    }
    fn search(
        &self,
        q: &str,
        limit: usize,
        city: Option<&CityIndex>,
        offsets: Option<&HashMap<String, i64>>,
        use_localized: bool,
    ) -> SearchResult {
        let q = fold(q);
        if q.is_empty() || limit == 0 {
            return SearchResult::ready(vec![]);
        }
        let mut out = vec![];
        let mut seen = HashSet::new();
        let append = |option: ZoneOption, out: &mut Vec<ZoneOption>, seen: &mut HashSet<String>| {
            if out.len() < limit && seen.insert(option.id.clone()) {
                out.push(option);
            }
        };
        if (2..=5).contains(&q.graphemes(true).count()) {
            if let Some(id) = self.abbreviations.get(&q.to_uppercase()) {
                if let Some(z) = self.zones.iter().find(|z| &z.identifier == id) {
                    append(z.clone(), &mut out, &mut seen);
                }
            }
        }
        if let Some(z) = self.zones.iter().find(|z| z.folded_full == q) {
            append(z.clone(), &mut out, &mut seen);
        }
        if let Some(city) = city {
            for hit in city.search(&q, limit) {
                if let Some(r) = city.city(hit.city_index) {
                    append(ZoneOption::city(hit.city_index, r), &mut out, &mut seen);
                }
            }
            if out.len() < limit && q.graphemes(true).count() >= 2 {
                if !self.countries_loaded {
                    return SearchResult::needs(true, false, false);
                }
                let mut codes = HashSet::new();
                for (name, code) in &self.countries {
                    if name.starts_with(&q) && codes.insert(code.clone()) {
                        for e in city.top(code, limit - out.len()) {
                            append(ZoneOption::city(e.index, e.record), &mut out, &mut seen);
                        }
                        if codes.len() >= 2 {
                            break;
                        }
                    }
                }
            }
        }
        if out.len() < limit {
            let wanted = parse_offset(&q);
            let need_names = use_localized && !self.names_loaded;
            let need_offsets = wanted.is_some() && offsets.is_none();
            if need_names || need_offsets {
                return SearchResult::needs(false, need_names, need_offsets);
            }
            let empty = HashMap::new();
            let offsets = offsets.unwrap_or(&empty);
            let mut scored = vec![];
            for z in &self.zones {
                if wanted.is_some() && offsets.get(&z.identifier) == wanted.as_ref() {
                    scored.push((1, z));
                }
                if z.folded_city.starts_with(&q) {
                    scored.push((2, z));
                } else if z.folded_full.contains(&q) {
                    scored.push((3, z));
                } else if use_localized
                    && self
                        .localized_names
                        .get(&z.identifier)
                        .is_some_and(|n| n.starts_with(&q))
                {
                    scored.push((2, z));
                }
            }
            scored.sort_by(|a, b| a.0.cmp(&b.0).then(a.1.identifier.cmp(&b.1.identifier)));
            let city_ids: HashSet<_> = out.iter().map(|o| o.identifier.clone()).collect();
            let mut zone_seen = HashSet::new();
            let mut ranked_count = 0;
            for (_, z) in scored {
                if !zone_seen.insert(&z.identifier) {
                    continue;
                }
                if ranked_count >= limit {
                    break;
                }
                ranked_count += 1;
                if !city_ids.contains(&z.identifier) {
                    append(z.clone(), &mut out, &mut seen);
                }
            }
        }
        SearchResult::ready(out)
    }
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SearchResult {
    results: Vec<ZoneOption>,
    needs_countries: bool,
    needs_localized_names: bool,
    needs_offsets: bool,
}
impl SearchResult {
    fn ready(results: Vec<ZoneOption>) -> Self {
        Self {
            results,
            needs_countries: false,
            needs_localized_names: false,
            needs_offsets: false,
        }
    }
    fn needs(countries: bool, names: bool, offsets: bool) -> Self {
        Self {
            results: vec![],
            needs_countries: countries,
            needs_localized_names: names,
            needs_offsets: offsets,
        }
    }
}
/// Only the active locale is retained, with the original 512-entry bounds.
/// Native DateFormatter objects stay in Swift; these are value-only caches.
#[derive(Default)]
struct NamesCache {
    locale: Option<String>,
    names: HashMap<String, String>,
    folded: HashMap<String, String>,
}
impl NamesCache {
    fn prepare(&mut self, locale: &str) {
        if self.locale.as_deref() != Some(locale) {
            self.locale = Some(locale.to_owned());
            self.names.clear();
            self.folded.clear();
        }
    }
    fn get(&mut self, locale: &str, id: &str, folded: bool) -> Option<String> {
        self.prepare(locale);
        if folded { &self.folded } else { &self.names }
            .get(id)
            .cloned()
    }
    fn put(&mut self, locale: &str, id: &str, value: String, folded: bool) -> String {
        self.prepare(locale);
        if self.names.len() >= 512 {
            self.names.clear();
        }
        if self.folded.len() >= 512 {
            self.folded.clear();
        }
        if folded {
            &mut self.folded
        } else {
            &mut self.names
        }
        .insert(id.to_owned(), value.clone());
        value
    }
}
static NAMES: OnceLock<Mutex<NamesCache>> = OnceLock::new();
fn names() -> &'static Mutex<NamesCache> {
    NAMES.get_or_init(|| Mutex::new(NamesCache::default()))
}
static CATALOGS: OnceLock<Mutex<HashMap<u64, Arc<Mutex<Catalog>>>>> = OnceLock::new();
static NEXT: AtomicU64 = AtomicU64::new(1);
fn registry() -> &'static Mutex<HashMap<u64, Arc<Mutex<Catalog>>>> {
    CATALOGS.get_or_init(|| Mutex::new(HashMap::new()))
}
fn text<'a>(v: &'a Value, k: &str) -> &'a str {
    v.get(k).and_then(Value::as_str).unwrap_or("")
}
fn optional_text<'a>(v: &'a Value, k: &str) -> Option<&'a str> {
    v.get(k).and_then(Value::as_str)
}
pub fn dispatch(operation: &str, p: Value) -> Result<Value, String> {
    match operation {
        "catalog.name_get" => {
            return Ok(json!(names()
                .lock()
                .map_err(|_| "name cache poisoned")?
                .get(
                    text(&p, "localeID"),
                    text(&p, "timezoneID"),
                    p["folded"].as_bool().unwrap_or(false)
                )))
        }
        "catalog.name_finish" => {
            let id = text(&p, "timezoneID");
            let raw = optional_text(&p, "computed");
            let value = raw
                .filter(|n| !n.is_empty() && !n.starts_with("GMT") && !n.starts_with("UTC"))
                .map(str::to_owned)
                .unwrap_or_else(|| tz_city(id));
            return Ok(json!(names()
                .lock()
                .map_err(|_| "name cache poisoned")?
                .put(text(&p, "localeID"), id, value, false)));
        }
        "catalog.fold" => return Ok(json!(fold(text(&p, "text")))),
        "catalog.tz_city" => return Ok(json!(tz_city(text(&p, "text")))),
        "catalog.parse_offset" => return Ok(json!(parse_offset(text(&p, "text")))),
        "catalog.load_coordinates" => return Ok(json!(load_coordinates(text(&p, "path")))),
        "catalog.language_slot" => return Ok(json!(language_slot(text(&p, "maximal")))),
        "catalog.identifiers" => {
            let mut ids = std::collections::BTreeSet::new();
            ids.insert("UTC".to_owned());
            for key in ["system", "coordinates"] {
                for id in p[key]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter_map(Value::as_str)
                {
                    ids.insert(id.to_owned());
                }
            }
            return Ok(json!(ids));
        }
        "catalog.select_coordinate" => {
            #[derive(Deserialize)]
            struct Candidate {
                record: CityRecord,
                offsets: Vec<i64>,
            }
            let rows: Vec<Candidate> =
                serde_json::from_value(p["candidates"].clone()).map_err(|e| e.to_string())?;
            let offsets: Vec<i64> =
                serde_json::from_value(p["offsets"].clone()).map_err(|e| e.to_string())?;
            let value = rows
                .into_iter()
                .find(|r| {
                    r.record.timezone_id == text(&p, "identifier")
                        || (!offsets.is_empty() && r.offsets == offsets)
                })
                .map(|r| Coordinate {
                    latitude: r.record.latitude,
                    longitude: r.record.longitude,
                });
            return Ok(json!(value));
        }
        "catalog.select_name" => {
            let code = text(&p, "code");
            let names = &p["names"];
            let value = names
                .get(code)
                .and_then(Value::as_str)
                .or_else(|| match code {
                    "zh-Hans" => names.get("zh-Hant").and_then(Value::as_str),
                    "zh-Hant" => names.get("zh-Hans").and_then(Value::as_str),
                    _ => None,
                });
            return Ok(json!(value));
        }
        "catalog.region_override" => {
            return Ok(json!(region_override(text(&p, "code"), text(&p, "slot"))))
        }
        "catalog.restore_chinese" => {
            return Ok(json!(restore_chinese(
                text(&p, "source"),
                text(&p, "converted")
            )))
        }
        "catalog.zone_option" => {
            return Ok(json!(ZoneOption::zone(
                text(&p, "identifier").to_owned(),
                serde_json::from_value(p.get("coordinate").cloned().unwrap_or(Value::Null))
                    .map_err(|e| e.to_string())?
            )))
        }
        "catalog.city_option" => {
            return Ok(json!(ZoneOption::city(
                p["index"].as_u64().ok_or("missing index")? as usize,
                serde_json::from_value(p["record"].clone()).map_err(|e| e.to_string())?
            )))
        }
        "catalog.offset_only_zone_name" => return Ok(json!(offset_only_zone_name(&p))),
        "catalog.subtitle" => {
            if text(&p, "source") == "zone" {
                let id = text(&p, "identifier");
                let mut parts: Vec<_> = id.split('/').filter(|s| !s.is_empty()).collect();
                parts.pop();
                return Ok(json!(parts.join(" / ").replace('_', " ")));
            }
            // The country part is whatever the host passes in: Apple's localized region name for the
            // record's country code (CLDR data), with no per-country or per-language override. The
            // region part is the record's first-level administrative name from the index.
            let (code, admin, resolved, country, city, display) = (
                text(&p, "code"),
                text(&p, "admin"),
                text(&p, "resolved"),
                text(&p, "country"),
                text(&p, "city"),
                text(&p, "display"),
            );
            let latitude = p.get("latitude").and_then(Value::as_f64);
            let longitude = p.get("longitude").and_then(Value::as_f64);
            if disputed_locality(code, admin, city, latitude, longitude) {
                return Ok(json!(""));
            }
            let redundant = |name: &str| {
                !name.is_empty()
                    && [admin, resolved].iter().any(|r| {
                        !r.is_empty() && (*r == name || r.starts_with(name) || name.starts_with(r))
                    })
            };
            let suppress = resolved == country || redundant(city) || redundant(display);
            return Ok(json!([if suppress { "" } else { resolved }, country]
                .into_iter()
                .filter(|s| !s.is_empty())
                .collect::<Vec<_>>()
                .join(", ")));
        }
        "catalog.open" => {
            #[derive(Deserialize)]
            struct Seed {
                identifier: String,
                coordinate: Option<Coordinate>,
            }
            let seeds: Vec<Seed> =
                serde_json::from_value(p["zones"].clone()).map_err(|e| e.to_string())?;
            let mut zones: Vec<_> = seeds
                .into_iter()
                .map(|s| ZoneOption::zone(s.identifier, s.coordinate))
                .collect();
            zones.sort_by(|a, b| a.identifier.cmp(&b.identifier));
            zones.dedup_by(|a, b| a.identifier == b.identifier);
            let abbreviations =
                serde_json::from_value(p["abbreviations"].clone()).map_err(|e| e.to_string())?;
            let handle = NEXT
                .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |v| v.checked_add(1))
                .map_err(|_| "catalog handle space exhausted")?;
            let response = json!({"handle":handle,"zones":zones});
            registry()
                .lock()
                .map_err(|_| "catalog registry poisoned")?
                .insert(
                    handle,
                    Arc::new(Mutex::new(Catalog {
                        zones,
                        abbreviations,
                        countries: vec![],
                        localized_names: HashMap::new(),
                        locale_id: None,
                        countries_loaded: false,
                        names_loaded: false,
                    })),
                );
            return Ok(response);
        }
        _ => {}
    }
    let handle = p["handle"].as_u64().ok_or("missing catalog handle")?;
    if operation == "catalog.close" {
        return Ok(json!(registry()
            .lock()
            .map_err(|_| "catalog registry poisoned")?
            .remove(&handle)
            .is_some()));
    }
    let catalog = registry()
        .lock()
        .map_err(|_| "catalog registry poisoned")?
        .get(&handle)
        .cloned()
        .ok_or("invalid or released catalog handle")?;
    if operation == "catalog.search" {
        let mut catalog = catalog.lock().map_err(|_| "catalog state poisoned")?;
        let locale = text(&p, "localeID");
        if catalog.locale_id.as_deref() != Some(locale) {
            catalog.locale_id = Some(locale.to_owned());
            catalog.countries.clear();
            catalog.localized_names.clear();
            catalog.countries_loaded = false;
            catalog.names_loaded = false;
        }
        if p.get("context").is_some_and(|v| !v.is_null()) {
            catalog
                .update(serde_json::from_value(p["context"].clone()).map_err(|e| e.to_string())?);
        }
        let city = p
            .get("cityHandle")
            .and_then(Value::as_u64)
            .and_then(city_index::get);
        let offsets: Option<HashMap<String, i64>> =
            serde_json::from_value(p.get("offsets").cloned().unwrap_or(Value::Null))
                .map_err(|e| e.to_string())?;
        let limit = p["limit"]
            .as_u64()
            .and_then(|n| usize::try_from(n).ok())
            .unwrap_or(0);
        return Ok(json!(catalog.search(
            text(&p, "query"),
            limit,
            city.as_deref(),
            offsets.as_ref(),
            p["useLocalizedNames"].as_bool().unwrap_or(false)
        )));
    }
    Err(format!("unknown catalog operation: {operation}"))
}
#[cfg(test)]
mod tests {
    use super::*;
    const INTERFACE_LANGUAGES: [&str; 16] = [
        "zh-Hans", "zh-Hant", "en", "ja", "ko", "de", "es", "fr", "ru", "pt-BR",
        "it", "nl", "pl", "tr", "vi", "id",
    ];
    #[test]
    fn folds_multilingual_queries() {
        for (input, expected) in [
            ("München", "munchen"),
            ("Москва", "москва"),
            ("서울", "서울"),
            ("St. Petersburg", "st petersburg"),
            ("N'Djamena", "ndjamena"),
            ("Asia/Tokyo", "asia tokyo"),
        ] {
            assert_eq!(fold(input), expected);
        }
    }
    #[test]
    fn offset_and_coordinate_contracts() {
        assert_eq!(parse_offset("utc+5:30"), Some(19800));
        assert_eq!(parse_offset("gmt-3:30"), Some(-12600));
        assert_eq!(parse_offset("8"), None);
        assert_eq!(parse_offset("+15"), None);
        assert_eq!(
            parse_iso("+404251-0740023"),
            Some(Coordinate {
                latitude: 40. + 42. / 60. + 51. / 3600.,
                longitude: -(74. + 23. / 3600.)
            })
        );
        assert!(parse_iso("+9900+00000").is_none());
    }
    #[test]
    fn restores_chinese_script_exceptions() {
        assert_eq!(restore_chinese("大阪", "大阪"), "大阪");
        assert_eq!(restore_chinese("大阪", "大坂"), "大阪");
        assert_eq!(restore_chinese("埨", "𫭢"), "埨");
    }
    #[test]
    fn subtitles_use_the_host_region_name_without_overrides() {
        let subtitle = |code: &str, admin: &str, slot: &str, resolved: &str, country: &str, city: &str| {
            dispatch(
                "catalog.subtitle",
                json!({"source":"city","identifier":"","code":code,"admin":admin,"slot":slot,
                       "resolved":resolved,"country":country,"city":city,"display":""}),
            )
            .unwrap()
        };
        // Other places show their region and the country name the host passed in.
        for slot in INTERFACE_LANGUAGES.into_iter().chain(std::iter::once("")) {
            for (code, admin, city) in [("CN", "Guangdong", "Guangzhou"),
                                       ("HK", "Kowloon City", "Hong Kong"),
                                       ("MO", "Nossa Senhora de Fátima", "Macao")] {
                assert_eq!(subtitle(code, admin, slot, "R", "C", city), "R, C", "{code} {slot}");
            }
            assert_eq!(subtitle("XK", "Prizren", slot, "R", "C", "Suva Reka"), "R, C", "{slot}");
            assert_eq!(subtitle("IN", "Arunachal Pradesh", slot, "R", "C", "Tawang"), "R, C", "{slot}");
            assert_eq!(subtitle("IL", "Tel Aviv", slot, "R", "C", "Holon"), "R, C", "{slot}");
            assert_eq!(subtitle("PS", "West Bank", slot, "R", "C", "Jenin"), "R, C", "{slot}");
        }
        // The generic de-duplication applies to every country alike.
        assert_eq!(subtitle("MC", "Monaco", "en", "Monaco", "Monaco", "Monte-Carlo"), "Monaco");
        assert_eq!(subtitle("KR", "Busan", "en", "Busan", "South Korea", "Busan"), "South Korea");
        assert!(dispatch("catalog.territory", json!({"code":"XK","admin":"","slot":"zh-Hans"})).is_err());
    }
    #[test]
    fn taiwan_region_label_is_empty_and_search_names_remain() {
        for slot in INTERFACE_LANGUAGES.into_iter().chain(std::iter::once("")) {
            assert_eq!(region_override("TW", slot), Some(""), "{slot}");
            assert_eq!(dispatch("catalog.region_override", json!({"code":"TW","slot":slot})).unwrap(), "", "{slot}");
        }
        for code in ["CN", "HK", "MO", "PS", "XK", "IN", "IL", "SY", "RS"] {
            for slot in INTERFACE_LANGUAGES.into_iter().chain(std::iter::once("")) {
                assert_eq!(region_override(code, slot), None, "{code} {slot}");
            }
        }
        // Both Chinese spellings are search keys in both Chinese interfaces, so 台湾 and 台灣 both find
        // Taiwan; the host's own name and the English name stay keys as well.
        let keys = search_region_names("TW", "zh-Hans", Some("台湾"), Some("Taiwan"));
        assert_eq!(keys, ["台湾", "台灣", "台湾", "Taiwan"]);
        let keys = search_region_names("TW", "zh-Hant", Some("台灣"), Some("Taiwan"));
        assert_eq!(keys, ["台湾", "台灣", "台灣", "Taiwan"]);
        assert_eq!(search_region_names("TW", "fr", Some("Taïwan"), Some("Taiwan")), ["Taïwan", "Taiwan"]);
        assert_eq!(search_region_names("HK", "zh-Hans", Some("香港"), Some("Hong Kong")), ["香港", "Hong Kong"]);
        assert!(dispatch("catalog.region_override", json!({"code":"CN","slot":"zh-Hans"})).unwrap().is_null());
    }
    #[test]
    fn taiwan_cities_show_no_region_or_country_in_every_language() {
        let index = cities();
        let mut taiwan_cities = 0;
        for i in 0..index.city_count() {
            let Some(record) = index.city(i).filter(|r| r.country_code == "TW") else { continue };
            taiwan_cities += 1;
            assert_eq!(record.timezone_id, "Asia/Taipei", "{}", record.name);
            for slot in INTERFACE_LANGUAGES {
                let subtitle = dispatch("catalog.subtitle", json!({
                    "source":"city", "code":record.country_code, "admin":record.region,
                    "resolved":record.region, "country":"Taiwan", "city":record.name,
                    "slot":slot, "display":"", "latitude":record.latitude, "longitude":record.longitude,
                })).unwrap();
                assert_eq!(subtitle, "", "{} [{slot}]", record.name);
                // TW is identified by its country code, including callers without coordinates.
                assert_eq!(dispatch("catalog.subtitle", json!({
                    "source":"city", "code":"TW", "admin":record.region,
                    "resolved":record.region, "country":"Taiwan", "city":record.name, "slot":slot,
                })).unwrap(), "", "{} [{slot}]", record.name);
            }
        }
        assert!(taiwan_cities > 0);
    }
    #[test]
    fn disputed_localities_show_no_region_or_country() {
        // The fourteen records in the shipped index: the two GeoNames records in "Judea and Samaria
        // Area" and the twelve Golan Heights localities. Every interface language gets an empty subtitle,
        // so neither a region nor a country is shown; the time zone is not touched.
        let index = cities();
        let israel = [
            ("en", "Israel"), ("zh-Hans", "以色列"), ("zh-Hant", "以色列"), ("ja", "イスラエル"), ("ko", "이스라엘"),
            ("de", "Israel"), ("es", "Israel"), ("fr", "Israël"), ("ru", "Израиль"), ("pt-BR", "Israel"),
            ("it", "Israele"), ("nl", "Israël"), ("pl", "Izrael"), ("tr", "İsrail"), ("vi", "Israel"), ("id", "Israel"),
        ];
        let mut west_bank = vec![];
        let mut golan = vec![];
        for i in 0..index.city_count() {
            let Some(r) = index.city(i) else { continue };
            if r.country_code != "IL" || !disputed_locality(&r.country_code, &r.region, &r.name, Some(r.latitude), Some(r.longitude)) {
                continue;
            }
            if r.region == "Judea and Samaria Area" { west_bank.push(r.name.clone()) } else { golan.push(r.name.clone()) }
            assert_eq!(r.timezone_id, "Asia/Jerusalem", "{}", r.name);
            let city_names = index.names(i, false);
            let region_names = if r.admin_index >= 0 { index.names(r.admin_index as usize, true) } else { HashMap::new() };
            for (slot, country) in israel {
                let pick = |names: &HashMap<String, String>, fallback: &str| {
                    names.get(slot).cloned().unwrap_or_else(|| fallback.to_owned())
                };
                let value = dispatch(
                    "catalog.subtitle",
                    json!({"source":"city","identifier":r.timezone_id,"code":r.country_code,"admin":r.region,
                           "slot":slot,"resolved":pick(&region_names, &r.region),"country":country,"city":r.name,
                           "display":pick(&city_names, &r.name),"latitude":r.latitude,"longitude":r.longitude}),
                )
                .unwrap();
                assert_eq!(value, "", "{} [{slot}]", r.name);
            }
        }
        assert_eq!(west_bank.len(), 2, "{west_bank:?}");
        golan.sort();
        let mut expected: Vec<String> = GOLAN_LOCALITIES.iter().map(|s| s.to_string()).collect();
        expected.sort();
        assert_eq!(golan, expected);
        // Neighbours keep the normal rule: Israeli places in the same Northern District, a Jerusalem
        // neighbourhood that shares a Golan name, and a Palestinian city.
        let subtitle = |code: &str, admin: &str, city: &str, lat: f64, lon: f64, slot: &str| {
            dispatch(
                "catalog.subtitle",
                json!({"source":"city","identifier":"","code":code,"admin":admin,"slot":slot,"resolved":admin,
                       "country":"C","city":city,"display":city,"latitude":lat,"longitude":lon}),
            )
            .unwrap()
        };
        for slot in INTERFACE_LANGUAGES {
            assert_eq!(subtitle("IL", "Northern District", "Dan", 33.2399, 35.6527, slot), "Northern District, C", "{slot}");
            assert_eq!(subtitle("IL", "Jerusalem", "Ramot", 31.8, 35.2, slot), "Jerusalem, C", "{slot}");
            assert_eq!(subtitle("PS", "West Bank", "Ramallah", 31.9, 35.2, slot), "West Bank, C", "{slot}");
            assert_eq!(subtitle("SY", "Quneitra", "Quneitra", 33.12, 35.82, slot), "C", "{slot}");
        }
    }
    #[test]
    fn disputed_name_without_both_coordinates_keeps_its_subtitle() {
        // A name alone cannot distinguish a Golan locality from a namesake elsewhere.
        for (latitude, longitude) in [(None, None), (Some(32.9919), None), (None, Some(35.6914))] {
            for slot in INTERFACE_LANGUAGES {
                let value = dispatch(
                    "catalog.subtitle",
                    json!({"source":"city","identifier":"Asia/Jerusalem","code":"IL","admin":"Northern District",
                           "slot":slot,"resolved":"Northern District","country":"C","city":"Katzrin","display":"",
                           "latitude":latitude,"longitude":longitude}),
                )
                .unwrap();
                assert_eq!(value, "Northern District, C", "{slot} {latitude:?} {longitude:?}");
            }
        }
    }
    #[test]
    fn offset_only_zone_names_cover_every_disputed_record_and_saved_entries() {
        let index = cities();
        let mut taiwan = 0;
        let mut israeli = 0;
        for i in 0..index.city_count() {
            let Some(r) = index.city(i) else { continue };
            let expected = disputed_locality(&r.country_code, &r.region, &r.name, Some(r.latitude), Some(r.longitude));
            let payload = json!({"identifier":r.timezone_id,"code":r.country_code,"admin":r.region,"city":r.name,
                "latitude":r.latitude,"longitude":r.longitude});
            assert_eq!(offset_only_zone_name(&payload), expected, "{}", r.name);
            if !expected { continue }
            if r.country_code == "TW" { taiwan += 1 } else { israeli += 1 }
            // Older persisted entries have no administrative-region field, but retain these facts.
            let mut saved = payload;
            saved.as_object_mut().unwrap().remove("admin");
            assert!(offset_only_zone_name(&saved), "saved {}", r.name);
        }
        assert!(taiwan > 0);
        assert_eq!(israeli, 14);
        assert_eq!(dispatch("catalog.offset_only_zone_name", json!({"identifier":"Asia/Taipei"})).unwrap(), true);
        assert_eq!(dispatch("catalog.offset_only_zone_name", json!({"identifier":"Asia/Jerusalem"})).unwrap(), false);
    }
    #[test]
    fn saved_west_bank_zone_names_need_matching_original_name_country_and_coordinates() {
        for (city, lat, lon) in [("Ariel", 32.1065, 35.1845), ("Hashmonaim", 31.929725, 35.0215)] {
            let valid = json!({"identifier":"Asia/Jerusalem","code":"IL","city":city,"latitude":lat,"longitude":lon});
            assert!(offset_only_zone_name(&valid));
            for (key, value) in [("code", json!("US")), ("city", json!("Tel Aviv")), ("latitude", Value::Null),
                ("longitude", Value::Null), ("latitude", json!(lat + 0.01)), ("longitude", json!(lon + 0.01))] {
                let mut invalid = valid.clone();
                invalid[key] = value;
                assert!(!offset_only_zone_name(&invalid), "{city} {key}");
            }
        }
        assert!(!offset_only_zone_name(&json!({"identifier":"Asia/Jerusalem","code":"IL","city":"Ramot",
            "latitude":31.8,"longitude":35.2})));
        assert!(!offset_only_zone_name(&json!({"identifier":"Asia/Jerusalem","code":"IL","city":"Katzrin"})));
    }
    fn sample_catalog() -> Catalog {
        Catalog {
            zones: ["America/Denver", "Asia/Tokyo", "UTC"]
                .into_iter()
                .map(|id| ZoneOption::zone(id.into(), None))
                .collect(),
            abbreviations: HashMap::from([("JST".into(), "Asia/Tokyo".into())]),
            countries: vec![],
            localized_names: HashMap::new(),
            locale_id: None,
            countries_loaded: false,
            names_loaded: false,
        }
    }
    fn cities() -> CityIndex {
        CityIndex::open(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../TahoeTime/Resources/cities.ttcity"
        ))
        .unwrap()
    }
    #[test]
    fn strong_or_full_city_matches_need_no_native_snapshot() {
        let c = sample_catalog();
        let cities = cities();
        for q in ["JST", "Asia/Tokyo"] {
            let found = c.search(q, 1, Some(&cities), None, true);
            assert_eq!(found.results[0].identifier, "Asia/Tokyo");
            assert!(!found.needs_countries && !found.needs_localized_names && !found.needs_offsets);
        }
        let found = c.search("a", 8, Some(&cities), None, true);
        assert_eq!(found.results.len(), 8);
        assert!(found.results.iter().all(|z| z.source == "city"));
        assert!(!found.needs_countries && !found.needs_localized_names && !found.needs_offsets);
    }
    #[test]
    fn country_results_request_only_country_names() {
        let mut c = sample_catalog();
        let cities = cities();
        let first = c.search("country of j", 8, Some(&cities), None, true);
        assert!(first.needs_countries);
        assert!(!first.needs_localized_names);
        c.update(HostContext {
            countries: Some(vec![HostCountry {
                code: "JP".into(),
                localized: Some("Country of Japan".into()),
                english: Some("Japan".into()),
            }]),
            localized_names: None,
            slot: None,
        });
        let found = c.search("country of j", 8, Some(&cities), None, true);
        assert_eq!(found.results.len(), 8);
        assert!(found.results.iter().all(|z| z.country_code == "JP"));
        assert!(!found.needs_localized_names);
    }
    #[test]
    fn weak_zone_queries_request_icu_and_live_offsets_only_when_needed() {
        let mut c = sample_catalog();
        assert!(c.search("東京", 8, None, None, true).needs_localized_names);
        c.update(HostContext {
            countries: None,
            localized_names: Some(HashMap::from([("Asia/Tokyo".into(), "東京".into())])),
            slot: None,
        });
        assert_eq!(
            c.search("東京", 8, None, None, true).results[0].identifier,
            "Asia/Tokyo"
        );
        assert!(c.search("東京", 8, None, None, false).results.is_empty());
        let missing = c.search("utc+9", 8, None, None, true);
        assert!(missing.needs_offsets);
        assert!(!missing.needs_localized_names);
        let offsets = HashMap::from([("Asia/Tokyo".into(), 32400)]);
        assert_eq!(
            c.search("utc+9", 8, None, Some(&offsets), true).results[0].identifier,
            "Asia/Tokyo"
        );
    }
    #[test]
    fn native_cache_is_bounded_and_locale_changes_do_not_reuse_names() {
        let mut c = NamesCache::default();
        c.put("en", "Asia/Tokyo", "Tokyo".into(), false);
        c.put("en", "Asia/Tokyo", "tokyo".into(), true);
        assert_eq!(c.get("en", "Asia/Tokyo", true).as_deref(), Some("tokyo"));
        assert!(c.get("ja", "Asia/Tokyo", false).is_none());
        assert!(c.get("en", "Asia/Tokyo", true).is_none());
        for i in 0..513 {
            c.put("en", &i.to_string(), "value".into(), false);
        }
        assert_eq!(c.names.len(), 1);
        assert!(c.get("en", "0", false).is_none());
        assert_eq!(c.get("en", "512", false).as_deref(), Some("value"));
    }
    #[test]
    fn switching_catalog_locale_discards_native_snapshot() {
        let opened = dispatch(
            "catalog.open",
            json!({"zones":[{"identifier":"Asia/Tokyo","coordinate":null}],"abbreviations":{}}),
        )
        .unwrap();
        let h = opened["handle"].as_u64().unwrap();
        let found=dispatch("catalog.search",json!({"handle":h,"query":"東京","limit":8,"localeID":"ja","useLocalizedNames":true,"context":{"localizedNames":{"Asia/Tokyo":"東京"}}})).unwrap();
        assert_eq!(found["results"][0]["identifier"], "Asia/Tokyo");
        let changed = dispatch(
            "catalog.search",
            json!({"handle":h,"query":"東京","limit":8,"localeID":"en","useLocalizedNames":true}),
        )
        .unwrap();
        assert_eq!(changed["needsLocalizedNames"], true);
        assert_eq!(
            dispatch("catalog.close", json!({"handle":h})).unwrap(),
            true
        );
        assert!(dispatch(
            "catalog.search",
            json!({"handle":h,"query":"Tokyo","limit":8})
        )
        .is_err());
    }

    /// 性质测试：搜索折叠是幂等的（折两次等于折一次，索引侧与查询侧才对得上），结果里没有大写、没有
    /// 组合符、没有被删的标点、没有连续或首尾空格；空白与连字符的任何组合折出来都一样。
    #[test]
    fn random_text_folds_idempotently_and_cleanly() {
        struct Xor(u64);
        impl Xor {
            fn next(&mut self) -> u64 {
                let mut x = self.0;
                x ^= x << 13;
                x ^= x >> 7;
                x ^= x << 17;
                self.0 = x;
                x
            }
            fn below(&mut self, n: u64) -> u64 {
                self.next() % n.max(1)
            }
        }
        let iterations: u64 = std::env::var("MEANTIME_FUZZ_ITERATIONS").ok().and_then(|v| v.parse().ok()).unwrap_or(20_000);
        let seed_offset: u64 = std::env::var("MEANTIME_FUZZ_SEED").ok().and_then(|v| v.parse().ok()).unwrap_or(0);
        let mut rng = Xor(0xF01D_F01D_5EED_0001_u64.wrapping_add(seed_offset));
        let pieces = ["São", "Paulo", "MÜNCHEN", "Zürich", "New", "York", "St.", "John's", "Ho-Chi-Minh", "東京", "서울", "Москва́", "a\u{301}", "ı", "İstanbul", "ß", "ǅ", "(old)", "x_y/z", "—", " ", "  ", ",", "\u{2019}"];
        for i in 0..iterations {
            let text: String = (0..rng.below(7)).map(|_| pieces[rng.below(pieces.len() as u64) as usize]).collect::<Vec<_>>().join(if rng.below(2) == 0 { " " } else { "" });
            let once = fold(&text);
            let twice = fold(&once);
            assert_eq!(once, twice, "#{i} 折叠不幂等：{text:?} → {once:?} → {twice:?}");
            assert!(!once.chars().any(|c| c.is_uppercase()), "#{i} 还有大写：{once:?}");
            assert!(!once.chars().any(|c| canonical_combining_class(c) != 0), "#{i} 还有组合符：{once:?}");
            assert!(!once.chars().any(|c| matches!(c, '.' | '\'' | ',' | '(' | ')' | '-' | '_' | '/' | '\u{2019}' | '\u{2014}')), "#{i} 还有该删该换的标点：{once:?}");
            assert!(!once.contains("  ") && once == once.trim(), "#{i} 空格没收干净：{once:?}");
            // 空白与连字符等价：把每个空格换成连字符再折，结果相同。
            assert_eq!(fold(&text.replace(' ', "-")), once, "#{i} 连字符与空格折出不同：{text:?}");
        }
    }
}
