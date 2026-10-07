// SPDX-License-Identifier: GPL-3.0-only
use serde::Deserialize;
use serde_json::{json, Value};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Input { command: Command, now: f64, zone_valid: bool }
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Command { version: u32, id: String, created_at: f64, action: String, arguments: std::collections::BTreeMap<String, String> }

pub fn dispatch(_: &str, value: Value) -> Result<Value, String> {
    let input: Input = serde_json::from_value(value).map_err(|e| e.to_string())?;
    let c = input.command;
    let arg = |key: &str| c.arguments.get(key).map(String::as_str).unwrap_or("");
    let error = if c.version != 1 || c.id.len() != 36 || c.arguments.len() > 8 {
        Some("invalidCommand")
    } else if !input.now.is_finite() || !c.created_at.is_finite() || c.created_at > input.now + 60.0 || input.now - c.created_at > 86_400.0 {
        Some("expiredCommand")
    } else {
        match c.action.as_str() {
            "addPlace" if input.zone_valid && !arg("timeZoneID").is_empty() && arg("name").len() <= 160 && !arg("name").chars().any(char::is_control) => None,
            "primary" if arg("id").len() == 36 || (input.zone_valid && !arg("timeZoneID").is_empty()) => None,
            "timer" if arg("minutes").parse::<u32>().is_ok_and(|n| (1..=1440).contains(&n)) => None,
            "pomodoro" => None,
            "convert" if !arg("text").is_empty() && arg("text").len() <= 2048 => None,
            "tools" if matches!(arg("feature"), "" | "planner" | "agenda" | "people" | "convert" | "timers" | "dstWatch" | "astronomy" | "markets" | "travel" | "sharing") => None,
            _ => Some("invalidCommand"),
        }
    };
    Ok(json!({"error": error}))
}

#[cfg(test)] mod tests {
    use super::*;
    fn run(action: &str, args: Value, at: f64, valid: bool) -> Value {
        dispatch("automation.validate", json!({"now": 200000.0,"zoneValid":valid,"command":{"version":1,"id":"12345678-1234-1234-1234-123456789012","createdAt":at,"action":action,"arguments":args}})).unwrap()
    }
    #[test] fn stale_or_future_commands_are_rejected() {
        assert_eq!(run("pomodoro",json!({}),100000.0,true)["error"],"expiredCommand");
        assert_eq!(run("pomodoro",json!({}),200061.0,true)["error"],"expiredCommand");
    }
    #[test] fn primary_accepts_a_place_uuid_or_a_validated_time_zone() {
        assert!(run("primary",json!({"id":"12345678-1234-1234-1234-123456789012"}),200000.0,false)["error"].is_null());
        assert!(run("primary",json!({"timeZoneID":"Asia/Tokyo"}),200000.0,true)["error"].is_null());
        assert!(run("primary",json!({"timeZoneID":"Asia/Nowhere"}),200000.0,false)["error"].is_string());
        assert!(run("primary",json!({}),200000.0,true)["error"].is_string());
    }
    #[test] fn native_zone_validation_and_duration_bounds_are_required() {
        assert!(run("addPlace",json!({"timeZoneID":"bad"}),200000.0,false)["error"].is_string());
        assert!(run("timer",json!({"minutes":"-1"}),200000.0,true)["error"].is_string());
        assert!(run("timer",json!({"minutes":"25"}),200000.0,true)["error"].is_null());
        // 市场时钟在页面白名单中；不存在的页名拒绝。
        assert!(run("tools",json!({"feature":"markets"}),200000.0,true)["error"].is_null());
        assert!(run("tools",json!({"feature":"casino"}),200000.0,true)["error"].is_string());
    }
}
