// SPDX-License-Identifier: GPL-3.0-only
//! Presentation policies and batched geometry. macOS supplies localized strings,
//! civil-day boundaries, scaled metrics, and renders these platform-neutral commands.
use serde::Serialize;
use serde_json::{json, Value};

use crate::lane::{command, day_lane};

fn number(v: &Value, key: &str) -> Result<f64, String> {
    v.get(key)
        .and_then(Value::as_f64)
        .filter(|n| n.is_finite())
        .ok_or_else(|| format!("Missing finite number: {key}"))
}
fn text<'a>(v: &'a Value, key: &str) -> Result<&'a str, String> {
    v.get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| format!("Missing string: {key}"))
}
fn array<'a>(v: &'a Value, key: &str) -> Result<&'a Vec<Value>, String> {
    v.get(key)
        .and_then(Value::as_array)
        .ok_or_else(|| format!("Missing array: {key}"))
}

fn planning_start(v: &Value) -> Result<f64, String> {
    let from = number(v, "fromDay")?;
    if from != number(v, "todayStart")? {
        return Ok(from);
    }
    Ok(((number(v, "now")? / 900.0).ceil() * 900.0).min(number(v, "nextDay")? - 1.0))
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct Row {
    source_index: i64,
    name: String,
    participates: bool,
}

fn planner_rows(v: &Value) -> Result<Value, String> {
    let zones = array(v, "zones")?;
    let excluded = array(v, "excluded")?;
    let local_tz = text(v, "localTimeZoneId")?;
    let mut rows = vec![];
    if !zones
        .iter()
        .any(|z| z["timeZoneId"].as_str() == Some(local_tz))
    {
        rows.push(Row {
            source_index: -1,
            name: text(v, "localName")?.into(),
            participates: v["includeLocal"].as_bool().unwrap_or(false),
        });
    }
    for (i, zone) in zones.iter().enumerate() {
        let name = if let Some(custom) = zone["customName"].as_str() {
            custom
        } else {
            let localized = text(zone, "localizedCity")?;
            if localized.is_empty() {
                text(zone, "cityName")?
            } else {
                localized
            }
        };
        rows.push(Row {
            source_index: i as i64,
            name: name.into(),
            participates: !excluded.contains(&zone["id"]),
        });
    }
    serde_json::to_value(rows).map_err(|e| e.to_string())
}

/// 太阳与月亮页的主图「这一天的天」：某地当地这一天（宿主给民用日的起止）真实的天色铺满整张图
/// （`sky::lane_stops` 每 10 分钟一个色标，与同一地方同一天的昼夜条逐个相同），太阳这一天的高度画成一条线：
/// 地平线以上是金线（深色外沿，纸色的天上也看得清），以下是一道细的纸色线（太阳在地平线下）。
/// 地平线取日出日落同一个判据（−0.833°），画成一道随天色换墨或纸的细线（`sky::line_stops`）；黄金时刻
/// （−4° … +6°）是太阳那条线上贴着地平线的两段金色的光。纵轴固定 +90°（天顶）到 −45°：地平线落在下三分之一处，
/// 白天那一段占三分之二的高，−18° 的天文晨昏也在图里；再往下的深夜被图边裁掉。
/// 另给地平线的高度与正在看的那一刻太阳在哪（宿主画太阳，沉在地平线下就画一圈空心的）。横轴刻度与文字由宿主排。
const SUN_DAY_TOP: f64 = 90.0;
const SUN_DAY_BOTTOM: f64 = -45.0;
const SUN_DAY_HORIZON: f64 = -0.833;

fn sun_day(v: &Value) -> Result<Value, String> {
    let w = number(v, "width")?;
    let h = number(v, "height")?;
    if !(w > 0.0 && h > 0.0) {
        return Err("画布尺寸必须为正".into());
    }
    let (t0, t1) = (number(v, "dayStart")?, number(v, "dayEnd")?);
    let (lat, lon) = (number(v, "latitude")?, number(v, "longitude")?);
    if !(crate::astronomy::SUPPORTED_UNIX.contains(&t0) && crate::astronomy::SUPPORTED_UNIX.contains(&t1))
        || t1 <= t0
        || t1 - t0 > 2.0 * 86_400.0
    {
        return Err("Sun day needs one civil day from 1800 to 2100".into());
    }
    if !(-90.0..=90.0).contains(&lat) || !(-180.0..=180.0).contains(&lon) {
        return Err("Sun day needs a valid coordinate".into());
    }
    let span = t1 - t0;
    let x_of = |t: f64| (t - t0) / span * w;
    let y_of = |deg: f64| (SUN_DAY_TOP - deg) / (SUN_DAY_TOP - SUN_DAY_BOTTOM) * h;
    let at = |t: f64| crate::astronomy::elevation(t, lat, lon);
    let horizon = y_of(SUN_DAY_HORIZON);
    let stops = |list: Vec<(f64, String)>| Some(list.into_iter().map(|(at, color)| crate::lane::Stop { at, color }).collect());

    let mut commands = Vec::new();
    // 天：这一天每 10 分钟的天色，铺满整张图。
    commands.push(crate::lane::Command { kind: "gradient", geometry: vec![0.0, 0.0, w, h], style: "sky", opacity: 1.0,
        line_width: 0.0, stops: stops(crate::sky::lane_stops(t0, t1, lat, lon, 10.0)) });
    // 「不使用颜色区分」：昼 / 曙暮 / 夜的边界刻度（与昼夜条同一画法）。
    if v["marks"] == true {
        crate::lane::push_band_marks(&mut commands, t0, t1, lat, lon, w, h);
    }
    // 地平线：1 点高的一道，颜色随天色换墨或纸。
    commands.push(crate::lane::Command { kind: "gradient", geometry: vec![0.0, horizon - 0.5, w, 1.0], style: "sky", opacity: 1.0,
        line_width: 0.0, stops: stops(crate::sky::line_stops(t0, t1, lat, lon, 10.0)) });
    // 太阳的高度：每 5 分钟一点，按在不在地平线以上切成几段，穿越处补上恰好在地平线上的一点，上下两段接得上。
    let count = ((span / 300.0).ceil() as usize).clamp(2, 1_000);
    let samples: Vec<(f64, f64)> = (0..=count).map(|k| {
        let t = t0 + span * k as f64 / count as f64;
        (t, at(t))
    }).collect();
    // 黄金时刻：太阳在 −4° … +6° 的那几段，沿太阳的线铺一道宽的金色光（线画在它上面），
    // 一眼看出「太阳贴着地平线、发金光」的是哪两段。
    for interval in v.get("golden").and_then(Value::as_array).into_iter().flatten() {
        let (Some(s), Some(e)) = (interval["start"].as_f64(), interval["end"].as_f64()) else { continue };
        let (s, e) = (s.max(t0), e.min(t1));
        if !(s.is_finite() && e.is_finite() && e > s) {
            continue;
        }
        let mut glow = vec![x_of(s), y_of(at(s))];
        for &(t, elevation) in samples.iter().filter(|(t, _)| *t > s && *t < e) {
            glow.extend([x_of(t), y_of(elevation)]);
        }
        glow.extend([x_of(e), y_of(at(e))]);
        commands.push(command("polyline", glow, "sun", 0.45, 10.0));
    }
    let mut runs: Vec<(bool, Vec<f64>)> = Vec::new();
    for (i, &(t, e)) in samples.iter().enumerate() {
        let up = e >= SUN_DAY_HORIZON;
        if i > 0 {
            let (pt, pe) = samples[i - 1];
            if (pe >= SUN_DAY_HORIZON) != up {
                let f = (SUN_DAY_HORIZON - pe) / (e - pe);
                let cross = [x_of(pt + (t - pt) * f), horizon];
                if let Some(run) = runs.last_mut() {
                    run.1.extend(cross);
                }
                runs.push((up, cross.to_vec()));
            }
        }
        if runs.is_empty() {
            runs.push((up, Vec::new()));
        }
        if let Some(run) = runs.last_mut() {
            run.1.extend([x_of(t), y_of(e)]);
        }
    }
    for (up, points) in &runs {
        if points.len() >= 4 && !up {
            commands.push(command("polyline", points.clone(), "paper", 0.6, 1.25));
        }
    }
    for (up, points) in &runs {
        if points.len() >= 4 && *up {
            commands.push(command("polyline", points.clone(), "sunRim", 1.0, 3.5));
            commands.push(command("polyline", points.clone(), "sun", 1.0, 2.0));
        }
    }
    // 正在看的那一刻：在这一天里才给。
    let sun = v.get("instant").and_then(Value::as_f64).filter(|t| *t >= t0 && *t <= t1).map(|t| {
        let e = at(t);
        json!({"x": x_of(t), "y": y_of(e).clamp(0.0, h), "up": e >= SUN_DAY_HORIZON, "degrees": e})
    });
    Ok(json!({"commands": commands, "horizon": horizon, "sun": sun}))
}

fn search_event(v: &Value) -> Result<Value, String> {
    let mut state = v["state"].clone();
    let ids = array(v, "ids")?;
    let mut commit = None;
    let mut handled = true;
    match text(v, "kind")? {
        "selectionChanged" if state["keyboardNavigating"] == true => {
            state["keyboardNavigating"] = json!(false)
        }
        "selectionChanged" => {
            commit = ids.iter().position(|id| id == &state["selection"]);
        }
        "key" => {
            let action = dispatch(
                "presentation.search_key",
                json!({"ids":ids,"selection":state["selection"],
                "command":v["command"],"query":state["query"]}),
            )?;
            handled = action["handled"] == true;
            if action["clear"] == true {
                state["query"] = json!("");
                state["selection"] = Value::Null;
            }
            if let Some(index) = action["index"].as_u64() {
                if action["commit"] == true {
                    commit = Some(index as usize);
                } else {
                    state["keyboardNavigating"] = json!(true);
                    state["selection"] = ids[index as usize].clone();
                }
            }
        }
        kind => return Err(format!("Unknown search event: {kind}")),
    }
    if commit.is_some() {
        state["query"] = json!("");
        state["selection"] = Value::Null;
    }
    Ok(json!({"state":state,"commitIndex":commit,"handled":handled}))
}

/// 「洛杉矶 21:00 · 伦敦 次日 5:00 · 东京 次日 13:00」：每个地点的钟点，与行首日期不是同一天的
/// 按 `dayOffset`（该地当地日期减行首日期的天数，Swift 用 Foundation 日历算）套上 `nextDay` /
/// `previousDay` 模板；模板里的 `%@` 是钟点，各语言自定前后（中日韩在前、英德法在后），
/// 没有 `%@` 的模板接在钟点后面。行首日期只写一次、各地不再写日期，所以跨日必须在这里标出来
/// （伦敦与东京已是 15 日，行首却写 14 日）。
fn window_places(v: &Value) -> Result<Value, String> {
    let mut segments = vec![];
    let mut spoken = vec![];
    let next_day = text(v, "nextDay")?;
    let previous_day = text(v, "previousDay")?;
    for (index, place) in array(v, "places")?.iter().enumerate() {
        if index > 0 {
            segments.push(json!({"text":" · ","outside":false}));
        }
        let time = text(place, "time")?;
        let day_offset = place["dayOffset"].as_i64().unwrap_or(0);
        let clock = match day_offset {
            0 => time.to_string(),
            offset => {
                let template = if offset > 0 { next_day } else { previous_day };
                if template.contains("%@") {
                    template.replacen("%@", time, 1)
                } else {
                    format!("{time} {template}")
                }
            }
        };
        let label = format!("{} {clock}", text(place, "name")?);
        let outside = text(place, "fit")? == "stretched";
        segments.push(json!({"text":label,"outside":outside}));
        spoken.push(if outside {
            format!("{} {}", label, text(v, "outsidePhrase")?)
        } else {
            label
        });
    }
    Ok(json!({"segments":segments,"accessibility":spoken.join(", ")}))
}

pub fn dispatch(operation: &str, payload: Value) -> Result<Value, String> {
    let v = &payload;
    match operation {
        "presentation.search_event" => search_event(v),
        "presentation.window_places" => window_places(v),
        "presentation.sun_day" => sun_day(v),
        "presentation.planner_rows" => planner_rows(v),
        "presentation.planning_start" => Ok(json!(planning_start(v)?)),
        "presentation.planner_inputs" => {
            let participants:Vec<Value>=array(v,"rows")?.iter().enumerate().filter(|(_,r)|r["participates"]==true)
                .map(|(i,r)|json!({"index":i,"id":r["id"].as_str().unwrap_or("00000000-0000-0000-0000-000000000000")})).collect();
            Ok(
                json!({"canPlan":participants.len()>=2,"participants":participants,"notBefore":planning_start(v)?}),
            )
        }
        "presentation.interval_text" => {
            let same_day = v["sameDay"] == true;
            let offsets_change = number(v, "startOffset")? != number(v, "endOffset")?;
            let endpoint = |key: &str| -> Result<String, String> {
                let p = &v[key];
                let time = text(p, "time")?;
                let value = if same_day {
                    time.into()
                } else {
                    format!("{} {time}", text(p, "day")?)
                };
                Ok(if offsets_change {
                    format!("{value} {}", text(p, "abbreviation")?)
                } else {
                    value
                })
            };
            Ok(json!(format!(
                "{}–{}",
                endpoint("start")?,
                endpoint("end")?
            )))
        }
        "presentation.day_lane" => day_lane(v),
        "presentation.signed_offset" => {
            let seconds = v["seconds"].as_i64().ok_or("Missing seconds")?;
            let sign = if seconds < 0 { "−" } else { "+" };
            let total = seconds.unsigned_abs();
            let hours = total / 3600;
            let minutes = (total % 3600) / 60;
            Ok(json!(if minutes == 0 {
                format!("{sign}{hours}")
            } else {
                format!("{sign}{hours}:{minutes:02}")
            }))
        }
        "presentation.availability_label_date" => Ok(json!(
            1_767_225_600.0 + number(v, "minute")?.clamp(0.0, 1440.0) * 60.0
        )),
        "presentation.menu_count" => Ok(json!((v["count"]
            .as_u64()
            .ok_or("Invalid zone count")?)
        .min(v["requested"].as_u64().ok_or("Invalid menu zone count")?))),
        "presentation.availability_date" => {
            Ok(json!(1_767_225_600.0 + number(v, "minute")? * 60.0))
        }
        "presentation.availability_minute" => Ok(json!((((number(v, "date")? - 1_767_225_600.0)
            / 60.0)
            .trunc() as i64)
            .rem_euclid(1440))),
        "presentation.weekend_indices" => Ok(json!(array(v, "weekend")?
            .iter()
            .enumerate()
            .filter(|(_, v)| **v == true)
            .map(|(i, _)| i)
            .collect::<Vec<_>>())),
        "presentation.overlap_tap" => {
            let fraction = (number(v, "x")? / number(v, "width")?.max(1.0)).clamp(0.0, 1.0);
            Ok(json!(
                number(v, "start")? + (fraction * number(v, "length")? / 900.0).round() * 900.0
            ))
        }
        "presentation.panel_layout" => {
            // 面板只有一个滚动区：地点列表整行取高、穿梭控件、规划区都按内容自然长高，三者一起放进
            // 一个 ScrollView，它的高度 = min(内容高, 预算)。预算 = 屏幕可见高 − 固定部分（搜索框、下一日程、
            // 底栏、分隔线 ≈ 160 pt），至少 320。此前列表与规划区各自一个限高滚动区、按 0.45 / 0.55 分预算，
            // 长语言（de / es / pt-BR / ru）的规划区在本机 861 pt 可见高下只有 311 pt，东京那行时间轴与图例
            // 整个滚出可见区；收起规划区时列表也不再独占 440。
            let body = (number(v, "screenHeight")? - 160.0).max(320.0);
            Ok(json!({"body": body}))
        }
        "presentation.search_height" => Ok(json!(
            number(v, "count")?.min(6.0) * number(v, "rowHeight")?
        )),
        "presentation.scroll_label" => {
            // 穿梭那一句放不下时的短写：不到一天「+17h24m」，满一天「+2d3h」（与全写「2天3小时后」同一个取整：
            // 小时四舍五入到整点、分钟不写）。
            let seconds = number(v, "seconds")?;
            let sign = if seconds >= 0.0 { "+" } else { "−" };
            let minutes = seconds.abs().round() as u64 / 60;
            if minutes >= 1440 {
                let hours = (minutes + 30) / 60;
                let (d, h) = (hours / 24, hours % 24);
                return Ok(json!(if h == 0 { format!("{sign}{d}d") } else { format!("{sign}{d}d{h}h") }));
            }
            let h = minutes / 60;
            let m = minutes % 60;
            Ok(json!(if m == 0 {
                format!("{sign}{h}h")
            } else {
                format!("{sign}{h}h{m:02}m")
            }))
        }
        "presentation.search_key" => {
            let ids = array(v, "ids")?;
            let selection = &v["selection"];
            let current = ids.iter().position(|id| id == selection);
            let command = text(v, "command")?;
            let next = match command {
                "down" if !ids.is_empty() => {
                    Some(current.map_or(0, |i| (i + 1).min(ids.len() - 1)))
                }
                "up" if !ids.is_empty() => {
                    Some(current.map_or(ids.len() - 1, |i| i.saturating_sub(1)))
                }
                "commit" => {
                    current.or_else(|| (selection.is_null() && !ids.is_empty()).then_some(0))
                }
                _ => None,
            };
            let clear = command == "cancel" && !text(v, "query")?.is_empty();
            Ok(
                json!({"handled":next.is_some()||clear||(command=="commit"&&!selection.is_null()),"index":next,"commit":command=="commit"&&next.is_some(),"clear":clear}),
            )
        }
        "presentation.search_active" => Ok(json!(!text(v, "query")?.trim().is_empty())),
        "presentation.clamp_opacity" => Ok(json!(number(v, "opacity")?.max(number(v, "minimum")?))),
        "presentation.spoken_name" => {
            let name = v["customName"]
                .as_str()
                .unwrap_or(text(v, "localizedCity")?);
            Ok(if v["nameMode"] == true && name.is_empty() {
                json!(text(v, "cityName")?)
            } else {
                Value::Null
            })
        }
        _ => Err(format!("Unknown presentation operation: {operation}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn run(op: &str, input: Value) -> Value {
        dispatch(&format!("presentation.{op}"), input).unwrap()
    }

    fn window_commands(input: &Value) -> Value {
        let mut commands = Vec::new();
        crate::lane::push_windows_in(
            &mut commands, input, number(input, "start").unwrap(), number(input, "length").unwrap(),
            number(input, "width").unwrap(), 0.0, number(input, "height").unwrap(),
        ).unwrap();
        serde_json::to_value(commands).unwrap()
    }
    #[test]
    fn search_mouse_commit_uses_current_results_and_keyboard_change_only_previews() {
        let state = json!({"query":"city","selection":"b","keyboardNavigating":true});
        let preview = run(
            "search_event",
            json!({"state":state,"ids":["a","b"],"kind":"selectionChanged"}),
        );
        assert_eq!(preview["commitIndex"], Value::Null);
        assert_eq!(preview["state"]["query"], "city");
        assert_eq!(preview["state"]["keyboardNavigating"], false);
        let committed = run(
            "search_event",
            json!({"state":preview["state"],"ids":["b","a"],"kind":"selectionChanged"}),
        );
        assert_eq!(committed["commitIndex"], 0);
        assert_eq!(committed["state"]["query"], "");
        assert_eq!(committed["state"]["selection"], Value::Null);
        let stale = run(
            "search_event",
            json!({"state":preview["state"],"ids":["a"],"kind":"selectionChanged"}),
        );
        assert_eq!(stale["commitIndex"], Value::Null);
        assert_eq!(stale["state"]["query"], "city");
        let key_stale = run(
            "search_event",
            json!({"state":preview["state"],"ids":["a"],"kind":"key","command":"commit"}),
        );
        assert_eq!(key_stale["handled"], true);
        assert_eq!(key_stale["commitIndex"], Value::Null);
    }

    #[test]
    fn search_keyboard_commit_and_cancel_preserve_existing_flag_lifecycle() {
        let state = json!({"query":"city","selection":null,"keyboardNavigating":false});
        let selected = run(
            "search_event",
            json!({"state":state,"ids":["a","b"],"kind":"key","command":"up"}),
        );
        assert_eq!(selected["state"]["selection"], "b");
        assert_eq!(selected["state"]["keyboardNavigating"], true);
        let committed = run(
            "search_event",
            json!({"state":selected["state"],"ids":["a","b"],"kind":"key","command":"commit"}),
        );
        assert_eq!(committed["commitIndex"], 1);
        assert_eq!(committed["state"]["query"], "");
        assert_eq!(committed["state"]["keyboardNavigating"], true);
        let cleared = run(
            "search_event",
            json!({"state":committed["state"],"ids":["a","b"],"kind":"selectionChanged"}),
        );
        assert_eq!(cleared["state"]["keyboardNavigating"], false);
        let escape = run(
            "search_event",
            json!({"state":state,"ids":[],"kind":"key","command":"cancel"}),
        );
        assert_eq!(escape["handled"], true);
        let escape_again = run(
            "search_event",
            json!({"state":escape["state"],"ids":[],"kind":"key","command":"cancel"}),
        );
        assert_eq!(escape_again["handled"], false);
    }

    /// 太阳一天图：底就是同一地方同一天的昼夜条那批色标（逐个相同）；地平线在下三分之一；
    /// 地平线以上金线（外沿 + 金两道）、以下纸线，两段在日出日落处接在地平线上，日出那一点与天文页算的日出对得上。
    #[test]
    fn the_sun_day_is_the_day_lane_sky_with_the_sun_path_on_it() {
        // 伦敦 2026-09-17（当地民用日按 UTC+1：前一天 23:00 UTC 起）。
        let (t0, t1) = (1_789_599_600.0, 1_789_686_000.0);
        let (lat, lon) = (51.507, -0.128);
        let (w, h) = (540.0, 150.0);
        let day = run("sun_day", json!({"dayStart": t0, "dayEnd": t1, "latitude": lat, "longitude": lon, "width": w, "height": h,
            "golden": [{"start": t0 + 6.0 * 3600.0, "end": t0 + 7.0 * 3600.0}], "instant": t0 + 13.0 * 3600.0}));
        let commands = day["commands"].as_array().unwrap();
        let lane = run("day_lane", json!({"start": t0, "length": t1 - t0, "reference": t0, "width": w, "height": 10.0,
            "latitude": lat, "longitude": lon, "sky": true}));
        assert_eq!(commands[0]["kind"], "gradient");
        assert_eq!(commands[0]["geometry"], json!([0.0, 0.0, w, h]));
        assert_eq!(commands[0]["stops"], lane[0]["stops"], "图底与同一天的昼夜条逐个色标相同");
        let horizon = day["horizon"].as_f64().unwrap();
        assert!((horizon - (90.0 + 0.833) / 135.0 * h).abs() < 1e-9, "地平线在下三分之一处");
        let gold: Vec<&Value> = commands.iter().filter(|c| c["style"] == "sun" && c["lineWidth"] == json!(10.0)).collect();
        assert_eq!(gold.len(), 1, "一段黄金时刻一道光");
        assert_eq!(gold[0]["kind"], "polyline");
        assert!((gold[0]["geometry"][0].as_f64().unwrap() - 6.0 / 24.0 * w).abs() < 1e-9, "光从黄金时刻开始的那一刻起");
        let glow_end = gold[0]["geometry"].as_array().unwrap();
        assert!((glow_end[glow_end.len() - 2].as_f64().unwrap() - 7.0 / 24.0 * w).abs() < 1e-9, "到黄金时刻结束的那一刻止");
        let line = commands.iter().find(|c| c["kind"] == "gradient" && c["geometry"][3] == json!(1.0)).unwrap();
        assert!((line["geometry"][1].as_f64().unwrap() - (horizon - 0.5)).abs() < 1e-9, "地平线是 1 点高的一道");
        let sun_runs: Vec<&Value> = commands.iter().filter(|c| c["style"] == "sun" && c["lineWidth"] == json!(2.0)).collect();
        let rims: Vec<&Value> = commands.iter().filter(|c| c["style"] == "sunRim").collect();
        let night_runs: Vec<&Value> = commands.iter().filter(|c| c["style"] == "paper").collect();
        assert_eq!(sun_runs.len(), 1, "白天一段金线");
        assert_eq!(rims.len(), 1);
        assert_eq!(rims[0]["geometry"], sun_runs[0]["geometry"], "外沿与金线同一条");
        assert_eq!(night_runs.len(), 2, "日出前、日落后各一段纸线");
        let points = |c: &Value| c["geometry"].as_array().unwrap().iter().map(|n| n.as_f64().unwrap()).collect::<Vec<f64>>();
        let day_line = points(sun_runs[0]);
        assert_eq!(day_line[1], horizon, "金线从地平线起");
        assert_eq!(day_line[day_line.len() - 1], horizon, "金线落回地平线");
        assert_eq!(points(night_runs[0])[points(night_runs[0]).len() - 2], day_line[0], "上下两段接在日出那一点");
        let solar = crate::astronomy::dispatch("astronomy.compute", json!({"dayStart": t0, "dayEnd": t1, "instant": t0 + 43_200.0,
            "latitude": lat, "longitude": lon})).unwrap();
        let sunrise = solar["solar"]["sunrise"].as_f64().unwrap();
        assert!((day_line[0] - (sunrise - t0) / (t1 - t0) * w).abs() < 0.2, "日出处与天文页的日出差不到 0.2 点");
        // 看的那一刻（当地 13:00）太阳在天上，位置就在金线上。
        let sun = &day["sun"];
        assert_eq!(sun["up"], json!(true));
        assert!((sun["x"].as_f64().unwrap() - 13.0 / 24.0 * w).abs() < 1e-9);
        // 金线的最高点就是这一天太阳最高的地方：伦敦九月中旬约 40°（纵轴 +90° 到 −45° 铺满 h）。
        let top = day_line.iter().skip(1).step_by(2).copied().fold(f64::INFINITY, f64::min);
        let degrees = 90.0 - top / h * 135.0;
        assert!((36.0..44.0).contains(&degrees), "{degrees}");
        // 看的那一刻不在这一天里：不画太阳。
        let other = run("sun_day", json!({"dayStart": t0, "dayEnd": t1, "latitude": lat, "longitude": lon, "width": w, "height": h,
            "instant": t1 + 3600.0}));
        assert!(other["sun"].is_null());
    }

    /// 极昼整天金线、极夜整天纸线；尺寸为零、年份越界、坐标不对都报错，不画半张图。
    #[test]
    fn the_sun_day_in_polar_days_and_bad_input() {
        let polar = 1_782_000_000.0; // 2026-06-21 左右
        let lines = |lat: f64| {
            let v = run("sun_day", json!({"dayStart": polar, "dayEnd": polar + 86_400.0, "latitude": lat, "longitude": 15.6,
                "width": 300.0, "height": 100.0}));
            let c = v["commands"].as_array().unwrap().clone();
            (c.iter().filter(|c| c["style"] == "sun" && c["lineWidth"] == json!(2.0)).count(), c.iter().filter(|c| c["style"] == "paper").count())
        };
        assert_eq!(lines(78.2), (1, 0), "斯瓦尔巴六月：极昼");
        assert_eq!(lines(-78.2), (0, 1), "南纬 78° 六月：极夜");
        let ok = json!({"dayStart": polar, "dayEnd": polar + 86_400.0, "latitude": 0.0, "longitude": 0.0, "width": 10.0, "height": 10.0});
        assert!(dispatch("presentation.sun_day", ok.clone()).is_ok());
        for (key, bad) in [("width", json!(0.0)), ("dayEnd", json!(polar)), ("dayStart", json!(-9e9)), ("latitude", json!(91.0)), ("height", json!(f64::NAN))] {
            let mut input = ok.clone();
            input[key] = bad;
            assert!(dispatch("presentation.sun_day", input).is_err(), "{key}");
        }
    }

    #[test]
    fn window_places_preserves_text_spacing_order_and_only_marks_stretched() {
        let output = run(
            "window_places",
            json!({"outsidePhrase":"outside work hours","nextDay":"%@ next day","previousDay":"%@ previous day","places":[
            {"name":"Paris","time":"09:00","fit":"inside"},
            {"name":"東京","time":"16:00","fit":"stretched","dayOffset":0},
            {"name":"","time":"2:00 PM","fit":"unavailable"}]}),
        );
        assert_eq!(
            output["segments"],
            json!([
            {"text":"Paris 09:00","outside":false},{"text":" · ","outside":false},
            {"text":"東京 16:00","outside":true},{"text":" · ","outside":false},
            {"text":" 2:00 PM","outside":false}])
        );
        assert_eq!(
            output["accessibility"],
            "Paris 09:00, 東京 16:00 outside work hours,  2:00 PM"
        );
        assert_eq!(
            run("window_places", json!({"outsidePhrase":"外","nextDay":"次日 %@","previousDay":"前一日 %@","places":[]})),
            json!({"segments":[],"accessibility":""})
        );
    }

    /// 洛杉矶周一 21:00 = 伦敦周二 5:00 = 东京周二 13:00：行首写的是本机（洛杉矶）的日期，
    /// 另两地的钟点要带「次日」；反向（东京组织者）则带「前一日」。模板的 `%@` 决定前后，
    /// 没有 `%@` 的模板接在钟点后面；无障碍文本同样带标注，且「在工作时间外」仍在最后。
    #[test]
    fn window_places_marks_the_next_and_previous_day_with_each_languages_template() {
        let output = run(
            "window_places",
            json!({"outsidePhrase":"在工作时间外","nextDay":"次日 %@","previousDay":"前一日 %@","places":[
            {"name":"洛杉矶","time":"21:00","fit":"inside","dayOffset":0},
            {"name":"伦敦","time":"5:00","fit":"stretched","dayOffset":1},
            {"name":"东京","time":"13:00","fit":"inside","dayOffset":1}]}),
        );
        assert_eq!(
            output["segments"],
            json!([
            {"text":"洛杉矶 21:00","outside":false},{"text":" · ","outside":false},
            {"text":"伦敦 次日 5:00","outside":true},{"text":" · ","outside":false},
            {"text":"东京 次日 13:00","outside":false}])
        );
        assert_eq!(
            output["accessibility"],
            "洛杉矶 21:00, 伦敦 次日 5:00 在工作时间外, 东京 次日 13:00"
        );
        let english = run(
            "window_places",
            json!({"outsidePhrase":"outside working hours","nextDay":"%@ next day","previousDay":"%@ previous day","places":[
            {"name":"Tokyo","time":"13:00","fit":"inside","dayOffset":0},
            {"name":"Los Angeles","time":"21:00","fit":"stretched","dayOffset":-1}]}),
        );
        assert_eq!(english["segments"][2]["text"], "Los Angeles 21:00 previous day");
        assert_eq!(
            english["accessibility"],
            "Tokyo 13:00, Los Angeles 21:00 previous day outside working hours"
        );
        let plain = run(
            "window_places",
            json!({"outsidePhrase":"外","nextDay":"翌日","previousDay":"前日","places":[
            {"name":"東京","time":"13:00","fit":"inside","dayOffset":2}]}),
        );
        assert_eq!(plain["segments"][0]["text"], "東京 13:00 翌日");
        assert!(dispatch("presentation.window_places", json!({"outsidePhrase":"外","places":[]})).is_err());
    }

    #[test]
    fn planning_today_ceils_without_crossing_day_boundary() {
        assert_eq!(
            run(
                "planning_start",
                json!({"fromDay":0,"todayStart":0,"now":86399,"nextDay":86400})
            ),
            86399.0
        );
        assert_eq!(
            run(
                "planning_start",
                json!({"fromDay":0,"todayStart":0,"now":901,"nextDay":82800})
            ),
            1800.0
        );
        assert_eq!(
            run(
                "planning_start",
                json!({"fromDay":86400,"todayStart":0,"now":901,"nextDay":172800})
            ),
            86400.0
        );
    }
    #[test]
    fn planner_rows_deduplicate_local_and_preserve_city_fallback() {
        let v = json!({"zones":[{"id":"a","timeZoneId":"UTC","customName":null,"cityName":"Original","localizedCity":""}],"excluded":["a"],"localTimeZoneId":"UTC","localName":"Local","includeLocal":true});
        assert_eq!(
            run("planner_rows", v),
            json!([{"sourceIndex":0,"name":"Original","participates":false}])
        );
    }
    #[test]
    fn availability_editor_wraps_negative_and_following_days() {
        for minute in [0, 1, 540, 1439] {
            let date = run("availability_date", json!({"minute":minute}));
            assert_eq!(run("availability_minute", json!({"date":date})), minute);
        }
        assert_eq!(run("availability_minute", json!({"date":1767225540})), 1439);
    }
    #[test]
    fn interval_labels_add_dates_and_zone_names_only_when_needed() {
        let v = json!({"sameDay":false,"startOffset":-28800,"endOffset":-25200,"start":{"time":"23:00","day":"Jan 1","abbreviation":"PST"},"end":{"time":"01:00","day":"Jan 2","abbreviation":"PDT"}});
        assert_eq!(run("interval_text", v), "Jan 1 23:00 PST–Jan 2 01:00 PDT");
    }
    #[test]
    fn offsets_and_scroller_preserve_original_formats_and_clamps() {
        assert_eq!(run("signed_offset", json!({"seconds":-1800})), "−0:30");
        assert_eq!(run("signed_offset", json!({"seconds":3600})), "+1");
        assert_eq!(run("scroll_label", json!({"seconds":11700})), "+3h15m");
        assert_eq!(run("scroll_label", json!({"seconds":62_640})), "+17h24m");
        assert_eq!(run("scroll_label", json!({"seconds":86_340})), "+23h59m", "不到一天照旧写到分钟");
        assert_eq!(run("scroll_label", json!({"seconds":86_400})), "+1d");
        assert_eq!(run("scroll_label", json!({"seconds":-(2.0 * 86_400.0 + 3.0 * 3600.0 + 24.0 * 60.0)})), "−2d3h");
        assert_eq!(run("scroll_label", json!({"seconds":2.0 * 86_400.0 + 3.0 * 3600.0 + 31.0 * 60.0})), "+2d4h", "小时四舍五入");
        assert_eq!(run("scroll_label", json!({"seconds":86_400.0 + 23.0 * 3600.0 + 40.0 * 60.0})), "+2d", "进位到整天");
    }
    #[test]
    fn day_lane_without_coordinates_is_only_the_base_and_the_marker() {
        let commands = run(
            "day_lane",
            json!({"sky":true,"start":0.0,"length":86_400.0,"reference":43_200.0,"width":240.0,"height":10.0}),
        );
        let commands = commands.as_array().unwrap();
        assert_eq!(commands.len(), 3, "{commands:?}");
        assert_eq!(commands[0]["kind"], "rect");
        assert_eq!(commands[0]["style"], "quaternary");
        assert_eq!(commands[1]["kind"], "line");
        assert_eq!(commands[1]["style"], "background");
        assert_eq!(commands[2]["kind"], "line");
        assert_eq!(commands[2]["style"], "primary");
        assert_eq!(commands[2]["geometry"][0], 120.0);
        // 参考时刻在框外时标记钉在边上，不消失。
        let clamped = run(
            "day_lane",
            json!({"sky":true,"start":0.0,"length":86_400.0,"reference":-5.0,"width":240.0,"height":10.0}),
        );
        assert_eq!(clamped[2]["geometry"][0], 0.0);
        assert!(dispatch("presentation.day_lane", json!({"sky":true,"start":0.0,"length":0.0,"reference":0.0,"width":1.0,"height":1.0})).is_err());
    }

    #[test]
    fn overlap_geometry_clips_and_taps_follow_the_actual_dst_day_length() {
        let scene = window_commands(
            &json!({"start":0,"length":82800,"reference":41400,"width":200,"height":8,"windows":[{"start":-900,"end":900,"tier":0}]}),
        );
        assert_eq!(scene[0]["geometry"][0], 0.0);
        let lane = run("day_lane", json!({"sky":true,"start":0,"length":82800,"reference":41400,"width":200,"height":8}));
        assert_eq!(lane.as_array().unwrap().last().unwrap()["geometry"][0], 100.0);
        // 绿色（tier 0）永远画在黄色之后，输入顺序不算数。
        let layered = window_commands(
            &json!({"start":0,"length":86400,"reference":0,"width":100,"height":8,"windows":[
                {"start":3600,"end":7200,"tier":0},{"start":0,"end":10800,"tier":1},{"start":9000,"end":9900,"tier":0}]}),
        );
        let colors: Vec<&str> = layered.as_array().unwrap().iter().filter_map(|c| c["style"].as_str()).collect();
        assert_eq!(colors, ["yellow", "green", "green"]);
        // 同色相邻窗口并成一段：两个折中窗口 8:45–9:45 与 9:15–10:15 只画一个矩形 8:45–10:15。
        let merged = window_commands(
            &json!({"start":0,"length":86400,"reference":0,"width":864,"height":8,"windows":[
                {"start":31500,"end":35100,"tier":1},{"start":33300,"end":36900,"tier":1}]}),
        );
        let rects: Vec<&Value> = merged.as_array().unwrap().iter().filter(|c| c["kind"] == "rect").collect();
        assert_eq!(rects.len(), 1);
        assert_eq!(rects[0]["geometry"], json!([315.0, 0.0, 54.0, 8.0]));
        // 黄色只涂在本行可约带之外：可约 9:00–18:00（32400–64800）时，折中 8:45–10:15 只剩 8:45–9:00 一小段。
        let clipped = window_commands(
            &json!({"start":0,"length":86400,"reference":0,"width":864,"height":8,
                "windows":[{"start":31500,"end":36900,"tier":1}],"available":[{"start":32400,"end":64800}]}),
        );
        let rects: Vec<&Value> = clipped.as_array().unwrap().iter().filter(|c| c["kind"] == "rect").collect();
        assert_eq!(rects.len(), 1);
        assert_eq!(rects[0]["geometry"], json!([315.0, 0.0, 9.0, 8.0]));
        assert_eq!(
            run(
                "overlap_tap",
                json!({"start":0,"length":82800,"x":200,"width":200})
            ),
            82800.0
        );
    }
    #[test]
    fn search_navigation_handles_empty_selection_and_boundaries() {
        assert_eq!(
            run(
                "search_key",
                json!({"ids":["a","b"],"selection":null,"command":"up","query":"x"})
            )["index"],
            1
        );
        assert_eq!(
            run(
                "search_key",
                json!({"ids":["a","b"],"selection":"b","command":"down","query":"x"})
            )["index"],
            1
        );
        assert_eq!(
            run(
                "search_key",
                json!({"ids":[],"selection":null,"command":"cancel","query":""})
            )["handled"],
            false
        );
    }
    #[test]
    fn planner_inputs_use_stable_local_id_and_require_two_selected_places() {
        let value = run(
            "planner_inputs",
            json!({"rows":[{"id":null,"participates":true},{"id":"abcd","participates":false}],
            "fromDay":0,"todayStart":0,"now":1,"nextDay":86400}),
        );
        assert_eq!(
            value["participants"],
            json!([{"index":0,"id":"00000000-0000-0000-0000-000000000000"}])
        );
        assert_eq!(value["canPlan"], false);
        assert_eq!(value["notBefore"], 900.0);
    }
    #[test]
    fn layout_values_preserve_existing_small_screen_and_scaled_row_limits() {
        // 单一滚动区的预算 = 可见高 − 160 固定部分，矮屏保底 320。
        assert_eq!(run("panel_layout", json!({"screenHeight":800,"expanded":true})), json!({"body":640.0}));
        assert_eq!(run("panel_layout", json!({"screenHeight":861,"expanded":false})), json!({"body":701.0}));
        assert_eq!(run("panel_layout", json!({"screenHeight":400,"expanded":true})), json!({"body":320.0}));
        assert_eq!(
            run("search_height", json!({"count":9,"rowHeight":40})),
            240.0
        );
        assert_eq!(
            run("availability_label_date", json!({"minute":-5})),
            1767225600.0
        );
        assert_eq!(
            run("availability_label_date", json!({"minute":1445})),
            1767312000.0
        );
    }
    #[test]
    fn stale_search_selection_does_not_commit_another_city() {
        let value = run(
            "search_key",
            json!({"ids":["first"],"selection":"gone","command":"commit","query":"x"}),
        );
        assert_eq!(value["handled"], true);
        assert_eq!(value["index"], Value::Null);
        assert_eq!(value["commit"], false);
    }

    /// 性质测试：随机窗口与可约带下，把画出来的矩形按「后画的盖住先画的」栅格化，逐像素与原始输入对照——
    /// 绿 ⇔ 该时刻在某个「所有人都合适」窗口里；黄 ⇔ 在某个折中窗口里、不在本行可约带里、也不绿；否则空。
    /// 另核：所有矩形都在 [0, width] 内且宽度为正、黄全部先于绿、此刻线最后。
    #[test]
    fn random_overlap_scenes_rasterize_back_to_their_inputs() {
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
        let iterations: u64 = std::env::var("MEANTIME_FUZZ_ITERATIONS").ok().and_then(|v| v.parse().ok()).unwrap_or(500);
        let seed_offset: u64 = std::env::var("MEANTIME_FUZZ_SEED").ok().and_then(|v| v.parse().ok()).unwrap_or(0);
        let mut rng = Xor(0x5CE7_E5CE_5EED_0001_u64.wrapping_add(seed_offset));
        let mut samples = 0usize;
        for i in 0..iterations {
            let start = (rng.below(1_000_000) * 60) as f64;
            let length = [82_800.0, 86_400.0, 90_000.0][rng.below(3) as usize];
            let width = 100.0 + rng.below(900) as f64;
            let span = |rng: &mut Xor| {
                // 一律对齐到 15 分钟格，边界正好落在采样点上也算数。
                let a = start - 7_200.0 + (rng.below(120) * 900) as f64;
                (a, a + (900 * (1 + rng.below(24))) as f64)
            };
            let windows: Vec<(f64, f64, u8)> = (0..rng.below(7)).map(|_| { let (a, b) = span(&mut rng); (a, b, rng.below(2) as u8) }).collect();
            let available: Vec<(f64, f64)> = (0..rng.below(4)).map(|_| span(&mut rng)).collect();
            let input = json!({"start": start, "length": length, "reference": start + rng.below(90_000) as f64,
                "width": width, "height": 8,
                "windows": windows.iter().map(|(a, b, t)| json!({"start": a, "end": b, "tier": t})).collect::<Vec<_>>(),
                "available": available.iter().map(|(a, b)| json!({"start": a, "end": b})).collect::<Vec<_>>()});
            let scene = window_commands(&input);
            let commands = scene.as_array().unwrap();
            let rects: Vec<(f64, f64, &str)> = commands.iter().filter(|c| c["kind"] == "rect")
                .map(|c| (c["geometry"][0].as_f64().unwrap(), c["geometry"][0].as_f64().unwrap() + c["geometry"][2].as_f64().unwrap(), c["style"].as_str().unwrap()))
                .collect();
            for &(x0, x1, color) in &rects {
                assert!(x0 >= -1e-9 && x1 <= width + 1e-9 && x1 > x0, "#{i} 矩形 {x0}–{x1} 出了 [0, {width}]");
                assert!(color == "green" || color == "yellow", "#{i} 颜色 {color}");
            }
            let first_green = rects.iter().position(|r| r.2 == "green").unwrap_or(rects.len());
            assert!(rects[first_green..].iter().all(|r| r.2 == "green"), "#{i} 黄色画在了绿色之后");
            let mut lane_input = input;
            lane_input["sky"] = json!(true);
            let lane = run("day_lane", lane_input);
            assert_eq!(lane.as_array().unwrap().last().unwrap()["kind"], "line", "#{i} 此刻线不在最后");
            // 逐像素对照：在 15 分钟格的中点采样（边界本身两边都对）。
            let mut t = start + 450.0;
            while t < start + length {
                let x = (t - start) / length * width;
                let drawn = rects.iter().rev().find(|r| r.0 <= x && x < r.1).map_or("none", |r| r.2);
                let green = windows.iter().any(|(a, b, tier)| *tier == 0 && *a <= t && t < *b);
                let compromise = windows.iter().any(|(a, b, tier)| *tier == 1 && *a <= t && t < *b);
                let free = available.iter().any(|(a, b)| *a <= t && t < *b);
                let expected = if green { "green" } else if compromise && !free { "yellow" } else { "none" };
                assert_eq!(drawn, expected, "#{i} 时刻 {t}（x={x:.2}）画的是 {drawn}，输入说该是 {expected}；窗口 {windows:?} 可约 {available:?} 矩形 {rects:?}");
                samples += 1;
                t += 900.0;
            }
        }
        assert!(samples > 0);
        eprintln!("[overlap property] {iterations} 幅随机时间轴，逐格核 {samples} 个采样点");
    }
}
