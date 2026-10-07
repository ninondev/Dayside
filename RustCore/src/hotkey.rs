// SPDX-License-Identifier: GPL-3.0-only
//! 全局快捷键的规则。
//!
//! 这里只管规则与写法：哪些键能当快捷键、哪个组合合法、怎么写成 `⌥⌘T`。注册与按键事件是
//! Apple 框架的活，在 Swift（Carbon 的 `RegisterEventHotKey`）。键码是 macOS 的虚拟键码
//! （`kVK_*`），与键盘布局无关——所以同一份表在各国键盘上都成立。

use serde_json::{json, Value};

pub const MOD_COMMAND: u32 = 1;
pub const MOD_OPTION: u32 = 2;
pub const MOD_CONTROL: u32 = 4;
pub const MOD_SHIFT: u32 = 8;
const MOD_ALL: u32 = MOD_COMMAND | MOD_OPTION | MOD_CONTROL | MOD_SHIFT;

/// 默认组合：⌥⌘T（T = time）。默认是关着的，所以它不会去抢任何人的快捷键。
pub const DEFAULT_KEY: u32 = 17;
pub const DEFAULT_MODIFIERS: u32 = MOD_OPTION | MOD_COMMAND;

/// 虚拟键码 → 菜单里的写法。封闭表：不在表里的键一律不认，设置页就不会出现「键 123」这种
/// 看不懂的东西。特殊键用 Apple 自己在菜单里用的符号（↩ ⇥ ⎋ ⌫ ⌦ ← → ↑ ↓ ⇞ ⇟ ↖ ↘），
/// 所以这一列不需要翻译。
const KEYS: &[(u32, &str)] = &[
    (0, "A"),
    (1, "S"),
    (2, "D"),
    (3, "F"),
    (4, "H"),
    (5, "G"),
    (6, "Z"),
    (7, "X"),
    (8, "C"),
    (9, "V"),
    (11, "B"),
    (12, "Q"),
    (13, "W"),
    (14, "E"),
    (15, "R"),
    (16, "Y"),
    (17, "T"),
    (18, "1"),
    (19, "2"),
    (20, "3"),
    (21, "4"),
    (22, "6"),
    (23, "5"),
    (24, "="),
    (25, "9"),
    (26, "7"),
    (27, "-"),
    (28, "8"),
    (29, "0"),
    (30, "]"),
    (31, "O"),
    (32, "U"),
    (33, "["),
    (34, "I"),
    (35, "P"),
    (36, "↩"),
    (37, "L"),
    (38, "J"),
    (39, "'"),
    (40, "K"),
    (41, ";"),
    (42, "\\"),
    (43, ","),
    (44, "/"),
    (45, "N"),
    (46, "M"),
    (47, "."),
    (48, "⇥"),
    (49, "␣"),
    (50, "`"),
    (51, "⌫"),
    (53, "⎋"),
    (96, "F5"),
    (97, "F6"),
    (98, "F7"),
    (99, "F3"),
    (100, "F8"),
    (101, "F9"),
    (103, "F11"),
    (109, "F10"),
    (111, "F12"),
    (115, "↖"),
    (116, "⇞"),
    (117, "⌦"),
    (118, "F4"),
    (119, "↘"),
    (120, "F2"),
    (121, "⇟"),
    (122, "F1"),
    (123, "←"),
    (124, "→"),
    (125, "↓"),
    (126, "↑"),
];

pub fn key_label(key_code: u32) -> Option<&'static str> {
    KEYS.iter().find(|(code, _)| *code == key_code).map(|(_, label)| *label)
}

/// 修饰键的写法与次序按 Apple 菜单：⌃ ⌥ ⇧ ⌘。
pub fn modifier_label(modifiers: u32) -> String {
    let mut out = String::new();
    for (bit, symbol) in [
        (MOD_CONTROL, "⌃"),
        (MOD_OPTION, "⌥"),
        (MOD_SHIFT, "⇧"),
        (MOD_COMMAND, "⌘"),
    ] {
        if modifiers & bit != 0 {
            out.push_str(symbol);
        }
    }
    out
}

/// 校验一个组合能不能当全局快捷键。
///
/// 三条拒绝：①键不在封闭表里（`unknownKey`）；②一个修饰键都没有，或只按了 ⇧
/// （`needsModifier`）——那会把这个键在全系统里吃掉；③只有 ⌘（含 ⇧⌘，`commandOnly`）——
/// ⌘ 加单键是各 App 自己的快捷键（⌘T 新建标签页…），全局抢走会砸掉每个 App 的这一项。
/// 剩下的（含 ⌥ 或 ⌃ 的任意组合）放行，包括 ⌥␣ 这种常见的呼出键。
pub fn normalize(key_code: u32, modifiers: u32) -> Result<(u32, u32), &'static str> {
    let modifiers = modifiers & MOD_ALL;
    if key_label(key_code).is_none() {
        return Err("unknownKey");
    }
    if modifiers & (MOD_COMMAND | MOD_OPTION | MOD_CONTROL) == 0 {
        return Err("needsModifier");
    }
    if modifiers & (MOD_OPTION | MOD_CONTROL) == 0 {
        return Err("commandOnly");
    }
    Ok((key_code, modifiers))
}

/// 一个组合的完整写法，例如 `⌥⌘T`。
pub fn label(key_code: u32, modifiers: u32) -> String {
    format!(
        "{}{}",
        modifier_label(modifiers),
        key_label(key_code).unwrap_or("")
    )
}

/// 设置里的 `hotkey` 字段。坏值不牵连邻居：键或组合不合法就整项回默认并关掉。
pub fn setting(input: &Value) -> Value {
    let enabled = input["enabled"].as_bool().unwrap_or(false);
    let key = input["keyCode"].as_u64().unwrap_or(DEFAULT_KEY as u64) as u32;
    let modifiers = input["modifiers"].as_u64().unwrap_or(DEFAULT_MODIFIERS as u64) as u32;
    match normalize(key, modifiers) {
        Ok((key, modifiers)) => json!({"enabled": enabled, "keyCode": key, "modifiers": modifiers}),
        Err(_) => {
            json!({"enabled": false, "keyCode": DEFAULT_KEY, "modifiers": DEFAULT_MODIFIERS})
        }
    }
}

pub fn dispatch(operation: &str, input: Value) -> Result<Value, String> {
    Ok(match operation {
        // 录制器按下一个组合就问这里：能不能用、怎么写。
        "hotkey.normalize" => {
            let key = input["keyCode"].as_u64().unwrap_or(u32::MAX as u64) as u32;
            let modifiers = input["modifiers"].as_u64().unwrap_or(0) as u32;
            match normalize(key, modifiers) {
                Ok((key, modifiers)) => json!({"ok":true,"keyCode":key,"modifiers":modifiers,
                    "label":label(key, modifiers),"error":Value::Null}),
                Err(error) => json!({"ok":false,"keyCode":Value::Null,"modifiers":Value::Null,
                    "label":Value::Null,"error":error}),
            }
        }
        "hotkey.label" => json!(label(
            input["keyCode"].as_u64().unwrap_or(u32::MAX as u64) as u32,
            input["modifiers"].as_u64().unwrap_or(0) as u32
        )),
        _ => return Err(format!("Unknown hotkey operation: {operation}")),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn labels_follow_the_apple_modifier_order() {
        // ⌃ ⌥ ⇧ ⌘ 的次序是 Apple 菜单的次序，不是按下的次序。
        assert_eq!(label(17, MOD_COMMAND | MOD_OPTION), "⌥⌘T");
        assert_eq!(
            label(17, MOD_SHIFT | MOD_COMMAND | MOD_CONTROL | MOD_OPTION),
            "⌃⌥⇧⌘T"
        );
        assert_eq!(label(49, MOD_OPTION), "⌥␣");
        assert_eq!(label(126, MOD_CONTROL | MOD_OPTION), "⌃⌥↑");
        assert_eq!(label(122, MOD_CONTROL), "⌃F1");
    }

    #[test]
    fn only_combinations_with_option_or_control_are_accepted() {
        assert_eq!(normalize(17, MOD_COMMAND | MOD_OPTION), Ok((17, MOD_OPTION | MOD_COMMAND)));
        assert_eq!(normalize(49, MOD_OPTION), Ok((49, MOD_OPTION)));
        assert_eq!(normalize(17, MOD_CONTROL | MOD_SHIFT), Ok((17, MOD_CONTROL | MOD_SHIFT)));
        // 裸键与 ⇧ 单独：会把这个键在全系统里吃掉。
        assert_eq!(normalize(17, 0), Err("needsModifier"));
        assert_eq!(normalize(17, MOD_SHIFT), Err("needsModifier"));
        // ⌘T / ⇧⌘T 是各 App 自己的快捷键。
        assert_eq!(normalize(17, MOD_COMMAND), Err("commandOnly"));
        assert_eq!(normalize(17, MOD_COMMAND | MOD_SHIFT), Err("commandOnly"));
        // 表外的键（Caps Lock 52、功能键 F13 105…）不认。
        assert_eq!(normalize(52, MOD_OPTION | MOD_COMMAND), Err("unknownKey"));
        assert_eq!(normalize(105, MOD_OPTION), Err("unknownKey"));
        // 位掩码里的杂位被丢掉，不影响判定。
        assert_eq!(normalize(17, MOD_OPTION | MOD_COMMAND | 0xF0), Ok((17, MOD_OPTION | MOD_COMMAND)));
    }

    #[test]
    fn the_setting_falls_back_to_a_disabled_default() {
        let good = setting(&json!({"enabled":true,"keyCode":49,"modifiers":MOD_OPTION}));
        assert_eq!(good, json!({"enabled":true,"keyCode":49,"modifiers":MOD_OPTION}));
        // 坏组合（⌘ 单独）→ 整项回默认并关掉，不留一个注册不了的状态。
        let bad = setting(&json!({"enabled":true,"keyCode":17,"modifiers":MOD_COMMAND}));
        assert_eq!(
            bad,
            json!({"enabled":false,"keyCode":DEFAULT_KEY,"modifiers":DEFAULT_MODIFIERS})
        );
        // 空输入 = 默认关。
        assert_eq!(
            setting(&json!({})),
            json!({"enabled":false,"keyCode":DEFAULT_KEY,"modifiers":DEFAULT_MODIFIERS})
        );
        assert_eq!(label(DEFAULT_KEY, DEFAULT_MODIFIERS), "⌥⌘T");
    }

    #[test]
    fn the_key_table_has_no_duplicates() {
        for (index, (code, label)) in KEYS.iter().enumerate() {
            assert!(
                !KEYS[..index].iter().any(|(other, _)| other == code),
                "键码 {code} 在表里出现了两次"
            );
            assert!(!label.is_empty());
        }
    }
}
