// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import Dayside

struct TimeInputTests {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func resolve(_ value: String, reference: String = "2026-09-09T12:00:00Z", zone: String = "UTC") -> TimeInput.Resolution {
        TimeInput.resolve(value, relativeTo: date(reference), in: TimeZone(identifier: zone)!)
    }

    @Test(arguments: [("what time is it in Tokyo", "Asia/Tokyo"), ("东京几点", "Asia/Tokyo"),
                      ("東京は何時ですか", "Asia/Tokyo"), ("서울 몇 시예요", "Asia/Seoul"),
                      ("İstanbul'da saat kaç", "Europe/Istanbul"), ("¿Qué hora es en Madrid?", "Europe/Madrid")])
    func panelCurrentTimeQuestionsKeepTheInstantAndUseTheTarget(query: String, target: String) throws {
        let now = date("2026-09-09T12:00:00Z")
        let resolution = TimeInput.resolve(query, relativeTo: now, now: now, in: .gmt)
        #expect(resolution.error == nil)
        #expect(resolution.dates == [now])
        #expect(resolution.timeZone == .gmt)
        #expect(resolution.resolved?.mention.relativeMinutes == 0)
        let jump = try #require(AddZoneField.jumpCandidate(from: resolution))
        #expect(jump.date == now)
        #expect(jump.zone.identifier == target)
    }

    @Test func panelJumpKeepsSourceClocksAndRejectsAQuestionWithoutItsAntecedent() throws {
        let clock = resolve("9am new york")
        #expect(try #require(AddZoneField.jumpCandidate(from: clock)).zone.identifier == "America/New_York")
        let question = resolve("What time is that in Tokyo?")
        #expect(question.error != nil)
        #expect(AddZoneField.jumpCandidate(from: question) == nil)
    }

    /// 时间段：终点跟起点同一套民用规则解析，跨午夜算次日；一行可粘贴文本各地一段、
    /// 日期只在与来源地不同时写；Discord / Slack 令牌带同一个 Unix 秒数。
    @Test func rangesResolveAnEndAndPasteLineReadsAcrossZones() throws {
        // Thursday 2026-09-10 12:00 UTC
        let thursday = Date(timeIntervalSince1970: 1_789_041_600)
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let range = TimeInput.resolve("13:00–15:00 Asia/Tokyo", relativeTo: thursday, in: .gmt)
        #expect(range.error == nil)
        #expect(range.dates == [Date(timeIntervalSince1970: 1_789_012_800)])      // 2026-09-10 04:00Z = 13:00 JST
        #expect(range.endDates == [Date(timeIntervalSince1970: 1_789_020_000)])   // 06:00Z = 15:00 JST
        let overnight = TimeInput.resolve("22:00-01:00 Asia/Tokyo", relativeTo: thursday, in: .gmt)
        #expect(try #require(overnight.endDates.first).timeIntervalSince(try #require(overnight.dates.first)) == 3 * 3600)
        #expect(TimeInput.resolve("13:00 Asia/Tokyo", relativeTo: thursday, in: .gmt).endDates.isEmpty)
        // 一行：东京是来源，洛杉矶前一天要带日期，伦敦同一天不带
        let line = TimeInput.pasteLine(start: range.dates[0], end: range.endDates.first,
                                       zones: [("东京", tokyo), ("洛杉矶", TimeZone(identifier: "America/Los_Angeles")!), ("伦敦", TimeZone(identifier: "Europe/London")!)],
                                       source: tokyo, hourStyle: .force24, locale: Locale(identifier: "zh-Hans"), now: thursday)
        #expect(line == "东京 13:00–15:00 / 洛杉矶 9月9日 21:00–23:00 / 伦敦 5:00–7:00", "\(line)")
        let stamp = try #require(TimeInput.timestamps(for: range.dates[0], in: tokyo))
        #expect(stamp.discord == "<t:1789012800:F>")
        #expect(stamp.discordRelative == "<t:1789012800:R>")
        #expect(stamp.slack == "<!date^1789012800^{date_short_pretty} at {time}|2026-09-10T13:00:00+09:00>")
    }

    /// 区域名随夏令时走；夏令时期间写的标准时间缩写（九月的 PST）默认按那个地区现在的钟（各入口都取这一项），
    /// 字面的 UTC−8 是第二个选项。
    @Test func regionalNamesUseSeasonalRulesAndStandardAbbreviationsInSummerMeanTheRegionsClock() throws {
        #expect(resolve("9am Central").dates == [date("2026-09-09T14:00:00Z")])
        #expect(resolve("2026-01-09 9am Central").dates == [date("2026-01-09T15:00:00Z")])
        let pst = resolve("9am PST")
        #expect(pst.dates == [date("2026-09-09T16:00:00Z")])
        #expect(try #require(pst.resolved).zoneOptions.map(\.id) == ["zone:America/Los_Angeles", "offset:-480@America/Los_Angeles"])
        #expect(resolve("2026-01-09 9am PST").dates == [date("2026-01-09T17:00:00Z")], "一月本来就是 PST")
        #expect(resolve("9am Pacific").dates == [date("2026-09-09T16:00:00Z")])
    }

    @Test func explicitZoneOverridesSelectedPlace() {
        // 九月写 CET（中欧标准时间）：与九月的 PST 同一条，默认按中欧现在的钟（CEST，UTC+2），字面的 UTC+1 是第二项。
        #expect(resolve("14:00 CET", zone: "Asia/Tokyo").dates == [date("2026-09-09T12:00:00Z")])
        #expect(resolve("2026-01-09 14:00 CET", zone: "Asia/Tokyo").dates == [date("2026-01-09T13:00:00Z")])
        #expect(resolve("14:00 America/New_York", zone: "Asia/Tokyo").dates == [date("2026-09-09T18:00:00Z")])
        let effective = TimeInput.sourceTimeZone(for: "9am Central", in: TimeZone(identifier: "Asia/Tokyo")!)
        #expect(effective.identifier == "America/Chicago")
        let reference = date("2026-09-09T18:00:00Z")
        #expect(Calendar.gregorianUTC(effective).component(.day, from: reference) == 9)
        #expect(resolve("9am Central", reference: "2026-09-09T18:00:00Z", zone: "Asia/Tokyo").dates == [date("2026-09-09T14:00:00Z")])
    }

    @Test func noSuffixUsesSelectedPlacesCivilDate() {
        #expect(resolve("00:15", reference: "2026-09-09T18:00:00Z", zone: "Asia/Tokyo").dates == [date("2026-09-09T15:15:00Z")])
        #expect(resolve("9am tomorrow", reference: "2026-09-09T18:00:00Z", zone: "Asia/Tokyo").dates == [date("2026-09-11T00:00:00Z")])
    }

    /// 拨快跳过的钟点不存在；萨摩亚 2011 年整天跳过的 12 月 30 日是「日期不存在」（新路补上「拼回来仍是同一天」的检查）。
    @Test(arguments: [("2026-03-08 02:30 America/New_York", "nonexistentTime"), ("2026-10-04 02:15 Australia/Lord_Howe", "nonexistentTime"),
                      ("2011-12-30 12:00 Pacific/Apia", "invalidDate")])
    func skippedCivilTimesAreRejected(_ input: String, _ error: String) {
        let result = resolve(input)
        #expect(result.error == error)
        #expect(result.dates.isEmpty)
    }

    @Test func autumnRepeatedHourRequiresAnExplicitChoice() {
        let result = resolve("2026-11-01 01:30 America/New_York")
        #expect(result.error == nil)
        #expect(result.dates == [date("2026-11-01T05:30:00Z"), date("2026-11-01T06:30:00Z")])
    }

    @Test func halfHourAutumnTransitionReturnsBothInstants() {
        let result = resolve("2026-04-05 01:45 Australia/Lord_Howe")
        #expect(result.dates == [date("2026-04-04T14:45:00Z"), date("2026-04-04T15:15:00Z")])
    }

    @Test func nonAmbiguousMidnightRetainsExactDate() {
        #expect(resolve("2026-11-01 00:00 America/New_York").dates == [date("2026-11-01T04:00:00Z")])
        #expect(resolve("2026-03-08 03:00 America/New_York").dates == [date("2026-03-08T07:00:00Z")])
    }

    /// 写得不成立的（12:60、平年的 2 月 29 日、系统没有的时区标识符）读不成；有歧义的缩写给第一候选并带上全部选项
    /// （此前报错，换心起与换算页同一套候选）；整段里找时间，旁边的词不打断（「14:00 UTC extra」）。
    @Test func invalidRequestsNeverYieldAnInstantAndAmbiguousOnesCarryTheirOptions() throws {
        for (input, error) in [("12:60", "invalid"), ("2026-02-29 12:00", "invalid"), ("14:00 America/Nowhere", "unknownPlace"),
                               ("", "unrecognized"), ("东京", "unrecognized")] {
            let result = resolve(input)
            #expect(result.error == error, "\(input)")
            #expect(result.dates.isEmpty)
        }
        for input in ["9am CST", "9am IST"] {
            let result = resolve(input)
            #expect(result.error == nil && result.dates.count == 1, "\(input)")
            #expect(try #require(result.resolved).zoneOptions.count > 1, "\(input)")
        }
        #expect(resolve("14:00 UTC extra").dates == [date("2026-09-09T14:00:00Z")])
        #expect(resolve("24:00").dates == [date("2026-09-10T00:00:00Z")], "24:00 是次日 0 点")
    }

    @Test func leapDaySecondsAndFractionalOffsetsRoundTrip() throws {
        let result = resolve("2028-02-29 23:59:07 UTC+05:45")
        let value = try #require(result.dates.first)
        #expect(value == date("2028-02-29T18:14:07Z"))
        #expect(TimeInput.timestamps(for: value, in: result.timeZone)?.iso8601 == "2028-02-29T23:59:07+05:45")
    }

    @Test func timestampExportsDescribeTheSameInstantAcrossDateLine() throws {
        let instant = date("2026-09-09T12:34:56Z")
        let west = try #require(TimeInput.timestamps(for: instant, in: TimeZone(identifier: "Pacific/Honolulu")!))
        let east = try #require(TimeInput.timestamps(for: instant, in: TimeZone(identifier: "Pacific/Kiritimati")!))
        #expect(west.iso8601 == "2026-09-09T02:34:56-10:00")
        #expect(east.iso8601 == "2026-09-10T02:34:56+14:00")
        #expect(west.unix == east.unix)
        #expect(Double(west.unix) == instant.timeIntervalSince1970)
    }

    @Test func timestampsFloorBeforeTheEpochAndRejectNonFiniteDate() {
        let stamp = TimeInput.timestamps(for: Date(timeIntervalSince1970: -0.1), in: TimeZone(secondsFromGMT: 0)!)
        #expect(stamp?.unix == "-1")
        #expect(stamp?.iso8601 == "1969-12-31T23:59:59+00:00")
        #expect(TimeInput.timestamps(for: Date(timeIntervalSince1970: .infinity), in: .current) == nil)
    }

    @Test @MainActor func applyingAConversionUpdatesEveryClockWithoutSavingPreferences() throws {
        let (defaults, cleanup) = TestDefaults.make(prefix: "TimeInputTests")
        defer { cleanup() }
        var settings = AppSettings()
        settings.keepAliveInBackground = false
        Store.saveSettings(settings, to: defaults)
        let model = AppModel(defaults: defaults, migrate: false)
        let before = defaults.dictionaryRepresentation()
        let target = try #require(resolve("2026-11-01 01:30 America/New_York").dates.last)
        model.jump(to: target)
        #expect(abs(model.referenceDate.timeIntervalSince(target)) < 0.001)
        #expect(model.isScrubbing)
        #expect(NSDictionary(dictionary: defaults.dictionaryRepresentation()).isEqual(to: before))
        model.resetToNow()
        #expect(!model.isScrubbing)
    }

    /// 结果先列来源，再列本机与保存地点，按时区标识符去重；首启没有保存地点时仍有来源与本机两行。
    @Test @MainActor func conversionResultsListSourceThenLocalThenSavedPlacesWithoutDuplicates() {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!, la = TimeZone(identifier: "America/Los_Angeles")!, london = TimeZone(identifier: "Europe/London")!
        #expect(TimeInputView.resultZones(source: tokyo, local: la, saved: []).map(\.identifier) == ["Asia/Tokyo", "America/Los_Angeles"])
        #expect(TimeInputView.resultZones(source: tokyo, local: la, saved: [la, london, tokyo]).map(\.identifier) == ["Asia/Tokyo", "America/Los_Angeles", "Europe/London"])
        #expect(TimeInputView.resultZones(source: la, local: la, saved: [london]).map(\.identifier) == ["America/Los_Angeles", "Europe/London"])
        #expect(TimeInputView.resultZones(source: nil, local: la, saved: [london, la]).map(\.identifier) == ["America/Los_Angeles", "Europe/London"])
    }

    /// 不存在的时刻带上缺口：纽约 2026-03-08 02:30 落在 07:00Z 那次拨快里，前后偏移 −5h / −4h。
    @Test func nonexistentTimeCarriesTheDaylightSavingGap() throws {
        let resolution = resolve("2026-03-08 02:30 America/New_York")
        #expect(resolution.error == "nonexistentTime")
        let gap = try #require(resolution.gap)
        #expect(gap.at == date("2026-03-08T07:00:00Z"))
        #expect(gap.before == -18_000 && gap.after == -14_400)
        #expect(resolve("2026-03-08 03:30 America/New_York").gap == nil)
    }
    /// 换算结果与面板行说同一句话：与本机差多少写「快 8小时 / 慢 8小时 / 快 4小时45分钟」，同一时间不写；
    /// 标记（原文、本机）在前。跨日写「次日（周一）」「前一日（周六）」，星期是那边那一天的。
    /// 判据各自独立：时差拿 Foundation 两个偏移相减，星期拿 Calendar 在那边的时区里算。
    @Test @MainActor func theConverterSaysTheOffsetThePanelWayAndNamesTheWeekdayOfAnotherDay() throws {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!, london = TimeZone(identifier: "Europe/London")!
        let en = Locale(identifier: "en"), zh = Locale(identifier: "zh-Hans")
        let noon = date("2026-06-21T03:00:00Z")      // 东京 12:00、伦敦 4:00（夏令时 +1）
        let hours = (tokyo.secondsFromGMT(for: noon) - london.secondsFromGMT(for: noon)) / 3600
        #expect(hours == 8)
        let place = { (zone: TimeZone, tags: [String]) in MomentTable.Place(zone: zone, name: zone.identifier, tags: tags, coordinate: nil) }
        let panel = try #require(PanelRowDetail.relative(timeZone: tokyo, at: noon, locale: en, home: london))
        #expect(MomentTable.note(for: place(tokyo, []), at: noon, locale: en, home: london) == panel.full)
        #expect(panel.full == "8 hours ahead")
        #expect(MomentTable.note(for: place(tokyo, ["as written"]), at: noon, locale: en, home: london) == "as written · 8 hours ahead")
        #expect(MomentTable.note(for: place(TimeZone(identifier: "America/Los_Angeles")!, []), at: noon, locale: en, home: london) == "8 hours behind")
        #expect(MomentTable.note(for: place(TimeZone(identifier: "Europe/Dublin")!, []), at: noon, locale: en, home: london).isEmpty)
        #expect(MomentTable.note(for: place(TimeZone(identifier: "Asia/Kathmandu")!, []), at: noon, locale: en, home: london)
                == "4 hours 45 minutes ahead")
        #expect(MomentTable.note(for: place(tokyo, []), at: noon, locale: zh, home: london) == "快 8小时")

        // 东京周一 0:00 = 伦敦周日 16:00：东京那一行写「次日（周一）」，反过来伦敦写「前一日（周日）」。
        let midnight = date("2026-06-21T15:00:00Z")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tokyo
        #expect(calendar.component(.weekday, from: midnight) == 2)
        #expect(MomentTable.dayNote(midnight, in: tokyo, from: london, locale: en) == "next day (Mon)")
        #expect(MomentTable.dayNote(midnight, in: london, from: tokyo, locale: en) == "previous day (Sun)")
        #expect(MomentTable.dayNote(midnight, in: tokyo, from: london, locale: zh) == "次日（周一）")
        #expect(MomentTable.dayNote(noon, in: tokyo, from: london, locale: zh) == nil)
        // 钟点或时间段：终点跨日连日期一起写。
        #expect(MomentTable.clock(start: noon, end: noon.addingTimeInterval(3600), in: tokyo, hourStyle: .force24, locale: zh, now: noon) == "12:00–13:00")
        // 钟点的前导零跟系统区域（`TimeFormatting`），只核日期写在终点前面。
        #expect(MomentTable.clock(start: date("2026-06-21T14:00:00Z"), end: midnight.addingTimeInterval(3600), in: tokyo, hourStyle: .force24,
                                  locale: zh, now: noon).hasPrefix("23:00–6月22日 "))
    }

    /// 几天共用一个钟点（CONVENTIONS 第 12 条）：引擎每天给一处、带同一个 `series` 号、相邻；换算页并成一行。
    /// 判据：手写的引擎输出（与 Rust 约定的形状：键 `series`、无号时不出现），分组只看号相等与相邻；
    /// 三天连着的写成一段，两天不连着的列出来；读成的是每一天自己的日期。
    @Test @MainActor func daysOfOneScheduleBecomeOneRow() throws {
        func mention(_ weekday: Int, series: Int?, group: Int) -> String {
            let tag = series.map { ",\"series\":\($0)" } ?? ""
            return #"{"span":[0,40],"parts":[{"kind":"date","span":[0,9]},{"kind":"time","span":[26,27]},{"kind":"end","span":[28,34]},{"kind":"zone","span":[35,40]}],"date":{"kind":"weekday","weekday":\#(weekday)},"time":{"hour":9,"minute":0,"second":0,"dayOffset":0},"end":{"hour":12,"minute":0,"second":0,"dayOffset":0},"source":{"kind":"region","iana":"Europe/Berlin"},"group":\#(group)\#(tag)}"#
        }
        let json = #"{"mentions":[\#(mention(2, series: 0, group: 0)),\#(mention(3, series: 0, group: 1)),\#(mention(4, series: 0, group: 2)),\#(mention(5, series: nil, group: 3))]}"#
        let output = try JSONDecoder().decode(TimeUnderstanding.Output.self, from: Data(json.utf8))
        #expect(output.mentions.map(\.series) == [0, 0, 0, nil])
        let rows = ReadingRow.group(output.mentions)
        #expect(rows.map(\.indices) == [[0, 1, 2], [3]])

        // 2026-10-02 是周五（柏林）：「周二至周四」落在 10 月 6–8 日。
        let friday = date("2026-10-02T10:00:00Z")
        let berlin = TimeZone(identifier: "Europe/Berlin")!
        let context = TimeUnderstanding.Context(reference: friday, now: friday, fallback: berlin, home: berlin)
        let all = TimeUnderstanding.resolveAll(output, context: context)
        let days = rows[0].indices.map { all[$0] }
        #expect(days.map { $0.day?.day } == [6, 7, 8])
        #expect(days.allSatisfy { $0.problem == nil })
        let style = UnderstandingText.Style(locale: Locale(identifier: "en"), hourStyle: .force24, now: friday, name: { $0.identifier })
        let line = UnderstandingText.seriesSummary(days, in: String(repeating: " ", count: 40), style: style, pasted: false)
        // 钟点的前导零跟系统区域（`ClockText.time`），这里只核日子那一段与终点。
        #expect(line.hasPrefix("Tue, Oct 6–Thu, Oct 8 ") && line.contains("–12:00"), "\(line)")
        let two = UnderstandingText.seriesSummary([days[0], days[2]], in: String(repeating: " ", count: 40), style: style, pasted: false)
        #expect(two.hasPrefix("Tue, Oct 6 and Thu, Oct 8 ") && two.contains("–12:00"), "\(two)")
    }

    /// 写法示例能点：十六种语言里每一条都是引擎读得成的一句（点了才有结果可看）。
    @Test @MainActor func everyClickableExampleReadsInEveryLanguage() {
        let thursday = Date(timeIntervalSince1970: 1_789_041_600)   // 2026-09-10 12:00 UTC
        for language in ["zh-Hans", "en", "zh-Hant", "ja", "ko", "de", "es", "fr", "ru", "pt-BR", "pl", "nl", "it", "vi", "tr", "id"] {
            for key in TimeInputView.exampleKeys {
                let example = L10n.string(key, locale: Locale(identifier: language))
                #expect(example != key || language == "zh-Hans" || key == "14:00", "\(language) 缺译文：\(key)")
                let resolution = TimeInput.resolve(example, relativeTo: thursday, in: .gmt)
                #expect(resolution.error == nil, "\(language)：\(example) → \(resolution.error ?? "")")
            }
        }
    }

    /// LMT（真太阳时）的秒级偏移：ISO 串只写 ±HH:MM，并标出已四舍五入（调研 #35）。
    /// 1947 年前的利雅得偏移是 `+03:06:52`，RFC 3339 不认带秒的偏移，收方会整串解析失败。
    @Test func localMeanTimeOffsetsAreRoundedToMinutesAndFlagged() throws {
        let riyadh = TimeZone(identifier: "Asia/Riyadh")!
        let old = date("1940-01-01T00:00:00Z")
        // 先确认本机 tzdata 在这个日期真给带秒的偏移，否则这条测试没有被测对象。
        #expect(riyadh.secondsFromGMT(for: old) % 60 != 0, "本机 tzdata 这个日期不是 LMT，断言前提不成立")
        let stamps = try #require(TimeInput.timestamps(for: old, in: riyadh))
        #expect(stamps.offsetRounded)
        #expect(!stamps.iso8601.hasSuffix("52"), "偏移里不许再出现秒：\(stamps.iso8601)")
        // 偏移后缀是 ±HH:MM，日期时间部分与瞬间对得上（Unix 秒不变）。
        #expect(stamps.iso8601.count == "1940-01-01T03:07:00+03:07".count)
        #expect(stamps.unix == "-946771200")
        // 整分钟偏移的地点一个字都不改，也不打标。
        let tokyo = try #require(TimeInput.timestamps(for: date("2026-09-17T00:00:00Z"), in: TimeZone(identifier: "Asia/Tokyo")!))
        #expect(!tokyo.offsetRounded)
        #expect(tokyo.iso8601 == "2026-09-17T09:00:00+09:00")
    }
}


struct TimeInputOutputReductionTests {
    @Test func reusedOutputKeepsInheritedDayBeforeChoosingAClock() throws {
        let json = #"{"mentions":[{"span":[0,10],"parts":[],"date":{"kind":"absolute","year":2026,"month":9,"day":24},"source":{"kind":"region","iana":"Europe/Berlin"},"group":0},{"span":[12,25],"parts":[],"date":{"kind":"absolute","year":2026,"month":9,"day":25},"dateInherited":true,"dateFrom":0,"time":{"hour":10,"minute":0,"second":0,"dayOffset":0},"source":{"kind":"region","iana":"UTC"},"group":1}]}"#
        let output = try JSONDecoder().decode(TimeUnderstanding.Output.self, from: Data(json.utf8))
        let formatter = ISO8601DateFormatter()
        let now = try #require(formatter.date(from: "2026-09-23T12:00:00Z"))
        let expected = try #require(formatter.date(from: "2026-09-24T10:00:00Z"))
        let actual = TimeInput.resolve(output, relativeTo: now, now: now, in: .gmt)
        #expect(actual.error == nil)
        #expect(actual.dates == [expected])
        #expect(actual.resolved?.mention.span == [12, 25])
        #expect(actual.resolved?.day?.day == 24)
    }
}
