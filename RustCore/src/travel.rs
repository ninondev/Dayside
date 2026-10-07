// SPDX-License-Identifier: GPL-3.0-only
//! Travel planning is clock arithmetic, not a prediction of physiological adaptation.
//! The host supplies timezone offsets and civil dates from the system tzdb.
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashSet;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct PlaceSnapshot {
    name: String,
    latitude: f64,
    longitude: f64,
    #[serde(
        rename = "countryCode",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    country_code: Option<String>,
}

fn place_snapshot(v: &Value) -> Option<PlaceSnapshot> {
    let name = v["name"].as_str()?.to_owned();
    if !(1..=80).contains(&name.chars().count()) || name.chars().any(char::is_control) {
        return None;
    }
    let latitude = v["latitude"]
        .as_f64()
        .filter(|n| (-90.0..=90.0).contains(n))?;
    let longitude = v["longitude"]
        .as_f64()
        .filter(|n| (-180.0..=180.0).contains(n))?;
    let country_code = match v.get("countryCode") {
        None | Some(Value::Null) => None,
        Some(Value::String(s)) if s.len() == 2 && s.bytes().all(|b| b.is_ascii_uppercase()) => {
            Some(s.clone())
        }
        _ => return None,
    };
    Some(PlaceSnapshot {
        name,
        latitude,
        longitude,
        country_code,
    })
}

fn deserialize_place<'de, D: serde::Deserializer<'de>>(
    d: D,
) -> Result<Option<PlaceSnapshot>, D::Error> {
    Ok(place_snapshot(&Value::deserialize(d)?))
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct Trip {
    id: String,
    name: String,
    #[serde(rename = "originTimeZoneID")]
    origin_time_zone_id: String,
    #[serde(rename = "destinationTimeZoneID")]
    destination_time_zone_id: String,
    #[serde(rename = "destinationPlaceID")]
    destination_place_id: Option<String>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "deserialize_place"
    )]
    origin_place: Option<PlaceSnapshot>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "deserialize_place"
    )]
    destination_place: Option<PlaceSnapshot>,
    departure_unix: f64,
    arrival_unix: f64,
    sleep_minute: i64,
    wake_minute: i64,
    preparation_days: i64,
    daily_shift_minutes: i64,
    direction: String,
}

fn string(v: &Value, key: &str) -> Option<String> {
    v[key]
        .as_str()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
}
fn valid_unix(n: f64) -> bool {
    // Bound Foundation date formatting to an explicitly supported civil range (1900–2200).
    n.is_finite() && (-2_208_988_800.0..7_258_118_400.0).contains(&n)
}
fn normalize(v: &Value) -> Option<Trip> {
    let id = string(v, "id").filter(|s| uuid::Uuid::parse_str(s).is_ok())?;
    let name = string(v, "name")?;
    let origin = string(v, "originTimeZoneID")?;
    let destination = string(v, "destinationTimeZoneID")?;
    let departure = v["departureUnix"].as_f64().filter(|n| valid_unix(*n))?;
    let arrival = v["arrivalUnix"]
        .as_f64()
        .filter(|n| valid_unix(*n) && *n >= departure)?;
    let sleep_minute = v["sleepMinute"]
        .as_i64()
        .filter(|n| (0..1440).contains(n))
        .unwrap_or(1380);
    let wake_minute = v["wakeMinute"]
        .as_i64()
        .filter(|n| (0..1440).contains(n))
        .unwrap_or(420);
    Some(Trip {
        id,
        name,
        origin_time_zone_id: origin,
        destination_time_zone_id: destination,
        destination_place_id: string(v, "destinationPlaceID")
            .filter(|s| uuid::Uuid::parse_str(s).is_ok()),
        origin_place: place_snapshot(&v["originPlace"]),
        destination_place: place_snapshot(&v["destinationPlace"]),
        departure_unix: departure,
        arrival_unix: arrival,
        sleep_minute,
        wake_minute,
        preparation_days: v["preparationDays"]
            .as_i64()
            .filter(|n| (0..=7).contains(n))
            .unwrap_or(3),
        daily_shift_minutes: v["dailyShiftMinutes"]
            .as_i64()
            .filter(|n| [15, 30, 60, 90, 120].contains(n))
            .unwrap_or(60),
        direction: string(v, "direction")
            .filter(|s| ["automatic", "earlier", "later"].contains(&s.as_str()))
            .unwrap_or("automatic".into()),
    })
}
fn validate(
    v: &Value,
    origin_valid: bool,
    destination_valid: bool,
) -> (Option<Trip>, Vec<&'static str>) {
    let mut issues = Vec::new();
    if string(v, "id").is_none_or(|s| uuid::Uuid::parse_str(&s).is_err()) {
        issues.push("id");
    }
    if string(v, "name").is_none() {
        issues.push("name");
    }
    if !origin_valid || string(v, "originTimeZoneID").is_none() {
        issues.push("originTimeZone");
    }
    if !destination_valid || string(v, "destinationTimeZoneID").is_none() {
        issues.push("destinationTimeZone");
    }
    let dep = v["departureUnix"].as_f64();
    let arr = v["arrivalUnix"].as_f64();
    if dep.is_none_or(|n| !valid_unix(n)) || arr.is_none_or(|n| !valid_unix(n)) {
        issues.push("date");
    } else if arr < dep {
        issues.push("arrivalBeforeDeparture");
    }
    let sleep = v["sleepMinute"].as_i64();
    let wake = v["wakeMinute"].as_i64();
    if sleep.is_none_or(|n| !(0..1440).contains(&n))
        || wake.is_none_or(|n| !(0..1440).contains(&n))
        || sleep == wake
    {
        issues.push("sleepHours");
    }
    if v["preparationDays"]
        .as_i64()
        .is_none_or(|n| !(0..=7).contains(&n))
    {
        issues.push("preparationDays");
    }
    if v["dailyShiftMinutes"]
        .as_i64()
        .is_none_or(|n| ![15, 30, 60, 90, 120].contains(&n))
    {
        issues.push("dailyShift");
    }
    if v["direction"]
        .as_str()
        .is_none_or(|s| !["automatic", "earlier", "later"].contains(&s))
    {
        issues.push("direction");
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
fn decoded(
    trips: Vec<Trip>,
    enabled: bool,
    corruption: bool,
    read_only: bool,
    rejected: usize,
) -> Value {
    json!({"trips":trips,"autoSwitchEnabled":enabled,"hadCorruption":corruption,"readOnly":read_only,"rejectedCount":rejected})
}
fn decode(raw: Option<&str>) -> Value {
    let Some(raw) = raw else {
        return decoded(vec![], false, false, false, 0);
    };
    let Ok(value) = serde_json::from_str::<Value>(raw) else {
        return decoded(vec![], false, true, false, 0);
    };
    if value["version"].as_u64().is_some_and(|n| n > 1) {
        return decoded(vec![], false, true, true, 0);
    }
    if value["version"].as_u64() != Some(1) {
        return decoded(vec![], false, true, false, 0);
    }
    let Some(rows) = value["trips"].as_array() else {
        return decoded(vec![], false, true, false, 0);
    };
    let mut trips = Vec::new();
    let mut seen = HashSet::new();
    let mut corruption = value["autoSwitchEnabled"].as_bool().is_none()
        || value.as_object().is_some_and(|o| {
            o.keys()
                .any(|k| !["version", "trips", "autoSwitchEnabled"].contains(&k.as_str()))
        });
    for row in rows {
        if let Some(trip) = normalize(row) {
            if seen.insert(trip.id.to_lowercase()) {
                let normalized = serde_json::to_value(&trip).unwrap();
                corruption |= normalized.as_object().unwrap().iter().any(|(k, v)| {
                    !["originPlace", "destinationPlace"].contains(&k.as_str())
                        && row.get(k).unwrap_or(&Value::Null) != v
                });
                corruption |= row.as_object().is_some_and(|o| {
                    o.keys().any(|k| {
                        !["originPlace", "destinationPlace"].contains(&k.as_str())
                            && normalized.get(k).is_none()
                    })
                });
                trips.push(trip);
                continue;
            }
        }
        corruption = true;
    }
    let rejected = rows.len() - trips.len();
    decoded(
        trips,
        value["autoSwitchEnabled"].as_bool().unwrap_or(false),
        corruption,
        false,
        rejected,
    )
}

/// 「自动」方向：钟面短路径，但东行跨 8 个时区以上改走推后（Eastman & Burgess 2009 引的通用指南：
/// 「东行 ≤ 7 时区提前、≥ 8 时区推后」，东行 ≥ 8 时区常见逆向重同步）；用户选了「提前 / 推后」就照用户的。
fn target_shift(offset_difference_seconds: i64, direction: &str) -> i64 {
    let advance = (offset_difference_seconds / 60).rem_euclid(1440);
    if advance == 0 {
        return 0;
    }
    let delay = 1440 - advance;
    match direction {
        "earlier" => -advance,
        "later" => delay,
        _ if advance <= delay && advance < 8 * 60 => -advance,
        _ => delay,
    }
}

/// 光照参考：以估计的体温最低点（CBTmin）为界，之后的光把生物钟拨早、
/// 之前的光把它拨晚（Khalsa 2003；St Hilaire 2012）。CBTmin 取起床前 3 小时，睡眠不足 7 小时取 2.5 小时
///（Eastman & Burgess 2009 的工作值；CDC 2026 写 2–4 小时）。提前日：起床后 3.5 小时求光、睡前 2 小时调暗；
/// 推后日：睡前 2 小时求光、起床后 3 小时避光（Eastman 2009 的两套行前方案）。落地后按目的地作息继续，
/// 每天把 CBTmin 按速率挪，剩余不足 1 小时就不再给窗口（时段挪得比生物钟快会落到另一侧帮倒忙）。
/// 不给褪黑素、安眠药、咖啡因。全部是估计与参考，界面标明。
const CBT_BEFORE_WAKE: i64 = 180;
const CBT_BEFORE_WAKE_SHORT_SLEEP: i64 = 150;
const SEEK_AFTER_WAKE: i64 = 210;
const SEEK_BEFORE_SLEEP: i64 = 120;
const AVOID_AFTER_WAKE: i64 = 180;
const DIM_BEFORE_SLEEP: i64 = 120;
const ARRIVAL_DAYS_CAP: i64 = 14;

fn cbt_offset(sleep_duration: i64) -> i64 {
    if sleep_duration < 7 * 60 {
        CBT_BEFORE_WAKE_SHORT_SLEEP
    } else {
        CBT_BEFORE_WAKE
    }
}

fn window(start: i64, end: i64) -> Value {
    json!({"startMinute": start.rem_euclid(1440), "endMinute": end.rem_euclid(1440)})
}

/// 行前某天的窗口（出发地墙钟）：`sleep` / `wake` 是这天已平移的作息，`shift` 为负是提前、为正是推后。
fn light_before_departure(sleep: i64, wake: i64, sleep_duration: i64, shift: i64) -> Value {
    let cbt = wake - cbt_offset(sleep_duration);
    if shift < 0 {
        json!({"cbtMinute": cbt.rem_euclid(1440), "seek": window(wake, wake + SEEK_AFTER_WAKE),
               "avoid": window(sleep - DIM_BEFORE_SLEEP, sleep), "avoidKind": "dim"})
    } else if shift > 0 {
        json!({"cbtMinute": cbt.rem_euclid(1440), "seek": window(sleep - SEEK_BEFORE_SLEEP, sleep),
               "avoid": window(wake, wake + AVOID_AFTER_WAKE), "avoidKind": "dark"})
    } else {
        Value::Null
    }
}

/// 把一段 [start, start + len) 裁到清醒时段（起床 → 入睡，可跨午夜）里；完全落在睡眠里返回 None。
fn clip_to_awake(start: i64, len: i64, wake: i64, awake_len: i64) -> Option<(i64, i64)> {
    let a = (start - wake).rem_euclid(1440);
    let b = a + len;
    for base in [0, 1440] {
        let (lo, hi) = (a.max(base), b.min(base + awake_len));
        if lo < hi {
            return Some((wake + lo, wake + hi));
        }
    }
    None
}

/// 落地后逐日窗口（目的地墙钟）：生物钟与目的地作息还差 `remaining`（负 = 还要拨早），每天按 `rate` 收敛。
/// 提前：CBTmin 之前的晨光是反的，先避光到 CBTmin，再求光 3.5 小时；推后：CBTmin 前 2 小时求光、之后 3 小时避光。
/// 窗口都裁到清醒时段里，整段落在睡眠里就不给（睡着就不用管）。
fn light_after_arrival(
    sleep: i64,
    wake: i64,
    sleep_duration: i64,
    remaining: i64,
    rate: i64,
) -> Vec<Value> {
    let mut rows = vec![];
    if remaining == 0 || rate <= 0 {
        return rows;
    }
    let rate = if remaining < 0 {
        rate.min(60)
    } else {
        rate.min(120)
    };
    let awake_len = (sleep - wake).rem_euclid(1440);
    let mut left = remaining;
    for day in 0..ARRIVAL_DAYS_CAP {
        if left.abs() < 60 {
            break;
        }
        // 生物钟的起床点 = 目的地起床点 − 剩余差（还要拨早 = 生物钟比当地晚）
        let body_wake = wake - left;
        let cbt = body_wake - cbt_offset(sleep_duration);
        let (seek, avoid) = if left < 0 {
            let seek_start = cbt.max(wake);
            (
                clip_to_awake(seek_start, SEEK_AFTER_WAKE, wake, awake_len),
                if cbt > wake {
                    clip_to_awake(wake, cbt - wake, wake, awake_len)
                } else {
                    None
                },
            )
        } else {
            (
                clip_to_awake(cbt - SEEK_BEFORE_SLEEP, SEEK_BEFORE_SLEEP, wake, awake_len),
                clip_to_awake(cbt, AVOID_AFTER_WAKE, wake, awake_len),
            )
        };
        rows.push(json!({"dayAfterArrival": day, "remainingMinutes": left, "cbtMinute": cbt.rem_euclid(1440),
            "seek": seek.map_or(Value::Null, |(a, b)| window(a, b)),
            "avoid": avoid.map_or(Value::Null, |(a, b)| window(a, b)),
            "avoidKind": "dark"}));
        left = if left < 0 {
            (left + rate).min(0)
        } else {
            (left - rate).max(0)
        };
    }
    rows
}

fn plan(input: &Value) -> Value {
    let Some(trip) = normalize(&input["trip"]) else {
        return json!({"error":"invalidTrip"});
    };
    if input["timeZonesValid"].as_bool() != Some(true) {
        return json!({"error":"timeZone"});
    }
    if trip.sleep_minute == trip.wake_minute {
        return json!({"error":"sleepHours"});
    }
    let Some(difference) = input["offsetDifferenceAtArrival"]
        .as_i64()
        .filter(|n| (-172_800..=172_800).contains(n))
    else {
        return json!({"error":"offset"});
    };
    let start_difference = input["offsetDifferenceAtDeparture"]
        .as_i64()
        .unwrap_or(difference);
    let shift = target_shift(difference, &trip.direction);
    let sleep_duration = (trip.wake_minute - trip.sleep_minute).rem_euclid(1440);
    let rows: Vec<Value> = (0..trip.preparation_days)
        .map(|index| {
            let shifted =
                (trip.daily_shift_minutes * (index + 1)).min(shift.abs()) * shift.signum();
            let start = trip.sleep_minute + shifted;
            let end = start + sleep_duration;
            json!({"relativeDay":index-trip.preparation_days,"shiftMinutes":shifted,
            "sleepMinute":start.rem_euclid(1440),"sleepDayOffset":start.div_euclid(1440),
            "wakeMinute":end.rem_euclid(1440),"wakeDayOffset":end.div_euclid(1440),
            "light": light_before_departure(start, end, sleep_duration, shift)})
        })
        .collect();
    let moved =
        (trip.daily_shift_minutes * trip.preparation_days).min(shift.abs()) * shift.signum();
    let remaining = shift - moved;
    let arrival_rows = light_after_arrival(
        trip.sleep_minute,
        trip.wake_minute,
        sleep_duration,
        remaining,
        trip.daily_shift_minutes,
    );
    json!({"error":null,"offsetDifferenceSeconds":difference,
        "arrivalDayDifference":input["destinationArrivalDay"].as_i64().unwrap_or(0).saturating_sub(input["originArrivalDay"].as_i64().unwrap_or(0)),
        "offsetChangesDuringTravel":start_difference!=difference,
        "travelDurationMinutes":(trip.arrival_unix-trip.departure_unix)/60.0,
        "targetShiftMinutes":shift,"remainingShiftMinutes":remaining,
        "direction": if shift < 0 { "advance" } else if shift > 0 { "delay" } else { "none" },
        "cbtOffsetMinutes": cbt_offset(sleep_duration),
        "sleepDurationMinutes":sleep_duration,"rows":rows,"arrivalRows":arrival_rows,
        "homeSleepAtDestinationMinute":(trip.sleep_minute+difference/60).rem_euclid(1440),
        "destinationSleepMinute":trip.sleep_minute,"destinationWakeMinute":trip.wake_minute})
}

/// 固定时刻在行程期间落在当地几点。
///
/// 用户自己写的几条「每天固定要做的事」（吃药、固定通话、打卡…）各是本地墙钟的一个时刻；
/// 宿主用 Foundation 把每条在每一天换算到目的地时区，这里只管：条目校验（名字裁到 40 字、
/// 最多 8 条、坏一条丢一条）、次日 / 前一日的标记、以及「这一条在当地是深夜」这种**事实**标注
/// （22:00–06:00 之间算夜间；只是陈述钟点，不劝人改时间——健康的事不是这个 App 该出主意的）。
use crate::settings::{fixed_time_list, normalize_fixed, FixedTime, FIXED_TIME_CAP};

const NIGHT_START: i64 = 1320; // 22:00
const NIGHT_END: i64 = 360; //  06:00

pub fn fixed_times(input: &Value) -> Value {
    let entries: Vec<FixedTime> = input["times"]
        .as_array()
        .map(|list| {
            list.iter()
                .filter_map(normalize_fixed)
                .take(FIXED_TIME_CAP)
                .collect()
        })
        .unwrap_or_default();
    // 宿主按「每条 × 每天」算好目的地的墙钟分钟与民用日差（跨日 ±1），顺序与 times 一致。
    let converted = input["converted"].as_array().cloned().unwrap_or_default();
    let rows: Vec<Value> = entries
        .iter()
        .enumerate()
        .map(|(index, entry)| {
            let days: Vec<Value> = converted
                .get(index)
                .and_then(|v| v.as_array())
                .map(|list| {
                    list.iter()
                        .filter_map(|day| {
                            let minute = day["minute"].as_i64().filter(|n| (0..1440).contains(n))?;
                            let offset = day["dayOffset"].as_i64().filter(|n| (-1..=1).contains(n))?;
                            let date = day["date"].as_str().unwrap_or("").to_owned();
                            Some(json!({"date":date,"minute":minute,"dayOffset":offset,
                                "night": !(NIGHT_END..NIGHT_START).contains(&minute)}))
                        })
                        .collect()
                })
                .unwrap_or_default();
            // 一周里多半每天都落在同一个当地钟点，所以把连着相同的那几天并成一段；
            // 目的地在这期间换钟的话，第二段的 fromDate 就是换钟那天（页面只需要显示这一两段）。
            let mut segments: Vec<Value> = Vec::new();
            for day in &days {
                let same = segments.last().is_some_and(|last: &Value| {
                    last["minute"] == day["minute"] && last["dayOffset"] == day["dayOffset"]
                });
                if same {
                    let last = segments.last_mut().expect("just checked");
                    last["toDate"] = day["date"].clone();
                    let count = last["days"].as_i64().unwrap_or(1) + 1;
                    last["days"] = json!(count);
                } else {
                    segments.push(json!({"fromDate":day["date"],"toDate":day["date"],
                        "minute":day["minute"],"dayOffset":day["dayOffset"],"night":day["night"],"days":1}));
                }
            }
            json!({"id":entry.id,"label":entry.label,"homeMinute":entry.minute,"days":days,"segments":segments})
        })
        .collect();
    json!({"rows":rows,"cap":FIXED_TIME_CAP,"dropped":input["times"].as_array().map_or(0, |l| l.len()).saturating_sub(rows.len())})
}

/// 行程期间「不工作」的阻塞时段。
///
/// 规则：工作时段之外就是不工作。当地的休息日（宿主按该地区的 ICU 周末数据判）整天阻塞；
/// 工作日阻塞 [0, 开始) 与 [结束, 1440) 两段——都是**目的地墙钟**，宿主再把它们变成真实时刻。
/// 工作时段跨午夜（夜班）时，不工作的就是中间那一段 [结束, 开始)。
pub fn away_blocks(input: &Value) -> Value {
    let start = input["startMinute"].as_i64().unwrap_or(540).clamp(0, 1439);
    let end = input["endMinute"].as_i64().unwrap_or(1080).clamp(0, 1440);
    let days = input["days"].as_array().cloned().unwrap_or_default();
    let mut out: Vec<Value> = Vec::new();
    for day in days {
        let Some(date) = day["date"].as_str() else {
            continue;
        };
        let weekend = day["weekend"].as_bool().unwrap_or(false);
        if weekend || start == end {
            out.push(json!({"date":date,"startMinute":0,"endMinute":1440,"wholeDay":true}));
            continue;
        }
        if end > start {
            if start > 0 {
                out.push(json!({"date":date,"startMinute":0,"endMinute":start,"wholeDay":false}));
            }
            if end < 1440 {
                out.push(json!({"date":date,"startMinute":end,"endMinute":1440,"wholeDay":false}));
            }
        } else {
            // 夜班：工作时段跨午夜，中间那段才是不工作。
            out.push(json!({"date":date,"startMinute":end,"endMinute":start,"wholeDay":false}));
        }
    }
    json!({"blocks":out})
}

/// 状态行的各段由宿主按界面语言拼接。
pub fn status_line(input: &Value) -> Value {
    let place = input["place"].as_str().unwrap_or("").trim();
    let segment = |key: &str| {
        if place.is_empty() {
            ""
        } else {
            input[key].as_str().unwrap_or("").trim()
        }
    };
    json!({"place":place,"zoneAbbreviation":segment("zoneAbbreviation"),"offsetText":segment("offsetText"),
        "localWindowText":segment("localWindowText"),"counterpartWindowText":segment("counterpartWindowText")})
}

#[derive(Clone)]
struct NightFrame {
    date: String,
    start: f64,
    end: f64,
}

fn night_span(value: &Value) -> Option<[f64; 2]> {
    let values = value.as_array()?;
    if values.len() != 2 {
        return None;
    }
    let start = values[0].as_f64()?;
    let end = values[1].as_f64()?;
    (crate::astronomy::SUPPORTED_UNIX.contains(&start)
        && crate::astronomy::SUPPORTED_UNIX.contains(&end)
        && start < end)
        .then_some([start, end])
}

fn night_frame(value: &Value) -> Option<NightFrame> {
    let span = night_span(&json!([value["start"], value["end"]]))?;
    let date = value["date"].as_str()?;
    let parts: Vec<_> = date.split('-').collect();
    if parts.len() != 3
        || parts[0].len() != 4
        || parts[1].len() != 2
        || parts[2].len() != 2
        || !date.bytes().all(|b| b.is_ascii_digit() || b == b'-')
        || span[1] - span[0] > 2.0 * 86_400.0
    {
        return None;
    }
    let year = parts[0].parse::<i32>().ok()?;
    if !(1800..=2100).contains(&year) {
        return None;
    }
    let month = parts[1].parse::<u32>().ok()?;
    let day = parts[2].parse::<u32>().ok()?;
    let days = month_days(year, month)?;
    if !(1..=days).contains(&day) {
        return None;
    }
    Some(NightFrame {
        date: date.into(),
        start: span[0],
        end: span[1],
    })
}

fn month_days(year: i32, month: u32) -> Option<u32> {
    match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => Some(31),
        4 | 6 | 9 | 11 => Some(30),
        2 => Some(if year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) {
            29
        } else {
            28
        }),
        _ => None,
    }
}

fn next_night_date(date: &str) -> String {
    let parts: Vec<_> = date.split('-').collect();
    let mut year = parts[0].parse::<i32>().unwrap_or(2000);
    let mut month = parts[1].parse::<u32>().unwrap_or(1);
    let mut day = parts[2].parse::<u32>().unwrap_or(1) + 1;
    if day > month_days(year, month).unwrap_or(31) {
        day = 1;
        month += 1;
        if month > 12 {
            month = 1;
            year += 1;
        }
    }
    format!("{year:04}-{month:02}-{day:02}")
}

fn night_position(frame: &NightFrame, instant: f64) -> f64 {
    ((instant - frame.start) / (frame.end - frame.start)).clamp(0.0, 1.0)
}

fn night_coordinate(value: &Value) -> Option<(f64, f64)> {
    Some((
        value["latitude"]
            .as_f64()
            .filter(|n| (-90.0..=90.0).contains(n))?,
        value["longitude"]
            .as_f64()
            .filter(|n| (-180.0..=180.0).contains(n))?,
    ))
}

struct NightPart {
    frame: NightFrame,
    start: f64,
    end: f64,
    place: &'static str,
}

struct NightLane {
    value: Value,
    parts: Vec<NightPart>,
}

fn night_part(frame: &NightFrame, start: f64, end: f64, place: &'static str) -> Option<NightPart> {
    (start < end).then(|| NightPart {
        frame: frame.clone(),
        start,
        end,
        place,
    })
}

fn night_lane(
    kind: &str,
    frame: &NightFrame,
    parts: Vec<NightPart>,
    label: Value,
    checks: Value,
    sleep: Option<[f64; 2]>,
    instants: (Option<f64>, Option<f64>),
) -> NightLane {
    let (departure, arrival) = instants;
    let clipped_sleep = sleep.and_then(|span| {
        parts.iter().find_map(|part| {
            let start = span[0].max(part.start);
            let end = span[1].min(part.end);
            (start < end).then(|| {
                (
                    json!([
                        night_position(&part.frame, start),
                        night_position(&part.frame, end)
                    ]),
                    span[0] < part.start,
                    span[1] > part.end,
                )
            })
        })
    });
    let (sleep, clip_start, clip_end) = clipped_sleep.unwrap_or((Value::Null, false, false));
    NightLane {
        value: json!({"kind":kind,"date":frame.date,"parts":[],"air":[],"sleep":sleep,"sleepClipStart":clip_start,"sleepClipEnd":clip_end,
        "seek":[],"avoid":[],"avoidKind":null,"departure":departure,"arrival":arrival,"reference":null,
        "label":label,"dateTo":null,"seekRange":null,"avoidRange":null,"midPlane":false,
        "range":[frame.start,frame.end],"checks":checks}),
        parts,
    }
}

fn add_night_window(lane: &mut NightLane, kind: &str, span: [f64; 2], avoid_kind: &str) {
    for part in &lane.parts {
        if !(part.frame.start..part.frame.end).contains(&span[0]) {
            continue;
        }
        let start = span[0].max(part.start);
        let end = span[1].min(part.end);
        if end <= start {
            continue;
        }
        let position = json!([
            night_position(&part.frame, start),
            night_position(&part.frame, end)
        ]);
        lane.value[kind]
            .as_array_mut()
            .expect("窗口数组")
            .push(position);
        let range_key = if kind == "seek" {
            "seekRange"
        } else {
            "avoidRange"
        };
        // 正常安排每种只有一个窗口；额外窗口都画，文字覆盖它们的起止范围。
        if let Some(old) = night_span(&lane.value[range_key]) {
            lane.value[range_key] = json!([old[0].min(start), old[1].max(end)]);
        } else {
            lane.value[range_key] = json!([start, end]);
        }
        if kind == "avoid" {
            lane.value["avoidKind"] = json!(avoid_kind);
        }
        return;
    }
}

fn nights(input: &Value) -> Result<Value, String> {
    let departure = input["departure"]
        .as_f64()
        .filter(|n| crate::astronomy::SUPPORTED_UNIX.contains(n))
        .ok_or("Travel nights needs a supported departure")?;
    let arrival = input["arrival"]
        .as_f64()
        .filter(|n| crate::astronomy::SUPPORTED_UNIX.contains(n) && *n >= departure)
        .ok_or("Travel nights needs a supported arrival")?;
    let departure_frame = night_frame(&input["departureNight"]).ok_or("Invalid departure night")?;
    let arrival_frame = night_frame(&input["arrivalNight"]).ok_or("Invalid arrival night")?;
    if !(departure_frame.start..departure_frame.end).contains(&departure)
        || !(arrival_frame.start..arrival_frame.end).contains(&arrival)
    {
        return Err("Travel instants must belong to their nights".into());
    }
    let prep = input["prep"]
        .as_array()
        .ok_or("Travel nights needs preparation rows")?;
    let after = input["after"]
        .as_array()
        .ok_or("Travel nights needs arrival rows")?;
    if prep.len() + after.len() + 1 > 32 {
        return Err("Travel nights supports up to 32 rows".into());
    }
    let mut lanes = Vec::new();
    for row in prep {
        let frame = night_frame(row).ok_or("Invalid preparation night")?;
        let truncated = (frame.start..frame.end).contains(&departure);
        let end = if truncated { departure } else { frame.end };
        let part = night_part(&frame, frame.start, end, "origin")
            .into_iter()
            .collect();
        let mut lane = night_lane(
            "prep",
            &frame,
            part,
            json!({"kind":"shift","minutes":row["shiftMinutes"].as_i64().unwrap_or(0)}),
            row.get("checks").cloned().unwrap_or(Value::Null),
            night_span(&row["sleep"]),
            (truncated.then(|| night_position(&frame, departure)), None),
        );
        for kind in ["seek", "avoid"] {
            if let Some(span) = night_span(&row[kind]) {
                add_night_window(
                    &mut lane,
                    kind,
                    span,
                    row["avoidKind"]
                        .as_str()
                        .filter(|k| *k == "dim")
                        .unwrap_or("dark"),
                );
            }
        }
        lanes.push(lane);
    }
    let departure_in_prep = prep
        .last()
        .and_then(night_frame)
        .is_some_and(|f| f.start == departure_frame.start && f.end == departure_frame.end);
    let left = if departure_in_prep {
        0.0
    } else {
        night_position(&departure_frame, departure)
    };
    // 宿主提供民用日期；旧调用方按中午框的前后半段推断。
    let departure_date = input["departureDate"]
        .as_str()
        .map(str::to_owned)
        .unwrap_or_else(|| {
            if departure < (departure_frame.start + departure_frame.end) / 2.0 {
                departure_frame.date.clone()
            } else {
                next_night_date(&departure_frame.date)
            }
        });
    let arrival_date = input["arrivalDate"]
        .as_str()
        .map(str::to_owned)
        .unwrap_or_else(|| {
            if arrival < (arrival_frame.start + arrival_frame.end) / 2.0 {
                arrival_frame.date.clone()
            } else {
                next_night_date(&arrival_frame.date)
            }
        });
    let has_right = arrival_frame.date < arrival_date;
    let right = night_position(&arrival_frame, arrival);
    let separate_right = has_right && right - left < 0.04;
    let mut flight_parts = Vec::new();
    if !departure_in_prep {
        flight_parts.extend(night_part(
            &departure_frame,
            departure_frame.start,
            departure,
            "origin",
        ));
    }
    if has_right && !separate_right {
        flight_parts.extend(night_part(
            &arrival_frame,
            arrival,
            arrival_frame.end,
            "destination",
        ));
    }
    let flight_frame = NightFrame {
        date: departure_date,
        start: departure,
        end: arrival,
    };
    let mut flight = night_lane(
        "flight",
        &flight_frame,
        flight_parts,
        json!({"kind":"flight","minutes":(arrival-departure)/60.0}),
        Value::Null,
        None,
        (
            (!departure_in_prep).then_some(left),
            (has_right && !separate_right).then_some(right),
        ),
    );
    flight.value["midPlane"] = json!(departure_in_prep && (!has_right || separate_right));
    lanes.push(flight);
    if separate_right {
        let part = night_part(&arrival_frame, arrival, arrival_frame.end, "destination")
            .into_iter()
            .collect();
        let remaining = after
            .first()
            .and_then(|r| r["remainingMinutes"].as_i64())
            .unwrap_or(0);
        let label = if remaining.unsigned_abs() >= 60 {
            json!({"kind":"remaining","minutes":remaining})
        } else {
            json!({"kind":"aligned"})
        };
        lanes.push(night_lane(
            "after",
            &arrival_frame,
            part,
            label,
            input["arrivalNight"]
                .get("checks")
                .cloned()
                .unwrap_or(Value::Null),
            night_span(&input["arrivalNight"]["sleep"]),
            (None, Some(right)),
        ));
    }
    if after.is_empty() {
        return Err("Travel nights needs at least one arrival night".into());
    }
    for row in after {
        let frame = night_frame(row).ok_or("Invalid arrival night")?;
        let truncated = (frame.start..frame.end).contains(&arrival);
        let start = if truncated { arrival } else { frame.start };
        let part = night_part(&frame, start, frame.end, "destination")
            .into_iter()
            .collect();
        let remaining = row["remainingMinutes"].as_i64().unwrap_or(0);
        let label = if remaining.unsigned_abs() >= 60 {
            json!({"kind":"remaining","minutes":remaining})
        } else {
            json!({"kind":"aligned"})
        };
        lanes.push(night_lane(
            "after",
            &frame,
            part,
            label,
            row.get("checks").cloned().unwrap_or(Value::Null),
            night_span(&row["sleep"]),
            (None, truncated.then(|| night_position(&frame, arrival))),
        ));
    }
    if lanes.len() > 32 {
        return Err("Travel nights supports up to 32 rows".into());
    }
    for window in input["windows"].as_array().into_iter().flatten().take(128) {
        let Some(kind) = window["kind"]
            .as_str()
            .filter(|k| ["seek", "avoid"].contains(k))
        else {
            continue;
        };
        let Some(span) = night_span(&window["span"]) else {
            continue;
        };
        if let Some(lane) = lanes.iter_mut().find(|lane| {
            lane.parts.iter().any(|p| {
                p.place == "destination"
                    && (p.frame.start..p.frame.end).contains(&span[0])
                    && span[1] > p.start
            })
        }) {
            add_night_window(
                lane,
                kind,
                span,
                window["avoidKind"]
                    .as_str()
                    .filter(|k| *k == "dim")
                    .unwrap_or("dark"),
            );
        }
    }
    let reference = input["reference"].as_f64().filter(|n| n.is_finite());
    if let Some(reference) = reference {
        if (departure..arrival).contains(&reference) {
            let flight = lanes
                .iter_mut()
                .find(|l| l.value["kind"] == "flight")
                .expect("飞行行");
            let from = flight.value["departure"].as_f64().unwrap_or(0.0);
            let to = flight.value["arrival"].as_f64().unwrap_or(1.0);
            flight.value["reference"] =
                json!(from + (to - from) * (reference - departure) / (arrival - departure));
        } else if let Some((lane, position)) = lanes.iter_mut().find_map(|lane| {
            lane.parts
                .iter()
                .find(|p| (p.start..p.end).contains(&reference))
                .map(|p| night_position(&p.frame, reference))
                .map(|position| (lane, position))
        }) {
            lane.value["reference"] = json!(position);
        }
    }
    let quiet = |lane: &NightLane| {
        lane.value["kind"] == "after"
            && lane.value["seek"].as_array().is_some_and(Vec::is_empty)
            && lane.value["avoid"].as_array().is_some_and(Vec::is_empty)
            && lane.value["arrival"].is_null()
            && lane.value["reference"].is_null()
            && lane
                .parts
                .iter()
                .all(|p| (p.frame.end - p.frame.start - 86_400.0).abs() < 1.0)
            && ["nonexistentTime", "repeatedTime", "overlapsDeparture"]
                .iter()
                .all(|key| lane.value["checks"][key].as_bool() != Some(true))
    };
    let first_quiet = lanes.iter().rposition(|l| !quiet(l)).map_or(0, |n| n + 1);
    if lanes.len() - first_quiet >= 2 {
        let count = lanes.len() - first_quiet;
        let date_to = lanes.last().expect("至少两晚").value["date"].clone();
        let first = &mut lanes[first_quiet];
        first.value["label"] = json!({"kind":"quiet","nights":count,"minutes":first.value["label"]["minutes"].as_i64().unwrap_or(0)});
        first.value["dateTo"] = date_to;
        lanes.truncate(first_quiet + 1);
    }
    let marks = input["marks"].as_bool().unwrap_or(false);
    for lane in &mut lanes {
        let mut positions = Vec::new();
        let mut parts = Vec::new();
        for part in &lane.parts {
            let from = night_position(&part.frame, part.start);
            let to = night_position(&part.frame, part.end);
            positions.push([from, to]);
            let coordinate = night_coordinate(&input[part.place]);
            let stops = |line: bool| {
                coordinate
                    .map(|(latitude, longitude)| {
                        let colors = if line {
                            crate::sky::line_stops(part.start, part.end, latitude, longitude, 10.0)
                        } else {
                            crate::sky::lane_stops(part.start, part.end, latitude, longitude, 10.0)
                        };
                        colors
                            .into_iter()
                            .map(|(at, color)| json!({"at":at,"color":color}))
                            .collect::<Vec<_>>()
                    })
                    .unwrap_or_default()
            };
            let boundaries = coordinate
                .filter(|_| marks)
                .map(|(latitude, longitude)| {
                    crate::sky::band_marks(
                        &crate::astronomy::daylight_bands(
                            part.start, part.end, latitude, longitude,
                        ),
                        part.start,
                        part.end,
                    )
                })
                .unwrap_or_default();
            parts.push(json!({"place":part.place,"from":from,"to":to,"stops":stops(false),"lineStops":stops(true),"marks":boundaries}));
        }
        positions.sort_by(|a, b| a[0].total_cmp(&b[0]));
        let mut air = Vec::new();
        let mut cursor: f64 = 0.0;
        for [from, to] in positions {
            if from > cursor {
                air.push(json!([cursor, from]));
            }
            cursor = cursor.max(to);
        }
        if cursor < 1.0 {
            air.push(json!([cursor, 1.0]));
        }
        lane.value["parts"] = json!(parts);
        lane.value["air"] = json!(air);
    }
    let selected = lanes
        .iter()
        .position(|l| !l.value["reference"].is_null())
        .unwrap_or_else(|| {
            let first = lanes
                .iter()
                .flat_map(|l| &l.parts)
                .map(|p| p.start)
                .min_by(f64::total_cmp)
                .unwrap_or(departure);
            if reference.is_some_and(|r| r < first) {
                0
            } else {
                lanes.len().saturating_sub(1)
            }
        });
    Ok(json!({"lanes":lanes.into_iter().map(|l| l.value).collect::<Vec<_>>(),"selected":selected}))
}

pub fn dispatch(operation: &str, input: Value) -> Result<Value, String> {
    Ok(match operation {
        "travel.decode" => decode(input["raw"].as_str()),
        "travel.mutate" => {
            let mut trips: Vec<Trip> =
                serde_json::from_value(input["trips"].clone()).map_err(|e| e.to_string())?;
            let mut enabled = input["autoSwitchEnabled"].as_bool().unwrap_or(false);
            let mut issues = Vec::new();
            match input["action"].as_str().unwrap_or("") {
                "save" => {
                    let (trip, errors) = validate(
                        &input["trip"],
                        input["originTimeZoneValid"].as_bool().unwrap_or(false),
                        input["destinationTimeZoneValid"].as_bool().unwrap_or(false),
                    );
                    issues = errors;
                    if let Some(trip) = trip {
                        if let Some(i) = trips
                            .iter()
                            .position(|t| t.id.eq_ignore_ascii_case(&trip.id))
                        {
                            trips[i] = trip;
                        } else {
                            trips.push(trip);
                        }
                    }
                }
                "remove" => {
                    if let Some(id) = input["id"].as_str() {
                        trips.retain(|t| !t.id.eq_ignore_ascii_case(id));
                    }
                }
                "setAutoSwitch" => {
                    if let Some(value) = input["enabled"].as_bool() {
                        enabled = value;
                    } else {
                        issues.push("autoSwitch");
                    }
                }
                _ => issues.push("action"),
            }
            let serialized = serde_json::to_string(
                &json!({"version":1,"trips":trips,"autoSwitchEnabled":enabled}),
            )
            .unwrap();
            json!({"trips":trips,"autoSwitchEnabled":enabled,"serialized":serialized,"issues":issues})
        }
        "travel.plan" => plan(&input),
        "travel.nights" => nights(&input)?,
        "travel.fixed_times" => fixed_times(&input),
        "travel.fixed_time_list" => fixed_time_list(&input),
        "travel.status_line" => status_line(&input),
        "travel.away_blocks" => away_blocks(&input),
        "travel.schedule_checks" => {
            let starts: Vec<f64> = input["sleepCandidates"]
                .as_array()
                .map(|v| v.iter().filter_map(Value::as_f64).collect())
                .unwrap_or_default();
            let ends: Vec<f64> = input["wakeCandidates"]
                .as_array()
                .map(|v| v.iter().filter_map(Value::as_f64).collect())
                .unwrap_or_default();
            let departure = input["departureUnix"].as_f64().unwrap_or(f64::MAX);
            json!({"nonexistentTime":starts.is_empty() || ends.is_empty(),"repeatedTime":starts.len()>1 || ends.len()>1,
                "overlapsDeparture":starts.iter().any(|s| *s>=departure) || ends.iter().any(|e| *e>departure),
                "elapsedSleepMinutes":if starts.len()==1 && ends.len()==1 {Some((ends[0]-starts[0])/60.0)} else {None}})
        }
        "travel.primary_change" => {
            if input["enabled"].as_bool() != Some(true) {
                Value::Null
            } else if let Some(zones) = input["zones"].as_array() {
                let system = input["systemTimeZoneID"].as_str().unwrap_or("");
                zones
                    .iter()
                    .enumerate()
                    .find(|(_, z)| !system.is_empty() && z["timeZoneID"].as_str() == Some(system))
                    .filter(|(index, _)| *index > 0)
                    .map(|(_, z)| z["id"].clone())
                    .unwrap_or(Value::Null)
            } else {
                Value::Null
            }
        }
        _ => return Err(format!("Unknown travel operation: {operation}")),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    fn trip() -> Value {
        json!({"id":"0cbad259-a750-4086-a50f-83cfa0c1c52d","name":"Tokyo","originTimeZoneID":"America/Los_Angeles","destinationTimeZoneID":"Asia/Tokyo","departureUnix":1789000000.0,"arrivalUnix":1789050000.0,"sleepMinute":1380,"wakeMinute":420,"preparationDays":3,"dailyShiftMinutes":60,"direction":"automatic"})
    }
    fn input(difference: i64) -> Value {
        json!({"trip":trip(),"timeZonesValid":true,"offsetDifferenceAtArrival":difference,"offsetDifferenceAtDeparture":difference,"originArrivalDay":20000,"destinationArrivalDay":20001})
    }
    #[test]
    fn eastward_short_difference_advances_clock() {
        let p = plan(&input(5 * 3600));
        assert_eq!(p["targetShiftMinutes"], -300);
        assert_eq!(p["rows"][0]["sleepMinute"], 1320);
        assert_eq!(p["remainingShiftMinutes"], -120);
    }
    #[test]
    fn westward_short_difference_delays_clock() {
        let p = plan(&input(-5 * 3600));
        assert_eq!(p["targetShiftMinutes"], 300);
        assert_eq!(p["rows"][0]["sleepMinute"], 0);
        assert_eq!(p["rows"][0]["sleepDayOffset"], 1);
        assert_eq!(p["rows"][0]["wakeMinute"], 480);
    }
    #[test]
    fn date_line_uses_short_clock_path_but_keeps_actual_difference() {
        let p = plan(&input(16 * 3600));
        assert_eq!(p["targetShiftMinutes"], 480);
        assert_eq!(p["offsetDifferenceSeconds"], 57600);
        assert_eq!(p["arrivalDayDifference"], 1);
    }
    #[test]
    fn a_full_day_difference_needs_no_clock_shift() {
        let p = plan(&input(24 * 3600));
        assert_eq!(p["targetShiftMinutes"], 0);
        assert_eq!(p["rows"][2]["sleepMinute"], 1380);
    }
    #[test]
    fn direction_override_is_honored() {
        let mut i = input(16 * 3600);
        i["trip"]["direction"] = json!("earlier");
        assert_eq!(plan(&i)["targetShiftMinutes"], -960);
        i["trip"]["direction"] = json!("later");
        assert_eq!(plan(&i)["targetShiftMinutes"], 480);
    }
    #[test]
    fn fractional_offset_never_overshoots() {
        let p = plan(&input(90 * 60));
        assert_eq!(p["rows"][0]["shiftMinutes"], -60);
        assert_eq!(p["rows"][1]["shiftMinutes"], -90);
        assert_eq!(p["rows"][2]["shiftMinutes"], -90);
        assert_eq!(p["remainingShiftMinutes"], 0);
    }
    #[test]
    fn zero_preparation_days_gives_no_imaginary_preparation() {
        let mut i = input(3600);
        i["trip"]["preparationDays"] = json!(0);
        let p = plan(&i);
        assert_eq!(p["rows"], json!([]));
        assert_eq!(p["remainingShiftMinutes"], -60);
    }
    #[test]
    fn negative_midnight_rolls_to_previous_date() {
        let mut i = input(5 * 3600);
        i["trip"]["sleepMinute"] = json!(30);
        i["trip"]["wakeMinute"] = json!(510);
        let p = plan(&i);
        assert_eq!(p["rows"][0]["sleepDayOffset"], -1);
        assert_eq!(p["rows"][0]["sleepMinute"], 1410);
        assert_eq!(p["rows"][0]["wakeMinute"], 450);
    }
    #[test]
    fn sleep_clock_duration_is_preserved_for_every_plan_step() {
        for offset in -26 * 60..=26 * 60 {
            let p = plan(&input(offset * 60));
            for row in p["rows"].as_array().unwrap() {
                let start = row["sleepMinute"].as_i64().unwrap()
                    + row["sleepDayOffset"].as_i64().unwrap() * 1440;
                let end = row["wakeMinute"].as_i64().unwrap()
                    + row["wakeDayOffset"].as_i64().unwrap() * 1440;
                assert_eq!(end - start, 480);
            }
        }
    }
    #[test]
    fn native_dst_offset_change_is_reported() {
        let mut i = input(3600);
        i["offsetDifferenceAtDeparture"] = json!(0);
        assert_eq!(plan(&i)["offsetChangesDuringTravel"], true);
    }
    #[test]
    fn impossible_arrival_order_is_rejected() {
        let mut t = trip();
        t["arrivalUnix"] = json!(1000);
        assert!(validate(&t, true, true)
            .1
            .contains(&"arrivalBeforeDeparture"));
    }
    #[test]
    fn equal_sleep_and_wake_requires_user_correction() {
        let mut t = trip();
        t["wakeMinute"] = t["sleepMinute"].clone();
        assert!(validate(&t, true, true).1.contains(&"sleepHours"));
    }
    #[test]
    fn future_schema_and_corrupt_rows_preserve_recovery_boundary() {
        assert_eq!(decode(Some("{\"version\":2}"))["readOnly"], true);
        let d = decode(Some(
            &json!({"version":1,"trips":[trip(),{}],"autoSwitchEnabled":false}).to_string(),
        ));
        assert_eq!(d["trips"].as_array().unwrap().len(), 1);
        assert_eq!(d["hadCorruption"], true);
        assert_eq!(d["rejectedCount"], 1);
    }
    #[test]
    fn automatic_primary_switch_requires_explicit_enablement_and_exact_zone() {
        let v = json!({"enabled":false,"systemTimeZoneID":"Asia/Tokyo","zones":[{"id":"a","timeZoneID":"UTC"},{"id":"b","timeZoneID":"Asia/Tokyo"}]});
        assert_eq!(
            dispatch("travel.primary_change", v.clone()).unwrap(),
            Value::Null
        );
        let mut v = v;
        v["enabled"] = json!(true);
        assert_eq!(
            dispatch("travel.primary_change", v.clone()).unwrap(),
            json!("b")
        );
        v["systemTimeZoneID"] = json!("Asia/Seoul");
        assert_eq!(dispatch("travel.primary_change", v).unwrap(), Value::Null);
    }
    #[test]
    fn already_primary_does_not_trigger_reorder() {
        assert_eq!(dispatch("travel.primary_change",json!({"enabled":true,"systemTimeZoneID":"UTC","zones":[{"id":"a","timeZoneID":"UTC"}]})).unwrap(),Value::Null);
    }
    #[test]
    fn changing_opt_in_preserves_trips() {
        let result=dispatch("travel.mutate",json!({"action":"setAutoSwitch","trips":[normalize(&trip()).unwrap()],"autoSwitchEnabled":false,"enabled":true})).unwrap();
        assert_eq!(result["autoSwitchEnabled"], true);
        assert_eq!(result["trips"].as_array().unwrap().len(), 1);
    }

    /// 性质测试：随机行程（任意时差含跨日界线、三种方向、0–7 天准备期、三档每日推移、任意作息）下，
    /// 作息参考表必须自洽——行数等于准备天数；每天推移量单调、每步不超过每日推移、绝对值不超过目标；
    /// 睡眠时长每行不变；目标推移在自动方向下取较短的一边（|目标| ≤ 12 小时），指定方向时符号跟方向；
    /// 剩余 = 目标 − 已推；表里每行的睡 / 醒分钟都在 0..1440、日偏移在 -1..=2 之内且睡眠时长按日偏移算回来不变。
    /// 用 Eastman & Burgess 2009 的两个案例当判据（PMC2829880 图 1 与图 6）。
    /// 芝加哥 → 巴黎东行 7 时区：提前；落地当天 CBTmin 在巴黎 11:00（家里 04:00 + 7），11:00 前避光、之后求光 3.5 小时。
    /// 旧金山 → 北京：钟面差 +15 小时，短边是推后 9 小时（西行）；落地当天 CBTmin 在北京 19:00，17–19 求光、19–22 避光。
    /// 北京 → 旧金山返程：短边是提前 9 小时 ≥ 8 → 自动改走推后 15 小时。
    #[test]
    fn light_windows_match_the_eastman_cases() {
        let plan_for = |difference: i64, prep: i64, daily: i64, direction: &str| {
            plan(
                &json!({"trip": {"id": "0cbad259-a750-4086-a50f-83cfa0c1c52d", "name": "t", "originTimeZoneID": "A", "destinationTimeZoneID": "B",
                "departureUnix": 1_789_000_000.0, "arrivalUnix": 1_789_030_000.0, "sleepMinute": 1380, "wakeMinute": 420,
                "preparationDays": prep, "dailyShiftMinutes": daily, "direction": direction},
                "timeZonesValid": true, "offsetDifferenceAtArrival": difference, "offsetDifferenceAtDeparture": difference}),
            )
        };
        // 芝加哥 → 巴黎，不做行前调整
        let paris = plan_for(7 * 3600, 0, 60, "automatic");
        assert_eq!(paris["direction"], "advance");
        assert_eq!(paris["targetShiftMinutes"], -420);
        assert_eq!(paris["cbtOffsetMinutes"], 180);
        let day0 = &paris["arrivalRows"][0];
        assert_eq!(day0["remainingMinutes"], -420);
        assert_eq!(day0["cbtMinute"], 11 * 60);
        assert_eq!(
            day0["avoid"],
            json!({"startMinute": 7 * 60, "endMinute": 11 * 60})
        );
        assert_eq!(
            day0["seek"],
            json!({"startMinute": 11 * 60, "endMinute": 14 * 60 + 30})
        );
        // 每天提前 1 小时，第 6 天剩 60 分钟还给窗口，第 7 天剩 0 不再列
        assert_eq!(paris["arrivalRows"].as_array().unwrap().len(), 7);
        assert_eq!(paris["arrivalRows"][6]["cbtMinute"], 5 * 60);
        // 行前 4 天每天提前 1 小时：起床后 3.5 小时求光，睡前 2 小时调暗
        let prepared = plan_for(7 * 3600, 4, 60, "automatic");
        let row = &prepared["rows"][0];
        assert_eq!(row["wakeMinute"], 360);
        assert_eq!(
            row["light"]["seek"],
            json!({"startMinute": 360, "endMinute": 570})
        );
        assert_eq!(
            row["light"]["avoid"],
            json!({"startMinute": 1200, "endMinute": 1320})
        );
        assert_eq!(row["light"]["avoidKind"], "dim");
        assert_eq!(prepared["remainingShiftMinutes"], -180);
        assert_eq!(prepared["arrivalRows"].as_array().unwrap().len(), 3);
        // 旧金山 → 北京
        let beijing = plan_for(15 * 3600, 0, 60, "automatic");
        assert_eq!(beijing["direction"], "delay");
        assert_eq!(beijing["targetShiftMinutes"], 540);
        let day0 = &beijing["arrivalRows"][0];
        assert_eq!(day0["cbtMinute"], 19 * 60);
        assert_eq!(
            day0["seek"],
            json!({"startMinute": 17 * 60, "endMinute": 19 * 60})
        );
        assert_eq!(
            day0["avoid"],
            json!({"startMinute": 19 * 60, "endMinute": 22 * 60})
        );
        // 推后每天最多 2 小时：每日 120 时 5 天收敛（540 → 420 → 300 → 180 → 60 → 0）
        let fast = plan_for(15 * 3600, 0, 120, "automatic");
        assert_eq!(fast["arrivalRows"].as_array().unwrap().len(), 5);
        // 推后到后半夜：CBTmin 落进睡眠时窗口不给
        let late = &fast["arrivalRows"][4];
        assert_eq!(late["remainingMinutes"], 60);
        assert_eq!(late["cbtMinute"], 3 * 60);
        assert!(late["seek"].is_null() && late["avoid"].is_null());
        // 北京 → 旧金山：东行 9 时区，自动改走推后 15 小时；用户点名「提前」就照提前
        assert_eq!(
            plan_for(-15 * 3600, 0, 60, "automatic")["targetShiftMinutes"],
            900
        );
        assert_eq!(
            plan_for(-15 * 3600, 0, 60, "earlier")["targetShiftMinutes"],
            -540
        );
        // 东行 7 时区仍提前
        assert_eq!(
            plan_for(7 * 3600, 0, 60, "automatic")["targetShiftMinutes"],
            -420
        );
        // 时差为零：没有方向、没有落地窗口
        let none = plan_for(0, 2, 60, "automatic");
        assert_eq!(none["direction"], "none");
        assert!(none["arrivalRows"].as_array().unwrap().is_empty());
        assert!(none["rows"][0]["light"].is_null());
        // 睡眠不足 7 小时：CBTmin 取起床前 2.5 小时
        let short = plan(
            &json!({"trip": {"id": "0cbad259-a750-4086-a50f-83cfa0c1c52d", "name": "t", "originTimeZoneID": "A", "destinationTimeZoneID": "B",
            "departureUnix": 1_789_000_000.0, "arrivalUnix": 1_789_030_000.0, "sleepMinute": 60, "wakeMinute": 420,
            "preparationDays": 0, "dailyShiftMinutes": 60, "direction": "automatic"},
            "timeZonesValid": true, "offsetDifferenceAtArrival": 7 * 3600, "offsetDifferenceAtDeparture": 7 * 3600}),
        );
        assert_eq!(short["cbtOffsetMinutes"], 150);
    }

    #[test]
    fn random_trips_produce_consistent_sleep_schedules() {
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
        let iterations: u64 = std::env::var("MEANTIME_FUZZ_ITERATIONS")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(5_000);
        let seed_offset: u64 = std::env::var("MEANTIME_FUZZ_SEED")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(0);
        let mut rng = Xor(0x7124_7124_5EED_0001_u64.wrapping_add(seed_offset));
        for i in 0..iterations {
            let sleep = rng.below(1440) as i64;
            let mut wake = rng.below(1440) as i64;
            if wake == sleep {
                wake = (wake + 480) % 1440;
            }
            let days = rng.below(8) as i64;
            let daily = [15, 30, 60, 90, 120][rng.below(5) as usize];
            let direction = ["automatic", "earlier", "later"][rng.below(3) as usize];
            // 时差按 15 分钟格，覆盖 ±26 小时（含跨日界线两边的极端）。
            let difference = (rng.below(209) as i64 - 104) * 900;
            let departure = 1_789_000_000.0 + rng.below(1_000_000) as f64;
            let input = json!({"trip": {"id": "7f5a1c2e-3d4b-4a5f-8e9d-0c1b2a3f4e5d", "name": "t", "originTimeZoneID": "A", "destinationTimeZoneID": "B",
                "departureUnix": departure, "arrivalUnix": departure + rng.below(90_000) as f64,
                "sleepMinute": sleep, "wakeMinute": wake, "preparationDays": days, "dailyShiftMinutes": daily, "direction": direction},
                "timeZonesValid": true, "offsetDifferenceAtArrival": difference, "offsetDifferenceAtDeparture": difference});
            let out = plan(&input);
            let tag = format!("#{i} 时差 {difference}s 方向 {direction} 天数 {days} 每日 {daily} 作息 {sleep}–{wake}");
            assert!(out["error"].is_null(), "{tag}：{}", out["error"]);
            let target = out["targetShiftMinutes"].as_i64().unwrap();
            let advance = (difference / 60).rem_euclid(1440);
            match direction {
                "earlier" => assert!(target <= 0 && (-target) == advance, "{tag}：目标 {target}"),
                "later" => assert!(
                    target >= 0 && target == if advance == 0 { 0 } else { 1440 - advance },
                    "{tag}：目标 {target}"
                ),
                _ => {
                    // 自动方向取较短一边，例外：短边是 ≥ 8 小时的提前时改走推后（东行 ≥ 8 时区，Eastman & Burgess 2009）。
                    if (480..=720).contains(&advance) {
                        assert_eq!(
                            target,
                            1440 - advance,
                            "{tag}：东行 ≥ 8 小时该推后，目标 {target}"
                        );
                    } else {
                        assert!(
                            target.abs() <= 720,
                            "{tag}：自动方向该取较短一边，目标 {target}"
                        );
                    }
                    assert!(
                        (target - advance).rem_euclid(1440) == 0
                            || (target + advance).rem_euclid(1440) == 0,
                        "{tag}：目标 {target} 与时差不同余"
                    );
                }
            }
            let rows = out["rows"].as_array().unwrap();
            assert_eq!(rows.len(), days as usize, "{tag}");
            let duration = (wake - sleep).rem_euclid(1440);
            assert_eq!(out["sleepDurationMinutes"], duration, "{tag}");
            let mut previous = 0i64;
            for (k, row) in rows.iter().enumerate() {
                let shifted = row["shiftMinutes"].as_i64().unwrap();
                assert!(
                    shifted.abs() <= target.abs() && shifted.signum() * target.signum() >= 0,
                    "{tag}：第 {k} 天推移 {shifted} 越过目标 {target}"
                );
                assert!(
                    (shifted - previous).abs() <= daily,
                    "{tag}：第 {k} 天一步推了 {}",
                    shifted - previous
                );
                assert!(shifted.abs() >= previous.abs(), "{tag}：第 {k} 天倒退");
                previous = shifted;
                assert_eq!(
                    row["relativeDay"].as_i64().unwrap(),
                    k as i64 - days,
                    "{tag}"
                );
                let s = row["sleepMinute"].as_i64().unwrap();
                let w = row["wakeMinute"].as_i64().unwrap();
                let so = row["sleepDayOffset"].as_i64().unwrap();
                let wo = row["wakeDayOffset"].as_i64().unwrap();
                assert!(
                    (0..1440).contains(&s) && (0..1440).contains(&w),
                    "{tag}：第 {k} 天分钟越界"
                );
                // 指定方向时目标可达 ±23 小时 45 分，再加最长 23 小时 59 分的「睡眠」，醒来最多落到后天。
                assert!(
                    (-1..=1).contains(&so) && (-1..=2).contains(&wo),
                    "{tag}：第 {k} 天日偏移 {so}/{wo}"
                );
                let length = (wo * 1440 + w) - (so * 1440 + s);
                assert_eq!(
                    length, duration,
                    "{tag}：第 {k} 天睡眠时长 {length} ≠ {duration}"
                );
            }
            let moved = rows
                .last()
                .map(|r| r["shiftMinutes"].as_i64().unwrap())
                .unwrap_or(0);
            assert_eq!(
                out["remainingShiftMinutes"].as_i64().unwrap(),
                target - moved,
                "{tag}：剩余"
            );
        }
    }
}

#[cfg(test)]
mod fixed_time_tests {
    use super::*;
    use serde_json::json;

    fn id(n: u8) -> String {
        format!("0000000{n}-0000-4000-8000-000000000000")
    }

    #[test]
    fn fixed_times_are_only_converted_never_advised() {
        // 家里 8:00 与 21:00 两条，目的地比家早 9 小时（东京 vs 伦敦）：
        // 8:00 → 17:00 当天；21:00 → 6:00 次日。夜间标记只看当地钟点。
        let result = fixed_times(&json!({
            "times":[{"id":id(1),"label":"服药","minute":480},{"id":id(2),"label":"和家里通话","minute":1260}],
            "converted":[
                [{"date":"2026-10-01","minute":1020,"dayOffset":0},{"date":"2026-10-02","minute":1020,"dayOffset":0}],
                [{"date":"2026-10-02","minute":360,"dayOffset":1},{"date":"2026-10-03","minute":360,"dayOffset":1}]
            ]
        }));
        let rows = result["rows"].as_array().unwrap();
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0]["label"], json!("服药"));
        assert_eq!(rows[0]["homeMinute"], json!(480));
        assert_eq!(rows[0]["days"][0]["minute"], json!(1020));
        assert_eq!(rows[0]["days"][0]["dayOffset"], json!(0));
        assert_eq!(rows[0]["days"][0]["night"], json!(false));
        assert_eq!(rows[1]["days"][0]["dayOffset"], json!(1));
        // 6:00 不算夜间（夜间是 22:00–06:00，左闭右开）。
        assert_eq!(rows[1]["days"][0]["night"], json!(false));
        // 输出里没有任何「建议 / 应该」字样的字段：这一条只换算。
        assert!(result["rows"][0].get("advice").is_none());
        // 两天钟点相同 → 并成一段。
        assert_eq!(rows[0]["segments"].as_array().unwrap().len(), 1);
        assert_eq!(rows[0]["segments"][0]["fromDate"], json!("2026-10-01"));
        assert_eq!(rows[0]["segments"][0]["toDate"], json!("2026-10-02"));
        assert_eq!(rows[0]["segments"][0]["days"], json!(2));
    }

    #[test]
    fn a_clock_change_at_the_destination_starts_a_second_segment() {
        // 伦敦 10-25 退夏令时：家里同一个 9:00 在当地 10-25 之后少一小时 → 两段，第二段从换钟那天起。
        let result = fixed_times(&json!({
            "times":[{"id":id(1),"label":"晨会","minute":540}],
            "converted":[[
                {"date":"2026-10-23","minute":600,"dayOffset":0},
                {"date":"2026-10-24","minute":600,"dayOffset":0},
                {"date":"2026-10-25","minute":540,"dayOffset":0},
                {"date":"2026-10-26","minute":540,"dayOffset":0}
            ]]
        }));
        let segments = result["rows"][0]["segments"].as_array().unwrap();
        assert_eq!(segments.len(), 2);
        assert_eq!(segments[0]["days"], json!(2));
        assert_eq!(segments[1]["fromDate"], json!("2026-10-25"));
        assert_eq!(segments[1]["minute"], json!(540));
        assert_eq!(segments[1]["days"], json!(2));
    }

    #[test]
    fn bad_entries_are_dropped_one_by_one_and_the_list_is_capped() {
        let mut times: Vec<Value> = (1..=9)
            .map(|n| json!({"id":id(n as u8),"label":format!("第{n}条"),"minute":600}))
            .collect();
        times.push(json!({"id":"not-a-uuid","label":"坏 id","minute":600}));
        times.push(json!({"id":id(1),"label":"","minute":600}));
        times.push(json!({"id":id(1),"label":"越界","minute":1440}));
        let result = fixed_times(&json!({"times":times,"converted":[]}));
        // 只留前 8 条合法的；坏的三条丢掉。
        assert_eq!(result["rows"].as_array().unwrap().len(), 8);
        assert_eq!(result["cap"], json!(8));
        assert_eq!(result["dropped"], json!(4));
        // 名字裁到 40 字。
        let long = fixed_times(&json!({"times":[{"id":id(1),"label":"名".repeat(60),"minute":0}]}));
        assert_eq!(
            long["rows"][0]["label"].as_str().unwrap().chars().count(),
            40
        );
        // 没有换算结果时也不炸，days 与 segments 都是空表。
        assert_eq!(long["rows"][0]["days"], json!([]));
        assert_eq!(long["rows"][0]["segments"], json!([]));
    }

    #[test]
    fn away_blocks_cover_everything_outside_the_working_window() {
        let result = away_blocks(&json!({"startMinute":540,"endMinute":1080,
            "days":[{"date":"2026-10-01","weekend":false},{"date":"2026-10-03","weekend":true}]}));
        let blocks = result["blocks"].as_array().unwrap();
        assert_eq!(blocks.len(), 3);
        assert_eq!(
            blocks[0],
            json!({"date":"2026-10-01","startMinute":0,"endMinute":540,"wholeDay":false})
        );
        assert_eq!(
            blocks[1],
            json!({"date":"2026-10-01","startMinute":1080,"endMinute":1440,"wholeDay":false})
        );
        assert_eq!(
            blocks[2],
            json!({"date":"2026-10-03","startMinute":0,"endMinute":1440,"wholeDay":true})
        );
        // 夜班（22:00–06:00）：不工作的是白天那一段。
        let night = away_blocks(&json!({"startMinute":1320,"endMinute":360,
            "days":[{"date":"2026-10-01","weekend":false}]}));
        assert_eq!(
            night["blocks"][0],
            json!({"date":"2026-10-01","startMinute":360,"endMinute":1320,"wholeDay":false})
        );
        // 整天工作（0–1440）时只剩下休息日；起止相同当整天不工作。
        let all_day = away_blocks(&json!({"startMinute":0,"endMinute":1440,
            "days":[{"date":"2026-10-01","weekend":false}]}));
        assert_eq!(all_day["blocks"].as_array().unwrap().len(), 0);
        let same = away_blocks(&json!({"startMinute":540,"endMinute":540,
            "days":[{"date":"2026-10-01","weekend":false}]}));
        assert_eq!(same["blocks"][0]["wholeDay"], json!(true));
    }

    #[test]
    fn the_status_line_drops_the_parts_it_does_not_have() {
        let full = status_line(
            &json!({"place":"东京","zoneAbbreviation":"JST","offsetText":"UTC+9",
            "localWindowText":"9:00–18:00","counterpartWindowText":"次日 2:00–11:00"}),
        );
        assert_eq!(full["place"], json!("东京"));
        assert_eq!(full["zoneAbbreviation"], json!("JST"));
        assert_eq!(full["counterpartWindowText"], json!("次日 2:00–11:00"));
        let no_counterpart = status_line(
            &json!({"place":"东京","zoneAbbreviation":"JST","offsetText":"UTC+9",
            "localWindowText":"9:00–18:00"}),
        );
        assert_eq!(no_counterpart["counterpartWindowText"], json!(""));
        let only_offset = status_line(&json!({"place":"卡萨布兰卡","offsetText":"UTC+0"}));
        assert_eq!(only_offset["offsetText"], json!("UTC+0"));
        assert_eq!(status_line(&json!({"place":"  "}))["place"], json!(""));
    }
}

#[cfg(test)]
mod nights_tests {
    use super::*;
    fn trip() -> Value {
        json!({"id":"0cbad259-a750-4086-a50f-83cfa0c1c52d","name":"Tokyo","originTimeZoneID":"America/Los_Angeles","destinationTimeZoneID":"Asia/Tokyo","departureUnix":1789000000.0,"arrivalUnix":1789050000.0,"sleepMinute":1380,"wakeMinute":420,"preparationDays":3,"dailyShiftMinutes":60,"direction":"automatic"})
    }
    fn input(difference: i64) -> Value {
        json!({"trip":trip(),"timeZonesValid":true,"offsetDifferenceAtArrival":difference,"offsetDifferenceAtDeparture":difference,"originArrivalDay":20000,"destinationArrivalDay":20001})
    }
    fn nights_input() -> Value {
        let base = 1_790_078_400.0;
        json!({"departure":base+84_000.0,"arrival":base+126_000.0,"reference":base-86_400.0,"marks":false,
            "departureDate":"2026-09-23","arrivalDate":"2026-09-24",
            "prep":[{"date":"2026-09-22","start":base,"end":base+86_400.0,"shiftMinutes":60,
                "sleep":[base+43_200.0,base+72_000.0],"seek":[base+36_000.0,base+43_200.0],
                "avoid":[base+72_000.0,base+82_800.0],"avoidKind":"dark","checks":{"nonexistentTime":false}}],
            "departureNight":{"date":"2026-09-22","start":base,"end":base+86_400.0},
            "arrivalNight":{"date":"2026-09-24","start":base+108_000.0,"end":base+194_400.0},
            "after":[{"date":"2026-09-24","start":base+108_000.0,"end":base+194_400.0,"k":0,
                "sleep":[base+147_600.0,base+176_400.0],"remainingMinutes":300}],"windows":[]})
    }
    fn night_result(input: &Value) -> Value {
        nights(input).unwrap()
    }
    fn flight_lane(output: &Value) -> &Value {
        output["lanes"]
            .as_array()
            .unwrap()
            .iter()
            .find(|l| l["kind"] == "flight")
            .unwrap()
    }

    #[test]
    fn nights_r1_real_dst_duration_controls_positions() {
        let mut i = nights_input();
        let start = i["prep"][0]["start"].as_f64().unwrap();
        i["prep"][0]["end"] = json!(start + 90_000.0);
        i["departure"] = json!(start + 89_000.0);
        i["departureNight"]["end"] = json!(start + 90_000.0);
        let r = night_result(&i);
        assert!((r["lanes"][0]["sleep"][0].as_f64().unwrap() - 43_200.0 / 90_000.0).abs() < 1e-12);
    }
    #[test]
    fn nights_r2_preparation_clips_sleep_light_and_sky_at_departure() {
        let mut i = nights_input();
        let start = i["prep"][0]["start"].as_f64().unwrap();
        i["departure"] = json!(start + 60_000.0);
        let r = night_result(&i);
        let l = &r["lanes"][0];
        assert_eq!(l["sleep"], json!([0.5, 60_000.0 / 86_400.0]));
        assert_eq!(l["avoid"], json!([]));
        assert_eq!(l["air"], json!([[60_000.0 / 86_400.0, 1.0]]));
        assert_eq!(l["departure"], json!(60_000.0 / 86_400.0));
    }
    #[test]
    fn nights_r3_flight_is_present_with_origin_date_and_two_sky_parts() {
        let mut i = nights_input();
        let start = i["prep"][0]["start"].as_f64().unwrap();
        i["prep"] = json!([]);
        i["departure"] = json!(start + 20_000.0);
        i["arrival"] = json!(start + 188_000.0);
        i["arrivalDate"] = json!("2026-09-25");
        i["after"][0]["start"] = json!(start + 194_400.0);
        i["after"][0]["end"] = json!(start + 280_800.0);
        let r = night_result(&i);
        let l = flight_lane(&r);
        assert_eq!(l["date"], json!("2026-09-23"));
        assert_eq!(l["parts"].as_array().unwrap().len(), 2);
        assert_eq!(l["parts"][0]["to"], json!(20_000.0 / 86_400.0));
        assert_eq!(l["parts"][1]["from"], json!(80_000.0 / 86_400.0));
    }
    #[test]
    fn nights_r4_landing_in_afternoon_clips_first_arrival_night() {
        let r = night_result(&nights_input());
        let l = &r["lanes"][2];
        assert_eq!(l["arrival"], json!(18_000.0 / 86_400.0));
        assert_eq!(l["parts"][0]["from"], l["arrival"]);
        assert_eq!(l["air"], json!([[0.0, 18_000.0 / 86_400.0]]));
    }
    #[test]
    fn nights_r5_windows_belong_to_start_frame_and_clip_to_landing() {
        let mut i = nights_input();
        let start = i["prep"][0]["start"].as_f64().unwrap();
        i["windows"] = json!([{"day":0,"kind":"seek","span":[start+120_000.0,start+132_000.0]},
            {"day":0,"kind":"seek","span":[start+135_000.0,start+140_000.0]},
            {"day":0,"kind":"avoid","span":[start-200_000.0,start-190_000.0]}]);
        let r = night_result(&i);
        let l = &r["lanes"][2];
        assert_eq!(l["seek"].as_array().unwrap().len(), 2);
        assert_eq!(
            l["seekRange"],
            json!([start + 126_000.0, start + 140_000.0])
        );
        assert_eq!(l["avoid"], json!([]));
    }
    #[test]
    fn nights_r6_labels_distinguish_shift_flight_remaining_and_aligned() {
        let mut i = nights_input();
        let r = night_result(&i);
        assert_eq!(r["lanes"][0]["label"], json!({"kind":"shift","minutes":60}));
        assert_eq!(
            flight_lane(&r)["label"],
            json!({"kind":"flight","minutes":700.0})
        );
        assert_eq!(
            r["lanes"][2]["label"],
            json!({"kind":"remaining","minutes":300})
        );
        i["after"][0]["remainingMinutes"] = json!(-59);
        assert_eq!(
            night_result(&i)["lanes"][2]["label"],
            json!({"kind":"aligned"})
        );
    }
    #[test]
    fn nights_r7_nearby_flight_parts_split_out_the_morning_landing() {
        let mut i = nights_input();
        let start = i["prep"][0]["start"].as_f64().unwrap();
        i["prep"] = json!([]);
        i["departure"] = json!(start + 80_000.0);
        i["arrival"] = json!(start + 188_000.0);
        i["arrivalDate"] = json!("2026-09-25");
        i["after"][0]["date"] = json!("2026-09-25");
        i["after"][0]["start"] = json!(start + 194_400.0);
        i["after"][0]["end"] = json!(start + 280_800.0);
        let r = night_result(&i);
        let flight = flight_lane(&r);
        assert_eq!(flight["parts"].as_array().unwrap().len(), 1);
        assert!(flight["arrival"].is_null());
        assert_eq!(r["lanes"][1]["kind"], json!("after"));
        assert_eq!(r["lanes"][1]["date"], json!("2026-09-24"));
        assert_eq!(r["lanes"][1]["arrival"], json!(80_000.0 / 86_400.0));
    }
    #[test]
    fn nights_r8_reference_is_unique_and_follows_flight_elapsed_fraction() {
        let mut i = nights_input();
        let dep = i["departure"].as_f64().unwrap();
        let arr = i["arrival"].as_f64().unwrap();
        i["reference"] = json!((dep + arr) / 2.0);
        let r = night_result(&i);
        assert_eq!(r["selected"], json!(1));
        assert_eq!(flight_lane(&r)["reference"], json!(0.5));
        assert_eq!(
            r["lanes"]
                .as_array()
                .unwrap()
                .iter()
                .filter(|l| !l["reference"].is_null())
                .count(),
            1
        );
        i["reference"] = json!(arr + 1_000_000.0);
        assert_eq!(night_result(&i)["selected"], json!(2));
    }
    #[test]
    fn nights_after_light_keeps_the_engine_dim_kind() {
        let mut i = nights_input();
        let start = i["after"][0]["start"].as_f64().unwrap();
        i["windows"] =
            json!([{ "kind":"avoid", "span":[start+24_000.0,start+30_000.0], "avoidKind":"dim" }]);
        let r = night_result(&i);
        assert_eq!(r["lanes"][2]["avoidKind"], json!("dim"));
    }
    #[test]
    fn nights_r9_sky_and_frame_lines_match_the_shared_sky_functions() {
        let mut i = nights_input();
        i["origin"] = json!({"latitude":34.05,"longitude":-118.24});
        i["marks"] = json!(true);
        let r = night_result(&i);
        let p = &r["lanes"][0]["parts"][0];
        let start = i["prep"][0]["start"].as_f64().unwrap();
        let end = i["departure"].as_f64().unwrap();
        let expected: Vec<_> = crate::sky::lane_stops(start, end, 34.05, -118.24, 10.0)
            .into_iter()
            .map(|(at, color)| json!({"at":at,"color":color}))
            .collect();
        assert_eq!(p["stops"], json!(expected));
        assert_eq!(p["lineStops"].as_array().unwrap().len(), expected.len());
        assert!(!p["marks"].as_array().unwrap().is_empty());
        assert_eq!(r["lanes"][2]["parts"][0]["stops"], json!([]));
    }
    #[test]
    fn nights_r10_bad_frames_dates_and_excessive_rows_never_panic() {
        let mut i = nights_input();
        i["prep"][0]["end"] = i["prep"][0]["start"].clone();
        assert!(nights(&i).is_err());
        i = nights_input();
        i["departure"] = json!(-100_000_000_000.0);
        assert!(nights(&i).is_err());
        i = nights_input();
        i["prep"] = json!(vec![i["prep"][0].clone(); 33]);
        assert!(nights(&i).is_err());
        i = nights_input();
        i["prep"][0]["date"] = json!("2026-02-31");
        assert!(nights(&i).is_err());
    }
    #[test]
    fn nights_r11_quiet_tail_merges_but_landing_and_reference_stay_separate() {
        let mut i = nights_input();
        let first = i["after"][0].clone();
        let start = first["start"].as_f64().unwrap();
        let mut rows = vec![first.clone()];
        for k in 1..=3 {
            let mut row = first.clone();
            row["date"] = json!(format!("2026-09-{}", 24 + k));
            row["start"] = json!(start + k as f64 * 86_400.0);
            row["end"] = json!(start + (k + 1) as f64 * 86_400.0);
            row["remainingMinutes"] = json!(300 - k * 60);
            rows.push(row);
        }
        i["after"] = json!(rows);
        let r = night_result(&i);
        let quiet = r["lanes"].as_array().unwrap().last().unwrap();
        assert_eq!(
            quiet["label"],
            json!({"kind":"quiet","nights":3,"minutes":240})
        );
        assert_eq!(quiet["dateTo"], json!("2026-09-27"));
        i["reference"] = json!(start + 2.5 * 86_400.0);
        let r = night_result(&i);
        assert_eq!(r["lanes"].as_array().unwrap().len(), 6);
    }
    #[test]
    fn quiet_tail_preserves_dst_and_warning_nights() {
        let mut i = nights_input();
        let first = i["after"][0].clone();
        let start = first["start"].as_f64().unwrap();
        let mut rows = vec![first.clone()];
        for k in 1..=3 {
            let mut row = first.clone();
            row["date"] = json!(format!("2026-09-{}", 24 + k));
            row["start"] = json!(start + k as f64 * 86_400.0);
            row["end"] = json!(start + (k + 1) as f64 * 86_400.0);
            rows.push(row);
        }
        rows[2]["end"] = json!(rows[2]["end"].as_f64().unwrap() - 3_600.0);
        rows[2]["checks"] = json!({"elapsedSleepMinutes":420});
        i["after"] = json!(rows.clone());
        let r = night_result(&i);
        assert_eq!(r["lanes"].as_array().unwrap().len(), 6);
        assert_eq!(r["lanes"][4]["checks"]["elapsedSleepMinutes"], 420);
        rows[2]["end"] = json!(start + 3.0 * 86_400.0);
        rows[2]["checks"] = json!({"repeatedTime":true});
        i["after"] = json!(rows);
        assert_eq!(night_result(&i)["lanes"].as_array().unwrap().len(), 6);
    }
    #[test]
    fn clipped_sleep_keeps_open_endpoint_facts() {
        let mut i = nights_input();
        let start = i["prep"][0]["start"].as_f64().unwrap();
        let departure = i["departure"].as_f64().unwrap();
        i["prep"][0]["sleep"] = json!([start - 1_800.0, departure + 1_800.0]);
        let r = night_result(&i);
        assert_eq!(r["lanes"][0]["sleepClipStart"], true);
        assert_eq!(r["lanes"][0]["sleepClipEnd"], true);
        i["prep"][0]["sleep"] = json!([start + 1_800.0, departure - 1_800.0]);
        let r = night_result(&i);
        assert_eq!(r["lanes"][0]["sleepClipStart"], false);
        assert_eq!(r["lanes"][0]["sleepClipEnd"], false);
    }
    #[test]
    fn trip_snapshots_survive_roundtrip_and_bad_metadata_does_not_corrupt_a_trip() {
        let mut t = trip();
        t["destinationPlace"] =
            json!({"name":"大阪","latitude":34.69,"longitude":135.5,"countryCode":"JP"});
        let stored = json!({"version":1,"trips":[t.clone()],"autoSwitchEnabled":false});
        let r = decode(Some(&stored.to_string()));
        assert_eq!(r["hadCorruption"], false);
        assert_eq!(r["trips"][0]["destinationPlace"], t["destinationPlace"]);
        for bad in [
            json!({"name":"大阪","latitude":91,"longitude":135.5}),
            json!({"name":"bad\n","latitude":0,"longitude":0}),
            json!({"name":"大阪","latitude":0,"longitude":0,"countryCode":"jp"}),
            json!(42),
        ] {
            t["destinationPlace"] = bad;
            let r = decode(Some(
                &json!({"version":1,"trips":[t.clone()],"autoSwitchEnabled":false}).to_string(),
            ));
            assert_eq!(r["hadCorruption"], false);
            assert_eq!(r["rejectedCount"], 0);
            assert!(r["trips"][0]["destinationPlace"].is_null());
        }
    }

    fn whole_trip_input(
        origin_offset: i64,
        destination_offset: i64,
        departure_minute: i64,
        duration: i64,
        prep_count: i64,
    ) -> Value {
        let civil_midnight = 1_791_244_800.0;
        let departure = civil_midnight - origin_offset as f64 + departure_minute as f64 * 60.0;
        let arrival = departure + duration as f64 * 60.0;
        let destination_day =
            ((arrival + destination_offset as f64 - civil_midnight) / 86_400.0).floor() as i64;
        let destination_minute = ((arrival + destination_offset as f64 - civil_midnight)
            .rem_euclid(86_400.0)
            / 60.0) as i64;
        let mut planner_input = input(destination_offset - origin_offset);
        planner_input["trip"]["departureUnix"] = json!(departure);
        planner_input["trip"]["arrivalUnix"] = json!(arrival);
        planner_input["trip"]["preparationDays"] = json!(prep_count);
        let plan = plan(&planner_input);
        let frame = |day: i64, offset: i64| {
            let start = civil_midnight + day as f64 * 86_400.0 + 43_200.0 - offset as f64;
            json!({"date":if 6+day > 0 { format!("2026-10-{:02}",6+day) } else { format!("2026-09-{:02}",36+day) },"start":start,"end":start+86_400.0})
        };
        let clock = |day: i64, minute: i64, offset: i64| {
            civil_midnight + day as f64 * 86_400.0 + minute as f64 * 60.0 - offset as f64
        };
        let span = |day: i64, window: &Value, offset: i64, preparation: bool| {
            let Some(a) = window["startMinute"].as_i64() else {
                return Value::Null;
            };
            let b = window["endMinute"].as_i64().unwrap();
            let start_day = day + i64::from(preparation && a < 720);
            let end_day = start_day + i64::from(b <= a);
            json!([clock(start_day, a, offset), clock(end_day, b, offset)])
        };
        let prep: Vec<_> = plan["rows"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|_| plan["targetShiftMinutes"] != 0)
            .map(|row| {
                let day = row["relativeDay"].as_i64().unwrap();
                let mut out = frame(day, origin_offset);
                out["shiftMinutes"] = row["shiftMinutes"].clone();
                out["sleep"] = json!([
                    clock(
                        day + row["sleepDayOffset"].as_i64().unwrap(),
                        row["sleepMinute"].as_i64().unwrap(),
                        origin_offset
                    ),
                    clock(
                        day + row["wakeDayOffset"].as_i64().unwrap(),
                        row["wakeMinute"].as_i64().unwrap(),
                        origin_offset
                    )
                ]);
                out["seek"] = span(day, &row["light"]["seek"], origin_offset, true);
                out["avoid"] = span(day, &row["light"]["avoid"], origin_offset, true);
                out["avoidKind"] = row["light"]["avoidKind"].clone();
                out
            })
            .collect();
        let arrival_rows = plan["arrivalRows"].as_array().unwrap();
        let count = arrival_rows.len().max(1);
        let after: Vec<_> = (0..count)
            .map(|k| {
                let day = destination_day + k as i64;
                let mut out = frame(day, destination_offset);
                out["k"] = json!(k);
                out["remainingMinutes"] = arrival_rows
                    .get(k)
                    .map(|r| r["remainingMinutes"].clone())
                    .unwrap_or(json!(0));
                out["sleep"] = json!([
                    clock(day, 1380, destination_offset),
                    clock(day + 1, 420, destination_offset)
                ]);
                out
            })
            .collect();
        let windows: Vec<_> = arrival_rows
            .iter()
            .enumerate()
            .flat_map(|(k, row)| {
                let mut out = vec![];
                for kind in ["seek", "avoid"] {
                    let span = span(
                        destination_day + k as i64,
                        &row[kind],
                        destination_offset,
                        false,
                    );
                    if !span.is_null() {
                        out.push(json!({"day":k,"kind":kind,"span":span}));
                    }
                }
                out
            })
            .collect();
        json!({"departure":departure,"arrival":arrival,"departureDate":"2026-10-06","arrivalDate":format!("2026-10-{:02}",6+destination_day),
            "departureNight":frame(if departure_minute<720 {-1}else{0},origin_offset),
            "arrivalNight":frame(destination_day-i64::from(destination_minute<720),destination_offset),
            "reference":departure-10.0*86_400.0,"marks":false,"prep":prep,"after":after,"windows":windows})
    }
    #[test]
    fn nights_whole_west_trip_has_seven_rows_and_three_quiet_nights() {
        let r = night_result(&whole_trip_input(-7 * 3600, 9 * 3600, 680, 705, 3));
        assert_eq!(r["lanes"].as_array().unwrap().len(), 7);
        assert_eq!(r["lanes"][6]["label"]["nights"], 3);
        assert_eq!(r["lanes"][2]["departure"], json!(1400.0 / 1440.0));
    }
    #[test]
    fn nights_whole_east_trip_clips_morning_light_to_landing() {
        let r = night_result(&whole_trip_input(-4 * 3600, 2 * 3600, 1110, 435, 3));
        let flight = flight_lane(&r);
        assert_eq!(flight["parts"].as_array().unwrap().len(), 2);
        assert_eq!(flight["arrival"], json!(1185.0 / 1440.0));
        assert_eq!(flight["seek"][0][0], flight["arrival"]);
        assert_eq!(r["lanes"].as_array().unwrap().len(), 7);
    }
    #[test]
    fn nights_whole_east8_trip_keeps_the_engine_delay_direction_and_fifteen_rows() {
        let i = whole_trip_input(-7 * 3600, 3600, 1140, 625, 3);
        let r = night_result(&i);
        assert_eq!(i["prep"][0]["shiftMinutes"], 60);
        assert_eq!(i["after"].as_array().unwrap().len(), 13);
        assert_eq!(r["lanes"].as_array().unwrap().len(), 15);
    }
    #[test]
    fn nights_whole_zero_difference_trip_has_only_flight_and_first_night() {
        let r = night_result(&whole_trip_input(-7 * 3600, -7 * 3600, 680, 180, 3));
        assert_eq!(r["lanes"].as_array().unwrap().len(), 2);
        assert_eq!(r["lanes"][0]["kind"], "flight");
        assert_eq!(r["lanes"][1]["label"]["kind"], "aligned");
    }
    #[test]
    fn nights_whole_no_preparation_trip_starts_with_flight() {
        let r = night_result(&whole_trip_input(-7 * 3600, 9 * 3600, 680, 705, 0));
        assert_eq!(r["lanes"][0]["kind"], "flight");
        assert_eq!(r["lanes"].as_array().unwrap().len(), 7);
    }

    /// 原生历法导出的整趟行程与另一套固定偏移公历算出的事实一致。
    #[test]
    fn foundation_west_fixture_matches_independent_civil_facts_and_geometry() {
        let input: Value = serde_json::from_str(
            r#"{
  "after" : [
    {
      "checks" : {
        "elapsedSleepMinutes" : 480,
        "nonexistentTime" : false,
        "overlapsDeparture" : false,
        "repeatedTime" : false
      },
      "date" : "2026-10-07",
      "end" : 1791428400,
      "k" : 0,
      "remainingMinutes" : 300,
      "sleep" : [
        1791381600,
        1791410400
      ],
      "start" : 1791342000
    },
    {
      "checks" : {
        "elapsedSleepMinutes" : 480,
        "nonexistentTime" : false,
        "overlapsDeparture" : false,
        "repeatedTime" : false
      },
      "date" : "2026-10-08",
      "end" : 1791514800,
      "k" : 1,
      "remainingMinutes" : 240,
      "sleep" : [
        1791468000,
        1791496800
      ],
      "start" : 1791428400
    },
    {
      "checks" : {
        "elapsedSleepMinutes" : 480,
        "nonexistentTime" : false,
        "overlapsDeparture" : false,
        "repeatedTime" : false
      },
      "date" : "2026-10-09",
      "end" : 1791601200,
      "k" : 2,
      "remainingMinutes" : 180,
      "sleep" : [
        1791554400,
        1791583200
      ],
      "start" : 1791514800
    },
    {
      "checks" : {
        "elapsedSleepMinutes" : 480,
        "nonexistentTime" : false,
        "overlapsDeparture" : false,
        "repeatedTime" : false
      },
      "date" : "2026-10-10",
      "end" : 1791687600,
      "k" : 3,
      "remainingMinutes" : 120,
      "sleep" : [
        1791640800,
        1791669600
      ],
      "start" : 1791601200
    },
    {
      "checks" : {
        "elapsedSleepMinutes" : 480,
        "nonexistentTime" : false,
        "overlapsDeparture" : false,
        "repeatedTime" : false
      },
      "date" : "2026-10-11",
      "end" : 1791774000,
      "k" : 4,
      "remainingMinutes" : 60,
      "sleep" : [
        1791727200,
        1791756000
      ],
      "start" : 1791687600
    }
  ],
  "arrival" : 1791353100,
  "arrivalDate" : "2026-10-07",
  "arrivalNight" : {
    "checks" : {
      "elapsedSleepMinutes" : 480,
      "nonexistentTime" : false,
      "overlapsDeparture" : false,
      "repeatedTime" : false
    },
    "date" : "2026-10-07",
    "end" : 1791428400,
    "sleep" : [
      1791381600,
      1791410400
    ],
    "start" : 1791342000
  },
  "departure" : 1791310800,
  "departureDate" : "2026-10-06",
  "departureNight" : {
    "date" : "2026-10-05",
    "end" : 1791313200,
    "start" : 1791226800
  },
  "destination" : {
    "latitude" : 35.68,
    "longitude" : 139.69
  },
  "marks" : false,
  "origin" : {
    "latitude" : 34.05,
    "longitude" : -118.24
  },
  "prep" : [
    {
      "avoid" : [
        1791126000,
        1791136800
      ],
      "avoidKind" : "dark",
      "checks" : {
        "elapsedSleepMinutes" : 480,
        "nonexistentTime" : false,
        "overlapsDeparture" : false,
        "repeatedTime" : false
      },
      "date" : "2026-10-03",
      "end" : 1791140400,
      "seek" : [
        1791090000,
        1791097200
      ],
      "shiftMinutes" : 60,
      "sleep" : [
        1791097200,
        1791126000
      ],
      "start" : 1791054000
    },
    {
      "avoid" : [
        1791216000,
        1791226800
      ],
      "avoidKind" : "dark",
      "checks" : {
        "elapsedSleepMinutes" : 480,
        "nonexistentTime" : false,
        "overlapsDeparture" : false,
        "repeatedTime" : false
      },
      "date" : "2026-10-04",
      "end" : 1791226800,
      "seek" : [
        1791180000,
        1791187200
      ],
      "shiftMinutes" : 120,
      "sleep" : [
        1791187200,
        1791216000
      ],
      "start" : 1791140400
    },
    {
      "avoid" : [
        1791306000,
        1791316800
      ],
      "avoidKind" : "dark",
      "checks" : {
        "elapsedSleepMinutes" : 480,
        "nonexistentTime" : false,
        "overlapsDeparture" : false,
        "repeatedTime" : false
      },
      "date" : "2026-10-05",
      "end" : 1791313200,
      "seek" : [
        1791270000,
        1791277200
      ],
      "shiftMinutes" : 180,
      "sleep" : [
        1791277200,
        1791306000
      ],
      "start" : 1791226800
    }
  ],
  "reference" : 1790967600,
  "windows" : [
    {
      "day" : 0,
      "kind" : "seek",
      "span" : [
        1791374400,
        1791381600
      ]
    },
    {
      "day" : 1,
      "kind" : "seek",
      "span" : [
        1791464400,
        1791468000
      ]
    }
  ]
}"#,
        )
        .unwrap();
        let expected = whole_trip_input(-7 * 3600, 9 * 3600, 680, 705, 3);
        for key in ["departure", "arrival"] {
            assert_eq!(input[key].as_f64(), expected[key].as_f64(), "{key}");
        }
        for key in ["departureDate", "arrivalDate"] {
            assert_eq!(input[key], expected[key], "{key}");
        }
        for key in ["departureNight", "arrivalNight"] {
            assert_eq!(input[key]["date"], expected[key]["date"]);
            for field in ["start", "end"] {
                assert_eq!(input[key][field].as_f64(), expected[key][field].as_f64());
            }
        }
        for key in ["prep", "after", "windows"] {
            let actual = input[key].as_array().unwrap();
            let wanted = expected[key].as_array().unwrap();
            assert_eq!(actual.len(), wanted.len(), "{key}");
            for (actual, wanted) in actual.iter().zip(wanted) {
                for (field, value) in wanted.as_object().unwrap() {
                    if value.is_number() {
                        assert_eq!(actual[field].as_f64(), value.as_f64(), "{key}.{field}");
                    } else if let Some(values) = value.as_array() {
                        let actual = actual[field].as_array().unwrap();
                        assert_eq!(actual.len(), values.len());
                        for (actual, wanted) in actual.iter().zip(values) {
                            assert_eq!(actual.as_f64(), wanted.as_f64(), "{key}.{field}");
                        }
                    } else {
                        assert_eq!(actual[field], *value, "{key}.{field}");
                    }
                }
            }
        }
        let output = night_result(&input);
        assert_eq!(output["lanes"].as_array().unwrap().len(), 7);
        assert_eq!(output["selected"], 0);
        assert_eq!(
            output["lanes"][2]["departure"].as_f64(),
            Some(1400.0 / 1440.0)
        );
        assert_eq!(
            output["lanes"][2]["avoidRange"],
            json!([1_791_306_000.0, 1_791_310_800.0])
        );
        assert_eq!(
            output["lanes"][6]["label"],
            json!({"kind":"quiet", "nights":3, "minutes":180})
        );
        assert_eq!(output["lanes"][6]["dateTo"], "2026-10-11");
        if let Ok(path) = std::env::var("MEANTIME_TRAVEL_NIGHTS_EXPORT") {
            std::fs::write(path, serde_json::to_string_pretty(&output).unwrap()).unwrap();
        }
    }

    #[test]
    fn random_travel_nights_keep_positions_windows_and_reference_inside_visible_parts() {
        let iterations = std::env::var("MEANTIME_FUZZ_ITERATIONS")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(150usize);
        let seed = std::env::var("MEANTIME_FUZZ_SEED")
            .ok()
            .and_then(|v| v.parse::<u64>().ok())
            .unwrap_or(0);
        let mut state = 0x77A9_E100_u64.wrapping_add(seed);
        let mut next = |limit: u64| {
            state = state
                .wrapping_mul(6_364_136_223_846_793_005)
                .wrapping_add(1);
            (state >> 16) % limit
        };
        for index in 0..iterations {
            let origin = (next(27) as i64 - 12) * 3600;
            let destination = (next(27) as i64 - 12) * 3600;
            let mut input = whole_trip_input(
                origin,
                destination,
                next(1440) as i64,
                30 + next(1200) as i64,
                next(8) as i64,
            );
            let dep = input["departure"].as_f64().unwrap();
            let reference = dep + (next(18 * 86_400) as f64) - 4.0 * 86_400.0;
            input["reference"] = json!(reference);
            let output = night_result(&input);
            assert_eq!(output, night_result(&input), "#{index} 非确定输出");
            let lanes = output["lanes"].as_array().unwrap();
            assert_eq!(lanes.iter().filter(|l| l["kind"] == "flight").count(), 1);
            assert!(lanes.len() <= 32);
            assert!(output["selected"].as_u64().unwrap() < lanes.len() as u64);
            let references = lanes.iter().filter(|l| !l["reference"].is_null()).count();
            assert!(references <= 1);
            for lane in lanes {
                let parts = lane["parts"].as_array().unwrap();
                let fractions = |key: &str| {
                    lane[key]
                        .as_array()
                        .unwrap()
                        .iter()
                        .map(|v| (v[0].as_f64().unwrap(), v[1].as_f64().unwrap()))
                        .collect::<Vec<_>>()
                };
                let mut coverage: Vec<(f64, f64)> = parts
                    .iter()
                    .map(|p| (p["from"].as_f64().unwrap(), p["to"].as_f64().unwrap()))
                    .collect();
                for key in ["seek", "avoid"] {
                    for (a, b) in fractions(key) {
                        assert!(
                            a.is_finite() && b.is_finite() && a >= 0.0 && a < b && b <= 1.0,
                            "#{index} {key}"
                        );
                        assert!(
                            coverage.iter().any(|(start, end)| a >= *start && b <= *end),
                            "#{index} 光窗超出天"
                        );
                    }
                }
                coverage.extend(fractions("air"));
                coverage.sort_by(|a, b| a.0.total_cmp(&b.0));
                let mut cursor = 0.0;
                for (a, b) in coverage {
                    assert!((a - cursor).abs() < 1e-10, "#{index} 天与飞行有空洞或重叠");
                    assert!(b > a && b <= 1.0);
                    cursor = b;
                }
                assert!((cursor - 1.0).abs() < 1e-10);
                if let Some(position) = lane["reference"].as_f64() {
                    assert!((0.0..=1.0).contains(&position));
                }
            }
        }
    }
}
