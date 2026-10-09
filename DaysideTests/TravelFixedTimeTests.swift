// SPDX-License-Identifier: GPL-3.0-only
//
//  TravelFixedTimeTests.swift
//  DaysideTests
//
//  旅行页三样产出的宿主那一半：固定时刻按真实日期换算、「不工作」阻塞时段的真实时刻。
//  判据是手算的 UTC 时刻与 IANA 事实（洛杉矶 → 东京跨日、伦敦 10-25 退夏令时），不照抄被测函数。
//  分段、拼法与校验的规则在 Rust（`travel.fixed_times` / `travel.status_line` / `travel.away_blocks` 六条测试）。
//

import Foundation
import Testing
@testable import Dayside

@MainActor
struct TravelFixedTimeTests {
    private static func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)!
    }

    private static func trip(origin: String, destination: String, arrival: String) -> TravelTrip {
        TravelTrip(id: UUID(), name: "出差", originTimeZoneID: origin, destinationTimeZoneID: destination,
                   destinationPlaceID: nil,
                   departureUnix: date(arrival).addingTimeInterval(-36_000).timeIntervalSince1970,
                   arrivalUnix: date(arrival).timeIntervalSince1970)
    }

    @Test func fixedTimesConvertWithTheRightDayMarker() {
        // 洛杉矶（家）→ 东京。家里 8:00 PDT = 东京次日 0:00；家里 21:00 = 东京次日 13:00。
        let trip = Self.trip(origin: "America/Los_Angeles", destination: "Asia/Tokyo",
                             arrival: "2026-10-01T12:00:00Z")
        let times = [TravelFixedTime(id: UUID(), label: "服药", minute: 480),
                     TravelFixedTime(id: UUID(), label: "通话", minute: 1260)]
        let rows = TravelFixedTimeConverter.rows(times: times, trip: trip).rows
        #expect(rows.count == 2)
        #expect(rows[0].segments.first?.minute == 0)
        #expect(rows[0].segments.first?.dayOffset == 1)
        #expect(rows[1].segments.first?.minute == 780)
        #expect(rows[1].segments.first?.dayOffset == 1)
        // 一周里钟点不变（两地都没换钟）→ 只有一段，覆盖 7 天。
        #expect(rows[0].segments.count == 1)
        #expect(rows[0].segments.first?.days == 7)
        // 0:00 落在夜间（22:00–06:00）。
        #expect(rows[0].segments.first?.night == true)
    }

    @Test func aClockChangeInsideTheWeekSplitsTheSegment() {
        // 家在东京（不换钟），目的地伦敦 2026-10-25 退夏令时：家里 17:00 JST 在伦敦
        // 10-25 之前是 9:00 BST、之后是 8:00 GMT → 两段。
        let trip = Self.trip(origin: "Asia/Tokyo", destination: "Europe/London",
                             arrival: "2026-10-22T00:00:00Z")
        let rows = TravelFixedTimeConverter.rows(
            times: [TravelFixedTime(id: UUID(), label: "晨会", minute: 17 * 60)], trip: trip).rows
        let segments = try! #require(rows.first).segments
        #expect(segments.count == 2)
        #expect(segments[0].minute == 9 * 60)
        #expect(segments[1].minute == 8 * 60)
        #expect(segments[1].fromDate == "2026-10-25")
        #expect(segments.map(\.days).reduce(0, +) == 7)
    }

    @Test func awayBlocksCoverTheHoursOutsideWork() {
        // 到达东京 2026-10-01（周四）。工作时段 9:00–18:00、只工作日：
        // 工作日各两段（0:00–9:00、18:00–24:00），周六日各一整天 → 5×2 + 2 = 12 个事件。
        let trip = Self.trip(origin: "America/Los_Angeles", destination: "Asia/Tokyo",
                             arrival: "2026-10-01T12:00:00Z")
        let events = TravelAwayBlocks.events(trip: trip, availability: .standard, placeName: "东京",
                                             countryCode: "JP", locale: Locale(identifier: "zh-Hans"),
                                             footer: "Dayside")
        #expect(events.count == 12)
        // 第一段就是到达日 0:00–9:00 东京时间 = 09-30T15:00Z–10-01T00:00Z。
        #expect(events.first?.start == Self.date("2026-09-30T15:00:00Z"))
        #expect(events.first?.end == Self.date("2026-10-01T00:00:00Z"))
        #expect(events.first?.title == "工作时段外（东京）")
        // 周末那天是整天（东京 10-03 00:00–10-04 00:00）。
        let wholeDay = events.first { $0.end.timeIntervalSince($0.start) == 86_400 }
        #expect(wholeDay?.start == Self.date("2026-10-02T15:00:00Z"))
        // 工作时段本身从不被阻塞。
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tokyo
        let noon = Self.date("2026-10-01T03:00:00Z")   // 东京 12:00 周四
        #expect(!events.contains { $0.start <= noon && noon < $0.end })
    }

    @Test func theStatusLineNamesThePlaceTheZoneAndBothWindows() {
        let line = TravelStatusLine.make(place: "东京", zoneAbbreviation: "", offsetText: "UTC+9",
            localWindowText: "9:00–18:00", counterpartWindowText: "洛杉矶 17:00–次日 2:00", locale: Locale(identifier: "zh-Hans"))
        #expect(line.text == "东京 · UTC+9 · 9:00–18:00（洛杉矶 17:00–次日 2:00）")
        #expect(line.parts.count == 3)
        let english = TravelStatusLine.make(place: "Tokyo", zoneAbbreviation: "JST", offsetText: "UTC+9",
            localWindowText: "9:00–18:00", counterpartWindowText: "Los Angeles 17:00–2:00 the next day", locale: Locale(identifier: "en"))
        #expect(english.text == "Tokyo · JST (UTC+9) · 9:00–18:00 (Los Angeles 17:00–2:00 the next day)")
    }
}
