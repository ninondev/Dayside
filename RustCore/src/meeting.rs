// SPDX-License-Identifier: GPL-3.0-only
//! Meeting descriptions and RFC 5545 serialization, independent of the UI and EventKit.
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Clone, Deserialize, Serialize)]
struct Line {
    name: String,
    text: String,
}

#[derive(Deserialize)]
struct Notes {
    lines: Vec<Line>,
    footer: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LocalTime {
    name: String,
    day: String,
    start_time: String,
    end_time: String,
    end_day: String,
    same_day: bool,
    offset_changed: bool,
    start_abbreviation: String,
    end_abbreviation: String,
}

#[derive(Deserialize)]
struct Event {
    title: String,
    start: f64,
    end: f64,
    lines: Vec<Line>,
    footer: String,
    uid: String,
    stamp: f64,
}

fn notes(lines: &[Line], footer: &str) -> String {
    let mut parts: Vec<_> = lines
        .iter()
        .map(|line| format!("{} · {}", line.name, line.text))
        .collect();
    parts.push(footer.to_owned());
    parts.join("\n")
}

fn local_lines(inputs: Vec<LocalTime>) -> Vec<Line> {
    inputs
        .into_iter()
        .map(|input| {
            let end = if input.same_day {
                input.end_time
            } else {
                format!("{} ({})", input.end_time, input.end_day)
            };
            let text = if input.offset_changed {
                format!(
                    "{} {} {}–{} {}",
                    input.day,
                    input.start_time,
                    input.start_abbreviation,
                    end,
                    input.end_abbreviation
                )
            } else {
                format!(
                    "{} {}–{} {}",
                    input.day, input.start_time, end, input.start_abbreviation
                )
            };
            Line {
                name: input.name,
                text,
            }
        })
        .collect()
}

fn escape(text: &str) -> String {
    text.replace('\\', "\\\\")
        .replace("\r\n", "\n")
        .replace('\r', "\n")
        .replace('\n', "\\n")
        .replace(';', "\\;")
        .replace(',', "\\,")
}

fn fold(line: &str) -> Vec<String> {
    if line.len() <= 75 {
        return vec![line.to_owned()];
    }
    let mut lines = Vec::new();
    let mut index = 0;
    while index < line.len() {
        let limit = if index == 0 { 75 } else { 74 };
        let mut cut = line.len().min(index + limit);
        while !line.is_char_boundary(cut) {
            cut -= 1;
        }
        lines.push(if index == 0 {
            line[index..cut].to_owned()
        } else {
            format!(" {}", &line[index..cut])
        });
        index = cut;
    }
    lines
}

fn utc_stamp(timestamp: f64) -> Result<String, String> {
    if !timestamp.is_finite() {
        return Err("meeting.utc_stamp requires a finite Unix timestamp".to_owned());
    }
    let seconds = timestamp.floor() as libc::time_t;
    let mut parts = std::mem::MaybeUninit::<libc::tm>::uninit();
    // gmtime_r reads only the supplied Unix timestamp and writes into this owned tm.
    let result = unsafe { libc::gmtime_r(&seconds, parts.as_mut_ptr()) };
    if result.is_null() {
        return Err(
            "meeting.utc_stamp timestamp is outside the platform calendar range".to_owned(),
        );
    }
    let parts = unsafe { parts.assume_init() };
    Ok(format!(
        "{:04}{:02}{:02}T{:02}{:02}{:02}Z",
        parts.tm_year + 1900,
        parts.tm_mon + 1,
        parts.tm_mday,
        parts.tm_hour,
        parts.tm_min,
        parts.tm_sec
    ))
}

fn vevent(event: &Event) -> Result<Vec<String>, String> {
    Ok(vec![
        "BEGIN:VEVENT".to_owned(),
        format!("UID:{}", event.uid),
        format!("DTSTAMP:{}", utc_stamp(event.stamp)?),
        format!("DTSTART:{}", utc_stamp(event.start)?),
        format!("DTEND:{}", utc_stamp(event.end)?),
        format!("SUMMARY:{}", escape(&event.title)),
        format!(
            "DESCRIPTION:{}",
            escape(&notes(&event.lines, &event.footer))
        ),
        "END:VEVENT".to_owned(),
    ])
}

/// One VCALENDAR holding every event, in the given order (a rotating series is one import).
fn ics_series(events: &[Event]) -> Result<String, String> {
    let mut lines = vec![
        "BEGIN:VCALENDAR".to_owned(),
        "VERSION:2.0".to_owned(),
        "PRODID:-//Dayside//Meeting Planner//EN".to_owned(),
        "CALSCALE:GREGORIAN".to_owned(),
        // 不写 METHOD：RFC 5546 §3.2.1 要求 METHOD:PUBLISH 的 VEVENT 带 ORGANIZER，我们没有组织者地址。
    ];
    for event in events {
        lines.extend(vevent(event)?);
    }
    lines.push("END:VCALENDAR".to_owned());
    Ok(lines
        .iter()
        .flat_map(|line| fold(line))
        .collect::<Vec<_>>()
        .join("\r\n")
        + "\r\n")
}

fn ics(event: Event) -> Result<String, String> {
    ics_series(std::slice::from_ref(&event))
}

pub fn dispatch(operation: &str, payload: Value) -> Result<Value, String> {
    match operation {
        "meeting.escape" | "meeting.fold" => {
            let input: String =
                serde_json::from_value(payload).map_err(|error| error.to_string())?;
            if operation == "meeting.escape" {
                Ok(Value::String(escape(&input)))
            } else {
                serde_json::to_value(fold(&input)).map_err(|error| error.to_string())
            }
        }
        "meeting.utc_stamp" => {
            let input: f64 = serde_json::from_value(payload).map_err(|error| error.to_string())?;
            Ok(Value::String(utc_stamp(input)?))
        }
        "meeting.notes" => {
            let input: Notes =
                serde_json::from_value(payload).map_err(|error| error.to_string())?;
            Ok(Value::String(notes(&input.lines, &input.footer)))
        }
        "meeting.lines" => {
            let input: Vec<LocalTime> =
                serde_json::from_value(payload).map_err(|error| error.to_string())?;
            serde_json::to_value(local_lines(input)).map_err(|error| error.to_string())
        }
        "meeting.ics" => {
            let input: Event =
                serde_json::from_value(payload).map_err(|error| error.to_string())?;
            Ok(Value::String(ics(input)?))
        }
        "meeting.ics_series" => {
            let input: Vec<Event> =
                serde_json::from_value(payload).map_err(|error| error.to_string())?;
            Ok(Value::String(ics_series(&input)?))
        }
        _ => Err(format!("Unknown meeting operation: {operation}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn escape_normalizes_all_newlines_and_escapes_text_punctuation() {
        assert_eq!(escape("a\\b;c,d\r\ne\nf\rg"), "a\\\\b\\;c\\,d\\ne\\nf\\ng");
    }

    #[test]
    fn utf8_folding_round_trips_every_byte_including_zwj() {
        let source = format!("DESCRIPTION:{}", "上海👩🏽‍💻é,".repeat(30));
        let lines = fold(&source);
        assert!(lines.iter().all(|line| line.len() <= 75));
        assert!(lines.iter().skip(1).all(|line| line.as_bytes()[0] == b' '));
        let unfolded = lines
            .iter()
            .enumerate()
            .flat_map(|(index, line)| {
                if index == 0 {
                    line.as_bytes()
                } else {
                    &line.as_bytes()[1..]
                }
            })
            .copied()
            .collect::<Vec<_>>();
        assert_eq!(unfolded, source.as_bytes());
    }

    #[test]
    fn byte_limit_includes_the_continuation_space() {
        let text = "a".repeat(75);
        assert_eq!(fold(&text), vec![text.clone()]);
        assert_eq!(fold(&(text.clone() + "b")), vec![text, " b".to_owned()]);
    }

    #[test]
    fn utc_formatting_preserves_seconds_and_handles_pre_epoch_dates() {
        assert_eq!(utc_stamp(0.0).unwrap(), "19700101T000000Z");
        assert_eq!(utc_stamp(-0.5).unwrap(), "19691231T235959Z");
        assert_eq!(utc_stamp(1_794_083_400.0).unwrap(), "20261107T203000Z");
    }

    #[test]
    fn calendar_serialization_keeps_utc_times_and_blocks_text_property_injection() {
        let text = ics(Event {
            title: "Meeting\r\nLOCATION:Elsewhere".to_owned(),
            start: 0.0,
            end: 3600.0,
            lines: vec![Line {
                name: "A,B".to_owned(),
                text: "One\rTwo".to_owned(),
            }],
            footer: "Dayside".to_owned(),
            uid: "fixture".to_owned(),
            stamp: 0.0,
        })
        .unwrap();
        assert!(text.contains("DTSTART:19700101T000000Z\r\n"));
        assert!(text.contains("DTEND:19700101T010000Z\r\n"));
        assert!(text.contains("SUMMARY:Meeting\\nLOCATION:Elsewhere\r\n"));
        assert!(!text.contains("\r\nLOCATION:"));
        assert!(text.ends_with("END:VCALENDAR\r\n"));
    }
    #[test]
    fn a_series_is_one_calendar_holding_every_event_and_a_single_event_is_the_same_as_before() {
        let event = |uid: &str, start: f64| Event {
            title: "Weekly sync".to_owned(),
            start,
            end: start + 3600.0,
            lines: vec![],
            footer: "Dayside".to_owned(),
            uid: uid.to_owned(),
            stamp: 0.0,
        };
        let series = ics_series(&[event("one", 0.0), event("two", 604_800.0)]).unwrap();
        assert_eq!(series.matches("BEGIN:VCALENDAR").count(), 1);
        assert_eq!(series.matches("BEGIN:VEVENT").count(), 2);
        assert!(series.contains("UID:one\r\n") && series.contains("UID:two\r\n"));
        assert!(series.contains("DTSTART:19700108T000000Z\r\n"));
        assert!(series.ends_with("END:VEVENT\r\nEND:VCALENDAR\r\n"));
        assert_eq!(ics(event("one", 0.0)).unwrap(), ics_series(&[event("one", 0.0)]).unwrap());
    }

    /// 性质测试：随机标题 / 各地时间行 / 脚注（塞满逗号、分号、反斜杠、三种换行、零宽连接符、长 CJK）做成
    /// 多场 .ics，再用一个独立的最小 RFC 5545 读法（CRLF 切行、以空格开头的行接回上一行、`\\` `\;` `\,` `\n`
    /// 反转义）读回：每个物理行 ≤ 75 字节且都是 CRLF 结尾、VEVENT 数量一致、SUMMARY 逐字等于标题、
    /// DESCRIPTION 逐字等于 `notes`（换行统一成 LF）、DTSTART/DTEND/DTSTAMP 等于独立公历算法算出的 UTC 戳。
    #[test]
    fn random_events_survive_ics_serialization_and_an_independent_reader() {
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
        fn civil_from_days(z: i64) -> (i64, i64, i64) {
            let z = z + 719_468;
            let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
            let doe = z - era * 146_097;
            let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
            let y = yoe + era * 400;
            let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
            let mp = (5 * doy + 2) / 153;
            let d = doy - (153 * mp + 2) / 5 + 1;
            let m = if mp < 10 { mp + 3 } else { mp - 9 };
            (if m <= 2 { y + 1 } else { y }, m, d)
        }
        fn stamp(unix: i64) -> String {
            let days = unix.div_euclid(86_400);
            let rem = unix.rem_euclid(86_400);
            let (y, m, d) = civil_from_days(days);
            format!("{y:04}{m:02}{d:02}T{:02}{:02}{:02}Z", rem / 3600, rem % 3600 / 60, rem % 60)
        }
        fn unescape(text: &str) -> String {
            let mut out = String::new();
            let mut chars = text.chars();
            while let Some(c) = chars.next() {
                if c == '\\' {
                    match chars.next() {
                        Some('n') | Some('N') => out.push('\n'),
                        Some(other) => out.push(other),
                        None => out.push('\\'),
                    }
                } else {
                    out.push(c);
                }
            }
            out
        }
        let pieces = ["Weekly, sync", "a;b", "back\\slash", "line\r\nbreak", "cr\ronly", "lf\nonly", "東京・ロンドン", "👩‍🚀 crew", "", " ", "Zoë", "x".repeat(90).as_str().to_owned().leak(), "混合, 标点; 中文"];
        let iterations: u64 = std::env::var("MEANTIME_FUZZ_ITERATIONS").ok().and_then(|v| v.parse().ok()).unwrap_or(1_500);
        let seed_offset: u64 = std::env::var("MEANTIME_FUZZ_SEED").ok().and_then(|v| v.parse().ok()).unwrap_or(0);
        let mut rng = Xor(0x1C5C_A1E0_5EED_0001_u64.wrapping_add(seed_offset));
        for i in 0..iterations {
            let text = |rng: &mut Xor| (0..rng.below(4)).map(|_| pieces[rng.below(pieces.len() as u64) as usize]).collect::<Vec<_>>().join("");
            let count = 1 + rng.below(4) as usize;
            let mut events = Vec::new();
            for k in 0..count {
                let start = (rng.below(4_000_000_000) as i64 - 500_000_000) as f64;
                let lines: Vec<Line> = (0..rng.below(4)).map(|_| Line { name: text(&mut rng), text: text(&mut rng) }).collect();
                events.push(Event { title: text(&mut rng), start, end: start + (900 * (1 + rng.below(16))) as f64, lines, footer: text(&mut rng), uid: format!("uid-{i}-{k}"), stamp: start - 86_400.0 });
            }
            let ics = ics_series(&events).unwrap_or_else(|e| panic!("#{i} ics_series 出错：{e}"));
            assert!(ics.ends_with("\r\n"), "#{i} 不以 CRLF 结尾");
            let physical: Vec<&str> = ics.strip_suffix("\r\n").unwrap().split("\r\n").collect();
            for line in &physical {
                assert!(line.len() <= 75, "#{i} 物理行 {} 字节：{line:?}", line.len());
                assert!(!line.contains('\r') && !line.contains('\n'), "#{i} 行里有裸换行");
            }
            // 接回折行。
            let mut logical: Vec<String> = Vec::new();
            for line in physical {
                if let Some(rest) = line.strip_prefix(' ') {
                    logical.last_mut().expect("续行前必须有行").push_str(rest);
                } else {
                    logical.push(line.to_owned());
                }
            }
            let vevents = logical.iter().filter(|l| *l == "BEGIN:VEVENT").count();
            assert_eq!(vevents, count, "#{i} VEVENT 数量");
            let mut k = 0usize;
            let mut cursor = 0usize;
            while k < count {
                let begin = logical[cursor..].iter().position(|l| l == "BEGIN:VEVENT").unwrap() + cursor;
                let end = logical[begin..].iter().position(|l| l == "END:VEVENT").unwrap() + begin;
                let field = |name: &str| -> String {
                    logical[begin..end].iter().find_map(|l| l.strip_prefix(&format!("{name}:"))).unwrap_or_else(|| panic!("#{i} 第 {k} 场缺 {name}")).to_owned()
                };
                let event = &events[k];
                assert_eq!(field("UID"), event.uid, "#{i}");
                assert_eq!(field("DTSTART"), stamp(event.start as i64), "#{i} DTSTART");
                assert_eq!(field("DTEND"), stamp(event.end as i64), "#{i} DTEND");
                assert_eq!(field("DTSTAMP"), stamp(event.stamp as i64), "#{i} DTSTAMP");
                let normalize = |t: &str| t.replace("\r\n", "\n").replace('\r', "\n");
                assert_eq!(unescape(&field("SUMMARY")), normalize(&event.title), "#{i} 第 {k} 场标题");
                assert_eq!(unescape(&field("DESCRIPTION")), normalize(&notes(&event.lines, &event.footer)), "#{i} 第 {k} 场说明");
                cursor = end + 1;
                k += 1;
            }
        }
    }
}
