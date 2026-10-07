// SPDX-License-Identifier: GPL-3.0-only
//! On-demand geocentric astronomy. The host supplies actual civil-day bounds;
//! this module never assumes that a local day lasts 24 hours and owns no timer.
//! Solar geometry follows NOAA/Meeus. Moon longitude uses the largest 30 terms
//! of Meeus 47.A, with eccentricity and additive corrections. Results are
//! estimates for planning, not an ephemeris.
use serde::Deserialize;
use serde_json::{json, Value};

const DAY: f64 = 86_400.0;

/// 本模块承诺的时刻范围（1800-01-01 … 2101-01-01 UTC，与 `compute` / `seasons` 的检查同一对数）：
/// 范围外的日期没有验证过，调用方按「不支持」处理；它也挡住 ±1e300 这种会把多项式算成 NaN 的输入。
pub(crate) const SUPPORTED_UNIX: std::ops::RangeInclusive<f64> = -5_364_662_400.0..=4_133_980_800.0;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Input {
    day_start: f64,
    day_end: f64,
    instant: f64,
    latitude: f64,
    longitude: f64,
}

fn rad(x: f64) -> f64 {
    x.to_radians()
}
fn sin(x: f64) -> f64 {
    rad(x).sin()
}
fn cos(x: f64) -> f64 {
    rad(x).cos()
}
fn cycle(x: f64) -> f64 {
    x.rem_euclid(360.0)
}
fn centuries(unix: f64) -> f64 {
    (unix / DAY + 2_440_587.5 - 2_451_545.0) / 36_525.0
}

pub(crate) struct Sun {
    longitude: f64,
    pub(crate) declination: f64,
    pub(crate) equation: f64,
}

pub(crate) fn sun(unix: f64) -> Sun {
    let t = centuries(unix);
    let l0 = cycle(280.46646 + t * (36000.76983 + t * 0.0003032));
    let m = 357.52911 + t * (35999.05029 - t * 0.0001537);
    let e = 0.016708634 - t * (0.000042037 + t * 0.0000001267);
    let center = sin(m) * (1.914602 - t * (0.004817 + t * 0.000014))
        + sin(2.0 * m) * (0.019993 - t * 0.000101)
        + sin(3.0 * m) * 0.000289;
    let omega = 125.04 - 1934.136 * t;
    let longitude = l0 + center - 0.00569 - 0.00478 * sin(omega);
    let eps = obliquity_at(t);
    let declination = (sin(eps) * sin(longitude)).asin();
    let y = rad(eps / 2.0).tan().powi(2);
    let equation = 4.0
        * (y * sin(2.0 * l0) - 2.0 * e * sin(m) + 4.0 * e * y * sin(m) * cos(2.0 * l0)
            - 0.5 * y * y * sin(4.0 * l0)
            - 1.25 * e * e * sin(2.0 * m))
        .to_degrees();
    Sun {
        longitude,
        declination,
        equation,
    }
}

/// 黄赤交角（度）：平交角（Meeus 22.2）加 NOAA 的章动近似 0.00256° cos Ω。`sun` 与昼夜地图的月下点共用这一份，
/// 从 `sun` 里原样搬出来（同样的运算顺序，数值逐位不变）。
fn obliquity_at(t: f64) -> f64 {
    let omega = 125.04 - 1934.136 * t;
    let eps0 = 23.0 + (26.0 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60.0) / 60.0;
    eps0 + 0.00256 * cos(omega)
}

pub(crate) fn obliquity(unix: f64) -> f64 {
    obliquity_at(centuries(unix))
}

pub(crate) fn elevation(unix: f64, latitude: f64, longitude: f64) -> f64 {
    let s = sun(unix);
    let hour_angle =
        rad((unix.rem_euclid(DAY) / 60.0 + s.equation + 4.0 * longitude) / 4.0 - 180.0);
    let cosine = sin(latitude) * s.declination.sin()
        + cos(latitude) * s.declination.cos() * hour_angle.cos();
    cosine.clamp(-1.0, 1.0).asin().to_degrees()
}

fn bisect(mut a: f64, mut b: f64, f: impl Fn(f64) -> f64) -> f64 {
    let initial = f(a).is_sign_positive();
    for _ in 0..40 {
        let middle = (a + b) / 2.0;
        if f(middle).is_sign_positive() == initial {
            a = middle;
        } else {
            b = middle;
        }
    }
    (a + b) / 2.0
}

fn solar(input: &Input) -> Value {
    let at = |t| elevation(t, input.latitude, input.longitude);
    let slope = |t| at(t + 30.0) - at(t - 30.0);
    // Partition at extrema before crossing tests, so even brief polar sunrise
    // intervals aren't lost between fixed time samples.
    let mut knots = vec![input.day_start, input.day_end];
    let mut previous = input.day_start;
    for i in 1..=48 {
        let next = input.day_start + (input.day_end - input.day_start) * f64::from(i) / 48.0;
        if slope(previous).is_sign_positive() != slope(next).is_sign_positive() {
            knots.push(bisect(previous, next, slope));
        }
        previous = next;
    }
    knots.sort_by(f64::total_cmp);
    knots.dedup_by(|a, b| (*a - *b).abs() < 0.01);
    let crossings = |level: f64| -> Vec<f64> {
        let mut roots = vec![];
        for pair in knots.windows(2) {
            if (at(pair[0]) - level).is_sign_positive() != (at(pair[1]) - level).is_sign_positive()
            {
                roots.push(bisect(pair[0], pair[1], |t| at(t) - level));
            }
        }
        roots
    };
    let horizon = crossings(-0.833);
    let mut daylight = 0.0;
    let mut boundaries = vec![input.day_start];
    boundaries.extend(horizon.iter().copied());
    boundaries.push(input.day_end);
    for pair in boundaries.windows(2) {
        if at((pair[0] + pair[1]) / 2.0) >= -0.833 {
            daylight += pair[1] - pair[0];
        }
    }
    let rise = horizon.iter().find(|&&t| slope(t) > 0.0).copied();
    let set = horizon.iter().find(|&&t| slope(t) < 0.0).copied();
    let kind = if horizon.is_empty() && daylight == 0.0 {
        "polarNight"
    } else if horizon.is_empty() {
        "polarDay"
    } else {
        "normal"
    };
    // Product convention: geometric solar elevation from -4° through +6°.
    let mut golden_bounds = vec![input.day_start, input.day_end];
    golden_bounds.extend(crossings(-4.0));
    golden_bounds.extend(crossings(6.0));
    golden_bounds.sort_by(f64::total_cmp);
    let golden: Vec<_> = golden_bounds
        .windows(2)
        .filter_map(|pair| {
            let altitude = at((pair[0] + pair[1]) / 2.0);
            ((-4.0..=6.0).contains(&altitude) && pair[1] - pair[0] > 0.01)
                .then(|| json!({"start":pair[0],"end":pair[1]}))
        })
        .collect();
    let noon = knots
        .iter()
        .filter(|&&t| t > input.day_start && t < input.day_end)
        .max_by(|&&a, &&b| at(a).total_cmp(&at(b)))
        .copied()
        .filter(|&t| slope(t - 60.0) > 0.0 && slope(t + 60.0) < 0.0);
    let samples: Vec<_> = (0..=48)
        .map(|i| {
            let instant = input.day_start + (input.day_end - input.day_start) * f64::from(i) / 48.0;
            json!({"instant":instant,"elevation":at(instant)})
        })
        .collect();
    json!({"kind":kind,"daylightSeconds":daylight,"sunrise":rise,"sunset":set,
           "solarNoon":noon,"golden":golden,"samples":samples})
}

/// 昼夜条用的三段分类：把绝对时间区间 [start, end] 按几何太阳高度切成
/// 夜（< −6°，民用曙暮光以下）/ 曙暮（−6° … −0.833°）/ 昼（≥ −0.833°，与 `solar` 的地平线同一判据）
/// 三类连续区段，按时间排好。极昼极夜自然落成单段。找边界的办法与 `solar` 相同：先在高度的极值处
/// 切开，再在每一段里二分找两条水平线的穿越点，所以短到几分钟的极地日出也不会漏在采样之间。
/// 类别：0 = 夜，1 = 曙暮，2 = 昼。
pub(crate) fn daylight_bands(start: f64, end: f64, latitude: f64, longitude: f64) -> Vec<(f64, f64, u8)> {
    if end <= start || !start.is_finite() || !end.is_finite() {
        return Vec::new();
    }
    let at = |t| elevation(t, latitude, longitude);
    let slope = |t| at(t + 30.0) - at(t - 30.0);
    let mut knots = vec![start, end];
    let steps = ((end - start) / 1800.0).ceil().clamp(8.0, 96.0) as u32;
    let mut previous = start;
    for i in 1..=steps {
        let next = start + (end - start) * f64::from(i) / f64::from(steps);
        if slope(previous).is_sign_positive() != slope(next).is_sign_positive() {
            knots.push(bisect(previous, next, slope));
        }
        previous = next;
    }
    // 极值结点要先排好序：`windows(2)` 按相邻对找穿越点，乱序时 [终点, 子夜] 这种对会把整个下午吞掉。
    knots.sort_by(f64::total_cmp);
    knots.dedup_by(|a, b| (*a - *b).abs() < 0.5);
    for level in [-6.0, -0.833] {
        let mut roots = vec![];
        for pair in knots.windows(2) {
            if (at(pair[0]) - level).is_sign_positive() != (at(pair[1]) - level).is_sign_positive() {
                roots.push(bisect(pair[0], pair[1], |t| at(t) - level));
            }
        }
        knots.extend(roots);
        knots.sort_by(f64::total_cmp);
        knots.dedup_by(|a, b| (*a - *b).abs() < 0.5);
    }
    let class = |t: f64| -> u8 {
        let h = at(t);
        if h >= -0.833 {
            2
        } else if h >= -6.0 {
            1
        } else {
            0
        }
    };
    let mut bands: Vec<(f64, f64, u8)> = Vec::new();
    for pair in knots.windows(2) {
        if pair[1] - pair[0] < 0.5 {
            continue;
        }
        let kind = class((pair[0] + pair[1]) / 2.0);
        match bands.last_mut() {
            Some(last) if last.2 == kind => last.1 = pair[1],
            _ => bands.push((pair[0], pair[1], kind)),
        }
    }
    bands
}

/// 月球地心黄经与黄纬（度；当日平春分点，未加章动）。
pub(crate) fn lunar_coordinates(unix: f64) -> (f64, f64) {
    let t = centuries(unix);
    let l = cycle(
        218.3164477 + 481267.88123421 * t - 0.0015786 * t * t + t.powi(3) / 538841.0
            - t.powi(4) / 65194000.0,
    );
    let d = cycle(
        297.8501921 + 445267.1114034 * t - 0.0018819 * t * t + t.powi(3) / 545868.0
            - t.powi(4) / 113065000.0,
    );
    let m = cycle(357.5291092 + 35999.0502909 * t - 0.0001536 * t * t + t.powi(3) / 24490000.0);
    let p = cycle(
        134.9633964 + 477198.8675055 * t + 0.0087414 * t * t + t.powi(3) / 69699.0
            - t.powi(4) / 14712000.0,
    );
    let f = cycle(
        93.2720950 + 483202.0175233 * t - 0.0036539 * t * t - t.powi(3) / 3526000.0
            + t.powi(4) / 863310000.0,
    );
    let e = 1.0 - 0.002516 * t - 0.0000074 * t * t;
    let terms: [(i32, i32, i32, i32, f64); 30] = [
        (0, 0, 1, 0, 6288774.),
        (2, 0, -1, 0, 1274027.),
        (2, 0, 0, 0, 658314.),
        (0, 0, 2, 0, 213618.),
        (0, 1, 0, 0, -185116.),
        (0, 0, 0, 2, -114332.),
        (2, 0, -2, 0, 58793.),
        (2, -1, -1, 0, 57066.),
        (2, 0, 1, 0, 53322.),
        (2, -1, 0, 0, 45758.),
        (0, 1, -1, 0, -40923.),
        (1, 0, 0, 0, -34720.),
        (0, 1, 1, 0, -30383.),
        (2, 0, 0, -2, 15327.),
        (0, 0, 1, 2, -12528.),
        (0, 0, 1, -2, 10980.),
        (4, 0, -1, 0, 10675.),
        (0, 0, 3, 0, 10034.),
        (4, 0, -2, 0, 8548.),
        (2, 1, -1, 0, -7888.),
        (2, 1, 0, 0, -6766.),
        (1, 0, -1, 0, -5163.),
        (1, 1, 0, 0, 4987.),
        (2, -1, 1, 0, 4036.),
        (2, 0, 2, 0, 3994.),
        (4, 0, 0, 0, 3861.),
        (2, 0, -3, 0, 3665.),
        (0, 1, -2, 0, -2689.),
        (2, 0, -1, 2, -2602.),
        (2, -1, -2, 0, 2390.),
    ];
    let mut correction: f64 = terms
        .iter()
        .map(|&(dd, mm, pp, ff, c)| {
            c * e.powi(mm.abs())
                * sin(f64::from(dd) * d + f64::from(mm) * m + f64::from(pp) * p + f64::from(ff) * f)
        })
        .sum();
    correction += 3958.0 * sin(119.75 + 131.849 * t)
        + 1962.0 * sin(l - f)
        + 318.0 * sin(53.09 + 479264.290 * t);
    // Dominant latitude terms suffice for the displayed illumination estimate.
    let latitude = 5.128122 * sin(f)
        + 0.280602 * sin(p + f)
        + 0.277693 * sin(p - f)
        + 0.173237 * sin(2.0 * d - f)
        + 0.055413 * sin(2.0 * d - p + f)
        + 0.046271 * sin(2.0 * d - p - f);
    (cycle(l + correction / 1_000_000.0), latitude)
}

fn phase_angle(unix: f64) -> f64 {
    cycle(lunar_coordinates(unix).0 - sun(unix).longitude)
}

fn phase_events(start: f64, end: f64, target: f64) -> Vec<f64> {
    let difference = |t| (phase_angle(t) - target + 180.0).rem_euclid(360.0) - 180.0;
    let mut result = vec![];
    let mut a = start;
    while a < end {
        let b = (a + DAY).min(end);
        if difference(a) <= 0.0 && difference(b) > 0.0 {
            result.push(bisect(a, b, difference));
        }
        a = b;
    }
    result
}

/// 此刻的月相三样：名字、在朔望月里的位置（0 … 1）、照亮比例。太阳与月亮页（`moon`）和昼夜地图共用这一份，
/// 两边报出来的数逐位相同；不含找上一次朔、下一次朔望的 35 天搜索（那是天文页才要的，地图每帧都算）。
pub(crate) struct MoonPhase {
    pub(crate) name: &'static str,
    pub(crate) cycle: f64,
    pub(crate) illumination: f64,
}

pub(crate) fn moon_phase(instant: f64) -> MoonPhase {
    let angle = phase_angle(instant);
    let latitude = lunar_coordinates(instant).1;
    let elongation = (cos(latitude) * cos(angle)).clamp(-1.0, 1.0).acos();
    // Finite Sun distance correction, using mean Earth-Moon/Sun distance.
    let phase = elongation.sin().atan2(0.00257 - elongation.cos());
    let illumination = (1.0 + phase.cos()) / 2.0;
    let names = [
        "new",
        "waxingCrescent",
        "firstQuarter",
        "waxingGibbous",
        "full",
        "waningGibbous",
        "lastQuarter",
        "waningCrescent",
    ];
    let name = names[((angle + 22.5) / 45.0).floor() as usize % 8];
    MoonPhase {
        name,
        cycle: angle / 360.0,
        illumination,
    }
}

fn moon(instant: f64) -> Value {
    let MoonPhase {
        name,
        cycle,
        illumination,
    } = moon_phase(instant);
    let previous = phase_events(instant - 35.0 * DAY, instant, 0.0)
        .last()
        .copied();
    let next_new = phase_events(instant + 1.0, instant + 35.0 * DAY, 0.0)
        .first()
        .copied();
    let next_full = phase_events(instant + 1.0, instant + 35.0 * DAY, 180.0)
        .first()
        .copied();
    json!({"instant":instant,"phase":name,"cycle":cycle,"illumination":illumination,
           "ageDays":previous.map(|p| (instant-p)/DAY),"nextNewMoon":next_new,"nextFullMoon":next_full})
}

/// 二分至日 / 分点：视黄经过 0° / 90° / 180° / 270° 的时刻，从 `instant` 起一年内按天扫、逐段二分。
/// 与 Meeus 第 27 章的多项式 + 周期项算法是两条独立的路，测试拿后者当判据（2026–2027 八个事件差 < 10 分钟）。
/// 太阳到某个视黄经的那一刻（节气用：0° 春分、15° 清明、180° 秋分…）。
/// 与 `season_events` 同一个求根法：按日扫一遍找符号变化再二分。
pub fn solar_term(instant: f64, days: f64, target: f64) -> Option<f64> {
    let difference = |t: f64| (sun(t).longitude - target + 180.0).rem_euclid(360.0) - 180.0;
    let mut a = instant;
    let end = instant + days * DAY;
    while a < end {
        let b = (a + DAY).min(end);
        if difference(a) <= 0.0 && difference(b) > 0.0 && difference(a) > -90.0 {
            return Some(bisect(a, b, difference));
        }
        a = b;
    }
    None
}

fn season_events(instant: f64, days: f64) -> Vec<(f64, &'static str)> {
    let mut events = vec![];
    for (target, kind) in [(0.0, "marchEquinox"), (90.0, "juneSolstice"), (180.0, "septemberEquinox"), (270.0, "decemberSolstice")] {
        let difference = |t: f64| (sun(t).longitude - target + 180.0).rem_euclid(360.0) - 180.0;
        let mut a = instant;
        let end = instant + days * DAY;
        while a < end {
            let b = (a + DAY).min(end);
            if difference(a) <= 0.0 && difference(b) > 0.0 && difference(a) > -90.0 {
                events.push((bisect(a, b, difference), kind));
            }
            a = b;
        }
    }
    events.sort_by(|x, y| x.0.total_cmp(&y.0));
    events
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TrendDay {
    day_start: f64,
    day_end: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TrendInput {
    latitude: f64,
    longitude: f64,
    days: Vec<TrendDay>,
}

/// 「今天比昨天长几分钟」：宿主给若干个真实民用日的边界（昨天、今天、明天、至日那天…），每天各算一次日照，
/// 相邻两天的差写在后一天上；不带曲线样本与黄金时刻。
fn trend(value: &Value) -> Value {
    let Ok(input) = serde_json::from_value::<TrendInput>(value.clone()) else {
        return json!({"available":false,"error":"invalidInput"});
    };
    if !(-90.0..=90.0).contains(&input.latitude) || !(-180.0..=180.0).contains(&input.longitude) || input.days.is_empty() || input.days.len() > 16 {
        return json!({"available":false,"error":"invalidInput"});
    }
    let mut days = Vec::with_capacity(input.days.len());
    let mut previous: Option<f64> = None;
    for day in &input.days {
        if !(20.0 * 3600.0..=28.0 * 3600.0).contains(&(day.day_end - day.day_start))
            || !(-5_364_662_400.0..=4_133_980_800.0).contains(&day.day_start)
        {
            return json!({"available":false,"error":"unsupportedDate"});
        }
        let s = solar(&Input { day_start: day.day_start, day_end: day.day_end, instant: (day.day_start + day.day_end) / 2.0, latitude: input.latitude, longitude: input.longitude });
        let daylight = s["daylightSeconds"].as_f64().unwrap_or(0.0);
        days.push(json!({
            "daylightSeconds": daylight,
            "daylightChangeSeconds": previous.map(|p| daylight - p),
            "sunrise": s["sunrise"], "sunset": s["sunset"], "kind": s["kind"],
        }));
        previous = Some(daylight);
    }
    json!({"available":true,"error":null,"days":days})
}

pub fn dispatch(operation: &str, value: Value) -> Result<Value, String> {
    match operation.strip_prefix("astronomy.") {
        Some("compute") => Ok(compute("compute", &value)),
        Some("trend") => Ok(trend(&value)),
        // 一地一段时间的太阳高度角采样（地点行的音频图）：从 `start` 起每 `stepMinutes` 分钟一个，共 `count` 个
        // （封顶 1,441）；坐标或时刻不成立时给空数组。与昼夜条同一个 `elevation`，Swift 不另存一份天文公式。
        Some("altitudes") => {
            let number = |key: &str| value.get(key).and_then(Value::as_f64).unwrap_or(f64::NAN);
            let (lat, lon, start) = (number("latitude"), number("longitude"), number("start"));
            let step = number("stepMinutes");
            let count = value.get("count").and_then(Value::as_u64).unwrap_or(0).min(1_441) as usize;
            let valid = (-90.0..=90.0).contains(&lat) && (-180.0..=180.0).contains(&lon) && step.is_finite() && step > 0.0
                && SUPPORTED_UNIX.contains(&start) && SUPPORTED_UNIX.contains(&(start + step * 60.0 * count as f64));
            let samples: Vec<f64> = if valid { (0..count).map(|k| elevation(start + step * 60.0 * k as f64, lat, lon)).collect() } else { Vec::new() };
            Ok(json!(samples))
        }
        // 节气（市场时钟的清明、日本的春分 / 秋分）：给一个起点与目标黄经，回那一刻。
        Some("solar_term") => {
            let instant = value.get("instant").and_then(Value::as_f64).unwrap_or(f64::NAN);
            let target = value.get("longitude").and_then(Value::as_f64).unwrap_or(0.0);
            let days = value.get("days").and_then(Value::as_f64).unwrap_or(400.0).clamp(1.0, 800.0);
            if !instant.is_finite() || !(-5_364_662_400.0..=4_133_980_800.0).contains(&instant) || !target.is_finite() {
                return Ok(json!({"available":false,"error":"unsupportedDate"}));
            }
            match solar_term(instant, days, target.rem_euclid(360.0)) {
                Some(found) => Ok(json!({"available":true,"error":null,"instant":found})),
                None => Ok(json!({"available":false,"error":"notFound"})),
            }
        }
        Some("seasons") => {
            let instant = value.get("instant").and_then(Value::as_f64).unwrap_or(f64::NAN);
            if !instant.is_finite() || !(-5_364_662_400.0..=4_133_980_800.0).contains(&instant) {
                return Ok(json!({"available":false,"error":"unsupportedDate"}));
            }
            let events: Vec<Value> = season_events(instant, 370.0).into_iter().map(|(t, kind)| json!({"instant": t, "kind": kind})).collect();
            Ok(json!({"available":true,"error":null,"events":events}))
        }
        _ => Err(format!("Unknown astronomy operation: {operation}")),
    }
}

fn compute(action: &str, value: &Value) -> Value {
    if action != "compute" {
        return json!({"available":false,"error":"invalidAction"});
    }
    let Ok(input) = serde_json::from_value::<Input>(value.clone()) else {
        return json!({"available":false,"error":"invalidInput"});
    };
    if !input.latitude.is_finite()
        || !input.longitude.is_finite()
        || !(-90.0..=90.0).contains(&input.latitude)
        || !(-180.0..=180.0).contains(&input.longitude)
    {
        return json!({"available":false,"error":"invalidCoordinates"});
    }
    // Bounded contemporary range avoids advertising unvalidated ancient dates.
    if ![input.day_start, input.day_end, input.instant]
        .iter()
        .all(|t| t.is_finite() && (-5_364_662_400.0..=4_133_980_800.0).contains(t))
        || !(20.0 * 3600.0..=28.0 * 3600.0).contains(&(input.day_end - input.day_start))
        || !(input.day_start..input.day_end).contains(&input.instant)
    {
        return json!({"available":false,"error":"unsupportedDate"});
    }
    json!({"available":true,"error":null,"dayStart":input.day_start,"dayEnd":input.day_end,
           "solar":solar(&input),"moon":moon(input.instant)})
}

#[cfg(test)]
mod tests {
    use super::*;

    fn input(day_start: f64, hours: f64, latitude: f64, longitude: f64) -> Input {
        Input {
            day_start,
            day_end: day_start + hours * 3600.0,
            instant: day_start + hours * 1800.0,
            latitude,
            longitude,
        }
    }

    #[test]
    fn matches_every_nasa_2026_lunar_phase_within_fifteen_minutes() {
        let fixture: Value = serde_json::from_str(include_str!(
            "../fixtures/astronomy/nasa-moon-phases-2026.json"
        ))
        .unwrap();
        let events = fixture["events"].as_array().unwrap();
        assert_eq!(events.len(), 50);
        let mut worst: f64 = 0.0;
        for event in events {
            let expected = event["unix"].as_f64().unwrap();
            let phase = event["phase"].as_f64().unwrap();
            let actual = phase_events(expected - DAY, expected + DAY, phase);
            assert_eq!(actual.len(), 1, "{event}");
            let error = (actual[0] - expected).abs();
            worst = worst.max(error);
            assert!(
                error < 900.0,
                "{} error {:.2} minutes",
                event["utc"],
                error / 60.0
            );
            let illumination = moon(expected)["illumination"].as_f64().unwrap();
            if phase == 0.0 {
                assert!(illumination < 0.005);
            }
            if phase == 180.0 {
                assert!(illumination > 0.995);
            }
            if phase == 90.0 || phase == 270.0 {
                assert!((illumination - 0.5).abs() < 0.01);
            }
        }
        eprintln!(
            "NASA 2026: {} phases, maximum event error {:.3} minutes",
            events.len(),
            worst / 60.0
        );
    }

    /// 判据是 Meeus 第 27 章（多项式 + 24 个周期项，另一套算法，Python 复算，TT−UTC 取 69 s）。
    #[test]
    fn season_events_match_meeus_chapter_27_within_ten_minutes() {
        let expected = [
            (1_774_017_936.0, "marchEquinox"), (1_782_030_295.0, "juneSolstice"), (1_790_121_930.0, "septemberEquinox"), (1_797_886_213.0, "decemberSolstice"),
            (1_805_574_294.0, "marchEquinox"), (1_813_587_042.0, "juneSolstice"), (1_821_679_279.0, "septemberEquinox"), (1_829_443_337.0, "decemberSolstice"),
        ];
        let events = season_events(1_767_225_600.0, 740.0); // 2026-01-01 起两年
        assert_eq!(events.len(), 8, "{events:?}");
        let mut worst: f64 = 0.0;
        for ((actual, kind), (unix, want)) in events.iter().zip(expected) {
            assert_eq!(*kind, want);
            worst = worst.max((actual - unix).abs());
            assert!((actual - unix).abs() < 600.0, "{want}: {actual} vs {unix} ({:.1} min)", (actual - unix) / 60.0);
        }
        eprintln!("Meeus ch.27 2026–2027: 8 events, maximum error {:.2} minutes", worst / 60.0);
        // dispatch 从今天起给一年内的四个事件，按时间排好
        let out = dispatch("astronomy.seasons", json!({"instant": 1_789_600_000.0})).unwrap();
        let kinds: Vec<&str> = out["events"].as_array().unwrap().iter().map(|e| e["kind"].as_str().unwrap()).collect();
        assert_eq!(kinds, ["septemberEquinox", "decemberSolstice", "marchEquinox", "juneSolstice"]);
        assert_eq!(dispatch("astronomy.seasons", json!({"instant": "x"})).unwrap()["error"], "unsupportedDate");
    }

    /// 节气：清明（黄经 15°）2026 年在 4 月 5 日、2027 年在 4 月 5 日（东八区民用日）；
    /// 春分（0°）2026-03-20。判据是公开的节气表，算出来的时刻换成东八区日期比。
    #[test]
    fn solar_terms_land_on_the_published_dates() {
        let civil_date = |instant: f64, offset: f64| {
            let days = ((instant + offset) / DAY).floor() as i64;
            // 1970-01-01 起的天数 → 年月日（只为断言，用简单换算）。
            let mut year = 1970;
            let mut remaining = days;
            loop {
                let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;
                let length = if leap { 366 } else { 365 };
                if remaining >= length {
                    remaining -= length;
                    year += 1;
                } else {
                    break;
                }
            }
            let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;
            let lengths = [31, if leap { 29 } else { 28 }, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
            let mut month = 0;
            while remaining >= lengths[month] {
                remaining -= lengths[month];
                month += 1;
            }
            (year, month + 1, remaining + 1)
        };
        // 2026-01-01 00:00 UTC 起找第一次 15°（清明）。
        let qingming = solar_term(1_767_225_600.0, 200.0, 15.0).unwrap();
        assert_eq!(civil_date(qingming, 8.0 * 3600.0), (2026, 4, 5));
        let equinox = solar_term(1_767_225_600.0, 200.0, 0.0).unwrap();
        assert_eq!(civil_date(equinox, 9.0 * 3600.0), (2026, 3, 20));
        // 2027 年的清明也在 4 月 5 日。
        let next = solar_term(1_798_761_600.0, 200.0, 15.0).unwrap();
        assert_eq!(civil_date(next, 8.0 * 3600.0), (2027, 4, 5));
        // 找不到就如实说（范围只给一天）。
        assert_eq!(dispatch("astronomy.solar_term", json!({"instant": 1_767_225_600.0, "longitude": 15.0, "days": 1.0})).unwrap()["error"], "notFound");
        assert_eq!(dispatch("astronomy.solar_term", json!({"instant": "x"})).unwrap()["error"], "unsupportedDate");
    }

    /// 九月中旬：伦敦每天短 3–4 分钟、悉尼每天长 1–2 分钟、基多几乎不变、朗伊尔城极昼未尽时 24 小时不变。
    #[test]
    fn daylight_trend_signs_follow_the_hemisphere() {
        let days = |start: f64| json!([{"dayStart": start - DAY, "dayEnd": start}, {"dayStart": start, "dayEnd": start + DAY}, {"dayStart": start + DAY, "dayEnd": start + 2.0 * DAY}]);
        let run = |lat: f64, lon: f64, start: f64| dispatch("astronomy.trend", json!({"latitude": lat, "longitude": lon, "days": days(start)})).unwrap();
        // 2026-09-15 00:00 BST = 2026-09-14 23:00 UTC
        let london = run(51.5074, -0.1278, 1_789_513_200.0);
        assert_eq!(london["available"], true);
        let d = london["days"].as_array().unwrap();
        assert!(d[0]["daylightChangeSeconds"].is_null());
        for day in &d[1..] {
            let change = day["daylightChangeSeconds"].as_f64().unwrap();
            assert!((-260.0..=-180.0).contains(&change), "London {change}");
        }
        // 悉尼 2026-09-15 00:00 AEST = 09-14 14:00 UTC
        let sydney = run(-33.8688, 151.2093, 1_789_480_800.0);
        let change = sydney["days"][1]["daylightChangeSeconds"].as_f64().unwrap();
        assert!((60.0..=150.0).contains(&change), "Sydney {change}");
        // 基多 2026-09-15 00:00 −05 = 05:00 UTC
        let quito = run(-0.1807, -78.4678, 1_789_534_800.0);
        let change = quito["days"][1]["daylightChangeSeconds"].as_f64().unwrap();
        assert!(change.abs() < 30.0, "Quito {change}");
        // 朗伊尔城 2026-08-01：极昼，两天都是 24 小时
        let svalbard = run(78.2232, 15.6267, 1_785_621_600.0);
        assert_eq!(svalbard["days"][1]["kind"], "polarDay");
        assert_eq!(svalbard["days"][1]["daylightChangeSeconds"].as_f64().unwrap(), 0.0);
        // 坏输入
        assert_eq!(dispatch("astronomy.trend", json!({"latitude": 91.0, "longitude": 0.0, "days": days(0.0)})).unwrap()["error"], "invalidInput");
        assert_eq!(dispatch("astronomy.trend", json!({"latitude": 0.0, "longitude": 0.0, "days": [{"dayStart": 0.0, "dayEnd": 10.0}]})).unwrap()["error"], "unsupportedDate");
    }

    #[test]
    fn daylight_bands_split_a_day_into_night_twilight_day_and_back() {
        // 2026-03-20 UTC 整天，赤道本初子午线：昼约 12 小时，前后各一段曙暮与夜，顺序固定。
        let bands = daylight_bands(1_773_964_800.0, 1_773_964_800.0 + 86_400.0, 0.0, 0.0);
        let kinds: Vec<u8> = bands.iter().map(|b| b.2).collect();
        assert_eq!(kinds, vec![0, 1, 2, 1, 0], "{bands:?}");
        let day = bands.iter().find(|b| b.2 == 2).unwrap();
        let hours = (day.1 - day.0) / 3600.0;
        assert!((11.9..=12.4).contains(&hours), "{hours}");
        // 赤道上民用曙暮光约 21–24 分钟。
        for twilight in bands.iter().filter(|b| b.2 == 1) {
            let minutes = (twilight.1 - twilight.0) / 60.0;
            assert!((18.0..=30.0).contains(&minutes), "{minutes}");
        }
        // 段首尾相接、覆盖整个区间。
        assert_eq!(bands.first().unwrap().0, 1_773_964_800.0);
        assert_eq!(bands.last().unwrap().1, 1_773_964_800.0 + 86_400.0);
        for pair in bands.windows(2) {
            assert_eq!(pair[0].1, pair[1].0);
        }
    }

    #[test]
    fn daylight_bands_are_one_piece_in_polar_night_and_polar_day() {
        let night = daylight_bands(1_797_292_800.0, 1_797_292_800.0 + 86_400.0, 89.0, 0.0);
        assert_eq!(night.len(), 1);
        assert_eq!(night[0].2, 0);
        let day = daylight_bands(1_781_481_600.0, 1_781_481_600.0 + 86_400.0, 89.0, 0.0);
        assert_eq!(day.len(), 1);
        assert_eq!(day[0].2, 2);
        assert!(daylight_bands(10.0, 10.0, 0.0, 0.0).is_empty());
        assert!(daylight_bands(f64::NAN, 100.0, 0.0, 0.0).is_empty());
    }

    #[test]
    fn noaa_published_boulder_elevation_fixture_matches() {
        // NOAA NEUBrew default coordinates, 2026-09-07 19:00 UTC:
        // lat 40.00, lon -105.00, uncorrected elevation 55.83946 degrees.
        let elevation = elevation(1_788_807_600.0, 40.0, -105.0);
        assert!((elevation - 55.83946).abs() < 0.1, "{elevation}");
    }

    #[test]
    fn equinox_is_nearly_twelve_hours_and_crossings_are_physical() {
        let i = input(1_773_964_800.0, 24.0, 0.0, 0.0); // 2026-03-20 UTC
        let s = solar(&i);
        let length = s["daylightSeconds"].as_f64().unwrap();
        assert!((length / 3600.0 - 12.11).abs() < 0.06, "{length}");
        for key in ["sunrise", "sunset"] {
            let t = s[key].as_f64().unwrap();
            assert!((elevation(t, 0.0, 0.0) + 0.833).abs() < 0.00001);
        }
        assert_eq!(s["golden"].as_array().unwrap().len(), 2);
    }

    #[test]
    fn polar_day_and_night_include_geographic_poles() {
        for lat in [78.2232, 90.0, -78.2232, -90.0] {
            let (summer_day, winter_day) = if lat > 0.0 {
                (1_782_000_000.0, 1_797_811_200.0)
            } else {
                (1_797_811_200.0, 1_782_000_000.0)
            };
            let summer = solar(&input(summer_day, 24.0, lat, 15.6469));
            assert_eq!(summer["kind"], "polarDay");
            assert_eq!(summer["daylightSeconds"], DAY);
            assert!(summer["sunrise"].is_null());
            let winter = solar(&input(winter_day, 24.0, lat, 15.6469));
            assert_eq!(winter["kind"], "polarNight");
            assert_eq!(winter["daylightSeconds"], 0.0);
        }
    }

    #[test]
    fn actual_23_and_25_hour_days_keep_all_intervals_in_bounds() {
        for i in [
            input(1_772_956_800.0, 23.0, 34.0522, -118.2437),
            input(1_793_516_400.0, 25.0, 34.0522, -118.2437),
            input(1_782_000_000.0, 24.0, -13.8333, -171.75),
        ] {
            let s = solar(&i);
            assert!(
                (0.0..=i.day_end - i.day_start).contains(&s["daylightSeconds"].as_f64().unwrap())
            );
            for interval in s["golden"].as_array().unwrap() {
                let start = interval["start"].as_f64().unwrap();
                let end = interval["end"].as_f64().unwrap();
                assert!(i.day_start <= start && start < end && end <= i.day_end);
                assert!((-4.0..=6.0).contains(&elevation(
                    (start + end) / 2.0,
                    i.latitude,
                    i.longitude
                )));
            }
            let samples = s["samples"].as_array().unwrap();
            assert_eq!(samples.first().unwrap()["instant"], i.day_start);
            assert_eq!(samples.last().unwrap()["instant"], i.day_end);
        }
    }

    #[test]
    fn longitude_wrap_and_fractional_day_bounds_are_continuous() {
        let a = input(1_774_049_400.0, 24.0, -16.5, -180.0);
        let b = input(a.day_start, 24.0, -16.5, 180.0);
        let aa = solar(&a);
        let bb = solar(&b);
        assert!(
            (aa["daylightSeconds"].as_f64().unwrap() - bb["daylightSeconds"].as_f64().unwrap())
                .abs()
                < 0.001
        );
        assert!((0.0..30.0).contains(&moon(a.instant)["ageDays"].as_f64().unwrap()));
    }

    #[test]
    fn invalid_coordinates_dates_and_actions_fail_without_partial_data() {
        let base = json!({"dayStart":1782000000.0,"dayEnd":1782086400.0,"instant":1782043200.0,"latitude":0.0,"longitude":0.0});
        assert_eq!(
            dispatch("astronomy.compute", base.clone()).unwrap()["available"],
            true
        );
        for (key, value) in [
            ("latitude", json!(91.0)),
            ("longitude", json!(-181.0)),
            ("instant", json!(1e100)),
            ("dayEnd", json!(1782000000.0)),
            ("instant", json!(1782086400.0)),
        ] {
            let mut invalid = base.clone();
            invalid[key] = value;
            assert_eq!(compute("compute", &invalid)["available"], false);
            assert!(compute("compute", &invalid).get("solar").is_none());
        }
        assert_eq!(compute("unknown", &base)["error"], "invalidAction");
        assert!(dispatch("unknown", base).is_err());
    }
    /// 音频图的高度采样：春分那天赤道本初子午线正午几乎头顶、子夜几乎脚底，97 个；坐标不成立给空。
    #[test]
    fn altitude_samples_cover_the_day() {
        let start = 1_773_964_800.0; // 2026-03-20 00:00 UTC
        let out = dispatch("astronomy.altitudes", json!({"latitude": 0.0, "longitude": 0.0, "start": start, "stepMinutes": 15.0, "count": 97})).unwrap();
        let samples: Vec<f64> = out.as_array().unwrap().iter().map(|v| v.as_f64().unwrap()).collect();
        assert_eq!(samples.len(), 97);
        assert!(samples[48] > 85.0 && samples[0] < -85.0 && samples[96] < -85.0, "{} {} {}", samples[0], samples[48], samples[96]);
        let bad = dispatch("astronomy.altitudes", json!({"latitude": 91.0, "longitude": 0.0, "start": start, "stepMinutes": 15.0, "count": 97})).unwrap();
        assert_eq!(bad, json!([]));
    }
}
