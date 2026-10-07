// SPDX-License-Identifier: GPL-3.0-only
import Foundation

nonisolated struct AgendaDriftRun: Decodable, Equatable, Identifiable, Sendable {
    let first: Double
    let last: Double
    let open: Bool
    let minute: Int
    var id: Double { first }
}

nonisolated struct AgendaDriftPlace: Decodable, Equatable, Identifiable, Sendable {
    let participant: String
    let participantName: String
    let baseline: Int
    let runs: [AgendaDriftRun]
    var id: String { "\(participant)|\(baseline)" }
}

nonisolated struct AgendaDriftMeeting: Decodable, Equatable, Identifiable, Sendable {
    let identifier: String
    let title: String
    let places: [AgendaDriftPlace]
    var id: String { identifier }
}

nonisolated struct AgendaDriftWarning: Equatable, Identifiable, Sendable {
    let identifier: String
    let title: String
    let participant: String
    let participantName: String
    let fromMinute: Int
    let toMinute: Int
    let at: Double
    let previousAt: Double
    var id: String { "\(identifier)|\(participant)" }
}

nonisolated struct AgendaDriftParticipant: Hashable, Sendable {
    let id: String
    let name: String
    let timeZoneID: String
}

nonisolated enum AgendaDrift {
    static let lookaheadDays = 35

    static func meetings(events: [AgendaEvent], participants: [AgendaDriftParticipant]) -> [AgendaDriftMeeting] {
        struct Event: Encodable {
            let identifier: String
            let title: String
            let start: Double
            let isAllDay: Bool
            let isCancelled: Bool
            let hasAttendees: Bool
            let urls: [AgendaURLFacts]
        }
        struct Participant: Encodable { let id: String; let name: String }
        struct Fact: Encodable { let identifier: String; let start: Double; let participant: String; let minuteOfDay: Int }
        struct Input: Encodable { let events: [Event]; let participants: [Participant]; let local: [Fact] }
        struct Output: Decodable { let meetings: [AgendaDriftMeeting] }
        var calendar = Calendar(identifier: .gregorian)
        var facts: [Fact] = []
        for participant in participants {
            guard let zone = TimeZone(identifier: participant.timeZoneID) else { continue }
            calendar.timeZone = zone
            for event in events where !event.isAllDay && !event.isCancelled && event.start.isFinite {
                let parts = calendar.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: event.start))
                facts.append(Fact(identifier: event.identifier, start: event.start, participant: participant.id,
                                  minuteOfDay: (parts.hour ?? 0) * 60 + (parts.minute ?? 0)))
            }
        }
        let output: Output = RustCore.invoke("agenda.drift", Input(
            events: events.map { Event(identifier: $0.identifier, title: $0.title, start: $0.start,
                isAllDay: $0.isAllDay, isCancelled: $0.isCancelled, hasAttendees: $0.hasAttendees, urls: $0.urls) },
            participants: participants.map { Participant(id: $0.id, name: $0.name) }, local: facts))
        return output.meetings
    }

    // 旧调用方只取每个地方的第一段，判定始终交给同一条 Rust 路径。
    static func warnings(events: [AgendaEvent], participants: [AgendaDriftParticipant]) -> [AgendaDriftWarning] {
        meetings(events: events, participants: participants).flatMap { meeting in
            meeting.places.compactMap { place in
                guard let run = place.runs.first else { return nil }
                let previous = events.filter { $0.identifier == meeting.identifier && $0.start < run.first }
                    .map(\.start).max() ?? run.first
                return AgendaDriftWarning(identifier: meeting.identifier, title: meeting.title,
                    participant: place.participant, participantName: place.participantName,
                    fromMinute: place.baseline, toMinute: run.minute, at: run.first, previousAt: previous)
            }
        }
    }

    @MainActor
    static func participants(localTimeZoneID: String, localName: String,
                             places: [TimeZoneEntry], people: [PersonProfile],
                             placeName: (String) -> String) -> [AgendaDriftParticipant] {
        var result = [AgendaDriftParticipant(id: localTimeZoneID, name: localName, timeZoneID: localTimeZoneID)]
        var seen: Set<String> = [localTimeZoneID]
        for place in places where seen.insert(place.timezoneID).inserted {
            result.append(.init(id: place.timezoneID, name: placeName(place.timezoneID), timeZoneID: place.timezoneID))
        }
        for person in people {
            let zone = person.resolvedTimeZoneID(places: places)
            guard seen.insert(zone).inserted else { continue }
            result.append(.init(id: zone, name: placeName(zone), timeZoneID: zone))
        }
        return result
    }
}
