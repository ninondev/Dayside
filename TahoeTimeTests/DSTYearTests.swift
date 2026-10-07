// SPDX-License-Identifier: GPL-3.0-only
//
//  DSTYearTests.swift
//  TahoeTimeTests
//
//  夏令时提醒页的一年：真时区（Foundation 的换钟事实）交给 Rust 分段，判据是本机 tzdata 2026c 的换钟时刻
//  （python zoneinfo 读同一份 /usr/share/zoneinfo 核过）：伦敦 2026-10-25 01:00Z、2027-03-28 01:00Z，
//  洛杉矶 2026-11-01 09:00Z、2027-03-14 10:00Z，悉尼 2026-10-03 16:00Z、2027-04-03 16:00Z。
//  框固定在 2026-10-02（洛杉矶）起，与跑测试的日期无关。
//

import Foundation
import Testing
@testable import TahoeTime

struct DSTYearTests {
    private func utc(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private var frame: DateInterval {
        DateInterval(start: utc("2026-10-02T07:00:00Z"), end: utc("2027-10-02T07:00:00Z"))
    }

    /// 伦敦先拨慢、洛杉矶一周后才拨：中间那一周伦敦只快 7 小时，是「两地错开的那几天」；春天反过来再来一遍。
    /// 东京从不换钟，冬天快 17 小时是季节，不涂蓝。
    @Test func theWeeksLondonIsSevenHoursAheadAreTheOnlyWindows() throws {
        let year = try #require(DSTYear.compute(frame: frame, local: "America/Los_Angeles", places: ["Europe/London", "Asia/Tokyo"]))
        let london = try #require(year.places.first { $0.zone == "Europe/London" })
        let windows = london.segments.filter(\.between)
        #expect(windows.map { Date(timeIntervalSince1970: $0.from) } == [utc("2026-10-25T01:00:00Z"), utc("2027-03-14T10:00:00Z")])
        #expect(windows.map { Date(timeIntervalSince1970: $0.to) } == [utc("2026-11-01T09:00:00Z"), utc("2027-03-28T01:00:00Z")])
        #expect(windows.allSatisfy { $0.value == 7 * 3600 })
        #expect(london.segments.filter { !$0.between }.allSatisfy { $0.value == 8 * 3600 })
        let tokyo = try #require(year.places.first { $0.zone == "Asia/Tokyo" })
        #expect(tokyo.segments.map(\.value) == [16 * 3600, 17 * 3600, 16 * 3600])
        #expect(tokyo.segments.filter(\.between).isEmpty)
        #expect(tokyo.transitions.isEmpty)
        #expect(year.hasWindows)
        // 本机自己分三段（夏令时、标准时间、夏令时），换钟两次。
        #expect(year.local.segments.map(\.value) == [-7 * 3600, -8 * 3600, -7 * 3600])
        #expect(year.local.transitions.count == 2)
        // 某一刻落在哪一段：10-28 伦敦快 7 小时，11-05 回到 8 小时。
        #expect(london.segment(at: utc("2026-10-28T17:00:00Z"))?.value == 7 * 3600)
        #expect(london.segment(at: utc("2026-11-05T17:00:00Z"))?.value == 8 * 3600)
    }

    /// 换钟表：四次，按时刻排；本机那两次让伦敦与东京一起变，伦敦那两次只让伦敦变。
    @Test func eachChangeNamesWhoChangedAndWhatItDidToTheDifferences() throws {
        let year = try #require(DSTYear.compute(frame: frame, local: "America/Los_Angeles", places: ["Europe/London", "Asia/Tokyo"]))
        #expect(year.changes.map(\.date) == [utc("2026-10-25T01:00:00Z"), utc("2026-11-01T09:00:00Z"),
                                             utc("2027-03-14T10:00:00Z"), utc("2027-03-28T01:00:00Z")])
        #expect(year.changes.map { $0.members.map(\.local) } == [[false], [true], [true], [false]])
        let november = year.changes[1]
        #expect(november.shift == -3600)
        #expect(Dictionary(uniqueKeysWithValues: november.effects.map { ($0.zone, $0.to) })
                == ["Europe/London": 8 * 3600, "Asia/Tokyo": 17 * 3600])
        #expect(year.changes[0].effects.map(\.zone) == ["Europe/London"])
    }

    /// 南半球：悉尼与洛杉矶反着换，错开的是 10 月与 3 月那几周（快 18 小时），中间整个冬天快 19 小时是季节。
    @Test func theOtherHemisphereHasTwoWindowsAroundASeason() throws {
        let year = try #require(DSTYear.compute(frame: frame, local: "America/Los_Angeles", places: ["Australia/Sydney"]))
        let sydney = try #require(year.places.first)
        #expect(sydney.segments.map { $0.value / 3600 } == [17, 18, 19, 18, 17])
        #expect(sydney.segments.map(\.between) == [false, true, false, true, false])
        #expect(Date(timeIntervalSince1970: sydney.segments[1].from) == utc("2026-10-03T16:00:00Z"))
    }

    /// 同一刻换钟的地方（本机伦敦、巴黎）时差不变：没有错开的那几天，换钟表里伦敦与巴黎并成一次、时差不变。
    @Test func placesThatChangeTogetherNeverDrift() throws {
        let year = try #require(DSTYear.compute(frame: frame, local: "Europe/London", places: ["Europe/Paris"]))
        #expect(year.places.first?.segments.count == 1)
        #expect(year.places.first?.segments.first?.value == 3600)
        #expect(!year.hasWindows)
        #expect(year.changes.count == 2)
        #expect(year.changes.allSatisfy { $0.members.count == 2 && $0.effects.isEmpty })
    }

    /// 框：看的那一刻在今后一年里时从今天起；跳到两年后，框跟着那一天走。
    @Test func theFrameStartsTodayUnlessTheViewedMomentIsOutsideTheYear() {
        let la = TimeZone(identifier: "America/Los_Angeles")!
        let now = utc("2026-10-02T20:00:00Z")
        let inside = DSTYear.frame(now: now, reference: utc("2027-02-01T20:00:00Z"), timeZone: la)
        #expect(inside.start == utc("2026-10-02T07:00:00Z"))
        let far = DSTYear.frame(now: now, reference: utc("2028-06-01T20:00:00Z"), timeZone: la)
        #expect(far.start == utc("2028-06-01T07:00:00Z"))
        let past = DSTYear.frame(now: now, reference: utc("2026-09-30T20:00:00Z"), timeZone: la)
        #expect(past.start == utc("2026-09-30T07:00:00Z"))
    }

    /// 只在框、地点或时区数据变了时去 Rust。
    @MainActor @Test func theMemoComputesOncePerFrameAndPlaces() {
        let memo = DSTYearMemo()
        memo.update(frame: frame, local: "America/Los_Angeles", places: ["Europe/London"], revision: 0)
        memo.update(frame: frame, local: "America/Los_Angeles", places: ["Europe/London"], revision: 0)
        #expect(memo.computations == 1)
        memo.update(frame: frame, local: "America/Los_Angeles", places: ["Europe/London", "Asia/Tokyo"], revision: 0)
        memo.update(frame: frame, local: "America/Los_Angeles", places: ["Europe/London", "Asia/Tokyo"], revision: 1)
        #expect(memo.computations == 3)
        #expect(memo.year?.places.count == 2)
    }

    /// 与本机差多少：面板行的说法（「快 8小时」），同一时间写「同一时间」；放不下时的短写与面板行一样（「+8h」）。
    @MainActor @Test func differencesUseThePanelsWording() {
        let zh = Locale(identifier: "zh-Hans"), en = Locale(identifier: "en")
        #expect(DSTWatchLensView.difference(8 * 3600, locale: zh) == String(format: L10n.string("快 %@", locale: zh),
                                                                              ClockText.duration(seconds: 8 * 3600, locale: zh)))
        #expect(DSTWatchLensView.difference(-12_600, locale: en) == "3 hours 30 minutes behind")
        #expect(DSTWatchLensView.difference(0, locale: zh) == L10n.string("同一时间", locale: zh))
        #expect(DSTWatchLensView.compactDifference(8 * 3600) == "+8h")
        #expect(DSTWatchLensView.compactDifference(-12_600) == "−3h30m")
        #expect(DSTWatchLensView.compactDifference(0) == nil)
    }
}
