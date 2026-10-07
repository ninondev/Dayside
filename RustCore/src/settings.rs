// SPDX-License-Identifier: GPL-3.0-only
use serde::Deserialize;
use serde_json::{json, Map, Value};

fn integer(value: &Value) -> Option<i64> {
    value.as_i64().or_else(|| {
        value
            .as_f64()
            .filter(|v| v.fract() == 0.0 && *v >= i64::MIN as f64 && *v < i64::MAX as f64)
            .map(|v| v as i64)
    })
}
fn enumeration(input: &Value, key: &str, choices: &[&str], fallback: &str) -> Value {
    json!(input[key]
        .as_str()
        .filter(|s| choices.contains(s))
        .unwrap_or(fallback))
}
fn boolean(input: &Value, key: &str, fallback: bool) -> Value {
    json!(input[key].as_bool().unwrap_or(fallback))
}
pub fn uuid_valid(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(i, c)| {
            if [8, 13, 18, 23].contains(&i) {
                c == b'-'
            } else {
                c.is_ascii_hexdigit()
            }
        })
}
/// 例会轮换的封闭选项：次数、周期（周）、单次最多在时段外（分钟）。校验与 `settings.constants` 共用同一份表，
/// 视图的菜单也从这里取，不再各存一份。
const ROTATION_COUNT_CHOICES: [i64; 4] = [4, 6, 8, 12];
const ROTATION_INTERVAL_CHOICES: [i64; 2] = [1, 2];
const ROTATION_STRETCH_CHOICES: [i64; 4] = [120, 240, 360, 480];
const ROTATION_SPLIT_CHOICES: [&str; 2] = ["rotate", "share"];
const ROTATION_CLOCK_WEIGHT_CHOICES: [&str; 3] = ["off", "gentle", "strong"];
/// 只认封闭选项里的整数（JSON 里的 12.0 也算 12），不在表里一律回默认，不做就近取整。
fn choice(input: &Value, key: &str, choices: &[i64], fallback: i64) -> Value {
    json!(integer(&input[key])
        .filter(|v| choices.contains(v))
        .unwrap_or(fallback))
}
pub fn availability(input: &Value) -> Value {
    json!({"startMinute": integer(&input["startMinute"]).unwrap_or(540).clamp(0,1439),
        "endMinute": integer(&input["endMinute"]).unwrap_or(1080).clamp(0,1440),
        "weekdaysOnly":input["weekdaysOnly"].as_bool().unwrap_or(true)})
}
/// 醒着时段：「能打给的时段」选了醒着的地点按它算；每天生效，所以 weekdaysOnly 恒为 false。
/// 起止各自校验、各自回默认 08:00 / 22:00（边界同 `availability`）；不是对象（旧偏好没有这段）就整段默认。
pub fn awake_window(input: &Value) -> Value {
    json!({"startMinute": integer(&input["startMinute"]).unwrap_or(480).clamp(0,1439),
        "endMinute": integer(&input["endMinute"]).unwrap_or(1320).clamp(0,1440),
        "weekdaysOnly": false})
}
/// 例会选项逐字段恢复默认，随排会设置持久化。
/// 星期留空时，由宿主取参考日起第一个工作日。
pub fn rotation(input: &Value) -> Value {
    json!({"weekday":integer(&input["weekday"]).filter(|v| (1..=7).contains(v)),
        "count":choice(input, "count", &ROTATION_COUNT_CHOICES, 6),
        "intervalWeeks":choice(input, "intervalWeeks", &ROTATION_INTERVAL_CHOICES, 1),
        "maxStretchMinutes":choice(input, "maxStretchMinutes", &ROTATION_STRETCH_CHOICES, 480),
        "split":enumeration(input, "split", &ROTATION_SPLIT_CHOICES, "rotate"),
        "clockWeight":enumeration(input, "clockWeight", &ROTATION_CLOCK_WEIGHT_CHOICES, "gentle")})
}
/// 理想时段：本机墙钟 [startMinute, endMinute)，null = 不设；封闭到 0–1440，起止相同当没有。
pub fn ideal_window(input: &Value) -> Value {
    match (integer(&input["startMinute"]), integer(&input["endMinute"])) {
        (Some(start), Some(end)) if (0..=1440).contains(&start) && (0..=1440).contains(&end) && start != end => {
            json!({"startMinute": start, "endMinute": end})
        }
        _ => Value::Null,
    }
}

/// 排会「常用组合」：名字 + 参与的地点 id + 人物 id + 该组合的理想时段。最多 20 组，名字 ≤ 60 字；
/// 一组坏了只丢那一组；不是数组就当空。
pub fn planner_groups(input: &Value) -> Value {
    let groups: Vec<Value> = input
        .as_array()
        .map(|list| {
            list.iter()
                .filter_map(|g| {
                    let id = g["id"].as_str().filter(|s| uuid_valid(s))?;
                    let name: String = g["name"].as_str()?.trim().chars().take(60).collect();
                    if name.is_empty() || name.chars().any(char::is_control) {
                        return None;
                    }
                    let ids = |key: &str| -> Vec<Value> {
                        g[key].as_array().map(|a| a.iter().filter(|v| v.as_str().is_some_and(uuid_valid)).cloned().collect()).unwrap_or_default()
                    };
                    Some(json!({"id": id, "name": name, "zoneIDs": ids("zoneIDs"), "personIDs": ids("personIDs"), "idealWindow": ideal_window(&g["idealWindow"])}))
                })
                .take(20)
                .collect()
        })
        .unwrap_or_default();
    Value::Array(groups)
}

pub fn planner(input: &Value) -> Value {
    let excluded = input["excludedZoneIDs"]
        .as_array()
        .filter(|a| a.iter().all(|v| v.as_str().is_some_and(uuid_valid)))
        .cloned()
        .unwrap_or_default();
    json!({"durationMinutes":integer(&input["durationMinutes"]).unwrap_or(60).clamp(5,480),
        "daysAhead":integer(&input["daysAhead"]).unwrap_or(7).clamp(1,31),
        "localAvailability":availability(&input["localAvailability"]),
        "includeLocal":input["includeLocal"].as_bool().unwrap_or(true),
        "excludedZoneIDs":excluded,"isExpanded":input["isExpanded"].as_bool().unwrap_or(false),
        "rotation":rotation(&input["rotation"]),
        "idealWindow":ideal_window(&input["idealWindow"]),
        "groups":planner_groups(&input["groups"])})
}
pub fn normalize(input: &Value) -> Value {
    let mut out = Map::new();
    for (key, choices, fallback) in [
        (
            "displayMode",
            &["name", "abbreviation", "offset"][..],
            "name",
        ),
        (
            "hourStyle",
            &["followSystem", "force12", "force24"][..],
            "followSystem",
        ),
        (
            "weight",
            &["regular", "medium", "semibold", "bold"][..],
            "regular",
        ),
        (
            "separator",
            &["space", "middleDot", "pipe", "enDash", "comma"][..],
            "space",
        ),
        (
            "fontDesign",
            &["system", "rounded", "serif", "monospaced"][..],
            "system",
        ),
        (
            "elementOrder",
            &["nameThenTime", "timeThenName"][..],
            "nameThenTime",
        ),
        ("rowTimeAlignment", &["trailing", "leading"][..], "trailing"),
        // 面板地点列表的排序：手动（拖拽的顺序）或「现在能打给谁」。
        ("panelSort", &["manual", "callable"][..], "manual"),
        // 面板的框（搜索栏、说明行、滑块、底栏）跟着这里的天色，还是跟着系统的浅色 / 深色。
        ("panelColors", &["sky", "system"][..], "sky"),
        // 文字大小三档：macOS 不支持 Dynamic Type，所以自己按倍数换字号。
        ("textSize", &["standard", "large", "larger"][..], "standard"),
        (
            "interfaceLanguage",
            &[
                "system", "en", "zhHans", "zhHant", "ja", "ko", "es", "fr", "de", "ru", "ptBR", "it", "nl",
                "pl", "tr", "vi", "id",
            ][..],
            "system",
        ),
        (
            "cityLanguage",
            &[
                "followInterface",
                "system",
                "none",
                "en",
                "zhHans",
                "zhHant",
                "ja",
                "ko",
                "es",
                "fr",
                "de",
                "ru",
                "ptBR",
                "it",
                "nl",
                "pl",
                "tr",
                "vi",
                "id",
            ][..],
            "followInterface",
        ),
    ] {
        out.insert(key.into(), enumeration(input, key, choices, fallback));
    }
    for (key, fallback) in [
        ("showSeconds", false),
        // 面板行「名称旁附 UTC 偏移」：默认关，默认外观逐像素不变。
        ("showOffsetBesideName", false),
        // 面板顶上的昼夜地图：默认开。
        ("panelShowsMap", true),
        // 面板行的日出日落时间（一轮）：昼夜条已经画出昼夜，两个时间默认收起。
        ("panelShowsSunTimes", false),
        ("useCustomColor", false),
        ("keepAliveInBackground", true),
        ("launchAtLogin", false),
        ("didAskLaunchAtLogin", false),
        ("didShowWelcome", false),
    ] {
        out.insert(key.into(), boolean(input, key, fallback));
    }
    out.insert(
        "menuBarMaxZones".into(),
        json!(integer(&input["menuBarMaxZones"]).unwrap_or(4).clamp(1, 6)),
    );
    // 地图手势「学一次」：拖完的地图拖动次数、亮过提示的面板打开次数；整数、默认 0、夹在 0…99。
    for key in ["mapDrags", "mapHintOpens"] {
        out.insert(key.into(), json!(integer(&input[key]).unwrap_or(0).clamp(0, 99)));
    }
    let color = &input["customColor"];
    out.insert(
        "customColor".into(),
        if ["red", "green", "blue", "opacity"]
            .iter()
            .all(|k| color[k].as_f64().is_some_and(f64::is_finite))
        {
            color.clone()
        } else {
            Value::Null
        },
    );
    out.insert("awakeWindow".into(), awake_window(&input["awakeWindow"]));
    out.insert("planner".into(), planner(&input["planner"]));
    // 旅行页的「固定时刻」：每天固定要做的事，只做换算；校验在 travel 模块。
    out.insert(
        "fixedTimes".into(),
        fixed_time_list(&input["fixedTimes"]),
    );
    // 全局快捷键：规则在 hotkey 模块，这里只把它按规则收进来。
    out.insert(
        "hotkey".into(),
        crate::hotkey::setting(&input["hotkey"]),
    );
    Value::Object(out)
}

pub fn dispatch(operation: &str, input: Value) -> Result<Value, String> {
    Ok(match operation {
        "settings.normalize" => normalize(&input),
        "settings.planner" => planner(&input),
        "settings.rotation" => rotation(&input),
        "settings.constants" => {
            json!({"durationChoices":[15,30,45,60,90,120],"daysChoices":[1,3,7,14,28],
            "rotationCountChoices":ROTATION_COUNT_CHOICES,
            "rotationIntervalChoices":ROTATION_INTERVAL_CHOICES,
            "rotationStretchChoices":ROTATION_STRETCH_CHOICES,
            "rotationSplitChoices":ROTATION_SPLIT_CHOICES,
            "rotationClockWeightChoices":ROTATION_CLOCK_WEIGHT_CHOICES,
            "maximumLabelWidth":180,"itemSeparator":"   ","minimumLegibleOpacity":0.25})
        }
        "settings.effects" => {
            let old = &input["old"];
            let new = &input["new"];
            json!({"changed":old!=new,"persist":!old.is_null(),
                "clock":!old.is_null() && old["showSeconds"]!=new["showSeconds"],
                "background":old.is_null() || old["keepAliveInBackground"]!=new["keepAliveInBackground"],
                "login":old.is_null() || old["launchAtLogin"]!=new["launchAtLogin"],
                "hotkey":old.is_null() || old["hotkey"]!=new["hotkey"]})
        }
        "settings.locale" => {
            let language = input["language"].as_str().unwrap_or("system");
            json!(match language {
                "zhHans" => Some("zh-Hans"),
                "zhHant" => Some("zh-Hant"),
                "ptBR" => Some("pt-BR"),
                "system" | "followInterface" | "none" => None,
                _ => Some(language),
            })
        }
        "settings.autonym" => json!(match input["language"].as_str().unwrap_or("") {
            "en" => "English",
            "zhHans" => "简体中文",
            "zhHant" => "繁體中文",
            "ja" => "日本語",
            "ko" => "한국어",
            "es" => "Español",
            "fr" => "Français",
            "de" => "Deutsch",
            "ru" => "Русский",
            "ptBR" => "Português (Brasil)",
            "it" => "Italiano",
            "nl" => "Nederlands",
            "pl" => "Polski",
            "tr" => "Türkçe",
            "vi" => "Tiếng Việt",
            "id" => "Bahasa Indonesia",
            _ => "",
        }),
        "settings.separator" => json!(match input.as_str().unwrap_or("") {
            "middleDot" => " · ",
            "pipe" => " | ",
            "enDash" => " – ",
            "comma" => ", ",
            _ => " ",
        }),
        _ => return Err(format!("Unknown settings operation: {operation}")),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    /// 地图手势「学一次」的两个计数：缺 → 0、越界夹到 0…99、不是整数 → 0、好值原样，两个键同规则。
    #[test]
    fn map_hint_counters_default_and_clamp() {
        let with = |key: &str, raw: Value| {
            let mut object = Map::new();
            object.insert(key.into(), raw);
            Value::Object(object)
        };
        for key in ["mapDrags", "mapHintOpens"] {
            for (raw, expected) in
                [(json!(150), json!(99)), (json!(-3), json!(0)), (json!("x"), json!(0)), (json!(7), json!(7))]
            {
                assert_eq!(normalize(&with(key, raw.clone()))[key], expected, "{key} {raw}");
            }
            assert_eq!(normalize(&Value::Null)[key], json!(0));
        }
    }
    /// 醒着时段：旧偏好没有这段 → 08:00–22:00；跨午夜照存；起止各自回默认、各自夹到边界；周末开关恒为 false。
    #[test]
    fn awake_window_defaults_and_bounds() {
        let window = |input: Value| normalize(&json!({"awakeWindow": input}))["awakeWindow"].clone();
        let default = json!({"startMinute":480,"endMinute":1320,"weekdaysOnly":false});
        assert_eq!(normalize(&json!({}))["awakeWindow"], default);
        assert_eq!(window(json!("bad")), default);
        assert_eq!(window(json!({"startMinute":1320,"endMinute":360,"weekdaysOnly":true})),
                   json!({"startMinute":1320,"endMinute":360,"weekdaysOnly":false}));
        assert_eq!(window(json!({"startMinute":-5,"endMinute":"x"})), json!({"startMinute":0,"endMinute":1320,"weekdaysOnly":false}));
        assert_eq!(window(json!({"startMinute":2000,"endMinute":2000})), json!({"startMinute":1439,"endMinute":1440,"weekdaysOnly":false}));
    }
    #[test]
    fn invalid_fields_do_not_reset_neighbors() {
        let result = normalize(
            &json!({"menuBarMaxZones":-50,"weight":"bold","hourStyle":"future","didAskLaunchAtLogin":true,
            "planner":{"durationMinutes":999,"daysAhead":-1,"excludedZoneIDs":["bad"]}}),
        );
        assert_eq!(result["menuBarMaxZones"], 1);
        assert_eq!(result["weight"], "bold");
        assert_eq!(result["hourStyle"], "followSystem");
        assert_eq!(result["didAskLaunchAtLogin"], true);
        assert_eq!(result["planner"]["durationMinutes"], 480);
        assert_eq!(result["planner"]["daysAhead"], 1);
        assert_eq!(result["planner"]["excludedZoneIDs"], json!([]));
        // 旧偏好没有 panelColors，面板的框默认跟着天色；只认两个值。
        assert_eq!(result["panelColors"], "sky");
        assert_eq!(normalize(&json!({"panelColors": "system"}))["panelColors"], "system");
        assert_eq!(normalize(&json!({"panelColors": "neon"}))["panelColors"], "sky");
        // 旧偏好恢复默认，星期留空。
        assert_eq!(
            result["planner"]["rotation"],
            json!({"weekday":null,"count":6,"intervalWeeks":1,"maxStretchMinutes":480,"split":"rotate","clockWeight":"gentle"})
        );
    }
    #[test]
    fn rotation_fields_fall_back_one_by_one() {
        // 坏一个只坏那一个：星期越界、次数不在表里、上限是字符串，周期 2 与邻居 daysAhead 原样保留。
        let result = planner(&json!({"daysAhead":14,
            "rotation":{"weekday":9,"count":5,"intervalWeeks":2,"maxStretchMinutes":"bad"}}));
        assert_eq!(result["daysAhead"], 14);
        assert_eq!(
            result["rotation"],
            json!({"weekday":null,"count":6,"intervalWeeks":2,"maxStretchMinutes":480,"split":"rotate","clockWeight":"gentle"})
        );
        // 合法值逐字保留；JSON 里的 12.0 按整数 12 认，星期 7（周六）在范围内。
        let kept =
            rotation(&json!({"weekday":7,"count":12.0,"intervalWeeks":2,"maxStretchMinutes":120}));
        assert_eq!(
            kept,
            json!({"weekday":7,"count":12,"intervalWeeks":2,"maxStretchMinutes":120,"split":"rotate","clockWeight":"gentle"})
        );
        // 不做就近取整：240 是选项、250 不是；星期 0、8、小数、字符串都回空。
        for (input, expected) in [
            (json!(250), json!(480)),
            (json!(240), json!(240)),
            (json!(true), json!(480)),
        ] {
            assert_eq!(
                rotation(&json!({"maxStretchMinutes":input}))["maxStretchMinutes"],
                expected
            );
        }
        for bad in [json!(0), json!(8), json!(2.5), json!("2"), json!(null)] {
            assert_eq!(rotation(&json!({"weekday":bad}))["weekday"], Value::Null);
        }
        // 理想时段与组合：合法的原样，越界 / 起止相同 / 缺一头当没有；组合坏一个丢一个、最多 20、名字裁到 60 字。
        let ideal = planner(&json!({"idealWindow":{"startMinute":600,"endMinute":720},"groups":[
            {"id":"0cbad259-a750-4086-a50f-83cfa0c1c52d","name":"  SF + London ","zoneIDs":["0cbad259-a750-4086-a50f-83cfa0c1c52d","bad"],"personIDs":[],"idealWindow":{"startMinute":480,"endMinute":600}},
            {"id":"bad","name":"x"},
            {"id":"0cbad259-a750-4086-a50f-83cfa0c1c52e","name":"","zoneIDs":[]},
            {"id":"0cbad259-a750-4086-a50f-83cfa0c1c52f","name":"a\u{0}b"},
            {"id":"0cbad259-a750-4086-a50f-83cfa0c1c530","name":"Team","idealWindow":{"startMinute":600,"endMinute":600}}
        ]}));
        assert_eq!(ideal["idealWindow"], json!({"startMinute":600,"endMinute":720}));
        let groups = ideal["groups"].as_array().unwrap();
        assert_eq!(groups.len(), 2);
        assert_eq!(groups[0]["name"], "SF + London");
        assert_eq!(groups[0]["zoneIDs"], json!(["0cbad259-a750-4086-a50f-83cfa0c1c52d"]));
        assert_eq!(groups[0]["idealWindow"], json!({"startMinute":480,"endMinute":600}));
        assert!(groups[1]["idealWindow"].is_null());
        for bad in [json!({"startMinute":600}), json!({"startMinute":-1,"endMinute":600}), json!({"startMinute":600,"endMinute":1441}), json!("x"), json!(null)] {
            assert!(planner(&json!({"idealWindow": bad}))["idealWindow"].is_null(), "{bad}");
        }
        assert!(planner(&json!({}))["groups"].as_array().unwrap().is_empty());
        assert!(planner(&json!({"groups":"bad"}))["groups"].as_array().unwrap().is_empty());
        let many: Vec<Value> = (0..25).map(|i| json!({"id": format!("0cbad259-a750-4086-a50f-83cfa0c1{:04x}", i), "name": "g"})).collect();
        assert_eq!(planner(&json!({"groups": many}))["groups"].as_array().unwrap().len(), 20);
        // rotation 整个不是对象：全默认，planner 的其他字段不受影响。
        let broken = planner(&json!({"durationMinutes":90,"rotation":"bad"}));
        assert_eq!(broken["durationMinutes"], 90);
        assert_eq!(broken["rotation"], rotation(&Value::Null));
        // 单独的 settings.rotation 操作与 planner 里嵌的是同一套规则；常量表与校验表一致。
        let payload = json!({"count":8,"intervalWeeks":3});
        assert_eq!(
            dispatch("settings.rotation", payload.clone()).unwrap(),
            planner(&json!({"rotation":payload}))["rotation"]
        );
        let constants = dispatch("settings.constants", Value::Null).unwrap();
        assert_eq!(
            constants["rotationCountChoices"],
            json!(ROTATION_COUNT_CHOICES)
        );
        assert_eq!(
            constants["rotationIntervalChoices"],
            json!(ROTATION_INTERVAL_CHOICES)
        );
        assert_eq!(
            constants["rotationStretchChoices"],
            json!(ROTATION_STRETCH_CHOICES)
        );
        assert_eq!(constants["rotationSplitChoices"], json!(ROTATION_SPLIT_CHOICES));
        assert_eq!(constants["rotationClockWeightChoices"], json!(ROTATION_CLOCK_WEIGHT_CHOICES));
    }
    #[test]
    fn rotation_split_and_clock_weight_defaults() {
        for missing in [json!({}), Value::Null, json!("bad")] {
            let result = rotation(&missing);
            assert_eq!(result["split"], "rotate");
            assert_eq!(result["clockWeight"], "gentle");
        }
        for split in ROTATION_SPLIT_CHOICES {
            for clock_weight in ROTATION_CLOCK_WEIGHT_CHOICES {
                let result = rotation(&json!({"split":split,"clockWeight":clock_weight}));
                assert_eq!(result["split"], split);
                assert_eq!(result["clockWeight"], clock_weight);
            }
        }
        for invalid in [json!("future"), json!(1), json!(true), Value::Null] {
            let bad_split = rotation(&json!({"split":invalid,"clockWeight":"strong","count":8}));
            assert_eq!(bad_split["split"], "rotate");
            assert_eq!(bad_split["clockWeight"], "strong");
            assert_eq!(bad_split["count"], 8);
            let bad_weight = rotation(&json!({"split":"share","clockWeight":invalid,"intervalWeeks":2}));
            assert_eq!(bad_weight["split"], "share");
            assert_eq!(bad_weight["clockWeight"], "gentle");
            assert_eq!(bad_weight["intervalWeeks"], 2);
        }
    }
    #[test]
    fn cold_start_applies_only_system_effects() {
        let effects = dispatch(
            "settings.effects",
            json!({"old":null,"new":normalize(&Value::Null)}),
        )
        .unwrap();
        assert_eq!(
            effects,
            json!({"changed":true,"persist":false,"clock":false,"background":true,"login":true,"hotkey":true})
        );
        // 只改快捷键时不要连带去动登录项与后台策略（那两项各有系统副作用）。
        let mut before = normalize(&Value::Null);
        let after = normalize(&json!({"hotkey":{"enabled":true,"keyCode":49,"modifiers":crate::hotkey::MOD_OPTION}}));
        assert_ne!(before["hotkey"], after["hotkey"]);
        let effects = dispatch("settings.effects", json!({"old":before,"new":after})).unwrap();
        assert_eq!(
            effects,
            json!({"changed":true,"persist":true,"clock":false,"background":false,"login":false,"hotkey":true})
        );
        // 快捷键没变就不重新注册。
        before["menuBarMaxZones"] = json!(2);
        let effects = dispatch("settings.effects", json!({"old":normalize(&Value::Null),"new":before})).unwrap();
        assert_eq!(effects["hotkey"], json!(false));
    }
}

// 固定时刻在这里校验，换算由 travel 处理。
pub const FIXED_TIME_CAP: usize = 8;
pub const FIXED_LABEL_CHARS: usize = 40;

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FixedTime {
    pub id: String,
    pub label: String,
    /// 在出发地（家）的墙钟分钟。
    pub minute: i64,
}

pub fn normalize_fixed(value: &Value) -> Option<FixedTime> {
    let trimmed = |key: &str| value[key].as_str().map(str::trim).filter(|s| !s.is_empty()).map(str::to_owned);
    let id = trimmed("id").filter(|s| uuid::Uuid::parse_str(s).is_ok())?;
    let label: String = trimmed("label")?.chars().take(FIXED_LABEL_CHARS).collect();
    let minute = value["minute"].as_i64().filter(|n| (0..1440).contains(n))?;
    Some(FixedTime { id, label, minute })
}

/// 设置里那份「每天固定要做的事」列表的校验出口（与 `fixed_times` 同一套规则）。
pub fn fixed_time_list(input: &Value) -> Value {
    let entries: Vec<Value> = input
        .as_array()
        .map(|list| {
            list.iter()
                .filter_map(normalize_fixed)
                .take(FIXED_TIME_CAP)
                .map(|entry| json!({"id":entry.id,"label":entry.label,"minute":entry.minute}))
                .collect()
        })
        .unwrap_or_default();
    Value::Array(entries)
}
