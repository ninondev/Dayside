// SPDX-License-Identifier: GPL-3.0-only
//
//  DSTCalendarPlanTests.swift
//  TahoeTimeTests
//
//  用真时区断言换钟时刻:London/New_York/Sydney/Tokyo 的数字先用本机 tzdata(python zoneinfo)核过,
//  再交给 Foundation 复现。参考时刻固定在 2026-09-01,与跑测试的日期无关。
//

import Foundation
import Testing
@testable import TahoeTime

struct DSTCalendarPlanTests {
    private func utc(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private var reference: Date { utc("2026-09-01T00:00:00Z") }

    /// 北半球的两次退出:伦敦 2026-10-25 01:00Z(UTC+1 → UTC)、纽约 2026-11-01 06:00Z(UTC−4 → UTC−5)。
    @Test func londonAndNewYorkLeaveDaylightTimeAtTheKnownInstants() throws {
        let london = try #require(DSTCalendarPlan.changes(zones: ["Europe/London"], from: reference).first)
        #expect(london.at == utc("2026-10-25T01:00:00Z"))
        #expect(london.entersDaylightTime == false)
        #expect(london.beforeSeconds == 3600 && london.afterSeconds == 0)

        let newYork = try #require(DSTCalendarPlan.changes(zones: ["America/New_York"], from: reference).first)
        #expect(newYork.at == utc("2026-11-01T06:00:00Z"))
        #expect(newYork.entersDaylightTime == false)
        #expect(newYork.beforeSeconds == -4 * 3600 && newYork.afterSeconds == -5 * 3600)
    }

    /// 南半球方向相反:悉尼 2026-10-03 16:00Z 偏移变大 = 进入;东京没有夏令时,12 个月里一次都没有。
    @Test func sydneyEntersDaylightTimeAndTokyoNeverChanges() throws {
        let sydney = try #require(DSTCalendarPlan.changes(zones: ["Australia/Sydney"], from: reference).first)
        #expect(sydney.at == utc("2026-10-03T16:00:00Z"))
        #expect(sydney.entersDaylightTime)
        #expect(sydney.beforeSeconds == 10 * 3600 && sydney.afterSeconds == 11 * 3600)
        #expect(DSTCalendarPlan.changes(zones: ["Asia/Tokyo"], from: reference).isEmpty)
    }

    /// 重复的标识符只算一次,按时刻排序;每次一小时,标题按方向分两种,说明写清几点变几点、偏移怎么变。
    @Test func eachChangeBecomesAnHourLongEventNamedAfterThePlace() throws {
        let changes = DSTCalendarPlan.changes(zones: ["Europe/London", "Australia/Sydney", "Europe/London"], from: reference)
        #expect(changes.map(\.zone) == ["Australia/Sydney", "Europe/London", "Europe/London", "Australia/Sydney"])
        #expect(changes.map(\.at) == [utc("2026-10-03T16:00:00Z"), utc("2026-10-25T01:00:00Z"),
                                      utc("2027-03-28T01:00:00Z"), utc("2027-04-03T16:00:00Z")])

        let events = DSTCalendarPlan.events(changes: changes,
                                            names: ["Europe/London": "伦敦", "Australia/Sydney": "悉尼"],
                                            locale: Locale(identifier: "zh-Hans"), hourStyle: .force24)
        #expect(events.count == 4)
        #expect(events.allSatisfy { $0.end.timeIntervalSince($0.start) == 3600 })
        #expect(events[0].title.contains("悉尼") && events[1].title.contains("伦敦"))
        // 同一个伦敦,10-25 退出与 2027-03-28 进入必须是两条不同的串
        #expect(events[1].title != events[2].title)
        let sydney = try #require(events.first?.lines.first)
        #expect(sydney.name == "悉尼")
        // 「2:00 → 3:00，UTC+10 → UTC+11」:墙钟读数的位数随系统 locale(2:00 / 02:00),偏移文案不随。
        let halves = sydney.text.components(separatedBy: "，")
        #expect(halves.count == 2)
        #expect(halves.last == "UTC+10 → UTC+11")
        let clocks = (halves.first ?? "").components(separatedBy: " → ")
        #expect(clocks.count == 2 && clocks[0] != clocks[1])
        #expect(clocks.allSatisfy { $0.contains(":") })
        #expect(events[1].lines[0].text.hasSuffix("UTC+1 → UTC"))
        #expect(events[0].notes.hasSuffix(L10n.string("用 Dayside 生成", locale: Locale(identifier: "zh-Hans"))))
    }

    /// 一份 .ics 装下全部换钟:VEVENT 数等于事件数,每个 DTSTART 都是那一刻的 UTC 时间戳。
    @Test func theSeriesIcsHasOneVeventPerChangeWithUtcStarts() {
        let changes = DSTCalendarPlan.changes(zones: ["Europe/London", "America/New_York", "Australia/Sydney"], from: reference)
        let events = DSTCalendarPlan.events(changes: changes, names: [:], locale: Locale(identifier: "en"), hourStyle: .force24)
        let text = MeetingEvent.icsSeriesText(events, stamp: Date(timeIntervalSince1970: 0))
        #expect(text.components(separatedBy: "BEGIN:VCALENDAR").count == 2)
        #expect(text.components(separatedBy: "BEGIN:VEVENT").count == events.count + 1)
        for event in events {
            #expect(text.contains("DTSTART:\(MeetingEvent.utcStamp(event.start))"))
        }
        #expect(text.contains("DTSTART:20261003T160000Z"))   // 悉尼进入
        #expect(text.contains("DTSTART:20261025T010000Z"))   // 伦敦退出
        #expect(text.contains("DTSTART:20261101T060000Z"))   // 纽约退出
        #expect(text.hasSuffix("END:VEVENT\r\nEND:VCALENDAR\r\n"))
    }
}

/// 与本机的时差变化窗口：真时区 + Foundation 的换钟事实，Rust 只做分段比较。
struct OffsetWindowsTests {
    private func utc(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    /// 本机洛杉矶、对方伦敦：2026-10-25 伦敦先退出 → 时差 8h 变 7h；11-01 洛杉矶退出 → 回到 8h；2027 春天再来一遍。
    @Test func londonAgainstLosAngelesDriftsForOneWeekEachAutumnAndSpring() throws {
        let reports = OffsetWindows.reports(localZone: "America/Los_Angeles", places: ["Europe/London", "Asia/Tokyo", "America/Los_Angeles"], now: utc("2026-09-01T00:00:00Z"))
        #expect(reports.map(\.zone) == ["Europe/London", "Asia/Tokyo"], "本机时区不列、重复的不列")
        let london = try #require(reports.first)
        #expect(london.diffNow == 8 * 3600)
        let changes = london.changes
        #expect(changes.count >= 4, "\(changes)")
        #expect(changes[0].date == utc("2026-10-25T01:00:00Z") && changes[0].from == 8 * 3600 && changes[0].to == 7 * 3600 && changes[0].cause == "place")
        #expect(changes[1].date == utc("2026-11-01T09:00:00Z") && changes[1].to == 8 * 3600 && changes[1].cause == "local")
        // 东京全年不动：变化全由本机引起，且时差 17h ↔ 16h 来回。
        let tokyo = reports[1]
        #expect(tokyo.diffNow == 16 * 3600 && tokyo.changes.allSatisfy { $0.cause == "local" })
        #expect(tokyo.changes.first?.to == 17 * 3600)
    }

    /// 同一天换钟的两地（伦敦 vs 巴黎）时差恒定：没有变化窗口。
    @Test func placesThatChangeTogetherHaveNoWindow() {
        let reports = OffsetWindows.reports(localZone: "Europe/London", places: ["Europe/Paris"], now: utc("2026-09-01T00:00:00Z"))
        #expect(reports.first?.changes.isEmpty == true && reports.first?.diffNow == 3600)
    }
}
