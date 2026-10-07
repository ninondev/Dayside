// SPDX-License-Identifier: GPL-3.0-only
//! 样例生成：先按轮转选定模板，再按模板需要构造能被该模板完整表达的
//! 规格（句子与 `want` 因此永远一致），用自带的 xorshift 保证可复现。

use super::data::{lang, Seg, CITY_KEYS};
use super::rng::Rng;
use super::{render, Case, Clock, DateSpec, Spec, Zone, LANGUAGES};

/// 分钟取值：整点/一刻/半点/三刻为主，另有若干其它分钟。
const MINUTES: [u8; 14] = [0, 15, 30, 45, 0, 15, 30, 45, 5, 10, 20, 40, 50, 55];

/// 允许出现的 UTC 偏移（分钟）。
const OFFSETS: [i16; 8] = [-300, -180, 0, 60, 330, 345, 540, 600];

/// 每种语言生成 `per_lang` 条样例，语言顺序与 `LANGUAGES` 一致。
pub fn cases(seed: u64, per_lang: usize) -> Vec<Case> {
    let mut out = Vec::with_capacity(LANGUAGES.len() * per_lang);
    for (i, code) in LANGUAGES.iter().enumerate() {
        let l = lang(code).expect("语言表已覆盖 LANGUAGES");
        // 每种语言一个独立子流，避免语言之间互相影响
        let mut rng = Rng::new(seed ^ 0x9E37_79B9_7F4A_7C15u64.wrapping_mul(i as u64 + 1));
        let n = l.templates.len();
        for j in 0..per_lang {
            // 轮转模板编号：per_lang 足够大时每种模板都会被用到
            let t = j % n;
            let spec = spec_for(l.templates[t], &mut rng);
            let text = render::render(&spec, code, t).expect("按模板构造的规格必须可渲染");
            out.push(Case {
                lang: code,
                text,
                want: super::expected(&spec),
            });
        }
    }
    out
}

// 分析模板需要哪些语义成分，再据此抽取一个随机规格。
fn spec_for(segs: &[Seg], rng: &mut Rng) -> Spec {
    let mut need_date = false; // 任意日期片段
    let mut iso_only = false; // 只能是完整日期（ISO 数字句式）
    let mut weekday = 0u8; // 1 = 星期（可带“下一”），2 = 星期（不带）
    let mut need_end = false;
    let mut need_city = false;
    let mut need_offset = false;
    let mut twelve = false;
    for s in segs {
        match s {
            Seg::Date => need_date = true,
            Seg::DateIso => {
                need_date = true;
                iso_only = true;
            }
            Seg::Wd => weekday = 1,
            Seg::WdPlain => weekday = 2,
            Seg::RangeDash | Seg::RangeFT => need_end = true,
            Seg::CityIn | Seg::CityTime => need_city = true,
            Seg::Utc => need_offset = true,
            Seg::Time12 => twelve = true,
            _ => {}
        }
    }

    // 12 小时制避开 0 点与 12 点；区间模板为结束时刻留出同日空间
    let max_hour: u8 = if need_end { 21 } else { 23 };
    let hour = if twelve {
        let allowed: Vec<u8> = (1..=11).chain(13..=max_hour).collect();
        allowed[rng.bound(allowed.len() as u64) as usize]
    } else {
        rng.bound(max_hour as u64 + 1) as u8
    };
    let minute = pick_minute(rng);
    let end = if need_end {
        let eh = hour + 1 + rng.bound((23 - hour) as u64) as u8;
        Some(Clock {
            hour: eh,
            minute: pick_minute(rng),
        })
    } else {
        None
    };
    let zone = if need_city {
        Some(Zone::City(
            CITY_KEYS[rng.bound(CITY_KEYS.len() as u64) as usize],
        ))
    } else if need_offset {
        Some(Zone::Offset(
            OFFSETS[rng.bound(OFFSETS.len() as u64) as usize],
        ))
    } else {
        None
    };
    let date = if weekday > 0 {
        Some(DateSpec::Weekday {
            weekday: 1 + rng.bound(7) as u8,
            next: weekday == 1 && rng.bound(2) == 1,
        })
    } else if need_date {
        if iso_only {
            Some(absolute(rng))
        } else {
            // 四种日期规格都要出现：完整日期权重稍高
            match rng.bound(4) {
                0 | 1 => Some(absolute(rng)),
                2 => {
                    let month = 1 + rng.bound(12) as u8;
                    let day = 1 + rng.bound(days_in_month(month, None) as u64) as u8;
                    Some(DateSpec::MonthDay { month, day })
                }
                _ => Some(DateSpec::Offset {
                    days: [-1i8, 0, 1, 2][rng.bound(4) as usize],
                }),
            }
        }
    } else {
        None
    };
    Spec {
        date,
        time: Clock { hour, minute },
        end,
        zone,
    }
}

// 随机分钟。
fn pick_minute(rng: &mut Rng) -> u8 {
    MINUTES[rng.bound(MINUTES.len() as u64) as usize]
}

// 随机完整日期（2025–2027），保证该月确有该日。
fn absolute(rng: &mut Rng) -> DateSpec {
    let year = 2025 + rng.bound(3) as i32;
    let month = 1 + rng.bound(12) as u8;
    let day = 1 + rng.bound(days_in_month(month, Some(year)) as u64) as u8;
    DateSpec::Absolute { year, month, day }
}

// 某月天数；不给年份时二月按 28 天处理。
fn days_in_month(month: u8, year: Option<i32>) -> u8 {
    match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 => match year {
            Some(y) if (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 => 29,
            _ => 28,
        },
        _ => 30,
    }
}
