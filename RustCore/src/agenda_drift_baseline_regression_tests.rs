// SPDX-License-Identifier: GPL-3.0-only

use serde_json::{json, Value};

fn drift(starts: &[f64], la: &[i32], london: &[i32]) -> Value {
    let events: Vec<_> = starts
        .iter()
        .map(|start| {
            json!({"identifier":"weekly","title":"Weekly sync","start":start,
                "hasAttendees":true})
        })
        .collect();
    let local: Vec<_> = [("la", la), ("london", london)]
        .into_iter()
        .flat_map(|(participant, minutes)| {
            starts.iter().zip(minutes).map(move |(start, minute)| {
                json!({"identifier":"weekly","start":start,
                    "participant":participant,"minuteOfDay":minute})
            })
        })
        .collect();
    super::dispatch(
        "agenda.drift",
        json!({"events":events,"local":local,"participants":[
            {"id":"la","name":"Los Angeles"},
            {"id":"london","name":"London"}]}),
    )
    .unwrap()
}

#[test]
fn finished_run_retains_its_starting_baseline_after_organiser_moves_everyone() {
    // 最后一场全员改时间，已结束的漂移仍以原钟点为准。
    let result = drift(&[100.0, 200.0, 300.0], &[540, 540, 600], &[1020, 960, 1080]);
    assert_eq!(
        result["meetings"],
        json!([{"identifier":"weekly","title":"Weekly sync","places":[{
            "participant":"london","participantName":"London","baseline":1020,
            "runs":[{"first":200.0,"last":200.0,"open":false,"minute":960}]}]}])
    );
}

#[test]
fn separated_baseline_epochs_keep_their_own_completed_and_open_runs() {
    let result = drift(
        &[100.0, 200.0, 300.0, 400.0, 500.0],
        &[540, 540, 600, 600, 600],
        &[1020, 960, 1080, 1140, 1140],
    );
    assert_eq!(
        result["meetings"][0]["places"],
        json!([
            {"participant":"london","participantName":"London","baseline":1020,
             "runs":[{"first":200.0,"last":200.0,"open":false,"minute":960}]},
            {"participant":"london","participantName":"London","baseline":1080,
             "runs":[{"first":400.0,"last":500.0,"open":true,"minute":1140}]}
        ])
    );
}
