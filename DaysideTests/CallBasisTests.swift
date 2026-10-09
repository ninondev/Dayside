// SPDX-License-Identifier: GPL-3.0-only
//
//  CallBasisTests.swift
//  Dayside
//
//  「能打给谁」的两个基准：旧存档解码回 .work；醒着窗口按每天算（周日深夜仍在窗内、
//  一关窗就数到次日 08:00）；旧偏好没有醒着窗口时回默认 08:00–22:00。
//

import Foundation
import Testing
@testable import Dayside

@MainActor
struct CallBasisTests {

    // MARK: 旧数据升级

    /// 未带 callBasis 的旧存档解码回 .work，保持原来的上班基准。
    @Test func oldEntryWithoutCallBasisDecodesToWork() throws {
        let json = """
        {"id": "6EC7A1B0-8E1A-4E5C-9C0B-000000000001", "timezoneID": "Asia/Tokyo",
         "cityName": "Tokyo", "usesExemplarName": true}
        """
        let entry = try JSONDecoder().decode(TimeZoneEntry.self, from: Data(json.utf8))
        #expect(entry.callBasis == .work)
    }

    // MARK: 醒着窗口的判定

    /// 2026-01-04 是周日：醒着窗口不看周末，21:59 仍在窗内（差一分钟关窗）。
    @Test func awakeWindowCallableLateOnSunday() throws {
        let sunday2159 = try #require(Self.utc.date(from: DateComponents(year: 2026, month: 1, day: 4, hour: 21, minute: 59)))
        #expect(Self.utc.isDateInWeekend(sunday2159))
        let state = PlaceCallability.compute(timeZone: Self.utc.timeZone, now: sunday2159, countryCode: nil,
                                             window: Availability(startMinute: 480, endMinute: 1320, weekdaysOnly: false))
        #expect(state.isCallable)
        #expect(state.minutesLeft == 1)
    }

    /// 22:00 关窗即不能打，且数到的是次日（周一）08:00——整 10 小时。
    @Test func awakeWindowClosesAt2200UntilNextMorning() throws {
        let sunday2200 = try #require(Self.utc.date(from: DateComponents(year: 2026, month: 1, day: 4, hour: 22)))
        let state = PlaceCallability.compute(timeZone: Self.utc.timeZone, now: sunday2200, countryCode: nil,
                                             window: Availability(startMinute: 480, endMinute: 1320, weekdaysOnly: false))
        #expect(!state.isCallable)
        #expect(state.minutesUntil == 600)
    }

    // MARK: 设置默认

    /// 旧偏好没有 awakeWindow：解码回默认 08:00–22:00、每天。
    @Test func settingsWithoutAwakeWindowDecodeToDefault() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(settings.awakeWindow.startMinute == 480)
        #expect(settings.awakeWindow.endMinute == 1320)
        #expect(settings.awakeWindow.weekdaysOnly == false)
    }

    // MARK: 面板顺序与落盘

    /// 2026-09-17 周四 09:00 UTC，东京 18:00：按上班刚下班；右键换成醒着就在窗内（离 22:00 还有 4 小时，排最前）。
    /// 同一分钟里改基准、改醒着窗口都立刻重排（缓存键带着它们）；两样都落盘，重开还在；换回上班存档里不留键。
    @Test func switchingTokyoToAwakeReordersThePanelAndPersists() throws {
        let (defaults, cleanup) = TestDefaults.make(prefix: "callbasis")
        defer { cleanup() }
        Store.saveZones([
            TimeZoneEntry(timezoneID: "America/Los_Angeles", cityName: "Los Angeles", countryCode: "US"),
            TimeZoneEntry(timezoneID: "Asia/Tokyo", cityName: "Tokyo", countryCode: "JP"),
            TimeZoneEntry(timezoneID: "Europe/London", cityName: "London", countryCode: "GB"),
        ], to: defaults)
        let model = AppModel(defaults: defaults, migrate: false)
        model.now = try #require(ISO8601DateFormatter().date(from: "2026-09-17T09:00:00Z"))
        model.settings.panelSort = .callable
        #expect(model.panelOrder.zones.map(\.cityName) == ["London", "Los Angeles", "Tokyo"])
        let tokyo = try #require(model.zones.first { $0.cityName == "Tokyo" })
        model.setCallBasis(id: tokyo.id, to: .awake)
        let order = model.panelOrder
        #expect(order.zones.map(\.cityName) == ["Tokyo", "London", "Los Angeles"])
        #expect(order.callableCount == 2)
        // 「下一个能打」不算这台 Mac 所在时区的地点：本机在洛杉矶时不提示。
        let macIsInLosAngeles = TimeZone.current.identifier == "America/Los_Angeles"
        #expect(order.nextZone?.cityName == (macIsInLosAngeles ? nil : "Los Angeles"))
        // 醒着窗口收到 18:00 为止：东京 18:00 正好关窗，要等明早 8:00（14 小时），排到洛杉矶（7 小时）后面。
        model.settings.awakeWindow = Availability(startMinute: 480, endMinute: 1080, weekdaysOnly: false)
        #expect(model.panelOrder.zones.map(\.cityName) == ["London", "Los Angeles", "Tokyo"])
        let reopened = AppModel(defaults: defaults, migrate: false)
        #expect(reopened.zones.first { $0.cityName == "Tokyo" }?.callBasis == .awake)
        #expect(reopened.settings.awakeWindow.endMinute == 1080)
        reopened.setCallBasis(id: tokyo.id, to: .work)
        #expect(Store.loadZones(from: defaults).zones.map(\.callBasis) == [.work, .work, .work])
    }

    /// 固定 UTC 的历法：没有夏令时，分钟数才是整的。
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
}
