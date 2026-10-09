// SPDX-License-Identifier: GPL-3.0-only
//
//  MenuBarPresenceTests.swift
//  DaysideTests
//
//  菜单栏存在恢复状态机的回归测试。
//  原 harness 是仓外的 swiftc 脚本,git 历史里没有;这里用注入的 NotificationCenter 与毫秒级
//  时长在进程内复现四种环境通知、burst 去重、active pulse 合并、系统 false 优先、首次 attach 缺失、
//  label 短暂 detach、reopen、stop 取消,以及后台线程发通知后安全回到 MainActor。
//

import AppKit
import XCTest
@testable import Dayside

@MainActor
final class MenuBarPresenceTests: XCTestCase {

    private var workspaceCenter: NotificationCenter!
    private var appCenter: NotificationCenter!
    private var controller: MenuBarPresenceController!
    /// 每次插入状态变化的记录:false 表示拔出,true 表示重插。一次完整脉冲 = [false, true]。
    private var transitions: [Bool] = []

    private let debounce: Duration = .milliseconds(40)
    private let gap: Duration = .milliseconds(20)
    private let initialDelay: Duration = .milliseconds(60)

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run { prepare() }
    }

    override func tearDown() async throws {
        await MainActor.run { cleanup() }
        try await super.tearDown()
    }

    private func prepare() {
        workspaceCenter = NotificationCenter()
        appCenter = NotificationCenter()
        transitions = []
        controller = MenuBarPresenceController(
            workspaceNotificationCenter: workspaceCenter,
            appNotificationCenter: appCenter,
            recoveryDebounce: debounce,
            reinsertionGap: gap,
            initialAttachmentDelay: initialDelay
        )
        controller.onInsertionChange = { [weak self] inserted in self?.transitions.append(inserted) }
    }

    private func cleanup() {
        controller.stopObserving()
        controller = nil
    }

    private func settle(_ ms: Int = 200) async throws {
        try await Task.sleep(for: .milliseconds(ms))
    }

    private var pulseCount: Int {
        // 数「false 后紧跟 true」的对数。
        var count = 0
        var index = 0
        while index + 1 < transitions.count {
            if transitions[index] == false, transitions[index + 1] == true { count += 1; index += 2 } else { index += 1 }
        }
        return count
    }

    private func launch() {
        controller.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    }

    // MARK: - 初始状态与首次 attach

    func testInitialState() {
        XCTAssertTrue(controller.isInserted)
        XCTAssertTrue(controller.userWantsVisible)
        XCTAssertTrue(transitions.isEmpty)
    }

    /// 冷启动 label 从未 attach → 延迟后做一次 false→true 脉冲补救。
    func testMissingInitialAttachmentTriggersOnePulse() async throws {
        launch()
        try await settle()
        XCTAssertEqual(transitions, [false, true])
        XCTAssertTrue(controller.isInserted)
    }

    /// label 在延迟期内正常 attach → 取消补救,零脉冲。
    func testLabelAppearingInTimeCancelsInitialRecovery() async throws {
        launch()
        controller.labelDidAppear()
        try await settle()
        XCTAssertTrue(transitions.isEmpty)
        XCTAssertTrue(controller.isInserted)
    }

    // MARK: - label detach

    func testLabelDetachTriggersPulseAfterDebounce() async throws {
        launch()
        controller.labelDidAppear()
        controller.labelDidDisappear()
        try await settle()
        XCTAssertEqual(pulseCount, 1)
        XCTAssertTrue(controller.isInserted)
    }

    /// SwiftUI 正常重排造成的极短 disappear/appear 不该闪动。
    func testBriefDetachThenReattachDoesNotPulse() async throws {
        launch()
        controller.labelDidAppear()
        controller.labelDidDisappear()
        controller.labelDidAppear()
        try await settle()
        XCTAssertTrue(transitions.isEmpty)
    }

    // MARK: - 四种环境通知

    func testEachEnvironmentNotificationTriggersOnePulse() async throws {
        let cases: [(NotificationCenter, Notification.Name)] = [
            (workspaceCenter, NSWorkspace.didWakeNotification),
            (workspaceCenter, NSWorkspace.screensDidWakeNotification),
            (workspaceCenter, NSWorkspace.sessionDidBecomeActiveNotification),
            (appCenter, NSApplication.didChangeScreenParametersNotification),
        ]
        launch()
        controller.labelDidAppear()
        for (center, name) in cases {
            transitions = []
            center.post(name: name, object: nil)
            try await settle()
            XCTAssertEqual(transitions, [false, true], "\(name.rawValue) 应触发恰好一次脉冲")
            XCTAssertTrue(controller.isInserted)
        }
    }

    /// 通知在后台线程发出(workspace 通知没有主线程保证)也必须安全回到 MainActor 处理。
    func testNotificationFromBackgroundThreadIsHandledOnMainActor() async throws {
        launch()
        controller.labelDidAppear()
        let center = workspaceCenter!
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                center.post(name: NSWorkspace.didWakeNotification, object: nil)
                continuation.resume()
            }
        }
        try await settle()
        XCTAssertEqual(transitions, [false, true])
    }

    // MARK: - 同 bundle id 的另一实例退出

    func testSiblingInstanceTerminationTriggersPulse() async throws {
        launch()
        controller.labelDidAppear()
        controller.treatsAsSiblingInstance = { _, _ in true }
        workspaceCenter.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil,
                             userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current])
        try await settle()
        XCTAssertEqual(transitions, [false, true])
        XCTAssertTrue(controller.isInserted)
    }

    func testUnrelatedAppTerminationIsIgnored() async throws {
        launch()
        controller.labelDidAppear()
        controller.treatsAsSiblingInstance = { _, _ in false }
        workspaceCenter.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil,
                             userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current])
        try await settle()
        XCTAssertTrue(transitions.isEmpty)
    }

    func testTerminationWithoutApplicationInfoIsIgnored() async throws {
        launch()
        controller.labelDidAppear()
        controller.treatsAsSiblingInstance = { _, _ in true }
        workspaceCenter.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        try await settle()
        XCTAssertTrue(transitions.isEmpty)
    }

    /// 默认判定:同 bundle id 且不是自己才算另一实例。
    func testDefaultSiblingFilter() {
        let me = ProcessInfo.processInfo.processIdentifier
        let bundle = Bundle.main.bundleIdentifier
        XCTAssertFalse(controller.treatsAsSiblingInstance(bundle, me), "自己退出不算")
        XCTAssertTrue(controller.treatsAsSiblingInstance(bundle, me + 1))
        XCTAssertFalse(controller.treatsAsSiblingInstance("com.example.other", me + 1))
        XCTAssertFalse(controller.treatsAsSiblingInstance(nil, me + 1))
    }

    // MARK: - burst 去重与 pulse 合并

    func testBurstOfNotificationsCollapsesToOnePulse() async throws {
        launch()
        controller.labelDidAppear()
        for _ in 0..<6 {
            workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
            appCenter.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        }
        try await settle(300)
        XCTAssertEqual(pulseCount, 1, "debounce 内的 burst 只能合并成一次脉冲")
        XCTAssertTrue(controller.isInserted)
    }

    /// 脉冲进行中(已拔出、等待重插)再来通知:合并进当前脉冲,不再开第二轮。
    func testNotificationDuringActivePulseIsMerged() async throws {
        launch()
        controller.labelDidAppear()
        _ = controller.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false)   // 零延迟脉冲
        try await Task.sleep(for: .milliseconds(5))                                                 // 此刻处于 false 半程
        XCTAssertEqual(transitions, [false])
        workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await settle(300)
        XCTAssertEqual(transitions, [false, true], "脉冲中来的通知不该再拔一次")
    }

    // MARK: - 系统 / 用户选择优先

    func testSystemFalseStopsAllAutomaticRecovery() async throws {
        launch()
        controller.labelDidAppear()
        controller.setInsertionFromSystem(false)
        XCTAssertFalse(controller.isInserted)
        XCTAssertFalse(controller.userWantsVisible)
        transitions = []
        workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        controller.labelDidDisappear()
        try await settle()
        XCTAssertTrue(transitions.isEmpty, "系统/用户移除后,本进程停止一切自动恢复")
        XCTAssertFalse(controller.isInserted)
    }

    /// 脉冲进行到 false 半程时系统传入 false:系统选择优先,不再重插。
    func testSystemFalseDuringPulseWins() async throws {
        launch()
        controller.labelDidAppear()
        _ = controller.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false)
        try await Task.sleep(for: .milliseconds(5))
        XCTAssertEqual(transitions, [false])
        controller.setInsertionFromSystem(false)
        try await settle(300)
        XCTAssertFalse(controller.isInserted)
        XCTAssertEqual(transitions, [false], "系统 false 之后不得自动重插")
    }

    func testSystemTrueRestoresAndReenablesRecovery() async throws {
        launch()
        controller.labelDidAppear()
        controller.setInsertionFromSystem(false)
        controller.setInsertionFromSystem(true)
        XCTAssertTrue(controller.isInserted)
        XCTAssertTrue(controller.userWantsVisible)
        transitions = []
        workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await settle()
        XCTAssertEqual(transitions, [false, true])
    }

    // MARK: - reopen

    /// 用户从 Finder/Spotlight 再次打开:视为明确要求恢复。已插入 → 零延迟脉冲。
    func testReopenWhileInsertedPulsesImmediately() async throws {
        launch()
        controller.labelDidAppear()
        let handled = controller.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false)
        XCTAssertFalse(handled, "LSUIElement app 不该生成无意义窗口")
        try await settle()
        XCTAssertEqual(transitions, [false, true])
    }

    /// 被移除后 reopen → 直接重插,并重新允许自动恢复。
    func testReopenAfterRemovalRestoresInsertion() async throws {
        launch()
        controller.labelDidAppear()
        controller.setInsertionFromSystem(false)
        transitions = []
        _ = controller.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false)
        XCTAssertTrue(controller.isInserted)
        XCTAssertTrue(controller.userWantsVisible)
        XCTAssertEqual(transitions, [true])
    }

    // MARK: - 观察者生命周期

    func testStartObservingIsIdempotent() async throws {
        launch()
        controller.labelDidAppear()
        controller.startObserving()
        controller.startObserving()
        workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await settle()
        XCTAssertEqual(pulseCount, 1, "重复注册不该让一条通知触发多次处理")
    }

    func testStopObservingCancelsPendingRecoveryAndIgnoresNotifications() async throws {
        launch()
        controller.labelDidAppear()
        controller.labelDidDisappear()          // 排了一个 debounce 中的恢复
        controller.stopObserving()
        workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await settle()
        XCTAssertTrue(transitions.isEmpty)
        XCTAssertTrue(controller.isInserted)
    }

    func testWillTerminateStopsObserving() async throws {
        launch()
        controller.labelDidAppear()
        controller.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await settle()
        XCTAssertTrue(transitions.isEmpty)
    }
}
