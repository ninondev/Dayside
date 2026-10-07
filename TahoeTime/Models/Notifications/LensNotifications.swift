// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Observation
import UserNotifications

nonisolated enum LensNotificationAccess: String, Sendable {
    case notDetermined, denied, authorized
}

nonisolated struct LensNotificationRequest: Equatable, Sendable {
    let id: String
    let fireAt: Date
    let title: String
    let body: String
}

nonisolated private struct NotificationDeadlinePassed: Error {}

/// Injected in tests so no test requests real notification permission.
@MainActor
protocol LensNotificationClient: AnyObject {
    func authorization() async -> LensNotificationAccess
    func requestAuthorization() async throws -> Bool
    func pendingIdentifiers() async -> [String]
    func deliveredIdentifiers() async -> [String]
    func add(_ request: LensNotificationRequest) async throws
    func removePending(_ identifiers: [String])
    func removeDelivered(_ identifiers: [String])
}

@MainActor
final class SystemLensNotificationClient: LensNotificationClient {
    func authorization() async -> LensNotificationAccess {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: .authorized
        case .denied: .denied
        default: .notDetermined
        }
    }

    func requestAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    func pendingIdentifiers() async -> [String] {
        await UNUserNotificationCenter.current().pendingNotificationRequests().map(\.identifier)
    }

    func deliveredIdentifiers() async -> [String] {
        await UNUserNotificationCenter.current().deliveredNotifications().map { $0.request.identifier }
    }

    func add(_ request: LensNotificationRequest) async throws {
        let interval = request.fireAt.timeIntervalSinceNow
        guard interval.isFinite, interval > 0 else { throw NotificationDeadlinePassed() }
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, interval), repeats: false)
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: request.id,
                                                                            content: content, trigger: trigger))
    }

    func removePending(_ identifiers: [String]) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func removeDelivered(_ identifiers: [String]) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}

/// Serializes replacement plans across suspending UserNotifications calls. A late
/// add is removed if the user changed or disabled its plan while it was in flight.
@MainActor @Observable
final class ScopedLensNotifications {
    private(set) var access = LensNotificationAccess.notDetermined
    private(set) var failed = false
    private(set) var pendingAccessCount = 0
    private(set) var workerIsRunning = false
    var activeResourceCount: Int { pendingAccessCount + (workerIsRunning ? 1 : 0) }
    var isWorking: Bool { activeResourceCount > 0 }
    @ObservationIgnored private let client: any LensNotificationClient
    @ObservationIgnored private let prefix: String
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var wanted: [String: LensNotificationRequest] = [:]
    @ObservationIgnored private var applied: [String: LensNotificationRequest] = [:]
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var clearDelivered = false
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var accessTasks: [UUID: Task<Bool, Never>] = [:]
    @ObservationIgnored private var accessGeneration = 0
    @ObservationIgnored var didSchedule: ((LensNotificationRequest) -> Void)?

    init(prefix: String, client: any LensNotificationClient, now: @escaping () -> Date = Date.init) {
        self.prefix = prefix
        self.client = client
        self.now = now
    }

    isolated deinit {
        worker?.cancel()
        for task in accessTasks.values { task.cancel() }
    }

    func setPlan(_ requests: [LensNotificationRequest], clearDelivered: Bool = false, force: Bool = false) {
        let next = Dictionary(requests.filter { $0.id.hasPrefix(prefix) }.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        guard force || failed || wanted != next || clearDelivered else { return }
        wanted = next
        self.clearDelivered = self.clearDelivered || clearDelivered
        revision += 1
        startWorker()
    }

    /// The return value reports whether this request still belongs to the live
    /// lens. Cancellation cannot dismiss a native prompt, so retain its task
    /// until the system acknowledges it and ignore any late result.
    @discardableResult
    func requestAccess() async -> Bool {
        await performAccess(requestPermission: true)
    }

    @discardableResult
    func refreshAccess() async -> Bool {
        await performAccess(requestPermission: false)
    }

    func cancelAccessRequests() {
        accessGeneration += 1
        for task in accessTasks.values { task.cancel() }
    }

    private func performAccess(requestPermission: Bool) async -> Bool {
        guard !Task.isCancelled else { return false }
        let id = UUID()
        let generation = accessGeneration
        let task = Task { @MainActor [self] in
            defer {
                accessTasks[id] = nil
                pendingAccessCount = accessTasks.count
            }
            guard !Task.isCancelled, generation == accessGeneration else { return false }
            if requestPermission {
                do { _ = try await client.requestAuthorization() }
                catch {
                    guard !Task.isCancelled, generation == accessGeneration else { return false }
                    failed = true
                }
                guard !Task.isCancelled, generation == accessGeneration else { return false }
            }
            let result = await client.authorization()
            guard !Task.isCancelled, generation == accessGeneration else { return false }
            access = result
            if requestPermission {
                revision += 1
                startWorker()
            }
            return true
        }
        accessTasks[id] = task
        pendingAccessCount = accessTasks.count
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func waitUntilSettled() async {
        while !accessTasks.isEmpty || worker != nil {
            for task in Array(accessTasks.values) { _ = await task.value }
            if let current = worker { await current.value }
        }
    }

    private func startWorker() {
        guard worker == nil else { return }
        workerIsRunning = true
        worker = Task { [weak self] in
            guard let self else { return }
            await synchronize()
            worker = nil
            workerIsRunning = false
        }
    }

    private func synchronize() async {
        while !Task.isCancelled {
            let generation = revision
            let snapshot = wanted
            let pending = await client.pendingIdentifiers().filter { $0.hasPrefix(prefix) }
            guard !Task.isCancelled else { return }
            if !snapshot.isEmpty { access = await client.authorization() }
            guard generation == revision else { continue }
            let effective = access == .authorized ? snapshot.filter { $0.value.fireAt > now() } : [:]
            client.removePending(pending.filter { effective[$0] == nil })
            applied = applied.filter { effective[$0.key] != nil }
            if clearDelivered {
                let delivered = await client.deliveredIdentifiers().filter { $0.hasPrefix(prefix) }
                guard generation == revision else { continue }
                client.removeDelivered(delivered)
                clearDelivered = false
            }
            failed = false
            for request in effective.values.sorted(by: { $0.fireAt < $1.fireAt }) {
                guard !Task.isCancelled, generation == revision else { break }
                if applied[request.id] == request, pending.contains(request.id) { continue }
                do {
                    try await client.add(request)
                    if wanted[request.id] == request, generation == revision, !Task.isCancelled {
                        applied[request.id] = request
                        didSchedule?(request)
                    } else {
                        client.removePending([request.id])
                    }
                } catch { failed = true }
            }
            if generation == revision { return }
        }
    }
}
