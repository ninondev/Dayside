// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import TahoeTime

@MainActor
struct AgendaTests {
    @Test func startsOffWithoutCreatingNativeResources() async {
        let f = AgendaFixture()
        f.store.activate()
        #expect(!f.store.isEnabled)
        #expect(f.store.state == .disabled)
        #expect(f.factories == 0)
        #expect(f.service.requests == 0)
        #expect(f.store.activeResourceCount == 0)
        f.store.deactivate()
        #expect(f.store.activeResourceCount == 0)
    }

    @Test func explicitEnableRequestsFullAccessAndReleasesOnDisable() async {
        let f = AgendaFixture(authorization: .writeOnly)
        f.store.activate()
        f.store.setEnabled(true)
        await settle { f.store.state == .ready }
        #expect(f.service.requests == 1)
        #expect(f.service.reads.count == 1)
        #expect(f.store.activeResourceCount > 0)
        #expect(f.store.nextMeeting(now: f.now)?.event.title == "Planning")
        #expect(f.store.menuBarMeeting(now: f.now) == nil)
        f.store.setMenuBarEnabled(true)
        #expect(f.store.menuBarMeeting(now: f.now) != nil)
        f.store.setEnabled(false)
        #expect(f.store.state == .disabled)
        #expect(f.store.activeResourceCount == 0)
        #expect(f.store.snapshot == nil)
    }

    @Test func persistedEnableNeverPromptsDuringActivation() async throws {
        let f = AgendaFixture(authorization: .notDetermined)
        f.store.setEnabled(true)
        #expect(f.factories == 0)
        f.store.activate()
        #expect(f.store.state == .permission(.notDetermined))
        #expect(f.service.requests == 0)
        #expect(f.service.reads.isEmpty)
        #expect(f.store.activeResourceCount == 0)
        f.store.requestAccess()
        await settle { f.store.state == .ready }
        #expect(f.service.requests == 1)
    }

    @Test(arguments: [AgendaAuthorization.denied, .restricted])
    func deniedAndRestrictedDoNotReadOrPrompt(authorization: AgendaAuthorization) {
        let f = AgendaFixture(authorization: authorization)
        f.store.activate()
        f.store.setEnabled(true)
        #expect(f.store.state == .permission(authorization))
        #expect(f.service.requests == 0)
        #expect(f.service.reads.isEmpty)
        #expect(f.store.activeResourceCount == 0)
    }

    @Test func latePermissionResponseCannotReactivateClosedLens() async {
        let f = AgendaFixture(authorization: .notDetermined)
        f.service.holdPermission = true
        f.store.activate()
        f.store.setEnabled(true)
        await settle { f.service.pendingPermission != nil }
        f.store.deactivate()
        f.service.grantPermission()
        await drain()
        #expect(f.store.state == .inactive)
        #expect(f.service.reads.isEmpty)
        #expect(f.store.activeResourceCount == 0)
        #expect(f.store.snapshot == nil)
    }

    @Test func revokedPermissionClearsSnapshot() async {
        let f = AgendaFixture()
        await f.enable()
        f.service.authorization = .denied
        f.store.clockDidChange(now: f.now)
        #expect(f.store.state == .permission(.denied))
        #expect(f.store.snapshot == nil)
        #expect(f.store.calendars.isEmpty)
        #expect(f.store.activeResourceCount == 0)
    }

    @Test func calendarFiltersDistinguishAllAndNoneAndPersist() async throws {
        let f = AgendaFixture()
        await f.enable()
        #expect(f.service.reads.last?.calendarIDs == nil)
        f.store.setCalendar("personal", included: false)
        await f.store.waitUntilSettled()
        #expect(f.service.reads.last?.calendarIDs == ["work"])
        #expect(!f.store.includesCalendar("new"))
        f.store.selectNoCalendars()
        await f.store.waitUntilSettled()
        #expect(f.service.reads.last?.calendarIDs == [])
        #expect(f.store.evaluation(now: f.now).events.isEmpty)
        let stored = try JSONDecoder().decode(AgendaPreferences.self,
            from: #require(f.defaults.data(forKey: AgendaStore.preferencesKey)))
        #expect(stored.selectedCalendarIDs == [])
        f.store.selectAllCalendars()
        await f.store.waitUntilSettled()
        #expect(f.store.preferences.selectedCalendarIDs == nil)
        #expect(f.store.includesCalendar("new"))
    }

    @Test func staleReadCannotOverwriteNewerCalendarSelection() async {
        let f = AgendaFixture()
        f.service.holdReads = true
        f.store.activate()
        f.store.setEnabled(true)
        await settle { f.service.pendingReads.count == 1 }
        f.store.selectNoCalendars()
        await settle { f.service.pendingReads.count == 2 }
        f.service.finishRead(at: 1)
        await settle { f.store.state == .ready }
        #expect(f.store.evaluation(now: f.now).events.isEmpty)
        f.service.finishRead(at: 0)
        await drain()
        #expect(f.store.preferences.selectedCalendarIDs == [])
        #expect(f.store.evaluation(now: f.now).events.isEmpty)
    }

    @Test func canceledJobsStayCountedUntilTheirBodiesReturn() async {
        let f = AgendaFixture()
        f.service.holdReads = true
        f.store.activate()
        f.store.setEnabled(true)
        await settle { f.service.pendingReads.count == 1 }
        f.store.refresh()
        await settle { f.service.pendingReads.count == 2 }
        #expect(f.store.activeResourceCount == 3) // Two tasks and the fake observer.
        let stopped = Task { await f.store.deactivateAndWait() }
        await settle { !f.store.isActive }
        #expect(f.store.activeResourceCount == 2)
        f.service.finishRead(at: 0)
        await settle { f.store.activeResourceCount == 1 }
        f.service.finishRead(at: 0)
        await stopped.value
        #expect(f.store.activeResourceCount == 0)
        #expect(f.store.snapshot == nil)
    }

    @Test func dayAndTimeZoneChangesRebuildCivilDateRange() async throws {
        let f = AgendaFixture()
        f.now = ISO8601DateFormatter().date(from: "2026-03-08T12:00:00Z")!
        f.zone = TimeZone(identifier: "America/Los_Angeles")!
        f.service.events = []
        let legacy = AgendaPreferences(isEnabled: false, showInMenuBar: false,
            selectedCalendarIDs: nil, days: 1)
        f.defaults.set(try JSONEncoder().encode(legacy), forKey: AgendaStore.preferencesKey)
        await f.enable()
        #expect(f.service.reads.last?.interval.duration == 601_200.0)
        let previous = f.service.reads.count
        f.zone = TimeZone(secondsFromGMT: 0)!
        f.store.clockDidChange(now: f.now)
        await f.store.waitUntilSettled()
        #expect(f.service.reads.count == previous + 1)
        #expect(f.service.reads.last?.interval.duration == 604_800.0)
        f.zone = TimeZone(identifier: "America/Los_Angeles")!
        f.now = ISO8601DateFormatter().date(from: "2026-11-01T12:00:00Z")!
        f.store.clockDidChange(now: f.now)
        await f.store.waitUntilSettled()
        #expect(f.service.reads.last?.interval.duration == 608_400.0)
    }

    @Test func deletedMeetingDoesNotOpenOldURL() async throws {
        let f = AgendaFixture()
        await f.enable()
        let id = try #require(f.store.nextMeeting(now: f.now)?.event.id)
        f.service.events = []
        f.store.joinMeeting(id: id)
        await settle { !f.store.isJoining }
        #expect(f.opened.isEmpty)
        #expect(f.store.joinFailure == .eventUnavailable)
    }

    @Test func meetingJoinUsesFreshValidatedURL() async throws {
        let f = AgendaFixture()
        await f.enable()
        let id = try #require(f.store.nextMeeting(now: f.now)?.event.id)
        f.service.events = [f.event(url: "https://meet.google.com/abc-defg-hij")]
        f.store.joinMeeting(id: id)
        await settle { !f.store.isJoining }
        #expect(f.opened.map(\.absoluteString) == ["https://meet.google.com/abc-defg-hij"])
        #expect(f.store.didOpenMeeting)
        f.service.events = [f.event(url: "https://zoom.us.attacker.example/j/123456789")]
        f.store.joinMeeting(id: id)
        await settle { !f.store.isJoining }
        #expect(f.opened.count == 1)
        #expect(f.store.joinFailure == .meetingLinkUnavailable)
    }

    @Test func filterChangeCancelsInFlightJoin() async throws {
        let f = AgendaFixture()
        await f.enable()
        let id = try #require(f.store.nextMeeting(now: f.now)?.event.id)
        f.service.holdReads = true
        f.store.joinMeeting(id: id)
        await settle { f.service.pendingReads.count == 1 }
        f.store.selectNoCalendars()
        await settle { f.service.pendingReads.count == 2 }
        f.service.finishRead(at: 0)
        f.service.finishRead(at: 0)
        await settle { f.store.state == .ready }
        #expect(f.opened.isEmpty)
        #expect(f.store.evaluation(now: f.now).events.isEmpty)
    }

    @Test func foundationURLFactsPreserveQueryAndRejectUnsafeOrigins() throws {
        let acceptedURL = try #require(URL(string: "https://acme.zoom.us/j/123456789?pwd=secret%2Bvalue"))
        let accepted = try #require(AgendaURLFacts(url: acceptedURL))
        #expect(AgendaMeetingLink.recognize([accepted])?.url == "https://acme.zoom.us/j/123456789?pwd=secret%2Bvalue")
        for raw in ["http://zoom.us/j/123456789", "https://user@zoom.us/j/123456789", "https://zoom.us:444/j/123456789", "https://zoom.us/j/123456789#fragment", "https://zoom.us.evil.example/j/123456789", "https://zoom.us/j/%2e%2e/123456789"] {
            let url = try #require(URL(string: raw))
            let facts = try #require(AgendaURLFacts(url: url))
            #expect(AgendaMeetingLink.recognize([facts]) == nil)
        }
    }

    private func settle(_ predicate: @MainActor () -> Bool) async {
        for _ in 0..<200 {
            if predicate() { return }
            await Task.yield()
        }
        #expect(predicate(), "Agenda operation did not complete")
    }

    private func drain() async { for _ in 0..<20 { await Task.yield() } }
}

@MainActor
private final class AgendaFixture {
    private let handle = TestDefaults.make(prefix: "meantime.agenda.tests")
    var defaults: UserDefaults { handle.defaults }
    let service: FakeAgendaService
    var now = ISO8601DateFormatter().date(from: "2026-09-09T12:00:00Z")!
    var zone = TimeZone(secondsFromGMT: 0)!
    var factories = 0
    var opened: [URL] = []
    lazy var store = AgendaStore(defaults: defaults,
        makeService: { [unowned self] in self.factories += 1; return self.service },
        now: { [unowned self] in self.now }, timeZone: { [unowned self] in self.zone },
        openURL: { [unowned self] in self.opened.append($0); return true })

    init(authorization: AgendaAuthorization = .fullAccess) {
        service = FakeAgendaService(authorization)
        service.events = [event()]
    }

    func event(url: String = "https://zoom.us/j/123456789?pwd=private") -> AgendaEvent {
        .init(identifier: "meeting", calendarID: "work", title: "Planning",
            start: now.addingTimeInterval(300).timeIntervalSince1970,
            end: now.addingTimeInterval(3_900).timeIntervalSince1970,
            isAllDay: false, isCancelled: false, isDeclined: false, location: "Private room",
            urls: [AgendaURLFacts(url: URL(string: url)!)!])
    }

    func enable() async {
        store.activate()
        store.setEnabled(true)
        for _ in 0..<200 { if store.state == .ready { return }; await Task.yield() }
        #expect(store.state == .ready)
    }

    isolated deinit {
        store.deactivate()
        service.completePending()
        handle.cleanup()
    }
}

@MainActor
private final class FakeAgendaService: AgendaService {
    struct Read { let interval: DateInterval; let calendarIDs: [String]? }
    var authorization: AgendaAuthorization
    var events: [AgendaEvent] = []
    var reads: [Read] = []
    var requests = 0
    var holdReads = false
    var holdPermission = false
    var pendingPermission: CheckedContinuation<Bool, any Error>?
    var pendingReads: [(AgendaSnapshot, CheckedContinuation<AgendaSnapshot, any Error>)] = []
    private var observing = false
    var activeResourceCount: Int { observing ? 1 : 0 }
    init(_ authorization: AgendaAuthorization) { self.authorization = authorization }

    func requestFullAccess() async throws -> Bool {
        requests += 1
        if holdPermission { return try await withCheckedThrowingContinuation { pendingPermission = $0 } }
        authorization = .fullAccess
        return true
    }

    func grantPermission() {
        authorization = .fullAccess
        let pending = pendingPermission; pendingPermission = nil
        pending?.resume(returning: true)
    }

    func snapshot(in interval: DateInterval, calendarIDs: [String]?) async throws -> AgendaSnapshot {
        reads.append(.init(interval: interval, calendarIDs: calendarIDs))
        let value = AgendaSnapshot(calendars: [.init(id: "work", title: "Work", sourceTitle: "Local"),
            .init(id: "personal", title: "Personal", sourceTitle: "Local")], events: events, interval: interval)
        if holdReads { return try await withCheckedThrowingContinuation { pendingReads.append((value, $0)) } }
        return value
    }

    func finishRead(at index: Int) {
        let (value, continuation) = pendingReads.remove(at: index)
        continuation.resume(returning: value)
    }
    func observeChanges(_ receive: @escaping @MainActor @Sendable () -> Void) { observing = true }
    func stop() { observing = false }
    func completePending() {
        let permission = pendingPermission; pendingPermission = nil
        permission?.resume(throwing: CancellationError())
        let reads = pendingReads; pendingReads = []
        for (_, continuation) in reads { continuation.resume(throwing: CancellationError()) }
    }
}
