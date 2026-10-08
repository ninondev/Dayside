// SPDX-License-Identifier: GPL-3.0-only
#if DEBUG
import Foundation

/// 功能模块的夹具：人物、日历、计时器账本、旅行的样例与永不弹框的提供者。
@MainActor
enum FeatureFixture {
    static func makeAgendaMenuBarReader(defaults: UserDefaults) -> AgendaMenuBarReader {
        AgendaMenuBarReader(defaults: defaults, authorization: { FixtureAgenda().authorization },
            read: { interval, calendarIDs in
                let service = FixtureAgenda()
                defer { service.stop() }
                return try service.readSnapshot(in: interval, calendarIDs: calendarIDs).events.map {
                    AgendaEvent(identifier: $0.identifier, calendarID: $0.calendarID, title: $0.title,
                        start: $0.start, end: $0.end, isAllDay: $0.isAllDay, isCancelled: $0.isCancelled,
                        isDeclined: $0.isDeclined, location: nil, urls: [])
                }
            })
    }

    static func install(into hub: FeatureHub, defaults: UserDefaults) {
        hub.register(.people) {
            let store = PeopleStore(defaults: defaults, contactsReader: FixtureContacts())
            if !UITestFixture.isEmpty && !PerformanceProbe.isRequested {
                for person in peopleSample() { _ = store.save(person) }
            }
            return PeopleModule(store: store)
        }
        hub.register(.timers) {
            if !UITestFixture.isEmpty {
                let now = Date.now.timeIntervalSince1970
                let entries = [now - 7_200, now - 5_400, now - 3_600, now - 86_400 - 3_600, now - 86_400 - 1_800]
                    .map { "{\"endedAt\":\($0),\"seconds\":1500}" }.joined(separator: ",")
                defaults.set(Data("{\"version\":1,\"notifications\":false,\"session\":null,\"ledger\":[\(entries)]}".utf8), forKey: TimerStore.storageKey)
            }
            return TimersModule(store: TimerStore(defaults: defaults, notificationClient: UITestFixture.makeNotifications(),
                                                  observeSystemEvents: false, runtimeEnabled: false))
        }
        hub.register(.agenda) {
            let store = AgendaStore(defaults: defaults, makeService: { FixtureAgenda() }, openURL: { _ in false })
            if !UITestFixture.isEmpty && FixtureAgenda.mode != "off" { store.setEnabled(true) }
            if FixtureAgenda.mode == "nonechosen" { store.selectNoCalendars() }
            return AgendaModule(store: store)
        }
        hub.register(.travel) {
            let store = TravelStore(defaults: defaults)
            let fixture = ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_TRAVEL"] ?? "west"
            if !UITestFixture.isEmpty && fixture != "none" {
                let origin = fixture == "east" ? "America/New_York" : "America/Los_Angeles"
                let destination = fixture == "east" ? "Europe/Paris" : fixture == "east8" ? "Europe/London" : fixture == "zero" ? "America/Vancouver" : "Asia/Tokyo"
                let days = fixture == "east" ? 6 : fixture == "east8" ? 7 : 4
                let hour = fixture == "east" ? 18 : fixture == "east8" ? 19 : 11
                let minute = fixture == "east" ? 30 : fixture == "east8" ? 0 : 20
                let flight = fixture == "east" ? 7 * 60 + 15 : fixture == "east8" ? 10 * 60 + 25 : 11 * 60 + 45
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(identifier: origin)!
                let day = calendar.date(byAdding: .day, value: days, to: Date.now)!
                let departure = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
                _ = store.save(TravelTrip(name: "Travel", originTimeZoneID: origin, destinationTimeZoneID: destination,
                                         departureUnix: departure.timeIntervalSince1970,
                                         arrivalUnix: departure.addingTimeInterval(Double(flight) * 60).timeIntervalSince1970))
            }
            return TravelModule(store: store)
        }
        hub.register(.dstWatch) {
            DSTWatchModule(store: DSTWatchStore(defaults: defaults, notificationClient: UITestFixture.makeNotifications(), observeSystemEvents: false))
        }
        hub.register(.sharing) {
            let store = SharingStore(defaults: defaults)
            if !UITestFixture.isEmpty {
                store.draft.timeZoneID = "Asia/Tokyo"
                store.draft.displayName = "Mei"
                // `MEANTIME_UI_TEST_SHARING_HOURS=1260-120`：名片带可约时段（开始-结束，分钟；结束早于开始 = 跨午夜）；
                // 第三段可选，是哪几天（`1260-120-1234567`，周日 = 1）。
                if let raw = ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_SHARING_HOURS"] {
                    let parts = raw.split(separator: "-").compactMap { Int($0) }
                    if parts.count >= 2 {
                        store.draft.includesAvailability = true
                        store.draft.startMinute = parts[0]
                        store.draft.endMinute = parts[1]
                    }
                    if parts.count == 3 {
                        store.draft.workingWeekdays = String(parts[2]).compactMap { $0.wholeNumberValue }.filter { (1...7).contains($0) }
                    }
                }
                store.prepare(now: .now, locale: UITestFixture.uiLocale)
            }
            return SharingModule(store: store)
        }
    }

    /// 人物页的样例：默认三位（伦敦、东京、奥克兰）；`MEANTIME_UI_TEST_PEOPLE=five` 换成五大洲五位
    /// （伦敦、圣保罗正在休假、班加罗尔的半小时时区、东京、奥克兰），量「五个人一屏装得下」与各种状态。
    static func peopleSample() -> [PersonProfile] {
        if let scenario = ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_COPY_PEOPLE"],
           ["contact", "weekoff", "overnight", "allDay", "vacation-editor"].contains(scenario) {
            var person = PersonProfile(name: "Ana", timeZoneID: "Europe/London", countryCode: "GB")
            switch scenario {
            case "contact": person.contactIdentifier = "fixture-ana"
            case "weekoff": person.schedule.workingWeekdays = []
            case "overnight":
                person.schedule.startMinute = 1260
                person.schedule.endMinute = 120
            case "allDay": person.schedule.endMinute = person.schedule.startMinute
            case "vacation-editor":
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(identifier: person.timeZoneID)!
                let day = PersonProfile.civilDate(.now, calendar: calendar)
                person.vacations = [PeopleVacation(startDate: day, endDate: day)]
            default: break
            }
            return [person]
        }
        guard ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_PEOPLE"] == "five" else {
            return [PersonProfile(name: "Ana", timeZoneID: "Europe/London", countryCode: "GB"),
                    PersonProfile(name: "Mei", timeZoneID: "Asia/Tokyo", countryCode: "JP"),
                    PersonProfile(name: "Nia", timeZoneID: "Pacific/Auckland", countryCode: "NZ")]
        }
        var lucas = PersonProfile(name: "Lucas", timeZoneID: "America/Sao_Paulo", countryCode: "BR")
        lucas.schedule.startMinute = 600
        lucas.schedule.endMinute = 1140
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        let today = calendar.startOfDay(for: .now)
        if let from = calendar.date(byAdding: .day, value: -1, to: today), let to = calendar.date(byAdding: .day, value: 3, to: today) {
            lucas.vacations = [PeopleVacation(startDate: PersonProfile.civilDate(from, calendar: calendar),
                                              endDate: PersonProfile.civilDate(to, calendar: calendar))]
        }
        var priya = PersonProfile(name: "Priya", timeZoneID: "Asia/Kolkata", countryCode: "IN")
        priya.schedule.startMinute = 570
        priya.schedule.endMinute = 1110
        var nia = PersonProfile(name: "Nia", timeZoneID: "Pacific/Auckland", countryCode: "NZ")
        nia.schedule.startMinute = 480
        nia.schedule.endMinute = 990
        return [PersonProfile(name: "Ana", timeZoneID: "Europe/London", countryCode: "GB"), lucas, priya,
                PersonProfile(name: "Mei", timeZoneID: "Asia/Tokyo", countryCode: "JP"), nia]
    }
}

private actor FixtureContacts: PeopleContactsReading {
    func candidates() async throws -> [PeopleContactCandidate] {
        [.init(id: "fixture-ana", name: "Ana"), .init(id: "fixture-mei", name: "Mei")]
    }
}

@MainActor private final class FixtureAgenda: AgendaService {
    static var mode: String { ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_AGENDA"] ?? "" }
    var authorization: AgendaAuthorization {
        if UITestFixture.isErrors { return .denied }
        switch Self.mode {
        case "denied": return .denied
        case "restricted": return .restricted
        case "writeOnly": return .writeOnly
        default: return .fullAccess
        }
    }
    var activeResourceCount: Int { 0 }
    func requestFullAccess() async throws -> Bool { authorization == .fullAccess }
    func observeChanges(_ receive: @escaping @MainActor @Sendable () -> Void) {}
    func stop() {}
    func snapshot(in interval: DateInterval, calendarIDs: [String]?) async throws -> AgendaSnapshot {
        try readSnapshot(in: interval, calendarIDs: calendarIDs)
    }
    func readSnapshot(in interval: DateInterval, calendarIDs: [String]?) throws -> AgendaSnapshot {
        if authorization != .fullAccess { throw AgendaFailure.permission }
        if Self.mode == "failed" { throw AgendaFailure.read }
        let calendars: [AgendaCalendar] = Self.mode == "nocalendars" ? [] : [
            .init(id: "fixture-work", title: "Work", sourceTitle: "iCloud", color: .init(red: 0, green: 0.48, blue: 1, opacity: 1)),
            .init(id: "fixture-home", title: "Home", sourceTitle: "iCloud", color: .init(red: 1, green: 0.5, blue: 0, opacity: 1))
        ]
        guard Self.mode != "empty", !calendars.isEmpty else {
            return AgendaSnapshot(calendars: calendars, events: [], interval: interval)
        }
        let now = Date.now.timeIntervalSince1970
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let today = calendar.startOfDay(for: .now)
        func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Double {
            let date = calendar.date(byAdding: .day, value: day, to: today)!
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date)!.timeIntervalSince1970
        }
        let link = [AgendaURLFacts(url: URL(string: "https://meet.google.com/abc-defg-hij")!)!]
        func event(_ id: String, _ title: String, _ start: Double, _ end: Double,
                   home: Bool = false, allDay: Bool = false, meeting: Bool = false, location: String? = nil) -> AgendaEvent {
            AgendaEvent(identifier: id, calendarID: home ? "fixture-home" : "fixture-work", title: title,
                        start: start, end: end, isAllDay: allDay, isCancelled: false, isDeclined: false,
                        location: location, urls: meeting ? link : [], hasAttendees: meeting)
        }
        var events = [
            event("fixture-all-day", "Tokyo office closed", at(0, 0), at(1, 0), allDay: true),
            event("fixture-late", "Late sync with Sydney", at(-1, 23), at(0, 0, 30), meeting: true),
            event("fixture-standup", "Standup with Tokyo", at(0, 6, 30), at(0, 7), meeting: true),
            event("fixture-review", UITestFixture.hasLongMeeting
                  ? "London and Tokyo international project review with the customer support, accessibility and release coordination teams"
                  : "London · Tokyo project review", now + 900, now + 2700, meeting: true),
            event("fixture-design", "Design discussion", now + 3600, now + 5400, location: "Studio"),
            event("fixture-lunch", "Lunch with Ana", at(0, 12, 30), at(0, 13, 15), home: true, location: "Tartine"),
            event("fixture-planning", "Planning with Tokyo", at(0, 17), at(0, 18), meeting: true),
            event("fixture-mom", "Call Mom", at(0, 21), at(0, 21, 30), home: true),
            event("fixture-offsite", "Offsite", at(-1, 9), at(1, 17))
        ]
        for week in 0..<6 {
            events.append(event("fixture-weekly", "Weekly sync", at(7 * week + 1, 9), at(7 * week + 1, 9, 30), meeting: true))
            events.append(event("fixture-gym", "Gym", at(7 * week + 1, 7), at(7 * week + 1, 7, 30), home: true))
        }
        if Self.mode == "crowded" {
            let titles = ["Morning briefing", "Product review", "Project coordination across London, Tokyo and Sydney with the whole team", "Research review", "Afternoon check-in", "Evening planning"]
            for index in 0..<6 {
                let start = index == 2 ? at(0, 10, 15) : at(0, 8 + index * 2)
                events.append(event("fixture-extra-\(index)", titles[index], start, start + 3600))
            }
        }
        if Self.mode == "next" {
            events = events.filter { $0.start >= at(1, 0) }
        }
        events = events.filter { $0.start < interval.end.timeIntervalSince1970 && $0.end > interval.start.timeIntervalSince1970 }
        return AgendaSnapshot(calendars: calendars, events: events, interval: interval)
    }
}
#endif
