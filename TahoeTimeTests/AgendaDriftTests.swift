// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import TahoeTime

struct AgendaDriftTests {
    private func event(_ id: String, _ title: String, _ iso: String, allDay: Bool = false, hasAttendees: Bool = true) -> AgendaEvent {
        let start = ISO8601DateFormatter().date(from: iso)!.timeIntervalSince1970
        return AgendaEvent(identifier: id, calendarID: "c", title: title, start: start, end: start + 1800,
                           isAllDay: allDay, isCancelled: false, isDeclined: false, location: nil, urls: [], hasAttendees: hasAttendees)
    }

    /// A weekly 09:00 Los Angeles call: New Zealand starts daylight time on 2026-09-27, so from the
    /// 2026-10-02 occurrence Nia's 04:00 becomes 05:00 while everyone else keeps their hour.
    @Test func aClockChangeInOneZoneIsNamedWithDateAndNewLocalTime() throws {
        let events = [event("weekly", "Weekly sync", "2026-09-25T16:00:00Z"), event("weekly", "Weekly sync", "2026-10-02T16:00:00Z")]
        let participants = [
            AgendaDriftParticipant(id: "la", name: "Los Angeles", timeZoneID: "America/Los_Angeles"),
            AgendaDriftParticipant(id: "ana", name: "Ana", timeZoneID: "Europe/London"),
            AgendaDriftParticipant(id: "nia", name: "Nia", timeZoneID: "Pacific/Auckland"),
        ]
        let meetings = AgendaDrift.meetings(events: events, participants: participants)
        #expect(meetings.count == 1)
        #expect(meetings.first?.identifier == "weekly")
        #expect(meetings.first?.places.count == 1)
        let place = try #require(meetings.first?.places.first)
        #expect(place.participant == "nia")
        #expect(place.participantName == "Nia")
        #expect(place.baseline == 4 * 60)
        #expect(place.runs.count == 1)
        let run = try #require(place.runs.first)
        let shiftedAt = ISO8601DateFormatter().date(from: "2026-10-02T16:00:00Z")!.timeIntervalSince1970
        #expect(run.first == shiftedAt && run.last == shiftedAt)
        #expect(run.minute == 5 * 60 && run.open == true)
        // 卡片上的钟点按小时制显示。
        #expect(ClockText.minute(run.minute, hourStyle: .force24, system: Locale(identifier: "en_US")) == "05:00")
        #expect(ClockText.minute(run.minute, hourStyle: .force12, system: Locale(identifier: "en_US")).hasPrefix("5:00"))
    }

    /// London ends daylight time on 2026-10-25: a London-anchored 17:00 call moves for Los Angeles
    /// and Tokyo, and London itself is the anchor.
    @Test func theAnchorZoneIsNeverWarnedAndEveryoneElseIs() {
        let events = [event("w", "Standup", "2026-10-22T16:00:00Z"), event("w", "Standup", "2026-10-29T17:00:00Z")]
        let participants = [
            AgendaDriftParticipant(id: "ldn", name: "Ana", timeZoneID: "Europe/London"),
            AgendaDriftParticipant(id: "la", name: "Los Angeles", timeZoneID: "America/Los_Angeles"),
            AgendaDriftParticipant(id: "tyo", name: "Mei", timeZoneID: "Asia/Tokyo"),
        ]
        let meetings = AgendaDrift.meetings(events: events, participants: participants)
        #expect(meetings.count == 1)
        let places = meetings.first?.places ?? []
        #expect(places.map(\.participantName).sorted() == ["Los Angeles", "Mei"])
        #expect(!places.contains { $0.participant == "ldn" })
        let la = places.first { $0.participant == "la" }
        #expect(la?.baseline == 9 * 60 && la?.runs.first?.minute == 10 * 60)
        let tokyo = places.first { $0.participant == "tyo" }
        #expect(tokyo?.baseline == 60 && tokyo?.runs.first?.minute == 120)
        #expect(places.allSatisfy { $0.runs.count == 1 && $0.runs[0].open })
    }

    @Test func aSoloSeriesWithoutAttendeesOrMeetingLinksIsNotReported() {
        let participants = [
            AgendaDriftParticipant(id: "la", name: "Los Angeles", timeZoneID: "America/Los_Angeles"),
            AgendaDriftParticipant(id: "nia", name: "Nia", timeZoneID: "Pacific/Auckland"),
        ]
        let events = [
            event("gym", "Gym", "2026-09-25T16:00:00Z", hasAttendees: false),
            event("gym", "Gym", "2026-10-02T16:00:00Z", hasAttendees: false),
        ]
        #expect(AgendaDrift.meetings(events: events, participants: participants).isEmpty)
    }

    @Test func nothingIsReportedWithoutARecurrenceOrWhenTheWholeMeetingMoved() {
        let participants = [
            AgendaDriftParticipant(id: "la", name: "Los Angeles", timeZoneID: "America/Los_Angeles"),
            AgendaDriftParticipant(id: "tyo", name: "Mei", timeZoneID: "Asia/Tokyo"),
        ]
        #expect(AgendaDrift.meetings(events: [event("one", "Once", "2026-09-25T16:00:00Z")], participants: participants).isEmpty)
        let moved = [event("m", "Moved", "2026-09-18T16:00:00Z"), event("m", "Moved", "2026-09-25T17:00:00Z")]
        #expect(AgendaDrift.meetings(events: moved, participants: participants).isEmpty)
        let allDay = [event("d", "Day", "2026-09-25T16:00:00Z", allDay: true), event("d", "Day", "2026-10-02T16:00:00Z", allDay: true)]
        #expect(AgendaDrift.meetings(events: allDay, participants: participants).isEmpty)
    }
}
