// SPDX-License-Identifier: GPL-3.0-only
//! Menu-bar label composition and degradation. The host only measures native fonts.
use crate::MTBuffer;
use serde_json::{json, Value};
use std::{
    ffi::c_void,
    panic::{catch_unwind, AssertUnwindSafe},
};
use unicode_segmentation::UnicodeSegmentation;

pub fn dispatch(operation: &str, input: Value) -> Result<Value, String> {
    match operation {
        "label.compose" => {
            let separator = input["separator"].as_str().ok_or("Missing separator")?;
            let first = input["nameFirst"].as_bool().unwrap_or(true);
            let items = input["items"].as_array().ok_or("Missing items")?;
            let parts: Vec<_> = items
                .iter()
                .map(|item| {
                    let name = item["name"].as_str().unwrap_or("");
                    let time = item["time"].as_str().unwrap_or("");
                    if name.is_empty() {
                        time.to_owned()
                    } else if first {
                        format!("{name}{separator}{time}")
                    } else {
                        format!("{time}{separator}{name}")
                    }
                })
                .collect();
            Ok(json!(parts.join("   ")))
        }
        _ => Err(format!("Unknown label operation: {operation}")),
    }
}
fn fit(full: &str, times: &[&str], max: f64, measure: impl Fn(&str) -> f64) -> String {
    if measure(full) <= max {
        return full.to_owned();
    }
    let compact = times.join("   ");
    if !compact.is_empty() && measure(&compact) <= max {
        return compact;
    }
    for count in (1..times.len()).rev() {
        let candidate = format!("{}…", times[..count].join("   "));
        if measure(&candidate) <= max {
            return candidate;
        }
    }
    let source = times.first().copied().unwrap_or(full);
    if measure(source) <= max {
        return source.to_owned();
    }
    if max <= 0.0 || measure("…") > max {
        return String::new();
    }
    let graphemes: Vec<_> = source.graphemes(true).collect();
    let (mut low, mut high) = (0, graphemes.len());
    while low < high {
        let middle = (low + high).div_ceil(2);
        if measure(&format!("{}…", graphemes[..middle].concat())) <= max {
            low = middle;
        } else {
            high = middle - 1;
        }
    }
    format!("{}…", graphemes[..low].concat())
}
type Measure = extern "C" fn(*mut c_void, *const u8, usize) -> f64;
/// # Safety
/// Input must be readable JSON for `len` bytes. Callback/context must be valid
/// throughout this synchronous call and must not unwind across the C boundary.
#[no_mangle]
pub unsafe extern "C" fn mt_label_fit(
    data: *const u8,
    len: usize,
    max: f64,
    context: *mut c_void,
    measure: Option<Measure>,
) -> MTBuffer {
    let output = catch_unwind(AssertUnwindSafe(|| -> Result<String, String> {
        if data.is_null() {
            return Err("Missing label input".into());
        }
        let bytes = unsafe { std::slice::from_raw_parts(data, len) };
        let input: Value = serde_json::from_slice(bytes).map_err(|e| e.to_string())?;
        let callback = measure.ok_or("Missing font measure callback")?;
        let full = input["full"].as_str().ok_or("Missing full label")?;
        let times: Vec<_> = input["compactTimes"]
            .as_array()
            .ok_or("Missing times")?
            .iter()
            .filter_map(Value::as_str)
            .collect();
        Ok(fit(full, &times, max, |text| {
            callback(context, text.as_ptr(), text.len())
        }))
    }));
    let response = match output {
        Ok(Ok(s)) => json!({"value":s}),
        Ok(Err(e)) => json!({"error":e}),
        Err(_) => json!({"error":"Label core panicked"}),
    };
    let bytes = serde_json::to_vec(&response)
        .expect("JSON response")
        .into_boxed_slice();
    let len = bytes.len();
    MTBuffer {
        data: Box::into_raw(bytes).cast(),
        len,
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn keeps_times_before_truncating_graphemes() {
        let width = |s: &str| s.graphemes(true).count() as f64;
        assert_eq!(
            fit(
                "Long city 12:34 Another 05:40",
                &["12:34", "05:40"],
                13.0,
                width
            ),
            "12:34   05:40"
        );
        assert_eq!(
            fit(
                "Long city 12:34 Another 05:40",
                &["12:34", "05:40"],
                6.0,
                width
            ),
            "12:34…"
        );
        assert_eq!(fit("👩‍🚀ABC", &[], 3.0, width), "👩‍🚀A…");
    }

    /// 性质测试：随机标签、随机每字宽度（单调可加的量宽函数）与随机预算下，降级结果永远量得进预算
    /// （连「…」都放不下才空串），能放整条就整条，其余只能是这几档之一：全部时间、前若干个时间加「…」、
    /// 第一个时间、第一个时间的字位簇前缀加「…」；截断时再多一个字位簇就超预算（不多截）。
    #[test]
    fn random_labels_degrade_within_budget_and_only_along_the_ladder() {
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
        let iterations: u64 = std::env::var("MEANTIME_FUZZ_ITERATIONS").ok().and_then(|v| v.parse().ok()).unwrap_or(3_000);
        let seed_offset: u64 = std::env::var("MEANTIME_FUZZ_SEED").ok().and_then(|v| v.parse().ok()).unwrap_or(0);
        let mut rng = Xor(0x1ABE_15EE_D000_0001_u64.wrapping_add(seed_offset));
        let pieces = ["12:34", "05:40", "23:59 ", "東京", "München", "👩‍🚀", "a\u{301}", "New York", "…", "🇯🇵", " ", "Ürümqi"];
        for i in 0..iterations {
            // 每个字位簇的宽度按其首个标量随机但固定（同一次迭代内一致），量宽 = 各簇宽度之和。
            let widths: Vec<f64> = (0..64).map(|_| 0.5 + rng.below(30) as f64 / 10.0).collect();
            let measure = |text: &str| -> f64 {
                text.graphemes(true).map(|g| widths[(g.chars().next().unwrap() as u32 as usize) % 64]).sum()
            };
            let times: Vec<String> = (0..rng.below(5)).map(|_| pieces[rng.below(4) as usize].trim().to_owned()).collect();
            let times_ref: Vec<&str> = times.iter().map(String::as_str).collect();
            let full: String = (0..1 + rng.below(6)).map(|_| pieces[rng.below(pieces.len() as u64) as usize]).collect::<Vec<_>>().join(" ");
            let max = rng.below(60) as f64 / 2.0;
            let out = fit(&full, &times_ref, max, measure);
            let tag = format!("#{i} full={full:?} times={times:?} max={max} → {out:?}");
            if out.is_empty() {
                assert!(measure(&full) > max, "{tag}：整条放得下却给了空串");
                assert!(max <= 0.0 || measure("…") > max || times_ref.first().is_some_and(|t| measure(t) > max && t.graphemes(true).next().is_some_and(|g| measure(&format!("{g}…")) > max)) || times_ref.is_empty() && full.graphemes(true).next().is_some_and(|g| measure(&format!("{g}…")) > max),
                    "{tag}：还有东西放得下却给了空串");
                continue;
            }
            assert!(measure(&out) <= max + 1e-9, "{tag}：结果 {} 超预算", measure(&out));
            if measure(&full) <= max {
                assert_eq!(out, full, "{tag}：整条放得下却降了级");
                continue;
            }
            let compact = times.join("   ");
            let source = times_ref.first().copied().unwrap_or(&full);
            let on_ladder = out == compact
                || (1..times.len()).any(|n| out == format!("{}…", times_ref[..n].join("   ")))
                || out == source
                || out.strip_suffix('…').is_some_and(|kept| source.starts_with(kept));
            assert!(on_ladder, "{tag}：结果不在降级阶梯上");
            // 截断到字位簇时不能少截：再多一个簇就超预算。
            if let Some(kept) = out.strip_suffix('…').filter(|_| out != compact && out != source && !(1..times.len()).any(|n| out == format!("{}…", times_ref[..n].join("   ")))) {
                let kept_count = kept.graphemes(true).count();
                let graphemes: Vec<&str> = source.graphemes(true).collect();
                if kept_count < graphemes.len() {
                    let longer = format!("{}…", graphemes[..kept_count + 1].concat());
                    assert!(measure(&longer) > max, "{tag}：还能多放一个字位簇 {longer:?}");
                }
            }
        }
    }
}
