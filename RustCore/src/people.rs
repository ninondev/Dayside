// SPDX-License-Identifier: GPL-3.0-only
//! People lens: validation, recoverable storage, editing and local work rules.
//! Foundation supplies timezone/civil-date facts; this module never reads contacts.
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashSet;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct Schedule {
    start_minute: i64,
    end_minute: i64,
    working_weekdays: Vec<i64>,
}
impl Default for Schedule {
    fn default() -> Self {
        Self {
            start_minute: 540,
            end_minute: 1080,
            working_weekdays: vec![2, 3, 4, 5, 6],
        }
    }
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct Vacation {
    id: String,
    start_date: String,
    end_date: String,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct Person {
    id: String,
    name: String,
    #[serde(rename = "timeZoneID")]
    time_zone_id: String,
    #[serde(rename = "placeID")]
    place_id: Option<String>,
    country_code: Option<String>,
    contact_identifier: Option<String>,
    schedule: Schedule,
    vacations: Vec<Vacation>,
    /// 「醒着」判定基准（与地点的 CallBasis 同义）：只认精确的 "awake"；其余值与缺省都不落盘，
    /// 上班基准的人物与旧存档的序列化结果和从前逐字相同。
    #[serde(default, skip_serializing_if = "call_basis_is_not_awake")]
    call_basis: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    offset_only_zone_name: Option<bool>,
}

fn call_basis_is_not_awake(value: &Option<String>) -> bool {
    value.as_deref() != Some("awake")
}

fn text(v: &Value, key: &str) -> Option<String> {
    v.get(key)?
        .as_str()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
}
fn valid_id(s: &str) -> bool {
    uuid::Uuid::parse_str(s).is_ok()
}
pub fn valid_date(s: &str) -> bool {
    let b = s.as_bytes();
    if b.len() != 10
        || b[4] != b'-'
        || b[7] != b'-'
        || b.iter()
            .enumerate()
            .any(|(i, c)| i != 4 && i != 7 && !c.is_ascii_digit())
    {
        return false;
    }
    let year = s[0..4].parse::<u32>().unwrap_or(0);
    let month = s[5..7].parse::<u32>().unwrap_or(0);
    let day = s[8..10].parse::<u32>().unwrap_or(0);
    let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
    let days = match month {
        2 => {
            if leap {
                29
            } else {
                28
            }
        }
        4 | 6 | 9 | 11 => 30,
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        _ => 0,
    };
    year > 0 && day > 0 && day <= days
}
fn normalize(v: &Value) -> Option<Person> {
    let id = text(v, "id").filter(|id| valid_id(id))?;
    let name = text(v, "name")?;
    let zone = text(v, "timeZoneID")?;
    let schedule = &v["schedule"];
    let default = Schedule::default();
    let weekdays = schedule["workingWeekdays"]
        .as_array()
        .map(|days| {
            let mut values: Vec<i64> = days
                .iter()
                .filter_map(Value::as_i64)
                .filter(|n| (1..=7).contains(n))
                .collect();
            values.sort();
            values.dedup();
            values
        })
        .unwrap_or(default.working_weekdays);
    let mut seen = HashSet::new();
    let vacations = v["vacations"]
        .as_array()
        .map(|rows| {
            rows.iter()
                .filter_map(|row| {
                    let id = text(row, "id").filter(|id| valid_id(id))?;
                    let start_date = text(row, "startDate").filter(|s| valid_date(s))?;
                    let end_date = text(row, "endDate").filter(|s| valid_date(s))?;
                    if end_date < start_date || !seen.insert(id.to_lowercase()) {
                        return None;
                    }
                    Some(Vacation {
                        id,
                        start_date,
                        end_date,
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    Some(Person {
        id,
        name,
        time_zone_id: zone,
        place_id: text(v, "placeID").filter(|id| valid_id(id)),
        country_code: text(v, "countryCode")
            .filter(|s| s.len() == 2 && s.bytes().all(|b| b.is_ascii_alphabetic()))
            .map(|s| s.to_uppercase()),
        contact_identifier: text(v, "contactIdentifier"),
        schedule: Schedule {
            start_minute: schedule["startMinute"]
                .as_i64()
                .filter(|n| (0..1440).contains(n))
                .unwrap_or(540),
            end_minute: schedule["endMinute"]
                .as_i64()
                .filter(|n| (0..=1440).contains(n))
                .unwrap_or(1080),
            working_weekdays: weekdays,
        },
        vacations,
        call_basis: v["callBasis"].as_str().filter(|s| *s == "awake").map(str::to_owned),
        offset_only_zone_name: v["offsetOnlyZoneName"].as_bool().filter(|value| *value),
    })
}
fn validation(v: &Value, zone_valid: bool) -> (Option<Person>, Vec<&'static str>) {
    let mut issues = Vec::new();
    if text(v, "name").is_none() {
        issues.push("name");
    }
    if !zone_valid || text(v, "timeZoneID").is_none() {
        issues.push("timeZone");
    }
    if text(v, "id").is_none_or(|s| !valid_id(&s)) {
        issues.push("id");
    }
    let s = &v["schedule"];
    if s["startMinute"]
        .as_i64()
        .is_none_or(|n| !(0..1440).contains(&n))
        || s["endMinute"]
            .as_i64()
            .is_none_or(|n| !(0..=1440).contains(&n))
    {
        issues.push("hours");
    }
    if s["workingWeekdays"].as_array().is_none_or(|days| {
        days.iter()
            .any(|n| n.as_i64().is_none_or(|n| !(1..=7).contains(&n)))
    }) {
        issues.push("weekdays");
    }
    let mut seen = HashSet::new();
    if v["vacations"].as_array().is_none_or(|rows| {
        rows.iter().any(|r| {
            let Some(id) = text(r, "id").filter(|s| valid_id(s)) else {
                return true;
            };
            let Some(start) = text(r, "startDate").filter(|s| valid_date(s)) else {
                return true;
            };
            let Some(end) = text(r, "endDate").filter(|s| valid_date(s)) else {
                return true;
            };
            start > end || !seen.insert(id.to_lowercase())
        })
    }) {
        issues.push("vacation");
    }
    (
        if issues.is_empty() {
            normalize(v)
        } else {
            None
        },
        issues,
    )
}
fn decode(raw: Option<&str>) -> Value {
    let Some(raw) = raw else {
        return json!({"people":[],"hadCorruption":false,"readOnly":false,"rejectedCount":0});
    };
    let Ok(value) = serde_json::from_str::<Value>(raw) else {
        return json!({"people":[],"hadCorruption":true,"readOnly":false,"rejectedCount":0});
    };
    if value["version"].as_u64().is_some_and(|version| version > 1) {
        return json!({"people":[],"hadCorruption":true,"readOnly":true,"rejectedCount":0});
    }
    if value["version"].as_u64() != Some(1) {
        return json!({"people":[],"hadCorruption":true,"readOnly":false,"rejectedCount":0});
    }
    let Some(rows) = value["people"].as_array() else {
        return json!({"people":[],"hadCorruption":true,"readOnly":false,"rejectedCount":0});
    };
    let mut people = Vec::new();
    let mut seen = HashSet::new();
    let mut corruption = value
        .as_object()
        .is_some_and(|o| o.keys().any(|k| k != "version" && k != "people"));
    for row in rows {
        if let Some(person) = normalize(row) {
            if seen.insert(person.id.to_lowercase()) {
                // Unread fields also require preserving the original before any rewrite.
                let normalized = serde_json::to_value(&person).unwrap();
                corruption |= normalized
                    .as_object()
                    .unwrap()
                    .iter()
                    .any(|(k, v)| row.get(k).unwrap_or(&Value::Null) != v);
                corruption |= row
                    .as_object()
                    .is_some_and(|o| o.keys().any(|k| normalized.get(k).is_none()));
                people.push(person);
                continue;
            }
        }
        corruption = true;
    }
    json!({"rejectedCount":rows.len()-people.len(),"people":people,"hadCorruption":corruption,"readOnly":false})
}
fn on_vacation(person: &Person, date: &str) -> bool {
    person
        .vacations
        .iter()
        .any(|v| date >= v.start_date.as_str() && date <= v.end_date.as_str())
}
fn work_status(person: &Person, facts: &Value) -> &'static str {
    if facts["timeZoneValid"].as_bool() != Some(true) {
        return "unknown";
    }
    let date = facts["date"].as_str().unwrap_or("");
    let previous = facts["previousDate"].as_str().unwrap_or("");
    let minute = facts["minute"].as_i64().unwrap_or(-1);
    let weekday = facts["weekday"].as_i64().unwrap_or(0);
    if !valid_date(date)
        || !valid_date(previous)
        || !(0..1440).contains(&minute)
        || !(1..=7).contains(&weekday)
    {
        return "unknown";
    }
    if on_vacation(person, date) {
        return "vacation";
    }
    let s = &person.schedule;
    let works_today = s.working_weekdays.contains(&weekday);
    let works_previous = s
        .working_weekdays
        .contains(&(if weekday == 1 { 7 } else { weekday - 1 }))
        && !on_vacation(person, previous);
    let working = if s.start_minute == s.end_minute || (s.start_minute == 0 && s.end_minute == 1440)
    {
        works_today
    } else if s.end_minute > s.start_minute {
        works_today && minute >= s.start_minute && minute < s.end_minute
    } else {
        (works_today && minute >= s.start_minute) || (works_previous && minute < s.end_minute)
    };
    if working {
        "working"
    } else if !works_today {
        "dayOff"
    } else {
        "outsideHours"
    }
}

/// 人物页与排会页共用的「两个人的工作时段有多少重合」（调研 #6）。
///
/// 输入是两边已经算好的可约区间（宿主经 `planner.intervals` 拿，含休假、周末、跨午夜班次）与
/// **本机**这几天的日界（Foundation 算，因为日界是日历事实）。这里只做三件规则上的事：
/// 按本机的日子把重叠切开、只统计两边那天都要上班的日子、报出典型值与范围。
///
/// 为什么报中位数而不是平均：一周里有一天休假或某天班次特殊时，平均会把「每工作日重叠 2 小时」
/// 说成 1.7 小时，而用户要的是「一般能碰上多久」。范围（min / max）一起给，界面自己决定要不要写。
pub fn overlap_summary(input: &Value) -> Value {
    let spans = |key: &str| -> Vec<(f64, f64)> {
        input[key]
            .as_array()
            .map(|rows| {
                rows.iter()
                    .filter_map(|r| {
                        let (start, end) = (r["start"].as_f64()?, r["end"].as_f64()?);
                        (start.is_finite() && end.is_finite() && end > start).then_some((start, end))
                    })
                    .collect()
            })
            .unwrap_or_default()
    };
    let mine = spans("mine");
    let theirs = spans("theirs");
    let now = input["now"].as_f64().unwrap_or(0.0);
    let mut day_bounds: Vec<f64> = input["dayStarts"]
        .as_array()
        .map(|rows| rows.iter().filter_map(|v| v.as_f64()).filter(|v| v.is_finite()).collect())
        .unwrap_or_default();
    day_bounds.sort_by(|a, b| a.partial_cmp(b).unwrap());

    let mut per_day: Vec<i64> = vec![];
    for window in day_bounds.windows(2) {
        let (from, to) = (window[0], window[1]);
        let clip = |spans: &[(f64, f64)]| -> Vec<(f64, f64)> {
            spans
                .iter()
                .filter_map(|&(s, e)| {
                    let (s, e) = (s.max(from), e.min(to));
                    (e > s).then_some((s, e))
                })
                .collect()
        };
        let (mine_day, theirs_day) = (clip(&mine), clip(&theirs));
        // 两边那天都要上班才算「工作日」；一边休假 / 周末的日子不进统计，否则「每工作日」会被 0 拉下来。
        if mine_day.is_empty() || theirs_day.is_empty() {
            continue;
        }
        let mut minutes = 0.0;
        for &(a_start, a_end) in &mine_day {
            for &(b_start, b_end) in &theirs_day {
                let overlap = a_end.min(b_end) - a_start.max(b_start);
                if overlap > 0.0 {
                    minutes += overlap / 60.0;
                }
            }
        }
        per_day.push(minutes.round() as i64);
    }
    let mut sorted = per_day.clone();
    sorted.sort_unstable();
    let typical = if sorted.is_empty() {
        Value::Null
    } else {
        json!(sorted[sorted.len() / 2])
    };
    // 「对方下班 = 我几点」：对方下一段还没结束的工作时段的结束时刻。
    // f64 没有 Ord，自己折一遍取最小（NaN 在上面已经被过滤掉了）。
    let their_end = theirs
        .iter()
        .filter(|&&(_, end)| end > now)
        .map(|&(_, end)| end)
        .fold(None::<f64>, |acc, end| Some(acc.map_or(end, |best: f64| best.min(end))));
    json!({
        "typicalMinutes": typical,
        "minMinutes": sorted.first().copied().map(Value::from).unwrap_or(Value::Null),
        "maxMinutes": sorted.last().copied().map(Value::from).unwrap_or(Value::Null),
        "workdays": sorted.len(),
        "theirDayEnd": their_end.map(Value::from).unwrap_or(Value::Null),
    })
}

pub fn dispatch(operation: &str, input: Value) -> Result<Value, String> {
    Ok(match operation {
        "people.filter_contacts" => {
            let query = input["query"].as_str().unwrap_or("").trim().to_lowercase();
            json!(input["names"]
                .as_array()
                .map(|names| names
                    .iter()
                    .enumerate()
                    .filter(|(_, name)| name
                        .as_str()
                        .is_some_and(|s| s.to_lowercase().contains(&query)))
                    .map(|(i, _)| i)
                    .collect::<Vec<_>>())
                .unwrap_or_default())
        }
        "people.decode" => decode(input["raw"].as_str()),
        "people.overlap_summary" => overlap_summary(&input),
        "people.mutate" => {
            let mut people: Vec<Person> =
                serde_json::from_value(input["people"].clone()).map_err(|e| e.to_string())?;
            let mut issues = Vec::new();
            match input["action"].as_str().unwrap_or("") {
                "save" => {
                    let (person, errors) = validation(
                        &input["person"],
                        input["timeZoneValid"].as_bool().unwrap_or(false),
                    );
                    issues = errors;
                    if let Some(person) = person {
                        if let Some(index) = people
                            .iter()
                            .position(|p| p.id.eq_ignore_ascii_case(&person.id))
                        {
                            people[index] = person;
                        } else {
                            people.push(person);
                        }
                    }
                }
                "remove" => {
                    if let Some(id) = input["id"].as_str() {
                        people.retain(|p| !p.id.eq_ignore_ascii_case(id));
                    }
                }
                _ => issues.push("action"),
            }
            let serialized = serde_json::to_string(&json!({"version":1,"people":people})).unwrap();
            json!({"people":people,"issues":issues,"serialized":serialized})
        }
        "people.status" => {
            let person: Person =
                serde_json::from_value(input["person"].clone()).map_err(|e| e.to_string())?;
            json!(work_status(&person, &input["facts"]))
        }
        _ => return Err(format!("Unknown people operation: {operation}")),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    fn person() -> Person {
        Person {
            id: "d619cc46-00b8-42b8-80aa-a321485bdd02".into(),
            name: "Ana".into(),
            time_zone_id: "Europe/Madrid".into(),
            place_id: None,
            country_code: None,
            contact_identifier: None,
            schedule: Schedule::default(),
            vacations: vec![],
            call_basis: None,
            offset_only_zone_name: None,
        }
    }
    fn facts(date: &str, previous: &str, weekday: i64, minute: i64) -> Value {
        json!({"date":date,"previousDate":previous,"weekday":weekday,"minute":minute,"timeZoneValid":true})
    }
    #[test]
    fn civil_dates_reject_impossible_days() {
        assert!(valid_date("2000-02-29"));
        for s in [
            "1900-02-29",
            "2026-02-29",
            "2026-13-01",
            "2026-00-01",
            "0000-01-01",
            "2026-2-01",
            "２０２６-01-01",
        ] {
            assert!(!valid_date(s), "{s}");
        }
    }
    #[test]
    fn work_edges_are_half_open() {
        let p = person();
        for (minute, result) in [
            (539, "outsideHours"),
            (540, "working"),
            (1079, "working"),
            (1080, "outsideHours"),
        ] {
            assert_eq!(
                work_status(&p, &facts("2026-09-09", "2026-09-08", 4, minute)),
                result
            );
        }
    }
    #[test]
    fn night_shift_belongs_to_start_day() {
        let mut p = person();
        p.schedule.start_minute = 1320;
        p.schedule.end_minute = 360;
        assert_eq!(
            work_status(&p, &facts("2026-09-12", "2026-09-11", 7, 300)),
            "working"
        );
        assert_eq!(
            work_status(&p, &facts("2026-09-14", "2026-09-13", 2, 300)),
            "outsideHours"
        );
    }
    #[test]
    fn vacation_blocks_midnight_and_previous_shift() {
        let mut p = person();
        p.schedule.start_minute = 1320;
        p.schedule.end_minute = 360;
        p.vacations = vec![Vacation {
            id: p.id.clone(),
            start_date: "2026-09-11".into(),
            end_date: "2026-09-11".into(),
        }];
        assert_eq!(
            work_status(&p, &facts("2026-09-11", "2026-09-10", 6, 60)),
            "vacation"
        );
        assert_eq!(
            work_status(&p, &facts("2026-09-12", "2026-09-11", 7, 60)),
            "dayOff"
        );
    }
    #[test]
    fn empty_workweek_is_valid_and_never_working() {
        let mut p = person();
        p.schedule.working_weekdays.clear();
        let v = serde_json::to_value(&p).unwrap();
        assert!(validation(&v, true).1.is_empty());
        assert_eq!(
            work_status(&p, &facts("2026-09-09", "2026-09-08", 4, 600)),
            "dayOff"
        );
    }
    #[test]
    fn equal_hours_mean_whole_day() {
        let mut p = person();
        p.schedule.end_minute = p.schedule.start_minute;
        assert_eq!(
            work_status(&p, &facts("2026-09-09", "2026-09-08", 4, 0)),
            "working"
        );
    }
    #[test]
    fn unknown_zone_does_not_claim_gmt_status() {
        let p = person();
        let mut f = facts("2026-09-09", "2026-09-08", 4, 600);
        f["timeZoneValid"] = json!(false);
        assert_eq!(work_status(&p, &f), "unknown");
    }
    #[test]
    fn mixed_corruption_keeps_valid_neighbors() {
        let p = person();
        let raw = json!({"version":1,"people":[p, {"name":"broken"}, p]}).to_string();
        let result = decode(Some(&raw));
        assert_eq!(result["people"].as_array().unwrap().len(), 1);
        assert_eq!(result["rejectedCount"], 2);
        assert_eq!(result["hadCorruption"], true);
    }
    #[test]
    fn malformed_schedule_recovers_individual_fields() {
        let mut p = serde_json::to_value(person()).unwrap();
        p["schedule"]["startMinute"] = json!(-4);
        p["schedule"]["endMinute"] = json!(420);
        let raw = json!({"version":1,"people":[p]}).to_string();
        let d = decode(Some(&raw));
        assert_eq!(d["people"][0]["schedule"]["startMinute"], 540);
        assert_eq!(d["people"][0]["schedule"]["endMinute"], 420);
        assert_eq!(d["hadCorruption"], true);
    }
    #[test]
    fn future_schema_is_read_only() {
        assert_eq!(
            decode(Some("{\"version\":2,\"people\":[]}"))["readOnly"],
            true
        );
        assert_eq!(decode(Some("bad"))["readOnly"], false);
    }
    #[test]
    fn additional_fields_require_original_backup() {
        let mut p = serde_json::to_value(person()).unwrap();
        p["futureNote"] = json!("keep this");
        assert_eq!(
            decode(Some(&json!({"version":1,"people":[p]}).to_string()))["hadCorruption"],
            true
        );
    }
    #[test]
    fn missing_optional_nulls_are_not_corruption() {
        let mut p = serde_json::to_value(person()).unwrap();
        for key in ["placeID", "countryCode", "contactIdentifier"] {
            p.as_object_mut().unwrap().remove(key);
        }
        assert_eq!(
            decode(Some(&json!({"version":1,"people":[p]}).to_string()))["hadCorruption"],
            false
        );
    }
    #[test]
    fn call_basis_survives_only_as_awake() {
        let base = serde_json::to_value(person()).unwrap();
        // 旧人物（没有这个键）：归一化后再序列化，与从前逐字相同。
        assert_eq!(serde_json::to_value(normalize(&base).unwrap()).unwrap(), base);
        let round = |call_basis: Value| {
            let mut row = base.clone();
            row["callBasis"] = call_basis;
            decode(Some(&json!({"version":1,"people":[row]}).to_string()))
        };
        // 只有精确的 "awake" 原样保留，也不是要备份的未知字段。
        let awake = round(json!("awake"));
        assert_eq!(awake["people"][0]["callBasis"], json!("awake"));
        assert_eq!(awake["hadCorruption"], false);
        // "work" / 大小写不同 / 非字符串：回来时都没有这个键。
        for bad in [json!("work"), json!("AWAKE"), json!(1)] {
            let result = round(bad.clone());
            assert!(result["people"][0].get("callBasis").is_none(), "{bad}");
        }
        // 缺省（旧存档）同样没有这个键。
        let missing = decode(Some(&json!({"version":1,"people":[base]}).to_string()));
        assert!(missing["people"][0].get("callBasis").is_none());
        assert_eq!(missing["hadCorruption"], false);
    }
    #[test]
    fn offset_only_zone_name_snapshot_is_optional_and_survives_place_removal() {
        let base = serde_json::to_value(person()).unwrap();
        assert_eq!(serde_json::to_value(normalize(&base).unwrap()).unwrap(), base);
        let mut row = base.clone();
        row["timeZoneID"] = json!("Asia/Jerusalem");
        row["offsetOnlyZoneName"] = json!(true);
        // The linked place need not exist in the host's place list; storage retains the snapshot.
        row["placeID"] = Value::Null;
        let decoded = decode(Some(&json!({"version":1,"people":[row]}).to_string()));
        assert_eq!(decoded["hadCorruption"], false);
        assert_eq!(decoded["people"][0]["offsetOnlyZoneName"], true);
        for invalid in [json!(false), json!("true"), Value::Null] {
            let mut row = base.clone();
            row["offsetOnlyZoneName"] = invalid;
            assert!(serde_json::to_value(normalize(&row).unwrap()).unwrap().get("offsetOnlyZoneName").is_none());
        }
    }
    #[test]
    fn contact_filter_handles_whitespace_and_unicode_case() {
        let result = dispatch(
            "people.filter_contacts",
            json!({"names":["Ana","АННА","李安"],"query":" анн "}),
        )
        .unwrap();
        assert_eq!(result, json!([1]));
    }
    #[test]
    fn invalid_edit_preserves_existing_people() {
        let p = person();
        let mut bad = serde_json::to_value(&p).unwrap();
        bad["name"] = json!("  ");
        let result = dispatch(
            "people.mutate",
            json!({"action":"save","people":[p],"person":bad,"timeZoneValid":true}),
        )
        .unwrap();
        assert_eq!(result["people"][0]["name"], "Ana");
        assert_eq!(result["issues"], json!(["name"]));
    }
    #[test]
    fn edit_replaces_and_remove_is_explicit() {
        let mut p = person();
        let old = p.clone();
        p.name = "Ana María".into();
        let result = dispatch(
            "people.mutate",
            json!({"action":"save","people":[old],"person":p,"timeZoneValid":true}),
        )
        .unwrap();
        assert_eq!(result["people"].as_array().unwrap().len(), 1);
        let removed = dispatch(
            "people.mutate",
            json!({"action":"remove","people":result["people"],"id":p.id}),
        )
        .unwrap();
        assert_eq!(removed["people"], json!([]));
    }
    #[test]
    fn overlapping_vacations_are_a_union() {
        let mut p = person();
        p.vacations = vec![
            Vacation {
                id: p.id.clone(),
                start_date: "2026-09-09".into(),
                end_date: "2026-09-12".into(),
            },
            Vacation {
                id: "9ba02967-0d74-4c3f-9b61-205734658624".into(),
                start_date: "2026-09-11".into(),
                end_date: "2026-09-15".into(),
            },
        ];
        assert_eq!(
            work_status(&p, &facts("2026-09-15", "2026-09-14", 3, 600)),
            "vacation"
        );
    }

    #[test]
    fn the_overlap_summary_counts_only_days_both_sides_work_and_reports_the_typical_amount() {
        let day = 86_400.0;
        let base = 1_789_000_000.0 - 1_789_000_000.0 % day; // 某个 UTC 午夜
        let span = |d: f64, from: f64, to: f64| json!({"start": base + d*day + from*3600.0, "end": base + d*day + to*3600.0});
        let day_starts: Vec<Value> = (0..=5).map(|d| json!(base + f64::from(d) * day)).collect();
        // 我 9–17，对方 14–22（本机时区口径由宿主给的日界决定）：每天重叠 3 小时。
        let mine: Vec<Value> = (0..5).map(|d| span(f64::from(d), 9.0, 17.0)).collect();
        let theirs: Vec<Value> = (0..5).map(|d| span(f64::from(d), 14.0, 22.0)).collect();
        let view = overlap_summary(&json!({"mine":mine,"theirs":theirs,"now":base,"dayStarts":day_starts}));
        assert_eq!(view["typicalMinutes"], json!(180));
        assert_eq!(view["minMinutes"], json!(180));
        assert_eq!(view["maxMinutes"], json!(180));
        assert_eq!(view["workdays"], json!(5));
        // 「对方下班」= 对方下一段还没结束的工作时段的结束时刻。
        assert_eq!(view["theirDayEnd"], json!(base + 22.0 * 3600.0));

        // 逐分钟扫一遍当判据（另一套算法）：第 0 天我 9–17、对方 14–22 的交集分钟数。
        let mut minutes = 0;
        for minute in 0..1440 {
            let t = base + f64::from(minute) * 60.0;
            let mine_on = (base + 9.0*3600.0..base + 17.0*3600.0).contains(&t);
            let theirs_on = (base + 14.0*3600.0..base + 22.0*3600.0).contains(&t);
            if mine_on && theirs_on { minutes += 1; }
        }
        assert_eq!(minutes, 180);

        // 一边休假的那天不算工作日：对方只上四天班，「每工作日」仍是 3 小时而不是被 0 拉低。
        let theirs_short: Vec<Value> = (0..4).map(|d| span(f64::from(d), 14.0, 22.0)).collect();
        let vacation = overlap_summary(&json!({"mine":mine,"theirs":theirs_short,"now":base,"dayStarts":day_starts}));
        assert_eq!(vacation["typicalMinutes"], json!(180));
        assert_eq!(vacation["workdays"], json!(4));

        // 完全不重叠的两地：工作日照数，重叠 0。
        let theirs_far: Vec<Value> = (0..5).map(|d| span(f64::from(d), 18.0, 23.0)).collect();
        let none = overlap_summary(&json!({"mine":mine,"theirs":theirs_far,"now":base,"dayStarts":day_starts}));
        assert_eq!(none["typicalMinutes"], json!(0));
        assert_eq!(none["workdays"], json!(5));

        // 有的日子不一样：中位数取中间那天，范围一起给（界面据此写「2–4 小时」）。
        let mixed = vec![span(0.0, 14.0, 15.0), span(1.0, 14.0, 17.0), span(2.0, 14.0, 20.0)];
        let uneven = overlap_summary(&json!({"mine":mine,"theirs":mixed,"now":base,"dayStarts":day_starts}));
        assert_eq!(uneven["minMinutes"], json!(60));
        assert_eq!(uneven["typicalMinutes"], json!(180));
        assert_eq!(uneven["maxMinutes"], json!(180));

        // 空输入与坏输入不炸，也不假装有数字。
        let empty = overlap_summary(&json!({}));
        assert_eq!(empty["typicalMinutes"], Value::Null);
        assert_eq!(empty["workdays"], json!(0));
        assert_eq!(empty["theirDayEnd"], Value::Null);
        let junk = overlap_summary(&json!({"mine":[{"start":"x","end":1.0}],"theirs":"nope","dayStarts":[1.0,2.0]}));
        assert_eq!(junk["workdays"], json!(0));
    }
}
