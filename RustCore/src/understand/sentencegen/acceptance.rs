// SPDX-License-Identifier: GPL-3.0-only
use super::{cases, expected, render, template_count, to_jsonl, Clock, DateSpec, Spec, Zone, LANGUAGES};

fn spec(date: Option<DateSpec>, h: u8, m: u8, end: Option<(u8, u8)>, zone: Option<Zone>) -> Spec {
    Spec { date, time: Clock { hour: h, minute: m }, end: end.map(|(hour, minute)| Clock { hour, minute }), zone }
}

#[test]
fn expected_uses_the_summary_notation() {
    let abs = Some(DateSpec::Absolute { year: 2026, month: 10, day: 3 });
    assert_eq!(expected(&spec(abs, 9, 0, Some((11, 30)), Some(Zone::City("tokyo")))), "2026-10-03 09:00–11:30 Asia/Tokyo > -");
    assert_eq!(expected(&spec(Some(DateSpec::Offset { days: 1 }), 15, 45, None, Some(Zone::Offset(330)))), "+1d 15:45 +330 > -");
    assert_eq!(expected(&spec(Some(DateSpec::Offset { days: 0 }), 7, 5, None, None)), "+0d 07:05 - > -");
    assert_eq!(expected(&spec(Some(DateSpec::Offset { days: -1 }), 23, 0, None, Some(Zone::City("new york")))), "-1d 23:00 America/New_York > -");
    assert_eq!(expected(&spec(Some(DateSpec::Weekday { weekday: 5, next: true }), 8, 15, None, None)), "w5:next 08:15 - > -");
    assert_eq!(expected(&spec(Some(DateSpec::Weekday { weekday: 1, next: false }), 13, 30, None, Some(Zone::City("london")))), "w1 13:30 Europe/London > -");
    assert_eq!(expected(&spec(Some(DateSpec::MonthDay { month: 1, day: 9 }), 0, 30, None, Some(Zone::Offset(-180)))), "01-09 00:30 -180 > -");
    assert_eq!(expected(&spec(None, 18, 0, None, Some(Zone::Offset(0)))), "- 18:00 +0 > -");
}

#[test]
fn sixteen_languages_each_with_at_least_eight_templates() {
    assert_eq!(LANGUAGES, ["zh-Hans", "zh-Hant", "ja", "ko", "en", "de", "es", "fr", "it", "nl", "pl", "pt-BR", "ru", "tr", "vi", "id"]);
    let plain = spec(None, 14, 30, None, None);
    for lang in LANGUAGES {
        assert!(template_count(lang) >= 8, "{lang}");
        let fits = (0..template_count(lang)).filter_map(|t| render(&plain, lang, t)).count();
        assert!(fits >= 1, "{lang}: some template must render a bare clock time");
    }
    assert_eq!(template_count("xx"), 0);
    assert_eq!(render(&plain, "xx", 0), None);
}

#[test]
fn cases_are_deterministic_and_balanced() {
    let a = cases(1, 40);
    assert_eq!(a, cases(1, 40));
    assert_ne!(a, cases(2, 40));
    assert_eq!(a.len(), 16 * 40);
    for lang in LANGUAGES {
        let mine: Vec<_> = a.iter().filter(|c| c.lang == lang).collect();
        assert_eq!(mine.len(), 40, "{lang}");
        assert!(mine.iter().all(|c| !c.text.trim().is_empty() && c.text.trim() == c.text && !c.text.contains('{') && !c.text.contains('}')));
        assert!(mine.iter().all(|c| c.want.ends_with(" > -") && c.want.split(' ').count() == 5), "{lang}");
        assert!(mine.iter().any(|c| !c.want.contains(" - > -")), "{lang}: some cases name a zone");
        assert!(mine.iter().any(|c| c.want.contains('–')), "{lang}: some cases are ranges");
        assert!(mine.iter().any(|c| !c.want.starts_with("- ")), "{lang}: some cases have a date");
    }
}

#[test]
fn jsonl_has_one_line_per_case() {
    let all = cases(3, 2);
    let text = to_jsonl(&all);
    assert_eq!(text.lines().count(), 32);
    for (line, case) in text.lines().zip(&all) {
        assert!(line.starts_with("{\"lang\":\"") && line.ends_with("\"}"), "{line}");
        assert!(line.contains("\"text\":\"") && line.contains("\"want\":\""), "{line}");
        assert!(line.contains(&case.want), "{line}");
    }
    assert_eq!(to_jsonl(&[]), "");
}
