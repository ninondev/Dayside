// SPDX-License-Identifier: GPL-3.0-only
//! Menu-bar recovery state machine. Delays are seconds; AppKit registration,
//! task sleeping/cancellation and Published delivery are platform effects.
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct State {
    inserted: bool,
    user_wants_visible: bool,
    observers_registered: bool,
    label_attached: bool,
    pulse_active: bool,
    generation: u64,
    pending_reason: Option<String>,
    debounce: f64,
    gap: f64,
    initial_delay: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Event {
    kind: String,
    inserted: Option<bool>,
    generation: Option<u64>,
    phase: Option<String>,
    sibling: Option<bool>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct Effect {
    kind: &'static str,
    generation: Option<u64>,
    phase: Option<&'static str>,
    delay: Option<f64>,
    message: Option<String>,
}

#[derive(Debug, Serialize)]
struct Output {
    state: State,
    effects: Vec<Effect>,
}

impl State {
    fn new(debounce: f64, gap: f64, initial_delay: f64) -> Result<Self, String> {
        if [debounce, gap, initial_delay]
            .iter()
            .any(|v| !v.is_finite() || *v < 0.0)
        {
            return Err("Recovery delays must be finite nonnegative seconds".into());
        }
        Ok(Self {
            inserted: true,
            user_wants_visible: true,
            observers_registered: false,
            label_attached: false,
            pulse_active: false,
            generation: 0,
            pending_reason: None,
            debounce,
            gap,
            initial_delay,
        })
    }

    fn start_observing(&mut self, effects: &mut Vec<Effect>) {
        if !self.observers_registered {
            self.observers_registered = true;
            effects.push(effect("registerObservers"));
        }
    }

    fn cancel(&mut self, restore_if_desired: bool, effects: &mut Vec<Effect>) {
        self.generation += 1;
        effects.push(effect("cancelTimer"));
        self.pending_reason = None;
        if restore_if_desired && self.user_wants_visible {
            self.inserted = true;
        }
        self.pulse_active = false;
    }

    fn schedule(&mut self, reason: &str, delay: f64, effects: &mut Vec<Effect>) {
        if (!self.user_wants_visible && reason != "reopen") || self.pulse_active {
            return;
        }
        self.generation += 1;
        self.pending_reason = Some(reason.into());
        effects.push(effect("cancelTimer"));
        effects.push(timer(self.generation, "debounce", delay));
    }

    fn clear(&mut self, effects: &mut Vec<Effect>) {
        self.pending_reason = None;
        self.pulse_active = false;
        effects.push(effect("clearTimer"));
    }

    fn reduce(mut self, event: Event) -> Result<Output, String> {
        let mut effects = vec![];
        match event.kind.as_str() {
            "launch" => {
                self.start_observing(&mut effects);
                if !self.label_attached {
                    self.schedule("initialAttachment", self.initial_delay, &mut effects);
                }
            }
            "startObserving" => self.start_observing(&mut effects),
            "stopObserving" => {
                if self.observers_registered {
                    self.observers_registered = false;
                    effects.push(effect("unregisterObservers"));
                }
                self.cancel(false, &mut effects);
            }
            "reopen" => {
                self.user_wants_visible = true;
                if self.inserted {
                    self.schedule("reopen", 0.0, &mut effects);
                } else {
                    self.cancel(false, &mut effects);
                    self.inserted = true;
                    effects.push(log(
                        "Reopen restored the menu bar extra in the existing process",
                    ));
                }
            }
            "systemInsertion" => {
                let inserted = event.inserted.ok_or("Missing system insertion state")?;
                self.inserted = inserted;
                self.user_wants_visible = inserted;
                self.cancel(inserted, &mut effects);
                effects.push(log(&format!("System insertion state changed: {inserted}")));
            }
            "labelAppear" => {
                self.label_attached = true;
                if !self.pulse_active
                    && matches!(
                        self.pending_reason.as_deref(),
                        Some("labelDetached" | "initialAttachment")
                    )
                {
                    self.cancel(true, &mut effects);
                }
            }
            "labelDisappear" => {
                self.label_attached = false;
                if self.user_wants_visible && self.inserted && !self.pulse_active {
                    self.schedule("labelDetached", self.debounce, &mut effects);
                }
            }
            "environmentChanged" => {
                if self.observers_registered && self.user_wants_visible {
                    self.schedule("environmentChanged", self.debounce, &mut effects);
                }
            }
            "siblingTerminated" => {
                if self.observers_registered
                    && self.user_wants_visible
                    && event.sibling == Some(true)
                {
                    self.schedule("siblingTerminated", self.debounce, &mut effects);
                }
            }
            "timerFired" => {
                if event.generation == Some(self.generation) && self.pending_reason.is_some() {
                    match event.phase.as_deref() {
                        Some("debounce") if !self.pulse_active => {
                            if !self.user_wants_visible {
                                self.clear(&mut effects);
                            } else {
                                self.pulse_active = true;
                                effects.push(log(&format!(
                                    "Reinserting menu bar extra after {}",
                                    self.pending_reason.as_deref().unwrap_or("unknown")
                                )));
                                if self.inserted {
                                    self.inserted = false;
                                    effects.push(timer(self.generation, "gap", self.gap));
                                } else {
                                    self.inserted = true;
                                    self.clear(&mut effects);
                                }
                            }
                        }
                        Some("gap") if self.pulse_active => {
                            if self.user_wants_visible {
                                self.inserted = true;
                            }
                            self.clear(&mut effects);
                        }
                        Some("debounce" | "gap") => {}
                        _ => return Err("Unknown recovery timer phase".into()),
                    }
                }
            }
            "timerCancelled" => {
                if event.generation == Some(self.generation) && self.pulse_active {
                    if self.user_wants_visible {
                        self.inserted = true;
                    }
                    self.clear(&mut effects);
                }
            }
            _ => return Err(format!("Unknown presence event: {}", event.kind)),
        }
        Ok(Output {
            state: self,
            effects,
        })
    }
}

fn effect(kind: &'static str) -> Effect {
    Effect {
        kind,
        generation: None,
        phase: None,
        delay: None,
        message: None,
    }
}
fn timer(generation: u64, phase: &'static str, delay: f64) -> Effect {
    Effect {
        kind: "scheduleTimer",
        generation: Some(generation),
        phase: Some(phase),
        delay: Some(delay),
        message: None,
    }
}
fn log(message: &str) -> Effect {
    Effect {
        message: Some(message.into()),
        ..effect("log")
    }
}

pub fn dispatch(operation: &str, payload: Value) -> Result<Value, String> {
    let output = match operation {
        "presence.init" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct Input {
                debounce: Option<f64>,
                gap: Option<f64>,
                initial_delay: Option<f64>,
            }
            let input: Input = serde_json::from_value(payload).map_err(|e| e.to_string())?;
            serde_json::to_value(Output {
                state: State::new(
                    input.debounce.unwrap_or(0.75),
                    input.gap.unwrap_or(0.12),
                    input.initial_delay.unwrap_or(2.0),
                )?,
                effects: vec![],
            })
        }
        "presence.reduce" => {
            #[derive(Deserialize)]
            struct Input {
                state: State,
                event: Event,
            }
            let input: Input = serde_json::from_value(payload).map_err(|e| e.to_string())?;
            serde_json::to_value(input.state.reduce(input.event)?)
        }
        "presence.sibling" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct Input {
                bundle_id: Option<String>,
                pid: i32,
                own_bundle_id: Option<String>,
                own_pid: i32,
            }
            let input: Input = serde_json::from_value(payload).map_err(|e| e.to_string())?;
            return Ok(Value::Bool(
                input.bundle_id.is_some()
                    && input.bundle_id == input.own_bundle_id
                    && input.pid != input.own_pid,
            ));
        }
        _ => return Err(format!("Unknown presence operation: {operation}")),
    };
    output.map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    fn initial() -> State {
        State::new(0.75, 0.12, 2.0).unwrap()
    }
    fn step(state: State, event: Value) -> Output {
        state
            .reduce(serde_json::from_value(event).unwrap())
            .unwrap()
    }
    fn ready() -> State {
        let launched = step(initial(), json!({"kind":"launch"})).state;
        step(launched, json!({"kind":"labelAppear"})).state
    }
    fn fire(state: State, phase: &str) -> Output {
        let generation = state.generation;
        step(
            state,
            json!({"kind":"timerFired","generation":generation,"phase":phase}),
        )
    }

    #[test]
    fn initial_state_is_visible_without_observers() {
        let s = initial();
        assert!(s.inserted && s.user_wants_visible);
        assert!(!s.observers_registered);
    }
    #[test]
    fn missing_attachment_pulses_once_after_initial_delay() {
        let launched = step(initial(), json!({"kind":"launch"}));
        assert_eq!(launched.effects.last().unwrap().delay, Some(2.0));
        let half = fire(launched.state, "debounce");
        assert!(!half.state.inserted);
        assert!(half.state.pulse_active);
        let complete = fire(half.state, "gap");
        assert!(complete.state.inserted);
        assert!(!complete.state.pulse_active);
        assert!(complete.state.pending_reason.is_none());
        assert!(fire(complete.state, "gap").effects.is_empty());
    }
    #[test]
    fn timely_attachment_and_brief_detach_cancel_recovery() {
        let ready = ready();
        assert!(ready.pending_reason.is_none());
        let detached = step(ready, json!({"kind":"labelDisappear"})).state;
        let generation = detached.generation;
        let attached = step(detached, json!({"kind":"labelAppear"})).state;
        let late = step(
            attached,
            json!({"kind":"timerFired","generation":generation,"phase":"debounce"}),
        );
        assert!(late.state.inserted);
        assert!(late.effects.is_empty());
    }
    #[test]
    fn burst_replaces_debounce_but_active_pulse_merges_events() {
        let mut state = ready();
        let mut previous = 0;
        for _ in 0..8 {
            state = step(state, json!({"kind":"environmentChanged"})).state;
            assert!(state.generation > previous);
            previous = state.generation;
        }
        let half = fire(state, "debounce").state;
        let merged = step(half, json!({"kind":"environmentChanged"}));
        assert!(merged.effects.is_empty());
        assert_eq!(merged.state.generation, previous);
        assert!(fire(merged.state, "gap").state.inserted);
    }
    #[test]
    fn system_false_wins_during_active_pulse_and_reopen_restores() {
        let queued = step(ready(), json!({"kind":"reopen"})).state;
        let half = fire(queued, "debounce").state;
        let generation = half.generation;
        let hidden = step(half, json!({"kind":"systemInsertion","inserted":false})).state;
        let stale = step(
            hidden,
            json!({"kind":"timerFired","generation":generation,"phase":"gap"}),
        )
        .state;
        assert!(!stale.inserted && !stale.user_wants_visible);
        assert!(step(stale.clone(), json!({"kind":"environmentChanged"}))
            .effects
            .is_empty());
        let reopened = step(stale, json!({"kind":"reopen"})).state;
        assert!(reopened.inserted && reopened.user_wants_visible);
    }
    #[test]
    fn system_true_reenables_recovery() {
        let hidden = step(ready(), json!({"kind":"systemInsertion","inserted":false})).state;
        let visible = step(hidden, json!({"kind":"systemInsertion","inserted":true})).state;
        assert!(step(visible, json!({"kind":"environmentChanged"}))
            .state
            .pending_reason
            .is_some());
    }
    #[test]
    fn observer_registration_is_idempotent_and_stop_rejects_pending_timer() {
        let state = ready();
        assert!(step(state.clone(), json!({"kind":"startObserving"}))
            .effects
            .is_empty());
        let queued = step(state, json!({"kind":"labelDisappear"})).state;
        let generation = queued.generation;
        let stopped = step(queued, json!({"kind":"stopObserving"})).state;
        assert!(!stopped.observers_registered);
        let late = step(
            stopped,
            json!({"kind":"timerFired","generation":generation,"phase":"debounce"}),
        )
        .state;
        assert!(late.inserted);
        assert!(step(late, json!({"kind":"environmentChanged"}))
            .effects
            .is_empty());
    }
    #[test]
    fn sibling_termination_requires_registered_visible_and_matching_instance() {
        assert!(
            step(ready(), json!({"kind":"siblingTerminated","sibling":false}))
                .effects
                .is_empty()
        );
        assert!(
            step(ready(), json!({"kind":"siblingTerminated","sibling":true}))
                .state
                .pending_reason
                .is_some()
        );
        for (bundle, pid, expected) in [
            (Some("app"), 2, true),
            (Some("app"), 1, false),
            (Some("other"), 2, false),
            (None, 2, false),
        ] {
            assert_eq!(
                dispatch(
                    "presence.sibling",
                    json!({"bundleId":bundle,"pid":pid,"ownBundleId":"app","ownPid":1})
                )
                .unwrap(),
                expected
            );
        }
    }
    #[test]
    fn same_generation_gap_cancellation_restores_visible_state() {
        let queued = step(ready(), json!({"kind":"reopen"})).state;
        let half = fire(queued, "debounce").state;
        let generation = half.generation;
        let cancelled = step(
            half,
            json!({"kind":"timerCancelled","generation":generation}),
        );
        assert!(cancelled.state.inserted);
        assert!(!cancelled.state.pulse_active);
    }
    #[test]
    fn unknown_events_and_invalid_delays_fail_explicitly() {
        assert!(State::new(-1.0, 0.1, 2.0).is_err());
        assert!(initial()
            .reduce(serde_json::from_value(json!({"kind":"bad"})).unwrap())
            .is_err());
    }
}
