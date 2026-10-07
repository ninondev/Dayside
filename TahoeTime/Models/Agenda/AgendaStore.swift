// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AgendaStore {
    enum State: Equatable {
        case disabled, inactive, permission(AgendaAuthorization), loading, ready, failed(AgendaFailure)
    }

    static let preferencesKey = "meantime.agenda.preferences.v1"

    private(set) var preferences: AgendaPreferences
    private(set) var state: State = .disabled
    private(set) var isActive = false
    private(set) var isRequestingAccess = false
    private(set) var isJoining = false
    private(set) var joinFailure: AgendaFailure?
    private(set) var didOpenMeeting = false
    private(set) var snapshot: AgendaSnapshot?
    private(set) var snapshotRevision = UUID()
    private(set) var daySnapshot: AgendaSnapshot?
    /// Five weeks of occurrences for the clock-change drift check; read-only, never shown as the list.
    private(set) var driftSnapshot: AgendaSnapshot?
    private(set) var calendars: [AgendaCalendar] = []
    /// Canceled work remains owned and counted until its task body acknowledges exit.
    private var jobs: [UUID: Task<Void, Never>] = [:]

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var preferencesDidChange: (@MainActor () -> Void)?
    @ObservationIgnored private let makeService: @MainActor () -> any AgendaService
    @ObservationIgnored private let dateProvider: @MainActor () -> Date
    @ObservationIgnored private let timeZoneProvider: @MainActor () -> TimeZone
    @ObservationIgnored private let openURL: @MainActor (URL) -> Bool
    @ObservationIgnored private var service: (any AgendaService)?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var driftTask: Task<Void, Never>?
    @ObservationIgnored private var driftRequestID = UUID()
    @ObservationIgnored private var dayTask: Task<Void, Never>?
    @ObservationIgnored private var dayRequestID = UUID()
    @ObservationIgnored private var daySnapshotRefreshID: UUID?
    @ObservationIgnored private var requestedDayInterval: DateInterval?
    @ObservationIgnored private var viewedDay: Date?
    @ObservationIgnored private var permissionTask: Task<Void, Never>?
    @ObservationIgnored private var joinTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var refreshID = UUID()
    @ObservationIgnored private var joinID = UUID()

    init(defaults: UserDefaults = Store.appDefaults,
         makeService: @escaping @MainActor () -> any AgendaService = { EventKitAgendaService() },
         now: @escaping @MainActor () -> Date = { .now },
         timeZone: @escaping @MainActor () -> TimeZone = { .autoupdatingCurrent },
         openURL: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.defaults = defaults
        self.makeService = makeService
        dateProvider = now
        timeZoneProvider = timeZone
        self.openURL = openURL
        let encoded = defaults.data(forKey: Self.preferencesKey)
        let stored = encoded.flatMap { try? JSONDecoder().decode(CoreJSON.self, from: $0) } ?? .null
        preferences = .normalize(stored)
        state = preferences.isEnabled ? .inactive : .disabled
        // 小组件时代留下的键（夜拆掉小组件）：老用户的偏好域里可能还有，顺手清掉。
        defaults.removeObject(forKey: "meantime.agenda.widget.v1")
    }

    static func shouldActivateAtLaunch(defaults: UserDefaults) -> Bool {
        guard let data = defaults.data(forKey: preferencesKey),
              let stored = try? JSONDecoder().decode(CoreJSON.self, from: data) else { return false }
        let preferences = AgendaPreferences.normalize(stored)
        return preferences.isEnabled && preferences.showInMenuBar
    }

    var isEnabled: Bool { preferences.isEnabled }
    var activeResourceCount: Int {
        _ = state
        return (service?.activeResourceCount ?? 0) + jobs.count
    }

    /// Demand is controlled by FeatureHub (tool window / opted-in menu-bar entry).
    /// This never requests permission. The explicit UI action does that separately.
    func activate() {
        isActive = true
        guard isEnabled else { state = .disabled; return }
        guard service == nil else { refresh(); return }
        service = makeService()
        refresh()
    }

    func deactivate() {
        isActive = false
        stopResources()
        viewedDay = nil
        state = isEnabled ? .inactive : .disabled
    }

    func waitUntilSettled() async {
        while !jobs.isEmpty {
            let pending = Array(jobs.values)
            for task in pending { await task.value }
        }
    }

    func deactivateAndWait() async {
        deactivate()
        await waitUntilSettled()
    }

    private func stopResources() {
        generation = UUID()
        for task in jobs.values { task.cancel() }
        refreshTask?.cancel(); refreshTask = nil
        permissionTask?.cancel(); permissionTask = nil
        driftTask?.cancel(); driftTask = nil
        driftRequestID = UUID()
        dayTask?.cancel(); dayTask = nil
        dayRequestID = UUID()
        requestedDayInterval = nil
        joinTask?.cancel(); joinTask = nil
        service?.stop(); service = nil
        isRequestingAccess = false
        isJoining = false
        snapshot = nil
        daySnapshot = nil
        daySnapshotRefreshID = nil
        driftSnapshot = nil
        calendars = []
        joinFailure = nil
        didOpenMeeting = false
    }

    func setEnabled(_ enabled: Bool) {
        apply(.object(["type": .string("enabled"), "value": .bool(enabled)]))
        if !enabled {
            stopResources()
            state = .disabled
        } else if isActive {
            if service == nil { service = makeService() }
            requestAccess()
        } else { state = .inactive }
    }

    func setMenuBarEnabled(_ enabled: Bool) {
        apply(.object(["type": .string("menuBar"), "value": .bool(enabled)]))
    }

    func setDays(_ days: Int) {
        apply(.object(["type": .string("days"), "value": .integer(Int64(days))]))
    }

    func includesCalendar(_ id: String) -> Bool {
        preferences.selectedCalendarIDs?.contains(id) ?? true
    }

    func setCalendar(_ id: String, included: Bool) {
        apply(.object(["type": .string("calendar"), "id": .string(id), "included": .bool(included),
            "allIDs": .array(calendars.map { .string($0.id) })]))
        refresh()
    }

    func selectAllCalendars() {
        apply(.object(["type": .string("allCalendars")]))
        refresh()
    }

    func selectNoCalendars() {
        apply(.object(["type": .string("noCalendars")]))
        refresh()
    }

    private func apply(_ action: CoreJSON) {
        preferences = preferences.applying(action)
        // Encodable value DTOs cannot contain invalid JSON values.
        guard let data = try? JSONEncoder().encode(preferences) else { preconditionFailure("Invalid agenda preferences DTO") }
        defaults.set(data, forKey: Self.preferencesKey)
        preferencesDidChange?()
    }

    /// Called only by an explicit enable/request button, including write-only upgrades.
    func requestAccess() {
        guard isActive, isEnabled, !isRequestingAccess else { return }
        if service == nil { service = makeService() }
        guard let service else { return }
        switch service.authorization {
        case .fullAccess: refresh(); return
        case .denied, .restricted: showPermission(service.authorization); return
        case .notDetermined, .writeOnly: break
        }
        let token = generation
        isRequestingAccess = true
        state = .permission(service.authorization)
        let jobID = UUID()
        let task = Task { [weak self] in
            defer { self?.jobs.removeValue(forKey: jobID) }
            do {
                let granted = try await service.requestFullAccess()
                guard let self, self.generation == token, !Task.isCancelled, self.isActive, self.isEnabled else { return }
                self.permissionTask = nil
                self.isRequestingAccess = false
                if granted && service.authorization == .fullAccess { self.refresh() }
                else { self.showPermission(service.authorization) }
            } catch {
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.permissionTask = nil
                self.isRequestingAccess = false
                self.stopResources()
                self.state = .failed(.permission)
            }
        }
        permissionTask = task
        jobs[jobID] = task
    }

    func refresh() {
        guard isActive, isEnabled, !isRequestingAccess else { return }
        if service == nil { service = makeService() }
        guard let service else { return }
        guard service.authorization == .fullAccess else { showPermission(service.authorization); return }
        service.observeChanges { [weak self] in self?.refresh() }
        refreshTask?.cancel()
        driftTask?.cancel(); driftTask = nil
        driftRequestID = UUID()
        joinTask?.cancel(); joinTask = nil
        joinID = UUID()
        isJoining = false
        let token = generation
        let requestID = UUID()
        refreshID = requestID
        let interval = queryInterval(now: dateProvider())
        let calendarIDs = preferences.selectedCalendarIDs
        dayTask?.cancel(); dayTask = nil
        dayRequestID = UUID()
        requestedDayInterval = nil
        // 旧的远日期只供当前页面刷新时继续显示，离开它后不能再拿来当新数据。
        let keepsRemoteSnapshot: Bool
        if let day = viewedDayInterval(), let daySnapshot {
            keepsRemoteSnapshot = covers(daySnapshot, day) && !(interval.start <= day.start && interval.end >= day.end)
        } else { keepsRemoteSnapshot = false }
        if !keepsRemoteSnapshot {
            daySnapshot = nil
            daySnapshotRefreshID = nil
        }
        let hasVisibleSnapshot = snapshot?.interval == interval || coveringDaySnapshot() != nil
        state = hasVisibleSnapshot ? .ready : .loading
        let jobID = UUID()
        let task = Task { [weak self] in
            defer { self?.jobs.removeValue(forKey: jobID) }
            do {
                let result = try await service.snapshot(in: interval, calendarIDs: calendarIDs)
                guard let self, self.generation == token, self.refreshID == requestID, !Task.isCancelled,
                      self.isActive, self.isEnabled else { return }
                self.refreshTask = nil
                guard service.authorization == .fullAccess else { self.showPermission(service.authorization); return }
                self.snapshot = result
                self.calendars = result.calendars
                self.state = .ready
                self.snapshotRevision = UUID()
            } catch {
                guard let self, self.generation == token, self.refreshID == requestID, !Task.isCancelled else { return }
                self.refreshTask = nil
                if service.authorization != .fullAccess { self.showPermission(service.authorization) }
                else { self.snapshot = nil; self.daySnapshot = nil; self.driftSnapshot = nil; self.state = .failed(.read) }
            }
        }
        refreshTask = task
        jobs[jobID] = task
        refreshViewedDay(force: true)
    }

    private func showPermission(_ authorization: AgendaAuthorization) {
        stopResources()
        state = .permission(authorization)
    }

    private func queryInterval(now: Date) -> DateInterval {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZoneProvider()
        let start = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: 7, to: start) else {
            preconditionFailure("System Calendar failed to form agenda date interval")
        }
        return DateInterval(start: start, end: end)
    }

    // 看别的日期时只保留一份额外快照；当前七天内直接复用菜单栏的快照。
    func setViewedDay(_ day: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZoneProvider()
        let start = calendar.startOfDay(for: day)
        guard viewedDay != start else { return }
        viewedDay = start
        dayTask?.cancel(); dayTask = nil
        dayRequestID = UUID()
        requestedDayInterval = nil
        if daySnapshotRefreshID != refreshID {
            daySnapshot = nil
            daySnapshotRefreshID = nil
        }
        refreshViewedDay(force: false)
    }

    private func viewedDayInterval() -> DateInterval? {
        guard let viewedDay else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZoneProvider()
        let start = calendar.startOfDay(for: viewedDay)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        return DateInterval(start: start, end: end)
    }

    private func covers(_ snapshot: AgendaSnapshot, _ interval: DateInterval) -> Bool {
        snapshot.interval.start <= interval.start && snapshot.interval.end >= interval.end
    }

    private func coveringDaySnapshot() -> AgendaSnapshot? {
        guard let interval = viewedDayInterval() else { return nil }
        if let snapshot, covers(snapshot, interval) { return snapshot }
        if let daySnapshot, covers(daySnapshot, interval) { return daySnapshot }
        return nil
    }

    private func refreshViewedDay(force: Bool) {
        guard isActive, isEnabled, let service, service.authorization == .fullAccess,
              let day = viewedDayInterval() else { return }
        let upcoming = queryInterval(now: dateProvider())
        if upcoming.start <= day.start && upcoming.end >= day.end {
            dayTask?.cancel(); dayTask = nil
            dayRequestID = UUID()
            requestedDayInterval = nil
            return
        }
        if !force, daySnapshotRefreshID == refreshID, let daySnapshot, covers(daySnapshot, day) { return }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZoneProvider()
        guard let end = calendar.date(byAdding: .day, value: 7, to: day.start) else { return }
        let interval = DateInterval(start: day.start, end: end)
        guard force || requestedDayInterval != interval else { return }
        dayTask?.cancel()
        let requestID = UUID()
        dayRequestID = requestID
        requestedDayInterval = interval
        let token = generation
        let listID = refreshID
        let calendarIDs = preferences.selectedCalendarIDs
        if coveringDaySnapshot() == nil && snapshot == nil { state = .loading }
        let jobID = UUID()
        let task = Task { [weak self] in
            defer { self?.jobs.removeValue(forKey: jobID) }
            do {
                let result = try await service.snapshot(in: interval, calendarIDs: calendarIDs)
                guard let self, self.generation == token, self.refreshID == listID,
                      self.dayRequestID == requestID, !Task.isCancelled, self.isActive, self.isEnabled else { return }
                self.dayTask = nil
                self.requestedDayInterval = nil
                guard service.authorization == .fullAccess else { self.showPermission(service.authorization); return }
                self.daySnapshot = result
                self.daySnapshotRefreshID = listID
                self.calendars = result.calendars
                self.state = .ready
            } catch {
                guard let self, self.generation == token, self.refreshID == listID,
                      self.dayRequestID == requestID, !Task.isCancelled else { return }
                self.dayTask = nil
                self.requestedDayInterval = nil
                if service.authorization != .fullAccess { self.showPermission(service.authorization) }
                else { self.state = .failed(.read) }
            }
        }
        dayTask = task
        jobs[jobID] = task
    }

    func day(dayStart: Date, dayEnd: Date, anchor: Date, now: Date) -> AgendaDay? {
        guard isActive, isEnabled, state == .ready else { return nil }
        let interval = DateInterval(start: dayStart, end: dayEnd)
        let source: AgendaSnapshot?
        if let snapshot, covers(snapshot, interval) { source = snapshot }
        else if let daySnapshot, covers(daySnapshot, interval) { source = daySnapshot }
        else { source = nil }
        return source?.day(preferences: preferences, dayStart: dayStart, dayEnd: dayEnd, anchor: anchor, now: now)
    }

    /// Five weeks of occurrences for the clock-change drift check, read on request by the agenda page
    /// once the list is ready; a failure here never touches the list or its state.
    func refreshDrift() {
        guard isActive, isEnabled, state == .ready, let service, service.authorization == .fullAccess else { return }
        driftTask?.cancel()
        let requestID = UUID()
        driftRequestID = requestID
        let token = generation
        let listID = refreshID
        let interval = driftInterval(now: dateProvider())
        let calendarIDs = preferences.selectedCalendarIDs
        let jobID = UUID()
        let task = Task { [weak self] in
            defer {
                self?.jobs.removeValue(forKey: jobID)
                if self?.driftRequestID == requestID { self?.driftTask = nil }
            }
            guard let occurrences = try? await service.snapshot(in: interval, calendarIDs: calendarIDs),
                  let self, self.generation == token, self.refreshID == listID,
                  self.driftRequestID == requestID, !Task.isCancelled,
                  self.isActive, self.isEnabled else { return }
            self.driftSnapshot = occurrences
        }
        driftTask = task
        jobs[jobID] = task
    }

    private func driftInterval(now: Date) -> DateInterval {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZoneProvider()
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: AgendaDrift.lookaheadDays, to: start) ?? start.addingTimeInterval(Double(AgendaDrift.lookaheadDays) * 86_400)
        return DateInterval(start: start, end: end)
    }

    func evaluation(now: Date) -> AgendaEvaluation {
        guard isActive, isEnabled, state == .ready, let snapshot else { return .empty }
        return snapshot.evaluate(preferences: preferences, now: now)
    }

    func nextMeeting(now: Date) -> AgendaMeeting? { evaluation(now: now).nextMeeting }
    func menuBarMeeting(now: Date) -> AgendaMeeting? { evaluation(now: now).menuBarMeeting }

    /// Reuses the host clock. No additional polling timer is installed by this lens.
    func clockDidChange(now: Date) {
        guard isActive, isEnabled else { return }
        if let service, service.authorization != .fullAccess, !isRequestingAccess {
            showPermission(service.authorization)
        } else if let snapshot, snapshot.interval != queryInterval(now: now) {
            refresh()
        }
    }

    /// Re-read before opening so deleted, declined, filtered, or edited events cannot
    /// keep launching a stale URL from an old rendered row.
    func joinMeeting(id: String, locale: Locale = .current) {
        guard isActive, isEnabled, !isJoining, let service, service.authorization == .fullAccess else { return }
        let token = generation
        let requestID = UUID()
        joinID = requestID
        refreshTask?.cancel(); refreshTask = nil
        refreshID = UUID()
        driftTask?.cancel(); driftTask = nil
        driftRequestID = UUID()
        dayTask?.cancel(); dayTask = nil
        dayRequestID = UUID()
        requestedDayInterval = nil
        let upcoming = queryInterval(now: dateProvider())
        let interval: DateInterval
        if let daySnapshot, daySnapshot.evaluate(preferences: preferences, now: dateProvider()).events.contains(where: { $0.id == id }) {
            interval = daySnapshot.interval
        } else { interval = upcoming }
        let calendarIDs = preferences.selectedCalendarIDs
        isJoining = true
        joinFailure = nil
        didOpenMeeting = false
        let jobID = UUID()
        let task = Task { [weak self] in
            defer { self?.jobs.removeValue(forKey: jobID) }
            do {
                let fresh = try await service.snapshot(in: interval, calendarIDs: calendarIDs)
                guard let self, self.generation == token, self.joinID == requestID, !Task.isCancelled,
                      self.isActive, self.isEnabled else { return }
                self.joinTask = nil
                self.isJoining = false
                guard service.authorization == .fullAccess else { self.showPermission(service.authorization); return }
                if fresh.interval == self.queryInterval(now: self.dateProvider()) { self.snapshot = fresh }
                else { self.daySnapshot = fresh; self.daySnapshotRefreshID = self.refreshID }
                self.calendars = fresh.calendars
                self.state = .ready
                self.snapshotRevision = UUID()
                let evaluated = fresh.evaluate(preferences: self.preferences, now: self.dateProvider())
                guard let event = evaluated.events.first(where: { $0.id == id }) else {
                    self.joinFailure = .eventUnavailable; return
                }
                guard let link = event.meetingLink, let url = URL(string: link.url) else {
                    self.joinFailure = .meetingLinkUnavailable; return
                }
                self.didOpenMeeting = self.openURL(url)
                if self.didOpenMeeting {
                    NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
                        userInfo: [.announcement: L10n.string("已打开会议链接。", locale: locale), .priority: NSAccessibilityPriorityLevel.high.rawValue])
                } else { self.joinFailure = .open }
            } catch {
                guard let self, self.generation == token, self.joinID == requestID, !Task.isCancelled else { return }
                self.joinTask = nil
                self.isJoining = false
                if service.authorization != .fullAccess { self.showPermission(service.authorization) }
                else { self.joinFailure = .read }
            }
        }
        joinTask = task
        jobs[jobID] = task
    }

    func openCalendarPrivacySettings() {
        if let pane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"), openURL(pane) { return }
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") else { return }
        _ = openURL(app)
    }

    func openCalendarApp() {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") else { return }
        _ = openURL(app)
    }

    isolated deinit {
        for task in jobs.values { task.cancel() }
        refreshTask?.cancel()
        driftTask?.cancel()
        dayTask?.cancel()
        permissionTask?.cancel()
        joinTask?.cancel()
        service?.stop()
    }
}
