// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct SettingsChange: Decodable {
    let changed: Bool
    let persist: Bool
    let clock: Bool
    let background: Bool
    let login: Bool
    let hotkey: Bool
    init(old: AppSettings?, new: AppSettings) {
        struct Input: Encodable { let old: AppSettings?; let new: AppSettings }
        self = RustCore.invoke("settings.effects", Input(old: old, new: new))
    }
}

@MainActor
protocol SettingsEffect {
    func apply(change: SettingsChange, new: AppSettings, on model: AppModel)
}
struct PersistSettingsEffect: SettingsEffect {
    let defaults: UserDefaults
    func apply(change: SettingsChange, new: AppSettings, on model: AppModel) {
        if change.persist { Store.saveSettings(new, to: defaults) }
    }
}
struct ClockCadenceEffect: SettingsEffect {
    func apply(change: SettingsChange, new: AppSettings, on model: AppModel) {
        if change.clock { model.restartClock() }
    }
}
struct SystemIntegrationEffect: SettingsEffect {
    func apply(change: SettingsChange, new: AppSettings, on model: AppModel) {
        if change.background { model.applyBackgroundKeepAlivePreference() }
        if change.login { model.applyLaunchAtLoginPreference() }
        if change.hotkey { GlobalHotkeyCenter.shared.apply(new.hotkey) }
    }
}
