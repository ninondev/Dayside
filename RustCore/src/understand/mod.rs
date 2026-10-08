// SPDX-License-Identifier: GPL-3.0-only
//! 确定性时间理解引擎：从整段文字中提取时间、地点、歧义候选与问题。
//!
//! 旧的两层（`converter::parse` 只认整句都是严格格式、`colloquial::parse` 要求整句都被词表吃掉）换成一条管线：
//! 折叠 → 切成单元 → 在**任意位置**认出日期、钟点、时间段、相对时间、精确时刻（ISO / Unix）、时区（偏移、缩写、
//! 「X 时间」句式）与地点线索 → 以每个钟点为中心拼成「一次提到的时间」（mention），一段话里可以有几次 → 地名交给
//! 城市索引只认精确命中 → 输出每次提到的结构与它在原文里的位置（UTF-16），宿主据此标出读懂了哪几个字。
//!
//! 仍然确定性、不猜：认不出的词不当地名，除非城市索引精确命中；有歧义的缩写给出全部候选；日期计算（星期几是哪天、
//! 夏令时）留给宿主的 Foundation。词表在 `lexicon.rs`（十六种界面语言），切词与折叠在 `text.rs`。
pub(crate) mod crosscheck;
#[cfg(test)]
pub(crate) mod sentencegen;
pub(crate) mod lexicon;
pub(crate) mod text;
mod assemble;
mod dates;
mod language;
mod table_storage;
#[cfg(all(test, feature = "parser-table-generator"))]
#[path = "generated_tables_bootstrap.rs"]
mod generated_tables;
#[cfg(not(all(test, feature = "parser-table-generator")))]
mod generated_tables;
#[cfg(test)]
mod table_generation;
#[cfg(not(test))]
const _: () = assert!(generated_tables::GENERATED, "generate parser tables before production build");
mod places;
mod scan;
mod series;
mod types;
mod units;
mod targets;

pub use types::{Mention, Output, Part, ZoneRef};
#[cfg(test)]
pub(crate) use types::{Clock, DateSpec};
#[cfg(test)]
use text::fold_str;

use assemble::Context;
use scan::Scanner;
use serde_json::Value;
use text::fold;
use units::{units, UKind, Unit};
#[cfg(not(feature = "intents-only"))]
use places::city_lookup;

/// 粘贴一整封邮件也够用；再长的按前 4,000 字节算（在字符边界上截），并在 `Output::truncated_at` 里说出来。
const MAX_INPUT_BYTES: usize = 4000;

// ───────────────────────────── 入口 ─────────────────────────────

pub struct Options<'a> {
    /// 用户所在地区（ISO 3166，`Locale.current.region`）：英文或判不出语言时「10/3」按它定顺序（美国等月/日，其余日/月）。
    pub region: &'a str,
    /// 界面语言（地区也没有时的回退）。
    pub ui_language: &'a str,
    /// 地名 → 时区。`strong` = 有明确的地点线索（in X、X time）：可以接受不那么有名的地方。
    pub lookup: &'a dyn Fn(&str, bool) -> Option<ZoneRef>,
}

pub fn understand(input: &str, options: &Options) -> Output {
    #[cfg(not(feature = "intents-only"))]
    let _nearby_index = places::nearby_parse_scope();
    let (input, truncated_at) = if input.len() > MAX_INPUT_BYTES {
        let mut end = MAX_INPUT_BYTES;
        while !input.is_char_boundary(end) {
            end -= 1;
        }
        (&input[..end], Some(input[..end].encode_utf16().count()))
    } else {
        (input, None)
    };
    let folded = fold(input);
    let mut u = units(&folded);
    units::prepare_lexicon(&mut u);
    scan::classify_numbers(&mut u);
    units::prepare_lexicon(&mut u);
    language::enable_memos(&u);
    let mut scanner = Scanner { u: &u, out: Vec::new() };
    // 整段只有一个 10 位 / 13 位数字（前面可以有 @ / unix / epoch / timestamp）：Unix 时间戳。
    let words: Vec<&Unit> = u.iter().filter(|t| t.kind != UKind::Punct || t.text != "@").collect();
    let meaningful: Vec<&&Unit> = words.iter().filter(|t| !matches!(t.text.as_str(), "unix" | "epoch" | "timestamp" | "ts")).collect();
    if meaningful.len() == 1 && meaningful[0].kind == UKind::Number && matches!(meaningful[0].text.len(), 10 | 13) {
        let raw: i64 = meaningful[0].text.parse().unwrap_or(0);
        let seconds = if meaningful[0].text.len() == 13 { raw / 1000 } else { raw };
        if (0..=7_258_118_400).contains(&seconds) {
            let span = [folded.span[meaningful[0].start].0, folded.span[meaningful[0].end - 1].1];
            let mut mention = Mention::empty(span);
            mention.parts = vec![Part { kind: "instant", span }];
            mention.instant = Some(seconds);
            return Output { mentions: vec![mention], truncated_at, languages: vec![], writer: None };
        }
    }
    scanner.scan();
    dates::apply_written_day_ends(&u, &mut scanner.out);
    let destinations = targets::scan(&u, &scanner.out);
    scanner.out.retain(|a| matches!(a.atom, scan::Atom::Boundary(_)) || !destinations.iter().any(|p| a.from < p.to && p.from < a.to));
    let lowercase = sentence_lowercase(&u);
    let initial = clause_initial(&u);
    let context = Context {
        units: &u,
        folded: &folded,
        atoms: scanner.out,
        lookup: options.lookup,
        lowercase,
        initial,
        region: options.region,
        ui_language: options.ui_language,
        destinations,
    };
    let mut output = context.assemble();
    output.truncated_at = truncated_at;
    output
}

/// 每一句（冒号、竖线、括号之后也算重新开头）的第一个词：它的首字母大写是语法要求，不说明它是专名（「Date limite
/// d'inscription」「Ende: 27.09.2025」「Vize ücretinin…」；这些都被当成了地名）。
fn clause_initial(u: &[Unit]) -> Vec<bool> {
    let mut out = vec![false; u.len()];
    let mut fresh = true;
    for (i, t) in u.iter().enumerate() {
        match t.kind {
            UKind::Punct => {
                // 句号、冒号后面要隔着空白才算（「14:00 Genève」「14.00」的冒号与点是钟点的一部分）。
                let opener = matches!(t.text.as_str(), "|" | "(" | "\"" | "•" | "。" | "；" | "！" | "？" | "\n" | "\n\n");
                let stop = matches!(t.text.as_str(), "." | "!" | "?" | ";" | ":") && u.get(i + 1).is_none_or(|n| n.space_before);
                if opener || stop {
                    fresh = true;
                }
            }
            UKind::Word => {
                out[i] = fresh;
                fresh = false;
            }
            _ => {}
        }
    }
    out
}

/// 每个单元所在的那一句（到句末标点或换行为止）拉丁字母是不是全小写。
fn sentence_lowercase(u: &[Unit]) -> Vec<bool> {
    let mut out = vec![false; u.len()];
    let mut start = 0;
    for i in 0..=u.len() {
        let ends = i == u.len()
            || (u[i].kind == UKind::Punct && matches!(u[i].text.as_str(), "." | "!" | "?" | ";" | "。" | "；" | "！" | "？" | "\n" | "\n\n"));
        if ends {
            let lower = !u[start..i].iter().any(|t| t.raw.chars().any(char::is_uppercase));
            out[start..i].iter_mut().for_each(|v| *v = lower);
            start = i + 1;
        }
    }
    out
}

#[cfg(not(feature = "intents-only"))]
fn memoized_lookup(lookup: impl Fn(&str, bool) -> Option<ZoneRef>) -> impl Fn(&str, bool) -> Option<ZoneRef> {
    // 原文与线索强度都参与键；未命中也保留，缓存只活过本次解析。按原文查，命中时不必再分配键。
    let cache = std::cell::RefCell::new(table_storage::FastMap::<String, [Option<Option<ZoneRef>>; 2]>::default());
    move |text: &str, strong: bool| {
        let slot = usize::from(strong);
        if let Some(zone) = cache.borrow().get(text).and_then(|entry| entry[slot].as_ref()) {
            return zone.clone();
        }
        let zone = lookup(text, strong);
        cache.borrow_mut().entry(text.to_owned()).or_default()[slot] = Some(zone.clone());
        zone
    }
}

pub fn dispatch(operation: &str, payload: Value) -> Result<Value, String> {
    match operation {
        "understand.parse" => {
            let text = payload.get("text").and_then(Value::as_str).unwrap_or("");
            let region = payload.get("region").and_then(Value::as_str).unwrap_or("");
            let ui_language = payload.get("language").and_then(Value::as_str).unwrap_or("");
            #[cfg(not(feature = "intents-only"))]
            let handle = payload.get("cityHandle").and_then(Value::as_u64);
            #[cfg(not(feature = "intents-only"))]
            let lookup = memoized_lookup(move |t: &str, strong: bool| city_lookup(handle, t, strong));
            #[cfg(feature = "intents-only")]
            // 快捷指令进程没有城市索引：国家名照样认（「9am in Brazil」），别的有线索的地名原样交宿主。
            let lookup = |t: &str, strong: bool| strong.then(|| places::country_lookup(t).unwrap_or_else(|| ZoneRef::Place { query: t.to_owned() }));
            let output = understand(text, &Options { region, ui_language, lookup: &lookup });
            Ok(serde_json::to_value(output).map_err(|e| e.to_string())?)
        }
        "understand.crosscheck" => {
            // 载荷：`{ mentions: [{ index, group, instant（秒）, zone, zoned, hasClock }] }`；返回 `{ same: [[…]], notes: [{ a, b, deltaMinutes, kind }] }`。
            let payload: CrosscheckPayload = serde_json::from_value(payload).map_err(|e| format!("Invalid crosscheck payload: {e}"))?;
            if payload.mentions.len() > 1_024 {
                return Err("Invalid crosscheck payload: too many mentions".into());
            }
            let items: Vec<crosscheck::Instant> = payload
                .mentions
                .into_iter()
                .map(|m| crosscheck::Instant { index: m.index, group: m.group, seconds: m.instant, zone: m.zone, zoned: m.zoned, has_clock: m.has_clock })
                .collect();
            let report = crosscheck::crosscheck(&items);
            let notes: Vec<Value> = report
                .notes
                .iter()
                .map(|n| {
                    let kind = match n.kind {
                        crosscheck::Kind::DstSuspect => "dstSuspect",
                        crosscheck::Kind::Different => "different",
                    };
                    serde_json::json!({ "a": n.a, "b": n.b, "deltaMinutes": n.delta_minutes, "kind": kind })
                })
                .collect();
            Ok(serde_json::json!({ "same": report.same, "notes": notes }))
        }
        _ => Err(format!("Unknown understand operation: {operation}")),
    }
}

#[derive(serde::Deserialize)]
struct CrosscheckPayload {
    mentions: Vec<CrosscheckMention>,
}

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct CrosscheckMention {
    index: usize,
    group: usize,
    instant: i64,
    zone: String,
    zoned: bool,
    has_clock: bool,
}

#[cfg(test)]
mod tests;

#[cfg(test)]
mod properties;

#[cfg(all(test, not(feature = "intents-only")))]
mod speed_tests;

#[cfg(test)]
mod places_unit5_tests;

#[cfg(test)]
mod targets_unit6_tests;

#[cfg(test)]
mod other_unit6_tests;

#[cfg(test)]
mod clocks_unit7_tests;
#[cfg(test)]
mod days_words_unit7_tests;
#[cfg(test)]
mod days_series_unit7_tests;

#[cfg(test)]
mod clause_tests;

#[cfg(test)]
mod nearby_tests;

#[cfg(test)]
mod nearby_revision_tests;

#[cfg(test)]
mod nearby_exact_tests;
