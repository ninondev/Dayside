// SPDX-License-Identifier: GPL-3.0-only
//! Explicit, local sharing. System timezone facts and planner intervals come from
//! the native adapter; no account, calendar, network, or contact data is read here.
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct Draft {
    #[serde(rename = "timeZoneID")]
    time_zone_id: String,
    display_name: String,
    includes_availability: bool,
    start_minute: i64,
    end_minute: i64,
    working_weekdays: Vec<u8>,
    /// 预约回执邮箱：对方在分享页选了时段后，
    /// 页面替他起一封给这个地址的邮件。空串 = 不放进名片。
    #[serde(default)]
    contact_email: String,
    /// 名片上的地名：发方在自己地点表里看到的城市名（不带自定义名与 emoji）。空串 = 不写（旧草稿没有这个键）。
    #[serde(default)]
    place_name: String,
    /// 那座城的拉丁写法（数据里的主名）：与上面不同才进名片，收方读不了汉字时也认得出是哪座城。
    #[serde(default)]
    place_city: String,
    /// 那座城的经纬度：收方的页面按它画那边此刻的天。进名片前四舍五入到 0.1°（约 11 公里），只说是哪座城。
    #[serde(default)]
    latitude: Option<f64>,
    #[serde(default)]
    longitude: Option<f64>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct Schedule {
    start_minute: i64,
    end_minute: i64,
    working_weekdays: Vec<u8>,
    is_whole_day: bool,
    end_day_offset: u8,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq)]
struct Window {
    start: f64,
    end: f64,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct Payload {
    version: u8,
    #[serde(rename = "timeZoneID")]
    time_zone_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    fixed_offset_seconds: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    display_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    schedule: Option<Schedule>,
    generated_at: f64,
    valid_until: f64,
    windows: Vec<Window>,
    /// tzdata release the sender's Mac used when computing the windows (e.g. `2026c`); the receiver
    /// can tell when a card was made with older rules than its own. Absent in cards from before it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    tzdata: Option<String>,
    /// Where a visitor's booking mail should go. Optional; the hosted page builds a `mailto:` from it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    contact_email: Option<String>,
    /// 可选地名；类型不合就当没有。
    #[serde(default, deserialize_with = "optional_postcard_field", skip_serializing_if = "Option::is_none")]
    place: Option<String>,
    #[serde(default, deserialize_with = "optional_postcard_field", skip_serializing_if = "Option::is_none")]
    city: Option<String>,
    /// 可选城市坐标；类型不合就当没有。
    #[serde(default, deserialize_with = "optional_postcard_field", skip_serializing_if = "Option::is_none")]
    latitude: Option<f64>,
    #[serde(default, deserialize_with = "optional_postcard_field", skip_serializing_if = "Option::is_none")]
    longitude: Option<f64>,
}

/// 坏的可选字段不影响名片其余内容。
fn optional_postcard_field<'de, D, T>(deserializer: D) -> Result<Option<T>, D::Error>
where
    D: serde::Deserializer<'de>,
    T: serde::de::DeserializeOwned,
{
    let raw = Box::<serde_json::value::RawValue>::deserialize(deserializer)?;
    Ok(serde_json::from_str(raw.get()).ok())
}

/// 名片上的地名：去首尾空白与控制符，最多 80 个字符；空了就是没有。
fn clean_place_name(value: &str) -> Option<String> {
    let text: String = value.chars().filter(|c| !c.is_control()).take(80).collect::<String>().trim().to_owned();
    (!text.is_empty()).then_some(text)
}

/// 经纬度一对都在范围里才要，四舍五入到 0.1°；缺一个或越界就都不要。
fn rounded_coordinate(latitude: Option<f64>, longitude: Option<f64>) -> Option<(f64, f64)> {
    let (lat, lon) = (latitude?, longitude?);
    if !lat.is_finite() || !lon.is_finite() || lat.abs() > 90.0 || lon.abs() > 180.0 {
        return None;
    }
    let round = |v: f64| (v * 10.0).round() / 10.0;
    Some((round(lat), round(lon)))
}

/// 只认最朴素的形状：ASCII 可见字符、一个 `@`、本地部分与域都非空、域里有点、总长 ≤ 254。
/// 不做 RFC 5322 全集——名片会被贴进网页的 `mailto:`，宁可少收也不收带引号和空白的写法。
fn valid_email(text: &str) -> bool {
    let bytes = text.as_bytes();
    if bytes.is_empty() || bytes.len() > 254 || !bytes.iter().all(|b| b.is_ascii_graphic()) {
        return false;
    }
    let Some((local, domain)) = text.split_once('@') else {
        return false;
    };
    !local.is_empty()
        && !domain.is_empty()
        && local.len() <= 64
        && !local.contains('@')
        && !domain.contains('@')
        && domain.contains('.')
        && !domain.starts_with('.')
        && !domain.ends_with('.')
        && !domain.contains("..")
        && domain
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'.')
        && !text.contains(['<', '>', '"', '\\', ',', ';', '(', ')', '[', ']', '?', '#', '/'])
}

/// A tzdata release looks like `2026c`: short, ASCII letters and digits only.
fn tzdata_release(value: Option<&str>) -> Option<String> {
    let text = value?.trim();
    (!text.is_empty() && text.len() <= 12 && text.chars().all(|c| c.is_ascii_alphanumeric()))
        .then(|| text.to_owned())
}

fn validate(value: &Value) -> (Option<Draft>, Vec<&'static str>) {
    let Ok(mut draft) = serde_json::from_value::<Draft>(value["draft"].clone()) else {
        return (None, vec!["draft"]);
    };
    draft.time_zone_id = draft.time_zone_id.trim().to_owned();
    draft.display_name = draft.display_name.trim().to_owned();
    draft.working_weekdays.sort();
    draft.working_weekdays.dedup();
    let mut errors = Vec::new();
    if value["timeZoneValid"].as_bool() != Some(true)
        || draft.time_zone_id.is_empty()
        || draft.time_zone_id.len() > 128
        || draft.time_zone_id.chars().any(char::is_control)
    {
        errors.push("timeZone");
    }
    if draft.display_name.chars().count() > 80 || draft.display_name.chars().any(char::is_control) {
        errors.push("name");
    }
    draft.contact_email = draft.contact_email.trim().to_owned();
    if !draft.contact_email.is_empty() && !valid_email(&draft.contact_email) {
        errors.push("contact");
    }
    if draft.includes_availability {
        if !(0..1440).contains(&draft.start_minute) || !(0..=1440).contains(&draft.end_minute) {
            errors.push("hours");
        }
        if draft.working_weekdays.is_empty()
            || draft
                .working_weekdays
                .iter()
                .any(|day| !(1..=7).contains(day))
        {
            errors.push("weekdays");
        }
    }
    if errors.is_empty() {
        (Some(draft), errors)
    } else {
        (None, errors)
    }
}

fn escape_html(value: &str) -> String {
    value.chars().fold(String::new(), |mut result, c| {
        match c {
            '&' => result.push_str("&amp;"),
            '<' => result.push_str("&lt;"),
            '>' => result.push_str("&gt;"),
            '"' => result.push_str("&quot;"),
            '\'' => result.push_str("&#39;"),
            _ => result.push(c),
        }
        result
    })
}

fn host_url(value: &Value) -> Result<Option<String>, &'static str> {
    if value.is_null() {
        return Ok(None);
    }
    let scheme = value["scheme"].as_str().ok_or("hostURL")?;
    let host = value["host"]
        .as_str()
        .ok_or("hostURL")?
        .to_ascii_lowercase();
    let path = value["encodedPath"].as_str().ok_or("hostURL")?;
    if !scheme.eq_ignore_ascii_case("https")
        || value["hasUserInfo"].as_bool() != Some(false)
        || value["hasQuery"].as_bool() != Some(false)
        || value["hasFragment"].as_bool() != Some(false)
        || (!value["port"].is_null() && value["port"].as_u64() != Some(443))
        || host.len() > 253
        || host.is_empty()
        || host.split('.').any(|label| {
            label.is_empty()
                || label.len() > 63
                || label.starts_with('-')
                || label.ends_with('-')
                || !label
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'-')
        })
        || path.len() > 2048
        || (!path.is_empty() && !path.starts_with('/'))
        || path
            .chars()
            .any(|c| c.is_control() || c.is_whitespace() || matches!(c, '\\' | '?' | '#'))
        || path.split('/').any(|part| matches!(part, "." | ".."))
    {
        return Err("hostURL");
    }
    let mut cursor = 0;
    let bytes = path.as_bytes();
    while cursor < bytes.len() {
        if bytes[cursor] == b'%' {
            let pair = bytes.get(cursor + 1..cursor + 3).ok_or("hostURL")?;
            let hi = char::from(pair[0]).to_digit(16).ok_or("hostURL")?;
            let lo = char::from(pair[1]).to_digit(16).ok_or("hostURL")?;
            let decoded = (hi * 16 + lo) as u8;
            if decoded.is_ascii_control() || matches!(decoded, b'\\' | b'/' | b'.') {
                return Err("hostURL");
            }
            cursor += 3;
        } else {
            cursor += 1;
        }
    }
    Ok(Some(format!("https://{host}{path}")))
}

/// Foundation normalizes fixed offsets to GMT or GMT+HHMM / GMT-HHMM.
/// Preserve them as numeric offsets because browsers reject these identifiers.
/// Geographic zones keep their IANA rules, including future DST transitions.
fn fixed_offset(value: &Value) -> Result<Option<i64>, &'static str> {
    let native = value["nativeTimeZoneID"].as_str().ok_or("timeZone")?;
    let offset = if native == "GMT" {
        0
    } else if let Some(rest) = native
        .strip_prefix("GMT")
        .filter(|rest| rest.starts_with(['+', '-']))
    {
        let bytes = rest.as_bytes();
        if bytes.len() != 5 || !bytes[1..].iter().all(u8::is_ascii_digit) {
            return Err("timeZone");
        }
        let hours = i64::from(bytes[1] - b'0') * 10 + i64::from(bytes[2] - b'0');
        let minutes = i64::from(bytes[3] - b'0') * 10 + i64::from(bytes[4] - b'0');
        if minutes > 59 || hours * 60 + minutes > 18 * 60 {
            return Err("timeZone");
        }
        (hours * 3600 + minutes * 60) * if bytes[0] == b'-' { -1 } else { 1 }
    } else {
        return Ok(None);
    };
    if value["nativeOffsetSeconds"].as_i64() != Some(offset) {
        return Err("timeZone");
    }
    Ok(Some(offset))
}

fn build(value: &Value) -> Result<Value, String> {
    let (draft, errors) = validate(value);
    let Some(draft) = draft else {
        return Ok(json!({"document": null, "errors": errors}));
    };
    let fixed_offset_seconds = match fixed_offset(value) {
        Ok(offset) => offset,
        Err(error) => return Ok(json!({"document":null,"errors":[error]})),
    };
    let now = value["now"]
        .as_f64()
        .filter(|v| v.is_finite() && v.abs() < 253_402_214_400.0);
    let end = value["validUntil"].as_f64().filter(|v| v.is_finite());
    let (Some(now), Some(end)) = (now, end) else {
        return Ok(json!({"document":null,"errors":["dates"]}));
    };
    if end <= now || end - now > 15.0 * 86_400.0 {
        return Ok(json!({"document":null,"errors":["dates"]}));
    }
    let base = match host_url(&value["hostFacts"]) {
        Ok(url) => url,
        Err(error) => return Ok(json!({"document":null,"errors":[error]})),
    };
    let mut windows = Vec::new();
    if draft.includes_availability {
        let Ok(input) = serde_json::from_value::<Vec<Window>>(value["intervals"].clone()) else {
            return Ok(json!({"document":null,"errors":["dates"]}));
        };
        if input.len() > 128 {
            return Ok(json!({"document":null,"errors":["dates"]}));
        }
        for window in input {
            if !window.start.is_finite() || !window.end.is_finite() || window.start >= window.end {
                return Ok(json!({"document":null,"errors":["dates"]}));
            }
            let clipped = Window {
                start: window.start.max(now),
                end: window.end.min(end),
            };
            if clipped.start < clipped.end {
                windows.push(clipped);
            }
        }
        windows.sort_by(|a, b| a.start.total_cmp(&b.start).then(a.end.total_cmp(&b.end)));
        let mut merged: Vec<Window> = Vec::new();
        for window in windows {
            if let Some(last) = merged.last_mut().filter(|last| window.start <= last.end) {
                last.end = last.end.max(window.end);
            } else {
                merged.push(window);
            }
        }
        windows = merged;
    }
    let place = clean_place_name(&draft.place_name);
    let city = clean_place_name(&draft.place_city).filter(|city| Some(city) != place.as_ref() && place.is_some());
    let coordinate = rounded_coordinate(draft.latitude, draft.longitude);
    let schedule = draft.includes_availability.then_some(Schedule {
        start_minute: draft.start_minute,
        end_minute: draft.end_minute,
        working_weekdays: draft.working_weekdays,
        is_whole_day: draft.start_minute == draft.end_minute
            || (draft.start_minute == 0 && draft.end_minute == 1440),
        end_day_offset: u8::from(
            draft.end_minute <= draft.start_minute || draft.end_minute == 1440,
        ),
    });
    let payload = Payload {
        version: 1,
        time_zone_id: draft.time_zone_id,
        fixed_offset_seconds,
        display_name: (!draft.display_name.is_empty()).then_some(draft.display_name),
        schedule,
        generated_at: now,
        valid_until: end,
        windows,
        tzdata: tzdata_release(value["tzdata"].as_str()),
        contact_email: (!draft.contact_email.is_empty()).then_some(draft.contact_email),
        place: place.clone(),
        city,
        latitude: coordinate.map(|c| c.0),
        longitude: coordinate.map(|c| c.1),
    };
    let bytes = serde_json::to_vec(&payload).map_err(|e| e.to_string())?;
    let fragment = format!("mt1.{}", URL_SAFE_NO_PAD.encode(bytes));
    let share_url = base.map(|url| format!("{url}#{fragment}"));
    // 标签页标题：「Mei · 东京」，只有一样就写那一样，都没有写 Dayside（页面脚本打开后会按同一规矩再设一次）。
    let title = match (payload.display_name.as_deref().filter(|n| !n.is_empty()), place.as_deref()) {
        (Some(name), Some(place)) => format!("{name} · {place}"),
        (Some(name), None) => name.to_owned(),
        (None, Some(place)) => place.to_owned(),
        (None, None) => "Dayside".to_owned(),
    };
    let html = include_str!("../../site/when.html")
        .replace("__MEANTIME_PAYLOAD__", &fragment)
        .replace("__MEANTIME_TITLE__", &escape_html(&title));
    Ok(
        json!({"document":{"payload":payload,"fragment":fragment,"shareURL":share_url,"html":html},"errors":[]}),
    )
}

/// What another person's shared card says about them, reduced to fields the People lens can keep.
#[derive(Clone, Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct Card {
    #[serde(rename = "timeZoneID")]
    time_zone_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    fixed_offset_seconds: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    display_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    start_minute: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    end_minute: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    working_weekdays: Option<Vec<u8>>,
    generated_at: f64,
    valid_until: f64,
    windows: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    tzdata: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    contact_email: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    place: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    city: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    latitude: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    longitude: Option<f64>,
}

/// Reads a pasted share link or bare `mt1.` fragment produced by `build`. Everything is treated as
/// untrusted input: bounded lengths, checked ranges, no HTML, no execution. Serverless by design:
/// two people exchange cards and each Mac merges them locally.
fn decode(value: &Value) -> Value {
    let text = value["text"].as_str().unwrap_or("");
    let now = value["now"].as_f64().unwrap_or(0.0);
    if text.len() > 16_384 {
        return json!({"card": null, "error": "tooLong"});
    }
    let Some(at) = text.find("mt1.") else {
        return json!({"card": null, "error": "notACard"});
    };
    let encoded: String = text[at + 4..]
        .chars()
        .take_while(|c| c.is_ascii_alphanumeric() || *c == '-' || *c == '_')
        .collect();
    if encoded.is_empty() || encoded.len() > 12_000 {
        return json!({"card": null, "error": "notACard"});
    }
    let Ok(bytes) = URL_SAFE_NO_PAD.decode(encoded.as_bytes()) else {
        return json!({"card": null, "error": "corrupt"});
    };
    let Ok(payload) = serde_json::from_slice::<Payload>(&bytes) else {
        return json!({"card": null, "error": "corrupt"});
    };
    if payload.version != 1 {
        return json!({"card": null, "error": "unsupportedVersion"});
    }
    let zone = payload.time_zone_id.trim();
    if zone.is_empty()
        || zone.len() > 64
        || zone.chars().any(|c| c.is_whitespace() || c.is_control())
        || !payload.generated_at.is_finite()
        || !payload.valid_until.is_finite()
        || payload.windows.len() > 128
    {
        return json!({"card": null, "error": "invalid"});
    }
    let display_name = payload
        .display_name
        .map(|name| {
            name.chars()
                .filter(|c| !c.is_control())
                .take(80)
                .collect::<String>()
                .trim()
                .to_owned()
        })
        .filter(|name| !name.is_empty());
    let (mut start_minute, mut end_minute, mut working_weekdays) = (None, None, None);
    if let Some(schedule) = payload.schedule {
        // 与 `validate` 同一对区间：发方永远写不出 startMinute 1440，收方也不认——人物模型只收
        // 0..1440 的开始分钟，放进来的人物在人物页存不回去（Swift 侧 fuzz 查出）。
        if !(0..1440).contains(&schedule.start_minute)
            || !(0..=1440).contains(&schedule.end_minute)
        {
            return json!({"card": null, "error": "invalid"});
        }
        let mut weekdays: Vec<u8> = schedule
            .working_weekdays
            .into_iter()
            .filter(|d| (1..=7).contains(d))
            .collect();
        weekdays.sort();
        weekdays.dedup();
        if weekdays.is_empty() {
            return json!({"card": null, "error": "invalid"});
        }
        // 起止相同也按全天收成 0–1440（人物模型与排会都把 start == end 当全天）：否则「18:00–18:00」这种
        // 标志位没打但起止相同的名片导入后再做名片会变成 0–0，往返不稳定（Swift 侧换种子 fuzz 查出）。
        if schedule.is_whole_day || schedule.start_minute == schedule.end_minute {
            start_minute = Some(0);
            end_minute = Some(1440);
        } else {
            start_minute = Some(schedule.start_minute);
            end_minute = Some(schedule.end_minute);
        }
        working_weekdays = Some(weekdays);
    }
    let place = payload.place.as_deref().and_then(clean_place_name);
    let city = payload.city.as_deref().and_then(clean_place_name)
        .filter(|city| place.as_ref().is_some_and(|place| city != place));
    let coordinate = rounded_coordinate(payload.latitude, payload.longitude);
    let card = Card {
        time_zone_id: zone.to_owned(),
        fixed_offset_seconds: payload
            .fixed_offset_seconds
            .filter(|o| o.abs() <= 18 * 3600),
        display_name,
        start_minute,
        end_minute,
        working_weekdays,
        generated_at: payload.generated_at,
        valid_until: payload.valid_until,
        windows: payload.windows.len(),
        tzdata: tzdata_release(payload.tzdata.as_deref()),
        // 别人的名片里的邮箱同样按最朴素形状核，不合形就当没有，不因此拒收整张名片。
        contact_email: payload
            .contact_email
            .as_deref()
            .map(str::trim)
            .filter(|e| valid_email(e))
            .map(str::to_owned),
        place,
        city,
        latitude: coordinate.map(|c| c.0),
        longitude: coordinate.map(|c| c.1),
    };
    json!({"card": card, "expired": now > payload.valid_until, "error": null})
}

// —— 地点清单同步——
// 与时间名片 `mt1.` 平行的第二种片段 `dp1.`：只装地点（名字、时区、国家码、坐标），不装可约时段，
// 不经任何服务器；链接形如 `dayside://import#dp1.<base64url>`，iPhone 扫码或粘贴后由本模块解回。

const PLACES_LIMIT: usize = 200;
/// 链接（含 `dayside://import#`）与粘贴文本共用的长度上限。
const PLACES_TEXT_LIMIT: usize = 65_536;

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct TransferPlace {
    name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    raw_city_name: Option<String>,
    #[serde(rename = "timeZoneID")]
    time_zone_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    country_code: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    latitude: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    longitude: Option<f64>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct TransferPayload {
    version: u8,
    generated_at: f64,
    places: Vec<TransferPlace>,
}

fn clean_place(place: &TransferPlace) -> Option<TransferPlace> {
    let name = place.name.trim();
    let zone = place.time_zone_id.trim();
    if name.is_empty()
        || name.chars().count() > 80
        || name.chars().any(char::is_control)
        || zone.is_empty()
        || zone.len() > 128
        || !zone.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'/' | b'_' | b'-' | b'+'))
    {
        return None;
    }
    let country = place
        .country_code
        .as_deref()
        .map(str::trim)
        .filter(|c| c.len() == 2 && c.bytes().all(|b| b.is_ascii_uppercase()))
        .map(str::to_owned);
    let (latitude, longitude) = match (place.latitude, place.longitude) {
        (Some(lat), Some(lon)) if lat.is_finite() && lon.is_finite() && lat.abs() <= 90.0 && lon.abs() <= 180.0 => {
            (Some(lat), Some(lon))
        }
        _ => (None, None),
    };
    let raw_city_name = place.raw_city_name.as_deref().map(str::trim)
        .filter(|name| !name.is_empty() && name.chars().count() <= 80 && !name.chars().any(char::is_control))
        .map(str::to_owned);
    Some(TransferPlace { name: name.to_owned(), raw_city_name, time_zone_id: zone.to_owned(), country_code: country, latitude, longitude })
}

fn places_encode(value: &Value) -> Value {
    let Ok(input) = serde_json::from_value::<Vec<TransferPlace>>(value["places"].clone()) else {
        return json!({"error": "places"});
    };
    if input.is_empty() || input.len() > PLACES_LIMIT {
        return json!({"error": "count"});
    }
    let places: Vec<TransferPlace> = input.iter().filter_map(clean_place).collect();
    if places.len() != input.len() {
        return json!({"error": "places"});
    }
    let now = value["now"].as_f64().filter(|v| v.is_finite()).unwrap_or(0.0);
    let payload = TransferPayload { version: 1, generated_at: now, places };
    let bytes = serde_json::to_vec(&payload).unwrap_or_default();
    let fragment = format!("dp1.{}", URL_SAFE_NO_PAD.encode(bytes));
    // 与解码端的 65,536 字节上限同一把尺：编出来的链接超过它就在发方报错，别让 iPhone 那边才发现。
    if fragment.len() + "dayside://import#".len() > PLACES_TEXT_LIMIT {
        return json!({"error": "tooLong"});
    }
    json!({"fragment": fragment, "url": format!("dayside://import#{fragment}"), "count": payload.places.len(), "error": null})
}

fn places_decode(value: &Value) -> Value {
    let text = value["text"].as_str().unwrap_or("").trim();
    if text.len() > PLACES_TEXT_LIMIT {
        return json!({"error": "tooLong"});
    }
    let Some(at) = text.find("dp1.") else {
        return json!({"error": "notAPlaceList"});
    };
    let encoded: String = text[at + 4..]
        .chars()
        .take_while(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_'))
        .collect();
    let Ok(bytes) = URL_SAFE_NO_PAD.decode(encoded.as_bytes()) else {
        return json!({"error": "corrupt"});
    };
    let Ok(payload) = serde_json::from_slice::<TransferPayload>(&bytes) else {
        return json!({"error": "corrupt"});
    };
    if payload.version != 1 || payload.places.is_empty() || payload.places.len() > PLACES_LIMIT {
        return json!({"error": "unsupported"});
    }
    let places: Vec<TransferPlace> = payload.places.iter().filter_map(clean_place).collect();
    if places.is_empty() {
        return json!({"error": "corrupt"});
    }
    let generated_at = payload.generated_at.is_finite().then_some(payload.generated_at);
    json!({"places": places, "generatedAt": generated_at, "dropped": payload.places.len() - places.len(), "error": null})
}

pub fn dispatch(operation: &str, payload: Value) -> Result<Value, String> {
    match operation {
        "sharing.places_encode" => Ok(places_encode(&payload)),
        "sharing.places_decode" => Ok(places_decode(&payload)),
        "sharing.decode" => Ok(decode(&payload)),
        "sharing.validate" => {
            let (draft, errors) = validate(&payload);
            Ok(json!({"draft":draft,"errors":errors}))
        }
        "sharing.build" => build(&payload),
        _ => Err(format!("unknown sharing operation: {operation}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn place_lists_round_trip_through_the_dp1_fragment_and_reject_junk() {
        let places = json!([
            {"name":"成都","timeZoneID":"Asia/Shanghai","countryCode":"CN","latitude":30.66,"longitude":104.07},
            {"name":" Tokyo ","timeZoneID":"Asia/Tokyo"},
            {"name":"UTC","timeZoneID":"UTC","countryCode":"xx","latitude":999.0,"longitude":0.0}
        ]);
        let out = dispatch("sharing.places_encode", json!({"places": places, "now": 1.7e9})).unwrap();
        assert!(out["error"].is_null(), "{out}");
        let url = out["url"].as_str().unwrap();
        assert!(url.starts_with("dayside://import#dp1."));
        assert_eq!(out["count"], 3);
        let back = dispatch("sharing.places_decode", json!({"text": format!("  {url}\n")})).unwrap();
        assert!(back["error"].is_null(), "{back}");
        let list = back["places"].as_array().unwrap();
        assert_eq!(list.len(), 3);
        assert_eq!(list[1]["name"], "Tokyo", "两端空白去掉");
        assert!(list[2].get("countryCode").is_none(), "小写国家码不收");
        assert!(list[2].get("latitude").is_none(), "越界坐标整对丢掉");
        assert_eq!(list[0]["latitude"], 30.66);
        assert_eq!(back["generatedAt"], 1.7e9);
        assert!(list[0].get("rawCityName").is_none(), "旧清单没有原名字段也能照常读回");
        // 名片片段、空清单、超长名字、控制字符都拒。
        assert_eq!(dispatch("sharing.places_decode", json!({"text": "mt1.AAAA"})).unwrap()["error"], "notAPlaceList");
        assert_eq!(dispatch("sharing.places_decode", json!({"text": "dp1.!!!"})).unwrap()["error"], "corrupt");
        assert_eq!(dispatch("sharing.places_encode", json!({"places": []})).unwrap()["error"], "count");
        assert_eq!(dispatch("sharing.places_encode", json!({"places": [{"name":"a\u{0}b","timeZoneID":"Asia/Tokyo"}]})).unwrap()["error"], "places");
        assert_eq!(dispatch("sharing.places_encode", json!({"places": [{"name":"x","timeZoneID":"Asia/Tokyo; rm"}]})).unwrap()["error"], "places");
        let too_many: Vec<Value> = (0..201).map(|i| json!({"name": format!("p{i}"), "timeZoneID": "UTC"})).collect();
        assert_eq!(dispatch("sharing.places_encode", json!({"places": too_many})).unwrap()["error"], "count");
        // 200 个 80 字汉字名合法但编出来超过解码上限：发方就报 tooLong，而不是让收方才失败。
        let fat: Vec<Value> = (0..200).map(|i| json!({"name": format!("{}{i:03}", "名".repeat(77)), "timeZoneID": "UTC"})).collect();
        let out = dispatch("sharing.places_encode", json!({"places": fat})).unwrap();
        assert_eq!(out["error"], "tooLong", "{}", out["url"].as_str().map(str::len).unwrap_or(0));
    }

    #[test]
    fn place_lists_preserve_original_city_names_and_drop_invalid_optional_names() {
        let places = json!([
            {"name":"Renamed","rawCityName":"Katzrin","timeZoneID":"Asia/Jerusalem","countryCode":"IL","latitude":32.99,"longitude":35.69},
            {"name":"Legacy","timeZoneID":"Asia/Jerusalem"},
            {"name":"Kept","rawCityName":"bad\u{0}name","timeZoneID":"Asia/Jerusalem"}
        ]);
        let out = dispatch("sharing.places_encode", json!({"places":places,"now":1.7e9})).unwrap();
        assert!(out["error"].is_null(), "{out}");
        let back = dispatch("sharing.places_decode", json!({"text":out["url"]})).unwrap();
        assert_eq!(back["places"][0]["rawCityName"], "Katzrin");
        assert_eq!(back["places"][0]["name"], "Renamed");
        assert!(back["places"][1].get("rawCityName").is_none());
        assert!(back["places"][2].get("rawCityName").is_none());
        assert_eq!(back["places"][2]["name"], "Kept");
    }
    fn input() -> Value {
        json!({"draft":{"timeZoneID":"Asia/Tokyo","displayName":"","includesAvailability":false,
            "startMinute":540,"endMinute":1020,"workingWeekdays":[2,3,4,5,6]},
            "timeZoneValid":true,"nativeTimeZoneID":"Asia/Tokyo","nativeOffsetSeconds":32400,
            "now":1000.0,"validUntil":2000.0,"intervals":[],"hostFacts":null})
    }
    fn document(value: &Value) -> Value {
        build(value).unwrap()["document"].clone()
    }
    fn host() -> Value {
        json!({"scheme":"https","host":"share.example.com","port":null,
        "encodedPath":"/when.html","hasUserInfo":false,"hasQuery":false,"hasFragment":false})
    }

    #[test]
    fn empty_name_and_disabled_schedule_do_not_enter_payload() {
        let value = document(&input());
        let p = &value["payload"];
        assert!(p.get("displayName").is_none());
        assert!(p.get("schedule").is_none());
        assert_eq!(p["windows"], json!([]));
        assert!(value["shareURL"].is_null());
        let fields: Vec<_> = p.as_object().unwrap().keys().map(String::as_str).collect();
        assert_eq!(
            fields,
            [
                "generatedAt",
                "timeZoneID",
                "validUntil",
                "version",
                "windows"
            ]
        );
    }
    #[test]
    fn invalid_zone_name_hours_and_weekdays_are_rejected() {
        for (key, bad) in [
            ("timeZoneID", json!("")),
            ("displayName", json!("a\nb")),
            ("startMinute", json!(-1)),
            ("endMinute", json!(1441)),
            ("workingWeekdays", json!([])),
            ("workingWeekdays", json!([0, 8])),
        ] {
            let mut i = input();
            i["draft"]["includesAvailability"] = json!(true);
            i["draft"][key] = bad;
            assert!(document(&i).is_null(), "{key}");
        }
        let mut i = input();
        i["timeZoneValid"] = json!(false);
        assert!(document(&i).is_null());
    }
    #[test]
    fn fixed_offsets_use_native_facts_without_replacing_geographic_zones() {
        for (id, offset) in [
            ("GMT", 0),
            ("GMT+0545", 20700),
            ("GMT-0330", -12600),
            ("GMT+1800", 64800),
        ] {
            let mut i = input();
            i["draft"]["timeZoneID"] = json!(id);
            i["nativeTimeZoneID"] = json!(id);
            i["nativeOffsetSeconds"] = json!(offset);
            assert_eq!(document(&i)["payload"]["fixedOffsetSeconds"], offset);
            i["nativeOffsetSeconds"] = json!(offset + 1);
            assert!(document(&i).is_null());
        }
        assert!(document(&input())["payload"]
            .get("fixedOffsetSeconds")
            .is_none());
        for id in ["GMT+1860", "GMT+1801", "GMT+5", "GMT+abcd"] {
            let mut i = input();
            i["nativeTimeZoneID"] = json!(id);
            assert!(document(&i).is_null());
        }
    }
    #[test]
    fn unicode_name_is_preserved_but_cannot_inject_html_or_script() {
        let mut i = input();
        let name = "林 </title><script>alert('x')</script> & 🕰";
        i["draft"]["displayName"] = json!(name);
        let d = document(&i);
        let html = d["html"].as_str().unwrap();
        assert_eq!(d["payload"]["displayName"], name);
        assert!(!html.contains("<script>alert('x')</script>"));
        assert!(
            html.contains("&lt;/title&gt;&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt; &amp;")
        );
        assert!(!html.contains("__MEANTIME_PAYLOAD__"));
    }
    #[test]
    fn interval_snapshot_is_clipped_sorted_merged_and_strips_extra_fields() {
        let mut i = input();
        i["draft"]["includesAvailability"] = json!(true);
        i["intervals"] = json!([{"start":1400,"end":2500,"notes":"secret"},{"start":900,"end":1300},{"start":1200,"end":1400}]);
        let d = document(&i);
        assert_eq!(
            d["payload"]["windows"],
            json!([{"start":1000.0,"end":2000.0}])
        );
        assert!(!d.to_string().contains("secret"));
    }
    #[test]
    fn invalid_and_unbounded_snapshots_fail_without_partial_document() {
        let mut i = input();
        i["draft"]["includesAvailability"] = json!(true);
        i["intervals"] = json!([{"start":1200,"end":1100}]);
        assert!(document(&i).is_null());
        i["intervals"] = json!([]);
        i["validUntil"] = json!(1000 + 16 * 86400);
        assert!(document(&i).is_null());
    }
    #[test]
    fn all_day_and_overnight_schedules_keep_explicit_weekdays() {
        let mut i = input();
        i["draft"]["includesAvailability"] = json!(true);
        i["draft"]["startMinute"] = json!(1320);
        i["draft"]["endMinute"] = json!(360);
        i["draft"]["workingWeekdays"] = json!([6, 2, 2]);
        assert_eq!(
            document(&i)["payload"]["schedule"]["workingWeekdays"],
            json!([2, 6])
        );
        i["draft"]["endMinute"] = json!(1320);
        assert!(!document(&i).is_null());
    }
    #[test]
    fn fragment_round_trips_without_sending_personal_data_in_query_or_path() {
        let mut i = input();
        i["hostFacts"] = host();
        i["draft"]["displayName"] = json!("明");
        let d = document(&i);
        let url = d["shareURL"].as_str().unwrap();
        assert!(url.starts_with("https://share.example.com/when.html#mt1."));
        // 预约回执邮箱（可选）：合形的进名片并原样解回，不合形的整份草稿报 contact，空串不放进名片。
        let with_email = |email: &str| {
            let mut input = i.clone();
            input["draft"]["contactEmail"] = json!(email);
            dispatch("sharing.build", input).unwrap()
        };
        let good = with_email("  Ana.Lima+work@example.co.uk ");
        assert_eq!(good["document"]["payload"]["contactEmail"], "Ana.Lima+work@example.co.uk");
        let decoded = dispatch("sharing.decode", json!({"text": good["document"]["fragment"], "now": i["now"]})).unwrap();
        assert_eq!(decoded["card"]["contactEmail"], "Ana.Lima+work@example.co.uk");
        for bad in ["ana", "ana@", "@x.com", "a b@x.com", "ana@x", "ana@.x.com", "ana@x..com", "<ana@x.com>", "ana@x.com,b@y.com", "ана@x.com"] {
            let out = with_email(bad);
            assert!(out["document"].is_null() && out["errors"] == json!(["contact"]), "{bad}: {out}");
        }
        assert!(with_email("")["document"]["payload"].get("contactEmail").is_none());
        assert!(with_email("")["document"]["payload"].as_object().unwrap().get("contactEmail").is_none());
        let decoded = URL_SAFE_NO_PAD
            .decode(
                d["fragment"]
                    .as_str()
                    .unwrap()
                    .strip_prefix("mt1.")
                    .unwrap(),
            )
            .unwrap();
        assert_eq!(
            serde_json::from_slice::<Value>(&decoded).unwrap(),
            d["payload"]
        );
    }
    #[test]
    fn the_senders_tzdata_release_rides_along_and_junk_releases_are_dropped() {
        let mut i = input();
        i["tzdata"] = json!("2026c");
        let built = dispatch("sharing.build", i.clone()).unwrap();
        let fragment = built["document"]["fragment"].as_str().unwrap().to_owned();
        let decoded = dispatch("sharing.decode", json!({"text": fragment, "now": 1_789_041_600.0})).unwrap();
        assert_eq!(decoded["card"]["tzdata"], "2026c");
        for junk in [json!(" 2026c/../x "), json!(""), json!("2026cccccccccccc"), json!(7)] {
            i["tzdata"] = junk;
            let built = dispatch("sharing.build", i.clone()).unwrap();
            let fragment = built["document"]["fragment"].as_str().unwrap().to_owned();
            let decoded = dispatch("sharing.decode", json!({"text": fragment, "now": 1_789_041_600.0})).unwrap();
            assert!(decoded["card"].get("tzdata").is_none(), "{decoded}");
        }
        let plain = dispatch("sharing.build", input()).unwrap();
        assert!(plain["document"]["payload"].get("tzdata").is_none(), "cards without the field stay byte-compatible");
    }

    #[test]
    fn a_built_card_decodes_back_to_the_same_facts_and_junk_is_refused() {
        let built = build(&json!({
            "draft": {"timeZoneID": "Asia/Tokyo", "displayName": "  Mei ", "includesAvailability": true,
                      "startMinute": 600, "endMinute": 1080, "workingWeekdays": [2, 3, 4, 5, 6]},
            "timeZoneValid": true, "nativeTimeZoneID": "Asia/Tokyo", "nativeOffsetSeconds": 32400,
            "now": 1_789_000_000.0, "validUntil": 1_789_000_000.0 + 14.0 * 86_400.0,
            "intervals": [{"start": 1_789_000_000.0, "end": 1_789_010_000.0}], "hostFacts": null
        }))
        .unwrap();
        let fragment = built["document"]["fragment"].as_str().unwrap().to_owned();
        let pasted = format!("look https://example.test/when.html#{fragment} thanks");
        let decoded = decode(&json!({"text": pasted, "now": 1_789_000_100.0}));
        assert_eq!(decoded["error"], Value::Null);
        assert_eq!(decoded["expired"], false);
        let card = &decoded["card"];
        assert_eq!(card["timeZoneID"], "Asia/Tokyo");
        assert_eq!(card["displayName"], "Mei");
        assert_eq!(card["startMinute"], 600);
        assert_eq!(card["endMinute"], 1080);
        assert_eq!(card["workingWeekdays"], json!([2, 3, 4, 5, 6]));
        assert_eq!(card["windows"], 1);
        let expired = decode(&json!({"text": fragment, "now": 1_789_000_000.0 + 20.0 * 86_400.0}));
        assert_eq!(expired["expired"], true);
        assert_eq!(expired["card"]["timeZoneID"], "Asia/Tokyo");
        let enc = |raw: &str| format!("mt1.{}", URL_SAFE_NO_PAD.encode(raw.as_bytes()));
        let cases = [
            ("hello".to_owned(), "notACard"),
            ("mt1.".to_owned(), "notACard"),
            ("mt1.!!!".to_owned(), "notACard"),
            ("mt1.AAAA".to_owned(), "corrupt"),
            (enc(r#"{"version":2}"#), "corrupt"),
            (
                enc(
                    r#"{"version":1,"timeZoneID":"bad zone","generatedAt":1,"validUntil":2,"windows":[]}"#,
                ),
                "invalid",
            ),
            (
                enc(
                    r#"{"version":1,"timeZoneID":"UTC","schedule":{"startMinute":9999,"endMinute":0,"workingWeekdays":[1],"isWholeDay":false,"endDayOffset":0},"generatedAt":1,"validUntil":2,"windows":[]}"#,
                ),
                "invalid",
            ),
            (
                enc(
                    r#"{"version":1,"timeZoneID":"UTC","schedule":{"startMinute":1440,"endMinute":1080,"workingWeekdays":[1],"isWholeDay":false,"endDayOffset":0},"generatedAt":1,"validUntil":2,"windows":[]}"#,
                ),
                "invalid",
            ),
        ];
        for (text, error) in cases {
            assert_eq!(
                decode(&json!({"text": text, "now": 0.0}))["error"],
                error,
                "{text}"
            );
        }
        let whole_day = enc(
            r#"{"version":1,"timeZoneID":"UTC","displayName":"A ","schedule":{"startMinute":0,"endMinute":0,"workingWeekdays":[9,3,3],"isWholeDay":true,"endDayOffset":1},"generatedAt":1,"validUntil":2,"windows":[]}"#,
        );
        let card = decode(&json!({"text": whole_day, "now": 0.0}));
        assert_eq!(card["card"]["startMinute"], 0);
        assert_eq!(card["card"]["endMinute"], 1440);
        assert_eq!(card["card"]["workingWeekdays"], json!([3]));
        assert_eq!(card["card"]["displayName"], "A");
        // 标志位没打但起止相同：同样是全天，收成同一种写法。
        let same_minute = enc(
            r#"{"version":1,"timeZoneID":"UTC","schedule":{"startMinute":1080,"endMinute":1080,"workingWeekdays":[2],"isWholeDay":false,"endDayOffset":0},"generatedAt":1,"validUntil":2,"windows":[]}"#,
        );
        let card = decode(&json!({"text": same_minute, "now": 0.0}));
        assert_eq!(card["card"]["startMinute"], 0);
        assert_eq!(card["card"]["endMinute"], 1440);
    }

    /// 明信片上的地名与坐标：城市名（发方看到的）与不同时才给的拉丁写法、四舍五入到 0.1° 的坐标都进名片，
    /// 原样解回；坏的地名与越界的坐标当没有，不拒收整张名片；没有这几样的名片与从前逐字节相同（上面那条测试）。
    #[test]
    fn the_postcard_place_and_its_rounded_coordinate_ride_along() {
        let mut i = input();
        i["draft"]["placeName"] = json!(" 东京 ");
        i["draft"]["placeCity"] = json!("Tokyo");
        i["draft"]["latitude"] = json!(35.6895);
        i["draft"]["longitude"] = json!(139.69171);
        i["draft"]["displayName"] = json!("Mei");
        let d = document(&i);
        let p = &d["payload"];
        assert_eq!(p["place"], "东京");
        assert_eq!(p["city"], "Tokyo");
        assert_eq!(p["latitude"], 35.7);
        assert_eq!(p["longitude"], 139.7);
        assert!(d["html"].as_str().unwrap().contains("<title>Mei · 东京</title>"));
        let decoded = dispatch("sharing.decode", json!({"text": d["fragment"], "now": i["now"]})).unwrap();
        assert_eq!(decoded["card"]["place"], "东京");
        assert_eq!(decoded["card"]["city"], "Tokyo");
        assert_eq!(decoded["card"]["latitude"], 35.7);
        // 拉丁写法与地名相同就不重复；只有一个经纬度、越界、非数都不要。
        i["draft"]["placeCity"] = json!("东京");
        i["draft"]["longitude"] = json!(200.0);
        let p = document(&i)["payload"].clone();
        assert!(p.get("city").is_none() && p.get("latitude").is_none() && p.get("longitude").is_none(), "{p}");
        // 只有拉丁写法、没有地名：不写半个地名。
        i["draft"]["placeName"] = json!("\u{0}  ");
        i["draft"]["placeCity"] = json!("Tokyo");
        let p = document(&i)["payload"].clone();
        assert!(p.get("place").is_none() && p.get("city").is_none(), "{p}");
        // 别人的名片里写坏了：地名去控制符、截到 80 个字符，坐标越界就丢，名片照收。
        let enc = |raw: &str| format!("mt1.{}", URL_SAFE_NO_PAD.encode(raw.as_bytes()));
        let long = "长".repeat(100);
        let odd = enc(&format!(r#"{{"version":1,"timeZoneID":"Asia/Tokyo","place":"{long}\u0007","city":"  ","latitude":95,"longitude":10,"generatedAt":1,"validUntil":2,"windows":[]}}"#));
        let card = decode(&json!({"text": odd, "now": 0.0}));
        assert_eq!(card["error"], Value::Null, "{card}");
        assert_eq!(card["card"]["place"].as_str().unwrap().chars().count(), 80);
        assert!(card["card"].get("city").is_none() && card["card"].get("latitude").is_none());
    }

    #[test]
    fn malformed_optional_postcard_field_types_do_not_reject_the_card() {
        for key in ["place", "city", "latitude", "longitude"] {
            let wrong_scalar = if matches!(key, "place" | "city") { json!(17) } else { json!("35.7") };
            for bad in [Value::Null, json!(true), json!([]), json!({}), wrong_scalar] {
                let mut payload = document(&input())["payload"].clone();
                payload["place"] = json!("东京");
                payload["city"] = json!("Tokyo");
                payload["latitude"] = json!(35.6895);
                payload["longitude"] = json!(139.69171);
                payload[key] = bad.clone();
                let fragment = format!("mt1.{}", URL_SAFE_NO_PAD.encode(serde_json::to_vec(&payload).unwrap()));
                let decoded = decode(&json!({"text": fragment, "now": 1000.0}));
                assert!(decoded["error"].is_null(), "{key}={bad}: {decoded}");
                let card = &decoded["card"];
                assert_eq!(card["timeZoneID"], "Asia/Tokyo");
                assert_eq!(card["generatedAt"], 1000.0);
                assert_eq!(card["validUntil"], 2000.0);
                assert_eq!(card["windows"], 0);
                assert!(card.get(key).is_none(), "{key}={bad}: {card}");
                if key == "place" { assert!(card.get("city").is_none()); }
                if matches!(key, "latitude" | "longitude") {
                    assert!(card.get("latitude").is_none() && card.get("longitude").is_none());
                    assert_eq!(card["place"], "东京");
                    assert_eq!(card["city"], "Tokyo");
                } else {
                    assert_eq!(card["latitude"], 35.7);
                    assert_eq!(card["longitude"], 139.7);
                }
            }
        }
    }

    #[test]
    fn decoded_postcard_names_and_coordinates_use_the_sender_normalization() {
        let decode_fields = |fields: Value| {
            let mut payload = document(&input())["payload"].clone();
            payload.as_object_mut().unwrap().extend(fields.as_object().unwrap().clone());
            let fragment = format!("mt1.{}", URL_SAFE_NO_PAD.encode(serde_json::to_vec(&payload).unwrap()));
            decode(&json!({"text": fragment, "now": 1000.0}))["card"].clone()
        };
        for fields in [json!({"city":"Tokyo"}), json!({"place":"\u{7}  ","city":"Tokyo"})] {
            let card = decode_fields(fields);
            assert!(card.get("place").is_none() && card.get("city").is_none(), "{card}");
        }
        for (place, city) in [(" Tokyo\u{7} ".to_owned(), " Tokyo ".to_owned()), ("长".repeat(81), "长".repeat(80))] {
            let card = decode_fields(json!({"place":place,"city":city}));
            assert!(card.get("place").is_some() && card.get("city").is_none(), "{card}");
        }
        let card = decode_fields(json!({"place":" 东京 ","city":" Tokyo "}));
        assert_eq!(card["place"], "东京");
        assert_eq!(card["city"], "Tokyo");
        for (lat, lon, want_lat, want_lon) in [
            (35.6895, 139.69171, 35.7, 139.7), (0.05, -0.05, 0.1, -0.1),
            (-35.65, -139.75, -35.7, -139.8), (90.0, 180.0, 90.0, 180.0), (-90.0, -180.0, -90.0, -180.0),
        ] {
            let card = decode_fields(json!({"latitude":lat,"longitude":lon}));
            assert_eq!(card["latitude"], want_lat, "{card}");
            assert_eq!(card["longitude"], want_lon, "{card}");
        }
        for fields in [json!({"latitude":30}), json!({"longitude":10}), json!({"latitude":90.01,"longitude":10}), json!({"latitude":30,"longitude":180.01})] {
            let card = decode_fields(fields);
            assert!(card.get("latitude").is_none() && card.get("longitude").is_none(), "{card}");
        }
    }

    #[test]
    fn legacy_postcards_keep_the_exact_payload_bytes() {
        let d = document(&input());
        let bytes = URL_SAFE_NO_PAD.decode(d["fragment"].as_str().unwrap().strip_prefix("mt1.").unwrap()).unwrap();
        assert_eq!(bytes.as_slice(), br#"{"version":1,"timeZoneID":"Asia/Tokyo","generatedAt":1000.0,"validUntil":2000.0,"windows":[]}"#);
    }

    fn decode_literal_postcard(extra: &str) -> Value {
        let raw = format!(r#"{{"version":1,"timeZoneID":"Asia/Tokyo","generatedAt":1000,"validUntil":2000,"windows":[],{extra}}}"#);
        let fragment = format!("mt1.{}", URL_SAFE_NO_PAD.encode(raw.as_bytes()));
        decode(&json!({"text":fragment,"now":1000.0}))
    }

    #[test]
    fn literal_postcard_marker_objects_are_ignored_without_number_coercion() {
        for extra in [
            r#""place":{"$serde_json::private::Number":1e309}"#,
            r#""latitude":{"$serde_json::private::Number":"35.7"},"longitude":139.7"#,
        ] {
            let decoded = decode_literal_postcard(extra);
            assert!(decoded["error"].is_null(), "{extra}: {decoded}");
            let card = &decoded["card"];
            assert_eq!(card["timeZoneID"], "Asia/Tokyo");
            for key in ["place", "city", "latitude", "longitude"] {
                assert!(card.get(key).is_none(), "{extra}: {card}");
            }
        }
    }

    #[test]
    fn literal_postcard_optional_overflow_is_ignored_and_required_values_stay_strict() {
        let good = decode_literal_postcard(r#""latitude":35.65,"longitude":139.69171"#);
        assert!(good["error"].is_null(), "{good}");
        assert_eq!(good["card"]["latitude"], 35.7);
        assert_eq!(good["card"]["longitude"], 139.7);
        for extra in [r#""latitude":1e309,"longitude":139.7"#, r#""place":{"nested":1e309}"#] {
            let decoded = decode_literal_postcard(extra);
            assert!(decoded["error"].is_null(), "{extra}: {decoded}");
            for key in ["place", "city", "latitude", "longitude"] {
                assert!(decoded["card"].get(key).is_none(), "{extra}: {decoded}");
            }
        }
        for extra in [r#""place":{"nested":1e}"#, r#""latitude":1e"#] {
            let decoded = decode_literal_postcard(extra);
            assert_eq!(decoded["error"], "corrupt", "{extra}: {decoded}");
            assert!(decoded["card"].is_null());
        }
        for key in ["generatedAt", "validUntil"] {
            let raw = r#"{"version":1,"timeZoneID":"Asia/Tokyo","generatedAt":1000,"validUntil":2000,"windows":[]}"#
                .replace(&format!("\"{key}\":{}", if key == "generatedAt" { "1000" } else { "2000" }), &format!("\"{key}\":1e309"));
            let fragment = format!("mt1.{}", URL_SAFE_NO_PAD.encode(raw.as_bytes()));
            let decoded = decode(&json!({"text":fragment,"now":1000.0}));
            assert_eq!(decoded["error"], "corrupt", "{key}: {decoded}");
            assert!(decoded["card"].is_null());
        }
    }

    #[test]
    fn host_rejects_http_credentials_queries_fragments_traversal_and_odd_ports() {
        for (key, bad) in [
            ("scheme", json!("http")),
            ("hasUserInfo", json!(true)),
            ("hasQuery", json!(true)),
            ("hasFragment", json!(true)),
            ("encodedPath", json!("/../when.html")),
            ("encodedPath", json!("/%2e%2e/when.html")),
            ("encodedPath", json!("/%00")),
            ("port", json!(444)),
            ("host", json!("example.com@evil.com")),
        ] {
            let mut i = input();
            i["hostFacts"] = host();
            i["hostFacts"][key] = bad;
            assert!(document(&i).is_null(), "{key}");
        }
    }
    #[test]
    fn page_has_no_remote_assets_or_connection_permission() {
        let d = document(&input());
        let html = d["html"].as_str().unwrap();
        assert!(html.contains("connect-src 'none'"));
        assert!(html.contains("textContent"));
        for forbidden in [
            "fetch(",
            "XMLHttpRequest",
            "WebSocket",
            "<script src=",
            "<link rel=\"stylesheet\"",
            "innerHTML",
        ] {
            assert!(!html.contains(forbidden), "{forbidden}");
        }
    }

    /// 性质测试：随机草稿 → 名片 → 解码 → 再按解码结果做草稿 → 名片 → 解码，两次解码必须逐字段相同
    /// （收方把名片存成人物、再分享出去，不能每转一手就变形），且第一次解码就是草稿的规范形。
    /// 起止相同或 0–1440 一律收成 0–1440；名字去首尾空白、控制符不进名片；星期去重排序。
    #[test]
    fn random_drafts_round_trip_canonically() {
        struct Rng(u64);
        impl Rng {
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
        let zones = ["Asia/Tokyo", "Europe/London", "America/Los_Angeles", "UTC", "Australia/Lord_Howe", "Asia/Kathmandu"];
        let name_pieces = ["Mei", "Ana", " ", "  ", "\t", "\u{0}", "Île", "東京", "Zoë", "\u{200b}", "-", "O'Neil", "a\u{301}"];
        let iterations: u64 = std::env::var("MEANTIME_FUZZ_ITERATIONS").ok().and_then(|v| v.parse().ok()).unwrap_or(2_000);
        let seed_offset: u64 = std::env::var("MEANTIME_FUZZ_SEED").ok().and_then(|v| v.parse().ok()).unwrap_or(0);
        let mut rng = Rng(0x1234_5678_9ABC_DEF1_u64.wrapping_add(seed_offset));
        let mut built = 0;
        for i in 0..iterations {
            let zone = zones[rng.below(zones.len() as u64) as usize];
            let mut name = String::new();
            for _ in 0..rng.below(6) {
                name.push_str(name_pieces[rng.below(name_pieces.len() as u64) as usize]);
            }
            let includes = rng.below(4) != 0;
            let (start, end) = match rng.below(6) {
                0 => (0, 1440),
                1 => { let m = rng.below(1440) as i64; (m, m) }
                2 => (rng.below(1440) as i64, 1440),
                3 => { let a = rng.below(1440) as i64; (a, rng.below(a as u64 + 1) as i64) } // 跨午夜或相同
                _ => (rng.below(1440) as i64, rng.below(1441) as i64),
            };
            let mut weekdays: Vec<u8> = (0..rng.below(9)).map(|_| 1 + rng.below(7) as u8).collect();
            if weekdays.is_empty() { weekdays.push(1 + rng.below(7) as u8); }
            let now = 1_000.0 + rng.below(1_000_000) as f64;
            let valid_until = now + 3_600.0 + rng.below(14 * 86_400) as f64;
            let intervals: Vec<Value> = (0..rng.below(5)).map(|_| {
                let a = now - 5_000.0 + rng.below(20 * 86_400) as f64;
                json!({"start": a, "end": a + 60.0 + rng.below(20_000) as f64})
            }).collect();
            let draft = json!({"timeZoneID": zone, "displayName": name, "includesAvailability": includes,
                "startMinute": start, "endMinute": end, "workingWeekdays": weekdays});
            let input = json!({"draft": draft, "timeZoneValid": true, "nativeTimeZoneID": zone, "nativeOffsetSeconds": 0,
                "now": now, "validUntil": valid_until, "intervals": intervals, "hostFacts": null,
                "tzdata": if rng.below(2) == 0 { json!("2026c") } else { Value::Null }});
            let first = build(&input).unwrap();
            let Some(fragment) = first["document"]["fragment"].as_str() else {
                // 只有名字超长 / 含控制符会被拒；其余随机草稿都应做得出名片。
                let errors = first["errors"].clone();
                assert!(errors.as_array().map(|e| e.iter().all(|x| x == "name")).unwrap_or(false),
                    "#{i} 草稿 {draft} 被拒：{errors}");
                continue;
            };
            built += 1;
            let card = decode(&json!({"text": fragment, "now": now}))["card"].clone();
            assert!(!card.is_null(), "#{i} 自己做的名片解不开：{}", first["errors"]);
            assert_eq!(card["timeZoneID"], zone, "#{i}");
            let expected_name = name.trim();
            match card["displayName"].as_str() {
                Some(got) => assert_eq!(got, expected_name, "#{i} 名字"),
                None => assert!(expected_name.is_empty(), "#{i} 名字 {expected_name:?} 丢了"),
            }
            if includes {
                let whole = start == end || (start == 0 && end == 1440);
                let (want_start, want_end) = if whole { (0, 1440) } else { (start, end) };
                assert_eq!(card["startMinute"], want_start, "#{i} 起 {draft}");
                assert_eq!(card["endMinute"], want_end, "#{i} 止 {draft}");
                let mut want_days = weekdays.clone();
                want_days.sort();
                want_days.dedup();
                assert_eq!(card["workingWeekdays"], json!(want_days), "#{i} 星期");
            } else {
                assert!(card["startMinute"].is_null() && card["workingWeekdays"].is_null(), "#{i} 没勾可约时段却带了日程");
            }
            // 收方按名片再做一张：解码结果必须逐字段相同（Swift 侧 TimeCard 就是这么转成人物再分享的）。
            let again_draft = json!({"timeZoneID": card["timeZoneID"], "displayName": card["displayName"].as_str().unwrap_or(""),
                "includesAvailability": includes,
                "startMinute": card["startMinute"].as_i64().unwrap_or(540),
                "endMinute": card["endMinute"].as_i64().unwrap_or(1020),
                "workingWeekdays": card["workingWeekdays"].clone().as_array().cloned().unwrap_or_else(|| vec![json!(1)])});
            let mut again_input = input.clone();
            again_input["draft"] = again_draft;
            let second = build(&again_input).unwrap();
            let fragment2 = second["document"]["fragment"].as_str().unwrap_or_else(|| panic!("#{i} 再做名片失败：{}", second["errors"]));
            let card2 = decode(&json!({"text": fragment2, "now": now}))["card"].clone();
            for key in ["timeZoneID", "displayName", "startMinute", "endMinute", "workingWeekdays", "windows", "tzdata"] {
                assert_eq!(card[key], card2[key], "#{i} 往返后 {key} 变了：{card} → {card2}");
            }
        }
        assert!(built > iterations / 2, "样本大多被拒（{built} / {iterations}），生成器有问题");
    }
}
