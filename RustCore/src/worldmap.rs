// SPDX-License-Identifier: GPL-3.0-only
//! 昼夜地图：地球被太阳照亮的那半边。
//! 底图（天色、海陆与地形、晨昏线、太阳光晕、城市灯火）由 `sky` 逐像素画进位图；这里给宿主放符号用的位置：
//! 地点（`pins`：位置、是不是本机、脚下的地面暗不暗 `dark` 与它的颜色 `fill`）、`lit`（此刻白天的地点）、
//! 直射点 `sun` / `subsolar`、月下点与月相 `moon`（`sunIsEast`：亮的那一侧朝东），以及给位图画晨昏线用的
//! `terminator_lines`（太阳高度 −0.833° 那条边界，按破晓 / 黄昏拆段、化简过）。
//!
//! 晨昏线的几何是「夜冠」：圆心在反日点、角半径 90° + h0 的球冠（`night_cap`），它的边就是那条线。
//! 底图由位图承担；本模块保留符号位置与夜冠几何，
//! 夜冠的正确性仍由测试按太阳高度逐点核（`night_caps_…`、`day_and_twilight_…`）。
use serde::Deserialize;
use serde_json::{json, Value};

use crate::astronomy;


/// 昼的下沿：太阳高度 −0.833°（大气折射 + 太阳半径），与昼夜条、日出日落和 `lit` 同一个判据。
const DAY_HORIZON: f64 = -0.833;
/// 民用曙暮的下沿：−6° … −0.833° 是曙暮，再低是夜。
#[cfg(test)]
const TWILIGHT_HORIZON: f64 = -6.0;
/// 画布边长上限（点）。地图最多几千点宽；再大只能是坏输入，平移副本投影出来会溢出成 inf，serde 会写成 null。
const MAX_SIDE: f64 = 100_000.0;
/// |反日点纬度| + 球冠半径离 90° 不到这么多（度）就按「盖住极点」画：极点正好压在边界上时两种画法都对，
/// 这样小圆那条路永远离极点至少这么远，经度差在极点旁不会失去精度。
const POLE_MARGIN: f64 = 1e-6;
/// 边界采样：一段的中点离弦超过这么多（经纬度平面上的度；960 点宽的图上约 0.13 点）就在这段中间加点。
const TOLERANCE: f64 = 0.05;
/// 加点最多对半分几层（2° 的一段最细到 2° / 256）。
const MAX_DEPTH: u32 = 8;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Place {
    latitude: f64,
    longitude: f64,
    #[serde(default)]
    home: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Input {
    instant: f64,
    width: f64,
    height: f64,
    #[serde(default)]
    places: Vec<Place>,
    /// 纬度裁剪（帮助页头图裁掉两极的空海）：默认整个球面 −90 … 90。
    #[serde(default = "south_pole")]
    latitude_min: f64,
    #[serde(default = "north_pole")]
    latitude_max: f64,
}

fn south_pole() -> f64 {
    -90.0
}
fn north_pole() -> f64 {
    90.0
}

/// 此刻太阳直射点（纬度 = 赤纬，经度 = 时角为零的子午线），度。
pub(crate) fn subsolar_point(instant: f64) -> (f64, f64) {
    let sun = astronomy::sun(instant);
    let minutes = instant.rem_euclid(86_400.0) / 60.0;
    let longitude = (180.0 - (minutes + sun.equation) / 4.0 + 180.0).rem_euclid(360.0) - 180.0;
    (sun.declination.to_degrees(), longitude)
}

/// 此刻月下点（地心；纬度 = 月球赤纬，经度 = 赤经 − 格林尼治平恒星时，东经为正，−180 … 180），度。
/// 黄经黄纬来自 `astronomy::lunar_coordinates`（Meeus 47.A 截断），换赤道坐标用 `astronomy::obliquity`，恒星时用 Meeus 12.4。
pub(crate) fn sublunar_point(instant: f64) -> (f64, f64) {
    let (longitude, latitude) = astronomy::lunar_coordinates(instant);
    let (sin_e, cos_e) = astronomy::obliquity(instant).to_radians().sin_cos();
    let (sin_l, cos_l) = longitude.to_radians().sin_cos();
    let (sin_b, cos_b) = latitude.to_radians().sin_cos();
    let declination = (sin_b * cos_e + cos_b * sin_e * sin_l).clamp(-1.0, 1.0).asin();
    // α = atan2(sinλ cosε − tanβ sinε, cosλ)，两边同乘 cosβ（> 0）免得用 tan。
    let right_ascension = (sin_l * cos_e * cos_b - sin_b * sin_e).atan2(cos_l * cos_b);
    (declination.to_degrees(), wrap(right_ascension.to_degrees() - greenwich_sidereal(instant)))
}

/// 格林尼治平恒星时（度，Meeus 式 12.4）；UT 按 UTC 取，差不到一秒。
fn greenwich_sidereal(instant: f64) -> f64 {
    let days = (instant - 946_728_000.0) / 86_400.0; // 自 J2000.0（2000-01-01 12:00）起的日数
    let t = days / 36_525.0;
    (280.460_618_37 + 360.985_647_366_29 * days + t * t * (0.000_387_933 - t / 38_710_000.0)).rem_euclid(360.0)
}

/// 经度折回 −180 … 180。
fn wrap(longitude: f64) -> f64 {
    (longitude + 180.0).rem_euclid(360.0) - 180.0
}

/// 太阳高度低于某条水平线的那一片（夜那一侧），经纬度（度）。
struct NightCap {
    /// 闭合环（首点不重复）：整张图减去它们（even-odd）就是被照亮的那一片。地图不再画这一片（天色在位图里），
    /// 留着是为了让测试按太阳高度逐点核这套构造——晨昏线（`edges`）是同一套构造的边。
    #[cfg_attr(not(test), allow(dead_code))]
    rings: Vec<Vec<(f64, f64)>>,
    /// 球冠边界本身，给晨昏线描边：不含为闭合而绕到极点的边；小圆那种情形首尾相接。
    edges: Vec<Vec<(f64, f64)>>,
}

/// 太阳高度 < `horizon` 的球冠：圆心在反日点（−δ, λs + 180°），角半径 ρ = 90° + horizon（horizon < 0，所以 ρ < 90°，是个小圆）。
/// 太阳高度满足 sin h = sinφ sinδ + cosφ cosδ cos(λ − λs)，与 `astronomy::elevation` 同一个式子。
/// 球冠盖住极点当且仅当 |δ| + ρ ≥ 90°，即 |δ| ≥ −horizon：−0.833° 这条线一年里只有分点前后各两天左右不盖，
/// −6° 这条线分点前后各半个月左右不盖。
fn night_cap(subsolar: (f64, f64), horizon: f64) -> NightCap {
    debug_assert!(horizon < -0.1 && horizon > -90.0, "{horizon}");
    let (declination, sun_longitude) = subsolar;
    if declination.abs() >= -horizon - POLE_MARGIN {
        pole_cap(declination, sun_longitude, horizon)
    } else {
        loop_cap(declination, sun_longitude, horizon)
    }
}

/// 情形一：球冠盖住一个极。边界与每条经线恰好交一次（两极一明一暗，沿经线的高度只穿过这条水平线一次），
/// 写成 纬度 = g(经度)：固定经度时 sinφ sinδ + cosφ cosδ cosH = sin h0 化成 R sin(φ + ψ) = sin h0
/// （R cosψ = |sinδ|、R sinψ = cosδ cosH），[−90°, 90°] 里只有 φ = asin(sin h0 / R) − ψ 这一个根；
/// δ < 0 时整个式子对 (φ, δ) → (−φ, −δ) 对称，取负号。按经度每 2° 取一点（急转处 `sample` 加点），
/// 再经夜里那个极的两个角（经度 ±180°）闭合。
fn pole_cap(declination: f64, sun_longitude: f64, horizon: f64) -> NightCap {
    let sign = if declination >= 0.0 { 1.0 } else { -1.0 }; // 北半球夏天北极亮、南极在夜里
    let (sin_d, cos_d) = declination.to_radians().sin_cos();
    let a = sin_d.abs(); // ≥ sin(0.833° − POLE_MARGIN) > 0
    let level = horizon.to_radians().sin();
    let pole = -sign * 90.0;
    let boundary = |longitude: f64| {
        let b = cos_d * (longitude - sun_longitude).to_radians().cos();
        let ratio = level / a.hypot(b);
        // 极点恰在边界外一点点（< POLE_MARGIN）时个别经线整条都亮、没有根：边界落在极点上，夜那一片在这条经线上宽度为零；
        // 根算到极点外面（舍入）也夹回极点。差的是一条看不见的缝。
        let latitude = if ratio < -1.0 { pole } else { sign * (ratio.max(-1.0).asin() - b.atan2(a)).to_degrees() };
        (longitude, latitude.clamp(-90.0, 90.0))
    };
    let edge = sample(-180.0, 180.0, 180, boundary);
    let mut ring = Vec::with_capacity(edge.len() + 2);
    ring.extend_from_slice(&edge);
    ring.push((180.0, pole));
    ring.push((-180.0, pole));
    NightCap { rings: vec![ring], edges: vec![edge] }
}

/// 情形二：球冠不含极（分点前后）。边界是一圈闭合的小圆，按从反日点出发的方位角每 2° 取一点（`sample` 在急转处加点），
/// 用球面「从一点出发走 ρ 到哪」的公式。不含极的球冠经度半宽 E 满足 sin E = sin ρ / cos φA < 1，E < 90°，
/// 所以相对反日点经线的经度差（atan2 的结果）从不跳变，本身就是连续的，不用解缠绕。
/// 伸出 ±180° 的那一边再平移 ±360° 画一份（E < 90° 时两份不会重叠）。
fn loop_cap(declination: f64, sun_longitude: f64, horizon: f64) -> NightCap {
    let (sin_r, cos_r) = (90.0 + horizon).to_radians().sin_cos();
    let (sin_c, cos_c) = (-declination).to_radians().sin_cos();
    let center = wrap(sun_longitude + 180.0);
    let point = |bearing: f64| {
        let (sin_b, cos_b) = bearing.to_radians().sin_cos();
        let sin_lat = (sin_c * cos_r + cos_c * sin_r * cos_b).clamp(-1.0, 1.0);
        let offset = (sin_b * sin_r * cos_c).atan2(cos_r - sin_c * sin_lat);
        (center + offset.to_degrees(), sin_lat.asin().to_degrees())
    };
    let mut ring = sample(0.0, 360.0, 180, point);
    ring.pop(); // 方位角 360° 与 0° 是同一点：环不重复首点
    let (west, east) = ring.iter().fold((f64::INFINITY, f64::NEG_INFINITY), |(west, east), p| (west.min(p.0), east.max(p.0)));
    let shifted = |offset: f64| ring.iter().map(|&(longitude, latitude)| (longitude + offset, latitude)).collect::<Vec<_>>();
    let mut rings = Vec::with_capacity(2);
    if west < -180.0 {
        rings.push(shifted(360.0));
    }
    if east > 180.0 {
        rings.push(shifted(-360.0));
    }
    rings.insert(0, ring);
    let edges = rings
        .iter()
        .map(|ring| {
            let mut closed = ring.clone();
            closed.push(ring[0]);
            closed
        })
        .collect();
    NightCap { rings, edges }
}

/// 参数曲线的采样：先按 `steps` 等分 [start, end]，某一段的中点离弦超过 `TOLERANCE` 就对半再分，最多 `MAX_DEPTH` 层。
/// 等距柱状投影里靠近极点的边界会急转（分点前后晨昏线几乎竖直地穿过赤道、小圆擦着极点绕过去），
/// 等分采样的弦会切掉一角；这里只在那种地方加点，平常一个点也不加。首尾两端的点都在。
fn sample(start: f64, end: f64, steps: u32, curve: impl Fn(f64) -> (f64, f64)) -> Vec<(f64, f64)> {
    let mut points = Vec::with_capacity(steps as usize + 1);
    let mut previous = (start, curve(start));
    points.push(previous.1);
    for i in 1..=steps {
        let t = start + (end - start) * f64::from(i) / f64::from(steps);
        let next = (t, curve(t));
        refine(&curve, previous, next, MAX_DEPTH, &mut points);
        points.push(next.1);
        previous = next;
    }
    points
}

fn refine(curve: &impl Fn(f64) -> (f64, f64), from: (f64, (f64, f64)), to: (f64, (f64, f64)), depth: u32, out: &mut Vec<(f64, f64)>) {
    if depth == 0 {
        return;
    }
    let t = (from.0 + to.0) / 2.0;
    let middle = (t, curve(t));
    if off_chord(middle.1, from.1, to.1) <= TOLERANCE {
        return;
    }
    refine(curve, from, middle, depth - 1, out);
    out.push(middle.1);
    refine(curve, middle, to, depth - 1, out);
}

/// 点到线段的距离（经纬度平面，度）。
fn off_chord(point: (f64, f64), a: (f64, f64), b: (f64, f64)) -> f64 {
    let (dx, dy) = (b.0 - a.0, b.1 - a.1);
    let length = dx * dx + dy * dy;
    let t = if length > 0.0 { (((point.0 - a.0) * dx + (point.1 - a.1) * dy) / length).clamp(0.0, 1.0) } else { 0.0 };
    (point.0 - a.0 - t * dx).hypot(point.1 - a.1 - t * dy)
}

/// 投影：经度 −180 … 180 → x 0 … width，纬度 north … south → y 0 … height（等距柱状）。
#[derive(Clone, Copy)]
struct Frame {
    width: f64,
    height: f64,
    north: f64,
    span: f64,
}

impl Frame {
    fn new(width: f64, height: f64, latitudes: (f64, f64)) -> Self {
        Frame { width, height, north: latitudes.1, span: (latitudes.1 - latitudes.0).max(1.0) }
    }

    fn project(self, point: (f64, f64)) -> (f64, f64) {
        ((point.0 + 180.0) / 360.0 * self.width, (self.north - point.1) / self.span * self.height)
    }

}

/// 地图上的符号：地点（位置、本机、脚下的地面暗不暗与它的颜色）、白天的地点、直射点、月下点与月相。
/// 底色、晨昏线、灯火、太阳的光晕都在 `sky` 画的位图里，这里不给绘图命令。
fn scene(input: &Input) -> Result<Value, String> {
    let fits = |side: f64| side > 0.0 && side <= MAX_SIDE;
    if !fits(input.width) || !fits(input.height) || !astronomy::SUPPORTED_UNIX.contains(&input.instant) {
        return Err("World map needs a size in (0, 100000] points and an instant from 1800 to 2100".into());
    }
    let latitudes = if input.latitude_min < input.latitude_max && (-90.0..=90.0).contains(&input.latitude_min) && (-90.0..=90.0).contains(&input.latitude_max) {
        (input.latitude_min, input.latitude_max)
    } else {
        (-90.0, 90.0)
    };
    let frame = Frame::new(input.width, input.height, latitudes);
    let subsolar = subsolar_point(input.instant);
    let mut pins = Vec::new();
    let mut lit = Vec::new();
    for (index, place) in input.places.iter().enumerate() {
        if !(-90.0..=90.0).contains(&place.latitude) || !(-180.0..=180.0).contains(&place.longitude) {
            continue;
        }
        let (x, y) = frame.project((place.longitude, place.latitude));
        let altitude = astronomy::elevation(input.instant, place.latitude, place.longitude);
        let ground = crate::sky::surface(altitude, crate::sky::rising(input.instant, place.longitude), true);
        pins.push(json!({"index": index, "x": x, "y": y, "home": place.home, "dark": ground.l < 0.62, "fill": crate::sky::hex(ground)}));
        if altitude >= DAY_HORIZON {
            lit.push(index);
        }
    }
    let (sx, sy) = frame.project((subsolar.1, subsolar.0));
    let lunar = sublunar_point(input.instant);
    let (mx, my) = frame.project((lunar.1, lunar.0));
    let phase = astronomy::moon_phase(input.instant);
    Ok(json!({
        "sun": [sx, sy],
        "subsolar": {"latitude": subsolar.0, "longitude": subsolar.1},
        "moon": {"x": mx, "y": my, "latitude": lunar.0, "longitude": lunar.1,
                 "phase": phase.name, "illumination": phase.illumination, "cycle": phase.cycle,
                 "sunIsEast": wrap(subsolar.1 - lunar.1) > 0.0},
        "pins": pins,
        "lit": lit,
    }))
}

/// 晨昏线的一段是破晓那一侧（太阳在东边，正在升）还是黄昏那一侧：按这一段中点的时角。
fn split_dawn_dusk(edge: &[(f64, f64)], sun_longitude: f64) -> Vec<(bool, Vec<(f64, f64)>)> {
    let mut out: Vec<(bool, Vec<(f64, f64)>)> = Vec::new();
    for pair in edge.windows(2) {
        let middle = (pair[0].0 + pair[1].0) / 2.0;
        let dawn = wrap(middle - sun_longitude) < 0.0;
        match out.last_mut() {
            Some((side, points)) if *side == dawn => points.push(pair[1]),
            _ => out.push((dawn, vec![pair[0], pair[1]])),
        }
    }
    out
}

/// 折线化简（Ramer–Douglas–Peucker，经纬度平面上的度）：晨昏线的采样为了多边形精确而很密，画一条线用不着——
/// 0.15° 在地球窗 1800 像素宽的图上还不到一个像素，点数少一个数量级（每帧的 JSON 与路径都跟着小）。
fn simplify(points: &[(f64, f64)], epsilon: f64) -> Vec<(f64, f64)> {
    if points.len() < 3 {
        return points.to_vec();
    }
    let mut keep = vec![false; points.len()];
    keep[0] = true;
    keep[points.len() - 1] = true;
    let mut stack = vec![(0, points.len() - 1)];
    while let Some((a, b)) = stack.pop() {
        let (p, q) = (points[a], points[b]);
        let (dx, dy) = (q.0 - p.0, q.1 - p.1);
        let length = (dx * dx + dy * dy).sqrt().max(1e-12);
        let mut far = (0.0, a);
        for (k, r) in points.iter().enumerate().take(b).skip(a + 1) {
            let d = ((r.0 - p.0) * dy - (r.1 - p.1) * dx).abs() / length;
            if d > far.0 {
                far = (d, k);
            }
        }
        if far.0 > epsilon {
            keep[far.1] = true;
            stack.push((a, far.1));
            stack.push((far.1, b));
        }
    }
    points.iter().zip(keep).filter(|(_, k)| *k).map(|(p, _)| *p).collect()
}

/// 晨昏线（太阳高度 −0.833° 那条边界），按破晓 / 黄昏拆段、化简过的经纬度折线。光的底图由 `sky` 逐像素画，
/// 这条线也由它画进位图（光晕 + 细线，贴图边淡出）；这里只给几何，测试钉住它贴着真正的晨昏线。
pub(crate) fn terminator_lines(instant: f64) -> Vec<(bool, Vec<(f64, f64)>)> {
    let subsolar = subsolar_point(instant);
    let mut out = Vec::new();
    for edge in &night_cap(subsolar, DAY_HORIZON).edges {
        for (dawn, points) in split_dawn_dusk(edge, subsolar.1) {
            let points = simplify(&points, 0.15);
            if points.len() >= 2 {
                out.push((dawn, points));
            }
        }
    }
    out
}

pub fn dispatch(operation: &str, value: Value) -> Result<Value, String> {
    match operation {
        "worldmap.scene" => {
            let input: Input = serde_json::from_value(value).map_err(|e| e.to_string())?;
            scene(&input)
        }
        _ => Err(format!("Unknown worldmap operation: {operation}")),
    }
}

#[cfg(test)]
mod light_tests {
    use super::*;

    /// 光模式：晨昏线只有破晓与黄昏两种，破晓那几段的每个中点都在太阳西边（时角 < 0），黄昏的都在东边；
    /// 场景本身不再带绘图命令（线画在位图里），只给符号的位置。
    #[test]
    fn the_terminator_splits_into_dawn_and_dusk() {
        for instant in [1_790_000_000.0, 1_800_000_000.0, 1_781_996_400.0, 1_766_000_000.0] {
            let value = dispatch(
                "worldmap.scene",
                serde_json::json!({"instant": instant, "width": 720.0, "height": 276.0, "latitudeMin": -58.0, "latitudeMax": 80.0,
                                   "places": [{"latitude": 51.5, "longitude": -0.1, "home": true}]}),
            )
            .unwrap();
            assert!(value.get("commands").is_none(), "底图在位图里，场景不带绘图命令");
            let (_, sun_longitude) = subsolar_point(instant);
            let lines = terminator_lines(instant);
            assert!(lines.iter().any(|(dawn, _)| *dawn) && lines.iter().any(|(dawn, _)| !*dawn));
            for (dawn, points) in &lines {
                for pair in points.windows(2) {
                    let hour_angle = wrap((pair[0].0 + pair[1].0) / 2.0 - sun_longitude);
                    if *dawn { assert!(hour_angle < 0.5, "{instant} dawn at {hour_angle}"); } else { assert!(hour_angle > -0.5, "{instant} dusk at {hour_angle}"); }
                }
            }
            assert_eq!(value["pins"][0]["dark"].as_bool(), Some(astronomy::elevation(instant, 51.5, -0.1) < DAY_HORIZON - 3.0).or(value["pins"][0]["dark"].as_bool()));
        }
    }

    /// 化简后的晨昏线仍贴着真正的晨昏线：每一段弦的中点反算回经纬度，太阳高度离 −0.833° 不到 0.6°（独立判据：
    /// `astronomy::elevation`）；点数比化简前少（实测 434 → 112、181 → 61），720 点宽的图整条不过 150 点。
    #[test]
    fn the_simplified_terminator_still_follows_the_sun() {
        for instant in [1_790_000_000.0, 1_782_030_240.0, 1_797_886_200.0, 1_774_017_936.0] {
            let mut total = 0;
            for (_, points) in terminator_lines(instant) {
                total += points.len();
                for pair in points.windows(2) {
                    let (lon, lat) = ((pair[0].0 + pair[1].0) / 2.0, (pair[0].1 + pair[1].1) / 2.0);
                    if lat.abs() < 79.0 {
                        let off = (astronomy::elevation(instant, lat, lon) - DAY_HORIZON).abs();
                        assert!(off < 0.6, "{instant} ({lat}, {lon}) is {off}° off the terminator");
                    }
                }
            }
            let dense: usize = night_cap(subsolar_point(instant), DAY_HORIZON).edges.iter().map(Vec::len).sum();
            assert!(total < dense && total <= 150, "{instant}: {total} points after simplifying, {dense} before");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SUMMER: f64 = 1_782_030_240.0; // 2026-06-21 08:24 UTC 夏至
    const WINTER: f64 = 1_797_886_200.0; // 2026-12-21 20:50 UTC 冬至
    const MARCH: f64 = 1_774_017_936.0; // 2026-03-20 14:45 UTC 春分（astronomy 测试里 Meeus 第 27 章的判据值）
    const SEPTEMBER: f64 = 1_790_121_930.0; // 2026-09-23 00:05 UTC 秋分
    const FROM_2026: f64 = 1_767_225_600.0; // 2026-01-01 00:00 UTC
    const UNTIL_2028: f64 = 1_830_297_600.0; // 2028-01-01 00:00 UTC
    const DAY: f64 = 86_400.0;

    /// 2026–2027 里的伪随机时刻（xorshift，固定种子）。
    fn random_instants(count: usize, seed: u64) -> Vec<f64> {
        let mut state = seed;
        (0..count)
            .map(|_| {
                state ^= state << 13;
                state ^= state >> 7;
                state ^= state << 17;
                FROM_2026 + (state % 1_000_003) as f64 / 1_000_003.0 * (UNTIL_2028 - FROM_2026)
            })
            .collect()
    }

    /// 太阳赤纬穿过 `target` 的时刻（[from, to] 里单调，二分到亚毫秒）：用来挑「极点正好压在边界上」的时刻。
    fn declination_crossing(target: f64, from: f64, to: f64) -> f64 {
        let above = |t: f64| subsolar_point(t).0 > target;
        let (mut a, mut b) = (from, to);
        assert_ne!(above(a), above(b), "{target}: {from} … {to}");
        let start = above(a);
        for _ in 0..80 {
            let middle = (a + b) / 2.0;
            if above(middle) == start {
                a = middle;
            } else {
                b = middle;
            }
        }
        (a + b) / 2.0
    }

    /// 网格核对用的时刻：两至两分、8 个伪随机时刻，加上两条水平线在两个分点前后「极点压线」的时刻各前后 0.3 秒
    /// （赤纬每秒走 ~5e-6°，0.3 秒把极点推到边界内外 ~1.4e-6°，正好越过 POLE_MARGIN，两种画法都走到最险的地方）。
    fn grid_instants() -> Vec<f64> {
        let mut instants = vec![SUMMER, WINTER, MARCH, SEPTEMBER];
        instants.extend(random_instants(8, 0x9E37_79B9_7F4A_7C15));
        for (equinox, rising) in [(MARCH, true), (SEPTEMBER, false)] {
            for level in [0.833, 6.0] {
                // 分点前赤纬在 ∓level，分点后在 ±level；两段里赤纬都单调。
                let (before, after) = if rising { (-level, level) } else { (level, -level) };
                for (target, from, to) in [(before, equinox - 40.0 * DAY, equinox), (after, equinox, equinox + 40.0 * DAY)] {
                    let t = declination_crossing(target, from, to);
                    instants.extend([t - 0.3, t, t + 0.3]);
                }
            }
        }
        instants
    }

    fn numbers(value: &Value) -> Vec<f64> {
        value.as_array().unwrap().iter().map(|n| n.as_f64().unwrap_or_else(|| panic!("几何里只能是有限数：{n}"))).collect()
    }

    /// `[点数, x, y, …]` 拆成环。
    fn rings_of(geometry: &[f64]) -> Vec<Vec<(f64, f64)>> {
        let mut rings = Vec::new();
        let mut i = 0;
        while i < geometry.len() {
            let count = geometry[i] as usize;
            assert!(count >= 3 && i + 1 + 2 * count <= geometry.len(), "环格式不对：第 {i} 个数");
            rings.push((0..count).map(|k| (geometry[i + 1 + 2 * k], geometry[i + 2 + 2 * k])).collect());
            i += 1 + 2 * count;
        }
        rings
    }

    /// even-odd 射线法：从点向右的水平射线与所有环的边交奇数次就在区域里。只看几何，不管环是怎么造出来的。
    fn even_odd(rings: &[Vec<(f64, f64)>], point: (f64, f64)) -> bool {
        let mut inside = false;
        for ring in rings {
            let n = ring.len();
            let mut j = n - 1;
            for i in 0..n {
                let (xi, yi) = ring[i];
                let (xj, yj) = ring[j];
                if (yi > point.1) != (yj > point.1) && point.0 < (xj - xi) * (point.1 - yi) / (yj - yi) + xi {
                    inside = !inside;
                }
                j = i;
            }
        }
        inside
    }

    fn scene_at(instant: f64, width: f64, height: f64) -> Value {
        dispatch("worldmap.scene", json!({"instant": instant, "width": width, "height": height})).unwrap()
    }

    /// 被照亮的那一片，写成 `[点数, x, y, …]` 的环：第一环整张图，其余是夜冠投影到图上（even-odd 填就是亮区）。
    /// 地图早已不画这一片（天色在位图里），这里只拿它核夜冠的构造——晨昏线就是这套构造的边。
    fn lit_region(frame: Frame, cap: &NightCap) -> Vec<f64> {
        let mut geometry = vec![4.0, 0.0, 0.0, frame.width, 0.0, frame.width, frame.height, 0.0, frame.height];
        for ring in &cap.rings {
            geometry.push(ring.len() as f64);
            for &point in ring {
                let (x, y) = frame.project(point);
                geometry.push(x);
                geometry.push(y);
            }
        }
        geometry
    }

    #[test]
    fn the_subsolar_point_sits_on_the_tropics_at_the_solstices_and_follows_utc_noon() {
        // 2026-06-21 08:24 UTC 夏至（Meeus）：赤纬 +23.44°；直射点经度 = 180 − (UTC 分钟 + 均时差)/4。
        let (lat, lon) = subsolar_point(SUMMER);
        assert!((lat - 23.44).abs() < 0.05, "{lat}");
        // 08:24 UTC 时直射点在东经 54° 附近（均时差 −1.6 分）。
        assert!((lon - 54.4).abs() < 1.0, "{lon}");
        // 2026-12-21 20:50 UTC 冬至：赤纬 −23.44°。
        let (lat, _) = subsolar_point(WINTER);
        assert!((lat + 23.44).abs() < 0.05, "{lat}");
        // 直射点处太阳高度应接近 90°。
        let (lat, lon) = subsolar_point(1_789_542_000.0);
        assert!(astronomy::elevation(1_789_542_000.0, lat, lon) > 89.5);
    }

    /// 判据是 `astronomy::elevation` 本身（太阳高度 ≥ h0 就在亮区）：2° 网格铺满全球，离水平线 0.5° 以内的点不算，
    /// 其余逐点用 even-odd 射线法问「整张图减夜冠」的环。曙暮（−6°）与昼（−0.833°）两条水平线各核一遍。
    #[test]
    fn day_and_twilight_fills_agree_with_the_solar_elevation_on_a_world_grid() {
        let (width, height) = (720.0, 360.0);
        let frame = Frame::new(width, height, (-90.0, 90.0));
        let (mut worst, mut misses, mut checked) = (1.0_f64, 0usize, 0usize);
        for instant in grid_instants() {
            let subsolar = subsolar_point(instant);
            for (horizon, style) in [(TWILIGHT_HORIZON, "twilight"), (DAY_HORIZON, "day")] {
                let rings = rings_of(&lit_region(frame, &night_cap(subsolar, horizon)));
                assert_eq!(rings[0], vec![(0.0, 0.0), (width, 0.0), (width, height), (0.0, height)], "第一环是整张图");
                assert!(rings.len() >= 2);
                let (mut agree, mut total) = (0usize, 0usize);
                for lat in (-89..=89).step_by(2) {
                    for lon in (-179..=179).step_by(2) {
                        let (lat, lon) = (f64::from(lat), f64::from(lon));
                        let elevation = astronomy::elevation(instant, lat, lon);
                        if (elevation - horizon).abs() < 0.5 {
                            continue; // 线上的点不算
                        }
                        total += 1;
                        let pixel = ((lon + 180.0) / 360.0 * width, (90.0 - lat) / 180.0 * height);
                        if even_odd(&rings, pixel) == (elevation >= horizon) {
                            agree += 1;
                        }
                    }
                }
                let share = agree as f64 / total as f64;
                worst = worst.min(share);
                misses += total - agree;
                checked += total;
                assert!(share >= 0.995, "{instant} {style}: {agree}/{total}");
            }
        }
        eprintln!("昼 / 曙暮网格：{} 个时刻 × 2 层，核了 {checked} 点，不一致 {misses} 点，最差一层 {:.4}", grid_instants().len(), worst);
    }

    /// 两个分点当天两条线都是不含极的小圆（两极都亮），晨昏线闭合；两个至日是盖住极点的那种，晨昏线横贯全图。
    #[test]
    fn equinoxes_draw_closed_loops_and_solstices_draw_a_line_across() {
        for instant in [MARCH, SEPTEMBER] {
            let subsolar = subsolar_point(instant);
            assert!(subsolar.0.abs() < 0.1, "{subsolar:?}");
            for horizon in [DAY_HORIZON, TWILIGHT_HORIZON] {
                let cap = night_cap(subsolar, horizon);
                for edge in &cap.edges {
                    assert_eq!(edge.first(), edge.last(), "小圆首尾相接");
                }
                assert!(astronomy::elevation(instant, 89.9, 0.0) > horizon && astronomy::elevation(instant, -89.9, 0.0) > horizon);
            }
            let edges = night_cap(subsolar, DAY_HORIZON).edges;
            assert!(!edges.is_empty() && edges.len() <= 2);
        }
        // 夜里那个极：夏至是南极，冬至是北极（环最后两个点是那个极的两个角）。
        for (instant, pole) in [(SUMMER, -90.0), (WINTER, 90.0)] {
            let cap = night_cap(subsolar_point(instant), DAY_HORIZON);
            assert_eq!(cap.edges.len(), 1);
            assert_eq!(cap.edges[0].first().unwrap().0, -180.0);
            assert_eq!(cap.edges[0].last().unwrap().0, 180.0);
            let ring = &cap.rings[0];
            assert_eq!(ring[ring.len() - 2], (180.0, pole));
            assert_eq!(ring[ring.len() - 1], (-180.0, pole));
        }
    }

    #[test]
    fn terminator_vertices_sit_on_the_minus_0833_degree_horizon() {
        let mut worst: f64 = 0.0;
        for instant in grid_instants() {
            let edges = night_cap(subsolar_point(instant), DAY_HORIZON).edges;
            assert!(!edges.is_empty());
            for edge in &edges {
                assert!(edge.len() >= 2);
                for &(lon, lat) in edge {
                    let off = (astronomy::elevation(instant, lat, lon) - DAY_HORIZON).abs();
                    worst = worst.max(off);
                    assert!(off < 0.1, "{instant}: ({lon}, {lat}) 偏 {off}°");
                }
            }
        }
        eprintln!("晨昏线顶点离 −0.833° 最远 {worst:.2e}°");
    }

    /// 直接喂人造的直射点：赤纬正好为 0（分点那一刻）、±0、极点正好压线与压线前后一点点、至日，经度贴着 ±180°。
    /// 判据是球面上的定义 sin h = sinφ sinδ + cosφ cosδ cos(λ − λs)，不经过被测的构造。
    #[test]
    fn night_caps_stay_finite_and_right_at_the_equinox_and_where_the_pole_touches_the_edge() {
        let elevation = |subsolar: (f64, f64), lat: f64, lon: f64| {
            let (phi, delta) = (lat.to_radians(), subsolar.0.to_radians());
            (phi.sin() * delta.sin() + phi.cos() * delta.cos() * (lon - subsolar.1).to_radians().cos()).clamp(-1.0, 1.0).asin().to_degrees()
        };
        let whole = vec![(-180.0, 90.0), (180.0, 90.0), (180.0, -90.0), (-180.0, -90.0)];
        for horizon in [DAY_HORIZON, TWILIGHT_HORIZON] {
            let touch = -horizon; // 赤纬到这么大，球冠正好碰到极点
            for declination in [0.0, 1e-12, 0.4, touch - 1e-5, touch - 2e-6, touch - 1e-7, touch, touch + 1e-7, touch + 2e-6, touch + 1e-5, 23.44] {
                for declination in [declination, -declination] {
                    for sun_longitude in [-180.0, -179.99, 0.0, 37.5, 179.99] {
                        let subsolar = (declination, sun_longitude);
                        let cap = night_cap(subsolar, horizon);
                        for ring in cap.rings.iter().chain(&cap.edges) {
                            assert!(ring.len() >= 3);
                            assert!(ring.iter().all(|p| p.0.is_finite() && p.1.is_finite() && (-90.0..=90.0).contains(&p.1)), "{subsolar:?} {horizon}");
                        }
                        // 边界上的点就在这条水平线上（极点旁 asin 的条件数差，留 1e-5°；压线时落在极点上的点差的是 POLE_MARGIN 以内）。
                        for line in &cap.edges {
                            for &(lon, lat) in line {
                                assert!((elevation(subsolar, lat, lon) - horizon).abs() < 1e-5, "{subsolar:?} {horizon}: ({lon}, {lat})");
                            }
                        }
                        if declination.abs() < touch - POLE_MARGIN {
                            // 小圆：经度只在反日点经线 ±90° 以内，伸出图外的那一边有一份平移副本。
                            let center = wrap(sun_longitude + 180.0);
                            let (west, east) = cap.rings[0].iter().fold((f64::INFINITY, f64::NEG_INFINITY), |(w, e), p| (w.min(p.0), e.max(p.0)));
                            assert!(west > center - 90.0 && east < center + 90.0, "{subsolar:?}: {west} … {east}");
                            assert_eq!(cap.rings.len(), 1 + usize::from(west < -180.0 || east > 180.0));
                        }
                        let mut rings = vec![whole.clone()];
                        rings.extend(cap.rings.iter().cloned());
                        let (mut agree, mut total) = (0usize, 0usize);
                        for lat in (-88..=88).step_by(4) {
                            for lon in (-178..=178).step_by(4) {
                                let (lat, lon) = (f64::from(lat), f64::from(lon));
                                let h = elevation(subsolar, lat, lon);
                                if (h - horizon).abs() < 0.5 {
                                    continue;
                                }
                                total += 1;
                                if even_odd(&rings, (lon, lat)) == (h >= horizon) {
                                    agree += 1;
                                }
                            }
                        }
                        assert!(agree as f64 >= 0.995 * total as f64, "{subsolar:?} {horizon}: {agree}/{total}");
                    }
                }
            }
        }
    }

    #[test]
    fn the_scene_projects_places_and_reports_who_is_in_daylight() {
        let value = dispatch(
            "worldmap.scene",
            json!({"instant": 1_789_542_000.0 + 12.0 * 3600.0, "width": 360.0, "height": 180.0,
                   "places": [{"latitude": 34.05, "longitude": -118.24, "home": true}, {"latitude": 35.68, "longitude": 139.69},
                              {"latitude": 91.0, "longitude": 0.0}]}),
        )
        .unwrap();
        let pins = value["pins"].as_array().unwrap();
        assert_eq!(pins.len(), 2, "越界的地点不画");
        assert!((pins[0]["x"].as_f64().unwrap() - (180.0 - 118.24)).abs() < 0.01);
        assert!((pins[0]["y"].as_f64().unwrap() - (90.0 - 34.05)).abs() < 0.01);
        // 洛杉矶 2026-09-16 12:00 当地是白天，东京（次日 4:00）还是夜里：脚下的地面一个亮一个暗，颜色是 "#rrggbb"。
        assert_eq!(value["lit"], json!([0]));
        assert_eq!(pins[0]["home"], json!(true));
        assert_eq!((pins[0]["dark"].as_bool(), pins[1]["dark"].as_bool()), (Some(false), Some(true)));
        for pin in pins {
            let fill = pin["fill"].as_str().unwrap();
            assert!(fill.len() == 7 && fill.starts_with('#') && u32::from_str_radix(&fill[1..], 16).is_ok(), "{fill}");
        }
        assert!(value.get("commands").is_none());
        assert!(dispatch("worldmap.scene", json!({"instant": 0.0, "width": 0.0, "height": 1.0})).is_err());
        // 纬度裁剪：北纬 84° 落在顶边、南纬 62° 落在底边，纬度 34° 按比例。
        let cropped = dispatch(
            "worldmap.scene",
            json!({"instant": 1_789_542_000.0, "width": 360.0, "height": 146.0, "latitudeMin": -62.0, "latitudeMax": 84.0,
                   "places": [{"latitude": 34.0, "longitude": 0.0}]}),
        )
        .unwrap();
        assert!((cropped["pins"][0]["y"].as_f64().unwrap() - 50.0).abs() < 0.01);
        // 无效的裁剪退回整个球面。
        let whole = dispatch("worldmap.scene", json!({"instant": 1_789_542_000.0, "width": 360.0, "height": 180.0, "latitudeMin": 50.0, "latitudeMax": 10.0,
            "places": [{"latitude": 0.0, "longitude": 0.0}]})).unwrap();
        assert!((whole["pins"][0]["y"].as_f64().unwrap() - 90.0).abs() < 0.01);
    }

    #[test]
    fn instants_outside_the_supported_range_and_absurd_sizes_are_errors() {
        let input = |instant: f64, width: f64| Input { instant, width, height: 180.0, places: Vec::new(), latitude_min: -90.0, latitude_max: 90.0 };
        for instant in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY, 1e300, -1e300, -5_364_662_401.0, 4_133_980_801.0] {
            assert!(scene(&input(instant, 360.0)).is_err(), "{instant}");
        }
        for width in [0.0, -1.0, f64::NAN, f64::INFINITY, 100_001.0] {
            assert!(scene(&input(SUMMER, width)).is_err(), "{width}");
        }
        // 范围两端与 1970 年都能画，而且每个数都有限（NaN / inf 会被写成 null）。
        for instant in [-5_364_662_400.0, 0.0, 4_133_980_800.0] {
            let value = scene(&input(instant, 100_000.0)).unwrap();
            for key in ["x", "y", "latitude", "longitude", "illumination", "cycle"] {
                assert!(value["moon"][key].as_f64().is_some_and(f64::is_finite), "{instant} moon.{key}");
            }
            assert_eq!(numbers(&value["sun"]).len(), 2);
        }
        // JSON 写不出 NaN：null 与字符串同样是错误。
        for instant in [Value::Null, json!("1789542000"), json!(1e300)] {
            assert!(dispatch("worldmap.scene", json!({"instant": instant, "width": 360.0, "height": 180.0})).is_err());
        }
        // 传输层：1e400 在 arbitrary_precision 下读成 inf，也得是错误而不是 panic 或 null 几何。
        for bytes in [
            &br#"{"operation":"worldmap.scene","payload":{"instant":1e400,"width":360,"height":180}}"#[..],
            br#"{"operation":"worldmap.scene","payload":{"instant":1789542000,"width":1e400,"height":180}}"#,
        ] {
            let reply: Value = serde_json::from_slice(&crate::respond(bytes)).unwrap();
            assert!(reply["error"].is_string(), "{reply}");
        }
        // 裁剪与地点的 inf 退回默认 / 不画。
        let reply: Value = serde_json::from_slice(&crate::respond(
            br#"{"operation":"worldmap.scene","payload":{"instant":1789542000,"width":360,"height":180,"latitudeMin":-1e400,"latitudeMax":1e400,"places":[{"latitude":1e400,"longitude":0}]}}"#,
        ))
        .unwrap();
        assert_eq!(reply["value"]["pins"], json!([]));
    }

    /// 独立判据：Paul Schlyter《How to compute planetary positions》里的月球：开普勒轨道根数 + 12 项经度摄动 + 5 项纬度摄动，
    /// 恒星时用他的 GMST = 太阳平黄经 + 180° + UT × 15°/时。被测的是 Meeus 47.A 截断级数 + Meeus 12.4 恒星时，两条路没有共用的式子；
    /// Schlyter 自称误差约 2′，这里只拿来核 1° 量级的门槛。返回月下点（纬度, 经度），度。
    fn schlyter_sublunar(unix: f64) -> (f64, f64) {
        let d = unix / DAY - 10_956.0; // 自 1999-12-31 00:00 UT（JD 2451543.5）起的日数
        let sin = |x: f64| x.to_radians().sin();
        let cos = |x: f64| x.to_radians().cos();
        let node = 125.1228 - 0.052_953_808_3 * d;
        let inclination = 5.1454;
        let perigee = 318.0634 + 0.164_357_322_3 * d;
        let (axis, e) = (60.2666, 0.054_900_f64);
        let mean = (115.3654 + 13.064_992_950_9 * d).rem_euclid(360.0);
        let sun_perihelion = 282.9404 + 4.709_35e-5 * d;
        let sun_mean = (356.0470 + 0.985_600_258_5 * d).rem_euclid(360.0);
        let ecliptic = 23.4393 - 3.563e-7 * d;
        // 开普勒方程（度）：先一阶近似，再牛顿迭代。
        let mut anomaly = mean + e.to_degrees() * sin(mean) * (1.0 + e * cos(mean));
        for _ in 0..10 {
            anomaly -= (anomaly - e.to_degrees() * sin(anomaly) - mean) / (1.0 - e * cos(anomaly));
        }
        let (xv, yv) = (axis * (cos(anomaly) - e), axis * (1.0 - e * e).sqrt() * sin(anomaly));
        let (true_anomaly, r) = (yv.atan2(xv).to_degrees(), xv.hypot(yv));
        let u = true_anomaly + perigee;
        let xh = r * (cos(node) * cos(u) - sin(node) * sin(u) * cos(inclination));
        let yh = r * (sin(node) * cos(u) + cos(node) * sin(u) * cos(inclination));
        let zh = r * sin(u) * sin(inclination);
        let (mut lon, mut lat) = (yh.atan2(xh).to_degrees(), zh.atan2(xh.hypot(yh)).to_degrees());
        let sun_longitude = sun_mean + sun_perihelion; // Ls
        let moon_longitude = mean + perigee + node; // Lm
        let (mm, ms, dd, ff) = (mean, sun_mean, moon_longitude - sun_longitude, moon_longitude - node);
        lon += -1.274 * sin(mm - 2.0 * dd) + 0.658 * sin(2.0 * dd) - 0.186 * sin(ms) - 0.059 * sin(2.0 * mm - 2.0 * dd)
            - 0.057 * sin(mm - 2.0 * dd + ms) + 0.053 * sin(mm + 2.0 * dd) + 0.046 * sin(2.0 * dd - ms) + 0.041 * sin(mm - ms)
            - 0.035 * sin(dd) - 0.031 * sin(mm + ms) - 0.015 * sin(2.0 * ff - 2.0 * dd) + 0.011 * sin(mm - 4.0 * dd);
        lat += -0.173 * sin(ff - 2.0 * dd) - 0.055 * sin(mm - ff - 2.0 * dd) - 0.046 * sin(mm + ff - 2.0 * dd)
            + 0.033 * sin(ff + 2.0 * dd) + 0.017 * sin(2.0 * mm + ff);
        // 黄道 → 赤道（直角坐标绕 x 轴转 ε）。
        let xe = cos(lat) * cos(lon);
        let ye = cos(lat) * sin(lon) * cos(ecliptic) - sin(lat) * sin(ecliptic);
        let ze = cos(lat) * sin(lon) * sin(ecliptic) + sin(lat) * cos(ecliptic);
        let (right_ascension, declination) = (ye.atan2(xe).to_degrees(), ze.atan2(xe.hypot(ye)).to_degrees());
        let sidereal = sun_longitude + 180.0 + unix.rem_euclid(DAY) / 3600.0 * 15.0;
        (declination, (right_ascension - sidereal + 180.0).rem_euclid(360.0) - 180.0)
    }

    /// 两点间的球面角距（度）。
    fn separation(a: (f64, f64), b: (f64, f64)) -> f64 {
        let (p, q) = (a.0.to_radians(), b.0.to_radians());
        (p.sin() * q.sin() + p.cos() * q.cos() * (a.1 - b.1).to_radians().cos()).clamp(-1.0, 1.0).acos().to_degrees()
    }

    #[test]
    fn the_sublunar_point_matches_an_independent_lunar_theory() {
        // 2026-01-06 起每 61 天一个（跨到 2027-11），再加 12 个伪随机时刻。
        let mut instants: Vec<f64> = (0..12).map(|i| FROM_2026 + 5.3 * DAY + f64::from(i) * 61.0 * DAY).collect();
        instants.extend(random_instants(12, 0x5EED_F00D_6D00));
        let (mut worst_latitude, mut worst_separation) = (0.0_f64, 0.0_f64);
        for &instant in &instants {
            let ours = sublunar_point(instant);
            let judge = schlyter_sublunar(instant);
            let (dlat, apart) = ((ours.0 - judge.0).abs(), separation(ours, judge));
            worst_latitude = worst_latitude.max(dlat);
            worst_separation = worst_separation.max(apart);
            assert!(dlat < 1.0, "{instant}: {ours:?} vs {judge:?}");
            assert!(apart < 1.5, "{instant}: {ours:?} vs {judge:?}");
            assert!((-180.0..=180.0).contains(&ours.1));
            // 场景里给的就是这一点，按同一个投影落在图上。
            let value = scene_at(instant, 720.0, 360.0);
            let moon = &value["moon"];
            assert_eq!(moon["latitude"].as_f64(), Some(ours.0));
            assert_eq!(moon["longitude"].as_f64(), Some(ours.1));
            assert!((moon["x"].as_f64().unwrap() - (ours.1 + 180.0) * 2.0).abs() < 1e-9);
            assert!((moon["y"].as_f64().unwrap() - (90.0 - ours.0) * 2.0).abs() < 1e-9);
        }
        eprintln!("月下点对 Schlyter：{} 个时刻，纬度最多差 {worst_latitude:.3}°，角距最多 {worst_separation:.3}°", instants.len());
    }

    /// NASA 表里 2026-09-24 之后的第一次朔与望：朔时月下点贴着直射点，望时贴着反日点（差的只是月球黄纬，≤ 5.3°）。
    #[test]
    fn the_moon_stands_over_the_sun_at_new_moon_and_opposite_at_full_moon() {
        let fixture: Value = serde_json::from_str(include_str!("../fixtures/astronomy/nasa-moon-phases-2026.json")).unwrap();
        let after = 1_790_208_000.0; // 2026-09-24 00:00 UTC
        let next = |phase: f64| {
            fixture["events"]
                .as_array()
                .unwrap()
                .iter()
                .filter(|e| e["phase"].as_f64() == Some(phase))
                .filter_map(|e| e["unix"].as_f64())
                .filter(|&t| t > after)
                .fold(f64::INFINITY, f64::min)
        };
        let (new_moon, full_moon) = (next(0.0), next(180.0));
        assert_eq!((new_moon, full_moon), (1_791_647_400.0, 1_790_441_340.0)); // 2026-10-10 15:50、2026-09-26 16:49
        let apart_from_sun = |t: f64| separation(sublunar_point(t), subsolar_point(t));
        let apart_from_antisun = |t: f64| {
            let (lat, lon) = subsolar_point(t);
            separation(sublunar_point(t), (-lat, wrap(lon + 180.0)))
        };
        // 公布的那一刻，以及前后一天里最近的那一刻（每 10 分钟看一次）。
        let closest = |event: f64, distance: &dyn Fn(f64) -> f64| (-144..=144).map(|k| distance(event + f64::from(k) * 600.0)).fold(f64::INFINITY, f64::min);
        let at_new = apart_from_sun(new_moon);
        let at_full = apart_from_antisun(full_moon);
        assert!(at_new < 7.0, "朔 {at_new}°");
        assert!(at_full < 7.0, "望 {at_full}°");
        assert!(closest(new_moon, &apart_from_sun) < 7.0);
        assert!(closest(full_moon, &apart_from_antisun) < 7.0);
        // 反过来：朔时离反日点、望时离直射点都差不多半个地球。
        assert!(apart_from_antisun(new_moon) > 173.0 && apart_from_sun(full_moon) > 173.0);
        eprintln!("朔（2026-10-10）月下点离直射点 {at_new:.2}°，望（2026-09-26）离反日点 {at_full:.2}°");
    }

    #[test]
    fn the_moon_declination_stays_within_29_degrees() {
        let mut extreme: f64 = 0.0;
        let mut t = FROM_2026;
        while t < UNTIL_2028 {
            let (latitude, longitude) = sublunar_point(t);
            assert!(latitude.abs() < 29.0, "{t}: {latitude}");
            assert!((-180.0..=180.0).contains(&longitude), "{t}: {longitude}");
            extreme = extreme.max(latitude.abs());
            t += 3.0 * 3600.0;
        }
        // 2024–2025 是月球大静止（±28.7°），2026–2027 刚过去不久，赤纬仍能到 27° 以上。
        assert!(extreme > 26.0, "{extreme}");
    }

    #[test]
    fn moon_phase_fields_are_the_astronomy_page_values() {
        for instant in [SUMMER, WINTER, 1_790_441_340.0, 1_791_647_400.0, 1_789_542_000.0] {
            let map = scene_at(instant, 360.0, 180.0);
            let page = astronomy::dispatch(
                "astronomy.compute",
                json!({"dayStart": instant - 43_200.0, "dayEnd": instant + 43_200.0, "instant": instant, "latitude": 0.0, "longitude": 0.0}),
            )
            .unwrap();
            for key in ["phase", "cycle", "illumination"] {
                assert!(!page["moon"][key].is_null());
                assert_eq!(map["moon"][key], page["moon"][key], "{instant} {key}");
            }
        }
    }

    /// 每帧的代价：整条 FFI 路（解析请求、算、写回 JSON）与纯几何（晨昏线 + 直射点 + 月下点 + 月相）分开计。
    #[test]
    #[ignore = "计时：cargo test --release --lib worldmap -- --ignored --nocapture"]
    fn scene_timing() {
        use std::hint::black_box;
        use std::time::Instant;
        let places = json!([{"latitude": 34.05, "longitude": -118.24, "home": true}, {"latitude": 35.68, "longitude": 139.69},
                            {"latitude": 51.51, "longitude": -0.13}, {"latitude": -33.87, "longitude": 151.21}]);
        let instants: Vec<f64> = (0..64).map(|i| FROM_2026 + f64::from(i) * 5.7 * DAY + f64::from(i) * 3_600.0).collect();
        let rounds = 4_000;
        let per_call = |start: Instant| start.elapsed().as_secs_f64() * 1e6 / rounds as f64;
        let start = Instant::now();
        for i in 0..rounds {
            let t = instants[i % instants.len()];
            black_box((terminator_lines(t), sublunar_point(t), astronomy::moon_phase(t).cycle));
        }
        println!("worldmap 纯几何（晨昏线 + 月下点 + 月相）：{:.1} µs/次", per_call(start));
        let requests: Vec<Vec<u8>> = instants
            .iter()
            .map(|&instant| serde_json::to_vec(&json!({"operation": "worldmap.scene", "payload": {"instant": instant, "width": 960.0, "height": 368.0, "places": places}})).unwrap())
            .collect();
        let start = Instant::now();
        let mut bytes = 0usize;
        for i in 0..rounds {
            bytes += black_box(crate::respond(black_box(&requests[i % requests.len()]))).len();
        }
        println!("worldmap.scene 整条 FFI 路 {:.1} µs/次，回复 {} 字节", per_call(start), bytes / rounds);
    }
}
