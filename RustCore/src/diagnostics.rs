// SPDX-License-Identifier: GPL-3.0-only
//! 诊断包:把 Swift 收集到的本机与本 App 事实排成一份纯文本,供用户自己看过再发给作者。
//! 零遥测——这里只做排版与脱敏(家目录、邮箱、URL 的路径与查询),不产生任何网络行为。
use serde::Deserialize;
use serde_json::{json, Map, Value};

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct App {
    name: String,
    version: String,
    build: String,
    #[serde(rename = "bundleID")]
    bundle_id: String,
    is_local_preview: bool,
    architecture: String,
    translated: bool,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct System {
    #[serde(rename = "macOS")]
    mac_os: String,
    model: String,
    tzdata: String,
    system_time_zone: String,
    locale: String,
    ui_language: String,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct Process {
    uptime_seconds: f64,
    cpu_seconds: f64,
    resident_bytes: u64,
    footprint_bytes: u64,
    index_open: bool,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct Place {
    name: String,
    #[serde(rename = "timeZoneID")]
    time_zone_id: String,
    country_code: String,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct State {
    zones: Vec<Place>,
    zones_recovered: bool,
    people_count: usize,
    people_time_zones: Vec<String>,
    menu_bar_inserted: Option<bool>,
    settings: Value,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct Stale {
    zone: String,
    since: String,
    expected_minutes: i64,
    observed_minutes: i64,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct TzData {
    version: String,
    coverage: String,
    checked: usize,
    stale: Vec<Stale>,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct LogLine {
    date: String,
    level: String,
    category: String,
    message: String,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct Report {
    generated_at: String,
    app: App,
    system: System,
    process: Process,
    state: State,
    tzdata: TzData,
    logs: Vec<LogLine>,
    /// Swift 读自己的日志文件失败时的原因;本身就是诊断信息。
    log_error: Option<String>,
    /// 只要前几节(复制到剪贴板用)。
    summary: bool,
}

const MAX_LOG_LINES: usize = 300;

/// 家目录路径、邮箱、URL 的路径与查询都不该进诊断包。
fn redact(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while !rest.is_empty() {
        if let Some(stripped) = rest.strip_prefix("/Users/") {
            // /Users/<name>/… → ~/…;/Users/<name> 单独出现 → ~
            let end = stripped.find(['/', ' ', '"', '\'', ',', ')', '\n']).unwrap_or(stripped.len());
            let after = &stripped[end..];
            out.push('~');
            rest = after;
            continue;
        }
        if let Some(scheme_len) = ["https://", "http://"].iter().find_map(|s| rest.starts_with(s).then_some(s.len())) {
            let body = &rest[scheme_len..];
            let host_end = body.find(['/', '?', '#', ' ', '"', '\'', ',', ')', '\n']).unwrap_or(body.len());
            out.push_str(&rest[..scheme_len + host_end]);
            let tail = &body[host_end..];
            let stop = tail.find([' ', '"', '\'', ',', ')', '\n']).unwrap_or(tail.len());
            if stop > 0 {
                out.push_str("/…");
            }
            rest = &tail[stop..];
            continue;
        }
        let mut chars = rest.char_indices();
        let (_, c) = chars.next().unwrap();
        let next = chars.next().map(|(i, _)| i).unwrap_or(rest.len());
        out.push(c);
        rest = &rest[next..];
    }
    redact_emails(&out)
}

fn redact_emails(text: &str) -> String {
    // 词内含 @ 且 @ 两侧都有字符、右侧含点:整词替换。不做完整 RFC 校验,宁可多脱。
    text.split(' ')
        .map(|word| {
            let trimmed = word.trim_matches(|c: char| !c.is_alphanumeric());
            if let Some(at) = trimmed.find('@') {
                let (left, right) = trimmed.split_at(at);
                if !left.is_empty() && right.len() > 1 && right[1..].contains('.') {
                    return word.replace(trimmed, "[email]");
                }
            }
            word.to_owned()
        })
        .collect::<Vec<_>>()
        .join(" ")
}

fn redact_value(value: &Value) -> Value {
    match value {
        Value::String(s) => Value::String(redact(s)),
        Value::Array(items) => Value::Array(items.iter().map(redact_value).collect()),
        Value::Object(map) => {
            let mut sorted: Vec<_> = map.iter().collect();
            sorted.sort_by(|a, b| a.0.cmp(b.0));
            let mut out = Map::new();
            for (k, v) in sorted {
                out.insert(k.clone(), redact_value(v));
            }
            Value::Object(out)
        }
        other => other.clone(),
    }
}

fn megabytes(bytes: u64) -> String {
    format!("{:.1} MB", bytes as f64 / 1_048_576.0)
}

fn duration(seconds: f64) -> String {
    let total = seconds.max(0.0).round() as u64;
    let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60);
    if h > 0 {
        format!("{h} h {m} min")
    } else if m > 0 {
        format!("{m} min {s} s")
    } else {
        format!("{s} s")
    }
}

fn offset_label(minutes: i64) -> String {
    let sign = if minutes < 0 { "−" } else { "+" };
    let abs = minutes.abs();
    if abs % 60 == 0 {
        format!("UTC{sign}{}", abs / 60)
    } else {
        format!("UTC{sign}{}:{:02}", abs / 60, abs % 60)
    }
}

fn render(report: &Report) -> String {
    let mut lines: Vec<String> = Vec::new();
    let app = &report.app;
    lines.push(format!("{} diagnostics · {}", app.name, report.generated_at));
    lines.push(String::new());
    lines.push("[app]".to_owned());
    lines.push(format!("version: {} ({})", app.version, app.build));
    lines.push(format!("bundle: {}", app.bundle_id));
    lines.push(format!(
        "build kind: {}",
        if app.is_local_preview { "local preview" } else { "standard" }
    ));
    lines.push(format!(
        "architecture: {}{}",
        app.architecture,
        if app.translated { " (under Rosetta)" } else { "" }
    ));
    lines.push(String::new());
    let sys = &report.system;
    lines.push("[system]".to_owned());
    lines.push(format!("macOS: {}", sys.mac_os));
    lines.push(format!("model: {}", sys.model));
    lines.push(format!("tzdata: {}", sys.tzdata));
    lines.push(format!("system time zone: {}", sys.system_time_zone));
    lines.push(format!("locale: {} · ui: {}", sys.locale, sys.ui_language));
    lines.push(String::new());
    let p = &report.process;
    lines.push("[process]".to_owned());
    lines.push(format!("running for: {}", duration(p.uptime_seconds)));
    lines.push(format!("cpu time: {:.2} s", p.cpu_seconds));
    lines.push(format!(
        "memory: footprint {} · resident {}",
        megabytes(p.footprint_bytes),
        megabytes(p.resident_bytes)
    ));
    lines.push(format!("city index: {}", if p.index_open { "open" } else { "not opened" }));
    lines.push(String::new());
    let st = &report.state;
    lines.push("[state]".to_owned());
    lines.push(format!(
        "places: {}{}",
        st.zones.len(),
        if st.zones_recovered { " (restored from snapshot at launch)" } else { "" }
    ));
    for place in &st.zones {
        lines.push(format!(
            "  - {} · {}{}",
            redact(&place.name),
            place.time_zone_id,
            if place.country_code.is_empty() { String::new() } else { format!(" · {}", place.country_code) }
        ));
    }
    lines.push(format!(
        "people: {} (time zones: {})",
        st.people_count,
        if st.people_time_zones.is_empty() { "—".to_owned() } else { st.people_time_zones.join(", ") }
    ));
    if let Some(inserted) = st.menu_bar_inserted {
        lines.push(format!("menu bar item: {}", if inserted { "inserted" } else { "not inserted" }));
    }
    lines.push(String::new());
    let tz = &report.tzdata;
    lines.push("[tzdata self-check]".to_owned());
    lines.push(format!(
        "installed {} · known changes through {} · checked {}",
        tz.version, tz.coverage, tz.checked
    ));
    if tz.stale.is_empty() {
        lines.push("stale: none".to_owned());
    } else {
        for s in &tz.stale {
            lines.push(format!(
                "stale: {} · since {} · expected {} · observed {}",
                s.zone,
                s.since,
                offset_label(s.expected_minutes),
                offset_label(s.observed_minutes)
            ));
        }
    }
    if report.summary {
        return lines.join("\n") + "\n";
    }
    lines.push(String::new());
    lines.push("[settings]".to_owned());
    let settings = redact_value(&report.state.settings);
    let pretty = serde_json::to_string_pretty(&settings).unwrap_or_else(|_| "{}".to_owned());
    lines.extend(pretty.lines().map(|l| l.to_owned()));
    lines.push(String::new());
    lines.push("[log · app's own log file · newest last]".to_owned());
    if let Some(error) = &report.log_error {
        lines.push(format!("log unavailable: {}", redact(error)));
    }
    let skip = report.logs.len().saturating_sub(MAX_LOG_LINES);
    if skip > 0 {
        lines.push(format!("… {skip} earlier lines omitted"));
    }
    for line in report.logs.iter().skip(skip) {
        lines.push(format!(
            "{} {} [{}] {}",
            line.date,
            line.level,
            line.category,
            redact(&line.message)
        ));
    }
    if report.logs.is_empty() && report.log_error.is_none() {
        lines.push("(no entries)".to_owned());
    }
    lines.join("\n") + "\n"
}

pub fn dispatch(operation: &str, payload: Value) -> Result<Value, String> {
    match operation {
        "diagnostics.render" => {
            let report: Report = serde_json::from_value(payload).map_err(|e| e.to_string())?;
            Ok(json!(render(&report)))
        }
        "diagnostics.redact" => {
            let text: String = serde_json::from_value(payload).map_err(|e| e.to_string())?;
            Ok(json!(redact(&text)))
        }
        _ => Err(format!("Unknown diagnostics operation: {operation}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn home_paths_emails_and_url_tails_are_redacted() {
        assert_eq!(redact("/Users/alice/Library/x.plist"), "~/Library/x.plist");
        assert_eq!(redact("saw /Users/alice, then"), "saw ~, then");
        assert_eq!(redact("mail me at someone@example.com now"), "mail me at [email] now");
        assert_eq!(redact("host https://example.com/when?x=1#f ok"), "host https://example.com/… ok");
        assert_eq!(redact("https://example.com"), "https://example.com");
        assert_eq!(redact("plain text stays"), "plain text stays");
        assert_eq!(redact("@ alone and a@b stay"), "@ alone and a@b stay");
    }

    #[test]
    fn settings_are_sorted_and_redacted_and_the_summary_stops_before_them() {
        let report = Report {
            generated_at: "2026-09-12T23:30:00Z".to_owned(),
            app: App {
                name: "Dayside".to_owned(),
                version: "1.1.0".to_owned(),
                build: "17".to_owned(),
                bundle_id: "com.dayside.Dayside".to_owned(),
                architecture: "arm64".to_owned(),
                ..Default::default()
            },
            state: State {
                zones: vec![Place {
                    name: "Home /Users/alice/pics".to_owned(),
                    time_zone_id: "Asia/Tokyo".to_owned(),
                    country_code: "JP".to_owned(),
                }],
                settings: json!({"z": 1, "a": {"hostURL": "https://h.example/when?k=v", "n": [1, 2]}}),
                ..Default::default()
            },
            logs: vec![LogLine {
                date: "2026-09-12T23:29:59Z".to_owned(),
                level: "notice".to_owned(),
                category: "MenuBarPresence".to_owned(),
                message: "attached for /Users/alice/x".to_owned(),
            }],
            ..Default::default()
        };
        let full = render(&report);
        assert!(full.starts_with("Dayside diagnostics · 2026-09-12T23:30:00Z\n"));
        assert!(full.contains("  - Home ~/pics · Asia/Tokyo · JP\n"));
        let a = full.find("\"a\"").unwrap();
        let z = full.find("\"z\"").unwrap();
        assert!(a < z, "settings keys must be sorted");
        assert!(full.contains("\"hostURL\": \"https://h.example/…\""));
        assert!(full.contains("[MenuBarPresence] attached for ~/x\n"));
        assert!(full.contains(
            "[log · app's own log file · newest last]\n"
        ));
        let summary = render(&Report { summary: true, ..report });
        assert!(summary.contains("[tzdata self-check]"));
        assert!(!summary.contains("[settings]") && !summary.contains("[log"));
    }

    #[test]
    fn the_wire_format_uses_swifts_field_names() {
        let text = dispatch(
            "diagnostics.render",
            json!({
                "generatedAt": "2026-09-13T06:00:00Z",
                "app": {"name": "Dayside", "version": "1.1.0", "build": "17", "bundleID": "com.dayside.Dayside", "architecture": "arm64"},
                "system": {"macOS": "Version 26.6.2 (Build 25G100)", "tzdata": "2026c"},
                "state": {"zones": [{"name": "Tokyo", "timeZoneID": "Asia/Tokyo", "countryCode": "JP"}]},
                "summary": true
            }),
        )
        .unwrap();
        let text = text.as_str().unwrap();
        assert!(text.contains("bundle: com.dayside.Dayside\n"), "{text}");
        assert!(text.contains("macOS: Version 26.6.2 (Build 25G100)\n"));
        assert!(text.contains("  - Tokyo · Asia/Tokyo · JP\n"));
    }

    #[test]
    fn long_logs_are_capped_and_a_read_error_is_reported_not_hidden() {
        let logs = (0..MAX_LOG_LINES + 5)
            .map(|i| LogLine {
                date: format!("t{i}"),
                level: "info".to_owned(),
                category: "c".to_owned(),
                message: format!("m{i}"),
            })
            .collect();
        let text = render(&Report { logs, ..Default::default() });
        assert!(text.contains("… 5 earlier lines omitted\n"));
        assert!(!text.contains("t4 info") && text.contains("t5 info [c] m5\n"));
        let failed = render(&Report {
            log_error: Some("OSLogStore denied for /Users/alice".to_owned()),
            ..Default::default()
        });
        assert!(failed.contains("log unavailable: OSLogStore denied for ~\n"));
        assert!(!failed.contains("(no entries)"));
        let empty = render(&Report::default());
        assert!(empty.contains("(no entries)\n") && empty.contains("stale: none\n"));
    }
}
