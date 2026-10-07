// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Foundation
import Testing
@testable import TahoeTime

@MainActor
struct AgendaMenuBarReaderTests {
    @Test(arguments: [AgendaAuthorization.notDetermined, .writeOnly, .denied, .restricted])
    func launchWithInsufficientAccessNeverReads(authorization: AgendaAuthorization) throws {
        let fixture = MenuReaderFixture()
        fixture.authorization = authorization
        try fixture.seed(enabled: true, menuBar: true)
        fixture.reader.synchronizePreferences()
        #expect(fixture.reader.isActive)
        #expect(fixture.reads.isEmpty)
        #expect(fixture.reader.nextMeeting(now: fixture.now) == nil)
        #expect(fixture.reader.nextRefreshAt == fixture.now.addingTimeInterval(900))
    }

    @Test(arguments: [(false, false), (false, true), (true, false)])
    func launchNeedsBothSavedOptions(enabled: Bool, menuBar: Bool) throws {
        let fixture = MenuReaderFixture()
        try fixture.seed(enabled: enabled, menuBar: menuBar)
        fixture.reader.synchronizePreferences()
        #expect(!fixture.reader.isActive)
        #expect(fixture.reads.isEmpty)
        #expect(fixture.reader.activeResourceCount == 0)
    }

    @Test(arguments: [
        ("2026-03-08T12:00:00Z", "America/Los_Angeles", 601_200.0),
        ("2026-03-08T12:00:00Z", "Etc/UTC", 604_800.0),
        ("2026-11-01T12:00:00Z", "America/Los_Angeles", 608_400.0),
    ])
    func readerIgnoresLegacyDaysAndReadsSevenCivilDays(iso: String, zone: String, duration: Double) throws {
        let fixture = MenuReaderFixture()
        fixture.now = ISO8601DateFormatter().date(from: iso)!
        fixture.zone = TimeZone(identifier: zone)!
        try fixture.seed(enabled: true, menuBar: true, days: 1)
        fixture.reader.synchronizePreferences()
        #expect(fixture.reads.count == 1)
        #expect(fixture.reads[0].interval.duration == duration)
        #expect(fixture.reads[0].calendarIDs == nil)
        #expect(fixture.authorizationChecks == 2)
    }

    @Test func rustFiltersCalendarAllDayCancellationDeclineAndElapsedEvents() throws {
        let fixture = MenuReaderFixture()
        fixture.events = [
            fixture.event("excluded-calendar", start: -100, calendar: "home"),
            fixture.event("all-day", start: -100, allDay: true),
            fixture.event("cancelled", start: -100, cancelled: true),
            fixture.event("declined", start: -100, declined: true),
            fixture.event("ended", start: -2000, duration: 100),
            fixture.event("chosen", start: 300),
        ]
        try fixture.seed(enabled: true, menuBar: true, calendars: ["work"])
        fixture.reader.synchronizePreferences()
        #expect(fixture.reads.first?.calendarIDs == ["work"])
        #expect(fixture.reader.nextMeeting(now: fixture.now)?.title == "chosen")
        #expect(fixture.reader.menuBarMeeting(now: fixture.now) == fixture.reader.nextMeeting(now: fixture.now))
        #expect(fixture.liveNativeResources == 0)
        #expect(fixture.completedReads == 1)
    }

    @Test func preferenceChangesRefreshAndDisableDropsCachedMeeting() throws {
        let fixture = MenuReaderFixture()
        fixture.events = [fixture.event("meeting", start: 300)]
        try fixture.seed(enabled: true, menuBar: true)
        fixture.reader.synchronizePreferences()
        fixture.reader.synchronizePreferences()
        #expect(fixture.reads.count == 1)
        try fixture.seed(enabled: true, menuBar: true, calendars: [])
        fixture.reader.synchronizePreferences()
        #expect(fixture.reads.count == 2)
        #expect(fixture.reader.nextMeeting(now: fixture.now) == nil)
        try fixture.seed(enabled: true, menuBar: false)
        fixture.reader.synchronizePreferences()
        #expect(!fixture.reader.isActive)
        #expect(fixture.reader.nextRefreshAt == nil)
        #expect(fixture.reader.activeResourceCount == 0)
        #expect(fixture.reader.menuBarMeeting(now: fixture.now) == nil)
    }

    @Test func clockTicksOnlyReadAtStartEndOrTheFifteenMinuteCap() throws {
        let fixture = MenuReaderFixture()
        let initial = fixture.now
        fixture.events = [fixture.event("first", start: 300, duration: 1200), fixture.event("second", start: 1800)]
        try fixture.seed(enabled: true, menuBar: true)
        fixture.reader.synchronizePreferences()
        #expect(fixture.reader.nextRefreshAt == initial.addingTimeInterval(300))
        fixture.now = initial.addingTimeInterval(120)
        fixture.reader.clockDidChange(now: fixture.now)
        #expect(fixture.reader.nextMeeting(now: fixture.now)?.minutesUntilStart == 3)
        #expect(fixture.reads.count == 1)
        #expect(fixture.authorizationChecks == 2)
        fixture.now = initial.addingTimeInterval(300)
        fixture.reader.clockDidChange(now: fixture.now)
        #expect(fixture.reads.count == 2)
        #expect(fixture.reader.nextMeeting(now: fixture.now)?.isOngoing == true)
        #expect(fixture.reader.nextRefreshAt == initial.addingTimeInterval(1200))
        fixture.now = initial.addingTimeInterval(1200)
        fixture.reader.clockDidChange(now: fixture.now)
        #expect(fixture.reads.count == 3)
        #expect(fixture.reader.nextRefreshAt == initial.addingTimeInterval(1500))
        fixture.now = initial.addingTimeInterval(1500)
        fixture.reader.clockDidChange(now: fixture.now)
        #expect(fixture.reads.count == 4)
        #expect(fixture.reader.nextMeeting(now: fixture.now)?.title == "second")
        #expect(fixture.reader.nextRefreshAt == initial.addingTimeInterval(1800))
    }

    @Test func wakeForcesAnEarlyRefreshAndStopReleasesObserversAndTimer() throws {
        let fixture = MenuReaderFixture(observeSystemEvents: true)
        try fixture.seed(enabled: true, menuBar: true)
        fixture.reader.synchronizePreferences()
        #expect(fixture.reads.count == 1)
        #expect(fixture.reader.activeResourceCount == 4)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(fixture.reads.count == 2)
        fixture.reader.stop()
        #expect(fixture.reader.activeResourceCount == 0)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(fixture.reads.count == 2)
    }

    @Test func revocationDuringTheTransientReadCannotPublishAnEvent() throws {
        let fixture = MenuReaderFixture()
        fixture.events = [fixture.event("meeting", start: 300)]
        fixture.revokeAfterRead = true
        try fixture.seed(enabled: true, menuBar: true)
        fixture.reader.synchronizePreferences()
        #expect(fixture.reads.count == 1)
        #expect(fixture.reader.nextMeeting(now: fixture.now) == nil)
        #expect(fixture.liveNativeResources == 0)
    }

    @Test func failedReadClearsCacheAndRetriesWithinFifteenMinutes() throws {
        let fixture = MenuReaderFixture()
        fixture.events = [fixture.event("meeting", start: 300)]
        try fixture.seed(enabled: true, menuBar: true)
        fixture.reader.synchronizePreferences()
        #expect(fixture.reader.nextMeeting(now: fixture.now) != nil)
        fixture.failRead = true
        fixture.reader.refresh()
        #expect(fixture.reader.nextMeeting(now: fixture.now) == nil)
        #expect(fixture.reader.nextRefreshAt == fixture.now.addingTimeInterval(900))
        #expect(fixture.liveNativeResources == 0)
    }

    @Test func scheduledWorkDoesNotRetainTheReader() throws {
        let handle = TestDefaults.make(prefix: "dayside.calendar.reader.lifetime")
        defer { handle.cleanup() }
        let preferences = AgendaPreferences(isEnabled: true, showInMenuBar: true, selectedCalendarIDs: nil, days: 7)
        handle.defaults.set(try JSONEncoder().encode(preferences), forKey: AgendaStore.preferencesKey)
        var reader: AgendaMenuBarReader? = AgendaMenuBarReader(defaults: handle.defaults,
            authorization: { .fullAccess }, read: { _, _ in [] }, observeSystemEvents: true)
        weak let retained = reader
        reader?.synchronizePreferences()
        #expect(reader?.activeResourceCount == 4)
        reader = nil
        #expect(retained == nil)
    }

    @Test func hubStartsOnlyTheReaderAndThePageTakesOverWithoutAnotherPermissionRequest() async throws {
        let fixture = MenuReaderFixture()
        fixture.events = [fixture.event("lightweight", start: 300)]
        try fixture.seed(enabled: true, menuBar: true)
        let model = AppModel(defaults: fixture.handle.defaults, migrate: false, applySystemIntegration: false)
        let hub = FeatureHub(defaults: fixture.handle.defaults, agendaMenuBarReader: fixture.reader,
            now: { fixture.now }, timeZone: { fixture.zone })
        let service = MenuReaderPageService(events: [fixture.event("page", start: 600)])
        let store = AgendaStore(defaults: fixture.handle.defaults, makeService: { service },
            now: { fixture.now }, timeZone: { fixture.zone }, openURL: { _ in false })
        var factories = 0
        hub.register(.agenda) { factories += 1; return AgendaModule(store: store) }
        hub.attach(to: model)
        #expect(hub.modules.isEmpty)
        #expect(factories == 0)
        #expect(fixture.reads.count == 1)
        #expect(hub.nextMeeting(now: fixture.now)?.title == "lightweight")
        #expect(hub.menuBarMeeting(now: fixture.now) == hub.nextMeeting(now: fixture.now))
        hub.clockDidTick(fixture.now.addingTimeInterval(60))
        #expect(fixture.reads.count == 1)
        let module: AgendaModule = hub.openModule(.agenda, as: AgendaModule.self)
        #expect(module.store === store)
        #expect(factories == 1)
        #expect(!fixture.reader.isActive)
        #expect(fixture.reader.activeResourceCount == 0)
        #expect(fixture.reader.nextRefreshAt == nil)
        await store.waitUntilSettled()
        #expect(service.requests == 0)
        #expect(service.reads == 1)
        #expect(hub.nextMeeting(now: fixture.now)?.title == "page")
        #expect(hub.menuBarMeeting(now: fixture.now) == hub.nextMeeting(now: fixture.now))
        store.setMenuBarEnabled(false)
        #expect(hub.menuBarMeeting(now: fixture.now) == nil)
        #expect(hub.nextMeeting(now: fixture.now)?.title == "page")
        store.selectNoCalendars()
        await store.waitUntilSettled()
        #expect(hub.nextMeeting(now: fixture.now) == nil)
        #expect(fixture.reads.count == 1)
        #expect(!fixture.reader.isActive)
        await store.deactivateAndWait()
        #expect(hub.activeResourceCount == 0)
    }

    @Test func hubPreferencesRefreshWithoutConstructingTheCalendarPage() throws {
        let fixture = MenuReaderFixture()
        fixture.events = [fixture.event("meeting", start: 300)]
        try fixture.seed(enabled: true, menuBar: true)
        let model = AppModel(defaults: fixture.handle.defaults, migrate: false, applySystemIntegration: false)
        let hub = FeatureHub(defaults: fixture.handle.defaults, agendaMenuBarReader: fixture.reader,
            now: { fixture.now }, timeZone: { fixture.zone })
        hub.attach(to: model)
        #expect(hub.nextMeeting(now: fixture.now) != nil)
        try fixture.seed(enabled: true, menuBar: false)
        hub.synchronizeAgendaMenuBarPreferences()
        #expect(hub.nextMeeting(now: fixture.now) == nil)
        #expect(hub.activeResourceCount == 0)
        #expect(hub.modules.isEmpty)
        try fixture.seed(enabled: true, menuBar: true, calendars: [])
        hub.synchronizeAgendaMenuBarPreferences()
        #expect(fixture.reads.count == 2)
        #expect(hub.nextMeeting(now: fixture.now) == nil)
        #expect(hub.modules.isEmpty)
        fixture.reader.stop()
    }

    @Test func anAlreadyRegisteredPageKeepsTheLightweightReaderStopped() async throws {
        let fixture = MenuReaderFixture()
        try fixture.seed(enabled: true, menuBar: true)
        let model = AppModel(defaults: fixture.handle.defaults, migrate: false, applySystemIntegration: false)
        let hub = FeatureHub(defaults: fixture.handle.defaults, agendaMenuBarReader: fixture.reader,
            now: { fixture.now }, timeZone: { fixture.zone })
        let service = MenuReaderPageService(events: [fixture.event("page", start: 300)])
        let store = AgendaStore(defaults: fixture.handle.defaults, makeService: { service },
            now: { fixture.now }, timeZone: { fixture.zone }, openURL: { _ in false })
        hub.register(AgendaModule(store: store))
        hub.attach(to: model)
        await store.waitUntilSettled()
        #expect(fixture.reads.isEmpty)
        #expect(!fixture.reader.isActive)
        #expect(service.requests == 0)
        #expect(hub.nextMeeting(now: fixture.now)?.title == "page")
        await store.deactivateAndWait()
    }
}

@MainActor
private final class MenuReaderPageService: AgendaService {
    var authorization = AgendaAuthorization.fullAccess
    var requests = 0
    var reads = 0
    var events: [AgendaEvent]
    var observing = false
    var activeResourceCount: Int { observing ? 1 : 0 }
    init(events: [AgendaEvent]) { self.events = events }
    func requestFullAccess() async throws -> Bool { requests += 1; return true }
    func snapshot(in interval: DateInterval, calendarIDs: [String]?) async throws -> AgendaSnapshot {
        reads += 1
        return AgendaSnapshot(calendars: [.init(id: "work", title: "Work", sourceTitle: "Fixture")],
            events: events, interval: interval)
    }
    func observeChanges(_ receive: @escaping @MainActor @Sendable () -> Void) { observing = true }
    func stop() { observing = false }
}

@MainActor
private final class MenuReaderFixture {
    struct Read { let interval: DateInterval; let calendarIDs: [String]? }
    let handle = TestDefaults.make(prefix: "dayside.calendar.reader")
    var now = ISO8601DateFormatter().date(from: "2026-10-05T00:00:00Z")!
    var zone = TimeZone(identifier: "Etc/UTC")!
    var authorization = AgendaAuthorization.fullAccess
    var authorizationChecks = 0
    var reads: [Read] = []
    var events: [AgendaEvent] = []
    var liveNativeResources = 0
    var completedReads = 0
    var revokeAfterRead = false
    var failRead = false
    let observeSystemEvents: Bool
    lazy var reader = AgendaMenuBarReader(defaults: handle.defaults,
        authorization: { [unowned self] in self.authorizationChecks += 1; return self.authorization },
        read: { [unowned self] interval, calendarIDs in
            self.reads.append(Read(interval: interval, calendarIDs: calendarIDs))
            self.liveNativeResources += 1
            defer { self.liveNativeResources -= 1; self.completedReads += 1 }
            if self.revokeAfterRead { self.authorization = .denied }
            if self.failRead { throw AgendaFailure.read }
            return self.events
        }, now: { [unowned self] in self.now }, timeZone: { [unowned self] in self.zone },
        observeSystemEvents: observeSystemEvents)

    init(observeSystemEvents: Bool = false) { self.observeSystemEvents = observeSystemEvents }
    func seed(enabled: Bool, menuBar: Bool, calendars: [String]? = nil, days: Int = 7) throws {
        let preferences = AgendaPreferences(isEnabled: enabled, showInMenuBar: menuBar, selectedCalendarIDs: calendars, days: days)
        handle.defaults.set(try JSONEncoder().encode(preferences), forKey: AgendaStore.preferencesKey)
    }
    func event(_ title: String, start: Double, duration: Double = 1800, calendar: String = "work",
               allDay: Bool = false, cancelled: Bool = false, declined: Bool = false) -> AgendaEvent {
        .init(identifier: title, calendarID: calendar, title: title,
            start: now.timeIntervalSince1970 + start, end: now.timeIntervalSince1970 + start + duration,
            isAllDay: allDay, isCancelled: cancelled, isDeclined: declined, location: nil, urls: [])
    }
    isolated deinit {
        reader.stop()
        handle.cleanup()
    }
}
