// SPDX-License-Identifier: GPL-3.0-only
//! Spotlight 索引计划。输入是 Swift 收来的事实——tzdata 发行号、界面 locale、系统时区目录里每个标识符
//! 的 ICU 名字、用户已保存地点的名字（只有地点，人物永远不进来）——输出每条实体的显示名、说明、关键词,
//! 以及一个「索引版本」串:它没变就不重建。CoreSpotlight 的读写留在 Swift。
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::BTreeMap;

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct Input {
    tzdata: String,
    locale: String,
    catalog: Vec<Row>,
    places: Vec<Place>,
}

/// 一个系统时区标识符与它在各语言下的城市名(第一个是界面语言,之后是系统语言、英文……)。
#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct Row {
    id: String,
    names: Vec<String>,
    zone: String,
}

/// 用户已保存的地点:只带时区标识符与显示名。
#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct Place {
    #[serde(rename = "timeZoneID")]
    time_zone_id: String,
    name: String,
}

const MAX_KEYWORDS: usize = 32;
const MAX_TEXT: usize = 160;

fn clean(text: &str) -> Option<String> {
    let trimmed = text.trim();
    if trimmed.is_empty() || trimmed.chars().any(char::is_control) {
        return None;
    }
    Some(trimmed.chars().take(MAX_TEXT).collect())
}

/// `America/Argentina/Buenos_Aires` → `Buenos Aires`。
fn raw_city(id: &str) -> String {
    id.rsplit('/').next().unwrap_or(id).replace('_', " ")
}

/// 标识符自己的每一段都能搜:`Asia`、`Tokyo`、`Buenos Aires`。
fn path_words(id: &str) -> Vec<String> {
    id.split('/').map(|part| part.replace('_', " ")).filter(|part| !part.is_empty()).collect()
}

fn push_unique(keywords: &mut Vec<String>, candidate: Option<String>) {
    if let Some(value) = candidate {
        if keywords.len() < MAX_KEYWORDS && !keywords.contains(&value) {
            keywords.push(value);
        }
    }
}

/// FNV-1a 64 位:跨启动稳定,索引版本只需要「变了就不同」。
fn fnv1a(text: &str) -> u64 {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in text.bytes() {
        hash ^= u64::from(byte);
        hash = hash.wrapping_mul(0x0100_0000_01b3);
    }
    hash
}

/// 已保存地点按时区归组（组内按字节序，用户把地点拖成什么顺序都不该改变版本串）。
fn saved_names(places: &[Place]) -> BTreeMap<String, Vec<String>> {
    let mut saved: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for place in places {
        let (Some(zone), Some(name)) = (clean(&place.time_zone_id), clean(&place.name)) else { continue };
        let names = saved.entry(zone).or_default();
        if !names.contains(&name) {
            names.push(name);
        }
    }
    for names in saved.values_mut() {
        names.sort_unstable();
    }
    saved
}

/// 版本 = 发行号 | 实体条数 | 地点数 | 摘要(界面语言 + 每个地点的时区与名字)。任何一项变了才重建。
/// 不依赖 ICU 名字：每次启动只算这一串，名字要到真要重建时才去取。
fn version(input: &Input, saved: &BTreeMap<String, Vec<String>>) -> String {
    let mut ids: std::collections::BTreeSet<String> = input.catalog.iter().filter_map(|row| clean(&row.id)).collect();
    ids.extend(saved.keys().cloned());
    let mut digest_input = input.locale.trim().to_owned();
    for (zone, names) in saved {
        for name in names {
            digest_input.push('\n');
            digest_input.push_str(zone);
            digest_input.push('\t');
            digest_input.push_str(name);
        }
    }
    let tzdata = clean(&input.tzdata).unwrap_or_else(|| "unknown".to_owned());
    let place_count = input.places.iter().filter(|place| clean(&place.time_zone_id).is_some()).count();
    format!("{tzdata}|{}|{place_count}|{:016x}", ids.len(), fnv1a(&digest_input))
}

fn plan(payload: Value, with_entities: bool) -> Result<Value, String> {
    let input: Input = serde_json::from_value(payload).map_err(|e| e.to_string())?;
    let saved = saved_names(&input.places);
    let version = version(&input, &saved);
    if !with_entities {
        return Ok(json!({"version": version}));
    }
    // 同一时区的几个地点(慕尼黑与柏林都是 Europe/Berlin)名字都成为该实体的关键词。
    let mut entities: BTreeMap<String, Value> = BTreeMap::new();
    for row in &input.catalog {
        let Some(id) = clean(&row.id) else { continue };
        if entities.contains_key(&id) {
            continue;
        }
        let names: Vec<String> = row.names.iter().filter_map(|name| clean(name)).collect();
        let display_name = names.first().cloned().unwrap_or_else(|| raw_city(&id));
        let mut keywords = Vec::new();
        push_unique(&mut keywords, Some(id.clone()));
        for word in path_words(&id) {
            push_unique(&mut keywords, Some(word));
        }
        for name in &names {
            push_unique(&mut keywords, Some(name.clone()));
        }
        for name in saved.get(&id).into_iter().flatten() {
            push_unique(&mut keywords, Some(name.clone()));
        }
        entities.insert(id.clone(), json!({
            "id": id,
            "displayName": display_name,
            "description": clean(&row.zone).unwrap_or_default(),
            "keywords": keywords,
        }));
    }
    // 时区不在目录里的已保存地点(极少:目录换代后消失的标识符)仍要能搜到,用地点自己的名字建一条。
    for (zone, names) in &saved {
        if entities.contains_key(zone) {
            continue;
        }
        let mut keywords = Vec::new();
        push_unique(&mut keywords, Some(zone.clone()));
        for word in path_words(zone) {
            push_unique(&mut keywords, Some(word));
        }
        for name in names {
            push_unique(&mut keywords, Some(name.clone()));
        }
        entities.insert(zone.clone(), json!({
            "id": zone,
            "displayName": names[0],
            "description": "",
            "keywords": keywords,
        }));
    }
    Ok(json!({
        "version": version,
        "entities": entities.into_values().collect::<Vec<_>>(),
    }))
}

pub fn dispatch(operation: &str, payload: Value) -> Result<Value, String> {
    match operation {
        "spotlight.version" => plan(payload, false),
        "spotlight.plan" => plan(payload, true),
        _ => Err(format!("Unknown spotlight operation: {operation}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(payload: Value) -> Value {
        dispatch("spotlight.plan", payload).unwrap()
    }

    fn sample() -> Value {
        json!({
            "tzdata": "2026c",
            "locale": "zh-Hans",
            "catalog": [
                {"id": "Asia/Tokyo", "names": ["东京", "Tokyo", "Tokyo"], "zone": "日本标准时间"},
                {"id": "Europe/Berlin", "names": ["柏林", "Berlin"], "zone": "中欧时间"},
                {"id": "America/Argentina/Buenos_Aires", "names": ["布宜诺斯艾利斯", "Buenos Aires"], "zone": "阿根廷时间"},
                {"id": "UTC", "names": ["UTC"], "zone": ""}
            ],
            "places": [
                {"timeZoneID": "Europe/Berlin", "name": "慕尼黑"},
                {"timeZoneID": "Europe/Berlin", "name": "Berlin"},
                {"timeZoneID": "Asia/Kolkata", "name": "班加罗尔"}
            ]
        })
    }

    fn entity<'a>(plan: &'a Value, id: &str) -> &'a Value {
        plan["entities"].as_array().unwrap().iter().find(|e| e["id"] == id).unwrap()
    }

    #[test]
    fn keywords_carry_the_identifier_its_words_every_name_and_saved_place_names() {
        let plan = run(sample());
        let berlin = entity(&plan, "Europe/Berlin");
        assert_eq!(berlin["displayName"], "柏林");
        assert_eq!(berlin["description"], "中欧时间");
        assert_eq!(berlin["keywords"], json!(["Europe/Berlin", "Europe", "Berlin", "柏林", "慕尼黑"]), "the saved \"Berlin\" is already a keyword");
        let tokyo = entity(&plan, "Asia/Tokyo");
        assert_eq!(tokyo["keywords"], json!(["Asia/Tokyo", "Asia", "Tokyo", "东京"]), "duplicates collapse");
        let ba = entity(&plan, "America/Argentina/Buenos_Aires");
        assert!(ba["keywords"].as_array().unwrap().contains(&json!("Buenos Aires")), "underscores become spaces");
        assert_eq!(entity(&plan, "UTC")["description"], "");
    }

    #[test]
    fn a_saved_place_outside_the_catalog_still_gets_an_entity_named_after_it() {
        let plan = run(sample());
        let kolkata = entity(&plan, "Asia/Kolkata");
        assert_eq!(kolkata["displayName"], "班加罗尔");
        assert_eq!(kolkata["keywords"], json!(["Asia/Kolkata", "Asia", "Kolkata", "班加罗尔"]));
        assert_eq!(plan["entities"].as_array().unwrap().len(), 5);
        let ids: Vec<&str> = plan["entities"].as_array().unwrap().iter().map(|e| e["id"].as_str().unwrap()).collect();
        let mut sorted = ids.clone();
        sorted.sort_unstable();
        assert_eq!(ids, sorted, "deterministic order");
    }

    #[test]
    fn the_version_changes_only_with_tzdata_catalog_size_locale_or_saved_places() {
        let base = run(sample())["version"].as_str().unwrap().to_owned();
        assert!(base.starts_with("2026c|5|3|"), "{base}");
        assert_eq!(run(sample())["version"], base, "stable across runs");
        let mut same_names_reordered = sample();
        same_names_reordered["places"].as_array_mut().unwrap().swap(0, 1);
        assert_eq!(run(same_names_reordered)["version"], base, "order of saved places is irrelevant");
        let mut newer = sample();
        newer["tzdata"] = json!("2026d");
        assert_ne!(run(newer)["version"], base);
        let mut other_locale = sample();
        other_locale["locale"] = json!("en");
        assert_ne!(run(other_locale)["version"], base);
        let mut renamed = sample();
        renamed["places"][0]["name"] = json!("总部");
        assert_ne!(run(renamed)["version"], base);
        let mut fewer = sample();
        fewer["places"].as_array_mut().unwrap().pop();
        assert_ne!(run(fewer)["version"], base);
        let mut bigger_catalog = sample();
        bigger_catalog["catalog"].as_array_mut().unwrap().push(json!({"id": "Asia/Seoul", "names": ["首尔"], "zone": ""}));
        assert_ne!(run(bigger_catalog)["version"], base);
        assert!(base.len() < 200, "must fit CoreSpotlight's client state");
        // 只算版本的便宜路径与完整计划给同一串，且不看 ICU 名字。
        let mut nameless = sample();
        for row in nameless["catalog"].as_array_mut().unwrap() {
            row["names"] = json!([]);
            row["zone"] = json!("");
        }
        let cheap = dispatch("spotlight.version", nameless).unwrap();
        assert_eq!(cheap["version"], base);
        assert!(cheap.get("entities").is_none());
    }

    #[test]
    fn hostile_rows_are_dropped_and_nothing_panics() {
        let plan = run(json!({
            "tzdata": "",
            "catalog": [
                {"id": "  ", "names": ["x"]},
                {"id": "Asia/Tokyo"},
                {"id": "Asia/Tokyo", "names": ["dup"]},
                {"id": "a\u{0}b", "names": ["ctl"]}
            ],
            "places": [
                {"timeZoneID": "Asia/Tokyo", "name": "\t\n"},
                {"timeZoneID": "", "name": "nowhere"},
                {"timeZoneID": "Asia/Tokyo", "name": "x".repeat(500)}
            ]
        }));
        let entities = plan["entities"].as_array().unwrap();
        assert_eq!(entities.len(), 1);
        assert_eq!(entities[0]["displayName"], "Tokyo", "no names → raw city from the identifier");
        let keywords = entities[0]["keywords"].as_array().unwrap();
        assert_eq!(keywords.len(), 4);
        assert_eq!(keywords[3].as_str().unwrap().chars().count(), MAX_TEXT);
        assert!(plan["version"].as_str().unwrap().starts_with("unknown|1|2|"));
        assert!(dispatch("spotlight.plan", json!([1, 2])).is_err());
        assert!(dispatch("spotlight.nope", json!({})).is_err());
    }
}
