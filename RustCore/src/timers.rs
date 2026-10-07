// SPDX-License-Identifier: GPL-3.0-only
//! One user-owned timer session. Clock readings and notifications are host services.
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

const MAX_DURATION: f64 = 31.0 * 86400.0;
const MAX_ELAPSED: f64 = 100.0 * 366.0 * 86400.0;

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct Clock {
    wall: f64,
    continuous: f64,
    boot_id: String,
}

impl Clock {
    fn valid(&self) -> bool {
        self.wall.is_finite()
            && (-62_135_596_800.0..253_402_300_800.0).contains(&self.wall)
            && self.continuous.is_finite()
            && self.continuous >= 0.0
            && !self.boot_id.is_empty()
            && self.boot_id.len() <= 128
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct Spec {
    mode: String,
    label: String,
    duration: f64,
    focus: f64,
    short_break: f64,
    long_break: f64,
    rounds: u8,
    alarm_at: Option<f64>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "optional_text"
    )]
    alarm_zone: Option<String>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "optional_text"
    )]
    alarm_place: Option<String>,
}

fn optional_text<'de, D: serde::Deserializer<'de>>(d: D) -> Result<Option<String>, D::Error> {
    Ok(Value::deserialize(d)?.as_str().map(str::to_owned))
}

impl Spec {
    fn normalize_place(&mut self) {
        if self.mode != "alarm" {
            self.alarm_zone = None;
            self.alarm_place = None;
            return;
        }
        self.alarm_zone = self.alarm_zone.take().filter(|s| {
            (1..=64).contains(&s.len())
                && s.bytes()
                    .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'+' | b'-' | b'/'))
        });
        self.alarm_place = self
            .alarm_place
            .take()
            .filter(|s| (1..=80).contains(&s.chars().count()) && !s.chars().any(char::is_control));
    }

    fn validate(&self, now: f64, starting: bool) -> Result<(), &'static str> {
        if ![self.duration, self.focus, self.short_break, self.long_break]
            .iter()
            .all(|n| n.is_finite())
        {
            return Err("invalidDuration");
        }
        if self.label.chars().count() > 120 || self.label.chars().any(char::is_control) {
            return Err("invalidLabel");
        }
        let duration = |value: f64| value.is_finite() && (1.0..=MAX_DURATION).contains(&value);
        match self.mode.as_str() {
            "countdown" if duration(self.duration) => Ok(()),
            "stopwatch" => Ok(()),
            "pomodoro"
                if duration(self.focus)
                    && duration(self.short_break)
                    && duration(self.long_break)
                    && (1..=12).contains(&self.rounds)
                    && self.total() <= MAX_DURATION =>
            {
                Ok(())
            }
            "alarm" => match self.alarm_at {
                Some(value)
                    if value.is_finite()
                        && (-62_135_596_800.0..253_402_300_800.0).contains(&value)
                        && (!starting || value > now) =>
                {
                    Ok(())
                }
                Some(value) if value <= now && starting => Err("alarmInPast"),
                _ => Err("invalidAlarm"),
            },
            _ => Err("invalidDuration"),
        }
    }

    fn phases(&self) -> Vec<(&'static str, u8, f64)> {
        if self.mode != "pomodoro" {
            return vec![];
        }
        let mut phases = Vec::new();
        for round in 1..=self.rounds {
            phases.push(("focus", round, self.focus));
            if round < self.rounds {
                phases.push((
                    if round % 4 == 0 {
                        "longBreak"
                    } else {
                        "shortBreak"
                    },
                    round,
                    if round % 4 == 0 {
                        self.long_break
                    } else {
                        self.short_break
                    },
                ));
            }
        }
        phases
    }

    fn total(&self) -> f64 {
        match self.mode.as_str() {
            "pomodoro" => self.phases().iter().map(|p| p.2).sum(),
            "countdown" => self.duration,
            _ => MAX_ELAPSED,
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct Session {
    id: String,
    spec: Spec,
    status: String,
    elapsed: f64,
    started_at: f64,
    continuous_at: f64,
    boot_id: String,
    /// 已记进账本的完整专注段数；老状态没有这个字段就当 0。
    #[serde(default)]
    credited_focus: u8,
}

impl Session {
    fn elapsed_at(&self, clock: &Clock) -> f64 {
        if self.status != "running" {
            return self.elapsed;
        }
        let delta = if self.boot_id == clock.boot_id && clock.continuous >= self.continuous_at {
            clock.continuous - self.continuous_at
        } else {
            (clock.wall - self.started_at).max(0.0)
        };
        (self.elapsed + delta).min(MAX_ELAPSED)
    }

    fn rebase(&mut self, clock: &Clock) {
        self.elapsed = self.elapsed_at(clock);
        self.started_at = clock.wall;
        self.continuous_at = clock.continuous;
        self.boot_id.clone_from(&clock.boot_id);
    }

    fn valid(&self) -> bool {
        !self.id.is_empty()
            && self.id.len() <= 128
            && self
                .id
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-')
            && matches!(self.status.as_str(), "running" | "paused" | "completed")
            && self.elapsed.is_finite()
            && (0.0..=MAX_ELAPSED).contains(&self.elapsed)
            && Clock {
                wall: self.started_at,
                continuous: self.continuous_at,
                boot_id: self.boot_id.clone(),
            }
            .valid()
            && self.spec.validate(self.started_at, false).is_ok()
    }
}

/// 番茄钟账本：只记做完的专注段（中途取消的不算，经典规则），每条是结束时刻与时长。
/// 92 天以前的条目在每次刷新时清掉，条数封顶 5,000；坏条目在加载时丢掉、不连累会话。
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct LedgerEntry {
    ended_at: f64,
    seconds: f64,
}

const LEDGER_DAYS: f64 = 92.0;
const LEDGER_CAP: usize = 5_000;

impl LedgerEntry {
    fn valid(&self) -> bool {
        self.ended_at.is_finite()
            && (-62_135_596_800.0..253_402_300_800.0).contains(&self.ended_at)
            && self.seconds.is_finite()
            && (1.0..=MAX_DURATION).contains(&self.seconds)
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
struct State {
    version: u8,
    notifications: bool,
    session: Option<Session>,
    #[serde(default)]
    ledger: Vec<LedgerEntry>,
}

impl Default for State {
    fn default() -> Self {
        Self {
            version: 1,
            notifications: false,
            session: None,
            ledger: vec![],
        }
    }
}

/// 把已经整段走完的专注段记进账本：按当前 elapsed 数完整的专注段，比 `credited_focus` 多出来的逐段入账，
/// 结束时刻由「现在 − (elapsed − 段末)」反推，所以 App 没开着时做完的段也能记对时间。
fn credit_focus(state: &mut State, clock: &Clock) {
    let Some(session) = state.session.as_mut() else {
        return;
    };
    if session.spec.mode != "pomodoro" {
        return;
    }
    let elapsed = session.elapsed_at(clock);
    let mut end = 0.0;
    let mut completed: Vec<(f64, f64)> = vec![];
    for (name, _, duration) in session.spec.phases() {
        end += duration;
        if name == "focus" && elapsed >= end {
            completed.push((end, duration));
        }
    }
    let credited = session.credited_focus as usize;
    if completed.len() <= credited {
        return;
    }
    for (phase_end, duration) in &completed[credited..] {
        state.ledger.push(LedgerEntry {
            ended_at: clock.wall - (elapsed - phase_end),
            seconds: *duration,
        });
    }
    session.credited_focus = completed.len() as u8;
}

fn prune_ledger(state: &mut State, clock: &Clock) {
    let floor = clock.wall - LEDGER_DAYS * 86_400.0;
    state
        .ledger
        .retain(|entry| entry.valid() && entry.ended_at >= floor);
    if state.ledger.len() > LEDGER_CAP {
        let excess = state.ledger.len() - LEDGER_CAP;
        state.ledger.drain(..excess);
    }
}

/// 宿主给若干个真实民用日的边界（今天在前），这里只做计数与求和。
fn ledger_summary(state: &State, days: &Value) -> Value {
    let Some(days) = days.as_array() else {
        return Value::Null;
    };
    let rows: Vec<Value> = days
        .iter()
        .take(31)
        .map(|day| {
            let start = day["start"].as_f64().unwrap_or(f64::NAN);
            let end = day["end"].as_f64().unwrap_or(f64::NAN);
            if !start.is_finite() || !end.is_finite() || end <= start {
                return json!({"focusCount": 0, "focusSeconds": 0.0});
            }
            let hits = state
                .ledger
                .iter()
                .filter(|e| e.ended_at >= start && e.ended_at < end);
            let (count, seconds) = hits.fold((0u32, 0.0f64), |(c, s), e| (c + 1, s + e.seconds));
            json!({"focusCount": count, "focusSeconds": seconds})
        })
        .collect();
    json!({"days": rows, "entries": state.ledger.len()})
}

fn refresh(state: &mut State, clock: &Clock) {
    credit_focus(state, clock);
    prune_ledger(state, clock);
    if let Some(session) = state.session.as_mut() {
        if session.status != "running" {
            return;
        }
        if session.boot_id != clock.boot_id || clock.continuous < session.continuous_at {
            session.rebase(clock);
        }
        let complete = if session.spec.mode == "alarm" {
            session
                .spec
                .alarm_at
                .is_some_and(|target| target <= clock.wall)
        } else {
            session.spec.mode != "stopwatch" && session.elapsed_at(clock) >= session.spec.total()
        };
        if complete {
            session.rebase(clock);
            if session.spec.mode != "alarm" {
                session.elapsed = session.spec.total();
            }
            session.status = "completed".to_owned();
        }
    }
}

fn digital(seconds: f64) -> String {
    let seconds = seconds.max(0.0).ceil().min(MAX_ELAPSED) as u64;
    if seconds >= 3600 {
        format!(
            "{}:{:02}:{:02}",
            seconds / 3600,
            seconds % 3600 / 60,
            seconds % 60
        )
    } else {
        format!("{:02}:{:02}", seconds / 60, seconds % 60)
    }
}

fn project(state: &State, clock: &Clock) -> (Value, Vec<Value>) {
    let Some(session) = &state.session else {
        return (Value::Null, vec![]);
    };
    let elapsed = session.elapsed_at(clock);
    let mut phase = session.spec.mode.as_str();
    let mut round = 0;
    let remaining = match session.spec.mode.as_str() {
        "alarm" => (session.spec.alarm_at.unwrap_or(clock.wall) - clock.wall).max(0.0),
        "stopwatch" => elapsed,
        "pomodoro" => {
            let mut end = 0.0;
            let mut remaining = 0.0;
            for (name, index, duration) in session.spec.phases() {
                end += duration;
                if elapsed < end {
                    phase = name;
                    round = index;
                    remaining = end - elapsed;
                    break;
                }
            }
            remaining
        }
        _ => (session.spec.duration - elapsed).max(0.0),
    };
    if session.status == "completed" {
        phase = "completed";
    }
    let view = json!({
        "phase": phase, "round": round, "rounds": session.spec.rounds,
        "seconds": remaining, "display": digital(if session.spec.mode == "stopwatch" { remaining.floor() } else { remaining }),
        "canPause": session.status == "running", "canResume": session.status == "paused",
        "isRunning": session.status == "running", "isCompleted": session.status == "completed"
    });
    let mut notices = vec![];
    if !state.notifications || session.status != "running" {
        return (view, notices);
    }
    let notice = |index: usize, fire_at: f64, kind: &str, round: u8| {
        json!({
            "id": format!("meantime.timer.{}.{}", session.id, index),
            "fireAt": fire_at, "kind": kind, "round": round, "label": session.spec.label
        })
    };
    match session.spec.mode.as_str() {
        "countdown" => notices.push(notice(0, clock.wall + remaining, "countdown", 0)),
        "alarm" => notices.push(notice(
            0,
            session.spec.alarm_at.unwrap_or(clock.wall),
            "alarm",
            0,
        )),
        "pomodoro" => {
            let phases = session.spec.phases();
            let mut end = 0.0;
            for (index, (_, round, duration)) in phases.iter().enumerate() {
                end += duration;
                if end > elapsed {
                    let kind = phases.get(index + 1).map_or("completed", |p| p.0);
                    notices.push(notice(index, clock.wall + end - elapsed, kind, *round));
                }
            }
        }
        _ => {}
    }
    (view, notices)
}

fn output(
    state: State,
    old: &State,
    clock: &Clock,
    error: Option<&str>,
    recovered: bool,
    days: &Value,
) -> Value {
    let (view, notices) = project(&state, clock);
    let ledger = ledger_summary(&state, days);
    json!({"changed": state != *old, "state": state, "view": view, "notices": notices,
        "error": error, "recovered": recovered, "ledger": ledger})
}

pub fn dispatch(operation: &str, payload: Value) -> Result<Value, String> {
    let clock: Clock =
        serde_json::from_value(payload["clock"].clone()).map_err(|e| e.to_string())?;
    if !clock.valid() {
        return Err("Invalid timer clock facts".to_owned());
    }
    if operation == "timers.load" {
        let stored = payload["stored"].as_str().filter(|s| !s.is_empty());
        let decoded = stored
            .and_then(|s| serde_json::from_str::<State>(s).ok())
            .filter(|s| s.version == 1 && s.session.as_ref().is_none_or(Session::valid));
        let recovered = stored.is_some() && decoded.is_none();
        let mut state = decoded.unwrap_or_default();
        if let Some(session) = &mut state.session {
            session.spec.normalize_place();
        }
        let old = state.clone();
        refresh(&mut state, &clock);
        return Ok(output(
            state,
            &old,
            &clock,
            None,
            recovered,
            &payload["days"],
        ));
    }
    if operation != "timers.reduce" {
        return Err(format!("Unknown timer operation: {operation}"));
    }
    let mut state: State =
        serde_json::from_value(payload["state"].clone()).map_err(|e| e.to_string())?;
    if state.version != 1 || !state.session.as_ref().is_none_or(Session::valid) {
        return Err("Invalid timer state".to_owned());
    }
    if let Some(session) = &mut state.session {
        session.spec.normalize_place();
    }
    let old = state.clone();
    refresh(&mut state, &clock);
    let event = &payload["event"];
    let kind = event["kind"].as_str().unwrap_or("");
    let mut error = None;
    match kind {
        "refresh" => {}
        "notifications" => state.notifications = event["enabled"].as_bool().unwrap_or(false),
        "cancel" => state.session = None,
        // 关掉透镜清会话与通知开关，账本留着：它是用户的历史，不是这次会话的资源。
        "deactivate" => {
            state = State {
                ledger: state.ledger.clone(),
                ..State::default()
            }
        }
        "start" => {
            if state
                .session
                .as_ref()
                .is_some_and(|s| s.status != "completed")
            {
                error = Some("activeSession");
            } else if let Ok(mut spec) = serde_json::from_value::<Spec>(event["spec"].clone()) {
                spec.label = spec.label.trim().to_owned();
                spec.normalize_place();
                match spec.validate(clock.wall, true) {
                    Err(code) => error = Some(code),
                    Ok(()) => {
                        state.session = Some(Session {
                            id: uuid::Uuid::new_v4().to_string(),
                            spec,
                            status: "running".to_owned(),
                            elapsed: 0.0,
                            started_at: clock.wall,
                            continuous_at: clock.continuous,
                            boot_id: clock.boot_id.clone(),
                            credited_focus: 0,
                        })
                    }
                }
            } else {
                error = Some("invalidDuration");
            }
        }
        "pause" => {
            if let Some(session) = state.session.as_mut() {
                if session.status == "running" {
                    session.rebase(&clock);
                    session.status = "paused".to_owned();
                }
            }
        }
        "resume" => {
            if let Some(session) = state.session.as_mut() {
                if session.status == "paused" {
                    session.started_at = clock.wall;
                    session.continuous_at = clock.continuous;
                    session.boot_id.clone_from(&clock.boot_id);
                    session.status = "running".to_owned();
                    refresh(&mut state, &clock);
                }
            }
        }
        "restart" => {
            if let Some(session) = state.session.as_mut() {
                if let Err(code) = session.spec.validate(clock.wall, true) {
                    error = Some(code);
                } else {
                    session.id = uuid::Uuid::new_v4().to_string();
                    session.elapsed = 0.0;
                    session.started_at = clock.wall;
                    session.continuous_at = clock.continuous;
                    session.boot_id.clone_from(&clock.boot_id);
                    session.status = "running".to_owned();
                    session.credited_focus = 0;
                }
            }
        }
        _ => error = Some("invalidAction"),
    }
    Ok(output(state, &old, &clock, error, false, &payload["days"]))
}

#[cfg(test)]
mod tests {
    use super::*;
    fn clock(wall: f64, continuous: f64, boot: &str) -> Clock {
        Clock {
            wall,
            continuous,
            boot_id: boot.to_owned(),
        }
    }
    fn initial() -> Value {
        serde_json::to_value(State::default()).unwrap()
    }
    fn reduce(state: Value, clock: Clock, event: Value) -> Value {
        dispatch(
            "timers.reduce",
            json!({"state": state, "clock": clock, "event": event}),
        )
        .unwrap()
    }
    fn spec(mode: &str) -> Value {
        json!({"mode": mode, "label": "", "duration": 60.0, "focus": 20.0, "shortBreak": 5.0, "longBreak": 15.0, "rounds": 5, "alarmAt": 2000.0})
    }
    fn start(mode: &str) -> Value {
        reduce(
            initial(),
            clock(1000.0, 100.0, "a"),
            json!({"kind":"start", "spec": spec(mode)}),
        )
    }

    #[test]
    fn default_is_inactive_and_never_plans_notifications() {
        let result = dispatch("timers.load", json!({"clock": clock(0.0, 0.0, "a")})).unwrap();
        assert!(result["view"].is_null());
        assert_eq!(result["notices"], json!([]));
        assert_eq!(result["state"]["notifications"], false);
    }
    #[test]
    fn continuous_time_survives_wall_clock_changes_and_sleep() {
        let state = start("countdown")["state"].clone();
        let result = reduce(
            state.clone(),
            clock(-1000.0, 130.0, "a"),
            json!({"kind":"refresh"}),
        );
        assert_eq!(result["view"]["seconds"], 30.0);
        let result = reduce(state, clock(1020.0, 180.0, "a"), json!({"kind":"refresh"}));
        assert_eq!(result["view"]["isCompleted"], true);
        assert!(result["notices"].as_array().unwrap().is_empty());
    }
    #[test]
    fn pause_resume_and_restart_preserve_user_control() {
        let running = start("countdown");
        let paused = reduce(
            running["state"].clone(),
            clock(1020.0, 120.0, "a"),
            json!({"kind":"pause"}),
        );
        assert_eq!(paused["view"]["seconds"], 40.0);
        let later = reduce(
            paused["state"].clone(),
            clock(5000.0, 500.0, "a"),
            json!({"kind":"refresh"}),
        );
        assert_eq!(later["view"]["seconds"], 40.0);
        let resumed = reduce(
            later["state"].clone(),
            clock(5000.0, 500.0, "a"),
            json!({"kind":"resume"}),
        );
        let ended = reduce(
            resumed["state"].clone(),
            clock(5041.0, 541.0, "a"),
            json!({"kind":"refresh"}),
        );
        assert_eq!(ended["view"]["isCompleted"], true);
        let restarted = reduce(
            ended["state"].clone(),
            clock(5041.0, 541.0, "a"),
            json!({"kind":"restart"}),
        );
        assert_eq!(restarted["view"]["seconds"], 60.0);
        assert_ne!(
            restarted["state"]["session"]["id"],
            running["state"]["session"]["id"]
        );
    }
    #[test]
    fn reload_and_reboot_expire_without_replaying_old_alerts() {
        let running = start("countdown");
        let result = dispatch("timers.load", json!({"stored": running["state"].to_string(), "clock": clock(1100.0, 2.0, "new-boot")})).unwrap();
        assert_eq!(result["view"]["isCompleted"], true);
        assert_eq!(result["notices"], json!([]));
        let within = dispatch("timers.load", json!({"stored": running["state"].to_string(), "clock": clock(1010.0, 2.0, "new-boot")})).unwrap();
        assert_eq!(within["view"]["seconds"], 50.0);
    }
    #[test]
    fn pomodoro_advances_all_phases_without_background_ticks() {
        let mut state = start("pomodoro")["state"].clone();
        let planned = reduce(
            state.clone(),
            clock(1000.0, 100.0, "a"),
            json!({"kind":"notifications", "enabled":true}),
        );
        assert_eq!(planned["notices"].as_array().unwrap().len(), 9);
        assert_eq!(planned["notices"][7]["kind"], "focus");
        assert_eq!(planned["notices"][8]["fireAt"], 1130.0);
        state = planned["state"].clone();
        let on_break = reduce(
            state.clone(),
            clock(1095.0, 195.0, "a"),
            json!({"kind":"refresh"}),
        );
        assert_eq!(on_break["view"]["phase"], "longBreak");
        assert_eq!(on_break["view"]["seconds"], 15.0);
        let finished = reduce(state, clock(1200.0, 300.0, "a"), json!({"kind":"refresh"}));
        assert_eq!(finished["view"]["isCompleted"], true);
    }
    /// 账本只记做完的专注段：spec 是 20 秒专注 / 5 秒短休 / 15 秒长休 × 5 轮，从 1000 起算，
    /// 第一段专注 1000–1020、第二段 1025–1045、第三段 1050–1070、第四段 1075–1095（后接长休 15）、第五段 1110–1130。
    #[test]
    fn pomodoro_ledger_counts_only_completed_focus_phases() {
        let days = json!([{"start": 0.0, "end": 86_400.0}]);
        let with_days = |state: Value, clock: Clock, event: Value| {
            dispatch(
                "timers.reduce",
                json!({"state": state, "clock": clock, "event": event, "days": days}),
            )
            .unwrap()
        };
        let state = start("pomodoro")["state"].clone();
        // 专注进行到一半：没有入账
        let mid = with_days(
            state.clone(),
            clock(1010.0, 110.0, "a"),
            json!({"kind":"refresh"}),
        );
        assert_eq!(mid["ledger"]["days"][0]["focusCount"], 0);
        assert_eq!(mid["state"]["ledger"].as_array().unwrap().len(), 0);
        // 第一段做完、休息中：一条，结束时刻反推为 1020
        let rest = with_days(
            mid["state"].clone(),
            clock(1022.0, 122.0, "a"),
            json!({"kind":"refresh"}),
        );
        assert_eq!(rest["state"]["ledger"].as_array().unwrap().len(), 1);
        assert_eq!(rest["state"]["ledger"][0]["endedAt"], 1020.0);
        assert_eq!(rest["state"]["ledger"][0]["seconds"], 20.0);
        assert_eq!(rest["state"]["session"]["creditedFocus"], 1);
        assert_eq!(
            rest["ledger"]["days"][0],
            json!({"focusCount": 1, "focusSeconds": 20.0})
        );
        // 暂停在第二段中间不入账；同一条不会重复入账
        let paused = with_days(
            rest["state"].clone(),
            clock(1035.0, 135.0, "a"),
            json!({"kind":"pause"}),
        );
        assert_eq!(paused["state"]["ledger"].as_array().unwrap().len(), 1);
        // 中途取消：账本保留已完成的一条，会话没了
        let cancelled = with_days(
            paused["state"].clone(),
            clock(1040.0, 140.0, "a"),
            json!({"kind":"cancel"}),
        );
        assert!(cancelled["state"]["session"].is_null());
        assert_eq!(cancelled["state"]["ledger"].as_array().unwrap().len(), 1);
        // App 没开着时整套跑完：一次刷新把剩下四段全部补记，时刻各自正确
        let fresh = start("pomodoro")["state"].clone();
        let done = with_days(fresh, clock(1300.0, 400.0, "a"), json!({"kind":"refresh"}));
        assert_eq!(done["view"]["isCompleted"], true);
        let ends: Vec<f64> = done["state"]["ledger"]
            .as_array()
            .unwrap()
            .iter()
            .map(|e| e["endedAt"].as_f64().unwrap())
            .collect();
        assert_eq!(ends, vec![1020.0, 1045.0, 1070.0, 1095.0, 1130.0]);
        assert_eq!(
            done["ledger"]["days"][0],
            json!({"focusCount": 5, "focusSeconds": 100.0})
        );
        // 关掉透镜：会话清掉，账本留着；重开一轮从零计数
        let off = with_days(
            done["state"].clone(),
            clock(1400.0, 500.0, "a"),
            json!({"kind":"deactivate"}),
        );
        assert!(off["state"]["session"].is_null());
        assert_eq!(off["state"]["ledger"].as_array().unwrap().len(), 5);
        let again = with_days(
            off["state"].clone(),
            clock(2000.0, 600.0, "a"),
            json!({"kind":"start", "spec": spec("pomodoro")}),
        );
        assert_eq!(again["state"]["session"]["creditedFocus"], 0);
        // 按日分桶：昨天一条、今天两条
        let split = json!([{"start": 1100.0, "end": 2000.0}, {"start": 0.0, "end": 1100.0}]);
        let bucketed = dispatch("timers.reduce", json!({"state": off["state"], "clock": clock(2000.0, 600.0, "a"), "event": {"kind":"refresh"}, "days": split})).unwrap();
        assert_eq!(bucketed["ledger"]["days"][0]["focusCount"], 1);
        assert_eq!(bucketed["ledger"]["days"][1]["focusCount"], 4);
        // 没给 days 就不出汇总
        assert!(reduce(
            off["state"].clone(),
            clock(2000.0, 600.0, "a"),
            json!({"kind":"refresh"})
        )["ledger"]
            .is_null());
    }

    /// 老状态没有账本字段照常加载；账本里的坏条目丢掉、92 天前的清掉，都不连累会话。
    #[test]
    fn pomodoro_ledger_survives_old_and_dirty_state() {
        let old = json!({"version": 1, "notifications": false, "session": null}).to_string();
        let loaded = dispatch(
            "timers.load",
            json!({"stored": old, "clock": clock(1000.0, 100.0, "a")}),
        )
        .unwrap();
        assert_eq!(loaded["recovered"], false);
        assert_eq!(loaded["state"]["ledger"], json!([]));
        let now = 100.0 * 86_400.0;
        let dirty = json!({"version": 1, "notifications": false, "session": null, "ledger": [
            {"endedAt": now - 1.0, "seconds": 1500.0},
            {"endedAt": now - 100.0 * 86_400.0, "seconds": 1500.0},
            {"endedAt": "x", "seconds": 1500.0},
            {"endedAt": now - 2.0, "seconds": 0.0},
            {"endedAt": now - 3.0, "seconds": 1e300}
        ]});
        // 类型错的条目让整份 JSON 解不开：那就走恢复路径，会话与账本都回默认；数值越界的条目单独丢
        let broken = dispatch(
            "timers.load",
            json!({"stored": dirty.to_string(), "clock": clock(now, 100.0, "a")}),
        )
        .unwrap();
        assert_eq!(broken["recovered"], true);
        let mut numeric = dirty.clone();
        numeric["ledger"].as_array_mut().unwrap().remove(2);
        let cleaned = dispatch("timers.load", json!({"stored": numeric.to_string(), "clock": clock(now, 100.0, "a"), "days": [{"start": now - 86_400.0, "end": now + 1.0}]})).unwrap();
        assert_eq!(cleaned["recovered"], false);
        assert_eq!(cleaned["state"]["ledger"].as_array().unwrap().len(), 1);
        assert_eq!(cleaned["ledger"]["days"][0]["focusCount"], 1);
        assert_eq!(cleaned["changed"], true);
    }

    #[test]
    fn stopwatch_pauses_and_keeps_elapsed_across_reload() {
        let state = start("stopwatch")["state"].clone();
        let paused = reduce(state, clock(1030.0, 130.0, "a"), json!({"kind":"pause"}));
        assert_eq!(paused["view"]["display"], "00:30");
        let loaded = dispatch(
            "timers.load",
            json!({"stored": paused["state"].to_string(), "clock": clock(2000.0, 1000.0, "a")}),
        )
        .unwrap();
        assert_eq!(loaded["view"]["seconds"], 30.0);
    }
    #[test]
    fn alarm_remains_an_absolute_instant_even_when_paused() {
        let state = start("alarm")["state"].clone();
        let paused = reduce(state, clock(1500.0, 200.0, "a"), json!({"kind":"pause"}));
        let resumed = reduce(
            paused["state"].clone(),
            clock(2001.0, 220.0, "a"),
            json!({"kind":"resume"}),
        );
        assert_eq!(resumed["view"]["isCompleted"], true);
        let restart = reduce(
            resumed["state"].clone(),
            clock(2001.0, 220.0, "a"),
            json!({"kind":"restart"}),
        );
        assert_eq!(restart["error"], "alarmInPast");
    }
    #[test]
    fn cancellation_and_deactivation_clear_only_this_session() {
        let running = start("countdown");
        let canceled = reduce(
            running["state"].clone(),
            clock(1000.0, 100.0, "a"),
            json!({"kind":"cancel"}),
        );
        assert!(canceled["state"]["session"].is_null());
        assert_eq!(canceled["notices"], json!([]));
        let off = reduce(
            running["state"].clone(),
            clock(1000.0, 100.0, "a"),
            json!({"kind":"deactivate"}),
        );
        assert_eq!(off["state"], initial());
    }
    #[test]
    fn malformed_storage_recovers_and_active_session_is_not_overwritten() {
        let bad = dispatch(
            "timers.load",
            json!({"stored":"{bad", "clock":clock(0.0,0.0,"a")}),
        )
        .unwrap();
        assert_eq!(bad["recovered"], true);
        let running = start("countdown");
        let duplicate = reduce(
            running["state"].clone(),
            clock(1000.0, 100.0, "a"),
            json!({"kind":"start", "spec":spec("stopwatch")}),
        );
        assert_eq!(duplicate["error"], "activeSession");
        assert_eq!(duplicate["state"], running["state"]);
    }
    #[test]
    fn invalid_user_input_is_a_recoverable_error() {
        let mut input = spec("countdown");
        input["duration"] = json!(-1);
        let result = reduce(
            initial(),
            clock(1000.0, 100.0, "a"),
            json!({"kind":"start", "spec":input}),
        );
        assert_eq!(result["error"], "invalidDuration");
        assert_eq!(result["state"], initial());
        let mut input = spec("alarm");
        input["alarmAt"] = json!(999.0);
        assert_eq!(
            reduce(
                initial(),
                clock(1000.0, 100.0, "a"),
                json!({"kind":"start", "spec":input})
            )["error"],
            "alarmInPast"
        );
    }

    /// 性质测试：随机操作流 + 随机时钟事件（走时、休眠、重启、墙钟被拨动）下，计时器的账必须对得上
    /// 一个独立记的「真实时间」：墙钟没被拨过时 elapsed 精确等于真实运行时长（同一次启动走连续时钟，
    /// 重启后走墙钟差）；暂停时 elapsed 冻结；倒计时 / 番茄钟到点即 completed 且不再走；秒表永不完成；
    /// 状态存下来再 `timers.load` 回来视图相同且不算恢复；提醒只在开着通知且在跑时给，倒计时的提醒时刻 = 墙钟 + 剩余。
    #[test]
    fn random_clocks_and_actions_keep_elapsed_honest() {
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
        let iterations: u64 = std::env::var("MEANTIME_FUZZ_ITERATIONS")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(300);
        let seed_offset: u64 = std::env::var("MEANTIME_FUZZ_SEED")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(0);
        let mut rng = Xor(0x7133_7133_5EED_0001_u64.wrapping_add(seed_offset));
        let mut exact_checks = 0usize;
        let mut completions = 0usize;
        for i in 0..iterations {
            // 真实时间轴：truth 单调；墙钟 = truth + drift；连续时钟 = truth - 本次启动的起点；重启换 bootId。
            let mut truth = 1_000_000.0_f64;
            let mut drift = 0.0_f64;
            let drift_allowed = rng.below(5) == 0;
            let mut boot = 1u64;
            let mut boot_start = truth - (rng.below(3_600) as f64);
            let clock = |truth: f64, drift: f64, boot: u64, boot_start: f64| json!({"wall": truth + drift, "continuous": truth - boot_start, "bootId": format!("boot-{boot}")});
            let mut state = dispatch(
                "timers.load",
                json!({"clock": clock(truth, drift, boot, boot_start)}),
            )
            .unwrap()["state"]
                .clone();
            // 独立记账：会话开始以来真实运行了多久、是否在跑、期望的模式与总长。
            let mut running_since: Option<f64> = None;
            let mut run_total = 0.0_f64;
            let mut have_session = false;
            let mut mode = String::new();
            let mut total = 0.0_f64;
            let mut alarm_at = 0.0_f64;
            let mut drifted_since_start = false;
            let mut rebooted_since_start = false;
            for step in 0..80 {
                // 先来一个时钟事件。
                match rng.below(10) {
                    0..=5 => truth += rng.below(600) as f64 + rng.below(1000) as f64 / 1000.0,
                    6 => truth += 3_600.0 * (1 + rng.below(30)) as f64, // 休眠：连续时钟照走（mach_continuous_time）
                    7 => {
                        truth += 30.0 + rng.below(3_600) as f64;
                        boot += 1;
                        boot_start = truth - rng.below(60) as f64;
                        rebooted_since_start = true;
                    }
                    8 if drift_allowed => {
                        drift += rng.below(7_200) as f64 - 3_600.0;
                        drifted_since_start = true;
                    }
                    _ => {}
                }
                let now = clock(truth, drift, boot, boot_start);
                let wall = truth + drift;
                // 再来一个操作。
                let event = match rng.below(9) {
                    0 | 1 => json!({"kind":"refresh"}),
                    2 => {
                        let spec = match rng.below(4) {
                            0 => {
                                json!({"mode":"countdown","label":"t","duration": 60.0 * (1 + rng.below(90)) as f64,"focus":1500.0,"shortBreak":300.0,"longBreak":900.0,"rounds":4,"alarmAt":null})
                            }
                            1 => {
                                json!({"mode":"stopwatch","label":"","duration":0.0,"focus":1500.0,"shortBreak":300.0,"longBreak":900.0,"rounds":4,"alarmAt":null})
                            }
                            2 => {
                                json!({"mode":"pomodoro","label":"p","duration":0.0,"focus": 60.0 * (1 + rng.below(30)) as f64,"shortBreak": 60.0 * (1 + rng.below(10)) as f64,"longBreak": 60.0 * (1 + rng.below(20)) as f64,"rounds": 1 + rng.below(6),"alarmAt":null})
                            }
                            _ => {
                                json!({"mode":"alarm","label":"a","duration":0.0,"focus":1500.0,"shortBreak":300.0,"longBreak":900.0,"rounds":4,"alarmAt": wall + (rng.below(7_200) as f64) - 600.0, "alarmZone":"Asia/Tokyo", "alarmPlace":"東京"})
                            }
                        };
                        json!({"kind":"start","spec":spec})
                    }
                    3 => json!({"kind":"pause"}),
                    4 => json!({"kind":"resume"}),
                    5 => json!({"kind":"restart"}),
                    6 => json!({"kind":"cancel"}),
                    7 => json!({"kind":"notifications","enabled": rng.below(2) == 0}),
                    _ => json!({"kind":"refresh"}),
                };
                let kind = event["kind"].as_str().unwrap().to_owned();
                // 先按同一时刻只做 refresh，拿到 reducer 自己眼里的状态（到点即完成），再发真正的操作：
                // 墙钟被拨过时 reducer 走墙钟差的账与真实时间不同，谁「在跑」以它为准，真实时间只核精确账。
                let refreshed = dispatch(
                    "timers.reduce",
                    json!({"state": state, "clock": now, "event": {"kind":"refresh"}}),
                )
                .unwrap();
                let before_status = refreshed["state"]["session"]["status"]
                    .as_str()
                    .map(str::to_owned);
                // 先把「真实」账推进到 now（在跑就累加）。
                if let Some(since) = running_since {
                    run_total += truth - since;
                    running_since = Some(truth);
                }
                // reducer 眼里已完成；墙钟没拨过时它必须与真实时间一致（在下面精确核）。
                let truly_done = have_session && before_status.as_deref() == Some("completed");
                if have_session
                    && !drifted_since_start
                    && before_status.as_deref() != Some("paused")
                {
                    let truth_done = match mode.as_str() {
                        "alarm" => alarm_at <= wall,
                        "stopwatch" => false,
                        _ => run_total >= total - 1e-6,
                    };
                    assert_eq!(truly_done, truth_done, "#{i}.{step}：reducer 说完成={truly_done}，真实时间说 {truth_done}（跑了 {run_total}s / {total}s，重启过 {rebooted_since_start}）");
                }
                let output = dispatch(
                    "timers.reduce",
                    json!({"state": state, "clock": now, "event": event}),
                )
                .unwrap_or_else(|e| panic!("#{i}.{step} {kind}: {e}"));
                let tag = format!("#{i}.{step} {kind}");
                let error = output["error"].as_str();
                let new_state = output["state"].clone();
                let session = new_state["session"].clone();
                let view = output["view"].clone();
                // 按操作更新真实账。
                match kind.as_str() {
                    "start" => {
                        if have_session
                            && matches!(before_status.as_deref(), Some("running") | Some("paused"))
                        {
                            assert_eq!(
                                error,
                                Some("activeSession"),
                                "{tag}：有会话在跑却让再开一个"
                            );
                        } else if error.is_none() {
                            have_session = true;
                            mode = session["spec"]["mode"].as_str().unwrap().to_owned();
                            total = match mode.as_str() {
                                "countdown" => session["spec"]["duration"].as_f64().unwrap(),
                                "pomodoro" => {
                                    let f = session["spec"]["focus"].as_f64().unwrap();
                                    let sb = session["spec"]["shortBreak"].as_f64().unwrap();
                                    let lb = session["spec"]["longBreak"].as_f64().unwrap();
                                    let rounds = session["spec"]["rounds"].as_u64().unwrap();
                                    (1..=rounds)
                                        .map(|r| {
                                            f + if r < rounds {
                                                if r % 4 == 0 {
                                                    lb
                                                } else {
                                                    sb
                                                }
                                            } else {
                                                0.0
                                            }
                                        })
                                        .sum()
                                }
                                _ => f64::INFINITY,
                            };
                            alarm_at = session["spec"]["alarmAt"].as_f64().unwrap_or(0.0);
                            run_total = 0.0;
                            running_since = Some(truth);
                            drifted_since_start = false;
                            rebooted_since_start = false;
                        } else {
                            // 只有闹钟在过去这一种随机规格会被拒。
                            assert_eq!(error, Some("alarmInPast"), "{tag}：规格被拒：{error:?}");
                        }
                    }
                    "pause" => {
                        if have_session
                            && before_status.as_deref() == Some("running")
                            && !truly_done
                        {
                            running_since = None;
                        }
                    }
                    "resume" => {
                        if have_session && before_status.as_deref() == Some("paused") {
                            running_since = Some(truth);
                        }
                    }
                    "restart" => {
                        if have_session {
                            if error.is_none() {
                                run_total = 0.0;
                                running_since = Some(truth);
                                drifted_since_start = false;
                                rebooted_since_start = false;
                            } else {
                                assert_eq!(error, Some("alarmInPast"), "{tag}");
                            }
                        }
                    }
                    "cancel" => {
                        have_session = false;
                        running_since = None;
                    }
                    _ => {}
                }
                if truly_done
                    && have_session
                    && !matches!(kind.as_str(), "cancel" | "start" | "restart")
                {
                    running_since = None;
                }
                // 完成后 elapsed 钉住：真实账也停在总长。
                if truly_done
                    && have_session
                    && mode != "alarm"
                    && mode != "stopwatch"
                    && !drifted_since_start
                {
                    run_total = run_total.min(total);
                }
                if !have_session {
                    assert!(session.is_null(), "{tag}：取消后还有会话");
                    state = new_state;
                    continue;
                }
                let status = session["status"].as_str().unwrap();
                let elapsed = session["elapsed"].as_f64().unwrap();
                // 完成态：非秒表到点即完成，之后 elapsed 钉在总长；秒表永不完成。
                match mode.as_str() {
                    "stopwatch" => assert_ne!(status, "completed", "{tag}：秒表完成了"),
                    "alarm" => {
                        if alarm_at <= wall && status != "paused" {
                            assert_eq!(status, "completed", "{tag}：闹钟到点没完成");
                            completions += 1;
                        }
                    }
                    _ => {
                        if status == "completed" {
                            assert!(
                                (elapsed - total).abs() < 1e-6,
                                "{tag}：完成后 elapsed {elapsed} ≠ 总长 {total}"
                            );
                            completions += 1;
                        }
                    }
                }
                assert!(
                    (0.0..=MAX_ELAPSED).contains(&elapsed),
                    "{tag}：elapsed {elapsed} 越界"
                );
                // 精确账：墙钟没被拨过时，状态里算出的运行时长 == 真实运行时长（视图 seconds 由它推出）。
                if !drifted_since_start && status != "completed" && mode != "alarm" {
                    let state_elapsed = if status == "running" {
                        // 用同一时刻再问一次视图：running 的 elapsed 藏在 startedAt / continuousAt 里，view 里是剩余。
                        match mode.as_str() {
                            "stopwatch" => view["seconds"].as_f64().unwrap(),
                            "countdown" => total - view["seconds"].as_f64().unwrap(),
                            _ => f64::NAN,
                        }
                    } else {
                        elapsed
                    };
                    if state_elapsed.is_finite() {
                        let truth_elapsed = run_total;
                        assert!((state_elapsed - truth_elapsed).abs() < 1e-3, "{tag}：状态说跑了 {state_elapsed}s，真实 {truth_elapsed}s（重启过 {rebooted_since_start}）");
                        exact_checks += 1;
                    }
                }
                // 暂停时视图不随时钟走：再推进时钟、只 refresh，elapsed 不变。闹钟除外——产品定义是「暂停只关提醒，
                // 目标时刻不变」，剩余时间照样随墙钟走。
                if status == "paused" && mode != "alarm" {
                    let later = clock(truth + 500.0, drift, boot, boot_start);
                    let again = dispatch(
                        "timers.reduce",
                        json!({"state": new_state, "clock": later, "event": {"kind":"refresh"}}),
                    )
                    .unwrap();
                    assert_eq!(
                        again["state"]["session"]["elapsed"], session["elapsed"],
                        "{tag}：暂停中 elapsed 走了"
                    );
                    assert_eq!(
                        again["view"]["seconds"], view["seconds"],
                        "{tag}：暂停中视图走了"
                    );
                }
                // 存下来再读回：视图相同，不算恢复。
                let reloaded = dispatch(
                    "timers.load",
                    json!({"stored": new_state.to_string(), "clock": now}),
                )
                .unwrap();
                assert_eq!(
                    reloaded["recovered"], false,
                    "{tag}：自己存的状态被当成损坏"
                );
                assert_eq!(reloaded["view"], view, "{tag}：读回后视图不同");
                // 提醒：只在开着通知且在跑时；倒计时的提醒时刻 = 墙钟 + 剩余。
                let notices = output["notices"].as_array().unwrap();
                if !new_state["notifications"].as_bool().unwrap() || status != "running" {
                    assert!(notices.is_empty(), "{tag}：不该有提醒");
                } else if mode == "countdown" {
                    assert_eq!(notices.len(), 1, "{tag}");
                    assert!(
                        (notices[0]["fireAt"].as_f64().unwrap()
                            - (wall + view["seconds"].as_f64().unwrap()))
                        .abs()
                            < 1e-6,
                        "{tag}：倒计时提醒时刻不对"
                    );
                }
                state = new_state;
            }
        }
        assert!(
            exact_checks > iterations as usize && completions > 0,
            "精确核对 {exact_checks} / 完成 {completions} 太少，生成器有问题"
        );
        eprintln!("[timers property] {iterations} 条操作流，精确核对 {exact_checks} 次，完成 {completions} 次");
    }
    #[test]
    fn old_alarm_without_place_loads_without_recovery() {
        let state = start("alarm")["state"].clone();
        let loaded = dispatch(
            "timers.load",
            json!({"stored":state.to_string(),"clock":clock(1010.0,110.0,"a")}),
        )
        .unwrap();
        assert_eq!(loaded["recovered"], false);
        assert!(loaded["state"]["session"]["spec"]
            .get("alarmZone")
            .is_none());
        assert!(loaded["state"]["session"]["spec"]
            .get("alarmPlace")
            .is_none());
    }
    #[test]
    fn alarm_place_survives_start_reload_pause_resume_and_restart() {
        let mut alarm = spec("alarm");
        alarm["alarmZone"] = json!("Asia/Tokyo");
        alarm["alarmPlace"] = json!("大阪");
        let started = reduce(
            initial(),
            clock(1000.0, 100.0, "a"),
            json!({"kind":"start","spec":alarm}),
        );
        let loaded = dispatch(
            "timers.load",
            json!({"stored":started["state"].to_string(),"clock":clock(1010.0,10.0,"b")}),
        )
        .unwrap();
        assert_eq!(loaded["recovered"], false);
        let mut state = loaded["state"].clone();
        for kind in ["pause", "resume", "restart"] {
            let result = reduce(state, clock(1020.0, 20.0, "b"), json!({"kind":kind}));
            assert!(result["error"].is_null());
            assert_eq!(
                result["state"]["session"]["spec"]["alarmZone"],
                json!("Asia/Tokyo")
            );
            assert_eq!(
                result["state"]["session"]["spec"]["alarmPlace"],
                json!("大阪")
            );
            state = result["state"].clone();
        }
    }
    #[test]
    fn invalid_alarm_place_fields_drop_individually_and_alarm_still_runs() {
        for (zone, place) in [
            (json!("Asia Tokyo"), json!("bad\n")),
            (json!("Z".repeat(65)), json!("名".repeat(81))),
            (json!(42), json!({})),
            (json!(""), json!("")),
        ] {
            let mut alarm = spec("alarm");
            alarm["alarmZone"] = zone;
            alarm["alarmPlace"] = place;
            let result = reduce(
                initial(),
                clock(1000.0, 100.0, "a"),
                json!({"kind":"start","spec":alarm}),
            );
            assert!(result["error"].is_null());
            assert_eq!(result["view"]["isRunning"], true);
            assert!(result["state"]["session"]["spec"]
                .get("alarmZone")
                .is_none());
            assert!(result["state"]["session"]["spec"]
                .get("alarmPlace")
                .is_none());
        }
        let mut alarm = spec("alarm");
        alarm["alarmZone"] = json!("Asia Tokyo");
        alarm["alarmPlace"] = json!("大阪");
        let result = reduce(
            initial(),
            clock(1000.0, 100.0, "a"),
            json!({"kind":"start","spec":alarm}),
        );
        assert_eq!(
            result["state"]["session"]["spec"]["alarmPlace"],
            json!("大阪")
        );
    }
    #[test]
    fn non_alarm_modes_discard_alarm_place_fields() {
        for mode in ["countdown", "pomodoro", "stopwatch"] {
            let mut input = spec(mode);
            input["alarmZone"] = json!("Asia/Tokyo");
            input["alarmPlace"] = json!("大阪");
            let result = reduce(
                initial(),
                clock(1000.0, 100.0, "a"),
                json!({"kind":"start","spec":input}),
            );
            assert!(result["error"].is_null());
            assert!(result["state"]["session"]["spec"]
                .get("alarmZone")
                .is_none());
            assert!(result["state"]["session"]["spec"]
                .get("alarmPlace")
                .is_none());
        }
    }
}
