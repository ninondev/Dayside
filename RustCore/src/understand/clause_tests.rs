// SPDX-License-Identifier: GPL-3.0-only
use super::*;

fn read(text: &str, language: &str) -> Output {
    understand(text, &Options { region: "US", ui_language: language, lookup: &|name, _| {
        matches!(fold_str(name).as_str(), "berlin" | "柏林")
            .then(|| ZoneRef::Region { iana: "Europe/Berlin".into() })
    } })
}

fn part_text(text: &str, mention: &Mention, kind: &str) -> Option<String> {
    mention.parts.iter().find(|p| p.kind == kind).map(|p| {
        String::from_utf16(&text.encode_utf16().collect::<Vec<_>>()[p.span[0]..p.span[1]]).unwrap()
    })
}

fn assert_split(text: &str, language: &str, inherited: bool) {
    let out = read(text, language);
    let start = usize::from(inherited);
    assert_eq!(out.mentions.len(), start + 2, "{text}: {out:?}");
    let time = &out.mentions[start];
    let date = &out.mentions[start + 1];
    assert_eq!(time.time, Some(Clock::at(18, 0)), "{text}: {out:?}");
    assert_eq!(time.date, inherited.then_some(DateSpec::Offset { days: 1 }), "{text}: {out:?}");
    assert_eq!(time.date_inherited, inherited, "{text}: {out:?}");
    assert_eq!(time.date_from, inherited.then_some(0), "{text}: {out:?}");
    assert!(part_text(text, time, "date").is_none(), "{text}: {out:?}");
    assert_eq!(date.date, Some(DateSpec::MonthDay { month: 10, day: 20 }), "{text}: {out:?}");
    assert!(date.time.is_none(), "{text}: {out:?}");
    assert!(!date.date_inherited, "{text}: {out:?}");
    assert!(date.date_from.is_none(), "{text}: {out:?}");
    assert!(time.span[1] <= date.span[0], "{text}: {out:?}");
    assert!(out.mentions.iter().all(|m| m.issues.is_empty()), "{text}: {out:?}");
}

#[test]
fn later_clause_date_keeps_the_lead_reproductions_separate() {
    for (text, language) in [
        ("明天9点PST开工，柏林18点同步，10月20日交报告", "zh-Hans"),
        ("Kickoff tomorrow 9am PST, Berlin sync at 18:00, report due Oct 20.", "en"),
    ] {
        assert_split(text, language, true);
        let out = read(text, language);
        assert_eq!(out.mentions[0].date, Some(DateSpec::Offset { days: 1 }));
        assert_eq!(out.mentions[0].time, Some(Clock::at(9, 0)));
        if language == "en" {
            assert!(out.mentions[1].source.is_none(), "{out:?}");
        } else {
            assert_eq!(out.mentions[1].source, Some(ZoneRef::Region { iana: "Europe/Berlin".into() }));
            assert_eq!(part_text(text, &out.mentions[1], "date"), None);
        }
    }
}

#[test]
fn later_clause_date_preserves_the_lead_controls() {
    for text in [
        "Kickoff tomorrow 9am PST, sync 18:00 Berlin, report due Oct 20.",
        "kickoff tmrw 9am PST, sync 18:00 Berlin, report due oct 20",
        "明天9点PST开工，柏林18点同步。10月20日交报告",
    ] {
        assert_split(text, "en", true);
        let out = read(text, "en");
        assert_eq!(out.mentions[1].source, Some(ZoneRef::Region { iana: "Europe/Berlin".into() }));
    }
    let text = "10月20日交报告，明天9点PST开工，柏林18点同步";
    let out = read(text, "zh-Hans");
    assert_eq!(out.mentions.len(), 3, "{out:?}");
    assert_eq!(out.mentions[0].date, Some(DateSpec::MonthDay { month: 10, day: 20 }));
    assert!(out.mentions[0].time.is_none());
    assert_eq!(out.mentions[1].date, Some(DateSpec::Offset { days: 1 }));
    assert_eq!(out.mentions[1].time, Some(Clock::at(9, 0)));
    assert_eq!(out.mentions[2].date, Some(DateSpec::Offset { days: 1 }));
    assert_eq!(out.mentions[2].time, Some(Clock::at(18, 0)));
    assert!(out.mentions[2].date_inherited);
    assert_eq!(out.mentions[2].date_from, Some(1));
    assert_eq!(out.mentions[2].source, Some(ZoneRef::Region { iana: "Europe/Berlin".into() }));
}

#[test]
fn later_clause_date_positive_and_negative_in_all_sixteen_languages() {
    let mut failures = Vec::new();
    for (language, positive, negative) in [
        ("en", "meet at 18:00, on Oct 20", "at 18:00, due Oct 20"),
        ("zh-Hans", "18点，在10月20日", "18点同步，10月20日交报告"),
        ("zh-Hant", "18點，在10月20日", "18點同步，10月20日交報告"),
        ("ja", "18時、10月20日", "18時会議、10月20日提出"),
        ("ko", "18시, 10월20일", "18시, 보고서 10월20일"),
        ("de", "18:00, 20. Oktober", "18:00, Bericht 20. Oktober"),
        ("fr", "18:00, le 20 octobre", "18:00, rapport 20 octobre"),
        ("es", "18:00, el 20 de octubre", "18:00, informe 20 de octubre"),
        ("ru", "18:00, 20 октября", "18:00, отчёт 20 октября"),
        ("pt-BR", "18:00, no dia 20 de outubro", "18:00, relatório 20 de outubro"),
        ("it", "18:00, il 20 ottobre", "18:00, rapporto 20 ottobre"),
        ("nl", "18:00, op 20 oktober", "18:00, verslag 20 oktober"),
        ("pl", "18:00, 20 października", "18:00, raport 20 października"),
        ("tr", "18:00, 20 Ekim", "18:00, rapor 20 Ekim"),
        ("vi", "18:00, vào ngày 20 tháng 10", "18:00, báo cáo ngày 20 tháng 10"),
        ("id", "18:00, pada tanggal 20 Oktober", "18:00, laporan tanggal 20 Oktober"),
    ] {
        let attached = read(positive, language);
        if attached.mentions.len() != 1 || attached.mentions[0].time != Some(Clock::at(18, 0))
            || attached.mentions[0].date != Some(DateSpec::MonthDay { month: 10, day: 20 })
            || attached.mentions[0].date_inherited || !attached.mentions[0].issues.is_empty() {
            failures.push(format!("{language} positive {positive}: {attached:?}"));
        }
        let separate = read(negative, language);
        if separate.mentions.len() != 2 || separate.mentions[0].time != Some(Clock::at(18, 0))
            || separate.mentions[0].date.is_some() || separate.mentions[1].time.is_some()
            || separate.mentions[1].date != Some(DateSpec::MonthDay { month: 10, day: 20 })
            || separate.mentions.iter().any(|m| !m.issues.is_empty()) {
            failures.push(format!("{language} negative {negative}: {separate:?}"));
        }
    }
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}

#[test]
fn later_clause_date_punctuation_and_known_activity_words() {
    for punctuation in [",", ";", "，", "；", "、", "-", "–", "—", "―"] {
        assert_split(&format!("18:00{punctuation} report due Oct 20"), "en", false);
        assert_split(&format!("18:00{punctuation} due Oct 20"), "en", false);
        assert_split(&format!("18点同步{punctuation}10月20日交报告"), "zh-Hans", false);
    }
    assert_split("18:00 meeting, Oct 20", "en", false);
    assert_split("18:00, call Oct 20", "en", false);
    assert_split("18:00 UTC, report Oct 20", "en", false);
    assert_split("18:00 Berlin, due Oct 20", "en", false);
}

#[test]
fn later_clause_date_still_attaches_in_one_expression() {
    for (text, expected_time, expected_date) in [
        ("meet at 18:00, Oct 20", Clock::at(18, 0), DateSpec::MonthDay { month: 10, day: 20 }),
        ("18:00 on Oct 20", Clock::at(18, 0), DateSpec::MonthDay { month: 10, day: 20 }),
        ("9am Friday", Clock::at(9, 0), DateSpec::Weekday { weekday: 5, week: None }),
        ("at 6pm, Monday the 5th", Clock::at(18, 0), DateSpec::Weekday { weekday: 1, week: None }),
        ("10月20日18点", Clock::at(18, 0), DateSpec::MonthDay { month: 10, day: 20 }),
        ("18点，10月20日", Clock::at(18, 0), DateSpec::MonthDay { month: 10, day: 20 }),
        ("18:00 UTC, on the 20th of October", Clock::at(18, 0), DateSpec::MonthDay { month: 10, day: 20 }),
        ("18:00 Berlin, on the 20th of October", Clock::at(18, 0), DateSpec::MonthDay { month: 10, day: 20 }),
        ("18:00 UTC on the 20th of October", Clock::at(18, 0), DateSpec::MonthDay { month: 10, day: 20 }),
        ("18:00, Friday, October 20", Clock::at(18, 0), DateSpec::MonthDay { month: 10, day: 20 }),
        ("18:00, on\nOct 20", Clock::at(18, 0), DateSpec::MonthDay { month: 10, day: 20 }),
    ] {
        let out = read(text, "en");
        assert_eq!(out.mentions.len(), 1, "{text}: {out:?}");
        assert_eq!(out.mentions[0].time, Some(expected_time), "{text}: {out:?}");
        assert_eq!(out.mentions[0].date, Some(expected_date), "{text}: {out:?}");
        assert!(!out.mentions[0].date_inherited);
        assert!(out.mentions[0].issues.is_empty(), "{text}: {out:?}");
    }
}

#[test]
fn later_clause_date_does_not_change_unpunctuated_narrative() {
    let out = read("18:00 due Oct 20", "en");
    assert_eq!(out.mentions.len(), 1, "{out:?}");
    assert_eq!(out.mentions[0].date, Some(DateSpec::MonthDay { month: 10, day: 20 }));
    assert_eq!(out.mentions[0].time, Some(Clock::at(18, 0)));
}
