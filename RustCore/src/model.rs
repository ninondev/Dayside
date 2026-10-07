// SPDX-License-Identifier: GPL-3.0-only
use serde_json::{json, Value};

/// 地点 emoji：一个可见符号（最多 8 个标量值，容得下国旗、肤色与 ZWJ 序列），不含空白与控制符；别的一律当没有。
pub fn emoji(value: &Value) -> Value {
    match value.as_str().map(str::trim) {
        Some(text) if !text.is_empty() && text.chars().count() <= 8 && !text.chars().any(|c| c.is_whitespace() || c.is_control() || c.is_ascii_alphanumeric()) => json!(text),
        _ => Value::Null,
    }
}

/// 语义色的封闭名单（系统色，面板行画一个小圆点；名字进无障碍标签）。
pub const COLORS: [&str; 7] = ["red", "orange", "yellow", "green", "blue", "purple", "gray"];

pub fn color(value: &Value) -> Value {
    match value.as_str() {
        Some(name) if COLORS.contains(&name) => json!(name),
        _ => Value::Null,
    }
}
use unicode_normalization::UnicodeNormalization;

fn whitespace(c: char) -> bool {
    matches!(
        c,
        '\t' | ' ' | '\u{a0}' | '\u{1680}' | '\u{2000}'
            ..='\u{200b}' | '\u{202f}' | '\u{205f}' | '\u{3000}'
    )
}
fn city_language(input: &Value) -> &str {
    match input["city"].as_str().unwrap_or("followInterface") {
        "system" => "system",
        "none" | "followInterface" => input["interface"].as_str().unwrap_or("system"),
        language => language,
    }
}
fn same_text(left: &Value, right: &Value) -> bool {
    match (left.as_str(), right.as_str()) {
        // Swift String equality includes canonical Unicode equivalence.
        (Some(left), Some(right)) => left.nfc().eq(right.nfc()),
        _ => false,
    }
}
pub fn dispatch(operation: &str, input: Value) -> Result<Value, String> {
    Ok(match operation {
        "model.edit" => {
            let mut zones = input["zones"].as_array().ok_or("Missing zones")?.clone();
            let original = zones.clone();
            let action = &input["action"];
            let kind = action["kind"].as_str().unwrap_or("");
            let id = action["id"].as_str();
            let index = zones
                .iter()
                .position(|v| v["id"].as_str() == id && id.is_some());
            let mut persist = true;
            match kind {
                "add" => zones.push(action["entry"].clone()),
                // 撤销删除：把条目放回原来的位置；同一个 id 已在列表里就不动（连按两次撤销）。
                "insert" => {
                    let entry = action["entry"].clone();
                    let exists = entry["id"]
                        .as_str()
                        .is_some_and(|new| zones.iter().any(|v| v["id"].as_str() == Some(new)));
                    if exists {
                        persist = false;
                    } else {
                        let at = action["index"].as_u64().unwrap_or(u64::MAX) as usize;
                        zones.insert(at.min(zones.len()), entry);
                    }
                }
                "remove" => zones.retain(|v| v["id"].as_str() != id),
                "removeOffsets" => {
                    let offsets = action["offsets"].as_array().ok_or("Missing offsets")?;
                    zones = zones
                        .into_iter()
                        .enumerate()
                        .filter_map(|(i, v)| {
                            if offsets.iter().any(|o| o.as_u64() == Some(i as u64)) {
                                None
                            } else {
                                Some(v)
                            }
                        })
                        .collect();
                }
                "move" => {
                    let offsets = action["offsets"].as_array().ok_or("Missing offsets")?;
                    let destination = action["destination"].as_u64().unwrap_or(0) as usize;
                    let selected = |i: usize| offsets.iter().any(|o| o.as_u64() == Some(i as u64));
                    let moved: Vec<_> = zones
                        .iter()
                        .enumerate()
                        .filter(|(i, _)| selected(*i))
                        .map(|(_, v)| v.clone())
                        .collect();
                    let before = (0..destination.min(zones.len()))
                        .filter(|i| selected(*i))
                        .count();
                    zones = zones
                        .into_iter()
                        .enumerate()
                        .filter_map(|(i, v)| if selected(i) { None } else { Some(v) })
                        .collect();
                    let insertion = destination.saturating_sub(before).min(zones.len());
                    zones.splice(insertion..insertion, moved);
                }
                // 地点的 emoji 与语义色点：两项一起设，null 即清掉；坏值当没有。
                "decorate" => {
                    if let Some(i) = index {
                        let emoji = emoji(&action["emoji"]);
                        let color = color(&action["color"]);
                        persist = zones[i]["emoji"] != emoji || zones[i]["color"] != color;
                        zones[i]["emoji"] = emoji;
                        zones[i]["color"] = color;
                    } else {
                        persist = false;
                    }
                }
                // 「能打给的时段」按上班还是醒着算：坏值当上班；存档里只有醒着才留键（store::entry）。
                "callBasis" => {
                    if let Some(i) = index {
                        let basis = |v: &Value| if v.as_str() == Some("awake") { "awake" } else { "work" };
                        let value = basis(&action["callBasis"]);
                        persist = basis(&zones[i]["callBasis"]) != value;
                        zones[i]["callBasis"] = json!(value);
                    } else {
                        persist = false;
                    }
                }
                "rename" => {
                    if let Some(i) = index {
                        let name = action["name"]
                            .as_str()
                            .unwrap_or("")
                            .trim_matches(whitespace);
                        zones[i]["customName"] = if name.is_empty() {
                            Value::Null
                        } else {
                            json!(name)
                        };
                    } else {
                        persist = false;
                    }
                }
                "availability" => {
                    if let Some(i) = index {
                        let value = if action["availability"]
                            == crate::settings::availability(&Value::Null)
                        {
                            Value::Null
                        } else {
                            action["availability"].clone()
                        };
                        persist = zones[i]["availability"] != value;
                        zones[i]["availability"] = value;
                    } else {
                        persist = false;
                    }
                }
                "refreshNames" => {
                    if let Some(updates) = action["updates"].as_object() {
                        for zone in &mut zones {
                            if let Some(names) = zone["id"].as_str().and_then(|id| updates.get(id))
                            {
                                if names.as_object().is_some_and(|m| !m.is_empty()) {
                                    zone["localizedNames"] = names.clone();
                                }
                            }
                        }
                    }
                    persist = zones != original;
                }
                _ => return Err(format!("Unknown zone edit: {kind}")),
            }
            let reset = zones.is_empty() && ["remove", "removeOffsets"].contains(&kind);
            json!({"zones":zones,"persist":persist,"resetScrub":reset})
        }
        "model.participation" => {
            let id = &input["id"];
            let mut ids = input["excluded"]
                .as_array()
                .ok_or("Missing exclusions")?
                .clone();
            if input["participates"].as_bool().unwrap_or(true) {
                ids.retain(|v| v != id);
            } else if !ids.contains(id) {
                ids.push(id.clone());
            }
            json!(ids)
        }
        "model.scrub" => {
            let mut anchor = input["anchor"].as_f64().unwrap_or(0.0);
            let mut offset = input["offset"].as_f64().unwrap_or(0.0);
            match input["kind"].as_str().unwrap_or("") {
                "reset" => {
                    anchor = 0.0;
                    offset = 0.0;
                }
                "jump" => {
                    anchor = input["target"].as_f64().ok_or("Missing target")?
                        - input["now"].as_f64().ok_or("Missing now")?
                        - offset
                }
                "flush" => (),
                _ => return Err("Invalid scrub action".into()),
            }
            json!({"anchor":anchor,"offset":offset,"display":anchor+offset})
        }
        "model.clock" => json!(if input["empty"].as_bool().unwrap_or(true)
            || !input["visible"].as_bool().unwrap_or(false)
        {
            "stop"
        } else if !input["running"].as_bool().unwrap_or(false) {
            "start"
        } else {
            "none"
        }),
        "model.name_source" => {
            let disabled = input["cityLanguage"].as_str() == Some("none");
            json!(if disabled {
                if input["hide"].as_bool().unwrap_or(false) {
                    "hidden"
                } else {
                    "raw"
                }
            } else if input["exemplar"].as_bool().unwrap_or(false) {
                "system"
            } else {
                "stored"
            })
        }
        "model.city_locale" => json!(city_language(&input)),
        "model.city_search_locale" => {
            if input["city"].as_str() == Some("none") {
                Value::Null
            } else {
                json!(city_language(&input))
            }
        }
        "model.stored_name" => json!(input["candidate"]
            .as_str()
            .or(input["raw"].as_str())
            .unwrap_or("")),
        "model.refresh_name_requests" => {
            let zones = input.as_array().ok_or("Missing zones")?;
            json!(zones.iter().filter(|zone|zone["usesExemplarName"].as_bool()==Some(false))
                .map(|zone|json!({"id":zone["id"],"cityName":zone["cityName"],"timezoneID":zone["timezoneID"]})).collect::<Vec<_>>())
        }
        "model.refresh_name_matches" => {
            let lookups = input.as_array().ok_or("Missing name lookups")?;
            let mut matches = Vec::new();
            for lookup in lookups {
                let request = &lookup["request"];
                let candidates = lookup["candidates"]
                    .as_array()
                    .ok_or("Missing name candidates")?;
                if let Some(candidate) = candidates.iter().find(|candidate| {
                    same_text(&candidate["identifier"], &request["timezoneID"])
                        && same_text(&candidate["cityName"], &request["cityName"])
                }) {
                    // Preserve first-match-then-index behavior, including a first match without an index.
                    if let Some(index) = candidate["cityIndex"].as_u64() {
                        matches.push(json!({"id":request["id"],"cityIndex":index}));
                    }
                }
            }
            json!(matches)
        }
        "model.entry_label" => {
            let offset = input["offset"].as_i64().unwrap_or(0);
            let format_offset = || {
                // 显示用的负号是真减号（U+2212），与面板「−24h」、天文页「−50°」同一写法；解析侧两种都认。
                let sign = if offset >= 0 { "+" } else { "\u{2212}" };
                let n = offset.unsigned_abs();
                if n % 3600 / 60 == 0 {
                    format!("UTC{sign}{}", n / 3600)
                } else {
                    format!("UTC{sign}{}:{:02}", n / 3600, n % 3600 / 60)
                }
            };
            let label = match input["mode"].as_str().unwrap_or("name") {
                "offset" => format_offset(),
                "abbreviation" => input["abbreviation"]
                    .as_str()
                    .filter(|s| !s.starts_with("GMT") && !s.starts_with("UTC"))
                    .map(str::to_owned)
                    .unwrap_or_else(format_offset),
                _ => input["customName"]
                    .as_str()
                    .or(input["localized"].as_str())
                    .unwrap_or("")
                    .to_owned(),
            };
            // 「名称旁附 UTC 偏移」开关：名称与缩写后面补一个 UTC±N。
            // 偏移档本身就是这个数，不重复写；缩写回退成 UTC±N 时（macOS 26 会泄漏「GMT+9」）
            // 也不重复写。
            let label = if input["withOffset"] == true && !label.starts_with("UTC") && !label.is_empty() {
                format!("{label} {}", format_offset())
            } else {
                label
            };
            // emoji 放在标识前面；标识为空（城市语言 = 无）时只剩 emoji。
            json!(match emoji(&input["emoji"]).as_str() {
                Some(e) if !label.is_empty() => format!("{e} {label}"),
                Some(e) => e.to_owned(),
                None => label,
            })
        }
        _ => return Err(format!("Unknown model operation: {operation}")),
    })
}

#[no_mangle]
pub extern "C" fn mt_reference_date(unix: f64, offset: f64) -> f64 {
    unix + offset
}
#[no_mangle]
pub extern "C" fn mt_is_scrubbing(offset: f64) -> bool {
    offset != 0.0
}
#[no_mangle]
pub extern "C" fn mt_legible_opacity(opacity: f64) -> f64 {
    opacity.max(0.25)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn city_search_language_and_disabled_name_source_match_display_policy() {
        for (city, interface, expected) in [
            ("none", "ja", Value::Null),
            ("followInterface", "ja", json!("ja")),
            ("system", "ja", json!("system")),
            ("zhHans", "en", json!("zhHans")),
        ] {
            assert_eq!(
                dispatch(
                    "model.city_search_locale",
                    json!({"city":city,"interface":interface})
                )
                .unwrap(),
                expected
            );
        }
        assert_eq!(
            dispatch("model.city_locale", json!({"city":"none","interface":"ja"})).unwrap(),
            json!("ja")
        );
        assert_eq!(
            dispatch(
                "model.name_source",
                json!({"cityLanguage":"none","exemplar":true,"hide":true})
            )
            .unwrap(),
            json!("hidden")
        );
        assert_eq!(
            dispatch(
                "model.name_source",
                json!({"cityLanguage":"none","exemplar":true,"hide":false})
            )
            .unwrap(),
            json!("raw")
        );
    }
    #[test]
    fn stored_name_falls_back_only_when_absent() {
        for (candidate, expected) in [
            (Value::Null, "Munich"),
            (json!(""), ""),
            (json!("München"), "München"),
        ] {
            assert_eq!(
                dispatch(
                    "model.stored_name",
                    json!({"candidate":candidate,"raw":"Munich"})
                )
                .unwrap(),
                json!(expected)
            );
        }
    }
    #[test]
    fn refresh_requests_only_include_concrete_cities_in_original_order() {
        let result=dispatch("model.refresh_name_requests",json!([
            {"id":"a","cityName":"Berlin","timezoneID":"Europe/Berlin","usesExemplarName":true},
            {"id":"b","cityName":"Munich","timezoneID":"Europe/Berlin","usesExemplarName":false},
            {"id":"c","cityName":"Osaka","timezoneID":"Asia/Tokyo","usesExemplarName":false}
        ])).unwrap();
        assert_eq!(
            result,
            json!([
                {"id":"b","cityName":"Munich","timezoneID":"Europe/Berlin"},
                {"id":"c","cityName":"Osaka","timezoneID":"Asia/Tokyo"}
            ])
        );
    }
    #[test]
    fn refresh_matching_preserves_first_match_and_unicode_equivalence() {
        let result = dispatch(
            "model.refresh_name_matches",
            json!([
                {"request":{"id":"a","cityName":"Café","timezoneID":"UTC"},"candidates":[
                    {"cityName":"Café","identifier":"Europe/Paris","cityIndex":1},
                    {"cityName":"Cafe\u{301}","identifier":"UTC","cityIndex":2},
                    {"cityName":"Café","identifier":"UTC","cityIndex":3}]},
                {"request":{"id":"b","cityName":"Tokyo","timezoneID":"Asia/Tokyo"},"candidates":[
                    {"cityName":"Tokyo","identifier":"Asia/Tokyo","cityIndex":null},
                    {"cityName":"Tokyo","identifier":"Asia/Tokyo","cityIndex":4}]},
                {"request":{"id":"c","cityName":"Osaka","timezoneID":"Asia/Tokyo"},"candidates":[]}
            ]),
        )
        .unwrap();
        assert_eq!(result, json!([{"id":"a","cityIndex":2}]));
    }
    #[test]
    fn rename_matches_foundation_zero_width_space_trimming() {
        let result = dispatch("model.edit", json!({"zones":[{"id":"a"}],"action":{"kind":"rename","id":"a","name":"\u{200b}Tokyo\u{200b}"}})).unwrap();
        assert_eq!(result["zones"][0]["customName"], "Tokyo");
    }
    /// 「能打给的时段」：`callBasis` 设成醒着 / 上班，坏值当上班，没变化不落盘，找不到这一行也不落盘；
    /// 存档只给醒着留键，旧存档（没有这个键）读回来仍是上班。
    #[test]
    fn call_basis_edit_and_the_saved_entry() {
        let edit = |zones: &Value, basis: Value| dispatch("model.edit", json!({"zones":zones,"action":{"kind":"callBasis","id":"a","callBasis":basis}})).unwrap();
        let awake = edit(&json!([{"id":"a"},{"id":"b"}]), json!("awake"));
        assert_eq!((awake["zones"][0]["callBasis"].as_str(), awake["persist"].as_bool()), (Some("awake"), Some(true)));
        assert!(awake["zones"][1]["callBasis"].is_null());
        assert_eq!(edit(&awake["zones"], json!("awake"))["persist"], false);
        let back = edit(&awake["zones"], json!("sleepy"));
        assert_eq!((back["zones"][0]["callBasis"].as_str(), back["persist"].as_bool()), (Some("work"), Some(true)));
        assert_eq!(edit(&json!([{"id":"a","callBasis":"work"}]), json!("work"))["persist"], false);
        let missing = dispatch("model.edit", json!({"zones":[{"id":"a"}],"action":{"kind":"callBasis","id":"z","callBasis":"awake"}})).unwrap();
        assert_eq!(missing["persist"], false);
        let saved = |basis: Value| crate::store::entry(&json!({"timezoneID":"Asia/Tokyo","callBasis":basis})).unwrap()["callBasis"].clone();
        assert_eq!(saved(json!("awake")), "awake");
        assert!(saved(json!("work")).is_null() && saved(json!("AWAKE")).is_null() && saved(json!(1)).is_null() && saved(Value::Null).is_null());
    }
    /// 地点 emoji 与色点：`decorate` 两项一起设、坏值当没有、没变化不落盘；emoji 进标识前面（各模式），
    /// 标识为空时只剩 emoji；国旗（两个区域指示符）与带 ZWJ 的家庭 emoji 都算一个符号。
    #[test]
    fn decorate_sets_emoji_and_color_and_the_label_carries_the_emoji() {
        let zones = json!([{"id":"a"}]);
        let result = dispatch("model.edit", json!({"zones":zones,"action":{"kind":"decorate","id":"a","emoji":"🇯🇵","color":"blue"}})).unwrap();
        assert_eq!(result["zones"][0]["emoji"], "🇯🇵");
        assert_eq!(result["zones"][0]["color"], "blue");
        assert_eq!(result["persist"], true);
        let same = dispatch("model.edit", json!({"zones":result["zones"],"action":{"kind":"decorate","id":"a","emoji":"🇯🇵","color":"blue"}})).unwrap();
        assert_eq!(same["persist"], false);
        let bad = dispatch("model.edit", json!({"zones":result["zones"],"action":{"kind":"decorate","id":"a","emoji":"ab","color":"pink"}})).unwrap();
        assert!(bad["zones"][0]["emoji"].is_null() && bad["zones"][0]["color"].is_null());
        for (value, ok) in [("👨‍👩‍👧", true), (" 🌸 ", true), ("", false), ("🌸🌸🌸🌸🌸🌸🌸🌸🌸", false), ("a", false), ("🌸 x", false), ("\u{7}", false)] {
            assert_eq!(emoji(&json!(value)).is_string(), ok, "{value:?}");
        }
        assert!(color(&json!("gray")).is_string() && color(&json!("Gray")).is_null() && color(&json!(1)).is_null());
        let label = |mode: &str, custom: Option<&str>, localized: &str, e: Option<&str>| {
            dispatch("model.entry_label", json!({"mode": mode, "customName": custom, "localized": localized, "offset": 32400, "abbreviation": "JST", "emoji": e})).unwrap()
        };
        assert_eq!(label("name", Some("HQ"), "东京", Some("🇯🇵")), "🇯🇵 HQ");
        assert_eq!(label("name", None, "东京", Some("🇯🇵")), "🇯🇵 东京");
        assert_eq!(label("name", None, "", Some("🇯🇵")), "🇯🇵");
        assert_eq!(label("abbreviation", None, "东京", Some("🇯🇵")), "🇯🇵 JST");
        assert_eq!(label("offset", None, "东京", None), "UTC+9");
        assert_eq!(label("name", None, "东京", None), "东京");
        // 名称旁附 UTC 偏移（调研 #9）：名称与缩写后面补，偏移档不重复写。
        let with_offset = |mode: &str, localized: &str, abbreviation: Option<&str>| -> String {
            dispatch("model.entry_label", json!({"mode":mode,"customName":Value::Null,"localized":localized,
                "offset":32400,"abbreviation":abbreviation,"emoji":Value::Null,"withOffset":true})).unwrap()
                .as_str().unwrap().to_owned()
        };
        assert_eq!(with_offset("name", "东京", None), "东京 UTC+9");
        assert_eq!(with_offset("abbreviation", "东京", Some("JST")), "JST UTC+9");
        assert_eq!(with_offset("offset", "东京", None), "UTC+9");
        // 缩写回退成 UTC+9 时也不重复。
        assert_eq!(with_offset("abbreviation", "东京", Some("GMT+9")), "UTC+9");
        // 城市语言 = 无（标识为空）时不写成孤零零的偏移。
        assert_eq!(with_offset("name", "", None), "");
        // 存档往返：store.entry 认这两个字段，坏值丢掉
        let entry = crate::store::entry(&json!({"timezoneID":"Asia/Tokyo","emoji":"🗼","color":"red"})).unwrap();
        assert_eq!((entry["emoji"].as_str(), entry["color"].as_str()), (Some("🗼"), Some("red")));
        let dirty = crate::store::entry(&json!({"timezoneID":"Asia/Tokyo","emoji":"tokyo","color":"neon"})).unwrap();
        assert!(dirty["emoji"].is_null() && dirty["color"].is_null());
    }

    #[test]
    fn move_matches_indexset_destination_semantics() {
        let zones = json!([{"id":"a"},{"id":"b"},{"id":"c"},{"id":"d"}]);
        let result = dispatch(
            "model.edit",
            json!({"zones":zones,"action":{"kind":"move","offsets":[0,2],"destination":4}}),
        )
        .unwrap();
        assert_eq!(
            result["zones"],
            json!([{"id":"b"},{"id":"d"},{"id":"a"},{"id":"c"}])
        );
    }
    #[test]
    fn insert_restores_a_removed_entry_at_its_index_and_ignores_duplicates() {
        let zones = json!([{"id":"a"},{"id":"c"}]);
        let result = dispatch(
            "model.edit",
            json!({"zones":zones,"action":{"kind":"insert","index":1,"entry":{"id":"b"}}}),
        )
        .unwrap();
        assert_eq!(result["zones"], json!([{"id":"a"},{"id":"b"},{"id":"c"}]));
        assert_eq!(result["persist"], true);
        // 下标超出范围就放末尾（列表在删除后变短是常态）。
        let tail = dispatch(
            "model.edit",
            json!({"zones":[{"id":"a"}],"action":{"kind":"insert","index":9,"entry":{"id":"z"}}}),
        )
        .unwrap();
        assert_eq!(tail["zones"], json!([{"id":"a"},{"id":"z"}]));
        // 已在列表里的 id 不重复插入，也不落盘。
        let twice = dispatch(
            "model.edit",
            json!({"zones":result["zones"],"action":{"kind":"insert","index":0,"entry":{"id":"b"}}}),
        )
        .unwrap();
        assert_eq!(twice["zones"], result["zones"]);
        assert_eq!(twice["persist"], false);
        assert_eq!(twice["resetScrub"], false);
    }

    #[test]
    fn jump_keeps_slider_component() {
        let result = dispatch(
            "model.scrub",
            json!({"kind":"jump","anchor":0,"offset":3600,"now":10000,"target":20000}),
        )
        .unwrap();
        assert_eq!(result["anchor"], 6400.0);
        assert_eq!(result["display"], 10000.0);
    }

    /// 性质测试：地点表的移动 / 删除 / 撤销在随机操作下守住集合与顺序——移动 = 选中的整块按原顺序插到
    /// 「原表里 destination 位置那一项」之前、未选中的相对顺序不变；删除再按原下标 insert 回来逐字节复原；
    /// 同一个 id 的 insert 第二次是空操作；批量按下标删除只删那些下标。
    #[test]
    fn random_list_edits_keep_membership_and_order() {
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
        let iterations: u64 = std::env::var("MEANTIME_FUZZ_ITERATIONS").ok().and_then(|v| v.parse().ok()).unwrap_or(2_000);
        let seed_offset: u64 = std::env::var("MEANTIME_FUZZ_SEED").ok().and_then(|v| v.parse().ok()).unwrap_or(0);
        let mut rng = Xor(0x11D5_0F00_5EED_0001_u64.wrapping_add(seed_offset));
        let edit = |zones: &Vec<Value>, action: Value| dispatch("model.edit", json!({"zones": zones, "action": action})).unwrap();
        let ids = |zones: &[Value]| zones.iter().map(|z| z["id"].as_str().unwrap().to_owned()).collect::<Vec<_>>();
        for i in 0..iterations {
            let count = rng.below(9) as usize;
            let mut zones: Vec<Value> = (0..count).map(|k| json!({"id": format!("z{k}"), "timezoneID": "UTC", "cityName": format!("c{k}")})).collect();
            for step in 0..12 {
                let tag = format!("#{i}.{step}");
                let before = zones.clone();
                match rng.below(4) {
                    0 if !zones.is_empty() => {
                        // 移动：随机选一组下标，随机目的地 0..=len。
                        let selected: Vec<usize> = (0..zones.len()).filter(|_| rng.below(3) == 0).collect();
                        let destination = rng.below(zones.len() as u64 + 1) as usize;
                        let out = edit(&zones, json!({"kind":"move","offsets":selected,"destination":destination}));
                        let after = out["zones"].as_array().unwrap().clone();
                        let before_ids = ids(&before);
                        let after_ids = ids(&after);
                        let moved: Vec<String> = selected.iter().map(|&k| before_ids[k].clone()).collect();
                        let rest: Vec<String> = before_ids.iter().enumerate().filter(|(k, _)| !selected.contains(k)).map(|(_, id)| id.clone()).collect();
                        let insertion = (0..destination.min(before_ids.len())).filter(|k| !selected.contains(k)).count();
                        let mut expected = rest.clone();
                        expected.splice(insertion..insertion, moved.clone());
                        assert_eq!(after_ids, expected, "{tag} 移动 {selected:?} → {destination}：{before_ids:?}");
                        zones = after;
                    }
                    1 if !zones.is_empty() => {
                        // 删除再撤销：insert 回原下标必须逐字节复原；再 insert 一次是空操作。
                        let k = rng.below(zones.len() as u64) as usize;
                        let entry = zones[k].clone();
                        let removed = edit(&zones, json!({"kind":"remove","id": entry["id"]}));
                        let after_remove = removed["zones"].as_array().unwrap().clone();
                        assert_eq!(after_remove.len(), zones.len() - 1, "{tag}");
                        assert_eq!(removed["resetScrub"], after_remove.is_empty(), "{tag} 删光才重置穿梭");
                        let restored = edit(&after_remove, json!({"kind":"insert","entry": entry, "index": k}));
                        assert_eq!(restored["zones"], json!(zones), "{tag} 撤销删除没复原");
                        assert_eq!(restored["persist"], true, "{tag}");
                        let twice = edit(restored["zones"].as_array().unwrap(), json!({"kind":"insert","entry": entry, "index": k}));
                        assert_eq!(twice["zones"], json!(zones), "{tag} 连按两次撤销多出一条");
                        assert_eq!(twice["persist"], false, "{tag}");
                    }
                    2 if !zones.is_empty() => {
                        let selected: Vec<usize> = (0..zones.len()).filter(|_| rng.below(2) == 0).collect();
                        let out = edit(&zones, json!({"kind":"removeOffsets","offsets":selected}));
                        let after = out["zones"].as_array().unwrap().clone();
                        let expected: Vec<String> = ids(&before).into_iter().enumerate().filter(|(k, _)| !selected.contains(k)).map(|(_, id)| id).collect();
                        assert_eq!(ids(&after), expected, "{tag} 按下标删除");
                        assert_eq!(out["resetScrub"], after.is_empty(), "{tag}");
                        zones = after;
                    }
                    _ => {
                        let id = format!("n{i}-{step}");
                        let out = edit(&zones, json!({"kind":"add","entry":{"id": id, "timezoneID": "UTC", "cityName": "n"}}));
                        zones = out["zones"].as_array().unwrap().clone();
                        assert_eq!(zones.len(), before.len() + 1, "{tag}");
                    }
                }
                // 任何操作后 id 不重复。
                let mut seen = ids(&zones);
                seen.sort();
                seen.dedup();
                assert_eq!(seen.len(), zones.len(), "{tag} id 重复");
            }
        }
    }
}
