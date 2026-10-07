// SPDX-License-Identifier: GPL-3.0-only
use super::*;

fn read(text: &str, language: &str) -> Output {
    understand(text, &Options { region: "GB", ui_language: language, lookup: &|_, _| None })
}

#[test]
fn written_day_ends_cover_all_interface_languages() {
    for (language, phrase, weekday) in [
        ("en", "until the end of Thursday", 4),
        ("de", "bis zum Ende des Dienstags", 2),
        ("es", "hasta el final del jueves", 4),
        ("fr", "jusqu'à la fin de mercredi", 3),
        ("it", "fino alla fine di sabato", 6),
        ("ja", "火曜日の終わりまで", 2),
        ("ko", "목요일 끝까지", 4),
        ("nl", "tot het einde van maandag", 1),
        ("pl", "do końca wtorku", 2),
        ("ru", "до конца пятницы", 5),
        ("tr", "pazartesi gün sonuna kadar", 1),
        ("vi", "đến hết thứ ba", 2),
        ("id", "sampai akhir hari rabu", 3),
        ("pt-BR", "até o fim de quinta-feira", 4),
        ("zh-Hans", "直到星期六结束", 6),
        ("zh-Hant", "直到星期三結束", 3),
    ] {
        let out = read(phrase, language);
        assert_eq!(out.mentions.len(), 1, "{language}: {phrase}: {out:?}");
        let mention = &out.mentions[0];
        assert_eq!(mention.date, Some(DateSpec::Weekday { weekday, week: None }), "{phrase}: {out:?}");
        assert_eq!(mention.time, Some(Clock::at(17, 0)), "{phrase}: {out:?}");
        assert_eq!(mention.time_implied, Some("eod"), "{phrase}: {out:?}");
        assert_eq!(mention.span, [0, phrase.encode_utf16().count()], "{phrase}: {out:?}");
        assert!(mention.unresolved.is_empty(), "{phrase}: {out:?}");
    }
    for (language, prefix, days) in [
        ("de", "bis zum Ende des", ["Montags", "Dienstags", "Mittwochs", "Donnerstags", "Freitags", "Samstags", "Sonntags"]),
        ("pl", "do końca", ["poniedziałku", "wtorku", "środy", "czwartku", "piątku", "soboty", "niedzieli"]),
        ("ru", "до конца", ["понедельника", "вторника", "среды", "четверга", "пятницы", "субботы", "воскресенья"]),
    ] {
        for (index, word) in days.into_iter().enumerate() {
            let text = format!("{prefix} {word}");
            let out = read(&text, language);
            assert_eq!(out.mentions.len(), 1, "{text}: {out:?}");
            assert_eq!(out.mentions[0].date, Some(DateSpec::Weekday { weekday: index as u8 + 1, week: None }), "{text}: {out:?}");
            assert_eq!(out.mentions[0].time, Some(Clock::at(17, 0)), "{text}: {out:?}");
        }
    }
    for (language, text, days) in [("ru", "Завтра до конца дня", 1), ("tr", "yarın gün sonuna kadar", 1), ("en", "until the end of yesterday", -1)] {
        let out = read(text, language);
        assert_eq!(out.mentions.len(), 1, "{text}: {out:?}");
        assert_eq!(out.mentions[0].date, Some(DateSpec::Offset { days }), "{text}: {out:?}");
        assert_eq!(out.mentions[0].time, Some(Clock::at(17, 0)), "{text}: {out:?}");
    }
    let out = read("until the end of 17 November 2028", "en");
    assert_eq!(out.mentions.len(), 1, "{out:?}");
    assert_eq!(out.mentions[0].date, Some(DateSpec::Absolute { year: 2028, month: 11, day: 17 }));
    assert_eq!(out.mentions[0].time, Some(Clock::at(23, 59)));
    let date_part = out.mentions[0].parts.iter().find(|p| p.kind == "date").unwrap();
    assert_eq!(date_part.span, [17, 33]);
}

#[test]
fn week_month_and_year_ends_do_not_invent_a_day() {
    let written_day = read("until the end of Monday", "en");
    assert_eq!(written_day.mentions.len(), 1, "{written_day:?}");
    assert_eq!(written_day.mentions[0].time, Some(Clock::at(17, 0)));
    for (language, phrase) in [
        ("en", "until the end of November"), ("en", "until the end of the week"), ("en", "until the end of the year"),
        ("de", "bis zum Ende des Monats"), ("es", "hasta el final del año"),
        ("fr", "jusqu'à la fin de septembre"), ("it", "fino alla fine del mese"),
        ("ja", "今月の終わりまで"), ("ko", "이번 달 끝까지"),
        ("nl", "tot het einde van het jaar"), ("pl", "do końca miesiąca"),
        ("ru", "до конца недели"), ("tr", "ayın sonuna kadar"),
        ("vi", "đến hết tháng tám"), ("id", "sampai akhir bulan"),
        ("pt-BR", "até o fim do mês"), ("zh-Hans", "直到本月结束"),
        ("zh-Hant", "直到今年結束"),
    ] {
        let out = read(phrase, language);
        assert!(out.mentions.is_empty(), "{language}: {phrase}: {out:?}");
    }
    let out = read("The form is due end of day.", "en");
    assert_eq!(out.mentions.len(), 1, "{out:?}");
    assert_eq!(out.mentions[0].time, Some(Clock::at(17, 0)));
    assert!(out.mentions[0].date.is_none());
}

#[test]
fn from_today_phrases_name_today_in_all_interface_languages() {
    for (language, phrase) in [
        ("en", "From today"), ("en", "As of today"), ("en", "Starting today"),
        ("de", "ab heute"), ("es", "desde hoy"), ("fr", "à partir d'aujourd'hui"),
        ("it", "da oggi"), ("ja", "今日から"), ("ko", "오늘부터"),
        ("nl", "vanaf vandaag"), ("pl", "od dziś"), ("ru", "с сегодняшнего дня"),
        ("tr", "bugünden itibaren"), ("vi", "từ hôm nay"), ("id", "mulai hari ini"),
        ("pt-BR", "a partir de hoje"), ("zh-Hans", "自即日起"), ("zh-Hant", "即日起"),
    ] {
        let text = format!("{phrase} 06:42");
        let out = read(&text, language);
        assert_eq!(out.mentions.len(), 1, "{language}: {text}: {out:?}");
        let mention = &out.mentions[0];
        assert_eq!(mention.date, Some(DateSpec::Offset { days: 0 }), "{text}: {out:?}");
        assert_eq!(mention.time, Some(Clock::at(6, 42)), "{text}: {out:?}");
        assert!(mention.unresolved.is_empty(), "{text}: {out:?}");
        let date_part = mention.parts.iter().find(|p| p.kind == "date").unwrap();
        assert_eq!(date_part.span, [0, phrase.encode_utf16().count()], "{text}: {out:?}");
    }
}

#[test]
fn english_day_possessives_preserve_their_date_and_period() {
    for quote in ['\'', '’'] {
        for (word, days, hour) in [("today", 0, 7), ("tomorrow", 1, 7), ("tonight", 0, 19)] {
            let phrase = format!("{word}{quote}s");
            let text = format!("{phrase} rehearsal at 7:35");
            let out = read(&text, "en");
            assert_eq!(out.mentions.len(), 1, "{text}: {out:?}");
            let mention = &out.mentions[0];
            assert_eq!(mention.date, Some(DateSpec::Offset { days }), "{text}: {out:?}");
            assert_eq!(mention.time, Some(Clock::at(hour, 35)), "{text}: {out:?}");
            let date_part = mention.parts.iter().find(|p| p.kind == "date").unwrap();
            assert_eq!(date_part.span, [0, phrase.encode_utf16().count()], "{text}: {out:?}");
        }
    }
}

#[test]
fn polish_week_phrases_qualify_weekdays_without_places() {
    for (phrase, week) in [("w przyszłym tygodniu", "next"), ("w zeszłym tygodniu", "last"), ("w tym tygodniu", "this")] {
        for (day, weekday) in [("w niedzielę", 7), ("w środę", 3), ("w sobotę", 6)] {
            let text = format!("{day} {phrase} o 21:45");
            let out = read(&text, "pl");
            assert_eq!(out.mentions.len(), 1, "{text}: {out:?}");
            let mention = &out.mentions[0];
            assert_eq!(mention.date, Some(DateSpec::Weekday { weekday, week: Some(week) }), "{text}: {out:?}");
            assert_eq!(mention.time, Some(Clock::at(21, 45)));
            assert!(mention.source.is_none() && mention.target.is_none() && mention.unresolved.is_empty(), "{text}: {out:?}");
        }
        let text = format!("{phrase} o 16:25");
        let out = read(&text, "pl");
        assert_eq!(out.mentions.len(), 1, "{text}: {out:?}");
        assert!(out.mentions[0].date.is_none(), "{text}: {out:?}");
        assert!(out.mentions[0].source.is_none() && out.mentions[0].unresolved.is_empty(), "{text}: {out:?}");
    }
}

#[test]
fn unit7_followup_dotted_dates_before_clocks_have_no_clock_alternative() {
    for (text, language, month, day) in [
        ("Sprechstunde am 03.10 um 15 Uhr.", "de", 10, 3),
        ("Собрание 03.10 в 15:00 в Москве.", "ru", 10, 3),
        ("Sprechstunde am 04.11 beginnt um 16:25.", "de", 11, 4),
        ("Встреча 05.12 начинается в 16:25.", "ru", 12, 5),
    ] {
        let out = read(text, language);
        assert_eq!(out.mentions.len(), 1, "{text}: {out:?}");
        assert_eq!(out.mentions[0].date, Some(DateSpec::MonthDay { month, day }), "{text}: {out:?}");
        assert!(out.mentions[0].alternatives.is_empty(), "{text}: {out:?}");
    }
    for (text, language) in [("Rapat besok 10.05", "id"), ("Rapat besok 11.06", "id")] {
        let out = read(text, language);
        assert_eq!(out.mentions.len(), 1, "{text}: {out:?}");
        assert_eq!(out.mentions[0].alternatives.len(), 1, "{text}: {out:?}");
    }
}

#[test]
fn unit7_followup_day_end_uses_workday_clock_for_relative_days_and_weekdays() {
    for (text, language, date) in [
        ("Raporu yarın gün sonuna kadar teslim edin.", "tr", DateSpec::Offset { days: 1 }),
        ("Ödevi cuma gün sonuna kadar yükleyin.", "tr", DateSpec::Weekday { weekday: 5, week: None }),
        ("Сегодня до конца дня сдайте табель.", "ru", DateSpec::Offset { days: 0 }),
    ] {
        let out = read(text, language);
        assert_eq!(out.mentions.len(), 1, "{text}: {out:?}");
        assert_eq!(out.mentions[0].date, Some(date), "{text}: {out:?}");
        assert_eq!(out.mentions[0].time, Some(Clock::at(17, 0)), "{text}: {out:?}");
        assert!(out.mentions[0].time_implied.is_some(), "{text}: {out:?}");
    }
    for (text, language, date) in [
        ("until the end of 14 May", "en", DateSpec::MonthDay { month: 5, day: 14 }),
        ("jusqu’à la fin du 14 mai", "fr", DateSpec::MonthDay { month: 5, day: 14 }),
        ("đến hết ngày 30/6/2027", "vi", DateSpec::Absolute { year: 2027, month: 6, day: 30 }),
    ] {
        let out = read(text, language);
        assert_eq!(out.mentions.len(), 1, "{text}: {out:?}");
        assert_eq!(out.mentions[0].date, Some(date), "{text}: {out:?}");
        assert_eq!(out.mentions[0].time, Some(Clock::at(23, 59)), "{text}: {out:?}");
        assert!(out.mentions[0].time_implied.is_some(), "{text}: {out:?}");
    }
}

#[test]
fn unit7_followup_shared_calendar_preserves_minutes_first_clocks_and_written_years() {
    for (language, phrase, clock) in [
        ("de", "3. Oktober, 10 vor 4", Clock::at(3, 50)),
        ("de", "3. Oktober, 10 nach 4", Clock::at(4, 10)),
        ("nl", "3 oktober, 10 over 4", Clock::at(4, 10)),
    ] {
        let out = read(phrase, language);
        assert_eq!(out.mentions.len(), 1, "{phrase}: {out:?}");
        assert_eq!(out.mentions[0].date, Some(DateSpec::MonthDay { month: 10, day: 3 }), "{phrase}: {out:?}");
        assert_eq!(out.mentions[0].time, Some(clock), "{phrase}: {out:?}");
        assert!(out.mentions[0].series.is_none(), "{phrase}: {out:?}");
    }
    // 省略月份的日数只借同一年的字段，不能据日数大小自造前一年。
    let mut u = units::units(&text::fold("19–3 October 2027"));
    scan::classify_numbers(&mut u);
    let mut scanner = scan::Scanner { u: &u, out: Vec::new() };
    scanner.scan();
    let dates: Vec<_> = scanner.out.iter().filter_map(|atom| match &atom.atom {
        scan::Atom::Date(date) => Some(date.clone()), _ => None,
    }).collect();
    assert_eq!(dates, vec![DateSpec::Absolute { year: 2027, month: 10, day: 19 }, DateSpec::Absolute { year: 2027, month: 10, day: 3 }]);
}

#[test]
fn unit7_followup_closed_english_weekday_ranges_keep_standalone_words_protected() {
    for phrase in ["Tue–Sat", "Tue-Sat", "Tuesday–Sat", "Tue–Saturday"] {
        assert!(read(phrase, "en").mentions.is_empty(), "{phrase}");
        let phrase = format!("{phrase} 09:00–12:00");
        let out = read(&phrase, "en");
        assert_eq!(out.mentions.len(), 5, "{phrase}: {out:?}");
        for (index, mention) in out.mentions.iter().enumerate() {
            assert_eq!(mention.date, Some(DateSpec::Weekday { weekday: index as u8 + 2, week: None }), "{phrase}: {out:?}");
            assert_eq!(mention.time, Some(Clock::at(9, 0)), "{phrase}: {out:?}");
            assert_eq!(mention.end, Some(Clock::at(12, 0)), "{phrase}: {out:?}");
            assert!(mention.series.is_some(), "{phrase}: {out:?}");
        }
    }
    for phrase in ["I sat here.", "The sun is bright."] {
        assert!(read(phrase, "en").mentions.is_empty(), "{phrase}");
    }
}

#[test]
fn unit7_followup_french_contracted_calendar_day_end_accepts_curly_apostrophe() {
    for phrase in ["jusqu'à la fin du 14 mai", "jusqu’à la fin du 14 mai"] {
        let out = read(phrase, "fr");
        assert_eq!(out.mentions.len(), 1, "{phrase}: {out:?}");
        let mention = &out.mentions[0];
        assert_eq!(mention.date, Some(DateSpec::MonthDay { month: 5, day: 14 }), "{phrase}: {out:?}");
        assert_eq!(mention.time, Some(Clock::at(23, 59)), "{phrase}: {out:?}");
        assert_eq!(mention.time_implied, Some("dayend"), "{phrase}: {out:?}");
        assert_eq!(mention.span, [0, phrase.encode_utf16().count()], "{phrase}: {out:?}");
    }
    assert!(read("jusqu’à la fin du mois", "fr").mentions.is_empty());
}

#[test]
fn unit7_followup_english_weekday_range_keeps_written_prefix_scope() {
    for (prefix, week) in [("next", "next"), ("this", "this"), ("last", "last"), ("this coming", "next")] {
        let phrase = format!("{prefix} Tue–Sat");
        assert!(read(&phrase, "en").mentions.is_empty(), "{phrase}");
        let phrase = format!("{phrase} 09:00–12:00");
        let out = read(&phrase, "en");
        assert_eq!(out.mentions.len(), 5, "{phrase}: {out:?}");
        for (index, mention) in out.mentions.iter().enumerate() {
            assert_eq!(mention.date, Some(DateSpec::Weekday { weekday: index as u8 + 2, week: Some(week) }), "{phrase}: {out:?}");
            assert_eq!(mention.time, Some(Clock::at(9, 0)), "{phrase}: {out:?}");
            assert_eq!(mention.end, Some(Clock::at(12, 0)), "{phrase}: {out:?}");
            assert!(mention.series.is_some(), "{phrase}: {out:?}");
        }
        assert_eq!(out.mentions[0].parts.iter().find(|p| p.kind == "date").unwrap().span[0], 0, "{phrase}: {out:?}");
    }
    // 两端另写不同周限定词时，不借范围语法自行决定跨周。
    for phrase in ["next Tue–last Sat", "next Tue–Sat last week"] {
        assert!(read(phrase, "en").mentions.iter().all(|mention| mention.series.is_none()), "{phrase}");
    }
}

#[test]
fn unit7_followup_calendar_list_does_not_steal_implicit_clock_range_start() {
    for (phrase, month, day, start, end, zone, date_end) in [
        ("Wednesday, December 9, 10–11am ET", 12, 9, Clock::at(10, 0), Clock::at(11, 0), "America/New_York", 21),
        ("Friday, September 4, 2–3pm PT", 9, 4, Clock::at(14, 0), Clock::at(15, 0), "America/Los_Angeles", 19),
    ] {
        let out = read(phrase, "en");
        assert_eq!(out.mentions.len(), 1, "{phrase}: {out:?}");
        let mention = &out.mentions[0];
        assert_eq!(mention.date, Some(DateSpec::MonthDay { month, day }), "{phrase}: {out:?}");
        assert_eq!(mention.time, Some(start), "{phrase}: {out:?}");
        assert_eq!(mention.end, Some(end), "{phrase}: {out:?}");
        assert_eq!(mention.source, Some(ZoneRef::Region { iana: zone.to_string() }), "{phrase}: {out:?}");
        assert!(mention.series.is_none(), "{phrase}: {out:?}");
        assert_eq!(mention.group, 0, "{phrase}: {out:?}");
        assert!(!mention.date_inherited, "{phrase}: {out:?}");
        assert!(mention.date_from.is_none() && mention.time_implied.is_none() && mention.target.is_none(), "{phrase}: {out:?}");
        assert!(mention.alternatives.is_empty() && mention.unresolved.is_empty() && mention.issues.is_empty(), "{phrase}: {out:?}");
        assert_eq!(mention.parts.iter().find(|p| p.kind == "date").unwrap().span, [0, date_end], "{phrase}: {out:?}");
    }
}
