// SPDX-License-Identifier: GPL-3.0-only
//! NOAA/Meeus mathematics and bounded daylight cache. Host supplies civil dates
//! and the system time-zone offset at local noon, preserving Apple's tzdb rules.
use std::{
    collections::HashMap,
    sync::{Mutex, OnceLock},
};

#[derive(Clone, Copy)]
#[repr(C)]
pub struct MTSolarResult {
    pub sunrise: f64,
    pub sunset: f64,
    pub kind: i32,
}
#[repr(C)]
pub struct MTLocalComponents {
    pub day: i64,
    pub fraction: f64,
}

#[no_mangle]
pub extern "C" fn mt_local_components(unix: f64, offset: i32) -> MTLocalComponents {
    let local = unix + f64::from(offset);
    let mut fraction = (local % 86_400.0) / 86_400.0;
    if fraction < 0.0 {
        fraction += 1.0;
    }
    MTLocalComponents {
        day: (local / 86_400.0).floor() as i64,
        fraction,
    }
}

#[no_mangle]
pub extern "C" fn mt_clock_boundary(unix: f64, seconds: bool) -> f64 {
    let interval = if seconds { 1.0 } else { 60.0 };
    interval - unix % interval
}

#[no_mangle]
pub extern "C" fn mt_solar_minute(fraction: f64) -> i32 {
    (fraction * 1440.0).round().clamp(0.0, 1439.0) as i32
}

fn julian_day(year: i32, month: i32, day: i32) -> f64 {
    let (y, m) = if month <= 2 {
        (year - 1, month + 12)
    } else {
        (year, month)
    };
    let a = (f64::from(y) / 100.0).floor();
    let b = 2.0 - a + (a / 4.0).floor();
    (365.25 * f64::from(y + 4716)).floor()
        + (30.6001 * f64::from(m + 1)).floor()
        + f64::from(day)
        + b
        - 1524.5
}
fn rad(d: f64) -> f64 {
    d * std::f64::consts::PI / 180.0
}
fn deg(r: f64) -> f64 {
    r * 180.0 / std::f64::consts::PI
}
fn norm(x: f64, period: f64) -> f64 {
    let r = x % period;
    if r < 0.0 {
        r + period
    } else {
        r
    }
}

#[no_mangle]
pub extern "C" fn mt_solar_compute(
    year: i32,
    month: i32,
    day: i32,
    lat: f64,
    lon: f64,
    offset: i32,
) -> MTSolarResult {
    let tz_hours = f64::from(offset) / 3600.0;
    let t = (julian_day(year, month, day) - 2_451_545.0) / 36_525.0;
    let l0 = norm(280.46646 + t * (36000.76983 + t * 0.0003032), 360.0);
    let m = 357.52911 + t * (35999.05029 - t * 0.0001537);
    let e = 0.016708634 - t * (0.000042037 + t * 0.0000001267);
    let mr = rad(m);
    let center = mr.sin() * (1.914602 - t * (0.004817 + t * 0.000014))
        + (2.0 * mr).sin() * (0.019993 - t * 0.000101)
        + (3.0 * mr).sin() * 0.000289;
    let true_long = l0 + center;
    let omega = 125.04 - 1934.136 * t;
    let lambda = true_long - 0.00569 - 0.00478 * rad(omega).sin();
    let eps0 = 23.0 + (26.0 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60.0) / 60.0;
    let eps = eps0 + 0.00256 * rad(omega).cos();
    let decl = (rad(eps).sin() * rad(lambda).sin()).asin();
    let y = rad(eps / 2.0).tan().powi(2);
    let l0r = rad(l0);
    let eq_time = 4.0
        * deg(y * (2.0 * l0r).sin() - 2.0 * e * mr.sin()
            + 4.0 * e * y * mr.sin() * (2.0 * l0r).cos()
            - 0.5 * y * y * (4.0 * l0r).sin()
            - 1.25 * e * e * (2.0 * mr).sin());
    let latr = rad(lat);
    let cos_h = (rad(90.833).cos() - latr.sin() * decl.sin()) / (latr.cos() * decl.cos());
    if cos_h > 1.0 {
        return MTSolarResult {
            sunrise: 0.0,
            sunset: 0.0,
            kind: 2,
        };
    }
    if cos_h < -1.0 {
        return MTSolarResult {
            sunrise: 0.0,
            sunset: 1.0,
            kind: 1,
        };
    }
    let ha = deg(cos_h.acos());
    let noon = norm(720.0 - 4.0 * lon - eq_time + 60.0 * tz_hours, 1440.0);
    MTSolarResult {
        sunrise: ((noon - 4.0 * ha) / 1440.0).clamp(0.0, 1.0),
        sunset: ((noon + 4.0 * ha) / 1440.0).clamp(0.0, 1.0),
        kind: 0,
    }
}

#[derive(Hash, Eq, PartialEq)]
struct DayKey {
    lat: u64,
    lon: u64,
    zone: String,
    day: i64,
}
fn cache() -> &'static Mutex<HashMap<DayKey, MTSolarResult>> {
    static CACHE: OnceLock<Mutex<HashMap<DayKey, MTSolarResult>>> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}
unsafe fn key(lat: f64, lon: f64, zone: *const u8, len: usize, day: i64) -> Option<DayKey> {
    if zone.is_null() {
        return None;
    }
    let bytes = unsafe { std::slice::from_raw_parts(zone, len) };
    let zone = std::str::from_utf8(bytes).ok()?.to_owned();
    // Swift considers positive and negative zero equal in Double dictionary keys.
    Some(DayKey {
        lat: if lat == 0.0 { 0 } else { lat.to_bits() },
        lon: if lon == 0.0 { 0 } else { lon.to_bits() },
        zone,
        day,
    })
}

/// # Safety
/// `zone` must point to `len` readable UTF-8 bytes for this call.
#[no_mangle]
pub unsafe extern "C" fn mt_solar_cached(
    lat: f64,
    lon: f64,
    zone: *const u8,
    len: usize,
    day: i64,
) -> MTSolarResult {
    let miss = MTSolarResult {
        sunrise: 0.0,
        sunset: 0.0,
        kind: -1,
    };
    let Some(key) = (unsafe { key(lat, lon, zone, len, day) }) else {
        return miss;
    };
    cache()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .get(&key)
        .copied()
        .unwrap_or(miss)
}

/// # Safety
/// `zone` must point to `len` readable UTF-8 bytes for this call.
#[no_mangle]
pub unsafe extern "C" fn mt_solar_store(
    lat: f64,
    lon: f64,
    zone: *const u8,
    len: usize,
    day: i64,
    value: MTSolarResult,
) {
    let Some(key) = (unsafe { key(lat, lon, zone, len, day) }) else {
        return;
    };
    let mut cache = cache().lock().unwrap_or_else(|e| e.into_inner());
    if cache.len() > 512 {
        cache.clear();
    }
    cache.insert(key, value);
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn local_day_handles_negative_dates_and_offsets() {
        let parts = mt_local_components(-1.0, 0);
        assert_eq!(parts.day, -1);
        assert!((parts.fraction - 86_399.0 / 86_400.0).abs() < 1e-12);
        assert_eq!(mt_local_components(0.0, -3600).day, -1);
    }
    #[test]
    fn polar_days_and_dateline_noon_remain_valid() {
        assert_eq!(mt_solar_compute(2026, 6, 21, 78.22, 15.64, 7200).kind, 1);
        assert_eq!(mt_solar_compute(2026, 12, 21, 78.22, 15.64, 3600).kind, 2);
        let result = mt_solar_compute(2026, 6, 21, 1.87, -157.43, 14 * 3600);
        assert_eq!(result.kind, 0);
        assert!(result.sunrise < result.sunset && result.sunset < 1.0);
    }
}
