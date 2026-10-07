// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import TahoeTime

@MainActor
struct PeopleTests {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    @Test func manualCRUDPersistsWithoutRequestingContacts() async {
        let (defaults, cleanup) = TestDefaults.make(prefix: "meantime.people.tests"); defer { cleanup() }
        let contacts = FakePeopleContacts(.denied)
        let store = PeopleStore(defaults: defaults, contactsReader: contacts)
        var person = PersonProfile(name: "  Ana  ", timeZoneID: "Europe/Madrid")
        #expect(store.save(person).isEmpty)
        #expect(store.people.first?.name == "Ana")
        person.name = "Ana María"
        #expect(store.save(person).isEmpty)
        let reloaded = PeopleStore(defaults: defaults, contactsReader: contacts)
        #expect(reloaded.people.count == 1)
        #expect(reloaded.people.first?.name == "Ana María")
        #expect(reloaded.remove(id: person.id))
        #expect(PeopleStore(defaults: defaults, contactsReader: contacts).people.isEmpty)
        #expect(await contacts.calls == 0)
    }

    @Test func invalidEditsLeaveStoredBytesUntouched() {
        let (defaults, cleanup) = TestDefaults.make(prefix: "meantime.people.tests"); defer { cleanup() }
        let store = PeopleStore(defaults: defaults)
        var person = PersonProfile(name: "Ana", timeZoneID: "Asia/Tokyo")
        #expect(store.save(person).isEmpty)
        let before = defaults.data(forKey: PeopleStore.storageKey)
        person.timeZoneID = "Not/AZone"
        #expect(store.save(person).contains("timeZone"))
        #expect(defaults.data(forKey: PeopleStore.storageKey) == before)
        person.timeZoneID = "Asia/Tokyo"
        person.vacations = [PeopleVacation(startDate: "2026-02-29", endDate: "2026-03-01")]
        #expect(store.save(person).contains("vacation"))
        #expect(defaults.data(forKey: PeopleStore.storageKey) == before)
    }

    @Test func corruptedBytesArePreservedUntilAndAfterExplicitEdit() {
        let (defaults, cleanup) = TestDefaults.make(prefix: "meantime.people.tests"); defer { cleanup() }
        let damaged = Data([0xff, 0x01, 0x02])
        defaults.set(damaged, forKey: PeopleStore.storageKey)
        let store = PeopleStore(defaults: defaults)
        #expect(store.storageNeedsRecovery)
        #expect(defaults.data(forKey: PeopleStore.storageKey) == damaged)
        #expect(store.save(PersonProfile(name: "Ana", timeZoneID: "UTC")).isEmpty)
        let backups = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix(PeopleStore.backupPrefix) }
        #expect(backups.count == 1)
        #expect(backups.values.first as? Data == damaged)
        #expect(PeopleStore(defaults: defaults).people.count == 1)
    }

    @Test func mixedRecordsRecoverNeighborsAndRetainOriginalData() throws {
        let (defaults, cleanup) = TestDefaults.make(prefix: "meantime.people.tests"); defer { cleanup() }
        let person = PersonProfile(name: "Ana", timeZoneID: "UTC")
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(person))
        let raw = try JSONSerialization.data(withJSONObject: ["version": 1, "people": [object, ["name": "broken"]]])
        defaults.set(raw, forKey: PeopleStore.storageKey)
        let store = PeopleStore(defaults: defaults)
        #expect(store.people.map(\.id) == [person.id])
        #expect(store.rejectedCount == 1)
        #expect(store.storageNeedsRecovery)
        #expect(defaults.data(forKey: PeopleStore.storageKey) == raw)
    }

    @Test func twoExchangedTimeCardsFindOverlapWithoutAnyServer() {
        let now = Date(timeIntervalSince1970: 1_789_041_600)   // Thursday 2026-09-10 12:00 UTC
        func card(_ name: String, _ zone: String, _ start: Int, _ end: Int) -> String {
            var draft = SharingDraft()
            draft.timeZoneID = zone; draft.displayName = name; draft.includesAvailability = true
            draft.startMinute = start; draft.endMinute = end
            let result = SharingGenerator.build(draft: draft, hostURL: "https://example.test/when.html", now: now)
            return result.document!.shareURL!
        }
        let meiCard = try! TimeCard.person(from: "see " + card("Mei", "Asia/Tokyo", 540, 1080) + " ok", now: now).get()
        let anaCard = try! TimeCard.person(from: card("Ana", "Europe/London", 480, 1020), now: now).get()
        let (mei, ana) = (PersonProfile(meiCard.contact), PersonProfile(anaCard.contact))
        #expect(mei.name == "Mei")
        #expect(mei.timeZoneID == "Asia/Tokyo")
        #expect(mei.schedule.startMinute == 540)
        #expect(mei.schedule.endMinute == 1080)
        #expect(mei.schedule.workingWeekdays == [2, 3, 4, 5, 6])
        #expect(!meiCard.expired && meiCard.hadSchedule)
        let plan = OverlapPlanner.plan(.init(participants: [mei.plannerParticipant(places: []), ana.plannerParticipant(places: [])],
                                             from: now, days: 3, durationMinutes: 30, localTimeZoneID: "UTC", toleranceMinutes: 0, limit: 5))
        #expect(!plan.everyone.isEmpty)
        // Tokyo 09:00-18:00 (UTC+9) and London 08:00-17:00 (BST, UTC+1) overlap only 16:00-18:00 Tokyo time.
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        for window in plan.everyone {
            let hour = Calendar.gregorianUTC(tokyo).component(.hour, from: window.best)
            #expect(hour >= 16 && hour < 18)
        }
        if case .failure(let error) = TimeCard.person(from: "not a card", now: now) { #expect(error == "notACard") } else { Issue.record("junk must fail") }
        if case .failure(let error) = TimeCard.person(from: "mt1.AAAA", now: now) { #expect(error == "corrupt") } else { Issue.record("corrupt must fail") }
        let stale = try! TimeCard.person(from: card("Old", "UTC", 0, 0), now: now.addingTimeInterval(30 * 86_400)).get()
        #expect(stale.expired)
        let old = PersonProfile(stale.contact)
        #expect(old.schedule.startMinute == 0 && old.schedule.endMinute == 0)
    }

    @Test func futureSchemaCannotBeOverwritten() {
        let (defaults, cleanup) = TestDefaults.make(prefix: "meantime.people.tests"); defer { cleanup() }
        let raw = Data("{\"version\":20,\"people\":[]}".utf8)
        defaults.set(raw, forKey: PeopleStore.storageKey)
        let store = PeopleStore(defaults: defaults)
        #expect(store.storageReadOnly)
        #expect(store.save(PersonProfile(name: "Ana", timeZoneID: "UTC")) == ["readOnly"])
        #expect(defaults.data(forKey: PeopleStore.storageKey) == raw)
    }

    @Test func placeBindingTracksChangesAndRetainsFallbackAfterRemoval() {
        var place = TimeZoneEntry(timezoneID: "Asia/Tokyo", cityName: "Tokyo")
        let person = PersonProfile(name: "Ana", timeZoneID: "Asia/Tokyo", placeID: place.id)
        place.timezoneID = "Europe/London"
        #expect(person.resolvedTimeZoneID(places: [place]) == "Europe/London")
        #expect(person.resolvedTimeZoneID(places: []) == "Asia/Tokyo")
    }

    @Test func plannerConversionPreservesCustomWorkdaysAndVacations() {
        var person = PersonProfile(name: "Ana", timeZoneID: "Asia/Tokyo")
        person.schedule = PeopleWorkSchedule(startMinute: 1320, endMinute: 360, workingWeekdays: [1, 2, 3, 4, 5])
        person.vacations = [PeopleVacation(startDate: "2026-09-10", endDate: "2026-09-12")]
        let participant = person.plannerParticipant(places: [])
        #expect(participant.workingWeekdays == [1, 2, 3, 4, 5])
        #expect(participant.availability.startMinute == 1320)
        #expect(participant.availability.endMinute == 360)
        #expect(participant.vacations == [OverlapPlanner.Vacation(startDate: "2026-09-10", endDate: "2026-09-12")])
    }

    @Test func repeatedDSTHourHasSameCivilWorkStatus() {
        var person = PersonProfile(name: "Ana", timeZoneID: "America/New_York")
        person.schedule = PeopleWorkSchedule(startMinute: 60, endMinute: 120, workingWeekdays: [1])
        #expect(person.workStatus(at: date("2026-11-01T05:30:00Z"), places: []) == .working)
        #expect(person.workStatus(at: date("2026-11-01T06:30:00Z"), places: []) == .working)
        #expect(person.workStatus(at: date("2026-11-01T07:00:00Z"), places: []) == .outsideHours)
    }

    @Test func vacationUsesPersonsCivilDayRatherThanMacDay() {
        var person = PersonProfile(name: "Ana", timeZoneID: "Pacific/Kiritimati")
        person.schedule.workingWeekdays = Array(1...7)
        person.schedule.startMinute = 0; person.schedule.endMinute = 0
        person.vacations = [PeopleVacation(startDate: "2026-09-10", endDate: "2026-09-10")]
        #expect(person.workStatus(at: date("2026-09-09T09:59:00Z"), places: []) == .working)
        #expect(person.workStatus(at: date("2026-09-09T10:00:00Z"), places: []) == .vacation)
        #expect(person.workStatus(at: date("2026-09-10T10:00:00Z"), places: []) == .working)
    }

    @Test func deniedContactsStillAllowManualPeople() async throws {
        let (defaults, cleanup) = TestDefaults.make(prefix: "meantime.people.tests"); defer { cleanup() }
        let contacts = FakePeopleContacts(.denied)
        let store = PeopleStore(defaults: defaults, contactsReader: contacts)
        #expect(await contacts.calls == 0)
        store.beginContactsImport()
        try await waitForIdle(store)
        #expect(store.contactsState == .denied)
        #expect(await contacts.calls == 1)
        #expect(store.save(PersonProfile(name: "Ana", timeZoneID: "UTC")).isEmpty)
    }

    @Test func fetchedContactsAreTransientAndNeverAutomaticallySaved() async throws {
        let (defaults, cleanup) = TestDefaults.make(prefix: "meantime.people.tests"); defer { cleanup() }
        let contacts = FakePeopleContacts(.success)
        let store = PeopleStore(defaults: defaults, contactsReader: contacts)
        store.beginContactsImport()
        try await waitForIdle(store)
        #expect(store.contacts == [PeopleContactCandidate(id: "contact-1", name: "Ana")])
        #expect(store.people.isEmpty)
        #expect(defaults.object(forKey: PeopleStore.storageKey) == nil)
        store.deactivate()
        #expect(store.contacts.isEmpty)
        #expect(store.activeResourceCount == 0)
    }

    @Test func deactivationCancelsInFlightReadAndPreventsLateResults() async throws {
        let (defaults, cleanup) = TestDefaults.make(prefix: "meantime.people.tests"); defer { cleanup() }
        let contacts = FakePeopleContacts(.delayed)
        let store = PeopleStore(defaults: defaults, contactsReader: contacts)
        store.beginContactsImport()
        #expect(store.activeResourceCount == 1)
        store.deactivate()
        try await waitForIdle(store)
        #expect(store.contacts.isEmpty)
        #expect(store.contactsState == .idle)
        #expect(store.activeResourceCount == 0)
    }

    private func waitForIdle(_ store: PeopleStore) async throws {
        for _ in 0..<100 where store.activeResourceCount != 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(store.activeResourceCount == 0)
    }

    /// 首启空态的建议地点：本机永远第一，再按人物顺序补所在地，去重、认不出的时区跳过、最多三个；日历未授权时不读日历。
    @Test func suggestedPlacesStartWithLocalThenPeopleWithoutDuplicates() {
        let people = [PersonPlace(name: "Ana", timeZoneID: "Europe/London", countryCode: nil),
                      PersonPlace(name: "Bo", timeZoneID: "America/Los_Angeles", countryCode: nil),
                      PersonPlace(name: "Cy", timeZoneID: "Not/AZone", countryCode: nil),
                      PersonPlace(name: "Mei", timeZoneID: "Asia/Tokyo", countryCode: nil),
                      PersonPlace(name: "Nia", timeZoneID: "Pacific/Auckland", countryCode: nil)]
        let local = TimeZone(identifier: "America/Los_Angeles")!
        #expect(SuggestedPlaces.identifiers(local: local, region: nil, people: people, now: .now)
                == ["America/Los_Angeles", "Europe/London", "Asia/Tokyo"])
        #expect(SuggestedPlaces.identifiers(local: local, region: nil, people: [], now: .now) == ["America/Los_Angeles"])
    }

    /// 系统地区：本机在洛杉矶、地区设成日本 → 第二颗是东京（该国人口最多的城市，带坐标）；地区就是本机所在国家时不重复建议；
    /// 认不出的地区码跳过。人物排在地区前面。
    @Test func suggestedPlacesAddTheHomeRegionsLargestCityWhenItIsAbroad() {
        let local = TimeZone(identifier: "America/Los_Angeles")!
        let home = SuggestedPlaces.homeCity(region: "JP", local: local)
        #expect(home?.identifier == "Asia/Tokyo")
        #expect(home?.coordinate != nil)
        #expect(SuggestedPlaces.identifiers(local: local, region: "JP", people: [], now: .now) == ["America/Los_Angeles", "Asia/Tokyo"])
        #expect(SuggestedPlaces.identifiers(local: local, region: "US", people: [], now: .now) == ["America/Los_Angeles"])
        #expect(SuggestedPlaces.identifiers(local: local, region: "ZZ", people: [], now: .now) == ["America/Los_Angeles"])
        let people = [PersonPlace(name: "Ana", timeZoneID: "Europe/London", countryCode: nil)]
        #expect(SuggestedPlaces.identifiers(local: local, region: "JP", people: people, now: .now)
                == ["America/Los_Angeles", "Europe/London", "Asia/Tokyo"])
    }

    /// 通讯录地址 → 城市：国家码对得上才认（「Paris, US」不是巴黎），没填国家按人口取第一个；索引里没有的城市跳过。
    @Test func contactCitiesResolveThroughTheIndexWithCountryGuard() {
        #expect(SuggestedPlaces.cityOption(.init(city: "Paris", country: "FR", count: 1))?.identifier == "Europe/Paris")
        #expect(SuggestedPlaces.cityOption(.init(city: "Paris", country: "", count: 1))?.identifier == "Europe/Paris")
        #expect(SuggestedPlaces.cityOption(.init(city: "Paris", country: "US", count: 1))?.identifier != "Europe/Paris")
        #expect(SuggestedPlaces.cityOption(.init(city: "Nowhere-That-Exists-Zzz", country: "", count: 1)) == nil)
        let local = TimeZone(identifier: "America/Los_Angeles")!
        let paris = SuggestedPlaces.cityOption(.init(city: "Paris", country: "FR", count: 3))!
        let merged = SuggestedPlaces.merge(local: SuggestedPlaces.option(identifier: local.identifier), people: [], region: nil,
                                           calendar: [], contacts: [paris, paris])
        #expect(merged.map(\.identifier) == ["America/Los_Angeles", "Europe/Paris"])
    }



}

private actor FakePeopleContacts: PeopleContactsReading {
    enum Outcome: Sendable { case success, denied, delayed }
    let outcome: Outcome
    private(set) var calls = 0
    init(_ outcome: Outcome) { self.outcome = outcome }
    func candidates() async throws -> [PeopleContactCandidate] {
        calls += 1
        try Task.checkCancellation()
        switch outcome {
        case .denied: throw PeopleContactsError.denied
        case .delayed: try await Task.sleep(for: .seconds(60))
        case .success: break
        }
        return [PeopleContactCandidate(id: "contact-1", name: "Ana")]
    }
}

/// 人物行「共同时段」：本机与对方工作时段求交，取 7 天里第一段 ≥ 30 分钟的重叠。
struct PeopleOverlapTests {
    private func utc(_ v: String) -> Date { ISO8601DateFormatter().date(from: v)! }

    /// 本机洛杉矶 9–18、对方伦敦 9–18：重叠是洛杉矶的 9:00–10:00（伦敦 17–18）。周一 2026-09-14 16:00Z = 洛杉矶 9:00。
    @Test func londonAndLosAngelesShareOneMorningHour() throws {
        let me = PeopleOverlap.localParticipant(availability: .standard, timeZoneID: "America/Los_Angeles")
        let them = OverlapPlanner.Participant(id: UUID(), name: "Mei", timeZoneID: "Europe/London", availability: .standard, countryCode: "GB")
        let now = utc("2026-09-14T14:00:00Z") // 洛杉矶周一 7:00
        let window = try #require(PeopleOverlap.nextSharedWindow(person: them, local: me, now: now))
        #expect(window.start == utc("2026-09-14T16:00:00Z") && window.end == utc("2026-09-14T17:00:00Z") && window.dayOffset == 0)
        // 已经到了洛杉矶 9:30：起点被「现在」截掉，还剩 30 分钟正好够；9:45 就不够了 → 跳到明天。
        let late = try #require(PeopleOverlap.nextSharedWindow(person: them, local: me, now: utc("2026-09-14T16:30:00Z")))
        #expect(late.start == utc("2026-09-14T16:30:00Z") && late.dayOffset == 0)
        let tomorrow = try #require(PeopleOverlap.nextSharedWindow(person: them, local: me, now: utc("2026-09-14T16:45:00Z")))
        #expect(tomorrow.dayOffset == 1 && tomorrow.start == utc("2026-09-15T16:00:00Z"))
    }

    /// 东京 9–18 与洛杉矶 9–18 只剩一小时交集：洛杉矶周一 17:00–18:00 = 东京周二 9:00–10:00（相差 16 小时）；
    /// 对方作息改成周末也休、只有周日的人则 7 天内可能一段都没有。
    @Test func tokyoDaytimeOverlapsLosAngelesOnlyAtTheEndOfTheDay() throws {
        let me = PeopleOverlap.localParticipant(availability: .standard, timeZoneID: "America/Los_Angeles")
        let tokyo = OverlapPlanner.Participant(id: UUID(), name: "Ken", timeZoneID: "Asia/Tokyo", availability: .standard, countryCode: "JP")
        let window = try #require(PeopleOverlap.nextSharedWindow(person: tokyo, local: me, now: utc("2026-09-14T14:00:00Z")))
        #expect(window.start == utc("2026-09-15T00:00:00Z") && window.end == utc("2026-09-15T01:00:00Z") && window.dayOffset == 0)
        let disjoint = OverlapPlanner.Participant(id: UUID(), name: "Ken", timeZoneID: "Asia/Tokyo",
                                                  availability: Availability(startMinute: 10 * 60, endMinute: 16 * 60, weekdaysOnly: true), countryCode: "JP")
        #expect(PeopleOverlap.nextSharedWindow(person: disjoint, local: me, now: utc("2026-09-14T14:00:00Z")) == nil, "东京 10–16 = 洛杉矶 18–24，与 9–18 不交")
        let night = OverlapPlanner.Participant(id: UUID(), name: "Ken", timeZoneID: "Asia/Tokyo",
                                               availability: Availability(startMinute: 22 * 60, endMinute: 6 * 60, weekdaysOnly: true), countryCode: "JP")
        #expect(PeopleOverlap.nextSharedWindow(person: night, local: me, now: utc("2026-09-14T14:00:00Z")) != nil)
    }

    /// 「每工作日重叠 N 小时 / 对方下班 = 我几点」（调研 #6）：人物页与排会页读同一个函数。
    /// 判据另算一遍：伦敦 9–18 与马德里 9–18 差一小时，重叠是马德里的 10:00–18:00 共 8 小时；
    /// 对方下班那一刻在本机是 17:00。
    @Test func theOverlapSummaryReportsTypicalHoursAndWhenTheirDayEnds() throws {
        let me = PeopleOverlap.localParticipant(availability: .standard, timeZoneID: "Europe/London")
        let madrid = OverlapPlanner.Participant(id: UUID(), name: "Ana", timeZoneID: "Europe/Madrid",
                                                availability: .standard, countryCode: "ES")
        // 周一 2026-09-14 07:00Z = 伦敦 8:00（还没上班）。
        let summary = PeopleOverlap.summary(person: madrid, local: me, now: utc("2026-09-14T07:00:00Z"))
        #expect(summary.typicalMinutes == 480)
        #expect(summary.isUniform)
        #expect(summary.workdays == 5, "7 天里两边都上班的是五个工作日，周末不算")
        // 马德里 18:00 = 16:00Z = 伦敦 17:00。
        #expect(summary.theirDayEnd == utc("2026-09-14T16:00:00Z"))

        // 完全不重叠的两地：工作日照数，重叠 0（界面据此写「每工作日重叠 0 分钟」而不是假装没有数据）。
        let tokyo = OverlapPlanner.Participant(id: UUID(), name: "Ken", timeZoneID: "Asia/Tokyo",
                                               availability: Availability(startMinute: 10 * 60, endMinute: 16 * 60, weekdaysOnly: true),
                                               countryCode: "JP")
        let la = PeopleOverlap.localParticipant(availability: .standard, timeZoneID: "America/Los_Angeles")
        let none = PeopleOverlap.summary(person: tokyo, local: la, now: utc("2026-09-14T14:00:00Z"))
        #expect(none.typicalMinutes == 0)
        // 东京 10–16 在洛杉矶是前一天 18–24：本机这七天里「两边都上班」的日子因此多算一天（周一到周六早晨都有对方的班次）。
        // 东京 10–16 在洛杉矶是**前一天** 18–24：从洛杉矶周一往后数，周一到周四各沾到东京周二到周五的班，
        // 洛杉矶周五沾到的是东京周六（不上班），所以「两边都上班」的日子是四天。
        #expect(none.workdays == 4)

        // 休假会把那天从「两边都上班」里去掉：对方休两天 → 工作日剩三天，典型值不变。
        let onLeave = OverlapPlanner.Participant(id: madrid.id, name: madrid.name, timeZoneID: madrid.timeZoneID,
                                                 availability: .standard, countryCode: "ES",
                                                 vacations: [OverlapPlanner.Vacation(startDate: "2026-09-15", endDate: "2026-09-16")])
        let partial = PeopleOverlap.summary(person: onLeave, local: me, now: utc("2026-09-14T07:00:00Z"))
        #expect(partial.typicalMinutes == 480)
        #expect(partial.workdays == 3, "马德里休 15、16 两天 → 只剩三天")
    }

    /// 「对方上班时提醒我」：按对方时区、工作日与假期找下一个上班时刻——周五晚上问就是下周一，
    /// 周一在休假就是周二；一周都不上班的人没有。
    @Test func nextWorkStartSkipsWeekendsAndVacations() {
        var mei = PersonProfile(name: "Mei", timeZoneID: "Asia/Tokyo")
        // 2026-09-18 是周五；东京 20:00 = 11:00Z。
        let fridayEvening = utc("2026-09-18T11:00:00Z")
        let monday = PeopleReminder.nextWorkStart(for: mei, places: [], now: fridayEvening)
        #expect(monday == utc("2026-09-21T00:00:00Z"), "下周一东京 9:00")
        mei.vacations = [PeopleVacation(startDate: "2026-09-21", endDate: "2026-09-21")]
        #expect(PeopleReminder.nextWorkStart(for: mei, places: [], now: fridayEvening) == utc("2026-09-22T00:00:00Z"), "周一休假 → 周二")
        // 周一 8:00 问：当天 9:00 还没到，就是当天（假期先清掉）。
        mei.vacations = []
        #expect(PeopleReminder.nextWorkStart(for: mei, places: [], now: utc("2026-09-20T23:00:00Z")) == utc("2026-09-21T00:00:00Z"))
        mei.schedule.workingWeekdays = []
        #expect(PeopleReminder.nextWorkStart(for: mei, places: [], now: fridayEvening) == nil, "一周都不上班")
    }
}
