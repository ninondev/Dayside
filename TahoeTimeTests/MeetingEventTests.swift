// SPDX-License-Identifier: GPL-3.0-only
//
//  MeetingEventTests.swift
//  TahoeTimeTests
//

import Foundation
import Testing
@testable import TahoeTime

struct MeetingEventTests {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    private func event(start: String = "2026-09-08T16:00:00Z", duration: Int = 60,
                       zones: [String] = ["America/Los_Angeles", "Asia/Tokyo"]) -> MeetingEvent {
        let start = date(start)
        let window = OverlapPlanner.Window(tier: .everyone, start: start,
                                            end: start.addingTimeInterval(Double(duration * 60)),
                                            best: start, durationMinutes: duration, score: 1, fits: [])
        return MeetingEvent.make(window: window, names: zones, timeZones: zones.map { TimeZone(identifier: $0)! },
                                 title: "Meeting", footer: "Planned with Dayside", locale: Locale(identifier: "en_US"),
                                 hourStyle: .force24)
    }

    @Test func notesContainEveryParticipantAndTheirLocalDate() {
        let value = event()
        #expect(value.lines.map(\.name) == ["America/Los_Angeles", "Asia/Tokyo"])
        #expect(value.lines[0].text.contains("Sep 8, 2026"))
        #expect(value.lines[1].text.contains("Sep 9, 2026"))
        #expect(value.notes.hasSuffix("Planned with Dayside"))
        #expect(value.end.timeIntervalSince(value.start) == 3600)
    }

    @Test func crossingMidnightIncludesTheEndDate() throws {
        let value = event(start: "2026-09-08T23:30:00Z", zones: ["UTC"])
        let line = try #require(value.lines.first)
        #expect(line.text.contains("Sep 8, 2026"))
        #expect(line.text.contains("Sep 9, 2026"))
    }

    @Test func fallBackLabelsBothOffsetsWhenWallClockTimesRepeat() throws {
        let value = event(start: "2026-11-01T08:30:00Z", zones: ["America/Los_Angeles"])
        let line = try #require(value.lines.first)
        let zone = TimeZoneEntry(timezoneID: "America/Los_Angeles", cityName: "")
        #expect(zone.abbreviation(at: value.start) != zone.abbreviation(at: value.end))
        #expect(line.text.contains(zone.abbreviation(at: value.start)))
        #expect(line.text.contains(zone.abbreviation(at: value.end)))
    }

    @Test func icsUsesUTCForUnambiguousStartAndEnd() {
        let value = event(start: "2026-11-01T08:30:00Z")
        let ics = value.icsText(uid: "fixture@example.test", stamp: date("2026-09-08T12:00:00Z"))
        #expect(ics.contains("DTSTART:20261101T083000Z\r\n"))
        #expect(ics.contains("DTEND:20261101T093000Z\r\n"))
        #expect(ics.contains("DTSTAMP:20260908T120000Z\r\n"))
        #expect(ics.contains("UID:fixture@example.test\r\n"))
        #expect(ics.hasPrefix("BEGIN:VCALENDAR\r\n"))
        #expect(ics.hasSuffix("END:VCALENDAR\r\n"))
        #expect(!ics.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
    }

    @Test func textEscapesAllSupportedNewlineFormsAndPunctuation() {
        #expect(MeetingEvent.escape("a\\b;c,d\r\ne\nf\rg") == "a\\\\b\\;c\\,d\\ne\\nf\\ng")
    }

    @Test func icsEscapesUserTextWithoutInjectingProperties() {
        let value = MeetingEvent(title: "Meeting\r\nLOCATION:elsewhere", start: date("2026-09-08T16:00:00Z"),
                                 end: date("2026-09-08T17:00:00Z"),
                                 lines: [.init(name: "A;B,C", text: "one\rtwo")], footer: "Dayside")
        let ics = value.icsText(uid: "fixture")
        #expect(!ics.contains("\r\nLOCATION:"))
        #expect(ics.contains("SUMMARY:Meeting\\nLOCATION:elsewhere\r\n"))
        #expect(ics.contains("A\\;B\\,C · one\\ntwo"))
    }

    @Test func longUnicodeLinesFoldAtByteBoundariesAndUnfoldLosslessly() {
        let source = "DESCRIPTION:" + String(repeating: "上海👩🏽‍💻é,", count: 30)
        let lines = MeetingEvent.fold(source)
        #expect(lines.count > 1)
        #expect(lines.allSatisfy { $0.utf8.count <= 75 })
        #expect(lines.dropFirst().allSatisfy { $0.utf8.first == 0x20 })
        // ICS 展开移除一个空格字节。Swift Character 可能把空格与紧随的 ZWJ 合为一个字素簇。
        let unfoldedBytes = lines.enumerated().flatMap {
            $0.offset == 0 ? Array($0.element.utf8) : Array($0.element.utf8.dropFirst())
        }
        #expect(unfoldedBytes == Array(source.utf8))
        let unfolded = String(decoding: unfoldedBytes, as: UTF8.self)
        #expect(unfolded == source)
        #expect(!unfolded.contains("�"))
    }

    @Test func exactly75BytesNeedNoContinuationLine() {
        let source = String(repeating: "a", count: 75)
        #expect(MeetingEvent.fold(source) == [source])
        #expect(MeetingEvent.fold(source + "b") == [source, " b"])
    }
}
