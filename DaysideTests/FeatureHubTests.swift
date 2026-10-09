// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import Dayside

@MainActor
struct FeatureHubTests {
    /// 面板入口不提前创建模块，重复进入保留原模块与用户偏好。
    @Test func panelMeetingEntryPreservesLazyModulesAndSharedPreferences() async {
        await withFixture { f in
            f.hub.attach(to: f.model)
            let settings = f.model.settings
            let modules = Set(f.hub.modules.keys)
            let resources = f.hub.activeResourceCount
            f.hub.showPlannerFromPanel()
            #expect(f.hub.selection == .planner)
            #expect(Set(f.hub.modules.keys) == modules)
            #expect(f.hub.activeResourceCount == resources)
            #expect(f.model.settings == settings)

            let planner: PlannerModule = f.hub.openModule(.planner, as: PlannerModule.self)
            let openedModules = Set(f.hub.modules.keys)
            let request = f.hub.panelPlannerRequest
            f.hub.showPlannerFromPanel()
            #expect(f.hub.panelPlannerRequest != request)
            #expect(f.hub.module(.planner, as: PlannerModule.self) === planner)
            #expect(Set(f.hub.modules.keys) == openedModules)
            #expect(f.model.settings == settings)
            #expect(f.hub.activeResourceCount == resources)
        }
    }

    @Test func userDefaultsWrappersForOneSuiteDoNotEstablishIdentity() {
        let (suite, cleanup) = TestDefaults.makeSuiteName(prefix: "meantime.hub.identity")
        defer { cleanup() }
        let first = UserDefaults(suiteName: suite)!
        let second = UserDefaults(suiteName: suite)!
        #expect(first !== second)
        first.set("same domain", forKey: "probe")
        #expect(second.string(forKey: "probe") == "same domain")
    }

    @Test func injectedHubDefaultsToNoSystemSurfacesOrPermissionWork() async {
        await withFixture { f in
            #expect(f.hub.activeResourceCount == 0)
            f.hub.attach(to: f.model)
            f.hub.setVisible(true)
            f.hub.setVisible(false)
            #expect(f.hub.activeResourceCount == 0)
            #expect(f.agendaService.factories == 0)
            #expect(f.agendaService.permissionRequests == 0)
            #expect(await f.contacts.requests == 0)
            #expect(f.notifications.authorizationRequests == 0)
            #expect(f.notifications.added.isEmpty)
        }
    }

    @Test func repeatedAttachmentUsesTheOriginalLiveModel() async {
        await withFixture { f in
            f.hub.attach(to: f.model)
            f.hub.attach(to: f.model)
            let other = AppModel(defaults: f.defaults, migrate: false,
                                 applySystemIntegration: false)
            f.hub.attach(to: other)
            let target = f.model.zones[1]
            #expect(f.hub.handle(.init(action: "primary", arguments: ["id": target.id.uuidString])))
            #expect(f.model.zones.first?.id == target.id)
            #expect(other.zones.first?.id != target.id)
            #expect(f.hub.activeResourceCount == 0)
        }
    }

    @Test func primaryClockAcceptsATimeZoneIdentifierFromCatalogConfiguredControls() async {
        await withFixture { f in
            f.hub.attach(to: f.model)
            let target = f.model.zones[1]
            #expect(f.hub.handle(.init(action: "primary", arguments: ["timeZoneID": target.timezoneID])))
            #expect(f.model.zones.first?.id == target.id)
            #expect(!f.hub.handle(.init(action: "primary", arguments: ["timeZoneID": "Antarctica/Troll"])))
            #expect(f.hub.automationError == "unknownPlace")
            #expect(!f.hub.handle(.init(action: "primary", arguments: ["timeZoneID": "Not/AZone"])))
        }
    }

    @Test func timeZoneCatalogSearchesCitiesWithoutAnySharedContainer() async throws {
        #expect(TimeZonePlaceCatalog.search("tokyo").first == "Asia/Tokyo")
        #expect(TimeZonePlaceCatalog.search("Los Ang").first == "America/Los_Angeles")
        #expect(TimeZonePlaceCatalog.search("utc").contains("UTC"))
        #expect(TimeZonePlaceCatalog.search("zzzz-nothing").isEmpty)
        #expect(TimeZonePlaceCatalog.search("").count == TimeZonePlaceCatalog.suggestedIdentifiers.count)
        #expect(TimeZonePlaceCatalog.cityName("Asia/Tokyo", locale: Locale(identifier: "zh-Hans")) == "东京")
        #expect(TimeZonePlaceCatalog.cityName("Asia/Tokyo", locale: Locale(identifier: "en")) == "Tokyo")
        #expect(TimeZonePlaceCatalog.rawCity("America/Argentina/Buenos_Aires") == "Buenos Aires")
        let query = TimeZonePlaceQuery()
        #expect(try await query.entities(for: ["Asia/Tokyo", "Bad/Zone"]).map(\.id) == ["Asia/Tokyo"])
        #expect(try await query.entities(matching: "berlin").first?.id == "Europe/Berlin")
    }

    @Test func travelSwitchesOnlyAfterAnOptedInSystemTimeZoneChange() async {
        await withFixture { f in
            f.hub.attach(to: f.model)
            let original = f.model.zones.first!.id
            f.hub.travel.setAutoSwitchEnabled(true)
            f.model.onSystemChange?()
            #expect(f.model.zones.first?.id == original)
            f.clock.zone = TimeZone(identifier: "Asia/Tokyo")!
            f.model.onSystemChange?()
            #expect(f.model.zones.first?.timezoneID == "Asia/Tokyo")
            let london = f.model.zones.firstIndex { $0.timezoneID == "Europe/London" }!
            f.model.moveZones(from: IndexSet(integer: london), to: 0)
            f.model.settings.interfaceLanguage = .fr
            f.model.onSystemChange?()
            #expect(f.model.zones.first?.timezoneID == "Europe/London")
            f.clock.zone = TimeZone(identifier: "Pacific/Auckland")!
            f.model.onSystemChange?()
            #expect(f.model.zones.first?.timezoneID == "Europe/London")
        }
    }

    @Test func travelKeepsOrderWhenAutomaticSwitchingIsOff() async {
        await withFixture { f in
            f.hub.attach(to: f.model)
            let before = f.model.zones.map(\.id)
            f.clock.zone = TimeZone(identifier: "Asia/Tokyo")!
            f.model.onSystemChange?()
            #expect(f.model.zones.map(\.id) == before)
        }
    }

    @Test func closingTimerWorkspaceStopsRefreshAndPreservesTheSession() async {
        await withFixture { f in
            f.hub.attach(to: f.model)
            f.hub.selection = .timers
            f.hub.timers.start(TimerSpec())
            let identifier = f.hub.timers.state.session?.id
            f.hub.setVisible(true)
            #expect(f.hub.timers.activeResourceCount == 1)
            f.hub.setVisible(false)
            await f.hub.timers.waitUntilSettled()
            #expect(f.hub.activeResourceCount == 0)
            #expect(f.hub.timers.state.session?.id == identifier)
            f.clock.facts.wall += 75
            f.clock.facts.continuous += 75
            f.hub.setVisible(true)
            #expect(f.hub.timers.presentation?.seconds == 225)
            f.hub.selection = .people
            f.hub.setVisible(true)
            await f.hub.timers.waitUntilSettled()
            #expect(f.hub.timers.activeResourceCount == 0)
        }
    }

    @Test func enabledAgendaDSTAndContactsReleaseTheirRealJobsOnShutdown() async {
        await withFixture { f in
            f.hub.attach(to: f.model)
            f.hub.agenda.setEnabled(true)
            f.hub.dstWatch.setEnabled(true)
            f.hub.people.beginContactsImport()
            await settle { f.hub.agenda.state == .ready }
            await f.hub.dstWatch.waitUntilSettled()
            await settle { await f.contacts.isSuspended }
            #expect(f.agendaService.permissionRequests == 1)
            #expect(f.hub.agenda.activeResourceCount > 0)
            #expect(f.hub.dstWatch.activeResourceCount > 0)
            #expect(f.hub.people.activeResourceCount == 1)
            f.hub.agenda.setEnabled(false)
            await f.hub.agenda.waitUntilSettled()
            await f.hub.dstWatch.deactivate()
            f.hub.people.deactivate()
            #expect(f.hub.people.activeResourceCount == 1)
            await f.contacts.finish()
            await settle { f.hub.people.activeResourceCount == 0 }
            #expect(f.hub.activeResourceCount == 0)
            #expect(f.hub.people.contacts.isEmpty)
            #expect(f.notifications.authorizationRequests == 0)
        }
    }

    @Test func agendaCancellationRemainsCountedUntilTheReadAcknowledgesIt() async {
        await withFixture { f in
            f.agendaService.holdRead = true
            f.hub.attach(to: f.model)
            f.hub.agenda.setEnabled(true)
            await settle { f.agendaService.pendingRead != nil }
            let stopped = Task { await f.hub.agenda.deactivateAndWait() }
            await settle { !f.hub.agenda.isActive }
            #expect(f.hub.activeResourceCount == 1)
            f.agendaService.finishRead()
            await stopped.value
            #expect(f.hub.activeResourceCount == 0)
            #expect(f.hub.agenda.snapshot == nil)
        }
    }

    @Test func eitherWindowKeepsTheSharedClockAliveAndClosingBothStopsIt() async {
        await withFixture { f in
            f.hub.attach(to: f.model)
            f.model.settings.showSeconds = true
            f.model.setPanelVisible(true)
            f.hub.setVisible(true)
            f.hub.setVisible(false)
            let panelOnly = f.model.now
            _ = await SharedClockEvents.next(in: f.model.core, after: panelOnly)
            #expect(f.model.now > panelOnly)
            f.hub.setVisible(true)
            f.model.setPanelVisible(false)
            let workspaceOnly = f.model.now
            _ = await SharedClockEvents.next(in: f.model.core, after: workspaceOnly)
            #expect(f.model.now > workspaceOnly)
            f.hub.setVisible(false)
            let closed = f.model.now
            try? await Task.sleep(for: .milliseconds(1150))
            #expect(f.model.now == closed)
            #expect(f.hub.activeResourceCount == 0)
        }
    }

    @Test func everyPageAndTimerEntranceIsAvailable() async {
        await withFixture { f in
            f.hub.attach(to: f.model)
            for feature in FeatureSelection.allCases {
                #expect(f.hub.allows(feature))
                #expect(f.hub.handle(.init(action: "tools", arguments: ["feature": feature.rawValue])))
                #expect(f.hub.automationError == nil)
            }
            #expect(f.hub.startTimer(TimerSpec()))
            #expect(f.hub.timers.state.session != nil)
            f.hub.timers.cancel()
            #expect(f.hub.handle(.init(action: "pomodoro")))
            #expect(f.hub.timers.state.session?.spec.mode == "pomodoro")
            f.hub.timers.cancel()
            f.hub.handle(url: URL(string: "dayside://timer?minutes=5")!)
            #expect(f.hub.automationError == nil)
            #expect(f.hub.timers.state.session?.spec.duration == 300)
            #expect(f.notifications.authorizationRequests == 0)
            #expect(f.agendaService.factories == 0)
            #expect(await f.contacts.requests == 0)
            #expect(f.hub.handle(.init(action: "convert", arguments: ["text": "14:00 UTC"])))
            #expect(f.hub.conversionText == "14:00 UTC")
            #expect(TimeInput.resolve(f.hub.conversionText, relativeTo: f.clock.now, in: .gmt).dates.count == 1)
        }
    }

    @Test func savedAgendaStartsWithoutAnotherPermissionRequest() async {
        await withFixture(agendaInitiallyEnabled: true) { f in
            f.agendaService.authorization = .fullAccess
            let stored = f.defaults.data(forKey: AgendaStore.preferencesKey)
            f.hub.attach(to: f.model)
            #expect(f.hub.agenda.isEnabled)
            #expect(f.hub.agenda.isActive)
            await settle { f.hub.agenda.state == .ready }
            #expect(f.agendaService.factories == 1)
            #expect(f.agendaService.permissionRequests == 0)
            #expect(f.defaults.data(forKey: AgendaStore.preferencesKey) == stored)
            await f.hub.agenda.deactivateAndWait()
            #expect(!f.hub.agenda.isActive)
            #expect(f.hub.agenda.isEnabled)
            #expect(f.hub.agenda.snapshot == nil)
            #expect(f.hub.activeResourceCount == 0)
            #expect(f.defaults.data(forKey: AgendaStore.preferencesKey) == stored)
        }
    }

    @Test func coldStartRetainsTimerAndReplacesOnlyItsEarlierNotifications() async {
        await withFixture(timerInitiallyRunning: true) { f in
            let stored = f.defaults.data(forKey: TimerStore.storageKey)
            let timer = f.hub.timers.state.session
            #expect(timer != nil)
            #expect(f.hub.activeResourceCount == 0)
            f.notifications.added["meantime.timer.previous"] = LensNotificationRequest(id: "meantime.timer.previous",
                fireAt: f.clock.now.addingTimeInterval(100), title: "Old timer", body: "")
            f.notifications.added["other.feature.notice"] = LensNotificationRequest(id: "other.feature.notice",
                fireAt: f.clock.now.addingTimeInterval(100), title: "Keep", body: "")
            f.hub.attach(to: f.model)
            f.hub.selection = .timers
            f.hub.setVisible(true)
            await f.hub.timers.waitUntilSettled()
            #expect(f.hub.timers.activeResourceCount == 1)
            #expect(f.hub.timers.state.session == timer)
            #expect(f.hub.timers.state.notifications)
            #expect(f.defaults.data(forKey: TimerStore.storageKey) == stored)
            #expect(f.notifications.added["meantime.timer.previous"] == nil)
            #expect(f.notifications.added["other.feature.notice"] != nil)
            #expect(f.notifications.pendingReads == 1)
            #expect(f.notifications.authorizationReads == 1)
            #expect(f.notifications.authorizationRequests == 0)
            f.hub.refreshSnapshot()
            #expect(f.hub.timers.activeResourceCount == 1)
            f.hub.setVisible(false)
            await f.hub.timers.waitUntilSettled()
            #expect(f.hub.timers.activeResourceCount == 0)
        }
    }

    private func settle(_ condition: @MainActor () async -> Bool) async {
        for _ in 0..<400 { if await condition() { return }; await Task.yield() }
        #expect(await condition())
    }

    private func withFixture(agendaInitiallyEnabled: Bool = false,
                             timerInitiallyRunning: Bool = false, _ body: @MainActor (HubFixture) async -> Void) async {
        let fixture = HubFixture(agendaInitiallyEnabled: agendaInitiallyEnabled,
                                 timerInitiallyRunning: timerInitiallyRunning)
        await body(fixture)
        await fixture.close()
    }
}

@MainActor
private final class HubFixture {
    private let handle = TestDefaults.make(prefix: "meantime.feature-hub.tests")
    let defaults: UserDefaults
    let clock = HubTestClock()
    let notifications = HubNotifications()
    let contacts = HubContacts()
    let agendaService = HubAgendaService()
    let model: AppModel
    let hub: FeatureHub

    init(agendaInitiallyEnabled: Bool = false, timerInitiallyRunning: Bool = false) {
        defaults = handle.defaults
        if agendaInitiallyEnabled {
            defaults.set(try! JSONEncoder().encode(AgendaPreferences(isEnabled: true, showInMenuBar: true,
                selectedCalendarIDs: ["work"], days: 3)), forKey: AgendaStore.preferencesKey)
        }
        Store.saveZones([
            TimeZoneEntry(timezoneID: "Europe/London", cityName: "London"),
            TimeZoneEntry(timezoneID: "Asia/Tokyo", cityName: "Tokyo"),
            TimeZoneEntry(timezoneID: "America/Los_Angeles", cityName: "Los Angeles")
        ], to: defaults)
        model = AppModel(defaults: defaults, migrate: false,
                         applySystemIntegration: false)
        let service = agendaService, clock = clock
        let agenda = AgendaStore(defaults: defaults, makeService: {
            service.factories += 1
            return service
        }, now: { clock.now }, timeZone: { clock.zone }, openURL: { _ in false })
        let people = PeopleStore(defaults: defaults, contactsReader: contacts)
        if timerInitiallyRunning {
            let seed = TimerStore(defaults: defaults, notificationClient: notifications, clock: { clock.facts },
                                  observeSystemEvents: false, runtimeEnabled: false)
            seed.start(TimerSpec())
            seed.setNotificationsEnabled(true)
        }
        let timers = TimerStore(defaults: defaults, notificationClient: notifications,
                                clock: { clock.facts }, observeSystemEvents: false, runtimeEnabled: false)
        let dst = DSTWatchStore(defaults: defaults, notificationClient: notifications, now: { clock.now },
                                factsProvider: { _, now in
            [DSTTransitionFact(zone: "Europe/London", transitionAt: now.timeIntervalSince1970 + 604_800,
                               before: 3600, after: 0)]
        }, observeSystemEvents: false)
        hub = FeatureHub(defaults: defaults, dstWatch: dst, now: { clock.now }, timeZone: { clock.zone })
        FeatureModules.install(into: hub, agenda: agenda, people: people, timers: timers, travel: TravelStore(defaults: defaults))
    }

    func close() async {
        hub.setVisible(false)
        model.setPanelVisible(false)
        agendaService.finishRead()
        await contacts.finish()
        await hub.agenda.deactivateAndWait()
        hub.people.deactivate()
        await hub.timers.deactivate()
        await hub.dstWatch.deactivate()
        for _ in 0..<400 where hub.people.activeResourceCount != 0 { await Task.yield() }
        #expect(hub.activeResourceCount == 0)
        handle.cleanup()
    }
}

@MainActor
private final class HubTestClock {
    var facts = TimerClockFacts(wall: 1_789_000_000, continuous: 100, bootID: "hub-test")
    var now: Date { Date(timeIntervalSince1970: facts.wall) }
    var zone = TimeZone(identifier: "America/Los_Angeles")!
}

@MainActor
private final class HubNotifications: LensNotificationClient {
    var authorizationRequests = 0
    var authorizationReads = 0
    var pendingReads = 0
    var added: [String: LensNotificationRequest] = [:]
    func authorization() async -> LensNotificationAccess { authorizationReads += 1; return .authorized }
    func requestAuthorization() async throws -> Bool { authorizationRequests += 1; return true }
    func pendingIdentifiers() async -> [String] { pendingReads += 1; return Array(added.keys) }
    func deliveredIdentifiers() async -> [String] { [] }
    func add(_ request: LensNotificationRequest) async throws { added[request.id] = request }
    func removePending(_ identifiers: [String]) { identifiers.forEach { added[$0] = nil } }
    func removeDelivered(_ identifiers: [String]) {}
}

private actor HubContacts: PeopleContactsReading {
    private(set) var requests = 0
    private var continuation: CheckedContinuation<[PeopleContactCandidate], Never>?
    var isSuspended: Bool { continuation != nil }
    func candidates() async throws -> [PeopleContactCandidate] {
        requests += 1
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish() {
        let pending = continuation; continuation = nil
        pending?.resume(returning: [PeopleContactCandidate(id: "fake", name: "Test contact")])
    }
}

@MainActor
private final class HubAgendaService: AgendaService {
    var authorization = AgendaAuthorization.notDetermined
    var factories = 0
    var permissionRequests = 0
    var holdRead = false
    private var observing = false
    private(set) var pendingRead: CheckedContinuation<AgendaSnapshot, any Error>?
    private var pendingSnapshot: AgendaSnapshot?
    var activeResourceCount: Int { observing ? 1 : 0 }
    func requestFullAccess() async throws -> Bool {
        permissionRequests += 1
        authorization = .fullAccess
        return true
    }
    func snapshot(in interval: DateInterval, calendarIDs: [String]?) async throws -> AgendaSnapshot {
        let value = AgendaSnapshot(calendars: [.init(id: "work", title: "Work", sourceTitle: "Fixture")], events: [], interval: interval)
        if holdRead {
            pendingSnapshot = value
            return try await withCheckedThrowingContinuation { pendingRead = $0 }
        }
        return value
    }
    func observeChanges(_ receive: @escaping @MainActor @Sendable () -> Void) { observing = true }
    func stop() { observing = false }
    func finishRead() {
        let pending = pendingRead, snapshot = pendingSnapshot
        pendingRead = nil; pendingSnapshot = nil
        if let snapshot { pending?.resume(returning: snapshot) }
    }
}
