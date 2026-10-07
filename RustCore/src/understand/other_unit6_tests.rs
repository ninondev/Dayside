// SPDX-License-Identifier: GPL-3.0-only
use super::types::Alternative;
use super::*;

fn read(text: &str) -> Output {
    understand(
        text,
        &Options {
            region: "US",
            ui_language: "en",
            lookup: &|_, _| None,
        },
    )
}

#[test]
fn code_numbers_do_not_become_range_endpoints() {
    let out = read("The schedule table shows code 1547 as 15:47.");
    assert_eq!(out.mentions.len(), 1, "{out:?}");
    assert_eq!(out.mentions[0].time, Some(Clock::at(15, 47)));
    assert!(out.mentions[0].end.is_none(), "{out:?}");

    // A real compact endpoint still works, and a distant code noun cannot block it.
    for text in ["1547 to 16:00", "The code review runs 1547 to 16:00."] {
        let out = read(text);
        assert_eq!(out.mentions.len(), 1, "{text}: {out:?}");
        assert_eq!(out.mentions[0].time, Some(Clock::at(15, 47)), "{text}");
        assert_eq!(out.mentions[0].end, Some(Clock::at(16, 0)), "{text}");
    }
}

#[test]
fn invalid_cjk_dates_report_the_written_span() {
    for date in ["2026年2月30日", "2026年2月29日", "2026年13月2日", "13月2日"] {
        let text = format!("会議は {date} の 10:00。");
        let out = read(&text);
        assert_eq!(out.mentions.len(), 1, "{text}: {out:?}");
        let mention = &out.mentions[0];
        assert_eq!(mention.time, Some(Clock::at(10, 0)), "{text}");
        assert!(mention.date.is_none(), "{text}");
        assert_eq!(mention.issues.len(), 1, "{text}: {out:?}");
        assert_eq!(mention.issues[0].kind, "invalidDate");
        assert_eq!(mention.issues[0].text, date);
    }

    for (date, year, month, day) in [
        ("2026年2月28日", 2026, 2, 28),
        ("2028年2月29日", 2028, 2, 29),
    ] {
        let text = format!("会議は {date} の 10:00。");
        let out = read(&text);
        assert_eq!(out.mentions.len(), 1, "{text}: {out:?}");
        assert_eq!(
            out.mentions[0].date,
            Some(DateSpec::Absolute { year, month, day }),
            "{text}"
        );
        assert!(out.mentions[0].issues.is_empty(), "{text}: {out:?}");
    }
}

#[test]
fn turkish_broadcast_noun_does_not_engulf_the_clock_place() {
    let lookup = |text: &str, _: bool| match text::fold_str(text).as_str() {
        "tokyo" | "tokyo'da" => Some(ZoneRef::Region {
            iana: "Asia/Tokyo".into(),
        }),
        "new york" | "new york'ta" => Some(ZoneRef::Region {
            iana: "America/New_York".into(),
        }),
        _ => None,
    };
    for (text, iana) in [
        ("Yayın Tokyo'da 10:00'da.", "Asia/Tokyo"),
        ("Yayın New York'ta 10:00'da.", "America/New_York"),
    ] {
        let out = understand(
            text,
            &Options {
                region: "US",
                ui_language: "tr",
                lookup: &lookup,
            },
        );
        assert_eq!(out.mentions.len(), 1, "{text}: {out:?}");
        assert!(
            matches!(&out.mentions[0].source, Some(ZoneRef::Region { iana: actual }) if actual == iana),
            "{text}: {out:?}"
        );
        assert!(out.mentions[0].unresolved.is_empty(), "{text}: {out:?}");
    }
}

#[test]
fn standalone_slash_dates_preserve_regional_order_and_alternatives() {
    for (region, month, day, alt_month, alt_day) in [("US", 10, 3, 3, 10), ("GB", 3, 10, 10, 3)] {
        let out = understand(
            "We ship on 10/3.",
            &Options {
                region,
                ui_language: "en",
                lookup: &|_, _| None,
            },
        );
        assert_eq!(out.mentions.len(), 1, "{region}: {out:?}");
        let mention = &out.mentions[0];
        assert_eq!(mention.date, Some(DateSpec::MonthDay { month, day }));
        assert!(mention.time.is_none(), "{region}: {out:?}");
        assert_eq!(
            mention.alternatives,
            vec![Alternative::DateOrder {
                date: DateSpec::MonthDay {
                    month: alt_month,
                    day: alt_day
                }
            }]
        );
    }

    for text in ["We ship on 11/23.", "We ship on 23/11."] {
        let out = read(text);
        assert_eq!(out.mentions.len(), 1, "{text}: {out:?}");
        assert_eq!(
            out.mentions[0].date,
            Some(DateSpec::MonthDay { month: 11, day: 23 })
        );
        assert!(out.mentions[0].time.is_none(), "{text}: {out:?}");
        assert!(out.mentions[0].alternatives.is_empty(), "{text}: {out:?}");
    }
}

#[test]
fn standalone_full_year_slash_dates_remain_dates_and_other_numbers_stay_blocked() {
    for (region, month, day, alt_month, alt_day) in [("GB", 12, 8, 8, 12), ("US", 8, 12, 12, 8)] {
        let out = understand(
            "08/12/2026",
            &Options {
                region,
                ui_language: "en",
                lookup: &|_, _| None,
            },
        );
        assert_eq!(out.mentions.len(), 1, "{region}: {out:?}");
        let mention = &out.mentions[0];
        assert_eq!(
            mention.date,
            Some(DateSpec::Absolute {
                year: 2026,
                month,
                day
            })
        );
        assert!(mention.time.is_none(), "{region}: {out:?}");
        assert_eq!(
            mention.alternatives,
            vec![Alternative::DateOrder {
                date: DateSpec::Absolute {
                    year: 2026,
                    month: alt_month,
                    day: alt_day
                }
            }]
        );
    }
    for text in [
        "version 9.2.1",
        "for 2 hours",
        "costs 4.50",
        "code 1547",
        "15.03",
    ] {
        let out = read(text);
        assert!(out.mentions.is_empty(), "{text}: {out:?}");
    }
}

#[test]
fn fraction_quantities_are_blocked_by_their_attached_measurement_unit() {
    for text in [
        "Der Teig braucht 1/2 Tasse Zucker.",
        "Der Teig braucht 2/3 Tassen Zucker.",
        "Add 1/2 cup of flour.",
        "Añade 1/2 taza de leche.",
        "Ajoute 1/2 litre de lait.",
        "Aggiungi 1/2 tazza di latte.",
        "小麦粉 1/2 カップをふるいます。",
        "Doe 1/2 kopje havermout in de pan.",
        "Do ciasta dodaj 1/2 szklanki cukru.",
        "Добавь в тесто 1/2 чайной ложки соли.",
        "Смешай 3/4 стакана муки.",
        "1/2 su bardağı süt ekleyin.",
        "Thêm 1/2 thìa muối.",
    ] {
        let out = read(text);
        assert!(out.mentions.is_empty(), "{text}: {out:?}");
        let clock_text = format!("{text} 14:00 UTC.");
        let out = read(&clock_text);
        assert_eq!(out.mentions.len(), 1, "{clock_text}: {out:?}");
        assert_eq!(out.mentions[0].time, Some(Clock::at(14, 0)));
        assert!(out.mentions[0].date.is_none(), "{clock_text}: {out:?}");
        let date_text = format!("{text} 2026-10-03.");
        let out = read(&date_text);
        assert_eq!(out.mentions.len(), 1, "{date_text}: {out:?}");
        assert_eq!(
            out.mentions[0].date,
            Some(DateSpec::Absolute {
                year: 2026,
                month: 10,
                day: 3
            })
        );
        assert!(out.mentions[0].time.is_none(), "{date_text}: {out:?}");
    }
    let out = read("1/2");
    assert_eq!(out.mentions.len(), 1, "{out:?}");
    assert_eq!(
        out.mentions[0].date,
        Some(DateSpec::MonthDay { month: 1, day: 2 })
    );
    assert_eq!(out.mentions[0].alternatives.len(), 1);
}

#[test]
fn dotted_dates_before_explicit_clocks_cover_all_languages() {
    for (language, text) in [
        ("en", "Meeting 15.10 at 10:00."),
        ("de", "Treffen 15.10 um 10 Uhr."),
        ("es", "Reunión 15.10 a las 10:00."),
        ("fr", "Réunion 15.10 à 10h00."),
        ("it", "Riunione 15.10 alle 10:00."),
        ("ja", "会議15.10 10時。"),
        ("ko", "회의15.10 10시."),
        ("nl", "Vergadering 15.10 om 10:00."),
        ("pl", "Spotkanie 15.10 o 10:00."),
        ("ru", "Встреча 15.10 в 10:00."),
        ("tr", "Toplantı 15.10 saat 10:00."),
        ("vi", "Họp 15.10 lúc 10:00."),
        ("id", "Rapat 15.10 pukul 10.30."),
        ("pt-BR", "Reunião 15.10 às 10:00."),
        ("zh-Hans", "会议15.10 10点。"),
        ("zh-Hant", "會議15.10 10點。"),
    ] {
        let out = understand(text, &Options { region: "US", ui_language: language, lookup: &|_, _| None });
        assert_eq!(out.mentions.len(), 1, "{language}: {text}: {out:?}");
        let mention = &out.mentions[0];
        assert_eq!(mention.date, Some(DateSpec::MonthDay { month: 10, day: 15 }), "{language}: {out:?}");
        assert_eq!(mention.time, Some(Clock::at(10, if language == "id" { 30 } else { 0 })), "{language}: {out:?}");
        assert!(mention.alternatives.is_empty(), "{language}: {out:?}");
    }
}

#[test]
fn slash_fraction_measures_cover_all_languages_and_stay_local() {
    for (language, measures) in [
        ("en", ["cup", "teaspoon", "tablespoon", "glass", "spoon", "kilogram", "gram", "milliliter", "liter"]),
        ("de", ["Tasse", "Teelöffel", "Esslöffel", "Glas", "Löffel", "Kilogramm", "Gramm", "Milliliter", "Liter"]),
        ("es", ["taza", "cucharadita", "cucharada", "vaso", "cuchara", "kilogramo", "gramo", "mililitro", "litro"]),
        ("fr", ["tasse", "cuillère à café", "cuillère à soupe", "verre", "cuillère", "kilogramme", "gramme", "millilitre", "litre"]),
        ("it", ["tazza", "cucchiaino", "cucchiaio da tavola", "bicchiere", "cucchiaio", "chilogrammo", "grammo", "millilitro", "litro"]),
        ("ja", ["カップ", "小さじ", "大さじ", "グラス", "スプーン", "キログラム", "グラム", "ミリリットル", "リットル"]),
        ("ko", ["컵", "작은술", "큰술", "잔", "숟가락", "킬로그램", "그램", "밀리리터", "리터"]),
        ("nl", ["kopje", "theelepel", "eetlepel", "glas", "lepel", "kilogram", "gram", "milliliter", "liter"]),
        ("pl", ["szklanki", "łyżeczki", "łyżki stołowej", "szklanek", "łyżki", "kilograma", "grama", "mililitra", "litra"]),
        ("ru", ["чашки", "чайной ложки", "столовой ложки", "стакана", "ложки", "килограмма", "грамма", "миллилитра", "литра"]),
        ("tr", ["fincan", "çay kaşığı", "yemek kaşığı", "su bardağı", "kaşık", "kilogram", "gram", "mililitre", "litre"]),
        ("vi", ["tách", "thìa cà phê", "thìa canh", "ly", "thìa", "kilôgam", "gam", "mililít", "lít"]),
        ("id", ["cangkir", "sendok teh", "sendok makan", "gelas", "sendok", "kilogram", "gram", "mililiter", "liter"]),
        ("pt-BR", ["xícara", "colher de chá", "colher de sopa", "copo", "colher", "quilograma", "grama", "mililitro", "litro"]),
        ("zh-Hans", ["杯", "茶匙", "汤匙", "玻璃杯", "勺", "千克", "克", "毫升", "升"]),
        ("zh-Hant", ["杯", "茶匙", "大匙", "玻璃杯", "匙", "公斤", "公克", "毫公升", "公升"]),
    ] {
        for measure in measures.into_iter().chain(["kg", "g", "ml", "l"]) {
            let text = format!("2/3 {measure}.");
            let out = understand(&text, &Options { region: "US", ui_language: language, lookup: &|_, _| None });
            assert!(out.mentions.is_empty(), "{language}: {text}: {out:?}");
        }
    }
    for text in ["Add 2/3 cup, then bake at 10:00.", "放1/4杯糖，10:00烘烤。", "Misture 1/3 de xícara de açúcar. Bake at 10:00."] {
        let out = read(text);
        assert_eq!(out.mentions.len(), 1, "{text}: {out:?}");
        assert_eq!(out.mentions[0].time, Some(Clock::at(10, 0)), "{text}: {out:?}");
        assert!(out.mentions[0].date.is_none(), "{text}: {out:?}");
    }
    for text in ["Delivery on 3/4. Bring a cup.", "Add 2/3 cupcake.", "1/2 잔디"] {
        let out = read(text);
        assert_eq!(out.mentions.len(), 1, "{text}: {out:?}");
        assert!(out.mentions[0].date.is_some(), "{text}: {out:?}");
    }
}

#[test]
fn dotted_dates_with_period_prefixes_and_explicit_clock_contrasts() {
    for text in ["会议15.10 下午2点", "會議15.10 下午2點", "会議15.10 午後2時", "회의15.10 오후2시"] {
        let out = read(text);
        assert_eq!(out.mentions.len(), 1, "{text}: {out:?}");
        assert_eq!(out.mentions[0].date, Some(DateSpec::MonthDay { month: 10, day: 15 }), "{text}: {out:?}");
        assert_eq!(out.mentions[0].time, Some(Clock::at(14, 0)), "{text}: {out:?}");
        assert!(out.mentions[0].alternatives.is_empty(), "{text}: {out:?}");
    }
    for text in ["at 15.10 until 16:00", "a las 15.10 hasta 16:00"] {
        let out = read(text);
        assert_eq!(out.mentions.len(), 1, "{text}: {out:?}");
        assert_eq!(out.mentions[0].time, Some(Clock::at(15, 10)), "{text}: {out:?}");
        assert_eq!(out.mentions[0].end, Some(Clock::at(16, 0)), "{text}: {out:?}");
        assert!(out.mentions[0].date.is_none(), "{text}: {out:?}");
    }
    let out = read("会议3.10 下午两点");
    assert_eq!(out.mentions.len(), 1, "{out:?}");
    assert_eq!(out.mentions[0].date, Some(DateSpec::MonthDay { month: 3, day: 10 }), "{out:?}");
    let out = read("2026/3/4 cup");
    assert_eq!(out.mentions.len(), 1, "{out:?}");
    assert_eq!(out.mentions[0].date, Some(DateSpec::Absolute { year: 2026, month: 3, day: 4 }), "{out:?}");
}
