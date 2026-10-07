// SPDX-License-Identifier: GPL-3.0-only
//! QR 码编码器（ISO/IEC 18004，字节模式，纠错 M，版本 1–40）。
//!
//! 为什么自己写：分享页的二维码此前交给 CoreImage 的 `CIQRCodeGenerator`，
//! 而 `CIContext` 即便声明软件渲染也会把 Metal 起起来，页面首帧多出 ~17 MB 图形缓冲，
//! 主程序还因此链着整个 CoreImage。二维码是纯算法，按本仓的分工归 Rust；Swift 只把 0/1 矩阵
//! 用 CoreGraphics 画成位图。
//!
//! 只做名片需要的一种：字节模式（payload 是 base64url 名片或 https 链接，都是字节）、纠错等级 M
//! （与此前 CoreImage 的 `inputCorrectionLevel = "M"` 相同，扫码端行为不变）、版本按内容取最小能装下的。
//! 掩码按规范四条罚分挑最优。判据在 Swift 侧：Vision 把每个版本的码解回原文（`SharingQRCodeTests`）。
//!
//! 表只有两张（各版本的纠错分块、对齐图案中心），其余（总码字数、数据码字数）从版面自己数出来，
//! 测试里再用「分块之和 = 版面数出来的总码字」逐版本互证，表抄错一格就会被抓住。

use serde_json::{json, Value};

/// 每个版本纠错等级 M 的分块：(每块纠错码字数, 第一组块数, 第一组每块数据码字, 第二组块数, 第二组每块数据码字)。
const EC_BLOCKS_M: [(usize, usize, usize, usize, usize); 40] = [
    (10, 1, 16, 0, 0),
    (16, 1, 28, 0, 0),
    (26, 1, 44, 0, 0),
    (18, 2, 32, 0, 0),
    (24, 2, 43, 0, 0),
    (16, 4, 27, 0, 0),
    (18, 4, 31, 0, 0),
    (22, 2, 38, 2, 39),
    (22, 3, 36, 2, 37),
    (26, 4, 43, 1, 44),
    (30, 1, 50, 4, 51),
    (22, 6, 36, 2, 37),
    (22, 8, 37, 1, 38),
    (24, 4, 40, 5, 41),
    (24, 5, 41, 5, 42),
    (28, 7, 45, 3, 46),
    (28, 10, 46, 1, 47),
    (26, 9, 43, 4, 44),
    (26, 3, 44, 11, 45),
    (26, 3, 41, 13, 42),
    (26, 17, 42, 0, 0),
    (28, 17, 46, 0, 0),
    (28, 4, 47, 14, 48),
    (28, 6, 45, 14, 46),
    (28, 8, 47, 13, 48),
    (28, 19, 46, 4, 47),
    (28, 22, 45, 3, 46),
    (28, 3, 45, 23, 46),
    (28, 21, 45, 7, 46),
    (28, 19, 47, 10, 48),
    (28, 2, 46, 29, 47),
    (28, 10, 46, 23, 47),
    (28, 14, 46, 21, 47),
    (28, 14, 46, 23, 47),
    (28, 12, 47, 26, 48),
    (28, 6, 47, 34, 48),
    (28, 29, 46, 14, 47),
    (28, 13, 46, 32, 47),
    (28, 40, 47, 7, 48),
    (28, 18, 47, 31, 48),
];

/// 对齐图案中心坐标（版本 2 起；版本 1 没有）。
const ALIGNMENT: [&[usize]; 40] = [
    &[],
    &[6, 18],
    &[6, 22],
    &[6, 26],
    &[6, 30],
    &[6, 34],
    &[6, 22, 38],
    &[6, 24, 42],
    &[6, 26, 46],
    &[6, 28, 50],
    &[6, 30, 54],
    &[6, 32, 58],
    &[6, 34, 62],
    &[6, 26, 46, 66],
    &[6, 26, 48, 70],
    &[6, 26, 50, 74],
    &[6, 30, 54, 78],
    &[6, 30, 56, 82],
    &[6, 30, 58, 86],
    &[6, 34, 62, 90],
    &[6, 28, 50, 72, 94],
    &[6, 26, 50, 74, 98],
    &[6, 30, 54, 78, 102],
    &[6, 28, 54, 80, 106],
    &[6, 32, 58, 84, 110],
    &[6, 30, 58, 86, 114],
    &[6, 34, 62, 90, 118],
    &[6, 26, 50, 74, 98, 122],
    &[6, 30, 54, 78, 102, 126],
    &[6, 26, 52, 78, 104, 130],
    &[6, 30, 56, 82, 108, 134],
    &[6, 34, 60, 86, 112, 138],
    &[6, 30, 58, 86, 114, 142],
    &[6, 34, 62, 90, 118, 146],
    &[6, 30, 54, 78, 102, 126, 150],
    &[6, 24, 50, 76, 102, 128, 154],
    &[6, 28, 54, 80, 106, 132, 158],
    &[6, 32, 58, 84, 110, 136, 162],
    &[6, 26, 54, 82, 110, 138, 166],
    &[6, 30, 58, 86, 114, 142, 170],
];

/// 版面：`modules` 是 0/1，`function` 标记哪些格是功能图案或预留位（数据不能放）。
struct Grid {
    size: usize,
    modules: Vec<u8>,
    function: Vec<bool>,
}

impl Grid {
    fn new(version: usize) -> Self {
        let size = version * 4 + 17;
        Self { size, modules: vec![0; size * size], function: vec![false; size * size] }
    }
    fn set(&mut self, x: usize, y: usize, dark: bool) {
        self.modules[y * self.size + x] = u8::from(dark);
    }
    fn get(&self, x: usize, y: usize) -> u8 {
        self.modules[y * self.size + x]
    }
    fn set_function(&mut self, x: usize, y: usize, dark: bool) {
        self.set(x, y, dark);
        self.function[y * self.size + x] = true;
    }
    fn is_function(&self, x: usize, y: usize) -> bool {
        self.function[y * self.size + x]
    }
}

fn place_finder(grid: &mut Grid, x0: usize, y0: usize) {
    for dy in 0..7 {
        for dx in 0..7 {
            let ring = dx == 0 || dx == 6 || dy == 0 || dy == 6;
            let core = (2..=4).contains(&dx) && (2..=4).contains(&dy);
            grid.set_function(x0 + dx, y0 + dy, ring || core);
        }
    }
}

/// 功能图案与预留区：定位图案（含分隔）、定时图案、对齐图案、暗模块、格式信息位、版本信息位。
fn place_function_patterns(grid: &mut Grid, version: usize) {
    let size = grid.size;
    place_finder(grid, 0, 0);
    place_finder(grid, size - 7, 0);
    place_finder(grid, 0, size - 7);
    // 分隔（定位图案外一圈亮模块）。
    for i in 0..8 {
        grid.set_function(7, i, false);
        grid.set_function(i, 7, false);
        grid.set_function(size - 8, i, false);
        grid.set_function(size - 8 + i, 7, false);
        grid.set_function(7, size - 8 + i, false);
        grid.set_function(i, size - 8, false);
    }
    // 定时图案。
    for i in 8..size - 8 {
        let dark = i % 2 == 0;
        grid.set_function(i, 6, dark);
        grid.set_function(6, i, dark);
    }
    // 对齐图案：与定位图案重叠的三个角不放。
    let centers = ALIGNMENT[version - 1];
    for &cy in centers {
        for &cx in centers {
            let overlaps_finder = (cx <= 8 && cy <= 8) || (cx >= size - 9 && cy <= 8) || (cx <= 8 && cy >= size - 9);
            if overlaps_finder {
                continue;
            }
            for dy in 0..5 {
                for dx in 0..5 {
                    let ring = dx == 0 || dx == 4 || dy == 0 || dy == 4;
                    grid.set_function(cx - 2 + dx, cy - 2 + dy, ring || (dx == 2 && dy == 2));
                }
            }
        }
    }
    // 格式信息预留（两处），先填亮；暗模块固定为暗。
    for i in 0..9 {
        if i != 6 {
            grid.set_function(8, i, false);
            grid.set_function(i, 8, false);
        }
    }
    for i in 0..8 {
        grid.set_function(size - 1 - i, 8, false);
        grid.set_function(8, size - 1 - i, false);
    }
    grid.set_function(8, size - 8, true);
    // 版本信息预留（版本 7 起，两处 6×3）。
    if version >= 7 {
        for i in 0..6 {
            for j in 0..3 {
                grid.set_function(i, size - 11 + j, false);
                grid.set_function(size - 11 + j, i, false);
            }
        }
    }
}

/// 版面里能放数据的格子数 ÷ 8 = 总码字数（规范表由此而来，这里不抄表）。
fn total_codewords(version: usize) -> usize {
    let mut grid = Grid::new(version);
    place_function_patterns(&mut grid, version);
    grid.function.iter().filter(|f| !**f).count() / 8
}

fn data_codewords(version: usize) -> usize {
    let (ec, g1, d1, g2, d2) = EC_BLOCKS_M[version - 1];
    let _ = ec;
    g1 * d1 + g2 * d2
}

/// 字节模式在该版本能装下的字节数：4 位模式 + 计数位 + 8 位/字节，末尾不必留终止符。
fn capacity_bytes(version: usize) -> usize {
    let bits = data_codewords(version) * 8;
    let count_bits = if version <= 9 { 8 } else { 16 };
    (bits - 4 - count_bits) / 8
}

/// 选最小能装下的版本。
fn version_for(len: usize) -> Option<usize> {
    (1..=40).find(|&v| capacity_bytes(v) >= len)
}

// ---- GF(256) 与 Reed–Solomon（本原多项式 0x11D）----

fn gf_tables() -> ([u8; 256], [u8; 512]) {
    let mut log = [0u8; 256];
    let mut exp = [0u8; 512];
    let mut x: u16 = 1;
    for (i, slot) in exp.iter_mut().enumerate().take(255) {
        *slot = x as u8;
        log[x as usize] = i as u8;
        x <<= 1;
        if x & 0x100 != 0 {
            x ^= 0x11D;
        }
    }
    for i in 255..512 {
        exp[i] = exp[i - 255];
    }
    (log, exp)
}

fn gf_mul(a: u8, b: u8, log: &[u8; 256], exp: &[u8; 512]) -> u8 {
    if a == 0 || b == 0 {
        0
    } else {
        exp[log[a as usize] as usize + log[b as usize] as usize]
    }
}

/// 生成多项式 (x − α^0)(x − α^1)…(x − α^{n−1}) 的系数，首项为 1。
fn generator(ec_len: usize, log: &[u8; 256], exp: &[u8; 512]) -> Vec<u8> {
    let mut g = vec![1u8];
    for i in 0..ec_len {
        let mut next = vec![0u8; g.len() + 1];
        for (j, &coef) in g.iter().enumerate() {
            next[j] ^= coef;
            next[j + 1] ^= gf_mul(coef, exp[i], log, exp);
        }
        g = next;
    }
    g
}

fn rs_remainder(data: &[u8], ec_len: usize, log: &[u8; 256], exp: &[u8; 512]) -> Vec<u8> {
    let g = generator(ec_len, log, exp);
    let mut rem = vec![0u8; ec_len];
    for &byte in data {
        let factor = byte ^ rem[0];
        rem.rotate_left(1);
        rem[ec_len - 1] = 0;
        if factor != 0 {
            for (i, &gc) in g[1..].iter().enumerate() {
                rem[i] ^= gf_mul(gc, factor, log, exp);
            }
        }
    }
    rem
}

/// 数据位流 → 分块 → 纠错 → 交错成最终码字序列。
fn codewords(version: usize, payload: &[u8]) -> Vec<u8> {
    let data_len = data_codewords(version);
    let mut bits: Vec<u8> = Vec::with_capacity(data_len * 8);
    let push = |value: u32, count: usize, bits: &mut Vec<u8>| {
        for i in (0..count).rev() {
            bits.push(((value >> i) & 1) as u8);
        }
    };
    push(0b0100, 4, &mut bits);
    push(payload.len() as u32, if version <= 9 { 8 } else { 16 }, &mut bits);
    for &b in payload {
        push(u32::from(b), 8, &mut bits);
    }
    let capacity = data_len * 8;
    // 终止符最多 4 个 0，再补到字节边界。
    let terminator = (capacity - bits.len()).min(4);
    let padding = (bits.len() + terminator).div_ceil(8) * 8 - bits.len();
    bits.resize(bits.len() + padding, 0);
    let mut data: Vec<u8> = bits.chunks(8).map(|c| c.iter().fold(0u8, |acc, &b| (acc << 1) | b)).collect();
    let mut pad = [0xEC, 0x11].iter().cycle();
    while data.len() < data_len {
        data.push(*pad.next().unwrap());
    }

    let (ec, g1, d1, g2, d2) = EC_BLOCKS_M[version - 1];
    let (log, exp) = gf_tables();
    let mut blocks: Vec<(Vec<u8>, Vec<u8>)> = Vec::new();
    let mut offset = 0;
    for (count, len) in [(g1, d1), (g2, d2)] {
        for _ in 0..count {
            let chunk = data[offset..offset + len].to_vec();
            offset += len;
            let parity = rs_remainder(&chunk, ec, &log, &exp);
            blocks.push((chunk, parity));
        }
    }
    let max_data = blocks.iter().map(|b| b.0.len()).max().unwrap_or(0);
    let mut out = Vec::with_capacity(total_codewords(version));
    for i in 0..max_data {
        for (chunk, _) in &blocks {
            if let Some(&b) = chunk.get(i) {
                out.push(b);
            }
        }
    }
    for i in 0..ec {
        for (_, parity) in &blocks {
            out.push(parity[i]);
        }
    }
    out
}

/// 按规范的之字形把码字放进版面（从右下开始，两列一组向上、向下交替，跳过第 6 列与功能格）。
fn place_data(grid: &mut Grid, codewords: &[u8]) {
    let size = grid.size;
    let mut bit_index = 0usize;
    let total_bits = codewords.len() * 8;
    let mut upward = true;
    let mut col = size as isize - 1;
    while col > 0 {
        if col == 6 {
            col -= 1;
        }
        for i in 0..size {
            let y = if upward { size - 1 - i } else { i };
            for dx in 0..2 {
                let x = (col - dx) as usize;
                if grid.is_function(x, y) {
                    continue;
                }
                let dark = if bit_index < total_bits {
                    (codewords[bit_index / 8] >> (7 - bit_index % 8)) & 1 == 1
                } else {
                    false // 余位（remainder bits）填亮
                };
                grid.set(x, y, dark);
                bit_index += 1;
            }
        }
        upward = !upward;
        col -= 2;
    }
}

fn mask_bit(mask: u8, x: usize, y: usize) -> bool {
    match mask {
        0 => (x + y) % 2 == 0,
        1 => y % 2 == 0,
        2 => x % 3 == 0,
        3 => (x + y) % 3 == 0,
        4 => (y / 2 + x / 3) % 2 == 0,
        5 => (x * y) % 2 + (x * y) % 3 == 0,
        6 => ((x * y) % 2 + (x * y) % 3) % 2 == 0,
        _ => ((x + y) % 2 + (x * y) % 3) % 2 == 0,
    }
}

fn apply_mask(grid: &mut Grid, mask: u8) {
    for y in 0..grid.size {
        for x in 0..grid.size {
            if !grid.is_function(x, y) && mask_bit(mask, x, y) {
                grid.modules[y * grid.size + x] ^= 1;
            }
        }
    }
}

/// 格式信息：2 位纠错等级（M = 00）+ 3 位掩码，BCH(15,5)，再异或 0x5412。
fn format_bits(mask: u8) -> u32 {
    let data: u32 = u32::from(mask) & 0b111; // 等级 M 的两位是 00
    let mut rem = data;
    for _ in 0..10 {
        rem = (rem << 1) ^ if rem >> 9 & 1 == 1 { 0x537 } else { 0 };
    }
    ((data << 10) | rem) ^ 0x5412
}

fn place_format(grid: &mut Grid, mask: u8) {
    let bits = format_bits(mask);
    let size = grid.size;
    let bit = |i: u32| (bits >> i) & 1 == 1;
    // 左上：沿第 8 列/行，跳过定时图案所在的第 6 格。
    for i in 0..6 {
        grid.set(8, i, bit(i as u32));
    }
    grid.set(8, 7, bit(6));
    grid.set(8, 8, bit(7));
    grid.set(7, 8, bit(8));
    for i in 9..15 {
        grid.set(14 - i, 8, bit(i as u32));
    }
    // 右上与左下。
    for i in 0..8 {
        grid.set(size - 1 - i, 8, bit(i as u32));
    }
    for i in 8..15 {
        grid.set(8, size - 15 + i, bit(i as u32));
    }
}

/// 版本信息（版本 7 起）：6 位版本 + 12 位 Golay 余数。
fn place_version(grid: &mut Grid, version: usize) {
    if version < 7 {
        return;
    }
    let mut rem = version as u32;
    for _ in 0..12 {
        rem = (rem << 1) ^ if rem >> 11 & 1 == 1 { 0x1F25 } else { 0 };
    }
    let bits = ((version as u32) << 12) | rem;
    let size = grid.size;
    for i in 0..18 {
        let dark = (bits >> i) & 1 == 1;
        let (a, b) = (i / 3, size - 11 + i % 3);
        grid.set(a, b, dark);
        grid.set(b, a, dark);
    }
}

/// 规范的四条罚分：连续同色 ≥5、2×2 同色块、1:1:3:1:1 定位样式、暗模块比例偏离 50%。
fn penalty(grid: &Grid) -> u32 {
    let n = grid.size;
    let mut score = 0u32;
    // 规则 1：行与列里连续 5 个以上同色。
    for line in 0..n {
        for (mut run, mut prev, axis) in [(0u32, 2u8, 0), (0u32, 2u8, 1)] {
            for i in 0..n {
                let v = if axis == 0 { grid.get(i, line) } else { grid.get(line, i) };
                if v == prev {
                    run += 1;
                    if run == 5 {
                        score += 3;
                    } else if run > 5 {
                        score += 1;
                    }
                } else {
                    prev = v;
                    run = 1;
                }
            }
        }
    }
    // 规则 2：2×2 同色块。
    for y in 0..n - 1 {
        for x in 0..n - 1 {
            let v = grid.get(x, y);
            if v == grid.get(x + 1, y) && v == grid.get(x, y + 1) && v == grid.get(x + 1, y + 1) {
                score += 3;
            }
        }
    }
    // 规则 3：1:1:3:1:1 样式，两侧任一边接 4 个亮模块。
    let pattern = [1u8, 0, 1, 1, 1, 0, 1];
    for line in 0..n {
        for axis in 0..2 {
            let get = |i: usize| if axis == 0 { grid.get(i, line) } else { grid.get(line, i) };
            for start in 0..n.saturating_sub(6) {
                if (0..7).all(|k| get(start + k) == pattern[k]) {
                    let before = start >= 4 && (1..=4).all(|k| get(start - k) == 0);
                    let after = start + 10 < n && (7..11).all(|k| get(start + k) == 0);
                    if before || after {
                        score += 40;
                    }
                }
            }
        }
    }
    // 规则 4：暗模块比例每偏离 50% 5 个百分点记 10 分。
    let dark = grid.modules.iter().filter(|&&m| m == 1).count();
    let percent = dark * 100 / (n * n);
    let low = (percent / 5) * 5;
    let high = low + 5;
    let deviation = (low.abs_diff(50) / 5).min(high.abs_diff(50) / 5);
    score += deviation as u32 * 10;
    score
}

pub struct Code {
    pub version: usize,
    pub size: usize,
    /// 逐行，1 = 暗。
    pub rows: Vec<Vec<u8>>,
}

pub fn encode(payload: &[u8]) -> Result<Code, &'static str> {
    if payload.is_empty() {
        return Err("empty");
    }
    let version = version_for(payload.len()).ok_or("tooLong")?;
    let words = codewords(version, payload);
    let mut best: Option<(u32, Grid)> = None;
    for mask in 0..8u8 {
        let mut grid = Grid::new(version);
        place_function_patterns(&mut grid, version);
        place_data(&mut grid, &words);
        apply_mask(&mut grid, mask);
        place_format(&mut grid, mask);
        place_version(&mut grid, version);
        let score = penalty(&grid);
        if best.as_ref().is_none_or(|(s, _)| score < *s) {
            best = Some((score, grid));
        }
    }
    let (_, grid) = best.ok_or("internal")?;
    let rows = (0..grid.size).map(|y| grid.modules[y * grid.size..(y + 1) * grid.size].to_vec()).collect();
    Ok(Code { version, size: grid.size, rows })
}

pub fn dispatch(operation: &str, input: Value) -> Result<Value, String> {
    match operation {
        "qr.encode" => {
            let text = input["text"].as_str().unwrap_or_default();
            if text.len() > 2_000 {
                return Ok(json!({"error": "tooLong", "size": 0, "rows": []}));
            }
            match encode(text.as_bytes()) {
                Ok(code) => Ok(json!({"error": Value::Null, "version": code.version, "size": code.size,
                    "rows": code.rows.iter().map(|r| r.iter().map(|b| if *b == 1 { '1' } else { '0' }).collect::<String>()).collect::<Vec<_>>()})),
                Err(e) => Ok(json!({"error": e, "size": 0, "rows": []})),
            }
        }
        // 各版本能装的字节数（测试用它给每个版本造刚好装满的负载，再交 Vision 解回来）。
        "qr.capacities" => Ok(json!((1..=40).map(capacity_bytes).collect::<Vec<_>>())),
        _ => Err(format!("Unknown qr operation: {operation}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 两张表互证：每个版本「分块数据 + 纠错」之和必须等于版面自己数出来的总码字数。表抄错一格就在这里炸。
    #[test]
    fn block_tables_agree_with_the_layout_for_every_version() {
        for version in 1..=40 {
            let (ec, g1, d1, g2, d2) = EC_BLOCKS_M[version - 1];
            let from_table = g1 * (d1 + ec) + g2 * (d2 + ec);
            assert_eq!(from_table, total_codewords(version), "版本 {version}");
            // 第二组每块数据码字总比第一组多 1，且第二组存在时第一组不为空。
            if g2 > 0 {
                assert_eq!(d2, d1 + 1, "版本 {version}");
                assert!(g1 > 0);
            }
        }
        // 版本 1 的经典数字：26 个码字，M 级 16 数据 + 10 纠错。
        assert_eq!(total_codewords(1), 26);
        assert_eq!(capacity_bytes(1), 14);
        assert_eq!(capacity_bytes(40), 2331);
    }

    #[test]
    fn alignment_centers_are_within_the_grid_and_symmetric() {
        for version in 2..=40 {
            let size = version * 4 + 17;
            let centers = ALIGNMENT[version - 1];
            assert_eq!(centers[0], 6);
            assert_eq!(*centers.last().unwrap(), size - 7, "版本 {version} 最后一个中心该在 size−7");
            assert!(centers.windows(2).all(|w| w[1] > w[0]));
        }
    }

    /// Reed–Solomon 用规范附录的例子核：版本 1-M 的「HELLO WORLD」不方便，用 ISO 18004 附录 I 的 1-M 数据
    /// 「01234567」（数字模式）不适用字节模式；这里退而核最基本的性质：余式长度正确、全零数据余式全零、
    /// 生成多项式对 ec=10 的已知系数（规范表：α^251, α^67, α^46, α^61, α^118, α^70, α^64, α^94, α^32, α^45）。
    #[test]
    fn reed_solomon_generator_matches_the_standard_table_for_ten_ec_codewords() {
        let (log, exp) = gf_tables();
        let g = generator(10, &log, &exp);
        let expected_exponents = [0u8, 251, 67, 46, 61, 118, 70, 64, 94, 32, 45];
        let got: Vec<u8> = g.iter().map(|&c| log[c as usize]).collect();
        assert_eq!(got, expected_exponents);
        assert_eq!(rs_remainder(&[0; 16], 10, &log, &exp), vec![0; 10]);
    }

    #[test]
    fn format_bits_match_the_standard_examples() {
        // 规范附录：等级 M、掩码 5 的格式信息是 0x40CE；等级 M 掩码 0 是 0x5412（数据 0 只剩掩码常量）。
        assert_eq!(format_bits(5), 0x40CE);
        assert_eq!(format_bits(0), 0x5412);
    }

    #[test]
    fn encoding_picks_the_smallest_version_and_produces_a_square_with_finders() {
        let code = encode(b"DS1.hello").unwrap();
        assert_eq!(code.version, 1);
        assert_eq!(code.size, 21);
        // 三个定位图案的角是暗的，分隔是亮的，暗模块在 (8, size−8)。
        assert_eq!(code.rows[0][0], 1);
        assert_eq!(code.rows[0][20], 1);
        assert_eq!(code.rows[20][0], 1);
        assert_eq!(code.rows[7][7], 0);
        assert_eq!(code.rows[code.size - 8][8], 1);
        // 2,000 字节走到版本 35 附近；超过上限报错；空报错。
        let long = vec![b'a'; 2_000];
        let big = encode(&long).unwrap();
        assert!(big.version >= 33 && big.version <= 40, "{}", big.version);
        assert!(encode(&vec![b'a'; 2_400]).is_err());
        assert!(encode(b"").is_err());
        // 每个版本至少编一次，不能 panic，尺寸对得上。
        for version in 1..=40 {
            let len = capacity_bytes(version);
            let code = encode(&vec![b'x'; len]).unwrap();
            assert_eq!(code.version, version);
            assert_eq!(code.size, version * 4 + 17);
        }
    }

    #[test]
    fn the_dispatch_surface_is_stable() {
        let out = dispatch("qr.encode", json!({"text": "mt1.abc"})).unwrap();
        assert_eq!(out["size"], json!(21));
        assert_eq!(out["rows"].as_array().unwrap().len(), 21);
        assert!(out["error"].is_null());
        assert_eq!(dispatch("qr.encode", json!({"text": ""})).unwrap()["error"], json!("empty"));
        let caps = dispatch("qr.capacities", Value::Null).unwrap();
        assert_eq!(caps.as_array().unwrap().len(), 40);
        assert_eq!(caps[0], json!(14));
        assert!(dispatch("qr.nope", Value::Null).is_err());
    }
}
