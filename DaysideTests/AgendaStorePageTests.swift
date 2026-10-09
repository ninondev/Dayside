// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import Dayside

@MainActor
struct AgendaStorePageTests {
    @Test(arguments: [
        ("2026-03-08T12:00:00Z", "America/Los_Angeles", 601_200.0),
        ("2026-03-08T12:00:00Z", "Etc/UTC", 604_800.0),
        ("2026-11-01T12:00:00Z", "America/Los_Angeles", 608_400.0),
    ])
    func upcomingAlwaysUsesSevenCivilDays(iso: String, zone: String, duration: Double) async throws {
        let fixture = CalendarPageStoreFixture(iso: iso, zone: zone)
        try fixture.seed(enabled: true, menuBar: false, legacyDays: 1)
        fixture.store.activate()
        await fixture.store.waitUntilSettled()
        #expect(fixture.service.reads.count == 1)
        #expect(fixture.service.reads.first?.duration == duration)
        #expect(fixture.service.requests == 0)
        #expect(fixture.store.preferences.days == 1)
    }

    @Test func grantedAccessDoesNotRequestAgainAndLaunchDemandNeedsBothOptions() async throws {
        let fixture = CalendarPageStoreFixture()
        try fixture.seed(enabled: true, menuBar: false)
        #expect(!AgendaStore.shouldActivateAtLaunch(defaults: fixture.defaults))
        fixture.store.activate()
        fixture.store.setEnabled(true)
        await fixture.store.waitUntilSettled()
        #expect(fixture.service.requests == 0)
        fixture.store.setMenuBarEnabled(true)
        #expect(AgendaStore.shouldActivateAtLaunch(defaults: fixture.defaults))
        fixture.store.setEnabled(false)
        #expect(!AgendaStore.shouldActivateAtLaunch(defaults: fixture.defaults))
    }

    @Test func oneExtraDayReadIsReusedThenReplacedAndDroppedOnDeactivate() async throws {
        let fixture = CalendarPageStoreFixture()
        try await fixture.enable()
        let today = fixture.now
        fixture.store.setViewedDay(today.addingTimeInterval(86_400))
        #expect(fixture.service.reads.count == 1)
        let outside = today.addingTimeInterval(8 * 86_400)
        fixture.store.setViewedDay(outside)
        await fixture.store.waitUntilSettled()
        #expect(fixture.service.reads.count == 2)
        let first = try #require(fixture.store.daySnapshot)
        fixture.store.setViewedDay(outside)
        fixture.store.setViewedDay(outside.addingTimeInterval(86_400))
        await fixture.store.waitUntilSettled()
        #expect(fixture.service.reads.count == 2)
        let later = outside.addingTimeInterval(8 * 86_400)
        fixture.store.setViewedDay(later)
        await fixture.store.waitUntilSettled()
        #expect(fixture.service.reads.count == 3)
        #expect(fixture.store.daySnapshot?.interval != first.interval)
        #expect(fixture.store.snapshot?.interval == fixture.service.reads.first)
        fixture.store.deactivate()
        #expect(fixture.store.daySnapshot == nil)
    }

    @Test func refreshKeepsSnapshotReadyUntilFreshReadLands() async throws {
        let fixture = CalendarPageStoreFixture()
        try await fixture.enable()
        let old = try #require(fixture.store.snapshot)
        fixture.service.holdReads = true
        fixture.service.title = "Replacement"
        fixture.store.refresh()
        #expect(fixture.store.state == .ready)
        #expect(fixture.store.snapshot == old)
        await settle { fixture.service.pending.count == 1 }
        #expect(fixture.store.snapshot == old)
        fixture.service.finish(at: 0)
        await fixture.store.waitUntilSettled()
        #expect(fixture.store.snapshot?.events.first?.title == "Replacement")
        #expect(fixture.store.state == .ready)
    }

    @Test func anUnchangedUpcomingRefreshStillAdvancesTheDriftTrigger() async throws {
        let fixture = CalendarPageStoreFixture()
        try await fixture.enable()
        let snapshot = fixture.store.snapshot
        let revision = fixture.store.snapshotRevision
        fixture.store.refresh()
        await fixture.store.waitUntilSettled()
        #expect(fixture.store.snapshot == snapshot)
        #expect(fixture.store.snapshotRevision != revision)
    }

    @Test func permissionRetryRestoresTheSameOutsideViewedDay() async throws {
        let fixture = CalendarPageStoreFixture()
        try await fixture.enable()
        let outside = fixture.now.addingTimeInterval(8 * 86_400)
        fixture.store.setViewedDay(outside)
        await fixture.store.waitUntilSettled()
        #expect(fixture.service.reads.count == 2)
        fixture.service.authorization = .denied
        fixture.store.clockDidChange(now: fixture.now)
        #expect(fixture.store.state == .permission(.denied))
        #expect(fixture.store.daySnapshot == nil)
        fixture.service.authorization = .fullAccess
        fixture.store.refresh()
        await fixture.store.waitUntilSettled()
        #expect(fixture.service.reads.count == 4)
        #expect(fixture.store.day(dayStart: outside, dayEnd: outside.addingTimeInterval(86_400),
                                  anchor: outside, now: fixture.now)?.timed.count == 1)
        #expect(fixture.service.requests == 0)
    }

    @Test func staleOutsideDayCannotReplaceLatestViewedDay() async throws {
        let fixture = CalendarPageStoreFixture()
        try await fixture.enable()
        fixture.service.holdReads = true
        let firstDay = fixture.now.addingTimeInterval(8 * 86_400)
        fixture.store.setViewedDay(firstDay)
        await settle { fixture.service.pending.count == 1 }
        let secondDay = fixture.now.addingTimeInterval(20 * 86_400)
        fixture.store.setViewedDay(secondDay)
        await settle { fixture.service.pending.count == 2 }
        let expected = fixture.service.pending[1].0.interval
        fixture.service.finish(at: 1)
        await settle { fixture.store.daySnapshot?.interval == expected }
        fixture.service.finish(at: 0)
        await fixture.store.waitUntilSettled()
        #expect(fixture.store.daySnapshot?.interval == expected)
        #expect(fixture.store.day(dayStart: firstDay, dayEnd: firstDay.addingTimeInterval(86_400),
                                  anchor: firstDay, now: fixture.now) == nil)
    }

    @Test func staleDayAfterCalendarChangeCannotRestoreExcludedEvents() async throws {
        let fixture = CalendarPageStoreFixture()
        try await fixture.enable()
        let outside = fixture.now.addingTimeInterval(8 * 86_400)
        fixture.service.holdReads = true
        fixture.store.setViewedDay(outside)
        await settle { fixture.service.pending.count == 1 }
        fixture.store.selectNoCalendars()
        await settle { fixture.service.pending.count == 3 }
        fixture.service.finish(at: 2)
        fixture.service.finish(at: 1)
        fixture.service.finish(at: 0)
        await fixture.store.waitUntilSettled()
        let day = try #require(fixture.store.day(dayStart: outside,
            dayEnd: outside.addingTimeInterval(86_400), anchor: outside, now: fixture.now))
        #expect(day.timed.isEmpty)
        #expect(fixture.store.nextMeeting(now: fixture.now) == nil)
    }

    @Test func inactiveRemoteCacheIsDiscardedAfterCalendarSelectionRefresh() async throws {
        let fixture = CalendarPageStoreFixture()
        try await fixture.enable()
        let outside = fixture.now.addingTimeInterval(8 * 86_400)
        fixture.store.setViewedDay(outside)
        await fixture.store.waitUntilSettled()
        fixture.store.setViewedDay(fixture.now)
        fixture.store.selectNoCalendars()
        await fixture.store.waitUntilSettled()
        #expect(fixture.store.daySnapshot == nil)
        fixture.service.title = "After filter change"
        fixture.store.selectAllCalendars()
        await fixture.store.waitUntilSettled()
        let before = fixture.service.reads.count
        fixture.store.setViewedDay(outside)
        await fixture.store.waitUntilSettled()
        #expect(fixture.service.reads.count == before + 1)
        #expect(fixture.store.daySnapshot?.events.first?.title == "After filter change")
    }

    @Test func inactiveRemoteCacheIsDiscardedAfterCalendarEventRefresh() async throws {
        let fixture = CalendarPageStoreFixture()
        try await fixture.enable()
        let outside = fixture.now.addingTimeInterval(8 * 86_400)
        fixture.store.setViewedDay(outside)
        await fixture.store.waitUntilSettled()
        fixture.store.setViewedDay(fixture.now)
        fixture.service.title = "Edited calendar event"
        fixture.store.refresh()
        await fixture.store.waitUntilSettled()
        #expect(fixture.store.daySnapshot == nil)
        let before = fixture.service.reads.count
        fixture.store.setViewedDay(outside)
        await fixture.store.waitUntilSettled()
        #expect(fixture.service.reads.count == before + 1)
        #expect(fixture.store.daySnapshot?.events.first?.title == "Edited calendar event")
    }

    @Test func activeRemoteRefreshKeepsOldDataButLeavingInvalidatesIt() async throws {
        let fixture = CalendarPageStoreFixture()
        try await fixture.enable()
        let outside = fixture.now.addingTimeInterval(8 * 86_400)
        fixture.store.setViewedDay(outside)
        await fixture.store.waitUntilSettled()
        let old = fixture.store.daySnapshot
        fixture.service.holdReads = true
        fixture.service.title = "Cancelled remote read"
        fixture.store.refresh()
        #expect(fixture.store.state == .ready)
        #expect(fixture.store.daySnapshot == old)
        await settle { fixture.service.pending.count == 2 }
        fixture.store.setViewedDay(fixture.now)
        #expect(fixture.store.daySnapshot == nil)
        fixture.service.title = "Fresh remote event"
        fixture.store.setViewedDay(outside)
        await settle { fixture.service.pending.count == 3 }
        fixture.service.finish(at: 2)
        await settle { fixture.store.daySnapshot?.events.first?.title == "Fresh remote event" }
        fixture.service.finish(at: 1)
        fixture.service.finish(at: 0)
        await fixture.store.waitUntilSettled()
        #expect(fixture.store.daySnapshot?.events.first?.title == "Fresh remote event")
    }

    @Test func activeRemoteFilterRefreshReplacesItsCacheWithTheNewSelection() async throws {
        let fixture = CalendarPageStoreFixture()
        try await fixture.enable()
        let outside = fixture.now.addingTimeInterval(8 * 86_400)
        fixture.store.setViewedDay(outside)
        await fixture.store.waitUntilSettled()
        let old = fixture.store.daySnapshot
        fixture.service.holdReads = true
        fixture.store.selectNoCalendars()
        #expect(fixture.store.state == .ready)
        #expect(fixture.store.daySnapshot == old)
        await settle { fixture.service.pending.count == 2 }
        let remoteIndex = try #require(fixture.service.pending.firstIndex { $0.0.interval.start == outside })
        fixture.service.finish(at: remoteIndex)
        await settle { fixture.store.daySnapshot?.events.isEmpty == true }
        fixture.service.finish(at: 0)
        await fixture.store.waitUntilSettled()
        fixture.store.setViewedDay(fixture.now)
        let before = fixture.service.reads.count
        fixture.store.setViewedDay(outside)
        #expect(fixture.service.reads.count == before)
        #expect(fixture.store.daySnapshot?.events.isEmpty == true)
    }

    @Test func staleDriftReadCannotReplaceTheLatestRequest() async throws {
        let fixture = CalendarPageStoreFixture()
        try await fixture.enable()
        fixture.service.holdReads = true
        fixture.service.title = "Older"
        fixture.store.refreshDrift()
        await settle { fixture.service.pending.count == 1 }
        fixture.service.title = "Newer"
        fixture.store.refreshDrift()
        await settle { fixture.service.pending.count == 2 }
        fixture.service.finish(at: 1)
        await settle { fixture.store.driftSnapshot?.events.first?.title == "Newer" }
        fixture.service.finish(at: 0)
        await fixture.store.waitUntilSettled()
        #expect(fixture.store.driftSnapshot?.events.first?.title == "Newer")
    }

    @Test func driftParticipantsDeduplicateResolvedZonesWithThisMacFirst() {
        let local = TimeZoneEntry(timezoneID: "Etc/UTC", cityName: "Home")
        let london = TimeZoneEntry(timezoneID: "Europe/London", cityName: "London")
        let places = [local, london, TimeZoneEntry(timezoneID: "Europe/London", cityName: "Duplicate")]
        let people = [
            PersonProfile(name: "Linked", timeZoneID: "Asia/Tokyo", placeID: london.id),
            PersonProfile(name: "Tokyo", timeZoneID: "Asia/Tokyo"),
            PersonProfile(name: "Tokyo again", timeZoneID: "Asia/Tokyo"),
        ]
        let participants = AgendaDrift.participants(localTimeZoneID: "Etc/UTC", localName: "This Mac",
            places: places, people: people, placeName: { $0 })
        #expect(participants.map(\.timeZoneID) == ["Etc/UTC", "Europe/London", "Asia/Tokyo"])
        #expect(participants.first?.name == "This Mac")
    }

    @Test func attendeeFilteringAndTypedRunsUseRealClockChanges() {
        let formatter = ISO8601DateFormatter()
        func event(_ iso: String) -> AgendaEvent {
            let start = formatter.date(from: iso)!.timeIntervalSince1970
            return .init(identifier: "weekly", calendarID: "work", title: "Weekly", start: start, end: start + 1800,
                isAllDay: false, isCancelled: false, isDeclined: false, location: nil, urls: [], hasAttendees: true)
        }
        let participants = [
            AgendaDriftParticipant(id: "la", name: "LA", timeZoneID: "America/Los_Angeles"),
            AgendaDriftParticipant(id: "ldn", name: "London", timeZoneID: "Europe/London"),
            AgendaDriftParticipant(id: "tyo", name: "Tokyo", timeZoneID: "Asia/Tokyo"),
        ]
        let events = [event("2026-10-19T16:00:00Z"), event("2026-10-26T16:00:00Z"), event("2026-11-02T17:00:00Z"), event("2026-11-09T17:00:00Z")]
        let meetings = AgendaDrift.meetings(events: events, participants: participants)
        #expect(meetings.count == 1)
        let london = meetings.first?.places.first { $0.participant == "ldn" }
        #expect(london?.baseline == 17 * 60)
        #expect(london?.runs.count == 1)
        #expect(london?.runs.first?.minute == 16 * 60)
        #expect(london?.runs.first?.open == false)
        let tokyo = meetings.first?.places.first { $0.participant == "tyo" }
        #expect(tokyo?.baseline == 60)
        #expect(tokyo?.runs.first?.minute == 120)
        #expect(tokyo?.runs.first?.open == true)
        let solo = events.map { event in var value = event; value.hasAttendees = false; return value }
        #expect(AgendaDrift.meetings(events: solo, participants: participants).isEmpty)
    }

    private func settle(_ predicate: @MainActor () -> Bool) async {
        for _ in 0..<300 { if predicate() { return }; await Task.yield() }
        #expect(predicate())
    }
}

@MainActor
private final class CalendarPageStoreFixture {
    private let handle = TestDefaults.make(prefix: "dayside.calendar.page")
    var defaults: UserDefaults { handle.defaults }
    let now: Date
    let zone: TimeZone
    let service = CalendarPageService()
    lazy var store = AgendaStore(defaults: defaults, makeService: { [unowned self] in self.service },
        now: { [unowned self] in self.now }, timeZone: { [unowned self] in self.zone }, openURL: { _ in true })

    init(iso: String = "2026-10-04T00:00:00Z", zone: String = "Etc/UTC") {
        now = ISO8601DateFormatter().date(from: iso)!
        self.zone = TimeZone(identifier: zone)!
    }
    func seed(enabled: Bool, menuBar: Bool, legacyDays: Int = 7) throws {
        defaults.set(try JSONEncoder().encode(AgendaPreferences(isEnabled: enabled, showInMenuBar: menuBar,
            selectedCalendarIDs: nil, days: legacyDays)), forKey: AgendaStore.preferencesKey)
    }
    func enable() async throws {
        try seed(enabled: true, menuBar: false)
        store.activate()
        await store.waitUntilSettled()
        #expect(store.state == .ready)
    }
    isolated deinit {
        store.deactivate()
        service.completePending()
        handle.cleanup()
    }
}

@MainActor
private final class CalendarPageService: AgendaService {
    var authorization: AgendaAuthorization = .fullAccess
    var activeResourceCount: Int { 0 }
    var requests = 0
    var reads: [DateInterval] = []
    var pending: [(AgendaSnapshot, CheckedContinuation<AgendaSnapshot, any Error>)] = []
    var holdReads = false
    var title = "Initial"

    func requestFullAccess() async throws -> Bool { requests += 1; return true }
    func snapshot(in interval: DateInterval, calendarIDs: [String]?) async throws -> AgendaSnapshot {
        reads.append(interval)
        let event = AgendaEvent(identifier: "event", calendarID: "work", title: title,
            start: interval.start.timeIntervalSince1970 + 3600, end: interval.start.timeIntervalSince1970 + 7200,
            isAllDay: false, isCancelled: false, isDeclined: false, location: nil, urls: [])
        let snapshot = AgendaSnapshot(calendars: [.init(id: "work", title: "Work", sourceTitle: "Local")],
            events: calendarIDs == [] ? [] : [event], interval: interval)
        if holdReads { return try await withCheckedThrowingContinuation { pending.append((snapshot, $0)) } }
        return snapshot
    }
    func finish(at index: Int) {
        let (_, continuation) = pending[index]
        let value = pending.remove(at: index).0
        continuation.resume(returning: value)
    }
    func observeChanges(_ receive: @escaping @MainActor @Sendable () -> Void) {}
    func stop() {}
    func completePending() {
        let values = pending
        pending = []
        for (_, continuation) in values { continuation.resume(throwing: CancellationError()) }
    }
}
