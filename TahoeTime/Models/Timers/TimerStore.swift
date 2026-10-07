// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Darwin
import Foundation
import Observation

nonisolated struct TimerClockFacts: Codable, Equatable, Sendable {
    var wall: Double
    var continuous: Double
    var bootID: String
    private enum CodingKeys: String, CodingKey { case wall, continuous; case bootID = "bootId" }

    private static let bootSession: String = {
        var count = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &count, nil, 0) == 0, count > 1, count < 256 else {
            return UUID().uuidString
        }
        var bytes = [UInt8](repeating: 0, count: count)
        let status = bytes.withUnsafeMutableBytes { sysctlbyname("kern.bootsessionuuid", $0.baseAddress, &count, nil, 0) }
        guard status == 0 else { return UUID().uuidString }
        return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }()

    private static let timebase: (Double, Double) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (Double(info.numer), Double(max(1, info.denom)))
    }()

    static func now() -> Self {
        Self(wall: Date.now.timeIntervalSince1970,
             continuous: Double(mach_continuous_time()) * timebase.0 / timebase.1 / 1_000_000_000,
             bootID: bootSession)
    }
}

nonisolated struct TimerSpec: Codable, Equatable, Sendable {
    var mode = "countdown"
    var label = ""
    var duration: Double = 300
    var focus: Double = 25 * 60
    var shortBreak: Double = 5 * 60
    var longBreak: Double = 15 * 60
    var rounds = 4
    var alarmAt: Double?
    var alarmZone: String?
    var alarmPlace: String?
}

nonisolated struct TimerSession: Codable, Equatable, Sendable {
    let id: String
    let spec: TimerSpec
    let status: String
    let elapsed: Double
    let startedAt: Double
    let continuousAt: Double
    let bootID: String
    /// 已记进账本的专注段数；Rust 一直带着它，这里只是原样带回去。
    let creditedFocus: Int?
    private enum CodingKeys: String, CodingKey {
        case id, spec, status, elapsed, startedAt, continuousAt, creditedFocus
        case bootID = "bootId"
    }
}

/// 番茄钟账本一条：做完的一段专注的结束时刻与秒数（Rust 记账，这里只镜像以便往返）。
nonisolated struct TimerLedgerEntry: Codable, Equatable, Sendable {
    let endedAt: Double
    let seconds: Double
}

nonisolated struct TimerMachineState: Codable, Equatable, Sendable {
    let version: Int
    let notifications: Bool
    let session: TimerSession?
    let ledger: [TimerLedgerEntry]?
}

/// 账本按本机民用日的汇总：`days[0]` 是今天，后面往前数。
nonisolated struct TimerLedgerDay: Decodable, Equatable, Sendable {
    let focusCount: Int
    let focusSeconds: Double
}

nonisolated struct TimerLedgerSummary: Decodable, Equatable, Sendable {
    let days: [TimerLedgerDay]
    let entries: Int
    var today: TimerLedgerDay? { days.first }
    var recentCount: Int { days.reduce(0) { $0 + $1.focusCount } }
}

/// 最近 N 个本机民用日的边界（今天在前），交给 Rust 分桶；日界按本机当前时区。
nonisolated struct TimerDayBounds: Encodable, Sendable {
    let start: Double
    let end: Double

    static func recent(_ count: Int, now: Date, calendar: Calendar = .current) -> [TimerDayBounds] {
        var days: [TimerDayBounds] = []
        var cursor = now
        for _ in 0..<count {
            guard let day = calendar.dateInterval(of: .day, for: cursor) else { break }
            days.append(TimerDayBounds(start: day.start.timeIntervalSince1970, end: day.end.timeIntervalSince1970))
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day.start) else { break }
            cursor = previous
        }
        return days
    }
}

nonisolated struct TimerPresentation: Decodable, Equatable, Sendable {
    let phase: String
    let round: Int
    let rounds: Int
    let seconds: Double
    let display: String
    let canPause: Bool
    let canResume: Bool
    let isRunning: Bool
    let isCompleted: Bool
}

nonisolated struct TimerNotice: Decodable, Sendable {
    let id: String
    let fireAt: Double
    let kind: String
    let round: Int
    let label: String
}

nonisolated private struct TimerResult: Decodable {
    let state: TimerMachineState
    let view: TimerPresentation?
    let notices: [TimerNotice]
    let changed: Bool
    let error: String?
    let recovered: Bool
    let ledger: TimerLedgerSummary?
}


@MainActor @Observable
final class TimerStore {
    static let storageKey = "meantime.timer.v1"
    static let changeNotification = Notification.Name("com.dayside.timer.changed")
    /// 完成提示的单一学习标记，只写进本 store 注入的 defaults：
    /// 值为「本页起跑」、尚未完成会话的会话号；那一场跑到已完成后固定为 true，永不重置。
    static let completionHintKey = "meantime.timer.completion-hint.v1"
    private(set) var state: TimerMachineState
    private(set) var presentation: TimerPresentation?
    /// 番茄钟账本最近 7 天汇总（今天在前），每次与 Rust 往返都刷新。
    private(set) var ledger: TimerLedgerSummary?
    private(set) var error: String?
    private(set) var recovered = false
    /// 底部说明是否仍显示：从计时页跑完一次倒计时/番茄钟/闹钟后永久收起。
    private(set) var showsCompletionHint: Bool
    /// 等待「完成学习」的会话号（completionHintKey 的内存镜像），学会后为 nil。
    @ObservationIgnored private var pageSessionID: String?
    let notifications: ScopedLensNotifications
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let clock: () -> TimerClockFacts
    @ObservationIgnored private let observeSystemEvents: Bool
    @ObservationIgnored private var visible = false
    @ObservationIgnored private var runtimeEnabled: Bool
    @ObservationIgnored private var receivedRuntimeDecision = false
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var tickerToken: UUID?
    @ObservationIgnored private var events: LensSystemEvents?
    @ObservationIgnored private var hourStyle = HourStyle.followSystem
    @ObservationIgnored private var locale = Locale.autoupdatingCurrent
    @ObservationIgnored private var lastStoredData: Data?

    var activeResourceCount: Int { (ticker == nil ? 0 : 1) + (events?.count ?? 0) + notifications.activeResourceCount }

    init(defaults: UserDefaults = Store.appDefaults,
         notificationClient: (any LensNotificationClient)? = nil,
         clock: @escaping () -> TimerClockFacts = TimerClockFacts.now,
         observeSystemEvents: Bool = true, runtimeEnabled: Bool = true) {
        self.defaults = defaults
        self.clock = clock
        self.observeSystemEvents = observeSystemEvents
        self.runtimeEnabled = runtimeEnabled
        let storedHint = defaults.object(forKey: Self.completionHintKey)
        if let learned = storedHint as? Bool, learned {
            showsCompletionHint = false
        } else {
            showsCompletionHint = true
            pageSessionID = storedHint as? String
        }
        let facts = clock()
        let data = defaults.data(forKey: Self.storageKey)
        struct Input: Encodable { let stored: String?; let clock: TimerClockFacts; let days: [TimerDayBounds] }
        let result: TimerResult = RustCore.invoke("timers.load", Input(stored: data.map { String(decoding: $0, as: UTF8.self) }, clock: facts,
                                                                       days: Self.ledgerDays(facts)))
        state = result.state
        presentation = result.view
        ledger = result.ledger
        error = result.error
        recovered = result.recovered
        notifications = ScopedLensNotifications(prefix: "meantime.timer.", client: notificationClient ?? SystemLensNotificationClient(),
                                                now: { Date(timeIntervalSince1970: clock().wall) })
        lastStoredData = data
        if result.recovered, let data { defaults.set(data, forKey: Self.storageKey + ".corrupt-backup") }
        if result.changed || result.recovered { persist() }
        reconcileCompletionHint()
        updateRuntime()
        if runtimeEnabled && (data != nil || state.session != nil) { synchronize(result.notices, force: true) }
    }

    isolated deinit { ticker?.cancel(); events?.invalidate() }

    func configure(zones: [TimeZoneEntry], locale: Locale = .autoupdatingCurrent, hourStyle: HourStyle = .followSystem) {
        self.locale = locale
        self.hourStyle = hourStyle
        if state.session != nil { refresh() }
    }

    func setVisible(_ visible: Bool) {
        self.visible = visible
        if visible { refresh() } else { updateRuntime() }
    }

    /// 暂停原生任务时保留计时器与偏好。
    func setRuntimeEnabled(_ enabled: Bool) {
        guard enabled != runtimeEnabled || !receivedRuntimeDecision else { return }
        receivedRuntimeDecision = true
        runtimeEnabled = enabled
        if enabled { refresh() }
        else {
            notifications.cancelAccessRequests()
            // 只清理本功能此前留下的通知。
            if lastStoredData != nil || state.session != nil || state.notifications {
                notifications.setPlan([], force: true)
            }
            updateRuntime()
        }
    }

    func start(_ spec: TimerSpec) { send(kind: "start", spec: spec) }

    /// 计时页专用的开始入口：这一场倒计时/番茄钟/闹钟跑到「已完成」后收起底部说明。
    /// 秒表与外部（联系人/自动化）发起的开始仍走 `start`，不会学习。
    func startFromTimersPage(_ spec: TimerSpec) {
        let replaced = state.session?.id
        send(kind: "start", spec: spec)
        guard showsCompletionHint, ["countdown", "pomodoro", "alarm"].contains(spec.mode),
              let session = state.session, session.id != replaced else { return }
        pageSessionID = session.id
        defaults.set(session.id, forKey: Self.completionHintKey)
    }

    func pause() { send(kind: "pause") }
    func resume() { send(kind: "resume") }
    func restart() { send(kind: "restart") }
    func cancel() { send(kind: "cancel", clearDelivered: true) }
    func refresh() { send(kind: "refresh") }

    func setNotificationsEnabled(_ enabled: Bool) {
        if !enabled { notifications.cancelAccessRequests() }
        send(kind: "notifications", enabled: enabled, clearDelivered: !enabled)
    }

    /// Call only from an explicit user action. Loading persisted state never prompts.
    func requestNotificationPermission() async {
        guard runtimeEnabled else { return }
        setNotificationsEnabled(true)
        guard await notifications.requestAccess() else { return }
        if state.notifications { refresh() }
    }

    func reloadFromDefaults() {
        let data = defaults.data(forKey: Self.storageKey)
        guard data != lastStoredData else { refresh(); return }
        struct Input: Encodable { let stored: String?; let clock: TimerClockFacts; let days: [TimerDayBounds] }
        let facts = clock()
        let result: TimerResult = RustCore.invoke("timers.load", Input(stored: data.map { String(decoding: $0, as: UTF8.self) }, clock: facts,
                                                                       days: Self.ledgerDays(facts)))
        lastStoredData = data
        if result.recovered, let data { defaults.set(data, forKey: Self.storageKey + ".corrupt-backup") }
        apply(result, synchronize: true)
    }

    func deactivate() async {
        let previousTicker = ticker
        notifications.cancelAccessRequests()
        send(kind: "deactivate", clearDelivered: true)
        await previousTicker?.value
        await notifications.waitUntilSettled()
    }

    func waitUntilSettled() async {
        if let ticker, ticker.isCancelled { await ticker.value }
        await notifications.waitUntilSettled()
    }

    private func send(kind: String, spec: TimerSpec? = nil, enabled: Bool? = nil,
                      synchronize: Bool = true, clearDelivered: Bool = false) {
        struct Event: Encodable { let kind: String; let spec: TimerSpec?; let enabled: Bool? }
        struct Input: Encodable { let state: TimerMachineState; let clock: TimerClockFacts; let event: Event; let days: [TimerDayBounds] }
        let facts = clock()
        let result: TimerResult = RustCore.invoke("timers.reduce", Input(state: state, clock: facts, event: Event(kind: kind, spec: spec, enabled: enabled),
                                                                         days: Self.ledgerDays(facts)))
        apply(result, synchronize: synchronize || result.changed, clearDelivered: clearDelivered)
    }

    private static func ledgerDays(_ facts: TimerClockFacts) -> [TimerDayBounds] {
        TimerDayBounds.recent(7, now: Date(timeIntervalSince1970: facts.wall))
    }

    private func apply(_ result: TimerResult, synchronize: Bool, clearDelivered: Bool = false) {
        state = result.state
        presentation = result.view
        ledger = result.ledger
        error = result.error
        recovered = recovered || result.recovered
        reconcileCompletionHint()
        if result.changed || result.recovered { persist() }
        updateRuntime()
        if synchronize { self.synchronize(result.notices, clearDelivered: clearDelivered) }
    }

    /// 只认 `presentation.isCompleted`，且会话号必须仍是待完成的那一场；换了会话
    /// （取消、被外部开始替换）就作废标记。学会即在返回前写入 defaults，
    /// 之后的取消/新开始/重启都不会恢复。
    private func reconcileCompletionHint() {
        guard let pending = pageSessionID else { return }
        guard let session = state.session, session.id == pending else {
            pageSessionID = nil
            defaults.removeObject(forKey: Self.completionHintKey)
            return
        }
        guard presentation?.isCompleted == true else { return }
        pageSessionID = nil
        showsCompletionHint = false
        defaults.set(true, forKey: Self.completionHintKey)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(state), data != lastStoredData else { return }
        defaults.set(data, forKey: Self.storageKey)
        lastStoredData = data
        if observeSystemEvents {
            DistributedNotificationCenter.default().postNotificationName(Self.changeNotification, object: nil, userInfo: nil, deliverImmediately: true)
        }
    }

    private func synchronize(_ notices: [TimerNotice], clearDelivered: Bool = false, force: Bool = false) {
        guard runtimeEnabled else { return }
        let requests = notices.map { notice in
            let key = switch notice.kind {
            case "focus": "开始下一轮专注"
            case "shortBreak", "longBreak": "该休息了"
            case "completed": "番茄钟已完成"
            case "alarm": "闹钟时间到了"
            default: "倒计时已结束"
            }
            return LensNotificationRequest(id: notice.id, fireAt: Date(timeIntervalSince1970: notice.fireAt),
                                           title: L10n.string(key, locale: locale),
                                           body: Self.noticeBody(notice, spec: state.session?.spec, hourStyle: hourStyle, locale: locale))
        }
        notifications.setPlan(requests, clearDelivered: clearDelivered, force: force)
    }

    static func noticeBody(_ notice: TimerNotice, spec: TimerSpec?, hourStyle: HourStyle, locale: Locale,
                           system: Locale = .current) -> String {
        guard notice.kind == "alarm", let spec, let identifier = spec.alarmZone,
              let zone = TimeZone(identifier: identifier) else { return notice.label }
        let clock = ClockText.time(Date(timeIntervalSince1970: notice.fireAt), in: zone, hourStyle: hourStyle,
                                   system: hourStyle == .followSystem ? system : locale)
        let place = spec.alarmPlace ?? ""
        return [notice.label, [place, clock].filter { !$0.isEmpty }.joined(separator: " ")]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func updateRuntime() {
        let running = runtimeEnabled && presentation?.isRunning == true
        if running && observeSystemEvents && events == nil {
            events = LensSystemEvents(changeName: Self.changeNotification) { [weak self] in self?.reloadFromDefaults() }
        } else if !running { events?.invalidate(); events = nil }
        if visible && running && ticker == nil {
            let token = UUID()
            tickerToken = token
            ticker = Task { [weak self] in
                defer { self?.tickerFinished(token) }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { break }
                    guard let self, !Task.isCancelled else { break }
                    send(kind: "refresh", synchronize: false)
                }
            }
        } else if !visible || !running { ticker?.cancel() }
    }

    private func tickerFinished(_ token: UUID) {
        guard tickerToken == token else { return }
        ticker = nil
        tickerToken = nil
        // The MainActor task has no suspension after this cleanup, so observers
        // cannot see an empty handle before the cancelled task returns.
        updateRuntime()
    }
}
