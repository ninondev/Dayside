// SPDX-License-Identifier: GPL-3.0-only
//! 渲染引擎：把 `Spec` 的各个片段按语言数据拼成句子。
//! 模板是一串片段（`Seg`）；任一片段无法表达该规格时整个模板返回 `None`。

use super::data::{lang, Lang, Seg};
use super::{Clock, DateSpec, Spec, Zone};

/// 语言数量已知，`template_count` 返回该语言的模板数；未知语言为 0。
pub fn template_count(lang: &str) -> usize {
    lang_data(lang).map(|l| l.templates.len()).unwrap_or(0)
}

/// 按模板编号渲染；语言或编号未知、或模板无法表达该规格时返回 `None`。
pub fn render(spec: &Spec, lang: &str, template: usize) -> Option<String> {
    let l = lang_data(lang)?;
    let segs = *l.templates.get(template)?;
    let mut out = String::new();
    for seg in segs {
        out.push_str(seg_str(spec, l, seg)?.as_str());
    }
    Some(out)
}

// 语言查找（包内包装，便于复用）。
fn lang_data(code: &str) -> Option<&'static Lang> {
    lang(code)
}

// 单个片段的文本；无法表达时为 `None`。
fn seg_str(spec: &Spec, l: &Lang, seg: &Seg) -> Option<String> {
    match seg {
        Seg::Lit(t) => Some((*t).to_string()),
        Seg::Date => date_str(spec.date?, l),
        Seg::DateIso => match spec.date? {
            DateSpec::Absolute { year, month, day } => {
                Some(format!("{year:04}-{month:02}-{day:02}"))
            }
            _ => None, // ISO 数字形式仅用于完整日期，避免月日顺序歧义
        },
        Seg::Time24 => Some(time24(&spec.time, l)),
        Seg::Time12 => time12(&spec.time, l),
        Seg::RangeDash => {
            let e = spec.end?;
            let body = format!(
                "{}{}{}",
                clock_hm(&spec.time),
                l.dash,
                clock_hm(&e)
            );
            Some(fill(l.t24_pat, &[("", &body)]))
        }
        Seg::RangeFT => {
            let e = spec.end?;
            let a = time24(&spec.time, l);
            let b = time24(&e, l);
            Some(fill(l.from_to_pat, &[("a", &a), ("b", &b)]))
        }
        Seg::CityIn => city(spec.zone?, l, l.city_in_pat),
        Seg::CityTime => city(spec.zone?, l, l.city_time_pat),
        Seg::Utc => match spec.zone? {
            Zone::Offset(mins) => {
                let sign = if mins < 0 { "-" } else { "+" };
                let abs = mins.unsigned_abs();
                let mut body = format!("{sign}{}", abs / 60);
                if abs % 60 > 0 {
                    body.push_str(&format!(":{:02}", abs % 60));
                }
                Some(fill(l.utc_pat, &[("", &body)]))
            }
            _ => None,
        },
        Seg::Wd => match spec.date? {
            DateSpec::Weekday { .. } => Some(weekday(spec.date?, l, true)),
            _ => None, // 本模板只写星期名
        },
        Seg::WdPlain => match spec.date? {
            DateSpec::Weekday { next: false, .. } => Some(weekday(spec.date?, l, false)),
            _ => None, // 本模板只写不带“下一”词的星期名
        },
    }
}

// 日期表达：月名句式、日词或星期名。
fn date_str(d: DateSpec, l: &Lang) -> Option<String> {
    match d {
        DateSpec::Absolute { year, month, day } => Some(date_fill(l.date_abs_pat, year, month, day, l)),
        DateSpec::MonthDay { month, day } => Some(date_fill(l.date_md_pat, 0, month, day, l)),
        DateSpec::Offset { days } => Some(match days {
            0 => l.today.to_string(),
            1 => l.tomorrow.to_string(),
            2 => l.after_tomorrow.to_string(),
            -1 => l.yesterday.to_string(),
            n if n > 0 => fill(l.in_days_pat, &[("n", &n.to_string())]),
            n => fill(l.ago_days_pat, &[("n", &(-n as i16).to_string())]),
        }),
        DateSpec::Weekday { next, .. } => Some(weekday(d, l, next)),
    }
}

// 星期表达；with_next 为真且规格带 next 时附上该语言的“下一…”说法。
fn weekday(d: DateSpec, l: &Lang, with_next: bool) -> String {
    match d {
        DateSpec::Weekday { weekday, next } => {
            let idx = (weekday.clamp(1, 7) - 1) as usize;
            let name = l.weekdays[idx];
            if next && with_next {
                fill(l.next_pat, &[("", name)])
            } else {
                name.to_string()
            }
        }
        _ => String::new(),
    }
}

// 24 小时制时刻，套用该语言的后缀句式（如德语 “9:00 Uhr”）。
fn time24(c: &Clock, l: &Lang) -> String {
    fill(l.t24_pat, &[("", &clock_hm(c))])
}

// “时:分”，时不补零、分补两位。
fn clock_hm(c: &Clock) -> String {
    format!("{}:{:02}", c.hour, c.minute)
}

// 12 小时制时刻；时段词按 24 小时制小时从表中选取，
// 无对应词（0 点与 12 点）时返回 `None`。
fn time12(c: &Clock, l: &Lang) -> Option<String> {
    let p = period_word(c.hour, l)?;
    let h = c.hour % 12; // 有词的小时必然落在 1..=11 或 13..=23，取模后为 1..=11
    Some(fill(
        l.t12_pat,
        &[("h", &h.to_string()), ("m", &format!("{:02}", c.minute)), ("p", p)],
    ))
}

// 该 24 小时制小时的时段词；不在任何区间（0 点、12 点）时为 `None`。
fn period_word(hour: u8, l: &Lang) -> Option<&'static str> {
    l.periods
        .iter()
        .find(|(from, to, _)| hour >= *from && hour <= *to)
        .map(|(_, _, word)| *word)
}

// 城市短语（“在东京” / “东京时间”）；仅城市时区可用。
fn city(z: Zone, l: &Lang, pat: &str) -> Option<String> {
    match z {
        Zone::City(key) => {
            let idx = super::data::CITY_KEYS.iter().position(|k| *k == key)?;
            Some(fill(pat, &[("", l.cities[idx])]))
        }
        _ => None,
    }
}

// 日期句式填充：Y 年、N 月名、n 月数字、M 两位月、d 日数字、D 两位日。
fn date_fill(pat: &str, year: i32, month: u8, day: u8, l: &Lang) -> String {
    let name = l.months[(month.clamp(1, 12) - 1) as usize];
    fill(
        pat,
        &[
            ("Y", &year.to_string()),
            ("N", name),
            ("n", &month.to_string()),
            ("M", &format!("{month:02}")),
            ("d", &day.to_string()),
            ("D", &format!("{day:02}")),
        ],
    )
}

// 通用占位符填充：把 {name} 换成对应文本。
fn fill(pat: &str, subs: &[(&str, &str)]) -> String {
    let mut out = String::with_capacity(pat.len() + 16);
    let mut rest = pat;
    while let Some(open) = rest.find('{') {
        out.push_str(&rest[..open]);
        let close = open + rest[open..].find('}').expect("模板占位符缺少右括号");
        let name = &rest[open + 1..close];
        let val = subs
            .iter()
            .find(|(k, _)| *k == name)
            .unwrap_or_else(|| panic!("未知占位符 {{{name}}}"))
            .1;
        out.push_str(val);
        rest = &rest[close + 1..];
    }
    out.push_str(rest);
    out
}
