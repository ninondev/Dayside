// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import TahoeTime

@Suite("Astronomy native calendar adapter") @MainActor
struct AstronomyTests {
    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }
    private func zone(_ identifier: String, latitude: Double, longitude: Double) -> TimeZoneEntry {
        TimeZoneEntry(timezoneID: identifier, cityName: identifier,
                      coordinate: Coordinate(latitude: latitude, longitude: longitude))
    }

    @Test func defaultCreatesNoWorkAndMissingCoordinatesStayExplicit() {
        let store = AstronomyStore()
        #expect(store.activeResourceCount == 0)
        #expect(store.computationCount == 0)
        #expect(store.result == nil)
        store.compute(zone: TimeZoneEntry(timezoneID: "Etc/UTC", cityName: "UTC"), on: date("2026-09-11T12:00:00Z"))
        #expect(store.error == "missingCoordinates")
        #expect(store.result == nil)
        #expect(store.computationCount == 0)
    }

    @Test(arguments: [("2026-03-08T12:00:00Z", 23.0), ("2026-11-01T12:00:00Z", 25.0)])
    func nativeDayBoundariesFollowDST(iso: String, hours: Double) throws {
        let store = AstronomyStore()
        store.compute(zone: zone("America/Los_Angeles", latitude: 34.0522, longitude: -118.2437), on: date(iso))
        let result = try #require(store.result)
        #expect(result.available)
        #expect(try #require(result.dayEnd) - #require(result.dayStart) == hours * 3600)
        let moon = try #require(result.moon)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        #expect(calendar.component(.hour, from: Date(timeIntervalSince1970: moon.instant)) == 12)
        #expect(store.activeResourceCount == 0)
    }

    @Test func fractionalOffsetAndDateLineKeepEventsOnSelectedDay() throws {
        let store = AstronomyStore()
        for entry in [zone("Asia/Kathmandu", latitude: 27.7172, longitude: 85.324),
                      zone("Pacific/Apia", latitude: -13.8333, longitude: -171.75)] {
            store.compute(zone: entry, on: date("2026-09-09T12:00:00Z"))
            let result = try #require(store.result)
            let solar = try #require(result.solar)
            let start = try #require(result.dayStart)
            let end = try #require(result.dayEnd)
            #expect(try #require(solar.sunrise) >= start)
            #expect(try #require(solar.sunset) < end)
            #expect(solar.samples.first?.instant == start)
            #expect(solar.samples.last?.instant == end)
        }
        #expect(store.computationCount == 2)
        store.deactivate()
        #expect(store.result == nil)
        #expect(store.activeResourceCount == 0)
    }

    /// 昼长变化：伦敦九月每天短 3–4 分钟（日出晚、日落早），下一次至日是 12 月 21 日「最短的一天」；悉尼同一天在变长，
    /// 下一次至日同样是 12 月 21 日却是「最长的一天」；至日当天「还有 0 天」并按与昨天比定长短；换钟那天的日出按墙钟跳一小时。
    @Test func daylightTrendCountsDownToTheSolsticeAndShiftsFollowTheWallClock() throws {
        let store = AstronomyStore()
        store.compute(zone: zone("Europe/London", latitude: 51.5074, longitude: -0.1278), on: date("2026-09-15T12:00:00Z"))
        let london = try #require(store.trend)
        #expect((-260 ... -180).contains(london.daylightChangeSeconds))
        #expect(london.sunriseShiftMinutes == 2 || london.sunriseShiftMinutes == 1)
        #expect(london.sunsetShiftMinutes == -2 || london.sunsetShiftMinutes == -3)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        #expect(calendar.dateComponents([.month, .day], from: london.solsticeDay) == DateComponents(month: 12, day: 21))
        #expect(london.solsticeDaysAway == 97)
        #expect(!london.solsticeIsLongest)
        #expect((7 * 3600 ... 8 * 3600).contains(london.solsticeDaylightSeconds))

        store.compute(zone: zone("Australia/Sydney", latitude: -33.8688, longitude: 151.2093), on: date("2026-09-15T02:00:00Z"))
        let sydney = try #require(store.trend)
        #expect((60 ... 150).contains(sydney.daylightChangeSeconds))
        #expect(sydney.solsticeIsLongest)
        // 12 月至日 20:50 UTC 在悉尼已是 22 日 07:50 AEDT：民用日按当地算，比伦敦多一天
        #expect(sydney.solsticeDaysAway == 98)
        #expect((14 * 3600 ... 15 * 3600).contains(sydney.solsticeDaylightSeconds))

        // 至日当天：伦敦 2026-06-21（至日 08:24 UTC 在这天里）
        store.compute(zone: zone("Europe/London", latitude: 51.5074, longitude: -0.1278), on: date("2026-06-21T12:00:00Z"))
        let solstice = try #require(store.trend)
        #expect(solstice.solsticeDaysAway == 0)
        #expect(solstice.solsticeIsLongest)
        // 至日次日：下一次至日在 12 月，「最短的一天」
        store.compute(zone: zone("Europe/London", latitude: 51.5074, longitude: -0.1278), on: date("2026-06-22T12:00:00Z"))
        let after = try #require(store.trend)
        #expect(after.solsticeDaysAway == 182)
        #expect(!after.solsticeIsLongest)

        // 换钟：伦敦 2026-03-29 进入夏令时，墙钟上日出比前一天晚约 58 分钟，真实日照只差两三分钟
        store.compute(zone: zone("Europe/London", latitude: 51.5074, longitude: -0.1278), on: date("2026-03-29T12:00:00Z"))
        let clockChange = try #require(store.trend)
        #expect((55 ... 60).contains(clockChange.sunriseShiftMinutes ?? 0))
        #expect((150 ... 260).contains(clockChange.daylightChangeSeconds))

        // 极夜：特罗姆瑟 12 月没有日出，挪动为 nil，日照差 0
        store.compute(zone: zone("Europe/Oslo", latitude: 69.6492, longitude: 18.9553), on: date("2026-12-10T12:00:00Z"))
        let polar = try #require(store.trend)
        #expect(polar.sunriseShiftMinutes == nil)
        #expect(polar.daylightChangeSeconds == 0)
        store.clear()
        #expect(store.trend == nil)
    }

    @Test func nativeBridgeReturnsNASANewMoonDayAndRejectsInvalidFacts() throws {
        let store = AstronomyStore()
        store.compute(zone: zone("Etc/UTC", latitude: 0, longitude: 0), on: date("2026-09-11T12:00:00Z"))
        let moon = try #require(store.result?.moon)
        #expect(moon.phase == "new")
        #expect(moon.illumination < 0.01)
        #expect(try #require(moon.ageDays) < 1)
        store.compute(zone: zone("Etc/UTC", latitude: .nan, longitude: 0), on: Date())
        #expect(store.result == nil)
        #expect(store.error == "invalidCoordinates")
        store.compute(zone: zone("Invalid/Zone", latitude: 0, longitude: 0), on: Date())
        #expect(store.error == "unsupportedDate")
        store.compute(zone: zone("Etc/UTC", latitude: 0, longitude: 0), on: Date(timeIntervalSince1970: 1e20))
        #expect(store.error == "unsupportedDate")
        #expect(store.computationCount == 1)
    }
}
