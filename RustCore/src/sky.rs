// SPDX-License-Identifier: GPL-3.0-only
//! Dayside 的材料只有光。
//!
//! - 天色：某地此刻的天（天顶与地平线两色）按太阳高度插值，破晓偏玫瑰、黄昏偏琥珀；夜是墨，白天近乎白纸，
//!   颜色只在晨昏线附近。插值在 OKLab 里做：冷色的天顶与暖色的地平线直接按色相插值会绕进绿色。
//! - 可读：字色只有墨与纸两种，字与底的对比度按 WCAG 与 APCA 实算；不够就把底色往深或往浅推（色相与彩度不动），
//!   直到小字够 `need`（平常 5.5，系统「提高对比度」时 7）。底色给字让路。
//! - 地图：逐像素按太阳高度上色（`mt_sky_map_raster`），海陆两套底色；地形来自 Natural Earth 灰度地形
//!   （宿主解码后交给 `mt_sky_relief_set`），夜里用整幅明暗、白天只留山脊山谷的局部明暗。
//!   颜色先按太阳高度（1/4 度一档）× 升落 × 海陆查表，逐像素只做一次乘加、一次反正弦与一次查表。
//! - 面板（`sky.panel`）：每行的天色与字色、一天里的词（破晓 / 下午 / 深夜…，宿主再本地化）、太阳弧上太阳的位置、
//!   框的颜色（这里的天顶）与滑块轨道（这里前后 12 小时的天）。
//! - 昼夜条（`sky.lane`）：一个地方一段时间里的天色色标，宿主画成渐变。
use std::sync::{Arc, Mutex, OnceLock};

use serde::Deserialize;
use serde_json::{json, Value};

use crate::astronomy;
use crate::worldmap;

// ---------------------------------------------------------------- 颜色

/// OKLCH：明度 0…1、彩度、色相（度）。
#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) struct Lch {
    pub(crate) l: f64,
    pub(crate) c: f64,
    pub(crate) h: f64,
}

pub(crate) const fn lch(l: f64, c: f64, h: f64) -> Lch {
    Lch { l, c, h }
}

fn to_lab(c: Lch) -> (f64, f64, f64) {
    let (s, co) = c.h.to_radians().sin_cos();
    (c.l, c.c * co, c.c * s)
}

fn from_lab(l: f64, a: f64, b: f64) -> Lch {
    Lch {
        l,
        c: a.hypot(b),
        h: b.atan2(a).to_degrees().rem_euclid(360.0),
    }
}

/// 在 OKLab 里线性插值（t = 0 是 `a`，1 是 `b`）。
pub(crate) fn mix(a: Lch, b: Lch, t: f64) -> Lch {
    let (l1, a1, b1) = to_lab(a);
    let (l2, a2, b2) = to_lab(b);
    from_lab(l1 + (l2 - l1) * t, a1 + (a2 - a1) * t, b1 + (b2 - b1) * t)
}

/// OKLCH → 线性 sRGB（未截断）。
fn to_linear(c: Lch) -> [f64; 3] {
    let (l, a, b) = to_lab(c);
    let l_ = (l + 0.396_337_777_4 * a + 0.215_803_757_3 * b).powi(3);
    let m_ = (l - 0.105_561_345_8 * a - 0.063_854_172_8 * b).powi(3);
    let s_ = (l - 0.089_484_177_5 * a - 1.291_485_548_0 * b).powi(3);
    [
        4.076_741_662_1 * l_ - 3.307_711_591_3 * m_ + 0.230_969_929_2 * s_,
        -1.268_438_004_6 * l_ + 2.609_757_401_1 * m_ - 0.341_319_396_5 * s_,
        -0.004_196_086_3 * l_ - 0.703_418_614_7 * m_ + 1.707_614_701_0 * s_,
    ]
}

fn encode(x: f64) -> f64 {
    let x = x.clamp(0.0, 1.0);
    if x <= 0.003_130_8 {
        12.92 * x
    } else {
        1.055 * x.powf(1.0 / 2.4) - 0.055
    }
}

/// OKLCH → 8 位 sRGB（超出色域的分量截断）。
pub(crate) fn srgb8(c: Lch) -> [u8; 3] {
    let v = to_linear(c);
    [0, 1, 2].map(|i| (encode(v[i]) * 255.0).round() as u8)
}

pub(crate) fn hex(c: Lch) -> String {
    let [r, g, b] = srgb8(c);
    format!("#{r:02x}{g:02x}{b:02x}")
}

/// 屏幕上的 8 位 sRGB 转回 OKLab，分隔判据与输出颜色一致。
fn display_lab(c: Lch) -> (f64, f64, f64) {
    let [r, g, b] = srgb8(c).map(|v| {
        let v = f64::from(v) / 255.0;
        if v <= 0.040_45 {
            v / 12.92
        } else {
            ((v + 0.055) / 1.055).powf(2.4)
        }
    });
    let l = (0.412_221_470_8 * r + 0.536_332_536_3 * g + 0.051_445_992_9 * b).cbrt();
    let m = (0.211_903_498_2 * r + 0.680_699_545_1 * g + 0.107_396_956_6 * b).cbrt();
    let s = (0.088_302_461_9 * r + 0.281_718_837_6 * g + 0.629_978_700_5 * b).cbrt();
    (
        0.210_454_255_3 * l + 0.793_617_785_0 * m - 0.004_072_046_8 * s,
        1.977_998_495_1 * l - 2.428_592_205_0 * m + 0.450_593_709_9 * s,
        0.025_904_037_1 * l + 0.782_771_766_2 * m - 0.808_675_766_0 * s,
    )
}

/// WCAG 相对亮度（按截断后的 8 位 sRGB 算，与屏幕上显示的是同一个颜色）。
pub(crate) fn luminance(c: Lch) -> f64 {
    let [r, g, b] = srgb8(c).map(|v| {
        let v = f64::from(v) / 255.0;
        if v <= 0.040_45 {
            v / 12.92
        } else {
            ((v + 0.055) / 1.055).powf(2.4)
        }
    });
    0.2126 * r + 0.7152 * g + 0.0722 * b
}

pub(crate) fn contrast(a: Lch, b: Lch) -> f64 {
    let (x, y) = (luminance(a), luminance(b));
    (x.max(y) + 0.05) / (x.min(y) + 0.05)
}

/// APCA 明度对比：按屏幕上的 8 位 sRGB 算，深字浅底为正，浅字深底为负。
pub(crate) fn apca(text: Lch, background: Lch) -> f64 {
    let y = |color: Lch| {
        let [r, g, b] = srgb8(color).map(|v| (f64::from(v) / 255.0).powf(2.4));
        let y = 0.212_672_9 * r + 0.715_152_2 * g + 0.072_175_0 * b;
        if y < 0.022 {
            y + (0.022 - y).powf(1.414)
        } else {
            y
        }
    };
    let (text, background) = (y(text), y(background));
    if (background - text).abs() < 0.0005 {
        return 0.0;
    }
    if background > text {
        let s = (background.powf(0.56) - text.powf(0.57)) * 1.14;
        if s < 0.1 {
            0.0
        } else {
            (s - 0.027) * 100.0
        }
    } else {
        let s = (background.powf(0.65) - text.powf(0.62)) * 1.14;
        if s > -0.1 {
            0.0
        } else {
            (s + 0.027) * 100.0
        }
    }
}

// ---------------------------------------------------------------- 天色

/// 墨与纸：面板上一切字只用这两种颜色。
pub(crate) const INK: Lch = lch(0.20, 0.022, 265.0);
pub(crate) const PAPER: Lch = lch(0.962, 0.006, 90.0);

/// 太阳升起时（破晓那一侧）的天：（太阳高度，天顶，地平线）。
const RISE: [(f64, Lch, Lch); 11] = [
    (-90.0, lch(0.140, 0.018, 268.0), lch(0.152, 0.022, 266.0)),
    (-24.0, lch(0.150, 0.022, 268.0), lch(0.172, 0.028, 267.0)),
    (-15.0, lch(0.168, 0.032, 268.0), lch(0.215, 0.046, 272.0)),
    (-9.0, lch(0.200, 0.048, 268.0), lch(0.300, 0.070, 286.0)),
    (-4.5, lch(0.270, 0.058, 276.0), lch(0.500, 0.090, 345.0)),
    (-1.0, lch(0.380, 0.058, 272.0), lch(0.660, 0.100, 30.0)),
    (2.0, lch(0.600, 0.045, 255.0), lch(0.815, 0.085, 62.0)),
    (7.0, lch(0.800, 0.030, 245.0), lch(0.895, 0.060, 78.0)),
    (18.0, lch(0.930, 0.010, 240.0), lch(0.950, 0.020, 84.0)),
    (40.0, lch(0.962, 0.004, 245.0), lch(0.967, 0.008, 90.0)),
    (90.0, lch(0.972, 0.003, 245.0), lch(0.975, 0.006, 95.0)),
];

/// 太阳落下时（黄昏那一侧）：曙暮与低空更暖、更偏琥珀，其余同 `RISE`。
const SET: [(f64, Lch, Lch); 11] = [
    RISE[0],
    RISE[1],
    RISE[2],
    (-9.0, lch(0.200, 0.052, 272.0), lch(0.305, 0.078, 300.0)),
    (-4.5, lch(0.265, 0.062, 285.0), lch(0.505, 0.110, 18.0)),
    (-1.0, lch(0.370, 0.062, 290.0), lch(0.650, 0.128, 42.0)),
    (2.0, lch(0.580, 0.055, 265.0), lch(0.795, 0.118, 60.0)),
    (7.0, lch(0.780, 0.038, 250.0), lch(0.880, 0.080, 72.0)),
    (18.0, lch(0.915, 0.016, 242.0), lch(0.942, 0.034, 80.0)),
    RISE[9],
    RISE[10],
];

/// 某地此刻的天：天顶、地平线与二者之间（偏地平线）的「整体」颜色。
#[derive(Clone, Copy, Debug)]
pub(crate) struct Sky {
    pub(crate) top: Lch,
    pub(crate) horizon: Lch,
    pub(crate) mid: Lch,
}

pub(crate) fn sky(altitude: f64, rising: bool) -> Sky {
    let table = if rising { &RISE } else { &SET };
    let altitude = if altitude.is_finite() {
        altitude.clamp(-90.0, 90.0)
    } else {
        -90.0
    };
    let mut i = 0;
    while i < table.len() - 2 && altitude > table[i + 1].0 {
        i += 1;
    }
    let (a, b) = (table[i], table[i + 1]);
    let t = ((altitude - a.0) / (b.0 - a.0)).clamp(0.0, 1.0);
    let top = mix(a.1, b.1, t);
    let horizon = mix(a.2, b.2, t);
    Sky {
        top,
        horizon,
        mid: mix(top, horizon, 0.6),
    }
}

/// 底色给字让路之后的颜色与字色。
#[derive(Clone, Copy, Debug)]
pub(crate) struct Readable {
    pub(crate) top: Lch,
    pub(crate) horizon: Lch,
    pub(crate) mid: Lch,
    /// 字用墨（true）还是纸（false）。
    pub(crate) ink: bool,
    /// 字对底色（天顶与地平线两端里更差的那一端）的对比度。
    pub(crate) ratio: f64,
}

/// 选墨或纸；两法有分歧时取所需步数更少的方向，每步明度 0.012，最多 60 步。
pub(crate) fn readable(sky: &Sky, need: f64) -> Readable {
    let worst = |fg: Lch, top: Lch, horizon: Lch| contrast(fg, top).min(contrast(fg, horizon));
    let ink = worst(INK, sky.top, sky.horizon) > worst(PAPER, sky.top, sky.horizon);
    let perceptual =
        |fg: Lch, top: Lch, horizon: Lch| apca(fg, top).abs().min(apca(fg, horizon).abs());
    let apca_ink = perceptual(INK, sky.top, sky.horizon) > perceptual(PAPER, sky.top, sky.horizon);
    if ink != apca_ink {
        let candidate = |use_ink: bool| {
            let fg = if use_ink { INK } else { PAPER };
            let step = if use_ink { 0.012 } else { -0.012 };
            let (mut top, mut horizon) = (sky.top, sky.horizon);
            for steps in 0..=60 {
                let ratio = worst(fg, top, horizon);
                let wcag_ink = worst(INK, top, horizon) > worst(PAPER, top, horizon);
                let apca_ink = perceptual(INK, top, horizon) > perceptual(PAPER, top, horizon);
                if ratio >= need && wcag_ink == use_ink && apca_ink == use_ink {
                    return Some((
                        steps,
                        Readable {
                            top,
                            horizon,
                            mid: mix(top, horizon, 0.5),
                            ink: use_ink,
                            ratio,
                        },
                    ));
                }
                if steps < 60 {
                    top.l = (top.l + step).clamp(0.04, 0.99);
                    horizon.l = (horizon.l + step).clamp(0.04, 0.99);
                }
            }
            None
        };
        // 步数相同沿用 WCAG 的选择；两个方向都达不到时走原来的算法。
        let selected = match (candidate(ink), candidate(!ink)) {
            (Some(a), Some(b)) => Some(if a.0 <= b.0 { a.1 } else { b.1 }),
            (Some(a), None) | (None, Some(a)) => Some(a.1),
            (None, None) => None,
        };
        if let Some(out) = selected {
            return out;
        }
    }
    let fg = if ink { INK } else { PAPER };
    let step = if ink { 0.012 } else { -0.012 };
    let (mut top, mut horizon) = (sky.top, sky.horizon);
    for _ in 0..60 {
        if worst(fg, top, horizon) >= need {
            break;
        }
        top.l = (top.l + step).clamp(0.04, 0.99);
        horizon.l = (horizon.l + step).clamp(0.04, 0.99);
    }
    Readable {
        top,
        horizon,
        mid: mix(top, horizon, 0.5),
        ink,
        ratio: worst(fg, top, horizon),
    }
}

/// 太阳在不在往上走：此刻这里的时角在正午之前（太阳在东边）。地图与面板同一个判据。
pub(crate) fn rising(instant: f64, longitude: f64) -> bool {
    let (_, sun_longitude) = worldmap::subsolar_point(instant);
    wrap(longitude - sun_longitude) < 0.0
}

fn wrap(longitude: f64) -> f64 {
    (longitude + 180.0).rem_euclid(360.0) - 180.0
}

// ---------------------------------------------------------------- 地表

/// 地平线：太阳上沿贴着地平线（大气折射 + 太阳半径），与日出日落、昼夜地图同一个判据。
pub(crate) const HORIZON: f64 = -0.833;
const LAND_DAY: Lch = lch(0.975, 0.016, 84.0);
const SEA_DAY: Lch = lch(0.79, 0.042, 234.0);
const LAND_NIGHT: Lch = lch(0.40, 0.032, 256.0);
const SEA_NIGHT: Lch = lch(0.145, 0.026, 266.0);

/// 地图上一点的底色：白天陆暖海冷，贴着晨昏线有一道金边；过了线夜里还有一段余晖，慢慢沉进夜色。
pub(crate) fn surface(altitude: f64, is_rising: bool, land: bool) -> Lch {
    let (day, night) = if land {
        (LAND_DAY, LAND_NIGHT)
    } else {
        (SEA_DAY, SEA_NIGHT)
    };
    if altitude >= HORIZON {
        let edge = (1.0 - (altitude - HORIZON) / 6.0).max(0.0);
        if edge <= 0.0 {
            return day;
        }
        let gold = if is_rising {
            lch(0.83, 0.075, 55.0)
        } else {
            lch(0.80, 0.095, 62.0)
        };
        return mix(day, gold, edge * 0.55);
    }
    let depth = ((HORIZON - altitude) / 14.0).min(1.0);
    let s = sky(altitude * 1.2, is_rising);
    let glow = mix(s.mid, s.horizon, 0.35);
    mix(mix(glow, night, 0.3), night, depth.powf(0.8))
}

/// 查表：太阳高度 −90…90 每 1/4 度一档 × 升落 × 海陆，存 8 位 sRGB。
const STEPS: usize = 721;
fn table() -> &'static [[u8; 3]] {
    static TABLE: OnceLock<Vec<[u8; 3]>> = OnceLock::new();
    TABLE.get_or_init(|| {
        let mut out = Vec::with_capacity(STEPS * 4);
        for i in 0..STEPS {
            let altitude = -90.0 + i as f64 / 4.0;
            for r in [false, true] {
                for land in [false, true] {
                    out.push(srgb8(surface(altitude, r, land)));
                }
            }
        }
        out
    })
}

#[cfg(test)]
fn table_index(altitude: f64, is_rising: bool, land: bool) -> usize {
    let step = ((altitude + 90.0) * 4.0)
        .round()
        .clamp(0.0, (STEPS - 1) as f64) as usize;
    (step * 2 + usize::from(is_rising)) * 2 + usize::from(land)
}

// ---------------------------------------------------------------- 地形

/// 地形按地形图自己的分辨率只算一次（宿主交来灰度图时）：每个像素是不是陆地（0 / 255）、夜里与白天的明暗乘数
/// （× `GAIN`，255 = 1.02）。灰度图（Natural Earth GRAY_50M_SR_OB：海 75…115、陆 140…220）算完就不留。
struct Terrain {
    width: usize,
    height: usize,
    north: f64,
    south: f64,
    /// 地形图分辨率上的那一份；画布恰好与地形图同尺寸、同纬度范围（地球窗）时直接拿它当画布地形，不另存一份。
    cells: Arc<Grid>,
}

/// 某个画布尺寸上的地形：每个画布像素取它在地形图上覆盖那一块的平均（陆地比例、两种乘数）。
/// 海岸按陆地比例混两种底色，缩小时不起锯齿；只按尺寸与纬度裁法缓存，窗口拉大拉小只重做这一步。
enum GridStorage {
    Owned { land: Vec<u8>, night: Vec<u8>, day: Vec<u8> },
    Mapped(memmap2::Mmap),
}

struct Grid {
    storage: GridStorage,
    count: usize,
}

impl Grid {
    fn owned(land: Vec<u8>, night: Vec<u8>, day: Vec<u8>) -> Self {
        Self { count: land.len(), storage: GridStorage::Owned { land, night, day } }
    }

    fn table(&self, index: usize) -> &[u8] {
        match &self.storage {
            GridStorage::Owned { land, night, day } => match index { 0 => land, 1 => night, _ => day },
            GridStorage::Mapped(bytes) => &bytes[TERRAIN_HEADER + index * self.count..TERRAIN_HEADER + (index + 1) * self.count],
        }
    }

    fn land(&self) -> &[u8] { self.table(0) }
    fn night(&self) -> &[u8] { self.table(1) }
    fn day(&self) -> &[u8] { self.table(2) }
}

const TERRAIN_MAGIC: &[u8; 8] = b"DSTERR01";
const TERRAIN_VERSION: u32 = 1;
const TERRAIN_HEADER: usize = 72;
include!(concat!(env!("OUT_DIR"), "/terrain_source.rs"));

fn terrain_checksum(bytes: &[u8]) -> u64 {
    let mut hash = 0xcbf2_9ce4_8422_2325_u64;
    let mut i = 0;
    while i < bytes.len() {
        hash = (hash ^ bytes[i] as u64).wrapping_mul(0x100_0000_01b3);
        i += 1;
    }
    hash
}

fn save_terrain(path: &std::path::Path, terrain: &Terrain) -> std::io::Result<()> {
    use std::io::Write;
    let mut header = Vec::with_capacity(TERRAIN_HEADER);
    header.extend_from_slice(TERRAIN_MAGIC);
    header.extend_from_slice(&TERRAIN_VERSION.to_le_bytes());
    header.extend_from_slice(&(terrain.width as u32).to_le_bytes());
    header.extend_from_slice(&(terrain.height as u32).to_le_bytes());
    header.extend_from_slice(&0_u32.to_le_bytes());
    header.extend_from_slice(&terrain.north.to_le_bytes());
    header.extend_from_slice(&terrain.south.to_le_bytes());
    header.extend_from_slice(&(RELIEF_LENGTH).to_le_bytes());
    header.extend_from_slice(&RELIEF_CHECKSUM.to_le_bytes());
    let mut hash = 0xcbf2_9ce4_8422_2325_u64;
    for table in [terrain.cells.land(), terrain.cells.night(), terrain.cells.day()] {
        for &byte in table { hash = (hash ^ u64::from(byte)).wrapping_mul(0x100_0000_01b3); }
    }
    header.extend_from_slice(&hash.to_le_bytes());
    header.extend_from_slice(&0_u64.to_le_bytes());
    let temporary = path.with_extension(format!("{}.tmp", uuid::Uuid::new_v4()));
    let result = (|| {
        let mut file = std::fs::OpenOptions::new().write(true).create_new(true).open(&temporary)?;
        file.write_all(&header)?;
        for table in [terrain.cells.land(), terrain.cells.night(), terrain.cells.day()] { file.write_all(table)?; }
        file.sync_all()?;
        std::fs::rename(&temporary, path)
    })();
    if result.is_err() { let _ = std::fs::remove_file(temporary); }
    result
}

fn mapped_terrain(path: &std::path::Path, width: usize, height: usize, north: f64, south: f64) -> Option<Terrain> {
    let file = std::fs::File::open(path).ok()?;
    // SAFETY: 缓存通过改名原子替换，不改动已经映射的文件。
    let bytes = unsafe { memmap2::Mmap::map(&file) }.ok()?;
    let count = width.checked_mul(height)?;
    if bytes.len() != TERRAIN_HEADER.checked_add(count.checked_mul(3)?)? { return None; }
    let u32_at = |start| u32::from_le_bytes(bytes[start..start + 4].try_into().unwrap());
    let u64_at = |start| u64::from_le_bytes(bytes[start..start + 8].try_into().unwrap());
    if &bytes[..8] != TERRAIN_MAGIC || u32_at(8) != TERRAIN_VERSION || u32_at(12) as usize != width || u32_at(16) as usize != height
        || u32_at(20) != 0 || u64_at(24) != north.to_bits() || u64_at(32) != south.to_bits()
        || u64_at(40) != RELIEF_LENGTH || u64_at(48) != RELIEF_CHECKSUM || u64_at(56) != terrain_checksum(&bytes[TERRAIN_HEADER..]) || u64_at(64) != 0 {
        return None;
    }
    Some(Terrain { width, height, north, south, cells: Arc::new(Grid { storage: GridStorage::Mapped(bytes), count }) })
}

/// 乘数的定点刻度：乘数 × 250 存进一个字节（地形乘数都在 0.66…1.02 之间）。
const GAIN: f32 = 250.0;
/// 按尺寸缓存的画布地形最多几份（面板、地球窗、帮助页头图同时开着也够）。
const GRIDS: usize = 3;

type GridKey = (usize, usize, u64, u64);

#[derive(Default)]
struct ReliefState {
    terrain: Option<Arc<Terrain>>,
    /// 最近用过的在最后。
    grids: Vec<(GridKey, Arc<Grid>)>,
}

fn state() -> &'static Mutex<ReliefState> {
    static STATE: OnceLock<Mutex<ReliefState>> = OnceLock::new();
    STATE.get_or_init(|| Mutex::new(ReliefState::default()))
}

fn set_terrain(terrain: Option<Terrain>) {
    let mut state = state().lock().unwrap_or_else(|e| e.into_inner());
    state.terrain = terrain.map(Arc::new);
    state.grids.clear();
}

/// 把第 `y` 行加进（或移出）纵向窗口的逐列和。`sums[q][x]` / `counts[q][x]`：第 x 列窗口里 q 类地面（0 海、1 陆）的灰度和与像素数。
fn slide_row(
    gray: &[u8],
    land: &[bool],
    width: usize,
    y: usize,
    add: bool,
    sums: &mut [Vec<u32>; 2],
    counts: &mut [Vec<u32>; 2],
) {
    let row = y * width;
    for x in 0..width {
        let q = usize::from(land[row + x]);
        let g = u32::from(gray[row + x]);
        if add {
            sums[q][x] += g;
            counts[q][x] += 1;
        } else {
            sums[q][x] -= g;
            counts[q][x] -= 1;
        }
    }
}

/// 夜里用整幅明暗（高原亮、平原暗；深海暗、浅海亮），白天只留山脊山谷的局部明暗：局部 = 与周围同类地面的均值之差
/// （陆和陆比、海和海比，海岸不会因为海陆落差冒出一圈假地形）。均值用滑动的方窗（半径 = 宽 / 180，约 2°），
/// 纵向窗口的逐列和 + 横向滑动：时间与像素数成正比，额外内存只有四行。
fn terrain(gray: &[u8], width: usize, height: usize, north: f64, south: f64) -> Terrain {
    let n = width * height;
    let land: Vec<bool> = gray.iter().map(|&g| g >= 125).collect();
    let radius = (width / 180).max(2);
    let mut sums = [vec![0_u32; width], vec![0_u32; width]];
    let mut counts = [vec![0_u32; width], vec![0_u32; width]];
    for y in 0..=radius.min(height - 1) {
        slide_row(gray, &land, width, y, true, &mut sums, &mut counts);
    }
    let (mut night, mut day) = (vec![0_u8; n], vec![0_u8; n]);
    let fixed = |v: f64| (v * f64::from(GAIN)).round().clamp(0.0, 255.0) as u8;
    for y in 0..height {
        let (mut s, mut c) = ([0_u32; 2], [0_u32; 2]);
        for x in 0..=radius.min(width - 1) {
            for q in 0..2 {
                s[q] += sums[q][x];
                c[q] += counts[q][x];
            }
        }
        for x in 0..width {
            let i = y * width + x;
            let q = usize::from(land[i]);
            let g = f64::from(gray[i]);
            let detail = g - f64::from(s[q]) / f64::from(c[q].max(1));
            if land[i] {
                let t = ((g - 140.0) / 80.0).clamp(0.0, 1.0);
                night[i] = fixed(0.66 + 0.34 * t);
                day[i] = fixed((0.965 + detail * 0.0055 + (t - 0.35) * 0.03).clamp(0.84, 1.0));
            } else {
                let t = ((g - 75.0) / 40.0).clamp(0.0, 1.0);
                night[i] = fixed(0.72 + 0.28 * t);
                day[i] = fixed((0.975 + detail * 0.003 + (t - 0.5) * 0.04).clamp(0.9, 1.02));
            }
            if x + radius + 1 < width {
                for q in 0..2 {
                    s[q] += sums[q][x + radius + 1];
                    c[q] += counts[q][x + radius + 1];
                }
            }
            if x >= radius {
                for q in 0..2 {
                    s[q] -= sums[q][x - radius];
                    c[q] -= counts[q][x - radius];
                }
            }
        }
        if y + radius + 1 < height {
            slide_row(
                gray,
                &land,
                width,
                y + radius + 1,
                true,
                &mut sums,
                &mut counts,
            );
        }
        if y >= radius {
            slide_row(
                gray,
                &land,
                width,
                y - radius,
                false,
                &mut sums,
                &mut counts,
            );
        }
    }
    let cells = Grid::owned(land.iter().map(|&l| if l { 255 } else { 0 }).collect(), night, day);
    Terrain { width, height, north, south, cells: Arc::new(cells) }
}

/// 画布一行（一列）覆盖地形图上的哪几行（列）：[起, 止)。缩小时是几个像素，放大时是最近的一个。
fn spans(count: usize, source: usize, from: impl Fn(f64) -> f64) -> Vec<(usize, usize)> {
    (0..count)
        .map(|k| {
            let a = from(k as f64 / count as f64);
            let b = from((k + 1) as f64 / count as f64);
            let start = (a.min(b).floor().max(0.0) as usize).min(source - 1);
            let end = (a.max(b).ceil().max(0.0) as usize).clamp(start + 1, source);
            (start, end)
        })
        .collect()
}

fn grid(width: usize, height: usize, north: f64, south: f64) -> Option<Arc<Grid>> {
    let key = (width, height, north.to_bits(), south.to_bits());
    let terrain = {
        let mut state = state().lock().unwrap_or_else(|e| e.into_inner());
        if let Some(k) = state.grids.iter().position(|(k, _)| *k == key) {
            let entry = state.grids.remove(k);
            let found = entry.1.clone();
            state.grids.push(entry);
            return Some(found);
        }
        state.terrain.clone()?
    };
    if width == terrain.width
        && height == terrain.height
        && north == terrain.north
        && south == terrain.south
    {
        return Some(terrain.cells.clone());
    }
    let t = &terrain;
    let cells = &t.cells;
    let columns = spans(width, t.width, |f| f * t.width as f64);
    // 行按纬度对应：画布的纬度范围可以是地形图覆盖范围里的任意一段（帮助页头图 66°N…46°S）。
    let rows = spans(height, t.height, |f| {
        (t.north - (north - f * (north - south))) / (t.north - t.south) * t.height as f64
    });
    let n = width * height;
    let (mut land, mut night, mut day) = (vec![0_u8; n], vec![0_u8; n], vec![0_u8; n]);
    for (y, &(y0, y1)) in rows.iter().enumerate() {
        for (x, &(x0, x1)) in columns.iter().enumerate() {
            let (mut l, mut ni, mut d) = (0_u32, 0_u32, 0_u32);
            for sy in y0..y1 {
                let row = sy * t.width;
                for sx in x0..x1 {
                    l += u32::from(cells.land()[row + sx]);
                    ni += u32::from(cells.night()[row + sx]);
                    d += u32::from(cells.day()[row + sx]);
                }
            }
            let count = ((y1 - y0) * (x1 - x0)) as u32;
            let i = y * width + x;
            land[i] = ((l + count / 2) / count) as u8;
            night[i] = ((ni + count / 2) / count) as u8;
            day[i] = ((d + count / 2) / count) as u8;
        }
    }
    let built = Arc::new(Grid::owned(land, night, day));
    let mut state = state().lock().unwrap_or_else(|e| e.into_inner());
    if state.grids.len() >= GRIDS {
        state.grids.remove(0);
    }
    state.grids.push((key, built.clone()));
    Some(built)
}

// ---------------------------------------------------------------- 像素排布

/// 一张位图在内存里怎么排：每行多少字节（IOSurface 的行会按对齐补齐），红蓝谁在前（CGImage 用 RGBA，IOSurface 用 BGRA）。
#[derive(Clone, Copy)]
pub(crate) struct Layout {
    pub(crate) stride: usize,
    pub(crate) bgra: bool,
}

impl Layout {
    fn tight(width: usize) -> Self {
        Layout {
            stride: width * 4,
            bgra: false,
        }
    }
    /// 红、绿、蓝在一个像素四个字节里的位置。
    fn channels(self) -> [usize; 3] {
        if self.bgra {
            [2, 1, 0]
        } else {
            [0, 1, 2]
        }
    }
}

// ---------------------------------------------------------------- 画在位图里的记号

/// 晨昏线与太阳光晕的大小要按「点」算：`ppp` 是每点几个像素，`large` 是大图（地球窗、海报：太阳大一号）。
#[derive(Clone, Copy)]
pub(crate) struct Marks {
    pub(crate) ppp: f64,
    pub(crate) large: bool,
}

/// 覆盖率草稿（每像素一个字节）：一条折线先把各段的覆盖率取最大值，再一次性混进位图，相邻两段接头处不会叠出深一点的点。
/// 与地形同寿命（地形放掉时一起放）。
fn scratch() -> &'static Mutex<Vec<u8>> {
    static SCRATCH: OnceLock<Mutex<Vec<u8>>> = OnceLock::new();
    SCRATCH.get_or_init(|| Mutex::new(Vec::new()))
}

/// 每帧都要的几列数（每一列的时角余弦与升落、折线每行碰到的范围）：复用，不每帧分配（拖动时每秒几十帧，
/// 每帧几十 KB 的小块频繁分配后可能留在分配器里）。与地形同寿命。
#[derive(Default)]
struct Columns {
    cos_h: Vec<f64>,
    up: Vec<usize>,
    spans: Vec<(usize, usize)>,
}

fn columns() -> &'static Mutex<Columns> {
    static COLUMNS: OnceLock<Mutex<Columns>> = OnceLock::new();
    COLUMNS.get_or_init(|| Mutex::new(Columns::default()))
}

/// 一条抗锯齿的粗折线（像素坐标），半宽 `half`、不透明度 `alpha`，贴着左右图边 `fade` 像素以内淡出，按 source-over 混进位图。
#[allow(clippy::too_many_arguments)]
fn draw_polyline(
    out: &mut [u8],
    layout: Layout,
    width: usize,
    height: usize,
    points: &[(f64, f64)],
    half: f64,
    color: [u8; 3],
    alpha: f64,
    fade: f64,
) {
    if points.len() < 2 || alpha <= 0.0 {
        return;
    }
    let reach = half + 1.0;
    let (mut x0, mut y0, mut x1, mut y1) = (f64::MAX, f64::MAX, f64::MIN, f64::MIN);
    for &(x, y) in points {
        x0 = x0.min(x - reach);
        y0 = y0.min(y - reach);
        x1 = x1.max(x + reach);
        y1 = y1.max(y + reach);
    }
    let (bx0, by0) = (x0.floor().max(0.0) as usize, y0.floor().max(0.0) as usize);
    let (bx1, by1) = (
        (x1.ceil().max(0.0) as usize).min(width),
        (y1.ceil().max(0.0) as usize).min(height),
    );
    if bx1 <= bx0 || by1 <= by0 {
        return;
    }
    let bw = bx1 - bx0;
    let mut coverage = scratch().lock().unwrap_or_else(|e| e.into_inner());
    coverage.clear();
    coverage.resize(bw * (by1 - by0), 0);
    // 每行真正碰到的横向范围：混色时只扫这一段，不扫整个外接矩形。
    let mut reuse = columns().lock().unwrap_or_else(|e| e.into_inner());
    let spans = &mut reuse.spans;
    spans.clear();
    spans.resize(by1 - by0, (usize::MAX, 0_usize));
    for pair in points.windows(2) {
        let (p, q) = (pair[0], pair[1]);
        let (dx, dy) = (q.0 - p.0, q.1 - p.1);
        let length2 = (dx * dx + dy * dy).max(1e-12);
        let (sx0, sx1) = (
            (p.0.min(q.0) - reach).floor().max(bx0 as f64) as usize,
            ((p.0.max(q.0) + reach).ceil().max(0.0) as usize).min(bx1),
        );
        let (sy0, sy1) = (
            (p.1.min(q.1) - reach).floor().max(by0 as f64) as usize,
            ((p.1.max(q.1) + reach).ceil().max(0.0) as usize).min(by1),
        );
        for y in sy0..sy1 {
            let cy = y as f64 + 0.5;
            let span = &mut spans[y - by0];
            span.0 = span.0.min(sx0);
            span.1 = span.1.max(sx1);
            for x in sx0..sx1 {
                let cx = x as f64 + 0.5;
                let t = (((cx - p.0) * dx + (cy - p.1) * dy) / length2).clamp(0.0, 1.0);
                let (ex, ey) = (cx - (p.0 + t * dx), cy - (p.1 + t * dy));
                let c = (half + 0.5 - (ex * ex + ey * ey).sqrt()).clamp(0.0, 1.0);
                if c > 0.0 {
                    let cell = &mut coverage[(y - by0) * bw + (x - bx0)];
                    *cell = (*cell).max((c * 255.0) as u8);
                }
            }
        }
    }
    let channels = layout.channels();
    for y in by0..by1 {
        let (sx0, sx1) = spans[y - by0];
        for x in sx0..sx1.max(sx0) {
            let c = coverage[(y - by0) * bw + (x - bx0)];
            if c == 0 {
                continue;
            }
            let edge = ((x as f64 + 0.5).min(width as f64 - x as f64 - 0.5) / fade).clamp(0.0, 1.0);
            let a = alpha * f64::from(c) / 255.0 * edge;
            let o = y * layout.stride + x * 4;
            for (j, &ch) in channels.iter().enumerate() {
                out[o + ch] =
                    (f64::from(out[o + ch]) * (1.0 - a) + f64::from(color[j]) * a).round() as u8;
            }
        }
    }
}

/// 晨昏线（一道宽而淡的光晕 14% + 一条细线 55%，破晓玫瑰、黄昏琥珀，贴着左右图边 5% 以内淡出）与太阳的光晕
/// （金色 38% 从半个日盘处往外淡到 30 / 16 点）。线宽按图宽算：360 点宽时光晕 4 点、细线 0.45 点（不细于 0.5 点）。
#[allow(clippy::too_many_arguments)]
fn draw_marks(
    out: &mut [u8],
    layout: Layout,
    width: usize,
    height: usize,
    north: f64,
    south: f64,
    instant: f64,
    marks: Marks,
) {
    let project = |(lon, lat): (f64, f64)| {
        (
            (lon + 180.0) / 360.0 * width as f64,
            (north - lat) / (north - south) * height as f64,
        )
    };
    let (glow, line) = (
        4.0 * width as f64 / 360.0,
        (0.45 * width as f64 / 360.0).max(0.5 * marks.ppp),
    );
    let fade = width as f64 * 0.05;
    let lines: Vec<(bool, Vec<(f64, f64)>)> = worldmap::terminator_lines(instant)
        .into_iter()
        .map(|(dawn, points)| (dawn, points.into_iter().map(project).collect()))
        .collect();
    for (half, alpha) in [(glow / 2.0, 0.14), (line / 2.0, 0.55)] {
        for (dawn, points) in &lines {
            draw_polyline(
                out,
                layout,
                width,
                height,
                points,
                half,
                srgb8(if *dawn { DAWN } else { DUSK }),
                alpha,
                fade,
            );
        }
    }
    // 太阳的光晕（日盘本身与细圈由宿主画成矢量）。
    let (lat, lon) = worldmap::subsolar_point(instant);
    let (sx, sy) = project((lon, lat));
    let (disc, reach) = if marks.large {
        (8.0, 30.0)
    } else {
        (4.5, 16.0)
    };
    let (inner, outer) = (disc * 0.6 * marks.ppp, reach * marks.ppp);
    let color = srgb8(SUN_GLOW);
    let channels = layout.channels();
    let (x0, x1) = (
        (sx - outer).floor().max(0.0) as usize,
        ((sx + outer).ceil().max(0.0) as usize).min(width),
    );
    let (y0, y1) = (
        (sy - outer).floor().max(0.0) as usize,
        ((sy + outer).ceil().max(0.0) as usize).min(height),
    );
    for y in y0..y1 {
        for x in x0..x1 {
            let d = ((x as f64 + 0.5 - sx).powi(2) + (y as f64 + 0.5 - sy).powi(2)).sqrt();
            if d >= outer {
                continue;
            }
            let a = 0.38 * (1.0 - ((d - inner) / (outer - inner)).clamp(0.0, 1.0));
            let o = y * layout.stride + x * 4;
            for (j, &ch) in channels.iter().enumerate() {
                out[o + ch] =
                    (f64::from(out[o + ch]) * (1.0 - a) + f64::from(color[j]) * a).round() as u8;
            }
        }
    }
}

// ---------------------------------------------------------------- 城市灯火

const LIGHT_STEPS: usize = 64;

/// 一盏灯的中心近白的暖金、往外是琥珀，四倍半径处全暗。
/// 表里是预乘过不透明度的 sRGB 8 位值（与画布渐变一样在编码值上插值），按「到中心的距离 ÷ 外径」查；叠加是相加（亮上加亮）。
fn light_profile() -> &'static [[f32; 3]] {
    static PROFILE: OnceLock<Vec<[f32; 3]>> = OnceLock::new();
    PROFILE.get_or_init(|| {
        let stops: [(f64, Lch, f64); 4] = [
            (0.0, lch(0.97, 0.05, 85.0), 1.0),
            (0.22, lch(0.86, 0.11, 72.0), 0.55),
            (0.55, lch(0.72, 0.12, 60.0), 0.14),
            (1.0, lch(0.6, 0.1, 55.0), 0.0),
        ];
        let premultiplied = |c: Lch, a: f64| srgb8(c).map(|v| f64::from(v) * a);
        (0..=LIGHT_STEPS)
            .map(|i| {
                let d = i as f64 / LIGHT_STEPS as f64;
                let k = (0..stops.len() - 1)
                    .find(|&k| d <= stops[k + 1].0)
                    .unwrap_or(stops.len() - 2);
                let (a, b) = (stops[k], stops[k + 1]);
                let t = ((d - a.0) / (b.0 - a.0)).clamp(0.0, 1.0);
                let (pa, pb) = (premultiplied(a.1, a.2), premultiplied(b.1, b.2));
                [0, 1, 2].map(|j| (pa[j] + (pb[j] - pa[j]) * t) as f32)
            })
            .collect()
    })
}

/// 夜半球上人口够多的城市亮一盏灯（`lights.rs` 的 392 座）：太阳落到地平线下就开始亮，−6°（民用曙暮光结束）全亮；
/// 三档人口三种大小。半径按图宽走（720 像素宽时最小一档 0.75 像素、光晕 3 像素），`scale` 是宿主给的倍数，0 不画。
#[allow(clippy::too_many_arguments)]
fn add_lights(
    out: &mut [u8],
    layout: Layout,
    width: usize,
    height: usize,
    north: f64,
    south: f64,
    scale: f64,
    sin_d: f64,
    cos_d: f64,
    sun_longitude: f64,
) {
    let profile = light_profile();
    let channels = layout.channels();
    let unit = width as f64 / 720.0 * scale;
    for (lon, lat, tier) in crate::lights::points() {
        if lat > north || lat < south {
            continue;
        }
        let (sl, cl) = lat.to_radians().sin_cos();
        let altitude = (sl * sin_d + cl * cos_d * (lon - sun_longitude).to_radians().cos())
            .clamp(-1.0, 1.0)
            .asin()
            .to_degrees();
        let k = ((HORIZON - altitude) / (6.0 + HORIZON)).clamp(0.0, 1.0) as f32;
        if k <= 0.0 {
            continue;
        }
        let outer = 4.0
            * unit
            * match tier {
                3 => 1.35,
                2 => 1.0,
                _ => 0.75,
            };
        let cx = (lon + 180.0) / 360.0 * width as f64;
        let cy = (north - lat) / (north - south) * height as f64;
        let (x0, x1) = (
            (cx - outer).floor().max(0.0) as usize,
            ((cx + outer).ceil().max(0.0) as usize).min(width),
        );
        let (y0, y1) = (
            (cy - outer).floor().max(0.0) as usize,
            ((cy + outer).ceil().max(0.0) as usize).min(height),
        );
        for y in y0..y1 {
            let dy = y as f64 + 0.5 - cy;
            for x in x0..x1 {
                let dx = x as f64 + 0.5 - cx;
                let d = (dx * dx + dy * dy).sqrt() / outer;
                if d >= 1.0 {
                    continue;
                }
                let glow = profile[(d * LIGHT_STEPS as f64).round() as usize];
                let o = y * layout.stride + x * 4;
                for (j, &c) in channels.iter().enumerate() {
                    out[o + c] = (f32::from(out[o + c]) + glow[j] * k).min(255.0) as u8;
                }
            }
        }
    }
}

// ---------------------------------------------------------------- 出图

/// 太阳高度的正弦（−1…1）分成这么多档：逐像素不做反正弦，按正弦查「颜色表第几档 + 白天的程度」。
/// 地平线附近一档约 0.007°（颜色表本身 1/4 度一档），头顶附近一档最粗约 0.9°（那里的颜色本来就不变）。
const SINE_STEPS: usize = 16_384;

/// 正弦 → （颜色表里 1/4 度那一档，白天的程度 0…256：太阳在 −6° 以下 0，0° 以上 256）。
fn sine_table() -> &'static [(u16, u16)] {
    static TABLE: OnceLock<Vec<(u16, u16)>> = OnceLock::new();
    TABLE.get_or_init(|| {
        (0..SINE_STEPS)
            .map(|k| {
                let sine = (k as f64 + 0.5) / SINE_STEPS as f64 * 2.0 - 1.0;
                let altitude = sine.asin().to_degrees();
                let step = ((altitude + 90.0) * 4.0)
                    .round()
                    .clamp(0.0, (STEPS - 1) as f64) as u16;
                let dayness = (((altitude + 6.0) / 6.0).clamp(0.0, 1.0) * 256.0).round() as u16;
                (step, dayness)
            })
            .collect()
    })
}

/// 画一张 `width` × `height` 的地图（RGBA8，不透明）。没有地形时整张按陆地的底色画。
/// `lights` 是城市灯火的大小倍数（面板 1、地球窗 1.15、海报 1.1），0 不画。
/// 逐像素只做一次乘加、两次查表与几次整数乘移位（太阳高度按正弦查表，不做反正弦；地形乘数是定点数）。
#[cfg(test)]
pub(crate) fn raster(
    instant: f64,
    width: usize,
    height: usize,
    north: f64,
    south: f64,
    lights: f64,
    out: &mut [u8],
) -> bool {
    raster_into(
        instant,
        width,
        height,
        north,
        south,
        lights,
        out,
        Layout::tight(width),
        None,
    )
}

/// 同 `raster`，按 `layout` 的行跨度与通道顺序写（IOSurface）；`marks` 给了就把晨昏线与太阳光晕也画进去。
#[allow(clippy::too_many_arguments)]
pub(crate) fn raster_into(
    instant: f64,
    width: usize,
    height: usize,
    north: f64,
    south: f64,
    lights: f64,
    out: &mut [u8],
    layout: Layout,
    marks: Option<Marks>,
) -> bool {
    if width == 0
        || height == 0
        || width > 8192
        || height > 8192
        || layout.stride < width * 4
        || out.len() < layout.stride * (height - 1) + width * 4
    {
        return false;
    }
    if !astronomy::SUPPORTED_UNIX.contains(&instant)
        || !north.is_finite()
        || !south.is_finite()
        || north <= south
        || !lights.is_finite()
    {
        return false;
    }
    let (declination, sun_longitude) = worldmap::subsolar_point(instant);
    let (sin_d, cos_d) = declination.to_radians().sin_cos();
    let colors = table();
    let sines = sine_table();
    let terrain = grid(width, height, north, south);
    let mut reuse = columns().lock().unwrap_or_else(|e| e.into_inner());
    let (mut cos_h, mut up) = (
        std::mem::take(&mut reuse.cos_h),
        std::mem::take(&mut reuse.up),
    );
    drop(reuse);
    cos_h.clear();
    cos_h.resize(width, 0.0);
    up.clear();
    up.resize(width, 0);
    for (x, (c, r)) in cos_h.iter_mut().zip(up.iter_mut()).enumerate() {
        let lon = -180.0 + (x as f64 + 0.5) / width as f64 * 360.0;
        *c = (lon - sun_longitude).to_radians().cos();
        *r = usize::from(wrap(lon - sun_longitude) < 0.0);
    }
    let scale = (SINE_STEPS as f64) / 2.0;
    // 乘地形乘数（定点 × 250 → 除 250 ≈ × 262 >> 16）。
    let shade = |c: u8, gain: u32| ((u32::from(c) * gain * 262) >> 16).min(255) as u8;
    let [cr, cg, cb] = layout.channels();
    let pixel = |r: u8, g: u8, b: u8| {
        let mut p = [255_u8; 4];
        p[cr] = r;
        p[cg] = g;
        p[cb] = b;
        p
    };
    for y in 0..height {
        let pixels = &mut out[y * layout.stride..y * layout.stride + width * 4];
        let lat = (north - (y as f64 + 0.5) / height as f64 * (north - south)).to_radians();
        let (a, b) = (lat.sin() * sin_d, lat.cos() * cos_d);
        // 这一行里每个像素的（颜色表下标的底，白天的程度）。
        let lookup = |c: f64, r: usize| {
            let k = (((a + b * c) + 1.0) * scale) as usize;
            let (step, dayness) = sines[k.min(SINE_STEPS - 1)];
            ((usize::from(step) * 2 + r) * 2, u32::from(dayness))
        };
        match &terrain {
            Some(t) => {
                let row = y * width..(y + 1) * width;
                let cells = t.land()[row.clone()].iter().zip(&t.night()[row.clone()]).zip(&t.day()[row]);
                for (((px, &c), &r), ((&cover, &night), &day)) in pixels.chunks_exact_mut(4).zip(&cos_h).zip(&up).zip(cells) {
                    let (base, dayness) = lookup(c, r);
                    let gain = (u32::from(night) * (256 - dayness) + u32::from(day) * dayness) >> 8;
                    let rgb = match cover {
                        255 => colors[base + 1],
                        0 => colors[base],
                        _ => {
                            // 海岸：按这个像素里陆地的比例混两种底色。
                            let (land, sea, f) = (colors[base + 1], colors[base], u32::from(cover));
                            [0, 1, 2].map(|j| {
                                ((u32::from(sea[j]) * (255 - f) + u32::from(land[j]) * f) / 255)
                                    as u8
                            })
                        }
                    };
                    px.copy_from_slice(&pixel(
                        shade(rgb[0], gain),
                        shade(rgb[1], gain),
                        shade(rgb[2], gain),
                    ));
                }
            }
            None => {
                for ((px, &c), &r) in pixels.chunks_exact_mut(4).zip(&cos_h).zip(&up) {
                    let (base, _) = lookup(c, r);
                    let rgb = colors[base + 1];
                    px.copy_from_slice(&pixel(rgb[0], rgb[1], rgb[2]));
                }
            }
        }
    }
    {
        let mut reuse = columns().lock().unwrap_or_else(|e| e.into_inner());
        reuse.cos_h = cos_h;
        reuse.up = up;
    }
    if let Some(marks) = marks.filter(|m| m.ppp.is_finite() && m.ppp > 0.0) {
        draw_marks(out, layout, width, height, north, south, instant, marks);
    }
    if lights > 0.0 {
        add_lights(
            out,
            layout,
            width,
            height,
            north,
            south,
            lights,
            sin_d,
            cos_d,
            sun_longitude,
        );
    }
    true
}

/// 地图上一块地方（像素坐标 [x0, x1) × [y0, y1)）的平均相对亮度（WCAG）：在这块里均匀取 12 × 6 个点，
/// 按与出图相同的颜色（天色、海陆、地形，不含灯火）算。地图上的字选墨还是纸就问它，不必读回位图。
#[allow(clippy::too_many_arguments)]
pub(crate) fn map_luminance(
    instant: f64,
    width: usize,
    height: usize,
    north: f64,
    south: f64,
    x0: f64,
    y0: f64,
    x1: f64,
    y1: f64,
) -> Option<f64> {
    let finite = [x0, y0, x1, y1, north, south].iter().all(|v| v.is_finite());
    if width == 0
        || height == 0
        || !finite
        || x1 <= x0
        || y1 <= y0
        || !astronomy::SUPPORTED_UNIX.contains(&instant)
        || north <= south
    {
        return None;
    }
    let (declination, sun_longitude) = worldmap::subsolar_point(instant);
    let (sin_d, cos_d) = declination.to_radians().sin_cos();
    let colors = table();
    let sines = sine_table();
    let terrain = grid(width, height, north, south);
    let (nx, ny) = (12, 6);
    let mut total = 0.0;
    for j in 0..ny {
        for i in 0..nx {
            let px = (x0 + (i as f64 + 0.5) / nx as f64 * (x1 - x0)).clamp(0.0, width as f64 - 1.0);
            let py =
                (y0 + (j as f64 + 0.5) / ny as f64 * (y1 - y0)).clamp(0.0, height as f64 - 1.0);
            let lon = -180.0 + (px.floor() + 0.5) / width as f64 * 360.0;
            let lat = (north - (py.floor() + 0.5) / height as f64 * (north - south)).to_radians();
            let sine =
                lat.sin() * sin_d + lat.cos() * cos_d * (lon - sun_longitude).to_radians().cos();
            let k = ((sine + 1.0) * SINE_STEPS as f64 / 2.0) as usize;
            let (step, dayness) = sines[k.min(SINE_STEPS - 1)];
            let base = (usize::from(step) * 2 + usize::from(wrap(lon - sun_longitude) < 0.0)) * 2;
            let index = py as usize * width + px as usize;
            let (land, gain) = match &terrain {
                Some(t) => {
                    let (night, day, d) = (f64::from(t.night()[index]), f64::from(t.day()[index]), f64::from(dayness) / 256.0);
                    (t.land()[index] >= 128, (night + (day - night) * d) / f64::from(GAIN))
                }
                None => (true, 1.0),
            };
            let rgb = colors[base + usize::from(land)];
            let linear = |c: u8| {
                let v = (f64::from(c) / 255.0 * gain).min(1.0);
                if v <= 0.04045 {
                    v / 12.92
                } else {
                    ((v + 0.055) / 1.055).powf(2.4)
                }
            };
            total += 0.2126 * linear(rgb[0]) + 0.7152 * linear(rgb[1]) + 0.0722 * linear(rgb[2]);
        }
    }
    Some(total / (nx * ny) as f64)
}

/// # Safety
/// `gray` must point to `width * height` readable bytes for the duration of the call.
#[no_mangle]
pub unsafe extern "C" fn mt_sky_relief_set(
    gray: *const u8,
    width: u32,
    height: u32,
    north: f64,
    south: f64,
) -> bool {
    let (w, h) = (width as usize, height as usize);
    if gray.is_null()
        || w == 0
        || h == 0
        || w > 16_384
        || h > 16_384
        || !north.is_finite()
        || !south.is_finite()
        || north <= south
        || north > 90.0
        || south < -90.0
    {
        return false;
    }
    // SAFETY: the host guarantees `width * height` readable bytes.
    let bytes = unsafe { std::slice::from_raw_parts(gray, w * h) };
    match std::panic::catch_unwind(|| terrain(bytes, w, h, north, south)) {
        Ok(built) => {
            set_terrain(Some(built));
            true
        }
        Err(_) => false,
    }
}

/// # Safety
/// `path` must be a readable null-terminated UTF-8 path for the duration of the call.
#[no_mangle]
pub unsafe extern "C" fn mt_sky_terrain_save(path: *const std::ffi::c_char) -> bool {
    if path.is_null() { return false; }
    // SAFETY: 宿主保证路径以零结尾。
    let Ok(path) = unsafe { std::ffi::CStr::from_ptr(path) }.to_str() else { return false; };
    let terrain = state().lock().unwrap_or_else(|e| e.into_inner()).terrain.clone();
    terrain.is_some_and(|terrain| save_terrain(std::path::Path::new(path), &terrain).is_ok())
}

/// # Safety
/// `path` must be a readable null-terminated UTF-8 path for the duration of the call.
#[no_mangle]
pub unsafe extern "C" fn mt_sky_terrain_map(path: *const std::ffi::c_char) -> bool {
    if path.is_null() { return false; }
    // SAFETY: 宿主保证路径以零结尾。
    let Ok(path) = unsafe { std::ffi::CStr::from_ptr(path) }.to_str() else { return false; };
    let Some(terrain) = mapped_terrain(std::path::Path::new(path), 1800, 690, 80.0, -58.0) else { return false; };
    set_terrain(Some(terrain));
    true
}

/// 面板与地球窗都关了：放掉地形与按尺寸算好的画布地形（空闲时不占内存）。
#[no_mangle]
pub extern "C" fn mt_sky_relief_release() {
    set_terrain(None);
    *scratch().lock().unwrap_or_else(|e| e.into_inner()) = Vec::new();
    *columns().lock().unwrap_or_else(|e| e.into_inner()) = Columns::default();
}

/// 画进宿主的 IOSurface：每行 `stride` 字节、`bgra` 时按 BGRA 排（屏幕上的地图直接显示这块像素面，不经 CGImage）。
///
/// # Safety
/// `out` must point to `stride * height` writable bytes for the duration of the call.
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn mt_sky_map_raster_into(
    instant: f64,
    width: u32,
    height: u32,
    north: f64,
    south: f64,
    lights: f64,
    out: *mut u8,
    stride: usize,
    bgra: bool,
    ppp: f64,
    large: bool,
) -> bool {
    if out.is_null() || height == 0 {
        return false;
    }
    // SAFETY: the host guarantees `stride * height` writable bytes.
    let buffer = unsafe { std::slice::from_raw_parts_mut(out, stride * height as usize) };
    let layout = Layout { stride, bgra };
    let marks = Some(Marks { ppp, large });
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        raster_into(
            instant,
            width as usize,
            height as usize,
            north,
            south,
            lights,
            buffer,
            layout,
            marks,
        )
    }))
    .unwrap_or(false)
}

/// 地图上一块地方（像素坐标）的平均相对亮度；算不出（参数不合理）时 −1。
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub extern "C" fn mt_sky_map_luminance(
    instant: f64,
    width: u32,
    height: u32,
    north: f64,
    south: f64,
    x0: f64,
    y0: f64,
    x1: f64,
    y1: f64,
) -> f64 {
    std::panic::catch_unwind(|| {
        map_luminance(
            instant,
            width as usize,
            height as usize,
            north,
            south,
            x0,
            y0,
            x1,
            y1,
        )
    })
    .ok()
    .flatten()
    .unwrap_or(-1.0)
}

/// # Safety
/// `out` must point to `len` writable bytes for the duration of the call.
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn mt_sky_map_raster(
    instant: f64,
    width: u32,
    height: u32,
    north: f64,
    south: f64,
    lights: f64,
    out: *mut u8,
    len: usize,
    ppp: f64,
    large: bool,
) -> bool {
    if out.is_null() {
        return false;
    }
    // SAFETY: the host guarantees `len` writable bytes.
    let buffer = unsafe { std::slice::from_raw_parts_mut(out, len) };
    let (w, h) = (width as usize, height as usize);
    let marks = Some(Marks { ppp, large });
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        raster_into(
            instant,
            w,
            h,
            north,
            south,
            lights,
            buffer,
            Layout::tight(w),
            marks,
        )
    }))
    .unwrap_or(false)
}

// ---------------------------------------------------------------- 面板

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Place {
    latitude: Option<f64>,
    longitude: Option<f64>,
    /// 此刻那里相对 UTC 的秒数（宿主按那一刻的时区规则算）。
    utc_offset: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PanelInput {
    /// 面板正在看的那一刻（拖过时间就是拖到的那一刻）。
    instant: f64,
    /// 真正的此刻：滑块轨道以它为中心，拖动时轨道不动、圆点动。
    now: f64,
    home: Place,
    places: Vec<Place>,
    /// 小字要的对比度：5.5，系统「提高对比度」时 7。
    #[serde(default = "default_need")]
    need: f64,
    /// 提高对比度时，行底色平涂。
    #[serde(default)]
    flat: bool,
    /// 界面语言（`zh-Hans`、`en`、`pt-BR`…）：一天里的词按它的钟点表（`day_words`），缺省英语。
    #[serde(default = "default_language")]
    language: String,
}

fn default_language() -> String {
    "en".into()
}

fn default_need() -> f64 {
    5.5
}

/// 框的底色对墨 / 纸至少要这么高的对比度（见 `panel` 里的说明）。
const CHROME_NEED: f64 = 8.0;

// 相邻底色的 OKLab 距离低于此值时，加线分开两行。
const DIVIDER_DISTANCE: f64 = 0.06;

fn coordinate(place: &Place) -> Option<(f64, f64)> {
    let (lat, lon) = (place.latitude?, place.longitude?);
    ((-90.0..=90.0).contains(&lat) && (-180.0..=180.0).contains(&lon)).then_some((lat, lon))
}

fn readable_json(r: &Readable) -> Value {
    json!({"top": hex(r.top), "horizon": hex(r.horizon), "mid": hex(r.mid), "ink": r.ink, "ratio": r.ratio})
}

/// 当地这一天（按那里的钟）的日出与日落，分钟；极昼极夜给 None。
fn sun_times(day_start: f64, lat: f64, lon: f64) -> (Option<f64>, Option<f64>) {
    let at = |m: f64| astronomy::elevation(day_start + m * 60.0, lat, lon);
    let (mut rise, mut set) = (None, None);
    let mut previous = at(0.0);
    let mut m = 5.0;
    while m <= 1440.0 {
        let current = at(m);
        if previous < HORIZON && current >= HORIZON && rise.is_none() {
            rise = Some(m);
        }
        if previous >= HORIZON && current < HORIZON && rise.is_some() && set.is_none() {
            set = Some(m);
        }
        previous = current;
        m += 5.0;
    }
    (rise, set)
}

/// 当地这一天（按那里的钟）从几点开始（Unix 秒）。
fn local_day_start(instant: f64, utc_offset: f64) -> f64 {
    ((instant + utc_offset) / 86_400.0).floor() * 86_400.0 - utc_offset
}

/// 太阳弧上太阳的位置：白天在弧上（0 = 日出一端，1 = 日落一端）；夜里在地平线下，从落下的一端往升起的一端走。
fn sun_path(instant: f64, lat: f64, lon: f64, utc_offset: f64) -> Value {
    let day_start = local_day_start(instant, utc_offset);
    let minutes = (instant - day_start) / 60.0;
    let up = astronomy::elevation(instant, lat, lon) >= HORIZON;
    match sun_times(day_start, lat, lon) {
        (Some(rise), Some(set)) if set > rise => {
            if up {
                json!({"up": true, "fraction": ((minutes - rise) / (set - rise)).clamp(0.0, 1.0)})
            } else {
                let night = if minutes > set {
                    (minutes - set) / (rise + 1440.0 - set)
                } else {
                    (minutes - (set - 1440.0)) / (rise - (set - 1440.0))
                };
                json!({"up": false, "fraction": night.clamp(0.0, 1.0)})
            }
        }
        // 极昼、极夜，或当地这一天先落后升：点在正中（上或下）。
        _ => json!({"up": up, "fraction": 0.5}),
    }
}

fn row(instant: f64, place: &Place, need: f64, language: &str, flat: bool) -> (Value, [Lch; 2]) {
    let Some((lat, lon)) = coordinate(place) else {
        // 没有坐标（UTC 这类）：只给中性的纸色与字，不猜天色。
        let plain = readable(
            &Sky {
                top: PAPER,
                horizon: PAPER,
                mid: PAPER,
            },
            need,
        );
        return (
            json!({"known": false, "colors": readable_json(&plain), "gradient": false}),
            [plain.mid; 2],
        );
    };
    let altitude = astronomy::elevation(instant, lat, lon);
    let is_rising = rising(instant, lon);
    let colors = readable(&sky(altitude, is_rising), need);
    let local_minutes = ((instant + place.utc_offset) / 60.0).rem_euclid(1440.0);
    // 当地这一天的日出日落（Unix 秒；面板「显示日出日落」时写在行里，极昼极夜没有）。
    let day_start = local_day_start(instant, place.utc_offset);
    let (rise, set) = sun_times(day_start, lat, lon);
    // 太阳贴近地平线时画渐变；平涂时两端都取整体颜色。
    let gradient = altitude > -10.0 && altitude < 8.0;
    let edges = if gradient && !flat {
        [colors.top, colors.horizon]
    } else {
        [colors.mid; 2]
    };
    (
        json!({
            "known": true,
            "colors": readable_json(&colors),
            // 太阳在地平线附近（−10° … 8°）时画天顶到地平线的渐变，那是一天里颜色最多的时候；其余用一种颜色。
            "gradient": gradient,
            "word": crate::day_words::word(language, local_minutes, altitude, is_rising),
            "altitude": altitude,
            "rising": is_rising,
            "path": sun_path(instant, lat, lon, place.utc_offset),
            "sunrise": rise.map(|m| day_start + m * 60.0),
            "sunset": set.map(|m| day_start + m * 60.0),
        }),
        edges,
    )
}

fn panel(input: &PanelInput) -> Result<Value, String> {
    for t in [input.instant, input.now] {
        if !astronomy::SUPPORTED_UNIX.contains(&t) {
            return Err("Sky panel needs instants from 1800 to 2100".into());
        }
    }
    let need = if input.need.is_finite() {
        input.need.clamp(3.0, 12.0)
    } else {
        5.5
    };
    // 框：这里此刻的天顶（字同样给墨或纸）；没有坐标时用纸。框里还有系统控件的次要文字（78% 的 labelColor，
    // 实际不透明度约 0.66），底色要推到 8:1，那些字才也过 4.5:1（逐档算过：深底亮度 ≤ 0.07、浅底 ≥ 0.49）。
    let chrome_need = need.max(CHROME_NEED);
    let home = coordinate(&input.home);
    let chrome = match home {
        Some((lat, lon)) => {
            let s = sky(
                astronomy::elevation(input.instant, lat, lon),
                rising(input.instant, lon),
            );
            readable(
                &Sky {
                    top: s.top,
                    horizon: s.top,
                    mid: s.top,
                },
                chrome_need,
            )
        }
        None => readable(
            &Sky {
                top: PAPER,
                horizon: PAPER,
                mid: PAPER,
            },
            chrome_need,
        ),
    };
    let mut rows = Vec::with_capacity(input.places.len());
    let mut dividers = Vec::with_capacity(input.places.len());
    let mut above = display_lab(chrome.top);
    for place in &input.places {
        let (value, [top, bottom]) = row(input.instant, place, need, &input.language, input.flat);
        let (l, a, b) = display_lab(top);
        let distance =
            ((above.0 - l).powi(2) + (above.1 - a).powi(2) + (above.2 - b).powi(2)).sqrt();
        dividers.push(distance < DIVIDER_DISTANCE);
        rows.push(value);
        above = display_lab(bottom);
    }
    // 看的那一刻这里是昼是夜（滑块的圆点画太阳还是月亮）。滑块轨道不在这里算：它与工具窗页首天色带是同一个 `strip`，
    // 宿主只在每分钟与轨道换中心时调（此前轨道 73 个色标跟着这里拖时间时 ~30 Hz 每次重算，2026-10-02 挪走）。
    let day_here = home.map(|(lat, lon)| astronomy::elevation(input.instant, lat, lon) >= HORIZON);
    Ok(json!({
        "rows": rows,
        "dividers": dividers,
        "chrome": readable_json(&chrome),
        "dayHere": day_here,
    }))
}

// ---------------------------------------------------------------- 昼夜条

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LaneInput {
    start: f64,
    end: f64,
    latitude: f64,
    longitude: f64,
    /// 色标间隔（分钟），默认 10。
    #[serde(default)]
    step: Option<f64>,
}

/// 一段时间里这个地方的天：每 `step_minutes` 分钟一个色标（位置 0…1、颜色是那一刻天的「整体」色）。
/// 昼夜条（`lane::day_lane` 的天色版）与滑块轨道同一种颜色。
pub(crate) fn lane_stops(
    start: f64,
    end: f64,
    latitude: f64,
    longitude: f64,
    step_minutes: f64,
) -> Vec<(f64, String)> {
    let step = if step_minutes.is_finite() && step_minutes >= 1.0 {
        step_minutes
    } else {
        10.0
    } * 60.0;
    let span = end - start;
    let count = ((span / step).ceil() as usize).clamp(1, 2_000);
    (0..=count)
        .map(|k| {
            let t = start + span * k as f64 / count as f64;
            let s = sky(
                astronomy::elevation(t, latitude, longitude),
                rising(t, longitude),
            );
            (k as f64 / count as f64, hex(s.mid))
        })
        .collect()
}

/// 一段时间里这个地方的天（每 `step` 分钟一个色标，位置 0…1）。
fn lane(input: &LaneInput) -> Result<Value, String> {
    let fits = |t: f64| astronomy::SUPPORTED_UNIX.contains(&t);
    if !fits(input.start)
        || !fits(input.end)
        || input.end <= input.start
        || input.end - input.start > 8.0 * 86_400.0
    {
        return Err("Sky lane needs a span of up to eight days from 1800 to 2100".into());
    }
    if !(-90.0..=90.0).contains(&input.latitude) || !(-180.0..=180.0).contains(&input.longitude) {
        return Err("Sky lane needs a valid coordinate".into());
    }
    let stops: Vec<Value> = lane_stops(
        input.start,
        input.end,
        input.latitude,
        input.longitude,
        input.step.unwrap_or(10.0),
    )
    .into_iter()
    .map(|(at, color)| json!({"at": at, "color": color}))
    .collect();
    Ok(json!({"stops": stops}))
}

/// 一段时间里写在天上的线该用墨还是纸：与 `lane_stops` 同一批时刻、同一种「整体」颜色，谁对它的对比度高用谁。
/// 太阳一天图的地平线用它：白天那截是墨线、夜里那截是纸线，曙暮里跟着换，整条线在哪段天上都看得见。
pub(crate) fn line_stops(
    start: f64,
    end: f64,
    latitude: f64,
    longitude: f64,
    step_minutes: f64,
) -> Vec<(f64, String)> {
    let step = if step_minutes.is_finite() && step_minutes >= 1.0 {
        step_minutes
    } else {
        10.0
    } * 60.0;
    let span = end - start;
    let count = ((span / step).ceil() as usize).clamp(1, 2_000);
    (0..=count)
        .map(|k| {
            let t = start + span * k as f64 / count as f64;
            let mid = sky(
                astronomy::elevation(t, latitude, longitude),
                rising(t, longitude),
            )
            .mid;
            let ink = contrast(INK, mid) >= contrast(PAPER, mid);
            (k as f64 / count as f64, hex(if ink { INK } else { PAPER }))
        })
        .collect()
}

// ---------------------------------------------------------------- 页首天色带

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct StripInput {
    /// 真正的此刻。
    now: f64,
    /// 正在看的那一刻（拖过时间就是拖到的那一刻）。
    instant: f64,
    latitude: Option<f64>,
    longitude: Option<f64>,
    /// 系统「不使用颜色区分」：另给昼 / 曙暮 / 夜的边界，宿主在带上画刻度。
    #[serde(default)]
    marks: bool,
}

/// 天色带每一边的秒数：与面板滑块同一个量程（前后 12 小时）。
const STRIP_HALF: f64 = 12.0 * 3600.0;

/// 工具窗页首的天色带（十页共用的出身）：这里前后 12 小时的天，与面板滑块轨道同一批色标（每 20 分钟一个，73 个），
/// 外加正在看的那一刻在带上的位置、那一刻这里是昼是夜（标记画太阳还是月亮）。
/// 看的那一刻离此刻超过 12 小时：带改以那一刻为中心（「那一刻前后 12 小时的天」），此刻不在带上（`now` 为空）。
/// 没有本机坐标时不给色标（宿主画中性的底），位置照给。宿主只在打开、每分钟与拖时间时调它，不逐帧。
fn strip(input: &StripInput) -> Result<Value, String> {
    let offset = input.instant - input.now;
    if !offset.is_finite() {
        return Err("Sky strip needs finite instants".into());
    }
    let beyond = offset.abs() > STRIP_HALF;
    let center = if beyond { input.instant } else { input.now };
    let (start, end) = (center - STRIP_HALF, center + STRIP_HALF);
    for t in [input.now, input.instant, start, end] {
        if !astronomy::SUPPORTED_UNIX.contains(&t) {
            return Err("Sky strip needs instants from 1800 to 2100".into());
        }
    }
    let place = match (input.latitude, input.longitude) {
        (Some(lat), Some(lon))
            if (-90.0..=90.0).contains(&lat) && (-180.0..=180.0).contains(&lon) =>
        {
            Some((lat, lon))
        }
        _ => None,
    };
    let stops: Vec<Value> = place
        .map(|(lat, lon)| lane_stops(start, end, lat, lon, 20.0))
        .unwrap_or_default()
        .into_iter()
        .map(|(at, color)| json!({"at": at, "color": color}))
        .collect();
    let marks: Vec<Value> = match place {
        Some((lat, lon)) if input.marks => {
            band_marks(&astronomy::daylight_bands(start, end, lat, lon), start, end)
        }
        _ => Vec::new(),
    };
    Ok(json!({
        "stops": stops,
        "marker": ((input.instant - start) / (end - start)).clamp(0.0, 1.0),
        "now": if beyond { Value::Null } else { json!(0.5) },
        "beyond": beyond,
        "dayHere": place.map(|(lat, lon)| astronomy::elevation(input.instant, lat, lon) >= HORIZON),
        "marks": marks,
    }))
}

/// 「不使用颜色区分」的刻度：昼 / 曙暮 / 夜相邻两段的每个边界一道，位置 0…1；日出日落（昼接曙暮）整条高，
/// 晨光始昏影终（曙暮接夜）半条高。页首天色带与换算页的共同时间轴同一套。
pub(crate) fn band_marks(bands: &[(f64, f64, u8)], start: f64, end: f64) -> Vec<Value> {
    bands
        .windows(2)
        .filter_map(|pair| {
            let full = match (pair[0].2, pair[1].2) {
                (2, 1) | (1, 2) => true,
                (1, 0) | (0, 1) => false,
                _ => return None,
            };
            Some(json!({"at": (pair[0].1 - start) / (end - start), "full": full}))
        })
        .collect()
}

// ---------------------------------------------------------------- 换算页的共同时间轴

#[derive(Deserialize)]
struct LanePlace {
    latitude: Option<f64>,
    longitude: Option<f64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LanesInput {
    start: f64,
    end: f64,
    places: Vec<LanePlace>,
    /// 系统「不使用颜色区分」：另给昼 / 曙暮 / 夜的边界刻度。
    #[serde(default)]
    marks: bool,
}

/// 一张时间轴上最多几条（换算结果是来源、目标、本机与保存的地点，几个到十几个）。
const LANES_MAX: usize = 64;

/// 换算页结果的共同时间轴：同一个时间框（本机当天）里每个地方一条天。每条给天色色标（与昼夜条同一批：`lane_stops`，
/// 每 10 分钟一个）、昼 / 曙暮 / 夜三段（位置 0…1；宿主按竖线落在哪一段说「白天 / 夜晚」，不再自己算日出日落），
/// 「不使用颜色区分」开着时再给三段的边界刻度。没有坐标的地方三样都空（宿主画中性的底，不说昼夜，不拿别处的坐标冒充）。
/// 宿主只在框或地点变了时调它（读到、换一处、跨过午夜）；竖线与点出来的那一刻只是框里的位置，不再来这里。
fn lanes(input: &LanesInput) -> Result<Value, String> {
    let fits = |t: f64| astronomy::SUPPORTED_UNIX.contains(&t);
    if !fits(input.start)
        || !fits(input.end)
        || input.end <= input.start
        || input.end - input.start > 2.0 * 86_400.0
    {
        return Err("Lanes need a span of up to two days from 1800 to 2100".into());
    }
    if input.places.len() > LANES_MAX {
        return Err(format!("Lanes take at most {LANES_MAX} places"));
    }
    let (start, end) = (input.start, input.end);
    let span = end - start;
    let lanes: Vec<Value> = input
        .places
        .iter()
        .map(|place| match (place.latitude, place.longitude) {
            (Some(lat), Some(lon)) if (-90.0..=90.0).contains(&lat) && (-180.0..=180.0).contains(&lon) => {
                let stops: Vec<Value> =
                    lane_stops(start, end, lat, lon, 10.0).into_iter().map(|(at, color)| json!({"at": at, "color": color})).collect();
                let bands = astronomy::daylight_bands(start, end, lat, lon);
                let parts: Vec<Value> = bands
                    .iter()
                    .map(|&(from, to, kind)| json!({"from": (from - start) / span, "to": (to - start) / span, "kind": kind}))
                    .collect();
                let marks = if input.marks { band_marks(&bands, start, end) } else { Vec::new() };
                json!({"stops": stops, "bands": parts, "marks": marks})
            }
            _ => json!({"stops": [], "bands": [], "marks": []}),
        })
        .collect();
    Ok(json!({"lanes": lanes}))
}

/// 晨昏线两段的颜色与太阳光晕的颜色（位图里画，`palette` 也给宿主）。
const DAWN: Lch = lch(0.78, 0.10, 30.0);
const DUSK: Lch = lch(0.80, 0.12, 62.0);
const SUN_GLOW: Lch = lch(0.86, 0.12, 75.0);

/// 地图上几样固定的颜色（宿主照这张表画，别处不另存一份）：墨与纸（地点的圈与地图上的字）、破晓与黄昏两段晨昏线、
/// 太阳（金盘、深色外沿、浅色细圈、光晕）、月亮（暗面与亮面）、地图上字的衬底（深、浅）。不透明度由宿主按用处给。
fn palette() -> Value {
    json!({
        "ink": hex(INK), "paper": hex(PAPER), "nightSky": hex(SEA_NIGHT),
        "dawn": hex(DAWN), "dusk": hex(DUSK),
        "sun": hex(lch(0.80, 0.14, 68.0)), "sunRim": hex(lch(0.30, 0.05, 60.0)), "sunRing": hex(lch(0.98, 0.02, 85.0)),
        "sunGlow": hex(SUN_GLOW),
        "moonDark": hex(lch(0.32, 0.02, 262.0)), "moonLit": hex(lch(0.88, 0.01, 250.0)),
        "haloDark": hex(lch(0.16, 0.03, 268.0)), "haloLight": hex(lch(0.97, 0.006, 90.0)),
    })
}

pub fn dispatch(operation: &str, value: Value) -> Result<Value, String> {
    match operation {
        "sky.panel" => panel(&serde_json::from_value(value).map_err(|e| e.to_string())?),
        "sky.lane" => lane(&serde_json::from_value(value).map_err(|e| e.to_string())?),
        "sky.strip" => strip(&serde_json::from_value(value).map_err(|e| e.to_string())?),
        "sky.lanes" => lanes(&serde_json::from_value(value).map_err(|e| e.to_string())?),
        "sky.palette" => Ok(palette()),
        _ => Err(format!("Unknown sky operation: {operation}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 地形是进程里的一份共享状态：碰它的测试一个一个跑。
    static RELIEF_LOCK: Mutex<()> = Mutex::new(());

    #[test]
    fn apca_matches_the_reference_values() {
        let black = lch(0.0, 0.0, 0.0);
        let white = lch(1.0, 0.0, 0.0);
        let gray = lch(
            ((136.0_f64 / 255.0 + 0.055) / 1.055).powf(2.4).cbrt(),
            0.0,
            0.0,
        );
        assert_eq!(srgb8(gray), [136, 136, 136]);
        for (text, background, expected) in [
            (black, white, 106.0407),
            (white, black, -107.8847),
            (gray, white, 63.0565),
            (white, gray, -68.5415),
        ] {
            let actual = apca(text, background);
            assert!(
                (actual - expected).abs() < 0.001,
                "{text:?} on {background:?}: {actual} vs {expected}"
            );
        }
        for color in [black, white, gray, INK, PAPER] {
            assert_eq!(apca(color, color), 0.0);
        }
    }

    fn readable_wcag_only(sky: &Sky, need: f64) -> Readable {
        let worst = |fg: Lch, top: Lch, horizon: Lch| contrast(fg, top).min(contrast(fg, horizon));
        let ink = worst(INK, sky.top, sky.horizon) > worst(PAPER, sky.top, sky.horizon);
        let fg = if ink { INK } else { PAPER };
        let step = if ink { 0.012 } else { -0.012 };
        let (mut top, mut horizon) = (sky.top, sky.horizon);
        for _ in 0..60 {
            if worst(fg, top, horizon) >= need {
                break;
            }
            top.l = (top.l + step).clamp(0.04, 0.99);
            horizon.l = (horizon.l + step).clamp(0.04, 0.99);
        }
        Readable {
            top,
            horizon,
            mid: mix(top, horizon, 0.5),
            ink,
            ratio: worst(fg, top, horizon),
        }
    }

    fn text_preferences(top: Lch, horizon: Lch) -> (bool, bool) {
        let wcag = |fg: Lch| contrast(fg, top).min(contrast(fg, horizon));
        let perceptual = |fg: Lch| apca(fg, top).abs().min(apca(fg, horizon).abs());
        (wcag(INK) > wcag(PAPER), perceptual(INK) > perceptual(PAPER))
    }

    fn readable_bits(r: &Readable) -> ([u64; 10], bool) {
        let Lch {
            l: tl,
            c: tc,
            h: th,
        } = r.top;
        let Lch {
            l: hl,
            c: hc,
            h: hh,
        } = r.horizon;
        let Lch {
            l: ml,
            c: mc,
            h: mh,
        } = r.mid;
        (
            [tl, tc, th, hl, hc, hh, ml, mc, mh, r.ratio].map(f64::to_bits),
            r.ink,
        )
    }

    #[test]
    fn readable_agrees_with_apca_in_the_twilight_band() {
        let mut disagreements = 0;
        for need in [5.5, 7.0] {
            for rising in [false, true] {
                for k in 0..=160 {
                    let altitude = -20.0 + f64::from(k) * 0.25;
                    let original = sky(altitude, rising);
                    let out = readable(&original, need);
                    let oracle = readable_wcag_only(&original, need);
                    let (wcag, perceptual) = text_preferences(original.top, original.horizon);
                    if wcag == perceptual {
                        assert_eq!(
                            readable_bits(&out),
                            readable_bits(&oracle),
                            "altitude {altitude} rising {rising} need {need}"
                        );
                    } else {
                        disagreements += 1;
                        assert_eq!(
                            text_preferences(out.top, out.horizon),
                            (out.ink, out.ink),
                            "altitude {altitude} rising {rising} need {need}"
                        );
                        let fg = if out.ink { INK } else { PAPER };
                        let worst = contrast(fg, out.top).min(contrast(fg, out.horizon));
                        assert!(
                            worst >= need || oracle.ratio < need,
                            "altitude {altitude} rising {rising} need {need}: {worst}"
                        );
                        assert_eq!(out.top.c.to_bits(), original.top.c.to_bits());
                        assert_eq!(out.top.h.to_bits(), original.top.h.to_bits());
                        assert_eq!(out.horizon.c.to_bits(), original.horizon.c.to_bits());
                        assert_eq!(out.horizon.h.to_bits(), original.horizon.h.to_bits());
                        assert_eq!(out.ratio.to_bits(), worst.to_bits());
                        assert_eq!(
                            readable_bits(&readable(&original, f64::INFINITY)),
                            readable_bits(&readable_wcag_only(&original, f64::INFINITY))
                        );
                    }
                }
            }
        }
        assert!(disagreements > 0);
    }

    #[test]
    fn readable_chooses_the_fewest_agreeing_steps() {
        let mut changed_from_legacy = 0;
        for rising in [false, true] {
            for k in 0..=160 {
                let original = sky(-20.0 + f64::from(k) * 0.25, rising);
                let (wcag, perceptual) = text_preferences(original.top, original.horizon);
                if wcag == perceptual {
                    continue;
                }
                // 两条完整路径独立枚举，按步数从小到大找第一个合格状态。
                let paths = [false, true].map(|ink| {
                    let step = if ink { 0.012 } else { -0.012 };
                    std::iter::successors(
                        Some((original.top, original.horizon)),
                        |&(top, horizon)| {
                            Some((
                                Lch {
                                    l: (top.l + step).clamp(0.04, 0.99),
                                    ..top
                                },
                                Lch {
                                    l: (horizon.l + step).clamp(0.04, 0.99),
                                    ..horizon
                                },
                            ))
                        },
                    )
                    .take(61)
                    .collect::<Vec<_>>()
                });
                for need in [3.0, 5.5, 7.0, 12.0, f64::INFINITY] {
                    let expected = (0..=60).find_map(|steps| {
                        [wcag, !wcag].into_iter().find_map(|ink| {
                            let (top, horizon) = paths[usize::from(ink)][steps];
                            let fg = if ink { INK } else { PAPER };
                            let ratio = contrast(fg, top).min(contrast(fg, horizon));
                            (ratio >= need && text_preferences(top, horizon) == (ink, ink)).then(
                                || Readable {
                                    top,
                                    horizon,
                                    mid: mix(top, horizon, 0.5),
                                    ink,
                                    ratio,
                                },
                            )
                        })
                    });
                    let oracle = readable_wcag_only(&original, need);
                    let expected = expected.unwrap_or(oracle);
                    changed_from_legacy +=
                        usize::from(readable_bits(&expected) != readable_bits(&oracle));
                    assert_eq!(
                        readable_bits(&readable(&original, need)),
                        readable_bits(&expected),
                        "rising {rising} step {k} need {need}"
                    );
                }
            }
        }
        assert!(
            changed_from_legacy > 0,
            "the shortest-step test must distinguish the legacy algorithm"
        );
    }

    #[test]
    #[ignore]
    fn apca_band_report() {
        let (mut changed, mut total, mut flipped, mut max_shift) = (0, 0, 0, 0.0_f64);
        for need in [5.5, 7.0] {
            for rising in [false, true] {
                for k in 0..=160 {
                    let original = sky(-20.0 + f64::from(k) * 0.25, rising);
                    let out = readable(&original, need);
                    let oracle = readable_wcag_only(&original, need);
                    total += 1;
                    changed += usize::from(readable_bits(&out) != readable_bits(&oracle));
                    flipped += usize::from(out.ink != oracle.ink);
                    max_shift = max_shift
                        .max((out.top.l - oracle.top.l).abs())
                        .max((out.horizon.l - oracle.horizon.l).abs());
                }
            }
        }
        println!("APCA changed={changed}/{total} flipped={flipped} max_shift={max_shift:.3}");
    }

    #[test]
    fn terrain_cache_maps_the_same_bytes_and_rejects_invalid_files() {
        let path = std::env::temp_dir().join(format!("dayside-terrain-{}.bin", uuid::Uuid::new_v4()));
        let original = terrain(&[80, 90, 140, 160, 95, 110, 190, 210], 4, 2, 80.0, -58.0);
        save_terrain(&path, &original).unwrap();
        let mapped = mapped_terrain(&path, 4, 2, 80.0, -58.0).unwrap();
        for index in 0..3 { assert_eq!(original.cells.table(index), mapped.cells.table(index)); }
        assert!(matches!(mapped.cells.storage, GridStorage::Mapped(_)));
        assert!(mapped_terrain(&path, 5, 2, 80.0, -58.0).is_none());
        assert!(mapped_terrain(&path, 4, 3, 80.0, -58.0).is_none());
        assert!(mapped_terrain(&path, 4, 2, 79.0, -58.0).is_none());
        assert!(mapped_terrain(&path, 4, 2, 80.0, -57.0).is_none());
        // 写坏文件用原子替换，不碰仍在读的映射。
        let good = std::fs::read(&path).unwrap();
        for offset in [0, 8, 12, 16, 20, 24, 32, 40, 48, 56, 64, TERRAIN_HEADER] {
            let mut bad = good.clone();
            bad[offset] ^= 1;
            let replacement = path.with_extension("bad");
            std::fs::write(&replacement, bad).unwrap();
            std::fs::rename(replacement, &path).unwrap();
            assert!(mapped_terrain(&path, 4, 2, 80.0, -58.0).is_none(), "offset {offset}");
        }
        for length in [0, 7, TERRAIN_HEADER - 1, good.len() - 1] {
            let replacement = path.with_extension("short");
            std::fs::write(&replacement, &good[..length]).unwrap();
            std::fs::rename(replacement, &path).unwrap();
            assert!(mapped_terrain(&path, 4, 2, 80.0, -58.0).is_none(), "length {length}");
        }
        // 改坏磁盘缓存不会改掉已经打开的表。
        for index in 0..3 { assert_eq!(original.cells.table(index), mapped.cells.table(index)); }
        std::fs::remove_file(path).unwrap();
    }

    /// 太阳高度从 −90° 扫到 90°（1/8 度一步），两个方向、两档要求，字与底的对比度一次也不低于要求。
    #[test]
    fn every_sky_reads_at_the_required_contrast() {
        for need in [5.5, 7.0] {
            for r in [false, true] {
                let mut a = -90.0;
                while a <= 90.0 {
                    let got = readable(&sky(a, r), need);
                    assert!(
                        got.ratio >= need,
                        "altitude {a} rising {r} need {need}: {}",
                        got.ratio
                    );
                    // 独立复核：用最终的两端各算一次。
                    let fg = if got.ink { INK } else { PAPER };
                    assert!(contrast(fg, got.top) >= need && contrast(fg, got.horizon) >= need);
                    a += 0.125;
                }
            }
        }
    }

    /// 天越亮太阳越高：「整体」色的明度随太阳高度不减（两个方向）。
    #[test]
    fn the_sky_brightens_as_the_sun_climbs() {
        for r in [false, true] {
            let mut previous = 0.0;
            let mut a = -90.0;
            while a <= 90.0 {
                let l = sky(a, r).mid.l;
                assert!(l + 1e-9 >= previous, "altitude {a}: {l} < {previous}");
                previous = l;
                a += 0.25;
            }
        }
    }

    #[test]
    fn mixing_in_oklab_keeps_the_ends_and_never_turns_green() {
        let (cool, warm) = (lch(0.93, 0.010, 240.0), lch(0.95, 0.020, 84.0));
        let a = mix(cool, warm, 0.0);
        let b = mix(cool, warm, 1.0);
        assert!((a.l - cool.l).abs() < 1e-12 && (b.h - warm.h).abs() < 1e-9);
        // 按色相插值会经过 160° 附近的绿；OKLab 里中点彩度很低、不是绿。
        let middle = mix(cool, warm, 0.5);
        assert!(
            middle.c < 0.01 || !(120.0..200.0).contains(&middle.h),
            "{middle:?}"
        );
    }

    /// 地图的海陆：白天陆比海亮、夜里陆比海亮，两边亮度比都至少 1.5。
    #[test]
    fn land_and_sea_part_by_day_and_by_night() {
        let day = contrast(surface(40.0, true, true), surface(40.0, true, false));
        let night = contrast(surface(-40.0, true, true), surface(-40.0, true, false));
        assert!(day >= 1.5 && night >= 1.5, "day {day} night {night}");
        assert!(luminance(surface(40.0, true, true)) > luminance(surface(40.0, true, false)));
        assert!(luminance(surface(-40.0, true, true)) > luminance(surface(-40.0, true, false)));
    }

    /// 地球窗的边色与地图深夜海面的颜色相同，文字仍有足够对比度。
    #[test]
    fn earth_margin_matches_the_maps_night_ocean() {
        let edge = palette()["nightSky"].as_str().unwrap().to_owned();
        for rising in [false, true] {
            assert_eq!(edge, hex(surface(-90.0, rising, false)));
        }
        assert!(contrast(PAPER, SEA_NIGHT) >= 4.5);
    }

    /// 查表与逐点算出来的颜色一致（1/4 度一档内）。
    #[test]
    fn the_table_matches_the_surface_function() {
        for &(a, r, land) in &[
            (-50.0, false, true),
            (-3.25, true, false),
            (0.0, false, false),
            (12.5, true, true),
            (89.75, false, true),
        ] {
            assert_eq!(table()[table_index(a, r, land)], srgb8(surface(a, r, land)));
        }
    }

    /// 地图上某一点是白天还是夜，与 `astronomy::elevation` 的判断一致（离晨昏线 2° 以外的点；无地形时陆地底色）。
    #[test]
    fn the_raster_agrees_with_the_sun_about_day_and_night() {
        let _guard = RELIEF_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        set_terrain(None);
        let (w, h) = (360_usize, 138_usize);
        let (north, south) = (80.0, -58.0);
        for instant in [1_790_000_000.0, 1_800_000_000.0, 1_806_000_000.0] {
            let mut buffer = vec![0_u8; w * h * 4];
            assert!(raster(instant, w, h, north, south, 0.0, &mut buffer));
            let mut checked = 0;
            for y in (0..h).step_by(7) {
                for x in (0..w).step_by(11) {
                    let lat = north - (y as f64 + 0.5) / h as f64 * (north - south);
                    let lon = -180.0 + (x as f64 + 0.5) / w as f64 * 360.0;
                    let altitude = astronomy::elevation(instant, lat, lon);
                    let o = (y * w + x) * 4;
                    let light = 0.2126 * f64::from(buffer[o])
                        + 0.7152 * f64::from(buffer[o + 1])
                        + 0.0722 * f64::from(buffer[o + 2]);
                    if altitude > 2.0 {
                        assert!(light > 190.0, "{instant} ({lat},{lon}) day but {light}");
                        checked += 1;
                    } else if altitude < -8.0 {
                        assert!(light < 110.0, "{instant} ({lat},{lon}) night but {light}");
                        checked += 1;
                    }
                }
            }
            assert!(checked > 500, "{checked}");
        }
    }

    /// 合成地形：一半是海（灰 90）一半是陆（灰 180）。有地形时白天的海比陆暗、夜里也是。
    #[test]
    fn relief_splits_land_from_sea() {
        let _guard = RELIEF_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let (rw, rh) = (72_usize, 36_usize);
        let mut gray = vec![90_u8; rw * rh];
        for y in 0..rh {
            for x in rw / 2..rw {
                gray[y * rw + x] = 180;
            }
        }
        unsafe {
            assert!(mt_sky_relief_set(
                gray.as_ptr(),
                rw as u32,
                rh as u32,
                90.0,
                -90.0
            ));
        }
        let (w, h) = (144_usize, 72_usize);
        let mut buffer = vec![0_u8; w * h * 4];
        // 太阳在 (0°, 0°) 附近：经度 −90…90 白天。
        let instant = 1_790_000_000.0;
        assert!(raster(instant, w, h, 90.0, -90.0, 0.0, &mut buffer));
        let (_, sun_lon) = worldmap::subsolar_point(instant);
        let pixel = |lon: f64| {
            let x = (((lon + 180.0) / 360.0) * w as f64) as usize;
            let o = ((h / 2) * w + x.min(w - 1)) * 4;
            0.2126 * f64::from(buffer[o])
                + 0.7152 * f64::from(buffer[o + 1])
                + 0.0722 * f64::from(buffer[o + 2])
        };
        // 离太阳 30° 的海与陆（各在一边）都在白天。
        let (sea, land) = (wrap(sun_lon - 30.0), wrap(sun_lon + 30.0));
        let (sea_x, land_x) = (
            ((sea + 180.0) / 360.0 * w as f64) as usize,
            ((land + 180.0) / 360.0 * w as f64) as usize,
        );
        if sea_x < w / 2 && land_x >= w / 2 {
            assert!(
                pixel(land) > pixel(sea),
                "land {} sea {}",
                pixel(land),
                pixel(sea)
            );
        }
        mt_sky_relief_release();
    }

    /// 滑动窗口算的地形与逐像素暴力求「同类地面局部均值」一模一样（独立判据：直接按窗口求和，不用逐列和）。
    #[test]
    fn terrain_equals_the_brute_force_local_mean() {
        let (w, h) = (97_usize, 41_usize);
        let mut seed = 0x2545_f491_u32;
        let mut next = || {
            seed ^= seed << 13;
            seed ^= seed >> 17;
            seed ^= seed << 5;
            seed
        };
        // 一块块的陆地（140…220）落在海（75…115）里，边界不规则。
        let gray: Vec<u8> = (0..w * h)
            .map(|i| {
                let (x, y) = (i % w, i / w);
                let land = ((x / 9 + y / 7) % 3 == 0) ^ (next() % 11 == 0);
                if land {
                    140 + (next() % 81) as u8
                } else {
                    75 + (next() % 41) as u8
                }
            })
            .collect();
        let t = terrain(&gray, w, h, 80.0, -58.0);
        let radius = (w / 180).max(2);
        let fixed = |v: f64| (v * f64::from(GAIN)).round().clamp(0.0, 255.0) as u8;
        for y in 0..h {
            for x in 0..w {
                let i = y * w + x;
                let is_land = gray[i] >= 125;
                let (mut sum, mut count) = (0_u32, 0_u32);
                for yy in y.saturating_sub(radius)..(y + radius + 1).min(h) {
                    for xx in x.saturating_sub(radius)..(x + radius + 1).min(w) {
                        if (gray[yy * w + xx] >= 125) == is_land {
                            sum += u32::from(gray[yy * w + xx]);
                            count += 1;
                        }
                    }
                }
                let g = f64::from(gray[i]);
                let detail = g - f64::from(sum) / f64::from(count.max(1));
                let (night, day) = if is_land {
                    let t = ((g - 140.0) / 80.0).clamp(0.0, 1.0);
                    (
                        fixed(0.66 + 0.34 * t),
                        fixed((0.965 + detail * 0.0055 + (t - 0.35) * 0.03).clamp(0.84, 1.0)),
                    )
                } else {
                    let t = ((g - 75.0) / 40.0).clamp(0.0, 1.0);
                    (
                        fixed(0.72 + 0.28 * t),
                        fixed((0.975 + detail * 0.003 + (t - 0.5) * 0.04).clamp(0.9, 1.02)),
                    )
                };
                assert_eq!((t.cells.land()[i] == 255, t.cells.night()[i], t.cells.day()[i]), (is_land, night, day), "({x}, {y})");
            }
        }
    }

    /// 画布地形取每个画布像素覆盖那一块的平均：半海半陆的那一列是半陆；纬度按范围对应（只画 66°N…46°S 时，
    /// 北纬 20°…10° 那条陆地带落在同一纬度上）。
    #[test]
    fn the_canvas_terrain_averages_what_each_pixel_covers() {
        let _guard = RELIEF_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        // 8 列：左 4 列海、右 4 列陆；缩成 3 列时中间那列盖住第 2…5 列（两海两陆）。
        let gray: Vec<u8> = (0..8 * 4)
            .map(|i| if i % 8 < 4 { 95 } else { 180 })
            .collect();
        set_terrain(Some(terrain(&gray, 8, 4, 90.0, -90.0)));
        let g = grid(3, 4, 90.0, -90.0).expect("terrain is set");
        assert_eq!(g.land()[0], 0);
        assert_eq!(g.land()[2], 255);
        assert!((120..=135).contains(&g.land()[1]), "{}", g.land()[1]);
        // 纬度带：138 行覆盖 80°N…58°S，1° 一行；北纬 20°…10° 是陆地。
        let gray: Vec<u8> = (0..36 * 138)
            .map(|i| {
                if (60..70).contains(&(i / 36)) {
                    180
                } else {
                    95
                }
            })
            .collect();
        set_terrain(Some(terrain(&gray, 36, 138, 80.0, -58.0)));
        let (north, south, rows) = (66.0, -46.0, 112_usize);
        let g = grid(36, rows, north, south).expect("terrain is set");
        for y in 0..rows {
            let lat = north - (y as f64 + 0.5) / rows as f64 * (north - south);
            let cover = g.land()[y * 36 + 5];
            if (10.5..19.5).contains(&lat) {
                assert_eq!(cover, 255, "{lat}");
            } else if !(9.0..21.0).contains(&lat) {
                assert_eq!(cover, 0, "{lat}");
            }
        }
        set_terrain(None);
    }

    /// 画进 IOSurface 的那条路（行尾补齐、BGRA）与紧排 RGBA 逐像素相同；量一块地方的亮度与读回位图算的差不到 0.02。
    #[test]
    fn the_surface_layout_matches_the_image_layout_and_luminance_matches_the_pixels() {
        let _guard = RELIEF_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        set_terrain(None);
        let (w, h, instant) = (240_usize, 92_usize, 1_790_000_000.0);
        let mut tight = vec![0_u8; w * h * 4];
        assert!(raster(instant, w, h, 80.0, -58.0, 1.0, &mut tight));
        let stride = w * 4 + 64;
        let mut surface = vec![7_u8; stride * h];
        assert!(raster_into(
            instant,
            w,
            h,
            80.0,
            -58.0,
            1.0,
            &mut surface,
            Layout { stride, bgra: true },
            None
        ));
        for y in 0..h {
            for x in 0..w {
                let (t, s) = ((y * w + x) * 4, y * stride + x * 4);
                assert_eq!(
                    [tight[t], tight[t + 1], tight[t + 2], tight[t + 3]],
                    [surface[s + 2], surface[s + 1], surface[s], surface[s + 3]],
                    "({x}, {y})"
                );
            }
            assert!(
                surface[y * stride + w * 4..(y + 1) * stride]
                    .iter()
                    .all(|&b| b == 7),
                "行尾的补齐不能写"
            );
        }
        let mut dark = vec![0_u8; w * h * 4];
        assert!(raster(instant, w, h, 80.0, -58.0, 0.0, &mut dark));
        for &(x0, y0, x1, y1) in &[
            (10.0, 10.0, 40.0, 20.0),
            (120.0, 40.0, 200.0, 60.0),
            (0.0, 0.0, 240.0, 92.0),
        ] {
            let measured = map_luminance(instant, w, h, 80.0, -58.0, x0, y0, x1, y1).unwrap();
            let (mut sum, mut n) = (0.0, 0.0);
            for y in y0 as usize..y1 as usize {
                for x in x0 as usize..x1 as usize {
                    let o = (y * w + x) * 4;
                    let lin = |c: u8| {
                        let v = f64::from(c) / 255.0;
                        if v <= 0.04045 {
                            v / 12.92
                        } else {
                            ((v + 0.055) / 1.055).powf(2.4)
                        }
                    };
                    sum += 0.2126 * lin(dark[o])
                        + 0.7152 * lin(dark[o + 1])
                        + 0.0722 * lin(dark[o + 2]);
                    n += 1.0;
                }
            }
            assert!(
                (measured - sum / n).abs() < 0.02,
                "({x0}, {y0}) {measured} vs {}",
                sum / n
            );
        }
    }

    /// 晨昏线与太阳光晕画进位图：只改动晨昏线附近（太阳高度离 −0.833° 不远）与太阳附近的像素，贴图边那一截淡到几乎不变。
    #[test]
    fn marks_are_drawn_only_along_the_terminator_and_around_the_sun() {
        let _guard = RELIEF_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        set_terrain(None);
        let (w, h, north, south, instant) = (720_usize, 276_usize, 80.0, -58.0, 1_790_000_000.0);
        let (mut plain, mut marked) = (vec![0_u8; w * h * 4], vec![0_u8; w * h * 4]);
        assert!(raster_into(
            instant,
            w,
            h,
            north,
            south,
            0.0,
            &mut plain,
            Layout::tight(w),
            None
        ));
        assert!(raster_into(
            instant,
            w,
            h,
            north,
            south,
            0.0,
            &mut marked,
            Layout::tight(w),
            Some(Marks {
                ppp: 2.0,
                large: false
            })
        ));
        let (sun_lat, sun_lon) = worldmap::subsolar_point(instant);
        let (sx, sy) = (
            (sun_lon + 180.0) / 360.0 * w as f64,
            (north - sun_lat) / (north - south) * h as f64,
        );
        let mut changed = 0;
        for y in 0..h {
            for x in 0..w {
                let o = (y * w + x) * 4;
                if (0..3).all(|j| plain[o + j] == marked[o + j]) {
                    continue;
                }
                changed += 1;
                let near_sun = ((x as f64 + 0.5 - sx).powi(2) + (y as f64 + 0.5 - sy).powi(2))
                    .sqrt()
                    <= 16.0 * 2.0 + 1.0;
                let lat = north - (y as f64 + 0.5) / h as f64 * (north - south);
                let lon = -180.0 + (x as f64 + 0.5) / w as f64 * 360.0;
                let off = (astronomy::elevation(instant, lat, lon) - HORIZON).abs();
                assert!(
                    near_sun || off < 3.0,
                    "({lat}, {lon}) changed {off}° from the terminator"
                );
            }
        }
        assert!(changed > 1_000, "{changed}");
    }

    /// 城市灯火只亮在夜里（与没开灯的同一张图比，变亮的像素离晨昏线的夜一侧不远于光晕），东京深夜是亮的，只加不减。
    #[test]
    fn city_lights_only_light_the_night() {
        let _guard = RELIEF_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        set_terrain(None);
        let (w, h, north, south) = (720_usize, 276_usize, 80.0, -58.0);
        let instant = 1_790_000_000.0; // 2026-09-21 14:13 UTC：东京 23:13
        let (mut dark, mut lit) = (vec![0_u8; w * h * 4], vec![0_u8; w * h * 4]);
        assert!(raster(instant, w, h, north, south, 0.0, &mut dark));
        assert!(raster(instant, w, h, north, south, 1.0, &mut lit));
        let mut changed = 0;
        for y in 0..h {
            for x in 0..w {
                let o = (y * w + x) * 4;
                assert!((0..3).all(|j| lit[o + j] >= dark[o + j]), "lights only add");
                if (0..3).any(|j| lit[o + j] != dark[o + j]) {
                    changed += 1;
                    let lat = north - (y as f64 + 0.5) / h as f64 * (north - south);
                    let lon = -180.0 + (x as f64 + 0.5) / w as f64 * 360.0;
                    assert!(
                        astronomy::elevation(instant, lat, lon) < HORIZON + 2.0,
                        "({lat}, {lon}) lit in daylight"
                    );
                }
            }
        }
        assert!(changed > 300, "{changed}");
        let tokyo = {
            let (x, y) = (
                ((139.69 + 180.0) / 360.0 * w as f64) as usize,
                ((north - 35.69) / (north - south) * h as f64) as usize,
            );
            (y * w + x) * 4
        };
        let bright = |b: &[u8]| (0..3).map(|j| u32::from(b[tokyo + j])).sum::<u32>();
        assert!(
            bright(&lit) > bright(&dark) + 150,
            "Tokyo {} vs {}",
            bright(&lit),
            bright(&dark)
        );
    }

    /// 太阳弧：日出时点在最左、日落时在最右；正午在中间附近。
    #[test]
    fn the_sun_path_walks_from_rise_to_set() {
        // 伦敦，2026-06-21（夏至，BST +1 小时）。
        let (lat, lon, offset) = (51.5, -0.13, 3600.0);
        let day_start = 1_781_996_400.0; // 2026-06-21 00:00 BST
        let (rise, set) = sun_times(day_start, lat, lon);
        let (rise, set) = (rise.expect("rise"), set.expect("set"));
        let at = |m: f64| sun_path(day_start + m * 60.0, lat, lon, offset);
        assert!(at(rise + 1.0)["fraction"].as_f64().unwrap() < 0.05);
        assert!(at(set - 6.0)["fraction"].as_f64().unwrap() > 0.95);
        let noon = at((rise + set) / 2.0);
        assert!(
            noon["up"].as_bool().unwrap()
                && (noon["fraction"].as_f64().unwrap() - 0.5).abs() < 0.05
        );
        let night = at(set + 30.0);
        assert!(!night["up"].as_bool().unwrap() && night["fraction"].as_f64().unwrap() < 0.1);
    }

    #[test]
    fn panel_gives_every_row_colours_and_the_dot_its_day() {
        let value = dispatch(
            "sky.panel",
            json!({
                "instant": 1_790_000_000.0, "now": 1_790_000_000.0,
                "home": {"latitude": 34.05, "longitude": -118.24, "utcOffset": -25_200.0},
                "places": [
                    {"latitude": 51.51, "longitude": -0.13, "utcOffset": 3600.0},
                    {"latitude": null, "longitude": null, "utcOffset": 0.0}
                ]
            }),
        )
        .unwrap();
        assert_eq!(value["rows"].as_array().unwrap().len(), 2);
        assert_eq!(value["rows"][1]["known"], json!(false));
        assert!(value["rows"][0]["colors"]["ratio"].as_f64().unwrap() >= 5.5);
        assert!(value.get("track").is_none(), "滑块轨道走 strip，面板不再每次重算");
        assert!(value["dayHere"].is_boolean(), "有本机坐标就说昼夜");
        // 伦敦 2026-09-21：日出约 6:50、日落约 19:05（当地夏令时），都在当地这一天里。
        let (rise, set) = (
            value["rows"][0]["sunrise"].as_f64().unwrap(),
            value["rows"][0]["sunset"].as_f64().unwrap(),
        );
        let local = |t: f64| ((t + 3600.0) / 60.0).rem_euclid(1440.0);
        assert!(
            (local(rise) - 410.0).abs() < 15.0 && (local(set) - 1145.0).abs() < 15.0,
            "{} {}",
            local(rise),
            local(set)
        );
        assert!(value["rows"][1]["sunrise"].is_null());
        // 框的底色一天里每 10 分钟都够 8:1（框里系统的次要文字才过 4.5:1）。
        for k in 0..144 {
            let t = 1_790_000_000.0 + f64::from(k) * 600.0;
            let v = dispatch("sky.panel", json!({"instant": t, "now": t, "home": {"latitude": 34.05, "longitude": -118.24, "utcOffset": -25_200.0},
                                                 "places": []})).unwrap();
            assert!(
                v["chrome"]["ratio"].as_f64().unwrap() >= CHROME_NEED,
                "{t}: {}",
                v["chrome"]["ratio"]
            );
        }
    }

    /// 页首天色带与面板滑块轨道是同一个操作：宿主拿轨道的中心当「看的那一刻」来问（`SliderTrackMemo`），
    /// 中心是此刻时得到此刻前后 12 小时、每 20 分钟一个色标（73 个，位置均分）；中心离此刻超过 12 小时时得到它前后 12 小时。
    /// 圆点画太阳还是月亮（`sky.panel` 的 `dayHere`）与带上同一刻的昼夜一致。
    #[test]
    fn the_strip_is_the_panel_track() {
        for now in [1_790_000_000.0, 1_790_031_337.0, 1_782_030_240.0] {
            let panel = dispatch("sky.panel", json!({"instant": now, "now": now,
                "home": {"latitude": 34.05, "longitude": -118.24, "utcOffset": -25_200.0}, "places": []})).unwrap();
            let strip = dispatch(
                "sky.strip",
                json!({"now": now, "instant": now, "latitude": 34.05, "longitude": -118.24}),
            )
            .unwrap();
            let stops = strip["stops"].as_array().unwrap();
            assert_eq!(stops.len(), 73);
            let expected = lane_stops(now - STRIP_HALF, now + STRIP_HALF, 34.05, -118.24, 20.0);
            for (k, (stop, (at, color))) in stops.iter().zip(expected).enumerate() {
                assert_eq!(stop["color"], json!(color), "{now} stop {k}");
                assert!((stop["at"].as_f64().unwrap() - k as f64 / 72.0).abs() < 1e-12 && (at - k as f64 / 72.0).abs() < 1e-12);
            }
            assert_eq!(strip["marker"], json!(0.5));
            assert_eq!(strip["now"], json!(0.5));
            assert_eq!(strip["beyond"], json!(false));
            assert_eq!(strip["dayHere"], panel["dayHere"]);
            assert_eq!(strip["marks"], json!([]), "没要刻度就不给");
            // 跳到 17 小时 24 分钟后：滑块拿那一刻当中心问，得到的就是工具窗带子在那一刻画的天。
            let far = now + 17.0 * 3600.0 + 24.0 * 60.0;
            let slider = dispatch("sky.strip", json!({"now": now, "instant": far, "latitude": 34.05, "longitude": -118.24})).unwrap();
            assert_eq!(slider["beyond"], json!(true));
            assert_eq!(slider["marker"], json!(0.5));
            let far_panel = dispatch("sky.panel", json!({"instant": far, "now": now,
                "home": {"latitude": 34.05, "longitude": -118.24, "utcOffset": -25_200.0}, "places": []})).unwrap();
            assert_eq!(slider["dayHere"], far_panel["dayHere"], "圆点与轨道正中同一刻的昼夜");
        }
    }

    /// 拖过时间：带不动、标记动（往后 3 小时 = 正中往右 3 / 24）；超过 12 小时，带改以看的那一刻为中心，此刻不在带上。
    #[test]
    fn the_strip_follows_the_viewed_moment_and_recenters_beyond_twelve_hours() {
        let now = 1_790_000_000.0;
        let at = |instant: f64| {
            dispatch(
                "sky.strip",
                json!({"now": now, "instant": instant, "latitude": 51.51, "longitude": -0.13}),
            )
            .unwrap()
        };
        let later = at(now + 3.0 * 3600.0);
        assert!((later["marker"].as_f64().unwrap() - (0.5 + 3.0 / 24.0)).abs() < 1e-12);
        assert_eq!(later["now"], json!(0.5));
        assert_eq!(
            later["stops"],
            at(now)["stops"],
            "带以此刻为中心，拖动时不变"
        );
        let edge = at(now - 12.0 * 3600.0);
        assert_eq!(edge["marker"], json!(0.0));
        assert_eq!(edge["beyond"], json!(false));
        let far = at(now + 3.0 * 86_400.0);
        assert_eq!(far["beyond"], json!(true));
        assert_eq!(far["marker"], json!(0.5));
        assert!(far["now"].is_null());
        let expected: Vec<Value> = lane_stops(
            now + 3.0 * 86_400.0 - STRIP_HALF,
            now + 3.0 * 86_400.0 + STRIP_HALF,
            51.51,
            -0.13,
            20.0,
        )
        .into_iter()
        .map(|(at, color)| json!({"at": at, "color": color}))
        .collect();
        assert_eq!(
            far["stops"],
            json!(expected),
            "超过 12 小时：那一刻前后 12 小时的天"
        );
        // 正午的伦敦是白天，午夜不是。
        let noon = 1_789_992_000.0;
        assert_eq!(at(noon)["dayHere"], json!(true));
        assert_eq!(at(noon + 12.0 * 3600.0)["dayHere"], json!(false));
    }

    /// 没有本机坐标：不给色标、不猜昼夜，位置照给；1800–2100 以外与非有限值报错，不画半条带。
    #[test]
    fn the_strip_without_a_place_or_outside_the_years() {
        let now = 1_790_000_000.0;
        let bare = dispatch("sky.strip", json!({"now": now, "instant": now + 3600.0})).unwrap();
        assert_eq!(bare["stops"], json!([]));
        assert!(bare["dayHere"].is_null());
        assert!((bare["marker"].as_f64().unwrap() - (0.5 + 1.0 / 24.0)).abs() < 1e-12);
        assert!(dispatch(
            "sky.strip",
            json!({"now": now, "instant": 4_200_000_000.0, "latitude": 0.0, "longitude": 0.0})
        )
        .is_err());
        assert!(
            dispatch(
                "sky.strip",
                json!({"now": now, "instant": -5_364_662_400.0, "latitude": 0.0, "longitude": 0.0})
            )
            .is_err(),
            "1800 年元旦往前 12 小时已出范围"
        );
        assert!(dispatch("sky.strip", json!({"now": now})).is_err());
    }

    /// 「不使用颜色区分」：带上的昼夜边界与 `daylight_bands` 一一对应（伦敦这一天：日出日落两道全高、晨光始昏影终两道半高）。
    #[test]
    fn the_strip_marks_day_and_night_boundaries_when_asked() {
        let now = 1_789_646_400.0; // 2026-09-17 12:00 UTC
        let value = dispatch("sky.strip", json!({"now": now, "instant": now, "latitude": 51.507, "longitude": -0.128, "marks": true})).unwrap();
        let marks = value["marks"].as_array().unwrap();
        let bands =
            crate::astronomy::daylight_bands(now - STRIP_HALF, now + STRIP_HALF, 51.507, -0.128);
        assert_eq!(marks.len(), bands.len() - 1);
        assert_eq!(marks.iter().filter(|m| m["full"] == true).count(), 2);
        assert_eq!(marks.iter().filter(|m| m["full"] == false).count(), 2);
        for (mark, pair) in marks.iter().zip(bands.windows(2)) {
            let want = (pair[0].1 - (now - STRIP_HALF)) / (2.0 * STRIP_HALF);
            assert!((mark["at"].as_f64().unwrap() - want).abs() < 1e-12);
        }
    }

    /// 换算页的共同时间轴：每条的天与同一框、同一地方的昼夜条（`sky.lane`）逐个色标相同；三段首尾相接铺满 0…1，
    /// 正午在昼、子夜在夜（伦敦与东京，同一个本机当天）；刻度只在要时给，与 `daylight_bands` 一一对应；没有坐标的那条三样都空。
    #[test]
    fn the_converter_lanes_share_one_frame_and_match_the_day_lanes() {
        let start = 1_789_628_400.0; // 2026-09-17 00:00 洛杉矶（UTC−7）
        let end = start + 86_400.0;
        let places = json!([{"latitude": 51.507, "longitude": -0.128}, {"latitude": 35.68, "longitude": 139.69}, {}]);
        let value = dispatch(
            "sky.lanes",
            json!({"start": start, "end": end, "places": places, "marks": true}),
        )
        .unwrap();
        let lanes = value["lanes"].as_array().unwrap();
        assert_eq!(lanes.len(), 3);
        for (lane, (lat, lon)) in lanes.iter().zip([(51.507, -0.128), (35.68, 139.69)]) {
            let alone = dispatch(
                "sky.lane",
                json!({"start": start, "end": end, "latitude": lat, "longitude": lon}),
            )
            .unwrap();
            assert_eq!(lane["stops"], alone["stops"]);
            let parts = lane["bands"].as_array().unwrap();
            assert_eq!(parts.first().unwrap()["from"], json!(0.0));
            assert!((parts.last().unwrap()["to"].as_f64().unwrap() - 1.0).abs() < 1e-12);
            for pair in parts.windows(2) {
                assert!(
                    (pair[0]["to"].as_f64().unwrap() - pair[1]["from"].as_f64().unwrap()).abs()
                        < 1e-12
                );
                assert_ne!(pair[0]["kind"], pair[1]["kind"]);
            }
            let kind_at = |instant: f64| {
                let at = (instant - start) / 86_400.0;
                parts
                    .iter()
                    .find(|p| p["from"].as_f64().unwrap() <= at && at < p["to"].as_f64().unwrap())
                    .unwrap()["kind"]
                    .as_u64()
                    .unwrap()
            };
            // 当地正午在昼、当地子夜在夜（经度粗算的当地时，离日出日落都很远）。
            let solar_noon = 1_789_646_400.0 - lon / 15.0 * 3600.0; // 9 月 17 日 12:00 UTC 挪到当地正午
            let noon = if solar_noon < start {
                solar_noon + 86_400.0
            } else if solar_noon >= end {
                solar_noon - 86_400.0
            } else {
                solar_noon
            };
            let midnight = if noon - 43_200.0 >= start {
                noon - 43_200.0
            } else {
                noon + 43_200.0
            };
            assert_eq!(kind_at(noon), 2, "{lat},{lon} noon");
            assert_eq!(kind_at(midnight), 0, "{lat},{lon} midnight");
            let bands = crate::astronomy::daylight_bands(start, end, lat, lon);
            assert_eq!(lane["marks"].as_array().unwrap().len(), bands.len() - 1);
        }
        assert_eq!(lanes[2], json!({"stops": [], "bands": [], "marks": []}));
        let quiet = dispatch("sky.lanes", json!({"start": start, "end": end, "places": [{"latitude": 51.507, "longitude": -0.128}]})).unwrap();
        assert!(quiet["lanes"][0]["marks"].as_array().unwrap().is_empty());
        // 坏输入报错不崩：框倒着、太长、越界、地点太多、坐标出界（出界的那条当作没有坐标）。
        for bad in [
            json!({"start": end, "end": start, "places": []}),
            json!({"start": start, "end": start + 3.0 * 86_400.0, "places": []}),
            json!({"start": 4_200_000_000.0, "end": 4_200_086_400.0, "places": []}),
            json!({"start": start, "end": end, "places": vec![json!({}); LANES_MAX + 1]}),
            json!({"start": start, "end": end}),
        ] {
            assert!(dispatch("sky.lanes", bad.clone()).is_err(), "{bad}");
        }
        let outside = dispatch(
            "sky.lanes",
            json!({"start": start, "end": end, "places": [{"latitude": 95.0, "longitude": 0.0}]}),
        )
        .unwrap();
        assert_eq!(
            outside["lanes"][0],
            json!({"stops": [], "bands": [], "marks": []})
        );
    }

    /// 地平线的墨与纸：白天的天上是墨、深夜的天上是纸，每一段都是对它更清楚的那一个。
    #[test]
    fn the_horizon_line_reads_on_every_part_of_the_sky() {
        let start = 1_789_603_200.0; // 2026-09-17 00:00 UTC
        let stops = line_stops(start, start + 86_400.0, 51.507, -0.128, 10.0);
        assert_eq!(stops.len(), 145);
        assert_eq!(stops[0].1, hex(PAPER), "伦敦午夜：纸线");
        assert_eq!(stops[72].1, hex(INK), "伦敦正午：墨线");
        for (k, (_, color)) in stops.iter().enumerate() {
            let t = start + 600.0 * k as f64;
            let mid = sky(astronomy::elevation(t, 51.507, -0.128), rising(t, -0.128)).mid;
            let (ink, paper) = (contrast(INK, mid), contrast(PAPER, mid));
            assert_eq!(
                color,
                &hex(if ink >= paper { INK } else { PAPER }),
                "stop {k}"
            );
            assert!(
                ink.max(paper) >= 3.0,
                "stop {k}: 非文字对比度 {}",
                ink.max(paper)
            );
        }
    }

    fn divider_places() -> Vec<Value> {
        vec![
            json!({"latitude": 35.690, "longitude": 139.692, "utcOffset": 32400.0}),
            json!({"latitude": 37.566, "longitude": 126.978, "utcOffset": 32400.0}),
            json!({"latitude": 51.507, "longitude": -0.128, "utcOffset": 3600.0}),
            json!({"latitude": 48.857, "longitude": 2.352, "utcOffset": 7200.0}),
        ]
    }

    // 从输出的屏幕颜色独立换算，不调用生产颜色函数。
    fn divider_hex_lab(value: &Value) -> [f64; 3] {
        let color = value.as_str().unwrap();
        assert_eq!(color.len(), 7);
        assert!(color.starts_with('#'));
        let rgb = u32::from_str_radix(&color[1..], 16).unwrap();
        let [r, g, b] = [16, 8, 0].map(|shift| {
            let v = f64::from((rgb >> shift) & 255) / 255.0;
            if v <= 0.04045 {
                v / 12.92
            } else {
                ((v + 0.055) / 1.055).powf(2.4)
            }
        });
        let l = (0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b).cbrt();
        let m = (0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b).cbrt();
        let s = (0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b).cbrt();
        [
            0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
        ]
    }

    fn divider_hex_distance(a: &Value, b: &Value) -> f64 {
        let (a, b) = (divider_hex_lab(a), divider_hex_lab(b));
        a.into_iter()
            .zip(b)
            .map(|(a, b)| (a - b).powi(2))
            .sum::<f64>()
            .sqrt()
    }

    fn divider_edges(value: &Value, flat: bool) -> Vec<(&Value, &Value, f64)> {
        let mut above = &value["chrome"]["top"];
        value["rows"]
            .as_array()
            .unwrap()
            .iter()
            .map(|row| {
                let colors = &row["colors"];
                let gradient = row["gradient"].as_bool().unwrap() && !flat;
                let top = &colors[if gradient { "top" } else { "mid" }];
                let bottom = &colors[if gradient { "horizon" } else { "mid" }];
                let edge = (above, top, divider_hex_distance(above, top));
                above = bottom;
                edge
            })
            .collect()
    }

    #[test]
    fn dividers_only_where_rows_would_merge() {
        let instant = 1_789_646_400.0;
        let places = divider_places();
        let mut input =
            json!({"instant": instant, "now": instant, "home": places[2], "places": places});
        let value = dispatch("sky.panel", input.clone()).unwrap();
        let edges = divider_edges(&value, false);
        assert_eq!(
            value["dividers"],
            json!([false, true, false, true]),
            "edges and distances: {edges:?}"
        );
        for places in [json!([]), json!([{"utcOffset": 0.0}])] {
            input["places"] = places;
            let value = dispatch("sky.panel", input.clone()).unwrap();
            assert_eq!(
                value["dividers"].as_array().unwrap().len(),
                value["rows"].as_array().unwrap().len()
            );
        }

        // 两行同处黄昏：渐变两端不同，平涂的整体颜色相同。
        input["instant"] = json!(1_789_669_800.0);
        input["now"] = input["instant"].clone();
        input["places"] = json!([input["home"], input["home"]]);
        let gradient = dispatch("sky.panel", input.clone()).unwrap();
        assert_eq!(gradient["rows"][0]["gradient"], json!(true));
        assert_eq!(gradient["rows"][1]["gradient"], json!(true));
        assert!(divider_edges(&gradient, false)[1].2 >= 0.06);
        assert_eq!(gradient["dividers"][1], json!(false));
        input["flat"] = json!(true);
        let flat = dispatch("sky.panel", input).unwrap();
        assert_eq!(flat["rows"], gradient["rows"]);
        assert_eq!(divider_edges(&flat, true)[1].2, 0.0);
        assert_eq!(flat["dividers"][1], json!(true));
    }

    #[test]
    fn dividers_follow_the_distance_rule() {
        let places = divider_places();
        let mut state = 0x5eed_2026_u64;
        let mut next = || {
            state = state
                .wrapping_mul(6_364_136_223_846_793_005)
                .wrapping_add(1);
            state >> 32
        };
        let mut changed_by_flat = 0;
        for sample in 0..200 {
            let instant = 1_767_225_600.0 + (next() % 31_536_000) as f64;
            let mut shuffled = places.clone();
            for i in (1..shuffled.len()).rev() {
                shuffled.swap(i, (next() % (i + 1) as u64) as usize);
            }
            for need in [5.5, 7.0] {
                let mut normal = Vec::new();
                for flat in [false, true] {
                    let value = dispatch("sky.panel", json!({
                        "instant": instant, "now": instant, "home": places[2], "places": shuffled, "need": need, "flat": flat,
                    })).unwrap();
                    let dividers = value["dividers"].as_array().unwrap();
                    assert_eq!(dividers.len(), value["rows"].as_array().unwrap().len());
                    let edges = divider_edges(&value, flat);
                    let expected: Vec<bool> = edges.iter().map(|edge| edge.2 < 0.06).collect();
                    assert_eq!(
                        value["dividers"],
                        json!(expected),
                        "sample {sample} instant {instant} need {need} flat {flat}: {edges:?}"
                    );
                    if flat {
                        changed_by_flat += usize::from(expected != normal);
                    } else {
                        normal = expected;
                    }
                }
            }
        }
        assert!(changed_by_flat > 0);
    }

    #[test]
    fn lane_stops_span_the_frame() {
        let value = dispatch("sky.lane", json!({"start": 1_790_000_000.0, "end": 1_790_086_400.0, "latitude": 35.68, "longitude": 139.69})).unwrap();
        let stops = value["stops"].as_array().unwrap();
        assert_eq!(stops.len(), 145);
        assert_eq!(stops[0]["at"], json!(0.0));
        assert_eq!(stops[144]["at"], json!(1.0));
        assert!(dispatch(
            "sky.lane",
            json!({"start": 1.0, "end": 0.0, "latitude": 0.0, "longitude": 0.0})
        )
        .is_err());
    }

    /// 出图耗时（Release 下跑：`cargo test --release --lib sky::tests::raster_timing -- --ignored --nocapture`）。
    #[test]
    #[ignore]
    fn raster_timing() {
        let _guard = RELIEF_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let (rw, rh) = (1800_usize, 690_usize);
        let gray: Vec<u8> = (0..rw * rh)
            .map(|i| {
                if (i % rw) * 2 < rw {
                    95
                } else {
                    170 + (i % 37) as u8
                }
            })
            .collect();
        let built = std::time::Instant::now();
        unsafe {
            assert!(mt_sky_relief_set(
                gray.as_ptr(),
                rw as u32,
                rh as u32,
                80.0,
                -58.0
            ));
        }
        println!("terrain {rw}x{rh}: {:?}", built.elapsed());
        for &(w, h) in &[(592_usize, 227_usize), (640, 246), (1800, 690), (2176, 836)] {
            let mut buffer = vec![0_u8; w * h * 4];
            let first = std::time::Instant::now();
            assert!(raster(
                1_790_000_000.0,
                w,
                h,
                80.0,
                -58.0,
                1.15,
                &mut buffer
            ));
            let cold = first.elapsed();
            let warm_start = std::time::Instant::now();
            for k in 0..20 {
                assert!(raster(
                    1_790_000_000.0 + f64::from(k) * 60.0,
                    w,
                    h,
                    80.0,
                    -58.0,
                    1.15,
                    &mut buffer
                ));
            }
            let lit = warm_start.elapsed() / 20;
            let dark_start = std::time::Instant::now();
            for k in 0..20 {
                assert!(raster(
                    1_790_000_000.0 + f64::from(k) * 60.0,
                    w,
                    h,
                    80.0,
                    -58.0,
                    0.0,
                    &mut buffer
                ));
            }
            let dark = dark_start.elapsed() / 20;
            let marks_start = std::time::Instant::now();
            for k in 0..20 {
                let marks = Some(Marks {
                    ppp: 2.0,
                    large: w > 1000,
                });
                assert!(raster_into(
                    1_782_030_240.0 + f64::from(k) * 60.0,
                    w,
                    h,
                    80.0,
                    -58.0,
                    1.15,
                    &mut buffer,
                    Layout::tight(w),
                    marks
                ));
            }
            println!("{w}x{h}: first {cold:?} (with terrain grid), then {lit:?} per frame ({dark:?} without city lights, {:?} with lights, terminator and sun glow at the solstice)",
                     marks_start.elapsed() / 20);
        }
        mt_sky_relief_release();
    }

    /// 收方打开名片看到的网页（`site/when.html`）里有这几样算法的一份 JavaScript：太阳高度、那边此刻的天
    /// （面板行同一种：天顶、地平线、整体色、写墨还是写纸、要不要画渐变）、一天的天色色标（每 10 分钟一个）。
    /// 两边用同一份夹具钉住：这里核夹具就是 Rust 算出来的，`Tools/site_tests/when_test.mjs` 核网页算出来的与夹具相差不过
    /// 每个通道 1（两边的三角函数最后一位可能不同）。改了天色或太阳，用 `MEANTIME_WRITE_SKY_FIXTURE=1` 跑这一条重出夹具，网页那份跟着改。
    #[test]
    fn browser_sky_fixture_is_what_rust_computes() {
        // 2026-10-02T00:00Z = 1_790_899_200；东京 UTC+9 没有夏令时，那一天从 15:00Z 开始。
        let panel_cases = [
            (35.7, 139.7, 1_790_973_000.0),  // 东京 5:30 破晓
            (35.7, 139.7, 1_790_996_400.0),  // 东京 12:00
            (35.7, 139.7, 1_791_016_200.0),  // 东京 17:30 黄昏
            (35.7, 139.7, 1_791_035_000.0),  // 东京 22:43 夜
            (51.5, -0.1, 1_790_921_700.0),   // 伦敦 7:15
            (-33.9, 151.2, 1_790_906_400.0), // 悉尼正午（南半球）
            (69.6, 19.0, 1_797_850_800.0),   // 特罗姆瑟冬至正午（极夜）
            (-0.2, -78.5, 1_790_983_200.0),  // 基多 18:20
        ];
        let panel: Vec<Value> = panel_cases
            .iter()
            .map(|&(latitude, longitude, instant)| {
                let altitude = astronomy::elevation(instant, latitude, longitude);
                let is_rising = rising(instant, longitude);
                let colors = readable(&sky(altitude, is_rising), 5.5);
                json!({"latitude": latitude, "longitude": longitude, "instant": instant,
                       "altitude": (altitude * 1000.0).round() / 1000.0, "rising": is_rising,
                       "top": hex(colors.top), "horizon": hex(colors.horizon), "mid": hex(colors.mid), "ink": colors.ink,
                       "gradient": altitude > -10.0 && altitude < 8.0})
            })
            .collect();
        let lane_cases = [(35.7, 139.7, 1_790_953_200.0), (69.6, 19.0, 1_797_807_600.0)];
        let lanes: Vec<Value> = lane_cases
            .iter()
            .map(|&(latitude, longitude, start)| {
                let stops: Vec<String> = lane_stops(start, start + 86_400.0, latitude, longitude, 10.0).into_iter().map(|(_, c)| c).collect();
                json!({"latitude": latitude, "longitude": longitude, "start": start, "end": start + 86_400.0, "stops": stops})
            })
            .collect();
        let computed = json!({"panel": panel, "lanes": lanes});
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../Tools/site_tests/sky_fixture.json");
        if std::env::var("MEANTIME_WRITE_SKY_FIXTURE").is_ok() {
            std::fs::write(path, serde_json::to_string_pretty(&computed).unwrap() + "\n").unwrap();
        }
        let fixture: Value = serde_json::from_str(&std::fs::read_to_string(path).expect("夹具不在：先用 MEANTIME_WRITE_SKY_FIXTURE=1 出一份")).unwrap();
        assert_eq!(fixture, computed, "网页那份天色夹具与 Rust 对不上：重出夹具并同步改 site/when.html");
    }
}
