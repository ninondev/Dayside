// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import EventKit
import Foundation

/// Only the native adapter owns EventKit objects. Tests inject value snapshots.
@MainActor
protocol AgendaService: AnyObject {
    var authorization: AgendaAuthorization { get }
    var activeResourceCount: Int { get }
    func requestFullAccess() async throws -> Bool
    func snapshot(in interval: DateInterval, calendarIDs: [String]?) async throws -> AgendaSnapshot
    func observeChanges(_ receive: @escaping @MainActor @Sendable () -> Void)
    func stop()
}

@MainActor
final class EventKitAgendaService: AgendaService {
    private var eventStore: EKEventStore?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var accessRequest: (id: UUID, continuation: CheckedContinuation<Bool, any Error>)?

    var authorization: AgendaAuthorization {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: .notDetermined
        case .writeOnly: .writeOnly
        case .fullAccess: .fullAccess
        case .denied: .denied
        default: .restricted
        }
    }

    var activeResourceCount: Int {
        (eventStore == nil ? 0 : 1) + observers.count + (accessRequest == nil ? 0 : 1)
    }

    private func store() -> EKEventStore {
        if let eventStore { return eventStore }
        let value = EKEventStore()
        eventStore = value
        return value
    }

    func requestFullAccess() async throws -> Bool {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                accessRequest = (id, continuation)
                store().requestFullAccessToEvents { [weak self] granted, error in
                    Task { @MainActor [weak self] in
                        guard let self, self.accessRequest?.id == id else { return }
                        let pending = self.accessRequest
                        self.accessRequest = nil
                        if let error { pending?.continuation.resume(throwing: error) }
                        else { pending?.continuation.resume(returning: granted) }
                    }
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in self?.cancelAccess(id: id) }
        }
    }

    private func cancelAccess(id: UUID) {
        guard accessRequest?.id == id else { return }
        let pending = accessRequest
        accessRequest = nil
        pending?.continuation.resume(throwing: CancellationError())
    }

    func snapshot(in interval: DateInterval, calendarIDs: [String]?) async throws -> AgendaSnapshot {
        try Task.checkCancellation()
        guard authorization == .fullAccess else { throw AgendaFailure.permission }
        let store = store()
        let calendars = store.calendars(for: .event)
        struct Selection: Encodable { let allIDs: [String]; let selectedIDs: [String]? }
        let ids: [String] = RustCore.invoke("agenda.calendar_selection", Selection(allIDs: calendars.map(\.calendarIdentifier), selectedIDs: calendarIDs))
        let byID = Dictionary(calendars.map { ($0.calendarIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        let selected = ids.compactMap { byID[$0] }
        let predicate = store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: selected)
        let detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let events = (selected.isEmpty ? [] : store.events(matching: predicate)).compactMap { event -> AgendaEvent? in
            guard let start = event.startDate, let end = event.endDate, let calendar = event.calendar else { return nil }
            let texts = [event.url?.absoluteString, event.location, event.notes].compactMap { $0 }
            let urls = texts.flatMap { text in
                detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
                    .compactMap { $0.url.flatMap(AgendaURLFacts.init(url:)) }
            }
            return AgendaEvent(identifier: event.calendarItemIdentifier, calendarID: calendar.calendarIdentifier,
                title: event.title ?? "", start: start.timeIntervalSince1970, end: end.timeIntervalSince1970,
                isAllDay: event.isAllDay, isCancelled: event.status == .canceled,
                isDeclined: event.attendees?.contains(where: { $0.isCurrentUser && $0.participantStatus == .declined }) ?? false,
                location: event.location, urls: urls,
                hasAttendees: event.attendees?.contains { !$0.isCurrentUser } ?? false)
        }
        try Task.checkCancellation()
        guard authorization == .fullAccess else { throw AgendaFailure.permission }
        return AgendaSnapshot(calendars: calendars.map { .init(id: $0.calendarIdentifier,
            title: $0.title, sourceTitle: $0.source.title, color: Self.color(of: $0)) }, events: events, interval: interval)
    }

    /// 日历颜色按 sRGB 取分量（与 `CodableColor` 的持久化口径一致）；EventKit 没给颜色时为 nil。
    private static func color(of calendar: EKCalendar) -> CodableColor? {
        guard let srgb = calendar.color?.usingColorSpace(.sRGB) else { return nil }
        return CodableColor(red: Double(srgb.redComponent), green: Double(srgb.greenComponent),
                            blue: Double(srgb.blueComponent), opacity: Double(srgb.alphaComponent))
    }

    func observeChanges(_ receive: @escaping @MainActor @Sendable () -> Void) {
        guard observers.isEmpty else { return }
        // EventKit changes also report permission changes. Clock/day/wake changes
        // invalidate the native civil-date query, including all-day event projection.
        let sources: [(NotificationCenter, Notification.Name)] = [
            (.default, .EKEventStoreChanged),
            (.default, .NSSystemTimeZoneDidChange),
            (.default, .NSCalendarDayChanged),
            (.default, NSApplication.didBecomeActiveNotification),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification),
        ]
        for (center, name) in sources {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.observers.isEmpty else { return }
                    receive()
                }
            }
            observers.append((center, token))
        }
    }

    func stop() {
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        if let request = accessRequest { cancelAccess(id: request.id) }
        eventStore = nil
    }

    isolated deinit {
        for (center, token) in observers { center.removeObserver(token) }
        accessRequest?.continuation.resume(throwing: CancellationError())
    }
}
