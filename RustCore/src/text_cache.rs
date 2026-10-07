// SPDX-License-Identifier: GPL-3.0-only
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    sync::{Mutex, OnceLock},
};
type Cache = HashMap<String, String>;
fn storage() -> &'static Mutex<HashMap<String, Cache>> {
    static CACHE: OnceLock<Mutex<HashMap<String, Cache>>> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}
fn key(namespace: &str, value: &Value) -> String {
    let mut value = value.clone();
    if namespace == "time" {
        let unix = value["unix"].as_f64().unwrap_or(0.0);
        value.as_object_mut().unwrap().remove("unix");
        value["bucket"] = json!((unix / 60.0).floor() as i64);
    }
    value.to_string()
}
pub fn dispatch(operation: &str, payload: Value) -> Result<Value, String> {
    let action = operation
        .strip_prefix("cache.")
        .ok_or("Invalid cache operation")?;
    let (namespace, command) = action.rsplit_once('_').ok_or("Invalid cache operation")?;
    let mut caches = storage().lock().unwrap_or_else(|e| e.into_inner());
    let cache = caches.entry(namespace.to_owned()).or_default();
    match command {
        "get" => Ok(json!(cache.get(&key(namespace, &payload)))),
        "put" => {
            if cache.len() > 2048 {
                cache.clear();
            }
            cache.insert(
                key(namespace, &payload["key"]),
                payload["value"]
                    .as_str()
                    .ok_or("Missing cache value")?
                    .to_owned(),
            );
            Ok(json!(true))
        }
        _ => Err(format!("Unknown cache operation: {operation}")),
    }
}
