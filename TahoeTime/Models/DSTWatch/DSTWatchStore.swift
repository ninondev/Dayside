// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Observation

nonisolated struct DSTTransitionFact: Codable, Equatable, Sendable {
    let zone: String
    let transitionAt: Double
    let before: Int
    let after: Int

    static func systemFacts(zones: [String], now: Date) -> [Self] {
        let end = now.addingTimeInterval(400 * 86400)
        var result: [Self] = []
        for identifier in Set(zones).sorted() {
            guard let zone = TimeZone(identifier: identifier) else { continue }
            var cursor = now
            // A bounded snapshot of system facts; no private timezone database.
            for _ in 0..<16 {
                guard let transition = zone.nextDaylightSavingTimeTransition(after: cursor),
                      transition > cursor, transition <= end else { break }
                let before = zone.secondsFromGMT(for: transition.addingTimeInterval(-1))
                let after = zone.secondsFromGMT(for: transition)
                // 偏移没变只翻 isDST 的转换不算换钟（摩洛哥斋月）。
                if before != after {
                    result.append(Self(zone: identifier, transitionAt: transition.timeIntervalSince1970,
                                       before: before, after: after))
                }
                cursor = transition
            }
        }
        return result
    }
}

nonisolated struct DSTScheduleReceipt: Codable, Equatable, Sendable {
    let id: String
    let fireAt: Double
    let transitionAt: Double
}

nonisolated struct DSTWatchState: Codable, Equatable, Sendable {
    let version: Int
    let enabled: Bool
    let leadSeconds: Int
    let receipts: [DSTScheduleReceipt]
}

nonisolated struct DSTWatchEvent: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let zone: String
    let transitionAt: Double
    let before: Int
    let after: Int
    let shift: Int
    let beforeLabel: String
    let afterLabel: String
    let fireAt: Double
    let alreadyScheduled: Bool
}

nonisolated private struct DSTWatchResult: Decodable {
    let state: DSTWatchState
    let upcoming: [DSTWatchEvent]
    let notices: [DSTWatchEvent]
    let nextCheck: Double?
    let changed: Bool
    let recovered: Bool
    let error: String?
    let noticeLimit: Int
}

@MainActor @Observable
final class DSTWatchStore {
    static let storageKey = "meantime.dstwatch.v1"
    static let changeNotification = Notification.Name("com.dayside.dstwatch.changed")
    private(set) var state: DSTWatchState
    private(set) var upcoming: [DSTWatchEvent] = []
    private(set) var error: String?
    private(set) var recovered = false
    private(set) var noticeLimit = 32
    let notifications: ScopedLensNotifications
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let factsProvider: ([String], Date) -> [DSTTransitionFact]
    @ObservationIgnored private let observeSystemEvents: Bool
    @ObservationIgnored private var zones: [String] = []
    @ObservationIgnored private var names: [String: String] = [:]
    @ObservationIgnored private var locale = Locale.autoupdatingCurrent
    /// 通知正文里的钟点按设置的小时制（ClockText），与页面上的「当地时间 …」同一写法。
    @ObservationIgnored private var hourStyle = HourStyle.followSystem
    @ObservationIgnored private var facts: [DSTTransitionFact] = []
    @ObservationIgnored private var dailyTask: Task<Void, Never>?
    @ObservationIgnored private var accessTask: Task<Void, Never>?
    @ObservationIgnored private var dailyToken: UUID?
    @ObservationIgnored private var accessToken: UUID?
    @ObservationIgnored private var needsInitialCleanup = false
    @ObservationIgnored private var events: LensSystemEvents?
    @ObservationIgnored private var lastStoredData: Data?

    var activeResourceCount: Int {
        (dailyTask == nil ? 0 : 1) + (accessTask == nil ? 0 : 1) + (events?.count ?? 0) + notifications.activeResourceCount
    }

    init(defaults: UserDefaults = Store.appDefaults,
         notificationClient: (any LensNotificationClient)? = nil,
         now: @escaping () -> Date = Date.init,
         factsProvider: @escaping ([String], Date) -> [DSTTransitionFact] = DSTTransitionFact.systemFacts,
         observeSystemEvents: Bool = true) {
        self.defaults = defaults
        self.now = now
        self.factsProvider = factsProvider
        self.observeSystemEvents = observeSystemEvents
        let data = defaults.data(forKey: Self.storageKey)
        struct Input: Encodable { let stored: String?; let now: Double; let facts: [DSTTransitionFact]; let authorized: Bool }
        let result: DSTWatchResult = RustCore.invoke("dstwatch.load", Input(stored: data.map { String(decoding: $0, as: UTF8.self) },
                                                                          now: now().timeIntervalSince1970, facts: [], authorized: false))
        state = result.state
        recovered = result.recovered
        error = result.error
        notifications = ScopedLensNotifications(prefix: "meantime.dst.", client: notificationClient ?? SystemLensNotificationClient(), now: now)
        lastStoredData = data
        needsInitialCleanup = data != nil
        notifications.didSchedule = { [weak self] request in
            guard let self, let event = upcoming.first(where: { $0.id == request.id }) else { return }
            send(kind: "scheduled", receipt: DSTScheduleReceipt(id: request.id,
                                                                fireAt: request.fireAt.timeIntervalSince1970,
                                                                transitionAt: event.transitionAt))
        }
        if result.recovered, let data { defaults.set(data, forKey: Self.storageKey + ".corrupt-backup") }
        if result.changed || result.recovered { persist() }
        updateRuntime()
        // FeatureHub supplies the saved zones immediately after construction.
        // Wait for that snapshot before replacing existing scheduled requests.
    }

    isolated deinit { dailyTask?.cancel(); accessTask?.cancel(); events?.invalidate() }

    func configure(zones: [TimeZoneEntry], locale: Locale = .autoupdatingCurrent, displayNames: [String: String] = [:],
                   hourStyle: HourStyle = .followSystem) {
        self.zones = Array(Set(zones.map { $0.timeZone.identifier })).sorted()
        self.names = Dictionary(zones.map { ($0.timeZone.identifier, $0.customName ?? $0.cityName) }, uniquingKeysWith: { first, _ in first })
            .merging(displayNames, uniquingKeysWith: { _, new in new })
        self.locale = locale
        self.hourStyle = hourStyle
        if state.enabled { refresh() }
        else if needsInitialCleanup {
            needsInitialCleanup = false
            notifications.setPlan([], force: true)
        }
    }

    /// Permission is a separate explicit user action; the switch also enables the predictions UI.
    func setEnabled(_ enabled: Bool) {
        if !enabled { notifications.cancelAccessRequests() }
        if enabled { facts = factsProvider(zones, now()) }
        send(kind: "enable", enabled: enabled, clearDelivered: !enabled)
        if enabled { refreshAuthorization() }
    }

    func setLeadSeconds(_ seconds: Int) { send(kind: "lead", seconds: seconds) }

    func refresh() {
        guard state.enabled else { return }
        facts = factsProvider(zones, now())
        send(kind: "refresh")
        refreshAuthorization()
    }

    func requestNotificationPermission() async {
        if !state.enabled { setEnabled(true) }
        guard await notifications.requestAccess() else { return }
        if state.enabled { send(kind: "refresh") }
    }

    func reloadFromDefaults() {
        let data = defaults.data(forKey: Self.storageKey)
        guard data != lastStoredData else { refresh(); return }
        struct Input: Encodable { let stored: String?; let now: Double; let facts: [DSTTransitionFact]; let authorized: Bool }
        let result: DSTWatchResult = RustCore.invoke("dstwatch.load", Input(stored: data.map { String(decoding: $0, as: UTF8.self) },
                                                                          now: now().timeIntervalSince1970, facts: facts,
                                                                          authorized: notifications.access == .authorized))
        lastStoredData = data
        if result.recovered, let data { defaults.set(data, forKey: Self.storageKey + ".corrupt-backup") }
        apply(result, clearDelivered: !result.state.enabled)
        if state.enabled { refresh() }
    }

    func deactivate() async {
        let oldDaily = dailyTask
        let oldAccess = accessTask
        notifications.cancelAccessRequests()
        send(kind: "deactivate", clearDelivered: true)
        await oldDaily?.value
        await oldAccess?.value
        await notifications.waitUntilSettled()
    }

    func waitUntilSettled() async {
        if let accessTask { await accessTask.value }
        if let dailyTask, dailyTask.isCancelled { await dailyTask.value }
        await notifications.waitUntilSettled()
    }

    func displayName(for event: DSTWatchEvent) -> String { names[event.zone] ?? event.zone }

    private func refreshAuthorization() {
        guard state.enabled, accessTask == nil else { return }
        let token = UUID()
        accessToken = token
        accessTask = Task { [weak self] in
            guard let self else { return }
            defer { accessFinished(token, cancelled: Task.isCancelled) }
            guard await notifications.refreshAccess() else { return }
            if !Task.isCancelled && state.enabled { send(kind: "refresh") }
        }
    }

    private func accessFinished(_ token: UUID, cancelled: Bool) {
        guard accessToken == token else { return }
        accessTask = nil
        accessToken = nil
        if cancelled && state.enabled { refreshAuthorization() }
    }

    private func send(kind: String, enabled: Bool? = nil, seconds: Int? = nil,
                      receipt: DSTScheduleReceipt? = nil, clearDelivered: Bool = false) {
        struct Event: Encodable { let kind: String; let enabled: Bool?; let seconds: Int?; let receipt: DSTScheduleReceipt? }
        struct Input: Encodable { let state: DSTWatchState; let now: Double; let facts: [DSTTransitionFact]; let authorized: Bool; let event: Event }
        let result: DSTWatchResult = RustCore.invoke("dstwatch.reduce", Input(state: state, now: now().timeIntervalSince1970,
                                                                            facts: facts, authorized: notifications.access == .authorized,
                                                                            event: Event(kind: kind, enabled: enabled, seconds: seconds, receipt: receipt)))
        apply(result, clearDelivered: clearDelivered)
    }

    private func apply(_ result: DSTWatchResult, clearDelivered: Bool = false) {
        state = result.state
        upcoming = result.upcoming
        error = result.error
        recovered = recovered || result.recovered
        noticeLimit = result.noticeLimit
        if result.changed || result.recovered { persist() }
        updateRuntime()
        let requests = result.notices.map { event in
            // 日期按界面语言、钟点按小时制（ClockText）：此前这里自己 new DateFormatter，设置里选了 24 小时，
            // 通知正文照样是「1:00 AM」。
            let date = ClockText.dateTime(Date(timeIntervalSince1970: event.transitionAt), in: TimeZone(identifier: event.zone) ?? .gmt,
                                          hourStyle: hourStyle, locale: locale)
            let body = String(format: L10n.string("%@ 将于当地时间 %@ 调整时钟：%@ → %@。", locale: locale),
                              locale: locale, displayName(for: event), date, event.beforeLabel, event.afterLabel)
            return LensNotificationRequest(id: event.id, fireAt: Date(timeIntervalSince1970: event.fireAt),
                                           title: L10n.string("即将调整时钟", locale: locale), body: body)
        }
        notifications.setPlan(requests, clearDelivered: clearDelivered, force: needsInitialCleanup)
        needsInitialCleanup = false
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(state), data != lastStoredData else { return }
        defaults.set(data, forKey: Self.storageKey)
        lastStoredData = data
        if observeSystemEvents {
            DistributedNotificationCenter.default().postNotificationName(Self.changeNotification, object: nil, userInfo: nil, deliverImmediately: true)
        }
    }

    private func updateRuntime() {
        if state.enabled {
            if observeSystemEvents && events == nil {
                events = LensSystemEvents(changeName: Self.changeNotification) { [weak self] in self?.reloadFromDefaults() }
            }
            if dailyTask == nil {
                let token = UUID()
                dailyToken = token
                dailyTask = Task { [weak self] in
                    defer { self?.dailyFinished(token) }
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(86400)) } catch { break }
                        guard let self, !Task.isCancelled else { break }
                        refresh()
                    }
                }
            }
        } else {
            dailyTask?.cancel()
            accessTask?.cancel()
            events?.invalidate(); events = nil
        }
    }

    private func dailyFinished(_ token: UUID) {
        guard dailyToken == token else { return }
        dailyTask = nil
        dailyToken = nil
        updateRuntime()
    }
}
