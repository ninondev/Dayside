// SPDX-License-Identifier: GPL-3.0-only
//! 作息与可约区间。
//!
//! 这里只有「一个人的工作时段在真实日历上落成哪些区间」这一层规则：作息的归一化与派生
//! （跨午夜、全天、时长）、休假与周末、把墙钟分钟按当天的偏移段投影成绝对时间、合并重叠。
//! 日历 / 时区 / 地区周末这些**事实**由宿主（Foundation + ICU）一次算好传进来。
//!
//! 独立的基础区间规则供面板「现在能打给谁」排序、
//! 分享页的可约时段、地点的可约性判断共用；多人重叠搜索、例会轮换与拆场在 `planner.rs`。
//! `planner.rs` 复用这里的类型与函数，本模块不依赖规划器。
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Clone, Copy, Deserialize, Serialize, Debug)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Availability {
    pub(crate) start_minute: i64,
    pub(crate) end_minute: i64,
    #[serde(default)]
    pub(crate) weekdays_only: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct AvailabilityRules {
    pub(crate) start_minute: i64,
    pub(crate) end_minute: i64,
    pub(crate) crosses_midnight: bool,
    pub(crate) is_whole_day: bool,
    pub(crate) length_minutes: i64,
}

impl Availability {
    pub(crate) fn normalized(self) -> Self {
        Self {
            start_minute: self.start_minute.clamp(0, 1439),
            end_minute: self.end_minute.clamp(0, 1440),
            ..self
        }
    }

    pub(crate) fn rules(self) -> AvailabilityRules {
        let a = self.normalized();
        let is_whole_day = a.end_minute == a.start_minute || a.end_minute - a.start_minute == 1440;
        let crosses_midnight = a.end_minute <= a.start_minute && !is_whole_day;
        let length_minutes = if is_whole_day {
            1440
        } else if crosses_midnight {
            a.end_minute + 1440 - a.start_minute
        } else {
            a.end_minute - a.start_minute
        };
        AvailabilityRules {
            start_minute: a.start_minute,
            end_minute: a.end_minute,
            crosses_midnight,
            is_whole_day,
            length_minutes,
        }
    }
}

/// Persistence defaults and per-field recovery live with the rules, not in a Swift decoder.
pub(crate) fn normalize_availability(value: &Value) -> Availability {
    Availability {
        start_minute: value
            .get("startMinute")
            .and_then(Value::as_i64)
            .unwrap_or(540),
        end_minute: value
            .get("endMinute")
            .and_then(Value::as_i64)
            .unwrap_or(1080),
        weekdays_only: value
            .get("weekdaysOnly")
            .and_then(Value::as_bool)
            .unwrap_or(true),
    }
    .normalized()
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq)]
pub(crate) struct Interval {
    pub(crate) start: f64,
    pub(crate) end: f64,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct OffsetSegment {
    pub(crate) start: f64,
    pub(crate) end: f64,
    pub(crate) offset_seconds: i64,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Day {
    /// 这两个字段供排会规划器 `planner.rs` 使用，其他区间调用可以忽略。
    #[allow(dead_code)]
    pub(crate) start: f64,
    #[allow(dead_code)]
    pub(crate) end: f64,
    /// Unix seconds for this civil date interpreted as a UTC midnight.
    pub(crate) wall_day: f64,
    pub(crate) weekend: bool,
    #[serde(default)]
    pub(crate) weekday: u32,
    #[serde(default)]
    pub(crate) date: String,
    pub(crate) segments: Vec<OffsetSegment>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct CalendarFacts {
    pub(crate) days: Vec<Day>,
    pub(crate) anchor_count: usize,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Vacation {
    pub(crate) start_date: String,
    pub(crate) end_date: String,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Schedule {
    pub(crate) availability: Availability,
    #[serde(default)]
    pub(crate) working_weekdays: Option<Vec<u32>>,
    #[serde(default)]
    pub(crate) vacations: Vec<Vacation>,
    pub(crate) calendar: CalendarFacts,
}

pub(crate) fn holiday(schedule: &Schedule, day: &Day) -> bool {
    !day.date.is_empty() && schedule.vacations.iter().any(|range| {
        range.start_date <= day.date && day.date <= range.end_date
    })
}

pub(crate) fn can_start_shift(schedule: &Schedule, day: &Day) -> bool {
    !holiday(schedule, day) && match &schedule.working_weekdays {
        Some(days) => days.contains(&day.weekday),
        None => !schedule.availability.weekdays_only || !day.weekend,
    }
}

pub(crate) fn blocked_day(schedule: &Schedule, day: &Day) -> bool {
    holiday(schedule, day) || (schedule.working_weekdays.is_none()
        && schedule.availability.weekdays_only && day.weekend)
}

pub(crate) fn project(day: &Day, start_minute: i64, end_minute: i64, output: &mut Vec<Interval>) {
    if end_minute <= start_minute {
        return;
    }
    for segment in &day.segments {
        let start = segment
            .start
            .max(day.wall_day + (start_minute * 60 - segment.offset_seconds) as f64);
        let end = segment
            .end
            .min(day.wall_day + (end_minute * 60 - segment.offset_seconds) as f64);
        if start < end {
            output.push(Interval { start, end });
        }
    }
}

pub(crate) fn intervals(schedule: &Schedule) -> Vec<Interval> {
    let a = schedule.availability.normalized();
    let rules = a.rules();
    let mut output = Vec::new();
    for (index, day) in schedule
        .calendar
        .days
        .iter()
        .take(schedule.calendar.anchor_count)
        .enumerate()
    {
        if !can_start_shift(schedule, day) {
            continue;
        }
        if rules.is_whole_day {
            project(day, 0, 1440, &mut output);
        } else if rules.crosses_midnight {
            project(day, a.start_minute, 1440, &mut output);
            if let Some(next) = schedule.calendar.days.get(index + 1) {
                if !blocked_day(schedule, next) {
                    project(next, 0, a.end_minute, &mut output);
                }
            }
        } else {
            project(day, a.start_minute, a.end_minute, &mut output);
        }
    }
    output.sort_by(|a, b| a.start.total_cmp(&b.start));
    let mut merged: Vec<Interval> = Vec::new();
    for interval in output {
        if let Some(last) = merged.last_mut() {
            if interval.start <= last.end {
                last.end = last.end.max(interval.end);
                continue;
            }
        }
        merged.push(interval);
    }
    merged
}

/// 面板「现在能打给谁」排序。
///
/// 每个地点的两个数字由宿主用 Foundation 在该时区里算准（跨夏令时与周末都按真实日期），
/// 这里只定规则：**现在能打的排前面，按还剩多久从少到多**（快下班的先打），其余按**还要多久才能打**
/// 从少到多；两个数字都没有的（时区坏了）留在最后、保持原顺序。同键保持用户的手动顺序（稳定排序）。
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct CallableEntry {
    pub(crate) id: String,
    /// 现在在时段内：还剩多少分钟。不在时段内就是 null。
    #[serde(default)]
    pub(crate) minutes_left: Option<i64>,
    /// 现在不在时段内：还有多少分钟进入下一段。已在时段内就是 null。
    #[serde(default)]
    pub(crate) minutes_until: Option<i64>,
}

pub fn callable_order(input: &Value) -> Value {
    let entries: Vec<CallableEntry> = input["entries"]
        .as_array()
        .map(|list| {
            list.iter()
                .filter_map(|value| serde_json::from_value(value.clone()).ok())
                .collect()
        })
        .unwrap_or_default();
    // 三档：0 = 现在能打（键 = 还剩多久），1 = 还不能打（键 = 还要多久），2 = 不知道（键 = 原位次）。
    let mut ranked: Vec<(u8, i64, usize, &str)> = entries
        .iter()
        .enumerate()
        .map(|(index, entry)| match (entry.minutes_left, entry.minutes_until) {
            (Some(left), _) => (0, left, index, entry.id.as_str()),
            (None, Some(until)) => (1, until, index, entry.id.as_str()),
            (None, None) => (2, index as i64, index, entry.id.as_str()),
        })
        .collect();
    ranked.sort_by_key(|(tier, key, index, _)| (*tier, *key, *index));
    // 提示行「下一个能打的是谁」：只在确实有人还不能打时给，且给的是最快进入时段的那一个。
    let next = ranked
        .iter()
        .find(|(tier, ..)| *tier == 1)
        .map(|(_, key, _, id)| (*id, *key));
    serde_json::json!({
        "order": ranked.iter().map(|(.., id)| *id).collect::<Vec<_>>(),
        "callableCount": ranked.iter().filter(|(tier, ..)| *tier == 0).count(),
        "nextID": next.map(|(id, _)| id),
        "nextInMinutes": next.map(|(_, minutes)| minutes),
    })
}

pub fn dispatch(operation: &str, payload: Value) -> Result<Value, String> {
    match operation {
        "availability.normalize" => {
            serde_json::to_value(normalize_availability(&payload)).map_err(|e| e.to_string())
        }
        "availability.decode" => {
            if payload.is_object() {
                serde_json::to_value(normalize_availability(&payload)).map_err(|e| e.to_string())
            } else {
                Ok(Value::Null)
            }
        }
        "availability.rules" => {
            let input: Availability = serde_json::from_value(payload).map_err(|e| e.to_string())?;
            serde_json::to_value(input.rules()).map_err(|e| e.to_string())
        }
        "availability.intervals" => {
            let input: Schedule = serde_json::from_value(payload).map_err(|e| e.to_string())?;
            serde_json::to_value(intervals(&input)).map_err(|e| e.to_string())
        }
        "availability.callable_order" => Ok(callable_order(&payload)),
        _ => Err(format!("Unknown availability operation: {operation}")),
    }
}

#[cfg(test)]
mod callable_tests {
    use super::*;
    use serde_json::json;

    fn order(entries: Value) -> Value {
        callable_order(&json!({"entries": entries}))
    }

    #[test]
    fn callable_places_come_first_and_the_one_closing_soonest_leads() {
        // 东京还剩 30 分钟下班、伦敦还剩 7 小时、纽约还要 4 小时才上班、雷克雅未克 2 小时。
        let result = order(json!([
            {"id":"london","minutesLeft":420},
            {"id":"new-york","minutesUntil":240},
            {"id":"tokyo","minutesLeft":30},
            {"id":"reykjavik","minutesUntil":120},
        ]));
        assert_eq!(result["order"], json!(["tokyo", "london", "reykjavik", "new-york"]));
        assert_eq!(result["callableCount"], json!(2));
        assert_eq!(result["nextID"], json!("reykjavik"));
        assert_eq!(result["nextInMinutes"], json!(120));
    }

    #[test]
    fn ties_keep_the_users_own_order_and_unknowns_stay_last() {
        let result = order(json!([
            {"id":"a","minutesLeft":60},
            {"id":"broken"},
            {"id":"b","minutesLeft":60},
            {"id":"c","minutesUntil":10},
            {"id":"also-broken"},
        ]));
        assert_eq!(result["order"], json!(["a", "b", "c", "broken", "also-broken"]));
        assert_eq!(result["nextID"], json!("c"));
    }

    #[test]
    fn with_everyone_callable_there_is_no_next_hint() {
        let result = order(json!([{"id":"a","minutesLeft":10},{"id":"b","minutesLeft":20}]));
        assert_eq!(result["nextID"], Value::Null);
        assert_eq!(result["nextInMinutes"], Value::Null);
        assert_eq!(result["callableCount"], json!(2));
        // 空表不炸，也不给提示。
        let empty = order(json!([]));
        assert_eq!(empty["order"], json!([]));
        assert_eq!(empty["callableCount"], json!(0));
        assert_eq!(empty["nextID"], Value::Null);
    }

    #[test]
    fn a_place_already_in_its_window_is_never_ranked_by_the_waiting_number() {
        // 两个数字都给了（宿主不该这么给）也按「能打」算，不会把它排到等待组里。
        let result = order(json!([
            {"id":"waiting","minutesUntil":1},
            {"id":"both","minutesLeft":600,"minutesUntil":1},
        ]));
        assert_eq!(result["order"], json!(["both", "waiting"]));
    }
}
