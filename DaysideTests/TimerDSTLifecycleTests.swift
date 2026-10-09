// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import Dayside

@MainActor
private final class FakeLensNotifications: LensNotificationClient {
    var access = LensNotificationAccess.authorized
    var authorizationRequests = 0
    var authorizationQueries = 0
    var suspendPermissions = false
    var suspendAuthorization = false
    var permissionContinuations: [CheckedContinuation<Bool, Never>] = []
    var authorizationContinuations: [CheckedContinuation<LensNotificationAccess, Never>] = []
    var addCalls = 0
    var requests: [String: LensNotificationRequest] = [:]
    var delivered: [String] = []
    var failAdds = false
    var suspendAdds = false
    var addContinuation: CheckedContinuation<Void, Never>?

    func authorization() async -> LensNotificationAccess {
        authorizationQueries += 1
        if suspendAuthorization { return await withCheckedContinuation { authorizationContinuations.append($0) } }
        return access
    }
    func requestAuthorization() async throws -> Bool {
        authorizationRequests += 1
        let granted = if suspendPermissions { await withCheckedContinuation { permissionContinuations.append($0) } } else { true }
        access = granted ? .authorized : .denied
        return granted
    }
    func pendingIdentifiers() async -> [String] { Array(requests.keys) }
    func deliveredIdentifiers() async -> [String] { delivered }
    func add(_ request: LensNotificationRequest) async throws {
        addCalls += 1
        if suspendAdds { await withCheckedContinuation { addContinuation = $0 } }
        if failAdds { throw CocoaError(.fileWriteUnknown) }
        requests[request.id] = request
    }
    func removePending(_ identifiers: [String]) { identifiers.forEach { requests[$0] = nil } }
    func removeDelivered(_ identifiers: [String]) { delivered.removeAll { identifiers.contains($0) } }
}

@MainActor
private final class LensTestClock {
    var facts = TimerClockFacts(wall: 1000, continuous: 100, bootID: "test-boot")
    var now: Date { Date(timeIntervalSince1970: facts.wall) }
}

@MainActor
private func lensTestDefaults() -> (defaults: UserDefaults, cleanup: () -> Void) {
    TestDefaults.make(prefix: "com.dayside.tests.lenses")
}

@MainActor
struct TimerDSTLifecycleTests {
    @Test func alarmFollowSystemChoicesKeepSystemCycleAndLocalizedOccurrence() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2030-10-01T12:00:00Z"))
        let item = try #require(AlarmReading.resolve("Los Angeles 2030-11-03 1:30", now: now, home: .gmt).item)
        try #require(item.intervals.count == 2)
        for (systemID, uiID, twelve) in [("en_US@hours=h23", "en_US", false),
                                        ("en_US@hours=h12", "zh-Hans", true)] {
            let locale = Locale(identifier: uiID)
            let first = TimerLensView.repeatedLabel(item, index: 0, hourStyle: .followSystem,
                                                    locale: locale, system: Locale(identifier: systemID))
            let second = TimerLensView.repeatedLabel(item, index: 1, hourStyle: .followSystem,
                                                     locale: locale, system: Locale(identifier: systemID))
            for label in [first, second] {
                #expect(label.hasPrefix(twelve ? "1:30" : "01:30"), "\(systemID), UI \(uiID): \(label)")
                #expect(label.contains("AM") == twelve)
                #expect(!label.contains("上午"))
            }
            #expect(first.contains("PDT") && first.contains(L10n.string("第一次", locale: locale)))
            #expect(second.contains("PST") && second.contains(L10n.string("第二次", locale: locale)))
        }
    }

    @Test func alarmFollowSystemNoticeKeepsSystemCycleAcrossInterfaceLocales() throws {
        let target = try #require(ISO8601DateFormatter().date(from: "2030-10-04T04:05:00Z"))
        let notice = TimerNotice(id: "clock-locale", fireAt: target.timeIntervalSince1970,
                                 kind: "alarm", round: 0, label: "Meeting")
        var spec = TimerSpec()
        spec.mode = "alarm"; spec.alarmZone = "Asia/Tokyo"; spec.alarmPlace = "Tokyo"
        let twentyFour = TimerStore.noticeBody(notice, spec: spec, hourStyle: .followSystem,
                                              locale: Locale(identifier: "en_US"),
                                              system: Locale(identifier: "en_US@hours=h23"))
        #expect(twentyFour == "Meeting · Tokyo 13:05")
        let twelve = TimerStore.noticeBody(notice, spec: spec, hourStyle: .followSystem,
                                          locale: Locale(identifier: "zh-Hans"),
                                          system: Locale(identifier: "en_US@hours=h12"))
        #expect(twelve.hasPrefix("Meeting · Tokyo 1:05"))
        #expect(twelve.hasSuffix("PM"))
        #expect(!twelve.contains("下午"))
    }

    @Test func alarmRunningCityKeepsOsakaCoordinatesInsteadOfTokyo() throws {
        let zone = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let osaka = try #require(TimerLensView.cityCoordinate(place: "Osaka", in: zone))
        #expect(abs(osaka.latitude - 34.69) < 0.1)
        #expect(abs(osaka.longitude - 135.5) < 0.1)
        #expect(TimerLensView.cityCoordinate(place: "Osaka", in: .gmt) == nil)
    }

    @Test func oldAlarmSubjectNamesThisMacAndNewAlarmKeepsItsPlace() {
        var spec = TimerSpec()
        spec.mode = "alarm"
        let en = Locale(identifier: "en")
        #expect(TimerLensView.alarmSubjectPlace(spec, locale: en, fallback: "Los Angeles") == L10n.string("本机", locale: en))
        spec.alarmZone = "Asia/Tokyo"; spec.alarmPlace = "Tokyo"
        #expect(TimerLensView.alarmSubjectPlace(spec, locale: en, fallback: "Japan") == "Tokyo")
    }

    @Test func alarmUnknownSourcePlaceBlocksLocalFallback() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2030-10-01T12:00:00Z"))
        let result = AlarmReading.resolve("tomorrow 9am in Москвzz", now: now, home: .gmt)
        #expect(result.item?.problem == .unresolvedPlace("Москвzz"))
        #expect(result.item?.intervals.isEmpty == true)
        #expect(!result.advanced)
    }

    @Test func alarmWithoutDateUsesNextCivilDayAndExplicitPastDateStaysPast() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2030-11-03T18:00:00Z"))
        let zone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let next = AlarmReading.resolve("9:00", now: now, home: zone)
        let nextTime = try #require(next.item?.start)
        #expect(next.advanced)
        #expect(nextTime > now)
        let components = Calendar.gregorianUTC(zone).dateComponents([.day, .hour, .minute], from: nextTime)
        #expect(components.day == 4 && components.hour == 9 && components.minute == 0)
        let explicit = AlarmReading.resolve("2030-11-03 9:00", now: now, home: zone)
        #expect(!explicit.advanced)
        #expect(try #require(explicit.item?.start) < now)
    }

    @Test func alarmFirstMentionCanBeDateOnlyAndDoesNotSkipToLaterClock() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2030-10-01T12:00:00Z"))
        let result = AlarmReading.resolve("2030-10-04; tomorrow 9:00 Tokyo", now: now, home: .gmt)
        #expect(result.count > 1)
        #expect(result.item?.problem == .dateOnly)
        #expect(result.item?.intervals.isEmpty == true)
    }

    @Test(arguments: [
        "Los Angeles 2030-11-03 1:30",
        "Los Angeles November 3, 2030 1:30",
        "Лос-Анджелес 3 ноября 2030 г. 1:30",
        "Лос-Анджелес 3 ноября 2030\u{202f}г. 1:30",
        "洛杉矶 2030-11-03 1:30",
        "Лос-Анджелес 2030-11-03 1:30",
        "ロサンゼルス 2030-11-03 1:30",
        "洛杉矶2030年11月3日1:30",
        "Лос-Анджелес 3 ноября 2030 в 1:30",
        "Los Angeles 3. November 2030 1:30",
        "ロサンゼルス2030年11月3日1:30",
        "Los Angeles 2026-11-01 1:30",
    ])
    func repeatedAlarmLabelsNameBothOccurrencesWithoutISO(_ text: String) throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-01T12:00:00Z"))
        let result = AlarmReading.resolve(text, now: now, home: .gmt)
        let item = try #require(result.item)
        #expect(item.zone.identifier == "America/Los_Angeles", "\(text): \(item)")
        try #require(item.intervals.count == 2, "\(text): \(item)")
        let en = Locale(identifier: "en")
        let first = TimerLensView.repeatedLabel(item, index: 0, hourStyle: .force24, locale: en)
        let second = TimerLensView.repeatedLabel(item, index: 1, hourStyle: .force24, locale: en)
        #expect(first.contains("PDT") && first.contains(L10n.string("第一次", locale: en)), "\(text): first label = \(first)")
        #expect(second.contains("PST") && second.contains(L10n.string("第二次", locale: en)), "\(text): second label = \(second)")
        #expect(!first.contains("2030-") && !second.contains("2030-"))
        #expect(UnderstandingText.abbreviation(item.zoneOption, at: item.intervals[0].start, offsetOnly: true) == "UTC−7")
        #expect(UnderstandingText.abbreviation(item.zoneOption, at: item.intervals[1].start, offsetOnly: true) == "UTC−8")
        #expect(item.intervals[1].start.timeIntervalSince(item.intervals[0].start) == 3600)
    }

    @Test func alarmNoticeRetainsPlaceAndFollowsConfiguredHourStyle() async throws {
        let (defaults, cleanup) = lensTestDefaults()
        defer { cleanup() }
        let clock = LensTestClock()
        let target = try #require(ISO8601DateFormatter().date(from: "2030-10-04T00:00:00Z"))
        clock.facts.wall = target.timeIntervalSince1970 - 3600
        let client = FakeLensNotifications()
        let store = TimerStore(defaults: defaults, notificationClient: client, clock: { clock.facts }, observeSystemEvents: false)
        let locale = Locale(identifier: "en")
        let zone = try #require(TimeZone(identifier: "Asia/Tokyo"))
        store.configure(zones: [], locale: locale, hourStyle: .force12)
        var spec = TimerSpec()
        spec.mode = "alarm"; spec.alarmAt = target.timeIntervalSince1970
        spec.label = "Meeting"; spec.alarmZone = zone.identifier; spec.alarmPlace = "Tokyo"
        await store.requestNotificationPermission()
        store.start(spec)
        await store.waitUntilSettled()
        #expect(client.requests.values.first?.title == L10n.string("闹钟时间到了", locale: locale))
        #expect(client.requests.values.first?.body == "Meeting · Tokyo " + ClockText.time(target, in: zone, hourStyle: .force12, system: locale))
        store.configure(zones: [], locale: locale, hourStyle: .force24)
        await store.waitUntilSettled()
        #expect(client.requests.values.first?.body == "Meeting · Tokyo " + ClockText.time(target, in: zone, hourStyle: .force24, system: locale))
        let zh = Locale(identifier: "zh-Hans")
        store.configure(zones: [], locale: zh, hourStyle: .force12)
        await store.waitUntilSettled()
        #expect(client.requests.values.first?.title == L10n.string("闹钟时间到了", locale: zh))
        #expect(client.requests.values.first?.body == "Meeting · Tokyo " + ClockText.time(target, in: zone, hourStyle: .force12, system: zh))
        store.pause(); store.resume()
        #expect(store.state.session?.spec.alarmZone == "Asia/Tokyo")
        #expect(store.state.session?.spec.alarmPlace == "Tokyo")
        let restored = TimerStore(defaults: defaults, notificationClient: FakeLensNotifications(), clock: { clock.facts }, observeSystemEvents: false)
        #expect(!restored.recovered)
        #expect(restored.state.session?.spec.alarmPlace == "Tokyo")
        await restored.deactivate()
        await store.deactivate()
    }

    @Test func freshDisabledStoresOwnNoTasksAndNeverRequestPermission() async {
        let (defaults, cleanup) = lensTestDefaults()
        defer { cleanup() }
        let client = FakeLensNotifications()
        let clock = LensTestClock()
        let timer = TimerStore(defaults: defaults, notificationClient: client, clock: { clock.facts }, observeSystemEvents: false)
        let dst = DSTWatchStore(defaults: defaults, notificationClient: client, now: { clock.now }, observeSystemEvents: false)
        #expect(timer.activeResourceCount == 0)
        #expect(dst.activeResourceCount == 0)
        #expect(client.authorizationRequests == 0)
        #expect(client.addCalls == 0)
        #expect(defaults.data(forKey: TimerStore.storageKey) == nil)
        #expect(defaults.data(forKey: DSTWatchStore.storageKey) == nil)
    }

    @Test func hidingTimerStopsRefreshWithoutCancelingTheSession() async {
        let (defaults, cleanup) = lensTestDefaults()
        defer { cleanup() }
        let clock = LensTestClock()
        let store = TimerStore(defaults: defaults, notificationClient: FakeLensNotifications(), clock: { clock.facts }, observeSystemEvents: false)
        store.start(TimerSpec())
        store.setVisible(true)
        #expect(store.activeResourceCount == 1)
        store.setVisible(false)
        await store.waitUntilSettled()
        #expect(store.activeResourceCount == 0)
        #expect(store.state.session?.status == "running")
        clock.facts.wall += 75
        clock.facts.continuous += 75
        store.setVisible(true)
        #expect(store.presentation?.seconds == 225)
        await store.deactivate()
        #expect(store.activeResourceCount == 0)
    }

    @Test func timerPauseAndCancelRemoveOnlyTheirOwnNotifications() async {
        let (defaults, cleanup) = lensTestDefaults()
        defer { cleanup() }
        let client = FakeLensNotifications()
        let clock = LensTestClock()
        client.requests["meantime.dst.keep"] = LensNotificationRequest(id: "meantime.dst.keep", fireAt: clock.now.addingTimeInterval(500), title: "", body: "")
        let store = TimerStore(defaults: defaults, notificationClient: client, clock: { clock.facts }, observeSystemEvents: false)
        store.setNotificationsEnabled(true)
        store.start(TimerSpec())
        await store.waitUntilSettled()
        #expect(client.requests.keys.filter { $0.hasPrefix("meantime.timer.") }.count == 1)
        #expect(client.authorizationRequests == 0)
        store.pause()
        await store.waitUntilSettled()
        #expect(client.requests["meantime.dst.keep"] != nil)
        #expect(client.requests.count == 1)
        store.resume()
        await store.waitUntilSettled()
        #expect(client.requests.count == 2)
        await store.deactivate()
        #expect(client.requests.count == 1)
        #expect(store.activeResourceCount == 0)
    }

    /// 番茄钟账本：做完的专注段按本机民用日分桶（今天在前），中途取消不算，关掉透镜与重启进程都留着；
    /// 昨天做完的段落进 `最近 7 天` 不进 `今天`。时钟从 2026-09-16 12:30 UTC 起算（本机日界按当前时区）。
    @Test func pomodoroLedgerSurvivesCancelDeactivateAndReload() async {
        let (defaults, cleanup) = lensTestDefaults()
        defer { cleanup() }
        let clock = LensTestClock()
        clock.facts.wall = 1_789_561_800  // 12:30 UTC：没有哪个时区的午夜落在这 13 分钟窗口里
        let store = TimerStore(defaults: defaults, notificationClient: FakeLensNotifications(), clock: { clock.facts }, observeSystemEvents: false)
        #expect(store.ledger?.days.count == 7)
        #expect(store.ledger?.recentCount == 0)
        var spec = TimerSpec()
        spec.mode = "pomodoro"; spec.focus = 60; spec.shortBreak = 10; spec.longBreak = 20; spec.rounds = 3
        store.start(spec)
        // 第一段专注做完、进入休息
        clock.facts.wall += 65; clock.facts.continuous += 65
        store.refresh()
        #expect(store.ledger?.today?.focusCount == 1)
        #expect(store.ledger?.today?.focusSeconds == 60)
        #expect(store.state.session?.creditedFocus == 1)
        // 第二段做到一半取消：还是 1 次
        clock.facts.wall += 30; clock.facts.continuous += 30
        store.cancel()
        #expect(store.state.session == nil)
        #expect(store.ledger?.today?.focusCount == 1)
        #expect(store.state.ledger?.count == 1)
        // 再跑一整套（无人看着），3 段全部记上
        store.start(spec)
        clock.facts.wall += 400; clock.facts.continuous += 400
        store.refresh()
        #expect(store.presentation?.isCompleted == true)
        #expect(store.ledger?.today?.focusCount == 4)
        #expect(store.ledger?.today?.focusSeconds == 240)
        await store.deactivate()
        #expect(store.state.session == nil)
        #expect(store.state.ledger?.count == 4)
        // 隔天重开：昨天的 4 次只在「最近 7 天」里
        clock.facts.wall += 86_400; clock.facts.continuous += 86_400
        let reopened = TimerStore(defaults: defaults, notificationClient: FakeLensNotifications(), clock: { clock.facts }, observeSystemEvents: false)
        #expect(reopened.ledger?.today?.focusCount == 0)
        #expect(reopened.ledger?.recentCount == 4)
        #expect(reopened.ledger?.days[1].focusCount == 4)
        await reopened.deactivate()
    }

    @Test func endedTimerIsRestoredAsCompletedWithoutAnOldAlert() async {
        let (defaults, cleanup) = lensTestDefaults()
        defer { cleanup() }
        let clock = LensTestClock()
        let original = TimerStore(defaults: defaults, notificationClient: FakeLensNotifications(), clock: { clock.facts }, observeSystemEvents: false)
        original.start(TimerSpec())
        clock.facts.wall += 500
        clock.facts.continuous += 500
        let client = FakeLensNotifications()
        let restored = TimerStore(defaults: defaults, notificationClient: client, clock: { clock.facts }, observeSystemEvents: false)
        await restored.waitUntilSettled()
        #expect(restored.presentation?.isCompleted == true)
        #expect(client.addCalls == 0)
        #expect(restored.activeResourceCount == 0)
        await original.deactivate()
        await restored.deactivate()
    }

    @Test func corruptTimerStorageIsBackedUpWithoutRequestingPermission() async {
        let (defaults, cleanup) = lensTestDefaults()
        defer { cleanup() }
        let corrupt = Data([0xff, 0x12, 0x34])
        defaults.set(corrupt, forKey: TimerStore.storageKey)
        let client = FakeLensNotifications()
        let store = TimerStore(defaults: defaults, notificationClient: client, observeSystemEvents: false)
        await store.waitUntilSettled()
        #expect(store.recovered)
        #expect(defaults.data(forKey: TimerStore.storageKey + ".corrupt-backup") == corrupt)
        #expect(store.state.session == nil)
        #expect(client.authorizationRequests == 0)
    }

    @Test func timerNotificationFailureIsVisibleAndRetryDoesNotPrompt() async {
        let (defaults, cleanup) = lensTestDefaults()
        defer { cleanup() }
        let client = FakeLensNotifications()
        client.failAdds = true
        let clock = LensTestClock()
        let store = TimerStore(defaults: defaults, notificationClient: client, clock: { clock.facts }, observeSystemEvents: false)
        store.setNotificationsEnabled(true)
        store.start(TimerSpec())
        await store.waitUntilSettled()
        #expect(store.notifications.failed)
        client.failAdds = false
        clock.facts.wall += 1
        store.refresh()
        await store.waitUntilSettled()
        #expect(!store.notifications.failed)
        #expect(client.requests.count == 1)
        #expect(client.authorizationRequests == 0)
        await store.deactivate()
    }

    @Test func stoppingWhileNotificationAddIsSuspendedRemovesLateRequest() async {
        let (defaults, cleanup) = lensTestDefaults()
        defer { cleanup() }
        let client = FakeLensNotifications()
        client.suspendAdds = true
        let clock = LensTestClock()
        let store = TimerStore(defaults: defaults, notificationClient: client, clock: { clock.facts }, observeSystemEvents: false)
        store.setNotificationsEnabled(true)
        store.start(TimerSpec())
        for _ in 0..<100 where client.addContinuation == nil { await Task.yield() }
        #expect(client.addContinuation != nil)
        let stopping = Task { await store.deactivate() }
        for _ in 0..<10 { await Task.yield() }
        client.suspendAdds = false
        client.addContinuation?.resume()
        client.addContinuation = nil
        await stopping.value
        #expect(client.requests.isEmpty)
        #expect(store.activeResourceCount == 0)
    }

    @Test func timerDeactivationWaitsForEveryHeldPermissionAndIgnoresLateGrants() async {
        let (defaults, cleanup) = lensTestDefaults()
        defer { cleanup() }
        let client = FakeLensNotifications()
        client.access = .notDetermined
        client.suspendPermissions = true
        let clock = LensTestClock()
        let store = TimerStore(defaults: defaults, notificationClient: client, clock: { clock.facts }, observeSystemEvents: false)
        store.start(TimerSpec())
        let first = Task { await store.requestNotificationPermission() }
        for _ in 0..<100 where client.permissionContinuations.count < 1 { await Task.yield() }
        let second = Task { await store.requestNotificationPermission() }
        for _ in 0..<100 where client.permissionContinuations.count < 2 { await Task.yield() }
        #expect(client.permissionContinuations.count == 2)
        for _ in 0..<20 { await Task.yield() }
        #expect(store.activeResourceCount == 2)
        var stopped = false
        let stopping = Task { await store.deactivate(); stopped = true }
        for _ in 0..<20 { await Task.yield() }
        #expect(!stopped)
        #expect(store.activeResourceCount == 2)
        let queriesBeforeReply = client.authorizationQueries
        client.permissionContinuations.removeFirst().resume(returning: true)
        await first.value
        for _ in 0..<20 { await Task.yield() }
        #expect(!stopped)
        #expect(store.activeResourceCount == 1)
        client.permissionContinuations.removeFirst().resume(returning: true)
        await second.value
        await stopping.value
        #expect(stopped)
        #expect(store.activeResourceCount == 0)
        #expect(!store.state.notifications)
        #expect(client.authorizationQueries == queriesBeforeReply)
        #expect(client.addCalls == 0)
        #expect(client.requests.isEmpty)
    }

    @Test func dstDeactivationWaitsForHeldAuthorizationQueryWithoutRestartingWork() async {
        let (defaults, cleanup) = lensTestDefaults()
        defer { cleanup() }
        let client = FakeLensNotifications()
        client.suspendAuthorization = true
        let clock = LensTestClock()
        let store = DSTWatchStore(defaults: defaults, notificationClient: client, now: { clock.now }, factsProvider: { _, _ in
            [DSTTransitionFact(zone: "Europe/London", transitionAt: 100000, before: 0, after: 3600)]
        }, observeSystemEvents: false)
        store.setEnabled(true)
        for _ in 0..<100 where client.authorizationContinuations.isEmpty { await Task.yield() }
        #expect(client.authorizationContinuations.count == 1)
        #expect(store.activeResourceCount == 3) // Daily task, refresh task, and native authorization query.
        var stopped = false
        let stopping = Task { await store.deactivate(); stopped = true }
        for _ in 0..<20 { await Task.yield() }
        #expect(!stopped)
        #expect(store.activeResourceCount == 2)
        client.authorizationContinuations.removeFirst().resume(returning: .authorized)
        await stopping.value
        #expect(stopped)
        #expect(store.activeResourceCount == 0)
        #expect(!store.state.enabled)
        #expect(client.addCalls == 0)
        #expect(client.requests.isEmpty)
    }

    @Test func dstDefaultDoesNotComputeAndEnabledWatchUsesSystemFacts() async {
        let (defaults, cleanup) = lensTestDefaults()
        defer { cleanup() }
        var calls = 0
        let clock = LensTestClock()
        let client = FakeLensNotifications()
        let store = DSTWatchStore(defaults: defaults, notificationClient: client, now: { clock.now }, factsProvider: { _, _ in
            calls += 1
            return [DSTTransitionFact(zone: "Australia/Lord_Howe", transitionAt: 100000, before: 39600, after: 37800)]
        }, observeSystemEvents: false)
        store.configure(zones: [TimeZoneEntry(timezoneID: "Australia/Lord_Howe", cityName: "Lord Howe")])
        #expect(calls == 0)
        #expect(store.activeResourceCount == 0)
        store.setEnabled(true)
        await store.waitUntilSettled()
        #expect(calls == 1)
        #expect(store.upcoming.first?.shift == -1800)
        #expect(client.requests.count == 1)
        #expect(client.authorizationRequests == 0)
        #expect(store.activeResourceCount == 1)
        await store.deactivate()
        #expect(store.activeResourceCount == 0)
    }

    /// 通知正文里的钟点按设置的小时制（ClockText），不再各自 new DateFormatter。
    @Test func dstNoticeBodyFollowsTheHourStyle() async {
        let (defaults, cleanup) = lensTestDefaults()
        defer { cleanup() }
        let clock = LensTestClock()
        let client = FakeLensNotifications()
        // 2026-10-25 01:00 UTC：伦敦退出夏令时（02:00 BST → 01:00 GMT）；换钟那一刻按新偏移显示，是 1:00。
        // 时钟拨到换钟前 30 天：只有 400 天内、提前量之前的调整才会安排通知。
        let transition = 1_792_890_000.0
        clock.facts.wall = transition - 30 * 86_400
        let store = DSTWatchStore(defaults: defaults, notificationClient: client, now: { clock.now }, factsProvider: { _, _ in
            [DSTTransitionFact(zone: "Europe/London", transitionAt: transition, before: 3600, after: 0)]
        }, observeSystemEvents: false)
        store.configure(zones: [TimeZoneEntry(timezoneID: "Europe/London", cityName: "London")],
                        locale: Locale(identifier: "en_US"), hourStyle: .force12)
        store.setEnabled(true)
        await store.waitUntilSettled()
        let body = client.requests.values.first?.body ?? ""
        let london = TimeZone(identifier: "Europe/London")!
        let en = Locale(identifier: "en_US")
        // 正文里的日期钟点 = ClockText 的输出（日期按界面语言 en，钟点按本机系统 locale + 小时制）。
        let twelve = ClockText.dateTime(Date(timeIntervalSince1970: transition), in: london, hourStyle: .force12, locale: en)
        let twentyFour = ClockText.dateTime(Date(timeIntervalSince1970: transition), in: london, hourStyle: .force24, locale: en)
        #expect(twelve != twentyFour)
        // 年份按 ClockText.day 的规则只在不是今年时写，这里只钉「按界面语言」这一层。
        #expect(body.contains("Oct 25"), "日期按界面语言：\(body)")
        #expect(body.contains(twelve) && !body.contains(twentyFour), "12 小时制：\(body)")
        // 改成 24 小时制后重新配置，正文跟着变。
        store.configure(zones: [TimeZoneEntry(timezoneID: "Europe/London", cityName: "London")],
                        locale: en, hourStyle: .force24)
        await store.waitUntilSettled()
        let updated = client.requests.values.first?.body ?? ""
        #expect(updated.contains(twentyFour) && !updated.contains(twelve), "24 小时制：\(updated)")
        await store.deactivate()
    }

    @Test func dstDeniedAuthorizationKeepsPredictionsAndCanLaterBeGranted() async {
        let (defaults, cleanup) = lensTestDefaults()
        defer { cleanup() }
        let clock = LensTestClock()
        let client = FakeLensNotifications()
        client.access = .denied
        let store = DSTWatchStore(defaults: defaults, notificationClient: client, now: { clock.now }, factsProvider: { _, _ in
            [DSTTransitionFact(zone: "Europe/London", transitionAt: 100000, before: 0, after: 3600)]
        }, observeSystemEvents: false)
        store.setEnabled(true)
        await store.waitUntilSettled()
        #expect(store.upcoming.count == 1)
        #expect(client.requests.isEmpty)
        #expect(client.authorizationRequests == 0)
        await store.requestNotificationPermission()
        await store.waitUntilSettled()
        #expect(client.authorizationRequests == 1)
        #expect(client.requests.count == 1)
        await store.deactivate()
    }

    @Test func dstDeactivationPreservesTimerRequestsAndStopsDailyWork() async {
        let (defaults, cleanup) = lensTestDefaults()
        defer { cleanup() }
        let clock = LensTestClock()
        let client = FakeLensNotifications()
        client.requests["meantime.timer.keep"] = LensNotificationRequest(id: "meantime.timer.keep", fireAt: clock.now.addingTimeInterval(500), title: "", body: "")
        let store = DSTWatchStore(defaults: defaults, notificationClient: client, now: { clock.now }, factsProvider: { _, _ in
            [DSTTransitionFact(zone: "Europe/London", transitionAt: 100000, before: 0, after: 3600)]
        }, observeSystemEvents: false)
        store.setEnabled(true)
        await store.waitUntilSettled()
        #expect(client.requests.count == 2)
        await store.deactivate()
        #expect(client.requests.keys.sorted() == ["meantime.timer.keep"])
        #expect(store.activeResourceCount == 0)
    }

    @Test func dstDailyRefreshDoesNotReplayPreviouslySubmittedNotice() async {
        let (defaults, cleanup) = lensTestDefaults()
        defer { cleanup() }
        let clock = LensTestClock()
        let client = FakeLensNotifications()
        let store = DSTWatchStore(defaults: defaults, notificationClient: client, now: { clock.now }, factsProvider: { _, _ in
            [DSTTransitionFact(zone: "Europe/London", transitionAt: 100000, before: 0, after: 3600)]
        }, observeSystemEvents: false)
        store.setEnabled(true)
        await store.waitUntilSettled()
        #expect(store.state.receipts.count == 1)
        let added = client.addCalls
        clock.facts.wall = 90000
        client.requests.removeAll()
        store.refresh()
        await store.waitUntilSettled()
        #expect(client.addCalls == added)
        #expect(store.upcoming.count == 1)
        await store.deactivate()
    }

    @Test func dstSystemFactsIncludeLordHoweHalfHourAndDoNotInventUtcChanges() {
        let start = ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")!
        let facts = DSTTransitionFact.systemFacts(zones: ["Australia/Lord_Howe", "UTC"], now: start)
        #expect(facts.contains { $0.zone == "Australia/Lord_Howe" && $0.after - $0.before == -1800 })
        #expect(!facts.contains { $0.zone == "UTC" })
    }
}

@MainActor
struct AlarmCatalogExampleTests {
    @Test(arguments: ["zh-Hans", "zh-Hant", "en", "de", "es", "fr", "it", "ja", "ko", "nl", "pl", "pt-BR", "ru", "tr", "ar", "hi"])
    func translatedHintNamesTomorrowAtNineInTokyo(language: String) throws {
        let text = L10n.string("明天 9:00 东京", locale: Locale(identifier: language))
        let now = ISO8601DateFormatter().date(from: "2026-10-03T00:00:00Z")!
        let reading = AlarmReading.resolve(text, now: now, home: TimeZone(identifier: "America/Los_Angeles")!,
                                          preferredZones: ["Asia/Tokyo"])
        let item = try #require(reading.item)
        #expect(item.problem == nil)
        #expect(item.zoneWritten)
        #expect(item.zone.identifier == "Asia/Tokyo")
        #expect(item.intervals.count == 1)
        let interval = try #require(item.intervals.first)
        #expect(interval.start == ISO8601DateFormatter().date(from: "2026-10-04T00:00:00Z")!)
    }
}


extension TimerDSTLifecycleTests {
    @Test func singleParseAlarmRetainsTheWriterLocation() throws {
        let formatter = ISO8601DateFormatter()
        let now = try #require(formatter.date(from: "2026-09-24T12:00:00Z"))
        let expected = try #require(formatter.date(from: "2026-09-24T13:00:00Z"))
        let reading = AlarmReading.resolve("I'm in Berlin, 3pm my time", now: now, home: .gmt)
        let item = try #require(reading.item)
        #expect(reading.count == 1)
        #expect(item.problem == nil)
        #expect(item.zoneOption.id == "writer:Europe/Berlin")
        #expect(item.intervals.map(\.start) == [expected])
        #expect(item.notes.contains { if case .localIsTheWriter = $0 { true } else { false } })
        #expect(!reading.advanced)
    }

    @Test func alarmNextOccurrenceUsesAWholeCivilDayAcrossSpringForward() throws {
        let formatter = ISO8601DateFormatter()
        let now = try #require(formatter.date(from: "2026-03-07T18:00:00Z"))
        let expected = try #require(formatter.date(from: "2026-03-08T16:00:00Z"))
        let nextReference = try #require(formatter.date(from: "2026-03-08T17:00:00Z"))
        let zone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let reading = AlarmReading.resolve("9:00", now: now, home: zone)
        #expect(reading.count == 1)
        #expect(reading.advanced)
        #expect(reading.item?.problem == nil)
        #expect(reading.item?.intervals.map(\.start) == [expected])
        #expect(reading.reference == nextReference)
        #expect(reading.reference.timeIntervalSince(now) == 23 * 3600)
    }
}

@MainActor
struct VietnameseRepeatedAlarmYearTests {
    private func assertBothOccurrences(_ text: String) throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-01T12:00:00Z"))
        let result = AlarmReading.resolve(text, now: now, home: .gmt, preferredZones: ["America/Los_Angeles"])
        let item = try #require(result.item)
        #expect(item.reading.date == .absolute(year: 2030, month: 11, day: 3), "\(text)")
        #expect(item.day?.year == 2030, "\(text)")
        #expect(item.problem == nil, "\(text): \(item)")
        #expect(item.zone.identifier == "America/Los_Angeles", "\(text): \(item)")
        try #require(item.intervals.count == 2, "\(text): \(item)")
        let first = try #require(ISO8601DateFormatter().date(from: "2030-11-03T08:30:00Z"))
        let second = try #require(ISO8601DateFormatter().date(from: "2030-11-03T09:30:00Z"))
        #expect(item.intervals.map(\.start) == [first, second], "\(text): \(item)")
        let calendar = Calendar.gregorianUTC(item.zone)
        for interval in item.intervals {
            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: interval.start)
            #expect(components.year == 2030 && components.month == 11 && components.day == 3, "\(text)")
            #expect(components.hour == 1 && components.minute == 30, "\(text)")
        }
    }

    @Test(arguments: [
        "Los Angeles ngày 3 tháng 11, 2030 1:30",
        "Los Angeles ngày 3 tháng 11 2030 1:30",
        "Los Angeles Ngày 3 tháng 11, 2030 1:30",
        "Los Angeles 3 tháng 11, 2030 1:30",
        "Los Angeles 3 tháng 11 2030 1:30",
        "Los Angeles ngày 3 tháng 11 năm 2030 1:30",
        "Los Angeles ngày 3 tháng 11, năm 2030 1:30",
    ])
    func writtenYearSurvivesEveryVietnameseCalendarForm(_ text: String) throws {
        try assertBothOccurrences(text)
    }

    @Test func platformGeneratedVietnameseLongDateKeepsItsYear() throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "vi")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone.gmt
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        let date = try #require(ISO8601DateFormatter().date(from: "2030-11-03T12:00:00Z"))
        let written = formatter.string(from: date)
        #expect(written.contains("2030"), "\(written)")
        try assertBothOccurrences(["Los Angeles", written, "1:30"].joined(separator: " "))
    }
}
