// SPDX-License-Identifier: GPL-3.0-only
//! 各地与本机的「时差变化窗口」：两地不在同一天换钟时，时差会在中间几天变成另一个数
//! （伦敦 10 月底退出夏令时、洛杉矶 11 月初才退，那一周伦敦比洛杉矶只快 7 小时而不是 8）。
//! 输入是 Foundation 给的两条换钟时间线（当前偏移 + 未来转换点），这里只做分段与比较，不带任何时区规则。

use serde::Deserialize;
use serde_json::{json, Value};

const HORIZON: f64 = 400.0 * 86_400.0;

#[derive(Clone, Debug, Deserialize)]
struct Transition {
    at: f64,
    after: i32,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Timeline {
    zone: String,
    offset_now: i32,
    #[serde(default)]
    transitions: Vec<Transition>,
}

fn valid_offset(o: i32) -> bool {
    (-86_399..=86_399).contains(&o)
}

fn valid(tl: &Timeline, now: f64) -> bool {
    !tl.zone.is_empty()
        && tl.zone.len() <= 255
        && !tl.zone.chars().any(char::is_control)
        && valid_offset(tl.offset_now)
        && tl.transitions.len() <= 64
        && tl.transitions.iter().all(|t| t.at.is_finite() && t.at > now && t.at <= now + HORIZON && valid_offset(t.after))
        && tl.transitions.windows(2).all(|w| w[0].at < w[1].at)
}

/// 偏移在时刻 `t`：从当前偏移起，按顺序套用 `at <= t` 的转换。
fn offset_at(tl: &Timeline, t: f64) -> i32 {
    tl.transitions.iter().take_while(|x| x.at <= t).last().map_or(tl.offset_now, |x| x.after)
}

fn changes(local: &Timeline, place: &Timeline, now: f64, horizon: f64) -> Vec<Value> {
    let mut times: Vec<f64> = local
        .transitions
        .iter()
        .chain(place.transitions.iter())
        .map(|t| t.at)
        .filter(|t| *t > now && *t <= now + horizon)
        .collect();
    times.sort_by(f64::total_cmp);
    times.dedup();
    let mut previous = place.offset_now - local.offset_now;
    let mut out = vec![];
    for t in times {
        let diff = offset_at(place, t) - offset_at(local, t);
        let local_moved = local.transitions.iter().any(|x| x.at == t);
        let place_moved = place.transitions.iter().any(|x| x.at == t);
        if diff != previous {
            out.push(json!({"at": t, "from": previous, "to": diff,
                "cause": match (local_moved, place_moved) { (true, true) => "both", (true, false) => "local", _ => "place" }}));
        }
        previous = diff;
    }
    out
}

// MARK: - 一年的时间线（夏令时提醒页的主图）

/// 一个时区从 `origin` 起的偏移：`offset` 是 `origin` 那一刻的偏移，其后按顺序套用 `transitions`。
/// 宿主（Foundation）从「框起点前 400 天」问到「框终点后 400 天以内」，这样框里第一段与最后一段两头的换钟也看得见。
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct YearTimeline {
    zone: String,
    offset: i32,
    #[serde(default)]
    transitions: Vec<Transition>,
}

/// 一段时差的来历：哪一边换了钟让它开始或结束。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Side {
    Local,
    Place,
    Both,
    /// 框外很远、宿主没给到的那一头。
    Unknown,
}

fn valid_year_timeline(tl: &YearTimeline, origin: f64, horizon: f64) -> bool {
    !tl.zone.is_empty()
        && tl.zone.len() <= 255
        && !tl.zone.chars().any(char::is_control)
        && valid_offset(tl.offset)
        && tl.transitions.len() <= 128
        && tl.transitions.iter().all(|t| t.at.is_finite() && t.at > origin && t.at <= horizon && valid_offset(t.after))
        && tl.transitions.windows(2).all(|w| w[0].at < w[1].at)
}

fn year_offset_at(tl: &YearTimeline, t: f64) -> i32 {
    tl.transitions.iter().take_while(|x| x.at <= t).last().map_or(tl.offset, |x| x.after)
}

/// 本机自己那一行：按本机的偏移分段（每次换钟一段），只留框里的部分。
fn local_segments(local: &YearTimeline, start: f64, end: f64) -> Vec<Value> {
    let mut cuts: Vec<f64> = local.transitions.iter().map(|t| t.at).filter(|t| *t > start && *t < end).collect();
    cuts.insert(0, start);
    cuts.push(end);
    cuts.windows(2)
        .map(|w| json!({"from": w[0], "to": w[1], "value": year_offset_at(local, w[0]), "between": false}))
        .collect()
}

/// 一个地方与本机的时差，分成一段一段（时差变了才断开）。一段两头分别是本机换钟与对方换钟时（顺序不论），
/// 它就是「两地不在同一天换钟，中间那几天的时差是另一个数」那一段（`between`）；两头都是同一边换钟的，是季节里的时差
/// （东京与洛杉矶：洛杉矶 11 月拨慢、3 月拨快，中间整个冬天快 17 小时）。来历看框外的换钟，所以框里头一段也分得清。
fn place_segments(local: &YearTimeline, place: &YearTimeline, origin: f64, horizon: f64, start: f64, end: f64) -> Vec<Value> {
    let mut instants: Vec<f64> = local.transitions.iter().chain(place.transitions.iter()).map(|t| t.at).collect();
    instants.sort_by(f64::total_cmp);
    instants.dedup();
    let diff_at = |t: f64| year_offset_at(place, t) - year_offset_at(local, t);
    // 时差真变了的那些时刻与来历。
    let mut boundaries: Vec<(f64, Side)> = vec![(origin, Side::Unknown)];
    let mut previous = place.offset - local.offset;
    for t in instants {
        let diff = diff_at(t);
        if diff != previous {
            let local_moved = local.transitions.iter().any(|x| x.at == t);
            let place_moved = place.transitions.iter().any(|x| x.at == t);
            let side = match (local_moved, place_moved) {
                (true, true) => Side::Both,
                (true, false) => Side::Local,
                _ => Side::Place,
            };
            boundaries.push((t, side));
        }
        previous = diff;
    }
    boundaries.push((horizon, Side::Unknown));
    boundaries
        .windows(2)
        .filter_map(|w| {
            let (from, left) = w[0];
            let (to, right) = w[1];
            let (a, b) = (from.max(start), to.min(end));
            if b <= a {
                return None;
            }
            let between = matches!((left, right), (Side::Local, Side::Place) | (Side::Place, Side::Local));
            Some(json!({"from": a, "to": b, "value": diff_at(from), "between": between}))
        })
        .collect()
}

fn own_transitions(tl: &YearTimeline, start: f64, end: f64) -> Vec<Value> {
    tl.transitions
        .iter()
        .filter(|t| t.at >= start && t.at < end)
        .map(|t| json!({"at": t.at, "before": year_offset_at(tl, t.at - 1.0), "after": t.after}))
        .filter(|v| v["before"] != v["after"])
        .collect()
}

/// 框里的每一次换钟（同一刻、拨同样多的几个地方并成一次），以及它让哪些地方与本机的时差从几变成几。
fn year_changes(local: &YearTimeline, places: &[YearTimeline], start: f64, end: f64) -> Vec<Value> {
    // (时刻, 拨了多少, 是不是本机, 时区, 前, 后)
    let mut events: Vec<(f64, i32, bool, &str, i32, i32)> = vec![];
    for (is_local, tl) in std::iter::once((true, local)).chain(places.iter().map(|p| (false, p))) {
        for t in tl.transitions.iter().filter(|t| t.at >= start && t.at < end) {
            let before = year_offset_at(tl, t.at - 1.0);
            if before != t.after {
                events.push((t.at, t.after - before, is_local, tl.zone.as_str(), before, t.after));
            }
        }
    }
    // 本机排在同一刻的最前面，其余按时区名（确定的顺序）。
    events.sort_by(|a, b| a.0.total_cmp(&b.0).then(a.1.cmp(&b.1)).then(b.2.cmp(&a.2)).then(a.3.cmp(b.3)));
    let mut out: Vec<Value> = vec![];
    let mut index = 0;
    while index < events.len() {
        let (at, shift, ..) = events[index];
        let group: Vec<_> = events[index..].iter().take_while(|e| e.0 == at && e.1 == shift).collect();
        index += group.len();
        let members: Vec<Value> = group.iter().map(|e| json!({"zone": e.3, "local": e.2, "before": e.4, "after": e.5})).collect();
        let effects: Vec<Value> = places
            .iter()
            .filter_map(|p| {
                let from = year_offset_at(p, at - 1.0) - year_offset_at(local, at - 1.0);
                let to = year_offset_at(p, at) - year_offset_at(local, at);
                (from != to).then(|| json!({"zone": p.zone, "from": from, "to": to}))
            })
            .collect();
        out.push(json!({"at": at, "shift": shift, "members": members, "effects": effects}));
    }
    out
}

fn year(payload: &Value) -> Result<Value, String> {
    let number = |key: &str| payload[key].as_f64().filter(|n| n.is_finite()).ok_or_else(|| format!("Invalid {key}"));
    let (start, end, origin, horizon) = (number("start")?, number("end")?, number("origin")?, number("horizon")?);
    if !(origin < start && start < end && end <= horizon && end - start <= HORIZON && start - origin <= 2.0 * HORIZON && horizon - end <= 2.0 * HORIZON) {
        return Err("Invalid year frame".to_owned());
    }
    let local: YearTimeline = serde_json::from_value(payload["local"].clone()).map_err(|e| e.to_string())?;
    let places: Vec<YearTimeline> = serde_json::from_value(payload["places"].clone()).map_err(|e| e.to_string())?;
    if !valid_year_timeline(&local, origin, horizon) || places.len() > 256 || places.iter().any(|p| !valid_year_timeline(p, origin, horizon)) {
        return Err("Invalid offset timeline".to_owned());
    }
    let rows: Vec<Value> = places
        .iter()
        .map(|place| {
            json!({"zone": place.zone, "segments": place_segments(&local, place, origin, horizon, start, end),
                   "transitions": own_transitions(place, start, end)})
        })
        .collect();
    Ok(json!({
        "local": {"zone": local.zone, "segments": local_segments(&local, start, end), "transitions": own_transitions(&local, start, end)},
        "places": rows,
        "changes": year_changes(&local, &places, start, end),
    }))
}

pub fn dispatch(operation: &str, payload: Value) -> Result<Value, String> {
    if operation == "offsetwindows.year" {
        return year(&payload);
    }
    if operation != "offsetwindows.compute" {
        return Err(format!("unknown offset windows operation: {operation}"));
    }
    let now = payload["now"].as_f64().filter(|n| n.is_finite()).ok_or("Invalid clock facts")?;
    let horizon = payload["horizonDays"].as_f64().filter(|d| d.is_finite() && *d > 0.0 && *d <= 400.0).unwrap_or(365.0) * 86_400.0;
    let local: Timeline = serde_json::from_value(payload["local"].clone()).map_err(|e| e.to_string())?;
    let places: Vec<Timeline> = serde_json::from_value(payload["places"].clone()).map_err(|e| e.to_string())?;
    if !valid(&local, now) || places.len() > 4096 || places.iter().any(|p| !valid(p, now)) {
        return Err("Invalid offset timeline".to_owned());
    }
    let result: Vec<Value> = places
        .iter()
        .map(|place| {
            let list = changes(&local, place, now, horizon);
            json!({"zone": place.zone, "diffNow": place.offset_now - local.offset_now, "changes": list})
        })
        .collect();
    Ok(json!({"places": result, "horizonDays": horizon / 86_400.0}))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tl(zone: &str, offset_now: i32, transitions: &[(f64, i32)]) -> Value {
        json!({"zone": zone, "offsetNow": offset_now, "transitions": transitions.iter().map(|(at, after)| json!({"at": at, "after": after})).collect::<Vec<_>>()})
    }

    #[test]
    fn london_and_los_angeles_drift_apart_for_a_week_each_spring_and_autumn() {
        // 2026：美国 3 月 8 日进入夏令时、英国 3 月 29 日；英国 10 月 25 日退出、美国 11 月 1 日。
        let now = 1_767_225_600.0; // 2026-01-01
        let la = tl("America/Los_Angeles", -8 * 3600, &[(1_772_960_400.0, -7 * 3600), (1_793_523_600.0, -8 * 3600)]);
        let london = tl("Europe/London", 0, &[(1_774_746_000.0, 3600), (1_792_803_600.0, 0)]);
        let out = dispatch("offsetwindows.compute", json!({"now": now, "local": la, "places": [london]})).unwrap();
        let place = &out["places"][0];
        assert_eq!(place["diffNow"], 8 * 3600);
        let changes = place["changes"].as_array().unwrap();
        assert_eq!(changes.len(), 4, "{changes:?}");
        // 3 月 8 日本机拨快 → 时差 8h 变 7h（本机动）；3 月 29 日伦敦拨快 → 回到 8h（对方动）
        assert_eq!((changes[0]["from"].as_i64(), changes[0]["to"].as_i64(), changes[0]["cause"].as_str()), (Some(28_800), Some(25_200), Some("local")));
        assert_eq!((changes[1]["to"].as_i64(), changes[1]["cause"].as_str()), (Some(28_800), Some("place")));
        assert_eq!((changes[2]["to"].as_i64(), changes[2]["cause"].as_str()), (Some(25_200), Some("place")));
        assert_eq!((changes[3]["to"].as_i64(), changes[3]["cause"].as_str()), (Some(28_800), Some("local")));
    }

    #[test]
    fn same_day_changes_and_fixed_zones_produce_no_window() {
        let now = 1_767_225_600.0;
        // 两地同一刻换钟：时差不变，不报；东京全年不动、本机换两次：报两次且 cause 都是 local。
        let paris = tl("Europe/Paris", 3600, &[(1_774_746_000.0, 7200), (1_792_803_600.0, 3600)]);
        let london = tl("Europe/London", 0, &[(1_774_746_000.0, 3600), (1_792_803_600.0, 0)]);
        let tokyo = tl("Asia/Tokyo", 9 * 3600, &[]);
        let out = dispatch("offsetwindows.compute", json!({"now": now, "local": london, "places": [paris, tokyo]})).unwrap();
        assert_eq!(out["places"][0]["changes"].as_array().unwrap().len(), 0);
        let tokyo_changes = out["places"][1]["changes"].as_array().unwrap();
        assert_eq!(tokyo_changes.len(), 2);
        assert!(tokyo_changes.iter().all(|c| c["cause"] == "local"));
        assert_eq!(tokyo_changes[0]["to"], 8 * 3600);
    }

    #[test]
    fn invalid_timelines_are_rejected_and_horizon_is_clamped() {
        let now = 1_767_225_600.0;
        let bad = tl("", 0, &[]);
        assert!(dispatch("offsetwindows.compute", json!({"now": now, "local": bad, "places": []})).is_err());
        let unsorted = tl("X/Y", 0, &[(now + 20.0, 3600), (now + 10.0, 0)]);
        assert!(dispatch("offsetwindows.compute", json!({"now": now, "local": tl("A/B", 0, &[]), "places": [unsorted]})).is_err());
        let far = tl("X/Y", 0, &[(now + 500.0 * 86_400.0, 3600)]);
        assert!(dispatch("offsetwindows.compute", json!({"now": now, "local": tl("A/B", 0, &[]), "places": [far]})).is_err());
        let out = dispatch("offsetwindows.compute", json!({"now": now, "horizonDays": 30, "local": tl("A/B", 0, &[]), "places": [tl("C/D", 3600, &[(now + 40.0 * 86_400.0, 7200)])]})).unwrap();
        assert_eq!(out["places"][0]["changes"].as_array().unwrap().len(), 0, "30 天视野看不到 40 天后的变化");
    }

    // MARK: offsetwindows.year

    /// 换钟时刻取自本机 tzdata 2026c（Python zoneinfo 与 Foundation 读的是同一份 /usr/share/zoneinfo）。
    const LA: &[(f64, i32)] = &[(1_762_074_000.0, -8 * 3600), (1_772_964_000.0, -7 * 3600), (1_793_523_600.0, -8 * 3600),
                                (1_805_018_400.0, -7 * 3600), (1_825_578_000.0, -8 * 3600)];
    const LONDON: &[(f64, i32)] = &[(1_761_440_400.0, 0), (1_774_746_000.0, 3600), (1_792_890_000.0, 0),
                                    (1_806_195_600.0, 3600), (1_824_944_400.0, 0)];
    const SYDNEY: &[(f64, i32)] = &[(1_759_593_600.0, 11 * 3600), (1_775_318_400.0, 10 * 3600), (1_791_043_200.0, 11 * 3600),
                                    (1_806_768_000.0, 10 * 3600), (1_822_492_800.0, 11 * 3600)];
    const PARIS: &[(f64, i32)] = &[(1_761_440_400.0, 3600), (1_774_746_000.0, 7200), (1_792_890_000.0, 3600),
                                   (1_806_195_600.0, 7200), (1_824_944_400.0, 3600)];
    /// 2026-10-02 00:00 洛杉矶（07:00Z）到一年后；origin = 2025-09-01，horizon = 2027-12-31。
    const START: f64 = 1_790_924_400.0;
    const END: f64 = 1_822_460_400.0;
    const ORIGIN: f64 = 1_756_684_800.0;
    const HORIZON_END: f64 = 1_830_211_200.0;

    fn ytl(zone: &str, offset: i32, transitions: &[(f64, i32)]) -> Value {
        json!({"zone": zone, "offset": offset,
               "transitions": transitions.iter().map(|(at, after)| json!({"at": at, "after": after})).collect::<Vec<_>>()})
    }

    fn year_out(local: Value, places: Vec<Value>) -> Value {
        dispatch("offsetwindows.year", json!({"start": START, "end": END, "origin": ORIGIN, "horizon": HORIZON_END,
                                              "local": local, "places": places}))
        .unwrap()
    }

    /// (起, 止, 时差小时, 是不是两地错开的那几天)
    fn spans(row: &Value) -> Vec<(f64, f64, f64, bool)> {
        row["segments"].as_array().unwrap().iter()
            .map(|s| (s["from"].as_f64().unwrap(), s["to"].as_f64().unwrap(), s["value"].as_f64().unwrap() / 3600.0,
                      s["between"].as_bool().unwrap()))
            .collect()
    }

    #[test]
    fn the_week_london_is_only_seven_hours_ahead_is_marked_and_tokyos_winter_is_a_season() {
        let out = year_out(ytl("America/Los_Angeles", -7 * 3600, LA),
                           vec![ytl("Europe/London", 3600, LONDON), ytl("Asia/Tokyo", 9 * 3600, &[])]);
        // 伦敦：10-25 01:00Z 先拨慢（对方），11-01 09:00Z 本机再拨慢：中间一周快 7 小时，是错开的那几天；春天 3-14 到 3-28 同理。
        assert_eq!(spans(&out["places"][0]), vec![
            (START, 1_792_890_000.0, 8.0, false),
            (1_792_890_000.0, 1_793_523_600.0, 7.0, true),
            (1_793_523_600.0, 1_805_018_400.0, 8.0, false),
            (1_805_018_400.0, 1_806_195_600.0, 7.0, true),
            (1_806_195_600.0, END, 8.0, false),
        ]);
        // 东京从不换钟：两头都是本机换钟，整个冬天快 17 小时是季节，不是错开的那几天。
        assert_eq!(spans(&out["places"][1]), vec![
            (START, 1_793_523_600.0, 16.0, false),
            (1_793_523_600.0, 1_805_018_400.0, 17.0, false),
            (1_805_018_400.0, END, 16.0, false),
        ]);
        // 本机那一行按自己的偏移分三段。
        let local: Vec<_> = out["local"]["segments"].as_array().unwrap().iter().map(|s| s["value"].as_i64().unwrap() / 3600).collect();
        assert_eq!(local, vec![-7, -8, -7]);
        assert_eq!(out["local"]["transitions"].as_array().unwrap().len(), 2);
        assert_eq!(out["places"][0]["transitions"].as_array().unwrap().len(), 2);
        assert!(out["places"][1]["transitions"].as_array().unwrap().is_empty());
    }

    #[test]
    fn the_other_hemisphere_has_two_windows_and_two_seasons() {
        let out = year_out(ytl("America/Los_Angeles", -7 * 3600, LA), vec![ytl("Australia/Sydney", 10 * 3600, SYDNEY)]);
        // 悉尼 10-03 16:00Z 拨快（对方）→ 11-01 本机拨慢 → 3-14 本机拨快 → 4-03 16:00Z 悉尼拨慢：快 17 / 18 / 19 / 18 / 17。
        assert_eq!(spans(&out["places"][0]), vec![
            (START, 1_791_043_200.0, 17.0, false),
            (1_791_043_200.0, 1_793_523_600.0, 18.0, true),
            (1_793_523_600.0, 1_805_018_400.0, 19.0, false),
            (1_805_018_400.0, 1_806_768_000.0, 18.0, true),
            (1_806_768_000.0, END, 17.0, false),
        ]);
    }

    #[test]
    fn a_window_that_began_before_the_frame_is_still_a_window() {
        // 框从 10-28 开始：伦敦已经拨慢、本机还没有。头一段的来历在框外（10-25 伦敦），照样认得出。
        let start = 1_792_890_000.0 + 3.0 * 86_400.0;
        let out = dispatch("offsetwindows.year", json!({"start": start, "end": start + 300.0 * 86_400.0, "origin": ORIGIN,
            "horizon": HORIZON_END, "local": ytl("America/Los_Angeles", -7 * 3600, LA),
            "places": [ytl("Europe/London", 3600, LONDON)]})).unwrap();
        let first = &spans(&out["places"][0])[0];
        assert_eq!((first.0, first.1, first.2, first.3), (start, 1_793_523_600.0, 7.0, true));
    }

    #[test]
    fn places_that_change_together_give_one_change_and_no_window() {
        // 本机在伦敦：巴黎与伦敦同一刻换钟，时差恒为 1 小时；换钟表里伦敦（本机）与巴黎并成同一次，时差不变。
        let out = year_out(ytl("Europe/London", 3600, LONDON), vec![ytl("Europe/Paris", 7200, PARIS), ytl("Asia/Tokyo", 9 * 3600, &[])]);
        assert_eq!(spans(&out["places"][0]), vec![(START, END, 1.0, false)]);
        let changes = out["changes"].as_array().unwrap();
        assert_eq!(changes.len(), 2, "{changes:?}");
        let autumn = &changes[0];
        assert_eq!(autumn["at"], 1_792_890_000.0);
        assert_eq!(autumn["shift"], -3600);
        let members: Vec<_> = autumn["members"].as_array().unwrap().iter().map(|m| (m["zone"].as_str().unwrap(), m["local"].as_bool().unwrap())).collect();
        assert_eq!(members, vec![("Europe/London", true), ("Europe/Paris", false)]);
        // 只有东京的时差变了：8 → 9。
        let effects = autumn["effects"].as_array().unwrap();
        assert_eq!(effects.len(), 1);
        assert_eq!((effects[0]["zone"].as_str(), effects[0]["from"].as_i64(), effects[0]["to"].as_i64()),
                   (Some("Asia/Tokyo"), Some(8 * 3600), Some(9 * 3600)));
    }

    #[test]
    fn each_change_says_what_it_does_to_every_difference() {
        let out = year_out(ytl("America/Los_Angeles", -7 * 3600, LA),
                           vec![ytl("Europe/London", 3600, LONDON), ytl("Asia/Tokyo", 9 * 3600, &[])]);
        let changes = out["changes"].as_array().unwrap();
        let summary: Vec<_> = changes.iter().map(|c| {
            let zones: Vec<_> = c["members"].as_array().unwrap().iter().map(|m| m["zone"].as_str().unwrap().to_owned()).collect();
            let effects: Vec<_> = c["effects"].as_array().unwrap().iter()
                .map(|e| (e["zone"].as_str().unwrap().to_owned(), e["to"].as_i64().unwrap() / 3600)).collect();
            (c["at"].as_f64().unwrap(), zones, effects)
        }).collect();
        assert_eq!(summary, vec![
            (1_792_890_000.0, vec!["Europe/London".to_owned()], vec![("Europe/London".to_owned(), 7)]),
            (1_793_523_600.0, vec!["America/Los_Angeles".to_owned()], vec![("Europe/London".to_owned(), 8), ("Asia/Tokyo".to_owned(), 17)]),
            (1_805_018_400.0, vec!["America/Los_Angeles".to_owned()], vec![("Europe/London".to_owned(), 7), ("Asia/Tokyo".to_owned(), 16)]),
            (1_806_195_600.0, vec!["Europe/London".to_owned()], vec![("Europe/London".to_owned(), 8)]),
        ]);
    }

    #[test]
    fn year_frames_and_timelines_are_checked() {
        let good = ytl("America/Los_Angeles", -7 * 3600, LA);
        let call = |start: f64, end: f64, local: Value| dispatch("offsetwindows.year",
            json!({"start": start, "end": end, "origin": ORIGIN, "horizon": HORIZON_END, "local": local, "places": []}));
        assert!(call(START, END, good.clone()).is_ok());
        assert!(call(END, START, good.clone()).is_err(), "框倒过来");
        assert!(call(START, START + 500.0 * 86_400.0, good.clone()).is_err(), "框超过 400 天");
        assert!(call(START, END, ytl("", 0, &[])).is_err());
        assert!(call(START, END, ytl("X/Y", 0, &[(START + 10.0, 3600), (START + 5.0, 0)])).is_err(), "转换没排好序");
        assert!(call(START, END, ytl("X/Y", 0, &[(ORIGIN - 10.0, 3600)])).is_err(), "转换在 origin 之前");
        assert!(call(START, END, ytl("X/Y", 90_000, &[])).is_err(), "偏移越界");
        assert!(dispatch("offsetwindows.year", json!({"start": START})).is_err());
        // 没有任何换钟：一段，时差不变，换钟表为空。
        let flat = year_out(ytl("Asia/Tokyo", 9 * 3600, &[]), vec![ytl("Asia/Seoul", 9 * 3600, &[])]);
        assert_eq!(spans(&flat["places"][0]), vec![(START, END, 0.0, false)]);
        assert!(flat["changes"].as_array().unwrap().is_empty());
    }
}
