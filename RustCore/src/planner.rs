// SPDX-License-Identifier: GPL-3.0-only
//! 多人重叠搜索、例会轮换与拆场。日历 / tzdb / ICU 事实由 macOS 一次批量传入。
//!
//! 「一个人的作息落成哪些区间」那一层在 `availability.rs`，这里复用它；
//! 基础区间模块不依赖多人规划器。
use crate::availability::{blocked_day, intervals, CalendarFacts, Interval, Schedule};
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PlanRequest {
    participants: Vec<Schedule>,
    from: f64,
    range_end: f64,
    duration_minutes: i64,
    tolerance_minutes: i64,
    limit: i64,
    local_calendar: CalendarFacts,
    /// Foundation's additions of whole civil days from the reference day's start.
    scoring_day_starts: Vec<f64>,
    /// 理想时段：组织者本机墙钟的 [start, end) 分钟；时段起点落在里面的候选同档内排前面，
    /// 加分 0.5 永远越不过档（全员在时段内 2.0 vs 折中 1.0），所以只改顺序不改结论。没有就不加。
    #[serde(default)]
    ideal_start_minute: Option<i64>,
    #[serde(default)]
    ideal_end_minute: Option<i64>,
}

/// 理想时段加分：`minute` 是候选起点在本机墙钟的分钟数。时段可以跨午夜（22:00–02:00）。
fn ideal_bonus(minute: i64, ideal: Option<(i64, i64)>) -> f64 {
    match ideal {
        Some((start, end)) if start != end => {
            let inside = if start < end { (start..end).contains(&minute) } else { minute >= start || minute < end };
            if inside { 0.5 } else { 0.0 }
        }
        _ => 0.0,
    }
}

#[derive(Clone, Copy, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct Fit {
    kind: u8,
    outside_minutes: i64,
}

#[derive(Clone)]
struct Slot {
    start: f64,
    tier: u8,
    score: f64,
    fits: Vec<Fit>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct Window {
    tier: u8,
    start: f64,
    end: f64,
    best: f64,
    duration_minutes: i64,
    score: f64,
    fits: Vec<Fit>,
}


fn evaluate(start: f64, end: f64, intervals: &[Interval], tolerance: i64) -> (Fit, f64) {
    let mut best_outside = i64::MAX;
    let mut best_comfort: f64 = 0.0;
    let mut inside = false;
    for interval in intervals {
        if interval.end - start < -(tolerance as f64 * 60.0) {
            continue;
        }
        if interval.start - end > tolerance as f64 * 60.0 {
            break;
        }
        let before = (interval.start - start).max(0.0);
        let after = (end - interval.end).max(0.0);
        if before == 0.0 && after == 0.0 {
            inside = true;
            let mid = start + (end - start) / 2.0;
            let interval_mid = interval.start + (interval.end - interval.start) / 2.0;
            let relative =
                (mid - interval_mid).abs() / ((interval.end - interval.start) / 2.0).max(1.0);
            best_comfort = best_comfort.max(1.0 - relative.min(1.0));
        } else {
            best_outside = best_outside.min((before.max(after) / 60.0).ceil() as i64);
        }
    }
    if inside {
        (
            Fit {
                kind: 0,
                outside_minutes: 0,
            },
            best_comfort,
        )
    } else if best_outside <= tolerance {
        (
            Fit {
                kind: 1,
                outside_minutes: best_outside,
            },
            0.0,
        )
    } else {
        (
            Fit {
                kind: 2,
                outside_minutes: 0,
            },
            0.0,
        )
    }
}

fn same_group(a: &Slot, b: &Slot) -> bool {
    a.tier == b.tier
        && a.fits
            .iter()
            .map(|x| x.kind)
            .eq(b.fits.iter().map(|x| x.kind))
}

/// Every start time in `from..=range_end - duration` (15-minute grid) that all participants can
/// attend, with each one's fit. Shared by `plan` (one range) and `rotate` (one range per occurrence).
#[allow(clippy::too_many_arguments)]
fn enumerate_slots(
    participants: &[Schedule],
    schedules: &[Vec<Interval>],
    local_calendar: &CalendarFacts,
    from: f64,
    range_end: f64,
    duration_minutes: i64,
    tolerance_minutes: i64,
    scoring_day_starts: &[f64],
    ideal: Option<(i64, i64)>,
) -> Result<Vec<Slot>, String> {
    let duration = duration_minutes as f64 * 60.0;
    let step = 900.0;
    let mut time = (from / step).ceil() * step;
    let last_start = range_end - duration;
    let mut slots = Vec::new();
    while time <= last_start {
        let end = time + duration;
        let mut fits = Vec::with_capacity(participants.len());
        let mut tier = 0;
        let mut comfort = 0.0;
        let mut penalty = 0.0;
        let mut usable = true;
        for (index, participant) in participants.iter().enumerate() {
            if participant.calendar.days.iter().any(|day|
                blocked_day(participant, day) && time < day.end && end > day.start)
            {
                usable = false;
                break;
            }
            let (fit, c) = evaluate(time, end, &schedules[index], tolerance_minutes);
            match fit.kind {
                0 => comfort += c,
                1 => {
                    tier = 1;
                    penalty += fit.outside_minutes as f64 / tolerance_minutes.max(1) as f64;
                }
                _ => usable = false,
            }
            fits.push(fit);
            if !usable {
                break;
            }
        }
        if usable {
            let offset = local_calendar
                .days
                .iter()
                .flat_map(|day| &day.segments)
                .find(|segment| segment.start <= time && time < segment.end)
                .ok_or_else(|| "planner.plan: missing local offset segment".to_owned())?
                .offset_seconds;
            let minute = ((time + offset as f64).floor() as i64).rem_euclid(3600) / 60;
            let minute_of_day = ((time + offset as f64).floor() as i64).rem_euclid(86_400) / 60;
            let hourly = if minute == 0 {
                0.06
            } else if minute == 30 {
                0.03
            } else {
                0.0
            };
            let day_index = scoring_day_starts
                .iter()
                .take_while(|start| **start <= time)
                .count()
                .saturating_sub(1);
            let count = participants.len() as f64;
            let score = (if tier == 0 { 2.0 } else { 1.0 }) + comfort / count - penalty / count
                + hourly
                + ideal_bonus(minute_of_day, ideal)
                - 0.02 * day_index as f64;
            slots.push(Slot {
                start: time,
                tier,
                score,
                fits,
            });
        }
        time += step;
    }
    Ok(slots)
}

/// Adjacent slots with the same tier and fit kinds become one window; best tier and score first.
fn group_windows(slots: &[Slot], duration_minutes: i64, limit: usize) -> Vec<Window> {
    let duration = duration_minutes as f64 * 60.0;
    let step = 900.0;
    let mut windows = Vec::new();
    let mut first = 0;
    while first < slots.len() {
        let mut last = first;
        let mut best = first;
        while last + 1 < slots.len()
            && slots[last + 1].start - slots[last].start <= step + 0.5
            && same_group(&slots[first], &slots[last + 1])
        {
            last += 1;
            if slots[last].score > slots[best].score {
                best = last;
            }
        }
        windows.push(Window {
            tier: slots[first].tier,
            start: slots[first].start,
            end: slots[last].start + duration,
            best: slots[best].start,
            duration_minutes,
            score: slots[best].score,
            fits: slots[best].fits.clone(),
        });
        first = last + 1;
    }
    windows.sort_by(|a, b| {
        a.tier
            .cmp(&b.tier)
            .then_with(|| b.score.total_cmp(&a.score))
            .then_with(|| a.best.total_cmp(&b.best))
    });
    windows.truncate(limit.max(1));
    windows
}

fn plan(request: PlanRequest) -> Result<Vec<Window>, String> {
    if request.participants.is_empty() || request.duration_minutes <= 0 {
        return Ok(Vec::new());
    }
    let schedules: Vec<_> = request.participants.iter().map(intervals).collect();
    let slots = enumerate_slots(
        &request.participants,
        &schedules,
        &request.local_calendar,
        request.from,
        request.range_end,
        request.duration_minutes,
        request.tolerance_minutes,
        &request.scoring_day_starts,
        request.ideal_start_minute.zip(request.ideal_end_minute).filter(|(a, b)| (0..=1440).contains(a) && (0..=1440).contains(b)),
    )?;
    Ok(group_windows(&slots, request.duration_minutes, request.limit.max(1) as usize))
}

// MARK: - The find-a-meeting page: options for one meeting
//
// 页面的候选单。有大家都在工作时段内的时刻时：相邻时刻并成窗口，同一个本机钟点的几天并成一项（最多 4 项，按分数）。
// 没有时给「最接近」的几项：每个时刻算出谁在时段外、按当地钟点折合的负担（与例会轮换同一张钟点权重表），
// 同一批人在付的时刻里只留负担最轻的那一个，再按负担从轻到重取前 3 项。三项各是一种「谁让一点」的分法
// （洛杉矶清早加东京深夜、伦敦晚上加东京清早……），不会是同一个钟点排三天。每项另给同一个本机钟点、
// 同一批人在付的其余日子（页面的「哪一天」）。上限放到 12 小时：只有休息日与假期会让时刻不可用。
// 不改 `plan`：面板与快捷指令照旧用它，例会轮换也复用它的时刻枚举。

/// 「最接近」时容许的时段外分钟：够大，任何钟点都离某人的工作时段不到 12 小时，所以只有休息日会挡掉时刻。
const OPTIONS_TOLERANCE_MINUTES: i64 = 720;
/// 都在时段内的候选最多几项（各是一个本机钟点）。
const OPTIONS_EVERYONE: usize = 4;
/// 最接近的候选最多几项（各是一批不同的人在付）。
const OPTIONS_CLOSEST: usize = 3;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct OptionsRequest {
    participants: Vec<Schedule>,
    from: f64,
    range_end: f64,
    duration_minutes: i64,
    local_calendar: CalendarFacts,
    scoring_day_starts: Vec<f64>,
    #[serde(default)]
    ideal_start_minute: Option<i64>,
    #[serde(default)]
    ideal_end_minute: Option<i64>,
    /// 与例会轮换同一个设置：off / gentle / strong。
    #[serde(default = "default_clock_weight")]
    clock_weight: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct MeetingOption {
    /// 0 = 大家都在工作时段内，1 = 有人在时段外（最接近）。
    tier: u8,
    /// 代表那天的窗口：都在时段内时是可以开始的范围的外沿；最接近时就是这一场。
    start: f64,
    end: f64,
    best: f64,
    duration_minutes: i64,
    score: f64,
    /// 代表那天各人的处境（顺序同请求）。
    fits: Vec<Fit>,
    /// 各人按当地钟点折合的时段外分钟（在时段内为 0）。
    cost: Vec<i64>,
    /// 同一个本机钟点、同一批人在付的日子（各天的开始时刻，从早到晚，含代表那天）。
    days: Vec<f64>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct MeetingOptions {
    /// true = 下面几项大家都在时段内；false = 没有这样的时刻，下面是最接近的。
    everyone: bool,
    options: Vec<MeetingOption>,
}

/// 某一刻在组织者本机钟面上是几点几分（0…1439），与 `enumerate_slots` 里理想时段的算法相同。
fn local_minute(calendar: &CalendarFacts, time: f64) -> Option<i64> {
    calendar
        .days
        .iter()
        .flat_map(|day| &day.segments)
        .find(|segment| segment.start <= time && time < segment.end)
        .map(|segment| ((time + segment.offset_seconds as f64).floor() as i64).rem_euclid(86_400) / 60)
}

fn clock_column(clock_weight: &str) -> usize {
    match clock_weight {
        "gentle" => 1,
        "strong" => 2,
        _ => 0,
    }
}

/// `minute_cost` 的第一项（折合分钟），按段相加而不是逐分钟找日子：候选单要给几十天、上千个时刻各算一遍。
/// 逐分钟的那一个留给例会轮换（输出冻结），两者相等由测试核。
fn weighted_minutes(start: f64, minutes: i64, calendar: &CalendarFacts, column: usize) -> i64 {
    if minutes <= 0 {
        return 0;
    }
    // 不落在任何一天、或落在一天的第 1440 分钟以后（换钟那天 25 小时）的分钟按 1 倍算。
    let mut quarters = 4 * minutes;
    for day in &calendar.days {
        // 第 i 分钟（start + 60 i）落在这一天：day.start ≤ start + 60 i < day.end。
        let low = (((day.start - start) / 60.0).ceil() as i64).max(0);
        let high = (((day.end - start) / 60.0).ceil() as i64).min(minutes);
        if high <= low {
            continue;
        }
        // 第 i 分钟在当地是这一天的第 i + shift 分钟。
        let shift = ((start - day.start) / 60.0).floor() as i64;
        for (from, end, weights) in CLOCK_MINUTE_WEIGHTS {
            let a = low.max(from - shift);
            let b = high.min(end - shift);
            if b > a {
                quarters += (weights[column] - 4) * (b - a);
            }
        }
    }
    (quarters + 2) / 4
}

fn options(request: OptionsRequest) -> Result<MeetingOptions, String> {
    let empty = MeetingOptions { everyone: false, options: Vec::new() };
    if request.participants.is_empty() || request.duration_minutes <= 0 || request.range_end <= request.from {
        return Ok(empty);
    }
    let count = request.participants.len();
    let duration = request.duration_minutes;
    let schedules: Vec<_> = request.participants.iter().map(intervals).collect();
    let ideal = request
        .ideal_start_minute
        .zip(request.ideal_end_minute)
        .filter(|(a, b)| (0..=1440).contains(a) && (0..=1440).contains(b));
    let slots = enumerate_slots(
        &request.participants,
        &schedules,
        &request.local_calendar,
        request.from,
        request.range_end,
        duration,
        OPTIONS_TOLERANCE_MINUTES,
        &request.scoring_day_starts,
        ideal,
    )?;
    let minute_of = |time: f64| local_minute(&request.local_calendar, time);

    let everyone: Vec<Slot> = slots.iter().filter(|slot| slot.tier == 0).cloned().collect();
    if !everyone.is_empty() {
        // 相邻的时刻并成窗口（按分数从高到低），同一个本机钟点的窗口并成一项。
        let windows = group_windows(&everyone, duration, usize::MAX);
        let mut keys: Vec<Option<i64>> = Vec::new();
        let mut options: Vec<MeetingOption> = Vec::new();
        for window in windows {
            let key = minute_of(window.best);
            if let Some(index) = keys.iter().position(|k| *k == key) {
                options[index].days.push(window.best);
            } else if options.len() < OPTIONS_EVERYONE {
                keys.push(key);
                options.push(MeetingOption {
                    tier: 0,
                    start: window.start,
                    end: window.end,
                    best: window.best,
                    duration_minutes: duration,
                    score: window.score,
                    fits: window.fits,
                    cost: vec![0; count],
                    days: vec![window.best],
                });
            }
        }
        for option in &mut options {
            option.days.sort_by(f64::total_cmp);
        }
        return Ok(MeetingOptions { everyone: true, options });
    }

    // 最接近：每个时刻的负担，同一批人在付的只留最轻的那个。
    let column = clock_column(&request.clock_weight);
    struct Pick {
        slot: usize,
        payers: Vec<usize>,
        cost: Vec<i64>,
        key: (i64, i64),
    }
    let better = |a: &Pick, b: &Pick| -> bool {
        // 负担总量轻的在前，再看最重的那个人，再看分数（舒适度、整点、理想时段、越早越好），最后按时刻。
        a.key < b.key
            || (a.key == b.key
                && (slots[a.slot].score > slots[b.slot].score
                    || (slots[a.slot].score == slots[b.slot].score && slots[a.slot].start < slots[b.slot].start)))
    };
    let mut picks: Vec<Pick> = Vec::new();
    for (index, slot) in slots.iter().enumerate() {
        let end = slot.start + duration as f64 * 60.0;
        let mut payers = Vec::new();
        let mut cost = Vec::with_capacity(count);
        for (person, fit) in slot.fits.iter().enumerate() {
            if fit.kind == 1 {
                payers.push(person);
                let from = outside_start_at(slot.start, end, fit, &schedules[person], OPTIONS_TOLERANCE_MINUTES);
                cost.push(weighted_minutes(from, fit.outside_minutes, &request.participants[person].calendar, column));
            } else {
                cost.push(0);
            }
        }
        let key = (cost.iter().sum::<i64>(), cost.iter().copied().max().unwrap_or(0));
        let pick = Pick { slot: index, payers, cost, key };
        match picks.iter().position(|other| other.payers == pick.payers) {
            Some(existing) => {
                if better(&pick, &picks[existing]) {
                    picks[existing] = pick;
                }
            }
            None => picks.push(pick),
        }
    }
    picks.sort_by(|a, b| {
        if better(a, b) {
            std::cmp::Ordering::Less
        } else if better(b, a) {
            std::cmp::Ordering::Greater
        } else {
            std::cmp::Ordering::Equal
        }
    });
    picks.truncate(OPTIONS_CLOSEST);
    let options = picks
        .into_iter()
        .map(|pick| {
            let slot = &slots[pick.slot];
            let key = minute_of(slot.start);
            let days = slots
                .iter()
                .filter(|other| {
                    minute_of(other.start) == key
                        && other.fits.iter().map(|fit| fit.kind == 1).eq(slot.fits.iter().map(|fit| fit.kind == 1))
                })
                .map(|other| other.start)
                .collect();
            MeetingOption {
                tier: 1,
                start: slot.start,
                end: slot.start + duration as f64 * 60.0,
                best: slot.start,
                duration_minutes: duration,
                score: slot.score,
                fits: slot.fits.clone(),
                cost: pick.cost,
                days,
            }
        })
        .collect();
    Ok(MeetingOptions { everyone: false, options })
}

/// 试一个时刻（页面的时间轴上点一下）：每人按自己的工作时段区间算处境，与 `plan` 同一个 `evaluate`。
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct FitRequest {
    /// 每人的工作时段区间（宿主从 `availability.intervals` 拿到的，原样传回）。
    intervals: Vec<Vec<Interval>>,
    start: f64,
    duration_minutes: i64,
}

fn fit(request: FitRequest) -> Result<Vec<Fit>, String> {
    if request.duration_minutes <= 0 || !request.start.is_finite() {
        return Err("planner.fit needs a positive duration and a finite start".into());
    }
    let end = request.start + request.duration_minutes as f64 * 60.0;
    Ok(request
        .intervals
        .iter()
        .map(|list| {
            let mut sorted = list.clone();
            sorted.sort_by(|a, b| a.start.total_cmp(&b.start));
            evaluate(request.start, end, &sorted, OPTIONS_TOLERANCE_MINUTES).0
        })
        .collect())
}

// MARK: - Splitting one meeting into N sessions
//
// 三大洲的全员会没有一个时刻能让所有人都在工作时段内（这正是 `rotate` 要解的问题）。第二种解法是
// **开 N 场**，每人只来自己方便的那一场。命名按 GitLab 的规矩只标
// 「第 1 / 2 / 3 场」——「对一个人的 early 是另一个人的 late」，所以不许出现 APAC friendly / early / late。
//
// 挑法：先枚举整段范围里所有时刻（容差放到 24 小时，这样只有假期与休息日会让时刻不可用，
// 其余时刻都留下、各人的 `fit.kind == 0` 就表示「这一场在他的工作时段内」）；再按集合覆盖贪心选 N 场
// （每次选能新覆盖最多人的那一场，同样多就选分数高的），最后做几轮替换改进（覆盖更多人，或人数相同
// 而总分更高才换）。确定性，不猜。

/// 只允许拆成 2 或 3 场（封闭选项；再多就不是一个会了）。
const SPLIT_SESSION_CHOICES: [i64; 2] = [2, 3];
/// 枚举时给的容差：够大，所以每个人对每个时刻要么「在时段内」要么「在时段外」，不会因为超出容差被丢掉。
const SPLIT_TOLERANCE_MINUTES: i64 = 1440;
/// 改进的轮数上限。
const SPLIT_PASSES: usize = 3;

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SplitRequest {
    participants: Vec<Schedule>,
    from: f64,
    range_end: f64,
    duration_minutes: i64,
    sessions: i64,
    local_calendar: CalendarFacts,
    #[serde(default)]
    scoring_day_starts: Vec<f64>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct SplitSession {
    /// 第几场（1 起）。
    index: usize,
    start: f64,
    end: f64,
    /// 这一场落在工作时段内的参与者下标。
    inside: Vec<usize>,
    /// 每人的贴合度（与 `plan` 同一套：0 在时段内、1 在时段外）。
    fits: Vec<Fit>,
    score: f64,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct Split {
    sessions: Vec<SplitSession>,
    /// 每人是否至少有一场在工作时段内。
    covered: Vec<bool>,
    /// 一场都不在工作时段内的人（下标）。
    uncovered: Vec<usize>,
    /// 有没有必要拆：某一个时刻就能让所有人都在时段内时是 false。
    needed: bool,
}

fn split(request: SplitRequest) -> Result<Split, String> {
    let count = request.participants.len();
    let sessions_wanted = if SPLIT_SESSION_CHOICES.contains(&request.sessions) {
        request.sessions as usize
    } else {
        2
    };
    let empty = Split {
        sessions: Vec::new(),
        covered: vec![false; count],
        uncovered: (0..count).collect(),
        needed: count > 1,
    };
    if count == 0 || request.duration_minutes <= 0 || request.range_end <= request.from {
        return Ok(empty);
    }
    let schedules: Vec<_> = request.participants.iter().map(intervals).collect();
    let day_starts = if request.scoring_day_starts.is_empty() {
        vec![request.from]
    } else {
        request.scoring_day_starts.clone()
    };
    let slots = enumerate_slots(
        &request.participants,
        &schedules,
        &request.local_calendar,
        request.from,
        request.range_end,
        request.duration_minutes,
        SPLIT_TOLERANCE_MINUTES,
        &day_starts,
        None,
    )?;
    if slots.is_empty() {
        return Ok(empty);
    }
    let inside_of = |slot: &Slot| -> Vec<usize> {
        slot.fits
            .iter()
            .enumerate()
            .filter(|(_, fit)| fit.kind == 0)
            .map(|(index, _)| index)
            .collect()
    };
    // 一场就能覆盖所有人 → 不用拆（页面据此只给一句话，不列场次）。
    if slots.iter().any(|slot| inside_of(slot).len() == count) {
        return Ok(Split {
            sessions: Vec::new(),
            covered: vec![true; count],
            uncovered: Vec::new(),
            needed: false,
        });
    }
    let duration = request.duration_minutes as f64 * 60.0;
    let overlaps = |a: &Slot, b: &Slot| a.start < b.start + duration && b.start < a.start + duration;
    // 贪心：每次选「新覆盖的人最多」的时刻，一样多就选分数高的、再一样就选早的。
    let mut chosen: Vec<usize> = Vec::new();
    for _ in 0..sessions_wanted {
        let mut covered: Vec<bool> = vec![false; count];
        for index in &chosen {
            for person in inside_of(&slots[*index]) {
                covered[person] = true;
            }
        }
        let mut best: Option<(usize, usize, f64)> = None;
        for (index, slot) in slots.iter().enumerate() {
            if chosen.iter().any(|other| *other == index || overlaps(slot, &slots[*other])) {
                continue;
            }
            let gain = inside_of(slot).iter().filter(|person| !covered[**person]).count();
            let better = match best {
                None => true,
                Some((_, best_gain, best_score)) => {
                    gain > best_gain || (gain == best_gain && slot.score > best_score)
                }
            };
            if better {
                best = Some((index, gain, slot.score));
            }
        }
        match best {
            Some((index, _, _)) => chosen.push(index),
            None => break,
        }
    }
    // 改进：逐个位置试着换成别的时刻，覆盖更多人、或人数相同而总分更高才换。
    let coverage_of = |set: &[usize]| -> usize {
        let mut covered = vec![false; count];
        for index in set {
            for person in inside_of(&slots[*index]) {
                covered[person] = true;
            }
        }
        covered.iter().filter(|x| **x).count()
    };
    let total_score = |set: &[usize]| -> f64 { set.iter().map(|index| slots[*index].score).sum() };
    for _ in 0..SPLIT_PASSES {
        let mut improved = false;
        for position in 0..chosen.len() {
            let mut best = (coverage_of(&chosen), total_score(&chosen), chosen[position]);
            for (index, slot) in slots.iter().enumerate() {
                if chosen.iter().enumerate().any(|(other, value)| {
                    other != position && (*value == index || overlaps(slot, &slots[*value]))
                }) {
                    continue;
                }
                let mut trial = chosen.clone();
                trial[position] = index;
                let key = (coverage_of(&trial), total_score(&trial));
                if key.0 > best.0 || (key.0 == best.0 && key.1 > best.1) {
                    best = (key.0, key.1, index);
                    improved = true;
                }
            }
            chosen[position] = best.2;
        }
        if !improved {
            break;
        }
    }
    chosen.sort_by(|a, b| slots[*a].start.total_cmp(&slots[*b].start));
    let mut covered = vec![false; count];
    let sessions: Vec<SplitSession> = chosen
        .iter()
        .enumerate()
        .map(|(position, index)| {
            let slot = &slots[*index];
            let inside = inside_of(slot);
            for person in &inside {
                covered[*person] = true;
            }
            SplitSession {
                index: position + 1,
                start: slot.start,
                end: slot.start + duration,
                inside,
                fits: slot.fits.clone(),
                score: slot.score,
            }
        })
        .collect();
    let uncovered = (0..count).filter(|person| !covered[*person]).collect();
    Ok(Split {
        sessions,
        covered,
        uncovered,
        needed: true,
    })
}

// MARK: - Rotating a recurring meeting
//
// 按钟点成本分担时段外负担：轮流看累计成本，均摊只看单次成本。

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Occurrence {
    from: f64,
    range_end: f64,
}

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RotateRequest {
    participants: Vec<Schedule>,
    /// One civil-day range per occurrence, in the organizer's zone, oldest first.
    occurrences: Vec<Occurrence>,
    duration_minutes: i64,
    /// The most anyone is asked to sit outside their hours for a single occurrence, in minutes.
    max_stretch_minutes: i64,
    local_calendar: CalendarFacts,
    #[serde(default = "default_rotation_split")]
    split: String,
    #[serde(default = "default_clock_weight")]
    clock_weight: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct RotationOccurrence {
    index: usize,
    from: f64,
    /// None when nobody could meet that day: a holiday, a rest day, or nothing within the cap.
    window: Option<Window>,
    /// Minutes each participant (request order) sits outside their hours; zeros without a window.
    stretch: Vec<i64>,
    cost: Vec<i64>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct RotationTotal {
    outside_minutes: i64,
    outside_count: i64,
    weighted_minutes: i64,
    night_minutes: i64,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct Rotation {
    occurrences: Vec<RotationOccurrence>,
    totals: Vec<RotationTotal>,
    /// Largest total minus smallest total: 0 is perfectly even.
    spread_minutes: i64,
    weighted_spread: i64,
    /// False when every held occurrence has everyone inside their hours, so nothing rotates.
    needed: bool,
    skipped: usize,
}

const ROTATION_CANDIDATES: usize = 96;
const ROTATION_PASSES: usize = 8;

fn default_rotation_split() -> String {
    "rotate".to_owned()
}

fn default_clock_weight() -> String {
    "off".to_owned()
}

// 钟点权重以四分之一分钟为单位，依次为不加权、保守、加重。
const CLOCK_MINUTE_WEIGHTS: [(i64, i64, [i64; 3]); 4] = [
    (0, 360, [4, 8, 12]),
    (360, 480, [4, 5, 6]),
    (1320, 1440, [4, 6, 8]),
    (480, 1320, [4, 4, 4]),
];

struct RotationCandidate {
    window: Window,
    cost: Vec<i64>,
    night: Vec<i64>,
}

// 与贴合度同一段距离：前后两段取较长者，同长时取前段。
fn outside_start(window: &Window, fit: &Fit, schedule: &[Interval], tolerance: i64) -> f64 {
    let start = window.best;
    outside_start_at(start, start + window.duration_minutes as f64 * 60.0, fit, schedule, tolerance)
}

/// `outside_start` 按一场会的起止算（候选单的每个时刻用它，例会轮换经上面那一个）。
fn outside_start_at(start: f64, end: f64, fit: &Fit, schedule: &[Interval], tolerance: i64) -> f64 {
    schedule.iter().find_map(|interval| {
        if interval.end - start < -(tolerance as f64 * 60.0)
            || interval.start - end > tolerance as f64 * 60.0 {
            return None;
        }
        let before = (interval.start - start).max(0.0);
        let after = (end - interval.end).max(0.0);
        ((before.max(after) / 60.0).ceil() as i64 == fit.outside_minutes)
            .then_some(if before >= after { start } else { interval.end })
    }).unwrap_or(start)
}

fn minute_cost(start: f64, minutes: i64, calendar: &CalendarFacts, clock_weight: &str) -> (i64, i64) {
    let column = match clock_weight {
        "gentle" => 1,
        "strong" => 2,
        _ => 0,
    };
    let mut quarters = 0;
    let mut night = 0;
    for minute in 0..minutes {
        let time = start + minute as f64 * 60.0;
        let local = calendar.days.iter()
            .find(|day| day.start <= time && time < day.end)
            .map(|day| ((time - day.start) / 60.0).floor() as i64);
        let weight = local.and_then(|local| CLOCK_MINUTE_WEIGHTS.iter()
            .find(|(from, end, _)| (*from..*end).contains(&local)))
            .map_or(4, |(_, _, weights)| weights[column]);
        quarters += weight;
        if local.is_some_and(|local| (0..360).contains(&local)) {
            night += 1;
        }
    }
    ((quarters + 2) / 4, night)
}

fn rotation_candidate(window: Window, request: &RotateRequest, schedules: &[Vec<Interval>]) -> RotationCandidate {
    let mut cost = Vec::with_capacity(request.participants.len());
    let mut night = Vec::with_capacity(request.participants.len());
    for ((fit, participant), schedule) in window.fits.iter().zip(&request.participants).zip(schedules) {
        let (weighted, small_hours) = if fit.kind == 1 {
            minute_cost(outside_start(&window, fit, schedule, request.max_stretch_minutes),
                fit.outside_minutes, &participant.calendar, &request.clock_weight)
        } else {
            (0, 0)
        };
        cost.push(weighted);
        night.push(small_hours);
    }
    RotationCandidate { window, cost, night }
}

fn stretch_of(window: &Window) -> Vec<i64> {
    window
        .fits
        .iter()
        .map(|fit| if fit.kind == 1 { fit.outside_minutes } else { 0 })
        .collect()
}

/// 成本加到累计负担后，先比最重的人，再比总量。
fn fairness_key(load: &[i64], cost: &[i64]) -> (i64, i64) {
    let mut heaviest = 0;
    let mut total = 0;
    for (current, extra) in load.iter().zip(cost) {
        let value = current + extra;
        heaviest = heaviest.max(value);
        total += value;
    }
    (heaviest, total)
}

fn rotate(request: RotateRequest) -> Result<Rotation, String> {
    let count = request.participants.len();
    let empty = || Rotation {
        occurrences: Vec::new(),
        totals: vec![
            RotationTotal {
                outside_minutes: 0,
                outside_count: 0,
                weighted_minutes: 0,
                night_minutes: 0
            };
            count
        ],
        spread_minutes: 0,
        weighted_spread: 0,
        needed: false,
        skipped: request.occurrences.len(),
    };
    if count == 0 || request.duration_minutes <= 0 || request.occurrences.is_empty() {
        return Ok(empty());
    }
    let schedules: Vec<_> = request.participants.iter().map(intervals).collect();
    let mut candidates = Vec::with_capacity(request.occurrences.len());
    for occurrence in &request.occurrences {
        let slots = enumerate_slots(
            &request.participants,
            &schedules,
            &request.local_calendar,
            occurrence.from,
            occurrence.range_end,
            request.duration_minutes,
            request.max_stretch_minutes,
            &[occurrence.from],
            None,
        )?;
        candidates.push(group_windows(&slots, request.duration_minutes, ROTATION_CANDIDATES).into_iter()
            .map(|window| rotation_candidate(window, &request, &schedules)).collect::<Vec<_>>());
    }
    // 轮流按累计负担选；均摊只看这一次。
    let share = request.split == "share";
    let zero = vec![0i64; count];
    let mut load = vec![0i64; count];
    let mut choice: Vec<Option<usize>> = Vec::with_capacity(candidates.len());
    for windows in &candidates {
        let mut best: Option<(usize, (i64, i64), f64)> = None;
        for (index, window) in windows.iter().enumerate() {
            let key = fairness_key(if share { &zero } else { &load }, &window.cost);
            let better = match best {
                None => true,
                Some((_, best_key, best_score)) => {
                    key < best_key || (key == best_key && window.window.score > best_score)
                }
            };
            if better {
                best = Some((index, key, window.window.score));
            }
        }
        if let Some((index, _, _)) = best {
            for (current, extra) in load.iter_mut().zip(&windows[index].cost) {
                *current += extra;
            }
        }
        choice.push(best.map(|(index, _, _)| index));
    }
    // 轮流重选只在累计负担严格降低时接受。
    for _ in 0..if share { 0 } else { ROTATION_PASSES } {
        let mut improved = false;
        for (k, windows) in candidates.iter().enumerate() {
            let Some(current) = choice[k] else { continue };
            let current_cost = windows[current].cost.clone();
            let base: Vec<i64> = load
                .iter()
                .zip(&current_cost)
                .map(|(total, extra)| total - extra)
                .collect();
            let mut best = (fairness_key(&base, &current_cost), current);
            for (index, window) in windows.iter().enumerate() {
                let key = fairness_key(&base, &window.cost);
                if key < best.0 {
                    best = (key, index);
                }
            }
            if best.1 != current {
                let next = &windows[best.1].cost;
                for ((total, before), after) in load.iter_mut().zip(&current_cost).zip(next) {
                    *total = *total - before + after;
                }
                choice[k] = Some(best.1);
                improved = true;
            }
        }
        if !improved {
            break;
        }
    }
    let mut totals = vec![
        RotationTotal {
            outside_minutes: 0,
            outside_count: 0,
                weighted_minutes: 0,
                night_minutes: 0
        };
        count
    ];
    let mut occurrences = Vec::with_capacity(candidates.len());
    let mut skipped = 0;
    for (k, (occurrence, windows)) in request.occurrences.iter().zip(&candidates).enumerate() {
        match choice[k] {
            Some(index) => {
                let candidate = &windows[index];
                let window = candidate.window.clone();
                let stretch = stretch_of(&window);
                for (((total, extra), cost), night) in totals.iter_mut().zip(&stretch).zip(&candidate.cost).zip(&candidate.night) {
                    total.weighted_minutes += cost;
                    total.night_minutes += night;
                    total.outside_minutes += extra;
                    if *extra > 0 {
                        total.outside_count += 1;
                    }
                }
                occurrences.push(RotationOccurrence {
                    index: k,
                    from: occurrence.from,
                    window: Some(window),
                    stretch,
                    cost: candidate.cost.clone(),
                });
            }
            None => {
                skipped += 1;
                occurrences.push(RotationOccurrence {
                    index: k,
                    from: occurrence.from,
                    window: None,
                    stretch: vec![0; count],
                    cost: vec![0; count],
                });
            }
        }
    }
    let heaviest = totals.iter().map(|t| t.outside_minutes).max().unwrap_or(0);
    let lightest = totals.iter().map(|t| t.outside_minutes).min().unwrap_or(0);
    let weighted_heaviest = totals.iter().map(|t| t.weighted_minutes).max().unwrap_or(0);
    let weighted_lightest = totals.iter().map(|t| t.weighted_minutes).min().unwrap_or(0);
    Ok(Rotation {
        occurrences,
        needed: heaviest > 0,
        spread_minutes: heaviest - lightest,
        weighted_spread: weighted_heaviest - weighted_lightest,
        skipped,
        totals,
    })
}


pub fn dispatch(operation: &str, payload: Value) -> Result<Value, String> {
    match operation {
        "planner.plan" => {
            let input: PlanRequest = serde_json::from_value(payload).map_err(|e| e.to_string())?;
            serde_json::to_value(plan(input)?).map_err(|e| e.to_string())
        }
        "planner.split" => {
            let request: SplitRequest = serde_json::from_value(payload).map_err(|e| e.to_string())?;
            serde_json::to_value(split(request)?).map_err(|e| e.to_string())
        }
        "planner.rotate" => {
            let input: RotateRequest = serde_json::from_value(payload).map_err(|e| e.to_string())?;
            serde_json::to_value(rotate(input)?).map_err(|e| e.to_string())
        }
        "planner.options" => {
            let input: OptionsRequest = serde_json::from_value(payload).map_err(|e| e.to_string())?;
            serde_json::to_value(options(input)?).map_err(|e| e.to_string())
        }
        "planner.fit" => {
            let input: FitRequest = serde_json::from_value(payload).map_err(|e| e.to_string())?;
            serde_json::to_value(fit(input)?).map_err(|e| e.to_string())
        }
        _ => Err(format!("Unknown planner operation: {operation}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    // 作息与区间规则在 `availability.rs`，这里的夹具复用它的类型与函数。
    use crate::availability::{can_start_shift, Availability, Day, OffsetSegment, Vacation};

    fn day(start: f64, end: f64, wall_day: f64, segments: &[(f64, f64, i64)]) -> Day {
        Day {
            start,
            end,
            wall_day,
            weekend: false,
            weekday: 0,
            date: String::new(),
            segments: segments
                .iter()
                .map(|&(start, end, offset_seconds)| OffsetSegment {
                    start,
                    end,
                    offset_seconds,
                })
                .collect(),
        }
    }

    fn schedule(start: i64, end: i64, days: Vec<Day>, anchor_count: usize) -> Schedule {
        Schedule {
            availability: Availability {
                start_minute: start,
                end_minute: end,
                weekdays_only: false,
            },
            working_weekdays: None,
            vacations: vec![],
            calendar: CalendarFacts { days, anchor_count },
        }
    }

    #[test]
    fn equal_endpoints_cover_the_entire_day_and_adjacent_days_merge() {
        let a = day(0.0, 86400.0, 0.0, &[(0.0, 86400.0, 0)]);
        let b = day(86400.0, 172800.0, 86400.0, &[(86400.0, 172800.0, 0)]);
        assert_eq!(
            intervals(&schedule(540, 540, vec![a, b], 2)),
            vec![Interval {
                start: 0.0,
                end: 172800.0
            }]
        );
    }

    #[test]
    fn spring_forward_skips_missing_wall_clock_time() {
        let a = day(
            0.0,
            82800.0,
            0.0,
            &[(0.0, 7200.0, 0), (7200.0, 82800.0, 3600)],
        );
        assert!(intervals(&schedule(135, 165, vec![a.clone()], 1)).is_empty());
        assert_eq!(
            intervals(&schedule(150, 240, vec![a], 1)),
            vec![Interval {
                start: 7200.0,
                end: 10800.0
            }]
        );
    }

    #[test]
    fn fall_back_preserves_both_occurrences_with_a_real_gap() {
        let a = day(
            0.0,
            90000.0,
            0.0,
            &[(0.0, 7200.0, 0), (7200.0, 90000.0, -3600)],
        );
        assert_eq!(
            intervals(&schedule(75, 105, vec![a], 1)),
            vec![
                Interval {
                    start: 4500.0,
                    end: 6300.0
                },
                Interval {
                    start: 8100.0,
                    end: 9900.0
                }
            ]
        );
    }

    #[test]
    fn overnight_stops_at_a_weekend() {
        let a = day(0.0, 86400.0, 0.0, &[(0.0, 86400.0, 0)]);
        let mut b = day(86400.0, 172800.0, 86400.0, &[(86400.0, 172800.0, 0)]);
        b.weekend = true;
        let mut s = schedule(1320, 360, vec![a, b], 1);
        s.availability.weekdays_only = true;
        assert_eq!(
            intervals(&s),
            vec![Interval {
                start: 79200.0,
                end: 86400.0
            }]
        );
    }

    #[test]
    fn ordinary_overlap_enumerates_and_groups_only_valid_full_meetings() {
        let a = day(0.0, 86400.0, 0.0, &[(0.0, 86400.0, 0)]);
        let request = PlanRequest {
            participants: vec![
                schedule(540, 1080, vec![a.clone()], 1),
                schedule(600, 1020, vec![a.clone()], 1),
            ],
            from: 0.0,
            range_end: 86400.0,
            duration_minutes: 60,
            tolerance_minutes: 0,
            limit: 8,
            local_calendar: CalendarFacts {
                days: vec![a],
                anchor_count: 1,
            },
            scoring_day_starts: vec![0.0],
            ideal_start_minute: None,
            ideal_end_minute: None,
        };
        let windows = plan(request).unwrap();
        assert_eq!(windows.len(), 1);
        assert_eq!(windows[0].start, 36000.0);
        assert_eq!(windows[0].end, 61200.0);
        assert!(windows[0].fits.iter().all(|fit| fit.kind == 0));
    }
    /// 理想时段：两人 9–18 与 10–17 重叠 10:00–17:00；不设理想时段时最佳起点是 13:00（评分靠中点舒适度 + 整点），
    /// 设「上午 10–12」后最佳起点挪进 10:00–12:00；理想时段只改同档顺序，折中档（tier 1）永远排在全员档之后。
    #[test]
    fn ideal_window_reorders_within_a_tier_but_never_across_tiers() {
        let a = day(0.0, 86400.0, 0.0, &[(0.0, 86400.0, 0)]);
        let request = |ideal: Option<(i64, i64)>, tolerance: i64| PlanRequest {
            participants: vec![
                schedule(540, 1080, vec![a.clone()], 1),
                schedule(600, 1020, vec![a.clone()], 1),
            ],
            from: 0.0,
            range_end: 86400.0,
            duration_minutes: 60,
            tolerance_minutes: tolerance,
            limit: 8,
            local_calendar: CalendarFacts { days: vec![a.clone()], anchor_count: 1 },
            scoring_day_starts: vec![0.0],
            ideal_start_minute: ideal.map(|i| i.0),
            ideal_end_minute: ideal.map(|i| i.1),
        };
        let plain = plan(request(None, 0)).unwrap();
        let morning = plan(request(Some((10 * 60, 12 * 60)), 0)).unwrap();
        assert_eq!(plain.len(), 1);
        assert_eq!(morning.len(), 1, "理想时段不改结论：可约窗口还是那一个");
        assert_eq!((morning[0].start, morning[0].end), (plain[0].start, plain[0].end));
        let best_minute = |w: &Window| ((w.best / 60.0) as i64).rem_euclid(1440);
        assert_eq!(best_minute(&plain[0]), 13 * 60, "不设理想时段时最佳起点是重叠段的中点附近");
        assert!((10 * 60..12 * 60).contains(&best_minute(&morning[0])), "最佳起点 {} 该在 10:00–12:00", best_minute(&morning[0]));
        // 跨午夜的理想时段（22:00–02:00）与空时段（start == end）都不炸：空时段等于没有
        let empty = plan(request(Some((600, 600)), 0)).unwrap();
        assert_eq!(best_minute(&empty[0]), best_minute(&plain[0]));
        let _ = plan(request(Some((22 * 60, 2 * 60)), 0)).unwrap();
        // 折中档：把第二人时段改到只有 18–20 与第一人不重叠但容忍 120 分钟，理想时段设在折中处也不能越档
        assert_eq!(ideal_bonus(13 * 60, Some((13 * 60, 16 * 60))), 0.5);
        assert_eq!(ideal_bonus(16 * 60, Some((13 * 60, 16 * 60))), 0.0);
        assert_eq!(ideal_bonus(23 * 60, Some((22 * 60, 2 * 60))), 0.5);
        assert_eq!(ideal_bonus(60, Some((22 * 60, 2 * 60))), 0.5);
        assert_eq!(ideal_bonus(3 * 60, Some((22 * 60, 2 * 60))), 0.0);
    }

    // MARK: rotation

    // 冻结原选法，逐项核对旧调用的结果。
    fn legacy_rotate(request: RotateRequest) -> Result<Rotation, String> {
        fn legacy_key(load: &[i64], stretch: &[i64]) -> (i64, i64) {
            let sums: Vec<_> = load.iter().zip(stretch).map(|(a, b)| a + b).collect();
            (sums.iter().copied().max().unwrap_or(0), sums.iter().sum())
        }
        let count = request.participants.len();
        let empty = || Rotation {
            occurrences: Vec::new(),
            totals: vec![
                RotationTotal {
                    outside_minutes: 0,
                    outside_count: 0,
                    weighted_minutes: 0,
                    night_minutes: 0
                };
                count
            ],
            spread_minutes: 0,
            weighted_spread: 0,
            needed: false,
            skipped: request.occurrences.len(),
        };
        if count == 0 || request.duration_minutes <= 0 || request.occurrences.is_empty() {
            return Ok(empty());
        }
        let schedules: Vec<_> = request.participants.iter().map(intervals).collect();
        let mut candidates = Vec::with_capacity(request.occurrences.len());
        for occurrence in &request.occurrences {
            let slots = enumerate_slots(
                &request.participants,
                &schedules,
                &request.local_calendar,
                occurrence.from,
                occurrence.range_end,
                request.duration_minutes,
                request.max_stretch_minutes,
                &[occurrence.from],
                None,
            )?;
            candidates.push(group_windows(&slots, request.duration_minutes, ROTATION_CANDIDATES));
        }
        // 原贪心选法：每次压低累计分钟。
        let mut load = vec![0i64; count];
        let mut choice: Vec<Option<usize>> = Vec::with_capacity(candidates.len());
        for windows in &candidates {
            let mut best: Option<(usize, (i64, i64), f64)> = None;
            for (index, window) in windows.iter().enumerate() {
                let key = legacy_key(&load, &stretch_of(window));
                let better = match best {
                    None => true,
                    Some((_, best_key, best_score)) => {
                        key < best_key || (key == best_key && window.score > best_score)
                    }
                };
                if better {
                    best = Some((index, key, window.score));
                }
            }
            if let Some((index, _, _)) = best {
                for (current, extra) in load.iter_mut().zip(stretch_of(&windows[index])) {
                    *current += extra;
                }
            }
            choice.push(best.map(|(index, _, _)| index));
        }
        // 原重选规则：严格降低累计分钟才接受。
        for _ in 0..ROTATION_PASSES {
            let mut improved = false;
            for (k, windows) in candidates.iter().enumerate() {
                let Some(current) = choice[k] else { continue };
                let current_stretch = stretch_of(&windows[current]);
                let base: Vec<i64> = load
                    .iter()
                    .zip(&current_stretch)
                    .map(|(total, extra)| total - extra)
                    .collect();
                let mut best = (legacy_key(&base, &current_stretch), current);
                for (index, window) in windows.iter().enumerate() {
                    let key = legacy_key(&base, &stretch_of(window));
                    if key < best.0 {
                        best = (key, index);
                    }
                }
                if best.1 != current {
                    let next = stretch_of(&windows[best.1]);
                    for ((total, before), after) in load.iter_mut().zip(&current_stretch).zip(&next) {
                        *total = *total - before + after;
                    }
                    choice[k] = Some(best.1);
                    improved = true;
                }
            }
            if !improved {
                break;
            }
        }
        let mut totals = vec![
            RotationTotal {
                outside_minutes: 0,
                outside_count: 0,
                    weighted_minutes: 0,
                    night_minutes: 0
            };
            count
        ];
        let mut occurrences = Vec::with_capacity(candidates.len());
        let mut skipped = 0;
        for (k, (occurrence, windows)) in request.occurrences.iter().zip(&candidates).enumerate() {
            match choice[k] {
                Some(index) => {
                    let window = windows[index].clone();
                    let stretch = stretch_of(&window);
                    for (total, extra) in totals.iter_mut().zip(&stretch) {
                        total.outside_minutes += extra;
                        if *extra > 0 {
                            total.outside_count += 1;
                        }
                    }
                    occurrences.push(RotationOccurrence {
                        index: k,
                        from: occurrence.from,
                        window: Some(window),
                        cost: stretch.clone(),
                        stretch,
                    });
                }
                None => {
                    skipped += 1;
                    occurrences.push(RotationOccurrence {
                        index: k,
                        from: occurrence.from,
                        window: None,
                        stretch: vec![0; count],
                        cost: vec![0; count],
                    });
                }
            }
        }
        let heaviest = totals.iter().map(|t| t.outside_minutes).max().unwrap_or(0);
        let lightest = totals.iter().map(|t| t.outside_minutes).min().unwrap_or(0);
        Ok(Rotation {
            occurrences,
            needed: heaviest > 0,
            spread_minutes: heaviest - lightest,
            weighted_spread: heaviest - lightest,
            skipped,
            totals,
        })
    }


    const DAY: f64 = 86_400.0;
    /// A UTC midnight that keeps every fixture day clear of any real weekend logic (weekend=false).
    const WALL0: f64 = 1_800_057_600.0;

    /// Civil days of a fixed-offset zone for wall days `-1..=days`, dated "00099", "00100", ...
    fn zone_days(offset: i64, days: i64) -> Vec<Day> {
        (-1..=days)
            .map(|k| {
                let wall_day = WALL0 + k as f64 * DAY;
                let start = wall_day - offset as f64;
                Day {
                    date: format!("{:05}", 100 + k),
                    ..day(start, start + DAY, wall_day, &[(start, start + DAY, offset)])
                }
            })
            .collect()
    }

    fn zone_schedule(offset: i64, days: i64, vacations: Vec<Vacation>) -> Schedule {
        let days = zone_days(offset, days);
        let anchor_count = days.len();
        Schedule {
            vacations,
            ..schedule(540, 1080, days, anchor_count)
        }
    }

    /// Weekly occurrences on the organizer's (Los Angeles, UTC−7) civil days 0, 7, 14, ...
    fn weekly(count: usize) -> Vec<Occurrence> {
        (0..count)
            .map(|k| {
                let from = WALL0 + k as f64 * 7.0 * DAY + 25_200.0;
                Occurrence {
                    from,
                    range_end: from + DAY,
                }
            })
            .collect()
    }

    fn rotation_request(participants: Vec<Schedule>, occurrences: Vec<Occurrence>, cap: i64) -> RotateRequest {
        RotateRequest {
            participants,
            occurrences,
            duration_minutes: 60,
            max_stretch_minutes: cap,
            local_calendar: CalendarFacts {
                days: zone_days(-25_200, 22),
                anchor_count: 24,
            },
            split: "rotate".to_owned(),
            clock_weight: "off".to_owned(),
        }
    }

    fn rotation_payload(request: &RotateRequest) -> Value {
        let calendar = |facts: &CalendarFacts| serde_json::json!({
            "anchorCount": facts.anchor_count,
            "days": facts.days.iter().map(|day| serde_json::json!({
                "start": day.start, "end": day.end, "wallDay": day.wall_day,
                "weekend": day.weekend, "weekday": day.weekday, "date": day.date,
                "segments": day.segments.iter().map(|s| serde_json::json!({
                    "start": s.start, "end": s.end, "offsetSeconds": s.offset_seconds
                })).collect::<Vec<_>>()
            })).collect::<Vec<_>>()
        });
        serde_json::json!({
            "participants": request.participants.iter().map(|p| serde_json::json!({
                "availability": p.availability, "workingWeekdays": p.working_weekdays,
                "vacations": p.vacations.iter().map(|v| serde_json::json!({
                    "startDate": v.start_date, "endDate": v.end_date
                })).collect::<Vec<_>>(), "calendar": calendar(&p.calendar)
            })).collect::<Vec<_>>(),
            "occurrences": request.occurrences.iter().map(|o| serde_json::json!({
                "from": o.from, "rangeEnd": o.range_end
            })).collect::<Vec<_>>(),
            "durationMinutes": request.duration_minutes, "maxStretchMinutes": request.max_stretch_minutes,
            "localCalendar": calendar(&request.local_calendar)
        })
    }

    fn old_fields(mut value: Value) -> Value {
        value.as_object_mut().unwrap().remove("weightedSpread");
        for total in value["totals"].as_array_mut().unwrap() {
            let total = total.as_object_mut().unwrap();
            total.remove("weightedMinutes");
            total.remove("nightMinutes");
        }
        for occurrence in value["occurrences"].as_array_mut().unwrap() {
            occurrence.as_object_mut().unwrap().remove("cost");
        }
        value
    }

    fn assert_old_rotation(request: &RotateRequest) {
        let expected = old_fields(serde_json::to_value(legacy_rotate(request.clone()).unwrap()).unwrap());
        let mut payload = rotation_payload(request);
        for explicit in [false, true] {
            if explicit {
                payload["split"] = serde_json::json!("rotate");
                payload["clockWeight"] = serde_json::json!("off");
            }
            let result = dispatch("planner.rotate", payload.clone()).unwrap();
            for occurrence in result["occurrences"].as_array().unwrap() {
                assert_eq!(occurrence["cost"], occurrence["stretch"]);
            }
            for total in result["totals"].as_array().unwrap() {
                assert_eq!(total["weightedMinutes"], total["outsideMinutes"]);
            }
            assert_eq!(result["weightedSpread"], result["spreadMinutes"]);
            assert_eq!(old_fields(result), expected);
        }
    }

    fn rotation(participants: Vec<Schedule>, occurrences: Vec<Occurrence>, cap: i64) -> Rotation {
        let request = rotation_request(participants, occurrences, cap);
        assert_old_rotation(&request);
        rotate(request).unwrap()
    }

    #[test]
    fn rotation_off_and_rotate_equal_the_old_result() {
        let cities = || vec![
            zone_schedule(-25_200, 22, vec![]),
            zone_schedule(3_600, 22, vec![]),
            zone_schedule(32_400, 22, vec![]),
        ];
        assert_old_rotation(&rotation_request(cities(), weekly(3), 480));
        assert_old_rotation(&rotation_request(vec![zone_schedule(-25_200, 22, vec![]),
            zone_schedule(-14_400, 22, vec![])], weekly(2), 480));
        let mut holiday = cities();
        holiday[2].vacations.push(Vacation { start_date: "00107".to_owned(), end_date: "00108".to_owned() });
        assert_old_rotation(&rotation_request(holiday, weekly(3), 480));
        assert_old_rotation(&rotation_request(vec![], weekly(2), 480));
        // 与原性质测试同一批随机请求，包含换钟、休假、跨午夜和不同上限。
        let mut rng = Xor(0x0DDB_1A5E_5EED_0002);
        let offsets = [-28_800, -18_000, 0, 3_600, 19_800, 32_400, 37_800];
        let base = 1_789_000_000.0_f64 - 1_789_000_000.0_f64.rem_euclid(DAY);
        for _ in 0..300 {
            let day_count = 4 + rng.below(5) as usize;
            let participants = random_participants(&mut rng, day_count, base, &offsets);
            let local_calendar = participants[0].calendar.clone();
            let duration_minutes = 15 * (1 + rng.below(16)) as i64;
            let max_stretch_minutes = 15 * rng.below(33) as i64;
            let occurrences = local_calendar.days.iter().take(day_count - 1).filter_map(|day| {
                if rng.below(3) == 0 {
                    None
                } else {
                    Some(Occurrence { from: day.start + (rng.below(8) * 900) as f64, range_end: day.end })
                }
            }).collect();
            assert_old_rotation(&RotateRequest { participants, occurrences, duration_minutes,
                max_stretch_minutes, local_calendar, split: "rotate".to_owned(), clock_weight: "off".to_owned() });
        }
    }

    #[test]
    fn clock_weight_moves_the_small_hours_to_whoever_has_evening_instead() {
        let calendar = CalendarFacts { days: zone_days(0, 1), anchor_count: 3 };
        assert_eq!(minute_cost(WALL0 + 30.0 * 60.0, 60, &calendar, "gentle"), (120, 60));
        assert_eq!(minute_cost(WALL0 + 30.0 * 60.0, 60, &calendar, "strong"), (180, 60));
        assert_eq!(minute_cost(WALL0 + 1290.0 * 60.0, 60, &calendar, "gentle"), (75, 0));
        let cities = vec![zone_schedule(-25_200, 43, vec![]), zone_schedule(3_600, 43, vec![]),
            zone_schedule(32_400, 43, vec![])];
        let mut request = rotation_request(cities, weekly(6), 480);
        request.local_calendar = request.participants[0].calendar.clone();
        let off = rotate(request.clone()).unwrap();
        request.clock_weight = "gentle".to_owned();
        let gentle = rotate(request.clone()).unwrap();
        let london_nights = off.occurrences.iter().filter(|o| {
            let minute = ((o.window.as_ref().unwrap().best - WALL0 + 3_600.0) / 60.0) as i64;
            (60..120).contains(&minute.rem_euclid(1440))
        }).count();
        assert!(london_nights >= 2);
        assert_eq!(off.totals[1].outside_minutes, off.totals[2].outside_minutes);
        assert_eq!(off.totals[2].night_minutes, 0);
        for occurrence in off.occurrences.iter().filter(|o| o.stretch[2] > 0) {
            let minute = ((occurrence.window.as_ref().unwrap().best - WALL0 + 32_400.0) / 60.0) as i64;
            assert!((18 * 60..22 * 60).contains(&minute.rem_euclid(1440)));
        }
        assert!(gentle.totals[1].night_minutes < off.totals[1].night_minutes);
        eprintln!("[clock weight] off {:?}; gentle {:?}", off.totals, gentle.totals);
        let schedules: Vec<_> = request.participants.iter().map(intervals).collect();
        let weighted_old: Vec<i64> = (0..3).map(|person| off.occurrences.iter().filter_map(|o| o.window.clone())
            .map(|window| rotation_candidate(window, &request, &schedules).cost[person]).sum()).collect();
        let old_spread = weighted_old.iter().max().unwrap() - weighted_old.iter().min().unwrap();
        assert!(gentle.weighted_spread < old_spread);
        let sums: Vec<_> = (0..3).map(|person| gentle.occurrences.iter().map(|o| o.cost[person]).sum::<i64>()).collect();
        assert_eq!(sums, gentle.totals.iter().map(|t| t.weighted_minutes).collect::<Vec<_>>());
        assert_eq!(gentle.weighted_spread, sums.iter().max().unwrap() - sums.iter().min().unwrap());
        eprintln!("[clock weight] old windows weighted totals {weighted_old:?}, spread {old_spread}; new spread {}", gentle.weighted_spread);
    }

    #[test]
    fn clock_weight_counts_the_selected_outside_part_and_day_boundaries() {
        let calendar = CalendarFacts { days: zone_days(0, 1), anchor_count: 3 };
        let charge = |working: (i64, i64), meeting: (i64, i64), weighting: &str| {
            let schedule = vec![Interval { start: WALL0 + working.0 as f64 * 60.0,
                end: WALL0 + working.1 as f64 * 60.0 }];
            let start = WALL0 + meeting.0 as f64 * 60.0;
            let end = WALL0 + meeting.1 as f64 * 60.0;
            let (fit, _) = evaluate(start, end, &schedule, 480);
            assert_eq!(fit.kind, 1);
            let window = Window { tier: 1, start, end, best: start,
                duration_minutes: meeting.1 - meeting.0, score: 0.0, fits: vec![fit] };
            let mut request = rotation_request(vec![zone_schedule(0, 1, vec![])], vec![], 480);
            request.clock_weight = weighting.to_owned();
            let got = rotation_candidate(window, &request, &[schedule]);
            (got.cost[0], got.night[0])
        };
        assert_eq!(charge((90, 540), (30, 90), "gentle"), (120, 60));
        assert_eq!(charge((90, 540), (30, 90), "strong"), (180, 60));
        assert_eq!(charge((0, 30), (30, 90), "gentle"), (120, 60));
        assert_eq!(charge((1170, 1290), (1290, 1350), "gentle"), (75, 0));
        // 两侧都越界，只计较长的一侧；等长时取前侧。
        assert_eq!(charge((90, 105), (60, 150), "gentle"), (90, 45));
        assert_eq!(charge((360, 375), (315, 420), "gentle"), (90, 45));
        assert_eq!(charge((360, 375), (315, 420), "off"), (45, 45));
        assert_eq!(minute_cost(WALL0 + 360.0 * 60.0, 2, &calendar, "gentle"), (3, 0));
        assert_eq!(minute_cost(WALL0 + 359.0 * 60.0, 2, &calendar, "gentle"), (3, 1));
        assert_eq!(minute_cost(WALL0 + 1439.0 * 60.0, 2, &calendar, "gentle"), (4, 1));
        let missing = CalendarFacts { days: vec![], anchor_count: 0 };
        assert_eq!(minute_cost(WALL0, 60, &missing, "strong"), (60, 0));
        // 换钟日按距真实日首的分钟计，偏移段不改这把尺。
        let shifted = CalendarFacts { days: vec![day(0.0, 82800.0, 0.0,
            &[(0.0, 7200.0, 0), (7200.0, 82800.0, 3600)])], anchor_count: 1 };
        assert_eq!(minute_cost(359.0 * 60.0, 2, &shifted, "gentle"), (3, 1));
        assert_eq!(minute_cost(82800.0, 2, &shifted, "strong"), (2, 0));
    }

    #[test]
    fn share_takes_the_smallest_worst_case_each_time() {
        let mut request = rotation_request(vec![zone_schedule(-25_200, 43, vec![]),
            zone_schedule(3_600, 43, vec![]), zone_schedule(32_400, 43, vec![])], weekly(6), 480);
        request.local_calendar = request.participants[0].calendar.clone();
        request.split = "share".to_owned();
        for weighting in ["off", "gentle", "strong"] {
            request.clock_weight = weighting.to_owned();
            let result = rotate(request.clone()).unwrap();
            let schedules: Vec<_> = request.participants.iter().map(intervals).collect();
            for (occurrence, got) in request.occurrences.iter().zip(&result.occurrences) {
                let slots = enumerate_slots(&request.participants, &schedules, &request.local_calendar,
                    occurrence.from, occurrence.range_end, request.duration_minutes, request.max_stretch_minutes,
                    &[occurrence.from], None).unwrap();
                let chosen = (got.cost.iter().copied().max().unwrap_or(0), got.cost.iter().sum::<i64>());
                let score = got.window.as_ref().unwrap().score;
                for window in group_windows(&slots, request.duration_minutes, ROTATION_CANDIDATES) {
                    let candidate = rotation_candidate(window, &request, &schedules);
                    let key = (candidate.cost.iter().copied().max().unwrap_or(0), candidate.cost.iter().sum::<i64>());
                    assert!(chosen <= key);
                    if chosen == key { assert!(score >= candidate.window.score); }
                }
            }
            // 删去前几次不会改变剩下每次的选择。
            let mut tail = request.clone();
            tail.occurrences = tail.occurrences.into_iter().skip(3).collect();
            let tail = rotate(tail).unwrap();
            for (a, b) in result.occurrences.iter().skip(3).zip(&tail.occurrences) {
                assert_eq!(a.window.as_ref().unwrap().best, b.window.as_ref().unwrap().best);
                assert_eq!(a.cost, b.cost);
            }
        }
    }

    #[test]
    fn three_continents_share_the_night_shift_instead_of_one_city_taking_it_every_week() {
        // Los Angeles, London (BST) and Tokyo, all 9–18: nothing fits everyone, and any fixed weekly
        // slot leaves one city 7–8 hours outside its day every single week.
        let cities = vec![
            zone_schedule(-25_200, 22, vec![]),
            zone_schedule(3_600, 22, vec![]),
            zone_schedule(32_400, 22, vec![]),
        ];
        let result = rotation(cities, weekly(3), 480);
        assert!(result.needed);
        assert_eq!(result.skipped, 0);
        assert!(result.occurrences.iter().all(|o| o.window.is_some()));
        // The burden really rotates: everyone sits outside their hours at least once…
        assert!(result.totals.iter().all(|t| t.outside_count >= 1), "{:?}", result.totals);
        // …and nobody carries three weeks of it alone (a fixed slot would give one city 1,260+ min).
        let heaviest = result.totals.iter().map(|t| t.outside_minutes).max().unwrap();
        assert!(heaviest <= 600, "{:?}", result.totals);
        assert!(result.spread_minutes <= 240, "spread {}", result.spread_minutes);
        // Each occurrence stays inside the cap for every participant.
        for occurrence in &result.occurrences {
            assert!(occurrence.stretch.iter().all(|m| *m <= 480));
            let window = occurrence.window.as_ref().unwrap();
            assert!(window.start >= occurrence.from && window.best + 3600.0 <= occurrence.from + DAY);
        }
        // Deterministic: the same request gives the same schedule.
        let again = rotation(
            vec![
                zone_schedule(-25_200, 22, vec![]),
                zone_schedule(3_600, 22, vec![]),
                zone_schedule(32_400, 22, vec![]),
            ],
            weekly(3),
            480,
        );
        let picks = |r: &Rotation| r.occurrences.iter().map(|o| o.window.as_ref().map(|w| w.best)).collect::<Vec<_>>();
        assert_eq!(picks(&result), picks(&again));
    }

    /// 拆成 N 场：用与轮换同一套多时区夹具（zone_schedule 的偏移就是各人本地 9–18）。
    fn split_request(participants: Vec<Schedule>, sessions: i64) -> SplitRequest {
        // 组织者（洛杉矶 UTC−7）的两个民用日。
        let from = WALL0 + 25_200.0;
        SplitRequest {
            participants,
            from,
            range_end: from + 2.0 * DAY,
            duration_minutes: 60,
            sessions,
            local_calendar: CalendarFacts {
                days: zone_days(-25_200, 3),
                anchor_count: 5,
            },
            scoring_day_starts: vec![from, from + DAY],
        }
    }

    #[test]
    fn three_sessions_cover_three_continents_that_have_no_common_hour() {
        // 洛杉矶（−7）、伦敦（+1）、东京（+9）各自 9–18：没有一个时刻三人都在时段内（轮换那条测试已证）。
        let people = || {
            vec![
                zone_schedule(-25_200, 3, vec![]),
                zone_schedule(3_600, 3, vec![]),
                zone_schedule(32_400, 3, vec![]),
            ]
        };
        let result = split(split_request(people(), 3)).unwrap();
        assert!(result.needed);
        assert_eq!(result.sessions.len(), 3);
        // 每人至少有一场在自己的工作时段内。
        assert_eq!(result.covered, vec![true, true, true]);
        assert!(result.uncovered.is_empty());
        for person in 0..3 {
            assert!(
                result.sessions.iter().any(|session| session.inside.contains(&person)),
                "第 {person} 个人一场都不在时段内：{:?}",
                result.sessions.iter().map(|s| s.inside.clone()).collect::<Vec<_>>()
            );
        }
        // 场次按时间先后编号、互不重叠。
        let mut previous = f64::MIN;
        for (position, session) in result.sessions.iter().enumerate() {
            assert_eq!(session.index, position + 1);
            assert!(session.start >= previous, "场次没有按时间排序");
            previous = session.end;
        }
        // 同一份请求给同一个答案（确定性）。
        let again = split(split_request(people(), 3)).unwrap();
        assert_eq!(
            result.sessions.iter().map(|s| s.start).collect::<Vec<_>>(),
            again.sessions.iter().map(|s| s.start).collect::<Vec<_>>()
        );
        // 两场时至少覆盖两个人。
        let two = split(split_request(people(), 2)).unwrap();
        assert_eq!(two.sessions.len(), 2);
        assert!(two.covered.iter().filter(|x| **x).count() >= 2);
    }

    #[test]
    fn one_slot_for_everyone_means_no_need_to_split() {
        // 洛杉矶与纽约每天共有 09:00–15:00 太平洋时间：一场就够，不给场次。
        let result = split(split_request(
            vec![zone_schedule(-25_200, 3, vec![]), zone_schedule(-14_400, 3, vec![])],
            3,
        ))
        .unwrap();
        assert!(!result.needed);
        assert!(result.sessions.is_empty());
        assert_eq!(result.covered, vec![true, true]);
    }

    #[test]
    fn a_bad_session_count_falls_back_to_two_and_an_empty_range_gives_nothing() {
        // 9–18 的任意两地都还有一小时能碰上（东京与洛杉矶是 UTC 0–1，伦敦与东京是 UTC 8–9，
        // 伦敦与洛杉矶是 UTC 16–17；两次选错人之后记在这里），真正没有共同时刻的是三地一起。
        let people = || {
            vec![
                zone_schedule(-25_200, 3, vec![]),
                zone_schedule(3_600, 3, vec![]),
                zone_schedule(32_400, 3, vec![]),
            ]
        };
        // 7 不在封闭选项（2 / 3）里 → 按 2 场算。
        let seven = split(split_request(people(), 7)).unwrap();
        assert_eq!(seven.sessions.len(), 2);
        // 空范围 → 没有场次，所有人都算未覆盖。
        let mut request = split_request(people(), 2);
        request.range_end = request.from;
        let empty = split(request).unwrap();
        assert!(empty.sessions.is_empty());
        assert_eq!(empty.uncovered, vec![0, 1, 2]);
        assert!(empty.needed);
    }

    #[test]
    fn overlapping_cities_need_no_rotation_and_report_zero_stretch() {
        // Los Angeles and New York (EDT) share 09:00–15:00 Pacific every day.
        let result = rotation(
            vec![zone_schedule(-25_200, 22, vec![]), zone_schedule(-14_400, 22, vec![])],
            weekly(2),
            480,
        );
        assert!(!result.needed);
        assert_eq!(result.spread_minutes, 0);
        assert!(result.totals.iter().all(|t| t.outside_minutes == 0 && t.outside_count == 0));
        assert!(result.occurrences.iter().all(|o| o.window.as_ref().map(|w| w.tier) == Some(0)));
    }

    #[test]
    fn a_holiday_skips_that_occurrence_without_charging_anyone_for_it() {
        // Tokyo is away on the organizer's second occurrence (its civil days "00107" and "00108").
        let cities = vec![
            zone_schedule(-25_200, 22, vec![]),
            zone_schedule(3_600, 22, vec![]),
            zone_schedule(
                32_400,
                22,
                vec![Vacation {
                    start_date: "00107".to_owned(),
                    end_date: "00108".to_owned(),
                }],
            ),
        ];
        let result = rotation(cities, weekly(3), 480);
        assert_eq!(result.skipped, 1);
        assert!(result.occurrences[1].window.is_none());
        assert!(result.occurrences[1].stretch.iter().all(|m| *m == 0));
        assert!(result.occurrences[0].window.is_some() && result.occurrences[2].window.is_some());
        let charged: i64 = result.totals.iter().map(|t| t.outside_count).sum();
        let held: i64 = result
            .occurrences
            .iter()
            .filter_map(|o| o.window.as_ref())
            .map(|w| w.fits.iter().filter(|f| f.kind == 1).count() as i64)
            .sum();
        assert_eq!(charged, held);
    }

    #[test]
    fn rotation_with_nothing_to_schedule_is_empty_and_the_plan_refactor_kept_its_output() {
        let result = rotation(vec![], weekly(2), 480);
        assert!(!result.needed && result.occurrences.is_empty() && result.skipped == 2);
        let a = day(0.0, 86_400.0, 0.0, &[(0.0, 86_400.0, 0)]);
        let request = PlanRequest {
            participants: vec![schedule(540, 1080, vec![a.clone()], 1), schedule(600, 1020, vec![a.clone()], 1)],
            from: 0.0,
            range_end: 86_400.0,
            duration_minutes: 60,
            tolerance_minutes: 0,
            limit: 8,
            local_calendar: CalendarFacts { days: vec![a], anchor_count: 1 },
            scoring_day_starts: vec![0.0],
            ideal_start_minute: None,
            ideal_end_minute: None,
        };
        let windows = plan(request).unwrap();
        assert_eq!((windows.len(), windows[0].start, windows[0].end), (1, 36_000.0, 61_200.0));
    }

    // MARK: - 性质测试：随机日历与作息下，每个返回窗口都经得起逐分钟核对

    struct Xor(u64);
    impl Xor {
        fn next(&mut self) -> u64 {
            let mut x = self.0;
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            self.0 = x;
            x
        }
        fn below(&mut self, n: u64) -> u64 {
            self.next() % n.max(1)
        }
    }

    fn random_participants(rng: &mut Xor, day_count: usize, base: f64, offsets: &[i64]) -> Vec<Schedule> {
        let participant_count = 1 + rng.below(4) as usize;
        let mut participants = Vec::new();
        for _ in 0..participant_count {
            let offset = offsets[rng.below(offsets.len() as u64) as usize];
            let dst_day = if rng.below(3) == 0 { Some(rng.below(day_count as u64) as usize) } else { None };
            let mut days = Vec::new();
            let mut offset_now = offset;
            for d in 0..day_count {
                let wall = base + d as f64 * 86_400.0;
                let weekday = (((wall / 86_400.0) as i64 + 4).rem_euclid(7) + 1) as u32; // 1 = 周日
                let date = format!("2026-09-{:02}", 1 + d);
                // 平常一天一段；夏令时那天在当地 2:00 换偏移，前段旧偏移、后段新偏移；天与天首尾相接（真实日历如此）。
                let start = wall - offset_now as f64;
                let (segments, end) = if dst_day == Some(d) {
                    let shift = if rng.below(2) == 0 { 3_600 } else { -3_600 };
                    let split = wall + 7_200.0 - offset_now as f64;
                    let before = offset_now;
                    offset_now += shift;
                    let e = wall + 86_400.0 - offset_now as f64;
                    (vec![OffsetSegment { start, end: split, offset_seconds: before },
                          OffsetSegment { start: split, end: e, offset_seconds: offset_now }], e)
                } else {
                    let e = wall + 86_400.0 - offset_now as f64;
                    (vec![OffsetSegment { start, end: e, offset_seconds: offset_now }], e)
                };
                days.push(Day { start, end, wall_day: wall, weekend: weekday == 1 || weekday == 7, weekday, date, segments });
            }
            let (start_minute, end_minute) = match rng.below(5) {
                0 => { let m = rng.below(1440) as i64; (m, m) }
                1 => (0, 1440),
                2 => { let a = 900 + rng.below(540) as i64; (a, rng.below(600) as i64) } // 跨午夜
                _ => { let a = rng.below(1380) as i64; (a, a + 15 + rng.below((1440 - a - 15).max(1) as u64) as i64) }
            };
            let working_weekdays = if rng.below(3) == 0 {
                Some((1..=7).filter(|_| rng.below(3) != 0).collect::<Vec<u32>>())
            } else { None };
            let vacations = if rng.below(4) == 0 {
                let a = 1 + rng.below(day_count as u64) as usize;
                let b = a + rng.below(2) as usize;
                vec![Vacation { start_date: format!("2026-09-{a:02}"), end_date: format!("2026-09-{b:02}") }]
            } else { vec![] };
            participants.push(Schedule {
                availability: Availability { start_minute, end_minute, weekdays_only: rng.below(2) == 0 },
                working_weekdays,
                vacations,
                calendar: CalendarFacts { days, anchor_count: day_count - 1 },
            });
        }

        participants
    }

    /// 与 `intervals` 无关的另一种算法：某一瞬间 `t` 这个人在不在工作时段里，按「t 落在哪一天的哪一段偏移、
    /// 折成当地分钟、再按作息规则判」逐点算。跨午夜班次的后半段只在次日没被挡住时算数。
    fn available_at(schedule: &Schedule, t: f64) -> bool {
        let a = schedule.availability.normalized();
        let rules = a.rules();
        let days = &schedule.calendar.days;
        let anchors = schedule.calendar.anchor_count;
        for (index, day) in days.iter().enumerate() {
            let Some(segment) = day.segments.iter().find(|s| s.start <= t && t < s.end) else { continue };
            let minute = ((t - day.wall_day) / 60.0 + segment.offset_seconds as f64 / 60.0).floor() as i64;
            let starts_here = index < anchors && can_start_shift(schedule, day);
            if rules.is_whole_day {
                return starts_here;
            }
            if !rules.crosses_midnight {
                return starts_here && a.start_minute <= minute && minute < a.end_minute;
            }
            if starts_here && minute >= a.start_minute {
                return true;
            }
            let from_previous = index > 0
                && index - 1 < anchors
                && can_start_shift(schedule, &days[index - 1])
                && !blocked_day(schedule, day)
                && minute < a.end_minute;
            return from_previous;
        }
        false
    }

    /// 会议 [start, end) 整段都在时段里（逐分钟）。
    fn inside(schedule: &Schedule, start: f64, end: f64) -> bool {
        let mut t = start;
        while t < end {
            if !available_at(schedule, t) {
                return false;
            }
            t += 60.0;
        }
        true
    }

    #[test]
    fn random_calendars_every_window_survives_minute_by_minute_checks() {
        let iterations: u64 = std::env::var("MEANTIME_FUZZ_ITERATIONS").ok().and_then(|v| v.parse().ok()).unwrap_or(300);
        let seed_offset: u64 = std::env::var("MEANTIME_FUZZ_SEED").ok().and_then(|v| v.parse().ok()).unwrap_or(0);
        let mut rng = Xor(0x0DDB_1A5E_5EED_0001_u64.wrapping_add(seed_offset));
        let offsets: [i64; 7] = [-28_800, -18_000, 0, 3_600, 19_800, 32_400, 37_800];
        let base = 1_789_000_000.0_f64 - 1_789_000_000.0_f64.rem_euclid(86_400.0); // 某个 UTC 午夜
        let mut checked_windows = 0usize;
        for i in 0..iterations {
            let day_count = 4 + rng.below(5) as usize;
            let participants = random_participants(&mut rng, day_count, base, &offsets);
            let local_calendar = participants[0].calendar.clone();
            let from = local_calendar.days[0].start + (rng.below(96) * 900) as f64;
            let range_end = from + 3_600.0 + (rng.below((day_count as u64 - 1) * 96) * 900) as f64;
            let duration_minutes = 15 * (1 + rng.below(16)) as i64;
            let tolerance_minutes = 15 * rng.below(13) as i64;
            let scoring_day_starts: Vec<f64> = local_calendar.days.iter().map(|d| d.start).collect();
            let request = PlanRequest {
                participants,
                from, range_end, duration_minutes, tolerance_minutes, limit: 10_000,
                local_calendar, scoring_day_starts, ideal_start_minute: None, ideal_end_minute: None,
            };
            let participants = &request.participants;
            let duration = duration_minutes as f64 * 60.0;
            let windows = plan(PlanRequest {
                participants: participants.clone(), from, range_end, duration_minutes, tolerance_minutes,
                limit: 10_000, local_calendar: request.local_calendar.clone(), scoring_day_starts: request.scoring_day_starts.clone(),
                ideal_start_minute: None, ideal_end_minute: None,
            }).unwrap_or_else(|e| panic!("#{i} plan 出错：{e}"));
            let mut covered_starts: Vec<f64> = Vec::new();
            for w in &windows {
                checked_windows += 1;
                assert_eq!(w.duration_minutes, duration_minutes, "#{i}");
                assert!(w.start >= from && w.end <= range_end + 0.5, "#{i} 窗口 {}–{} 出了范围 {from}–{range_end}", w.start, w.end);
                assert!((w.start / 900.0).fract() == 0.0, "#{i} 起点不在 15 分钟格上");
                assert!(w.best >= w.start && w.best + duration <= w.end + 0.5, "#{i} best 不在窗口里");
                assert_eq!(w.fits.len(), participants.len(), "#{i}");
                let worst = w.fits.iter().map(|f| f.kind).max().unwrap_or(0);
                assert!(worst < 2, "#{i} 返回了没人能到的窗口");
                assert_eq!(w.tier, worst, "#{i} tier 与各人 fit 不一致");
                // 逐个可开会的起点、逐个人核：kind 0 = 整段在时段里；kind 1 = 不在但不超过容忍；且当天没被挡。
                let mut t = w.start;
                while t + duration <= w.end + 0.5 {
                    covered_starts.push(t);
                    for (p, participant) in participants.iter().enumerate() {
                        let blocked = participant.calendar.days.iter().any(|day|
                            blocked_day(participant, day) && t < day.end && t + duration > day.start);
                        assert!(!blocked, "#{i} 窗口撞上了第 {p} 人被挡的一天");
                        let fit = w.fits[p];
                        let is_inside = inside(participant, t, t + duration);
                        if fit.kind == 0 {
                            // 同组窗口里每个起点都应是全员在时段内（分组按 fit 种类，不按具体分钟）。
                            assert!(is_inside, "#{i} 第 {p} 人 fit=0 但 {t} 起的会不全在时段里：{:?} {:?}", participant.availability, participant.working_weekdays);
                        } else {
                            assert!(fit.outside_minutes > 0 && fit.outside_minutes <= tolerance_minutes,
                                "#{i} 第 {p} 人 fit=1 的时段外分钟 {} 越界（容忍 {tolerance_minutes}）", fit.outside_minutes);
                        }
                    }
                    t += 900.0;
                }
            }
            // 完整性：网格上每个全员都在时段内、没人被挡的起点，都得在某个 tier 0 窗口里。
            let mut t = (from / 900.0).ceil() * 900.0;
            while t + duration <= range_end {
                let everyone = participants.iter().all(|p| inside(p, t, t + duration)
                    && !p.calendar.days.iter().any(|day| blocked_day(p, day) && t < day.end && t + duration > day.start));
                if everyone {
                    let hit = windows.iter().any(|w| w.tier == 0 && w.start <= t && t + duration <= w.end + 0.5);
                    assert!(hit, "#{i} 起点 {t} 全员可到却没进任何 tier 0 窗口（from {from} range_end {range_end} dur {duration_minutes}）");
                }
                t += 900.0;
            }
            let _ = covered_starts;
        }
        assert!(checked_windows > 0, "随机日历一个窗口都没产生，生成器有问题");
        eprintln!("[planner property] {iterations} 份随机请求，核过 {checked_windows} 个窗口");
    }

    /// 例会轮换的账必须自洽：每次发生的窗口在自己那天的范围里、各人「时段外分钟」与 fit 一致且不超上限、
    /// 总账等于逐次相加、极差与 needed / skipped 按定义算；只要那天存在全员都在时段内的起点，选出来的就
    /// 不该让任何人在时段外（加零对公平键最优）。
    #[test]
    fn random_rotations_keep_their_books_straight() {
        let iterations: u64 = std::env::var("MEANTIME_FUZZ_ITERATIONS").ok().and_then(|v| v.parse().ok()).unwrap_or(300);
        let seed_offset: u64 = std::env::var("MEANTIME_FUZZ_SEED").ok().and_then(|v| v.parse().ok()).unwrap_or(0);
        let mut rng = Xor(0x0DDB_1A5E_5EED_0002_u64.wrapping_add(seed_offset));
        let offsets: [i64; 7] = [-28_800, -18_000, 0, 3_600, 19_800, 32_400, 37_800];
        let base = 1_789_000_000.0_f64 - 1_789_000_000.0_f64.rem_euclid(86_400.0);
        let mut held = 0usize;
        for i in 0..iterations {
            let day_count = 4 + rng.below(5) as usize;
            let participants = random_participants(&mut rng, day_count, base, &offsets);
            let local_calendar = participants[0].calendar.clone();
            let duration_minutes = 15 * (1 + rng.below(16)) as i64;
            let max_stretch_minutes = 15 * rng.below(33) as i64;
            let duration = duration_minutes as f64 * 60.0;
            // 每次发生 = 组织者日历里的一天（可能隔天），oldest first。
            let mut occurrences: Vec<Occurrence> = Vec::new();
            for day in local_calendar.days.iter().take(day_count - 1) {
                if rng.below(3) != 0 {
                    occurrences.push(Occurrence { from: day.start + (rng.below(8) * 900) as f64, range_end: day.end });
                }
            }
            let count = participants.len();
            let rotation = rotate(RotateRequest {
                participants: participants.clone(),
                occurrences: occurrences.iter().map(|o| Occurrence { from: o.from, range_end: o.range_end }).collect(),
                duration_minutes, max_stretch_minutes, local_calendar: local_calendar.clone(),
                split: "rotate".to_owned(), clock_weight: "off".to_owned(),
            }).unwrap_or_else(|e| panic!("#{i} rotate 出错：{e}"));
            assert_eq!(rotation.occurrences.len(), occurrences.len(), "#{i}");
            assert_eq!(rotation.totals.len(), count, "#{i}");
            let mut sums = vec![0i64; count];
            let mut counts = vec![0i64; count];
            let mut skipped = 0;
            for (k, (occ, got)) in occurrences.iter().zip(&rotation.occurrences).enumerate() {
                assert_eq!(got.index, k, "#{i}");
                assert_eq!(got.from, occ.from, "#{i}");
                assert_eq!(got.stretch.len(), count, "#{i}");
                let Some(window) = &got.window else {
                    skipped += 1;
                    assert!(got.stretch.iter().all(|&m| m == 0), "#{i} 没开会却记了时段外分钟");
                    // 跳过的那次：那天不该存在全员可到（含容忍）的起点——至少不该有全员在时段内的起点。
                    let mut t = (occ.from / 900.0).ceil() * 900.0;
                    while t + duration <= occ.range_end {
                        let everyone = participants.iter().all(|p| inside(p, t, t + duration)
                            && !p.calendar.days.iter().any(|day| blocked_day(p, day) && t < day.end && t + duration > day.start));
                        assert!(!everyone, "#{i} 第 {k} 次被跳过，但 {t} 起全员都在时段内");
                        t += 900.0;
                    }
                    continue;
                };
                held += 1;
                assert!(window.start >= occ.from && window.end <= occ.range_end + 0.5, "#{i} 第 {k} 次窗口出了那天的范围");
                assert_eq!(window.duration_minutes, duration_minutes, "#{i}");
                assert_eq!(window.fits.len(), count, "#{i}");
                assert_eq!(got.stretch, stretch_of(window), "#{i} stretch 与 fit 不一致");
                for (p, (participant, fit)) in participants.iter().zip(&window.fits).enumerate() {
                    assert!(fit.kind < 2, "#{i} 第 {k} 次第 {p} 人到不了");
                    let blocked = participant.calendar.days.iter().any(|day|
                        blocked_day(participant, day) && window.best < day.end && window.best + duration > day.start);
                    assert!(!blocked, "#{i} 第 {k} 次撞上第 {p} 人被挡的一天");
                    if fit.kind == 0 {
                        assert!(inside(participant, window.best, window.best + duration), "#{i} 第 {k} 次第 {p} 人 fit=0 却不在时段里");
                        assert_eq!(got.stretch[p], 0, "#{i}");
                    } else {
                        assert!(got.stretch[p] > 0 && got.stretch[p] <= max_stretch_minutes, "#{i} 第 {k} 次第 {p} 人时段外 {} 越过上限 {max_stretch_minutes}", got.stretch[p]);
                        assert!(!inside(participant, window.best, window.best + duration), "#{i} 第 {k} 次第 {p} 人明明在时段里却记了时段外分钟");
                    }
                    sums[p] += got.stretch[p];
                    if got.stretch[p] > 0 { counts[p] += 1; }
                }
                // 那天若有全员都在时段内的起点，选出来的就不该让任何人在时段外。
                let mut t = (occ.from / 900.0).ceil() * 900.0;
                let mut everyone_possible = false;
                while t + duration <= occ.range_end {
                    if participants.iter().all(|p| inside(p, t, t + duration)
                        && !p.calendar.days.iter().any(|day| blocked_day(p, day) && t < day.end && t + duration > day.start)) {
                        everyone_possible = true;
                        break;
                    }
                    t += 900.0;
                }
                if everyone_possible {
                    assert!(got.stretch.iter().all(|&m| m == 0), "#{i} 第 {k} 次有全员可到的起点，却选了让人在时段外的 {:?}", got.stretch);
                }
            }
            for p in 0..count {
                assert_eq!(rotation.totals[p].outside_minutes, sums[p], "#{i} 第 {p} 人总账");
                assert_eq!(rotation.totals[p].outside_count, counts[p], "#{i} 第 {p} 人次数");
            }
            let heaviest = sums.iter().copied().max().unwrap_or(0);
            let lightest = sums.iter().copied().min().unwrap_or(0);
            assert_eq!(rotation.spread_minutes, heaviest - lightest, "#{i} 极差");
            assert_eq!(rotation.needed, heaviest > 0, "#{i} needed");
            assert_eq!(rotation.skipped, skipped, "#{i} skipped");
        }
        assert!(held > 0, "随机轮换一次会都没排出，生成器有问题");
        eprintln!("[rotation property] {iterations} 份随机请求，核过 {held} 次发生");
    }

    // MARK: options for one meeting (the find-a-meeting page)

    /// 候选单的请求：组织者在洛杉矶（UTC−7），从第 0 天本机零点起看 `days` 天。
    fn options_request(participants: Vec<Schedule>, days: i64, clock_weight: &str) -> OptionsRequest {
        let from = WALL0 + 25_200.0;
        OptionsRequest {
            participants,
            from,
            range_end: from + days as f64 * DAY,
            duration_minutes: 60,
            local_calendar: CalendarFacts { days: zone_days(-25_200, days + 1), anchor_count: (days + 3) as usize },
            scoring_day_starts: (0..=days).map(|k| from + k as f64 * DAY).collect(),
            ideal_start_minute: None,
            ideal_end_minute: None,
            clock_weight: clock_weight.to_owned(),
        }
    }

    fn payers(option: &MeetingOption) -> Vec<usize> {
        option.fits.iter().enumerate().filter(|(_, fit)| fit.kind == 1).map(|(index, _)| index).collect()
    }

    /// 本机钟面上的几点几分（洛杉矶 UTC−7）。
    fn la_minute(time: f64) -> i64 {
        ((time - 25_200.0).floor() as i64).rem_euclid(86_400) / 60
    }

    #[test]
    fn three_continents_get_three_different_ways_to_give_a_little() {
        // 洛杉矶（−7）、伦敦（+1）、东京（+9）各自 9–18：没有大家都在时段内的时刻。
        let cities = || vec![
            zone_schedule(-25_200, 6, vec![]),
            zone_schedule(3_600, 6, vec![]),
            zone_schedule(32_400, 6, vec![]),
        ];
        let result = options(options_request(cities(), 3, "gentle")).unwrap();
        assert!(!result.everyone);
        assert_eq!(result.options.len(), 3, "最接近的三项");
        // 三项是三批不同的人在付，不是同一个钟点排三天。
        let sets: Vec<Vec<usize>> = result.options.iter().map(payers).collect();
        assert_ne!(sets[0], sets[1]);
        assert_ne!(sets[1], sets[2]);
        assert_ne!(sets[0], sets[2]);
        let minutes: Vec<i64> = result.options.iter().map(|o| la_minute(o.best)).collect();
        assert!(minutes[0] != minutes[1] && minutes[1] != minutes[2] && minutes[0] != minutes[2], "{minutes:?}");
        // 两人各让一点比一人整夜熬轻：三项都是两人在付（三种两两组合）。
        for set in &sets {
            assert_eq!(set.len(), 2, "{sets:?}");
        }
        // 从轻到重；每项的负担与它的处境对得上（在时段内的人负担为 0）。
        let totals: Vec<i64> = result.options.iter().map(|o| o.cost.iter().sum()).collect();
        assert!(totals.windows(2).all(|w| w[0] <= w[1]), "{totals:?}");
        for option in &result.options {
            assert_eq!(option.tier, 1);
            assert_eq!(option.end - option.start, 3_600.0);
            for (fit, cost) in option.fits.iter().zip(&option.cost) {
                assert_eq!(fit.kind == 1, *cost > 0, "{:?} {:?}", option.fits, option.cost);
            }
            // 同一个本机钟点、同一批人在付的日子：三天都是（夹具里没有周末）；第一个就是代表的那天。
            assert_eq!(option.days.len(), 3, "{:?}", option.days);
            assert_eq!(option.days[0], option.best);
            assert!(option.days.iter().all(|day| la_minute(*day) == la_minute(option.best)));
        }
        // 确定性。
        let again = options(options_request(cities(), 3, "gentle")).unwrap();
        assert_eq!(
            result.options.iter().map(|o| o.best).collect::<Vec<_>>(),
            again.options.iter().map(|o| o.best).collect::<Vec<_>>()
        );
        // 不加权时总负担按分钟算；最接近的仍是三批不同的人。
        let plain = options(options_request(cities(), 3, "off")).unwrap();
        assert_eq!(plain.options.len(), 3);
        let plain_sets: Vec<Vec<usize>> = plain.options.iter().map(payers).collect();
        assert!(plain_sets[0] != plain_sets[1] && plain_sets[1] != plain_sets[2]);
    }

    #[test]
    fn small_hours_weigh_more_so_the_lightest_burden_avoids_them() {
        // 洛杉矶与东京（+16 小时）：大家都在的只有洛杉矶 17:00 = 东京 9:00；时长两小时就没有了。
        // 加权时最接近的第一项不该让谁落在 0–6 点（凌晨按 2 倍算）。
        let mut request = options_request(vec![zone_schedule(-25_200, 4, vec![]), zone_schedule(32_400, 4, vec![])], 2, "gentle");
        request.duration_minutes = 120;
        let result = options(request).unwrap();
        assert!(!result.everyone);
        let first = &result.options[0];
        let local = |offset: i64| ((first.best + offset as f64).floor() as i64).rem_euclid(86_400) / 60;
        for (index, offset) in [-25_200, 32_400].into_iter().enumerate() {
            if first.fits[index].kind == 1 {
                assert!(local(offset) >= 6 * 60, "第一项让第 {index} 人在 {} 分开会", local(offset));
            }
        }
    }

    #[test]
    fn everyone_fits_one_clock_across_days_and_nobody_is_charged() {
        // 洛杉矶与伦敦：每天洛杉矶 9:00–10:00（伦敦 17:00–18:00）大家都在。三天并成一项。
        let result = options(options_request(
            vec![zone_schedule(-25_200, 6, vec![]), zone_schedule(3_600, 6, vec![])], 3, "gentle")).unwrap();
        assert!(result.everyone);
        assert_eq!(result.options.len(), 1, "同一个钟点的三天是一项");
        let option = &result.options[0];
        assert_eq!(option.tier, 0);
        assert_eq!(la_minute(option.best), 9 * 60);
        assert_eq!(option.days.len(), 3);
        assert_eq!(option.days[0], option.best);
        assert!(option.cost.iter().all(|c| *c == 0));
        assert!(option.fits.iter().all(|fit| fit.kind == 0));
        // 都在时段内的时候不再给「最接近」的：页面只说大家都在的那几项。
        assert!(result.options.iter().all(|o| o.tier == 0));
        // 窗口更宽时（纽约 −4 与洛杉矶共 6 小时）给的是可以开始的范围的外沿，最佳时刻在里面。
        let wide = options(options_request(
            vec![zone_schedule(-25_200, 6, vec![]), zone_schedule(-14_400, 6, vec![])], 1, "gentle")).unwrap();
        assert!(wide.everyone);
        let window = &wide.options[0];
        assert!(window.end - window.start > 3_600.0);
        assert!(window.start <= window.best && window.best + 3_600.0 <= window.end);
        assert!(wide.options.len() <= OPTIONS_EVERYONE);
    }

    #[test]
    fn a_holiday_removes_that_day_from_an_option() {
        // 伦敦第 1 天休假：大家都在的那一项只剩第 0、2 天。
        let vacation = Vacation { start_date: "00101".into(), end_date: "00101".into() };
        let result = options(options_request(
            vec![zone_schedule(-25_200, 6, vec![]), zone_schedule(3_600, 6, vec![vacation])], 3, "gentle")).unwrap();
        assert!(result.everyone);
        assert_eq!(result.options[0].days.len(), 2, "{:?}", result.options[0].days);
    }

    #[test]
    fn options_with_nothing_to_plan_are_empty() {
        assert!(options(options_request(vec![], 3, "gentle")).unwrap().options.is_empty());
        let mut zero = options_request(vec![zone_schedule(-25_200, 6, vec![])], 3, "gentle");
        zero.duration_minutes = 0;
        assert!(options(zero).unwrap().options.is_empty());
        let mut backwards = options_request(vec![zone_schedule(-25_200, 6, vec![])], 3, "gentle");
        backwards.range_end = backwards.from;
        assert!(options(backwards).unwrap().options.is_empty());
        // 走 dispatch：未知的钟点加权当不加权，缺的字段报错不崩。
        assert!(dispatch("planner.options", serde_json::json!({"participants": []})).is_err());
    }

    #[test]
    fn weighted_minutes_equals_the_minute_by_minute_cost() {
        // 夹具里放一天 23 小时、一天 25 小时（换钟），起点与长度随机，三种加权都要与逐分钟的那一个相等。
        let mut days = zone_days(-25_200, 6);
        days[3].end -= 3_600.0;
        for day in days.iter_mut().skip(4) {
            day.start -= 3_600.0;
            day.end -= 3_600.0;
        }
        days[5].end += 3_600.0;
        for day in days.iter_mut().skip(6) {
            day.start += 3_600.0;
            day.end += 3_600.0;
        }
        let calendar = CalendarFacts { anchor_count: days.len(), days };
        let mut rng = Xor(0x5eed_cafe);
        for _ in 0..3_000 {
            let start = WALL0 - DAY + (rng.below(9 * 86_400 / 60) * 60) as f64 + if rng.below(4) == 0 { 30.0 } else { 0.0 };
            let minutes = rng.below(900) as i64;
            for (column, name) in ["off", "gentle", "strong"].into_iter().enumerate() {
                assert_eq!(weighted_minutes(start, minutes, &calendar, column), minute_cost(start, minutes, &calendar, name).0,
                           "start {start} minutes {minutes} weight {name}");
            }
        }
    }

    #[test]
    fn fit_marks_who_is_outside_a_tried_time() {
        let a = vec![Interval { start: 0.0, end: 9.0 * 3_600.0 }];
        let b = vec![Interval { start: 10.0 * 3_600.0, end: 18.0 * 3_600.0 }];
        // 8:30–9:30：第一人超出 30 分钟，第二人早了 90 分钟。
        let fits = fit(FitRequest { intervals: vec![a.clone(), b.clone()], start: 8.5 * 3_600.0, duration_minutes: 60 }).unwrap();
        assert_eq!((fits[0].kind, fits[0].outside_minutes), (1, 30));
        assert_eq!((fits[1].kind, fits[1].outside_minutes), (1, 90));
        let inside = fit(FitRequest { intervals: vec![a, b], start: 3_600.0, duration_minutes: 60 }).unwrap();
        assert_eq!(inside[0].kind, 0);
        // 一个区间都没有（休息日）：离得再远也只说「不可用」。
        let nothing = fit(FitRequest { intervals: vec![vec![]], start: 0.0, duration_minutes: 60 }).unwrap();
        assert_eq!(nothing[0].kind, 2);
        assert!(fit(FitRequest { intervals: vec![], start: 0.0, duration_minutes: 0 }).is_err());
    }
}
