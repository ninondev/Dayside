// SPDX-License-Identifier: GPL-3.0-only
//! Dayside's platform-independent core. Apple frameworks are host services.
use serde::Deserialize;
use serde_json::{json, Value};
use std::panic::{catch_unwind, AssertUnwindSafe};
#[cfg(not(feature = "intents-only"))]
mod people;
#[cfg(not(feature = "intents-only"))]
mod timers;
#[cfg(not(feature = "intents-only"))]
mod dst_watch;
#[cfg(not(feature = "intents-only"))]
mod offset_windows;
#[cfg(not(feature = "intents-only"))]
mod tzdata;
#[cfg(not(feature = "intents-only"))]
mod diagnostics;
#[cfg(not(feature = "intents-only"))]
mod automation;
#[cfg(not(feature = "intents-only"))]
mod agenda;
#[cfg(not(feature = "intents-only"))]
mod catalog;
#[cfg(not(feature = "intents-only"))]
mod city_index;
pub mod fsst;
pub mod ttcity;
mod converter;
mod understand;
#[cfg(test)]
mod fuzz_tests;
#[cfg(not(feature = "intents-only"))]
mod hotkey;
#[cfg(not(feature = "intents-only"))]
mod label;
#[cfg(not(feature = "intents-only"))]
mod markets;
#[cfg(not(feature = "intents-only"))]
mod meeting;
#[cfg(not(feature = "intents-only"))]
mod model;
mod availability;
mod planner;
#[cfg(not(feature = "intents-only"))]
mod qr;
#[cfg(not(feature = "intents-only"))]
mod sharing;
#[cfg(not(feature = "intents-only"))]
mod astronomy;
// 昼夜条几何：intents-only 不要（它用不到，也没有 astronomy）。
#[cfg(not(feature = "intents-only"))]
mod lane;
#[cfg(not(feature = "intents-only"))]
mod travel;
#[cfg(not(feature = "intents-only"))]
mod presence;
#[cfg(not(feature = "intents-only"))]
mod presentation;
#[cfg(not(feature = "intents-only"))]
mod worldmap;
#[cfg(not(feature = "intents-only"))]
mod lights;
#[cfg(not(feature = "intents-only"))]
mod day_words;
#[cfg(not(feature = "intents-only"))]
mod sky;
#[cfg(not(feature = "intents-only"))]
mod settings;
#[cfg(not(feature = "intents-only"))]
mod solar;
#[cfg(not(feature = "intents-only"))]
mod spotlight;
#[cfg(not(feature = "intents-only"))]
mod store;
#[cfg(not(feature = "intents-only"))]
mod text_cache;

#[repr(C)]
pub struct MTBuffer {
    pub data: *mut u8,
    pub len: usize,
}

#[derive(Deserialize)]
struct Request {
    operation: String,
    payload: Value,
}

fn dispatch(operation: &str, payload: Value) -> Result<Value, String> {
    match operation {
        #[cfg(not(feature = "intents-only"))]
        _ if operation.starts_with("people.") => people::dispatch(operation, payload),
        #[cfg(not(feature = "intents-only"))]
        _ if operation.starts_with("timers.") => timers::dispatch(operation, payload),
        #[cfg(not(feature = "intents-only"))]
        _ if operation.starts_with("dstwatch.") => dst_watch::dispatch(operation, payload),
        #[cfg(not(feature = "intents-only"))]
        _ if operation.starts_with("offsetwindows.") => offset_windows::dispatch(operation, payload),
        #[cfg(not(feature = "intents-only"))]
        _ if operation.starts_with("tzdata.") => tzdata::dispatch(operation, payload),
        #[cfg(not(feature = "intents-only"))]
        _ if operation.starts_with("diagnostics.") => diagnostics::dispatch(operation, payload),
        #[cfg(not(feature = "intents-only"))]
        _ if operation.starts_with("automation.") => automation::dispatch(operation, payload),
        #[cfg(not(feature = "intents-only"))]
        _ if operation.starts_with("agenda.") => agenda::dispatch(operation, payload),
        #[cfg(not(feature = "intents-only"))]
        _ if operation.starts_with("travel.") => travel::dispatch(operation, payload),
        #[cfg(not(feature = "intents-only"))]
        _ if operation.starts_with("astronomy.") => astronomy::dispatch(operation, payload),
        #[cfg(not(feature = "intents-only"))]
        _ if operation.starts_with("sharing.") => sharing::dispatch(operation, payload),
        #[cfg(not(feature = "intents-only"))]
        _ if operation.starts_with("spotlight.") => spotlight::dispatch(operation, payload),
        "core.version" => Ok(json!({"abi": 1})),
        #[cfg(not(feature = "intents-only"))]
        _ if operation.starts_with("model.") => model::dispatch(operation, payload),
        #[cfg(not(feature = "intents-only"))]
        _ if operation.starts_with("presentation.") => presentation::dispatch(operation, payload),
        #[cfg(not(feature = "intents-only"))]
        _ if operation.starts_with("worldmap.") => worldmap::dispatch(operation, payload),
        #[cfg(not(feature = "intents-only"))]
        #[cfg(not(feature = "intents-only"))]
        _ if operation.starts_with("sky.") => sky::dispatch(operation, payload),
        #[cfg(not(feature = "intents-only"))]
        _ if operation.starts_with("hotkey.") => hotkey::dispatch(operation, payload),
        #[cfg(not(feature = "intents-only"))]
        _ if operation.starts_with("label.") => label::dispatch(operation, payload),
        #[cfg(not(feature = "intents-only"))]
        _ if operation.starts_with("qr.") => qr::dispatch(operation, payload),
        #[cfg(not(feature = "intents-only"))]
        _ if operation.starts_with("store.") => store::dispatch(operation, payload),
        #[cfg(not(feature = "intents-only"))]
        _ if operation.starts_with("settings.") => settings::dispatch(operation, payload),
        #[cfg(not(feature = "intents-only"))]
        _ if operation.starts_with("cache.") => text_cache::dispatch(operation, payload),
        // 作息与可约区间由 `availability.rs` 处理，多人重叠与轮换由 `planner.rs` 处理。
        _ if operation.starts_with("availability.") => availability::dispatch(operation, payload),
        _ if operation.starts_with("planner.") => planner::dispatch(operation, payload),
        #[cfg(not(feature = "intents-only"))]
        _ if operation.starts_with("markets.") => markets::dispatch(operation, payload),
        #[cfg(not(feature = "intents-only"))]
        _ if operation.starts_with("meeting.") => meeting::dispatch(operation, payload),
        #[cfg(not(feature = "intents-only"))]
        _ if operation.starts_with("city.") => city_index::dispatch(operation, payload),
        #[cfg(not(feature = "intents-only"))]
        _ if operation.starts_with("catalog.") => catalog::dispatch(operation, payload),
        _ if operation.starts_with("converter.") => converter::dispatch(operation, payload),
        _ if operation.starts_with("understand.") => understand::dispatch(operation, payload),
        #[cfg(not(feature = "intents-only"))]
        _ if operation.starts_with("presence.") => presence::dispatch(operation, payload),
        _ => Err(format!("Unknown core operation: {operation}")),
    }
}

fn respond(bytes: &[u8]) -> Vec<u8> {
    let result = catch_unwind(AssertUnwindSafe(|| {
        let request: Request = serde_json::from_slice(bytes).map_err(|e| e.to_string())?;
        dispatch(&request.operation, request.payload)
    }));
    let response = match result {
        Ok(Ok(value)) => json!({"value": value}),
        Ok(Err(error)) => json!({"error": error}),
        Err(_) => json!({"error": "Rust core panicked"}),
    };
    serde_json::to_vec(&response).expect("JSON response is serializable")
}

#[no_mangle]
pub extern "C" fn mt_core_abi_version() -> u32 {
    1
}

/// # Safety
/// `data` must point to `len` readable bytes for the duration of this call.
/// Null is valid only for zero length. The result must be freed exactly once.
#[no_mangle]
pub unsafe extern "C" fn mt_core_call(data: *const u8, len: usize) -> MTBuffer {
    let bytes = if len == 0 {
        &[]
    } else if data.is_null() {
        return MTBuffer {
            data: std::ptr::null_mut(),
            len: 0,
        };
    } else {
        // SAFETY: the host guarantees the input buffer lifetime and length.
        unsafe { std::slice::from_raw_parts(data, len) }
    };
    let output = respond(bytes).into_boxed_slice();
    let len = output.len();
    MTBuffer {
        data: Box::into_raw(output).cast::<u8>(),
        len,
    }
}

/// # Safety
/// `buffer` must be a live result of `mt_core_call`, not previously freed.
#[no_mangle]
pub unsafe extern "C" fn mt_core_free(buffer: MTBuffer) {
    if !buffer.data.is_null() {
        let slice = std::ptr::slice_from_raw_parts_mut(buffer.data, buffer.len);
        // SAFETY: the buffer comes from Box::into_raw above.
        unsafe {
            drop(Box::from_raw(slice));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn malformed_requests_return_errors() {
        for input in [b"".as_slice(), b"no-json", b"{}"] {
            let response: Value = serde_json::from_slice(&respond(input)).unwrap();
            assert!(response["error"].is_string());
        }
    }
    #[test]
    fn abi_round_trip_and_free() {
        let input = br#"{"operation":"core.version","payload":{}}"#;
        unsafe {
            let output = mt_core_call(input.as_ptr(), input.len());
            let value: Value =
                serde_json::from_slice(std::slice::from_raw_parts(output.data, output.len))
                    .unwrap();
            assert_eq!(value["value"]["abi"], 1);
            mt_core_free(output);
        }
    }
}
