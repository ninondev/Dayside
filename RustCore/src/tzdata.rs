// SPDX-License-Identifier: GPL-3.0-only
//! Is the Mac's own time zone database behind the world? Governments change clock rules on short
//! notice (Mexico 2022, Egypt 2023, Kazakhstan 2024, Paraguay 2024) and a Mac that has not updated
//! keeps computing meeting times with the old rule. This module carries a curated table of known
//! rule changes: for each, an instant after the change and the UTC offset the current rules give.
//! The host asks Foundation what the installed data says at that instant; a mismatch means the
//! installed data predates the change. The table only states facts about published rules; it never
//! overrides the system clock.
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

/// Rule changes the table knows about were verified against tzdata 2026c on 2026-09-11, 2026-09-12 and 2026-09-16.
/// 2026-09 = tzdata 2026c (Alberta year-round UTC−6, Morocco year-round UTC+0 from 2026-09-20); 2026d (2026-09-11,
/// Inuvik year-round UTC−6) is not on this Mac yet (2026-09-16 probe gave −420 MST), so not listed.
pub const COVERAGE: &str = "2026-09";

struct RuleChange {
    zone: &'static str,
    /// ISO-8601 instant safely after the change took effect.
    probe: &'static str,
    /// Total UTC offset (standard + any DST) the current rules give at `probe`, in minutes.
    expected_minutes: i32,
    /// Year-month the rule took effect, for the person reading the warning.
    since: &'static str,
}

const KNOWN_RULE_CHANGES: &[RuleChange] = &[
    RuleChange { zone: "America/Mexico_City", probe: "2023-07-01T12:00:00Z", expected_minutes: -360, since: "2022-10" },
    RuleChange { zone: "America/Chihuahua", probe: "2023-07-01T12:00:00Z", expected_minutes: -360, since: "2022-10" },
    RuleChange { zone: "America/Ojinaga", probe: "2023-07-01T12:00:00Z", expected_minutes: -300, since: "2022-11" },
    RuleChange { zone: "America/Cancun", probe: "2023-07-01T12:00:00Z", expected_minutes: -300, since: "2015-02" },
    RuleChange { zone: "Africa/Cairo", probe: "2023-07-01T12:00:00Z", expected_minutes: 180, since: "2023-04" },
    RuleChange { zone: "Asia/Almaty", probe: "2024-07-01T12:00:00Z", expected_minutes: 300, since: "2024-03" },
    RuleChange { zone: "Asia/Qostanay", probe: "2024-07-01T12:00:00Z", expected_minutes: 300, since: "2024-03" },
    RuleChange { zone: "America/Asuncion", probe: "2025-07-01T12:00:00Z", expected_minutes: -180, since: "2024-10" },
    RuleChange { zone: "Asia/Tehran", probe: "2023-07-01T12:00:00Z", expected_minutes: 210, since: "2022-09" },
    RuleChange { zone: "America/Whitehorse", probe: "2021-07-01T12:00:00Z", expected_minutes: -420, since: "2020-11" },
    RuleChange { zone: "Pacific/Fiji", probe: "2023-01-15T12:00:00Z", expected_minutes: 720, since: "2022-11" },
    RuleChange { zone: "Asia/Amman", probe: "2023-01-15T12:00:00Z", expected_minutes: 180, since: "2022-10" },
    RuleChange { zone: "Asia/Damascus", probe: "2023-01-15T12:00:00Z", expected_minutes: 180, since: "2022-10" },
    RuleChange { zone: "America/Nuuk", probe: "2024-07-01T12:00:00Z", expected_minutes: -60, since: "2023-03" },
    RuleChange { zone: "America/Nuuk", probe: "2024-01-15T12:00:00Z", expected_minutes: -120, since: "2023-03" },
    RuleChange { zone: "America/Sao_Paulo", probe: "2020-01-15T12:00:00Z", expected_minutes: -180, since: "2019-04" },
    RuleChange { zone: "Europe/Istanbul", probe: "2017-07-01T12:00:00Z", expected_minutes: 180, since: "2016-09" },
    RuleChange { zone: "Asia/Pyongyang", probe: "2019-07-01T12:00:00Z", expected_minutes: 540, since: "2018-05" },
    RuleChange { zone: "Africa/Juba", probe: "2021-07-01T12:00:00Z", expected_minutes: 120, since: "2021-02" },
    RuleChange { zone: "Europe/Volgograd", probe: "2021-07-01T12:00:00Z", expected_minutes: 180, since: "2020-12" },
    RuleChange { zone: "Pacific/Apia", probe: "2022-01-15T12:00:00Z", expected_minutes: 780, since: "2021-09" },
    RuleChange { zone: "Pacific/Norfolk", probe: "2024-01-15T12:00:00Z", expected_minutes: 720, since: "2019-10" },
    // Alberta stops changing clocks after 2026-11-01 and stays on UTC−6 (tzdata 2026c; America/Yellowknife and
    // Canada/Mountain link here). Verified with zoneinfo on this Mac: 2026-11-15 → −360 CST, 2027-07-15 → −360 CST.
    RuleChange { zone: "America/Edmonton", probe: "2027-01-15T12:00:00Z", expected_minutes: -360, since: "2026-11" },
    // Additional rule changes, each row verified with Python zoneinfo against tzdata 2026c:
    // Morocco and Western Sahara stay on UTC+0 from 2026-09-20 (tzdata 2026c); British Columbia stays on UTC−7 after
    // 2026-11-01 (2026b, modelled at 2026-11-01 02:00, winter probe because a summer one cannot tell old from new);
    // Moldova follows the EU transition instants since 2022 (2026a; old rules give 180 / 120 at these probes);
    // Aysén (Coyhaique) year-round UTC−3 (2025b, a zone older data does not know); Ittoqqortoormiit −2/−1 (2023d);
    // Vostok +5 and Casey +8 (2023d); Ciudad Juárez follows US rules (2022g, also unknown to older data);
    // Beirut is a control for the withdrawn 2023b Lebanon delay.
    RuleChange { zone: "Africa/Casablanca", probe: "2026-10-15T12:00:00Z", expected_minutes: 0, since: "2026-09" },
    RuleChange { zone: "Africa/El_Aaiun", probe: "2026-10-15T12:00:00Z", expected_minutes: 0, since: "2026-09" },
    RuleChange { zone: "America/Vancouver", probe: "2027-01-15T12:00:00Z", expected_minutes: -420, since: "2026-11" },
    RuleChange { zone: "Europe/Chisinau", probe: "2027-03-28T00:30:00Z", expected_minutes: 120, since: "2022-03" },
    RuleChange { zone: "Europe/Chisinau", probe: "2026-10-25T00:30:00Z", expected_minutes: 180, since: "2022-10" },
    RuleChange { zone: "America/Coyhaique", probe: "2025-07-15T12:00:00Z", expected_minutes: -180, since: "2025-03" },
    RuleChange { zone: "America/Scoresbysund", probe: "2025-01-15T12:00:00Z", expected_minutes: -120, since: "2024-03" },
    RuleChange { zone: "America/Scoresbysund", probe: "2024-07-15T12:00:00Z", expected_minutes: -60, since: "2024-03" },
    RuleChange { zone: "Antarctica/Vostok", probe: "2024-07-15T12:00:00Z", expected_minutes: 300, since: "2023-12" },
    RuleChange { zone: "Antarctica/Casey", probe: "2025-01-15T12:00:00Z", expected_minutes: 480, since: "2023-12" },
    RuleChange { zone: "America/Ciudad_Juarez", probe: "2024-01-15T12:00:00Z", expected_minutes: -420, since: "2022-11" },
    RuleChange { zone: "Asia/Beirut", probe: "2023-07-15T12:00:00Z", expected_minutes: 180, since: "2023-03" },
    // Controls: zones whose rules did not change; a mismatch here means broken data, not old data.
    RuleChange { zone: "Europe/Kyiv", probe: "2024-07-01T12:00:00Z", expected_minutes: 180, since: "1996-03" },
    RuleChange { zone: "America/Santiago", probe: "2024-07-01T12:00:00Z", expected_minutes: -240, since: "2019-04" },
    RuleChange { zone: "Australia/Lord_Howe", probe: "2024-01-15T12:00:00Z", expected_minutes: 660, since: "1985-10" },
    RuleChange { zone: "Asia/Kuala_Lumpur", probe: "2024-07-01T12:00:00Z", expected_minutes: 480, since: "1982-01" },
];

#[derive(Deserialize)]
struct Observation {
    zone: String,
    at: String,
    #[serde(rename = "offsetMinutes")]
    offset_minutes: Option<i32>,
}

#[derive(Serialize, Deserialize, Debug, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Stale {
    pub zone: String,
    pub since: String,
    pub expected_minutes: i32,
    pub observed_minutes: i32,
}

fn probes() -> Value {
    let list: Vec<Value> = KNOWN_RULE_CHANGES
        .iter()
        .map(|c| json!({"zone": c.zone, "at": c.probe}))
        .collect();
    json!({"probes": list, "coverage": COVERAGE, "count": KNOWN_RULE_CHANGES.len()})
}

fn check(payload: &Value) -> Result<Value, String> {
    let version = payload.get("version").and_then(Value::as_str).map(str::to_owned);
    let observed: Vec<Observation> = match payload.get("observed") {
        Some(v) => serde_json::from_value(v.clone()).map_err(|e| e.to_string())?,
        None => Vec::new(),
    };
    let mut stale = Vec::new();
    let mut unknown = Vec::new();
    let mut checked = 0usize;
    for change in KNOWN_RULE_CHANGES {
        let seen = observed
            .iter()
            .find(|o| o.zone == change.zone && o.at == change.probe)
            .and_then(|o| o.offset_minutes);
        match seen {
            None => unknown.push(change.zone.to_owned()),
            Some(minutes) => {
                checked += 1;
                if minutes != change.expected_minutes {
                    stale.push(Stale {
                        zone: change.zone.to_owned(),
                        since: change.since.to_owned(),
                        expected_minutes: change.expected_minutes,
                        observed_minutes: minutes,
                    });
                }
            }
        }
    }
    Ok(json!({
        "version": version,
        "coverage": COVERAGE,
        "checked": checked,
        "stale": stale,
        "unknown": unknown,
    }))
}

pub fn dispatch(operation: &str, payload: Value) -> Result<Value, String> {
    match operation {
        "tzdata.probes" => Ok(probes()),
        "tzdata.check" => check(&payload),
        _ => Err(format!("Unknown tzdata operation: {operation}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn all_correct() -> Vec<Value> {
        KNOWN_RULE_CHANGES
            .iter()
            .map(|c| json!({"zone": c.zone, "at": c.probe, "offsetMinutes": c.expected_minutes}))
            .collect()
    }

    #[test]
    fn probes_list_every_known_change_with_its_instant() {
        let p = probes();
        assert_eq!(p["count"].as_u64().unwrap() as usize, KNOWN_RULE_CHANGES.len());
        assert_eq!(p["probes"].as_array().unwrap().len(), KNOWN_RULE_CHANGES.len());
        assert_eq!(p["probes"][0]["zone"], "America/Mexico_City");
        assert!(p["probes"][0]["at"].as_str().unwrap().ends_with('Z'));
        assert_eq!(p["coverage"], COVERAGE);
    }

    #[test]
    fn data_that_matches_every_change_is_current_and_data_that_misses_one_is_named() {
        let ok = check(&json!({"version": "2026c", "observed": all_correct()})).unwrap();
        assert_eq!(ok["version"], "2026c");
        assert_eq!(ok["checked"].as_u64().unwrap() as usize, KNOWN_RULE_CHANGES.len());
        assert_eq!(ok["stale"].as_array().unwrap().len(), 0);
        assert_eq!(ok["unknown"].as_array().unwrap().len(), 0);

        // A Mac whose data predates Kazakhstan's 2024 change still reports +6 at the probe.
        let mut observed = all_correct();
        for o in observed.iter_mut() {
            if o["zone"] == "Asia/Almaty" {
                o["offsetMinutes"] = json!(360);
            }
        }
        let old = check(&json!({"version": "2023c", "observed": observed})).unwrap();
        let stale: Vec<Stale> = serde_json::from_value(old["stale"].clone()).unwrap();
        assert_eq!(
            stale,
            vec![Stale { zone: "Asia/Almaty".into(), since: "2024-03".into(), expected_minutes: 300, observed_minutes: 360 }]
        );
    }

    #[test]
    fn missing_and_foreign_observations_are_reported_not_guessed() {
        let mut observed = all_correct();
        observed.retain(|o| o["zone"] != "Pacific/Apia" && o["zone"] != "Africa/Cairo");
        observed.push(json!({"zone": "Mars/Olympus", "at": "2030-01-01T00:00:00Z", "offsetMinutes": 0}));
        observed.push(json!({"zone": "Africa/Cairo", "at": "2023-07-01T12:00:00Z"}));
        let r = check(&json!({"observed": observed})).unwrap();
        assert!(r["version"].is_null());
        let unknown = r["unknown"].as_array().unwrap();
        assert!(unknown.contains(&json!("Pacific/Apia")));
        assert!(unknown.contains(&json!("Africa/Cairo")), "an observation without an offset counts as unknown");
        assert_eq!(r["stale"].as_array().unwrap().len(), 0);
        assert_eq!(r["checked"].as_u64().unwrap() as usize, KNOWN_RULE_CHANGES.len() - 2);
    }

    #[test]
    fn table_rows_are_well_formed() {
        for c in KNOWN_RULE_CHANGES {
            assert!(c.zone.contains('/'), "{}", c.zone);
            assert!(c.probe.len() == 20 && c.probe.ends_with('Z'), "{}", c.probe);
            assert!(c.since.len() == 7 && &c.since[4..5] == "-", "{}", c.since);
            assert!(c.expected_minutes % 15 == 0 && c.expected_minutes.abs() <= 14 * 60);
        }
    }
}
