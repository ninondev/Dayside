// SPDX-License-Identifier: GPL-3.0-only
//
//  OverlapPlannerTests.swift
//  TahoeTimeTests
//

import Foundation
import Testing
@testable import TahoeTime

struct OverlapPlannerTests {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    private func participant(_ zone: String = "UTC", start: Int = 540, end: Int = 1080,
                             weekdays: Bool = false, country: String? = "US") -> OverlapPlanner.Participant {
        .init(id: UUID(), name: zone, timeZoneID: zone,
              availability: .init(startMinute: start, endMinute: end, weekdaysOnly: weekdays), countryCode: country)
    }

    private func plan(_ people: [OverlapPlanner.Participant], from: String = "2026-09-08T00:00:00Z",
                      days: Int = 1, duration: Int = 60, tolerance: Int = 120,
                      localZone: String = "UTC") -> OverlapPlanner.Result {
        OverlapPlanner.plan(.init(participants: people, from: date(from), days: days,
                                  durationMinutes: duration, localTimeZoneID: localZone,
                                  toleranceMinutes: tolerance, limit: 100))
    }

    @Test func ordinaryOverlapContainsTheEntireMeeting() throws {
        let result = plan([participant(), participant(start: 600, end: 1020)])
        let window = try #require(result.everyone.first)
        #expect(window.start == date("2026-09-08T10:00:00Z"))
        #expect(window.end == date("2026-09-08T17:00:00Z"))
        #expect(window.best >= window.start)
        #expect(window.bestEnd <= window.end)
        #expect(window.fits.allSatisfy { $0.fit == .inside })
    }

    @Test func adjacentWorkHoursOfferAnExplicitCompromise() {
        let result = plan([participant(start: 540, end: 600), participant(start: 600, end: 660)])
        #expect(result.everyone.isEmpty)
        #expect(!result.compromises.isEmpty)
        #expect(result.compromises.allSatisfy { !$0.stretched.isEmpty })
    }

    @Test func distantWorkHoursHaveNoUsableWindow() {
        let result = plan([participant(start: 0, end: 60), participant(start: 720, end: 780)])
        #expect(result.windows.isEmpty)
    }

    @Test func quarterHourAndHalfHourZonesStayOnTheirWallClockGrid() throws {
        let result = plan([participant("Asia/Kathmandu"), participant("Asia/Kolkata")], tolerance: 0)
        let window = try #require(result.everyone.first)
        #expect(window.start == date("2026-09-08T03:30:00Z"))
        #expect(window.end == date("2026-09-08T12:15:00Z"))
        for fit in window.fits {
            let calendar = OverlapPlanner.calendar(for: fit.participant.timeZone, countryCode: nil)
            #expect(calendar.component(.minute, from: window.best) % 15 == 0)
        }
    }

    @Test func searchRoundsForwardWithoutOfferingPastMeetings() {
        let start = "2026-09-08T12:01:01Z"
        let result = plan([participant()], from: start, tolerance: 0)
        #expect(!result.windows.isEmpty)
        #expect(result.windows.allSatisfy { $0.start >= date(start) && $0.best >= date(start) })
        #expect(result.everyone.first?.start == date("2026-09-08T12:15:00Z"))
    }

    @Test func overnightAvailabilityRemainsContinuousAcrossMidnight() throws {
        let result = plan([participant(start: 1320, end: 360)], from: "2026-09-08T22:00:00Z", days: 2, tolerance: 0)
        let window = try #require(result.everyone.first)
        #expect(window.start == date("2026-09-08T22:00:00Z"))
        #expect(window.end == date("2026-09-09T06:00:00Z"))
    }

    @Test(arguments: [0, 540, 1439])
    func equalEndpointsMeanTheWholeLocalDay(minute: Int) throws {
        let day = date("2026-09-08T00:00:00Z")
        let intervals = OverlapPlanner.availabilityIntervals(
            for: participant(start: minute, end: minute), coveringFrom: day, to: day)
        let interval = try #require(intervals.first)
        #expect(intervals.count == 1)
        #expect(interval.start == day)
        #expect(interval.duration == 86_400)
    }

    @Test func allDayMeetingsCanCrossTheDateBoundary() throws {
        let start = date("2026-09-08T23:30:00Z")
        let result = plan([participant(start: 0, end: 1440)], from: "2026-09-08T23:30:00Z", days: 2, tolerance: 0)
        let window = try #require(result.everyone.first)
        #expect(window.start == start)
        #expect(window.end >= start.addingTimeInterval(3600))
        #expect(result.compromises.isEmpty)
    }

    @Test func weekendsExcludeNightShiftSpilloverAndCompromises() {
        let saturday = plan([participant(start: 1320, end: 360, weekdays: true)],
                            from: "2026-09-12T02:00:00Z")
        #expect(saturday.windows.isEmpty)
        let sunday = plan([participant(start: 0, end: 60, weekdays: true)],
                          from: "2026-09-13T22:30:00Z")
        #expect(sunday.windows.isEmpty, "折中也不能提前到周一之前的休息日")
    }

    @Test func fridayNightShiftStopsAtTheWeekendBoundary() throws {
        let friday = date("2026-09-11T00:00:00Z")
        let intervals = OverlapPlanner.availabilityIntervals(
            for: participant(start: 1320, end: 360, weekdays: true), coveringFrom: friday, to: friday)
        let interval = try #require(intervals.first)
        #expect(interval.start == date("2026-09-11T22:00:00Z"))
        #expect(interval.end == date("2026-09-12T00:00:00Z"))
    }

    @Test func regionalWeekendsUseTheParticipantsCountry() {
        let zone = TimeZone(identifier: "Asia/Jerusalem")!
        #expect(OverlapPlanner.isWeekend(date("2026-09-11T12:00:00Z"), timeZone: zone, countryCode: "IL"))
        #expect(!OverlapPlanner.isWeekend(date("2026-09-13T12:00:00Z"), timeZone: zone, countryCode: "IL"))
    }

    @Test(arguments: [("2026-03-08T08:00:00Z", 23.0), ("2026-11-01T07:00:00Z", 25.0)])
    func fullDayFollowsTheRealLengthOfDSTDays(start: String, hours: Double) throws {
        let day = date(start)
        let intervals = OverlapPlanner.availabilityIntervals(
            for: participant("America/Los_Angeles", start: 540, end: 540), coveringFrom: day, to: day)
        let interval = try #require(intervals.first)
        #expect(interval.start == day)
        #expect(interval.duration == hours * 3600)
    }

    @Test func springForwardClipsTheMissingWallClockHour() throws {
        let day = date("2026-03-08T08:00:00Z")
        let intervals = OverlapPlanner.availabilityIntervals(
            for: participant("America/Los_Angeles", start: 150, end: 240), coveringFrom: day, to: day)
        let interval = try #require(intervals.first)
        #expect(interval.start == date("2026-03-08T10:00:00Z"))
        #expect(interval.end == date("2026-03-08T11:00:00Z"))
        let missing = OverlapPlanner.availabilityIntervals(
            for: participant("America/Los_Angeles", start: 135, end: 165), coveringFrom: day, to: day)
        #expect(missing.isEmpty)
    }

    @Test func midnightTransitionDoesNotExtendTheSearchIntoTomorrow() throws {
        let start = date("2026-09-06T04:00:00Z")
        let person = participant("America/Santiago", start: 0, end: 1440)
        let intervals = OverlapPlanner.availabilityIntervals(for: person, coveringFrom: start, to: start)
        let interval = try #require(intervals.first)
        #expect(interval.start == start)
        #expect(interval.end == date("2026-09-07T03:00:00Z"))
        #expect(interval.duration == 23 * 3600)
        let result = plan([person], from: "2026-09-06T04:00:00Z", tolerance: 0, localZone: "America/Santiago")
        #expect(result.everyone.first?.end == interval.end)
    }

    @Test func fallBackKeepsBothOccurrencesWithoutFillingTheGap() {
        let day = date("2026-11-01T07:00:00Z")
        let intervals = OverlapPlanner.availabilityIntervals(
            for: participant("America/Los_Angeles", start: 75, end: 105), coveringFrom: day, to: day)
        #expect(intervals == [
            DateInterval(start: date("2026-11-01T08:15:00Z"), end: date("2026-11-01T08:45:00Z")),
            DateInterval(start: date("2026-11-01T09:15:00Z"), end: date("2026-11-01T09:45:00Z")),
        ])
    }

    @Test func meetingDurationMeasuresElapsedTimeAcrossDST() throws {
        let result = plan([participant("America/Los_Angeles", start: 60, end: 240)],
                          from: "2026-03-08T09:00:00Z", duration: 120, tolerance: 0,
                          localZone: "America/Los_Angeles")
        let window = try #require(result.everyone.first)
        #expect(window.best == date("2026-03-08T09:00:00Z"))
        #expect(window.bestEnd == date("2026-03-08T11:00:00Z"))
    }

    @Test func invalidRequestsReturnNoWindows() {
        #expect(plan([]).windows.isEmpty)
        #expect(plan([participant()], duration: 0).windows.isEmpty)
    }

    /// 结果行的「各地时间」（排会、例会轮换、日历页同一条 Rust 路）：行首日期是本机的，
    /// 洛杉矶周一 21:00 开会时伦敦、东京已是次日，钟点后（英文）或前（中文）带标注；
    /// 东京组织者看同一场，洛杉矶是前一日；无障碍文本同样带标注。
    @Test func placesLineMarksTheNextAndPreviousDayInEachLanguage() throws {
        let best = date("2026-09-15T04:00:00Z")   // 洛杉矶 09-14 21:00、伦敦 09-15 05:00、东京 09-15 13:00
        let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
        let format = ClockFormat(hourStyle: .force24, showSeconds: false)
        let names = [("Los Angeles", "America/Los_Angeles"), ("London", "Europe/London"), ("Tokyo", "Asia/Tokyo")]
        func line(reference: TimeZone, locale: Locale) -> PresentationCore.Places {
            PresentationCore.call("window_places", PresentationCore.PlacesInput(
                places: names.map { name, zone in
                    .init(name: name, date: best, in: TimeZone(identifier: zone)!, reference: reference, format: format)
                }, locale: locale))
        }
        // 钟点文本本身随本机 locale（en「05:00」、zh「5:00」），所以拿 TimeFormatting 的输出拼期望值，只钉标注与顺序。
        let clock = names.map { TimeFormatting.string(for: best, in: TimeZone(identifier: $0.1)!, format: format) }
        #expect(clock[0].hasSuffix("21:00") && clock[1].hasSuffix("5:00") && clock[2].hasSuffix("13:00"))
        let english = line(reference: losAngeles, locale: Locale(identifier: "en"))
        #expect(english.segments.map(\.text) == ["Los Angeles \(clock[0])", " · ", "London \(clock[1]) next day", " · ", "Tokyo \(clock[2]) next day"])
        #expect(english.accessibility == "Los Angeles \(clock[0]), London \(clock[1]) next day, Tokyo \(clock[2]) next day")
        let chinese = line(reference: losAngeles, locale: Locale(identifier: "zh-Hans"))
        #expect(chinese.segments.map(\.text) == ["Los Angeles \(clock[0])", " · ", "London 次日 \(clock[1])", " · ", "Tokyo 次日 \(clock[2])"])
        let fromTokyo = line(reference: TimeZone(identifier: "Asia/Tokyo")!, locale: Locale(identifier: "en"))
        #expect(fromTokyo.segments.map(\.text) == ["Los Angeles \(clock[0]) previous day", " · ", "London \(clock[1])", " · ", "Tokyo \(clock[2])"])
        // 十六语都有这两条模板，且 %@ 恰好一个（否则 Rust 会把钟点接在模板后面）。
        for id in ["zh-Hans", "zh-Hant", "en", "ja", "ko", "de", "es", "fr", "ru", "pt-BR", "it", "nl", "pl", "tr", "vi", "id"] {
            for key in ["次日 %@", "前一日 %@"] {
                let template = L10n.string(key, locale: Locale(identifier: id))
                #expect(template.components(separatedBy: "%@").count == 2, "\(id) \(key): \(template)")
            }
        }
    }
}
