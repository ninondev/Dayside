// SPDX-License-Identifier: GPL-3.0-only
use super::*;

fn read(text: &str) -> Output {
    understand(text, &Options { region: "GB", ui_language: "en", lookup: &|_, _| None })
}

#[test]
fn clock_followed_by_its_own_date_does_not_take_range_start() {
    for text in [
        "2027-04-02 to 17:25 on 6 April 2027",
        "2027-04-02 to 17:25–18:35 on 6 April 2027",
        "2027-04-02 bis um 17:25 am 6.4.2027",
        "Từ 2/4/2027 đến 17 giờ 25 ngày 6/4/2027",
        "Từ 2/4/2027 đến 17 giờ 00 ngày 6/4/2027",
        "2027-04-02\n\n17:25 on 6 April 2027",
    ] {
        let out = read(text);
        assert_eq!(out.mentions.len(), 2, "{text}: {out:?}");
        assert_eq!(out.mentions[0].date, Some(DateSpec::Absolute { year: 2027, month: 4, day: 2 }), "{text}");
        assert!(out.mentions[0].time.is_none(), "{text}: {out:?}");
        assert_eq!(out.mentions[1].date, Some(DateSpec::Absolute { year: 2027, month: 4, day: 6 }), "{text}: {out:?}");
        let minute = if text.contains("giờ 00") { 0 } else { 25 };
        assert_eq!(out.mentions[1].time, Some(Clock::at(17, minute)), "{text}");
        if text.contains("giờ 00") {
            let part = out.mentions[1].parts.iter().find(|part| part.kind == "time").unwrap();
            assert!(String::from_utf16(&text.encode_utf16().collect::<Vec<_>>()[part.span[0]..part.span[1]]).unwrap().contains("00"));
        }
        assert!(!out.mentions[1].date_inherited, "{text}");
        assert!(out.mentions[1].date_from.is_none(), "{text}");
        assert!(serde_json::to_value(&out.mentions[1]).unwrap().get("series").is_none());
        assert!(date_part(text, &out.mentions[1]).contains('6'), "{text}");
    }
    let text = "17 giờ 00 ngày 5/8/2027";
    let out = read(text);
    assert_eq!(out.mentions.len(), 1, "{out:?}");
    assert_eq!(out.mentions[0].date, Some(DateSpec::Absolute { year: 2027, month: 8, day: 5 }));
    assert_eq!(out.mentions[0].time, Some(Clock::at(17, 0)));
    let part = out.mentions[0].parts.iter().find(|p| p.kind == "time").unwrap();
    assert_eq!(String::from_utf16(&text.encode_utf16().collect::<Vec<_>>()[part.span[0]..part.span[1]]).unwrap(), "17 giờ 00");
    let duration = read("trong 17 giờ 25 ngày 6/4/2027");
    assert!(duration.mentions.iter().all(|m| m.time.is_none()), "{duration:?}");
}

fn date_part(text: &str, mention: &Mention) -> String {
    let span = mention.parts.iter().find(|p| p.kind == "date").unwrap().span;
    String::from_utf16(&text.encode_utf16().collect::<Vec<_>>()[span[0]..span[1]]).unwrap()
}

fn assert_series(out: &Output, first: usize, count: usize) {
    for m in &out.mentions[first..first + count] {
        let json = serde_json::to_value(m).unwrap();
        assert_eq!(json.get("series").and_then(|v| v.as_u64()), Some(first as u64), "{out:?}");
        assert_eq!(m.span, out.mentions[first].span, "{out:?}");
    }
}

#[test]
fn day_lists_share_a_clock_but_separate_clocks_keep_their_days() {
    let text = "Tuesday and Thursday 13:20–15:40 UTC";
    let out = read(text);
    assert_eq!(out.mentions.len(), 2, "{out:?}");
    assert_series(&out, 0, 2);
    for (m, weekday) in out.mentions.iter().zip([2, 4]) {
        assert_eq!(m.date, Some(DateSpec::Weekday { weekday, week: None }));
        assert_eq!(m.time, Some(Clock::at(13, 20)));
        assert_eq!(m.end, Some(Clock::at(15, 40)));
        assert_eq!(m.source, Some(ZoneRef::Fixed { minutes: 0, region: None }));
    }
    assert_eq!(date_part(text, &out.mentions[0]), "Tuesday");
    assert_eq!(date_part(text, &out.mentions[1]), "Thursday");
    let separate = read("Tuesday 13:20–15:40 UTC, Thursday 16:15–18:05 UTC");
    assert_eq!(separate.mentions.len(), 2, "{separate:?}");
    assert_eq!(separate.mentions[0].date, Some(DateSpec::Weekday { weekday: 2, week: None }));
    assert_eq!(separate.mentions[1].date, Some(DateSpec::Weekday { weekday: 4, week: None }));
    assert!(separate.mentions.iter().all(|m| serde_json::to_value(m).unwrap().get("series").is_none()));
    assert_eq!((separate.mentions[0].time, separate.mentions[0].end), (Some(Clock::at(13, 20)), Some(Clock::at(15, 40))));
    assert_eq!((separate.mentions[1].time, separate.mentions[1].end), (Some(Clock::at(16, 15)), Some(Clock::at(18, 5))));
    let reordered = read("Thursday, Tuesday and Friday at 16:25");
    assert_series(&reordered, 0, 3);
    assert_eq!(reordered.mentions.iter().map(|m| m.date.clone()).collect::<Vec<_>>(), [4, 2, 5].map(|weekday| Some(DateSpec::Weekday { weekday, week: None })));
}

#[test]
fn weekday_ranges_keep_shared_zone_and_written_day_parts() {
    let text = "Wednesday to Friday 08:45 CET";
    let out = read(text);
    assert_eq!(out.mentions.len(), 3, "{out:?}");
    assert_series(&out, 0, 3);
    for (m, weekday) in out.mentions.iter().zip(3..=5) {
        assert_eq!(m.date, Some(DateSpec::Weekday { weekday, week: None }));
        assert_eq!(m.time, Some(Clock::at(8, 45)));
        assert!(matches!(m.source, Some(ZoneRef::Fixed { minutes: 60, .. })));
    }
    assert_eq!(date_part(text, &out.mentions[0]), "Wednesday");
    assert_eq!(date_part(text, &out.mentions[1]), "Wednesday to Friday");
    assert_eq!(date_part(text, &out.mentions[2]), "Friday");
    let single = read("Wednesday 08:45 CET");
    assert_eq!(single.mentions.len(), 1);
    assert_eq!(single.mentions[0].date, Some(DateSpec::Weekday { weekday: 3, week: None }));
    assert!(serde_json::to_value(&single.mentions[0]).unwrap().get("series").is_none());
}

#[test]
fn every_weekday_in_an_explicit_month_has_four_or_five_dates() {
    for (text, month, days) in [
        ("Every Monday in February 2027 at 14:35", 2, vec![1, 8, 15, 22]),
        ("Every Monday in March 2027 at 14:35", 3, vec![1, 8, 15, 22, 29]),
    ] {
        let out = read(text);
        assert_eq!(out.mentions.len(), days.len(), "{text}: {out:?}");
        assert_series(&out, 0, days.len());
        for (m, day) in out.mentions.iter().zip(days) {
            assert_eq!(m.date, Some(DateSpec::Absolute { year: 2027, month, day }), "{text}");
            assert_eq!(m.time, Some(Clock::at(14, 35)));
            assert_eq!(date_part(text, m), "Monday");
        }
    }
    let since = read("Every Monday since February 2027 at 14:35");
    assert!(since.mentions.iter().all(|m| serde_json::to_value(m).unwrap().get("series").is_none()), "{since:?}");
    let invalid = read("Every Monday, deadline 31 February 2027, at 14:35");
    assert!(invalid.mentions.iter().all(|m| serde_json::to_value(m).unwrap().get("series").is_none()));
    let zoned = read("Every Monday UTC in March 2027 at 14:35");
    assert_series(&zoned, 0, 5);
    assert!(zoned.mentions.iter().all(|m| m.source == Some(ZoneRef::Fixed { minutes: 0, region: None })), "{zoned:?}");
}

#[test]
fn short_daily_date_ranges_expand_and_long_ranges_keep_endpoints() {
    let text = "2027-06-08 to 2027-06-10, 09:15–16:40";
    let out = read(text);
    assert_eq!(out.mentions.len(), 3, "{out:?}");
    assert_series(&out, 0, 3);
    for (m, day) in out.mentions.iter().zip(8..=10) {
        assert_eq!(m.date, Some(DateSpec::Absolute { year: 2027, month: 6, day }));
        assert_eq!(m.time, Some(Clock::at(9, 15)));
        assert_eq!(m.end, Some(Clock::at(16, 40)));
    }
    assert_eq!(date_part(text, &out.mentions[0]), "2027-06-08");
    assert_eq!(date_part(text, &out.mentions[1]), "2027-06-08 to 2027-06-10");
    assert_eq!(date_part(text, &out.mentions[2]), "2027-06-10");
    let shared_year = read("8 June to 10 June 2027, 09:15–16:40");
    assert_series(&shared_year, 0, 3);
    assert_eq!(shared_year.mentions.iter().map(|m| m.date.clone()).collect::<Vec<_>>(), [8, 9, 10].map(|day| Some(DateSpec::Absolute { year: 2027, month: 6, day })));
    let plain_shared_year = read("8 June to 10 June 2027");
    assert_eq!(plain_shared_year.mentions.len(), 2, "{plain_shared_year:?}");
    assert_eq!(plain_shared_year.mentions.iter().map(|m| m.date.clone()).collect::<Vec<_>>(), [8, 10].map(|day| Some(DateSpec::Absolute { year: 2027, month: 6, day })));
    for (text, expected) in [("2028-02-28 to 2028-03-01, 09:15–16:40", 3), ("2027-02-28 to 2027-03-01, 09:15–16:40", 2)] {
        let leap = read(text);
        assert_eq!(leap.mentions.len(), expected, "{leap:?}");
        assert_series(&leap, 0, expected);
    }
    let plain = read("2027-06-08 to 2027-06-10");
    assert_eq!(plain.mentions.len(), 2, "{plain:?}");
    assert!(plain.mentions.iter().all(|m| m.time.is_none() && m.end.is_none()));
    assert_eq!(plain.mentions.iter().map(|m| m.date.clone()).collect::<Vec<_>>(), [8, 10].map(|day| Some(DateSpec::Absolute { year: 2027, month: 6, day })));
    let long = read("2027-06-08 to 2027-06-18, 09:15–16:40");
    assert_eq!(long.mentions.len(), 2, "{long:?}");
    for (m, day) in long.mentions.iter().zip([8, 18]) {
        assert_eq!(m.date, Some(DateSpec::Absolute { year: 2027, month: 6, day }));
        assert_eq!(m.time, Some(Clock::at(9, 15)));
        assert_eq!(m.end, Some(Clock::at(16, 40)));
    }
}

#[test]
fn overnight_daily_range_stops_on_the_last_morning() {
    let out = read("Du 8 juin 2027 au 10 juin 2027, de 23h à 5h");
    assert_eq!(out.mentions.len(), 2, "{out:?}");
    assert_series(&out, 0, 2);
    for (m, day) in out.mentions.iter().zip([8, 9]) {
        assert_eq!(m.date, Some(DateSpec::Absolute { year: 2027, month: 6, day }));
        assert_eq!(m.time, Some(Clock::at(23, 0)));
        assert_eq!(m.end, Some(Clock { hour: 5, minute: 0, second: 0, day_offset: 1 }));
    }
    let daytime = read("Du 8 juin 2027 au 10 juin 2027, de 8h à 16h");
    assert_eq!(daytime.mentions.len(), 3, "{daytime:?}");
    assert_series(&daytime, 0, 3);
    for (m, day) in daytime.mentions.iter().zip(8..=10) {
        assert_eq!(m.date, Some(DateSpec::Absolute { year: 2027, month: 6, day }));
        assert_eq!(m.time, Some(Clock::at(8, 0)));
        assert_eq!(m.end, Some(Clock::at(16, 0)));
    }
}

#[test]
fn series_indices_follow_the_first_mention_and_skip_non_series() {
    let out = read("Call at 07:45. Monday and Wednesday 12:35. Friday and Sunday 17:50.");
    assert_eq!(out.mentions.len(), 5, "{out:?}");
    assert!(serde_json::to_value(&out.mentions[0]).unwrap().get("series").is_none());
    assert_series(&out, 1, 2);
    assert_series(&out, 3, 2);
}

#[test]
fn shared_day_lists_and_ranges_use_all_sixteen_closed_tables() {
    let cases = [
        ("en", "Tuesday and Thursday 13:25", "Tuesday to Thursday 13:25"),
        ("de", "Dienstag und Donnerstag 13:25", "Dienstag bis Donnerstag 13:25"),
        ("es", "martes y jueves 13:25", "martes al jueves 13:25"),
        ("fr", "mardi et jeudi 13:25", "mardi à jeudi 13:25"),
        ("it", "martedì e giovedì 13:25", "martedì al giovedì 13:25"),
        ("ja", "火曜日と木曜日13:25", "火曜日～木曜日13:25"),
        ("ko", "화요일과 목요일 13:25", "화요일부터 목요일까지 13:25"),
        ("nl", "dinsdag en donderdag 13:25", "dinsdag tot donderdag 13:25"),
        ("pl", "wtorek i czwartek 13:25", "wtorek do czwartek 13:25"),
        ("ru", "вторник и четверг 13:25", "вторник–четверг 13:25"),
        ("tr", "Salı ve Perşembe 13:25", "Salı–Perşembe 13:25"),
        ("vi", "thứ ba và thứ năm 13:25", "thứ ba đến thứ năm 13:25"),
        ("id", "Selasa dan Kamis 13:25", "Selasa s.d. Kamis 13:25"),
        ("pt-BR", "terça-feira e quinta-feira 13:25", "terça-feira até quinta-feira 13:25"),
        ("zh-Hans", "周二和周四13:25", "周二至周四13:25"),
        ("zh-Hant", "週二及週四13:25", "週二至週四13:25"),
    ];
    for (lang, list, range) in cases {
        for (text, weekdays) in [(list, vec![2, 4]), (range, vec![2, 3, 4])] {
            let out = understand(text, &Options { region: "GB", ui_language: lang, lookup: &|_, _| None });
            assert_eq!(out.mentions.len(), weekdays.len(), "{lang}: {text}: {out:?}");
            assert_series(&out, 0, weekdays.len());
            for (m, weekday) in out.mentions.iter().zip(weekdays) {
                assert_eq!(m.date, Some(DateSpec::Weekday { weekday, week: None }), "{lang}: {text}");
                assert_eq!(m.time, Some(Clock::at(13, 25)), "{lang}: {text}");
            }
        }
    }
}

#[test]
fn monthly_weekdays_use_each_languages_every_form() {
    let cases = [
        ("en", "Every Monday in February 2027 at 14:35"),
        ("de", "Jeden Montag im Februar 2027 um 14:35"),
        ("es", "Cada lunes de febrero de 2027 a las 14:35"),
        ("fr", "Chaque lundi en février 2027 à 14:35"),
        ("it", "Ogni lunedì a febbraio 2027 alle 14:35"),
        ("ja", "2027年2月の毎週月曜日14:35"),
        ("ko", "2027년2월 매주 월요일 14:35"),
        ("nl", "Elke maandag in februari 2027 om 14:35"),
        ("pl", "Każdy poniedziałek w lutym 2027 o 14:35"),
        ("ru", "Каждый понедельник в феврале 2027 в 14:35"),
        ("tr", "2027 Şubat ayında her Pazartesi 14:35"),
        ("vi", "Mỗi thứ hai trong tháng 2 năm 2027 lúc 14:35"),
        ("id", "Setiap Senin pada bulan Februari 2027 pukul 14:35"),
        ("pt-BR", "Toda segunda-feira em fevereiro de 2027 às 14:35"),
        ("zh-Hans", "2027年2月每周一14:35"),
        ("zh-Hant", "2027年2月每週一14:35"),
    ];
    for (lang, text) in cases {
        let out = understand(text, &Options { region: "GB", ui_language: lang, lookup: &|_, _| None });
        assert_eq!(out.mentions.len(), 4, "{lang}: {text}: {out:?}");
        assert_series(&out, 0, 4);
        for (m, day) in out.mentions.iter().zip([1, 8, 15, 22]) {
            assert_eq!(m.date, Some(DateSpec::Absolute { year: 2027, month: 2, day }), "{lang}: {text}");
            assert_eq!(m.time, Some(Clock::at(14, 35)), "{lang}: {text}");
        }
    }
}

#[test]
fn series_spans_and_conversion_targets_cover_the_shared_clock() {
    let text = "🙂 Tuesday, Thursday and Saturday at 12:40 UTC → JST";
    let out = read(text);
    assert_eq!(out.mentions.len(), 3, "{out:?}");
    assert_series(&out, 0, 3);
    let start = text[..text.find("Tuesday").unwrap()].encode_utf16().count();
    let end = text[..text.find(" UTC").unwrap()].encode_utf16().count();
    for m in &out.mentions {
        assert_eq!(m.span, [start, end]);
        assert!(matches!(m.target, Some(ZoneRef::Fixed { minutes: 540, .. })), "{out:?}");
        assert_eq!(m.source, Some(ZoneRef::Fixed { minutes: 0, region: None }));
    }
    let separate = read("Tuesday 12:40 UTC, Thursday 15:20 UTC → JST");
    assert_eq!(separate.mentions.len(), 2, "{separate:?}");
    assert!(separate.mentions[0].target.is_none());
    assert!(separate.mentions[1].target.is_some());
}

#[test]
fn ambiguous_slash_days_keep_their_candidates() {
    let out = read("8/6 and 10/6 at 13:20");
    assert_eq!(out.mentions.len(), 2, "{out:?}");
    assert_series(&out, 0, 2);
    for (m, day) in out.mentions.iter().zip([8, 10]) {
        assert_eq!(m.date, Some(DateSpec::MonthDay { month: 6, day }));
        assert!(m.alternatives.iter().any(|alt| matches!(alt, types::Alternative::DateOrder { date: DateSpec::MonthDay { month, day: 6 } } if *month == day)), "{out:?}");
    }
    let range = read("8/6 to 10/6 at 13:20");
    assert_eq!(range.mentions.len(), 2, "{range:?}");
    assert_series(&range, 0, 2);
    assert!(range.mentions.iter().all(|m| m.alternatives.iter().any(|alt| matches!(alt, types::Alternative::DateOrder { .. }))));
}

#[test]
fn unit7_followup_no_clock_weekday_lists_and_ranges_stay_out() {
    for text in ["Tuesday and Friday", "Friday, Tuesday and Wednesday", "dienstags und freitags", "火曜と金曜", "dienstags bis samstags", "Selasa sampai Kamis", "Tue–Sat", "火曜～土曜", "周二至周六", "Tuesday"] {
        let out = read(text);
        assert!(out.mentions.is_empty(), "{text}: {out:?}");
    }
}

fn assert_distinct_series_groups(out: &Output) {
    for (i, first) in out.mentions.iter().enumerate() {
        for second in &out.mentions[i + 1..] {
            if first.series.is_some() && first.series == second.series {
                assert_ne!(first.group, second.group, "{out:?}");
            }
        }
    }
}

#[test]
fn unit7_followup_calendar_range_requires_daily_clock_range_to_interpolate() {
    for (text, days, clock) in [
        ("2027-06-08 to 2027-06-10", vec![8, 10], None),
        ("2027-06-08 to 2027-06-10 at 09:15", vec![8, 10], Some(Clock::at(9, 15))),
        ("2027-06-08 to 2027-06-10, 09:15–16:40", vec![8, 9, 10], Some(Clock::at(9, 15))),
        ("2027-06-01 to 2027-06-07, 09:15–16:40", vec![1, 2, 3, 4, 5, 6, 7], Some(Clock::at(9, 15))),
        ("2027-06-01 to 2027-06-08, 09:15–16:40", vec![1, 8], Some(Clock::at(9, 15))),
    ] {
        let out = read(text);
        assert_eq!(out.mentions.len(), days.len(), "{text}: {out:?}");
        assert_series(&out, 0, days.len());
        assert_distinct_series_groups(&out);
        for (mention, day) in out.mentions.iter().zip(days) {
            assert_eq!(mention.date, Some(DateSpec::Absolute { year: 2027, month: 6, day }), "{text}: {out:?}");
            assert_eq!(mention.time, clock, "{text}: {out:?}");
        }
    }
    let weekdays = read("Tuesday to Thursday at 09:15");
    assert_eq!(weekdays.mentions.len(), 3, "{weekdays:?}");
    assert_series(&weekdays, 0, 3);
}

#[test]
fn unit7_followup_monthly_weekdays_need_no_clock() {
    for text in ["every Wednesday in March 2027", "2027년 3월 매주 수요일", "2027年3月の毎週水曜"] {
        let out = read(text);
        assert_eq!(out.mentions.len(), 5, "{text}: {out:?}");
        assert_series(&out, 0, 5);
        assert_distinct_series_groups(&out);
        for (mention, day) in out.mentions.iter().zip([3, 10, 17, 24, 31]) {
            assert_eq!(mention.date, Some(DateSpec::Absolute { year: 2027, month: 3, day }), "{text}: {out:?}");
            assert!(mention.time.is_none() && mention.end.is_none(), "{text}: {out:?}");
        }
    }
}

#[test]
fn unit7_followup_rule12_exact_calendar_lists_share_only_written_fields() {
    for (text, month, days) in [
        ("les 3 et 19 octobre", 10, vec![3, 19]),
        ("agosto 4, 5, 6 y 7", 8, vec![4, 5, 6, 7]),
        ("nos dias 12 e 13 de março", 3, vec![12, 13]),
    ] {
        let out = read(text);
        assert_eq!(out.mentions.len(), days.len(), "{text}: {out:?}");
        assert_series(&out, 0, days.len());
        assert_distinct_series_groups(&out);
        for (mention, day) in out.mentions.iter().zip(days) {
            assert_eq!(mention.date, Some(DateSpec::MonthDay { month, day }), "{text}: {out:?}");
            assert!(mention.time.is_none() && mention.end.is_none(), "{text}: {out:?}");
        }
    }
    let out = read("les 3 et 19 octobre à 13:25 UTC");
    assert_eq!(out.mentions.len(), 2, "{out:?}");
    assert_series(&out, 0, 2);
    assert_distinct_series_groups(&out);
    for (mention, day) in out.mentions.iter().zip([3, 19]) {
        assert_eq!(mention.date, Some(DateSpec::MonthDay { month: 10, day }));
        assert_eq!(mention.time, Some(Clock::at(13, 25)));
        assert_eq!(mention.source, Some(ZoneRef::Fixed { minutes: 0, region: None }));
    }
}

#[test]
fn unit7_followup_rule12_exact_date_ranges_keep_endpoints() {
    for (text, dates) in [
        ("3–9 April 2027", vec![(2027, 4, 3), (2027, 4, 9)]),
        ("12-14.03.2027", vec![(2027, 3, 12), (2027, 3, 14)]),
        ("del 2 de febrero al 15 de mayo de 2027", vec![(2027, 2, 2), (2027, 5, 15)]),
        ("từ ngày 3/6 đến ngày 10/6/2027", vec![(2027, 6, 3), (2027, 6, 10)]),
    ] {
        let out = read(text);
        assert_eq!(out.mentions.len(), dates.len(), "{text}: {out:?}");
        assert_series(&out, 0, dates.len());
        assert_distinct_series_groups(&out);
        for (mention, (year, month, day)) in out.mentions.iter().zip(dates) {
            assert_eq!(mention.date, Some(DateSpec::Absolute { year, month, day }), "{text}: {out:?}");
            assert!(mention.time.is_none() && mention.end.is_none(), "{text}: {out:?}");
        }
    }
}

#[test]
fn unit7_followup_rule12_exact_daily_ranges_share_clocks_and_finish_last_morning() {
    let text = "du mardi 11 au jeudi 13 mars, de 23h à 5h";
    let out = read(text);
    assert_eq!(out.mentions.len(), 2, "{out:?}");
    assert_series(&out, 0, 2);
    assert_distinct_series_groups(&out);
    for (mention, day) in out.mentions.iter().zip([11, 12]) {
        assert_eq!(mention.date, Some(DateSpec::MonthDay { month: 3, day }), "{out:?}");
        assert_eq!(mention.time, Some(Clock::at(23, 0)), "{out:?}");
        assert_eq!(mention.end, Some(Clock { hour: 5, minute: 0, second: 0, day_offset: 1 }), "{out:?}");
    }
    let out = read("Sprechstunde dienstags bis donnerstags 9–12 Uhr.");
    assert_eq!(out.mentions.len(), 3, "{out:?}");
    assert_series(&out, 0, 3);
    assert_distinct_series_groups(&out);
    for (mention, weekday) in out.mentions.iter().zip(2..=4) {
        assert_eq!(mention.date, Some(DateSpec::Weekday { weekday, week: None }));
        assert_eq!(mention.time, Some(Clock::at(9, 0)));
        assert_eq!(mention.end, Some(Clock::at(12, 0)));
    }
}

#[test]
fn unit7_followup_conservative_unspecified_cases_do_not_invent_series_dates() {
    for text in [
        "Every Wednesday in March at 13:25",
        "Friday to Monday at 13:25",
        "This Tuesday to next Thursday at 13:25",
    ] {
        let out = read(text);
        assert!(out.mentions.iter().all(|mention| mention.series.is_none()), "{text}: {out:?}");
    }
    let out = read("28 February to 1 March, 09:15–16:40");
    assert_eq!(out.mentions.len(), 2, "{out:?}");
    assert_series(&out, 0, 2);
    assert_eq!(out.mentions.iter().map(|mention| mention.date.clone()).collect::<Vec<_>>(),
        [Some(DateSpec::MonthDay { month: 2, day: 28 }), Some(DateSpec::MonthDay { month: 3, day: 1 })]);
}

#[test]
fn unit7_followup_date_only_series_share_zone_and_keep_independent_mentions() {
    let out = read("3 and 19 October UTC. 2027-10-11.");
    assert_eq!(out.mentions.len(), 3, "{out:?}");
    assert_series(&out, 0, 2);
    assert_distinct_series_groups(&out);
    for mention in &out.mentions[..2] {
        assert_eq!(mention.source, Some(ZoneRef::Fixed { minutes: 0, region: None }), "{out:?}");
        assert!(mention.time.is_none());
    }
    assert!(out.mentions[2].series.is_none(), "{out:?}");
}

#[test]
fn unit7_followup_shared_calendar_grammar_respects_claimed_numbers_and_own_clocks() {
    for text in [
        "version 3–9 April 2027",
        "for 3 hours and 19 October",
        "at 3 and 19 October",
        "April 3, 5pm",
        "3 April 2027 at 09:15 and 19 April 2027 at 16:40",
    ] {
        let out = read(text);
        assert!(out.mentions.iter().all(|mention| mention.series.is_none()), "{text}: {out:?}");
    }
    let out = read("April 3, 5pm");
    assert_eq!(out.mentions.len(), 1, "{out:?}");
    assert_eq!(out.mentions[0].date, Some(DateSpec::MonthDay { month: 4, day: 3 }));
    assert_eq!(out.mentions[0].time, Some(Clock::at(17, 0)));
}

#[test]
fn unit7_followup_ambiguous_date_only_range_keeps_candidates_and_versions_stay_blocked() {
    let out = read("8/6 to 10/6");
    assert_eq!(out.mentions.len(), 2, "{out:?}");
    assert_series(&out, 0, 2);
    for (mention, day) in out.mentions.iter().zip([8, 10]) {
        assert_eq!(mention.date, Some(DateSpec::MonthDay { month: 6, day }), "{out:?}");
        assert_eq!(mention.alternatives.len(), 1, "{out:?}");
        assert!(mention.alternatives.iter().any(|alt| matches!(alt,
            types::Alternative::DateOrder { date: DateSpec::MonthDay { month, day: 6 } } if *month == day)), "{out:?}");
    }
    assert!(read("version 12-14.03.2027").mentions.is_empty());
}

#[test]
fn unit7_followup_shared_deadline_idioms_carry_their_existing_clock() {
    for (text, hour, minute, implied) in [
        ("Tuesday and Friday EOD", 17, 0, Some("eod")),
        ("Tuesday and Friday by noon", 12, 0, None),
        ("Tuesday and Friday before midnight", 23, 59, Some("midnight")),
        ("Tuesday and Friday noon", 12, 0, None),
    ] {
        let out = read(text);
        assert_eq!(out.mentions.len(), 2, "{text}: {out:?}");
        assert_series(&out, 0, 2);
        assert_distinct_series_groups(&out);
        for (mention, weekday) in out.mentions.iter().zip([2, 5]) {
            assert_eq!(mention.date, Some(DateSpec::Weekday { weekday, week: None }), "{text}: {out:?}");
            assert_eq!(mention.time, Some(Clock::at(hour, minute)), "{text}: {out:?}");
            assert_eq!(mention.time_implied, implied, "{text}: {out:?}");
        }
    }
    let monthly = read("Every Monday in March 2027 EOD");
    assert_eq!(monthly.mentions.len(), 5, "{monthly:?}");
    assert_series(&monthly, 0, 5);
    assert!(monthly.mentions.iter().all(|mention| mention.time == Some(Clock::at(17, 0)) && mention.time_implied == Some("eod")));
    let separate = read("Tuesday EOD, Friday by noon");
    assert_eq!(separate.mentions.len(), 2, "{separate:?}");
    assert!(separate.mentions.iter().all(|mention| mention.series.is_none()), "{separate:?}");
    assert_eq!(separate.mentions[0].time, Some(Clock::at(17, 0)));
    assert_eq!(separate.mentions[1].time, Some(Clock::at(12, 0)));
}

#[test]
fn unit7_followup_shared_series_before_an_independently_dated_clock_stays_intact() {
    let out = read("Tuesday and Friday 09:15, 11 October 2027 at 10:30");
    assert_eq!(out.mentions.len(), 3, "{out:?}");
    assert_series(&out, 0, 2);
    assert_distinct_series_groups(&out);
    for (mention, weekday) in out.mentions[..2].iter().zip([2, 5]) {
        assert_eq!(mention.date, Some(DateSpec::Weekday { weekday, week: None }), "{out:?}");
        assert_eq!(mention.time, Some(Clock::at(9, 15)), "{out:?}");
    }
    assert_eq!(out.mentions[2].date, Some(DateSpec::Absolute { year: 2027, month: 10, day: 11 }));
    assert_eq!(out.mentions[2].time, Some(Clock::at(10, 30)));
    assert!(out.mentions[2].series.is_none(), "{out:?}");
}

#[test]
fn unit7_followup_series_date_heading_merges_all_days_into_its_shared_clock() {
    for text in ["3 and 19 October. Call at 09:15.", "3 and 19 October\n\n09:15"] {
        let out = read(text);
        assert_eq!(out.mentions.len(), 2, "{text}: {out:?}");
        assert_series(&out, 0, 2);
        assert_distinct_series_groups(&out);
        for (mention, day) in out.mentions.iter().zip([3, 19]) {
            assert_eq!(mention.date, Some(DateSpec::MonthDay { month: 10, day }), "{text}: {out:?}");
            assert_eq!(mention.time, Some(Clock::at(9, 15)), "{text}: {out:?}");
        }
    }
    let out = read("3 and 19 October. Call on 21 October at 09:15.");
    assert_eq!(out.mentions.len(), 3, "{out:?}");
    assert_series(&out, 0, 2);
    assert!(out.mentions[..2].iter().all(|mention| mention.time.is_none()), "{out:?}");
    assert_eq!(out.mentions[2].date, Some(DateSpec::MonthDay { month: 10, day: 21 }));
    assert_eq!(out.mentions[2].time, Some(Clock::at(9, 15)));
    assert!(out.mentions[2].series.is_none(), "{out:?}");
}

#[test]
fn unit7_followup_single_line_break_keeps_an_explicit_shared_clock() {
    for text in ["Tuesday and Friday\n09:15", "Tuesday to Thursday\n09:15"] {
        let out = read(text);
        let weekdays = if text.contains("to") { vec![2, 3, 4] } else { vec![2, 5] };
        assert_eq!(out.mentions.len(), weekdays.len(), "{text}: {out:?}");
        assert_series(&out, 0, weekdays.len());
        for (mention, weekday) in out.mentions.iter().zip(weekdays) {
            assert_eq!(mention.date, Some(DateSpec::Weekday { weekday, week: None }));
            assert_eq!(mention.time, Some(Clock::at(9, 15)));
        }
    }
}

#[test]
fn unit7_followup_date_range_heading_uses_the_shared_daily_clock_range() {
    for (text, days, start, end) in [
        ("2027-06-08 to 2027-06-10\n\n09:15–16:40", vec![8, 9, 10], Clock::at(9, 15), Clock::at(16, 40)),
        ("2027-06-08 to 2027-06-10\n\n23:15–04:40", vec![8, 9], Clock::at(23, 15), Clock { hour: 4, minute: 40, second: 0, day_offset: 1 }),
        ("2027-06-08 to 2027-06-18\n\n09:15–16:40", vec![8, 18], Clock::at(9, 15), Clock::at(16, 40)),
        ("2027-06-08 and 2027-06-10\n\n23:15–04:40", vec![8, 10], Clock::at(23, 15), Clock { hour: 4, minute: 40, second: 0, day_offset: 1 }),
    ] {
        let out = read(text);
        assert_eq!(out.mentions.len(), days.len(), "{text}: {out:?}");
        assert_series(&out, 0, days.len());
        assert_distinct_series_groups(&out);
        for (mention, day) in out.mentions.iter().zip(days) {
            assert_eq!(mention.date, Some(DateSpec::Absolute { year: 2027, month: 6, day }), "{text}: {out:?}");
            assert_eq!(mention.time, Some(start), "{text}: {out:?}");
            assert_eq!(mention.end, Some(end), "{text}: {out:?}");
        }
    }
}

#[test]
fn unit7_followup_series_heading_shares_following_clock_and_metadata() {
    for text in [
        "Tuesday and Friday. Meeting at 09:00 UTC.",
        "Tuesday and Friday\n\n09:00 UTC",
        "Tuesday and Friday\n09:00 UTC",
    ] {
        let out = read(text);
        assert_eq!(out.mentions.len(), 2, "{text}: {out:?}");
        assert_series(&out, 0, 2);
        assert_ne!(out.mentions[0].group, out.mentions[1].group, "{text}: {out:?}");
        for (m, weekday) in out.mentions.iter().zip([2, 5]) {
            assert_eq!(m.date, Some(DateSpec::Weekday { weekday, week: None }), "{text}: {out:?}");
            assert_eq!(m.time, Some(Clock::at(9, 0)), "{text}: {out:?}");
            assert_eq!(m.source, Some(ZoneRef::Fixed { minutes: 0, region: None }), "{text}: {out:?}");
            assert!(m.end.is_none() && m.alternatives.is_empty(), "{text}: {out:?}");
            assert!(!m.date_inherited && m.date_from.is_none(), "{text}: {out:?}");
            assert!(m.issues.is_empty(), "{text}: {out:?}");
            let end = text[..text.find(" UTC").unwrap()].encode_utf16().count();
            assert_eq!(m.span, [0, end], "{text}: {out:?}");
        }
    }
}

#[test]
fn unit7_followup_series_heading_keeps_each_dates_exact_alternative() {
    for text in ["8/6 and 10/6. Meeting at 09:00 UTC.", "8/6 and 10/6\n\n09:00 UTC"] {
        let out = read(text);
        assert_eq!(out.mentions.len(), 2, "{text}: {out:?}");
        assert_series(&out, 0, 2);
        assert_ne!(out.mentions[0].group, out.mentions[1].group, "{text}: {out:?}");
        for (m, day) in out.mentions.iter().zip([8, 10]) {
            assert_eq!(m.date, Some(DateSpec::MonthDay { month: 6, day }), "{text}: {out:?}");
            assert_eq!(m.time, Some(Clock::at(9, 0)), "{text}: {out:?}");
            assert_eq!(m.alternatives, vec![types::Alternative::DateOrder {
                date: DateSpec::MonthDay { month: day, day: 6 },
            }], "{text}: {out:?}");
        }
    }
}

#[test]
fn unit7_followup_series_heading_shares_source_before_resolving_local_target() {
    let text = "Tuesday and Friday UTC. 09:00 → my time";
    let out = read(text);
    assert_eq!(out.mentions.len(), 2, "{out:?}");
    assert_series(&out, 0, 2);
    for m in &out.mentions {
        assert_eq!(m.source, Some(ZoneRef::Fixed { minutes: 0, region: None }), "{out:?}");
        assert_eq!(m.target, Some(ZoneRef::Local), "{out:?}");
        assert_eq!(m.time, Some(Clock::at(9, 0)), "{out:?}");
    }
}

#[test]
fn unit7_followup_series_heading_obeys_calendar_range_and_list_difference() {
    for (text, days, end) in [
        ("2027-06-08 to 2027-06-10\n\n09:15–16:40", vec![8, 9, 10], Clock::at(16, 40)),
        ("2027-06-08 to 2027-06-10\n\n23:00–05:00", vec![8, 9], Clock { hour: 5, minute: 0, second: 0, day_offset: 1 }),
        ("2027-06-08 and 2027-06-10\n\n09:15–16:40", vec![8, 10], Clock::at(16, 40)),
        ("2027-06-01 to 2027-06-08\n\n09:15–16:40", vec![1, 8], Clock::at(16, 40)),
    ] {
        let out = read(text);
        assert_eq!(out.mentions.len(), days.len(), "{text}: {out:?}");
        assert_series(&out, 0, days.len());
        for (i, (m, day)) in out.mentions.iter().zip(days).enumerate() {
            assert_eq!(m.date, Some(DateSpec::Absolute { year: 2027, month: 6, day }), "{text}: {out:?}");
            assert_eq!(m.end, Some(end), "{text}: {out:?}");
            assert_eq!(m.time, Some(if text.contains("23:00") { Clock::at(23, 0) } else { Clock::at(9, 15) }), "{text}: {out:?}");
            if i > 0 { assert_ne!(m.group, out.mentions[i - 1].group, "{text}: {out:?}"); }
        }
    }
}

#[test]
fn unit7_followup_series_heading_never_overrides_a_later_written_date() {
    for text in ["Tuesday and Friday. Meeting on 2027-10-11 at 09:00.", "Tuesday and Friday\n\n2027-10-11\n\n09:00"] {
        let out = read(text);
        assert_eq!(out.mentions.len(), 1, "{text}: {out:?}");
        assert_eq!(out.mentions[0].date, Some(DateSpec::Absolute { year: 2027, month: 10, day: 11 }));
        assert_eq!(out.mentions[0].time, Some(Clock::at(9, 0)));
        assert!(out.mentions[0].series.is_none(), "{out:?}");
    }
    let out = read("We close Tuesday and Friday.\n\nMeeting at 09:00.");
    assert_eq!(out.mentions.len(), 1, "{out:?}");
    assert!(out.mentions[0].date.is_none() && out.mentions[0].series.is_none(), "{out:?}");
}

#[test]
fn unit7_followup_complete_date_heading_shares_clock_after_arbitrary_next_line_prose() {
    for text in [
        "3 and 19 October\nCake at 20:00.",
        "3 and 19 October\nBirthday cake will be cut at 20:00.",
        "3 and 19 October. Cake at 20:00.",
    ] {
        let out = read(text);
        assert_eq!(out.mentions.len(), 2, "{text}: {out:?}");
        assert_series(&out, 0, 2);
        assert_distinct_series_groups(&out);
        for (mention, day) in out.mentions.iter().zip([3, 19]) {
            assert_eq!(mention.date, Some(DateSpec::MonthDay { month: 10, day }), "{text}: {out:?}");
            assert_eq!(mention.time, Some(Clock::at(20, 0)), "{text}: {out:?}");
            assert!(mention.issues.is_empty(), "{text}: {out:?}");
        }
    }
}

#[test]
fn unit7_followup_proven_date_heading_keeps_its_series_before_an_own_dated_clock() {
    for text in [
        "3 and 19 October\nMeeting on 21 October at 09:15",
        "3 and 19 October. Meeting on 21 October at 09:15",
    ] {
        let out = read(text);
        assert_eq!(out.mentions.len(), 3, "{text}: {out:?}");
        assert_series(&out, 0, 2);
        for (mention, day) in out.mentions[..2].iter().zip([3, 19]) {
            assert_eq!(mention.date, Some(DateSpec::MonthDay { month: 10, day }));
            assert!(mention.time.is_none() && mention.issues.is_empty(), "{text}: {out:?}");
        }
        assert_eq!(out.mentions[2].date, Some(DateSpec::MonthDay { month: 10, day: 21 }));
        assert_eq!(out.mentions[2].time, Some(Clock::at(9, 15)));
        assert!(out.mentions[2].series.is_none() && out.mentions[2].issues.is_empty(), "{text}: {out:?}");
    }
    let text = "Tuesday and Friday. Meeting on 2027-10-11 at 09:15";
    let out = read(text);
    assert_eq!(out.mentions.len(), 1, "{text}: {out:?}");
    assert_eq!(out.mentions[0].date, Some(DateSpec::Absolute { year: 2027, month: 10, day: 11 }));
    assert_eq!(out.mentions[0].time, Some(Clock::at(9, 15)));
    assert!(out.mentions[0].series.is_none() && out.mentions[0].issues.is_empty(), "{out:?}");
}

#[test]
fn unit7_followup_date_series_share_same_paragraph_clock_through_prose() {
    for text in ["3 and 19 October Cake at 20:00.", "Cake on 3 and 19 October\nStarts at 20:00."] {
        let out = read(text);
        assert_eq!(out.mentions.len(), 2, "{text}: {out:?}");
        assert_series(&out, 0, 2);
        assert_distinct_series_groups(&out);
        for (mention, day) in out.mentions.iter().zip([3, 19]) {
            assert_eq!(mention.date, Some(DateSpec::MonthDay { month: 10, day }), "{text}: {out:?}");
            assert_eq!(mention.time, Some(Clock::at(20, 0)), "{text}: {out:?}");
            assert!(mention.end.is_none() && mention.issues.is_empty(), "{text}: {out:?}");
        }
    }
}

#[test]
fn unit7_followup_date_list_own_clocks_barrier_stays_independent() {
    let text = "3 October at 09:15 and 19 October at 20:00.";
    let out = read(text);
    assert_eq!(out.mentions.len(), 2, "{out:?}");
    for (mention, (day, hour, minute)) in out.mentions.iter().zip([(3, 9, 15), (19, 20, 0)]) {
        assert_eq!(mention.date, Some(DateSpec::MonthDay { month: 10, day }), "{out:?}");
        assert_eq!(mention.time, Some(Clock::at(hour, minute)), "{out:?}");
        assert!(mention.series.is_none() && mention.end.is_none() && mention.issues.is_empty(), "{out:?}");
    }
}


#[test]
fn unit7_third_pass_clockless_days_stay_out_and_calendar_dates_stay() {
    for text in [
        "Das Büro hat Montag bis Freitag offen.", "Office hours are Monday to Friday.",
        "Horario de oficina: de lunes a viernes.", "Horaires d'ouverture : du lundi au vendredi.",
        "Orario di ufficio: dal lunedì al venerdì.", "O atendimento é de segunda a sexta.",
        "Офис открыт с понедельника по пятницу.", "Mở cửa từ thứ hai đến thứ sáu.",
        "tomorrow", "today and tomorrow", "today to tomorrow", "See you Friday.", "à demain",
    ] {
        let out = read(text);
        assert!(out.mentions.is_empty(), "{text}: {out:?}");
    }
    let dated = read("3 and 19 October");
    assert_eq!(dated.mentions.len(), 2, "{dated:?}");
    assert!(dated.mentions.iter().all(|m| m.time.is_none()));
}

#[test]
fn unit7_third_pass_clockless_headings_merge_into_the_following_clock() {
    for text in ["Montag bis Freitag:\n9:00–17:00", "Montag bis Freitag:\n\n9:00–17:00"] {
        let out = read(text);
        assert_eq!(out.mentions.len(), 5, "{text}: {out:?}");
        assert_series(&out, 0, 5);
        assert_distinct_series_groups(&out);
        for (m, weekday) in out.mentions.iter().zip(1..=5) {
            assert_eq!(m.date, Some(DateSpec::Weekday { weekday, week: None }));
            assert_eq!(m.time, Some(Clock::at(9, 0)));
            assert_eq!(m.end, Some(Clock::at(17, 0)));
        }
    }
    let out = read("today and tomorrow:\n\n9:00");
    assert_eq!(out.mentions.len(), 2, "{out:?}");
    assert_series(&out, 0, 2);
    for (m, days) in out.mentions.iter().zip(0..=1) {
        assert_eq!(m.date, Some(DateSpec::Offset { days }));
        assert_eq!(m.time, Some(Clock::at(9, 0)));
    }
}

#[cfg(not(feature = "intents-only"))]
fn third_pass_iana(zone: &ZoneRef) -> Option<&str> {
    match zone {
        ZoneRef::City { iana, .. } | ZoneRef::Region { iana } => Some(iana),
        ZoneRef::Options { options, .. } => options.first().and_then(third_pass_iana),
        _ => None,
    }
}

#[cfg(not(feature = "intents-only"))]
fn third_pass_with_places(text: &str, language: &str) -> Output {
    let opened = crate::city_index::dispatch("city.open", serde_json::json!({"path": concat!(env!("CARGO_MANIFEST_DIR"), "/../TahoeTime/Resources/cities.ttcity")})).unwrap();
    let handle = opened["handle"].as_u64().unwrap();
    let lookup = |name: &str, strong: bool| city_lookup(Some(handle), name, strong);
    let out = understand(text, &Options { region: "GB", ui_language: language, lookup: &lookup });
    crate::city_index::dispatch("city.close", serde_json::json!({"handle": handle})).unwrap();
    out
}

#[test]
#[cfg(not(feature = "intents-only"))]
fn unit7_third_pass_abbreviated_weekday_range_shares_berlin_source() {
    for text in ["Tue–Thu 9:00–12:00 Berlin time", "Tue–Thu 9:00–12:00", "Tue–Thu 09:15–12:45 Berlin time"] {
        let out = third_pass_with_places(text, "en");
        assert_eq!(out.mentions.len(), 3, "{text}: {out:?}");
        assert_series(&out, 0, 3);
        assert_distinct_series_groups(&out);
        for (m, weekday) in out.mentions.iter().zip(2..=4) {
            let minute = if text.contains("09:15") { 15 } else { 0 };
            assert_eq!(m.date, Some(DateSpec::Weekday { weekday, week: None }));
            assert_eq!(m.time, Some(Clock::at(9, minute)));
            assert_eq!(m.end, Some(Clock::at(12, if minute == 0 { 0 } else { 45 })));
            assert_eq!(m.source.as_ref().and_then(third_pass_iana), text.contains("Berlin").then_some("Europe/Berlin"));
            assert!(m.issues.is_empty() && m.unresolved.is_empty(), "{out:?}");
        }
    }
}

#[test]
#[cfg(not(feature = "intents-only"))]
fn unit7_third_pass_parenthesized_places_are_clock_sources() {
    for language in ["en", "de"] {
        for (text, hour, zone) in [
            ("15:00 (Berlin)", 15, "Europe/Berlin"), ("15:00 Berlin", 15, "Europe/Berlin"),
            ("9am (London time)", 9, "Europe/London"), ("9am (London)", 9, "Europe/London"),
            ("15:00–17:00 (Berlin)", 15, "Europe/Berlin"),
        ] {
            let out = third_pass_with_places(text, language);
            assert_eq!(out.mentions.len(), 1, "{language}: {text}: {out:?}");
            assert_eq!(out.mentions[0].time, Some(Clock::at(hour, 0)));
            assert_eq!(out.mentions[0].source.as_ref().and_then(third_pass_iana), Some(zone), "{language}: {text}: {out:?}");
            assert_eq!(out.mentions[0].source, third_pass_with_places(&format!("{hour}:00 {}", if zone == "Europe/Berlin" { "Berlin" } else if text.contains("time") { "London time" } else { "London" }), language).mentions[0].source.clone(), "{language}: {text}: {out:?}");
            assert!(out.mentions[0].issues.is_empty() && out.mentions[0].unresolved.is_empty(), "{out:?}");
        }
        let out = third_pass_with_places("9am ET (15:00 Berlin)", language);
        assert_eq!(out.mentions.len(), 2, "{out:?}");
        assert_eq!(out.mentions[0].time, Some(Clock::at(9, 0)));
        assert!(matches!(&out.mentions[0].source, Some(ZoneRef::Region { iana }) if iana == "America/New_York"), "{out:?}");
        assert_eq!(out.mentions[1].time, Some(Clock::at(15, 0)));
        assert_eq!(out.mentions[1].source.as_ref().and_then(third_pass_iana), Some("Europe/Berlin"));
        assert_eq!(out.mentions[1].source, third_pass_with_places("15:00 Berlin", language).mentions[0].source);
        assert_eq!(out.mentions[0].group, out.mentions[1].group);
        assert!(out.mentions.iter().all(|m| m.series.is_none() && m.issues.is_empty() && m.unresolved.is_empty()));
        let prose = third_pass_with_places("15:00 (meeting with Berlin team)", language);
        assert!(prose.mentions.iter().all(|m| m.source.is_none()), "{prose:?}");
    }
}
