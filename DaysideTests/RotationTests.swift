// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import Dayside

/// 例会轮换:Rust `planner.rotate` 拿 Foundation 给的真实时区事实分摊「时段外」的负担。
struct RotationTests {
    private func participant(_ name: String, _ zone: String, _ country: String,
                             start: Int = 9 * 60, end: Int = 18 * 60) -> OverlapPlanner.Participant {
        OverlapPlanner.Participant(id: UUID(), name: name, timeZoneID: zone,
                                   availability: Availability(startMinute: start, endMinute: end, weekdaysOnly: false),
                                   countryCode: country)
    }

    private func utc(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    /// 参与者 `tz` 的 9–18:某次会议在时段外的分钟(与 Rust `evaluate` 同一口径:对最近的一天算,
    /// 开始前或结束后取大者,再取最小的一天)。
    private func expectedStretch(start: Date, end: Date, tz: TimeZone, startMinute: Int, endMinute: Int) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        var best = Int.max
        for offset in -1...1 {
            let day = cal.startOfDay(for: cal.date(byAdding: .day, value: offset, to: start)!)
            let open = day.addingTimeInterval(TimeInterval(startMinute * 60))
            let close = day.addingTimeInterval(TimeInterval(endMinute * 60))
            let before = max(0, open.timeIntervalSince(start))
            let after = max(0, end.timeIntervalSince(close))
            best = min(best, Int((max(before, after) / 60).rounded(.up)))
        }
        return best
    }

    /// 洛杉矶、伦敦、东京各自 9–18:没有大家都合适的时段,轮换让三地各吃一部分,而不是一地每周熬夜。
    @Test func threeContinentsShareTheBurdenInsteadOfOneCityEveryWeek() {
        let people = [participant("Los Angeles", "America/Los_Angeles", "US"),
                      participant("Ana", "Europe/London", "GB"),
                      participant("Mei", "Asia/Tokyo", "JP")]
        let monday = utc("2026-09-14T07:00:00Z")   // 2026-09-14 00:00 PDT
        let rotation = OverlapPlanner.rotate(.init(participants: people, fromDay: monday, notBefore: monday, count: 6,
                                                   durationMinutes: 60, localTimeZoneID: "America/Los_Angeles"))
        #expect(rotation.needed)
        #expect(rotation.skipped == 0)
        #expect(rotation.held.count == 6)
        #expect(rotation.totals.allSatisfy { $0.outsideCount >= 1 }, Comment(rawValue: "\(rotation.totals)"))
        #expect(rotation.spreadMinutes <= 240, Comment(rawValue: "spread \(rotation.spreadMinutes)"))
        let heaviest = rotation.totals.map(\.outsideMinutes).max()!
        // 固定一个时段六周,一地要扛 6 × 420 分钟以上;轮换后最重的人远低于此。
        #expect(heaviest < 6 * 420 / 2, Comment(rawValue: "heaviest \(heaviest)"))
        // 每次都落在本机的那一天,且每人的时段外分钟与 Foundation 自己算的一致。
        var la = Calendar(identifier: .gregorian)
        la.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        for occurrence in rotation.occurrences {
            let window = try! #require(occurrence.window)
            #expect(la.isDate(window.best, inSameDayAs: occurrence.day))
            #expect(la.dateComponents([.weekday], from: occurrence.day).weekday == 2)
            for (index, person) in people.enumerated() {
                let expected = expectedStretch(start: window.best, end: window.bestEnd, tz: person.timeZone,
                                               startMinute: 9 * 60, endMinute: 18 * 60)
                #expect(occurrence.stretch[index] == expected, Comment(rawValue: "\(person.name) at \(window.best): \(occurrence.stretch[index]) vs \(expected)"))
                #expect(occurrence.stretch[index] <= 480)
            }
        }
        // 确定性:同样的请求给同样的排法。
        let again = OverlapPlanner.rotate(.init(participants: people, fromDay: monday, notBefore: monday, count: 6,
                                                durationMinutes: 60, localTimeZoneID: "America/Los_Angeles"))
        #expect(again.occurrences.map { $0.window?.best } == rotation.occurrences.map { $0.window?.best })
    }

    /// 每次发生都落在本机的那一天、指定的星期,且每人的时段外分钟与 Foundation 自己算的一致。
    private func checkOccurrences(_ rotation: OverlapPlanner.Rotation, people: [OverlapPlanner.Participant],
                                  localTimeZoneID: String, weekday: Int, maxStretch: Int = 480) throws {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = try #require(TimeZone(identifier: localTimeZoneID))
        for occurrence in rotation.occurrences {
            let window = try #require(occurrence.window)
            #expect(local.startOfDay(for: occurrence.day) == occurrence.day)
            #expect(local.isDate(window.best, inSameDayAs: occurrence.day))
            #expect(local.dateComponents([.weekday], from: occurrence.day).weekday == weekday)
            for (index, person) in people.enumerated() {
                let expected = expectedStretch(start: window.best, end: window.bestEnd, tz: person.timeZone,
                                               startMinute: 9 * 60, endMinute: 18 * 60)
                #expect(occurrence.stretch[index] == expected, Comment(rawValue: "\(person.name) at \(window.best): \(occurrence.stretch[index]) vs \(expected)"))
                #expect(occurrence.stretch[index] <= maxStretch)
            }
        }
    }

    /// 组织者在伦敦:天按伦敦切,八周跨过 10-25 伦敦退出夏令时,每次仍落在伦敦的周一、相邻两次隔 7 个伦敦日,
    /// 每人的时段外分钟与 Foundation 自算一致;洛杉矶与东京各自在伦敦时区之外,也都至少吃到一次。
    @Test func aLondonOrganizerGetsMondaysInLondonAcrossTheClockChange() throws {
        let people = [participant("Los Angeles", "America/Los_Angeles", "US"),
                      participant("Ana", "Europe/London", "GB"),
                      participant("Mei", "Asia/Tokyo", "JP")]
        let london = try #require(TimeZone(identifier: "Europe/London"))
        let monday = utc("2026-09-13T23:00:00Z")   // 2026-09-14 00:00 BST
        #expect(OverlapPlanner.defaultRotationWeekday(onOrAfter: monday, in: london, countryCode: "GB") == 2)
        let rotation = OverlapPlanner.rotate(.init(participants: people, fromDay: monday, notBefore: monday, count: 8,
                                                   durationMinutes: 60, localTimeZoneID: "Europe/London"))
        #expect(rotation.needed)
        #expect(rotation.skipped == 0)
        #expect(rotation.held.count == 8)
        #expect(rotation.totals.allSatisfy { $0.outsideCount >= 1 }, Comment(rawValue: "\(rotation.totals)"))
        try checkOccurrences(rotation, people: people, localTimeZoneID: "Europe/London", weekday: 2)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = london
        let days = rotation.occurrences.map(\.day)
        #expect(days.first == monday)
        for (earlier, later) in zip(days, days.dropFirst()) {
            #expect(cal.dateComponents([.day], from: earlier, to: later).day == 7)
        }
        // 10-26 是退出夏令时后的第一个周一:那天的 0 点比前一周晚一小时,按伦敦日切才对。
        #expect(days[6] == utc("2026-10-26T00:00:00Z"))
        #expect(days[6].timeIntervalSince(days[5]) == 7 * 86_400 + 3_600)
    }

    /// 组织者在东京、指定周三:从参考日起的第一个东京周三开始,每次都落在东京的周三;
    /// 东京 9–18 与洛杉矶 9–18 隔着日界线,每人的时段外分钟仍与 Foundation 自算一致。
    @Test func aTokyoOrganizerGetsTheChosenWeekdayInTokyo() throws {
        let people = [participant("Los Angeles", "America/Los_Angeles", "US"),
                      participant("Ana", "Europe/London", "GB"),
                      participant("Mei", "Asia/Tokyo", "JP")]
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let monday = utc("2026-09-13T15:00:00Z")   // 2026-09-14 00:00 JST
        let wednesday = OverlapPlanner.firstDate(weekday: 4, onOrAfter: monday, in: tokyo)
        #expect(wednesday == utc("2026-09-15T15:00:00Z"))   // 2026-09-16 00:00 JST
        let rotation = OverlapPlanner.rotate(.init(participants: people, fromDay: wednesday, notBefore: monday, count: 6,
                                                   durationMinutes: 60, localTimeZoneID: "Asia/Tokyo"))
        #expect(rotation.needed)
        #expect(rotation.skipped == 0)
        #expect(rotation.held.count == 6)
        #expect(rotation.totals.allSatisfy { $0.outsideCount >= 1 }, Comment(rawValue: "\(rotation.totals)"))
        try checkOccurrences(rotation, people: people, localTimeZoneID: "Asia/Tokyo", weekday: 4)
        let days = rotation.occurrences.map(\.day)
        #expect(days.first == wednesday)
        #expect(days.last == utc("2026-10-20T15:00:00Z"))   // 2026-10-21 00:00 JST,东京没有夏令时,整 7 天一跳
        for (earlier, later) in zip(days, days.dropFirst()) {
            #expect(later.timeIntervalSince(earlier) == 7 * 86_400)
        }
        // 东京日里的候选与洛杉矶日里的不同:同一批人换个组织者,排出来的时刻集合不必一样,但账同样在上限内。
        let heaviest = rotation.totals.map(\.outsideMinutes).max()!
        #expect(heaviest < 6 * 420 / 2, Comment(rawValue: "heaviest \(heaviest)"))
    }

    /// 洛杉矶与纽约每天都有共同的工作时间:没什么可轮,每次都是所有人都在时段内。
    @Test func overlappingCitiesNeedNoRotation() {
        let people = [participant("Los Angeles", "America/Los_Angeles", "US"), participant("Ben", "America/New_York", "US")]
        let monday = utc("2026-09-14T07:00:00Z")
        let rotation = OverlapPlanner.rotate(.init(participants: people, fromDay: monday, notBefore: monday, count: 3,
                                                   durationMinutes: 30, localTimeZoneID: "America/Los_Angeles"))
        #expect(!rotation.needed)
        #expect(rotation.spreadMinutes == 0)
        #expect(rotation.totals.allSatisfy { $0.outsideMinutes == 0 && $0.outsideCount == 0 })
        #expect(rotation.occurrences.allSatisfy { $0.window?.tier == .everyone })
    }

    // 单人也是组织者，夜间负担照常记账。
    @Test func rotationSendsClockWeightPreferencesToRust() throws {
        let people = [participant("Organizer", "Etc/UTC", "GB")]
        let monday = utc("2026-09-14T00:00:00Z")
        var preferences = RotationPreferences()
        preferences.split = "share"
        preferences.clockWeight = "gentle"
        var request = OverlapPlanner.RotationRequest(
            participants: people, fromDay: monday, notBefore: utc("2026-09-14T22:00:00Z"), count: 1,
            durationMinutes: 60, localTimeZoneID: "Etc/UTC", maxStretchMinutes: 480,
            split: preferences.split, clockWeight: preferences.clockWeight)
        let weighted = OverlapPlanner.rotate(request)
        let weightedTotal = try #require(weighted.totals.first)
        #expect(weighted.held.count == 1)
        #expect(weightedTotal.outsideMinutes > 0)
        #expect(weightedTotal.weightedMinutes > weightedTotal.outsideMinutes)
        #expect(weighted.held.first?.cost == [weightedTotal.weightedMinutes])

        preferences.clockWeight = "off"
        request.clockWeight = preferences.clockWeight
        let unweighted = OverlapPlanner.rotate(request)
        #expect(unweighted.held.count == 1)
        #expect(unweighted.totals.allSatisfy { $0.weightedMinutes == $0.outsideMinutes })
        #expect(unweighted.held.first?.cost == unweighted.held.first?.stretch)
    }

    /// 东京在第二次那周休假:那次跳过、不记账,其余照排;每两周一次时日期隔 14 天。
    @Test func aVacationSkipsThatOccurrenceAndBiweeklySpacingHolds() {
        var mei = participant("Mei", "Asia/Tokyo", "JP")
        mei.vacations = [.init(startDate: "2026-09-27", endDate: "2026-09-30")]
        let people = [participant("Los Angeles", "America/Los_Angeles", "US"), participant("Ana", "Europe/London", "GB"), mei]
        let monday = utc("2026-09-14T07:00:00Z")
        let rotation = OverlapPlanner.rotate(.init(participants: people, fromDay: monday, notBefore: monday, count: 3,
                                                   intervalWeeks: 2, durationMinutes: 60, localTimeZoneID: "America/Los_Angeles"))
        #expect(rotation.skipped == 1)
        #expect(rotation.occurrences[1].window == nil)
        #expect(rotation.occurrences[1].stretch.allSatisfy { $0 == 0 })
        #expect(rotation.occurrences[0].window != nil && rotation.occurrences[2].window != nil)
        #expect(rotation.occurrences[2].day.timeIntervalSince(rotation.occurrences[0].day) == 28 * 86_400)
        let charged = rotation.totals.map(\.outsideCount).reduce(0, +)
        let held = rotation.held.map { $0.stretch.filter { $0 > 0 }.count }.reduce(0, +)
        #expect(charged == held)
    }

    /// 周六打开排会页:例会默认落到周一,而不是「每周六」;选了周三就从下一个周三起。
    @Test func aRecurringMeetingDefaultsToTheFirstWorkingDayNotTheWeekend() {
        let la = TimeZone(identifier: "America/Los_Angeles")!
        let saturday = utc("2026-09-12T19:00:00Z")   // 2026-09-12 12:00 PDT
        #expect(OverlapPlanner.defaultRotationWeekday(onOrAfter: saturday, in: la, countryCode: "US") == 2)
        #expect(OverlapPlanner.firstDate(weekday: 2, onOrAfter: saturday, in: la) == utc("2026-09-14T07:00:00Z"))
        #expect(OverlapPlanner.firstDate(weekday: 4, onOrAfter: saturday, in: la) == utc("2026-09-16T07:00:00Z"))
        let monday = utc("2026-09-14T19:00:00Z")
        #expect(OverlapPlanner.defaultRotationWeekday(onOrAfter: monday, in: la, countryCode: "US") == 2)
        #expect(OverlapPlanner.firstDate(weekday: 2, onOrAfter: monday, in: la) == utc("2026-09-14T07:00:00Z"))
    }

    /// 六场合成一份 .ics:一个 VCALENDAR、六个 VEVENT,每场的说明都写全各地时间。
    @Test func aSeriesExportsAsOneCalendarFileWithEveryOccurrence() {
        let people = [participant("Los Angeles", "America/Los_Angeles", "US"), participant("Mei", "Asia/Tokyo", "JP")]
        let monday = utc("2026-09-14T07:00:00Z")
        let rotation = OverlapPlanner.rotate(.init(participants: people, fromDay: monday, notBefore: monday, count: 6,
                                                   durationMinutes: 60, localTimeZoneID: "America/Los_Angeles"))
        let events = rotation.held.map { occurrence in
            MeetingEvent.make(window: occurrence.window!, names: people.map(\.name), timeZones: people.map(\.timeZone),
                              title: "Weekly", footer: "Dayside", locale: Locale(identifier: "en"), hourStyle: .force24)
        }
        let text = MeetingEvent.icsSeriesText(events, stamp: Date(timeIntervalSince1970: 0))
        #expect(text.components(separatedBy: "BEGIN:VCALENDAR").count == 2)
        #expect(text.components(separatedBy: "BEGIN:VEVENT").count == 7)
        #expect(text.components(separatedBy: "DESCRIPTION:Los Angeles").count == 7)
        #expect(text.hasSuffix("END:VEVENT\r\nEND:VCALENDAR\r\n"))
    }
}

/// 拆成 N 场：Rust `planner.split` 挑时刻，这里核「每人至少一场在自己的工作时段内」这个结论，
/// 判据用 Foundation 自算（把每场起止换到各人时区，看是否落在 9–18 里），不看 Rust 自己报的 inside。
struct SplitSessionTests {
    private func participant(_ name: String, _ zone: String, _ country: String)
        -> OverlapPlanner.Participant {
        OverlapPlanner.Participant(id: UUID(), name: name, timeZoneID: zone,
                                   availability: Availability(startMinute: 9 * 60, endMinute: 18 * 60, weekdaysOnly: false),
                                   countryCode: country)
    }

    private func utc(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    /// 一场会议在某人当地是否整段落在 9:00–18:00 内（独立于被测代码的判据）。
    private func inside(start: Date, end: Date, zone: String) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        let day = calendar.startOfDay(for: start)
        let open = day.addingTimeInterval(9 * 3600)
        let close = day.addingTimeInterval(18 * 3600)
        return start >= open && end <= close
    }

    @Test func threeContinentsGetThreeSessionsThatCoverEveryone() {
        let people = [participant("洛杉矶", "America/Los_Angeles", "US"),
                      participant("伦敦", "Europe/London", "GB"),
                      participant("东京", "Asia/Tokyo", "JP")]
        let split = OverlapPlanner.split(.init(participants: people, from: utc("2026-09-21T16:00:00Z"),
                                               days: 5, durationMinutes: 60, sessions: 3,
                                               localTimeZoneID: "America/Los_Angeles"))
        #expect(split.needed)
        #expect(split.sessions.count == 3)
        #expect(split.uncovered.isEmpty)
        // 自算判据：每个人都至少有一场整段落在自己的 9–18 里。
        for person in people {
            #expect(split.sessions.contains { inside(start: $0.start, end: $0.end, zone: person.timeZoneID) },
                    "\(person.name) 一场都不在工作时段内")
        }
        // 场次按时间排序、互不重叠、编号 1…N。
        for (index, session) in split.sessions.enumerated() {
            #expect(session.index == index + 1)
            if index > 0 { #expect(session.start >= split.sessions[index - 1].end) }
        }
    }

    @Test func overlappingCitiesNeedNoSplit() {
        let split = OverlapPlanner.split(.init(
            participants: [participant("洛杉矶", "America/Los_Angeles", "US"),
                           participant("纽约", "America/New_York", "US")],
            from: utc("2026-09-21T16:00:00Z"), days: 3, durationMinutes: 60, sessions: 3,
            localTimeZoneID: "America/Los_Angeles"))
        #expect(!split.needed)
        #expect(split.sessions.isEmpty)
        #expect(split.uncovered.isEmpty)
    }
}
