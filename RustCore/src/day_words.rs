// SPDX-License-Identifier: GPL-3.0-only
//! 一天里的词：面板每行第二行打头的那个词，告诉人「那边此刻是一天里的什么时候」。
//!
//! 太阳贴着地平线时按太阳说（破晓 / 日出 / 日落 / 黄昏：太阳高度 −7° … 0° 升起时破晓、落下时黄昏，0° … 5° 日出 / 日落），
//! 这组词跨文化最稳；其余按当地钟点，**每种语言一张自己的表**。此前是一张中文钟点表的译文套到十种语言上，
//! 边界与用词都错了（「深夜」23 点在法、德、西、葡、俄译成「午夜那一刻」，德语 11 点写 Mittag）。
//!
//! 表的来源：中文（简繁）沿用原型定的八段（深夜、凌晨、清晨、上午、中午、下午、傍晚、晚上）；其余语言取 Unicode CLDR
//! 的 `dayPeriods` 规则与各语言的独立（stand-alone）写法，首字母按句首大写。只改两处：CLDR 是给「凌晨三点」这类说法用的，
//! 英语把 0–12 点都算 morning，法、俄、日、越 4 点起就算早上，印尼语 0 点起就是 pagi；当标签贴在行上会让人以为那边已经是早上，
//! 所以统一一条：5 点前写夜（Night / Nuit / Ночь / 夜中 / Đêm / Malam）；韩语 3–6 点 CLDR 写 아침，那几个钟头韩语习惯叫 새벽（本来就是天亮前）。
//!
//! 意、荷、波、土、越、印尼六语的太阳四词：日出、日落取苹果自家的写法（系统「天气」与「照片」场景词表，
//! 本机 `Weather.app` 与 `PhotosFormats.framework` 的 loctable），黄昏取「照片」的 Dusk（土耳其语除外，见下）；破晓两处都没有，按各语言的常用词：
//! 意大利语 Alba 本义就是日出前的第一道光（Treccani），日出用「天气」的 Levata del sole，两者不重；荷兰语 Dageraad；波兰语 Świt；
//! 土耳其语 Şafak，黄昏用 Alacakaranlık（「照片」的 Akşam karanlığı 是「天黑了」，而钟点表 18 点起已是 Akşamüstü / Akşam）；
//! 越南语 Bình minh 与 Hoàng hôn 本是一对（破晓 / 黄昏），日出日落用「天气」的 Mặt trời mọc / lặn，免得与这一对混；印尼语 Fajar 与 Senja。

/// 太阳四词：破晓、日出、日落、黄昏。
struct SunWords {
    dawn: &'static str,
    sunrise: &'static str,
    sunset: &'static str,
    dusk: &'static str,
}

/// 一种语言：太阳四词，与按当地钟点的表（每段的起点小时与词，从 0 点起、按小时升序；最后一段一直到 24 点）。
struct Table {
    sun: SunWords,
    clock: &'static [(u32, &'static str)],
}

const CHINESE_CLOCK: &[(u32, &str)] =
    &[(0, "深夜"), (1, "凌晨"), (5, "清晨"), (8, "上午"), (11, "中午"), (13, "下午"), (17, "傍晚"), (19, "晚上"), (23, "深夜")];

fn table(language: &str) -> Table {
    let sun = |dawn, sunrise, sunset, dusk| SunWords { dawn, sunrise, sunset, dusk };
    match language {
        "zh-Hans" => Table { sun: sun("破晓", "日出", "日落", "黄昏"), clock: CHINESE_CLOCK },
        "zh-Hant" => Table { sun: sun("破曉", "日出", "日落", "黃昏"), clock: CHINESE_CLOCK },
        "ja" => Table {
            sun: sun("夜明け", "日の出", "日の入り", "夕暮れ"),
            clock: &[(0, "夜中"), (5, "朝"), (12, "昼"), (16, "夕方"), (19, "夜"), (23, "夜中")],
        },
        "ko" => Table {
            sun: sun("동틀 녘", "일출", "일몰", "해 질 녘"),
            clock: &[(0, "밤"), (3, "새벽"), (6, "오전"), (12, "오후"), (18, "저녁"), (21, "밤")],
        },
        "de" => Table {
            sun: sun("Morgengrauen", "Sonnenaufgang", "Sonnenuntergang", "Abenddämmerung"),
            clock: &[(0, "Nacht"), (5, "Morgen"), (10, "Vormittag"), (12, "Mittag"), (13, "Nachmittag"), (18, "Abend")],
        },
        "es" => Table {
            sun: sun("Alba", "Amanecer", "Atardecer", "Anochecer"),
            clock: &[(0, "Madrugada"), (6, "Mañana"), (12, "Tarde"), (20, "Noche")],
        },
        "fr" => Table {
            sun: sun("Aube", "Lever du soleil", "Coucher du soleil", "Crépuscule"),
            clock: &[(0, "Nuit"), (5, "Matin"), (12, "Après-midi"), (18, "Soir")],
        },
        "pt-BR" => Table {
            sun: sun("Alvorada", "Nascer do Sol", "Pôr do Sol", "Crepúsculo"),
            clock: &[(0, "Madrugada"), (6, "Manhã"), (12, "Tarde"), (19, "Noite")],
        },
        "ru" => Table {
            sun: sun("Рассвет", "Восход", "Закат", "Сумерки"),
            clock: &[(0, "Ночь"), (5, "Утро"), (12, "День"), (18, "Вечер"), (22, "Ночь")],
        },
        "it" => Table {
            sun: sun("Alba", "Levata del sole", "Tramonto", "Crepuscolo"),
            clock: &[(0, "Notte"), (6, "Mattina"), (12, "Pomeriggio"), (18, "Sera")],
        },
        "nl" => Table {
            sun: sun("Dageraad", "Zonsopgang", "Zonsondergang", "Schemering"),
            clock: &[(0, "Nacht"), (6, "Ochtend"), (12, "Middag"), (18, "Avond")],
        },
        "pl" => Table {
            sun: sun("Świt", "Wschód słońca", "Zachód słońca", "Zmierzch"),
            clock: &[(0, "Noc"), (6, "Rano"), (10, "Przedpołudnie"), (12, "Popołudnie"), (18, "Wieczór"), (21, "Noc")],
        },
        "tr" => Table {
            sun: sun("Şafak", "Gün doğumu", "Gün batımı", "Alacakaranlık"),
            clock: &[(0, "Gece"), (6, "Sabah"), (11, "Öğleden önce"), (12, "Öğleden sonra"), (18, "Akşamüstü"), (19, "Akşam"), (21, "Gece")],
        },
        "vi" => Table {
            sun: sun("Bình minh", "Mặt trời mọc", "Mặt trời lặn", "Hoàng hôn"),
            clock: &[(0, "Đêm"), (5, "Sáng"), (12, "Chiều"), (18, "Tối"), (21, "Đêm")],
        },
        "id" => Table {
            sun: sun("Fajar", "Matahari terbit", "Matahari terbenam", "Senja"),
            clock: &[(0, "Malam"), (5, "Pagi"), (10, "Siang"), (15, "Sore"), (18, "Malam")],
        },
        _ => Table {
            sun: sun("Dawn", "Sunrise", "Sunset", "Dusk"),
            clock: &[(0, "Night"), (5, "Morning"), (12, "Afternoon"), (18, "Evening"), (21, "Night")],
        },
    }
}

/// 界面语言（`zh-Hans`、`zh-Hant`、`en`、`ja`、`ko`、`de`、`es`、`fr`、`pt-BR`、`ru`…）里，当地钟点 `local_minutes`（0 … 1440）、
/// 太阳高度 `altitude`（度）、太阳正在升（`is_rising`）时的那个词。不认识的语言用英语。
pub(crate) fn word(language: &str, local_minutes: f64, altitude: f64, is_rising: bool) -> &'static str {
    let table = table(language);
    let sun = table.sun;
    if (-7.0..0.0).contains(&altitude) {
        return if is_rising { sun.dawn } else { sun.dusk };
    }
    if (0.0..5.0).contains(&altitude) {
        return if is_rising { sun.sunrise } else { sun.sunset };
    }
    let hour = (local_minutes.rem_euclid(1440.0) / 60.0).floor() as u32;
    table.clock.iter().rev().find(|(from, _)| *from <= hour).map_or(table.clock[0].1, |(_, word)| word)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 离地平线远（太阳高 40° 或低 −40°）时按钟点：
    fn at(language: &str, hour: f64) -> &'static str {
        word(language, hour * 60.0, if (6.0..18.0).contains(&hour) { 40.0 } else { -40.0 }, hour < 12.0)
    }

    /// 检查各语言的钟点边界：23 点不是「午夜」，德语 11 点不是 Mittag，西语 19 点还是 tarde。
    #[test]
    fn each_language_has_its_own_hours() {
        assert_eq!(at("fr", 23.1), "Soir");
        assert_eq!(at("de", 23.1), "Abend");
        assert_eq!(at("es", 23.1), "Noche");
        assert_eq!(at("pt-BR", 23.1), "Noite");
        assert_eq!(at("ru", 23.1), "Ночь");
        assert_eq!(at("de", 11.0), "Vormittag");
        assert_eq!(at("de", 12.5), "Mittag");
        assert_eq!(at("de", 13.0), "Nachmittag");
        assert_eq!(at("es", 19.0), "Tarde");
        assert_eq!(at("es", 20.0), "Noche");
        assert_eq!(at("pt-BR", 19.0), "Noite");
        assert_eq!(at("ru", 19.0), "Вечер");
        assert_eq!(at("ja", 17.0), "夕方");
        assert_eq!(at("ja", 23.5), "夜中");
        assert_eq!(at("ko", 4.0), "새벽");
        assert_eq!(at("ko", 22.0), "밤");
        // 天亮前不说「早上」：5 点前是夜（CLDR 的 morning / matin / утро / 朝 是给「凌晨三点」这类说法用的）。
        assert_eq!(at("en", 2.0), "Night");
        assert_eq!(at("en", 5.5), "Morning");
        assert_eq!(at("fr", 4.5), "Nuit");
        assert_eq!(at("fr", 5.0), "Matin");
        assert_eq!(at("ru", 4.6), "Ночь");
        assert_eq!(at("ru", 5.0), "Утро");
        assert_eq!(at("ja", 4.6), "夜中");
        assert_eq!(at("ja", 5.0), "朝");
        assert_eq!(at("vi", 4.6), "Đêm");
        assert_eq!(at("id", 3.0), "Malam");
        assert_eq!(at("id", 6.0), "Pagi");
        // 所有语言：4:30 都不是早上那个词。
        for language in ["en", "fr", "ru", "ja", "vi", "id", "de", "es", "pt-BR", "it", "nl", "pl", "tr", "zh-Hans"] {
            let early = at(language, 4.5);
            assert!(![("en", "Morning"), ("fr", "Matin"), ("ru", "Утро"), ("ja", "朝"), ("vi", "Sáng"), ("id", "Pagi")].contains(&(language, early)), "{language} {early}");
        }
        // 中文沿用原型的八段。
        assert_eq!(at("zh-Hans", 0.5), "深夜");
        assert_eq!(at("zh-Hans", 3.0), "凌晨");
        assert_eq!(at("zh-Hans", 14.0), "下午");
        assert_eq!(at("zh-Hans", 17.5), "傍晚");
        assert_eq!(at("zh-Hant", 23.5), "深夜");
        // 不认识的语言用英语。
        assert_eq!(at("xx", 14.0), "Afternoon");
    }

    /// 太阳贴着地平线时按太阳说，与钟点无关（高纬度的夏天，日出可以在凌晨三点）。
    #[test]
    fn near_the_horizon_the_sun_decides() {
        assert_eq!(word("zh-Hans", 6.0 * 60.0, -3.0, true), "破晓");
        assert_eq!(word("zh-Hans", 19.0 * 60.0, -3.0, false), "黄昏");
        assert_eq!(word("zh-Hans", 7.0 * 60.0, 2.0, true), "日出");
        assert_eq!(word("zh-Hans", 18.0 * 60.0, 2.0, false), "日落");
        assert_eq!(word("zh-Hant", 18.0 * 60.0, -2.0, false), "黃昏");
        assert_eq!(word("de", 3.0 * 60.0, 1.0, true), "Sonnenaufgang");
        assert_eq!(word("ja", 18.5 * 60.0, 3.0, false), "日の入り");
        assert_eq!(word("it", 6.0 * 60.0, -3.0, true), "Alba");
        assert_eq!(word("it", 6.5 * 60.0, 2.0, true), "Levata del sole");
        assert_eq!(word("nl", 21.0 * 60.0, -4.0, false), "Schemering");
        assert_eq!(word("pl", 20.0 * 60.0, 1.0, false), "Zachód słońca");
        assert_eq!(word("tr", 5.5 * 60.0, -6.0, true), "Şafak");
        assert_eq!(word("vi", 17.8 * 60.0, 3.0, false), "Mặt trời lặn");
        assert_eq!(word("id", 18.3 * 60.0, -2.0, false), "Senja");
        assert_eq!(word("xx", 6.0 * 60.0, -3.0, true), "Dawn");
    }

    /// 每张钟点表：从 0 点起、起点严格升序、不超过 23；每个小时都落在某一段里。
    #[test]
    fn every_table_covers_the_whole_day() {
        for language in ["zh-Hans", "zh-Hant", "en", "ja", "ko", "de", "es", "fr", "pt-BR", "ru", "it", "nl", "pl", "tr", "vi", "id"] {
            let clock = table(language).clock;
            assert_eq!(clock[0].0, 0, "{language}");
            assert!(clock.windows(2).all(|w| w[0].0 < w[1].0), "{language}");
            assert!(clock.iter().all(|(h, word)| *h < 24 && !word.is_empty()), "{language}");
            for minutes in (0..1440).step_by(30) {
                assert!(!word(language, f64::from(minutes), -40.0, false).is_empty());
            }
        }
    }
}
