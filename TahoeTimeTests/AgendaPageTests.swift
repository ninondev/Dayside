// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Foundation
import Testing
@testable import TahoeTime

@MainActor
struct AgendaPageTests {
    private let home = TimeZone(identifier: "America/Los_Angeles")!
    private let london = TimeZone(identifier: "Europe/London")!
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    private var start: Date { ISO8601DateFormatter().date(from: "2026-10-05T16:00:00Z")! }
    private func event(_ id: String, start: Date, duration: Double = 1800) -> AgendaDayItem {
        .init(id: id, calendarID: "work", title: "Weekly sync", start: start.timeIntervalSince1970,
              end: start.timeIntervalSince1970 + duration, displayEnd: start.timeIntervalSince1970 + duration,
              isAllDay: false, location: nil, meetingLink: nil, identifier: id, startsBefore: false, ended: false, ongoing: false)
    }

    @Test func selectionChangesOnDayAndScrubButNotOnMinuteTicks() {
        var selection = AgendaPageSelection()
        let day = Calendar.gregorianUTC(home).startOfDay(for: start)
        selection.update(day: day, offset: 0, preferred: "first", available: ["first", "second"])
        selection.select("second")
        selection.update(day: day, offset: 0, preferred: "third", available: ["first", "second", "third"])
        #expect(selection.id == "second")
        selection.update(day: day, offset: 60, preferred: "first", available: ["first", "second"])
        #expect(selection.id == "first")
        selection.select("second")
        selection.update(day: day.addingTimeInterval(86400), offset: 60, preferred: "first", available: ["first", "second"])
        #expect(selection.id == "first")
    }

    @Test func copyingUsesTheSameRowsAndWritesCrossDayDates() {
        let places = [
            AgendaTable.Place(zone: home, name: "Los Angeles", note: "", coordinate: nil),
            AgendaTable.Place(zone: london, name: "London", note: "", coordinate: nil),
            AgendaTable.Place(zone: tokyo, name: "Tokyo", note: "", coordinate: nil),
        ]
        let text = AgendaDayList.copyText(event("e", start: start).item, places: places, hourStyle: .force24,
                                          locale: Locale(identifier: "en_US"), now: start, home: home)
        let end = start.addingTimeInterval(1800)
        func clocks(_ zone: TimeZone) -> String {
            "\(ClockText.time(start, in: zone, hourStyle: .force24))–\(ClockText.time(end, in: zone, hourStyle: .force24))"
        }
        #expect(text == "Weekly sync\nLos Angeles \(clocks(home)) / London \(clocks(london)) / Tokyo Oct 6 \(clocks(tokyo))")
    }

    @Test(arguments: [HourStyle.force12, .force24])
    func timeColumnIncludesEveryMeasuredClock(hourStyle: HourStyle) {
        var settings = AppSettings()
        settings.hourStyle = hourStyle
        let events = [event("early", start: start), event("late", start: start.addingTimeInterval(9 * 3600))]
        let day = AgendaDay(allDay: [], timed: events, selected: "early", next: nil)
        let width = AgendaDayList.timeWidth(day: day, settings: settings, scale: 1.3, locale: Locale(identifier: "en_US"), zone: home)
        let font = ClockFace.nativeFont(size: ClockFace.mediumSize(scale: 1.3), design: settings.fontDesign, weight: settings.weight, light: false)
        for event in events {
            let time = ClockText.time(event.startDate, in: home, hourStyle: hourStyle)
            #expect(width >= (time as NSString).size(withAttributes: [.font: font]).width)
        }
    }

    @Test(arguments: [HourStyle.force12, .force24])
    func allDayTimeColumnIncludesTheLocalizedLabel(hourStyle: HourStyle) {
        var settings = AppSettings()
        settings.hourStyle = hourStyle
        let allDay = AgendaItem(id: "day", calendarID: "work", title: "Holiday",
            start: start.timeIntervalSince1970, end: start.timeIntervalSince1970 + 86_400,
            displayEnd: start.timeIntervalSince1970 + 86_400, isAllDay: true,
            location: nil, meetingLink: nil)
        let day = AgendaDay(allDay: [allDay], timed: [], selected: nil, next: nil)
        let scale = 1.3
        let locale = Locale(identifier: "ru")
        let width = AgendaDayList.timeWidth(day: day, settings: settings, scale: scale, locale: locale, zone: home)
        let label = L10n.string("全天", locale: locale)
        let font = NSFont.systemFont(ofSize: AppFont.size(.callout) * scale)
        #expect(width >= (label as NSString).size(withAttributes: [.font: font]).width)
    }

    @Test func aSelectedEventRemovedFromTheDayFallsBackToThePreferredEvent() {
        var selection = AgendaPageSelection()
        let day = Calendar.gregorianUTC(home).startOfDay(for: start)
        selection.update(day: day, offset: 0, preferred: "first", available: ["first", "second"])
        selection.select("second")
        selection.update(day: day, offset: 0, preferred: "first", available: ["first"])
        #expect(selection.id == "first")
        selection.update(day: day, offset: 0, preferred: nil, available: [])
        #expect(selection.id == nil)
    }

    @Test func timelineHitPrefersLatestOverlapAndHasEightPointTolerance() {
        let frame = DayLaneFrame.homeDay(containing: start, timeZone: home)
        let a = event("a", start: start, duration: 3600)
        let b = event("b", start: start.addingTimeInterval(900), duration: 1800)
        let at = MomentTable.fraction(of: start.addingTimeInterval(1200), in: frame)
        #expect(AgendaTable.hit(at: at, width: 720, events: [a, b], frame: frame) == "b")
        let nearby = MomentTable.fraction(of: a.endDate, in: frame) + 7 / 720
        #expect(AgendaTable.hit(at: nearby, width: 720, events: [a, b], frame: frame) == "a")
        #expect(AgendaTable.hit(at: nearby + 2 / 720, width: 720, events: [a, b], frame: frame) == nil)
    }

    @Test func changingTheDateKeepsTheLocalClockAcrossSpringChange() {
        let old = ISO8601DateFormatter().date(from: "2026-03-07T17:30:00Z")!
        let target = ISO8601DateFormatter().date(from: "2026-03-08T20:00:00Z")!
        let changed = AgendaLensView.replacingDay(of: old, with: target, zone: home)
        let parts = Calendar.gregorianUTC(home).dateComponents([.day, .hour, .minute], from: changed)
        #expect(parts.day == 8 && parts.hour == 9 && parts.minute == 30)
        #expect(changed.timeIntervalSince(old) == 23 * 3600)
    }
}
