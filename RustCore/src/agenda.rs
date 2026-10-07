// SPDX-License-Identifier: GPL-3.0-only
//! Calendar presentation and meeting-link policy. EventKit remains an Apple adapter.
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashSet;

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct Preferences {
    is_enabled: bool,
    show_in_menu_bar: bool,
    // None follows all calendars, including newly added calendars. Some([]) means none.
    #[serde(rename = "selectedCalendarIDs")]
    selected_calendar_ids: Option<Vec<String>>,
    days: u8,
}

fn normalize_preferences(value: &Value) -> Preferences {
    let selected_calendar_ids = value
        .get("selectedCalendarIDs")
        .and_then(Value::as_array)
        .map(|ids| {
            let mut result: Vec<String> = ids
                .iter()
                .filter_map(Value::as_str)
                .filter(|id| !id.is_empty())
                .map(str::to_owned)
                .collect();
            result.sort();
            result.dedup();
            result
        });
    Preferences {
        is_enabled: value
            .get("isEnabled")
            .and_then(Value::as_bool)
            .unwrap_or(false),
        show_in_menu_bar: value
            .get("showInMenuBar")
            .and_then(Value::as_bool)
            .unwrap_or(false),
        selected_calendar_ids,
        days: match value.get("days").and_then(Value::as_u64) {
            Some(1) => 1,
            _ => 7,
        },
    }
}

fn reduce(value: &Value) -> Result<Preferences, String> {
    let mut preferences = normalize_preferences(&value["preferences"]);
    let action = &value["action"];
    match action["type"].as_str() {
        Some("enabled") => {
            preferences.is_enabled = action["value"].as_bool().ok_or("enabled needs a boolean")?
        }
        Some("menuBar") => {
            preferences.show_in_menu_bar =
                action["value"].as_bool().ok_or("menuBar needs a boolean")?
        }
        Some("days") => {
            preferences.days = if action["value"].as_u64() == Some(1) {
                1
            } else {
                7
            }
        }
        Some("allCalendars") => preferences.selected_calendar_ids = None,
        Some("noCalendars") => preferences.selected_calendar_ids = Some(Vec::new()),
        Some("calendar") => {
            let id = action["id"]
                .as_str()
                .filter(|id| !id.is_empty())
                .ok_or("calendar needs an id")?;
            let included = action["included"]
                .as_bool()
                .ok_or("calendar needs included")?;
            if preferences.selected_calendar_ids.is_none() && included {
                return Ok(preferences);
            }
            let mut ids = preferences.selected_calendar_ids.unwrap_or_else(|| {
                action["allIDs"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter_map(Value::as_str)
                    .filter(|id| !id.is_empty())
                    .map(str::to_owned)
                    .collect()
            });
            ids.retain(|existing| existing != id);
            if included {
                ids.push(id.to_owned());
            }
            ids.sort();
            ids.dedup();
            preferences.selected_calendar_ids = Some(ids);
        }
        _ => return Err("unknown agenda preference action".into()),
    }
    Ok(preferences)
}

/// URLComponents supplies URL syntax facts. The core builds the opened URL from
/// those fields; an unrelated raw URL can never bypass the host/path decision.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct URLFacts {
    scheme: String,
    host: String,
    port: Option<u16>,
    has_user_info: bool,
    encoded_path: String,
    encoded_query: Option<String>,
    has_fragment: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
struct MeetingLink {
    url: String,
    provider: String,
}

fn decoded_component(raw: &str) -> Option<String> {
    let bytes = raw.as_bytes();
    let mut result = Vec::with_capacity(bytes.len());
    let mut cursor = 0;
    while cursor < bytes.len() {
        let byte = if bytes[cursor] == b'%' {
            let hi = char::from(*bytes.get(cursor + 1)?).to_digit(16)?;
            let lo = char::from(*bytes.get(cursor + 2)?).to_digit(16)?;
            cursor += 3;
            (hi * 16 + lo) as u8
        } else {
            let value = bytes[cursor];
            cursor += 1;
            value
        };
        if byte.is_ascii_control() || byte == b'\\' {
            return None;
        }
        result.push(byte);
    }
    String::from_utf8(result).ok()
}

fn numeric_id(value: &str, min: usize, max: usize) -> bool {
    (min..=max).contains(&value.len()) && value.bytes().all(|byte| byte.is_ascii_digit())
}

fn meeting_link(facts: &URLFacts) -> Option<MeetingLink> {
    if !facts.scheme.eq_ignore_ascii_case("https")
        || facts.has_user_info
        || facts.has_fragment
        || facts.port.is_some_and(|port| port != 443)
    {
        return None;
    }
    let host = facts.host.to_ascii_lowercase();
    if !host.is_ascii() || host.is_empty() {
        return None;
    }
    let raw_path = &facts.encoded_path;
    if !raw_path.starts_with('/')
        || raw_path
            .chars()
            .any(|c| c.is_whitespace() || matches!(c, '?' | '#'))
    {
        return None;
    }
    let path = decoded_component(raw_path)?;
    let parts: Vec<_> = path
        .strip_prefix('/')?
        .trim_end_matches('/')
        .split('/')
        .collect();
    if parts
        .iter()
        .any(|part| part.is_empty() || matches!(*part, "." | ".."))
    {
        return None;
    }
    let provider = if host == "zoom.us"
        || host.ends_with(".zoom.us")
        || host == "zoomgov.com"
        || host.ends_with(".zoomgov.com")
    {
        let accepted = match parts.as_slice() {
            ["j", id] | ["wc", "join", id] | ["wc", id, "join"] => numeric_id(id, 9, 11),
            ["my", name] => {
                (5..=40).contains(&name.len())
                    && name.as_bytes()[0].is_ascii_alphabetic()
                    && name
                        .bytes()
                        .all(|byte| byte.is_ascii_alphanumeric() || byte == b'.')
            }
            _ => false,
        };
        if !accepted {
            return None;
        }
        "Zoom"
    } else if host == "meet.google.com" {
        let accepted = match parts.as_slice() {
            [code] => {
                let groups: Vec<_> = code.split('-').collect();
                groups.iter().map(|part| part.len()).eq([3, 4, 3])
                    && groups
                        .iter()
                        .all(|part| part.bytes().all(|b| b.is_ascii_alphabetic()))
            }
            ["lookup", name] => {
                !name.is_empty()
                    && name
                        .bytes()
                        .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_'))
            }
            _ => false,
        };
        if !accepted {
            return None;
        }
        "Google Meet"
    } else if matches!(
        host.as_str(),
        "teams.microsoft.com" | "teams.live.com" | "teams.cloud.microsoft"
    ) {
        let accepted = match parts.as_slice() {
            ["meet", id] => numeric_id(id, 5, 20),
            ["l", "meetup-join", room, "0"] => {
                room.starts_with("19:meeting_")
                    && room.ends_with("@thread.v2")
                    && room.len() > "19:meeting_@thread.v2".len()
            }
            _ => false,
        };
        if !accepted {
            return None;
        }
        "Microsoft Teams"
    } else {
        return None;
    };
    let query = match &facts.encoded_query {
        Some(raw) => {
            if raw.chars().any(|c| c.is_whitespace() || c == '#') {
                return None;
            }
            decoded_component(raw)?;
            format!("?{raw}")
        }
        None => String::new(),
    };
    Some(MeetingLink {
        url: format!("https://{host}{raw_path}{query}"),
        provider: provider.into(),
    })
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct Event {
    identifier: String,
    #[serde(rename = "calendarID")]
    calendar_id: String,
    title: String,
    start: f64,
    end: f64,
    is_all_day: bool,
    is_cancelled: bool,
    is_declined: bool,
    location: Option<String>,
    urls: Vec<URLFacts>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct Item {
    id: String,
    #[serde(rename = "calendarID")]
    calendar_id: String,
    title: String,
    start: f64,
    end: f64,
    display_end: f64,
    is_all_day: bool,
    location: Option<String>,
    meeting_link: Option<MeetingLink>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct Meeting {
    event: Item,
    is_ongoing: bool,
    minutes_until_start: u64,
    // Hosts can reuse their clock or schedule this boundary; the core owns no timer.
    next_change_at: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct EvaluationInput {
    events: Vec<Event>,
    preferences: Value,
    now: f64,
    range_start: f64,
    range_end: f64,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct Evaluation {
    events: Vec<Item>,
    next_meeting: Option<Meeting>,
    menu_bar_meeting: Option<Meeting>,
}

fn evaluate(input: EvaluationInput) -> Evaluation {
    let preferences = normalize_preferences(&input.preferences);
    let empty = || Evaluation {
        events: Vec::new(),
        next_meeting: None,
        menu_bar_meeting: None,
    };
    if !preferences.is_enabled
        || !input.now.is_finite()
        || !input.range_start.is_finite()
        || !input.range_end.is_finite()
        || input.range_start >= input.range_end
    {
        return empty();
    }
    let selected: Option<HashSet<_>> = preferences
        .selected_calendar_ids
        .as_ref()
        .map(|ids| ids.iter().collect());
    let mut seen = HashSet::new();
    let mut events: Vec<Item> = input
        .events
        .into_iter()
        .filter_map(|event| {
            if event.identifier.is_empty()
                || event.calendar_id.is_empty()
                || event.is_cancelled
                || event.is_declined
                || !event.start.is_finite()
                || !event.end.is_finite()
                || event.end <= event.start
                || event.end <= input.now
                || event.end <= input.range_start
                || event.start >= input.range_end
                || selected
                    .as_ref()
                    .is_some_and(|ids| !ids.contains(&event.calendar_id))
            {
                return None;
            }
            // JSON tuple encoding avoids collisions in calendar IDs or recurring item IDs.
            let id = json!([event.calendar_id, event.identifier, event.start]).to_string();
            if !seen.insert(id.clone()) {
                return None;
            }
            let meeting_link = event.urls.iter().find_map(meeting_link);
            Some(Item {
                id,
                calendar_id: event.calendar_id,
                title: event.title,
                start: event.start,
                end: event.end,
                display_end: if event.is_all_day {
                    (event.end - 1.0).max(event.start)
                } else {
                    event.end
                },
                is_all_day: event.is_all_day,
                location: event.location,
                meeting_link,
            })
        })
        .collect();
    events.sort_by(|a, b| {
        a.start
            .total_cmp(&b.start)
            .then(a.end.total_cmp(&b.end))
            .then(a.id.cmp(&b.id))
    });
    let next_meeting = events.iter().find(|event| !event.is_all_day).map(|event| {
        let is_ongoing = event.start <= input.now;
        let remaining = (event.start - input.now).max(0.0);
        let remainder = remaining % 60.0;
        let next_minute = input.now + if remainder == 0.0 { 60.0 } else { remainder };
        Meeting {
            event: event.clone(),
            is_ongoing,
            minutes_until_start: (remaining / 60.0).ceil() as u64,
            next_change_at: if is_ongoing {
                event.end
            } else {
                event.start.min(next_minute)
            },
        }
    });
    let menu_bar_meeting = preferences
        .show_in_menu_bar
        .then(|| next_meeting.clone())
        .flatten();
    Evaluation {
        events,
        next_meeting,
        menu_bar_meeting,
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct DayInput {
    events: Vec<Event>,
    preferences: Value,
    now: f64,
    day_start: f64,
    day_end: f64,
    anchor: f64,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct DayItem {
    #[serde(flatten)]
    event: Item,
    identifier: String,
    starts_before: bool,
    ended: bool,
    ongoing: bool,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct Day {
    all_day: Vec<Item>,
    timed: Vec<DayItem>,
    selected: Option<String>,
    next: Option<Item>,
}

fn day(input: DayInput) -> Day {
    let mut output = Day {
        all_day: Vec::new(),
        timed: Vec::new(),
        selected: None,
        next: None,
    };
    let preferences = normalize_preferences(&input.preferences);
    if !preferences.is_enabled
        || !input.now.is_finite()
        || !input.day_start.is_finite()
        || !input.day_end.is_finite()
        || !input.anchor.is_finite()
        || input.day_start >= input.day_end
    {
        return output;
    }
    let selected: Option<HashSet<_>> = preferences
        .selected_calendar_ids
        .as_ref()
        .map(|ids| ids.iter().collect());
    let mut seen = HashSet::new();
    for event in input.events {
        if event.identifier.is_empty()
            || event.calendar_id.is_empty()
            || event.is_cancelled
            || event.is_declined
            || !event.start.is_finite()
            || !event.end.is_finite()
            || event.end <= event.start
            || selected
                .as_ref()
                .is_some_and(|ids| !ids.contains(&event.calendar_id))
        {
            continue;
        }
        let is_day_span = event.is_all_day || event.end - event.start >= 86_400.0;
        let intersects_day = event.end > input.day_start && event.start < input.day_end;
        let is_next_candidate = !is_day_span && event.start >= input.day_end.max(input.now);
        if !intersects_day && !is_next_candidate {
            continue;
        }
        let id = json!([event.calendar_id, event.identifier, event.start]).to_string();
        if !seen.insert(id.clone()) {
            continue;
        }
        let identifier = event.identifier;
        let item = Item {
            id,
            calendar_id: event.calendar_id,
            title: event.title,
            start: event.start,
            end: event.end,
            display_end: if event.is_all_day {
                (event.end - 1.0).max(event.start)
            } else {
                event.end
            },
            is_all_day: event.is_all_day,
            location: event.location,
            meeting_link: event.urls.iter().find_map(meeting_link),
        };
        if intersects_day {
            if is_day_span {
                output.all_day.push(item);
            } else {
                output.timed.push(DayItem {
                    identifier,
                    starts_before: item.start < input.day_start,
                    ended: item.end <= input.now,
                    ongoing: item.start <= input.now && input.now < item.end,
                    event: item,
                });
            }
        } else if output.next.is_none() && is_next_candidate {
            output.next = Some(item);
        }
    }
    output.all_day.sort_by(|a, b| {
        a.start
            .total_cmp(&b.start)
            .then(a.title.cmp(&b.title))
            .then(a.id.cmp(&b.id))
    });
    output.timed.sort_by(|a, b| {
        a.event
            .start
            .total_cmp(&b.event.start)
            .then(a.event.end.total_cmp(&b.event.end))
            .then(a.event.id.cmp(&b.event.id))
    });
    let selected = if input.anchor < input.day_start {
        output.timed.first()
    } else if input.anchor >= input.day_end {
        output.timed.last()
    } else {
        output
            .timed
            .iter()
            .find(|item| item.event.end > input.anchor)
            .or_else(|| output.timed.last())
    };
    output.selected = selected.map(|item| item.event.id.clone());
    if input.day_end <= input.now || output.timed.iter().any(|item| item.event.end > input.now) {
        output.next = None;
    }
    output
}

// 每个地方相对第一场的钟点，记录连续偏移区段。

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct DriftEvent {
    identifier: String,
    title: String,
    start: f64,
    #[serde(default)]
    is_all_day: bool,
    #[serde(default)]
    is_cancelled: bool,
    #[serde(default)]
    has_attendees: bool,
    #[serde(default)]
    urls: Vec<URLFacts>,
}

#[derive(Clone, Debug, Deserialize)]
struct DriftParticipant {
    id: String,
    name: String,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct LocalFact {
    identifier: String,
    start: f64,
    participant: String,
    minute_of_day: i32,
}

#[derive(Clone, Debug, Deserialize)]
struct DriftInput {
    events: Vec<DriftEvent>,
    participants: Vec<DriftParticipant>,
    local: Vec<LocalFact>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
struct DriftRun {
    first: f64,
    last: f64,
    open: bool,
    minute: i32,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct DriftPlace {
    participant: String,
    participant_name: String,
    baseline: i32,
    runs: Vec<DriftRun>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
struct DriftMeeting {
    identifier: String,
    title: String,
    places: Vec<DriftPlace>,
}

fn drift(input: DriftInput) -> Vec<DriftMeeting> {
    use std::collections::BTreeMap;
    let mut groups: BTreeMap<&str, Vec<&DriftEvent>> = BTreeMap::new();
    for event in &input.events {
        if event.is_all_day
            || event.is_cancelled
            || !event.start.is_finite()
            || !(event.has_attendees || event.urls.iter().any(|url| meeting_link(url).is_some()))
        {
            continue;
        }
        groups
            .entry(event.identifier.as_str())
            .or_default()
            .push(event);
    }
    let mut meetings = Vec::new();
    for (identifier, mut occurrences) in groups {
        occurrences.sort_by(|a, b| a.start.total_cmp(&b.start));
        occurrences.dedup_by(|a, b| a.start == b.start);
        if occurrences.len() < 2 {
            continue;
        }
        let minutes: Vec<Vec<Option<i32>>> = occurrences
            .iter()
            .map(|occurrence| {
                input
                    .participants
                    .iter()
                    .map(|participant| {
                        input
                            .local
                            .iter()
                            .find(|fact| {
                                fact.identifier == identifier
                                    && fact.start == occurrence.start
                                    && fact.participant == participant.id
                            })
                            .map(|fact| fact.minute_of_day)
                    })
                    .collect()
            })
            .collect();
        let mut baselines = minutes[0].clone();
        // 每段保留开始时的基准，后续全员改时不重写旧段。
        let mut runs: Vec<Vec<(i32, DriftRun)>> = vec![Vec::new(); input.participants.len()];
        let mut active: Vec<Option<(i32, DriftRun)>> = vec![None; input.participants.len()];
        for k in 1..occurrences.len() {
            let mut compared = 0;
            let mut anchored = false;
            for (previous, current) in minutes[k - 1].iter().zip(&minutes[k]) {
                if let (Some(a), Some(b)) = (previous, current) {
                    compared += 1;
                    anchored |= a == b;
                }
            }
            if compared > 0 && !anchored {
                for (finished, open) in runs.iter_mut().zip(&mut active) {
                    if let Some(run) = open.take() {
                        finished.push(run);
                    }
                }
                baselines.clone_from(&minutes[k]);
                continue;
            }
            for (index, current) in minutes[k].iter().enumerate() {
                let (Some(baseline), Some(minute)) = (baselines[index], *current) else {
                    if let Some(run) = active[index].take() {
                        runs[index].push(run);
                    }
                    continue;
                };
                if minute == baseline {
                    if let Some(run) = active[index].take() {
                        runs[index].push(run);
                    }
                } else if active[index]
                    .as_ref()
                    .is_some_and(|(_, run)| run.minute == minute)
                {
                    active[index].as_mut().unwrap().1.last = occurrences[k].start;
                } else {
                    if let Some(run) = active[index].take() {
                        runs[index].push(run);
                    }
                    active[index] = Some((
                        baseline,
                        DriftRun {
                            first: occurrences[k].start,
                            last: occurrences[k].start,
                            open: false,
                            minute,
                        },
                    ));
                }
            }
        }
        let last = occurrences.last().unwrap().start;
        let places: Vec<_> = input
            .participants
            .iter()
            .enumerate()
            .flat_map(|(index, participant)| {
                if let Some((baseline, mut run)) = active[index].take() {
                    run.open = run.last == last;
                    runs[index].push((baseline, run));
                }
                let mut groups: Vec<DriftPlace> = Vec::new();
                for (baseline, run) in std::mem::take(&mut runs[index]) {
                    if let Some(place) = groups.iter_mut().find(|place| place.baseline == baseline) {
                        place.runs.push(run);
                    } else {
                        groups.push(DriftPlace {
                            participant: participant.id.clone(),
                            participant_name: participant.name.clone(),
                            baseline,
                            runs: vec![run],
                        });
                    }
                }
                groups
            })
            .collect();
        if !places.is_empty() {
            meetings.push(DriftMeeting {
                identifier: identifier.to_owned(),
                title: occurrences[0].title.clone(),
                places,
            });
        }
    }
    let first = |meeting: &DriftMeeting| {
        meeting
            .places
            .iter()
            .flat_map(|place| &place.runs)
            .map(|run| run.first)
            .min_by(f64::total_cmp)
            .unwrap()
    };
    meetings.sort_by(|a, b| first(a).total_cmp(&first(b)).then(a.title.cmp(&b.title)));
    meetings
}

pub fn dispatch(operation: &str, payload: Value) -> Result<Value, String> {
    let parse_error = |error: serde_json::Error| error.to_string();
    match operation {
        "agenda.normalize_preferences" => {
            serde_json::to_value(normalize_preferences(&payload)).map_err(parse_error)
        }
        "agenda.reduce" => serde_json::to_value(reduce(&payload)?).map_err(parse_error),
        "agenda.calendar_selection" => {
            let all: Vec<String> =
                serde_json::from_value(payload["allIDs"].clone()).map_err(parse_error)?;
            let selected: Option<Vec<String>> =
                serde_json::from_value(payload["selectedIDs"].clone()).map_err(parse_error)?;
            let selected = selected.map(|ids| ids.into_iter().collect::<HashSet<_>>());
            let ids: Vec<String> = all
                .into_iter()
                .filter(|id| selected.as_ref().is_none_or(|set| set.contains(id)))
                .collect();
            serde_json::to_value(ids).map_err(parse_error)
        }
        "agenda.meeting_link" => {
            let urls: Vec<URLFacts> =
                serde_json::from_value(payload["urls"].clone()).map_err(parse_error)?;
            serde_json::to_value(urls.iter().find_map(meeting_link)).map_err(parse_error)
        }
        "agenda.evaluate" => serde_json::to_value(evaluate(
            serde_json::from_value(payload).map_err(parse_error)?,
        ))
        .map_err(parse_error),
        "agenda.day" => {
            serde_json::to_value(day(serde_json::from_value(payload).map_err(parse_error)?))
                .map_err(parse_error)
        }
        "agenda.drift" => {
            let input: DriftInput = serde_json::from_value(payload).map_err(parse_error)?;
            Ok(json!({"meetings": drift(input)}))
        }
        _ => Err(format!("unknown agenda operation: {operation}")),
    }
}

#[cfg(test)]
#[path = "agenda_drift_baseline_regression_tests.rs"]
mod drift_baseline_regression_tests;

#[cfg(test)]
mod tests {
    #[test]
    fn drift_names_the_shifted_participants_and_ignores_meetings_that_moved_for_everyone() {
        use super::*;
        let events = json!([
            {"identifier":"weekly","title":"Weekly sync","hasAttendees":true,"start":1000.0},
            {"identifier":"weekly","title":"Weekly sync","hasAttendees":true,"start":2000.0},
            {"identifier":"weekly","title":"Weekly sync","hasAttendees":true,"start":3000.0},
            {"identifier":"moved","title":"Moved","hasAttendees":true,"start":1000.0},
            {"identifier":"moved","title":"Moved","hasAttendees":true,"start":2000.0},
            {"identifier":"single","title":"Single","hasAttendees":true,"start":1000.0},
            {"identifier":"allday","title":"Day","hasAttendees":true,"start":1000.0,"isAllDay":true},
            {"identifier":"allday","title":"Day","hasAttendees":true,"start":2000.0,"isAllDay":true}
        ]);
        let participants = json!([{"id":"la","name":"Los Angeles"},{"id":"akl","name":"Nia"},{"id":"ldn","name":"Ana"}]);
        let local = json!([
            {"identifier":"weekly","start":1000.0,"participant":"la","minuteOfDay":540},
            {"identifier":"weekly","start":2000.0,"participant":"la","minuteOfDay":540},
            {"identifier":"weekly","start":3000.0,"participant":"la","minuteOfDay":540},
            {"identifier":"weekly","start":1000.0,"participant":"akl","minuteOfDay":240},
            {"identifier":"weekly","start":2000.0,"participant":"akl","minuteOfDay":300},
            {"identifier":"weekly","start":3000.0,"participant":"akl","minuteOfDay":300},
            {"identifier":"weekly","start":1000.0,"participant":"ldn","minuteOfDay":1020},
            {"identifier":"weekly","start":2000.0,"participant":"ldn","minuteOfDay":1020},
            {"identifier":"weekly","start":3000.0,"participant":"ldn","minuteOfDay":1020},
            {"identifier":"moved","start":1000.0,"participant":"la","minuteOfDay":540},
            {"identifier":"moved","start":2000.0,"participant":"la","minuteOfDay":600},
            {"identifier":"moved","start":1000.0,"participant":"akl","minuteOfDay":240},
            {"identifier":"moved","start":2000.0,"participant":"akl","minuteOfDay":300},
            {"identifier":"allday","start":1000.0,"participant":"la","minuteOfDay":0},
            {"identifier":"allday","start":2000.0,"participant":"la","minuteOfDay":60}
        ]);
        let out = dispatch("agenda.drift", json!({"events":events,"participants":participants,"local":local})).unwrap();
        let meetings: Vec<DriftMeeting> = serde_json::from_value(out["meetings"].clone()).unwrap();
        assert_eq!(
            meetings,
            vec![DriftMeeting {
                identifier: "weekly".into(), title: "Weekly sync".into(),
                places: vec![DriftPlace {
                    participant: "akl".into(), participant_name: "Nia".into(), baseline: 240,
                    runs: vec![DriftRun { first: 2000.0, last: 3000.0, open: true, minute: 300 }]
                }]
            }]
        );
        assert!(dispatch("agenda.drift", json!({"events":[],"participants":[],"local":[]})).unwrap()["meetings"].as_array().unwrap().is_empty());
        assert!(dispatch("agenda.drift", json!({"events":"nope"})).is_err());
    }

    use super::*;

    fn url(host: &str, path: &str) -> URLFacts {
        URLFacts {
            scheme: "https".into(),
            host: host.into(),
            port: None,
            has_user_info: false,
            encoded_path: path.into(),
            encoded_query: None,
            has_fragment: false,
        }
    }
    fn event(id: &str, start: f64, end: f64) -> Event {
        Event {
            identifier: id.into(),
            calendar_id: "work".into(),
            title: id.into(),
            start,
            end,
            is_all_day: false,
            is_cancelled: false,
            is_declined: false,
            location: None,
            urls: Vec::new(),
        }
    }
    fn input(events: Vec<Event>) -> EvaluationInput {
        EvaluationInput {
            events,
            preferences: json!({"isEnabled":true}),
            now: 100.0,
            range_start: 0.0,
            range_end: 1000.0,
        }
    }

    #[test]
    fn fresh_preferences_are_completely_disabled_and_menu_bar_is_opt_in() {
        let p = normalize_preferences(&Value::Null);
        assert!(!p.is_enabled && !p.show_in_menu_bar);
        assert_eq!(p.days, 7);
        assert_eq!(p.selected_calendar_ids, None);
        let mut i = input(vec![event("one", 200.0, 300.0)]);
        i.preferences = Value::Null;
        assert!(evaluate(i).events.is_empty());
    }

    #[test]
    fn preference_fields_recover_independently_and_preserve_empty_selection() {
        let p = normalize_preferences(
            &json!({"isEnabled":true,"showInMenuBar":"bad","days":1,"selectedCalendarIDs":["b",null,"a","b",""]}),
        );
        assert!(p.is_enabled);
        assert!(!p.show_in_menu_bar);
        assert_eq!(p.days, 1);
        assert_eq!(p.selected_calendar_ids, Some(vec!["a".into(), "b".into()]));
        assert_eq!(
            normalize_preferences(&json!({"selectedCalendarIDs":[]})).selected_calendar_ids,
            Some(vec![])
        );
    }

    #[test]
    fn unchecking_one_calendar_freezes_the_explicit_selection() {
        let p = reduce(&json!({"preferences":{},"action":{"type":"calendar","id":"personal","included":false,"allIDs":["work","personal"]}})).unwrap();
        assert_eq!(p.selected_calendar_ids, Some(vec!["work".into()]));
        let restored = reduce(&json!({"preferences":p,"action":{"type":"allCalendars"}})).unwrap();
        assert_eq!(restored.selected_calendar_ids, None);
        assert!(reduce(&json!({"preferences":{},"action":{"type":"surprise"}})).is_err());
    }

    #[test]
    fn agenda_is_sorted_and_selects_the_ongoing_then_the_next_timed_event() {
        let mut all_day = event("holiday", 0.0, 900.0);
        all_day.is_all_day = true;
        let output = evaluate(input(vec![
            event("later", 300.0, 400.0),
            all_day,
            event("ongoing", 90.0, 150.0),
            event("next", 200.0, 250.0),
        ]));
        assert_eq!(
            output
                .events
                .iter()
                .map(|e| e.title.as_str())
                .collect::<Vec<_>>(),
            ["holiday", "ongoing", "next", "later"]
        );
        assert_eq!(output.next_meeting.as_ref().unwrap().event.title, "ongoing");
        assert!(output.next_meeting.unwrap().is_ongoing);
        assert!(output.menu_bar_meeting.is_none());
        let mut next = input(vec![
            event("ongoing", 90.0, 150.0),
            event("next", 200.0, 250.0),
        ]);
        next.now = 150.0;
        next.preferences = json!({"isEnabled":true,"showInMenuBar":true});
        let next = evaluate(next);
        assert_eq!(next.next_meeting, next.menu_bar_meeting);
        assert_eq!(next.next_meeting.unwrap().minutes_until_start, 1);
    }

    #[test]
    fn deleted_cancelled_declined_ended_and_invalid_events_never_become_meetings() {
        let mut cancelled = event("cancelled", 200.0, 250.0);
        cancelled.is_cancelled = true;
        let mut declined = event("declined", 200.0, 250.0);
        declined.is_declined = true;
        let output = evaluate(input(vec![
            cancelled,
            declined,
            event("ended", 0.0, 100.0),
            event("invalid", 200.0, 199.0),
            event("zero", 200.0, 200.0),
            event("nan", f64::NAN, 250.0),
        ]));
        assert!(output.events.is_empty() && output.next_meeting.is_none());
        assert!(evaluate(input(vec![])).next_meeting.is_none());
    }

    #[test]
    fn none_selected_is_distinct_from_all_and_unknown_ids_are_not_reassigned() {
        let mut i = input(vec![event("one", 200.0, 250.0)]);
        i.preferences = json!({"isEnabled":true,"selectedCalendarIDs":[]});
        assert!(evaluate(i).events.is_empty());
        let mut i = input(vec![event("one", 200.0, 250.0)]);
        i.preferences = json!({"isEnabled":true,"selectedCalendarIDs":["deletedCalendar"]});
        assert!(evaluate(i).events.is_empty());
    }

    #[test]
    fn recurrences_have_distinct_identity_and_duplicate_instances_are_removed() {
        let first = event("recurring", 200.0, 250.0);
        let output = evaluate(input(vec![
            first.clone(),
            event("recurring", 400.0, 450.0),
            first,
        ]));
        assert_eq!(output.events.len(), 2);
        assert_ne!(output.events[0].id, output.events[1].id);
    }

    #[test]
    fn date_boundaries_use_absolute_instants_and_half_open_intervals() {
        let mut i = input(vec![
            event("crossesStart", 50.0, 150.0),
            event("atEnd", 500.0, 550.0),
            event("inside", 499.0, 550.0),
        ]);
        i.range_start = 100.0;
        i.range_end = 500.0;
        let output = evaluate(i);
        assert_eq!(
            output
                .events
                .iter()
                .map(|e| e.title.as_str())
                .collect::<Vec<_>>(),
            ["crossesStart", "inside"]
        );
    }

    #[test]
    fn known_provider_links_keep_encoded_passwords_and_context() {
        for (host, path, provider) in [
            ("us02web.zoom.us", "/j/12345678901", "Zoom"),
            ("zoom.us", "/my/alice.example", "Zoom"),
            ("agency.zoomgov.com", "/j/1234567890", "Zoom"),
            ("meet.google.com", "/abc-defg-hij", "Google Meet"),
            ("meet.google.com", "/lookup/team-meeting", "Google Meet"),
            (
                "teams.microsoft.com",
                "/l/meetup-join/19%3ameeting_abc%40thread.v2/0",
                "Microsoft Teams",
            ),
            (
                "teams.microsoft.com",
                "/meet/1234567890123",
                "Microsoft Teams",
            ),
            ("teams.live.com", "/meet/1234567890123", "Microsoft Teams"),
        ] {
            let mut f = url(host, path);
            f.encoded_query = Some("pwd=abc%2B123%3D&context=%7B%22Tid%22%3A%22x%22%7D".into());
            let link = meeting_link(&f).unwrap();
            assert_eq!(link.provider, provider);
            assert_eq!(
                link.url,
                format!("https://{host}{path}?pwd=abc%2B123%3D&context=%7B%22Tid%22%3A%22x%22%7D")
            );
        }
    }

    #[test]
    fn unknown_hosts_lookalikes_and_non_meeting_paths_are_rejected() {
        for (host, path) in [
            ("zoom.us.evil.test", "/j/1234567890"),
            ("evilzoom.us", "/j/1234567890"),
            ("meet.google.com.evil.test", "/abc-defg-hij"),
            ("teams.microsoft.com.evil.test", "/meet/123456789"),
            ("zoom.us", "/signin"),
            ("meet.google.com", "/landing"),
            ("teams.microsoft.com", "/l/message/abc"),
            ("meet.google.com.", "/abc-defg-hij"),
            ("zооm.us", "/j/1234567890"),
        ] {
            assert!(meeting_link(&url(host, path)).is_none(), "{host}{path}");
        }
    }

    #[test]
    fn scripts_credentials_nonstandard_ports_fragments_and_traversal_are_rejected() {
        let valid = url("zoom.us", "/j/1234567890");
        let mut f = valid.clone();
        f.scheme = "zoommtg".into();
        assert!(meeting_link(&f).is_none());
        let mut f = valid.clone();
        f.scheme = "http".into();
        assert!(meeting_link(&f).is_none());
        let mut f = valid.clone();
        f.has_user_info = true;
        assert!(meeting_link(&f).is_none());
        let mut f = valid.clone();
        f.port = Some(444);
        assert!(meeting_link(&f).is_none());
        let mut f = valid.clone();
        f.has_fragment = true;
        assert!(meeting_link(&f).is_none());
        for path in [
            "//j/1234567890",
            "/j/%2e%2e/1234567890",
            "/j/1234567890%0A",
            "/j/1234567890\\x",
            "/j/%ZZ",
        ] {
            let mut f = valid.clone();
            f.encoded_path = path.into();
            assert!(meeting_link(&f).is_none());
        }
        for query in ["x=%0d%0a", "x=foo#bar", "x=%FF"] {
            let mut f = valid.clone();
            f.encoded_query = Some(query.into());
            assert!(meeting_link(&f).is_none());
        }
    }

    #[test]
    fn invalid_links_do_not_hide_the_first_valid_meeting_link() {
        let mut e = event("one", 200.0, 250.0);
        e.urls = vec![
            url("evil.test", "/j/1234567890"),
            url("meet.google.com", "/abc-defg-hij"),
        ];
        let output = evaluate(input(vec![e]));
        assert_eq!(
            output.events[0].meeting_link.as_ref().unwrap().provider,
            "Google Meet"
        );
    }

    #[test]
    fn dispatch_preserves_optional_link_and_rejects_invalid_contracts() {
        assert_eq!(
            dispatch("agenda.meeting_link", json!({"urls":[]})).unwrap(),
            Value::Null
        );
        assert!(dispatch("agenda.evaluate", json!({})).is_err());
        assert!(dispatch("agenda.missing", Value::Null).is_err());
    }

    #[test]
    fn calendar_query_selection_preserves_all_none_and_missing_id_meanings() {
        assert_eq!(
            dispatch(
                "agenda.calendar_selection",
                json!({"allIDs":["b","a"],"selectedIDs":null})
            )
            .unwrap(),
            json!(["b", "a"])
        );
        assert_eq!(
            dispatch(
                "agenda.calendar_selection",
                json!({"allIDs":["b","a"],"selectedIDs":[]})
            )
            .unwrap(),
            json!([])
        );
        assert_eq!(
            dispatch(
                "agenda.calendar_selection",
                json!({"allIDs":["b","a"],"selectedIDs":["a","deleted"]})
            )
            .unwrap(),
            json!(["a"])
        );
    }

    #[test]
    fn serialized_preferences_keep_calendar_acronym_and_selection_on_roundtrip() {
        let p = normalize_preferences(&json!({"isEnabled":true,"selectedCalendarIDs":["private"]}));
        let value = serde_json::to_value(&p).unwrap();
        assert_eq!(value["selectedCalendarIDs"], json!(["private"]));
        assert_eq!(normalize_preferences(&value), p);
    }

    #[test]
    fn all_day_display_excludes_the_exclusive_midnight_end() {
        let mut all_day = event("holiday", 0.0, 900.0);
        all_day.is_all_day = true;
        let output = evaluate(input(vec![all_day]));
        assert_eq!(output.events[0].display_end, 899.0);
        assert!(output.next_meeting.is_none());
    }

    #[test]
    fn countdown_wakes_when_the_rounded_minute_changes_or_the_event_starts() {
        let output = evaluate(input(vec![event("next", 400.0, 500.0)]));
        let next = output.next_meeting.unwrap();
        assert_eq!(next.minutes_until_start, 5);
        assert_eq!(next.next_change_at, 160.0);
        let output = evaluate(input(vec![event("next", 119.0, 150.0)]));
        let next = output.next_meeting.unwrap();
        assert_eq!(next.minutes_until_start, 1);
        assert_eq!(next.next_change_at, 119.0);
    }
}

#[cfg(test)]
mod day_and_drift_tests {
    use super::*;

    fn event(id: &str, start: f64, end: f64) -> Value {
        json!({"identifier":id,"calendarID":"work","title":id,"start":start,"end":end,
            "isAllDay":false,"isCancelled":false,"isDeclined":false,"urls":[]})
    }

    fn day_at(events: Vec<Value>, anchor: f64, now: f64) -> Value {
        dispatch(
            "agenda.day",
            json!({"events":events,"preferences":{"isEnabled":true},
            "now":now,"dayStart":100.0,"dayEnd":1000.0,"anchor":anchor}),
        )
        .unwrap()
    }

    #[test]
    fn day_keeps_ended_events_and_splits_day_spans_from_timed_events() {
        let mut all_day = event("holiday", 0.0, 150.0);
        all_day["isAllDay"] = json!(true);
        let output = day_at(
            vec![
                event("later", 400.0, 500.0),
                event("ended", 110.0, 150.0),
                event("ongoing", 180.0, 250.0),
                event("overnight", 90.0, 120.0),
                event("long", 50.0, 86_450.0),
                all_day,
            ],
            200.0,
            200.0,
        );
        assert_eq!(
            output["allDay"]
                .as_array()
                .unwrap()
                .iter()
                .map(|e| e["title"].as_str().unwrap())
                .collect::<Vec<_>>(),
            ["holiday", "long"]
        );
        let timed = output["timed"].as_array().unwrap();
        assert_eq!(
            timed
                .iter()
                .map(|e| e["identifier"].as_str().unwrap())
                .collect::<Vec<_>>(),
            ["overnight", "ended", "ongoing", "later"]
        );
        assert_eq!(timed[0]["startsBefore"], true);
        assert_eq!(timed[0]["ended"], true);
        assert_eq!(timed[2]["ongoing"], true);
        assert_eq!(timed[3]["ongoing"], false);
        assert_eq!(output["selected"], timed[2]["id"]);
        assert!(output["next"].is_null());
    }

    #[test]
    fn day_selection_obeys_anchor_boundaries_and_falls_back_to_last() {
        for (anchor, chosen) in [
            (99.0, "one"),
            (100.0, "one"),
            (149.0, "one"),
            (150.0, "two"),
            (249.0, "two"),
            (250.0, "two"),
            (999.0, "two"),
            (1000.0, "two"),
        ] {
            let output = day_at(
                vec![event("two", 200.0, 250.0), event("one", 110.0, 150.0)],
                anchor,
                150.0,
            );
            let expected = output["timed"]
                .as_array()
                .unwrap()
                .iter()
                .find(|e| e["identifier"] == chosen)
                .unwrap();
            assert_eq!(output["selected"], expected["id"], "anchor {anchor}");
        }
        assert!(day_at(vec![], 200.0, 150.0)["selected"].is_null());
    }

    #[test]
    fn day_uses_half_open_intersection_dedupe_and_calendar_selection() {
        let mut cancelled = event("cancelled", 110.0, 120.0);
        cancelled["isCancelled"] = json!(true);
        let mut declined = event("declined", 110.0, 120.0);
        declined["isDeclined"] = json!(true);
        let mut no_calendar = event("missing", 110.0, 120.0);
        no_calendar["calendarID"] = json!("");
        let mut home = event("home", 110.0, 120.0);
        home["calendarID"] = json!("home");
        let events = vec![
            event("before", 90.0, 100.0),
            event("after", 1000.0, 1100.0),
            event("inside", 999.0, 1100.0),
            event("cross", 99.0, 101.0),
            event("inside", 999.0, 1100.0),
            event("", 110.0, 120.0),
            event("zero", 110.0, 110.0),
            event("reversed", 120.0, 110.0),
            cancelled,
            declined,
            no_calendar,
            home,
        ];
        let payload = json!({"events":events,"preferences":{"isEnabled":true,"selectedCalendarIDs":["work"]},
            "now":200.0,"dayStart":100.0,"dayEnd":1000.0,"anchor":200.0});
        let output = dispatch("agenda.day", payload.clone()).unwrap();
        assert_eq!(
            output["timed"]
                .as_array()
                .unwrap()
                .iter()
                .map(|e| e["title"].as_str().unwrap())
                .collect::<Vec<_>>(),
            ["cross", "inside"]
        );
        for preferences in [
            json!({}),
            json!({"isEnabled":true,"selectedCalendarIDs":[]}),
            json!({"isEnabled":true,"selectedCalendarIDs":["deleted"]}),
        ] {
            let mut payload = payload.clone();
            payload["preferences"] = preferences;
            assert!(dispatch("agenda.day", payload).unwrap()["timed"]
                .as_array()
                .unwrap()
                .is_empty());
        }
    }

    #[test]
    fn day_next_uses_first_eligible_input_only_when_the_day_has_no_remaining_timed_events() {
        let mut holiday = event("holiday", 1000.0, 1100.0);
        holiday["isAllDay"] = json!(true);
        let mut cancelled = event("cancelled", 1000.0, 1100.0);
        cancelled["isCancelled"] = json!(true);
        let mut future = event("firstInput", 1200.0, 1250.0);
        future["urls"] = json!([{"scheme":"https","host":"meet.google.com","port":null,
            "hasUserInfo":false,"encodedPath":"/abc-defg-hij","encodedQuery":null,"hasFragment":false}]);
        let events = vec![
            event("past", 110.0, 150.0),
            holiday,
            cancelled,
            event("long", 1000.0, 87_400.0),
            future,
            event("earlier", 1000.0, 1100.0),
        ];
        let output = day_at(events.clone(), 200.0, 200.0);
        assert_eq!(output["next"]["title"], "firstInput");
        assert_eq!(output["next"]["meetingLink"]["provider"], "Google Meet");
        assert!(day_at(events.clone(), 200.0, 1000.0)["next"].is_null());
        let mut events = events;
        events.push(event("remaining", 200.0, 300.0));
        assert!(day_at(events, 200.0, 200.0)["next"].is_null());
    }

    #[test]
    fn day_invalid_bounds_and_nonfinite_inputs_return_no_items() {
        let parsed: DayInput = serde_json::from_value(json!({"events":[event("one",110.0,150.0)],
            "preferences":{"isEnabled":true},"now":120.0,"dayStart":100.0,"dayEnd":1000.0,"anchor":120.0})).unwrap();
        for field in 0..5 {
            let mut input = DayInput {
                events: parsed.events.clone(),
                preferences: parsed.preferences.clone(),
                now: parsed.now,
                day_start: parsed.day_start,
                day_end: parsed.day_end,
                anchor: parsed.anchor,
            };
            match field {
                0 => input.now = f64::NAN,
                1 => input.day_start = f64::NEG_INFINITY,
                2 => input.day_end = f64::INFINITY,
                3 => input.anchor = f64::NAN,
                _ => input.day_end = input.day_start,
            }
            assert!(day(input).timed.is_empty());
        }
        assert!(dispatch("agenda.day", json!({})).is_err());
    }

    fn drift_with(starts: &[f64], minutes: &[Vec<i32>], attendees: bool) -> Value {
        let events: Vec<_> = starts
            .iter()
            .map(|start| {
                json!({"identifier":"weekly","title":"Weekly sync",
            "start":start,"hasAttendees":attendees})
            })
            .collect();
        let participants: Vec<_> = minutes
            .iter()
            .enumerate()
            .map(|(index, _)| json!({"id":index.to_string(),"name":format!("Place {index}")}))
            .collect();
        let local: Vec<_> = minutes
            .iter()
            .enumerate()
            .flat_map(|(index, values)| {
                starts.iter().zip(values).map(move |(start, minute)| {
                    json!({"identifier":"weekly",
                "start":start,"participant":index.to_string(),"minuteOfDay":minute})
                })
            })
            .collect();
        json!({"events":events,"participants":participants,"local":local})
    }

    fn meetings(payload: Value) -> Vec<DriftMeeting> {
        serde_json::from_value(dispatch("agenda.drift", payload).unwrap()["meetings"].clone())
            .unwrap()
    }

    #[test]
    fn drift_reports_london_closed_week_and_tokyo_open_week_with_hand_built_clock_facts() {
        // 洛杉矶每周一九点；伦敦十月二十五日换钟，洛杉矶十一月一日换钟。
        let starts = [1_792_425_600.0, 1_793_030_400.0, 1_793_638_800.0];
        let result = meetings(drift_with(
            &starts,
            &[
                vec![540, 540, 540],
                vec![1020, 960, 1020],
                vec![60, 60, 120],
            ],
            true,
        ));
        assert_eq!(result.len(), 1);
        assert_eq!(
            result[0].places,
            vec![
                DriftPlace {
                    participant: "1".into(),
                    participant_name: "Place 1".into(),
                    baseline: 1020,
                    runs: vec![DriftRun {
                        first: starts[1],
                        last: starts[1],
                        open: false,
                        minute: 960
                    }]
                },
                DriftPlace {
                    participant: "2".into(),
                    participant_name: "Place 2".into(),
                    baseline: 60,
                    runs: vec![DriftRun {
                        first: starts[2],
                        last: starts[2],
                        open: true,
                        minute: 120
                    }]
                },
            ]
        );
        let shifted = meetings(drift_with(
            &starts[1..],
            &[vec![540, 540], vec![960, 1020], vec![60, 120]],
            true,
        ));
        assert_eq!(shifted[0].places[0].baseline, 960);
        assert_eq!(shifted[0].places[0].runs[0].minute, 1020);
        assert!(shifted[0].places[0].runs[0].open);
    }

    #[test]
    fn drift_organiser_moves_reset_baselines_and_do_not_create_warnings() {
        assert!(meetings(drift_with(
            &[100.0, 200.0, 300.0],
            &[vec![540, 600, 600], vec![1020, 1080, 1080]],
            true
        ))
        .is_empty());
        let result = meetings(drift_with(
            &[100.0, 200.0, 300.0],
            &[vec![540, 600, 600], vec![1020, 1080, 1140]],
            true,
        ));
        assert_eq!(result[0].places[0].baseline, 1080);
        assert_eq!(
            result[0].places[0].runs,
            [DriftRun {
                first: 300.0,
                last: 300.0,
                open: true,
                minute: 1140
            }]
        );
    }

    #[test]
    fn drift_closes_daily_runs_and_splits_different_shifted_minutes() {
        let result = meetings(drift_with(
            &[100.0, 200.0, 300.0, 400.0, 500.0, 600.0],
            &[vec![540; 6], vec![1020, 960, 960, 960, 1020, 900]],
            true,
        ));
        assert_eq!(
            result[0].places[0].runs,
            [
                DriftRun {
                    first: 200.0,
                    last: 400.0,
                    open: false,
                    minute: 960
                },
                DriftRun {
                    first: 600.0,
                    last: 600.0,
                    open: true,
                    minute: 900
                },
            ]
        );
        let result = meetings(drift_with(
            &[100.0, 200.0, 300.0],
            &[vec![540; 3], vec![1020, 960, 900]],
            true,
        ));
        assert_eq!(result[0].places[0].runs.len(), 2);
        assert!(!result[0].places[0].runs[0].open);
        assert!(result[0].places[0].runs[1].open);
    }

    #[test]
    fn drift_requires_attendees_or_a_recognized_link_and_ignores_cancelled_or_all_day_series() {
        let payload = drift_with(&[100.0, 200.0], &[vec![540, 540], vec![1020, 960]], false);
        assert!(meetings(payload.clone()).is_empty());
        for flag in ["isAllDay", "isCancelled"] {
            let mut payload = payload.clone();
            for event in payload["events"].as_array_mut().unwrap() {
                event["hasAttendees"] = json!(true);
                event[flag] = json!(true);
            }
            assert!(meetings(payload).is_empty());
        }
        let mut linked = payload.clone();
        for event in linked["events"].as_array_mut().unwrap() {
            event["urls"] = json!([{"scheme":"https","host":"meet.google.com","port":null,"hasUserInfo":false,
                "encodedPath":"/abc-defg-hij","encodedQuery":null,"hasFragment":false}]);
        }
        assert_eq!(meetings(linked.clone()).len(), 1);
        for event in linked["events"].as_array_mut().unwrap() {
            event["urls"][0]["host"] = json!("evil.test");
        }
        assert!(meetings(linked).is_empty());
    }

    #[test]
    fn drift_sorts_occurrences_deduplicates_and_preserves_participant_order() {
        let mut payload = drift_with(
            &[300.0, 100.0, 200.0, 200.0],
            &[
                vec![540; 4],
                vec![900, 1020, 960, 960],
                vec![180, 60, 120, 120],
            ],
            true,
        );
        payload["participants"].as_array_mut().unwrap().reverse();
        let result = meetings(payload);
        assert_eq!(
            result[0]
                .places
                .iter()
                .map(|p| p.participant.as_str())
                .collect::<Vec<_>>(),
            ["2", "1"]
        );
        assert_eq!(result[0].places[0].runs.len(), 2);
        assert_eq!(result[0].places[0].runs[0].first, 200.0);
    }

    #[test]
    fn day_seeded_selection_matches_end_boundaries_for_shuffled_events() {
        let seed = std::env::var("MEANTIME_FUZZ_SEED")
            .ok()
            .and_then(|v| v.parse::<u64>().ok())
            .unwrap_or(0);
        let mut state = 0x9E37_79B9_7F4A_7C15_u64.wrapping_add(seed);
        for _ in 0..150 {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            let anchor = (state % 1200) as f64;
            let events = vec![
                event("c", 700.0, 800.0),
                event("a", 110.0, 150.0),
                event("b", 200.0, 300.0),
            ];
            let expected = if anchor < 150.0 {
                "a"
            } else if anchor < 300.0 {
                "b"
            } else {
                "c"
            };
            let output = day_at(events, anchor, 400.0);
            let chosen = output["timed"]
                .as_array()
                .unwrap()
                .iter()
                .find(|item| item["id"] == output["selected"])
                .unwrap();
            assert_eq!(
                chosen["identifier"], expected,
                "anchor {anchor}, seed {seed}"
            );
        }
    }

    #[test]
    fn drift_seeded_daily_runs_match_the_hand_built_interval() {
        let seed = std::env::var("MEANTIME_FUZZ_SEED")
            .ok()
            .and_then(|v| v.parse::<u64>().ok())
            .unwrap_or(0);
        let mut state = 0xD1B5_4A32_D192_ED03_u64.wrapping_add(seed);
        for _ in 0..150 {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            let count = 3 + (state % 30) as usize;
            let baseline = (state % 1440) as i32;
            let shifted = (baseline + 1 + ((state >> 8) % 1439) as i32) % 1440;
            let first = 1 + ((state >> 16) % (count - 1) as u64) as usize;
            let last = first + ((state >> 24) % (count - first) as u64) as usize;
            let starts: Vec<_> = (0..count)
                .map(|index| 1000.0 + index as f64 * 86_400.0)
                .collect();
            let minutes = (0..count)
                .map(|index| {
                    if (first..=last).contains(&index) {
                        shifted
                    } else {
                        baseline
                    }
                })
                .collect();
            let result = meetings(drift_with(&starts, &[vec![540; count], minutes], true));
            assert_eq!(result[0].places[0].baseline, baseline);
            assert_eq!(
                result[0].places[0].runs,
                [DriftRun {
                    first: starts[first],
                    last: starts[last],
                    open: last == count - 1,
                    minute: shifted
                }]
            );
        }
    }

    #[test]
    fn day_outside_occurrences_do_not_hide_a_valid_duplicate() {
        let output = day_at(vec![event("same", 90.0, 100.0), event("same", 90.0, 120.0)], 110.0, 110.0);
        assert_eq!(output["timed"].as_array().unwrap().len(), 1);
        assert_eq!(output["timed"][0]["end"], 120.0);
    }

}
