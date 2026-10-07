// SPDX-License-Identifier: GPL-3.0-only
//! 反向生成器（第二套算法）：随机的时间说明按十六种界面语言的模板写成句子，同时给出标准答案
//!（`tests.rs::summary` 的记法），引擎读回来比。词表与模板是它自己的，不用引擎的 `lexicon`。只在测试里编译。
//! 时段词按钟点挑；`acceptance.rs` 独立检查生成的句子与标准答案。

mod data;
mod gen;
mod render;
mod rng;

#[cfg(test)]
mod tests;
#[cfg(test)]
mod acceptance;

pub use data::LANGUAGES;

/// 日期规格：绝对日期、月日、相对天数或星期几（ISO 星期，1 = 周一）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DateSpec {
    Absolute { year: i32, month: u8, day: u8 },
    MonthDay { month: u8, day: u8 },
    Offset { days: i8 },
    Weekday { weekday: u8, next: bool },
}

/// 时刻，24 小时制的时与分。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Clock {
    pub hour: u8,
    pub minute: u8,
}

/// 时区：按城市键（八个允许的城市之一）或相对 UTC 的分钟偏移（东为正）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Zone {
    City(&'static str),
    Offset(i16),
}

/// 一条时间表达的全部语义。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Spec {
    pub date: Option<DateSpec>,
    pub time: Clock,
    pub end: Option<Clock>,
    pub zone: Option<Zone>,
}

/// 一条生成样例：语言、句子、期望摘要。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Case {
    pub lang: &'static str,
    pub text: String,
    pub want: String,
}

/// 城市键到 IANA 时区 id 的映射（仅允许的八个城市）。
fn iana(key: &str) -> &'static str {
    match key {
        "tokyo" => "Asia/Tokyo",
        "london" => "Europe/London",
        "new york" => "America/New_York",
        "paris" => "Europe/Paris",
        "berlin" => "Europe/Berlin",
        "sydney" => "Australia/Sydney",
        "singapore" => "Asia/Singapore",
        "los angeles" => "America/Los_Angeles",
        _ => "-",
    }
}

/// 期望摘要的固定格式：`{date} {time} {zone} > -`。
pub fn expected(spec: &Spec) -> String {
    let date = match spec.date {
        None => "-".to_string(),
        Some(DateSpec::Absolute { year, month, day }) => {
            format!("{year:04}-{month:02}-{day:02}")
        }
        Some(DateSpec::MonthDay { month, day }) => format!("{month:02}-{day:02}"),
        Some(DateSpec::Offset { days }) => format!("{days:+}d"),
        Some(DateSpec::Weekday { weekday, next }) => {
            if next {
                format!("w{weekday}:next")
            } else {
                format!("w{weekday}")
            }
        }
    };
    let time = match spec.end {
        None => format!("{:02}:{:02}", spec.time.hour, spec.time.minute),
        Some(e) => format!(
            "{:02}:{:02}\u{2013}{:02}:{:02}",
            spec.time.hour, spec.time.minute, e.hour, e.minute
        ),
    };
    let zone = match spec.zone {
        None => "-".to_string(),
        Some(Zone::City(key)) => iana(key).to_string(),
        Some(Zone::Offset(mins)) => format!("{mins:+}"),
    };
    format!("{date} {time} {zone} > -")
}

/// 把样例序列化成 JSON Lines：每行一个对象，行尾换行；无样例时为空串。
pub fn to_jsonl(cases: &[Case]) -> String {
    let mut out = String::new();
    for c in cases {
        out.push_str("{\"lang\":\"");
        escape_into(c.lang, &mut out);
        out.push_str("\",\"text\":\"");
        escape_into(&c.text, &mut out);
        out.push_str("\",\"want\":\"");
        escape_into(&c.want, &mut out);
        out.push_str("\"}\n");
    }
    out
}

/// 按 JSON 规则转义：引号、反斜杠、控制字符以及 U+2028/U+2029，
/// 其余非 ASCII 字符保持原样。
fn escape_into(s: &str, out: &mut String) {
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\u{8}' => out.push_str("\\b"),
            '\u{c}' => out.push_str("\\f"),
            '\u{2028}' | '\u{2029}' => out.push_str(&format!("\\u{:04x}", c as u32)),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
}

pub use gen::cases;
pub use render::{render, template_count};
