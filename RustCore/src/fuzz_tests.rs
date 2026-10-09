// SPDX-License-Identifier: GPL-3.0-only
//! Structure-aware hostile-input sweep over every core operation. The FFI layer turns a panic into
//! `{"error":"Rust core panicked"}`, which the app survives, but each panic is still a bug: the
//! feature silently fails for that input. This test hunts them deterministically (fixed seed).
use crate::dispatch;
use serde_json::{json, Map, Value};
use std::panic::{catch_unwind, AssertUnwindSafe};

const OPERATIONS: &[&str] = &[
    "agenda.calendar_selection",
    "agenda.evaluate",
    "agenda.day",
    "agenda.drift",
    "agenda.meeting_link",
    "agenda.normalize_preferences",
    "agenda.reduce",
    "astronomy.altitudes",
    "astronomy.compute",
    "astronomy.seasons",
    "astronomy.trend",
    "catalog.city_option",
    "catalog.fold",
    "catalog.identifiers",
    "catalog.language_slot",
    "catalog.name_finish",
    "catalog.name_get",
    "catalog.parse_offset",
    "catalog.offset_only_zone_name",
    "catalog.region_override",
    "catalog.restore_chinese",
    "catalog.select_coordinate",
    "catalog.select_name",
    "catalog.subtitle",
    "catalog.tz_city",
    "catalog.zone_option",
    "city.coordinate_candidates",
    "city.names",
    "city.nearest",
    "city.record",
    "city.representative",
    "city.search",
    "city.timezone",
    "city.top",
    "converter.candidates",
    "converter.resolve",
    "converter.timestamps",
    "core.version",
    "diagnostics.redact",
    "diagnostics.render",
    "label.compose",
    "meeting.fold",
    "meeting.ics",
    "meeting.ics_series",
    "meeting.lines",
    "meeting.notes",
    "meeting.utc_stamp",
    "model.city_locale",
    "model.city_search_locale",
    "model.clock",
    "model.edit",
    "model.entry_label",
    "model.name_source",
    "model.participation",
    "model.refresh_name_matches",
    "model.refresh_name_requests",
    "model.scrub",
    "model.stored_name",
    "people.decode",
    "people.overlap_summary",
    "people.filter_contacts",
    "people.mutate",
    "people.status",
    "availability.rules",
    "availability.decode",
    "qr.encode",
    "qr.capacities",
    "availability.callable_order",
    "availability.intervals",
    "availability.normalize",
    "planner.plan",
    "planner.rotate",
    "planner.options",
    "planner.fit",
    "presence.init",
    "presence.reduce",
    "presence.sibling",
    "presentation.availability_date",
    "presentation.availability_label_date",
    "presentation.availability_minute",
    "presentation.clamp_opacity",
    "presentation.interval_text",
    "presentation.menu_count",
    "worldmap.scene",
    "sky.panel",
    "sky.lane",
    "sky.palette",
    "sky.strip",
    "sky.lanes",
    "presentation.overlap_tap",
    "presentation.panel_layout",
    "presentation.planner_inputs",
    "presentation.planner_rows",
    "presentation.planning_start",
    "presentation.scroll_label",
    "presentation.search_active",
    "presentation.search_event",
    "presentation.search_height",
    "presentation.search_key",
    "presentation.signed_offset",
    "presentation.spoken_name",
    "presentation.day_lane",
    "presentation.weekend_indices",
    "presentation.window_places",
    "presentation.sun_day",
    "settings.autonym",
    "settings.constants",
    "settings.effects",
    "settings.locale",
    "settings.normalize",
    "settings.planner",
    "settings.rotation",
    "settings.separator",
    "sharing.build",
    "sharing.decode",
    "sharing.places_encode",
    "sharing.places_decode",
    "sharing.validate",
    "spotlight.plan",
    "spotlight.version",
    "store.entry",
    "store.keys",
    "store.load_settings",
    "store.load_zones",
    "store.migrate",
    "store.migrate_domain",
    "store.save_settings",
    "store.save_zones",
    "travel.decode",
    "travel.mutate",
    "travel.nights",
    "travel.plan",
    "travel.primary_change",
    "travel.schedule_checks",
    "understand.crosscheck",
    "understand.parse",
    "dstwatch.reduce",
    "offsetwindows.compute",
    "offsetwindows.year",
    "markets.status",
    "markets.catalog",
    "tzdata.probes",
    "tzdata.check",
    "timers.reduce",
    "automation.validate",
    "nonsense.operation",
];

const KEYS: &[&str] = &[
    "text",
    "cityHandle",
    "region",
    "query",
    "handle",
    "index",
    "limit",
    "now",
    "zone",
    "timeZoneID",
    "command",
    "draft",
    "intent",
    "reference",
    "candidates",
    "offsets",
    "timestamp",
    "offsetSeconds",
    "identifiers",
    "person",
    "people",
    "state",
    "event",
    "settings",
    "zones",
    "primary",
    "snapshot",
    "legacy",
    "days",
    "minutes",
    "participants",
    "from",
    "duration",
    "localTimeZoneID",
    "toleranceMinutes",
    "weekday",
    "year",
    "month",
    "day",
    "isoWeekday",
    "kind",
    "hour",
    "minute",
    "place",
    "language",
    "version",
    "id",
    "createdAt",
    "action",
    "arguments",
    "name",
    "path",
    "value",
    "key",
    "locale",
    "hourStyle",
    "interval",
    "start",
    "end",
    "rows",
    "calendar",
    "fromDay",
    "timeZone",
    "facts",
    "latitude",
    "longitude",
    "date",
    "payload",
    "html",
    "hostFacts",
    "validUntil",
    "intervals",
    "timeZoneValid",
    "nativeTimeZoneID",
    "nativeOffsetSeconds",
    "trip",
    "trips",
    "seconds",
    "enabled",
    "leadSeconds",
    "receipts",
    "spec",
    "session",
    "mode",
    "label",
    "focus",
    "rounds",
    "alarmAt",
    "alarmZone",
    "alarmPlace",
    "departureNight",
    "arrivalNight",
    "departureDate",
    "arrivalDate",
    "originPlace",
    "destinationPlace",
    "countryCode",
    "windows",
    "sleep",
    "seek",
    "avoid",
    "avoidKind",
    "checks",
    "shiftMinutes",
    "remainingMinutes",
    "prep",
    "after",
    "span",
    "width",
    "height",
    "scale",
    "count",
    "items",
    "rangeStart",
    "rangeEnd",
    "allIDs",
    "selectedIDs",
    "events",
    "calendars",
    "preferences",
    "nextMeeting",
    "kindOf",
    "old",
    "new",
    "effects",
    "cityIndex",
    "tier",
    "population",
    "countryCode",
    "region",
    "adminIndex",
    "coordinate",
    "cityName",
    "displayName",
    "includesAvailability",
    "startMinute",
    "endMinute",
    "workingWeekdays",
    "vacations",
    "schedule",
    "expression",
    "sourceTimeZone",
    "windows",
    "generatedAt",
    "fixedOffsetSeconds",
    "primaryIndex",
    "inserted",
    "userWantsVisible",
    "rotation",
    "intervalWeeks",
    "maxStretchMinutes",
    "tzdata",
    "catalog",
    "places",
    "names",
    // 昼夜地图：时刻、要哪几层、纬度裁剪。
    "instant",
    "parts",
    "latitudeMin",
    "latitudeMax",
    // 夏令时提醒的一年时间线、市场时钟的状态。
    "local",
    "origin",
    "horizon",
    "spans",
    "dayStart",
    "dayEnd",
];

const STRINGS: &[&str] = &[
    "",
    " ",
    "0",
    "-1",
    "9999999999999999999",
    "Asia/Tokyo",
    "Europe/London",
    "UTC",
    "GMT+9",
    "bad zone",
    "mt1.",
    "mt1.AAAA",
    "下周二东京下午三点",
    "明日の午後3時に東京で",
    "내일 오후 3시에 도쿄에서",
    "next tuesday 3pm tokyo",
    "Webinar: 2 October 2026, 18:00–19:30 CEST. What time in Tokyo?",
    "9am PST in the U.S., 10/3 15.03 3時70分 午前15時 by EOD",
    "2026-10-02T09:00-10:00 Berlin 9:00 - Tokyo 16:00 1727000000",
    "14:00",
    "2026-09-10 12:00 Asia/Tokyo",
    "2026-02-30",
    "东京",
    "москва",
    "القاهرة",
    "😀🌍",
    "\u{202e}reverse",
    "a\u{0}b",
    "\t\n\r",
    "null",
    "true",
    "{}",
    "[]",
    "12345678-1234-1234-1234-123456789012",
    "york",
    "san",
    "新",
    "%s%s%n",
    "../../etc/passwd",
    "https://example.test/#mt1.x",
    "addPlace",
    "primary",
    "pomodoro",
    "convert",
    "tools",
    "planner",
    "force24",
    "force12",
    "followSystem",
    "zh-Hans",
    "en",
    "all",
    "static",
    "dynamic",
];

struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.0 = x;
        x
    }
    fn below(&mut self, n: usize) -> usize {
        (self.next() % n.max(1) as u64) as usize
    }
    fn chance(&mut self, percent: u64) -> bool {
        self.next() % 100 < percent
    }
}

fn scalar(rng: &mut Rng, handle: Option<u64>) -> Value {
    match rng.below(14) {
        0 => Value::Null,
        1 => json!(rng.chance(50)),
        2 => json!(0),
        3 => json!(-1),
        4 => json!(rng.next() as i64),
        5 => json!(i64::MAX),
        6 => json!((rng.next() % 5000) as f64 / 7.0),
        7 => json!(1e300),
        8 => json!(-1e300),
        9 => json!(1_789_041_600.0 + (rng.next() % 1_000_000) as f64),
        10 => json!(STRINGS[rng.below(STRINGS.len())]),
        11 => json!("x".repeat(rng.below(3000))),
        12 => match handle {
            Some(h) if rng.chance(70) => json!(h),
            _ => json!(rng.next()),
        },
        _ => json!((rng.next() % 2000) as i64 - 1000),
    }
}

fn value(rng: &mut Rng, depth: u8, handle: Option<u64>) -> Value {
    if depth == 0 || rng.chance(45) {
        return scalar(rng, handle);
    }
    if rng.chance(35) {
        let count = rng.below(6);
        return Value::Array((0..count).map(|_| value(rng, depth - 1, handle)).collect());
    }
    let mut map = Map::new();
    for _ in 0..rng.below(9) {
        let key = KEYS[rng.below(KEYS.len())];
        map.insert(key.to_owned(), value(rng, depth - 1, handle));
    }
    Value::Object(map)
}

#[test]
fn hostile_payloads_never_panic_any_operation() {
    // The city index is absent from the intents-only build; the sweep then runs without a handle.
    let handle = dispatch(
        "city.open",
        json!({"path": concat!(env!("CARGO_MANIFEST_DIR"), "/../Dayside/Resources/cities.ttcity")}),
    )
    .ok()
    .and_then(|opened| opened["handle"].as_u64());
    // `MEANTIME_FUZZ_SEED=<n>` 换一条序列（默认 0 即原序列），`MEANTIME_FUZZ_ITERATIONS` 拉长。
    let seed_offset: u64 = std::env::var("MEANTIME_FUZZ_SEED")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(0);
    let mut rng = Rng(0x9E37_79B9_7F4A_7C15_u64.wrapping_add(seed_offset));
    let mut panics: Vec<String> = Vec::new();
    let iterations = std::env::var("MEANTIME_FUZZ_ITERATIONS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(150usize);
    for operation in OPERATIONS {
        for _ in 0..iterations {
            let payload = value(&mut rng, 3, handle);
            let shown = payload.to_string();
            let shown = if shown.len() > 300 {
                format!("{}…", &shown[..shown.floor_char_boundary(300)])
            } else {
                shown
            };
            let outcome = catch_unwind(AssertUnwindSafe(|| dispatch(operation, payload)));
            if outcome.is_err() {
                panics.push(format!("{operation} <- {shown}"));
            }
        }
    }
    // The transport layer must also survive bytes that are not JSON at all.
    for bytes in [
        &b"\xff\xfe\x00"[..],
        b"",
        b"{",
        b"{\"operation\":1}",
        b"{\"operation\":\"city.search\"}",
        b"[1,2,3]",
    ] {
        let reply = crate::respond(bytes);
        assert!(
            serde_json::from_slice::<Value>(&reply).is_ok(),
            "transport reply must be JSON for {bytes:?}"
        );
    }
    if !panics.is_empty() {
        let mut unique: Vec<String> = panics
            .iter()
            .map(|p| p.split(" <- ").next().unwrap().to_owned())
            .collect();
        unique.sort();
        unique.dedup();
        panic!(
            "{} panics across {} operations:\n{}",
            panics.len(),
            unique.len(),
            panics.join("\n")
        );
    }
}

/// 昼夜地图：通用扫描很少凑齐 instant / width / height 三个数，这里按字段挑敌意值并断言结果。
/// 时刻不在 1800–2100（或不是数）、尺寸不在 (0, 100000]、`parts` 不是 all / static / dynamic / null、
/// 裁剪或地点的字段不是数时，一定是错误；其余一定成功，而且几何里每个数都有限（NaN / inf 会被 serde 写成 null，
/// 宿主解不出来）、命令种类与颜色角色都在封闭表里、static 只有底色与陆地、dynamic 从曙暮与昼两层起头。
#[cfg(not(feature = "intents-only"))]
#[test]
fn worldmap_scene_hostile_fields_never_panic_and_never_emit_non_finite_geometry() {
    let seed_offset: u64 = std::env::var("MEANTIME_FUZZ_SEED")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(0);
    let iterations = std::env::var("MEANTIME_FUZZ_ITERATIONS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(400usize);
    let mut rng = Rng(0xD1B5_4A32_D192_ED03_u64.wrapping_add(seed_offset));
    // (值, 合不合法)；None = 不带这个键。
    let instants: &[(Option<Value>, bool)] = &[
        (Some(json!(1_789_542_000.0)), true),
        (Some(json!(1_774_017_936.0)), true),
        (Some(json!(0)), true),
        (Some(json!(-5_364_662_400.0)), true),
        (Some(json!(4_133_980_800.0)), true),
        (Some(json!(-5_364_662_401.0)), false),
        (Some(json!(4_133_980_801.0)), false),
        (Some(json!(1e300)), false),
        (Some(json!(-1e300)), false),
        (Some(json!(i64::MAX)), false),
        (Some(json!(u64::MAX)), false),
        (Some(Value::Null), false),
        (Some(json!("1789542000")), false),
        (Some(json!([1])), false),
        (None, false),
    ];
    let sides: &[(Option<Value>, bool)] = &[
        (Some(json!(288.0)), true),
        (Some(json!(960)), true),
        (Some(json!(1)), true),
        (Some(json!(0.25)), true),
        (Some(json!(100_000.0)), true),
        (Some(json!(0)), false),
        (Some(json!(-1)), false),
        (Some(json!(100_000.5)), false),
        (Some(json!(1e300)), false),
        (Some(Value::Null), false),
        (Some(json!("x")), false),
        (None, false),
    ];
    // 没有分层：以前的 `parts` 键现在是不认识的键，照样忽略，任何值都不影响成败。
    let stale_parts = [
        Value::Null,
        json!("static"),
        json!("moon"),
        json!(1),
        json!(["all"]),
    ];
    let latitudes: &[(Option<Value>, bool)] = &[
        (None, true),
        (Some(json!(-90)), true),
        (Some(json!(90)), true),
        (Some(json!(-62.0)), true),
        (Some(json!(84.0)), true),
        (Some(json!(0)), true),
        (Some(json!(-91)), true),
        (Some(json!(1e300)), true),
        (Some(json!(-1e300)), true),
        (Some(Value::Null), false),
        (Some(json!("n")), false),
    ];
    let coordinates = [
        json!(-90),
        json!(90),
        json!(45.5),
        json!(-180),
        json!(180),
        json!(181),
        json!(-91),
        json!(1e300),
        json!(0),
    ];
    // 每个字段八成挑合法的值，整条请求才有一半左右能走到成功那条路；其余照样挑敌意值。
    fn pick<'a, T>(rng: &mut Rng, table: &'a [T], valid: impl Fn(&T) -> bool) -> &'a T {
        if rng.chance(80) {
            let good: Vec<&T> = table.iter().filter(|entry| valid(entry)).collect();
            if !good.is_empty() {
                return good[rng.below(good.len())];
            }
        }
        &table[rng.below(table.len())]
    }
    let mut failures: Vec<String> = Vec::new();
    let mut successes = 0usize;
    for _ in 0..iterations {
        let mut payload = Map::new();
        let mut valid = true;
        let mut put = |key: &str, choice: &(Option<Value>, bool), valid: &mut bool| {
            if let Some(value) = &choice.0 {
                payload.insert(key.to_owned(), value.clone());
            }
            *valid &= choice.1;
        };
        // 一半用范围里的随机时刻，一半从敌意表里挑。
        let random_instant = (
            Some(json!(
                -5_364_662_400.0 + (rng.next() % 9_498_643_201) as f64
            )),
            true,
        );
        let instant = if rng.chance(50) {
            &random_instant
        } else {
            pick(&mut rng, instants, |entry| entry.1)
        };
        put("instant", instant, &mut valid);
        put("width", pick(&mut rng, sides, |entry| entry.1), &mut valid);
        put("height", pick(&mut rng, sides, |entry| entry.1), &mut valid);
        put(
            "latitudeMin",
            pick(&mut rng, latitudes, |entry| entry.1),
            &mut valid,
        );
        put(
            "latitudeMax",
            pick(&mut rng, latitudes, |entry| entry.1),
            &mut valid,
        );
        if rng.chance(20) {
            payload.insert(
                "parts".into(),
                stale_parts[rng.below(stale_parts.len())].clone(),
            );
        }
        if rng.chance(70) {
            let count = rng.below(5);
            let mut places = Vec::with_capacity(count);
            for _ in 0..count {
                if rng.chance(5) {
                    valid = false; // 缺纬度的地点：整条请求是错误
                    places.push(json!({"longitude": 0}));
                } else {
                    let latitude = coordinates[rng.below(coordinates.len())].clone();
                    let longitude = coordinates[rng.below(coordinates.len())].clone();
                    places.push(json!({"latitude": latitude, "longitude": longitude, "home": rng.chance(30)}));
                }
            }
            payload.insert("places".into(), Value::Array(places));
        }
        let shown = Value::Object(payload.clone()).to_string();
        let outcome = catch_unwind(AssertUnwindSafe(|| {
            dispatch("worldmap.scene", Value::Object(payload))
        }));
        let Ok(result) = outcome else {
            failures.push(format!("panic <- {shown}"));
            continue;
        };
        match (valid, result) {
            (false, Ok(_)) => failures.push(format!("该是错误却成功了 <- {shown}")),
            (false, Err(_)) => {}
            (true, Err(error)) => failures.push(format!("该成功却报错 {error} <- {shown}")),
            (true, Ok(value)) => {
                successes += 1;
                let finite = |v: &Value| v.as_f64().is_some_and(f64::is_finite);
                if value.get("commands").is_some() {
                    failures.push(format!("底图在位图里，场景不该再带绘图命令 <- {shown}"));
                }
                // 每个地点：位置有限、本机与脚下明暗是布尔、脚下的颜色是 "#rrggbb"。
                for pin in value["pins"].as_array().cloned().unwrap_or_default() {
                    let fill = pin["fill"].as_str().unwrap_or("");
                    let fill_ok = fill.len() == 7
                        && fill.starts_with('#')
                        && u32::from_str_radix(&fill[1..], 16).is_ok();
                    if !finite(&pin["x"])
                        || !finite(&pin["y"])
                        || !pin["home"].is_boolean()
                        || !pin["dark"].is_boolean()
                        || !fill_ok
                    {
                        failures.push(format!("地点字段不对 {pin} <- {shown}"));
                    }
                }
                let moon_ok = ["x", "y", "latitude", "longitude", "illumination", "cycle"]
                    .iter()
                    .all(|key| finite(&value["moon"][key]));
                let sun_ok = value["sun"]
                    .as_array()
                    .is_some_and(|sun| sun.len() == 2 && sun.iter().all(finite));
                if !moon_ok || !sun_ok || !value["pins"].is_array() || !value["lit"].is_array() {
                    failures.push(format!("缺字段或非有限数 <- {shown}"));
                }
            }
        }
    }
    // 传输层：1e400 在 arbitrary_precision 下读成 inf；NaN 字面量不是 JSON。都得是错误，不许 panic。
    for bytes in [
        &br#"{"operation":"worldmap.scene","payload":{"instant":1e400,"width":360,"height":180}}"#[..],
        br#"{"operation":"worldmap.scene","payload":{"instant":-1e400,"width":360,"height":180,"parts":"dynamic"}}"#,
        br#"{"operation":"worldmap.scene","payload":{"instant":1789542000,"width":360,"height":1e400}}"#,
        br#"{"operation":"worldmap.scene","payload":{"instant":NaN,"width":360,"height":180}}"#,
    ] {
        let reply: Value = serde_json::from_slice(&crate::respond(bytes)).expect("transport reply must be JSON");
        if !reply["error"].is_string() {
            failures.push(format!("传输层该报错：{}", String::from_utf8_lossy(bytes)));
        }
    }
    assert!(
        failures.is_empty(),
        "{} 条：\n{}",
        failures.len(),
        failures.join("\n")
    );
    // 成功那条路要真走到（默认 400 次里约一半）。
    assert!(successes * 5 >= iterations, "{successes}/{iterations}");
}
