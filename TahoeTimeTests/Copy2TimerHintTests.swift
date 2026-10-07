// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SwiftUI
import Testing
@testable import TahoeTime

/// 手动推进的时钟：wall 与 continuous 同步走，测试不依赖真实时间。
private final class FakeClock {
    var facts: TimerClockFacts

    init(wall: Double) {
        facts = TimerClockFacts(wall: wall, continuous: 0, bootID: "copy2-timer-hints")
    }

    func advance(by seconds: Double) {
        facts = TimerClockFacts(wall: facts.wall + seconds, continuous: facts.continuous + seconds,
                                bootID: facts.bootID)
    }
}

@MainActor
struct Copy2TimerHintTests {
    private func makeSuite(_ label: String) -> (UserDefaults, String) {
        let name = "copy2-timer-hints.\(label).\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    /// 一次性 suite + 手动时钟；关掉原生事件观察与运行时，测试不触碰通知系统，也不提示授权。
    private func makeStore(suite: UserDefaults, clock: FakeClock) -> TimerStore {
        TimerStore(defaults: suite, notificationClient: Copy2Notifications(), clock: { clock.facts },
                   observeSystemEvents: false, runtimeEnabled: false)
    }

    private func makeSpec(_ mode: String, at clock: FakeClock) -> TimerSpec {
        var spec = TimerSpec()
        spec.mode = mode
        switch mode {
        case "countdown": spec.duration = 60
        case "pomodoro": spec.focus = 60; spec.shortBreak = 60; spec.longBreak = 60; spec.rounds = 2
        case "alarm": spec.alarmAt = clock.facts.wall + 60
        default: break
        }
        return spec
    }

    @Test(arguments: ["countdown", "pomodoro", "alarm"])
    func completedPageTimerDismissesAndStaysGone(mode: String) {
        let (suite, suiteName) = makeSuite("complete-\(mode)")
        defer { suite.removePersistentDomain(forName: suiteName) }
        let clock = FakeClock(wall: 1_700_000_000)
        let store = makeStore(suite: suite, clock: clock)
        #expect(store.showsCompletionHint)

        store.startFromTimersPage(makeSpec(mode, at: clock))
        #expect(store.state.session?.spec.mode == mode)
        #expect(store.showsCompletionHint)

        clock.advance(by: mode == "pomodoro" ? 600 : 120)
        store.refresh()
        #expect(store.presentation?.isCompleted == true)
        #expect(!store.showsCompletionHint)

        let reopened = makeStore(suite: suite, clock: clock)
        #expect(!reopened.showsCompletionHint)
        reopened.cancel()
        reopened.startFromTimersPage(makeSpec(mode, at: clock))
        clock.advance(by: mode == "pomodoro" ? 600 : 120)
        reopened.refresh()
        #expect(reopened.presentation?.isCompleted == true)
        #expect(!reopened.showsCompletionHint)
    }

    @Test
    func stopwatchAndExternalStartsDoNotDismiss() {
        let (suite, suiteName) = makeSuite("stopwatch-external")
        defer { suite.removePersistentDomain(forName: suiteName) }
        let clock = FakeClock(wall: 1_700_000_000)
        let store = makeStore(suite: suite, clock: clock)
        #expect(store.showsCompletionHint)

        store.startFromTimersPage(makeSpec("stopwatch", at: clock))
        clock.advance(by: 120)
        store.refresh()
        #expect(store.state.session?.spec.mode == "stopwatch")
        #expect(store.showsCompletionHint)

        store.cancel()
        #expect(store.state.session == nil)
        store.start(makeSpec("countdown", at: clock))
        clock.advance(by: 120)
        store.refresh()
        #expect(store.presentation?.isCompleted == true)
        #expect(store.showsCompletionHint)

        let restored = makeStore(suite: suite, clock: clock)
        #expect(restored.state.session?.spec.mode == "countdown")
        #expect(restored.showsCompletionHint)
    }

    @Test
    func pauseCancelAndFocusBoundaryDoNotDismiss() {
        let (suite, suiteName) = makeSuite("pause-cancel-boundary")
        defer { suite.removePersistentDomain(forName: suiteName) }
        let clock = FakeClock(wall: 1_700_000_000)
        let store = makeStore(suite: suite, clock: clock)
        store.startFromTimersPage(makeSpec("countdown", at: clock))

        clock.advance(by: 10)
        store.refresh()
        store.pause()
        #expect(store.state.session?.status == "paused")
        clock.advance(by: 300)
        store.refresh()
        #expect(store.presentation?.isCompleted != true)
        #expect(store.showsCompletionHint)

        store.cancel()
        #expect(store.state.session == nil)
        clock.advance(by: 120)
        store.refresh()
        #expect(store.showsCompletionHint)

        store.startFromTimersPage(makeSpec("pomodoro", at: clock))
        clock.advance(by: 70)
        store.refresh()
        #expect(store.presentation?.phase == "shortBreak")
        #expect(store.presentation?.isCompleted != true)
        #expect(store.showsCompletionHint)

        let reopened = makeStore(suite: suite, clock: clock)
        #expect(reopened.showsCompletionHint)
    }

    @Test
    func pendingPageSessionSurvivesModelRelaunch() {
        let (suite, suiteName) = makeSuite("relaunch")
        defer { suite.removePersistentDomain(forName: suiteName) }
        let clock = FakeClock(wall: 1_700_000_000)
        let first = makeStore(suite: suite, clock: clock)
        #expect(first.showsCompletionHint)
        first.startFromTimersPage(makeSpec("countdown", at: clock))
        let sessionID = first.state.session?.id

        clock.advance(by: 30)
        let restored = makeStore(suite: suite, clock: clock)
        #expect(restored.state.session?.id == sessionID)
        #expect(restored.presentation?.isRunning == true)
        #expect(restored.showsCompletionHint)

        clock.advance(by: 90)
        let expired = makeStore(suite: suite, clock: clock)
        #expect(expired.presentation?.isCompleted == true)
        #expect(!expired.showsCompletionHint)

        let reopened = makeStore(suite: suite, clock: clock)
        #expect(!reopened.showsCompletionHint)
    }
}

@MainActor private final class Copy2Notifications: LensNotificationClient {
    func authorization() async -> LensNotificationAccess { .authorized }
    func requestAuthorization() async throws -> Bool { true }
    func pendingIdentifiers() async -> [String] { [] }
    func deliveredIdentifiers() async -> [String] { [] }
    func add(_ request: LensNotificationRequest) async throws {}
    func removePending(_ identifiers: [String]) {}
    func removeDelivered(_ identifiers: [String]) {}
}
