// SPDX-License-Identifier: GPL-3.0-only
//
//  MenuBarPresenceController.swift
//  TahoeTime
//
//  AppKit adapter for the Rust menu-bar recovery reducer. Swift owns notification
//  selectors, task timers and Published delivery; recovery policy lives in Rust.
//

import AppKit
import Combine
import OSLog

@MainActor
final class MenuBarPresenceController: NSObject, NSApplicationDelegate, ObservableObject {
    @Published private(set) var isInserted: Bool
    private(set) var userWantsVisible: Bool

    /// Native observation hooks retained for the existing integration tests.
    var onInsertionChange: ((Bool) -> Void)?
    var treatsAsSiblingInstance: (_ bundleIdentifier: String?, _ pid: pid_t) -> Bool = { bundleID, pid in
        RustCore.invoke("presence.sibling", PresenceSiblingInput(bundleId: bundleID, pid: pid,
            ownBundleId: Bundle.main.bundleIdentifier, ownPid: ProcessInfo.processInfo.processIdentifier))
    }

    private let workspaceNotificationCenter: NotificationCenter
    private let appNotificationCenter: NotificationCenter
    private var machine: PresenceMachineState
    private var recoveryTask: Task<Void, Never>?

    override convenience init() {
        self.init(workspaceNotificationCenter: NSWorkspace.shared.notificationCenter,
                  appNotificationCenter: .default)
    }

    init(workspaceNotificationCenter: NotificationCenter,
         appNotificationCenter: NotificationCenter,
         recoveryDebounce: Duration? = nil,
         reinsertionGap: Duration? = nil,
         initialAttachmentDelay: Duration? = nil) {
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.appNotificationCenter = appNotificationCenter
        let output: PresenceMachineOutput = RustCore.invoke("presence.init", PresenceMachineInit(
            debounce: recoveryDebounce.map(Self.seconds), gap: reinsertionGap.map(Self.seconds),
            initialDelay: initialAttachmentDelay.map(Self.seconds)))
        machine = output.state
        isInserted = output.state.inserted
        userWantsVisible = output.state.userWantsVisible
        super.init()
    }

    deinit { recoveryTask?.cancel() }

    func applicationDidFinishLaunching(_ notification: Notification) { send(.init(kind: "launch")) }
    func applicationWillTerminate(_ notification: Notification) {
        DiagnosticsLog.note("lifecycle", "will terminate")
        stopObserving()
    }

    /// 菜单栏 App:关掉最后一个窗口(工具窗、设置)只是关窗,进程留在菜单栏。SwiftUI 自己的默认值不可靠,这里钉死。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        DiagnosticsLog.note("lifecycle", "last window closed; staying in the menu bar")
        return false
    }

    /// 谁在要求退出:记下当前事件(退出按钮、⌘Q、系统),便于诊断「App 自己退出了」。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let event = NSApp.currentEvent
        let window = event?.window?.identifier?.rawValue ?? "-"
        let kind = event.map { "\($0.type.rawValue)" } ?? "none"
        DiagnosticsLog.note("lifecycle", "terminate requested · event=\(kind) window=\(window)")
        return .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        send(.init(kind: "reopen"))
        return false
    }

    func setInsertionFromSystem(_ inserted: Bool) { send(.init(kind: "systemInsertion", inserted: inserted)) }
    func labelDidAppear() { send(.init(kind: "labelAppear")) }
    func labelDidDisappear() { send(.init(kind: "labelDisappear")) }
    func startObserving() { send(.init(kind: "startObserving")) }
    func stopObserving() { send(.init(kind: "stopObserving")) }

    /// NotificationCenter selectors execute on the posting thread; only scalar data crosses actors.
    @objc nonisolated private func environmentDidChange(_ notification: Notification) {
        Task { @MainActor [weak self] in self?.send(.init(kind: "environmentChanged")) }
    }

    @objc nonisolated private func applicationDidTerminate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let bundleID = app.bundleIdentifier
        let pid = app.processIdentifier
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.send(.init(kind: "siblingTerminated", sibling: self.treatsAsSiblingInstance(bundleID, pid)))
        }
    }

    private func send(_ event: PresenceMachineEvent) {
        let output: PresenceMachineOutput = RustCore.invoke("presence.reduce", PresenceMachineInput(state: machine, event: event))
        machine = output.state
        userWantsVisible = output.state.userWantsVisible
        if isInserted != output.state.inserted {
            isInserted = output.state.inserted
            onInsertionChange?(output.state.inserted)
        }
        for effect in output.effects { execute(effect) }
    }

    private func execute(_ effect: PresenceMachineEffect) {
        switch effect.kind {
        case "registerObservers":
            for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                         NSWorkspace.sessionDidBecomeActiveNotification] {
                workspaceNotificationCenter.addObserver(self, selector: #selector(environmentDidChange(_:)), name: name, object: nil)
            }
            appNotificationCenter.addObserver(self, selector: #selector(environmentDidChange(_:)),
                name: NSApplication.didChangeScreenParametersNotification, object: nil)
            workspaceNotificationCenter.addObserver(self, selector: #selector(applicationDidTerminate(_:)),
                name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        case "unregisterObservers":
            workspaceNotificationCenter.removeObserver(self)
            appNotificationCenter.removeObserver(self)
        case "cancelTimer":
            recoveryTask?.cancel()
            recoveryTask = nil
        case "clearTimer":
            recoveryTask = nil
        case "scheduleTimer":
            recoveryTask = Task { @MainActor [weak self] in
                do {
                    if let delay = effect.delay, delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                    try Task.checkCancellation()
                    self?.send(.init(kind: "timerFired", generation: effect.generation, phase: effect.phase))
                } catch {
                    self?.send(.init(kind: "timerCancelled", generation: effect.generation, phase: effect.phase))
                }
            }
        case "log":
            if let message = effect.message { DiagnosticsLog.note("MenuBarPresence", message) }
        default:
            preconditionFailure("Unknown Rust presence effect: \(effect.kind)")
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

private struct PresenceMachineInit: Encodable {
    let debounce: Double?
    let gap: Double?
    let initialDelay: Double?
}
private struct PresenceSiblingInput: Encodable {
    let bundleId: String?
    let pid: Int32
    let ownBundleId: String?
    let ownPid: Int32
}
private struct PresenceMachineInput: Encodable { let state: PresenceMachineState; let event: PresenceMachineEvent }
private struct PresenceMachineOutput: Decodable { let state: PresenceMachineState; let effects: [PresenceMachineEffect] }
private struct PresenceMachineEvent: Encodable {
    let kind: String
    var inserted: Bool? = nil
    var generation: UInt64? = nil
    var phase: String? = nil
    var sibling: Bool? = nil
}
private struct PresenceMachineEffect: Decodable, Sendable {
    let kind: String
    let generation: UInt64?
    let phase: String?
    let delay: Double?
    let message: String?
}
private struct PresenceMachineState: Codable {
    let inserted: Bool
    let userWantsVisible: Bool
    let observersRegistered: Bool
    let labelAttached: Bool
    let pulseActive: Bool
    let generation: UInt64
    let pendingReason: String?
    let debounce: Double
    let gap: Double
    let initialDelay: Double
}
