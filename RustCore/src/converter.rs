// SPDX-License-Identifier: GPL-3.0-only
//! Deterministic time export and wall-clock candidates. The host resolves local calendar times
//! through its system timezone database, including DST gaps and repeated times; this module only
//! turns the offsets it reads into candidate instants and renders timestamps.
//!
//! 文字输入由 `understand` 引擎处理；本模块保留换算候选、时间戳与输出格式。
//! 时区词表在 `understand/lexicon.rs`；解析兼容性由冻结的测试语料
//! `tests/corpus/migration-*.jsonl` 与 understand 的两道迁移门逐条对照。
use serde_json::{json, Value};

// Four-digit ISO years, inclusive at the start and exclusive at the end.
const MIN_TIMESTAMP: f64 = -62_135_596_800.0;
const MAX_TIMESTAMP: f64 = 253_402_300_800.0;

fn valid_timestamp(timestamp: f64) -> bool {
    timestamp.is_finite() && (MIN_TIMESTAMP..MAX_TIMESTAMP).contains(&timestamp)
}

fn resolved_instants(mut instants: Vec<f64>) -> Value {
    instants.sort_by(f64::total_cmp);
    instants.dedup_by(|a, b| *a == *b);
    if instants.is_empty() {
        json!({"error": "nonexistentTime", "instants": []})
    } else {
        json!({"instants": instants})
    }
}

fn resolve(payload: &Value) -> Value {
    let Some(candidates) = payload.get("candidates").and_then(Value::as_array) else {
        return json!({"error": "invalidCandidates", "instants": []});
    };
    let mut instants = Vec::with_capacity(candidates.len());
    for candidate in candidates {
        let Some(timestamp) = candidate.as_f64().filter(|t| valid_timestamp(*t)) else {
            return json!({"error": "invalidCandidates", "instants": []});
        };
        instants.push(timestamp);
    }
    resolved_instants(instants)
}

fn candidates(payload: &Value) -> Value {
    let invalid = || json!({"error": "invalidCandidates", "instants": []});
    let Some(local_timestamp) = payload
        .get("localTimestamp")
        .and_then(Value::as_f64)
        .filter(|t| valid_timestamp(*t))
    else {
        return invalid();
    };
    let Some(offsets) = payload.get("offsets").and_then(Value::as_array) else {
        return invalid();
    };
    let mut instants = Vec::with_capacity(offsets.len());
    for offset in offsets {
        let Some(offset) = offset.as_i64().filter(|o| (-86_399..=86_399).contains(o)) else {
            return invalid();
        };
        // Offsets are facts supplied by the host's system timezone database.
        // Do not assume a transition is one hour, or that a local day is 24 hours.
        let instant = local_timestamp - offset as f64;
        if !valid_timestamp(instant) {
            return invalid();
        }
        instants.push(instant);
    }
    resolved_instants(instants)
}

fn timestamps(payload: &Value) -> Result<Value, &'static str> {
    let timestamp = payload
        .get("timestamp")
        .and_then(Value::as_f64)
        .ok_or("invalidTimestamp")?;
    let offset = payload
        .get("offsetSeconds")
        .and_then(Value::as_i64)
        .ok_or("invalidTimestamp")?;
    if !valid_timestamp(timestamp) || !(-86_399..=86_399).contains(&offset) {
        return Err("invalidTimestamp");
    }
    let unix = timestamp.floor() as i64;
    // 1947 年前的利雅得是真太阳时（`+03:06:52` 这种带秒的偏移，tzdata 里叫 LMT）。
    // RFC 3339 与几乎所有收 ISO 串的系统只认 ±HH:MM，所以偏移**四舍五入到分钟**，
    // 当地读数跟着同一个舍入走（这样串指的还是同一个瞬间，只是当地钟点差 ≤30 秒），
    // 并把这件事标出来（`offsetRounded`），界面据此加一句脚注（调研 #35）。
    let rounded = ((offset as f64) / 60.0).round() as i64 * 60;
    // 舍入不许把本来越界的输入变成合法的：精确偏移与舍入后的偏移都要落在支持的公历范围里
    // （`timestamps_reject_invalid_values_and_calendar_overflow` 钉着这条边界）。
    let exact_local = unix.checked_add(offset).ok_or("invalidTimestamp")?;
    if !(MIN_TIMESTAMP as i64..MAX_TIMESTAMP as i64).contains(&exact_local) {
        return Err("invalidTimestamp");
    }
    let local = unix.checked_add(rounded).ok_or("invalidTimestamp")?;
    if !(MIN_TIMESTAMP as i64..MAX_TIMESTAMP as i64).contains(&local) {
        return Err("invalidTimestamp");
    }
    let local = local as libc::time_t;
    let mut parts = std::mem::MaybeUninit::<libc::tm>::uninit();
    // The checked four-digit-year timestamp is passed by value. gmtime_r writes
    // solely to this call's owned tm; it does not inspect or mutate local TZ.
    if unsafe { libc::gmtime_r(&local, parts.as_mut_ptr()) }.is_null() {
        return Err("invalidTimestamp");
    }
    let parts = unsafe { parts.assume_init() };
    let magnitude = rounded.abs();
    let suffix = format!(
        "{}{:02}:{:02}",
        if rounded < 0 { '-' } else { '+' },
        magnitude / 3600,
        magnitude % 3600 / 60
    );
    let iso = format!("{:04}-{:02}-{:02}T{:02}:{:02}:{:02}{}", parts.tm_year + 1900, parts.tm_mon + 1, parts.tm_mday, parts.tm_hour, parts.tm_min, parts.tm_sec, suffix);
    // Discord 时间戳令牌（F = 完整日期时间，R = 相对）与 Slack 日期令牌（回退文本是 ISO 串），收方各自按本地时区显示。
    Ok(json!({
        "iso8601": iso,
        "offsetRounded": rounded != offset,
        "offsetSeconds": offset,
        "unix": unix.to_string(),
        "discord": format!("<t:{unix}:F>"),
        "discordRelative": format!("<t:{unix}:R>"),
        "slack": format!("<!date^{unix}^{{date_short_pretty}} at {{time}}|{iso}>")
    }))
}

pub fn dispatch(operation: &str, payload: Value) -> Result<Value, String> {
    match operation {
        "converter.resolve" => Ok(resolve(&payload)),
        "converter.candidates" => Ok(candidates(&payload)),
        "converter.timestamps" => {
            Ok(timestamps(&payload).unwrap_or_else(|error| json!({"error": error})))
        }
        _ => Err(format!("Unknown converter operation: {operation}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn timestamps_include_chat_tokens() {
        let out = timestamps(&json!({"timestamp": 1_789_041_600.0, "offsetSeconds": 32_400})).unwrap();
        assert_eq!(out["iso8601"], "2026-09-10T21:00:00+09:00");
        assert_eq!(out["unix"], "1789041600");
        assert_eq!(out["discord"], "<t:1789041600:F>");
        assert_eq!(out["discordRelative"], "<t:1789041600:R>");
        assert_eq!(out["slack"], "<!date^1789041600^{date_short_pretty} at {time}|2026-09-10T21:00:00+09:00>");
    }

    #[test]
    fn resolver_distinguishes_gap_unique_time_and_fold() {
        assert_eq!(
            resolve(&json!({"candidates": []})),
            json!({"error": "nonexistentTime", "instants": []})
        );
        assert_eq!(
            resolve(&json!({"candidates": [1793511000.0, 1793507400.0, 1793511000.0]})),
            json!({"instants": [1793507400.0, 1793511000.0]})
        );
        assert_eq!(
            resolve(&json!({"candidates": [42.25, 42.25]})),
            json!({"instants": [42.25]})
        );
        assert_eq!(
            resolve(&json!({"candidates": [-0.0, 0.0]}))["instants"]
                .as_array()
                .unwrap()
                .len(),
            1
        );
        for input in [
            json!({}),
            json!({"candidates": [null]}),
            json!({"candidates": ["42"]}),
            json!({"candidates": [MAX_TIMESTAMP]}),
        ] {
            assert_eq!(resolve(&input)["error"], "invalidCandidates");
        }
    }

    #[test]
    fn candidate_offsets_preserve_half_hour_two_hour_and_date_line_changes() {
        for (offsets, expected) in [
            (vec![37800, 39600, 37800], vec![960400.25, 962200.25]),
            (vec![7200, 0], vec![992800.25, 1000000.25]),
            (vec![-36000, 50400], vec![949600.25, 1036000.25]),
            (vec![561, -561, 561], vec![999439.25, 1000561.25]),
        ] {
            assert_eq!(
                candidates(&json!({"localTimestamp": 1000000.25, "offsets": offsets})),
                json!({"instants": expected})
            );
        }
        assert_eq!(
            candidates(&json!({"localTimestamp": -0.5, "offsets": [0, 0]})),
            json!({"instants": [-0.5]})
        );
        assert_eq!(
            candidates(&json!({"localTimestamp": 0.0, "offsets": []})),
            json!({"error": "nonexistentTime", "instants": []})
        );
    }

    #[test]
    fn candidates_reject_bad_offsets_nonfinite_values_and_calendar_overflow() {
        for input in [
            json!({}),
            json!({"localTimestamp": 0}),
            json!({"localTimestamp": "0", "offsets": [0]}),
            json!({"localTimestamp": MAX_TIMESTAMP, "offsets": [0]}),
            json!({"localTimestamp": MIN_TIMESTAMP, "offsets": [1]}),
            json!({"localTimestamp": MAX_TIMESTAMP - 1.0, "offsets": [-1]}),
            json!({"localTimestamp": 0, "offsets": [86400]}),
            json!({"localTimestamp": 0, "offsets": [-86400]}),
            json!({"localTimestamp": 0, "offsets": [i64::MIN]}),
            json!({"localTimestamp": 0, "offsets": [null]}),
            json!({"localTimestamp": 0, "offsets": ["3600"]}),
            json!({"localTimestamp": 0, "offsets": [1.5]}),
        ] {
            assert_eq!(
                candidates(&input),
                json!({"error": "invalidCandidates", "instants": []}),
                "{input}"
            );
        }
        for number in ["1e400", "-1e400"] {
            let input =
                serde_json::from_str(&format!(r#"{{"localTimestamp":{number},"offsets":[0]}}"#))
                    .unwrap();
            assert_eq!(candidates(&input)["error"], "invalidCandidates");
        }
        assert_eq!(
            dispatch(
                "converter.candidates",
                json!({"localTimestamp": 0.0, "offsets": [0]})
            )
            .unwrap(),
            json!({"instants": [0.0]})
        );
    }

    #[test]
    fn timestamp_export_floors_negative_epoch_and_preserves_numeric_offset() {
        for (timestamp, offset, iso, unix) in [
            (0.0, 0, "1970-01-01T00:00:00+00:00", "0"),
            (-0.5, 0, "1969-12-31T23:59:59+00:00", "-1"),
            (0.999, 50400, "1970-01-01T14:00:00+14:00", "0"),
            (0.0, -50400, "1969-12-31T10:00:00-14:00", "0"),
            (0.0, 20700, "1970-01-01T05:45:00+05:45", "0"),
            (0.0, -12600, "1969-12-31T20:30:00-03:30", "0"),
            // 带秒的偏移（LMT）四舍五入到分钟，当地读数跟着同一个舍入走（调研 #35）：
            // 561 秒 = 9 分 21 秒 → +00:09，当地 0:09:00；−561 → −00:09。
            (0.0, 561, "1970-01-01T00:09:00+00:09", "0"),
            (0.0, -561, "1969-12-31T23:51:00-00:09", "0"),
        ] {
            let out = timestamps(&json!({"timestamp": timestamp, "offsetSeconds": offset})).unwrap();
            assert_eq!(out["iso8601"], iso);
            assert_eq!(out["unix"], unix);
        }
    }

    /// LMT（真太阳时）的秒级偏移：ISO 串只写 ±HH:MM，并标出「已四舍五入」（调研 #35）。
    /// 判据是 1947 年前的利雅得 `+03:06:52`：RFC 3339 不认带秒的偏移，收方会整串解析失败。
    #[test]
    fn a_local_mean_time_offset_is_rounded_to_whole_minutes_and_flagged() {
        // 1940-01-01 00:00:00 UTC = 利雅得当地 03:06:52（偏移 11_212 秒）。
        let riyadh = timestamps(&json!({"timestamp": -946_771_200.0, "offsetSeconds": 11_212})).unwrap();
        assert_eq!(riyadh["iso8601"], "1940-01-01T03:07:00+03:07");
        assert_eq!(riyadh["offsetRounded"], json!(true));
        assert_eq!(riyadh["offsetSeconds"], json!(11_212));
        // 舍入不改瞬间：unix 秒数照旧。
        assert_eq!(riyadh["unix"], "-946771200");
        // 往下舍：52 秒的那一侧进位，22 秒的一侧退位。
        let down = timestamps(&json!({"timestamp": 0.0, "offsetSeconds": 11_182})).unwrap();
        assert_eq!(down["iso8601"], "1970-01-01T03:06:00+03:06");
        // 整分钟的偏移一个字都不改，也不打标（绝大多数地点走这条路）。
        let tokyo = timestamps(&json!({"timestamp": 1_789_041_600.0, "offsetSeconds": 32_400})).unwrap();
        assert_eq!(tokyo["offsetRounded"], json!(false));
        assert_eq!(tokyo["iso8601"], "2026-09-10T21:00:00+09:00");
        // 半分钟正好在中间：Rust 的 round 远离零取整，+30 秒进位成 +00:01。
        let half = timestamps(&json!({"timestamp": 0.0, "offsetSeconds": 30})).unwrap();
        assert_eq!(half["iso8601"], "1970-01-01T00:01:00+00:01");
    }

    #[test]
    fn timestamps_reject_invalid_values_and_calendar_overflow() {
        for payload in [
            json!({"timestamp": MAX_TIMESTAMP, "offsetSeconds": 0}),
            json!({"timestamp": MIN_TIMESTAMP, "offsetSeconds": -1}),
            json!({"timestamp": MAX_TIMESTAMP - 1.0, "offsetSeconds": 1}),
            json!({"timestamp": 0, "offsetSeconds": i64::MIN}),
            json!({"timestamp": 0, "offsetSeconds": 86400}),
            json!({"timestamp": 0, "offsetSeconds": -86400}),
            json!({"timestamp": 0, "offsetSeconds": 1.5}),
            json!({"timestamp": "0", "offsetSeconds": 0}),
            json!({}),
        ] {
            assert_eq!(timestamps(&payload).unwrap_err(), "invalidTimestamp");
        }
        for timestamp in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY, f64::MAX] {
            assert!(!valid_timestamp(timestamp));
        }
    }

    #[test]
    fn dispatch_preserves_business_errors_in_value_envelope() {
        assert_eq!(
            dispatch("converter.timestamps", json!({})).unwrap(),
            json!({"error": "invalidTimestamp"})
        );
        assert!(dispatch("converter.parse", json!("9am")).is_err(), "读文字的那一半已删");
        assert!(dispatch("converter.unknown", json!({})).is_err());
    }
}
