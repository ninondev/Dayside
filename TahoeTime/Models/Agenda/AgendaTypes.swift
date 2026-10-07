// SPDX-License-Identifier: GPL-3.0-only
import Foundation

nonisolated enum AgendaAuthorization: String, Sendable {
    case notDetermined, writeOnly, fullAccess, denied, restricted
}

nonisolated enum AgendaFailure: Error, Equatable, Sendable {
    case permission, read, eventUnavailable, meetingLinkUnavailable, open
}

nonisolated struct AgendaPreferences: Codable, Equatable, Sendable {
    let isEnabled: Bool
    let showInMenuBar: Bool
    let selectedCalendarIDs: [String]?
    let days: Int

    static func normalize(_ value: CoreJSON) -> Self {
        RustCore.invoke("agenda.normalize_preferences", value)
    }

    func applying(_ action: CoreJSON) -> Self {
        struct Input: Encodable { let preferences: AgendaPreferences; let action: CoreJSON }
        return RustCore.invoke("agenda.reduce", Input(preferences: self, action: action))
    }
}

nonisolated struct AgendaCalendar: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let sourceTitle: String
    /// 系统日历 app 里这个日历的颜色（EventKit 给的 sRGB 分量）；只上日历名前的小圆点，不上文字。
    /// 夹具与测试不给时是 nil，圆点退成三级色。
    var color: CodableColor? = nil
}

/// Foundation supplies syntax facts; Rust alone decides which meeting addresses to open.
nonisolated struct AgendaURLFacts: Codable, Equatable, Sendable {
    let scheme: String
    let host: String
    let port: Int?
    let hasUserInfo: Bool
    let encodedPath: String
    let encodedQuery: String?
    let hasFragment: Bool

    init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme, let host = components.host else { return nil }
        self.scheme = scheme
        self.host = host
        port = components.port
        hasUserInfo = components.user != nil || components.password != nil
        encodedPath = components.percentEncodedPath
        encodedQuery = components.percentEncodedQuery
        hasFragment = components.fragment != nil
    }
}

nonisolated struct AgendaEvent: Codable, Equatable, Sendable {
    let identifier: String
    let calendarID: String
    let title: String
    let start: Double
    let end: Double
    let isAllDay: Bool
    let isCancelled: Bool
    let isDeclined: Bool
    let location: String?
    let urls: [AgendaURLFacts]
    var hasAttendees = false
}

nonisolated struct AgendaMeetingLink: Codable, Equatable, Sendable {
    let url: String
    let provider: String

    static func recognize(_ facts: [AgendaURLFacts]) -> Self? {
        RustCore.invoke("agenda.meeting_link", ["urls": facts])
    }
}

nonisolated struct AgendaItem: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let calendarID: String
    let title: String
    let start: Double
    let end: Double
    let displayEnd: Double
    let isAllDay: Bool
    let location: String?
    let meetingLink: AgendaMeetingLink?

    var startDate: Date { Date(timeIntervalSince1970: start) }
    var endDate: Date { Date(timeIntervalSince1970: end) }
    var displayEndDate: Date { Date(timeIntervalSince1970: displayEnd) }
}

nonisolated struct AgendaMeeting: Codable, Equatable, Sendable {
    let event: AgendaItem
    let isOngoing: Bool
    let minutesUntilStart: UInt64
    let nextChangeAt: Double
}

nonisolated struct AgendaEvaluation: Decodable, Sendable {
    let events: [AgendaItem]
    let nextMeeting: AgendaMeeting?
    let menuBarMeeting: AgendaMeeting?

    static let empty = Self(events: [], nextMeeting: nil, menuBarMeeting: nil)
}

nonisolated struct AgendaSnapshot: Equatable, Sendable {
    let calendars: [AgendaCalendar]
    let events: [AgendaEvent]
    let interval: DateInterval

    func evaluate(preferences: AgendaPreferences, now: Date) -> AgendaEvaluation {
        struct Input: Encodable {
            let events: [AgendaEvent]
            let preferences: AgendaPreferences
            let now: Double
            let rangeStart: Double
            let rangeEnd: Double
        }
        return RustCore.invoke("agenda.evaluate", Input(events: events, preferences: preferences,
            now: now.timeIntervalSince1970, rangeStart: interval.start.timeIntervalSince1970,
            rangeEnd: interval.end.timeIntervalSince1970))
    }
}

nonisolated struct AgendaDayItem: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let calendarID: String
    let title: String
    let start: Double
    let end: Double
    let displayEnd: Double
    let isAllDay: Bool
    let location: String?
    let meetingLink: AgendaMeetingLink?
    let identifier: String
    let startsBefore: Bool
    let ended: Bool
    let ongoing: Bool

    var item: AgendaItem {
        .init(id: id, calendarID: calendarID, title: title, start: start, end: end,
              displayEnd: displayEnd, isAllDay: isAllDay, location: location, meetingLink: meetingLink)
    }
    var startDate: Date { Date(timeIntervalSince1970: start) }
    var endDate: Date { Date(timeIntervalSince1970: end) }
    var displayEndDate: Date { Date(timeIntervalSince1970: displayEnd) }
}

nonisolated struct AgendaDay: Decodable, Equatable, Sendable {
    let allDay: [AgendaItem]
    let timed: [AgendaDayItem]
    let selected: String?
    let next: AgendaItem?
}

extension AgendaSnapshot {
    func day(preferences: AgendaPreferences, dayStart: Date, dayEnd: Date, anchor: Date, now: Date) -> AgendaDay {
        struct Input: Encodable {
            let events: [AgendaEvent]
            let preferences: AgendaPreferences
            let dayStart: Double
            let dayEnd: Double
            let now: Double
            let anchor: Double
        }
        return RustCore.invoke("agenda.day", Input(events: events, preferences: preferences,
            dayStart: dayStart.timeIntervalSince1970, dayEnd: dayEnd.timeIntervalSince1970,
            now: now.timeIntervalSince1970, anchor: anchor.timeIntervalSince1970))
    }
}
