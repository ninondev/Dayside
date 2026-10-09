// SPDX-License-Identifier: GPL-3.0-only
//
//  WelcomeLocalPlaceTests.swift
//  DaysideTests
//
//  欢迎页「本机的地点」那一格的取舍（WelcomeLocalPlace）：没加是「添加 …」按钮，
//  加过后是静态的「已添加 …」行。只测这段纯逻辑，版式由截图与无障碍转储查。
//

import Foundation
import Testing
@testable import Dayside

struct WelcomeLocalPlaceTests {
    private func entry(_ timezoneID: String) -> TimeZoneEntry {
        TimeZoneEntry(timezoneID: timezoneID, cityName: timezoneID)
    }

    @Test func emptyListShowsAddButton() {
        #expect(!WelcomeLocalPlace.showsAddedRow(zones: [], currentTimeZoneID: "America/Los_Angeles"))
    }

    @Test func localPlaceInListShowsAddedRow() {
        #expect(WelcomeLocalPlace.showsAddedRow(zones: [entry("America/Los_Angeles")],
                                                currentTimeZoneID: "America/Los_Angeles"))
    }

    @Test func otherPlacesDoNotCount() {
        #expect(!WelcomeLocalPlace.showsAddedRow(zones: [entry("Asia/Tokyo"), entry("Europe/Berlin")],
                                                 currentTimeZoneID: "America/Los_Angeles"))
    }

    @Test func judgedByTimeZoneNotDisplayName() {
        // 自定义名只改显示；时区没变就仍是同一个地点，仍算已添加。
        var zone = entry("America/Los_Angeles")
        zone.customName = "家"
        #expect(WelcomeLocalPlace.showsAddedRow(zones: [zone], currentTimeZoneID: "America/Los_Angeles"))
    }

    @Test func localPlaceAmongMany() {
        let zones = [entry("Asia/Tokyo"), entry("America/Los_Angeles"), entry("Europe/Berlin")]
        #expect(WelcomeLocalPlace.showsAddedRow(zones: zones, currentTimeZoneID: "America/Los_Angeles"))
        #expect(!WelcomeLocalPlace.showsAddedRow(zones: zones, currentTimeZoneID: "Australia/Sydney"))
    }
}

@MainActor
struct WelcomeStartTests {
    @Test func loginCheckboxStartsCheckedWithoutRegistering() {
        let (defaults, cleanup) = TestDefaults.make(prefix: "com.dayside.welcome-tests")
        defer { cleanup() }
        let model = AppModel(defaults: defaults, migrate: false, applySystemIntegration: false)

        #expect(WelcomeOptions().openAtLogin)
        #expect(!model.settings.launchAtLogin)
        #expect(!model.settings.didShowWelcome)
        #expect(defaults.data(forKey: "dayside.settings.v1") == nil)
    }

    @Test(arguments: [false, true])
    func checkedStartRequestsLoginRegistrationRegardlessOfOldPromptFlag(didAsk: Bool) {
        let (defaults, cleanup) = TestDefaults.make(prefix: "com.dayside.welcome-tests")
        defer { cleanup() }
        var initial = AppSettings()
        initial.didAskLaunchAtLogin = didAsk
        Store.saveSettings(initial, to: defaults)
        let model = AppModel(defaults: defaults, migrate: false, applySystemIntegration: false)
        let before = model.settings

        model.finishWelcome(openAtLogin: true)

        #expect(model.settings.launchAtLogin)
        #expect(model.settings.didShowWelcome)
        #expect(SettingsChange(old: before, new: model.settings).login)
        #expect(Store.loadSettings(from: defaults).launchAtLogin)
        #expect(Store.loadSettings(from: defaults).didShowWelcome)
        // 再按一次不重复请求注册。
        let completed = model.settings
        model.finishWelcome(openAtLogin: true)
        #expect(!SettingsChange(old: completed, new: model.settings).login)
    }

    @Test func uncheckedStartDoesNotRequestLoginRegistration() {
        let (defaults, cleanup) = TestDefaults.make(prefix: "com.dayside.welcome-tests")
        defer { cleanup() }
        let model = AppModel(defaults: defaults, migrate: false, applySystemIntegration: false)
        let before = model.settings

        model.finishWelcome(openAtLogin: false)

        #expect(!model.settings.launchAtLogin)
        #expect(model.settings.didShowWelcome)
        #expect(!SettingsChange(old: before, new: model.settings).login)
        #expect(!Store.loadSettings(from: defaults).launchAtLogin)
        #expect(Store.loadSettings(from: defaults).didShowWelcome)
    }
}
