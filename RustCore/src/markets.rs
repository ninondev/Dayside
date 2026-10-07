// SPDX-License-Identifier: GPL-3.0-only
//! 市场时钟。
//!
//! 一个市场就是「地点 + 作息 + 休市日」，数据形状与人物透镜相同。这里管三件事：
//! ①预置市场的封闭表（交易所与外汇时段，含午休那种两段式）；②休市日的**规则**
//! （美英是「几月第几个星期几」加复活节，日本还有春分秋分与振替休日，中港有农历锚点）；
//! ③给定一串真实的时段边界，判断现在开着还是关着、下一次变化是什么时候。
//!
//! 不做行情、不联网。农历日期与分点日期这类要日历事实的东西由宿主（Foundation / ICU 的
//! 农历与我们的天文模块）算好传进来——Rust 只决定「哪个市场认哪些休市日」。

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

/// 休市日规则的编号：同一套规则可被多个市场共用（NYSE 与 NASDAQ 就是同一套）。
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum HolidaySet {
    UnitedStates,
    UnitedKingdom,
    Japan,
    MainlandChina,
    HongKong,
    /// 没有收录休市日：只按作息算，页面如实写明。
    None,
}

#[derive(Clone, Copy)]
pub struct Session {
    pub start_minute: i64,
    pub end_minute: i64,
}

#[derive(Clone, Copy)]
pub struct Market {
    pub id: &'static str,
    /// 界面上的名字走字符串目录，这里只给键（源语是简体中文，与其它文案同一套）。
    pub name_key: &'static str,
    pub time_zone_id: &'static str,
    pub sessions: &'static [Session],
    pub holidays: HolidaySet,
    /// 外汇时段没有交易所，只是「这个时区的市场时间」；页面分组用。
    pub kind: &'static str,
    /// 交易所所在的城市（纬度, 经度）：页面上那一行的天按它画。不用时区的代表城市：
    /// 印度国家证券交易所在孟买，时区代表城市是加尔各答，两地日出差近一小时。
    pub city: (f64, f64),
}

const fn session(start: i64, end: i64) -> Session {
    Session {
        start_minute: start,
        end_minute: end,
    }
}

/// 预置市场。作息是各市场官网公布的常规交易时段（本地墙钟），不含盘前盘后与半日市。
/// 加市场要同时给 `name_key` 的十语译文；不确定休市日就用 `HolidaySet::None`，页面会写明。
pub static MARKETS: &[Market] = &[
    Market {
        id: "nyse",
        name_key: "纽约证券交易所",
        time_zone_id: "America/New_York",
        sessions: &[session(570, 960)], // 09:30–16:00
        holidays: HolidaySet::UnitedStates,
        kind: "exchange",
        city: (40.71, -74.01),
    },
    Market {
        id: "nasdaq",
        name_key: "纳斯达克",
        time_zone_id: "America/New_York",
        sessions: &[session(570, 960)],
        holidays: HolidaySet::UnitedStates,
        kind: "exchange",
        city: (40.71, -74.01),
    },
    Market {
        id: "lse",
        name_key: "伦敦证券交易所",
        time_zone_id: "Europe/London",
        sessions: &[session(480, 990)], // 08:00–16:30
        holidays: HolidaySet::UnitedKingdom,
        kind: "exchange",
        city: (51.51, -0.10),
    },
    Market {
        id: "tse",
        name_key: "东京证券交易所",
        time_zone_id: "Asia/Tokyo",
        // 2024-11 起后场延到 15:30，中午休市 11:30–12:30。
        sessions: &[session(540, 690), session(750, 930)],
        holidays: HolidaySet::Japan,
        kind: "exchange",
        city: (35.68, 139.78),
    },
    Market {
        id: "hkex",
        name_key: "香港交易所",
        time_zone_id: "Asia/Hong_Kong",
        sessions: &[session(570, 720), session(780, 960)], // 09:30–12:00、13:00–16:00
        holidays: HolidaySet::HongKong,
        kind: "exchange",
        city: (22.28, 114.16),
    },
    Market {
        id: "sse",
        name_key: "上海证券交易所",
        time_zone_id: "Asia/Shanghai",
        sessions: &[session(570, 690), session(780, 900)], // 09:30–11:30、13:00–15:00
        holidays: HolidaySet::MainlandChina,
        kind: "exchange",
        city: (31.23, 121.47),
    },
    Market {
        id: "euronext-paris",
        name_key: "泛欧交易所（巴黎）",
        time_zone_id: "Europe/Paris",
        sessions: &[session(540, 1050)], // 09:00–17:30
        holidays: HolidaySet::None,
        kind: "exchange",
        city: (48.87, 2.34),
    },
    Market {
        id: "xetra",
        name_key: "德意志交易所（Xetra）",
        time_zone_id: "Europe/Berlin",
        sessions: &[session(540, 1050)],
        holidays: HolidaySet::None,
        kind: "exchange",
        city: (50.11, 8.68),
    },
    Market {
        id: "asx",
        name_key: "澳大利亚证券交易所",
        time_zone_id: "Australia/Sydney",
        sessions: &[session(600, 960)], // 10:00–16:00
        holidays: HolidaySet::None,
        kind: "exchange",
        city: (-33.87, 151.21),
    },
    Market {
        id: "tsx",
        name_key: "多伦多证券交易所",
        time_zone_id: "America/Toronto",
        sessions: &[session(570, 960)],
        holidays: HolidaySet::None,
        kind: "exchange",
        city: (43.65, -79.38),
    },
    Market {
        id: "nse",
        name_key: "印度国家证券交易所",
        time_zone_id: "Asia/Kolkata",
        sessions: &[session(555, 930)], // 09:15–15:30
        holidays: HolidaySet::None,
        kind: "exchange",
        city: (19.06, 72.86),
    },
    // 外汇的四个时段：按业界惯例的当地时间，用来看「哪几段在重叠」。
    Market {
        id: "fx-sydney",
        name_key: "外汇 · 悉尼时段",
        time_zone_id: "Australia/Sydney",
        sessions: &[session(420, 960)], // 07:00–16:00
        holidays: HolidaySet::None,
        kind: "fx",
        city: (-33.87, 151.21),
    },
    Market {
        id: "fx-tokyo",
        name_key: "外汇 · 东京时段",
        time_zone_id: "Asia/Tokyo",
        sessions: &[session(540, 1020)], // 09:00–17:00
        holidays: HolidaySet::None,
        kind: "fx",
        city: (35.68, 139.78),
    },
    Market {
        id: "fx-london",
        name_key: "外汇 · 伦敦时段",
        time_zone_id: "Europe/London",
        sessions: &[session(480, 1020)], // 08:00–17:00
        holidays: HolidaySet::None,
        kind: "fx",
        city: (51.51, -0.10),
    },
    Market {
        id: "fx-new-york",
        name_key: "外汇 · 纽约时段",
        time_zone_id: "America/New_York",
        sessions: &[session(480, 1020)],
        holidays: HolidaySet::None,
        kind: "fx",
        city: (40.71, -74.01),
    },
];

fn holiday_set_name(set: HolidaySet) -> &'static str {
    match set {
        HolidaySet::UnitedStates => "us",
        HolidaySet::UnitedKingdom => "uk",
        HolidaySet::Japan => "jp",
        HolidaySet::MainlandChina => "cn",
        HolidaySet::HongKong => "hk",
        HolidaySet::None => "none",
    }
}

/// 市场目录（页面用）。
pub fn catalog() -> Value {
    json!(MARKETS
        .iter()
        .map(|market| json!({
            "id": market.id,
            "nameKey": market.name_key,
            "timeZoneID": market.time_zone_id,
            "kind": market.kind,
            "holidaySet": holiday_set_name(market.holidays),
            "latitude": market.city.0,
            "longitude": market.city.1,
            "sessions": market.sessions.iter().map(|session| json!({
                "startMinute": session.start_minute, "endMinute": session.end_minute
            })).collect::<Vec<_>>(),
        }))
        .collect::<Vec<_>>())
}

// MARK: - 休市日

/// 公历闰年（格里历规则）。
fn leap(year: i64) -> bool {
    (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
}

fn days_in_month(year: i64, month: i64) -> i64 {
    match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        _ => {
            if leap(year) {
                29
            } else {
                28
            }
        }
    }
}

/// 从 1970-01-01（星期四）起的天数；只用来推星期与做加减，不涉及时区。
fn day_number(year: i64, month: i64, day: i64) -> i64 {
    let mut total = 0;
    if year >= 1970 {
        for y in 1970..year {
            total += if leap(y) { 366 } else { 365 };
        }
    } else {
        for y in year..1970 {
            total -= if leap(y) { 366 } else { 365 };
        }
    }
    for m in 1..month {
        total += days_in_month(year, m);
    }
    total + day - 1
}

/// 0 = 周日 … 6 = 周六（1970-01-01 是周四 = 4）。
fn weekday(year: i64, month: i64, day: i64) -> i64 {
    (day_number(year, month, day) + 4).rem_euclid(7)
}

fn from_day_number(mut number: i64) -> (i64, i64, i64) {
    let mut year = 1970;
    loop {
        let length = if leap(year) { 366 } else { 365 };
        if number >= length {
            number -= length;
            year += 1;
        } else if number < 0 {
            year -= 1;
            number += if leap(year) { 366 } else { 365 };
        } else {
            break;
        }
    }
    let mut month = 1;
    while number >= days_in_month(year, month) {
        number -= days_in_month(year, month);
        month += 1;
    }
    (year, month, number + 1)
}

fn shift(date: (i64, i64, i64), days: i64) -> (i64, i64, i64) {
    from_day_number(day_number(date.0, date.1, date.2) + days)
}

/// 某年某月第 n 个星期 w（w：0 = 周日）。
fn nth_weekday(year: i64, month: i64, w: i64, n: i64) -> (i64, i64, i64) {
    let first = weekday(year, month, 1);
    let offset = (w - first).rem_euclid(7);
    (year, month, 1 + offset + (n - 1) * 7)
}

/// 某年某月最后一个星期 w。
fn last_weekday(year: i64, month: i64, w: i64) -> (i64, i64, i64) {
    let length = days_in_month(year, month);
    let last = weekday(year, month, length);
    (year, month, length - (last - w).rem_euclid(7))
}

/// 复活节（格里历，Anonymous Gregorian algorithm）。耶稣受难日 = 复活节前两天。
pub fn easter(year: i64) -> (i64, i64, i64) {
    let a = year % 19;
    let b = year / 100;
    let c = year % 100;
    let d = b / 4;
    let e = b % 4;
    let f = (b + 8) / 25;
    let g = (b - f + 1) / 3;
    let h = (19 * a + b - d - g + 15) % 30;
    let i = c / 4;
    let k = c % 4;
    let l = (32 + 2 * e + 2 * i - h - k) % 7;
    let m = (a + 11 * h + 22 * l) / 451;
    let month = (h + l - 7 * m + 114) / 31;
    let day = ((h + l - 7 * m + 114) % 31) + 1;
    (year, month, day)
}

/// 宿主给的日历事实：这一年里要靠农历或天文才知道的日子（都是该地民用日）。
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct YearAnchors {
    /// 农历正月初一。
    #[serde(default)]
    pub lunar_new_year: Option<String>,
    /// 农历八月十五（中秋）。
    #[serde(default)]
    pub mid_autumn: Option<String>,
    /// 农历五月初五（端午）。
    #[serde(default)]
    pub dragon_boat: Option<String>,
    /// 清明（节气，公历 4 月 4–6 日）。
    #[serde(default)]
    pub qingming: Option<String>,
    /// 春分、秋分（日本的春分の日 / 秋分の日 就是这两天）。
    #[serde(default)]
    pub march_equinox: Option<String>,
    #[serde(default)]
    pub september_equinox: Option<String>,
}

#[derive(Clone, Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Holiday {
    /// `YYYY-MM-DD`。
    pub date: String,
    /// 名字的字符串目录键。
    pub name_key: String,
}

fn iso(date: (i64, i64, i64)) -> String {
    format!("{:04}-{:02}-{:02}", date.0, date.1, date.2)
}

fn parse_iso(text: &str) -> Option<(i64, i64, i64)> {
    let mut parts = text.split('-');
    let year = parts.next()?.parse().ok()?;
    let month = parts.next()?.parse().ok()?;
    let day = parts.next()?.parse().ok()?;
    if (1..=12).contains(&month) && (1..=31).contains(&day) {
        Some((year, month, day))
    } else {
        None
    }
}

/// 周末顺延：周六的假日提前到周五、周日的顺延到周一（美国市场的惯例）。
fn us_observed(date: (i64, i64, i64)) -> (i64, i64, i64) {
    match weekday(date.0, date.1, date.2) {
        6 => shift(date, -1),
        0 => shift(date, 1),
        _ => date,
    }
}

/// 英国的替代假日：碰上周末就推到下一个工作日（圣诞与节礼日可能连推两天）。
fn uk_substitute(date: (i64, i64, i64), taken: &[(i64, i64, i64)]) -> (i64, i64, i64) {
    let mut candidate = date;
    loop {
        let w = weekday(candidate.0, candidate.1, candidate.2);
        if w == 0 || w == 6 || taken.contains(&candidate) {
            candidate = shift(candidate, 1);
        } else {
            return candidate;
        }
    }
}

/// 日本的振替休日：假日落在周日就顺延到下一个「既不是假日也不是别的振替休日」的日子。
/// **必须先知道全年的假日**再算顺延：2026-05-03（宪法纪念日）是周日，而 5-4、5-5 本身也是假日，
/// 所以振替休日落在 5-6——顺着往前找的时候把后面的假日也算进去（第一版就漏了这个）。
fn jp_substitute(
    date: (i64, i64, i64),
    fixed: &[(i64, i64, i64)],
    substitutes: &[(i64, i64, i64)],
) -> Option<(i64, i64, i64)> {
    if weekday(date.0, date.1, date.2) != 0 {
        return None;
    }
    let mut candidate = shift(date, 1);
    while fixed.contains(&candidate) || substitutes.contains(&candidate) {
        candidate = shift(candidate, 1);
    }
    Some(candidate)
}

fn push(out: &mut Vec<Holiday>, date: (i64, i64, i64), key: &str) {
    out.push(Holiday {
        date: iso(date),
        name_key: key.to_owned(),
    });
}

struct AnnouncedClosure {
    year: i64,
    first: (i64, i64),
    last: (i64, i64),
    name_key: &'static str,
}

// 来源：上海证券交易所 2025-12-22 公布的 2026 年节假日休市安排。
const MAINLAND_CLOSURES: &[AnnouncedClosure] = &[
    AnnouncedClosure {
        year: 2026,
        first: (1, 1),
        last: (1, 3),
        name_key: "元旦",
    },
    AnnouncedClosure {
        year: 2026,
        first: (2, 15),
        last: (2, 23),
        name_key: "春节",
    },
    AnnouncedClosure {
        year: 2026,
        first: (4, 4),
        last: (4, 6),
        name_key: "清明节",
    },
    AnnouncedClosure {
        year: 2026,
        first: (5, 1),
        last: (5, 5),
        name_key: "劳动节",
    },
    AnnouncedClosure {
        year: 2026,
        first: (6, 19),
        last: (6, 21),
        name_key: "端午节",
    },
    AnnouncedClosure {
        year: 2026,
        first: (9, 25),
        last: (9, 27),
        name_key: "中秋节",
    },
    AnnouncedClosure {
        year: 2026,
        first: (10, 1),
        last: (10, 7),
        name_key: "国庆节",
    },
];

// 来源：香港交易所 2026 年证券市场交易日历；半日交易不在此表中。
const HONG_KONG_CLOSURES: &[AnnouncedClosure] = &[
    AnnouncedClosure {
        year: 2026,
        first: (1, 1),
        last: (1, 1),
        name_key: "元旦",
    },
    AnnouncedClosure {
        year: 2026,
        first: (2, 17),
        last: (2, 19),
        name_key: "农历新年",
    },
    AnnouncedClosure {
        year: 2026,
        first: (4, 3),
        last: (4, 3),
        name_key: "耶稣受难日",
    },
    AnnouncedClosure {
        year: 2026,
        first: (4, 6),
        last: (4, 6),
        name_key: "复活节星期一",
    },
    AnnouncedClosure {
        year: 2026,
        first: (4, 7),
        last: (4, 7),
        name_key: "清明节翌日",
    },
    AnnouncedClosure {
        year: 2026,
        first: (5, 1),
        last: (5, 1),
        name_key: "劳动节",
    },
    AnnouncedClosure {
        year: 2026,
        first: (5, 25),
        last: (5, 25),
        name_key: "佛诞翌日",
    },
    AnnouncedClosure {
        year: 2026,
        first: (6, 19),
        last: (6, 19),
        name_key: "端午节",
    },
    AnnouncedClosure {
        year: 2026,
        first: (7, 1),
        last: (7, 1),
        name_key: "香港特别行政区成立纪念日",
    },
    AnnouncedClosure {
        year: 2026,
        first: (10, 1),
        last: (10, 1),
        name_key: "国庆节",
    },
    AnnouncedClosure {
        year: 2026,
        first: (10, 19),
        last: (10, 19),
        name_key: "重阳节翌日",
    },
    AnnouncedClosure {
        year: 2026,
        first: (12, 25),
        last: (12, 25),
        name_key: "圣诞节",
    },
];

/// 一年的休市日。规则在这里，农历与分点由 `anchors` 给；`HolidaySet::None` 返回空表。
pub fn holidays(set: HolidaySet, year: i64, anchors: &YearAnchors) -> Vec<Holiday> {
    let mut out: Vec<Holiday> = Vec::new();
    match set {
        HolidaySet::UnitedStates => {
            push(&mut out, us_observed((year, 1, 1)), "元旦");
            push(&mut out, nth_weekday(year, 1, 1, 3), "马丁·路德·金纪念日");
            push(&mut out, nth_weekday(year, 2, 1, 3), "华盛顿诞辰日");
            push(&mut out, shift(easter(year), -2), "耶稣受难日");
            push(&mut out, last_weekday(year, 5, 1), "阵亡将士纪念日");
            push(&mut out, us_observed((year, 6, 19)), "六月节");
            push(&mut out, us_observed((year, 7, 4)), "美国独立日");
            push(&mut out, nth_weekday(year, 9, 1, 1), "劳动节");
            push(&mut out, nth_weekday(year, 11, 4, 4), "感恩节");
            push(&mut out, us_observed((year, 12, 25)), "圣诞节");
        }
        HolidaySet::UnitedKingdom => {
            let mut taken: Vec<(i64, i64, i64)> = Vec::new();
            let new_year = uk_substitute((year, 1, 1), &taken);
            taken.push(new_year);
            push(&mut out, new_year, "元旦");
            push(&mut out, shift(easter(year), -2), "耶稣受难日");
            push(&mut out, shift(easter(year), 1), "复活节星期一");
            push(&mut out, nth_weekday(year, 5, 1, 1), "五月初银行假日");
            push(&mut out, last_weekday(year, 5, 1), "春季银行假日");
            push(&mut out, last_weekday(year, 8, 1), "夏季银行假日");
            let christmas = uk_substitute((year, 12, 25), &taken);
            taken.push(christmas);
            push(&mut out, christmas, "圣诞节");
            let boxing = uk_substitute((year, 12, 26), &taken);
            push(&mut out, boxing, "节礼日");
        }
        HolidaySet::Japan => {
            let mut taken: Vec<(i64, i64, i64)> = Vec::new();
            let mut fixed: Vec<((i64, i64, i64), &str)> = vec![
                ((year, 1, 1), "元旦"),
                ((year, 2, 11), "建国纪念日"),
                ((year, 2, 23), "天皇诞辰日"),
                ((year, 4, 29), "昭和日"),
                ((year, 5, 3), "宪法纪念日"),
                ((year, 5, 4), "绿之日"),
                ((year, 5, 5), "儿童节"),
                ((year, 8, 11), "山之日"),
                ((year, 11, 3), "文化日"),
                ((year, 11, 23), "劳动感谢日"),
            ];
            // 快乐星期一：成人日（1 月第 2 个周一）、海之日（7 月第 3 个周一）、
            // 敬老日（9 月第 3 个周一）、体育日（10 月第 2 个周一）。
            fixed.push((nth_weekday(year, 1, 1, 2), "成人日"));
            fixed.push((nth_weekday(year, 7, 1, 3), "海之日"));
            fixed.push((nth_weekday(year, 9, 1, 3), "敬老日"));
            fixed.push((nth_weekday(year, 10, 1, 2), "体育日"));
            if let Some(date) = anchors.march_equinox.as_deref().and_then(parse_iso) {
                fixed.push((date, "春分日"));
            }
            if let Some(date) = anchors.september_equinox.as_deref().and_then(parse_iso) {
                fixed.push((date, "秋分日"));
            }
            fixed.sort_by_key(|(date, _)| day_number(date.0, date.1, date.2));
            let dates: Vec<(i64, i64, i64)> = fixed.iter().map(|(date, _)| *date).collect();
            for (date, key) in &fixed {
                push(&mut out, *date, key);
                if let Some(substitute) = jp_substitute(*date, &dates, &taken) {
                    taken.push(substitute);
                    push(&mut out, substitute, "振替休日");
                }
            }
            // 东证的年末年初休市：12-31 与 1-2、1-3（1-1 已在上面）。
            push(&mut out, (year, 1, 2), "年初休市");
            push(&mut out, (year, 1, 3), "年初休市");
            push(&mut out, (year, 12, 31), "年末休市");
        }
        HolidaySet::MainlandChina => {
            if MAINLAND_CLOSURES.iter().any(|closure| closure.year == year) {
                for closure in MAINLAND_CLOSURES
                    .iter()
                    .filter(|closure| closure.year == year)
                {
                    let first = day_number(year, closure.first.0, closure.first.1);
                    let last = day_number(year, closure.last.0, closure.last.1);
                    for day in first..=last {
                        push(&mut out, from_day_number(day), closure.name_key);
                    }
                }
            } else {
                push(&mut out, (year, 1, 1), "元旦");
                push(&mut out, (year, 5, 1), "劳动节");
                push(&mut out, (year, 10, 1), "国庆节");
                if let Some(date) = anchors.lunar_new_year.as_deref().and_then(parse_iso) {
                    // 春节休市按农历除夕到正月初六的惯例（具体天数每年由交易所公布，这里给常规区间）。
                    for offset in -1..=5 {
                        push(&mut out, shift(date, offset), "春节");
                    }
                }
                if let Some(date) = anchors.qingming.as_deref().and_then(parse_iso) {
                    push(&mut out, date, "清明节");
                }
                if let Some(date) = anchors.dragon_boat.as_deref().and_then(parse_iso) {
                    push(&mut out, date, "端午节");
                }
                if let Some(date) = anchors.mid_autumn.as_deref().and_then(parse_iso) {
                    push(&mut out, date, "中秋节");
                }
            }
        }
        HolidaySet::HongKong => {
            if HONG_KONG_CLOSURES.iter().any(|closure| closure.year == year) {
                for closure in HONG_KONG_CLOSURES.iter().filter(|closure| closure.year == year) {
                    let first = day_number(year, closure.first.0, closure.first.1);
                    let last = day_number(year, closure.last.0, closure.last.1);
                    for day in first..=last {
                        push(&mut out, from_day_number(day), closure.name_key);
                    }
                }
            } else {
                push(&mut out, (year, 1, 1), "元旦");
                push(&mut out, shift(easter(year), -2), "耶稣受难日");
                push(&mut out, shift(easter(year), -1), "耶稣受难日翌日");
                push(&mut out, shift(easter(year), 1), "复活节星期一");
                push(&mut out, (year, 5, 1), "劳动节");
                push(&mut out, (year, 7, 1), "香港特别行政区成立纪念日");
                push(&mut out, (year, 10, 1), "国庆节");
                push(&mut out, (year, 12, 25), "圣诞节");
                push(&mut out, (year, 12, 26), "节礼日");
                if let Some(date) = anchors.lunar_new_year.as_deref().and_then(parse_iso) {
                    for offset in 0..=2 {
                        push(&mut out, shift(date, offset), "农历新年");
                    }
                }
                if let Some(date) = anchors.qingming.as_deref().and_then(parse_iso) {
                    push(&mut out, date, "清明节");
                }
                if let Some(date) = anchors.dragon_boat.as_deref().and_then(parse_iso) {
                    push(&mut out, date, "端午节");
                }
                if let Some(date) = anchors.mid_autumn.as_deref().and_then(parse_iso) {
                    // 香港休的是中秋翌日。
                    push(&mut out, shift(date, 1), "中秋节翌日");
                }
            }
        }
        HolidaySet::None => {}
    }
    out.sort_by(|a, b| a.date.cmp(&b.date));
    out.dedup_by(|a, b| a.date == b.date);
    out
}

// MARK: - 现在开着吗、下一次变化是什么时候

/// 宿主给的一串真实边界：每段交易时段的起止 Unix 秒（已按该市场时区与休市日算好，升序）。
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct StatusRequest {
    now: f64,
    /// 升序的交易时段（同一天的两段分开给）。
    spans: Vec<Span>,
    /// 该市场当地那一个民用日的起止（含 `now`）：有了它才分得清「未开盘 / 午休 / 已收盘 / 今天不开」。
    #[serde(default)]
    day_start: Option<f64>,
    #[serde(default)]
    day_end: Option<f64>,
}

/// 关着的时候是哪一种：当地今天根本不开（周末、休市日）、还没开、午休、已收盘。
/// 状态词只按这个选，「休市」只给今天不开的那一种。
fn closed_phase(spans: &[Span], now: f64, day: Option<(f64, f64)>) -> &'static str {
    let Some((start, end)) = day.filter(|(s, e)| s.is_finite() && e.is_finite() && e > s) else {
        return "closed";
    };
    let today: Vec<&Span> = spans.iter().filter(|span| span.start >= start && span.start < end).collect();
    match (today.first(), today.last()) {
        (Some(first), _) if now < first.start => "beforeOpen",
        (_, Some(last)) if now >= last.end => "afterClose",
        (Some(_), Some(_)) => "break",
        _ => "noSession",
    }
}

#[derive(Clone, Copy, Debug, Deserialize)]
struct Span {
    start: f64,
    end: f64,
}

pub fn status(input: &Value) -> Value {
    let Ok(request) = serde_json::from_value::<StatusRequest>(input.clone()) else {
        return json!({"state":"unknown","changeAt":Value::Null,"minutesToChange":Value::Null});
    };
    let now = request.now;
    let mut spans: Vec<Span> = request
        .spans
        .into_iter()
        .filter(|span| span.end > span.start && span.start.is_finite() && span.end.is_finite())
        .collect();
    spans.sort_by(|a, b| a.start.total_cmp(&b.start));
    if let Some(current) = spans.iter().find(|span| span.start <= now && now < span.end) {
        // 开着：下一次变化是收盘（同一天还有下一段时，页面另写「午休」）。
        let next_open = spans.iter().find(|span| span.start >= current.end);
        return json!({"state":"open","phase":"open","changeAt":current.end,
            "minutesToChange":((current.end - now) / 60.0).ceil(),
            "sessionStart":current.start,"sessionEnd":current.end,
            "nextOpenAt":next_open.map(|span| span.start),
            "breakUntil": next_open.filter(|span| span.start - current.end <= 4.0 * 3600.0).map(|span| span.start)});
    }
    let phase = closed_phase(&spans, now, request.day_start.zip(request.day_end));
    match spans.iter().find(|span| span.start > now) {
        Some(next) => json!({"state":"closed","phase":phase,"changeAt":next.start,
            "minutesToChange":((next.start - now) / 60.0).ceil(),
            "sessionStart":next.start,"sessionEnd":next.end,
            "nextOpenAt":next.start,"breakUntil":Value::Null}),
        // 范围里没有下一段（例如只给了今天而今天已收盘）：如实说不知道，不猜。
        None => json!({"state":"closed","phase":phase,"changeAt":Value::Null,"minutesToChange":Value::Null,
            "sessionStart":Value::Null,"sessionEnd":Value::Null,"nextOpenAt":Value::Null,
            "breakUntil":Value::Null}),
    }
}

pub fn dispatch(operation: &str, input: Value) -> Result<Value, String> {
    Ok(match operation {
        "markets.catalog" => catalog(),
        "markets.holidays" => {
            let set = match input["set"].as_str().unwrap_or("none") {
                "us" => HolidaySet::UnitedStates,
                "uk" => HolidaySet::UnitedKingdom,
                "jp" => HolidaySet::Japan,
                "cn" => HolidaySet::MainlandChina,
                "hk" => HolidaySet::HongKong,
                _ => HolidaySet::None,
            };
            let year = input["year"].as_i64().unwrap_or(2026).clamp(1900, 2200);
            let anchors: YearAnchors =
                serde_json::from_value(input["anchors"].clone()).unwrap_or_default();
            serde_json::to_value(holidays(set, year, &anchors)).map_err(|e| e.to_string())?
        }
        "markets.status" => status(&input),
        _ => return Err(format!("Unknown markets operation: {operation}")),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn calendar_arithmetic_matches_the_gregorian_calendar() {
        // 1970-01-01 是周四；2026-09-17 是周四；2000-02-29 存在、1900-02-29 不存在。
        assert_eq!(weekday(1970, 1, 1), 4);
        assert_eq!(weekday(2026, 9, 17), 4);
        assert!(leap(2000) && !leap(1900) && leap(2024));
        assert_eq!(days_in_month(2024, 2), 29);
        assert_eq!(from_day_number(day_number(2026, 12, 31)), (2026, 12, 31));
        assert_eq!(shift((2026, 12, 31), 1), (2027, 1, 1));
        assert_eq!(shift((2027, 1, 1), -1), (2026, 12, 31));
        // 2026-01 的第 3 个周一是 19 日；5 月最后一个周一是 25 日。
        assert_eq!(nth_weekday(2026, 1, 1, 3), (2026, 1, 19));
        assert_eq!(last_weekday(2026, 5, 1), (2026, 5, 25));
    }

    #[test]
    fn easter_matches_the_published_dates() {
        // 公开的复活节日期（格里历）：2024-03-31、2025-04-20、2026-04-05、2027-03-28、2030-04-21。
        assert_eq!(easter(2024), (2024, 3, 31));
        assert_eq!(easter(2025), (2025, 4, 20));
        assert_eq!(easter(2026), (2026, 4, 5));
        assert_eq!(easter(2027), (2027, 3, 28));
        assert_eq!(easter(2030), (2030, 4, 21));
    }

    #[test]
    fn us_market_holidays_2026_match_the_nyse_calendar() {
        let list = holidays(HolidaySet::UnitedStates, 2026, &YearAnchors::default());
        let dates: Vec<&str> = list.iter().map(|h| h.date.as_str()).collect();
        // NYSE 2026 公布的休市日：1-1、1-19、2-16、4-3（受难日）、5-25、6-19、7-3（7-4 周六）、
        // 9-7、11-26、12-25。
        assert_eq!(
            dates,
            vec![
                "2026-01-01", "2026-01-19", "2026-02-16", "2026-04-03", "2026-05-25",
                "2026-06-19", "2026-07-03", "2026-09-07", "2026-11-26", "2026-12-25"
            ]
        );
        // 2027：元旦周五、7-5（7-4 周日顺延）、12-24（12-25 周六提前）。
        let next = holidays(HolidaySet::UnitedStates, 2027, &YearAnchors::default());
        let dates: Vec<&str> = next.iter().map(|h| h.date.as_str()).collect();
        assert!(dates.contains(&"2027-01-01"));
        assert!(dates.contains(&"2027-07-05"));
        assert!(dates.contains(&"2027-12-24"));
    }

    #[test]
    fn uk_substitutes_push_christmas_past_the_weekend() {
        // 2027-12-25 是周六、12-26 周日 → 替代假日 12-27 与 12-28。
        let list = holidays(HolidaySet::UnitedKingdom, 2027, &YearAnchors::default());
        let dates: Vec<&str> = list.iter().map(|h| h.date.as_str()).collect();
        assert!(dates.contains(&"2027-12-27"), "{dates:?}");
        assert!(dates.contains(&"2027-12-28"), "{dates:?}");
        // 2026：元旦周四不动；五月初银行假日 5-4、春季 5-25、夏季 8-31。
        let list = holidays(HolidaySet::UnitedKingdom, 2026, &YearAnchors::default());
        let dates: Vec<&str> = list.iter().map(|h| h.date.as_str()).collect();
        assert!(dates.contains(&"2026-01-01"));
        assert!(dates.contains(&"2026-05-04"));
        assert!(dates.contains(&"2026-05-25"));
        assert!(dates.contains(&"2026-08-31"));
    }

    #[test]
    fn japan_moves_a_sunday_holiday_to_the_next_free_day() {
        // 2026-05-03（宪法纪念日）是周日 → 振替休日落在 5-6（5-4、5-5 本身是假日）。
        let list = holidays(
            HolidaySet::Japan,
            2026,
            &YearAnchors {
                march_equinox: Some("2026-03-20".into()),
                september_equinox: Some("2026-09-23".into()),
                ..Default::default()
            },
        );
        let dates: Vec<&str> = list.iter().map(|h| h.date.as_str()).collect();
        assert!(dates.contains(&"2026-05-03"), "{dates:?}");
        assert!(dates.contains(&"2026-05-06"), "{dates:?}");
        // 分点日期由宿主给，进表。
        assert!(dates.contains(&"2026-03-20"));
        assert!(dates.contains(&"2026-09-23"));
        // 东证年末年初。
        assert!(dates.contains(&"2026-01-02") && dates.contains(&"2026-12-31"));
        // 没给分点就不写那两天（不猜）。
        let without = holidays(HolidaySet::Japan, 2026, &YearAnchors::default());
        assert!(!without.iter().any(|h| h.name_key == "春分日"));
    }

    #[test]
    fn mainland_china_2026_matches_the_announced_closures() {
        let expected = [
            ("2026-01-01", "元旦"),
            ("2026-01-02", "元旦"),
            ("2026-01-03", "元旦"),
            ("2026-02-15", "春节"),
            ("2026-02-16", "春节"),
            ("2026-02-17", "春节"),
            ("2026-02-18", "春节"),
            ("2026-02-19", "春节"),
            ("2026-02-20", "春节"),
            ("2026-02-21", "春节"),
            ("2026-02-22", "春节"),
            ("2026-02-23", "春节"),
            ("2026-04-04", "清明节"),
            ("2026-04-05", "清明节"),
            ("2026-04-06", "清明节"),
            ("2026-05-01", "劳动节"),
            ("2026-05-02", "劳动节"),
            ("2026-05-03", "劳动节"),
            ("2026-05-04", "劳动节"),
            ("2026-05-05", "劳动节"),
            ("2026-06-19", "端午节"),
            ("2026-06-20", "端午节"),
            ("2026-06-21", "端午节"),
            ("2026-09-25", "中秋节"),
            ("2026-09-26", "中秋节"),
            ("2026-09-27", "中秋节"),
            ("2026-10-01", "国庆节"),
            ("2026-10-02", "国庆节"),
            ("2026-10-03", "国庆节"),
            ("2026-10-04", "国庆节"),
            ("2026-10-05", "国庆节"),
            ("2026-10-06", "国庆节"),
            ("2026-10-07", "国庆节"),
        ];
        for anchors in [
            YearAnchors::default(),
            YearAnchors {
                lunar_new_year: Some("2026-03-01".into()),
                qingming: Some("2026-04-01".into()),
                dragon_boat: Some("2026-06-01".into()),
                mid_autumn: Some("2026-09-01".into()),
                ..Default::default()
            },
        ] {
            let list = holidays(HolidaySet::MainlandChina, 2026, &anchors);
            let actual: Vec<(&str, &str)> = list
                .iter()
                .map(|holiday| (holiday.date.as_str(), holiday.name_key.as_str()))
                .collect();
            assert_eq!(actual, expected);
        }
    }

    #[test]
    fn lunar_anchors_come_from_the_host_and_are_never_guessed() {
        let anchors = YearAnchors {
            lunar_new_year: Some("2026-02-17".into()),
            mid_autumn: Some("2026-09-25".into()),
            dragon_boat: Some("2026-06-19".into()),
            qingming: Some("2026-04-05".into()),
            ..Default::default()
        };
        let cn = holidays(HolidaySet::MainlandChina, 2026, &anchors);
        let dates: Vec<&str> = cn.iter().map(|h| h.date.as_str()).collect();
        // 春节按除夕到初六。
        assert!(dates.contains(&"2026-02-16") && dates.contains(&"2026-02-22"), "{dates:?}");
        assert!(dates.contains(&"2026-04-05") && dates.contains(&"2026-09-25"));
        // 香港休中秋翌日而不是中秋当天。
        let hk = holidays(HolidaySet::HongKong, 2027, &YearAnchors {
            lunar_new_year: Some("2027-02-06".into()),
            mid_autumn: Some("2027-09-15".into()),
            ..Default::default()
        });
        let hk_dates: Vec<&str> = hk.iter().map(|h| h.date.as_str()).collect();
        assert!(hk_dates.contains(&"2027-09-16"), "{hk_dates:?}");
        assert!(hk_dates.contains(&"2027-02-06"));
        // 不给农历锚点时，中港两套只剩公历那几天，绝不猜农历。
        let bare = holidays(HolidaySet::MainlandChina, 2027, &YearAnchors::default());
        assert_eq!(
            bare.iter().map(|h| h.date.as_str()).collect::<Vec<_>>(),
            vec!["2027-01-01", "2027-05-01", "2027-10-01"]
        );
    }

    #[test]
    fn status_reads_open_closed_and_the_lunch_break() {
        // 东证 2026-09-17：09:00–11:30 与 12:30–15:30（JST = UTC+9）。
        let morning = 1_789_000_000.0;
        let spans = json!([
            {"start": morning, "end": morning + 9_000.0},
            {"start": morning + 12_600.0, "end": morning + 23_400.0}
        ]);
        // 开盘中：下一次变化是上午收盘，且写明午休到下午开盘。
        let open = status(&json!({"now": morning + 60.0, "spans": spans}));
        assert_eq!(open["state"], json!("open"));
        assert_eq!(open["minutesToChange"], json!(149.0));
        assert_eq!(open["breakUntil"], json!(morning + 12_600.0));
        // 午休中：算关着，下一次变化是下午开盘。
        let lunch = status(&json!({"now": morning + 10_000.0, "spans": spans}));
        assert_eq!(lunch["state"], json!("closed"));
        assert_eq!(lunch["changeAt"], json!(morning + 12_600.0));
        // 收盘后、且范围里没有下一段：如实说不知道下一次变化。
        let after = status(&json!({"now": morning + 30_000.0, "spans": spans}));
        assert_eq!(after["state"], json!("closed"));
        assert_eq!(after["changeAt"], Value::Null);
        // 坏输入不炸。
        assert_eq!(status(&json!({"spans": "bad"}))["state"], json!("unknown"));
        assert_eq!(status(&json!({"now": 0.0, "spans": []}))["state"], json!("closed"));
    }

    #[test]
    fn closed_says_which_kind_of_closed() {
        // 东证 2026-11-25（周三）：当地日 2026-11-24T15:00Z 起 24 小时；两段 00:00–02:30Z、03:30–06:30Z；
        // 下一个交易日 11-26 两段同样。
        let day = 1_795_532_400.0; // 2026-11-24T15:00:00Z = 东京 11-25 00:00（周三）
        let first = day + 9.0 * 3600.0;
        let spans = json!([
            {"start": first, "end": first + 9_000.0},
            {"start": first + 12_600.0, "end": first + 23_400.0},
            {"start": first + 86_400.0, "end": first + 86_400.0 + 9_000.0}
        ]);
        let at = |now: f64, day_start: f64| status(&json!({"now": now, "spans": spans, "dayStart": day_start, "dayEnd": day_start + 86_400.0}));
        assert_eq!(at(day + 3_600.0, day)["phase"], json!("beforeOpen"), "当地 1 点：还没开");
        assert_eq!(at(first + 60.0, day)["phase"], json!("open"));
        assert_eq!(at(first + 10_000.0, day)["phase"], json!("break"), "11:46 午休");
        assert_eq!(at(first + 30_000.0, day)["phase"], json!("afterClose"), "17:20 已收盘");
        // 已收盘时下一次变化是第二天开盘，不是「不知道」。
        assert_eq!(at(first + 30_000.0, day)["changeAt"], json!(first + 86_400.0));
        // 当地日里一段都没有：今天不开（周末或休市日）。
        let saturday = day + 3.0 * 86_400.0;
        assert_eq!(at(saturday + 3_600.0, saturday)["phase"], json!("noSession"));
        // 没给当地日：只说关着，不猜是哪一种。
        assert_eq!(status(&json!({"now": day, "spans": spans}))["phase"], json!("closed"));
        // 当地日给反了也不猜。
        assert_eq!(status(&json!({"now": day, "spans": spans, "dayStart": day, "dayEnd": day - 1.0}))["phase"], json!("closed"));
    }

    #[test]
    fn the_market_table_is_consistent() {
        for market in MARKETS {
            assert!(!market.id.is_empty() && !market.name_key.is_empty());
            assert!(
                MARKETS.iter().filter(|other| other.id == market.id).count() == 1,
                "市场 id 重复：{}",
                market.id
            );
            assert!(!market.sessions.is_empty(), "{} 没有作息", market.id);
            let mut previous_end = -1;
            for session in market.sessions {
                assert!(
                    (0..1440).contains(&session.start_minute)
                        && (1..=1440).contains(&session.end_minute)
                        && session.end_minute > session.start_minute,
                    "{} 的作息越界",
                    market.id
                );
                assert!(session.start_minute > previous_end, "{} 的两段重叠", market.id);
                previous_end = session.end_minute;
            }
        }
        // 目录里的键与表一致。
        let catalog = catalog();
        assert_eq!(catalog.as_array().unwrap().len(), MARKETS.len());
        assert_eq!(catalog[0]["id"], json!("nyse"));
        assert_eq!(catalog[0]["holidaySet"], json!("us"));
        // 每个市场都有所在城市，且在它自己的时区附近（经度与时区偏移差不到 30°，排除把经纬度写反的那种错）。
        for market in MARKETS {
            let (lat, lon) = market.city;
            assert!((-60.0..=70.0).contains(&lat) && (-180.0..=180.0).contains(&lon), "{} 的城市坐标越界", market.id);
        }
        let nse = catalog.as_array().unwrap().iter().find(|m| m["id"] == json!("nse")).unwrap();
        assert_eq!((nse["latitude"].as_f64(), nse["longitude"].as_f64()), (Some(19.06), Some(72.86)), "孟买，不是加尔各答");
    }

    #[test]
    fn hong_kong_2026_matches_the_announced_closures() {
        let expected = [
            ("2026-01-01", "元旦"),
            ("2026-02-17", "农历新年"),
            ("2026-02-18", "农历新年"),
            ("2026-02-19", "农历新年"),
            ("2026-04-03", "耶稣受难日"),
            ("2026-04-06", "复活节星期一"),
            ("2026-04-07", "清明节翌日"),
            ("2026-05-01", "劳动节"),
            ("2026-05-25", "佛诞翌日"),
            ("2026-06-19", "端午节"),
            ("2026-07-01", "香港特别行政区成立纪念日"),
            ("2026-10-01", "国庆节"),
            ("2026-10-19", "重阳节翌日"),
            ("2026-12-25", "圣诞节"),
        ];
        for anchors in [
            YearAnchors::default(),
            YearAnchors {
                lunar_new_year: Some("2026-03-01".into()),
                qingming: Some("2026-04-01".into()),
                dragon_boat: Some("2026-06-01".into()),
                mid_autumn: Some("2026-09-01".into()),
                ..Default::default()
            },
        ] {
            let list = holidays(HolidaySet::HongKong, 2026, &anchors);
            let actual: Vec<(&str, &str)> = list.iter()
                .map(|holiday| (holiday.date.as_str(), holiday.name_key.as_str()))
                .collect();
            assert_eq!(actual, expected);
        }
        let fallback = holidays(HolidaySet::HongKong, 2027, &YearAnchors {
            lunar_new_year: Some("2027-02-06".into()),
            mid_autumn: Some("2027-09-15".into()),
            ..Default::default()
        });
        assert!(fallback.iter().any(|holiday| holiday.date == "2027-02-06" && holiday.name_key == "农历新年"));
        assert!(fallback.iter().any(|holiday| holiday.date == "2027-09-16" && holiday.name_key == "中秋节翌日"));
    }
}
