// SPDX-License-Identifier: GPL-3.0-only
//
//  TimeUnderstandingTests.swift
//  「听懂时间」落成具体时刻：日期要存在、时间段带秒并按起点配对、选项按意思记、
//  国家的几个时区按钟走法合并、沿用的日期跟着来源的读法、「两小时后」从现在算。判据是 ISO 8601 的 UTC 串（另一套写法），
//  参考时刻固定为 2026-09-24（星期四）12:00 UTC，来源地点默认洛杉矶。
//  也检查写信人自述在哪里（「我在柏林」）与没写时由同组写明时区那处推出的偏移。
//

import Foundation
import Testing
@testable import Dayside

struct TimeUnderstandingTests {
    private let reference = ISO8601DateFormatter().date(from: "2026-09-24T12:00:00Z")!
    private let losAngeles = TimeZone(identifier: "America/Los_Angeles")!

    private func iso(_ date: Date?) -> String {
        guard let date else { return "-" }
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f.string(from: date)
    }

    private func context(reference: Date? = nil, now: Date? = nil, preferred: [String] = [],
                         origin: TimeUnderstanding.Origin = .typed) -> TimeUnderstanding.Context {
        TimeUnderstanding.Context(reference: reference ?? self.reference, now: now ?? reference ?? self.reference, fallback: losAngeles,
                                  home: losAngeles, preferredZones: preferred, origin: origin)
    }

    private func first(_ text: String, preferred: [String] = [], choice: TimeUnderstanding.Choice = .init(),
                       reference: Date? = nil) throws -> TimeUnderstanding.Resolved {
        let output = TimeUnderstanding.read(text, region: "US")
        try #require(!output.mentions.isEmpty, "没读出：\(text)")
        return TimeUnderstanding.resolveAll(output, context: context(reference: reference, preferred: preferred), choices: [0: choice])[0]
    }

    @Test func citiesZonesAndWeekdaysBecomeRealInstants() throws {
        #expect(iso(try first("3pm tokyo").start) == "2026-09-24T06:00:00Z")
        #expect(try first("3pm tokyo").zone.identifier == "Asia/Tokyo")
        #expect(iso(try first("Let's meet Thursday at 3pm ET").start) == "2026-09-24T19:00:00Z", "今天就是星期四：今天")
        #expect(iso(try first("next Monday 9am").start) == "2026-09-28T16:00:00Z", "没写时区：来源地点洛杉矶")
        #expect(iso(try first("3 октября в 18:00 Москва").start) == "2026-10-03T15:00:00Z")
        #expect(iso(try first("东京明早九点是纽约几点").start) == "2026-09-25T00:00:00Z")
        #expect(try first("东京明早九点是纽约几点").target?.identifier == "America/New_York")
        #expect(iso(try first("in 3 hours").start) == "2026-09-24T15:00:00Z")
        #expect(iso(try first("2026-09-24T14:00:00Z").start) == "2026-09-24T14:00:00Z")
    }

    @Test func rangesKeepTheirEndAndCrossMidnight() throws {
        let webinar = try first("Webinar: 2 October 2026, 18:00–19:30 CEST")
        #expect(iso(webinar.start) == "2026-10-02T16:00:00Z")
        #expect(iso(webinar.end) == "2026-10-02T17:30:00Z")
        let night = try first("22:00-01:00 UTC")
        #expect(iso(night.end) == "2026-09-25T01:00:00Z", "终点早于起点：次日")
    }

    /// 终点比较漏了秒，「10:20:10–10:20:20」被当成跨夜。
    @Test func rangeEndsCompareSecondsToo() throws {
        let tenSeconds = try first("10:20:10–10:20:20 UTC")
        #expect(iso(tenSeconds.start) == "2026-09-24T10:20:10Z")
        #expect(iso(tenSeconds.end) == "2026-09-24T10:20:20Z", "10 秒，不是跨夜")
    }

    /// 夏令时结束那天 1:00–2:00 走两遍：两个起点各自配终点（2:30 只有一个，都配它）。
    @Test func repeatedHourStartsEachGetTheirOwnEnd() throws {
        let fallBack = try first("Nov 1 2026 1:30am–2:30am Los Angeles")
        #expect(fallBack.intervals.map { "\(iso($0.start))/\(iso($0.end))" } == [
            "2026-11-01T08:30:00Z/2026-11-01T10:30:00Z",
            "2026-11-01T09:30:00Z/2026-11-01T10:30:00Z",
        ])
    }

    /// 新路少了旧版「拼回来仍是同一天」的检查，平年的 2 月 29 日被挪到 3 月 1 日。
    @Test func datesThatDoNotExistThereAreSaidSo() throws {
        let feb29 = try first("Feb 29 9am UTC")
        #expect(feb29.problem == .invalidDate, "2026-09 说的 2 月 29 日是 2027 年的，平年没有这一天")
        #expect(feb29.intervals.isEmpty)
        let leap = try first("Feb 29 9am UTC", reference: ISO8601DateFormatter().date(from: "2027-12-01T12:00:00Z")!)
        #expect(iso(leap.start) == "2028-02-29T09:00:00Z", "2028 年是闰年")
        let apia = try first("2011-12-30 12:00 Apia")
        #expect(apia.zone.identifier == "Pacific/Apia")
        #expect(apia.problem == .invalidDate, "萨摩亚 2011 年跳过了 12 月 30 日")
        #expect(TimeUnderstanding.civilDay(.absolute(year: 2011, month: 12, day: 31), reference: reference,
                                           in: TimeZone(identifier: "Pacific/Apia")!) == DateComponents(year: 2011, month: 12, day: 31))
    }

    /// 写得不成立的部分由 Rust 报出（Issue），这一处不换算；地名有线索却没认出，照来源地点换算并标出来。
    @Test func brokenPartsAreNotConvertedAndUnknownPlacesAreMarked() throws {
        let invalid = try first("2027-02-29 9am UTC")
        guard case .issues(let issues) = invalid.problem else { Issue.record("没报问题：\(String(describing: invalid.problem))"); return }
        #expect(issues.map(\.kind) == ["invalidDate"])
        #expect(invalid.intervals.isEmpty)
        // 有线索却没认出的地名不挡换算：照来源地点（洛杉矶）算，标出来。
        let unknown = try first("9am in Москвzz")
        #expect(unknown.problem == nil)
        #expect(unknown.notes.contains(.unresolvedPlace("Москвzz")))
        #expect(iso(unknown.start) == "2026-09-24T16:00:00Z")
        let target = try first("meet at 9am Tokyo, what time in Qwxyzland?")
        #expect(iso(target.start) == "2026-09-24T00:00:00Z", "目标没认出不影响来源那一处")
        #expect(target.notes.contains(.unresolvedTarget("Qwxyzland")))
    }

    /// 七月的 PST 此前只在选第一项时才把「按地区现在的钟」插进表，选第二项时表就变了。
    /// 现在两项先建好、按意思的标识选，选哪项表都不变；一月本来就是 PST，只有一项。
    @Test func pstInSeptemberOffersPacificTimeFirstAndTheLiteralOffsetSecond() throws {
        let pst = try first("9am PST")
        #expect(pst.zoneOptions.map(\.id) == ["zone:America/Los_Angeles", "offset:-480@America/Los_Angeles"])
        #expect(pst.zone.identifier == "America/Los_Angeles")
        #expect(iso(pst.start) == "2026-09-24T16:00:00Z")
        #expect(pst.notes.contains { if case .standardAbbreviationDuringDaylightTime = $0 { true } else { false } })
        let literal = try first("9am PST", choice: .init(zone: "offset:-480@America/Los_Angeles"))
        #expect(literal.zoneOptions.map(\.id) == pst.zoneOptions.map(\.id), "选第二项时表不变")
        #expect(iso(literal.start) == "2026-09-24T17:00:00Z", "按字面 UTC−8")
        #expect(literal.notes.isEmpty)
        let january = try first("9am PST", reference: ISO8601DateFormatter().date(from: "2026-01-15T12:00:00Z")!)
        #expect(january.zoneOptions.map(\.id) == ["zone:America/Los_Angeles"], "一月的 PST 就是洛杉矶那天的钟：按地区算，不另给按字面")
        #expect(iso(january.start) == "2026-01-15T17:00:00Z")
        #expect(january.notes.isEmpty)
        let unknownChoice = try first("9am PST", choice: .init(zone: "zone:Asia/Tokyo"))
        #expect(unknownChoice.zoneOption.id == "zone:America/Los_Angeles", "记住的选择不在表里时回到第一项")
    }

    @Test func ambiguousAbbreviationsPreferTheUsersOwnPlaces() throws {
        let india = try first("10:00 IST")
        #expect(india.zone.identifier == "Asia/Kolkata", "印度没有夏令时：字面偏移就是那边的钟，按地区算")
        #expect(india.zone.secondsFromGMT() == 19_800)
        // 用户地点里有以色列：以色列排第一；九月以色列在夏令时（IDT），写 IST 的人说的是以色列现在的钟（与七月的 PST 同一条）。
        let israel = try first("10:00 IST", preferred: ["Asia/Jerusalem"])
        #expect(israel.zone.identifier == "Asia/Jerusalem")
        #expect(iso(israel.start) == "2026-09-24T07:00:00Z")
        #expect(Set(israel.zoneOptions.map(\.id)) == Set(india.zoneOptions.map(\.id)), "排序变了，选项还是那几个")
    }

    /// 国家给全部时区，钟走法一样的只留一个（雅加达与坤甸都是西印尼时间）；用户自己的地点排前面。
    @Test func countriesOfferOneOptionPerClock() throws {
        let indonesia = try first("9am in Indonesia")
        #expect(indonesia.zoneOptions.map(\.id) == ["zone:Asia/Jakarta", "zone:Asia/Makassar", "zone:Asia/Jayapura"])
        let usa = try first("9am in USA")
        let anchors = usa.zoneOptions.compactMap(\.anchor)
        for expected in ["America/New_York", "America/Chicago", "America/Denver", "America/Phoenix", "America/Los_Angeles",
                         "America/Anchorage", "Pacific/Honolulu"] {
            #expect(anchors.contains(expected), "美国少了 \(expected)：\(anchors)")
        }
        #expect(!anchors.contains("America/Detroit"), "底特律与纽约同一个钟")
        let clocks = usa.zoneOptions.map { option in (0..<25).map { option.zone.secondsFromGMT(for: reference.addingTimeInterval(Double($0) * 15 * 86_400)) } }
        #expect(Set(clocks.map { $0.description }).count == clocks.count, "没有两项钟走法完全一样")
        let mine = try first("9am in USA", preferred: ["America/Denver"])
        #expect(mine.zone.identifier == "America/Denver")
    }

    /// 沿用的日期跟着来源那一处选的读法走：「10/3」改成 3 月 10 日，后面的东京也跟着改。
    @Test func inheritedDatesFollowTheReadingChosenAtTheirSource() throws {
        let output = TimeUnderstanding.read("10/3: 9:00 Berlin, 14:00 Tokyo", region: "US")
        #expect(output.mentions.map(\.dateFrom) == [nil, 0])
        let readings = TimeUnderstanding.readings(of: output.mentions[0])
        #expect(readings.count == 2)
        let asRead = TimeUnderstanding.resolveAll(output, context: context())
        #expect(asRead.map { iso($0.start) } == ["2026-10-03T07:00:00Z", "2026-10-03T05:00:00Z"])
        let swapped = TimeUnderstanding.resolveAll(output, context: context(), choices: [0: .init(reading: readings[1].id)])
        #expect(swapped.map { iso($0.start) } == ["2027-03-10T08:00:00Z", "2027-03-10T05:00:00Z"], "3 月 10 日已过去一个月以上：明年")
    }

    /// 沿用的是前面那处落定的那一天（界面写「同上」），不是把「明天」按这一处的时区再算一遍：傍晚在洛杉矶读，
    /// 柏林已是次日，再算一遍就晚一天（换算页实测：两处本是同一刻）。
    @Test func inheritedRelativeDatesKeepTheDayAlreadyRead() throws {
        let evening = ISO8601DateFormatter().date(from: "2026-09-24T02:00:00Z")!   // 洛杉矶 23 日 19:00，柏林已是 24 日 04:00
        let output = TimeUnderstanding.read("Kickoff tomorrow 9am PST, sync 18:00 Berlin", region: "US")
        #expect(output.mentions.map(\.dateFrom) == [nil, 0])
        let both = TimeUnderstanding.resolveAll(output, context: context(reference: evening))
        #expect(both.map { iso($0.start) } == ["2026-09-24T16:00:00Z", "2026-09-24T16:00:00Z"])
        // 星期五傍晚在洛杉矶读：柏林已是星期六，按柏林再算「星期五」就是下星期五。
        let fridayEvening = ISO8601DateFormatter().date(from: "2026-09-26T02:00:00Z")!
        let friday = TimeUnderstanding.resolveAll(TimeUnderstanding.read("Friday 9am PT / 6pm Berlin", region: "US"), context: context(reference: fridayEvening))
        #expect(friday.map { iso($0.start) } == ["2026-09-25T16:00:00Z", "2026-09-25T16:00:00Z"])
    }

    /// 同一行里几个时区写同一刻（等价组）：没写日期的几处落在离第一处最近的那一天，不是「那边的今天」
    /// （傍晚在洛杉矶读，伦敦、新加坡已是次日，各落各的今天就差出 24 小时、核对也就提醒不出来）；
    /// 核对把差 2 小时的新加坡那处标成 dstSuspect，同一刻的纽约与伦敦进 same。
    @Test func oneLineInSeveralZonesIsCheckedAsOneMoment() throws {
        let evening = ISO8601DateFormatter().date(from: "2026-09-24T02:00:00Z")!   // 洛杉矶 23 日 19:00，伦敦已是 24 日 03:00
        let output = TimeUnderstanding.read("9:00 New York / 14:00 London / 23:00 Singapore", region: "US")
        try #require(output.mentions.count == 3)
        #expect(Set(output.mentions.map(\.group)).count == 1, "同一行只隔着斜杠：一个等价组")
        let all = TimeUnderstanding.resolveAll(output, context: context(reference: evening))
        #expect(all.map { iso($0.start) } == ["2026-09-23T13:00:00Z", "2026-09-23T13:00:00Z", "2026-09-23T15:00:00Z"])
        let check = TimeUnderstanding.crosscheck(all)
        #expect(check.same == [[0, 1]])
        #expect(check.notes == [TimeUnderstanding.Crosscheck.Note(a: 0, b: 2, deltaMinutes: 120, kind: "dstSuspect")])
        #expect(check.suspects.map(\.b) == [2])
        // 中间隔着实词的两场不是一组：不核对，各落各的。
        let two = TimeUnderstanding.resolveAll(TimeUnderstanding.read("Keynote 9:00 New York, workshop 15:00 London", region: "US"),
                                               context: context(reference: evening))
        #expect(TimeUnderstanding.crosscheck(two).notes.isEmpty)
        // 没写时区的、只有日期的不参与。
        #expect(TimeUnderstanding.crosscheck(TimeUnderstanding.resolveAll(TimeUnderstanding.read("9:00 / 10:00", region: "US"),
                                                                          context: context(reference: evening))).notes.isEmpty)
    }

    /// 「两小时后」从现在算；只有钟点时落在所选的那一天（计时器闹钟框：选了别的日子、窗口开了很久都不影响）。
    @Test func relativeTimesCountFromNowAndClocksLandOnTheChosenDay() throws {
        let later = ISO8601DateFormatter().date(from: "2026-09-30T19:00:00Z")!
        let ctx = context(reference: later, now: reference)
        let inTwoHours = TimeUnderstanding.resolveAll(TimeUnderstanding.read("in 2 hours", region: "US"), context: ctx)[0]
        #expect(iso(inTwoHours.start) == "2026-09-24T14:00:00Z")
        let nine = TimeUnderstanding.resolveAll(TimeUnderstanding.read("9am", region: "US"), context: ctx)[0]
        #expect(iso(nine.start) == "2026-09-30T16:00:00Z")
    }

    /// 回拨时按真实经过的分钟算：00:30 后 90 分钟是第二次 01:00。
    @Test func relativeMinutesCrossFallBackIntoTheSecondOneAM() throws {
        let newYork = try #require(TimeZone(identifier: "America/New_York"))
        let now = try #require(ISO8601DateFormatter().date(from: "2026-11-01T04:30:00Z"))
        let expected = try #require(ISO8601DateFormatter().date(from: "2026-11-01T06:00:00Z"))
        let ctx = TimeUnderstanding.Context(reference: now, now: now, fallback: newYork, home: newYork)
        let all = TimeUnderstanding.resolveAll(TimeUnderstanding.read("in 90 minutes", region: "US"), context: ctx)
        try #require(all.count == 1)
        #expect(all[0].problem == nil)
        #expect(all[0].intervals.count == 1)
        let instant = try #require(all[0].start)
        #expect(instant == expected)
        #expect(instant.timeIntervalSince(now) == 5_400)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = newYork
        #expect(calendar.dateComponents([.hour, .minute], from: now) == DateComponents(hour: 0, minute: 30))
        #expect(calendar.dateComponents([.hour, .minute], from: instant) == DateComponents(hour: 1, minute: 0))
        #expect(newYork.secondsFromGMT(for: now) == -14_400)
        #expect(newYork.secondsFromGMT(for: instant) == -18_000, "回拨后的第二次 01:00")
    }

    /// 跳过不存在的一小时，01:45 后 30 分钟是 03:15。
    @Test func relativeMinutesCrossSpringForwardIntoThreeFifteen() throws {
        let newYork = try #require(TimeZone(identifier: "America/New_York"))
        let now = try #require(ISO8601DateFormatter().date(from: "2026-03-08T06:45:00Z"))
        let expected = try #require(ISO8601DateFormatter().date(from: "2026-03-08T07:15:00Z"))
        let ctx = TimeUnderstanding.Context(reference: now, now: now, fallback: newYork, home: newYork)
        let all = TimeUnderstanding.resolveAll(TimeUnderstanding.read("in 30 minutes", region: "US"), context: ctx)
        try #require(all.count == 1)
        #expect(all[0].problem == nil)
        #expect(all[0].intervals.count == 1)
        let instant = try #require(all[0].start)
        #expect(instant == expected)
        #expect(instant.timeIntervalSince(now) == 1_800)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = newYork
        #expect(calendar.dateComponents([.hour, .minute], from: now) == DateComponents(hour: 1, minute: 45))
        #expect(calendar.dateComponents([.hour, .minute], from: instant) == DateComponents(hour: 3, minute: 15))
        #expect(newYork.secondsFromGMT(for: now) == -18_000)
        #expect(newYork.secondsFromGMT(for: instant) == -14_400)
    }

    /// 下班前是按默认的 17:00，要标出来；「我这边」打字时是这台 Mac，粘贴时指写信人、标出来让人确认。
    @Test func defaultsAndMyTimeAreMarked() throws {
        let eod = try first("submit by EOD")
        #expect(eod.notes.contains(.impliedTime("eod")))
        #expect(iso(eod.start) == "2026-09-25T00:00:00Z", "洛杉矶 17:00")
        let typed = try first("9am my time")
        #expect(typed.zoneOption.id == "local")
        #expect(typed.notes.isEmpty)
        let output = TimeUnderstanding.read("9am my time", region: "US")
        let pasted = TimeUnderstanding.resolveAll(output, context: context(preferred: ["Asia/Tokyo"], origin: .pasted))[0]
        #expect(pasted.notes.contains(.localMeansTheWriter))
        #expect(pasted.zoneOptions.map(\.id) == ["local", "zone:Asia/Tokyo"], "用户自己的地点都给出来让他改")
    }

    /// 太长只读前面一截，要说出来；约定对不上时不崩，当作没读出。
    @Test func truncationIsReportedAndTransportErrorsDoNotTrap() throws {
        let long = String(repeating: "东", count: 1_400) + "明天 9:00 东京"
        let output = TimeUnderstanding.read(long, region: "US")
        #expect(output.truncatedAt == 1_333)
        #expect(output.mentions.isEmpty)
        #expect(TimeUnderstanding.read("9:00 Tokyo", region: "US").truncatedAt == nil)
        struct Empty: Encodable {}
        #expect(throws: (any Error).self) { let _: TimeUnderstanding.Output = try RustCore.attempt("understand.nonexistent", Empty()) }
    }

    /// 换算页的四条可点示例（十六语）都要读成该读的地方：依次是「没写」、东京、伦敦（英文是美中）、纽约，最后一条是相对时间。
    /// 示例从目录里按界面语言取，所以改了译文、例子读不出或读错地方就会挂。
    @Test(arguments: ["zh-Hans", "zh-Hant", "en", "ja", "ko", "de", "es", "fr", "ru", "pt-BR", "it", "nl", "pl", "tr", "vi", "id"])
    @MainActor func everyLanguagesHintExamplesAreRead(_ language: String) throws {
        let locale = Locale(identifier: language)
        let middle = language == "en" ? "America/Chicago" : "Europe/London"
        var zones: [String] = []
        var last: TimeUnderstanding.Resolved?
        for key in TimeInputView.exampleKeys {
            let example = L10n.string(key, locale: locale)
            let resolved = TimeUnderstanding.resolveAll(TimeUnderstanding.read(example, region: "US", language: language), context: context())
            #expect(resolved.count == 1, "\(language)：\(example) → \(resolved.count) 处")
            #expect(resolved.allSatisfy { $0.problem == nil }, "\(language)：\(example) → \(resolved.map { String(describing: $0.problem) })")
            zones.append(resolved.first.map { $0.zoneWritten ? $0.zone.identifier : "-" } ?? "none")
            last = resolved.first
        }
        #expect(zones == ["-", "Asia/Tokyo", middle, "America/New_York"], "\(language) → \(zones)")
        #expect(last?.mention.relativeMinutes == 180, "\(language)：最后一个例子是三小时后")
    }

    @Test func monthDayWithoutAYearIsTheComingOne() throws {
        let november = ISO8601DateFormatter().date(from: "2026-11-20T12:00:00Z")!
        let day = TimeUnderstanding.civilDay(.monthDay(month: 10, day: 3), reference: november, in: losAngeles)
        #expect(day?.year == 2027)
        let soon = TimeUnderstanding.civilDay(.monthDay(month: 9, day: 20), reference: reference, in: losAngeles)
        #expect(soon?.year == 2026, "四天前的月日仍是今年")
    }

    /// 原文写了写信人在哪儿（「我在柏林」）：「我这边」先按那里算，本机仍在表里让人改回去；没写时照今天的做法。
    @Test func explicitWriterPlaceSetsMyTimeThere() throws {
        let output = TimeUnderstanding.read("I'm in Berlin. Can we talk at 3pm my time?", region: "US")
        let pasted = TimeUnderstanding.resolveAll(output, context: context(origin: .pasted))
        let mine = try #require(pasted.first { $0.mention.source == .local })
        #expect(mine.zone.identifier == "Europe/Berlin")
        #expect(mine.zoneOptions.map(\.id).first == "writer:Europe/Berlin")
        #expect(mine.zoneOptions.contains { $0.id == "local" }, "读的人自己的时区仍在表里")
        #expect(mine.notes.contains { if case .localIsTheWriter = $0 { true } else { false } })
        #expect(!mine.notes.contains(.localMeansTheWriter))
        #expect(iso(mine.start) == "2026-09-24T13:00:00Z", "柏林 15:00（九月仍是夏令时 UTC+2）")
        // 没写在哪里时使用本机，提醒行说明「先按你这里」。
        let alone = TimeUnderstanding.resolveAll(TimeUnderstanding.read("3pm my time", region: "US"), context: context(origin: .pasted))[0]
        #expect(alone.zoneOption.id == "local")
        #expect(alone.notes.contains(.localMeansTheWriter))
    }

    /// 打的字也一样：自己写了「我在柏林，3pm 我这边」是告诉 App 人在哪（句子不另分打字 / 粘贴）。
    @Test func typedWriterPlaceIsUsedToo() throws {
        let typed = try first("I'm in Berlin, 3pm my time")
        #expect(typed.zone.identifier == "Europe/Berlin")
        #expect(iso(typed.start) == "2026-09-24T13:00:00Z")
        #expect(typed.notes.contains { if case .localIsTheWriter = $0 { true } else { false } })
    }

    /// 没写在哪、同组里另有一处写明时区：两处本是同一刻，这边墙钟与那处那刻的差（归到一刻钟）就是写信人的偏移；
    /// 落成后两处同一刻，核对也就不再报差。
    @Test func myTimeIsInferredFromTheWrittenZoneOnTheSameLine() throws {
        let output = TimeUnderstanding.read("3pm my time / 9am New York", region: "US")
        try #require(output.mentions.count == 2)
        let all = TimeUnderstanding.resolveAll(output, context: context(origin: .pasted))
        let mine = try #require(all.first { $0.mention.source == .local })
        #expect(mine.zone.secondsFromGMT() == 7_200, "9:00 纽约（13:00 UTC）对 15:00：UTC+2")
        #expect(mine.zoneOptions.map(\.id).first == "writer:offset:120")
        #expect(mine.zoneOptions.contains { $0.id == "local" }, "本机仍在表里")
        let note = mine.notes.compactMap { note -> (Int, String)? in
            if case let .localInferredFrom(minutes, placeAndClock, _) = note { return (minutes, placeAndClock) }
            return nil
        }.first
        #expect(note?.0 == 120)
        #expect(note?.1.hasSuffix("9:00") == true, "另一处的钟点照写：\(note?.1 ?? "-")")
        #expect(all.allSatisfy { iso($0.start) == "2026-09-24T13:00:00Z" }, "两处同一刻")
        #expect(TimeUnderstanding.crosscheck(all).notes.isEmpty, "同一刻：核对不报差")
    }

    /// 写了就在哪儿就按写的算，不由同组另推（东京赢）。
    @Test func explicitWriterWinsOverInference() throws {
        let output = TimeUnderstanding.read("I'm in Tokyo. 3pm my time / 9am New York", region: "US")
        let all = TimeUnderstanding.resolveAll(output, context: context(origin: .pasted))
        let mine = try #require(all.first { $0.mention.source == .local })
        #expect(mine.zone.identifier == "Asia/Tokyo")
        #expect(iso(mine.start) == "2026-09-24T06:00:00Z", "东京 15:00")
        #expect(mine.notes.contains { if case .localIsTheWriter = $0 { true } else { false } })
        #expect(!mine.notes.contains { if case .localInferredFrom = $0 { true } else { false } })
    }

    /// 推出来的偏移出 ±14 小时不推：另一处带了「明天」，差出 22 小时，照旧本机算。
    @Test func inferenceBeyond14HoursIsNotMade() throws {
        let output = TimeUnderstanding.read("3pm my time / tomorrow 9am New York", region: "US")
        let all = TimeUnderstanding.resolveAll(output, context: context(origin: .pasted))
        let mine = try #require(all.first { $0.mention.source == .local })
        #expect(mine.zoneOption.id == "local")
        #expect(mine.notes.contains(.localMeansTheWriter))
        #expect(iso(mine.start) == "2026-09-24T22:00:00Z", "本机洛杉矶 15:00")
    }
}

struct UnderstandingCityPopulationTests {
    private let identifiers = ["Asia/Tokyo", "Europe/London", "America/New_York", "Asia/Shanghai",
                               "Asia/Kolkata", "Europe/Berlin", "Pacific/Auckland", "America/Chicago"]

    private func city(_ index: Int, population: UInt64?) -> TimeUnderstanding.Zone {
        .city(index: index, name: "Candidate \(index)", iana: identifiers[index], population: population)
    }

    private func options(_ cities: [TimeUnderstanding.Zone], preferred: [String] = [], reason: String = "city") -> [TimeUnderstanding.ZoneOption] {
        let context = TimeUnderstanding.Context(reference: Date(timeIntervalSince1970: 0), fallback: .gmt,
                                                preferredZones: preferred)
        return TimeUnderstanding.zoneOptions(.options(reason: reason, cities), date: nil, context: context)
    }

    @Test func tinyTownIsHiddenAndExactTenPercentIsKept() {
        let result = options([city(0, population: 1_000_000), city(1, population: 100_000), city(2, population: 99_999)])
        #expect(result.compactMap { $0.city?.index } == [0, 1])
    }

    @Test func usersPlaceKeepsTinyTownAndComesFirst() {
        let result = options([city(0, population: 1_000_000), city(1, population: 1)], preferred: [identifiers[1]])
        #expect(result.compactMap { $0.city?.index } == [1, 0])
    }

    @Test func unknownPopulationIsKept() {
        let result = options([city(0, population: 1_000_000), city(1, population: nil), city(2, population: 1)])
        #expect(result.compactMap { $0.city?.index } == [0, 1])
        #expect(result.last?.city?.population == nil)
    }

    @Test func thresholdUsesTheWholeListBeforeTheCap() {
        let cities = (0..<6).map { city($0, population: 100) }
            + [city(6, population: 10_000), city(7, population: nil)]
        #expect(options(cities).compactMap { $0.city?.index } == [6, 7])
    }

    @Test func capKeepsSixInEngineOrderAfterUsersPlaces() {
        let cities = (0..<8).map { city($0, population: UInt64(1_000 - $0)) }
        #expect(options(cities, preferred: [identifiers[7]]).compactMap { $0.city?.index } == [7, 0, 1, 2, 3, 4])
        #expect(options((0..<8).map { city($0, population: nil) }).compactMap { $0.city?.index } == [0, 1, 2, 3, 4, 5])
    }

    @Test func fractionalThresholdAndLargestIntegerStayExact() {
        #expect(options([city(0, population: 1_001), city(1, population: 101), city(2, population: 100)])
            .compactMap { $0.city?.index } == [0, 1])
        #expect(options([city(0, population: UInt64.max), city(1, population: 1_844_674_407_370_955_162),
                         city(2, population: 1_844_674_407_370_955_161)]).compactMap { $0.city?.index } == [0, 1])
    }

    @Test func otherAmbiguitiesKeepTheirOptions() {
        let cities = (0..<8).map { city($0, population: $0 == 0 ? 1_000_000 : 1) }
        #expect(options(cities, reason: "abbreviation").count == 8)
    }

    @Test func populationIsDecodedAndMissingPopulationStaysUnknown() throws {
        let data = Data(#"{"kind":"options","reason":"city","options":[{"kind":"city","cityIndex":0,"name":"Big","iana":"Asia/Tokyo","population":1000000},{"kind":"city","cityIndex":1,"name":"Unknown","iana":"Europe/London"},{"kind":"city","cityIndex":2,"name":"Tiny","iana":"America/New_York","population":1}]}"#.utf8)
        let zone = try JSONDecoder().decode(TimeUnderstanding.Zone.self, from: data)
        let context = TimeUnderstanding.Context(reference: Date(timeIntervalSince1970: 0), fallback: .gmt)
        let result = TimeUnderstanding.zoneOptions(zone, date: nil, context: context)
        #expect(result.compactMap { $0.city?.index } == [0, 1])
        #expect(result.first?.city?.population == 1_000_000)
        #expect(result.last?.city?.population == nil)
    }
}

@MainActor
struct UnderstandingZoneLabelTests {
    private let date = ISO8601DateFormatter().date(from: "2026-01-15T12:00:00Z")!

    private func place(_ name: String, country: String, region: String? = nil) throws -> ZoneOption {
        try #require(ZoneCatalog.shared.search(name, locale: nil, limit: 64).first {
            $0.cityName == name && $0.countryCode == country && (region == nil || $0.adminRegion == region)
        })
    }

    private func choice(_ place: ZoneOption) throws -> TimeUnderstanding.ZoneOption {
        let index = try #require(place.cityIndex)
        let zone = try #require(TimeZone(identifier: place.identifier))
        return .init(id: "city:\(index)", zone: zone, kind: .region, anchor: place.identifier,
                     city: .init(index: index, name: place.cityName))
    }

    private func style(_ locale: Locale) -> UnderstandingText.Style {
        UnderstandingText.Style(locale: locale, hourStyle: .force24, now: date, name: { $0.identifier },
            cityName: { CityNameLanguage.name(from: CityIndex.shared.localizedNames(cityIndex: $0), locale: locale) })
    }

    private func label(_ option: TimeUnderstanding.ZoneOption, among options: [TimeUnderstanding.ZoneOption],
                       style: UnderstandingText.Style) -> String {
        UnderstandingText.zoneLabel(option, among: options, at: date, style: style, pasted: false)
    }

    private func formatted(_ name: String, for option: TimeUnderstanding.ZoneOption, locale: Locale) -> String {
        String(format: L10n.string("%1$@（%2$@）", locale: locale), locale: locale,
               arguments: [name, UnderstandingText.offset(option.zone.secondsFromGMT(for: date))])
    }

    @Test(arguments: ["en", "zh-Hans", "ja"])
    func sameNamedLondonChoicesContainTheirSearchSubtitles(_ language: String) throws {
        let locale = Locale(identifier: language)
        let london = try #require(["en": "London", "zh-Hans": "伦敦", "ja": "ロンドン"][language])
        var style = style(locale)
        style.cityName = { _ in london }
        let england = try place("London", country: "GB", region: "England")
        let ontario = try place("London", country: "CA", region: "Ontario")
        let options = try [choice(england), choice(ontario)]
        let names = options.map { UnderstandingText.zoneName($0, at: date, style: style, pasted: false) }
        try #require(names[0] == names[1])
        let subtitles = [england, ontario].enumerated().map { index, place in
            place.subtitle(locale: locale, displayName: names[index])
        }
        try #require(subtitles.allSatisfy { !$0.isEmpty })
        let labels = options.map { label($0, among: options, style: style) }
        #expect(labels[0] != labels[1])
        #expect(labels[0].contains(subtitles[0]))
        #expect(labels[1].contains(subtitles[1]))
        #expect(labels == options.enumerated().map { index, option in
            formatted(names[index] + " · " + subtitles[index], for: option, locale: locale)
        })
    }

    @Test(arguments: ["en", "zh-Hans", "ja"])
    func disputedCityWithAnEmptySubtitleKeepsItsPlainLabel(_ language: String) throws {
        let locale = Locale(identifier: language)
        let taipei = try place("Taipei", country: "TW")
        let kaohsiung = try place("Kaohsiung", country: "TW")
        let options = try [choice(taipei), choice(kaohsiung)]
        // 让两个真实记录显示同名，确认空副标题的分支确实被走到。
        var style = style(locale)
        style.cityName = { _ in "Taipei" }
        #expect(taipei.subtitle(locale: locale, displayName: "Taipei").isEmpty)
        let taipeiLabel = label(options[0], among: options, style: style)
        #expect(!taipeiLabel.contains(" · "))
        #expect(taipeiLabel == formatted("Taipei", for: options[0], locale: locale))
    }

    @Test(arguments: ["en", "zh-Hans", "ja"])
    func distinctCityNamesAndSingleChoicesKeepTheirExistingLabels(_ language: String) throws {
        let locale = Locale(identifier: language)
        let style = style(locale)
        let options = try [choice(place("London", country: "GB", region: "England")),
                           choice(place("Tokyo", country: "JP"))]
        for option in options {
            let name = UnderstandingText.zoneName(option, at: date, style: style, pasted: false)
            let expected = formatted(name, for: option, locale: locale)
            #expect(label(option, among: options, style: style) == expected)
            #expect(label(option, among: [option], style: style) == expected)
        }
        let taipei = try #require(TimeZone(identifier: "Asia/Taipei"))
        let region = TimeUnderstanding.ZoneOption(id: "zone:Asia/Taipei", zone: taipei, kind: .region, anchor: taipei.identifier)
        let sameTextStyle = UnderstandingText.Style(locale: locale, hourStyle: .force24, now: date, name: { $0.identifier },
                                                   cityName: { _ in "UTC+8" })
        #expect(label(options[0], among: [options[0], region], style: sameTextStyle)
            == formatted("UTC+8", for: options[0], locale: locale))
    }
}

struct UnderstandingSeriesDecodingTests {
    @Test(arguments: [0, 7, 13])
    func seriesIndicesDecodeAsMentionIndices(_ index: Int) throws {
        let json = """
        {"span":[4,29],"parts":[{"kind":"date","span":[4,10]},{"kind":"time","span":[20,29]}],
         "date":{"kind":"weekday","weekday":2},"time":{"hour":16,"minute":25,"second":0,"dayOffset":0},
         "series":\(index)}
        """
        let mention = try JSONDecoder().decode(TimeUnderstanding.Mention.self, from: Data(json.utf8))
        #expect(mention.series == index)
        #expect(mention.span == [4, 29])
        #expect(mention.parts.map(\.span) == [[4, 10], [20, 29]])
        #expect(mention.date == .weekday(2, week: nil))
        #expect(mention.time?.hour == 16)
        #expect(mention.time?.minute == 25)
    }

    @Test func singleMentionWithoutASeriesKeyStillDecodes() throws {
        let json = #"{"span":[0,5],"parts":[{"kind":"time","span":[0,5]}],"time":{"hour":8,"minute":45,"second":0,"dayOffset":0}}"#
        let mention = try JSONDecoder().decode(TimeUnderstanding.Mention.self, from: Data(json.utf8))
        #expect(mention.series == nil)
        #expect(mention.time?.hour == 8)
        #expect(mention.time?.minute == 45)
    }

    @Test func eachSeriesRetainsItsFirstMentionIndexAndSharedSpan() throws {
        let json = #"""
        {"mentions":[
            {"span":[0,5],"parts":[{"kind":"time","span":[0,5]}]},
            {"span":[7,35],"parts":[{"kind":"date","span":[7,14]}],"date":{"kind":"weekday","weekday":1},"series":1},
            {"span":[7,35],"parts":[{"kind":"date","span":[19,28]}],"date":{"kind":"weekday","weekday":3},"series":1},
            {"span":[37,66],"parts":[{"kind":"date","span":[37,43]}],"date":{"kind":"weekday","weekday":5},"series":3},
            {"span":[37,66],"parts":[{"kind":"date","span":[48,54]}],"date":{"kind":"weekday","weekday":6},"series":3}
        ]}
        """#
        let output = try JSONDecoder().decode(TimeUnderstanding.Output.self, from: Data(json.utf8))
        #expect(output.mentions.map(\.series) == [nil, 1, 1, 3, 3])
        #expect(output.mentions.map(\.span) == [[0, 5], [7, 35], [7, 35], [37, 66], [37, 66]])
        #expect(output.mentions.map(\.date) == [nil, .weekday(1, week: nil), .weekday(3, week: nil),
                                               .weekday(5, week: nil), .weekday(6, week: nil)])
    }

}
