// SPDX-License-Identifier: GPL-3.0-only
//
//  PlannerPersistenceTests.swift
//  TahoeTimeTests
//

import Foundation
import Testing
@testable import TahoeTime

@MainActor
struct PlannerPersistenceTests {
    @Test func oversizedJSONNumbersOnlyResetTheirOwnFields() throws {
        let raw = Data("""
        {"menuBarMaxZones":1e309,"showSeconds":true,"weight":"bold","future":1e9999,
         "customColor":{"red":1e309,"green":0,"blue":0,"opacity":1}}
        """.utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: raw)
        #expect(decoded.menuBarMaxZones == 4)
        #expect(decoded.showSeconds)
        #expect(decoded.weight == .bold)
        #expect(decoded.customColor == nil)
        try withDefaults { defaults in
            defaults.set(raw, forKey: "tahoetime.settings.v1")
            #expect(Store.loadSettings(from: defaults) == decoded)
            #expect(defaults.data(forKey: "tahoetime.settings.v1.corrupt-backup") == nil)
        }
        let zone = try JSONDecoder().decode(TimeZoneEntry.self, from: Data("""
        {"timezoneID":"UTC","cityName":"kept","coordinate":{"latitude":1e309,"longitude":0}}
        """.utf8))
        #expect(zone.coordinate == nil)
        #expect(zone.cityName == "kept")
    }

    /// 常用组合与理想时段：随设置落盘再读回原样；坏的一组只丢那一组、越界的理想时段当没有；
    /// 老偏好没有这两个键就是空。
    @Test func plannerGroupsAndIdealWindowRoundTripAndTolerateBadData() throws {
        let zone = UUID(), person = UUID()
        var settings = AppSettings()
        settings.planner.idealWindow = IdealWindow(startMinute: 540, endMinute: 720)
        settings.planner.groups = [PlannerGroup(id: UUID(), name: "SF + London", zoneIDs: [zone], personIDs: [person],
                                                idealWindow: IdealWindow(startMinute: 480, endMinute: 660))]
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded.planner == settings.planner)
        #expect(decoded.planner.groups.first?.zoneIDs == [zone] && decoded.planner.groups.first?.personIDs == [person])
        let dirty = Data("""
        {"planner":{"idealWindow":{"startMinute":600,"endMinute":600},"groups":[
          {"id":"\(UUID().uuidString)","name":" Team ","zoneIDs":["\(zone.uuidString)","nope"],"idealWindow":{"startMinute":-5,"endMinute":700}},
          {"id":"bad","name":"x"}]}}
        """.utf8)
        let tolerant = try JSONDecoder().decode(AppSettings.self, from: dirty)
        #expect(tolerant.planner.idealWindow == nil, "起止相同当没有")
        #expect(tolerant.planner.groups.count == 1)
        #expect(tolerant.planner.groups.first?.name == "Team")
        #expect(tolerant.planner.groups.first?.zoneIDs == [zone])
        #expect(tolerant.planner.groups.first?.idealWindow == nil, "越界的理想时段当没有")
        let old = try JSONDecoder().decode(AppSettings.self, from: Data("{\"planner\":{\"durationMinutes\":30}}".utf8))
        #expect(old.planner.groups.isEmpty && old.planner.idealWindow == nil && old.planner.durationMinutes == 30)
        // 理想时段进排会请求：洛杉矶 1:00–12:00 与伦敦 9–18（= 洛杉矶 1:00–10:00）重叠 1:00–10:00，候选窗口不变，最佳起点挪进时段
        let la = OverlapPlanner.Participant(id: UUID(), name: "LA", timeZoneID: "America/Los_Angeles",
                                            availability: Availability(startMinute: 60, endMinute: 720), countryCode: "US")
        let london = OverlapPlanner.Participant(id: UUID(), name: "London", timeZoneID: "Europe/London", availability: .standard, countryCode: "GB")
        // 2026-09-14 周一 00:00 PDT（07:00 UTC）
        let monday = Date(timeIntervalSince1970: 1_789_369_200)
        var request = OverlapPlanner.Request(participants: [la, london], from: monday, days: 1, durationMinutes: 60, localTimeZoneID: "America/Los_Angeles")
        let plain = try #require(OverlapPlanner.plan(request).windows.first)
        request.idealWindow = IdealWindow(startMinute: 8 * 60, endMinute: 9 * 60)
        let ideal = try #require(OverlapPlanner.plan(request).windows.first)
        #expect(plain.start == ideal.start && plain.end == ideal.end, "窗口本身不变")
        let calendar = Calendar.gregorianUTC(TimeZone(identifier: "America/Los_Angeles")!)
        #expect(calendar.component(.hour, from: plain.best) != 8, "不设理想时段时最佳起点不在 8 点")
        #expect(calendar.component(.hour, from: ideal.best) == 8, "最佳起点挪进 8:00–9:00")
    }

    @Test func renameTrimsZeroWidthSpaceWithoutRemovingInnerCharacters() throws {
        try withDefaults { defaults in
            let zone = TimeZoneEntry(timezoneID: "UTC", cityName: "UTC")
            Store.saveZones([zone], to: defaults)
            let model = AppModel(defaults: defaults, migrate: false)
            model.rename(id: zone.id, to: "\u{200B}To\u{200B}kyo\u{200B}")
            #expect(model.zones.first?.customName == "To\u{200B}kyo")
        }
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let (defaults, cleanup) = TestDefaults.make(prefix: "com.dayside.planner-tests")
        defer { cleanup() }
        try body(defaults)
    }

    @Test func legacyZonesKeepTheirNamesAndUseStandardAvailability() throws {
        try withDefaults { defaults in
            defaults.set(Data("""
            [{"timezoneID":"Asia/Tokyo","cityName":"Tokyo","customName":"Colleague"}]
            """.utf8), forKey: "tahoetime.zones.v1")
            let loaded = Store.loadZones(from: defaults)
            let zone = try #require(loaded.zones.first)
            #expect(!loaded.recovered)
            #expect(zone.customName == "Colleague")
            #expect(zone.countryCode == nil)
            #expect(zone.availability == nil)
            #expect(zone.effectiveAvailability == .standard)
        }
    }

    @Test func legacySettingsAddPlannerDefaultsWithoutResettingOtherPreferences() throws {
        try withDefaults { defaults in
            defaults.set(Data("""
            {"showSeconds":true,"weight":"bold","menuBarMaxZones":6}
            """.utf8), forKey: "tahoetime.settings.v1")
            let loaded = Store.loadSettings(from: defaults)
            #expect(loaded.planner == PlannerPreferences())
            #expect(loaded.showSeconds)
            #expect(loaded.weight == .bold)
            #expect(loaded.menuBarMaxZones == 6)
        }
    }

    /// 没有 rotation 的旧 planner 存档应让四个轮换控件使用默认值。
    /// planner 里其他已存的字段原样保留。
    @Test func legacyPlannerWithoutRotationReadsRotationDefaults() throws {
        try withDefaults { defaults in
            defaults.set(Data("""
            {"showSeconds":true,"planner":{"durationMinutes":90,"daysAhead":14,"includeLocal":false,"isExpanded":true}}
            """.utf8), forKey: "tahoetime.settings.v1")
            let loaded = Store.loadSettings(from: defaults)
            let rotation = loaded.planner.rotation
            #expect(rotation == RotationPreferences())
            #expect(rotation.weekday == nil)
            #expect(rotation.count == 6)
            #expect(rotation.intervalWeeks == 1)
            #expect(rotation.maxStretchMinutes == 480)
            #expect(loaded.planner.durationMinutes == 90)
            #expect(loaded.planner.daysAhead == 14)
            #expect(!loaded.planner.includeLocal)
            #expect(loaded.planner.isExpanded)
            #expect(loaded.showSeconds)
        }
        // 选项表来自 Rust 常量,与校验用的是同一份。
        #expect(RotationPreferences.countChoices == [4, 6, 8, 12])
        #expect(RotationPreferences.stretchChoices == [120, 240, 360, 480])
    }

    /// rotation 里坏一个字段只坏那一个:星期越界回空、次数不在表里回 6、上限是字符串回 480,
    /// 周期 2 与 planner 的邻居字段都保留;rotation 整个不是对象时四项全默认、邻居仍在。
    @Test func malformedRotationFieldsFallBackIndependently() throws {
        try withDefaults { defaults in
            defaults.set(Data("""
            {"planner":{"daysAhead":14,"rotation":{"weekday":9,"count":5,"intervalWeeks":2,"maxStretchMinutes":"bad"}}}
            """.utf8), forKey: "tahoetime.settings.v1")
            let planner = Store.loadSettings(from: defaults).planner
            #expect(planner.daysAhead == 14)
            #expect(planner.rotation.weekday == nil)
            #expect(planner.rotation.count == 6)
            #expect(planner.rotation.intervalWeeks == 2)
            #expect(planner.rotation.maxStretchMinutes == 480)
            #expect(defaults.data(forKey: "tahoetime.settings.v1.corrupt-backup") == nil)
        }
        try withDefaults { defaults in
            defaults.set(Data("""
            {"planner":{"durationMinutes":90,"rotation":"bad"}}
            """.utf8), forKey: "tahoetime.settings.v1")
            let planner = Store.loadSettings(from: defaults).planner
            #expect(planner.durationMinutes == 90)
            #expect(planner.rotation == RotationPreferences())
        }
        // 直接解码也走同一套规则（视图之外没有第二条路径）。
        let decoded = try JSONDecoder().decode(RotationPreferences.self, from: Data("""
        {"weekday":7,"count":12.0,"intervalWeeks":3,"maxStretchMinutes":250}
        """.utf8))
        #expect(decoded.weekday == 7)
        #expect(decoded.count == 12)
        #expect(decoded.intervalWeeks == 1)
        #expect(decoded.maxStretchMinutes == 480)
    }

    @Test func plannerPreferencesAndZoneAvailabilityRoundTripThroughStore() throws {
        try withDefaults { defaults in
            let zone = TimeZoneEntry(timezoneID: "Asia/Tokyo", cityName: "Tokyo", countryCode: "JP",
                                     availability: .init(startMinute: 1320, endMinute: 360, weekdaysOnly: false))
            var settings = AppSettings()
            settings.planner.durationMinutes = 90
            settings.planner.daysAhead = 14
            settings.planner.includeLocal = false
            settings.planner.excludedZoneIDs = [zone.id]
            settings.planner.isExpanded = true
            settings.planner.localAvailability = .init(startMinute: 540, endMinute: 540, weekdaysOnly: false)
            settings.planner.rotation.weekday = 4
            settings.planner.rotation.count = 12
            settings.planner.rotation.intervalWeeks = 2
            settings.planner.rotation.maxStretchMinutes = 240
            Store.saveZones([zone], to: defaults)
            Store.saveSettings(settings, to: defaults)
            #expect(Store.loadZones(from: defaults).zones == [zone])
            #expect(Store.loadSettings(from: defaults) == settings)
            // 星期没选过(nil)也要原样往返,不能被存成某个具体星期。
            settings.planner.rotation.weekday = nil
            Store.saveSettings(settings, to: defaults)
            #expect(Store.loadSettings(from: defaults).planner.rotation.weekday == nil)
            #expect(Store.loadSettings(from: defaults) == settings)
        }
    }

    /// 视图的绑定写的是 `model.settings.planner.rotation.*`:每次改动立刻落盘,改成同一个值不再写。
    @Test func rotationEditsThroughTheModelPersistImmediately() throws {
        try withDefaults { defaults in
            let model = AppModel(defaults: defaults, migrate: false)
            #expect(model.settings.planner.rotation == RotationPreferences())
            model.settings.planner.rotation.count = 8
            #expect(Store.loadSettings(from: defaults).planner.rotation.count == 8)
            model.settings.planner.rotation.weekday = 3
            model.settings.planner.rotation.maxStretchMinutes = 120
            let stored = Store.loadSettings(from: defaults).planner.rotation
            #expect(stored.weekday == 3)
            #expect(stored.count == 8)
            #expect(stored.intervalWeeks == 1)
            #expect(stored.maxStretchMinutes == 120)
            #expect(model.core.settings.planner.rotation == stored)
            // 同一个值再写一次不该改变落盘内容(Picker 复确认同一项就是这种情况)。
            let bytes = defaults.data(forKey: "tahoetime.settings.v1")
            model.settings.planner.rotation.count = 8
            #expect(defaults.data(forKey: "tahoetime.settings.v1") == bytes)
        }
    }

    @Test func malformedAvailabilityFieldsDoNotDiscardTheZone() throws {
        try withDefaults { defaults in
            defaults.set(Data("""
            [{"timezoneID":"Asia/Tokyo","cityName":"Tokyo","countryCode":"JP",
              "availability":{"startMinute":"bad","endMinute":360,"weekdaysOnly":false}}]
            """.utf8), forKey: "tahoetime.zones.v1")
            let loaded = Store.loadZones(from: defaults)
            let zone = try #require(loaded.zones.first)
            #expect(!loaded.recovered)
            #expect(zone.countryCode == "JP")
            #expect(zone.effectiveAvailability == Availability(startMinute: 540, endMinute: 360, weekdaysOnly: false))
        }
    }

    @Test func malformedPlannerFieldsFallBackIndependently() throws {
        try withDefaults { defaults in
            defaults.set(Data("""
            {"showSeconds":true,"planner":{"durationMinutes":"bad","daysAhead":14,
              "includeLocal":false,"isExpanded":true,"localAvailability":"bad"}}
            """.utf8), forKey: "tahoetime.settings.v1")
            let settings = Store.loadSettings(from: defaults)
            #expect(settings.showSeconds)
            #expect(settings.planner.durationMinutes == 60)
            #expect(settings.planner.daysAhead == 14)
            #expect(!settings.planner.includeLocal)
            #expect(settings.planner.isExpanded)
            #expect(settings.planner.localAvailability == .standard)
        }
    }

    @Test func invalidAvailabilityBoundsAreClampedDuringDecode() throws {
        let availability = try JSONDecoder().decode(Availability.self, from: Data("""
        {"startMinute":-1,"endMinute":10000,"weekdaysOnly":false}
        """.utf8))
        #expect(availability.startMinute == 0)
        #expect(availability.endMinute == 1440)
        #expect(availability.isWholeDay)
    }

    @Test func modelEditsPersistAvailabilityAndParticipationImmediately() throws {
        try withDefaults { defaults in
            let zone = TimeZoneEntry(timezoneID: "Asia/Tokyo", cityName: "Tokyo", countryCode: "JP")
            Store.saveZones([zone], to: defaults)
            let model = AppModel(defaults: defaults, migrate: false)
            let night = Availability(startMinute: 1320, endMinute: 360, weekdaysOnly: false)
            model.setAvailability(id: zone.id, night)
            #expect(Store.loadZones(from: defaults).zones.first?.availability == night)
            model.setParticipates(id: zone.id, false)
            #expect(Store.loadSettings(from: defaults).planner.excludedZoneIDs == [zone.id])
            model.setParticipates(id: zone.id, false)
            #expect(Store.loadSettings(from: defaults).planner.excludedZoneIDs == [zone.id])
            model.setParticipates(id: zone.id, true)
            #expect(Store.loadSettings(from: defaults).planner.excludedZoneIDs.isEmpty)
            model.setAvailability(id: zone.id, nil)
            #expect(Store.loadZones(from: defaults).zones.first?.availability == nil)
        }
    }
}
