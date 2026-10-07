// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import EventKit
import Foundation
import Observation

@MainActor
@Observable
final class AgendaMenuBarReader: NextMeetingProviding {
    private struct Next: Equatable {
        let title: String
        let start: Date
        let end: Date
    }

    private var next: Next?
    private(set) var isActive = false
    private(set) var nextRefreshAt: Date?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let authorization: @MainActor () -> AgendaAuthorization
    @ObservationIgnored private let read: @MainActor (DateInterval, [String]?) throws -> [AgendaEvent]
    @ObservationIgnored private let dateProvider: @MainActor () -> Date
    @ObservationIgnored private let timeZoneProvider: @MainActor () -> TimeZone
    @ObservationIgnored private let observeSystemEvents: Bool
    @ObservationIgnored private var preferences: AgendaPreferences?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var interval: DateInterval?
    @ObservationIgnored private var timeZoneID: String?

    init(defaults: UserDefaults = Store.appDefaults,
         authorization: @escaping @MainActor () -> AgendaAuthorization = { nativeAuthorization() },
         read: @escaping @MainActor (DateInterval, [String]?) throws -> [AgendaEvent] = { try nativeRead(in: $0, calendarIDs: $1) },
         now: @escaping @MainActor () -> Date = { .now },
         timeZone: @escaping @MainActor () -> TimeZone = { .autoupdatingCurrent },
         observeSystemEvents: Bool = true) {
        self.defaults = defaults
        self.authorization = authorization
        self.read = read
        dateProvider = now
        timeZoneProvider = timeZone
        self.observeSystemEvents = observeSystemEvents
    }

    var activeResourceCount: Int { observers.count + (timer == nil ? 0 : 1) }

    func synchronizePreferences() {
        let stored = defaults.data(forKey: AgendaStore.preferencesKey)
            .flatMap { try? JSONDecoder().decode(CoreJSON.self, from: $0) } ?? .null
        let updated = AgendaPreferences.normalize(stored)
        guard updated.isEnabled && updated.showInMenuBar else {
            preferences = updated
            stop()
            return
        }
        let changed = preferences != updated
        preferences = updated
        if !isActive {
            isActive = true
            observeChanges()
            refresh()
        } else if changed { refresh() }
    }

    func stop() {
        isActive = false
        timer?.invalidate()
        timer = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        next = nil
        nextRefreshAt = nil
        interval = nil
        timeZoneID = nil
    }

    func refresh() {
        guard isActive, let preferences, preferences.isEnabled && preferences.showInMenuBar else { return }
        let now = dateProvider()
        let zone = timeZoneProvider()
        let window = Self.queryInterval(now: now, zone: zone)
        interval = window
        timeZoneID = zone.identifier
        timer?.invalidate()
        timer = nil
        next = nil
        if authorization() == .fullAccess {
            do {
                let events = try read(window, preferences.selectedCalendarIDs)
                if authorization() == .fullAccess {
                    let snapshot = AgendaSnapshot(calendars: [], events: events, interval: window)
                    if let meeting = snapshot.evaluate(preferences: preferences, now: now).nextMeeting {
                        next = Next(title: meeting.event.title, start: meeting.event.startDate, end: meeting.event.endDate)
                    }
                }
            } catch {
                next = nil
            }
        }
        scheduleRefresh(after: now)
    }

    func clockDidChange(now: Date) {
        guard isActive else { return }
        let zone = timeZoneProvider()
        if timeZoneID != zone.identifier || interval != Self.queryInterval(now: now, zone: zone)
            || nextRefreshAt.map({ now >= $0 }) == true {
            refresh()
        }
    }

    func nextMeeting(now: Date) -> UpcomingMeeting? {
        guard isActive, let next, now < next.end else { return nil }
        return UpcomingMeeting(title: next.title, start: next.start, isOngoing: now >= next.start,
            minutesUntilStart: UInt64((max(0, next.start.timeIntervalSince(now)) / 60).rounded(.up)))
    }

    func menuBarMeeting(now: Date) -> UpcomingMeeting? { nextMeeting(now: now) }

    private func scheduleRefresh(after now: Date) {
        var deadline = now.addingTimeInterval(900)
        if let next {
            let boundary = next.start > now ? next.start : next.end
            deadline = min(deadline, boundary)
        }
        nextRefreshAt = deadline
        let timer = Timer(timeInterval: max(0.001, deadline.timeIntervalSince(now)), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func observeChanges() {
        guard observeSystemEvents, observers.isEmpty else { return }
        let sources: [(NotificationCenter, Notification.Name)] = [
            (.default, .EKEventStoreChanged),
            (.default, .NSCalendarDayChanged),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification),
        ]
        for (center, name) in sources {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            observers.append((center, token))
        }
    }

    private static func queryInterval(now: Date, zone: TimeZone) -> DateInterval {
        let calendar = Calendar.gregorianUTC(zone)
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 7, to: start) ?? start.addingTimeInterval(7 * 86_400)
        return DateInterval(start: start, end: end)
    }

    private static func nativeAuthorization() -> AgendaAuthorization {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: .notDetermined
        case .writeOnly: .writeOnly
        case .fullAccess: .fullAccess
        case .denied: .denied
        default: .restricted
        }
    }

    private static func nativeRead(in interval: DateInterval, calendarIDs: [String]?) throws -> [AgendaEvent] {
        guard nativeAuthorization() == .fullAccess else { throw AgendaFailure.permission }
        let result: [AgendaEvent] = autoreleasepool {
            guard calendarIDs != [] else { return [] }
            let store = EKEventStore()
            let allowed = calendarIDs.map(Set.init)
            let calendars = store.calendars(for: .event).filter { allowed?.contains($0.calendarIdentifier) ?? true }
            guard !calendars.isEmpty else { return [] }
            let predicate = store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: calendars)
            return store.events(matching: predicate).compactMap { event in
                guard let start = event.startDate, let end = event.endDate, let calendar = event.calendar else { return nil }
                return AgendaEvent(identifier: event.calendarItemIdentifier, calendarID: calendar.calendarIdentifier,
                    title: event.title ?? "", start: start.timeIntervalSince1970, end: end.timeIntervalSince1970,
                    isAllDay: event.isAllDay, isCancelled: event.status == .canceled,
                    isDeclined: event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false,
                    location: nil, urls: [])
            }
        }
        guard nativeAuthorization() == .fullAccess else { throw AgendaFailure.permission }
        return result
    }

    isolated deinit {
        timer?.invalidate()
        for (center, token) in observers { center.removeObserver(token) }
    }
}
