// SPDX-License-Identifier: GPL-3.0-only
//! 城市灯火：地球窗的夜半球上，人口够多的城市在太阳落到地平线下 6° 之后亮起，
//! 曙暮里（−6° … −0.833°）先亮一半。扫动时间能看见灯一路往西点亮：夜里有人的地方是亮的，这张图才算画到了人。
//!
//! 资格：人口 ≥ 111 万才亮，欧洲（洲码 EU）与加拿大、澳大利亚、新西兰 ≥ 100 万；亮度分三档，
//! 上两档按联合国城市规模线：门槛–500 万、500–1000 万、≥ 1000 万（超大城市），越大越亮越大。同一片都会区只点一盏
//! （相距 ≥ 0.6°）。数据由 `Tools/make_lights_bin.py` 从 GeoNames cities500 生成 `data/lights.bin`（392 盏，1.9 KB）。
//! 灯由 `sky::add_lights` 逐像素画进地图的位图（面板、地球窗、海报都亮，−0.833° 起渐亮、−6° 全亮）；
//! 这里只剩数据本身。原来给宿主画点的 `lights.scene` 那条路随之删掉。

static LIGHTS: &[u8] = include_bytes!("../data/lights.bin");

/// 一盏灯：经度、纬度（度）与人口档（1 = 门槛–500 万、2 = 500–1000 万、3 = ≥ 1000 万），按人口从大到小。
pub(crate) fn points() -> Vec<(f64, f64, u8)> {
    let u16_at = |i: usize| u16::from_le_bytes([LIGHTS[i], LIGHTS[i + 1]]) as usize;
    let i16_at = |i: usize| i16::from_le_bytes([LIGHTS[i], LIGHTS[i + 1]]) as f64 / 100.0;
    (0..u16_at(0)).map(|k| (i16_at(2 + 5 * k), i16_at(4 + 5 * k), LIGHTS[6 + 5 * k])).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_cities_of_1_11_million_qualify_one_light_per_metro_area_in_three_size_classes() {
        let lights = points();
        assert_eq!(lights.len(), 392, "cities500 2026-09-15 按 ≥ 111 万（欧洲、加拿大、澳新 ≥ 100 万）、0.6° 去重");
        assert!(lights.iter().all(|&(lon, lat, tier)| (-180.0..=180.0).contains(&lon) && (-90.0..=90.0).contains(&lat) && (1..=3).contains(&tier)));
        let count = |t: u8| lights.iter().filter(|l| l.2 == t).count();
        assert_eq!((count(1), count(2), count(3)), (328, 40, 24));
        // 酌情降到 100 万的地区：科隆、布鲁塞尔、都柏林、奥斯陆、渥太华这些 100–111 万的城市有灯（按经纬度框认）。
        let has = |lon: f64, lat: f64| lights.iter().any(|p| (p.0 - lon).abs() < 0.3 && (p.1 - lat).abs() < 0.3);
        assert!(has(6.95, 50.94) && has(4.35, 50.85) && has(-6.26, 53.35) && has(10.75, 59.91) && has(-75.7, 45.42));
        // 按人口从大到小：档只会往下走，不会回升。
        assert!(lights.windows(2).all(|w| w[0].2 >= w[1].2));
        // 生成规则：任何两盏至少隔 0.6°（经度按跨日界线取近的那边）。独立地两两核一遍。
        for (i, a) in lights.iter().enumerate() {
            for b in &lights[i + 1..] {
                let d = (a.0 - b.0).abs();
                assert!((a.1 - b.1).abs() >= 0.6 - 0.011 || d.min(360.0 - d) >= 0.6 - 0.011, "{a:?} 与 {b:?} 太近");
            }
        }
        // ≥ 500 万的两档里应当有东京、德里、上海、拉各斯、圣保罗一带（按经纬度框认，不认名字）。
        let big = |lon: f64, lat: f64| lights.iter().filter(|l| l.2 >= 2).any(|p| (p.0 - lon).abs() < 1.0 && (p.1 - lat).abs() < 1.0);
        assert!(big(139.7, 35.7) && big(77.2, 28.6) && big(121.5, 31.2) && big(3.4, 6.5) && big(-46.6, -23.5));
    }
}
