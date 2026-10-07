// SPDX-License-Identifier: GPL-3.0-only
//! 昼夜条与共享绘图命令。宿主只把命令画成形状。
use serde::Serialize;
use serde_json::Value;

fn number(v: &Value, key: &str) -> Result<f64, String> {
    v.get(key)
        .and_then(Value::as_f64)
        .filter(|n| n.is_finite())
        .ok_or_else(|| format!("Missing finite number: {key}"))
}

/// 渐变的一个色标（位置 0…1、"#rrggbb"）。
#[derive(Debug, Serialize)]
pub(crate) struct Stop {
    pub(crate) at: f64,
    pub(crate) color: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Command {
    pub(crate) kind: &'static str,
    pub(crate) geometry: Vec<f64>,
    pub(crate) style: &'static str,
    pub(crate) opacity: f64,
    pub(crate) line_width: f64,
    /// `gradient`（横向渐变填满 geometry 那个矩形）的色标；别的命令没有。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) stops: Option<Vec<Stop>>,
}
pub(crate) fn command(
    kind: &'static str,
    geometry: Vec<f64>,
    style: &'static str,
    opacity: f64,
    line_width: f64,
) -> Command {
    Command {
        kind,
        geometry,
        style,
        opacity,
        line_width,
        stops: None,
    }
}

/// 从一组有序不相交区间里减掉另一组区间，保留剩下的段（用于「黄色只涂在可约带之外」）。
pub(crate) fn subtract_spans(spans: Vec<(f64, f64)>, holes: &[(f64, f64)]) -> Vec<(f64, f64)> {
    let mut out = Vec::new();
    for (mut s, e) in spans {
        let mut sorted: Vec<&(f64, f64)> = holes.iter().collect();
        sorted.sort_by(|a, b| a.0.total_cmp(&b.0));
        for &(hs, he) in sorted {
            if he <= s || hs >= e {
                continue;
            }
            if hs > s {
                out.push((s, hs));
            }
            s = s.max(he);
            if s >= e {
                break;
            }
        }
        if s < e {
            out.push((s, e));
        }
    }
    out
}

/// 重叠窗口只画在 `top` 起、高 `height` 的细轨里。
pub(crate) fn push_windows_in(commands: &mut Vec<Command>, v: &Value, start: f64, length: f64, width: f64, top: f64, height: f64) -> Result<(), String> {
    // 黄色（折中）先画、绿色（所有人都合适）后画：两类时段常常重叠，按输入顺序画会让黄色盖住绿色，
    // 轴上几乎看不见「所有人都合适」。同一色的相邻窗口先并成一段再画：两个折中
    // 窗口 8:45–9:45 与 9:15–10:15 各画一次会在重叠处叠出第二种黄。
    let Some(windows) = v.get("windows").and_then(Value::as_array) else { return Ok(()) };
    // 本行的可约区间：黄色（折中）只涂在它们之外，图上的黄就只有一个意思「这个人在时段外」；盖在蓝色可约带上的
    // 半透明黄会变成第二种黄。绿色（所有人都合适）不裁。
    let available: Vec<(f64, f64)> = match v.get("available").and_then(Value::as_array) {
        Some(items) => items
            .iter()
            .map(|w| Ok((number(w, "start")?, number(w, "end")?)))
            .collect::<Result<_, String>>()?,
        None => Vec::new(),
    };
    for tier_is_everyone in [false, true] {
        let mut spans: Vec<(f64, f64)> = windows
            .iter()
            .filter(|w| (w["tier"] == 0) == tier_is_everyone)
            .map(|w| Ok((number(w, "start")?, number(w, "end")?)))
            .collect::<Result<_, String>>()?;
        spans.sort_by(|a, b| a.0.total_cmp(&b.0));
        let mut merged: Vec<(f64, f64)> = Vec::new();
        for (s, e) in spans {
            match merged.last_mut() {
                Some(last) if s <= last.1 => last.1 = last.1.max(e),
                _ => merged.push((s, e)),
            }
        }
        if !tier_is_everyone {
            merged = subtract_spans(merged, &available);
        }
        for (s, e) in merged {
            let x0 = ((s - start) / length).max(0.0) * width;
            let x1 = ((e - start) / length).min(1.0) * width;
            if x1 > x0 {
                commands.push(command(
                    "rect",
                    vec![x0, top, x1 - x0, height],
                    if tier_is_everyone { "green" } else { "yellow" },
                    0.75,
                    0.0,
                ));
            }
        }
    }
    Ok(())
}

/// 昼夜条的天色、可约段与参考线。
pub(crate) fn day_lane(v: &Value) -> Result<Value, String> {
    let start = number(v, "start")?;
    let length = number(v, "length")?;
    let width = number(v, "width")?;
    let height = number(v, "height")?;
    if length <= 0.0 {
        return Err("Day length must be positive".into());
    }
    serde_json::to_value(sky_lane(v, start, length, width, height)?).map_err(|e| e.to_string())
}

/// 天色版的昼夜条（`sky: true`）。上面一条是这个地方这段时间真实的天（`sky::lane_stops` 每 10 分钟一个色标，
/// 宿主画成横向渐变；没有坐标就是中性的底）。可约 / 工作段与排会窗口不再半透明地盖在天色上（颜色会搅浑、夜里的蓝看不见），
/// 挪到底下一道细轨里：轨底中性、可约段用它的角色色画实、窗口照旧黄 / 绿（黄只在可约段之外）。参考时刻是一道竖线，
/// 先画一道 3.5 宽的底色衬边再画 1.5 宽的主色线，深浅天色上都看得见。没有可约段也没有窗口时整条都是天。
/// 「不使用颜色区分」开着时（`marks`）另在天色上画昼夜边界的刻度（`push_band_marks`）。
fn sky_lane(v: &Value, start: f64, length: f64, width: f64, height: f64) -> Result<Vec<Command>, String> {
    let nonempty = |key: &str| v.get(key).and_then(Value::as_array).is_some_and(|a| !a.is_empty());
    let track = if nonempty("available") || nonempty("windows") { (height * 0.36).clamp((height / 2.0).min(2.5), height / 2.0) } else { 0.0 };
    let gap = if track > 0.0 { (height - 2.0 * track).clamp(0.0, 1.0) } else { 0.0 };
    let strip = (height - track - gap).max(0.0);
    let mut commands = Vec::new();
    match (v["latitude"].as_f64(), v["longitude"].as_f64()) {
        (Some(lat), Some(lon)) if (-90.0..=90.0).contains(&lat) && (-180.0..=180.0).contains(&lon) => {
            let stops = crate::sky::lane_stops(start, start + length, lat, lon, 10.0).into_iter().map(|(at, color)| Stop { at, color }).collect();
            commands.push(Command { kind: "gradient", geometry: vec![0.0, 0.0, width, strip], style: "sky", opacity: 1.0, line_width: 0.0, stops: Some(stops) });
            if v["marks"] == true {
                push_band_marks(&mut commands, start, start + length, lat, lon, width, strip);
            }
        }
        _ => commands.push(command("rect", vec![0.0, 0.0, width, strip], "quaternary", 1.0, 0.0)),
    }
    if track > 0.0 {
        let top = height - track;
        commands.push(command("rect", vec![0.0, top, width, track], "quaternary", 1.0, 0.0));
        let style = if v["availableStyle"] == "green" { "green" } else { "available" };
        if let Some(items) = v.get("available").and_then(Value::as_array) {
            for band in items {
                let x0 = ((number(band, "start")? - start) / length).max(0.0) * width;
                let x1 = ((number(band, "end")? - start) / length).min(1.0) * width;
                if x1 > x0 {
                    commands.push(command("rect", vec![x0, top, x1 - x0, track], style, 0.9, 0.0));
                }
            }
        }
        push_windows_in(&mut commands, v, start, length, width, top, track)?;
    }
    let marker = ((number(v, "reference")? - start) / length).clamp(0.0, 1.0) * width;
    commands.push(command("line", vec![marker, -2.0, marker, height + 2.0], "background", 1.0, 3.5));
    commands.push(command("line", vec![marker, -2.0, marker, height + 2.0], "primary", 1.0, 1.5));
    Ok(commands)
}

/// 「不使用颜色区分」的刻度：昼夜条的昼 / 曙暮 / 夜只靠颜色分，色弱或单色输出上读不出；
/// 在 `daylight_bands` 相邻两段的每个边界画一道 tick——昼接曙暮（日出 / 日落）整条天色高，曙暮接夜（晨光始 / 昏影终）
/// 从顶上只半条高。画法与参考线同一套：先一道底色衬边（2.5 宽）再一道主色线（1 宽），深浅天色上都看得见。
pub(crate) fn push_band_marks(commands: &mut Vec<Command>, start: f64, end: f64, latitude: f64, longitude: f64, width: f64, strip: f64) {
    for pair in crate::astronomy::daylight_bands(start, end, latitude, longitude).windows(2) {
        let bottom = match (pair[0].2, pair[1].2) {
            (2, 1) | (1, 2) => strip,
            (1, 0) | (0, 1) => strip / 2.0,
            _ => continue,
        };
        let x = (pair[0].1 - start) / (end - start) * width;
        commands.push(command("line", vec![x, 0.0, x, bottom], "background", 1.0, 2.5));
        commands.push(command("line", vec![x, 0.0, x, bottom], "primary", 1.0, 1.0));
    }
}

#[cfg(test)]
mod sky_lane_tests {
    use super::*;
    use serde_json::json;

    fn lane(extra: Value) -> Vec<Value> {
        let mut input = json!({"start": 1_790_000_000.0, "length": 86_400.0, "reference": 1_790_030_000.0,
                               "width": 240.0, "height": 10.0, "latitude": 51.5, "longitude": -0.1, "sky": true});
        for (k, value) in extra.as_object().unwrap() {
            input[k] = value.clone();
        }
        day_lane(&input).unwrap().as_array().unwrap().clone()
    }

    /// 没有可约段与窗口：整条是天（一条渐变），只加参考线的衬边与主线；不再有昼 / 曙暮的半透明色块。
    #[test]
    fn a_bare_sky_lane_is_all_sky() {
        let commands = lane(json!({}));
        assert_eq!(commands[0]["kind"], "gradient");
        assert_eq!(commands[0]["geometry"], json!([0.0, 0.0, 240.0, 10.0]));
        let stops = commands[0]["stops"].as_array().unwrap();
        assert_eq!(stops.len(), 145, "一天每 10 分钟一个色标");
        assert_eq!(stops[0]["at"], 0.0);
        assert_eq!(stops[144]["at"], 1.0);
        assert!(commands.iter().all(|c| c["style"] != "day"));
        let styles: Vec<&str> = commands[1..].iter().map(|c| c["style"].as_str().unwrap()).collect();
        assert_eq!(styles, ["background", "primary"]);
    }

    /// 有可约段：天在上、细轨在下（中间 1 点空），可约段只画在轨里；黄色窗口只在可约段之外，绿色不裁。
    #[test]
    fn schedules_live_in_a_track_under_the_sky() {
        let commands = lane(json!({"available": [{"start": 1_790_010_000.0, "end": 1_790_040_000.0}],
                                   "windows": [{"start": 1_790_035_000.0, "end": 1_790_045_000.0, "tier": 1},
                                               {"start": 1_790_020_000.0, "end": 1_790_024_000.0, "tier": 0}]}));
        let sky = &commands[0];
        let strip = sky["geometry"][3].as_f64().unwrap();
        let track: Vec<&Value> = commands.iter().filter(|c| c["geometry"][1].as_f64().unwrap_or(0.0) > strip).collect();
        assert!((5.0..10.0).contains(&strip), "{strip}");
        assert!(track.iter().any(|c| c["style"] == "quaternary"));
        let available = commands.iter().find(|c| c["style"] == "available").unwrap();
        assert!(available["geometry"][1].as_f64().unwrap() > strip, "可约段在轨里");
        let yellow = commands.iter().find(|c| c["style"] == "yellow").unwrap();
        let x_available_end = (1_790_040_000.0 - 1_790_000_000.0) / 86_400.0 * 240.0;
        assert!(yellow["geometry"][0].as_f64().unwrap() >= x_available_end - 1e-9, "黄只在可约段之外");
        assert!(commands.iter().any(|c| c["style"] == "green"));
    }

    /// 没有坐标：天那一条是中性底，不猜天色。
    #[test]
    fn without_a_place_the_strip_is_neutral() {
        let commands = lane(json!({"latitude": null, "longitude": null}));
        assert_eq!(commands[0]["kind"], "rect");
        assert_eq!(commands[0]["style"], "quaternary");
    }

    /// 「不使用颜色区分」的刻度（`marks`）：缺省与 false 是同一份命令；true 时伦敦 2026-09-17（UTC 一整天）
    /// 恰好 2 道全高（日出 / 日落）+ 2 道半高（晨光始 / 昏影终），x 与 `daylight_bands` 的边界对得上、都落在条内；
    /// 没有坐标、极昼都一道不画。刻度的衬边 2.5 宽、主线 1 宽（参考线是 3.5 / 1.5，认不错）。
    #[test]
    fn sky_lane_marks_only_when_asked() {
        let day = 86_400.0;
        // 2026-09-17 00:00:00 UTC。
        let start = 1_789_603_200.0;
        let london = json!({"start": start, "latitude": 51.507, "longitude": -0.128});
        let today = lane(london.clone());
        let mut off = london.clone();
        off["marks"] = json!(false);
        assert_eq!(lane(off), today, "marks: false 与缺省同一份命令");

        let mut asked = london;
        asked["marks"] = json!(true);
        let marked = lane(asked);
        assert_eq!(marked.len(), today.len() + 8, "四条边界 × 衬边与主线两道");
        assert_eq!(marked[0], today[0], "天色渐变原样");
        assert_eq!(&marked[marked.len() - 2..], &today[today.len() - 2..], "参考线原样、仍在最后");

        let bands = crate::astronomy::daylight_bands(start, start + day, 51.507, -0.128);
        let kinds: Vec<u8> = bands.iter().map(|b| b.2).collect();
        assert_eq!(kinds, vec![0, 1, 2, 1, 0], "夜—曙暮—昼—曙暮—夜");
        let expected: Vec<(f64, bool)> = bands
            .windows(2)
            .filter_map(|pair| match (pair[0].2, pair[1].2) {
                (2, 1) | (1, 2) => Some((pair[0].1, true)),
                (1, 0) | (0, 1) => Some((pair[0].1, false)),
                _ => None,
            })
            .collect();
        assert_eq!(expected.iter().filter(|e| e.1).count(), 2, "日出与日落两道全高");
        assert_eq!(expected.iter().filter(|e| !e.1).count(), 2, "晨光始与昏影终两道半高");

        let strip = marked[0]["geometry"][3].as_f64().unwrap();
        let ticks: Vec<&Value> = marked.iter().filter(|c| c["lineWidth"].as_f64() == Some(2.5)).collect();
        let mains: Vec<&Value> = marked.iter().filter(|c| c["lineWidth"].as_f64() == Some(1.0)).collect();
        assert_eq!(ticks.len(), 4, "四道衬边");
        assert_eq!(mains.len(), 4, "四道主线");
        for tick in &ticks {
            assert!(mains.iter().any(|m| m["geometry"] == tick["geometry"]), "每道刻度是衬边 + 主线一对，几何一致");
        }
        for (time, full) in expected {
            let want_x = (time - start) / day * 240.0;
            assert!((0.0..=240.0).contains(&want_x), "x 要落在条内：{want_x}");
            let found = ticks
                .iter()
                .find(|t| (t["geometry"][0].as_f64().unwrap() - want_x).abs() < 1e-6)
                .unwrap_or_else(|| panic!("边界 {time} 处应有刻度"));
            assert_eq!(found["geometry"][3].as_f64().unwrap(), if full { strip } else { strip / 2.0 });
        }

        let mut nowhere = json!({"start": start, "latitude": null, "longitude": null});
        let nowhere_plain = lane(nowhere.clone());
        nowhere["marks"] = json!(true);
        assert_eq!(lane(nowhere), nowhere_plain, "没有坐标不画刻度");

        // 78.2°N 2026-06-21：极昼，整天一段昼、没有边界。
        let polar = 1_782_000_000.0;
        assert_eq!(crate::astronomy::daylight_bands(polar, polar + day, 78.2, 15.6).iter().map(|b| b.2).collect::<Vec<_>>(), vec![2u8]);
        let mut polar_asked = json!({"start": polar, "latitude": 78.2, "longitude": 15.6});
        let polar_plain = lane(polar_asked.clone());
        polar_asked["marks"] = json!(true);
        assert_eq!(lane(polar_asked), polar_plain, "极昼没有边界，不画刻度");
    }
}
