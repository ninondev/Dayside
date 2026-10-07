// SPDX-License-Identifier: GPL-3.0-only
//! 单元测试：随机压力测试（不 panic、无残留占位符）与固定样例的精确句子。

use super::{cases, expected, render, template_count, Clock, DateSpec, Spec, Zone, LANGUAGES};

// 构造规格的辅助函数
fn spec(date: Option<DateSpec>, h: u8, m: u8, end: Option<(u8, u8)>, zone: Option<Zone>) -> Spec {
    Spec {
        date,
        time: Clock { hour: h, minute: m },
        end: end.map(|(hour, minute)| Clock { hour, minute }),
        zone,
    }
}

// 每种语言 10000 次随机抽样：所有模板都要能安全渲染，且不残留大括号
#[test]
fn all_templates_render_random_specs_without_panicking() {
    let mut rng = super::rng::Rng::new(0xABCD_1234);
    for lang in LANGUAGES {
        let n = template_count(lang);
        assert!(n >= 8, "{lang} 至少 8 个模板");
        for _ in 0..10_000 {
            let s = random_spec(&mut rng);
            for t in 0..n {
                if let Some(text) = render(&s, lang, t) {
                    assert!(!text.is_empty(), "{lang}/{t} 渲染为空串");
                    assert!(text.trim() == text, "{lang}/{t} 首尾有空白: {text:?}");
                    assert!(!text.contains('{') && !text.contains('}'), "{lang}/{t} 残留占位符: {text:?}");
                }
            }
        }
    }
}

// 12 小时制模板对 0 点与 12 点必须返回 None
#[test]
fn twelve_hour_templates_reject_zero_and_twelve() {
    for lang in LANGUAGES {
        assert_eq!(render(&spec(None, 0, 30, None, None), lang, 1), None, "{lang}");
        assert_eq!(render(&spec(None, 12, 15, None, None), lang, 1), None, "{lang}");
        assert!(render(&spec(None, 13, 30, None, None), lang, 1).is_some(), "{lang}");
    }
}

// 各语言在 3、9、15、21 点应使用的时段词（顺序与下方小时一致）。
const PERIOD_WORDS: [(&str, [&str; 4]); 16] = [
    ("zh-Hans", ["凌晨", "上午", "下午", "晚上"]),
    ("zh-Hant", ["凌晨", "上午", "下午", "晚上"]),
    ("ja", ["午前", "午前", "午後", "午後"]),
    ("ko", ["새벽", "오전", "오후", "오후"]),
    ("en", ["AM", "AM", "PM", "PM"]),
    ("de", ["nachts", "morgens", "nachmittags", "abends"]),
    ("es", ["de la madrugada", "de la mañana", "de la tarde", "de la noche"]),
    ("fr", ["du matin", "du matin", "de l'après-midi", "du soir"]),
    ("it", ["di notte", "del mattino", "del pomeriggio", "di sera"]),
    ("nl", ["'s nachts", "'s ochtends", "'s middags", "'s avonds"]),
    ("pl", ["w nocy", "rano", "po południu", "wieczorem"]),
    ("pt-BR", ["da madrugada", "da manhã", "da tarde", "da noite"]),
    ("ru", ["ночи", "утра", "дня", "вечера"]),
    ("tr", ["gece", "sabah", "öğleden sonra", "akşam"]),
    ("vi", ["sáng", "sáng", "chiều", "tối"]),
    ("id", ["pagi", "pagi", "sore", "malam"]),
];

// 该语言所有含 12 小时制片段的模板编号。
fn twelve_hour_templates(code: &str) -> Vec<usize> {
    let data = super::data::lang(code).expect("语言已知");
    data.templates
        .iter()
        .enumerate()
        .filter(|(_, segs)| {
            segs.iter()
                .any(|s| matches!(s, super::data::Seg::Time12))
        })
        .map(|(i, _)| i)
        .collect()
}

// 带完整日期与城市的规格：让每一个 12 小时制模板都能渲染。
fn full_spec(hour: u8) -> Spec {
    spec(
        Some(DateSpec::Absolute { year: 2026, month: 10, day: 3 }),
        hour,
        30,
        None,
        Some(Zone::City("tokyo")),
    )
}

// 3、9、15、21 点的时段词必须与表一致，且时钟显示 12 小时制小时
#[test]
fn twelve_hour_period_word_matches_hour() {
    assert_eq!(PERIOD_WORDS.len(), LANGUAGES.len());
    for (code, words) in PERIOD_WORDS {
        for (hour, want) in [3u8, 9, 15, 21].into_iter().zip(words) {
            for t in twelve_hour_templates(code) {
                let text = render(&full_spec(hour), code, t)
                    .unwrap_or_else(|| panic!("{code}/{t} 在 {hour} 点应能渲染 12 小时制句子"));
                assert!(
                    text.contains(want),
                    "{code}/{t} 在 {hour} 点应有时段词 {want}: {text:?}"
                );
                // 时钟是 12 小时制：13 点以后不得出现 24 小时制小时
                if hour >= 13 {
                    assert!(
                        !text.contains(&format!("{hour}:")),
                        "{code}/{t} 在 {hour} 点出现了 24 小时制写法: {text:?}"
                    );
                }
            }
        }
    }
}

// 0 点与 12 点：任何 12 小时制模板都不得产出句子
#[test]
fn render_never_uses_twelve_hour_templates_for_zero_and_twelve() {
    for lang in LANGUAGES {
        let templates = twelve_hour_templates(lang);
        assert!(!templates.is_empty(), "{lang} 应有 12 小时制模板");
        for hour in [0u8, 12] {
            for t in &templates {
                assert_eq!(
                    render(&full_spec(hour), lang, *t),
                    None,
                    "{lang}/{t} 在 {hour} 点不应产出 12 小时制句子"
                );
            }
        }
    }
}

// 未知语言与越界编号
#[test]
fn unknown_language_or_index_is_none() {
    let s = spec(None, 9, 0, None, None);
    assert_eq!(template_count("xx"), 0);
    assert_eq!(render(&s, "xx", 0), None);
    for lang in LANGUAGES {
        assert_eq!(render(&s, lang, template_count(lang)), None);
    }
}

// 固定规格：日期 + 时刻（模板 2）在 16 种语言中的精确句子
#[test]
fn fixed_date_time_sentence_per_language() {
    let s = spec(
        Some(DateSpec::Absolute { year: 2026, month: 10, day: 3 }),
        9,
        5,
        None,
        None,
    );
    let want = [
        ("zh-Hans", "2026年10月3日9:05"),
        ("zh-Hant", "2026年10月3日9:05"),
        ("ja", "2026年10月3日の9:05"),
        ("ko", "2026년 10월 3일 9:05"),
        ("en", "October 3, 2026 at 9:05"),
        ("de", "3. Oktober 2026 um 9:05 Uhr"),
        ("es", "3 de octubre de 2026 a las 9:05"),
        ("fr", "3 octobre 2026 à 9:05"),
        ("it", "3 ottobre 2026 alle 9:05"),
        ("nl", "3 oktober 2026 om 9:05 uur"),
        ("pl", "3 października 2026 o 9:05"),
        ("pt-BR", "3 de outubro de 2026 às 9:05"),
        ("ru", "3 октября 2026 в 9:05"),
        ("tr", "3 Ekim 2026 saat 9:05"),
        ("vi", "3 tháng 10 2026 lúc 9:05"),
        ("id", "3 Oktober 2026 pukul 9:05"),
    ];
    assert_eq!(want.len(), LANGUAGES.len());
    for (lang, text) in want {
        assert_eq!(render(&s, lang, 2).as_deref(), Some(text), "{lang}");
    }
}

// 固定规格：裸时刻（模板 0）在 16 种语言中的精确句子
#[test]
fn fixed_bare_clock_per_language() {
    let s = spec(None, 14, 30, None, None);
    let want = [
        ("zh-Hans", "14:30"),
        ("zh-Hant", "14:30"),
        ("ja", "14:30"),
        ("ko", "14:30"),
        ("en", "14:30"),
        ("de", "14:30 Uhr"),
        ("es", "14:30"),
        ("fr", "14:30"),
        ("it", "14:30"),
        ("nl", "14:30 uur"),
        ("pl", "14:30"),
        ("pt-BR", "14:30"),
        ("ru", "14:30"),
        ("tr", "saat 14:30"),
        ("vi", "14:30"),
        ("id", "14:30"),
    ];
    for (lang, text) in want {
        assert_eq!(render(&s, lang, 0).as_deref(), Some(text), "{lang}");
    }
}

// 英语的日词、星期、12 小时制、区间与偏移
#[test]
fn fixed_english_variants() {
    let abs = || Some(DateSpec::Absolute { year: 2026, month: 10, day: 3 });
    assert_eq!(render(&spec(Some(DateSpec::Offset { days: 1 }), 15, 30, None, Some(Zone::City("london"))), "en", 5).as_deref(), Some("tomorrow at 15:30 in London"));
    assert_eq!(render(&spec(Some(DateSpec::Offset { days: -1 }), 9, 5, None, None), "en", 2).as_deref(), Some("yesterday at 9:05"));
    assert_eq!(render(&spec(Some(DateSpec::Offset { days: 2 }), 9, 5, None, None), "en", 2).as_deref(), Some("the day after tomorrow at 9:05"));
    assert_eq!(render(&spec(Some(DateSpec::Offset { days: 5 }), 9, 5, None, None), "en", 2).as_deref(), Some("in 5 days at 9:05"));
    assert_eq!(render(&spec(Some(DateSpec::Offset { days: -3 }), 9, 5, None, None), "en", 2).as_deref(), Some("3 days ago at 9:05"));
    assert_eq!(render(&spec(Some(DateSpec::Weekday { weekday: 5, next: true }), 8, 15, None, None), "en", 9).as_deref(), Some("next Friday at 8:15"));
    assert_eq!(render(&spec(Some(DateSpec::Weekday { weekday: 5, next: false }), 8, 15, None, None), "en", 10).as_deref(), Some("Friday at 8:15"));
    assert_eq!(render(&spec(None, 13, 30, None, None), "en", 1).as_deref(), Some("1:30 PM"));
    assert_eq!(render(&spec(None, 9, 0, Some((11, 30)), None), "en", 7).as_deref(), Some("from 9:00 to 11:30"));
    assert_eq!(render(&spec(None, 9, 0, None, Some(Zone::Offset(330))), "en", 8).as_deref(), Some("9:00 UTC+5:30"));
    assert_eq!(render(&spec(None, 9, 0, None, Some(Zone::Offset(-180))), "en", 8).as_deref(), Some("9:00 UTC-3"));
    assert_eq!(render(&spec(None, 9, 0, None, Some(Zone::Offset(0))), "en", 8).as_deref(), Some("9:00 UTC+0"));
    assert_eq!(render(&spec(None, 9, 0, None, Some(Zone::City("tokyo"))), "en", 4).as_deref(), Some("9:00 Tokyo time"));
    assert_eq!(render(&spec(abs(), 9, 5, None, None), "en", 3).as_deref(), Some("2026-10-03 9:05"));
    // 月日与 ISO 模板对非完整日期不可用
    assert_eq!(render(&spec(Some(DateSpec::MonthDay { month: 10, day: 3 }), 9, 5, None, None), "en", 3), None);
}

// 日语、韩语、简体中文的更多句式
#[test]
fn fixed_cjk_variants() {
    let wd = Some(DateSpec::Weekday { weekday: 5, next: true });
    assert_eq!(render(&spec(wd, 9, 0, None, None), "ja", 9).as_deref(), Some("次の金曜日の9:00"));
    assert_eq!(render(&spec(None, 15, 30, None, None), "ja", 1).as_deref(), Some("午後3時30分"));
    assert_eq!(render(&spec(None, 9, 0, Some((11, 30)), None), "ja", 7).as_deref(), Some("9:00から11:30まで"));
    assert_eq!(render(&spec(None, 9, 0, None, Some(Zone::City("tokyo"))), "ja", 4).as_deref(), Some("9:00、東京時間"));
    assert_eq!(render(&spec(None, 9, 0, None, Some(Zone::Offset(540))), "ja", 8).as_deref(), Some("9:00 UTC+9"));
    assert_eq!(render(&spec(Some(DateSpec::Offset { days: 0 }), 9, 5, None, None), "ja", 2).as_deref(), Some("今日の9:05"));

    assert_eq!(render(&spec(wd, 9, 0, None, None), "ko", 9).as_deref(), Some("다음 금요일 9:00"));
    assert_eq!(render(&spec(None, 15, 30, None, None), "ko", 1).as_deref(), Some("오후 3시 30분"));
    assert_eq!(render(&spec(Some(DateSpec::Offset { days: 2 }), 15, 30, None, Some(Zone::City("new york"))), "ko", 5).as_deref(), Some("모레 15:30 뉴욕 기준"));
    assert_eq!(render(&spec(None, 9, 0, Some((11, 30)), None), "ko", 7).as_deref(), Some("9:00부터 11:30까지"));

    let abs = Some(DateSpec::Absolute { year: 2026, month: 10, day: 3 });
    assert_eq!(render(&spec(wd, 9, 0, None, None), "zh-Hans", 9).as_deref(), Some("下星期五 9:00"));
    assert_eq!(render(&spec(None, 15, 30, None, None), "zh-Hans", 1).as_deref(), Some("下午3:30"));
    assert_eq!(render(&spec(abs, 9, 0, Some((11, 30)), Some(Zone::City("tokyo"))), "zh-Hans", 15).as_deref(), Some("2026年10月3日（从9:00到11:30，东京时间）"));
    assert_eq!(render(&spec(Some(DateSpec::Offset { days: -1 }), 9, 5, None, None), "zh-Hans", 2).as_deref(), Some("昨天9:05"));
}

// 德语、俄语、西班牙语的更多句式（含格变化与 GMT 写法）
#[test]
fn fixed_european_variants() {
    assert_eq!(render(&spec(Some(DateSpec::Offset { days: 1 }), 9, 5, None, None), "de", 2).as_deref(), Some("morgen um 9:05 Uhr"));
    assert_eq!(render(&spec(None, 15, 30, None, None), "de", 1).as_deref(), Some("3:30 Uhr nachmittags"));
    assert_eq!(render(&spec(None, 9, 0, Some((11, 30)), None), "de", 7).as_deref(), Some("von 9:00 Uhr bis 11:30 Uhr"));
    assert_eq!(render(&spec(Some(DateSpec::Weekday { weekday: 3, next: false }), 9, 0, None, None), "de", 10).as_deref(), Some("am Mittwoch um 9:00 Uhr"));

    let wd = Some(DateSpec::Weekday { weekday: 5, next: true });
    assert_eq!(render(&spec(wd, 9, 0, None, None), "ru", 9).as_deref(), Some("в пятницу на следующей неделе в 9:00"));
    assert_eq!(render(&spec(Some(DateSpec::MonthDay { month: 10, day: 3 }), 9, 5, None, None), "ru", 2).as_deref(), Some("3 октября в 9:05"));
    assert_eq!(render(&spec(None, 15, 30, None, None), "ru", 1).as_deref(), Some("3:30 дня"));
    assert_eq!(render(&spec(None, 9, 0, None, Some(Zone::City("london"))), "ru", 4).as_deref(), Some("9:00, время в Лондоне"));

    assert_eq!(render(&spec(None, 15, 30, None, None), "es", 1).as_deref(), Some("3:30 de la tarde"));
    assert_eq!(render(&spec(None, 9, 0, None, Some(Zone::Offset(-180))), "es", 8).as_deref(), Some("9:00 GMT-3"));
    assert_eq!(render(&spec(None, 9, 0, Some((11, 30)), None), "pt-BR", 7).as_deref(), Some("das 9:00 às 11:30"));
}

// 期望摘要格式与 JSON 转义
#[test]
fn expected_and_jsonl_details() {
    let s = spec(Some(DateSpec::Offset { days: 1 }), 15, 45, None, Some(Zone::Offset(330)));
    assert_eq!(expected(&s), "+1d 15:45 +330 > -");
    let tricky = super::Case {
        lang: "en",
        text: "quote \" backslash \\ brace-free \u{7}\u{2028}".into(),
        want: "x".into(),
    };
    let line = super::to_jsonl(&[tricky])[..].to_string();
    assert!(line.contains("\\\"") && line.contains("\\\\"), "{line}");
    assert!(line.contains("\\u0007") && line.contains("\\u2028"), "{line}");
    assert!(line.ends_with("}\n"));
    assert_eq!(super::to_jsonl(&[]), "");
}

// 生成的样例自身保持一致性：句子非空、want 与句子的语义来源相同
#[test]
fn generated_cases_are_consistent() {
    let all = cases(7, 48);
    assert_eq!(all.len(), 16 * 48);
    for lang in LANGUAGES {
        let mine: Vec<&super::Case> = all.iter().filter(|c| c.lang == lang).collect();
        assert_eq!(mine.len(), 48, "{lang}");
        assert!(mine.iter().all(|c| c.text.trim() == c.text), "{lang}");
        assert!(mine.iter().all(|c| c.want.ends_with(" > -")), "{lang}");
        assert!(mine.iter().any(|c| !c.want.contains(" - > -")), "{lang} 应有带时区的样例");
        assert!(mine.iter().any(|c| c.want.contains('\u{2013}')), "{lang} 应有区间样例");
        assert!(mine.iter().any(|c| !c.want.starts_with("- ")), "{lang} 应有带日期的样例");
    }
}

// 用简单 xorshift 造一个完全随机的规格（不做模板适配）
fn random_spec(rng: &mut super::rng::Rng) -> Spec {
    let date = match rng.bound(6) {
        0 => None,
        1 => Some(DateSpec::Absolute {
            year: 2025 + rng.bound(3) as i32,
            month: 1 + rng.bound(12) as u8,
            day: 1 + rng.bound(28) as u8,
        }),
        2 => Some(DateSpec::MonthDay {
            month: 1 + rng.bound(12) as u8,
            day: 1 + rng.bound(28) as u8,
        }),
        3 => Some(DateSpec::Offset {
            days: rng.bound(7) as i8 - 3,
        }),
        4 => Some(DateSpec::Weekday {
            weekday: 1 + rng.bound(7) as u8,
            next: rng.bound(2) == 1,
        }),
        _ => Some(DateSpec::Offset { days: 1 }),
    };
    let hour = rng.bound(24) as u8;
    let minute = [0, 5, 10, 15, 20, 30, 40, 45, 50, 55][rng.bound(10) as usize];
    let end = if rng.bound(3) == 0 && hour < 23 {
        Some(Clock {
            hour: hour + 1,
            minute,
        })
    } else {
        None
    };
    let zone = match rng.bound(3) {
        0 => None,
        1 => Some(Zone::City(
            super::data::CITY_KEYS[rng.bound(8) as usize],
        )),
        _ => Some(Zone::Offset([-300, -180, 0, 60, 330, 345, 540, 600][rng.bound(8) as usize])),
    };
    Spec {
        date,
        time: Clock { hour, minute },
        end,
        zone,
    }
}
