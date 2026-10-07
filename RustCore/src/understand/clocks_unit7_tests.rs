// SPDX-License-Identifier: GPL-3.0-only
use super::{understand, Clock, Mention, Options, ZoneRef};

fn read(text: &str) -> Vec<Mention> {
    understand(text, &Options { region: "US", ui_language: "en", lookup: &|_, _| None }).mentions
}

#[test]
fn unit7_cjk_fullwidth_colons_accept_spaces_and_preserve_spans() {
    for (text, written, hour, minute) in [
        ("签到安排 08： 25", "08： 25", 8, 25),
        ("集合安排 12 ：45", "12 ：45", 12, 45),
        ("受付時刻は07： 50です", "07： 50", 7, 50),
        ("開始時刻は16 ：20です", "16 ：20", 16, 20),
        ("입장 시각은 06： 35입니다", "06： 35", 6, 35),
        ("강연 시각은 13 ：55입니다", "13 ：55", 13, 55),
        ("会場案内 2028.02.09 12 ：45", "12 ：45", 12, 45),
    ] {
        let mentions = read(text);
        assert_eq!(mentions.len(), 1, "{text}: {mentions:?}");
        let mention = &mentions[0];
        assert_eq!(mention.time, Some(Clock::at(hour, minute)), "{text}");
        assert!(mention.issues.is_empty(), "{text}: {:?}", mention.issues);
        let start = text.find(written).unwrap();
        let span = [text[..start].encode_utf16().count(), text[..start + written.len()].encode_utf16().count()];
        assert!(mention.parts.iter().any(|part| part.kind == "time" && part.span == span), "{text}: {:?}", mention.parts);
    }
}

#[test]
fn unit7_cjk_spaced_fullwidth_colons_keep_number_blockers() {
    let clock = read("集合通知 12 ：45");
    assert_eq!(clock.len(), 1, "{clock:?}");
    assert_eq!(clock[0].time, Some(Clock::at(12, 45)));
    for text in [
        "比分 08： 25", "集合通知的價格 12 ：45 元", "得点07： 50", "点数の表示価格16 ：20円", "점수 06： 35", "가격 13 ：55 원",
    ] {
        assert!(read(text).is_empty(), "{text}: {:?}", read(text));
    }
}

#[test]
fn unit7_cjk_spaced_fullwidth_colons_require_valid_two_digit_minutes() {
    for (text, written) in [("排班安排 27： 41", "27： 41"), ("集合安排 08 ：74", "08 ：74")] {
        let mentions = read(text);
        assert_eq!(mentions.len(), 1, "{text}: {mentions:?}");
        assert_eq!(mentions[0].issues.len(), 1, "{text}: {mentions:?}");
        assert_eq!(mentions[0].issues[0].kind, "invalidTime", "{text}");
        assert_eq!(mentions[0].issues[0].text, written, "{text}");
        assert!(mentions[0].time.is_none(), "{text}: {mentions:?}");
    }
    for text in ["受付時刻は07： 5です", "集合安排 08: 25", "集合安排 12 :45", "Workshop 16 ：20"] {
        assert!(read(text).is_empty(), "{text}: {:?}", read(text));
    }
}

#[test]
fn unit7_cyrillic_hyphen_clocks_require_clock_cues() {
    for (text, hour, minute) in [
        ("Созвон в 8-35", 8, 35), ("Подойду к 16-20", 16, 20), ("Проверка в 15-00", 15, 0), ("Экспресс в 0-05", 0, 5),
        ("Екскурсія о 7-45", 7, 45), ("Семінар у 12-05", 12, 5),
    ] {
        let mentions = read(text);
        assert_eq!(mentions.len(), 1, "{text}: {mentions:?}");
        assert_eq!(mentions[0].time, Some(Clock::at(hour, minute)), "{text}");
        assert!(mentions[0].issues.is_empty(), "{text}: {mentions:?}");
    }
    for text in ["Позиция 8-35", "Номер 11-25", "счёт 8-35", "Выплата в 8-35 рублей"] {
        assert!(read(text).is_empty(), "{text}: {:?}", read(text));
    }
}

#[test]
fn unit7_cyrillic_hyphen_clocks_keep_ranges_and_source_zones() {
    for (text, start, end) in [
        ("Библиотека открыта с 7-40 до 19-15", Clock::at(7, 40), Clock::at(19, 15)),
        ("Музей працює з 8-20 до 17-50", Clock::at(8, 20), Clock::at(17, 50)),
    ] {
        let mentions = read(text);
        assert_eq!(mentions.len(), 1, "{text}: {mentions:?}");
        assert_eq!(mentions[0].time, Some(start), "{text}");
        assert_eq!(mentions[0].end, Some(end), "{text}");
    }
    for text in ["Обсудим 11-25 по Мск", "Обсудим 11-25 МСК"] {
        let mentions = read(text);
        assert_eq!(mentions.len(), 1, "{text}: {mentions:?}");
        assert_eq!(mentions[0].time, Some(Clock::at(11, 25)), "{text}");
        assert_eq!(mentions[0].source, Some(ZoneRef::Fixed { minutes: 180, region: Some("Europe/Moscow".to_owned()) }), "{text}");
        assert!(mentions[0].unresolved.is_empty(), "{text}: {mentions:?}");
    }
    let mentions = read("Обсудим 14-45 по московскому времени");
    assert_eq!(mentions.len(), 1, "{mentions:?}");
    assert_eq!(mentions[0].time, Some(Clock::at(14, 45)));
    assert_eq!(mentions[0].source, Some(ZoneRef::Region { iana: "Europe/Moscow".to_owned() }));
}

#[test]
fn unit7_cued_hyphen_clocks_report_invalid_whole_spans() {
    for (text, written) in [("Сбор в 8-74", "8-74"), ("Доставка о 28-15", "28-15")] {
        let mentions = read(text);
        assert_eq!(mentions.len(), 1, "{text}: {mentions:?}");
        assert_eq!(mentions[0].issues.len(), 1, "{text}: {mentions:?}");
        assert_eq!(mentions[0].issues[0].kind, "invalidTime", "{text}");
        assert_eq!(mentions[0].issues[0].text, written, "{text}");
        assert!(mentions[0].time.is_none(), "{text}: {mentions:?}");
    }
}
