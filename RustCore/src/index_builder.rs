// SPDX-License-Identifier: GPL-3.0-only
//! GeoNames -> TTCITY10 compiler. Selection rules preserve the established Python compiler's behavior.
//! TTCITY10 keeps TTCITY07's content and section order (plus a symbol-table section): 16-byte city
//! records with fixed-point coordinates, symbol-coded strings (`fsst.rs`) in the text pool and in the
//! front-coded key blocks of `KEY_BLOCK` records, 3-byte postings, 8-byte localized entries (see
//! `city_index.rs` for the record layout). 生成与转码都先得到 `Model`（逻辑内容）再经 `write_image`
//! 序列化；`transcode` 把既有 TTCITY07/08/09/10 镜像解成 `Model` 后写回，不重新推导任何内容，顺带套上
//! `rules::SEARCH_KEY_ERRATA`：一张封闭的搜索键补丁表，只给 `pick_alternates` 留不住的名字补倒排。
use std::collections::{BTreeMap, HashMap, HashSet};
use std::error::Error;
use std::fs::{self, File};
use std::io::{BufRead, BufReader};
use std::path::Path;
use unicode_general_category::{get_general_category, GeneralCategory};
use unicode_normalization::{char::canonical_combining_class, UnicodeNormalization};
use crate as dayside_core;
use dayside_core::fsst;
use dayside_core::ttcity::{self, script_class, KEY_BLOCK};

use super::index_builder_rules as rules;

const LANGUAGES: [&str; 15] = [
    "zh-Hans", "zh-Hant", "ja", "ko", "es", "fr", "de", "ru", "pt-BR", "it", "nl", "pl", "tr", "vi", "id",
];
/// 基础九语沿用 GeoNames 名字；意、荷、波、土、越、印尼六语只从 Wikidata 与
/// 「加语言」那条路进来；黄金夹具（不带补充表）不给它们写槽位，所以夹具镜像逐字节不变。
const BASE_LANGUAGES: usize = 9;
/// Postings are 3 bytes: bit 23 marks a primary-name hit, the low 23 bits hold the city index.
const PRIMARY_BIT: u32 = 0x80_0000;
const MAX_CITIES: usize = 0x80_0000;
const MAX_U24: usize = 0xff_ffff;
const EDGE_JUNK: &str = "_,/\\|;:·、-–— \t";
const TAIL_SEPARATORS: &str = " \u{00a0}/·・-_";

fn alpha(c: char) -> bool {
    matches!(
        get_general_category(c),
        GeneralCategory::UppercaseLetter
            | GeneralCategory::LowercaseLetter
            | GeneralCategory::TitlecaseLetter
            | GeneralCategory::ModifierLetter
            | GeneralCategory::OtherLetter
    )
}
fn whitespace(c: char) -> bool {
    c.is_whitespace() || ('\u{001c}'..='\u{001f}').contains(&c)
}
fn words(s: &str) -> Vec<&str> {
    s.split(whitespace).filter(|s| !s.is_empty()).collect()
}
fn lower(s: &str) -> bool {
    s.chars().any(char::is_lowercase)
        && !s.chars().any(|c| {
            c.is_uppercase() || get_general_category(c) == GeneralCategory::TitlecaseLetter
        })
}
fn len(s: &str) -> usize {
    s.chars().count()
}

pub fn fold(s: &str) -> String {
    let decomposed: String = s
        .nfd()
        .filter(|c| canonical_combining_class(*c) == 0)
        .filter_map(|c| {
            if ".'’ʼ,()".contains(c) {
                None
            } else if "-‐‑‒–—_/".contains(c) {
                Some(' ')
            } else {
                Some(c)
            }
        })
        .collect();
    words(&decomposed.to_lowercase()).join(" ").nfc().collect()
}

fn clean_value(value: &str) -> String {
    let visible: String = value
        .chars()
        .filter(|c| {
            !matches!(*c as u32,
        0x200b..=0x200f | 0x202a..=0x202e | 0x2066..=0x2069 | 0xfeff)
        })
        .collect();
    words(&visible)
        .join(" ")
        .trim_matches(|c| EDGE_JUNK.contains(c))
        .trim_matches(whitespace)
        .to_owned()
}

const HAN: u8 = 1;
const KANA: u8 = 2;
const HANGUL: u8 = 4;
const CYRL: u8 = 8;
const LATN: u8 = 16;
const OTHER: u8 = 32;

fn script(c: char) -> u8 {
    match c as u32 {
        0x4e00..=0x9fff | 0x3400..=0x4dbf | 0xf900..=0xfaff => HAN,
        0x3040..=0x30ff => KANA,
        0xac00..=0xd7af | 0x1100..=0x11ff => HANGUL,
        0x0400..=0x04ff => CYRL,
        0..=0x024f | 0x1e00..=0x1eff => LATN,
        _ => OTHER,
    }
}
fn script_set(s: &str) -> u8 {
    s.chars()
        .filter(|c| alpha(*c))
        .fold(0, |set, c| set | script(c))
}
fn native_script(s: &str) -> Option<u8> {
    let set = script_set(s);
    (set != 0 && set & !(HAN | KANA | HANGUL) == 0).then_some(set)
}
fn slot(language: &str) -> Option<usize> {
    let canonical = match language {
        "zh" | "zh-Hans" | "zh-CN" => "zh-Hans",
        "zh-Hant" | "zh-TW" | "zh-HK" => "zh-Hant",
        "pt" | "pt-BR" => "pt-BR",
        other => other,
    };
    LANGUAGES.iter().position(|s| *s == canonical)
}
fn script_fits(value: &str, slot: usize) -> bool {
    let allowed = match slot {
        0 | 1 => HAN,
        2 => HAN | KANA,
        3 => HANGUL | HAN,
        7 => CYRL,
        _ => LATN,
    };
    script_set(value) & allowed != 0
}
fn native_rule(country: &str) -> Option<(u8, usize)> {
    match country {
        "CN" => Some((HAN, 0)),
        "TW" | "HK" | "MO" => Some((HAN, 1)),
        "JP" => Some((HAN | KANA, 2)),
        "KR" | "KP" => Some((HANGUL, 3)),
        _ => None,
    }
}
fn malformed(value: &str) -> bool {
    value.chars().filter(|c| "(（".contains(*c)).count()
        != value.chars().filter(|c| ")）".contains(*c)).count()
        || value.chars().any(|c| matches!(get_general_category(c), GeneralCategory::Format))
}

fn ethnic_prefix(tail: &str) -> Option<usize> {
    let positions: Vec<_> = tail
        .char_indices()
        .map(|(index, _)| index)
        .chain(std::iter::once(tail.len()))
        .collect();
    for count in (1..=4.min(positions.len() - 1)).rev() {
        let prefix = &tail[..positions[count]];
        if !prefix
            .chars()
            .all(|c| ('\u{4e00}'..='\u{9fff}').contains(&c))
        {
            continue;
        }
        let rest = &tail[positions[count]..];
        for suffix in ["民族", "族"] {
            if rest.starts_with(suffix) {
                return Some(positions[count] + suffix.len());
            }
        }
    }
    None
}
fn admin_tail(mut tail: &str) -> bool {
    tail = tail.trim_matches(|c| TAIL_SEPARATORS.contains(c));
    while !tail.is_empty() {
        if let Some(count) = ethnic_prefix(tail) {
            tail = tail[count..].trim_start_matches(|c| TAIL_SEPARATORS.contains(c));
            continue;
        }
        if let Some(unit) = rules::ADMIN_UNITS
            .iter()
            .find(|unit| tail.starts_with(**unit))
        {
            tail = tail[unit.len()..].trim_start_matches(|c| TAIL_SEPARATORS.contains(c));
        } else {
            return false;
        }
    }
    true
}
fn inflected(base: &str, full: &str, primary: Option<&str>) -> bool {
    let Some(primary) = primary.filter(|s| !s.is_empty()) else {
        return false;
    };
    if len(full) != len(base) + 1 || len(base) < 4 {
        return false;
    }
    let last_full = full
        .chars()
        .last()
        .unwrap()
        .to_lowercase()
        .collect::<String>();
    let last_base = base
        .chars()
        .last()
        .unwrap()
        .to_lowercase()
        .collect::<String>();
    if !"аеиоуыэюяё".contains(&last_full) || !"бвгджзйклмнпрстфхцчшщ".contains(&last_base)
    {
        return false;
    }
    primary
        .trim_end_matches(['.', ' '])
        .chars()
        .last()
        .is_some_and(|c| alpha(c) && !"aeiouy".contains(&c.to_lowercase().collect::<String>()))
}

type Bucket = Vec<(u8, String)>;
/// 拉丁语种名字前面的行政通名（「Ville de Saragosse」「Ciudad de La Coruña」）：与 `admin_tail` 对称，
/// 只用来在两个都由数据给出的名字里挑短的那个（Wikidata 把西班牙城市的「市」条目标成「Ville de …」，
/// GeoNames 给的「Saragosse」才是法国人说的名字）。
const BASE_GENERIC_HEADS: &[&str] = &[
    "Ville de ", "Ville d'", "Ville d’", "Ciudad de ", "Cidade de ", "Città di ", "City of ", "Stadt ", "Municipio de ",
    "Município de ", "Municipalité de ", "Kanton ", "Canton de ", "Distrito de ", "District de ", "Distrikt ",
];
const GENERIC_HEADS: &[&str] = &[
    "Kreisfreie Stadt ", "Stadtgemeinde ", "Municipio ", "Municipality of ", "Municipalidad de ",
    "Comune di ", "Commune de ", "Gemeente ", "Gmina ", "Kota ", "Kota praja ",
    "Thành phố ", "Thị xã ", "городской округ ", "городское поселение ",
    "District ", "Distrito ", "Distretto di ", "Distretto del ", "Kabupaten ", "Kabupaten de ",
    "Provincia de ", "Provincia di ", "Province de ", "Provinz ", "Provincie ",
    "Casco histórico de ", "Centro histórico de ", "Zona Histórica de ", "Distrito Histórico de ",
    "Cidade Histórica de ", "Cidade Antiga de ", "Administração Municipal dos ", "Bundestagswahlkreis ", "Bundeswahlkreis ",
];
const CITY_GENERIC_TAILS: &[&str] = &[
    "Şehri", "Kenti", "Belediyesi", "сити", "городской округ", "городское поселение",
    "городское самоуправление", "自治体", "自治體", "地方自治体", "地方自治體", "현",
    "Province", "Municipality", "District", "municipio", "município",
];
const MUNICIPAL_HEADS: &[&str] = &[
    "Ville de ", "Ville d'", "Ville d’", "Ciudad de ", "Cidade de ", "Città di ", "City of ", "Stadt ",
    "Municipio de ", "Município de ", "Municipalité de ", "Kreisfreie Stadt ", "Stadtgemeinde ",
    "Municipio ", "Municipality of ", "Municipalidad de ", "Comune di ", "Commune de ", "Gemeente ",
    "Kota ", "Kota praja ", "Thành phố ", "Thị xã ", "городской округ ", "городское поселение ",
    "Casco histórico de ", "Centro histórico de ", "Zona Histórica de ", "Distrito Histórico de ",
    "Cidade Histórica de ", "Cidade Antiga de ", "Administração Municipal dos ",
];
const MUNICIPAL_TAILS: &[&str] = &[
    "市", "廣域市", "広域市", "广域市", "特別市", "特别市", "特別自治市", "특별시", "광역시", "시",
    "Şehri", "Kenti", "Belediyesi", "сити", "городской округ", "городское поселение",
    "городское самоуправление", "自治体", "自治體", "地方自治体", "地方自治體", "Municipality",
];
fn equals_folded(left: &str, right: &str) -> bool {
    left.eq_ignore_ascii_case(right) || left.to_lowercase() == right.to_lowercase()
}
fn generic_head(head: &str, city: bool) -> bool {
    BASE_GENERIC_HEADS.iter().chain(if city { GENERIC_HEADS } else { &[] })
        .any(|unit| equals_folded(head, unit))
}
fn is_generic_shortening(full: &str, short: &str, city: bool) -> bool {
    len(short) >= 2 && len(short) < len(full)
        && ((full.starts_with(short) && {
            let tail = &full[short.len()..];
            admin_tail(tail) || (city && CITY_GENERIC_TAILS.iter().any(|unit| {
                equals_folded(tail.trim_matches(|c| TAIL_SEPARATORS.contains(c)), unit)
            }))
        }) || (full.ends_with(short) && generic_head(&full[..full.len() - short.len()], city)))
}
fn municipal_shortening(full: &str, short: &str) -> bool {
    len(short) >= 2 && len(short) < len(full)
        && ((full.starts_with(short) && MUNICIPAL_TAILS.iter().any(|unit| {
            equals_folded(full[short.len()..].trim_matches(|c| TAIL_SEPARATORS.contains(c)), unit)
        })) || (full.ends_with(short) && MUNICIPAL_HEADS.iter().any(|unit| {
            equals_folded(&full[..full.len() - short.len()], unit)
        })))
}
fn protected_city_primary(primary: &str) -> bool {
    // 数据主名保留 City、Town 或 Township 时，不能跨语言把它当成行政通名删去。
    [" City", " Town", " Township"].iter().any(|suffix| primary.ends_with(*suffix))
        || ["City of London", "Ciudad Juárez", "Ciudad Acuña"].contains(&primary)
}
fn choose_name(bucket: &mut Bucket, primary: Option<&str>) -> String {
    bucket.sort_by_key(|(rank, _)| *rank);
    let mut chosen = bucket[0].1.clone();
    let protected = primary.is_some_and(protected_city_primary);
    let mut ordered: Vec<_> = bucket.iter().map(|(_, name)| name).collect();
    ordered.sort_by_key(|name| len(name));
    loop {
        let shorter = ordered.iter().find(|other| {
            let n = len(other);
            n >= 2 && n < len(&chosen)
                && (!protected || primary == Some(other.as_str()))
                && ((chosen.starts_with(other.as_str()) && admin_tail(&chosen[other.len()..]))
                    || (chosen.ends_with(other.as_str())
                        && BASE_GENERIC_HEADS.iter().any(|unit| equals_folded(&chosen[..chosen.len() - other.len()], unit)))
                    || (primary.is_some() && municipal_shortening(&chosen, other))
                    || (chosen.starts_with(other.as_str()) && inflected(other, &chosen, primary)))
        });
        if let Some(name) = shorter {
            chosen = (*name).clone();
            continue;
        }
        // 主名只能去掉城市通名，不能把县、区或省名当成城市名。
        if let Some(name) = primary.filter(|name| municipal_shortening(&chosen, name)) {
            chosen = name.to_owned();
            continue;
        }
        return chosen;
    }
}
fn shrink_admin(mut base: String, names: &[String]) -> String {
    let mut ordered: Vec<_> = names.iter().collect();
    ordered.sort_by_key(|name| len(name));
    loop {
        let shorter = ordered.iter().find(|name| {
            len(name) >= 2
                && len(name) < len(&base)
                && base.starts_with(name.as_str())
                && admin_tail(&base[name.len()..])
        });
        match shorter {
            Some(name) => base = (*name).clone(),
            None => return base,
        }
    }
}

#[derive(Debug)]
struct City {
    population: i64,
    ascii: String,
    country: String,
    name: String,
    alternates: String,
    latitude: f64,
    longitude: f64,
    admin: String,
    timezone: String,
    id: String,
}
type Readings = HashMap<char, HashSet<String>>;
fn learn_pinyin(rows: &[City]) -> Readings {
    let mut readings: HashMap<char, HashMap<String, usize>> = HashMap::new();
    for city in rows {
        let parts: Vec<_> = city
            .alternates
            .split(',')
            .map(|p| p.trim_matches(whitespace))
            .filter(|p| !p.is_empty())
            .collect();
        let hans: Vec<_> = parts
            .iter()
            .filter(|p| native_script(p) == Some(HAN))
            .collect();
        let trans: Vec<_> = parts
            .iter()
            .filter(|p| lower(p) && p.contains(' ') && p.chars().all(|c| alpha(c) || c == ' '))
            .collect();
        for han in &hans {
            for text in &trans {
                let syllables = words(text);
                if syllables.len() != len(han) {
                    continue;
                }
                for (c, reading) in han.chars().zip(syllables) {
                    *readings
                        .entry(c)
                        .or_default()
                        .entry(reading.to_owned())
                        .or_default() += 1;
                }
            }
        }
    }
    readings
        .into_iter()
        .filter_map(|(c, counts)| {
            let floor = (0.05 * counts.values().sum::<usize>() as f64).max(2.0);
            let kept: HashSet<_> = counts
                .into_iter()
                .filter_map(|(reading, n)| (n as f64 >= floor).then_some(reading))
                .collect();
            (!kept.is_empty()).then_some((c, kept))
        })
        .collect()
}
fn pinyin_matches(han: &str, latin: &str, table: &Readings) -> bool {
    let target: String = latin.to_lowercase().chars().filter(|c| alpha(*c)).collect();
    if target.is_empty() {
        return false;
    }
    fn walk(han: &[char], target: &str, table: &Readings) -> bool {
        if han.is_empty() {
            return target.is_empty();
        }
        table.get(&han[0]).is_some_and(|readings| {
            readings.iter().any(|reading| {
                target
                    .strip_prefix(reading)
                    .is_some_and(|rest| walk(&han[1..], rest, table))
            })
        })
    }
    walk(&han.chars().collect::<Vec<_>>(), &target, table)
}
fn choose_native(bucket: &Bucket, primary: &str, table: &Readings) -> Option<String> {
    let mut names = Vec::new();
    for (_, name) in bucket {
        if !names.contains(name) {
            names.push(name.clone());
        }
    }
    if !primary.is_empty() && !table.is_empty() {
        let parts = words(primary);
        let targets: Vec<_> = (1..=parts.len()).map(|i| parts[..i].join(" ")).collect();
        let hits: Vec<_> = names
            .iter()
            .filter(|name| {
                targets
                    .iter()
                    .any(|target| pinyin_matches(name, target, table))
            })
            .collect();
        if hits.len() == 1 {
            return Some(shrink_admin(hits[0].clone(), &names));
        }
    }
    // Python max keeps the first element on ties.
    let base = names
        .iter()
        .enumerate()
        .max_by(|(ai, a), (bi, b)| len(a).cmp(&len(b)).then_with(|| bi.cmp(ai)))?
        .1;
    if names.iter().any(|name| !base.contains(name)) {
        return None;
    }
    Some(shrink_admin(base.clone(), &names))
}

fn alternate_budget(population: i64) -> usize {
    if population >= 500_000 {
        40
    } else if population >= 100_000 {
        24
    } else if population >= 15_000 {
        8
    } else {
        0
    }
}
fn pick_alternates(raw: &str, budget: usize, seen: &mut HashSet<String>) -> Vec<String> {
    let mut order = Vec::new();
    let mut encountered = HashSet::new();
    let mut native = HashSet::new();
    let mut latin = HashSet::new();
    for name in raw.split(',').map(|s| s.trim_matches(whitespace)) {
        let count = len(name);
        if !(2..=40).contains(&count) {
            continue;
        }
        let key = fold(name);
        if key.is_empty() || seen.contains(&key) {
            continue;
        }
        if encountered.insert(key.clone()) {
            order.push(key.clone());
        }
        if name.is_ascii() {
            if name.chars().filter(|c| *c == ' ').count() > 3 || count > 24 {
                continue;
            }
            if name.as_bytes()[0].is_ascii_uppercase()
                || (budget >= 40 && !name.contains(' ') && count <= 12)
            {
                latin.insert(key);
            }
        } else {
            native.insert(key);
        }
    }
    let mut output: Vec<_> = order
        .iter()
        .filter(|key| native.contains(*key))
        .cloned()
        .collect();
    output.extend(
        order
            .iter()
            .filter(|key| !native.contains(*key) && latin.contains(*key))
            .take(budget)
            .cloned(),
    );
    seen.extend(output.iter().cloned());
    output
}

fn secondary_keys(key: &str) -> Vec<String> {
    let parts: Vec<_> = key.split(' ').collect();
    let mut out: Vec<_> = (1..parts.len())
        .map(|index| parts[index..].join(" "))
        .collect();
    for (long, short) in [
        ("saint ", "st "),
        ("mount ", "mt "),
        ("fort ", "ft "),
        ("sankt ", "st "),
    ] {
        if let Some(rest) = key.strip_prefix(long) {
            out.push(format!("{short}{rest}"));
        } else if let Some(rest) = key.strip_prefix(short) {
            out.push(format!("{long}{rest}"));
        }
    }
    out
}

#[derive(Default)]
/// 文本池：按原样字节去重，每条按文种用符号表编码；编码不省字节或超 255 字节时原样存（表号 0）。
struct TextPool<'a> {
    bytes: Vec<u8>,
    offsets: HashMap<Vec<u8>, (u32, u8, u8)>,
    encoders: Vec<fsst::Encoder<'a>>,
}
impl<'a> TextPool<'a> {
    fn new(tables: &'a [fsst::Table]) -> Self {
        Self {
            bytes: Vec::new(),
            offsets: HashMap::new(),
            encoders: tables.iter().map(fsst::Table::encoder).collect(),
        }
    }
    /// 这条字符串早先写进池里了吗（逐字节相同）：本地化条目靠它转义引用而不是再写一遍。
    fn find(&self, text: &str) -> Option<(u32, u8, u8)> {
        self.offsets.get(&text.as_bytes()[..text.len().min(255)]).copied()
    }
    /// 把字符串追加到池末尾（不去重——城市名按记录顺序连续摆放，偏移才能由长度推出来），
    /// 返回（偏移, 编码后长度, 表号）；第一次出现的字符串记进查找表供 `find`。
    fn append(&mut self, text: &str) -> Result<(u32, u8, u8), String> {
        // Preserve TTCITY07's byte truncation rule, including its 255-byte field limit.
        let raw = &text.as_bytes()[..text.len().min(255)];
        if raw.is_empty() {
            return Err("an empty string cannot be stored in the text pool".into());
        }
        let class = script_class(raw);
        let mut coded = Vec::with_capacity(raw.len());
        self.encoders[class as usize - 1].encode(raw, &mut coded);
        let (stored, class): (&[u8], u8) = if coded.len() < raw.len() && coded.len() <= 255 {
            (&coded, class)
        } else {
            (raw, 0)
        };
        let entry = (self.bytes.len() as u32, stored.len() as u8, class);
        self.bytes.extend_from_slice(stored);
        self.offsets.entry(raw.to_vec()).or_insert(entry);
        Ok(entry)
    }
}
fn u32le(out: &mut Vec<u8>, value: usize) {
    out.extend_from_slice(&(value as u32).to_le_bytes());
}
fn u16le(out: &mut Vec<u8>, value: usize) {
    out.extend_from_slice(&(value as u16).to_le_bytes());
}
/// Offsets and counts that fit 24 bits; anything wider is a hard build error rather than a
/// silently truncated index.
fn u24le(out: &mut Vec<u8>, value: usize, what: &str) -> Result<(), String> {
    if value > MAX_U24 {
        return Err(format!("{what} {value} exceeds the 24-bit limit"));
    }
    out.extend_from_slice(&(value as u32).to_le_bytes()[..3]);
    Ok(())
}
/// 有符号 24 位（补码）。
fn i24le(out: &mut Vec<u8>, value: i32, what: &str) -> Result<(), String> {
    if !(-0x80_0000..0x80_0000).contains(&value) {
        return Err(format!("{what} {value} exceeds the signed 24-bit range"));
    }
    out.extend_from_slice(&value.to_le_bytes()[..3]);
    Ok(())
}
/// Small unsigned field of the key text: one byte below 255, otherwise `0xff` + u16.
fn push_small(out: &mut Vec<u8>, value: usize, what: &str) -> Result<(), String> {
    match value {
        0..=254 => out.push(value as u8),
        255..=65535 => {
            out.push(0xff);
            out.extend_from_slice(&(value as u16).to_le_bytes());
        }
        _ => return Err(format!("{what} {value} exceeds the u16 limit")),
    }
    Ok(())
}
/// 坐标定点值：与 TTCITY07–09 一样先过一遍 f32（生成与转码走同一条路，黄金夹具才逐字节相等）。
fn fixed_coordinate(degrees: f32) -> i32 {
    (degrees as f64 * ttcity::COORDINATE_SCALE).round() as i32
}
/// 一个键块用哪张表：按各键（整键）文种的字节数取多数，平局取小的类别。
fn block_class(keys: &[&[u8]]) -> u8 {
    let mut weight = [0usize; ttcity::SCRIPT_CLASSES + 1];
    for key in keys {
        weight[script_class(key) as usize] += key.len();
    }
    (1..=ttcity::SCRIPT_CLASSES)
        .max_by(|a, b| weight[*a].cmp(&weight[*b]).then(b.cmp(a)))
        .unwrap_or(1) as u8
}
/// Front-codes sorted keys into `KEY_BLOCK`-sized blocks. Returns the block table (one
/// 6-byte entry per block plus a sentinel) and the key text. Postings must already be laid
/// out in the same key order; only their counts are stored here. Each block opens with its
/// table byte; suffixes are symbol-coded with that table unless raw bytes are shorter.
fn encode_keys(
    keys: &[(Vec<u8>, Vec<u32>)],
    encoders: &[fsst::Encoder<'_>],
) -> Result<(Vec<u8>, Vec<u8>), String> {
    let (mut entries, mut text) = (Vec::new(), Vec::new());
    let mut postings = 0usize;
    for (ordinal, pair) in keys.windows(2).enumerate() {
        if pair[0].0 >= pair[1].0 {
            return Err(format!(
                "search keys are not strictly sorted at {:?}",
                pair[1].0
            ));
        }
        let _ = ordinal;
    }
    for block in keys.chunks(KEY_BLOCK) {
        u24le(&mut entries, text.len(), "key text offset")?;
        u24le(&mut entries, postings, "posting index")?;
        let whole: Vec<&[u8]> = block.iter().map(|(k, _)| k.as_slice()).collect();
        let class = block_class(&whole);
        // 两种编法都试：用表编、原样；整块取短的那种（同一块里文种混杂时表可能反而更长）。
        // 试编会给符号标「用过」；整块最后按原样存时要退回去，表里不能留死符号。
        let snapshot = if class > 0 { Some(encoders[class as usize - 1].used()) } else { None };
        let mut best: Option<Vec<u8>> = None;
        let mut best_candidate = 0u8;
        for candidate in [class, 0] {
            let mut body = vec![candidate];
            let mut coded = Vec::new();
            for (slot, (key, values)) in block.iter().enumerate() {
                if slot == 0 {
                    push_small(&mut body, key.len(), "key length")?;
                    body.extend_from_slice(key);
                    push_small(&mut body, values.len(), "posting count")?;
                    continue;
                }
                let previous = &block[slot - 1].0;
                let shared = key
                    .iter()
                    .zip(previous)
                    .take_while(|(a, b)| a == b)
                    .count();
                coded.clear();
                if candidate == 0 {
                    coded.extend_from_slice(&key[shared..]);
                } else {
                    encoders[candidate as usize - 1].encode(&key[shared..], &mut coded);
                }
                let count = values.len();
                let lcp_code = if shared < 15 { shared as u8 } else { 15 };
                let len_code = match (coded.len(), count) {
                    (1..=14, 1) => coded.len() as u8,
                    (_, 1) => 15,
                    _ => 0,
                };
                body.push(lcp_code << 4 | len_code);
                if lcp_code == 15 {
                    push_small(&mut body, shared, "shared prefix length")?;
                }
                if len_code == 0 || len_code == 15 {
                    push_small(&mut body, coded.len(), "key suffix length")?;
                }
                if len_code == 0 {
                    push_small(&mut body, count, "posting count")?;
                }
                body.extend_from_slice(&coded);
            }
            if best.as_ref().is_none_or(|b| body.len() < b.len()) {
                best = Some(body);
                best_candidate = candidate;
            }
        }
        if best_candidate == 0 {
            if let (Some(snapshot), true) = (snapshot, class > 0) {
                encoders[class as usize - 1].restore(snapshot);
            }
        }
        text.extend_from_slice(&best.unwrap_or_default());
        postings += block.iter().map(|(_, v)| v.len()).sum::<usize>();
    }
    u24le(&mut entries, text.len(), "key text offset")?;
    u24le(&mut entries, postings, "posting index")?;
    Ok((entries, text))
}
fn blobs(items: impl IntoIterator<Item = impl AsRef<str>>) -> (Vec<u8>, Vec<u8>) {
    let (mut entries, mut text) = (Vec::new(), Vec::new());
    for item in items {
        let bytes = item.as_ref().as_bytes();
        u32le(&mut entries, text.len());
        u16le(&mut entries, bytes.len());
        text.extend_from_slice(bytes);
    }
    (entries, text)
}
/// Localized entries are 8 bytes: key u24, text offset u24, coded length u8, table byte.
/// `data/<name>`：Wikidata 标签表，每行 `geonameid\t语言\t标签\tstrong|weak`（`Tools/wikidata_labels.py resolve` 生成，
/// 语言已归到索引的九个槽位）。运行时读文件而不是 `include_str!`：表有十几 MB，只有生成器需要它。
/// （GeoNames ID, 语言槽位, 标签, strong）。
pub type WikidataLabel = (String, usize, String, bool);
fn wikidata_labels(name: &str) -> Result<Vec<WikidataLabel>, Box<dyn Error>> {
    Ok(wikidata_rows(name)?.0)
}

/// 「确认」行（`same`）：Wikidata 在这种语言里的写法逐字就是 GeoNames 主名（`Tools/wikidata_labels.py confirm`，
/// 只收 GeoNames 别名表里这种语言另有名字的那些）。全量构建不读它（主名本来就不进候选），「加语言」时有确认的城市
/// 不让别名表改名（「Kırıkkale」在印尼语别名表里是去掉变音符号的「Kirikkale」，Wikidata 印尼语写 Kırıkkale）。
/// （GeoNames ID, 语言槽位）。
pub type Confirmation = (String, usize);

fn wikidata_rows(name: &str) -> Result<(Vec<WikidataLabel>, Vec<Confirmation>), Box<dyn Error>> {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("data").join(name);
    let (mut rows, mut confirmations) = (Vec::new(), Vec::new());
    for (number, line) in BufReader::new(File::open(&path).map_err(|e| format!("{}: {e}", path.display()))?)
        .lines()
        .enumerate()
    {
        let line = line?;
        if line.starts_with('#') || line.trim().is_empty() {
            continue;
        }
        let fields: Vec<_> = line.split('\t').collect();
        let [id, language, label, strength] = fields[..] else {
            return Err(format!("{name} 第 {} 行不是四列", number + 1).into());
        };
        let slot = slot(language).ok_or_else(|| format!("{name} 第 {} 行的语言 {language} 不在索引的语言表里", number + 1))?;
        let strong = match strength {
            "strong" => true,
            "weak" => false,
            "same" => {
                confirmations.push((id.to_owned(), slot));
                continue;
            }
            other => return Err(format!("{name} 第 {} 行的强弱 {other} 只能是 strong / weak / same", number + 1).into()),
        };
        rows.push((id.to_owned(), slot, label.to_owned(), strong));
    }
    Ok((rows, confirmations))
}

/// 本地化条目（TTCITY12）：每语言一条字节流 + 一张稀疏索引，格式见 `ttcity.rs`。字符串第一次出现时顺着
/// 文本游标写进池里（条目只记长度），早已在池里的写成转义引用（长度 0 + u24 偏移 + u8 长度）。
fn emit_localized(
    tables: &[BTreeMap<usize, String>],
    text: &mut TextPool<'_>,
) -> Result<(Vec<u8>, Vec<u8>), String> {
    let mut streams = Vec::new();
    let mut spec = Vec::with_capacity(tables.len());
    for table in tables {
        let start = streams.len();
        let mut index = Vec::with_capacity(ttcity::localized_index_len(table.len()));
        let mut previous = 0usize;
        for (k, (key, value)) in table.iter().enumerate() {
            if k % ttcity::LOCALIZED_GROUP == 0 {
                u24le(&mut index, *key, "localized key")?;
                u24le(&mut index, streams.len() - start, "localized stream offset")?;
                u24le(&mut index, text.bytes.len(), "localized text cursor")?;
                ttcity::push_varint(&mut streams, *key);
            } else {
                ttcity::push_varint(&mut streams, *key - previous - 1);
            }
            previous = *key;
            if let Some((offset, length, class)) = text.find(value) {
                streams.push(0);
                u24le(&mut streams, offset as usize, "localized text offset")?;
                streams.extend_from_slice(&[length, class]);
            } else {
                let cursor = text.bytes.len();
                let (offset, length, class) = text.append(value)?;
                debug_assert_eq!(offset as usize, cursor);
                streams.extend_from_slice(&[length, class]);
            }
        }
        spec.push((start, streams.len() - start, index, table.len()));
    }
    // 稀疏索引接在全部流之后，范围表记下各自的起点。
    let (mut ranges, mut entries) = (Vec::with_capacity(tables.len() * ttcity::LOCALIZED_RANGE), streams);
    for (start, len, index, count) in spec {
        u32le(&mut ranges, start);
        u32le(&mut ranges, len);
        u32le(&mut ranges, entries.len());
        u32le(&mut ranges, count);
        entries.extend_from_slice(&index);
    }
    Ok((ranges, entries))
}

/// 一条搜索键补丁：(主名, 国家码, 要补成次名键的名字)。表在 `index_builder_rules.rs` 的
/// `SEARCH_KEY_ERRATA`；名字在这里过与 `pick_alternates` 同一个 `fold`，补出来的键不可能和
/// 生成器本来会建的键有出入。
pub type SearchKeyErratum = (&'static str, &'static str, &'static [&'static str]);

/// 一次转码对搜索键做了什么，CLI 打印、测试钉住。
#[derive(Debug, Default, PartialEq, Eq)]
pub struct PatchReport {
    /// 原本不存在、这次新建的键。
    pub keys_added: usize,
    /// 插入的倒排数，每个（城市, 名字）一条，不分新键旧键。
    pub postings_added: usize,
    /// 键已经带着这座城市的名字：什么都没改（重跑幂等）。
    pub already_present: usize,
}

/// 一座城市在索引里的全部字段（名字已解码；坐标保留 f32 精度）。
#[derive(Clone, Debug, PartialEq)]
struct CityRow {
    name: String,
    admin: usize,
    timezone: usize,
    country: usize,
    latitude: f32,
    longitude: f32,
}
/// 索引的逻辑内容：从 GeoNames 推导出来，或从既有 TTCITY07–10 镜像解出来；`write_image` 把它序列化成
/// TTCITY10。生成与转码走同一个序列化器，所以黄金夹具的两条路逐字节相等。倒排值为
/// `city | PRIMARY_BIT`（主名命中带位）。
#[derive(Clone, Debug, PartialEq)]
struct Model {
    cities: Vec<CityRow>,
    keys: Vec<(Vec<u8>, Vec<u32>)>,
    timezones: Vec<String>,
    countries: Vec<String>,
    languages: Vec<String>,
    admins: Vec<String>,
    representatives: Vec<u32>,
    /// 每国最多 8 座（人口序）。
    country_tops: Vec<Vec<u32>>,
    localized: Vec<BTreeMap<usize, String>>,
    admin_localized: Vec<BTreeMap<usize, String>>,
}
fn le32(b: &[u8], at: usize) -> usize {
    u32::from_le_bytes(b[at..at + 4].try_into().unwrap()) as usize
}
fn le16(b: &[u8], at: usize) -> usize {
    u16::from_le_bytes(b[at..at + 2].try_into().unwrap()) as usize
}
fn le24(b: &[u8], at: usize) -> usize {
    b[at] as usize | (b[at + 1] as usize) << 8 | (b[at + 2] as usize) << 16
}
fn le24s(b: &[u8], at: usize) -> i32 {
    let raw = le24(b, at) as i32;
    if raw >= 0x80_0000 {
        raw - 0x100_0000
    } else {
        raw
    }
}
/// 键文本里的小字段：255 以下占 1 字节，否则 `0xff` + u16。
fn small(b: &[u8], at: &mut usize) -> Result<usize, String> {
    let first = *b.get(*at).ok_or("key text is truncated")? as usize;
    *at += 1;
    if first != 0xff {
        return Ok(first);
    }
    let wide = b
        .get(*at..*at + 2)
        .map(|w| u16::from_le_bytes([w[0], w[1]]) as usize)
        .ok_or("key text is truncated")?;
    *at += 2;
    Ok(wide)
}

/// 每张表按文种学一次；没有该文种字符串的类别得到空表（编码全转义，`TextPool` 会退回原样）。
fn learn_tables<'a>(strings: impl Iterator<Item = &'a [u8]>) -> Vec<fsst::Table> {
    let mut groups: Vec<Vec<&[u8]>> = vec![Vec::new(); ttcity::SCRIPT_CLASSES];
    let mut seen: HashSet<&[u8]> = HashSet::new();
    for s in strings {
        if seen.insert(s) {
            groups[script_class(s) as usize - 1].push(s);
        }
    }
    groups
        .iter()
        .map(|g| fsst::Table::learn(g.iter().copied()))
        .collect()
}

/// 把逻辑内容写成 TTCITY10 镜像。
fn write_image(model: &Model) -> Result<Vec<u8>, String> {
    let Model {
        cities,
        keys,
        timezones,
        countries,
        languages,
        admins,
        representatives,
        country_tops,
        localized,
        admin_localized,
    } = model;
    if cities.len() >= MAX_CITIES {
        return Err(format!(
            "{} cities exceed the posting limit of {MAX_CITIES}",
            cities.len()
        ));
    }
    if countries.len() > 255 {
        return Err(format!("{} countries exceed the u8 limit", countries.len()));
    }
    if timezones.len() >= ttcity::TIMEZONE_LIMIT || admins.len() >= ttcity::ADMIN_NONE {
        return Err("timezone table exceeds 9 bits or admin table exceeds 12 bits".into());
    }
    if representatives.len() != timezones.len() || country_tops.len() != countries.len() {
        return Err("representative or country-top table length mismatch".into());
    }
    if localized.len() != languages.len() || admin_localized.len() != languages.len() {
        return Err("localized table count does not match the language list".into());
    }
    // 文本表：城市名、本地化名、行政区本地化名（去重后按首次出现的顺序）。键表：后缀按其整键的文种分组。
    fn truncated(s: &String) -> &[u8] {
        &s.as_bytes()[..s.len().min(255)]
    }
    let text_tables = learn_tables(
        cities
            .iter()
            .map(|c| truncated(&c.name))
            .chain(localized.iter().flat_map(|t| t.values().map(truncated)))
            .chain(admin_localized.iter().flat_map(|t| t.values().map(truncated))),
    );
    let mut suffixes: Vec<Vec<u8>> = Vec::with_capacity(keys.len());
    for (ordinal, (key, _)) in keys.iter().enumerate() {
        let shared = if ordinal % KEY_BLOCK == 0 {
            0
        } else {
            key.iter()
                .zip(&keys[ordinal - 1].0)
                .take_while(|(a, b)| a == b)
                .count()
        };
        suffixes.push(key[shared..].to_vec());
    }
    let key_tables = {
        let mut groups: Vec<Vec<&[u8]>> = vec![Vec::new(); ttcity::SCRIPT_CLASSES];
        for ((key, _), suffix) in keys.iter().zip(&suffixes) {
            if !suffix.is_empty() {
                groups[script_class(key) as usize - 1].push(suffix.as_slice());
            }
        }
        groups
            .iter()
            .map(|g| fsst::Table::learn(g.iter().copied()))
            .collect::<Vec<_>>()
    };
    // 两遍：第一遍记下每张表实际用到的符号，剪掉没用的再编第二遍（切分不变，表里不留死符号）。
    type Usage = Vec<[bool; 256]>;
    let emit = |text_tables: &[fsst::Table], key_tables: &[fsst::Table]| -> Result<(Vec<Vec<u8>>, Usage, Usage), String> {
        let mut text = TextPool::new(text_tables);
        let key_encoders: Vec<_> = key_tables.iter().map(fsst::Table::encoder).collect();
        // 列式记录（TTCITY12）：五列各自连续，读取端按 `ttcity::record_columns` 定位。城市名按记录顺序
        // 连续写进文本池（不去重），记录里只留编码后长度，每 256 条一个 u32 基址。
        let (mut lens, mut packed, mut lats, mut lons, mut bases) = (
            Vec::with_capacity(cities.len()),
            Vec::with_capacity(cities.len() * 4),
            Vec::with_capacity(cities.len() * 3),
            Vec::with_capacity(cities.len() * 3),
            Vec::with_capacity(cities.len().div_ceil(ttcity::CITY_BASE_GROUP) * 4),
        );
        for (i, city) in cities.iter().enumerate() {
            if city.country >= countries.len()
                || city.timezone >= timezones.len()
                || (city.admin != 0xffff && city.admin >= admins.len())
            {
                return Err("city row points outside its lookup tables".into());
            }
            let (offset, length, class) = text.append(&city.name)?;
            if i % ttcity::CITY_BASE_GROUP == 0 {
                u32le(&mut bases, offset as usize);
            }
            lens.push(length);
            let admin = if city.admin == 0xffff { ttcity::ADMIN_NONE } else { city.admin };
            u32le(&mut packed, ttcity::pack_fields(admin, city.timezone, city.country, class) as usize);
            i24le(&mut lats, fixed_coordinate(city.latitude), "latitude")?;
            i24le(&mut lons, fixed_coordinate(city.longitude), "longitude")?;
        }
        let mut city_blob = lens;
        city_blob.extend(packed);
        city_blob.extend(lats);
        city_blob.extend(lons);
        city_blob.extend(bases);
        debug_assert_eq!(city_blob.len(), ttcity::city_blob_len(cities.len()));
        let (key_entries, key_blob) = encode_keys(keys, &key_encoders)?;
        let (localized_ranges, localized_entries) = emit_localized(localized, &mut text)?;
        let (admin_localized_ranges, admin_localized_entries) =
            emit_localized(admin_localized, &mut text)?;
        if text.bytes.len() > MAX_U24 {
            return Err(format!(
                "text pool {} bytes exceeds the 24-bit limit",
                text.bytes.len()
            ));
        }
        let text_used = text.encoders.iter().map(fsst::Encoder::used).collect();
        let key_used = key_encoders.iter().map(fsst::Encoder::used).collect();
        Ok((
            vec![
                city_blob,
                key_entries,
                key_blob,
                text.bytes,
                localized_ranges,
                localized_entries,
                admin_localized_ranges,
                admin_localized_entries,
            ],
            text_used,
            key_used,
        ))
    };
    let (_, text_used, key_used) = emit(&text_tables, &key_tables)?;
    let prune = |tables: &[fsst::Table], used: &[[bool; 256]]| -> Vec<fsst::Table> {
        tables.iter().zip(used).map(|(t, u)| t.retain(u)).collect()
    };
    let (text_tables, key_tables) = (prune(&text_tables, &text_used), prune(&key_tables, &key_used));
    let (parts, _, _) = emit(&text_tables, &key_tables)?;
    let [city_blob, key_entries, key_blob, text_bytes, localized_ranges, localized_entries, admin_localized_ranges, admin_localized_entries]: [Vec<u8>; 8] =
        parts.try_into().map_err(|_| "emit returned the wrong number of parts")?;
    // 倒排按 20 位一条连续排列（19 位记录号 + 主名标志），末尾 3 个零字节给读取端整字读。
    let posting_count: usize = keys.iter().map(|(_, v)| v.len()).sum();
    let mut posting_blob = vec![0u8; ttcity::posting_bytes(posting_count)];
    for (k, value) in keys.iter().flat_map(|(_, values)| values).enumerate() {
        let id = (*value & !PRIMARY_BIT) as usize;
        if id >= cities.len() {
            return Err(format!("posting {value:#x} points past the city table"));
        }
        if id >= ttcity::POSTING_LIMIT {
            return Err(format!("posting {id} exceeds the 19-bit record number"));
        }
        let coded = id as u32 | if *value & PRIMARY_BIT != 0 { ttcity::POSTING_PRIMARY } else { 0 };
        let bit = k * ttcity::POSTING_BITS;
        let (byte, shift) = (bit / 8, bit % 8);
        let mut word = u32::from_le_bytes(posting_blob[byte..byte + 4].try_into().unwrap());
        word |= coded << shift;
        posting_blob[byte..byte + 4].copy_from_slice(&word.to_le_bytes());
    }
    let representatives_blob: Vec<u8> = representatives
        .iter()
        .flat_map(|value| value.to_le_bytes())
        .collect();
    let country_top_blob: Vec<u8> = country_tops
        .iter()
        .flat_map(|top| {
            top.iter()
                .copied()
                .chain(std::iter::repeat(u32::MAX))
                .take(8)
                .flat_map(u32::to_le_bytes)
        })
        .collect();
    if country_tops.iter().any(|top| top.len() > 8) {
        return Err("a country lists more than 8 top cities".into());
    }
    let (language_entries, language_blob) = blobs(languages);
    let (timezone_entries, timezone_blob) = blobs(timezones);
    let (country_entries, country_blob) = blobs(countries);
    let (admin_entries, admin_blob) = blobs(admins);
    let mut symbol_tables = vec![ttcity::TABLE_COUNT as u8];
    for table in text_tables.iter().chain(&key_tables) {
        table.serialize(&mut symbol_tables);
    }
    let mut output = vec![0; ttcity::HEADER];
    let mut offsets = Vec::new();
    for part in [
        city_blob,
        key_entries,
        key_blob,
        posting_blob,
        text_bytes,
        timezone_entries,
        timezone_blob,
        country_entries,
        country_blob,
        representatives_blob,
        country_top_blob,
        localized_ranges,
        localized_entries,
        language_entries,
        language_blob,
        admin_entries,
        admin_blob,
        admin_localized_ranges,
        admin_localized_entries,
        symbol_tables,
    ] {
        output.resize((output.len() + 7) & !7, 0);
        offsets.push(output.len());
        output.extend_from_slice(&part);
    }
    if offsets.len() != ttcity::SECTIONS {
        return Err("section count mismatch".into());
    }
    let mut header = ttcity::MAGIC.to_vec();
    for value in [
        ttcity::VERSION as usize,
        cities.len(),
        keys.len(),
        timezones.len(),
        countries.len(),
        languages.len(),
        admins.len(),
    ]
    .into_iter()
    .chain(offsets)
    {
        u32le(&mut header, value);
    }
    output[..header.len()].copy_from_slice(&header);
    Ok(output)
}

/// 读入完整的 TTCITY07/08/09/10 镜像。各表推导长度之外的填充字节必须为零，输入里多出的字节
/// 报错而不是被静默丢掉；每个键块的倒排数也必须与块表逐一对得上。
fn read_image(input: &[u8]) -> Result<Model, String> {
    let u32_at = |at: usize| -> Result<usize, String> {
        input
            .get(at..at + 4)
            .map(|b| u32::from_le_bytes(b.try_into().unwrap()) as usize)
            .ok_or_else(|| format!("image truncated at byte {at}"))
    };
    let version = match input.get(..8) {
        Some(b"TTCITY07") if input.len() > 128 && u32_at(8)? == 7 => 7,
        Some(b"TTCITY08") if input.len() > 128 && u32_at(8)? == 8 => 8,
        Some(b"TTCITY09") if input.len() > 128 && u32_at(8)? == 9 => 9,
        Some(b"TTCITY10") if input.len() > 128 && u32_at(8)? == 10 => 10,
        Some(b"TTCITY11") if input.len() > 128 && u32_at(8)? == 11 => 11,
        Some(b"TTCITY12") if input.len() > 128 && u32_at(8)? == 12 => 12,
        _ => return Err("input is not a TTCITY07, TTCITY08, TTCITY09, TTCITY10 or TTCITY11 image".into()),
    };
    let section_count = if version >= 10 { ttcity::SECTIONS } else { 19 };
    let mut counts = [0usize; 6];
    for (i, count) in counts.iter_mut().enumerate() {
        *count = u32_at(12 + i * 4)?;
    }
    let mut sections = vec![0usize; section_count + 1];
    for (i, section) in sections.iter_mut().take(section_count).enumerate() {
        *section = u32_at(36 + i * 4)?;
    }
    sections[section_count] = input.len();
    if sections[0] < 128 || sections.windows(2).any(|p| p[0] > p[1]) {
        return Err("section offsets are not monotonic".into());
    }
    let [cities, keys, timezones, countries, languages, admins] = counts;
    // 恰好取一段的 `len` 字节，并坚持余下部分只能是对齐填充。
    let part = |section: usize, len: usize| -> Result<&[u8], String> {
        let start = sections[section];
        let end = start
            .checked_add(len)
            .filter(|end| *end <= sections[section + 1])
            .ok_or_else(|| format!("section {section} is shorter than its content"))?;
        if input[end..sections[section + 1]].iter().any(|b| *b != 0) {
            return Err(format!(
                "section {section} carries bytes beyond its derived length"
            ));
        }
        Ok(&input[start..end])
    };
    // 段 19：符号表（TTCITY10 起才有）。
    let tables: Vec<fsst::Table> = if version >= 10 {
        let raw = &input[sections[19]..sections[20]];
        if raw.first().copied() != Some(ttcity::TABLE_COUNT as u8) {
            return Err("symbol table count is wrong".into());
        }
        let mut at = 1;
        let mut tables = Vec::with_capacity(ttcity::TABLE_COUNT);
        for _ in 0..ttcity::TABLE_COUNT {
            tables.push(fsst::Table::parse(raw, &mut at).ok_or("symbol table is malformed")?);
        }
        part(19, at)?;
        tables
    } else {
        Vec::new()
    };
    let decode = |base: usize, class: u8, coded: &[u8]| -> Result<Vec<u8>, String> {
        if version < 10 {
            return Ok(coded.to_vec());
        }
        let mut out = Vec::with_capacity(coded.len() * 2);
        match class as usize {
            0 => out.extend_from_slice(coded),
            c if c <= ttcity::SCRIPT_CLASSES => tables[base + c - 1]
                .decode(coded, &mut out)
                .ok_or("string uses a code outside its symbol table")?,
            _ => return Err("string names a table that does not exist".into()),
        }
        Ok(out)
    };
    let record_width = match version { 12 => ttcity::CITY_RECORD, 11 => ttcity::CITY_RECORD_V11, 10 => 16, _ => 20 };
    let localized_width = if version == 7 { 12 } else { 8 };
    let city_blob = if version >= 12 {
        part(0, ttcity::city_blob_len(cities))?
    } else {
        part(0, cities.checked_mul(record_width).ok_or("city count overflow")?)?
    };
    // 键与倒排。
    let key_list: Vec<(Vec<u8>, Vec<u32>)> = if version >= 9 {
        // 前缀编码块：每块一条 6 字节表项加哨兵，按 `city_index::KeyCursor` 同样的顺序解码，
        // 每个块边界都交叉核对。
        // 旧镜像（TTCITY09 / 10）每块 32 条，TTCITY11 起 64 条：按输入版本走。
        let block_size = if version >= 11 { KEY_BLOCK } else { 32 };
        let blocks = keys.div_ceil(block_size);
        let key_entries = part(1, (blocks + 1) * 6)?;
        let entry = |b: usize| (le24(key_entries, b * 6), le24(key_entries, b * 6 + 3));
        let (key_blob_len, posting_count) = entry(blocks);
        let key_blob = part(2, key_blob_len)?;
        let postings_in = if version >= 11 {
            part(3, ttcity::posting_bytes(posting_count))?
        } else {
            part(3, posting_count * 3)?
        };
        // 20 位一条：读一个整字再移位；末尾的 3 个零字节保证最后一条也能整字读。
        let posting_at = |k: usize| -> Option<u32> {
            let bit = k * ttcity::POSTING_BITS;
            let (byte, shift) = (bit / 8, bit % 8);
            let word = u32::from_le_bytes(postings_in.get(byte..byte + 4)?.try_into().ok()?);
            let coded = (word >> shift) & ((1 << ttcity::POSTING_BITS) - 1);
            let id = coded & (ttcity::POSTING_PRIMARY - 1);
            Some(id | if coded & ttcity::POSTING_PRIMARY != 0 { PRIMARY_BIT } else { 0 })
        };
        let mut list: Vec<(Vec<u8>, Vec<u32>)> = Vec::with_capacity(keys);
        let mut posting = 0usize;
        for block in 0..blocks {
            let (mut at, first) = entry(block);
            let (end, _) = entry(block + 1);
            if first != posting || end < at || end > key_blob.len() {
                return Err(format!("key block {block} is not monotonic"));
            }
            let mut class = 0u8;
            if version >= 10 {
                class = *key_blob.get(at).ok_or("key block is empty")?;
                if class as usize > ttcity::SCRIPT_CLASSES {
                    return Err(format!("key block {block} names table {class}"));
                }
                at += 1;
            }
            let mut slot = 0;
            while at < end {
                if slot == block_size {
                    return Err(format!(
                        "key block {block} holds more than {block_size} records"
                    ));
                }
                let (key, count) = if slot == 0 {
                    let len = small(key_blob, &mut at)?;
                    let bytes = key_blob.get(at..at + len).ok_or("key text is truncated")?;
                    at += len;
                    (bytes.to_vec(), small(key_blob, &mut at)?)
                } else if version >= 10 {
                    let head = *key_blob.get(at).ok_or("key text is truncated")?;
                    at += 1;
                    let shared = match head >> 4 {
                        15 => small(key_blob, &mut at)?,
                        v => v as usize,
                    };
                    let (len, count) = match head & 15 {
                        0 => {
                            let len = small(key_blob, &mut at)?;
                            (len, small(key_blob, &mut at)?)
                        }
                        15 => (small(key_blob, &mut at)?, 1),
                        v => (v as usize, 1),
                    };
                    // 只认规范写法：能放进头字节的字段不许写成小字段，否则同一内容有两种字节。
                    if (head >> 4 == 15 && shared < 15)
                        || (head & 15 == 15 && (1..=14).contains(&len))
                        || (head & 15 == 0 && count == 1)
                    {
                        return Err(format!("key block {block} uses a non-canonical header"));
                    }
                    let previous = &list.last().unwrap().0;
                    if shared > previous.len() {
                        return Err(format!(
                            "key block {block} shares more than its previous key"
                        ));
                    }
                    let mut bytes = previous[..shared].to_vec();
                    let coded = key_blob.get(at..at + len).ok_or("key text is truncated")?;
                    bytes.extend(decode(ttcity::SCRIPT_CLASSES, class, coded)?);
                    at += len;
                    (bytes, count)
                } else {
                    let shared = small(key_blob, &mut at)?;
                    let len = small(key_blob, &mut at)?;
                    let previous = &list.last().unwrap().0;
                    if shared > previous.len() {
                        return Err(format!(
                            "key block {block} shares more than its previous key"
                        ));
                    }
                    let mut bytes = previous[..shared].to_vec();
                    bytes.extend_from_slice(
                        key_blob.get(at..at + len).ok_or("key text is truncated")?,
                    );
                    at += len;
                    (bytes, small(key_blob, &mut at)?)
                };
                let values: Vec<u32> = if version >= 11 {
                    (posting..posting + count)
                        .map(|k| posting_at(k).ok_or("postings are shorter than the key counts"))
                        .collect::<Result<_, _>>()?
                } else {
                    postings_in
                        .get(posting * 3..(posting + count) * 3)
                        .ok_or("postings are shorter than the key counts")?
                        .chunks(3)
                        .map(|p| le24(p, 0) as u32)
                        .collect()
                };
                list.push((key, values));
                posting += count;
                slot += 1;
            }
            if at != end {
                return Err(format!("key block {block} overruns its text"));
            }
        }
        // TTCITY11 的倒排按位排列：把解出来的值重新打包，必须与输入逐字节相同——末尾的补零与
        // 每条 20 位之外的位都不许有别的东西（读取端没有死字节这条性质靠它守住）。
        if version >= 11 {
            let mut expected = vec![0u8; ttcity::posting_bytes(posting_count)];
            for (k, value) in list.iter().flat_map(|(_, v)| v).enumerate() {
                let coded = (*value & !PRIMARY_BIT) | if *value & PRIMARY_BIT != 0 { ttcity::POSTING_PRIMARY } else { 0 };
                let bit = k * ttcity::POSTING_BITS;
                let (byte, shift) = (bit / 8, bit % 8);
                let mut word = u32::from_le_bytes(expected[byte..byte + 4].try_into().unwrap());
                word |= coded << shift;
                expected[byte..byte + 4].copy_from_slice(&word.to_le_bytes());
            }
            if expected.as_slice() != postings_in {
                return Err("postings carry stray bits or padding".into());
            }
        }
        if list.len() != keys || posting != posting_count {
            return Err(format!(
                "header promises {keys} keys / {posting_count} postings, blocks hold {} / {posting}",
                list.len()
            ));
        }
        list
    } else {
        let (entry_width, posting_width) = if version == 7 { (8, 4) } else { (6, 3) };
        let read_entry = |at: usize, b: &[u8]| -> (usize, usize) {
            if version == 7 {
                (le32(b, at), le32(b, at + 4))
            } else {
                (le24(b, at), le24(b, at + 3))
            }
        };
        let key_entries = part(1, (keys + 1) * entry_width)?;
        let (key_blob_len, posting_count) = read_entry(keys * entry_width, key_entries);
        let key_blob = part(2, key_blob_len)?;
        let postings_in = part(3, posting_count * posting_width)?;
        let posting_at = |j: usize| -> Result<u32, String> {
            let p = postings_in
                .get(j * posting_width..(j + 1) * posting_width)
                .ok_or("key entries point past the postings")?;
            let (city, primary) = if version == 7 {
                let raw = le32(p, 0);
                (raw & 0x7fff_ffff, raw & 0x8000_0000 != 0)
            } else {
                let raw = le24(p, 0);
                (raw & 0x7f_ffff, raw & 0x80_0000 != 0)
            };
            if city >= MAX_CITIES {
                return Err(format!(
                    "posting city index {city} exceeds the 23-bit limit"
                ));
            }
            Ok(city as u32 | if primary { PRIMARY_BIT } else { 0 })
        };
        (0..keys)
            .map(|i| {
                let (off, first) = read_entry(i * entry_width, key_entries);
                let (next_off, next_first) = read_entry((i + 1) * entry_width, key_entries);
                if next_off < off || next_first < first || next_off > key_blob.len() {
                    return Err(format!("key entry {i} is not monotonic"));
                }
                let values = (first..next_first)
                    .map(&posting_at)
                    .collect::<Result<Vec<_>, _>>()?;
                Ok((key_blob[off..next_off].to_vec(), values))
            })
            .collect::<Result<Vec<_>, _>>()?
    };
    // 本地化条目：先定下文本池的长度，再逐条解码。
    let ranges = |section: usize| part(section, languages * if version >= 12 { ttcity::LOCALIZED_RANGE } else { 8 });
    let entry_count = |ranges: &[u8]| {
        (0..languages)
            .map(|slot| le32(ranges, slot * 8) + le32(ranges, slot * 8 + 4))
            .max()
            .unwrap_or(0)
    };
    let localized_ranges = ranges(11)?;
    let admin_localized_ranges = ranges(17)?;
    // TTCITY12 的段 12 / 18 是流 + 稀疏索引，长度由范围表推出（流首尾相接、索引紧随其后）。
    let stream_section_len = |ranges: &[u8]| -> Result<usize, String> {
        let mut expected_stream = 0usize;
        let mut expected_index = None;
        for slot in 0..languages {
            let at = slot * ttcity::LOCALIZED_RANGE;
            let (start, len, index, count) = (le32(ranges, at), le32(ranges, at + 4), le32(ranges, at + 8), le32(ranges, at + 12));
            if start != expected_stream {
                return Err(format!("localized stream {slot} does not follow its predecessor"));
            }
            expected_stream = start + len;
            if let Some(expected) = expected_index {
                if index != expected {
                    return Err(format!("localized index {slot} does not follow its predecessor"));
                }
            }
            expected_index = Some(index + ttcity::localized_index_len(count));
        }
        let first_index = if languages > 0 { le32(ranges, 8) } else { 0 };
        if first_index != expected_stream {
            return Err("localized indexes do not start right after the streams".into());
        }
        Ok(expected_index.unwrap_or(0))
    };
    let (localized_in, admin_localized_in) = if version >= 12 {
        (
            part(12, stream_section_len(localized_ranges)?)?,
            part(18, stream_section_len(admin_localized_ranges)?)?,
        )
    } else {
        (
            part(12, entry_count(localized_ranges) * localized_width)?,
            part(18, entry_count(admin_localized_ranges) * localized_width)?,
        )
    };
    // 城市记录里的字段（版本相关）：文本偏移、编码后长度、表号。TTCITY12 的偏移由基址 + 长度前缀和推出，
    // 基址列必须与长度列完全一致（每个基址字节都被核过）。
    let columns = ttcity::record_columns(cities);
    let mut offsets12 = Vec::new();
    if version >= 12 {
        offsets12.reserve(cities);
        let mut cursor = 0usize;
        for i in 0..cities {
            if i % ttcity::CITY_BASE_GROUP == 0 {
                let base = le32(city_blob, columns[4] + (i / ttcity::CITY_BASE_GROUP) * 4);
                if base != cursor {
                    return Err(format!("city name base {} disagrees with the name lengths", i / ttcity::CITY_BASE_GROUP));
                }
            }
            offsets12.push(cursor);
            cursor += city_blob[columns[0] + i] as usize;
        }
    }
    let city_text = |i: usize| -> (usize, usize, u8) {
        if version >= 12 {
            let (_, _, _, class) = ttcity::unpack_fields(le32(city_blob, columns[1] + i * 4) as u32);
            (offsets12[i], city_blob[columns[0] + i] as usize, class)
        } else if version == 11 {
            let (_, _, _, class) = ttcity::unpack_fields(le32(city_blob, cities * 4 + i * 4) as u32);
            // TTCITY11 的文本指针列（u24 偏移 + u8 长度）在段 0 开头，每条 4 字节，打包字段列紧随其后。
            (le24(city_blob, i * 4), city_blob[i * 4 + 3] as usize, class)
        } else {
            let r = &city_blob[i * record_width..(i + 1) * record_width];
            if version == 10 {
                (le24(r, 0), r[3] as usize, r[9])
            } else {
                (le32(r, 0), r[18] as usize, 0)
            }
        }
    };
    let localized_fields = |e: &[u8]| -> (usize, usize, usize, u8) {
        match version {
            7 => (le32(e, 0), le32(e, 4), e[8] as usize, 0),
            10 | 11 => (le24(e, 0), le24(e, 3), e[6] as usize, e[7]),
            _ => (le24(e, 0), le24(e, 3), e[6] as usize, 0),
        }
    };
    let mut text_end = (0..cities)
        .map(|i| {
            let (offset, length, _) = city_text(i);
            offset + length
        })
        .max()
        .unwrap_or(0);
    // 本地化条目先解成（键、文本偏移、长度、表号）：TTCITY12 从流里解并逐项核对稀疏索引与文本游标
    // （游标从城市名末尾起、各语言首尾相接，转义引用只能指向游标之前），旧版本从定长条目里读。
    type Parsed = Vec<Vec<(usize, usize, usize, u8)>>;
    let mut cursor = text_end;
    let mut parse_localized = |ranges: &[u8], entries: &[u8]| -> Result<Parsed, String> {
        let mut out = Vec::with_capacity(languages);
        if version >= 12 {
            for slot in 0..languages {
                let at = slot * ttcity::LOCALIZED_RANGE;
                let (start, len, index_at, count) =
                    (le32(ranges, at), le32(ranges, at + 4), le32(ranges, at + 8), le32(ranges, at + 12));
                let stream = entries.get(start..start + len).ok_or("localized stream lies outside its section")?;
                let index = entries
                    .get(index_at..index_at + ttcity::localized_index_len(count))
                    .ok_or("localized index lies outside its section")?;
                let mut list = Vec::with_capacity(count);
                let (mut pos, mut previous) = (0usize, 0usize);
                for k in 0..count {
                    let key = if k % ttcity::LOCALIZED_GROUP == 0 {
                        let g = k / ttcity::LOCALIZED_GROUP * ttcity::LOCALIZED_INDEX_ENTRY;
                        if le24(index, g + 3) != pos || le24(index, g + 6) != cursor {
                            return Err(format!("localized index {slot}/{k} disagrees with the stream"));
                        }
                        let key = ttcity::read_varint(stream, &mut pos).ok_or("localized stream is truncated")?;
                        if le24(index, g) != key {
                            return Err(format!("localized index {slot}/{k} names another city"));
                        }
                        key
                    } else {
                        previous + ttcity::read_varint(stream, &mut pos).ok_or("localized stream is truncated")? + 1
                    };
                    if k > 0 && key <= previous {
                        return Err("localized entries are not strictly sorted by key".into());
                    }
                    previous = key;
                    let length = *stream.get(pos).ok_or("localized stream is truncated")? as usize;
                    pos += 1;
                    let (offset, length) = if length == 0 {
                        let escaped = stream.get(pos..pos + 4).ok_or("localized stream is truncated")?;
                        pos += 4;
                        let (offset, length) = (le24(escaped, 0), escaped[3] as usize);
                        if length == 0 || offset + length > cursor {
                            return Err("localized escape must point at an earlier string".into());
                        }
                        (offset, length)
                    } else {
                        cursor += length;
                        (cursor - length, length)
                    };
                    let class = *stream.get(pos).ok_or("localized stream is truncated")?;
                    pos += 1;
                    list.push((key, offset, length, class));
                }
                if pos != len {
                    return Err(format!("localized stream {slot} does not end with its last entry"));
                }
                out.push(list);
            }
            text_end = text_end.max(cursor);
            return Ok(out);
        }
        let mut expected_start = 0;
        for slot in 0..languages {
            let (start, count) = (le32(ranges, slot * 8), le32(ranges, slot * 8 + 4));
            // 各语言的范围首尾相接（生成器就这么写），空范围的起点也不许乱写。
            if start != expected_start {
                return Err(format!("localized range {slot} does not follow its predecessor"));
            }
            expected_start = start + count;
            let mut list = Vec::with_capacity(count);
            let mut previous = None;
            for j in start..start + count {
                let e = &entries[j * localized_width..(j + 1) * localized_width];
                let (key, offset, length, class) = localized_fields(e);
                let pad = match version {
                    7 => &e[9..12],
                    10 | 11 => &[][..],
                    _ => &e[7..8],
                };
                if pad.iter().any(|b| *b != 0) {
                    return Err("localized entry carries a non-zero pad byte".into());
                }
                if previous.is_some_and(|p| key <= p) {
                    return Err("localized entries are not strictly sorted by key".into());
                }
                previous = Some(key);
                text_end = text_end.max(offset + length);
                list.push((key, offset, length, class));
            }
            out.push(list);
        }
        Ok(out)
    };
    let localized_parsed = parse_localized(localized_ranges, localized_in)?;
    let admin_localized_parsed = parse_localized(admin_localized_ranges, admin_localized_in)?;
    let text = part(4, text_end)?;
    let table = |entries: usize, blob: usize, count: usize| -> Result<Vec<String>, String> {
        let e = part(entries, count * 6)?;
        let len = (0..count)
            .map(|i| le32(e, i * 6) + le16(e, i * 6 + 4))
            .max()
            .unwrap_or(0);
        let blob = part(blob, len)?;
        (0..count)
            .map(|i| {
                let (offset, length) = (le32(e, i * 6), le16(e, i * 6 + 4));
                String::from_utf8(blob[offset..offset + length].to_vec())
                    .map_err(|_| format!("table string {i} is not UTF-8"))
            })
            .collect()
    };
    let timezone_list = table(5, 6, timezones)?;
    let country_list = table(7, 8, countries)?;
    let language_list = table(13, 14, languages)?;
    let admin_list = table(15, 16, admins)?;
    let string = |offset: usize, length: usize, class: u8| -> Result<String, String> {
        let coded = text
            .get(offset..offset + length)
            .ok_or("string lies outside the text pool")?;
        let raw = decode(0, class, coded)?;
        // 生成器把每条字符串截到 255 字节再编码，解出来更长的只能是坏镜像。
        if raw.len() > 255 {
            return Err("string decodes to more than 255 bytes".into());
        }
        String::from_utf8(raw).map_err(|_| "string is not UTF-8".to_string())
    };
    let mut city_rows = Vec::with_capacity(cities);
    for i in 0..cities {
        let (offset, length, class) = city_text(i);
        let row = if version >= 11 {
            // TTCITY11 的四列：指针 4 B、打包 4 B、纬度 3 B、经度 3 B；TTCITY12 的五列见 `record_columns`。
            let (packed_at, lat_at, lon_at) = if version >= 12 {
                (columns[1], columns[2], columns[3])
            } else {
                (cities * 4, cities * 8, cities * 11)
            };
            let (admin, timezone, country, _) = ttcity::unpack_fields(le32(city_blob, packed_at + i * 4) as u32);
            CityRow {
                name: string(offset, length, class)?,
                admin: if admin == ttcity::ADMIN_NONE { 0xffff } else { admin },
                timezone,
                country,
                latitude: le24s(city_blob, lat_at + i * 3) as f32 / ttcity::COORDINATE_SCALE as f32,
                longitude: le24s(city_blob, lon_at + i * 3) as f32 / ttcity::COORDINATE_SCALE as f32,
            }
        } else if version == 10 {
            let r = &city_blob[i * record_width..(i + 1) * record_width];
            CityRow {
                name: string(offset, length, class)?,
                admin: le16(r, 4),
                timezone: le16(r, 6),
                country: r[8] as usize,
                latitude: le24s(r, 10) as f32 / ttcity::COORDINATE_SCALE as f32,
                longitude: le24s(r, 13) as f32 / ttcity::COORDINATE_SCALE as f32,
            }
        } else {
            let r = &city_blob[i * record_width..(i + 1) * record_width];
            if r[19] != 0 {
                return Err(format!("city {i} carries a non-zero pad byte"));
            }
            CityRow {
                name: string(offset, length, 0)?,
                admin: le16(r, 4),
                timezone: le16(r, 6),
                country: le16(r, 8),
                latitude: f32::from_le_bytes(r[10..14].try_into().unwrap()),
                longitude: f32::from_le_bytes(r[14..18].try_into().unwrap()),
            }
        };
        if row.country >= countries
            || row.timezone >= timezones
            || (row.admin != 0xffff && row.admin >= admins)
        {
            return Err(format!("city {i} points outside its lookup tables"));
        }
        city_rows.push(row);
    }
    let localized_tables = |parsed: Parsed| -> Result<Vec<BTreeMap<usize, String>>, String> {
        parsed
            .into_iter()
            .map(|list| {
                list.into_iter()
                    .map(|(key, offset, length, class)| Ok((key, string(offset, length, class)?)))
                    .collect()
            })
            .collect()
    };
    let representatives_in = part(9, timezones * 4)?;
    let representatives = (0..timezones)
        .map(|i| le32(representatives_in, i * 4) as u32)
        .collect();
    let tops_in = part(10, countries * 32)?;
    let mut country_tops = Vec::with_capacity(countries);
    for c in 0..countries {
        let values: Vec<u32> = (0..8).map(|k| le32(tops_in, c * 32 + k * 4) as u32).collect();
        let used = values.iter().position(|v| *v == u32::MAX).unwrap_or(8);
        if values[used..].iter().any(|v| *v != u32::MAX) {
            return Err(format!("country {c} lists a top city after the end marker"));
        }
        country_tops.push(values[..used].to_vec());
    }
    Ok(Model {
        cities: city_rows,
        keys: key_list,
        timezones: timezone_list,
        countries: country_list,
        languages: language_list,
        admins: admin_list,
        representatives,
        country_tops,
        localized: localized_tables(localized_parsed)?,
        admin_localized: localized_tables(admin_localized_parsed)?,
    })
}

/// 把补丁表的搜索键加进 `model.keys`。城市按主名 + 国家码找，必须恰好命中一条记录；折叠后的键
/// 已经带着这座城市就记作已存在，所以同一补丁重跑什么都不改。
fn patch_search_keys(
    model: &mut Model,
    patch: &[SearchKeyErratum],
) -> Result<PatchReport, String> {
    let mut report = PatchReport::default();
    if patch.is_empty() {
        return Ok(report);
    }
    if model.keys.windows(2).any(|pair| pair[0].0 >= pair[1].0) {
        return Err("search keys are not strictly sorted; refusing to patch".into());
    }
    for (name, country, names) in patch {
        let matches: Vec<usize> = model
            .cities
            .iter()
            .enumerate()
            .filter(|(_, c)| c.name == *name && model.countries[c.country] == *country)
            .map(|(i, _)| i)
            .collect();
        let &[city] = matches.as_slice() else {
            return Err(format!(
                "键补丁「{name}, {country}」命中 {} 座城市，须恰好一座",
                matches.len()
            ));
        };
        for raw in *names {
            let key = fold(raw).into_bytes();
            if key.is_empty() {
                return Err(format!(
                    "键补丁「{name}, {country}」的名字 {raw:?} 折叠后为空"
                ));
            }
            match model
                .keys
                .binary_search_by(|(k, _)| k.as_slice().cmp(key.as_slice()))
            {
                Ok(at) => {
                    let postings = &mut model.keys[at].1;
                    if postings
                        .iter()
                        .any(|p| (*p & !PRIMARY_BIT) as usize == city)
                    {
                        report.already_present += 1;
                    } else {
                        // 倒排按城市下标升序即人口序：前缀命中只读一个键的第一条倒排。
                        let slot =
                            postings.partition_point(|p| ((*p & !PRIMARY_BIT) as usize) < city);
                        postings.insert(slot, city as u32);
                        report.postings_added += 1;
                    }
                }
                Err(at) => {
                    model.keys.insert(at, (key, vec![city as u32]));
                    report.keys_added += 1;
                    report.postings_added += 1;
                }
            }
        }
    }
    Ok(report)
}

/// 主名只在封闭表内改选；旧主名倒排用于辨认重跑，所有搜索键和排序标记原样保留。
fn patch_primary_names(model: &mut Model, patch: &[(&str, &str, &str)]) -> Result<(), String> {
    for &(old, country, new) in patch {
        let has_key = |index: usize, name: &str| {
            let key = fold(name).into_bytes();
            model.keys.binary_search_by(|(k, _)| k.cmp(&key)).ok().is_some_and(|at| {
                model.keys[at].1.iter().any(|p| (*p & !PRIMARY_BIT) as usize == index)
            })
        };
        let originals: Vec<_> = model.cities.iter().enumerate()
            .filter(|(_, city)| city.name == old && model.countries[city.country] == country)
            .map(|(index, _)| index).collect();
        let matches = if originals.is_empty() {
            model.cities.iter().enumerate()
                .filter(|(index, city)| city.name == new && model.countries[city.country] == country
                    && has_key(*index, old))
                .map(|(index, _)| index).collect()
        } else { originals };
        let &[index] = matches.as_slice() else {
            return Err(format!("primary name erratum {old:?}, {country}: matched {} cities; expected one", matches.len()));
        };
        if !has_key(index, new) || !has_key(index, old) {
            return Err(format!("primary name erratum {old:?}, {country}: both {old:?} and {new:?} must already be search keys"));
        }
        model.cities[index].name = new.to_owned();
    }
    Ok(())
}

fn population_bucket(population: i64) -> u8 {
    if population < 1 {
        0
    } else {
        ((population as f64).ln() / 1.1_f64.ln()).round().clamp(1.0, 255.0) as u8
    }
}

fn build_fingerprint(image: &[u8], populations: &[u8]) -> [u8; ttcity::FINGERPRINT_LEN] {
    let mut first = ttcity::FNV_OFFSET_BASE;
    let mut second = ttcity::FNV_OFFSET_BASE_ALT;
    let bytes = image.iter().enumerate().map(|(at, &byte)| {
        if (ttcity::FINGERPRINT_OFFSET..ttcity::FINGERPRINT_OFFSET + ttcity::FINGERPRINT_LEN)
            .contains(&at)
        {
            0
        } else {
            byte
        }
    }).chain(populations.iter().copied());
    for byte in bytes {
        first = (first ^ u64::from(byte)).wrapping_mul(ttcity::FNV_PRIME);
        second = (second ^ u64::from(byte)).wrapping_mul(ttcity::FNV_PRIME);
    }
    let mut fingerprint = [0; ttcity::FINGERPRINT_LEN];
    fingerprint[..8].copy_from_slice(&first.to_le_bytes());
    fingerprint[8..].copy_from_slice(&second.to_le_bytes()[..4]);
    if fingerprint.iter().all(|&byte| byte == 0) {
        fingerprint[ttcity::FINGERPRINT_LEN - 1] = 1;
    }
    fingerprint
}

pub(crate) fn attach_population(image: &mut [u8], populations: &[u8]) -> Vec<u8> {
    assert_eq!(le32(image, 12), populations.len());
    let fingerprint = build_fingerprint(image, populations);
    image[ttcity::FINGERPRINT_OFFSET..ttcity::FINGERPRINT_OFFSET + ttcity::FINGERPRINT_LEN]
        .copy_from_slice(&fingerprint);
    let mut companion = Vec::with_capacity(ttcity::POP_HEADER + populations.len());
    companion.extend_from_slice(ttcity::POP_MAGIC);
    companion.extend_from_slice(&ttcity::POP_VERSION.to_le_bytes());
    companion.extend_from_slice(&(populations.len() as u32).to_le_bytes());
    companion.extend_from_slice(&fingerprint);
    companion.extend_from_slice(populations);
    companion
}

/// 只核头部与长度；索引正文保持惰性读取。
pub fn population_payload<'a>(image: &[u8], companion: &'a [u8]) -> Option<&'a [u8]> {
    let header = image.get(..ttcity::HEADER)?;
    let population_header = companion.get(..ttcity::POP_HEADER)?;
    let count = le32(header, 12);
    let fingerprint = &header[ttcity::FINGERPRINT_OFFSET
        ..ttcity::FINGERPRINT_OFFSET + ttcity::FINGERPRINT_LEN];
    (population_header[..4] == *ttcity::POP_MAGIC
        && le32(population_header, 4) == ttcity::POP_VERSION as usize
        && le32(population_header, 8) == count
        && companion.len() == ttcity::POP_HEADER.checked_add(count)?
        && fingerprint.iter().any(|&byte| byte != 0)
        && fingerprint == &population_header[12..ttcity::POP_HEADER])
        .then_some(&companion[ttcity::POP_HEADER..])
}

pub type TranscodedPopulation = (Vec<u8>, Option<Vec<u8>>, PatchReport);

/// 转码后逐条核对时区与坐标，再绑定原人口字节。
#[cfg(test)]
pub fn transcode_with_population(
    input: &[u8],
    companion: Option<&[u8]>,
    patch: &[SearchKeyErratum],
) -> Result<TranscodedPopulation, String> {
    let (output, report) = transcode(input, patch)?;
    rebind_transcoded_population(input, companion, output, report)
}

/// 生产转码同时执行主名勘误并重新绑定人口文件。
pub fn transcode_primary_names_with_population(
    input: &[u8], companion: Option<&[u8]>, patch: &[SearchKeyErratum],
) -> Result<TranscodedPopulation, String> {
    let mut model = read_image(input)?;
    let report = patch_search_keys(&mut model, patch)?;
    patch_primary_names(&mut model, rules::PRIMARY_NAME_ERRATA)?;
    rebind_transcoded_population(input, companion, write_image(&model)?, report)
}

fn rebind_transcoded_population(
    input: &[u8], companion: Option<&[u8]>, mut output: Vec<u8>, report: PatchReport,
) -> Result<TranscodedPopulation, String> {
    output[ttcity::FINGERPRINT_OFFSET..ttcity::HEADER].fill(0);
    let Some(populations) = companion.and_then(|bytes| population_payload(input, bytes)) else {
        return Ok((output, None, report));
    };
    let before = read_image(input)?;
    let after = read_image(&output)?;
    let order_matches = before.cities.len() == after.cities.len()
        && before.cities.iter().zip(&after.cities).all(|(left, right)| {
            before.timezones[left.timezone] == after.timezones[right.timezone]
                && left.latitude == right.latitude
                && left.longitude == right.longitude
        });
    let population = order_matches.then(|| attach_population(&mut output, populations));
    Ok((output, population, report))
}

/// 把完整的 TTCITY07/08/09/10 镜像转成 TTCITY10，途中对搜索键套上 `patch`（通常是
/// `rules::SEARCH_KEY_ERRATA`）。内容逐项解出再写回；补丁为空时 TTCITY10 镜像逐字节往返。
#[cfg(test)]
pub fn transcode(
    input: &[u8],
    patch: &[SearchKeyErratum],
) -> Result<(Vec<u8>, PatchReport), String> {
    let mut model = read_image(input)?;
    let report = patch_search_keys(&mut model, patch)?;
    let mut output = write_image(&model)?;
    // 正文逐字节相同时保留绑定；改过内容就等人口文件重新绑定。
    if output.len() == input.len()
        && output[..ttcity::FINGERPRINT_OFFSET] == input[..ttcity::FINGERPRINT_OFFSET]
        && output[ttcity::HEADER..] == input[ttcity::HEADER..]
    {
        output[ttcity::FINGERPRINT_OFFSET..ttcity::HEADER]
            .copy_from_slice(&input[ttcity::FINGERPRINT_OFFSET..ttcity::HEADER]);
    }
    Ok((output, report))
}

#[derive(Debug)]
pub struct BuildStats {
    pub cities: usize,
    pub keys: usize,
    pub postings: usize,
    pub timezones: usize,
    pub countries: usize,
    pub admins: usize,
    pub localized: usize,
    pub admin_localized: usize,
    pub bytes: usize,
}

fn string_id(
    value: &str,
    values: &mut Vec<String>,
    positions: &mut HashMap<String, usize>,
) -> usize {
    if let Some(index) = positions.get(value) {
        return *index;
    }
    let index = values.len();
    values.push(value.to_owned());
    positions.insert(value.to_owned(), index);
    index
}

pub fn build(
    cities_path: &Path,
    admin_path: &Path,
    output_path: &Path,
    alternate_path: Option<&Path>,
) -> Result<BuildStats, Box<dyn Error>> {
    let (mut image, populations, stats) =
        build_images(cities_path, admin_path, alternate_path, true, rules::PRIMARY_NAME_ERRATA)?;
    let population = attach_population(&mut image, &populations);
    fs::write(output_path, image)?;
    fs::write(output_path.with_extension("ttpop"), population)?;
    Ok(stats)
}

/// `supplement` 关掉时不读 `data/admin1_zh_supplement.tsv`：夹具的黄金文件是 Python 生成器的 TTCITY07，
/// 补充表里恰好有夹具的行政区（UA.04），带上就对不上锚点；生产入口 `build` 永远带。
/// 「在现有索引上加语言」每种语言的账：写进去多少城市名、行政区名，新加了多少搜索键、多少倒排。
#[derive(Debug, Default, PartialEq)]
pub struct LanguageReport {
    pub language: String,
    pub cities: usize,
    pub admins: usize,
    pub new_keys: usize,
    pub new_postings: usize,
    /// GeoNames 拿不出依据、没用的 Wikidata 标签（`backed`）。
    pub unbacked: usize,
    /// 去掉行政通名就是主名、没收的城市名（`only_generic`）。
    pub generic: usize,
    /// Wikidata 确认这种语言就写主名、没让别名表改名的城市（`Confirmation`）。
    pub confirmed: usize,
    /// 只收现名拼写变体的地方（`CURRENT_NAMES_ONLY`）里另起的名字，没收。
    pub renamed: usize,
}

/// 「在现有索引上加语言」时，索引记录与 GeoNames 转储逐条对上的账。
#[derive(Debug, Default, PartialEq)]
pub struct MatchReport {
    pub records: usize,
    pub matched: usize,
    /// 转储里找不到名字、定点坐标、时区、国家全等的一行（上游可能改名、挪点或删除了记录）。
    pub unmatched: usize,
    /// 全等的行不止一条（转储里的重复点），不猜。
    pub ambiguous: usize,
    pub admins: usize,
    pub admins_matched: usize,
}

/// 加过语言的镜像、对账、每种语言的账。
pub type AddedLanguages = (Vec<u8>, MatchReport, Vec<LanguageReport>);
/// （语言槽, 城市记录号或行政区位置）→ 候选名字桶。
type Buckets = HashMap<(usize, usize), Bucket>;

/// 比相似度时不算的词（已折叠）：行政通名与介词。「provincia in Indonesia」（西爪哇在意大利语 Wikidata 上的标签，其实是描述）
/// 与罗马尼亚语别名「Provincia Java de Vest」只因共有 provincia 就过了一半的相似度，去掉这些词再比。
/// 越南语的 thanh / quan、波兰语的 miasto 这类同时是地名实词的音节不在表里（「Thất Đài Hà」「Nowe Miasto」）。
const GENERIC_WORDS: &[&str] = &[
    "provincia", "province", "provinsi", "propinsi", "region", "regione", "regio", "regiao", "distretto", "district", "distrik",
    "distrito", "prefettura", "prefecture", "prefektur", "prefektura", "prefectuur", "oblast", "obwod", "governatorato",
    "gouvernement", "kegubernuran", "daerah", "wilayah", "contea", "county", "bolgesi", "stato", "state", "estado",
    "departamento", "dipartimento", "departement", "municipio", "municipality", "comune", "gemeente", "gmina", "powiat",
    "kabupaten", "kota", "city", "citta", "kenti", "sehri", "ili", "ilcesi", "di", "de", "del", "della", "in", "van", "of",
    "the", "en", "da", "do", "dos", "das", "le", "la",
];

/// 比名字用的宽松写法：`fold` 之后去掉 `GENERIC_WORDS`，每个词里 NFD 拆不开的字母换成基本字母（đ ł ı ø æ ß œ þ ð），
/// 再连成一串。
fn loose(s: &str) -> String {
    let mut out = String::new();
    for c in fold(s).split(' ').filter(|word| !GENERIC_WORDS.contains(word)).flat_map(str::chars) {
        match c {
            'đ' | 'ð' => out.push('d'),
            'ł' => out.push('l'),
            'ı' => out.push('i'),
            'ø' => out.push('o'),
            'æ' => out.push_str("ae"),
            'ß' => out.push_str("ss"),
            'œ' => out.push_str("oe"),
            'þ' => out.push_str("th"),
            c => out.push(c),
        }
    }
    out
}

fn levenshtein(a: &[char], b: &[char]) -> usize {
    let mut previous: Vec<usize> = (0..=b.len()).collect();
    for (i, x) in a.iter().enumerate() {
        let mut current = vec![i + 1];
        for (j, y) in b.iter().enumerate() {
            current.push((previous[j + 1] + 1).min(current[j] + 1).min(previous[j] + usize::from(x != y)));
        }
        previous = current;
    }
    previous[b.len()]
}

/// 一个 Wikidata 标签有没有 GeoNames 自己的名字撑腰（标签里有描述当名字的「provincia in Indonesia」、
/// 条目维护标记「unlöschbares Datenduplikat」、单个字母「V」、指向别的实体的「Guangxi」）。`evidence` 是这个地方在
/// GeoNames 里的名字（主名、ASCII 名、别名列 / 别名表里任何语言的名字），已按 `fold` 折叠。撑腰的三种：折叠后与某个名字相等；
/// 按整词包含某个 ≥ 3 字的名字或被它包含（「Kota Bandung」「Distretto di Wuchang」）；去掉通名与介词、宽松折叠后编辑距离
/// 不超过较长者的一半（「Kairo」≈「Cairo」、「Warszawa」≈「Varsova」）。拿不出依据的不用：宁可显示 GeoNames 的名字，
/// 也不显示错名。门槛按六语实测定：提到 0.6 要多丢约 700 个正当的名字（越南语的汉越读音「Thất Đài Hà」、土耳其语的
/// 「Telkele」），而去掉通名再比只多拒 22 个。
fn backed(label: &str, evidence: &[String]) -> bool {
    let folded = fold(label);
    if folded.chars().filter(|c| *c != ' ').count() < 2 {
        return false;
    }
    let padded = format!(" {folded} ");
    if evidence.iter().any(|name| {
        *name == folded || (len(name) >= 3 && (padded.contains(&format!(" {name} ")) || format!(" {name} ").contains(&padded)))
    }) {
        return true;
    }
    let compact: Vec<char> = loose(label).chars().collect();
    evidence.iter().any(|name| {
        let other: Vec<char> = loose(name).chars().collect();
        let longer = compact.len().max(other.len());
        !compact.is_empty() && !other.is_empty() && levenshtein(&compact, &other) * 2 <= longer
    })
}

/// 常见、不足以认出是哪个地方的词（已折叠）：方位、圣名、通名、地形。`translated` 认共用专名词时不算它们。
const COMMON_WORDS: &[&str] = &[
    "saint", "sankt", "santa", "santo", "sainte", "north", "south", "east", "west", "nord", "norte", "sud", "ouest", "oeste",
    "lake", "river", "mount", "monte", "villa", "ville", "nueva", "nuevo", "novo", "nova", "nouvelle", "grand", "grande",
    "upper", "lower", "great", "little", "ober", "unter", "gross", "klein", "city", "town", "village", "colonia", "ciudad",
    "cidade", "citta", "stadt", "island", "islands", "isla", "islas", "iles", "insel", "inseln", "ilhas", "isole", "port",
    "fort", "beach", "playa", "praia", "plage", "bahia", "baia", "sierra", "district", "distrito", "distrikt", "county",
    "province", "provincia", "region", "municipality", "municipio",
];

/// 翻译过的名字（修旧名时查出）：「Paso de Arthur」对「Arthur’s Pass」、「Îles Wellesley」对「Wellesley Islands」、
/// 「Baía de Jeffreys」对「Jeffreys Bay」整体字面不像，但共用一个专名词。`primary` 是主名与 ASCII 名（已折叠）；
/// 两边各有一个 ≥ 5 个字母、不在 `COMMON_WORDS` 与 `GENERIC_WORDS` 里的词，编辑距离 ≤ 1（容得下 Arthurs / Arthur、Almérie / Almería）就算。
/// 指向别的地方的错名（Chaoyang 写成「Tonghua」、Syrets 写成「U-Bahnhof Syrez」）没有共用的专名词，照样不认。
fn translated(label: &str, primary: &[String]) -> bool {
    // 撇号先当空格：法语、意大利语的省音（「d’Almérie」「l’Aia」）要拆成两个词。
    let words = |text: &str| -> Vec<Vec<char>> {
        fold(&text.replace(['\'', '’', 'ʼ'], " "))
            .split(' ')
            .map(plain_letters)
            .filter(|word| word.chars().count() >= 5 && !COMMON_WORDS.contains(&word.as_str()) && !GENERIC_WORDS.contains(&word.as_str()))
            .map(|word| word.chars().collect())
            .collect()
    };
    let own = words(label);
    primary.iter().flat_map(|name| words(name)).any(|word| own.iter().any(|mine| levenshtein(mine, &word) <= 1))
}

/// 新语言的名字前后常见的行政通名，例如意「Distretto di」、波「Gmina」、越「Thành phố」、
/// 印尼「Kota」、土「Şehri」。去掉通名后恰好就是这座城的主名或 ASCII 名时，这个本地化名什么也没多说，不收
/// （「Kota Bandung」→ 显示 Bandung）；剩下的不是主名时通名在区分东西，照留（「Thành phố Hồ Chí Minh」「Kota Meksiko」）。
const NEW_LANGUAGE_HEADS: &[&str] = &[
    "Città di ", "Comune di ", "Distretto di ", "Gemeente ", "Stad ", "Gmina ", "Miasto ", "Powiat ", "Thành phố ", "Thị xã ",
    "Huyện ", "Quận ", "Xã ", "Kota ", "Kabupaten ", "Desa ", "Kecamatan ", "Distrik ",
];
/// 后置的通名，含照抄进来的英文（荷、土、意 Wikidata 上的「Wuchang District」「Davao City」「Titabor Town」）。
const NEW_LANGUAGE_TAILS: &[&str] =
    &[" Şehri", " Kenti", " Belediyesi", " ili", " ilçesi", " köyü", " District", " City", " Town", " Village"];

fn only_generic(name: &str, primary: &[String]) -> bool {
    let rest = NEW_LANGUAGE_HEADS
        .iter()
        .filter_map(|head| name.strip_prefix(head))
        .chain(NEW_LANGUAGE_TAILS.iter().filter_map(|tail| name.strip_suffix(tail)));
    rest.map(fold).any(|rest| primary.contains(&rest))
}

/// 只收现名拼写变体的（语言, 国家）：土耳其语 Wikidata / 维基给亚美尼亚的省与村用的是另起的旧名
/// （Shirak 省写「Konakkıran」、Aragatsotn 省写「Alagöz」、Metsavan 写阿塞拜疆字母的「Şahnəzər」、Stepanavan 写「Celaloğlu」），
/// 现代土耳其语新闻用的是现名的转写（Şirak）。使用现名：这里只收与现名相近的写法（Erivan、Gümrü、Davtaşen），
/// 另起的名字不收、显示现名。
const CURRENT_NAMES_ONLY: &[(&str, &str)] = &[("tr", "AM")];

fn current_names_only(language: &str, country: &str) -> bool {
    CURRENT_NAMES_ONLY.contains(&(language, country))
}

/// 与 `city_index::plain_letters` 同一张表：NFD 拆不开的 ı、đ / ð、ł 换成基本字母。新语言的名字加搜索键时连这种写法一起加，
/// 不打这几个字母的人也搜得到（越南语「Luân Đôn」键是「luan đon」，打「Luan Don」的人要找到伦敦）。
fn plain_letters(folded: &str) -> String {
    folded
        .chars()
        .map(|c| match c {
            'ı' => 'i',
            'đ' | 'ð' => 'd',
            'ł' => 'l',
            c => c,
        })
        .collect()
}

/// 拉丁文字的新语言名字当标签单独显示（列表行、「行政区, 国家」副标题打头），首字母大写（别名表里有「provincia di Istanbul」「obwód odeski」）。
fn capitalized(name: String) -> String {
    let mut chars = name.chars();
    match chars.next() {
        Some(first) if first.is_lowercase() => first.to_uppercase().chain(chars).collect(),
        _ => name,
    }
}

/// 带限定语的名字不要：括号（含全角，「イリオン （自治体）」这类消歧后缀）、逗号（「Kota Morehead, Carolina Utara」），
/// 主名自己就带的除外。
fn qualified(name: &str, primary: &str) -> bool {
    (name.contains(['(', '（']) && !primary.contains('(')) || (name.contains(',') && !primary.contains(','))
}

/// GeoNames `alternateNamesV2.txt` 里的名字，按全量构建同一套规则进候选桶：口语名、历史名不要；首选名秩 1、其余秩 2
/// （秩 0 留给 Wikidata 的 strong 标签、3 给 weak）；空的、超过 80 字的、括号不成对或带格式字符的、文种不合的不收；
/// 城市名与主名相同的不收；每桶最多 8 个，按文件顺序先到先得。`want(是城市, 语言槽, 记录号或行政区位置)` 决定收哪些桶
/// （加语言：那几个新槽的全部；修旧名：点名的那几个）。顺带把每个行政区在别名表里的所有名字（任何语言）记进 `admin_evidence`，
/// 给 Wikidata 标签撑腰用；城市的依据用 cities500 的别名列。
fn alternate_buckets(
    path: &Path,
    want: &dyn Fn(bool, usize, usize) -> bool,
    city_ids: &HashMap<String, usize>,
    admin_ids: &HashMap<String, usize>,
    cities: &[CityRow],
    admin_evidence: &mut HashMap<usize, Vec<String>>,
) -> Result<(Buckets, Buckets), Box<dyn Error>> {
    let (mut city_buckets, mut admin_buckets) = (Buckets::new(), Buckets::new());
    for line in BufReader::new(File::open(path)?).lines() {
        let line = line?;
        let fields: Vec<_> = line.split('\t').collect();
        if fields.len() < 4 {
            continue;
        }
        let city = city_ids.get(fields[1]).copied();
        let admin = if city.is_none() { admin_ids.get(fields[1]).copied() } else { None };
        if let Some(position) = admin {
            let folded = fold(&clean_value(fields[3]));
            if !folded.is_empty() {
                admin_evidence.entry(position).or_default().push(folded);
            }
        }
        let Some(language_slot) = slot(fields[2]) else {
            continue;
        };
        let wanted = match (city, admin) {
            (Some(index), _) => want(true, language_slot, index),
            (None, Some(position)) => want(false, language_slot, position),
            _ => false,
        };
        if !wanted || fields.get(7) == Some(&"1") || fields.get(6) == Some(&"1") {
            continue;
        }
        let value = clean_value(fields[3]);
        if value.is_empty() || len(&value) > 80 || malformed(&value) || !script_fits(&value, language_slot) {
            continue;
        }
        let rank = if fields.get(4) == Some(&"1") { 1 } else { 2 };
        let bucket = match (city, admin) {
            (Some(index), _) => {
                if value == cities[index].name {
                    continue;
                }
                city_buckets.entry((language_slot, index)).or_default()
            }
            (None, Some(position)) => admin_buckets.entry((language_slot, position)).or_default(),
            _ => continue,
        };
        if bucket.len() < 8 {
            bucket.push((rank, value));
        }
    }
    Ok((city_buckets, admin_buckets))
}

/// 「加语言」与「修旧名」共用的准备：解开索引，按名字、定点坐标、时区、国家四项全等把每条记录对回一份 cities500
/// （唯一一行全等才算，对不上、有两行全等的都跳过，记进 `MatchReport`，不猜）；行政区按对上的城市所属「国家.行政区码」
/// 找回 ID，名字与索引相等、且该位置所有城市指向同一个行政区才算；再备好每座城在 GeoNames 里的名字（撑腰用）。
struct Prepared {
    model: Model,
    rows: Vec<City>,
    /// 索引记录号 → 转储里的那一行。
    record_row: Vec<Option<usize>>,
    matches: MatchReport,
    /// 行政区位置 → 对上的城市指向的「国家.行政区码」；同一位置指向两个不同的码时为 None。
    admin_code: HashMap<usize, Option<String>>,
    /// GeoNames ID → 城市记录号 / 行政区位置。
    city_ids: HashMap<String, usize>,
    admin_ids: HashMap<String, usize>,
    /// 城市记录号 → 主名、ASCII 名与别名列（已折叠）。
    city_evidence: HashMap<usize, Vec<String>>,
}

fn match_records(model: &Model, rows: &[City]) -> (Vec<Option<usize>>, MatchReport) {
    // 名字按写入时同一个 255 字节上限比（`write_image` 的 `truncated`）。
    type RecordKey = (String, i32, i32, String, String);
    let mut by_key: HashMap<RecordKey, Vec<usize>> = HashMap::new();
    for (position, row) in rows.iter().enumerate() {
        let stored = String::from_utf8_lossy(&row.name.as_bytes()[..row.name.len().min(255)]).into_owned();
        let key = (stored, fixed_coordinate(row.latitude as f32), fixed_coordinate(row.longitude as f32), row.timezone.clone(), row.country.clone());
        by_key.entry(key).or_default().push(position);
    }
    let mut matches = MatchReport { records: model.cities.len(), admins: model.admins.len(), ..Default::default() };
    let mut record_row: Vec<Option<usize>> = vec![None; model.cities.len()];
    for (index, city) in model.cities.iter().enumerate() {
        let (Some(timezone), Some(country)) = (model.timezones.get(city.timezone), model.countries.get(city.country)) else {
            matches.unmatched += 1;
            continue;
        };
        let key = (city.name.clone(), fixed_coordinate(city.latitude), fixed_coordinate(city.longitude), timezone.clone(), country.clone());
        match by_key.get(&key).map(Vec::as_slice) {
            Some([position]) => {
                record_row[index] = Some(*position);
                matches.matched += 1;
            }
            Some(_) => matches.ambiguous += 1,
            None => matches.unmatched += 1,
        }
    }
    (record_row, matches)
}

/// 人口只跟唯一匹配的记录绑定。
#[derive(Debug)]
pub struct PopulationMatchReport {
    pub matches: MatchReport,
    pub unmatched_by_country: BTreeMap<String, usize>,
    pub unmatched_records: Vec<String>,
}

pub type AddedPopulation = (Option<(Vec<u8>, Vec<u8>)>, PopulationMatchReport);

/// 保留索引全部字节，只写绑定指纹；匹配不足时不给产物。
pub fn add_population(image: &[u8], cities_path: &Path) -> Result<AddedPopulation, Box<dyn Error>> {
    let model = read_image(image)?;
    let rows = load_rows(cities_path)?;
    let (record_row, matches) = match_records(&model, &rows);
    let mut unmatched_by_country = BTreeMap::new();
    let mut unmatched_records = Vec::new();
    for (index, position) in record_row.iter().enumerate() {
        if position.is_some() {
            continue;
        }
        let city = &model.cities[index];
        let country = &model.countries[city.country];
        *unmatched_by_country.entry(country.clone()).or_default() += 1;
        unmatched_records.push(format!("{index}\t{country}\t{}\t{}\t{}\t{}",
            city.name, city.latitude, city.longitude, model.timezones[city.timezone]));
    }
    let output = if (matches.unmatched + matches.ambiguous) * 100 <= matches.records {
        let populations: Vec<u8> = record_row.iter().map(|position| {
            position.map_or(0, |p| population_bucket(rows[p].population))
        }).collect();
        let mut output = image.to_vec();
        let companion = attach_population(&mut output, &populations);
        Some((output, companion))
    } else {
        None
    };
    Ok((output, PopulationMatchReport { matches, unmatched_by_country, unmatched_records }))
}

fn prepare(image: &[u8], cities_path: &Path, admin_path: &Path) -> Result<Prepared, Box<dyn Error>> {
    let model = read_image(image)?;
    let rows = load_rows(cities_path)?;
    let (record_row, mut matches) = match_records(&model, &rows);
    let admins = load_admins(admin_path)?;
    let mut admin_code: HashMap<usize, Option<String>> = HashMap::new();
    for (index, position) in record_row.iter().enumerate() {
        let (Some(position), admin) = (position, model.cities[index].admin) else { continue };
        if admin == 0xffff {
            continue;
        }
        let code = format!("{}.{}", rows[*position].country, rows[*position].admin);
        admin_code
            .entry(admin)
            .and_modify(|seen| {
                if seen.as_deref() != Some(code.as_str()) {
                    *seen = None;
                }
            })
            .or_insert(Some(code));
    }
    let mut admin_ids: HashMap<String, usize> = HashMap::new();
    for (&position, code) in &admin_code {
        let Some((name, id)) = code.as_ref().and_then(|code| admins.get(code)) else { continue };
        if model.admins.get(position) == Some(name) {
            admin_ids.insert(id.clone(), position);
        }
    }
    matches.admins_matched = admin_ids.len();
    let city_ids: HashMap<String, usize> =
        record_row.iter().enumerate().filter_map(|(index, position)| position.map(|p| (rows[p].id.clone(), index))).collect();
    let city_evidence: HashMap<usize, Vec<String>> = record_row
        .iter()
        .enumerate()
        .filter_map(|(index, position)| {
            let row = &rows[(*position)?];
            let names = [row.name.as_str(), row.ascii.as_str()].into_iter().chain(row.alternates.split(','));
            Some((index, names.map(fold).filter(|name| !name.is_empty()).collect()))
        })
        .collect();
    Ok(Prepared { model, rows, record_row, matches, admin_code, city_ids, admin_ids, city_evidence })
}

impl Prepared {
    /// 这座城的主名与 ASCII 名（已折叠）；对不上转储的只有索引里的主名。
    fn primary(&self, index: usize) -> Vec<String> {
        self.record_row[index].map_or_else(
            || vec![fold(&self.model.cities[index].name)],
            |p| vec![fold(&self.rows[p].name), fold(&self.rows[p].ascii)],
        )
    }

    fn admin_evidence(&self) -> HashMap<usize, Vec<String>> {
        self.model.admins.iter().enumerate().map(|(position, name)| (position, vec![fold(name)])).collect()
    }
}

/// 一个显示名折叠后成为这座城的次名键（看得见就搜得到），连同 ı / đ / ł 换成基本字母的写法；返回（新键数, 新倒排数）。
fn add_search_keys(postings: &mut BTreeMap<Vec<u8>, Vec<u32>>, index: usize, name: &str) -> (usize, usize) {
    let (mut new_keys, mut new_postings) = (0, 0);
    let key = fold(name);
    if key.is_empty() || len(&key) > 40 {
        return (0, 0);
    }
    let plain = plain_letters(&key);
    for key in std::iter::once(key.clone()).chain((plain != key).then_some(plain)) {
        let values = match postings.entry(key.into_bytes()) {
            std::collections::btree_map::Entry::Occupied(entry) => entry.into_mut(),
            std::collections::btree_map::Entry::Vacant(entry) => {
                new_keys += 1;
                entry.insert(Vec::new())
            }
        };
        if !values.iter().any(|v| (*v & !PRIMARY_BIT) as usize == index) {
            values.push(index as u32);
            values.sort_by_key(|v| *v & !PRIMARY_BIT);
            new_postings += 1;
        }
    }
    (new_keys, new_postings)
}

/// 在现有索引上加语言（意、荷、波、土、越、印尼六种），无需重建已有语言。
/// 这条路保留随包索引的逻辑内容，只另读与记录对应的 GeoNames 转储
/// `cities500.txt`，记录对法见 `prepare`。
/// 新语言的名字来自 GeoNames 别名表（`alternates`，与全量构建同一套过滤与秩，见 `alternate_buckets`）与 Wikidata 标签
/// （strong 秩 0、weak 秩 3，文种不合、等于主名、带半个括号的不收），城市名照走通名规则；
/// 每个新显示名折叠后成为该城的次名键（看得见就搜得到）。已有的语言、键、倒排一个字节都不动；
/// 同一种语言再跑一次是替换那一种语言的名字表（键只增不减，所以要从没加过这些语言的镜像上跑）。
pub fn add_languages(
    image: &[u8],
    cities_path: &Path,
    admin_path: &Path,
    languages: &[&str],
    labels: &Labels,
    alternates: Option<&Path>,
) -> Result<AddedLanguages, Box<dyn Error>> {
    let (city_labels, admin_labels) = (&labels.cities, &labels.admins);
    let prepared = prepare(image, cities_path, admin_path)?;
    let slots = languages
        .iter()
        .map(|language| slot(language).ok_or_else(|| format!("{language} 不在索引的语言表里")))
        .collect::<Result<HashSet<usize>, _>>()?;
    let mut admin_evidence = prepared.admin_evidence();
    let (mut alternate_cities, mut alternate_admins) = match alternates {
        Some(path) => alternate_buckets(
            path,
            &|_, slot, _| slots.contains(&slot),
            &prepared.city_ids,
            &prepared.admin_ids,
            &prepared.model.cities,
            &mut admin_evidence,
        )?,
        None => (Buckets::new(), Buckets::new()),
    };
    let Prepared { mut model, rows, record_row, matches, admin_code, city_ids, admin_ids, city_evidence } = prepared;
    // 与 `Prepared::primary` 同义（`prepared` 已拆开）。
    let city_primary = |model: &Model, index: usize| -> Vec<String> {
        record_row[index].map_or_else(|| vec![fold(&model.cities[index].name)], |p| vec![fold(&rows[p].name), fold(&rows[p].ascii)])
    };
    let mut postings: BTreeMap<Vec<u8>, Vec<u32>> = std::mem::take(&mut model.keys).into_iter().collect();
    let confirmed_cities: HashSet<(usize, usize)> = labels
        .city_confirmations
        .iter()
        .filter_map(|(id, slot)| city_ids.get(id.as_str()).map(|index| (*slot, *index)))
        .collect();
    let confirmed_admins: HashSet<(usize, usize)> = labels
        .admin_confirmations
        .iter()
        .filter_map(|(id, slot)| admin_ids.get(id.as_str()).map(|position| (*slot, *position)))
        .collect();
    let mut reports = Vec::new();
    for &language in languages {
        let slot = slot(language).ok_or_else(|| format!("{language} 不在索引的语言表里"))?;
        // 别名在前、Wikidata 在后，与全量构建进桶的顺序相同（`choose_name` 按秩稳定排序，同秩先到先得）。
        let mut report = LanguageReport { language: language.to_owned(), ..Default::default() };
        let mut candidates: HashMap<usize, Bucket> = HashMap::new();
        for ((bucket_slot, index), bucket) in alternate_cities.iter_mut() {
            if *bucket_slot == slot {
                if confirmed_cities.contains(&(slot, *index)) {
                    report.confirmed += 1;
                    continue;
                }
                let primary = &model.cities[*index].name;
                let bucket: Bucket = std::mem::take(bucket).into_iter().filter(|(_, name)| !qualified(name, primary)).collect();
                if !bucket.is_empty() {
                    candidates.insert(*index, bucket);
                }
            }
        }
        for (id, label_slot, label, strong) in city_labels {
            let Some(&index) = city_ids.get(id.as_str()).filter(|_| *label_slot == slot) else {
                continue;
            };
            let primary = &model.cities[index].name;
            if !script_fits(label, slot) || label == primary || malformed(label) || len(label) > 80 || qualified(label, primary) {
                continue;
            }
            if !backed(label, &city_evidence[&index]) && !translated(label, &city_primary(&model, index)) {
                report.unbacked += 1;
                continue;
            }
            candidates.entry(index).or_default().push((if *strong { 0 } else { 3 }, label.clone()));
        }
        let mut table = BTreeMap::new();
        for (index, mut bucket) in candidates {
            let name = capitalized(choose_name(&mut bucket, Some(&model.cities[index].name)));
            let primary = city_primary(&model, index);
            if only_generic(&name, &primary) {
                report.generic += 1;
                continue;
            }
            let country = model.countries.get(model.cities[index].country).map_or("", String::as_str);
            if current_names_only(language, country) && !backed(&name, &primary) {
                report.renamed += 1;
                continue;
            }
            // 与主名逐字相同才不写（同全量构建）；只差变音符号的照写，那是这种语言的写法（荷兰语「Caïro」）。
            if name != model.cities[index].name {
                table.insert(index, name);
            }
        }
        let mut admin_candidates: HashMap<usize, Bucket> = HashMap::new();
        for ((bucket_slot, position), bucket) in alternate_admins.iter_mut() {
            if *bucket_slot == slot && !confirmed_admins.contains(&(slot, *position)) {
                admin_candidates.insert(*position, std::mem::take(bucket));
            }
        }
        for (id, label_slot, label, strong) in admin_labels {
            let Some(&position) = admin_ids.get(id.as_str()).filter(|_| *label_slot == slot) else {
                continue;
            };
            if !script_fits(label, slot) || malformed(label) || len(label) > 80 || qualified(label, &model.admins[position]) {
                continue;
            }
            if !backed(label, &admin_evidence[&position]) && !translated(label, &[fold(&model.admins[position])]) {
                report.unbacked += 1;
                continue;
            }
            admin_candidates.entry(position).or_default().push((if *strong { 0 } else { 3 }, label.clone()));
        }
        let mut admin_table = BTreeMap::new();
        for (position, mut bucket) in admin_candidates {
            bucket.retain(|(_, name)| !qualified(name, &model.admins[position]));
            if bucket.is_empty() {
                continue;
            }
            let name = capitalized(choose_name(&mut bucket, None));
            let country = admin_code.get(&position).and_then(|code| code.as_deref()?.split('.').next()).unwrap_or("");
            if current_names_only(language, country) && !backed(&name, &[fold(&model.admins[position])]) {
                report.renamed += 1;
                continue;
            }
            if name != model.admins[position] {
                admin_table.insert(position, name);
            }
        }
        report.cities = table.len();
        report.admins = admin_table.len();
        for (&index, name) in &table {
            let (keys, postings_added) = add_search_keys(&mut postings, index, name);
            report.new_keys += keys;
            report.new_postings += postings_added;
        }
        if let Some(position) = model.languages.iter().position(|l| l == language) {
            model.localized[position] = table;
            model.admin_localized[position] = admin_table;
        } else {
            model.languages.push(language.to_owned());
            model.localized.push(table);
            model.admin_localized.push(admin_table);
        }
        reports.push(report);
    }
    model.keys = postings.into_iter().collect();
    Ok((write_image(&model)?, matches, reports))
}

/// 修旧名的账（每种语言一份）：去掉限定语的、换成 GeoNames 别名的、拿掉（显示主名）的，城市与行政区合计。
#[derive(Debug, Default, PartialEq, Clone)]
pub struct RepairReport {
    pub language: String,
    /// 「San Antonio (Texas)」→「San Antonio」这类只去掉限定语的。
    pub stripped: usize,
    /// 换成 GeoNames 别名表里这种语言的名字的。
    pub replaced: usize,
    /// 拿掉、改显示主名的。
    pub removed: usize,
}

/// 修过的镜像、对账、每种语言的账、逐条改动（「语言\t城市|行政区\t记录号\t主名\t旧名\t新名（空 = 拿掉）\t原因」）。
pub type Repaired = (Vec<u8>, MatchReport, Vec<RepairReport>, Vec<String>);

/// 去掉名字里的限定语：括号（半角、全角）里的部分，与第一个逗号之后的部分；首尾空白收掉。
fn strip_qualifier(name: &str) -> String {
    let mut out = String::new();
    let mut depth = 0usize;
    for c in name.chars() {
        match c {
            '(' | '（' => depth += 1,
            ')' | '）' => depth = depth.saturating_sub(1),
            ',' | '，' if depth == 0 => break,
            c if depth == 0 => out.push(c),
            _ => {}
        }
    }
    out.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// 拉丁文字的旧语言槽（德、西、法、葡）：能拿 GeoNames 的名字给 Wikidata 标签撑腰（`backed`）。汉字、假名、谚文、
/// 西里尔文的名字与拉丁字母的依据比不了，只修限定语。
fn latin_slot(slot: usize) -> bool {
    slot >= 4 && slot != 7
}

/// 修旧九语里已经上线的坏名。只动两类，其余一个字节不动：
/// ①带限定语的名字（德「San Antonio (Texas)」、中「克洛维斯（新墨西哥州）」、日「イリオン （自治体）」、法「Bruxelles (Anderlecht)」）：
/// 去掉括号与逗号后的部分，剩下的若就是主名则拿掉；拉丁语种剩下的有 GeoNames 撑腰才用，汉字 / 假名 / 谚文 / 西里尔文剩下的
/// 文种对就用；都不成就当②处理。
/// ②拉丁语种（德、西、法、葡）里等于 Wikidata 标签、却拿不出 GeoNames 依据的名字（德语 Graz 写成它的一区「Innere Stadt」、
/// 葡语 Berezniki 写成另一座城「Perm」、德语「Unlöschbares Datenduplikat」、西语西爪哇「Provincia en Indonesia」）：
/// 从 GeoNames 别名表这种语言的名字里重选（同全量构建的过滤与秩，刚被拿掉的与带限定语的不算），没有就拿掉、显示主名。
/// 新名字进搜索键；旧键不删（多一个能搜到的写法无害）。
pub fn repair_old_names(
    image: &[u8],
    cities_path: &Path,
    admin_path: &Path,
    labels: &Labels,
    alternates: &Path,
) -> Result<Repaired, Box<dyn Error>> {
    let prepared = prepare(image, cities_path, admin_path)?;
    let old_slots = BASE_LANGUAGES.min(prepared.model.languages.len());
    let wikidata_cities: HashSet<(usize, usize, &str)> = labels
        .cities
        .iter()
        .filter_map(|(id, slot, label, _)| prepared.city_ids.get(id.as_str()).map(|index| (*slot, *index, label.as_str())))
        .collect();
    let wikidata_admins: HashSet<(usize, usize, &str)> = labels
        .admins
        .iter()
        .filter_map(|(id, slot, label, _)| prepared.admin_ids.get(id.as_str()).map(|position| (*slot, *position, label.as_str())))
        .collect();
    // 先定每个名字怎么处理：Some(新名) 换、None 拿掉；要重选的记进 `pending`。
    enum Verdict {
        Keep,
        Set(Option<String>, &'static str),
        Reselect(&'static str),
    }
    let mut admin_evidence = prepared.admin_evidence();
    // 行政区的依据要先扫一遍别名表（任何语言）；不收桶。
    alternate_buckets(alternates, &|_, _, _| false, &prepared.city_ids, &prepared.admin_ids, &prepared.model.cities, &mut admin_evidence)?;
    let judge = |slot: usize, name: &str, primary: &str, primary_folds: &[String], evidence: Option<&Vec<String>>, from_wikidata: bool| -> Verdict {
        if qualified(name, primary) {
            let bare = strip_qualifier(name);
            if bare.is_empty() || !script_fits(&bare, slot) {
                return Verdict::Reselect("限定语");
            }
            if bare == primary {
                return Verdict::Set(None, "限定语");
            }
            // 只差变音符号的照留（西语「Múnich (Baviera)」→「Múnich」），那是这种语言的写法。
            if !latin_slot(slot) || primary_folds.contains(&fold(&bare)) || evidence.is_some_and(|evidence| backed(&bare, evidence)) {
                return Verdict::Set(Some(bare), "限定语");
            }
            return Verdict::Reselect("限定语");
        }
        if latin_slot(slot) && from_wikidata && evidence.is_some_and(|evidence| !backed(name, evidence)) && !translated(name, primary_folds) {
            return Verdict::Reselect("没依据");
        }
        Verdict::Keep
    };
    /// 一条改动：城市还是行政区、语言槽、记录号或位置、旧名、新名（None = 拿掉）、原因。
    struct Decision {
        is_city: bool,
        slot: usize,
        key: usize,
        old: String,
        new: Option<String>,
        reason: &'static str,
    }
    let mut decided: Vec<Decision> = Vec::new();
    let mut pending_cities: HashMap<(usize, usize), (String, &'static str)> = HashMap::new();
    let mut pending_admins: HashMap<(usize, usize), (String, &'static str)> = HashMap::new();
    for slot in 0..old_slots {
        for (&index, name) in &prepared.model.localized[slot] {
            let primary = &prepared.model.cities[index].name;
            let from_wikidata = wikidata_cities.contains(&(slot, index, name.as_str()));
            match judge(slot, name, primary, &prepared.primary(index), prepared.city_evidence.get(&index), from_wikidata) {
                Verdict::Keep => {}
                Verdict::Set(new, reason) => decided.push(Decision { is_city: true, slot, key: index, old: name.clone(), new, reason }),
                Verdict::Reselect(reason) => {
                    pending_cities.insert((slot, index), (name.clone(), reason));
                }
            }
        }
        for (&position, name) in &prepared.model.admin_localized[slot] {
            let primary = &prepared.model.admins[position];
            let from_wikidata = wikidata_admins.contains(&(slot, position, name.as_str()));
            match judge(slot, name, primary, &[fold(primary)], admin_evidence.get(&position), from_wikidata) {
                Verdict::Keep => {}
                Verdict::Set(new, reason) => {
                    decided.push(Decision { is_city: false, slot, key: position, old: name.clone(), new, reason })
                }
                Verdict::Reselect(reason) => {
                    pending_admins.insert((slot, position), (name.clone(), reason));
                }
            }
        }
    }
    let (city_buckets, admin_buckets) = alternate_buckets(
        alternates,
        &|is_city, slot, key| if is_city { pending_cities.contains_key(&(slot, key)) } else { pending_admins.contains_key(&(slot, key)) },
        &prepared.city_ids,
        &prepared.admin_ids,
        &prepared.model.cities,
        &mut HashMap::new(),
    )?;
    for (is_city, pending, buckets) in [(true, &pending_cities, &city_buckets), (false, &pending_admins, &admin_buckets)] {
        for (&(slot, key), (old, reason)) in pending {
            let primary = if is_city { &prepared.model.cities[key].name } else { &prepared.model.admins[key] };
            let mut bucket: Bucket = buckets
                .get(&(slot, key))
                .into_iter()
                .flatten()
                .filter(|(_, name)| name != old && !qualified(name, primary))
                .cloned()
                .collect();
            let new = (!bucket.is_empty()).then(|| choose_name(&mut bucket, is_city.then_some(primary.as_str())));
            decided.push(Decision { is_city, slot, key, old: old.clone(), new: new.filter(|name| name != primary), reason });
        }
    }
    decided.sort_by_key(|decision| (decision.slot, !decision.is_city, decision.key));
    let Prepared { mut model, matches, .. } = prepared;
    let mut postings: BTreeMap<Vec<u8>, Vec<u32>> = std::mem::take(&mut model.keys).into_iter().collect();
    let mut reports: Vec<RepairReport> =
        model.languages[..old_slots].iter().map(|language| RepairReport { language: language.clone(), ..Default::default() }).collect();
    let mut changes = Vec::new();
    for Decision { is_city, slot, key, old, new, reason } in decided {
        let table = if is_city { &mut model.localized[slot] } else { &mut model.admin_localized[slot] };
        let primary = if is_city { model.cities[key].name.clone() } else { model.admins[key].clone() };
        let report = &mut reports[slot];
        match &new {
            Some(name) => {
                table.insert(key, name.clone());
                if reason == "限定语" && fold(name) == fold(&strip_qualifier(&old)) {
                    report.stripped += 1;
                } else {
                    report.replaced += 1;
                }
                if is_city {
                    add_search_keys(&mut postings, key, name);
                }
            }
            None => {
                table.remove(&key);
                report.removed += 1;
            }
        }
        changes.push(format!(
            "{}\t{}\t{key}\t{primary}\t{old}\t{}\t{reason}",
            model.languages[slot],
            if is_city { "城市" } else { "行政区" },
            new.as_deref().unwrap_or("")
        ));
    }
    model.keys = postings.into_iter().collect();
    Ok((write_image(&model)?, matches, reports, changes))
}

/// 生产用的两张 Wikidata 标签表（`data/city_names_wikidata.tsv`、`data/admin1_names_wikidata.tsv`）。
pub fn bundled_wikidata_labels() -> Result<Labels, Box<dyn Error>> {
    let (cities, city_confirmations) = wikidata_rows("city_names_wikidata.tsv")?;
    let (admins, admin_confirmations) = wikidata_rows("admin1_names_wikidata.tsv")?;
    Ok(Labels { cities, admins, city_confirmations, admin_confirmations })
}

pub struct SelectedNameInputs<'a> {
    pub cities: &'a Path,
    pub admins: &'a Path,
    pub alternates: &'a Path,
    pub selection: &'a Path,
}

pub struct SelectedNameRepair {
    pub image: Vec<u8>,
    pub population: Option<Vec<u8>>,
    pub changes: Vec<String>,
}

struct SelectedName {
    city: bool,
    index: usize,
    language: Option<usize>,
    script_slot: usize,
    id: String,
    before: String,
    after: String,
    source: String,
    evidence: String,
}

fn selected_names(prepared: &Prepared, path: &Path) -> Result<Vec<SelectedName>, Box<dyn Error>> {
    let mut selected = Vec::new();
    let mut seen = HashSet::new();
    let mut header = false;
    for (line_number, line) in BufReader::new(File::open(path)?).lines().enumerate() {
        let line = line?;
        if line.starts_with('#') || line.is_empty() {
            continue;
        }
        if !header {
            if line != "kind\tindex\tlanguage\tgeonameid\tprimary\tbefore\tafter\tsource" {
                return Err("点名修正表的表头不符".into());
            }
            header = true;
            continue;
        }
        let fields: Vec<_> = line.split('\t').collect();
        let [kind, index, language, id, primary, before, after, source] = fields[..] else {
            return Err(format!("点名修正表第 {} 行不是八列", line_number + 1).into());
        };
        let city = match kind {
            "city" => true,
            "admin" => false,
            _ => return Err(format!("未知的名字类型：{kind}").into()),
        };
        let index: usize = index.parse()?;
        let language = if language == "en" {
            if !city || source != "geonames" {
                return Err("英文主名修正只接受城市的 GeoNames 别名".into());
            }
            None
        } else {
            Some(prepared.model.languages.iter().position(|value| value == language)
                .ok_or_else(|| format!("索引没有语言：{language}"))?)
        };
        let script_slot = language.map_or(Some(4), |position| slot(&prepared.model.languages[position]))
            .ok_or("索引语言不受支持")?;
        if !seen.insert((city, index, language)) {
            return Err("点名修正表重复指定同一个名字".into());
        }
        let (identity, actual_primary) = if city {
            (prepared.city_ids.get(id).copied(), prepared.model.cities.get(index).map(|row| row.name.as_str()))
        } else {
            (prepared.admin_ids.get(id).copied(), prepared.model.admins.get(index).map(String::as_str))
        };
        if id.is_empty() || identity != Some(index) || actual_primary != Some(primary) {
            return Err(format!("第 {} 行的记录身份与索引不符", line_number + 1).into());
        }
        let actual_before = language.map_or(primary, |position| {
            let table = if city { &prepared.model.localized[position] } else { &prepared.model.admin_localized[position] };
            table.get(&index).map_or("", String::as_str)
        });
        if actual_before != before {
            return Err(format!("第 {} 行的旧名与索引不符", line_number + 1).into());
        }
        if !matches!(source, "geonames" | "geonames-generic" | "wikidata" | "primary") {
            return Err(format!("未知的名字来源：{source}").into());
        }
        if after.is_empty() || len(after) > 80 || malformed(after) {
            return Err(format!("第 {} 行的新名格式不符", line_number + 1).into());
        }
        if source == "primary" {
            if after != primary {
                return Err("主名回退必须逐字等于索引主名".into());
            }
        } else if after == primary || !script_fits(after, script_slot) {
            return Err("本地化新名必须符合语言文种，主名回退需指定 primary".into());
        }
        selected.push(SelectedName {
            city, index, language, script_slot, id: id.to_owned(), before: before.to_owned(),
            after: after.to_owned(), source: source.to_owned(), evidence: String::new(),
        });
    }
    if !header || selected.is_empty() {
        return Err("点名修正表没有改动".into());
    }
    Ok(selected)
}

fn verify_selected_sources(
    selected: &mut [SelectedName], prepared: &Prepared, labels: &Labels, alternates: &Path,
) -> Result<(), Box<dyn Error>> {
    // 扫描大文件前，一次列出所有不符合通名缩短规则的行。
    let rejected: Vec<_> = selected.iter().filter(|item| item.source == "geonames-generic")
        .filter(|item| !is_generic_shortening(&item.before, &item.after, item.city))
        .map(|item| format!(
            "kind={} index={} language={} geonameid={} before={:?} after={:?} 原因={}",
            if item.city { "city" } else { "admin" }, item.index,
            item.language.map_or("en", |position| prepared.model.languages[position].as_str()),
            item.id, item.before, item.after,
            if len(&item.after) < 2 { "新名少于两个字符" } else { "不是已有行政通名的严格缩短" },
        )).collect();
    if !rejected.is_empty() {
        return Err(format!("跨语言别名只能去掉已有名字的行政通名（{} 行）：\n{}", rejected.len(), rejected.join("\n")).into());
    }
    let mut wanted: HashMap<_, Vec<usize>> = HashMap::new();
    for (position, item) in selected.iter().enumerate() {
        let language = match item.source.as_str() {
            "geonames" if item.language.is_some() => item.script_slot,
            "geonames-generic" => usize::MAX,
            _ => continue,
        };
        wanted.entry((item.id.clone(), language, item.after.clone())).or_default().push(position);
    }
    if !wanted.is_empty() {
        for line in BufReader::new(File::open(alternates)?).lines() {
            let line = line?;
            let fields: Vec<_> = line.split('\t').collect();
            if fields.len() < 8 || fields[0].parse::<u64>().is_err() || fields[6] == "1" || fields[7] == "1" {
                continue;
            }
            let value = clean_value(fields[3]);
            for language in slot(fields[2]).into_iter().chain(std::iter::once(usize::MAX)) {
                let key = (fields[1].to_owned(), language, value.clone());
                if let Some(positions) = wanted.get(&key) {
                    for &position in positions {
                        if selected[position].evidence.is_empty() {
                            selected[position].evidence = format!("alternate:{}", fields[0]);
                        }
                    }
                }
            }
        }
    }
    for item in selected {
        if item.language.is_none() {
            let row = prepared.record_row[item.index].ok_or("英文主名没有唯一 GeoNames 记录")?;
            if prepared.rows[row].alternates.split(',').any(|name| clean_value(name) == item.after) {
                item.evidence = format!("cities500:{}:alternate", item.id);
            }
        }
        match item.source.as_str() {
            "primary" => item.evidence = format!("primary:{}", item.id),
            "wikidata" => {
                let rows = if item.city { &labels.cities } else { &labels.admins };
                if rows.iter().any(|(id, language, value, _)|
                    *id == item.id && *language == item.script_slot && *value == item.after)
                {
                    item.evidence = format!("wikidata:{}", item.id);
                }
            }
            _ => {}
        }
        if item.evidence.is_empty() {
            return Err(format!("{} 的新名没有指定语言的来源依据：{}", item.id, item.after).into());
        }
    }
    Ok(())
}

// 只改点名的显示名；旧键保留，新显示名补进搜索键。
pub fn repair_selected_names(
    image: &[u8], companion: Option<&[u8]>, inputs: &SelectedNameInputs<'_>, labels: &Labels,
) -> Result<SelectedNameRepair, Box<dyn Error>> {
    let prepared = prepare(image, inputs.cities, inputs.admins)?;
    let populations = companion.and_then(|bytes| population_payload(image, bytes));
    if image[ttcity::FINGERPRINT_OFFSET..ttcity::HEADER].iter().any(|byte| *byte != 0)
        && populations.is_none()
    {
        return Err("索引已绑定人口文件，但匹配的人口文件缺失或无效".into());
    }
    if let Some(payload) = populations {
        if build_fingerprint(image, payload) != image[ttcity::FINGERPRINT_OFFSET..ttcity::HEADER] {
            return Err("索引正文与人口绑定指纹不符".into());
        }
    }
    let mut selected = selected_names(&prepared, inputs.selection)?;
    verify_selected_sources(&mut selected, &prepared, labels, inputs.alternates)?;
    let original = prepared.model;
    let mut model = original.clone();
    let mut postings: BTreeMap<_, _> = model.keys.iter().cloned().collect();
    let mut changes = Vec::new();
    for item in &selected {
        if let Some(language) = item.language {
            let table = if item.city { &mut model.localized[language] } else { &mut model.admin_localized[language] };
            if item.source == "primary" {
                table.remove(&item.index);
            } else {
                table.insert(item.index, item.after.clone());
                if item.city {
                    add_search_keys(&mut postings, item.index, &item.after);
                }
            }
        } else {
            model.cities[item.index].name = item.after.clone();
            let key = fold(&item.after);
            if key.is_empty() || len(&key) > 40 {
                return Err("修正后的英文主名无法写成搜索键".into());
            }
            add_search_keys(&mut postings, item.index, &item.after);
            let plain = plain_letters(&key);
            for key in std::iter::once(key.clone()).chain((plain != key).then_some(plain)) {
                let values = postings.get_mut(key.as_bytes()).ok_or("英文主名搜索键缺失")?;
                let value = values.iter_mut().find(|value| (**value & !PRIMARY_BIT) as usize == item.index)
                    .ok_or("英文主名搜索倒排缺失")?;
                *value |= PRIMARY_BIT;
            }
        }
        changes.push(format!("{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}",
            if item.city { "city" } else { "admin" }, item.index,
            item.language.map_or("en", |language| model.languages[language].as_str()),
            item.id, item.before, item.after, item.source, item.evidence));
    }
    model.keys = postings.into_iter().collect();
    let mut output = write_image(&model)?;
    let decoded = read_image(&output)?;
    if decoded != model {
        return Err("修正后的索引未能完整往返解码".into());
    }
    // 还原允许改动后逐字段核对，禁止带入其它变化。
    let mut restored = decoded;
    restored.keys = original.keys.clone();
    for item in &selected {
        if let Some(language) = item.language {
            let table = if item.city { &mut restored.localized[language] } else { &mut restored.admin_localized[language] };
            if item.before.is_empty() {
                table.remove(&item.index);
            } else {
                table.insert(item.index, item.before.clone());
            }
        } else {
            restored.cities[item.index].name = item.before.clone();
        }
    }
    if restored != original {
        return Err("修正后的索引出现了点名范围之外的变化".into());
    }
    let population = populations.map(|payload| attach_population(&mut output, payload));
    Ok(SelectedNameRepair { image: output, population, changes })
}

#[cfg(test)]
mod selected_name_tests {
    use super::*;

    #[test]
    fn selected_generic_shortening_preserves_unapproved_geographic_qualifiers() {
        for (full, short) in [
            ("Stadt München", "München"), ("北京市", "北京"),
        ] {
            assert!(is_generic_shortening(full, short, true), "{full}");
        }
        for (full, short) in [
            ("Sous-district de Anwen", "Anwen"), ("Quận The Farrington", "The Farrington"),
            ("Qira County", "Qira"), ("Upper St. Clair Township", "Upper St. Clair"),
            ("Sous-district de Anwen", "An"), ("County Durham", "Durham"),
            ("Qira County Borough", "Qira"), ("柏市", "柏"),
            ("北京 County", "上海"), ("Upper St. Clair Township", "St. Clair"),
        ] {
            assert!(!is_generic_shortening(full, short, true), "{full}");
        }
    }

    #[test]
    fn selected_generic_errors_list_every_rejected_cell_before_source_scan() {
        let (image, _, root, directory) = fixture("generic-errors");
        let prepared = prepare(&image, &root.join("cities.txt"), &root.join("admin1CodesASCII.txt")).unwrap();
        let language = prepared.model.languages.iter().position(|value| value == "zh-Hans").unwrap();
        let mut selected: Vec<_> = [(708, "1853195", "堺市", "堺"), (1396, "1859924", "柏市", "柏")]
            .into_iter().map(|(index, id, before, after)| SelectedName {
                city: true, index, language: Some(language), script_slot: slot("zh-Hans").unwrap(),
                id: id.into(), before: before.into(), after: after.into(),
                source: "geonames-generic".into(), evidence: String::new(),
            }).collect();
        let error = verify_selected_sources(&mut selected, &prepared, &Labels::default(),
            &directory.join("absent-alternates.tsv")).unwrap_err().to_string();
        for expected in ["（2 行）", "index=708", "index=1396", "language=zh-Hans", "geonameid=1853195",
            "before=\"堺市\" after=\"堺\"", "新名少于两个字符"] {
            assert!(error.contains(expected), "{error}");
        }
    }

    #[test]
    #[ignore]
    fn logical_model_dump() {
        use std::io::Write;
        let input = std::env::var("MEANTIME_INDEX_PATH").expect("MEANTIME_INDEX_PATH is required");
        let output = std::env::var("MEANTIME_DUMP_OUT").expect("MEANTIME_DUMP_OUT is required");
        let image = fs::read(input).unwrap();
        let model = read_image(&image).unwrap();
        let mut writer = std::io::BufWriter::new(File::create(output).unwrap());
        for (field, value) in [
            ("timezones", serde_json::json!(model.timezones)),
            ("countries", serde_json::json!(model.countries)),
            ("languages", serde_json::json!(model.languages)),
            ("admins", serde_json::json!(model.admins)),
            ("representatives", serde_json::json!(model.representatives)),
            ("country_tops", serde_json::json!(model.country_tops)),
        ] {
            writeln!(writer, "M\t{field}\t{value}").unwrap();
        }
        for (index, city) in model.cities.iter().enumerate() {
            writeln!(writer, "R\t{index}\t{}", serde_json::json!({
                "name": city.name, "admin": city.admin, "timezone": city.timezone,
                "country": city.country, "latitude": city.latitude, "longitude": city.longitude,
            })).unwrap();
        }
        for (key, postings) in &model.keys {
            writeln!(writer, "K\t{}", serde_json::json!([key, postings])).unwrap();
        }
        for (kind, tables) in [("L", &model.localized), ("A", &model.admin_localized)] {
            for (language, table) in tables.iter().enumerate() {
                for (index, name) in table {
                    writeln!(writer, "{kind}\t{language}\t{index}\t{}", serde_json::json!(name)).unwrap();
                }
            }
        }
        writer.flush().unwrap();
    }

    fn fixture(tag: &str) -> (Vec<u8>, Vec<u8>, std::path::PathBuf, std::path::PathBuf) {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/index_builder");
        let directory = Path::new(env!("CARGO_MANIFEST_DIR")).join("target/selected-name-tests")
            .join(format!("{}-{tag}", std::process::id()));
        fs::create_dir_all(&directory).unwrap();
        let (image, companion) = build_with_population(
            &root.join("cities.txt"), &root.join("admin1CodesASCII.txt"), None, false,
        ).unwrap();
        (image, companion, root, directory)
    }

    #[test]
    fn selected_repair_preserves_all_other_fields_keys_and_population() {
        let (image, companion, root, directory) = fixture("preservation");
        let counts = population_payload(&image, &companion).unwrap().to_vec();
        let mut model = read_image(&image).unwrap();
        let city = model.cities.iter().position(|city| city.name == "Munich").unwrap();
        let admin = model.cities[city].admin;
        let de = slot("de").unwrap();
        model.localized[de].insert(city, "Stadt München".into());
        model.admin_localized[de].insert(admin, "Freistaat Bayern".into());
        let new_key = fold("München").into_bytes();
        model.keys.retain(|(key, _)| key != &new_key);
        let mut postings: BTreeMap<_, _> = model.keys.into_iter().collect();
        add_search_keys(&mut postings, city, "Stadt München");
        model.keys = postings.into_iter().collect();
        let mut image = write_image(&model).unwrap();
        let companion = attach_population(&mut image, &counts);
        let alternates = directory.join("alternates.tsv");
        let selection = directory.join("selection.tsv");
        fs::write(&alternates, "900001\t3\tde\tMünchen\t1\t\t\t\n900002\t1002\tde\tBayern\t1\t\t\t\n").unwrap();
        fs::write(&selection, format!(
            "kind\tindex\tlanguage\tgeonameid\tprimary\tbefore\tafter\tsource\ncity\t{city}\tde\t3\tMunich\tStadt München\tMünchen\tgeonames\nadmin\t{admin}\tde\t1002\tBavaria\tFreistaat Bayern\tBayern\tgeonames\n"
        )).unwrap();
        let inputs = SelectedNameInputs {
            cities: &root.join("cities.txt"), admins: &root.join("admin1CodesASCII.txt"),
            alternates: &alternates, selection: &selection,
        };
        let repaired = repair_selected_names(&image, Some(&companion), &inputs, &Labels::default()).unwrap();
        let after = read_image(&repaired.image).unwrap();
        let mut expected = model;
        expected.localized[de].insert(city, "München".into());
        expected.admin_localized[de].insert(admin, "Bayern".into());
        let mut postings: BTreeMap<_, _> = expected.keys.into_iter().collect();
        add_search_keys(&mut postings, city, "München");
        expected.keys = postings.into_iter().collect();
        assert_eq!(after, expected);
        assert_eq!(population_payload(&repaired.image, repaired.population.as_deref().unwrap()), Some(counts.as_slice()));
        assert_ne!(&image[116..128], &repaired.image[116..128]);
        assert_eq!(repaired.changes.len(), 2);
        assert!(repaired.changes[0].ends_with("alternate:900001"));
        assert!(repaired.changes[1].ends_with("alternate:900002"));
        assert!(repair_selected_names(&image, None, &inputs, &Labels::default()).is_err());
    }

    #[test]
    fn selected_repair_rejects_wrong_identity_names_sources_and_duplicate_cells() {
        let (image, companion, root, directory) = fixture("rejections");
        let model = read_image(&image).unwrap();
        let city = model.cities.iter().position(|city| city.name == "Munich").unwrap();
        let before = model.localized[slot("de").unwrap()].get(&city).map_or("", String::as_str);
        let alternates = directory.join("alternates.tsv");
        let selection = directory.join("selection.tsv");
        fs::write(&alternates, "900001\t3\tde\tMinga\t1\t\t\t\n").unwrap();
        let header = "kind\tindex\tlanguage\tgeonameid\tprimary\tbefore\tafter\tsource\n";
        let row = format!("city\t{city}\tde\t3\tMunich\t{before}\tMinga\tgeonames\n");
        let inputs = SelectedNameInputs {
            cities: &root.join("cities.txt"), admins: &root.join("admin1CodesASCII.txt"),
            alternates: &alternates, selection: &selection,
        };
        for rejected in [
            row.replace("\t3\t", "\t14\t"), row.replace("\tMunich\t", "\tParis\t"),
            row.replace(&format!("\t{before}\t"), "\tWrong old name\t"),
            row.replace("\tMinga\t", "\tInvented name\t"), row.replace("geonames", "primary"),
            row.replace("geonames", "wikidata"), row.replace("\tde\t", "\ten\t"),
            format!("{row}{row}"),
        ] {
            fs::write(&selection, format!("{header}{rejected}")).unwrap();
            assert!(repair_selected_names(&image, Some(&companion), &inputs, &Labels::default()).is_err(), "{rejected}");
        }
        fs::write(&selection, format!("{header}{row}")).unwrap();
        for rejected in [
            "900001\t3\tfr\tMinga\t1\t\t\t\n",
            "900001\t3\tde\tMinga\t1\t\t1\t\n",
            "900001\t3\tde\tMinga\t1\t\t\t1\n",
        ] {
            fs::write(&alternates, rejected).unwrap();
            assert!(repair_selected_names(&image, Some(&companion), &inputs, &Labels::default()).is_err());
        }
        let fallback = format!("city\t{city}\tde\t3\tMunich\t{before}\tMunich\tprimary\n");
        fs::write(&selection, format!("{header}{fallback}")).unwrap();
        let repaired = repair_selected_names(&image, Some(&companion), &inputs, &Labels::default()).unwrap();
        let after = read_image(&repaired.image).unwrap();
        assert!(!after.localized[slot("de").unwrap()].contains_key(&city));
        assert_eq!(after.keys, model.keys);
    }

    #[test]
    fn selected_english_primary_requires_existing_alias_and_upgrades_only_its_posting() {
        let (image, companion, root, directory) = fixture("english");
        let before = read_image(&image).unwrap();
        let city = before.cities.iter().position(|city| city.name == "Munich").unwrap();
        let selection = directory.join("selection.tsv");
        let header = "kind\tindex\tlanguage\tgeonameid\tprimary\tbefore\tafter\tsource\n";
        let row = format!("city\t{city}\ten\t3\tMunich\tMunich\tMunchen\tgeonames\n");
        fs::write(&selection, format!("{header}{row}")).unwrap();
        let inputs = SelectedNameInputs {
            cities: &root.join("cities.txt"), admins: &root.join("admin1CodesASCII.txt"),
            alternates: &root.join("alternateNamesV2.txt"), selection: &selection,
        };
        let repaired = repair_selected_names(&image, Some(&companion), &inputs, &Labels::default()).unwrap();
        let after = read_image(&repaired.image).unwrap();
        let mut expected = before.clone();
        expected.cities[city].name = "Munchen".into();
        let key = fold("Munchen").into_bytes();
        let (_, values) = expected.keys.iter_mut().find(|(existing, _)| *existing == key).unwrap();
        let value = values.iter_mut().find(|value| (**value & !PRIMARY_BIT) as usize == city).unwrap();
        *value |= PRIMARY_BIT;
        assert_eq!(after, expected);
        assert_eq!(population_payload(&repaired.image, repaired.population.as_deref().unwrap()),
            population_payload(&image, &companion));
        assert!(repaired.changes[0].ends_with("cities500:3:alternate"));
        for rejected in [
            row.replace("\tMunchen\t", "\tMade Up City\t"),
            row.replace("\tMunich\tMunich\t", "\tMunich\tWrong old name\t"),
            row.replace("geonames", "wikidata"), row.replacen("city\t", "admin\t", 1),
        ] {
            fs::write(&selection, format!("{header}{rejected}")).unwrap();
            assert!(repair_selected_names(&image, Some(&companion), &inputs, &Labels::default()).is_err());
        }
    }

    #[test]
    fn selected_generic_aliases_cross_languages_only_for_administrative_shortening() {
        let (_, _, _, directory) = fixture("generic-aliases");
        let cities = directory.join("cities.txt");
        let admins = directory.join("admins.txt");
        let alternates = directory.join("alternates.tsv");
        let selection = directory.join("selection.tsv");
        fs::write(&cities, [
            "42\tBeijing\tBeijing\t\t39.9\t116.4\tP\tPPL\tCN\t\t\t\t\t\t1000\t\t\tAsia/Shanghai\n",
            "43\tShanghai\tShanghai\t\t31.2\t121.5\tP\tPPL\tCN\t\t\t\t\t\t900\t\t\tAsia/Shanghai\n",
        ].concat()).unwrap();
        fs::write(&admins, "").unwrap();
        fs::write(&alternates, [
            "900001\t42\tzh\t北京\t1\t\t\t\n",
            "900002\t43\tja\t上海\t1\t\t\t\n",
            "900003\t42\tzh\t上海\t1\t\t\t\n",
        ].concat()).unwrap();
        let (image, population) = build_with_population(&cities, &admins, None, false).unwrap();
        let counts = population_payload(&image, &population).unwrap();
        let mut before = read_image(&image).unwrap();
        let beijing = before.cities.iter().position(|city| city.name == "Beijing").unwrap();
        let shanghai = before.cities.iter().position(|city| city.name == "Shanghai").unwrap();
        let ja = slot("ja").unwrap();
        let hant = slot("zh-Hant").unwrap();
        before.localized[ja].insert(beijing, "北京市".into());
        before.localized[hant].insert(shanghai, "上海市".into());
        let mut image = write_image(&before).unwrap();
        let population = attach_population(&mut image, counts);
        let header = "kind\tindex\tlanguage\tgeonameid\tprimary\tbefore\tafter\tsource\n";
        let rows = format!(
            "city\t{beijing}\tja\t42\tBeijing\t北京市\t北京\tgeonames-generic\ncity\t{shanghai}\tzh-Hant\t43\tShanghai\t上海市\t上海\tgeonames-generic\n"
        );
        fs::write(&selection, format!("{header}{rows}")).unwrap();
        let inputs = SelectedNameInputs { cities: &cities, admins: &admins, alternates: &alternates, selection: &selection };
        let repaired = repair_selected_names(&image, Some(&population), &inputs, &Labels::default()).unwrap();
        let mut expected = before;
        expected.localized[ja].insert(beijing, "北京".into());
        expected.localized[hant].insert(shanghai, "上海".into());
        let mut keys: BTreeMap<_, _> = expected.keys.into_iter().collect();
        add_search_keys(&mut keys, beijing, "北京");
        add_search_keys(&mut keys, shanghai, "上海");
        expected.keys = keys.into_iter().collect();
        assert_eq!(read_image(&repaired.image).unwrap(), expected);
        assert_eq!(population_payload(&repaired.image, repaired.population.as_deref().unwrap()), Some(counts));
        for rejected in [rows.replace("\t北京市\t北京\t", "\t北京市\t上海\t"), rows.replace("geonames-generic", "geonames")] {
            fs::write(&selection, format!("{header}{rejected}")).unwrap();
            assert!(repair_selected_names(&image, Some(&population), &inputs, &Labels::default()).is_err());
        }
        fs::write(&selection, format!("{header}{rows}")).unwrap();
        fs::write(&alternates, "900001\t42\tzh\t北京\t1\t\t\t1\n900002\t43\tja\t上海\t1\t\t\t\n").unwrap();
        assert!(repair_selected_names(&image, Some(&population), &inputs, &Labels::default()).is_err());
    }
}

/// 「加语言」用的 Wikidata 两张表：标签与确认行。
#[derive(Default)]
pub struct Labels {
    pub cities: Vec<WikidataLabel>,
    pub admins: Vec<WikidataLabel>,
    pub city_confirmations: Vec<Confirmation>,
    pub admin_confirmations: Vec<Confirmation>,
}

/// GeoNames `admin1CodesASCII.txt` → 「国家码.行政区码」→（名字, 行政区的 GeoNames ID）。
fn load_admins(admin_path: &Path) -> Result<HashMap<String, (String, String)>, Box<dyn Error>> {
    let mut admins = HashMap::new();
    for line in BufReader::new(File::open(admin_path)?).lines() {
        let line = line?;
        let fields: Vec<_> = line.split('\t').collect();
        if fields.len() >= 4 {
            admins.insert(fields[0].to_owned(), (clean_value(fields[1]), fields[3].to_owned()));
        }
    }
    Ok(admins)
}

/// GeoNames `cities500.txt` → 城市行，按人口降序、ASCII 名、国家码排好（记录号就是这个顺序）。生成与「加语言」共用，
/// 所以两条路对同一份转储得到同一个记录号。
fn load_rows(cities_path: &Path) -> Result<Vec<City>, Box<dyn Error>> {
    let mut rows = Vec::new();
    for line in BufReader::new(File::open(cities_path)?).lines() {
        let line = line?;
        let f: Vec<_> = line.split('\t').collect();
        if f.len() < 18
            || matches!(f[7], "PPLH" | "PPLQ" | "PPLW" | "PPLCH")
            || f[17].trim_matches(whitespace).is_empty()
        {
            continue;
        }
        let (Ok(latitude), Ok(longitude), Ok(population)) = (
            f[4].trim_matches(whitespace).parse::<f64>(),
            f[5].trim_matches(whitespace).parse::<f64>(),
            if f[14].is_empty() {
                Ok(0)
            } else {
                f[14].trim_matches(whitespace).parse::<i64>()
            },
        ) else {
            continue;
        };
        rows.push(City {
            population,
            ascii: clean_value(f[2]),
            country: f[8].trim_matches(whitespace).to_owned(),
            name: clean_value(f[1]),
            alternates: f[3].to_owned(),
            latitude,
            longitude,
            admin: f[10].trim_matches(whitespace).to_owned(),
            timezone: f[17].trim_matches(whitespace).to_owned(),
            id: f[0].trim_matches(whitespace).to_owned(),
        });
    }
    rows.sort_by(|a, b| {
        b.population
            .cmp(&a.population)
            .then_with(|| a.ascii.cmp(&b.ascii))
            .then_with(|| a.country.cmp(&b.country))
    });
    Ok(rows)
}

#[cfg(test)]
pub fn build_with_population(
    cities_path: &Path,
    admin_path: &Path,
    alternate_path: Option<&Path>,
    supplement: bool,
) -> Result<(Vec<u8>, Vec<u8>), Box<dyn Error>> {
    let (mut image, populations, _) =
        build_images(cities_path, admin_path, alternate_path, supplement, &[])?;
    let population = attach_population(&mut image, &populations);
    Ok((image, population))
}

#[cfg(test)]
pub fn build_with_options(
    cities_path: &Path,
    admin_path: &Path,
    output_path: &Path,
    alternate_path: Option<&Path>,
    supplement: bool,
) -> Result<BuildStats, Box<dyn Error>> {
    let (image, _, stats) = build_images(cities_path, admin_path, alternate_path, supplement, &[])?;
    fs::write(output_path, image)?;
    Ok(stats)
}

type BuiltImages = (Vec<u8>, Vec<u8>, BuildStats);

fn build_images(
    cities_path: &Path,
    admin_path: &Path,
    alternate_path: Option<&Path>,
    supplement: bool,
    primary_errata: &[(&str, &str, &str)],
) -> Result<BuiltImages, Box<dyn Error>> {
    let admins = load_admins(admin_path)?;
    let rows = load_rows(cities_path)?;
    if rows.len() >= MAX_CITIES {
        return Err(format!(
            "{} cities exceed the TTCITY08 posting limit of {MAX_CITIES}",
            rows.len()
        )
        .into());
    }
    let (mut timezone_list, mut country_list, mut admin_list) =
        (Vec::new(), Vec::new(), Vec::new());
    let (mut timezone_index, mut country_index, mut admin_index) =
        (HashMap::new(), HashMap::new(), HashMap::new());
    let mut postings: BTreeMap<String, Vec<u32>> = BTreeMap::new();
    let mut city_rows = Vec::with_capacity(rows.len());
    let mut city_by_id = HashMap::new();
    for (index, city) in rows.iter().enumerate() {
        city_by_id.insert(city.id.clone(), index);
        let timezone = string_id(&city.timezone, &mut timezone_list, &mut timezone_index);
        let country = string_id(&city.country, &mut country_list, &mut country_index);
        let admin_key = format!("{}.{}", city.country, city.admin);
        let admin = if admins.contains_key(&admin_key) {
            string_id(&admin_key, &mut admin_list, &mut admin_index)
        } else {
            0xffff
        };
        city_rows.push(CityRow {
            name: city.name.clone(),
            admin,
            timezone,
            country,
            latitude: city.latitude as f32,
            longitude: city.longitude as f32,
        });
        let mut seen = HashSet::new();
        let mut primary = Vec::new();
        for value in [&city.ascii, &city.name] {
            let key = fold(value);
            if !key.is_empty() && seen.insert(key.clone()) {
                primary.push(key);
            }
        }
        for key in &primary {
            postings
                .entry(key.clone())
                .or_default()
                .push(index as u32 | PRIMARY_BIT);
        }
        for key in &primary {
            for secondary in secondary_keys(key) {
                if !secondary.is_empty() && seen.insert(secondary.clone()) {
                    postings.entry(secondary).or_default().push(index as u32);
                }
            }
        }
        for alternate in pick_alternates(
            &city.alternates,
            alternate_budget(city.population),
            &mut seen,
        ) {
            postings.entry(alternate).or_default().push(index as u32);
        }
    }
    let mut representatives = vec![u32::MAX; timezone_list.len()];
    let mut country_tops = vec![Vec::new(); country_list.len()];
    for (index, city) in rows.iter().enumerate() {
        let timezone = timezone_index[&city.timezone];
        if representatives[timezone] == u32::MAX {
            representatives[timezone] = index as u32;
        }
        let top = &mut country_tops[country_index[&city.country]];
        if top.len() < 8 {
            top.push(index as u32);
        }
    }
    let mut localized: Vec<BTreeMap<usize, String>> = vec![BTreeMap::new(); LANGUAGES.len()];
    let mut admin_localized: Vec<BTreeMap<usize, String>> = vec![BTreeMap::new(); LANGUAGES.len()];
    let admin_by_id: HashMap<_, _> = admin_list
        .iter()
        .enumerate()
        .map(|(index, key)| (admins[key].1.clone(), index))
        .collect();
    if let Some(path) = alternate_path {
        let table = learn_pinyin(&rows);
        let mut candidates: HashMap<(usize, usize), Bucket> = HashMap::new();
        let mut admin_candidates: HashMap<(usize, usize), Bucket> = HashMap::new();
        let mut fallback: HashMap<(usize, usize), Bucket> = HashMap::new();
        for line in BufReader::new(File::open(path)?).lines() {
            let line = line?;
            let fields: Vec<_> = line.split('\t').collect();
            if fields.len() < 4 {
                continue;
            }
            let (id, language, value) = (fields[1], fields[2], clean_value(fields[3]));
            if value.is_empty() || len(&value) > 80 || malformed(&value) {
                continue;
            }
            let city_index = city_by_id.get(id).copied();
            let admin_position = if city_index.is_none() {
                admin_by_id.get(id).copied()
            } else {
                None
            };
            if city_index.is_none() && admin_position.is_none() {
                continue;
            }
            if fields.get(7) == Some(&"1") || fields.get(6) == Some(&"1") {
                continue;
            }
            let language_slot = slot(language).filter(|slot| *slot < BASE_LANGUAGES || supplement);
            if language_slot.is_some_and(|slot| !script_fits(&value, slot)) {
                continue;
            }
            let Some(language_slot) = language_slot else {
                let Some(index) = city_index.filter(|_| language.is_empty()) else {
                    continue;
                };
                let Some((allowed, language_slot)) = native_rule(&rows[index].country) else {
                    continue;
                };
                if value == rows[index].name {
                    continue;
                }
                let Some(kinds) = native_script(&value) else {
                    continue;
                };
                if kinds & !allowed != 0 {
                    continue;
                }
                let bucket = fallback.entry((language_slot, index)).or_default();
                if bucket.len() < 8 {
                    bucket.push((1, value));
                }
                continue;
            };
            // 秩：0 留给 Wikidata 的 strong 标签，GeoNames 的首选名 1、其余 2，Wikidata 的 weak 标签 3（只填空缺）。
            let rank = if fields.get(4) == Some(&"1") { 1 } else { 2 };
            let bucket = if let Some(index) = city_index {
                if value == rows[index].name {
                    continue;
                }
                candidates.entry((language_slot, index)).or_default()
            } else {
                admin_candidates
                    .entry((language_slot, admin_position.unwrap()))
                    .or_default()
            };
            if bucket.len() < 8 {
                bucket.push((rank, value));
            }
        }
        // Wikidata 标签（`data/city_names_wikidata.tsv` / `admin1_names_wikidata.tsv`）：
        // 通行译名优先。strong 的（条目英文标签对得上
        // GeoNames 主名）排在 GeoNames 名字前面，weak 的排在后面只填空缺；文种不合、与主名相同、带半个括号的不收；
        // 城市名照样过通名规则（GeoNames 给「西宁」、Wikidata 给「西宁市」，取西宁），行政区名不去尾。
        if supplement {
            for (id, slot, label, strong) in wikidata_labels("city_names_wikidata.tsv")? {
                let Some(&index) = city_by_id.get(&id) else {
                    continue;
                };
                if !script_fits(&label, slot) || label == rows[index].name || malformed(&label) || len(&label) > 80 {
                    continue;
                }
                candidates
                    .entry((slot, index))
                    .or_default()
                    .push((if strong { 0 } else { 3 }, label));
            }
            for (id, slot, label, strong) in wikidata_labels("admin1_names_wikidata.tsv")? {
                let Some(&position) = admin_by_id.get(&id) else {
                    continue;
                };
                if !script_fits(&label, slot) || malformed(&label) || len(&label) > 80 {
                    continue;
                }
                admin_candidates
                    .entry((slot, position))
                    .or_default()
                    .push((if strong { 0 } else { 3 }, label));
            }
        }
        // 无标注的母语名（`fallback`）也是数据给的名字：Wikidata 给「泽普县」而 GeoNames 无标注列里有「泽普」时，
        // 通名规则要能取到裸名，所以并进候选桶排在最后（秩 4）；桶里本来没东西的城市仍走下面的读音互证路。
        for ((language, index), bucket) in fallback.iter().filter(|_| supplement) {
            if let Some(candidates_bucket) = candidates.get_mut(&(*language, *index)) {
                candidates_bucket.extend(bucket.iter().map(|(_, name)| (4, name.clone())));
            }
        }
        for ((language, index), bucket) in &mut candidates {
            localized[*language].insert(*index, choose_name(bucket, Some(&rows[*index].name)));
        }
        for ((language, index), bucket) in &fallback {
            if localized[*language].contains_key(index) {
                continue;
            }
            if let Some(name) = choose_native(bucket, &rows[*index].name, &table) {
                localized[*language].insert(*index, name);
            }
        }
        for (id, language, value) in rules::ERRATA {
            let Some(index) = city_by_id.get(*id).copied() else {
                continue;
            };
            let language = slot(language).unwrap();
            let key = (language, index);
            let pool: Vec<_> = candidates
                .get(&key)
                .into_iter()
                .chain(fallback.get(&key))
                .flatten()
                .map(|(_, value)| value.as_str())
                .collect();
            if pool.is_empty() {
                continue;
            }
            if let Some(value) = value {
                if !pool.contains(value) {
                    return Err(format!(
                        "勘误表 {id}/{} 的目标值不在 GeoNames 候选里:{value}",
                        LANGUAGES[language]
                    )
                    .into());
                }
                localized[language].insert(index, (*value).to_owned());
            } else {
                localized[language].remove(&index);
            }
        }
        // 行政区中文名的两张表进候选桶：人工核过的 ADMIN1_ZH 秩 0（与 Wikidata strong 并列、先入先取），
        // 补充表（Wikidata 1,178 + LLM 348）秩 1——压过 GeoNames 没给、只有裸 `zh` 标签（不分简繁、常是台湾写法
        // 「圖林根邦」）的 weak 标签，让不过 strong 的 Wikidata 标签。繁体为空时不写，显示层会从简体转换
        // （catalog.select_name 的 zh-Hans ↔ zh-Hant 回退 + CFStringTransform）。
        for (code, hans, hant) in rules::ADMIN1_ZH {
            let Some(index) = admin_index.get(*code).copied() else {
                continue;
            };
            admin_candidates.entry((0, index)).or_default().insert(0, (0, (*hans).to_owned()));
            admin_candidates.entry((1, index)).or_default().insert(0, (0, (*hant).to_owned()));
        }
        for (code, hans, hant) in rules::admin1_supplement().filter(|_| supplement) {
            let Some(index) = admin_index.get(code).copied() else {
                continue;
            };
            admin_candidates.entry((0, index)).or_default().push((1, hans.to_owned()));
            if !hant.is_empty() {
                admin_candidates.entry((1, index)).or_default().push((1, hant.to_owned()));
            }
        }
        for ((language, index), bucket) in &mut admin_candidates {
            let name = choose_name(bucket, None);
            if name != admins[&admin_list[*index]].0 {
                admin_localized[*language].insert(*index, name);
            }
        }
    }
    // 显示名必须搜得到：每个本地化显示名折叠后作为这座城市的次名键；Wikidata 补来的名字
    // 不在 GeoNames 的别名列里，不加这一步用户看得见「弗里敦」却搜不到。已有这座城市倒排的键不重复；
    // 倒排按人口序（记录号升序）。与补充表同一个开关：黄金夹具是 Python 生成器的产物，没有这些键。
    if supplement {
        for table in &localized {
            for (&index, name) in table {
                let key = fold(name);
                if key.is_empty() || len(&key) > 40 {
                    continue;
                }
                let values = postings.entry(key).or_default();
                if !values.iter().any(|v| (*v & !PRIMARY_BIT) as usize == index) {
                    values.push(index as u32);
                    values.sort_by_key(|v| *v & !PRIMARY_BIT);
                }
            }
        }
    }
    let keys: Vec<(Vec<u8>, Vec<u32>)> = postings
        .into_iter()
        .map(|(key, values)| (key.into_bytes(), values))
        .collect();
    let mut languages: Vec<String> = LANGUAGES.iter().map(|l| (*l).to_owned()).collect();
    while languages.len() > BASE_LANGUAGES
        && localized.last().is_some_and(BTreeMap::is_empty)
        && admin_localized.last().is_some_and(BTreeMap::is_empty)
    {
        languages.pop();
        localized.pop();
        admin_localized.pop();
    }
    let mut model = Model {
        cities: city_rows,
        keys,
        timezones: timezone_list,
        countries: country_list,
        languages,
        admins: admin_list.iter().map(|key| admins[key].0.clone()).collect(),
        representatives,
        country_tops,
        localized,
        admin_localized,
    };
    patch_primary_names(&mut model, primary_errata)?;
    let output = write_image(&model)?;
    let posting_count = model.keys.iter().map(|(_, v)| v.len()).sum();
    let rows_len = model.cities.len();
    let keys_len = model.keys.len();
    let stats = BuildStats {
        cities: rows_len,
        keys: keys_len,
        postings: posting_count,
        timezones: model.timezones.len(),
        countries: model.countries.len(),
        admins: model.admins.len(),
        localized: model.localized.iter().map(BTreeMap::len).sum(),
        admin_localized: model.admin_localized.iter().map(BTreeMap::len).sum(),
        bytes: output.len(),
    };
    let populations = rows.iter().map(|city| population_bucket(city.population)).collect();
    Ok((output, populations, stats))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn primary_name_fixture(cities: &Path, output: &Path) -> std::path::PathBuf {
        let directory = Path::new(env!("CARGO_MANIFEST_DIR")).join("target/nyname-fixtures")
            .join(std::process::id().to_string());
        fs::create_dir_all(&directory).unwrap();
        let path = directory.join(output.file_name().unwrap()).with_extension("cities.txt");
        let mut rows = fs::read_to_string(cities).unwrap();
        rows.push_str("\n5128581\tNew York City\tNew York City\tNew York,NYC\t40.71427\t-74.00597\tP\tPPL\tUS\t\tNY\t\t\t\t15000\t\t\tAmerica/New_York\t2026-10-07\n");
        fs::write(&path, rows).unwrap();
        path
    }

    #[test]
    fn primary_name_errata_reselects_existing_keys_and_is_strict_and_idempotent() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/index_builder");
        let cities = primary_name_fixture(&root.join("cities.txt"), Path::new("errata.ttcity"));
        let (old, population) = build_with_population(&cities, &root.join("admin1CodesASCII.txt"), None, false).unwrap();
        let before = read_image(&old).unwrap();
        let (new, companion, _) = transcode_primary_names_with_population(&old, Some(&population), &[]).unwrap();
        let after = read_image(&new).unwrap();
        let city = before.cities.iter().position(|city| city.name == "New York City").unwrap();
        let mut expected = before.clone();
        expected.cities[city].name = "New York".into();
        assert_eq!(after, expected);
        let companion = companion.unwrap();
        assert_eq!(population_payload(&old, &population), population_payload(&new, &companion));
        assert_eq!(transcode_primary_names_with_population(&new, Some(&companion), &[]).unwrap().0, new);
        let mut missing = before.clone();
        assert!(patch_primary_names(&mut missing, &[("Atlantis", "US", "New York")]).is_err());
        assert!(patch_primary_names(&mut missing, &[("New York City", "CA", "New York")]).is_err());
        assert!(patch_primary_names(&mut missing, &[("New York City", "US", "Invented")]).is_err());
        let mut duplicate = before.clone();
        duplicate.cities.push(before.cities[city].clone());
        assert!(patch_primary_names(&mut duplicate, rules::PRIMARY_NAME_ERRATA).is_err());
        let output = cities.with_extension("full.ttcity");
        build(&cities, &root.join("admin1CodesASCII.txt"), &output, None).unwrap();
        assert_eq!(read_image(&fs::read(output).unwrap()).unwrap().cities[city].name, "New York");
        let output = cities.with_extension("missing.ttcity");
        assert!(build(&root.join("cities.txt"), &root.join("admin1CodesASCII.txt"), &output, None).is_err());
        assert!(!output.exists());
    }

    #[test]
    fn added_population_preserves_index_bytes_and_matches_records_after_population_order_changes() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/index_builder");
        let (image, _) = build_with_population(&root.join("cities.txt"), &root.join("admin1CodesASCII.txt"), None, false).unwrap();
        let mut model = read_image(&image).unwrap();
        model.cities.reverse();
        // 键与名单仍指向有效记录，人口只按记录的身份匹配。
        let reversed = write_image(&model).unwrap();
        let (output, report) = add_population(&reversed, &root.join("cities.txt")).unwrap();
        assert_eq!(report.matches.matched, 16);
        assert!(report.unmatched_by_country.is_empty());
        let (bound, companion) = output.unwrap();
        assert_eq!(&bound[..ttcity::FINGERPRINT_OFFSET], &reversed[..ttcity::FINGERPRINT_OFFSET]);
        assert_eq!(&bound[ttcity::HEADER..], &reversed[ttcity::HEADER..]);
        let payload = population_payload(&bound, &companion).unwrap();
        let rows = load_rows(&root.join("cities.txt")).unwrap();
        for (at, expected) in rows.iter().rev().enumerate() {
            assert_eq!(payload[at], population_bucket(expected.population), "{}", expected.name);
        }
        let (again, _) = add_population(&bound, &root.join("cities.txt")).unwrap();
        assert_eq!(again.unwrap(), (bound, companion));
    }

    #[test]
    fn added_population_leaves_one_percent_unknown_and_refuses_more() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/index_builder");
        let (image, _) = build_with_population(&root.join("cities.txt"), &root.join("admin1CodesASCII.txt"), None, false).unwrap();
        let mut model = read_image(&image).unwrap();
        model.cities.resize(100, model.cities[0].clone());
        model.cities[99].name = "Unmatched town".into();
        let image = write_image(&model).unwrap();
        let (output, report) = add_population(&image, &root.join("cities.txt")).unwrap();
        assert_eq!(report.matches.matched, 99);
        assert_eq!(report.matches.unmatched, 1);
        assert_eq!(report.unmatched_by_country.values().sum::<usize>(), 1);
        assert!(report.unmatched_records[0].contains("Unmatched town"));
        let (bound, companion) = output.unwrap();
        assert_eq!(population_payload(&bound, &companion).unwrap()[99], 0);
        model.cities[98].name = "Another unmatched town".into();
        let image = write_image(&model).unwrap();
        let (output, report) = add_population(&image, &root.join("cities.txt")).unwrap();
        assert!(output.is_none());
        assert_eq!(report.matches.matched, 98);
        assert_eq!(report.matches.unmatched, 2);
    }

    #[test]
    fn population_matching_requires_unique_name_coordinates_zone_and_country() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/index_builder");
        let (image, _) = build_with_population(&root.join("cities.txt"), &root.join("admin1CodesASCII.txt"), None, false).unwrap();
        let model = read_image(&image).unwrap();
        let mut rows = load_rows(&root.join("cities.txt")).unwrap();
        rows[0].name.push_str(" changed");
        rows[1].latitude += 1.0;
        rows[2].timezone = "Etc/UTC".into();
        rows[3].country = "XX".into();
        let duplicate = load_rows(&root.join("cities.txt")).unwrap().remove(4);
        rows.push(duplicate);
        let (positions, report) = match_records(&model, &rows);
        assert_eq!(report.matched, 11);
        assert_eq!(report.unmatched, 4);
        assert_eq!(report.ambiguous, 1);
        assert!(positions[..5].iter().all(Option::is_none));
    }

    #[test]
    fn population_buckets_cover_unknown_small_and_saturated_values() {
        assert_eq!(population_bucket(-1), 0);
        assert_eq!(population_bucket(0), 0);
        assert_eq!(population_bucket(1), 1);
        assert_eq!(population_bucket(2), 7);
        assert_eq!(population_bucket(100), 48);
        assert_eq!(population_bucket(i64::MAX), 255);
        for population in [24_171, 68_408, 422_324, 8_961_989] {
            let decoded = 1.1_f64.powi(i32::from(population_bucket(population))).round();
            assert!((decoded / population as f64 - 1.0).abs() < 0.05);
        }
    }

    #[test]
    fn population_fingerprint_matches_an_independent_vector_and_zeros_padding() {
        let mut image: Vec<u8> = (0..132).collect();
        let expected = [0x57, 0xb0, 0x31, 0x0f, 0xb6, 0xcb, 0xa5, 0x10, 0xce, 0x8e, 0x50, 0xf2];
        assert_eq!(build_fingerprint(&image, &[0, 1, 255]), expected);
        image[ttcity::FINGERPRINT_OFFSET..ttcity::HEADER].fill(0);
        assert_eq!(build_fingerprint(&image, &[0, 1, 255]), expected);
        image[128] ^= 1;
        assert_ne!(build_fingerprint(&image, &[0, 1, 255]), expected);
        assert_ne!(build_fingerprint(&image, &[0, 2, 255]), expected);
    }

    #[test]
    fn population_companion_survives_transcode_and_rebinds_changed_bytes() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/index_builder");
        let (image, population) = build_with_population(
            &root.join("cities.txt"), &root.join("admin1CodesASCII.txt"), None, false,
        ).unwrap();
        assert_eq!(&population[..4], b"TTPP");
        assert_eq!(le32(&population, 4), 1);
        assert_eq!(population.len(), 24 + le32(&image, 12));
        assert!(image[ttcity::FINGERPRINT_OFFSET..ttcity::HEADER].iter().any(|&byte| byte != 0));
        assert_eq!(&image[ttcity::FINGERPRINT_OFFSET..ttcity::HEADER], &population[12..24]);
        let (same_image, same_population, report) =
            transcode_with_population(&image, Some(&population), &[]).unwrap();
        assert_eq!(same_image, image);
        assert_eq!(same_population.as_ref(), Some(&population));
        assert_eq!(report, PatchReport::default());
        let (changed_image, changed_population, report) = transcode_with_population(
            &image, Some(&population), &[("Munich", "DE", &["Minga fingerprint test"])],
        ).unwrap();
        assert_eq!(report.keys_added, 1);
        let changed_population = changed_population.unwrap();
        assert_ne!(&changed_population[12..24], &population[12..24]);
        assert_eq!(&changed_population[24..], &population[24..]);
        assert_eq!(population_payload(&changed_image, &changed_population), Some(&population[24..]));
        let before = read_image(&image).unwrap();
        let after = read_image(&changed_image).unwrap();
        assert_eq!(before.cities, after.cities);
        let (plain, _, _) = transcode_with_population(&image, None, &[]).unwrap();
        let mut expected_plain = image.clone();
        expected_plain[ttcity::FINGERPRINT_OFFSET..ttcity::HEADER].fill(0);
        assert_eq!(plain, expected_plain);
    }

    #[test]
    fn direct_transcode_keeps_only_an_unchanged_population_binding() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/index_builder");
        let (image, companion) = build_with_population(
            &root.join("cities.txt"), &root.join("admin1CodesASCII.txt"), None, false,
        ).unwrap();
        let (same, report) = transcode(&image, &[]).unwrap();
        assert_eq!(same, image);
        assert_eq!(report, PatchReport::default());
        assert!(population_payload(&same, &companion).is_some());
        let patch = &[("Munich", "DE", &["Minga direct transcode test"][..])];
        let (changed, report) = transcode(&image, patch).unwrap();
        assert_eq!(report.keys_added, 1);
        assert!(changed[ttcity::FINGERPRINT_OFFSET..ttcity::HEADER].iter().all(|&byte| byte == 0));
        assert!(population_payload(&changed, &companion).is_none());
        assert_eq!(read_image(&changed).unwrap().cities, read_image(&image).unwrap().cities);
        assert_eq!(transcode(&changed, patch).unwrap().0, changed);
    }

    #[test]
    fn population_transcode_ignores_invalid_companions() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/index_builder");
        let (image, population) = build_with_population(
            &root.join("cities.txt"), &root.join("admin1CodesASCII.txt"), None, false,
        ).unwrap();
        for at in [0, 4, 8, 12] {
            let mut invalid = population.clone();
            invalid[at] ^= 1;
            assert!(population_payload(&image, &invalid).is_none());
            let (output, companion, _) = transcode_with_population(&image, Some(&invalid), &[]).unwrap();
            assert!(companion.is_none());
            assert!(output[ttcity::FINGERPRINT_OFFSET..ttcity::HEADER].iter().all(|&byte| byte == 0));
        }
        let mut long = population.clone();
        long.push(0);
        assert!(population_payload(&image, &long).is_none());
        assert!(population_payload(&image, &population[..population.len() - 1]).is_none());
        let mut unbound = image;
        unbound[ttcity::FINGERPRINT_OFFSET..ttcity::HEADER].fill(0);
        assert!(population_payload(&unbound, &population).is_none());
    }

    #[test]
    fn full_build_writes_the_bound_population_companion_next_to_the_index() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/index_builder");
        let target = Path::new(env!("CARGO_MANIFEST_DIR")).join("target/samename-builder")
            .join(format!("{}", std::process::id()));
        fs::create_dir_all(&target).unwrap();
        let output = target.join("full.ttcity");
        let cities = primary_name_fixture(&root.join("cities.txt"), &output);
        let stats = build(&cities, &root.join("admin1CodesASCII.txt"), &output, None).unwrap();
        let image = fs::read(&output).unwrap();
        let population = fs::read(output.with_extension("ttpop")).unwrap();
        assert_eq!(stats.cities, 17);
        assert_eq!(stats.bytes, image.len());
        assert_eq!(population_payload(&image, &population).unwrap().len(), stats.cities);
    }

    #[test]
    fn folding_keeps_the_existing_search_key_contract() {
        assert_eq!(fold("  St. Pétersburg—New_York "), "st petersburg new york");
        assert_eq!(fold("N’Djamena"), "ndjamena");
        assert_eq!(fold("ΟΣ"), "ος");
        assert_eq!(fold("서울"), "서울");
    }
    #[test]
    fn only_administrative_tails_can_shorten_a_name() {
        assert!(admin_tail("城关镇"));
        assert!(admin_tail("土家族自治县"));
        assert!(!admin_tail("湖街道"));
        let mut bucket = vec![
            (0, "青山湖街道".to_owned()),
            (1, "青山".to_owned()),
            (1, "青山湖".to_owned()),
        ];
        assert_eq!(choose_name(&mut bucket, Some("Qingshanhu")), "青山湖");
        // 前面的通名同理：Wikidata 的「Ville de Saragosse」压过 GeoNames 时，短的那个也在数据里就取短的。
        let mut bucket = vec![(0, "Ville de Saragosse".to_owned()), (1, "Saragosse".to_owned())];
        assert_eq!(choose_name(&mut bucket, Some("Zaragoza")), "Saragosse");
        let mut bucket = vec![(0, "Ville de Saragosse".to_owned())];
        assert_eq!(choose_name(&mut bucket, Some("Zaragoza")), "Ville de Saragosse");
    }
    #[test]
    fn municipal_labels_require_an_existing_short_name() {
        for (full, short) in [
            ("Stadt Madrid", "Madrid"), ("Ville de Madrid", "Madrid"), ("Ciudad de Madrid", "Madrid"),
            ("Casco histórico de Graz", "Graz"), ("Kreisfreie Stadt Aachen", "Aachen"),
            ("Administração Municipal dos Navegantes", "Navegantes"),
            ("Brüksel Şehri", "Brüksel"), ("Мадрид-сити", "Мадрид"), ("北京市", "北京"),
        ] {
            let mut bucket = vec![(0, full.to_owned()), (1, short.to_owned())];
            assert_eq!(choose_name(&mut bucket, Some("Other")), short);
            let mut only_label = vec![(0, full.to_owned())];
            assert_eq!(choose_name(&mut only_label, Some("Other")), full);
        }
        let mut madrid = vec![(0, "Stadt Madrid".to_owned())];
        assert_eq!(choose_name(&mut madrid, Some("Madrid")), "Madrid");
        for full in ["District Madrid", "Province de Madrid", "Gmina Madrid", "Kabupaten Madrid", "Madrid区", "Madrid県"] {
            let mut bucket = vec![(0, full.to_owned())];
            assert_eq!(choose_name(&mut bucket, Some("Madrid")), full);
        }
        let mut province = vec![(0, "Province de Madrid".to_owned()), (1, "Madrid".to_owned())];
        assert_eq!(choose_name(&mut province, Some("Madrid")), "Province de Madrid");
    }
    #[test]
    fn complete_city_compounds_keep_their_identity_across_languages() {
        for (primary, full, short) in [
            ("Ho Chi Minh City", "Ho Chi Minh Kenti", "Ho Chi Minh"),
            ("Sadr City", "Sadr Şehri", "Sadr"),
            ("Kansas City", "Канзас-Сити", "Канзас"),
            ("City of London", "Cidade de Londres", "Londres"),
            ("Ciudad Juárez", "Thành phố Juárez", "Juárez"),
            ("Ciudad Acuña", "Thành phố Acuña", "Acuña"),
            ("Clarence Town", "Ville de Clarence", "Clarence"),
            ("Clarence Town", "Cidade de Clarence", "Clarence"),
            ("Clarence Town", "Kota Clarence", "Clarence"),
            ("Example Township", "Municipality of Example", "Example"),
        ] {
            let mut bucket = vec![(0, full.to_owned()), (1, short.to_owned())];
            assert_eq!(choose_name(&mut bucket, Some(primary)), full);
        }
        let mut complete = vec![(0, "City of Kansas City".to_owned()), (1, "Kansas City".to_owned())];
        assert_eq!(choose_name(&mut complete, Some("Kansas City")), "Kansas City");
        for (primary, full) in [
            ("Clarence Town", "City of Clarence Town"),
            ("Example Township", "Municipality of Example Township"),
        ] {
            let mut complete = vec![(0, full.to_owned()), (1, primary.to_owned())];
            assert_eq!(choose_name(&mut complete, Some(primary)), primary);
            let mut fallback = vec![(0, full.to_owned())];
            assert_eq!(choose_name(&mut fallback, Some(primary)), primary);
        }
        let mut ranked = vec![(0, "Clarence".to_owned()), (1, "Ville de Clarence".to_owned())];
        assert_eq!(choose_name(&mut ranked, Some("Clarence Town")), "Clarence");
        let mut admin = vec![(0, "Kreisfreie Stadt Aachen".to_owned()), (1, "Aachen".to_owned())];
        assert_eq!(choose_name(&mut admin, None), "Kreisfreie Stadt Aachen");
    }
    #[test]
    fn native_aliases_keep_their_key_when_ascii_budget_is_zero() {
        let result = pick_alternates("Munchen,München,mu ni hei", 0, &mut HashSet::new());
        assert_eq!(result, vec!["munchen"]);
    }
    #[test]
    fn unlabeled_disagreeing_names_do_not_guess_a_city() {
        let bucket = vec![
            (1, "丁家舍".to_owned()),
            (1, "沈高".to_owned()),
            (1, "沈高镇".to_owned()),
        ];
        assert_eq!(choose_native(&bucket, "Shengao", &HashMap::new()), None);
    }
    #[test]
    fn alphabetic_checks_ignore_combining_marks_as_python_did() {
        assert!(!alpha('\u{0345}'));
        assert_eq!(native_script("上海\u{0345}"), Some(HAN));
    }

    #[test]
    fn fixture_bytes_match_the_transcoded_python_golden_files() {
        // Golden TTCITY07 files were generated by the former Python city-index compiler
        // and stay untouched as the anchor. The compiler now emits TTCITY08, so every byte of its output
        // must equal the mechanical width-only transcoding of those goldens: this ties the new writer,
        // the transcoder and the Python-era content together without a second hand-made golden file.
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/index_builder");
        let output = std::env::temp_dir().join(format!(
            "dayside-index-fixture-{}.ttcity",
            std::process::id()
        ));
        for (golden, with_alternates) in [
            ("expected.ttcity", true),
            ("expected-no-alternates.ttcity", false),
        ] {
            let alternate = root.join("alternateNamesV2.txt");
            let result = build_with_options(
                &root.join("cities.txt"),
                &root.join("admin1CodesASCII.txt"),
                &output,
                with_alternates.then_some(alternate.as_path()),
                false,
            )
            .unwrap();
            let actual = fs::read(&output).unwrap();
            let golden7 = fs::read(root.join(golden)).unwrap();
            assert_eq!(
                &golden7[..8],
                b"TTCITY07",
                "{golden} anchor must stay TTCITY07"
            );
            let (expected, report) = transcode(&golden7, &[]).unwrap();
            assert_eq!(report, PatchReport::default());
            assert_eq!(actual, expected, "{golden}");
            assert_eq!(&actual[..8], ttcity::MAGIC);
            assert!(actual.len() < golden7.len(), "{golden} must shrink");
            // 内容逐项等于黄金镜像解出来的（坐标按 f32 → 定点的路走，所以相等）。
            assert_eq!(read_image(&actual).unwrap(), read_image(&golden7).unwrap());
            // 生产补丁表点名的城市这个夹具里没有：拒绝，而不是跳过。
            assert!(transcode(&golden7, rules::SEARCH_KEY_ERRATA).is_err());
            assert_eq!(result.cities, 16);
            assert_eq!(result.keys, 63);
        }
        fs::remove_file(output).unwrap();
    }
    /// 「在现有索引上加语言」：夹具镜像上加意大利语，旧九语的名字、键、倒排逐项不变；新名字读得到、
    /// 搜得到；文种不合、等于主名、GeoNames 拿不出依据、去掉通名就是主名、带限定语的标签不收；同样的输入再跑一次逐字节相同；转储里改了名的那一条对不上，
    /// 只有它拿不到新名字（记进账），其余照加；新转储与镜像里的原记录逐条核对。
    #[test]
    fn adding_a_language_keeps_everything_else_and_is_searchable() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/index_builder");
        let base = std::env::temp_dir().join(format!("dayside-add-languages-{}.ttcity", std::process::id()));
        build_with_options(&root.join("cities.txt"), &root.join("admin1CodesASCII.txt"), &base,
                           Some(root.join("alternateNamesV2.txt").as_path()), false).unwrap();
        let image = fs::read(&base).unwrap();
        let before = read_image(&image).unwrap();
        let it = slot("it").unwrap();
        let labels = vec![
            ("3".to_owned(), it, "Minhen".to_owned(), true),            // 与别名「München」相近：有依据
            ("14".to_owned(), it, "Parigi".to_owned(), false),
            ("14".to_owned(), it, "Paris".to_owned(), true),            // 等于主名：不收
            ("4".to_owned(), it, "Ростов-на-Дону".to_owned(), true),   // 文种不合：不收
            ("3".to_owned(), slot("de").unwrap(), "München".to_owned(), true), // 别的语言：这次不加
            ("5".to_owned(), it, "Unlöschbares Datenduplikat".to_owned(), true), // GeoNames 拿不出依据：不收
            ("6".to_owned(), it, "Distretto di Mangaluru".to_owned(), true),     // 去掉通名就是主名：不收
            ("12".to_owned(), it, "San Pietroburgo (Florida)".to_owned(), true), // 带限定语：不收
        ];
        let admin_labels = vec![("1002".to_owned(), it, "Baviera".to_owned(), true)];
        let labels = Labels { cities: labels, admins: admin_labels, ..Default::default() };
        let (output, matches, reports) = add_languages(&image, &root.join("cities.txt"), &root.join("admin1CodesASCII.txt"),
                                                       &["it"], &labels, None).unwrap();
        assert_eq!((matches.matched, matches.unmatched, matches.ambiguous), (before.cities.len(), 0, 0));
        assert_eq!(matches.admins_matched, before.admins.len());
        assert_eq!(reports, vec![LanguageReport {
            language: "it".into(), cities: 2, admins: 1, new_keys: 2, new_postings: 2, unbacked: 1, generic: 1, confirmed: 0,
            renamed: 0,
        }]);
        let after = read_image(&output).unwrap();
        assert_eq!(after.languages[..before.languages.len()], before.languages[..]);
        assert_eq!(after.languages.last().map(String::as_str), Some("it"));
        assert_eq!(after.localized[..before.localized.len()], before.localized[..], "旧语言的城市名一个不动");
        assert_eq!(after.admin_localized[..before.admin_localized.len()], before.admin_localized[..]);
        assert_eq!(after.cities, before.cities);
        let munich = before.cities.iter().position(|c| c.name == "Munich").unwrap();
        let paris = before.cities.iter().position(|c| c.name == "Paris").unwrap();
        assert_eq!(after.localized.last().unwrap().get(&munich).map(String::as_str), Some("Minhen"));
        assert_eq!(after.localized.last().unwrap().get(&paris).map(String::as_str), Some("Parigi"));
        assert_eq!(after.admin_localized.last().unwrap().values().next().map(String::as_str), Some("Baviera"));
        // 旧键逐个还在、倒排不变；新键指向那座城。
        let keys: HashMap<_, _> = after.keys.iter().cloned().collect();
        for (key, values) in &before.keys {
            assert_eq!(keys.get(key), Some(values), "旧键 {:?} 变了", String::from_utf8_lossy(key));
        }
        assert_eq!(keys.get(fold("Minhen").as_bytes()), Some(&vec![munich as u32]));
        assert_eq!(keys.get(fold("Parigi").as_bytes()), Some(&vec![paris as u32]));
        // 再跑一次：逐字节相同。
        let (again, _, _) = add_languages(&image, &root.join("cities.txt"), &root.join("admin1CodesASCII.txt"),
                                          &["it"], &labels, None).unwrap();
        assert_eq!(again, output);
        // 转储里慕尼黑改了名：只有它对不上、拿不到新名字，巴黎照加。
        let wrong = std::env::temp_dir().join(format!("dayside-add-languages-{}-cities.txt", std::process::id()));
        fs::write(&wrong, fs::read_to_string(root.join("cities.txt")).unwrap().replace("\tMunich\t", "\tMonaco\t")).unwrap();
        let (drifted, matches, reports) =
            add_languages(&image, &wrong, &root.join("admin1CodesASCII.txt"), &["it"], &labels, None).unwrap();
        assert_eq!((matches.matched, matches.unmatched), (before.cities.len() - 1, 1));
        assert_eq!(reports[0].cities, 1);
        let drifted = read_image(&drifted).unwrap();
        assert_eq!(drifted.localized.last().unwrap().get(&munich), None);
        assert_eq!(drifted.localized.last().unwrap().get(&paris).map(String::as_str), Some("Parigi"));
        for file in [base, wrong] {
            fs::remove_file(file).unwrap();
        }
    }

    /// 给 Wikidata 标签撑腰的规则：描述、维护标记、单个字母、指向别的实体的都没依据；
    /// 相近的拼写、包含主名的通名写法、另起旧名与现名的区别都按文件头说的判。
    #[test]
    fn wikidata_labels_need_geonames_backing() {
        let evidence = |names: &[&str]| names.iter().map(|n| fold(n)).collect::<Vec<_>>();
        let west_java = evidence(&["West Java", "Jawa Barat", "Provincia Java de Vest", "Giava Occidentale", "Tây Java"]);
        assert!(!backed("Provincia in Indonesia", &west_java), "描述当名字");
        assert!(!backed("Tỉnh ở Indonesia", &west_java));
        assert!(backed("Giava Occidentale", &west_java));
        let town = evidence(&["Bad Überkingen", "Bad Uberkingen"]);
        assert!(!backed("Unlöschbares Datenduplikat", &town), "条目维护标记");
        assert!(!backed("V", &evidence(&["Utica"])), "单个字母");
        assert!(!backed("Guangxi", &evidence(&["Chengzhong", "Chengzhong Jiedao"])), "别的实体");
        assert!(backed("Kairo", &evidence(&["Cairo", "Al Qahirah"])), "相近的拼写");
        assert!(backed("Kota Bandung", &evidence(&["Bandung"])), "包含主名");
        assert!(backed("Distretto di Wuchang", &evidence(&["Wuchang"])));
        assert!(only_generic("Kota Bandung", &evidence(&["Bandung"])));
        assert!(only_generic("Wuchang District", &evidence(&["Wuchang"])));
        assert!(!only_generic("Thành phố Hồ Chí Minh", &evidence(&["Ho Chi Minh City"])), "剩下的不是主名：通名在区分东西");
        // 亚美尼亚的地方在土耳其语里只收现名的拼写变体。
        assert!(current_names_only("tr", "AM") && !current_names_only("tr", "GR") && !current_names_only("pl", "AM"));
        assert!(backed("Şirak", &evidence(&["Shirak"])) && !backed("Konakkıran", &evidence(&["Shirak"])));
        assert!(backed("Gümrü", &evidence(&["Gyumri"])) && !backed("Celaloğlu", &evidence(&["Stepanavan"])));
        assert!(qualified("イリオン （自治体）", "Ílion") && qualified("Kota Morehead, Carolina Utara", "Morehead City"));
        // 翻译过的名字共用一个专名词就认；指向别处的错名不认。
        assert!(translated("Paso de Arthur", &evidence(&["Arthur’s Pass"])));
        assert!(translated("Îles Wellesley", &evidence(&["Wellesley Islands"])));
        assert!(translated("Ville d'Almérie", &evidence(&["Almería"])));
        assert!(!translated("Tonghua", &evidence(&["Chaoyang"])));
        assert!(!translated("U-Bahnhof Syrez", &evidence(&["Syrets"])));
        assert!(!translated("Innere Stadt", &evidence(&["Graz"])));
        assert!(!translated("Santa Vitória", &evidence(&["Santa Cruz"])), "常见词不算");
        assert!(!qualified("Frankfurt (Oder)", "Frankfurt (Oder)"));
        assert_eq!(plain_letters(&fold("Luân Đôn")), "luan don");
        assert_eq!(plain_letters(&fold("Iğdır")), "igdir");
        assert_eq!(plain_letters(&fold("Ðà Lạt")), "da lat");
        assert_eq!(capitalized("provincia di Istanbul".to_owned()), "Provincia di Istanbul");
        assert_eq!(capitalized("'s-Hertogenbosch".to_owned()), "'s-Hertogenbosch");
    }

    /// 修旧九语的坏名：带限定语的去掉限定语（剩下就是主名则拿掉；只差变音符号的照留；汉字 / 假名那一侧文种对就留），
    /// 拉丁语种里没有 GeoNames 依据的 Wikidata 名字从别名表重选、选不到就拿掉；其余名字、别的语言、城市记录一个字节不动。
    #[test]
    fn repairing_old_names_fixes_only_the_bad_ones() {
        assert_eq!(strip_qualifier("San Antonio (Texas)"), "San Antonio");
        assert_eq!(strip_qualifier("イリオン （自治体）"), "イリオン");
        assert_eq!(strip_qualifier("克洛维斯（新墨西哥州）"), "克洛维斯");
        assert_eq!(strip_qualifier("Kota Morehead, Carolina Utara"), "Kota Morehead");
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/index_builder");
        let base = std::env::temp_dir().join(format!("dayside-repair-{}.ttcity", std::process::id()));
        build_with_options(&root.join("cities.txt"), &root.join("admin1CodesASCII.txt"), &base,
                           Some(root.join("alternateNamesV2.txt").as_path()), false).unwrap();
        let mut model = read_image(&fs::read(&base).unwrap()).unwrap();
        let city = |name: &str| model.cities.iter().position(|c| c.name == name).unwrap();
        let (munich, paris, rostov) = (city("Munich"), city("Paris"), city("Rostov-na-Donu"));
        let (de, es, ja, fr, pt) =
            (slot("de").unwrap(), slot("es").unwrap(), slot("ja").unwrap(), slot("fr").unwrap(), slot("pt-BR").unwrap());
        model.localized[de].insert(paris, "Unlöschbares Datenduplikat".to_owned());
        model.localized[es].insert(munich, "Múnich (Baviera)".to_owned());
        model.localized[ja].insert(munich, "ミュンヘン（ドイツ）".to_owned());
        model.localized[fr].insert(rostov, "Bruxelles (Rostov)".to_owned()); // 括号里才是它（法语「Bruxelles (Anderlecht)」那种）
        model.localized[pt].insert(rostov, "Rostov (Rússia)".to_owned());
        let image = write_image(&model).unwrap();
        let before = read_image(&image).unwrap();
        let alternates = std::env::temp_dir().join(format!("dayside-repair-{}.txt", std::process::id()));
        fs::write(&alternates, ["900001\t14\tde\tParis\t1\t\t\t\t\t", "900002\t4\tfr\tRostov-sur-le-Don\t1\t\t\t\t\t"].join("\n")).unwrap();
        let labels = Labels { cities: vec![("14".to_owned(), de, "Unlöschbares Datenduplikat".to_owned(), true)], ..Default::default() };
        let (output, _, reports, changes) =
            repair_old_names(&image, &root.join("cities.txt"), &root.join("admin1CodesASCII.txt"), &labels, &alternates).unwrap();
        let after = read_image(&output).unwrap();
        assert_eq!(after.localized[de].get(&paris), None, "没依据、别名表只有主名：拿掉");
        assert_eq!(after.localized[es].get(&munich).map(String::as_str), Some("Múnich"), "只差变音符号：照留");
        assert_eq!(after.localized[ja].get(&munich).map(String::as_str), Some("ミュンヘン"));
        assert_eq!(after.localized[fr].get(&rostov).map(String::as_str), Some("Rostov-sur-le-Don"), "剩下的没依据：从别名表重选");
        assert_eq!(after.localized[pt].get(&rostov).map(String::as_str), Some("Rostov"), "剩下的是它的名字：留");
        // 夹具自己就带一个：简中巴黎「巴黎（法国)」（括号半全角混用）→「巴黎」。
        let zh = slot("zh-Hans").unwrap();
        assert_eq!(after.localized[zh].get(&paris).map(String::as_str), Some("巴黎"));
        assert_eq!(changes.len(), 6, "{changes:?}");
        let total: usize = reports.iter().map(|r| r.stripped + r.replaced + r.removed).sum();
        assert_eq!(total, 6);
        // 其余名字、城市记录、别的语言不动。
        for slot in 0..before.localized.len() {
            for (index, name) in &before.localized[slot] {
                let touched = [(de, paris), (es, munich), (ja, munich), (fr, rostov), (pt, rostov), (zh, paris)].contains(&(slot, *index));
                if !touched {
                    assert_eq!(after.localized[slot].get(index), Some(name));
                }
            }
        }
        assert_eq!(after.cities, before.cities);
        for file in [base, alternates] {
            fs::remove_file(file).unwrap();
        }
    }

    /// 加语言时读 GeoNames 别名表，与全量构建同一套秩与过滤：别名的首选名（秩 1）压过 Wikidata 的 weak 标签（秩 3），
    /// 让 strong 标签（秩 0）；非首选别名（秩 2）照样能当名字；口语名、历史名、没要加的语言、文种不合、等于主名的都不收；
    /// 行政区的别名同样进桶。
    #[test]
    fn adding_a_language_reads_geonames_alternates_like_the_full_build() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/index_builder");
        let base = std::env::temp_dir().join(format!("dayside-add-alternates-{}.ttcity", std::process::id()));
        build_with_options(&root.join("cities.txt"), &root.join("admin1CodesASCII.txt"), &base,
                           Some(root.join("alternateNamesV2.txt").as_path()), false).unwrap();
        let image = fs::read(&base).unwrap();
        let before = read_image(&image).unwrap();
        let alternates = std::env::temp_dir().join(format!("dayside-add-alternates-{}.txt", std::process::id()));
        fs::write(&alternates, [
            "900001\t3\tpl\tMonachium\t1\t\t\t\t\t",          // 首选名，秩 1
            "900002\t4\tpl\tRostow nad Donem\t1\t\t\t\t\t",   // 首选名，但 Wikidata strong 在
            "900003\t14\tpl\tParyż\t\t\t\t\t\t",              // 非首选，秩 2；但 Wikidata 确认写主名
            "900004\t5\tpl\tKattakowo\t\t\t1\t\t\t",          // 口语名：不要
            "900005\t5\tpl\tStary Kattak\t\t\t\t1\t\t",       // 历史名：不要
            "900006\t6\tpl\tМангалур\t1\t\t\t\t\t",           // 文种不合：不要
            "900007\t12\tpl\tSt. Pétersburg\t1\t\t\t\t\t",    // 等于主名：不要
            "900008\t3\tit\tMonaco di Baviera\t1\t\t\t\t\t",  // 这次不加意大利语
            "900009\t1002\tpl\tBawaria\t1\t\t\t\t\t",         // 行政区
            "900010\t16\tpl\tShengao Nowe\t\t\t\t\t\t",        // 非首选，秩 2，没有确认：照用
        ].join("\n")).unwrap();
        let pl = slot("pl").unwrap();
        let labels = Labels {
            cities: vec![
                ("3".to_owned(), pl, "München".to_owned(), false),          // weak：输给首选别名
                ("4".to_owned(), pl, "Rostów nad Donem".to_owned(), true), // strong：压过首选别名
            ],
            // Wikidata 确认波兰语就写「Paris」：别名表里的「Paryż」不用（真数据里是「Kırıkkale」被写成「Kirikkale」那种）。
            city_confirmations: vec![("14".to_owned(), pl)],
            ..Default::default()
        };
        let (output, _, reports) = add_languages(&image, &root.join("cities.txt"), &root.join("admin1CodesASCII.txt"),
                                                 &["pl"], &labels, Some(alternates.as_path())).unwrap();
        assert_eq!((reports[0].cities, reports[0].admins, reports[0].confirmed), (3, 1, 1));
        let after = read_image(&output).unwrap();
        let polish = after.localized.last().unwrap();
        let city = |name: &str| before.cities.iter().position(|c| c.name == name).unwrap();
        assert_eq!(polish.get(&city("Munich")).map(String::as_str), Some("Monachium"));
        assert_eq!(polish.get(&city("Rostov-na-Donu")).map(String::as_str), Some("Rostów nad Donem"));
        assert_eq!(polish.get(&city("Shengao")).map(String::as_str), Some("Shengao Nowe"));
        for skipped in ["Paris", "Kattak", "Mangaluru", "St. Pétersburg"] {
            assert_eq!(polish.get(&city(skipped)), None, "{skipped}");
        }
        assert_eq!(after.admin_localized.last().unwrap().values().collect::<Vec<_>>(), vec!["Bawaria"]);
        assert_eq!(after.localized[..before.localized.len()], before.localized[..], "旧语言的城市名一个不动");
        for file in [base, alternates] {
            fs::remove_file(file).unwrap();
        }
    }

    /// 补充表只填 GeoNames 没给的行政区中文名：夹具里 UA.04（Dnipropetrovsk）没有 zh 名，带表构建后读得到
    /// 第聂伯罗彼得罗夫斯克州；GB.ENG 这类 GeoNames 自带中文名的不受影响；表本身每行合法、不重复。
    #[test]
    fn supplement_fills_only_missing_region_names() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/index_builder");
        let output = std::env::temp_dir().join(format!(
            "dayside-index-supplement-{}.ttcity",
            std::process::id()
        ));
        let alternate = root.join("alternateNamesV2.txt");
        let cities = primary_name_fixture(&root.join("cities.txt"), &output);
        let stats = build(
            &cities,
            &root.join("admin1CodesASCII.txt"),
            &output,
            Some(alternate.as_path()),
        )
        .unwrap();
        let without = build_with_options(
            &root.join("cities.txt"),
            &root.join("admin1CodesASCII.txt"),
            &output.with_extension("plain.ttcity"),
            Some(alternate.as_path()),
            false,
        )
        .unwrap();
        assert!(stats.admin_localized > without.admin_localized, "supplement adds region names");
        // 走生产的 C ABI 读回（库不导出读取器）：city.open → city.record → city.names(kind=region)。
        let call = |request: serde_json::Value| -> serde_json::Value {
            let bytes = serde_json::to_vec(&request).unwrap();
            let buffer = unsafe { dayside_core::mt_core_call(bytes.as_ptr(), bytes.len()) };
            let response: serde_json::Value =
                serde_json::from_slice(unsafe { std::slice::from_raw_parts(buffer.data, buffer.len) }).unwrap();
            unsafe { dayside_core::mt_core_free(buffer) };
            assert!(response.get("error").is_none(), "{response}");
            response["value"].clone()
        };
        let opened = call(serde_json::json!({"operation": "city.open", "payload": {"path": output.to_str().unwrap()}}));
        let handle = opened["handle"].as_u64().unwrap();
        let mut seen_ua = false;
        for i in 0..stats.cities {
            let record = call(serde_json::json!({"operation": "city.record", "payload": {"handle": handle, "index": i}}));
            if record["countryCode"] == "UA" && record["region"] == "Dnipropetrovsk" {
                let names = call(serde_json::json!({"operation": "city.names", "payload": {"handle": handle, "index": record["adminIndex"], "kind": "region"}}));
                assert_eq!(names["zh-Hans"], "第聂伯罗彼得罗夫斯克州", "{names}");
                seen_ua = true;
            }
        }
        assert!(seen_ua, "fixture has a UA.04 city");
        call(serde_json::json!({"operation": "city.close", "payload": {"handle": handle}}));
        let mut codes = std::collections::HashSet::new();
        for (code, hans, hant) in rules::admin1_supplement() {
            assert!(codes.insert(code), "duplicate supplement row {code}");
            assert!(code.contains('.'), "{code}");
            for value in [hans, hant].into_iter().filter(|v| !v.is_empty()) {
                assert!(value.chars().any(|c| ('\u{4e00}'..='\u{9fff}').contains(&c)), "{code}: {value} is not Chinese");
                assert!(value.chars().count() <= 24, "{code}: {value} too long");
            }
        }
        assert!(codes.len() > 1500, "{}", codes.len());
        fs::remove_file(&output).unwrap();
        fs::remove_file(output.with_extension("plain.ttcity")).unwrap();
    }
    /// 排查用：`MEANTIME_BYTE=<偏移> cargo test --all-targets fixture_byte_probe -- --ignored --nocapture` 报某个字节落在哪一段。
    #[test]
    #[ignore]
    fn fixture_byte_probe() {
        let Ok(byte) = std::env::var("MEANTIME_BYTE").map(|v| v.parse::<usize>().unwrap()) else { return };
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/index_builder");
        let golden7 = fs::read(root.join("expected.ttcity")).unwrap();
        let (image, _) = transcode(&golden7, &[]).unwrap();
        let le32 = |at: usize| u32::from_le_bytes(image[at..at + 4].try_into().unwrap()) as usize;
        let counts: Vec<usize> = (0..6).map(|i| le32(12 + i * 4)).collect();
        let mut offsets: Vec<usize> = (0..20).map(|i| le32(36 + i * 4)).collect();
        offsets.push(image.len());
        println!("counts {counts:?}");
        for i in 0..20 {
            if offsets[i] <= byte && byte < offsets[i + 1] {
                println!("byte {byte} in section {i} at +{} (section {}..{}, len {})", byte - offsets[i], offsets[i], offsets[i + 1], offsets[i + 1] - offsets[i]);
            }
        }
        let n = counts[0];
        println!("record columns {:?}", ttcity::record_columns(n));
        let mut tampered = image.clone();
        tampered[byte] ^= 1;
        println!("original byte {:#04x}, transcode(tampered) == image: {}", image[byte], transcode(&tampered, &[]).map(|(b, _)| b == image).unwrap_or(false));
    }

    #[test]
    fn transcoding_rejects_foreign_images_and_every_stray_byte_matters() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/index_builder");
        let golden7 = fs::read(root.join("expected.ttcity")).unwrap();
        assert!(transcode(&[], &[]).is_err());
        let (v10, _) = transcode(&golden7, &[]).unwrap();
        assert_eq!(
            transcode(&v10, &[]).unwrap().0,
            v10,
            "a TTCITY10 image must round-trip byte for byte"
        );
        let mut wrong_version = golden7.clone();
        wrong_version[8] = 6;
        assert!(transcode(&wrong_version, &[]).is_err());
        // Nothing after the header may be silently dropped: flipping any byte must either be
        // rejected or change the output. The only exception is the three zero pad bytes of each
        // 12-byte localized entry, which TTCITY08 deliberately does not carry.
        let le32 = |at: usize| u32::from_le_bytes(golden7[at..at + 4].try_into().unwrap()) as usize;
        let languages = le32(28);
        let mut dead_padding = std::collections::HashSet::new();
        for (ranges, entries) in [(11, 12), (17, 18)] {
            let (ranges_at, entries_at) = (le32(36 + ranges * 4), le32(36 + entries * 4));
            let count = (0..languages)
                .map(|slot| le32(ranges_at + slot * 8) + le32(ranges_at + slot * 8 + 4))
                .max()
                .unwrap_or(0);
            for entry in 0..count {
                dead_padding.extend((9..12).map(|pad| entries_at + entry * 12 + pad));
            }
        }
        // 坐标从 f32 转成定点（2.5e-5°）时最低一个尾数字节的一位翻转（≤ 7.6e-6°）落在同一个格子里，
        // 这两个字节不算「被忽略」；高位字节的翻转仍必须改变输出。
        let cities = le32(12);
        let city_blob_at = le32(36);
        for i in 0..cities {
            dead_padding.insert(city_blob_at + i * 20 + 10);
            dead_padding.insert(city_blob_at + i * 20 + 14);
        }
        assert!(!dead_padding.is_empty());
        let mut influential = 0;
        for at in 128..golden7.len() {
            if dead_padding.contains(&at) {
                continue;
            }
            let mut tampered = golden7.clone();
            tampered[at] ^= 0x01;
            match transcode(&tampered, &[]) {
                Err(_) => {}
                Ok((bytes, _)) => {
                    assert!(bytes != v10, "byte {at} of the TTCITY07 image was ignored")
                }
            }
            influential += 1;
        }
        assert!(
            influential > 3000,
            "fixture sweep covered {influential} bytes"
        );
        // Transcoding is a pure function of its input; the original bytes are untouched.
        assert_eq!(transcode(&golden7, &[]).unwrap().0, v10);
        // TTCITY10 读取端没有任何死字节：头部之后每个字节要么被拒绝、要么进到输出
        // （键块的表号字节与头字节、符号表、倒排、填充字节都算）。唯一的例外是指进去重文本池的偏移：
        // 偏移翻一位可能恰好指到内容相同的字节（夹具里记录 3 的单字节名字就撞上了），那不是被忽略，
        // 而是同一内容的另一种写法；这类翻转要求解出来的内容与原镜像逐项相等。
        // TTCITY12 里指进文本池的偏移只剩本地化流里的转义引用（长度字节 0 之后的 u24）：这里独立走一遍流找出它们。
        let v10_le32 = |at: usize| u32::from_le_bytes(v10[at..at + 4].try_into().unwrap()) as usize;
        let mut pool_offsets = std::collections::HashSet::new();
        let mut escapes = 0;
        for (ranges, entries) in [(11, 12), (17, 18)] {
            let (ranges_at, entries_at) = (v10_le32(36 + ranges * 4), v10_le32(36 + entries * 4));
            for slot in 0..v10_le32(28) {
                let at = ranges_at + slot * ttcity::LOCALIZED_RANGE;
                let (start, len, count) = (v10_le32(at), v10_le32(at + 4), v10_le32(at + 12));
                let stream = &v10[entries_at + start..entries_at + start + len];
                let mut pos = 0;
                for _ in 0..count {
                    ttcity::read_varint(stream, &mut pos).unwrap();
                    let length = stream[pos];
                    pos += 1;
                    if length == 0 {
                        pool_offsets.extend((0..3).map(|b| entries_at + start + pos + b));
                        escapes += 1;
                        pos += 4;
                    }
                    pos += 1;
                }
                assert_eq!(pos, len);
            }
        }
        // 夹具 16 城没有重复的本地化串（转义在下一条测试里单独练）。
        let _ = escapes;
        let original = read_image(&v10).unwrap();
        for at in 128..v10.len() {
            let mut tampered = v10.clone();
            tampered[at] ^= 0x01;
            match transcode(&tampered, &[]) {
                Err(_) => {}
                Ok((bytes, _)) if bytes == v10 => {
                    assert!(pool_offsets.contains(&at), "byte {at} of the TTCITY10 image was ignored");
                    assert_eq!(read_image(&tampered).unwrap(), original, "byte {at}");
                }
                Ok(_) => {}
            }
        }
    }

    /// TTCITY12 的转义引用（同一字符串第二次出现只存偏移）：夹具里没有重复串，这里给几座城市塞同一个俄文名与
    /// 等于别城主名的日文名，写出来的流里必须有转义、解回来逐项相等、每个字节仍算数（只有转义的三个偏移字节
    /// 翻一位可能指到内容相同的地方）。
    #[test]
    fn localized_escapes_round_trip_and_every_byte_matters() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/index_builder");
        let golden7 = fs::read(root.join("expected.ttcity")).unwrap();
        let mut model = read_image(&golden7).unwrap();
        let ru = model.languages.iter().position(|l| l == "ru").unwrap();
        let ja = model.languages.iter().position(|l| l == "ja").unwrap();
        for city in [0usize, 1, 2, 5] {
            model.localized[ru].insert(city, "Дубль".to_owned());
        }
        let other = model.cities[3].name.clone();
        model.localized[ja].insert(4, other);
        model.localized[ja].insert(6, "Дубль".to_owned());
        let image = write_image(&model).unwrap();
        assert_eq!(read_image(&image).unwrap(), model);
        assert_eq!(transcode(&image, &[]).unwrap().0, image, "round trip");
        let le32 = |at: usize| u32::from_le_bytes(image[at..at + 4].try_into().unwrap()) as usize;
        let mut pool_offsets = std::collections::HashSet::new();
        let mut escapes = 0;
        for (ranges, entries) in [(11, 12), (17, 18)] {
            let (ranges_at, entries_at) = (le32(36 + ranges * 4), le32(36 + entries * 4));
            for slot in 0..le32(28) {
                let at = ranges_at + slot * ttcity::LOCALIZED_RANGE;
                let (start, len, count) = (le32(at), le32(at + 4), le32(at + 12));
                let stream = &image[entries_at + start..entries_at + start + len];
                let mut pos = 0;
                for _ in 0..count {
                    ttcity::read_varint(stream, &mut pos).unwrap();
                    let length = stream[pos];
                    pos += 1;
                    if length == 0 {
                        pool_offsets.extend((0..3).map(|b| entries_at + start + pos + b));
                        escapes += 1;
                        pos += 4;
                    }
                    pos += 1;
                }
                assert_eq!(pos, len);
            }
        }
        assert!(escapes >= 4, "expected escapes, got {escapes}");
        for at in 128..image.len() {
            let mut tampered = image.clone();
            tampered[at] ^= 0x01;
            match transcode(&tampered, &[]) {
                Err(_) => {}
                Ok((bytes, _)) if bytes == image => {
                    assert!(pool_offsets.contains(&at), "byte {at} of the image was ignored");
                    assert_eq!(read_image(&tampered).unwrap(), model, "byte {at}");
                }
                Ok(_) => {}
            }
        }
    }

    /// 搜索键补丁只加倒排、不动别的：新名字成新键，别的城市已占的名字按人口序并入那个键，
    /// 城市本来就有的名字是空操作，同一补丁套两次字节相同。
    #[test]
    fn search_key_patch_adds_postings_and_is_idempotent() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/index_builder");
        let golden7 = fs::read(root.join("expected.ttcity")).unwrap();
        let (v9, _) = transcode(&golden7, &[]).unwrap();
        let before = read_image(&v9).unwrap();
        let city = |name: &str| before.cities.iter().position(|c| c.name == name).unwrap();
        let (munich, paris) = (city("Munich"), city("Paris"));
        assert!(
            paris < munich,
            "the fixture sorts Paris (100k) before Munich (10k)"
        );
        let patch: &[SearchKeyErratum] = &[
            ("Munich", "DE", &["Minga", "Munich"]),
            ("Paris", "FR", &["Munich"]),
        ];
        let (patched, report) = transcode(&v9, patch).unwrap();
        assert_eq!(
            report,
            PatchReport {
                keys_added: 1,
                postings_added: 2,
                already_present: 1
            }
        );
        let after = read_image(&patched).unwrap();
        assert_eq!(after.keys.len(), before.keys.len() + 1);
        let key = |image: &Model, key: &str| {
            image
                .keys
                .iter()
                .find(|(k, _)| k == key.as_bytes())
                .map(|(_, postings)| postings.clone())
        };
        assert_eq!(key(&before, "minga"), None);
        assert_eq!(key(&after, "minga"), Some(vec![munich as u32]));
        assert_eq!(
            key(&before, "munich"),
            Some(vec![munich as u32 | PRIMARY_BIT])
        );
        assert_eq!(
            key(&after, "munich"),
            Some(vec![paris as u32, munich as u32 | PRIMARY_BIT]),
            "Paris joins as a secondary posting ahead of the less populous Munich"
        );
        // 其余每张表都没动。
        for (a, b) in before
            .keys
            .iter()
            .zip(after.keys.iter().filter(|(k, _)| k != b"minga"))
        {
            assert_eq!(a.0, b.0);
            if a.0 != b"munich" {
                assert_eq!(a.1, b.1);
            }
        }
        assert_eq!(before.cities, after.cities);
        assert_eq!(before.localized, after.localized);
        assert_eq!(before.admin_localized, after.admin_localized);
        assert_eq!(before.country_tops, after.country_tops);
        assert_eq!(before.representatives, after.representatives);
        // 幂等：对补过的镜像再套同一补丁什么都不改。
        let (again, report) = transcode(&patched, patch).unwrap();
        assert_eq!(again, patched);
        assert_eq!(
            report,
            PatchReport {
                keys_added: 0,
                postings_added: 0,
                already_present: 3
            }
        );
        // 找不到的城市与折叠后为空的名字都是错误，绝不静默跳过。
        assert!(transcode(&v9, &[("Atlantis", "XX", &["Lost"])]).is_err());
        assert!(transcode(&v9, &[("Munich", "FR", &["Minga"])]).is_err());
        assert!(transcode(&v9, &[("Munich", "DE", &["..."])]).is_err());
    }

    /// 随包索引必须已经带着 `SEARCH_KEY_ERRATA`：再套一遍表是逐字节的空操作。从 GeoNames 重建
    /// 却跳过 `--transcode` 的索引在这里失败。`MEANTIME_TEST_INDEX=<路径>` 可先核候选镜像再安装。
    #[test]
    fn bundled_index_already_carries_the_search_key_patch() {
        let path = std::env::var("MEANTIME_TEST_INDEX").unwrap_or_else(|_| {
            concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/../Dayside/Resources/cities.ttcity"
            )
            .to_owned()
        });
        let bundled = fs::read(&path).unwrap();
        let (again, report) = transcode(&bundled, rules::SEARCH_KEY_ERRATA).unwrap();
        assert_eq!(
            report,
            PatchReport {
                keys_added: 0,
                postings_added: 0,
                already_present: rules::SEARCH_KEY_ERRATA
                    .iter()
                    .map(|(_, _, names)| names.len())
                    .sum()
            },
            "{path} lacks part of SEARCH_KEY_ERRATA; run build_city_index --transcode on it"
        );
        assert_eq!(again, bundled, "{path} is not a fixed point of transcoding");
    }
}
