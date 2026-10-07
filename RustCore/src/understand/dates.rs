// SPDX-License-Identifier: GPL-3.0-only
//! 日期与钟点的算术：公历合法性、Hinnant 的公历 ↔ 天数、时段把钟点挪到 24 小时制、地区的日月顺序。
use super::lexicon::Period;
use super::types::DateSpec;

pub(super) fn valid_date(year: i32, month: u8, day: u8) -> bool {
    if !(1..=12).contains(&month) || day == 0 || !(1800..=2200).contains(&year) {
        return false;
    }
    let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;
    let days = [31, if leap { 29 } else { 28 }, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month as usize - 1];
    day <= days
}

/// 没写年的月日：按闰年（2024）核，2 月 29 日也算合法（哪一年由宿主定）。
pub(super) fn valid_month_day(month: u8, day: u8) -> bool {
    valid_date(2024, month, day)
}

pub(super) fn days_from_civil(y: i32, m: u8, d: u8) -> i64 {
    let (y, m, d) = (y as i64 - if m <= 2 { 1 } else { 0 }, m as i64, d as i64);
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let doy = (153 * (m + if m > 2 { -3 } else { 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// 时段把钟点挪到 24 小时制：（钟点，日偏移）。已经是 13–23 点的不动。
pub fn apply_period(hour: u8, period: Period) -> (u8, i8) {
    if hour > 12 {
        return (hour, 0);
    }
    match period {
        Period::Am | Period::Morning | Period::SmallHours => (if hour == 12 { 0 } else { hour }, 0),
        Period::Pm | Period::Afternoon => (if hour == 12 { 12 } else { hour + 12 }, 0),
        Period::Midday => (if (1..=5).contains(&hour) { hour + 12 } else { hour }, 0),
        Period::Evening => if hour == 12 { (0, 0) } else if hour >= 1 { (hour + 12, 0) } else { (0, 0) },
        Period::Night => if hour == 12 { (0, 0) } else if (6..=11).contains(&hour) { (hour + 12, 0) } else { (hour, 0) },
    }
}

/// 时段属于上半天（false）还是下半天（true）：夜里、中午两边都可能，不参与矛盾检查。
pub fn half_day(period: Period) -> Option<bool> {
    match period {
        Period::Am | Period::Morning | Period::SmallHours => Some(false),
        Period::Pm | Period::Afternoon | Period::Evening => Some(true),
        Period::Midday | Period::Night => None,
    }
}

/// 「10/3」这类两个数字的日期先写月还是先写日。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DateOrder {
    MonthDay,
    DayMonth,
}

/// 两个光秃秃的数（3/7）先当月的地区（ISO 3166）：美国与跟着美国写法的几处（加拿大两种都有人写，按月/日读并附另一种）；
/// 年月日顺序写日期、口头也先月的中日韩与匈牙利。判据与逐个理由在 `properties.rs` 的两条测试里；两边都 ≤ 12 时总附另一种顺序。
const MONTH_FIRST_REGIONS: [&str; 17] = [
    "AS", "CA", "CN", "GU", "HU", "JP", "KP", "KR", "MH", "MP", "PA", "PH", "PR", "TW", "UM", "US", "VI",
];

/// 顺序怎么定：这句的语言先说话；英文或判不出时看用户所在地区；地区也没有时看界面语言。
/// 两边都 ≤ 12 时无论怎么定都附另一种顺序（装配层做）。
pub fn date_order(sentence_language: Option<&str>, region: &str, ui_language: &str) -> DateOrder {
    match sentence_language {
        Some("zh" | "ja" | "ko") => return DateOrder::MonthDay,
        Some("de" | "fr" | "es" | "pt" | "it" | "nl" | "pl" | "ru" | "tr" | "vi" | "id") => return DateOrder::DayMonth,
        _ => {}
    }
    let region = region.trim().to_ascii_uppercase();
    if !region.is_empty() {
        return if MONTH_FIRST_REGIONS.contains(&region.as_str()) { DateOrder::MonthDay } else { DateOrder::DayMonth };
    }
    let ui = ui_language.trim().to_ascii_lowercase();
    if ui.starts_with("zh") || ui == "ja" || ui == "ko" || ui == "en" {
        DateOrder::MonthDay
    } else {
        DateOrder::DayMonth
    }
}

/// 点号连的两个数「15.03」在这种语言里先当钟点还是先当日期（两边都 ≤ 12 或小时 13–23 配月份时才用到）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DotReading {
    /// 钟点在前、日/月日期作备选：id、tr、nl、pl、it。
    ClockFirst,
    /// 日/月日期在前、钟点作备选：de、ru。
    DateFirst,
    /// 月/日日期，不当钟点：zh、ja、ko（「3.15」是三月十五）。
    MonthDayOnly,
    /// 不读：英文与其余语言不用点号写钟点也不用点号写这种没有年的日期。
    None,
}

pub fn dot_reading(sentence_language: Option<&str>) -> DotReading {
    match sentence_language {
        Some("id" | "tr" | "nl" | "pl" | "it") => DotReading::ClockFirst,
        Some("de" | "ru") => DotReading::DateFirst,
        Some("zh" | "ja" | "ko") => DotReading::MonthDayOnly,
        _ => DotReading::None,
    }
}

/// 公历日期的结束语给 23:59；相对日子和星期沿用下班时刻，周、月、年不参与。
pub(super) fn apply_written_day_ends(u: &[super::units::Unit], atoms: &mut Vec<super::scan::Located>) {
    use super::scan::{Atom, Located};
    use super::types::Clock;
    use std::sync::OnceLock;
    struct Cue {
        before: Vec<String>,
        after: Vec<String>,
        language: &'static str,
    }
    static CUES: OnceLock<Vec<Cue>> = OnceLock::new();
    let cues = CUES.get_or_init(|| super::lexicon::DAY_END_CUES.iter().map(|&(before, after, language)| Cue {
        before: super::units::phrase_units(&super::text::fold_str(before)),
        after: super::units::phrase_units(&super::text::fold_str(after)),
        language: match language { "zh-Hans" | "zh-Hant" => "zh", "pt-BR" => "pt", other => other },
    }).collect());
    let matches = |from: usize, phrase: &[String]| u.get(from..from + phrase.len())
        .is_some_and(|span| span.iter().zip(phrase).all(|(unit, expected)| unit.text == *expected));
    let mut ends = Vec::new();
    for day in atoms.iter() {
        if !matches!(day.atom, Atom::Date(_) | Atom::DatePeriod(..) | Atom::SlashPair { .. }) {
            continue;
        }
        let best = cues.iter().filter_map(|cue| {
            let from = day.from.checked_sub(cue.before.len())?;
            (matches(from, &cue.before) && matches(day.to, &cue.after))
                .then_some((from, day.to + cue.after.len(), cue.language))
        }).max_by_key(|(from, to, _)| to - from);
        if let Some((from, to, lang)) = best {
            if !atoms.iter().any(|a| matches!(a.atom, Atom::Idiom(..)) && a.from == from && a.to == to) {
                let calendar = matches!(day.atom, Atom::Date(DateSpec::Absolute { .. } | DateSpec::MonthDay { .. }) | Atom::SlashPair { .. });
                let (key, clock) = if calendar { ("dayend", Clock::at(23, 59)) } else { ("eod", Clock::at(17, 0)) };
                ends.push(Located { atom: Atom::Idiom(key, clock), from, to, lang: Some(lang) });
            }
        }
    }
    // 日末短语里的旧下班习语、介词和地点线索已由整个短语认走。
    atoms.retain(|atom| matches!(atom.atom, Atom::Date(_) | Atom::DatePeriod(..) | Atom::SlashPair { .. })
        || !ends.iter().any(|end| end.from <= atom.from && atom.to <= end.to));
    atoms.extend(ends);
    atoms.sort_by_key(|atom| (atom.from, atom.to));
}
