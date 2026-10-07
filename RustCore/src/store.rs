// SPDX-License-Identifier: GPL-3.0-only
//! Preference decoding, repair and migration plans. The host only performs
//! UserDefaults reads/writes; recovery always preserves the original bytes.
use crate::settings;
use base64::{engine::general_purpose::STANDARD, Engine};
use serde_json::{json, Map, Value};
const ZONES: &str = "tahoetime.zones.v1";
const SETTINGS: &str = "tahoetime.settings.v1";
const SNAPSHOT: &str = "tahoetime.zones.v1.last-nonempty";

pub fn entry(value: &Value) -> Option<Value> {
    let zone = value["timezoneID"].as_str()?;
    let id = value["id"]
        .as_str()
        .filter(|id| settings::uuid_valid(id))
        .map(str::to_uppercase)
        .unwrap_or_else(|| uuid::Uuid::new_v4().to_string().to_uppercase());
    let city = value["cityName"]
        .as_str()
        .map(str::to_owned)
        .unwrap_or_else(|| crate::catalog::tz_city(zone));
    let coordinate = &value["coordinate"];
    let names = &value["localizedNames"];
    let mut entry = json!({"id":id,"timezoneID":zone,"customName":value["customName"].as_str(),"cityName":city,
        "coordinate":if ["latitude", "longitude"].iter().all(|key| coordinate[key].as_f64().is_some_and(f64::is_finite)) {coordinate.clone()} else {Value::Null},
        "usesExemplarName":value["usesExemplarName"].as_bool().unwrap_or(true),
        "localizedNames":if names.as_object().is_some_and(|m|m.values().all(Value::is_string)) {names.clone()} else {Value::Null},
        "countryCode":value["countryCode"].as_str(),
        "availability":if value["availability"].is_object() {settings::availability(&value["availability"])} else {Value::Null},
        "emoji":crate::model::emoji(&value["emoji"]),"color":crate::model::color(&value["color"])});
    // 「能打给的时段」：只有按醒着算的地点带这个键；上班是默认，不写，旧存档的样子不变。
    if value["callBasis"].as_str() == Some("awake") {
        entry["callBasis"] = json!("awake");
    }
    Some(entry)
}
fn parse(encoded: &Value) -> Option<Value> {
    let data = STANDARD.decode(encoded.as_str()?).ok()?;
    serde_json::from_slice(&data).ok()
}
fn parsed_zones(encoded: &Value) -> Option<(Vec<Value>, bool)> {
    let data = parse(encoded)?;
    let array = data.as_array()?;
    let zones: Vec<_> = array.iter().filter_map(entry).collect();
    let dropped = zones.len() != array.len();
    Some((zones, dropped))
}
fn encoded(value: &Value) -> Value {
    json!(STANDARD.encode(serde_json::to_vec(value).expect("JSON is serializable")))
}
pub fn dispatch(operation: &str, input: Value) -> Result<Value, String> {
    Ok(match operation {
        "store.entry" => json!(entry(&input)),
        "store.keys" => {
            json!({"zones":ZONES,"settings":SETTINGS,"snapshot":SNAPSHOT,"marker":"tahoetime.migrated.v1",
            "group":"group.com.dayside.Dayside","lastNonEmptySuffix":".last-nonempty","corruptBackupSuffix":".corrupt-backup",
            "migrated":[ZONES,SNAPSHOT,"tahoetime.zones.v1.corrupt-backup",SETTINGS,"tahoetime.settings.v1.corrupt-backup"]})
        }
        "store.load_zones" => {
            let primary = &input["primary"];
            let snapshot = &input["snapshot"];
            let mut writes = Map::new();
            let (zones, recovered) = if primary.is_null() {
                if let Some((zones, _)) = parsed_zones(snapshot).filter(|(z, _)| !z.is_empty()) {
                    writes.insert(ZONES.into(), snapshot.clone());
                    (zones, true)
                } else {
                    (vec![], false)
                }
            } else if let Some((zones, dropped)) = parsed_zones(primary) {
                if dropped {
                    writes.insert(format!("{ZONES}.corrupt-backup"), primary.clone());
                } else if !zones.is_empty() && snapshot.is_null() {
                    writes.insert(SNAPSHOT.into(), primary.clone());
                }
                (zones, dropped)
            } else {
                writes.insert(format!("{ZONES}.corrupt-backup"), primary.clone());
                (vec![], true)
            };
            json!({"zones":zones,"recovered":recovered,"writes":writes})
        }
        "store.save_zones" => {
            let data = encoded(&input);
            let mut writes = Map::new();
            writes.insert(ZONES.into(), data.clone());
            if input.as_array().is_some_and(|a| !a.is_empty()) {
                writes.insert(SNAPSHOT.into(), data);
            }
            json!(writes)
        }
        "store.load_settings" => {
            let mut writes = Map::new();
            let value = match parse(&input) {
                Some(v) if v.is_object() => v,
                _ => {
                    if !input.is_null() {
                        writes.insert(format!("{SETTINGS}.corrupt-backup"), input.clone());
                    }
                    Value::Null
                }
            };
            json!({"settings":settings::normalize(&value),"writes":writes})
        }
        "store.save_settings" => json!({SETTINGS:encoded(&input)}),
        "store.migrate" => {
            let target = &input["target"];
            if !target["marker"].is_null()
                || !target[ZONES].is_null()
                || !target[SETTINGS].is_null()
            {
                return Ok(Value::Null);
            }
            let sources = input["sources"]
                .as_array()
                .ok_or("Missing migration sources")?;
            let choice = sources
                .iter()
                .enumerate()
                .find(|(_, s)| !s[ZONES].is_null() || !s[SETTINGS].is_null());
            if let Some((index, source)) = choice {
                let mut writes = Map::new();
                for key in [
                    ZONES,
                    SNAPSHOT,
                    "tahoetime.zones.v1.corrupt-backup",
                    SETTINGS,
                    "tahoetime.settings.v1.corrupt-backup",
                ] {
                    if let Some(value) = source.get(key) {
                        writes.insert(key.into(), value.clone());
                    }
                }
                let name = input["names"]
                    .as_array()
                    .and_then(|a| a.get(index))
                    .and_then(Value::as_str)
                    .map(str::to_owned)
                    .unwrap_or_else(|| format!("source-{index}"));
                json!({"name":name,"writes":writes})
            } else {
                Value::Null
            }
        }
        // 从旧版 Meantime 的 App Group 整域搬一次：目标域一片空白（没有迁移标记、
        // 没有地点、没有设置）才搬；只搬 App 自己的持久化键（`tahoetime.*` / `meantime.*`，后者是改名时明确不改的键名），
        // 其余（NSGlobalDomain 混进来的、系统窗口帧）一律不搬。来源不清空。
        "store.migrate_domain" => {
            let target = &input["target"];
            if !target["marker"].is_null()
                || !target[ZONES].is_null()
                || !target[SETTINGS].is_null()
            {
                return Ok(Value::Null);
            }
            let keys: Vec<&str> = input["keys"]
                .as_array()
                .ok_or("Missing source keys")?
                .iter()
                .filter_map(Value::as_str)
                .filter(|k| k.starts_with("tahoetime.") || k.starts_with("meantime."))
                .filter(|k| *k != "tahoetime.migrated.v1")
                .collect();
            if keys.is_empty() {
                Value::Null
            } else {
                json!({"copy": keys})
            }
        }
        _ => return Err(format!("Unknown store operation: {operation}")),
    })
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn oversized_numbers_recover_only_the_affected_fields() {
        let raw = br#"{"menuBarMaxZones":1e309,"showSeconds":true,"weight":"bold","future":1e9999,"customColor":{"red":1e309,"green":0,"blue":0,"opacity":1}}"#;
        let result = dispatch("store.load_settings", json!(STANDARD.encode(raw))).unwrap();
        assert_eq!(result["settings"]["menuBarMaxZones"], 4);
        assert_eq!(result["settings"]["showSeconds"], true);
        assert_eq!(result["settings"]["weight"], "bold");
        assert!(result["settings"]["customColor"].is_null());
        assert_eq!(result["writes"], json!({}));
        let bad_coordinate: Value = serde_json::from_str(r#"{"timezoneID":"UTC","cityName":"kept","coordinate":{"latitude":1e309,"longitude":0}}"#).unwrap();
        let decoded = entry(&bad_coordinate).unwrap();
        assert!(decoded["coordinate"].is_null());
        assert_eq!(decoded["cityName"], "kept");
    }
    #[test]
    fn empty_array_is_intentional_but_missing_key_restores_exact_snapshot() {
        let snapshot = encoded(&json!([{"timezoneID":"Asia/Tokyo","cityName":"Tokyo"}]));
        let cleared = dispatch(
            "store.load_zones",
            json!({"primary":encoded(&json!([])),"snapshot":snapshot}),
        )
        .unwrap();
        assert_eq!(cleared["zones"], json!([]));
        assert_eq!(cleared["recovered"], false);
        let restored = dispatch(
            "store.load_zones",
            json!({"primary":null,"snapshot":snapshot}),
        )
        .unwrap();
        assert_eq!(restored["recovered"], true);
        assert_eq!(restored["writes"][ZONES], snapshot);
    }
    #[test]
    fn bad_records_preserve_original_bytes() {
        let source = encoded(&json!([{"timezoneID":"UTC"},{"bad":"record"}]));
        let result = dispatch(
            "store.load_zones",
            json!({"primary":source,"snapshot":null}),
        )
        .unwrap();
        assert_eq!(result["zones"].as_array().unwrap().len(), 1);
        assert_eq!(result["writes"][format!("{ZONES}.corrupt-backup")], source);
    }

    #[test]
    fn domain_migration_copies_only_app_keys_into_a_blank_target() {
        let keys = json!(["tahoetime.zones.v1", "meantime.people.v1", "NSWindow Frame tools", "AppleLanguages",
            "tahoetime.migrated.v1", "meantime.travel.v1", "other.thing"]);
        let blank = dispatch("store.migrate_domain", json!({"target": {"marker": null}, "keys": keys})).unwrap();
        assert_eq!(blank["copy"], json!(["tahoetime.zones.v1", "meantime.people.v1", "meantime.travel.v1"]));
        let marked = dispatch("store.migrate_domain", json!({"target": {"marker": "x"}, "keys": keys})).unwrap();
        assert!(marked.is_null());
        let populated = dispatch("store.migrate_domain", json!({"target": {"marker": null, "tahoetime.zones.v1": "W10="}, "keys": keys})).unwrap();
        assert!(populated.is_null());
        let nothing = dispatch("store.migrate_domain", json!({"target": {}, "keys": ["AppleLanguages"]})).unwrap();
        assert!(nothing.is_null());
    }
}
