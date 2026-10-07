// SPDX-License-Identifier: GPL-3.0-only
//! Plans timezone-change notices from the host's current system timezone facts.
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::BTreeSet;

const NOTICE_LIMIT: usize = 32;
const HORIZON: f64 = 400.0 * 86400.0;

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct Receipt {
    id: String,
    fire_at: f64,
    transition_at: f64,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct State {
    version: u8,
    enabled: bool,
    lead_seconds: i64,
    receipts: Vec<Receipt>,
}

impl Default for State {
    fn default() -> Self {
        Self {
            version: 1,
            enabled: false,
            lead_seconds: 86400,
            receipts: vec![],
        }
    }
}

impl State {
    fn valid(&self) -> bool {
        self.version == 1
            && matches!(self.lead_seconds, 3600 | 86400 | 604800)
            && self.receipts.len() <= 512
            && self.receipts.iter().all(|r| {
                r.id.starts_with("meantime.dst.")
                    && r.id.len() <= 512
                    && valid_date(r.fire_at)
                    && valid_date(r.transition_at)
                    && r.fire_at < r.transition_at
            })
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct Fact {
    zone: String,
    transition_at: f64,
    before: i32,
    after: i32,
}

fn valid_date(value: f64) -> bool {
    value.is_finite() && (-62_135_596_800.0..253_402_300_800.0).contains(&value)
}

fn identifier(fact: &Fact) -> String {
    // IDs include the entire IANA identifier. Fixed-offset facts do not appear;
    // repeated copies of one saved timezone collapse to the same notification.
    format!("meantime.dst.{}.{}", fact.zone, fact.transition_at as i64)
}

fn offset_label(offset: i32) -> String {
    let magnitude = offset.abs();
    let mut value = format!(
        "UTC{}{:02}:{:02}",
        if offset < 0 { '\u{2212}' } else { '+' },
        magnitude / 3600,
        magnitude % 3600 / 60
    );
    if magnitude % 60 != 0 {
        value.push_str(&format!(":{:02}", magnitude % 60));
    }
    value
}

fn plan(state: &State, facts: &[Fact], now: f64, authorized: bool) -> (Vec<Value>, Vec<Value>) {
    if !state.enabled {
        return (vec![], vec![]);
    }
    let mut facts: Vec<_> = facts
        .iter()
        .filter(|fact| {
            !fact.zone.is_empty()
                && fact.zone.len() <= 255
                && !fact.zone.chars().any(char::is_control)
                && valid_date(fact.transition_at)
                && fact.transition_at.fract() == 0.0
                && fact.transition_at > now
                && fact.transition_at <= now + HORIZON
                && (-86399..=86399).contains(&fact.before)
                && (-86399..=86399).contains(&fact.after)
                && fact.before != fact.after
        })
        .collect();
    facts.sort_by(|a, b| {
        a.transition_at
            .total_cmp(&b.transition_at)
            .then_with(|| a.zone.cmp(&b.zone))
    });
    let mut seen = BTreeSet::new();
    let mut upcoming = vec![];
    let mut notices = vec![];
    for fact in facts {
        let id = identifier(fact);
        if !seen.insert(id.clone()) {
            continue;
        }
        let receipt = state.receipts.iter().find(|receipt| receipt.id == id);
        let planned = receipt.map_or(
            (fact.transition_at - state.lead_seconds as f64).max(now + 1.0),
            |r| r.fire_at,
        );
        let value = json!({"id":id, "zone":fact.zone, "transitionAt":fact.transition_at,
            "before":fact.before, "after":fact.after, "shift":fact.after-fact.before,
            "beforeLabel":offset_label(fact.before), "afterLabel":offset_label(fact.after),
            "fireAt":planned, "alreadyScheduled":receipt.is_some()});
        upcoming.push(value.clone());
        // An accepted notice whose date has passed is never replayed. This is
        // a receipt of scheduling, not a promise that macOS displayed it.
        if authorized
            && planned > now
            && planned < fact.transition_at
            && notices.len() < NOTICE_LIMIT
        {
            notices.push(value);
        }
    }
    (upcoming, notices)
}

pub fn dispatch(operation: &str, payload: Value) -> Result<Value, String> {
    let now = payload["now"]
        .as_f64()
        .filter(|n| valid_date(*n))
        .ok_or("Invalid DST clock facts")?;
    let authorized = payload["authorized"].as_bool().unwrap_or(false);
    let facts: Vec<Fact> =
        serde_json::from_value(payload["facts"].clone()).map_err(|e| e.to_string())?;
    if facts.len() > 4096 {
        return Err("Too many timezone facts".to_owned());
    }
    let (mut state, recovered) = if operation == "dstwatch.load" {
        let stored = payload["stored"].as_str().filter(|s| !s.is_empty());
        let decoded = stored
            .and_then(|s| serde_json::from_str::<State>(s).ok())
            .filter(State::valid);
        let recovered = stored.is_some() && decoded.is_none();
        (decoded.unwrap_or_default(), recovered)
    } else if operation == "dstwatch.reduce" {
        let state: State =
            serde_json::from_value(payload["state"].clone()).map_err(|e| e.to_string())?;
        if !state.valid() {
            return Err("Invalid DST watch state".to_owned());
        }
        (state, false)
    } else {
        return Err(format!("Unknown DST watch operation: {operation}"));
    };
    let old = state.clone();
    state
        .receipts
        .retain(|receipt| receipt.transition_at + 86400.0 > now);
    let event = &payload["event"];
    let mut error = None;
    if operation == "dstwatch.reduce" {
        match event["kind"].as_str().unwrap_or("") {
            "refresh" => {}
            "enable" => {
                state.enabled = event["enabled"].as_bool().unwrap_or(false);
                if !state.enabled {
                    // Unfired notices will be cancelled by the host and may be
                    // planned anew if the user enables the watch again.
                    state.receipts.retain(|r| r.fire_at <= now);
                }
            }
            "lead" => match event["seconds"].as_i64() {
                Some(seconds @ (3600 | 86400 | 604800)) => {
                    state.lead_seconds = seconds;
                    state.receipts.retain(|r| r.fire_at <= now);
                }
                _ => error = Some("invalidLead"),
            },
            "scheduled" => {
                if let Ok(receipt) = serde_json::from_value::<Receipt>(event["receipt"].clone()) {
                    let (_, requested) = plan(&state, &facts, now, true);
                    if state.enabled
                        && requested.iter().any(|n| {
                            n["id"] == receipt.id && n["transitionAt"] == receipt.transition_at
                        })
                        && valid_date(receipt.fire_at)
                        && receipt.fire_at < receipt.transition_at
                    {
                        state.receipts.retain(|r| r.id != receipt.id);
                        state.receipts.push(receipt);
                    }
                }
            }
            "deactivate" => {
                state.enabled = false;
                state.receipts.retain(|r| r.fire_at <= now);
            }
            _ => error = Some("invalidAction"),
        }
    }
    let (upcoming, notices) = plan(&state, &facts, now, authorized);
    Ok(
        json!({"state":state, "changed":state != old, "recovered":recovered, "error":error,
        "upcoming":upcoming, "notices":notices, "noticeLimit":NOTICE_LIMIT,
        "nextCheck": if state.enabled { Some(now + 86400.0) } else { None }}),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    fn initial() -> Value {
        serde_json::to_value(State::default()).unwrap()
    }
    fn fact(zone: &str, at: f64, before: i32, after: i32) -> Value {
        json!({"zone":zone,"transitionAt":at,"before":before,"after":after})
    }
    fn reduce(state: Value, now: f64, authorized: bool, facts: Value, event: Value) -> Value {
        dispatch(
            "dstwatch.reduce",
            json!({"state":state,"now":now,"authorized":authorized,"facts":facts,"event":event}),
        )
        .unwrap()
    }
    fn enabled(facts: Value) -> Value {
        reduce(
            initial(),
            1000.0,
            true,
            facts,
            json!({"kind":"enable","enabled":true}),
        )
    }
    #[test]
    fn disabled_state_has_no_schedule_or_next_wake() {
        let result = dispatch(
            "dstwatch.load",
            json!({"now":1000,"facts":[],"authorized":true}),
        )
        .unwrap();
        assert!(result["nextCheck"].is_null());
        assert_eq!(result["notices"], json!([]));
    }
    #[test]
    fn plans_non_hour_changes_from_system_facts_only() {
        let result = enabled(json!([
            fact("Australia/Lord_Howe", 100000.0, 39600, 37800),
            fact("Antarctica/Troll", 100100.0, 0, 7200),
            fact("Pacific/Apia", 100200.0, -36000, 50400)
        ]));
        assert_eq!(result["notices"].as_array().unwrap().len(), 3);
        assert_eq!(result["notices"][0]["shift"], -1800);
        assert_eq!(result["notices"][1]["shift"], 7200);
        assert_eq!(result["notices"][2]["shift"], 86400);
        assert_eq!(result["notices"][0]["fireAt"], 13600.0);
    }
    #[test]
    fn repeated_cities_and_unchanged_offset_facts_do_not_duplicate() {
        let f = fact("America/New_York", 100000.0, -18000, -14400);
        let result = enabled(json!([
            f.clone(),
            f,
            fact("UTC", 100000.0, 0, 0),
            fact("Old", 999.0, 0, 3600)
        ]));
        assert_eq!(result["notices"].as_array().unwrap().len(), 1);
    }
    #[test]
    fn denied_authorization_keeps_predictions_without_scheduling() {
        let facts = json!([fact("Europe/London", 100000.0, 0, 3600)]);
        let result = reduce(
            initial(),
            1000.0,
            false,
            facts.clone(),
            json!({"kind":"enable","enabled":true}),
        );
        assert_eq!(result["upcoming"].as_array().unwrap().len(), 1);
        assert_eq!(result["notices"], json!([]));
        let allowed = reduce(
            result["state"].clone(),
            90000.0,
            true,
            facts,
            json!({"kind":"refresh"}),
        );
        assert_eq!(allowed["notices"][0]["fireAt"], 90001.0);
    }
    #[test]
    fn accepted_notice_is_not_replayed_after_its_time() {
        let facts = json!([fact("Europe/London", 100000.0, 0, 3600)]);
        let result = enabled(facts.clone());
        let n = &result["notices"][0];
        let accepted = reduce(
            result["state"].clone(),
            1000.0,
            true,
            facts.clone(),
            json!({"kind":"scheduled","receipt":{"id":n["id"],"fireAt":n["fireAt"],"transitionAt":n["transitionAt"]}}),
        );
        let later = reduce(
            accepted["state"].clone(),
            90000.0,
            true,
            facts,
            json!({"kind":"refresh"}),
        );
        assert_eq!(later["notices"], json!([]));
        assert_eq!(later["upcoming"].as_array().unwrap().len(), 1);
    }
    #[test]
    fn deactivation_allows_unfired_notices_to_be_rescheduled() {
        let facts = json!([fact("Europe/London", 100000.0, 0, 3600)]);
        let result = enabled(facts.clone());
        let n = &result["notices"][0];
        let accepted = reduce(
            result["state"].clone(),
            1000.0,
            true,
            facts.clone(),
            json!({"kind":"scheduled","receipt":{"id":n["id"],"fireAt":n["fireAt"],"transitionAt":n["transitionAt"]}}),
        );
        let off = reduce(
            accepted["state"].clone(),
            1001.0,
            true,
            facts.clone(),
            json!({"kind":"deactivate"}),
        );
        assert_eq!(off["notices"], json!([]));
        assert!(off["nextCheck"].is_null());
        let on = reduce(
            off["state"].clone(),
            1002.0,
            true,
            facts,
            json!({"kind":"enable","enabled":true}),
        );
        assert_eq!(on["notices"].as_array().unwrap().len(), 1);
    }
    #[test]
    fn limits_system_requests_to_earliest_32_and_validates_facts() {
        let mut facts: Vec<_> = (0..40)
            .rev()
            .map(|i| fact(&format!("Zone/{i}"), 100000.0 + f64::from(i), 0, 3600))
            .collect();
        facts.push(fact("bad", 100000.0, 0, 86400));
        let result = enabled(json!(facts));
        assert_eq!(result["notices"].as_array().unwrap().len(), 32);
        assert_eq!(result["upcoming"].as_array().unwrap().len(), 40);
        assert_eq!(result["notices"][0]["zone"], "Zone/0");
    }
    #[test]
    fn corrupt_state_and_invalid_lead_are_visible_failures() {
        let result = dispatch(
            "dstwatch.load",
            json!({"now":1000,"facts":[],"stored":"bad"}),
        )
        .unwrap();
        assert_eq!(result["recovered"], true);
        let result = reduce(
            initial(),
            1000.0,
            true,
            json!([]),
            json!({"kind":"lead","seconds":-1}),
        );
        assert_eq!(result["error"], "invalidLead");
        assert_eq!(result["state"], initial());
    }

    /// 性质测试：随机时区事实（含过去的、超出 400 天的、偏移没变的、重复的、脏名字的）与随机回执下，
    /// `plan` 的输出必须——只含未来 400 天内真正换偏移的事实、按（时刻, 时区）去重且排序、每条提醒时刻
    /// 落在 (now, 换钟时刻) 内且等于「换钟前 lead 秒、最早 now+1」或已有回执的时刻、提醒最多 32 条、
    /// 没授权就没有提醒、关着就什么都没有。
    #[test]
    fn random_facts_plan_only_future_deduplicated_notices() {
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
        let mut rng = Xor(0xD57A_7C4E_5EED_0001_u64.wrapping_add(seed_offset));
        let zones = ["Europe/London", "America/New_York", "Australia/Lord_Howe", "Pacific/Auckland", "", "bad\u{0}zone"];
        for i in 0..iterations {
            let now = 1_789_000_000.0 + rng.below(1_000_000) as f64;
            let lead = [3600, 86400, 604800][rng.below(3) as usize];
            let enabled = rng.below(5) != 0;
            let authorized = rng.below(4) != 0;
            let mut facts = Vec::new();
            for _ in 0..rng.below(60) {
                let zone = zones[rng.below(zones.len() as u64) as usize];
                let transition = (now + rng.below(500 * 86_400) as f64 - 50.0 * 86_400.0).floor() + if rng.below(10) == 0 { 0.5 } else { 0.0 };
                let before = (rng.below(25) as i32 - 12) * 3600;
                let after = if rng.below(4) == 0 { before } else { before + if rng.below(2) == 0 { 3600 } else { -3600 } };
                facts.push(Fact { zone: zone.to_owned(), transition_at: transition, before, after });
                if rng.below(3) == 0 {
                    facts.push(Fact { zone: zone.to_owned(), transition_at: transition, before, after }); // 重复
                }
            }
            let mut receipts: Vec<Receipt> = Vec::new();
            for f in &facts {
                if rng.below(5) == 0 {
                    receipts.push(Receipt { id: identifier(f), fire_at: f.transition_at - 1.0 - rng.below(lead as u64) as f64, transition_at: f.transition_at });
                }
            }
            let state = State { version: 1, enabled, lead_seconds: lead, receipts };
            let (upcoming, notices) = plan(&state, &facts, now, authorized);
            let tag = format!("#{i} lead {lead} enabled {enabled} authorized {authorized}");
            if !enabled {
                assert!(upcoming.is_empty() && notices.is_empty(), "{tag}：关着还给了东西");
                continue;
            }
            // 期望集合：干净的、未来 400 天内、偏移真变的事实，按（时刻, 时区）去重。
            let mut expected: Vec<(i64, String)> = facts.iter()
                .filter(|f| !f.zone.is_empty() && !f.zone.chars().any(char::is_control) && f.transition_at.fract() == 0.0
                    && f.transition_at > now && f.transition_at <= now + 400.0 * 86_400.0 && f.before != f.after)
                .map(|f| (f.transition_at as i64, f.zone.clone())).collect();
            expected.sort();
            expected.dedup();
            let got: Vec<(i64, String)> = upcoming.iter().map(|u| (u["transitionAt"].as_f64().unwrap() as i64, u["zone"].as_str().unwrap().to_owned())).collect();
            assert_eq!(got, expected, "{tag}：upcoming 与期望不同");
            assert!(notices.len() <= NOTICE_LIMIT, "{tag}");
            if !authorized { assert!(notices.is_empty(), "{tag}：没授权却排了提醒"); }
            for u in &upcoming {
                let transition = u["transitionAt"].as_f64().unwrap();
                let fire = u["fireAt"].as_f64().unwrap();
                let id = u["id"].as_str().unwrap();
                match state.receipts.iter().find(|r| r.id == id) {
                    Some(r) => { assert_eq!(fire, r.fire_at, "{tag}：有回执的提醒时刻变了"); assert_eq!(u["alreadyScheduled"], true, "{tag}"); }
                    None => { assert_eq!(fire, (transition - lead as f64).max(now + 1.0), "{tag}：提醒时刻不对"); assert_eq!(u["alreadyScheduled"], false, "{tag}"); }
                }
                assert_eq!(u["shift"].as_i64().unwrap(), u["after"].as_i64().unwrap() - u["before"].as_i64().unwrap(), "{tag}");
            }
            // 提醒 = 授权时 upcoming 里提醒时刻落在 (now, 换钟) 内的前 32 条，顺序不变。
            let expected_notices: Vec<&Value> = if authorized {
                upcoming.iter().filter(|u| { let f = u["fireAt"].as_f64().unwrap(); f > now && f < u["transitionAt"].as_f64().unwrap() }).take(NOTICE_LIMIT).collect()
            } else { vec![] };
            assert_eq!(notices.iter().collect::<Vec<_>>(), expected_notices, "{tag}：提醒集合不对");
        }
    }
}
