// SPDX-License-Identifier: GPL-3.0-only
//
//  PlaceCallabilityTests.swift
//  TahoeTimeTests
//
//  「现在能打给谁」的宿主那一半：用真实时区算「还剩多久下班 / 还要多久上班」。
//  判据全用另一套算法核（手算 UTC 差、ICU 的地区周末数据），不照抄被测函数。
//  排序规则本身在 Rust（`availability.callable_order` 的四条测试）。
//

import Foundation
import Testing
@testable import TahoeTime

@MainActor
struct PlaceCallabilityTests {
    private static func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)!
    }

    @Test func insideTheWindowItCountsDownToTheEndOfTheLocalWorkday() {
        // 2026-09-17 是周四。东京 10:00 JST = 01:00 UTC，到当地 18:00 还有 8 小时。
        let state = PlaceCallability.compute(timeZone: TimeZone(identifier: "Asia/Tokyo")!,
                                             now: Self.date("2026-09-17T01:00:00Z"), countryCode: "JP")
        #expect(state.isCallable)
        #expect(state.minutesLeft == 480)
        #expect(state.minutesUntil == nil)
        // 18:00 整已经不算在内（时段是左闭右开）。
        let closed = PlaceCallability.compute(timeZone: TimeZone(identifier: "Asia/Tokyo")!,
                                              now: Self.date("2026-09-17T09:00:00Z"), countryCode: "JP")
        #expect(!closed.isCallable)
        // 次日（周五）9:00 JST = 00:00 UTC，距 09:00 UTC 是 15 小时。
        #expect(closed.minutesUntil == 900)
    }

    @Test func theWaitingNumberCrossesWeekendsAndClockChanges() {
        // 伦敦 2026-10-23 是周五，19:00 BST = 18:00 UTC；下一段是周一 2026-10-26 09:00，
        // 而 10-25 凌晨退出夏令时 → 那时是 09:00 GMT = 09:00 UTC。真实间隔 = 63 小时 = 3780 分钟，
        // 光按墙钟数会少算一小时（62 小时），所以这一条同时钉住周末与换钟。
        let london = PlaceCallability.compute(timeZone: TimeZone(identifier: "Europe/London")!,
                                              now: Self.date("2026-10-23T18:00:00Z"), countryCode: "GB")
        #expect(!london.isCallable)
        #expect(london.minutesUntil == 3780)
        // 同一时刻的纽约是周五 14:00 EDT，还在时段内，剩 4 小时。
        let newYork = PlaceCallability.compute(timeZone: TimeZone(identifier: "America/New_York")!,
                                               now: Self.date("2026-10-23T18:00:00Z"), countryCode: "US")
        #expect(newYork.minutesLeft == 240)
    }

    @Test func theWeekendFollowsTheRegionNotSaturdayAndSunday() {
        // 以色列的周末是周五与周六：2026-09-18 周五 12:00 IDT = 09:00 UTC 不算工作时段，
        // 下一段是周日 09-20 09:00 IDT = 06:00 UTC，间隔 45 小时 = 2700 分钟。
        let jerusalem = PlaceCallability.compute(timeZone: TimeZone(identifier: "Asia/Jerusalem")!,
                                                 now: Self.date("2026-09-18T09:00:00Z"), countryCode: "IL")
        #expect(!jerusalem.isCallable)
        #expect(jerusalem.minutesUntil == 2700)
        // 不知道国家时按中性默认（周六日休），同一个周五就还在时段内。
        let neutral = PlaceCallability.compute(timeZone: TimeZone(identifier: "Asia/Jerusalem")!,
                                               now: Self.date("2026-09-18T09:00:00Z"), countryCode: nil)
        #expect(neutral.minutesLeft == 360)
    }

    @Test func thePanelPutsTheReachablePlacesFirstAndNamesTheNextOne() {
        let (defaults, cleanup) = TestDefaults.make(prefix: "callable")
        defer { cleanup() }
        // 先写好三个地点再构造模型（加载时不回写，和生产同一条路）。
        Store.saveZones([
            TimeZoneEntry(timezoneID: "America/Los_Angeles", cityName: "Los Angeles", countryCode: "US"),
            TimeZoneEntry(timezoneID: "Asia/Tokyo", cityName: "Tokyo", countryCode: "JP"),
            TimeZoneEntry(timezoneID: "Europe/London", cityName: "London", countryCode: "GB"),
        ], to: defaults)
        let model = AppModel(defaults: defaults, migrate: false, applySystemIntegration: false)
        // 2026-09-17 周四 09:00 UTC：伦敦 10:00（剩 8 小时）、东京 18:00（刚下班，明早 9:00 还有 15 小时）、
        // 洛杉矶 02:00（还有 7 小时）。手动排序时顺序不动；换成「现在能打给谁」后伦敦在前。
        model.now = Self.date("2026-09-17T09:00:00Z")
        #expect(model.panelOrder.zones.map(\.cityName) == ["Los Angeles", "Tokyo", "London"])
        model.settings.panelSort = .callable
        let order = model.panelOrder
        #expect(order.zones.map(\.cityName) == ["London", "Los Angeles", "Tokyo"])
        #expect(order.callableCount == 1)
        let nextIsTokyo = TimeZone.current == TimeZone(identifier: "America/Los_Angeles")
        #expect(order.nextZone?.cityName == (nextIsTokyo ? "Tokyo" : "Los Angeles"))
        #expect(order.nextInMinutes == (nextIsTokyo ? 900 : 420))
        // 排序只是显示顺序，存的还是用户自己的顺序（拖拽与删除都按 id 走）。
        #expect(model.zones.map(\.cityName) == ["Los Angeles", "Tokyo", "London"])
        #expect(Store.loadSettings(from: defaults).panelSort == .callable)
    }

    @Test func nextCallSkipsEveryPlaceInTheMacTimeZoneButKeepsTheirSortPositions() {
        let home = TimeZone(identifier: "America/Los_Angeles")!
        let localOne = TimeZoneEntry(timezoneID: home.identifier, cityName: "Los Angeles")
        let localTwo = TimeZoneEntry(timezoneID: home.identifier, cityName: "San Francisco")
        let remote = TimeZoneEntry(timezoneID: "Asia/Tokyo", cityName: "Tokyo")
        let zones = [localOne, localTwo, remote]
        let states = [(id: localOne.id, state: PlaceCallability(minutesLeft: nil, minutesUntil: 60)),
                      (id: localTwo.id, state: PlaceCallability(minutesLeft: nil, minutesUntil: 20)),
                      (id: remote.id, state: PlaceCallability(minutesLeft: nil, minutesUntil: 120))]
        let sort = CallableOrder.compute(states)
        #expect(sort.order == [localTwo.id, localOne.id, remote.id])
        let hint = CallableOrder.compute(states, zones: zones, excluding: home)
        #expect(hint.nextID == remote.id)
        #expect(hint.nextInMinutes == 120)
    }

    @Test func nextCallIsHiddenWhenOnlyMacTimeZonePlacesAreWaiting() {
        let home = TimeZone(identifier: "America/Los_Angeles")!
        let local = TimeZoneEntry(timezoneID: home.identifier, cityName: "San Francisco")
        let remote = TimeZoneEntry(timezoneID: "Asia/Tokyo", cityName: "Tokyo")
        let states = [(id: local.id, state: PlaceCallability(minutesLeft: nil, minutesUntil: 60)),
                      (id: remote.id, state: PlaceCallability(minutesLeft: 300, minutesUntil: nil))]
        let hint = CallableOrder.compute(states, zones: [local, remote], excluding: home)
        #expect(hint.nextID == nil)
        #expect(hint.nextInMinutes == nil)
        let localOnly = CallableOrder.compute([states[0]], zones: [local], excluding: home)
        #expect(localOnly.nextID == nil && localOnly.nextInMinutes == nil)
    }

    @Test func panelOrderHidesTheHintForTwoCitiesInThisMacTimeZone() {
        let (defaults, cleanup) = TestDefaults.make(prefix: "callable-home")
        defer { cleanup() }
        Store.saveZones([
            TimeZoneEntry(timezoneID: TimeZone.current.identifier, cityName: "One", callBasis: .awake),
            TimeZoneEntry(timezoneID: TimeZone.current.identifier, cityName: "Two", callBasis: .awake)
        ], to: defaults)
        let model = AppModel(defaults: defaults, migrate: false, applySystemIntegration: false)
        model.now = Calendar.current.date(bySettingHour: 23, minute: 0, second: 0,
                                         of: Self.date("2026-09-17T09:00:00Z"))!
        model.settings.panelSort = .callable
        #expect(model.panelOrder.zones.count == 2)
        #expect(model.panelOrder.callableCount == 0)
        #expect(model.panelOrder.nextZone == nil)
        #expect(model.panelOrder.nextInMinutes == nil)
    }
}
