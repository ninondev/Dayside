// SPDX-License-Identifier: GPL-3.0-only
//
//  ClockTextTests.swift
//  TahoeTimeTests
//
//  工具页钟点文本（ClockText）：小时制设置要生效，
//  且与 TimeFormatting 同一条路——同一时刻在面板、排会页与天文/夏令时/分享页写法一致。
//

import Foundation
import Testing
@testable import TahoeTime

struct ClockTextTests {
    /// 2026-09-21 06:35 东京（固定时刻，不随本机时钟）。
    private let morning = Date(timeIntervalSince1970: 1_789_940_100)
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    private let enUS = Locale(identifier: "en_US")

    @Test
    func force24GivesTwoDigitHoursInEnglish() {
        #expect(ClockText.time(morning, in: tokyo, hourStyle: .force24, system: enUS) == "06:35")
    }

    @Test
    func force12GivesTwelveHourClockWithMeridiem() {
        let text = ClockText.time(morning, in: tokyo, hourStyle: .force12, system: enUS)
        // 6:35 AM（数字与 AM 之间是 ICU 的窄不换行空格）
        #expect(text.hasPrefix("6:35"))
        #expect(text.hasSuffix("AM"))
        #expect(!text.hasPrefix("06"))
    }

    @Test
    func followSystemTakesTheSystemHourCycle() {
        let twentyFour = Locale(identifier: "en_US@hours=h23")
        #expect(ClockText.time(morning, in: tokyo, hourStyle: .followSystem, system: twentyFour) == "06:35")
        #expect(ClockText.time(morning, in: tokyo, hourStyle: .followSystem, system: enUS).hasSuffix("AM"))
    }

    /// 与 TimeFormatting 逐字节相同：三种小时制在本机 locale 下都一样，否则同一时刻会有两种写法。
    @Test(arguments: [HourStyle.followSystem, .force12, .force24])
    func matchesTimeFormatting(style: HourStyle) {
        let evening = Date(timeIntervalSince1970: 1_790_000_100)
        for date in [morning, evening] {
            let expected = TimeFormatting.string(for: date, in: tokyo, format: ClockFormat(hourStyle: style, showSeconds: false))
            #expect(ClockText.time(date, in: tokyo, hourStyle: style) == expected)
        }
    }

    /// 图表横轴用的 FormatStyle 与钟点文本同一 hourCycle。
    @Test
    func axisStyleAgreesWithTimeText() {
        let style = ClockText.timeStyle(in: tokyo, hourStyle: .force24, system: enUS)
        #expect(morning.formatted(style) == ClockText.time(morning, in: tokyo, hourStyle: .force24, system: enUS))
    }

    /// 日期按界面语言、钟点按小时制，空格相接；年份规则同 `day`：同年不写、跨年才写，
    /// `year: .always` 一律写（旅行页行程），`weekday` 加星期全称（夏令时卡片）。
    @Test
    func dateTimeCombinesInterfaceDateWithClock() {
        let sameYear = Date(timeIntervalSince1970: 1_789_000_000)   // 2026-09-10
        let nextYear = Date(timeIntervalSince1970: 1_820_000_000)   // 2027-09-04
        let chinese = Locale(identifier: "zh-Hans")
        #expect(ClockText.dateTime(morning, in: tokyo, hourStyle: .force24, locale: enUS, now: sameYear, system: enUS)
                == "Sep 21 06:35")
        #expect(ClockText.dateTime(morning, in: tokyo, hourStyle: .force24, locale: enUS, now: nextYear, system: enUS)
                == "Sep 21, 2026 06:35")
        #expect(ClockText.dateTime(morning, in: tokyo, hourStyle: .force24, locale: chinese, now: sameYear, system: enUS)
                == "9月21日 06:35")
        #expect(ClockText.dateTime(morning, in: tokyo, hourStyle: .force24, locale: chinese, now: nextYear, system: enUS)
                == "2026年9月21日 06:35")
        // 旅行页的例外：同年也写年。
        #expect(ClockText.dateTime(morning, in: tokyo, hourStyle: .force24, locale: enUS, now: sameYear, year: .always, system: enUS)
                == "Sep 21, 2026 06:35")
        #expect(ClockText.day(morning, in: tokyo, locale: chinese, now: sameYear, year: .always) == "2026年9月21日")
        // 夏令时卡片：带星期（2026-09-21 是周一），年份规则不变。
        #expect(ClockText.dateTime(morning, in: tokyo, hourStyle: .force24, locale: enUS, now: sameYear, weekday: true, system: enUS)
                == "Mon, Sep 21 06:35")
        #expect(ClockText.day(morning, in: tokyo, locale: chinese, now: nextYear, weekday: true) == "2026年9月21日 周一")
    }

    /// 各地时间行的跨日偏移：洛杉矶周一 21:00 = 伦敦次日 5:00 = 东京次日 13:00；
    /// 反过来以东京为行首，洛杉矶是前一日。比较的是各自时区的年月日，与 24 小时倍数无关。
    @Test
    func dayOffsetFollowsEachZonesCalendarDate() {
        // 2026-09-15T04:00:00Z = 洛杉矶 09-14 21:00 PDT、伦敦 09-15 05:00 BST、东京 09-15 13:00 JST。
        let instant = ISO8601DateFormatter().date(from: "2026-09-15T04:00:00Z")!
        let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
        let london = TimeZone(identifier: "Europe/London")!
        #expect(ClockText.dayOffset(of: instant, in: london, from: losAngeles) == 1)
        #expect(ClockText.dayOffset(of: instant, in: tokyo, from: losAngeles) == 1)
        #expect(ClockText.dayOffset(of: instant, in: losAngeles, from: losAngeles) == 0)
        #expect(ClockText.dayOffset(of: instant, in: losAngeles, from: tokyo) == -1)
        #expect(ClockText.dayOffset(of: instant, in: london, from: tokyo) == 0)
        // 钟点一样、日期差一天：莱恩群岛（UTC+14）与夏威夷（UTC−10）同刻都是 1:30，不标「次日」就看不出差别。
        let hawaii = TimeZone(identifier: "Pacific/Honolulu")!
        let kiritimati = TimeZone(identifier: "Pacific/Kiritimati")!
        let noonUTC = ISO8601DateFormatter().date(from: "2026-09-15T11:30:00Z")!   // 夏威夷 09-15 01:30、莱恩群岛 09-16 01:30
        #expect(ClockText.dayOffset(of: noonUTC, in: kiritimati, from: hawaii) == 1)
        #expect(ClockText.dayOffset(of: noonUTC, in: hawaii, from: kiritimati) == -1)
        // 与换算页「各地现在」的判据一致：偏移非零 ⇔ 日期不同。
        #expect(TimeInputView.isDifferentDay(instant, in: london, from: losAngeles))
        #expect(!TimeInputView.isDifferentDay(instant, in: london, from: tokyo))
    }

    // MARK: - 分钟、区间、只在非本年写年份

    /// 一天里的第几分钟 → 钟点（可约时段、例会漂移、分享页可约时段共用）。
    @Test
    func minuteOfDayFollowsTheHourStyle() {
        #expect(ClockText.minute(9 * 60, hourStyle: .force24, system: enUS) == "09:00")
        #expect(ClockText.minute(18 * 60, hourStyle: .force24, system: enUS) == "18:00")
        let twelve = ClockText.minute(18 * 60, hourStyle: .force12, system: enUS)
        #expect(twelve.hasPrefix("6:00") && twelve.hasSuffix("PM"))
        #expect(ClockText.minute(0, hourStyle: .force24, system: enUS) == "00:00")
    }

    /// 区间只有一种写法：短横（U+2013）两侧不带空格。
    @Test
    func rangeUsesAnEnDashWithoutSpaces() {
        #expect(ClockText.range("9:00", "18:00") == "9:00\u{2013}18:00")
        #expect(ClockText.minuteRange(9 * 60, 18 * 60, hourStyle: .force24, system: enUS) == "09:00–18:00")
        #expect(!ClockText.minuteRange(9 * 60, 18 * 60, hourStyle: .force24, system: enUS).contains(" "))
    }

    /// 日期只在不是「今年」时才带年份：今天的日程写「Sep 21」，来年的才写年。
    @Test
    func dayWritesTheYearOnlyOutsideTheCurrentYear() {
        let sameYear = Date(timeIntervalSince1970: 1_789_000_000)   // 2026-09-10
        let nextYear = Date(timeIntervalSince1970: 1_820_000_000)   // 2027-09-04
        #expect(ClockText.day(morning, in: tokyo, locale: enUS, now: sameYear) == "Sep 21")
        #expect(ClockText.day(morning, in: tokyo, locale: enUS, now: nextYear) == "Sep 21, 2026")
        let chinese = Locale(identifier: "zh-Hans")
        #expect(ClockText.day(morning, in: tokyo, locale: chinese, now: sameYear) == "9月21日")
        #expect(ClockText.day(morning, in: tokyo, locale: chinese, now: nextYear) == "2026年9月21日")
    }

    /// 日程区间：同一天「Sep 21 06:35–07:05」，跨天两端都带日期，全天只写日期。
    @Test
    func intervalCoversSameDayCrossDayAndAllDay() {
        let now = Date(timeIntervalSince1970: 1_789_000_000)   // 2026-09-10，同一年
        let end = morning.addingTimeInterval(30 * 60)
        #expect(ClockText.interval(from: morning, to: end, in: tokyo, hourStyle: .force24, locale: enUS, now: now, system: enUS)
                == "Sep 21 06:35–07:05")
        // 2026-09-21 23:30 东京 → 次日 00:30。
        let lateStart = morning.addingTimeInterval((16 * 60 + 55) * 60)
        let lateEnd = lateStart.addingTimeInterval(60 * 60)
        #expect(ClockText.interval(from: lateStart, to: lateEnd, in: tokyo, hourStyle: .force24, locale: enUS, now: now, system: enUS)
                == "Sep 21 23:30–Sep 22 00:30")
        #expect(ClockText.interval(from: morning, to: end, in: tokyo, hourStyle: .force24, locale: enUS, allDay: true, now: now, system: enUS)
                == "Sep 21")
        let twoDays = morning.addingTimeInterval(2 * 86_400)
        #expect(ClockText.interval(from: morning, to: twoDays, in: tokyo, hourStyle: .force24, locale: enUS, allDay: true, now: now, system: enUS)
                == "Sep 21–Sep 23")
        // 12 小时制照样走同一条路。
        let twelve = ClockText.interval(from: morning, to: end, in: tokyo, hourStyle: .force12, locale: enUS, now: now, system: enUS)
        #expect(twelve.hasPrefix("Sep 21 6:35") && twelve.contains("–7:05") && twelve.hasSuffix("AM"))
    }

    /// 换算页「各地现在」只在该地日期与来源不同时才写日期。
    @Test
    func differentDayOnlyAcrossTheDateLine() {
        let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
        // 东京 06:35 = 洛杉矶前一天 14:35；伦敦同一天 22:35（前一天）… 用一个明确跨日的时刻：
        #expect(TimeInputView.isDifferentDay(morning, in: tokyo, from: losAngeles))
        #expect(!TimeInputView.isDifferentDay(morning, in: tokyo, from: tokyo))
        let london = TimeZone(identifier: "Europe/London")!
        // 2026-09-21 06:35 JST = 2026-09-20 22:35 BST：与伦敦跨日。
        #expect(TimeInputView.isDifferentDay(morning, in: tokyo, from: london))
        // 同一时刻东京与首尔同一天。
        #expect(!TimeInputView.isDifferentDay(morning, in: tokyo, from: TimeZone(identifier: "Asia/Seoul")!))
    }

    /// 时长文本走字符串目录：中文数字与单位之间有空格，英文单复数由目录的变体给，
    /// 零的段不写，不足一分钟写「0 分钟」；此前各页的 DateComponentsFormatter 在中文里给「11小时」。
    @Test
    func durationUsesTheCatalogWithSpacesAndPlurals() {
        let zh = Locale(identifier: "zh-Hans")
        let en = Locale(identifier: "en")
        #expect(ClockText.duration(seconds: 11 * 3600, locale: zh) == "11小时")
        // 段与段之间不留空格。
        #expect(ClockText.duration(seconds: 11 * 3600 + 30 * 60, locale: zh) == "11小时30分钟")
        #expect(ClockText.duration(seconds: 30 * 60, locale: zh) == "30分钟")
        #expect(ClockText.duration(seconds: 20, locale: zh) == "0分钟")
        #expect(ClockText.duration(seconds: 3600, locale: en) == "1 hour")
        #expect(ClockText.duration(seconds: 2 * 3600 + 60, locale: en) == "2 hours 1 minute")
        #expect(ClockText.duration(seconds: 26 * 3600 + 5 * 60, days: true, locale: en) == "1 day 2 hours 5 minutes")
        #expect(ClockText.duration(seconds: 26 * 3600, locale: en) == "26 hours")
        #expect(ClockText.duration(seconds: 2 * 3600, locale: Locale(identifier: "ru")) == "2 часа")
        #expect(ClockText.duration(seconds: 5 * 3600, locale: Locale(identifier: "ru")) == "5 часов")
    }

    /// 时钟调整写成 `换钟前 → 换钟后` 两种读法：伦敦 2026-10-25 01:00Z 退出夏令时是「2:00 → 1:00」，
    /// 纽约 2026-03-08 07:00Z 进入夏令时是「2:00 → 3:00」；日期跟换钟前的读法。
    @Test
    func clockChangeReadsBeforeAndAfterTheTransition() {
        let sameYear = Date(timeIntervalSince1970: 1_789_000_000)   // 2026-09-10
        let londonBack = Date(timeIntervalSince1970: 1_792_890_000)  // 2026-10-25T01:00:00Z
        #expect(ClockText.clockChange(at: londonBack, before: 3600, after: 0, hourStyle: .force24, locale: enUS, now: sameYear, system: enUS)
                == "Oct 25 02:00 → 01:00")
        #expect(ClockText.clockChange(at: londonBack, before: 3600, after: 0, hourStyle: .force24, locale: Locale(identifier: "zh-Hans"), now: sameYear, system: enUS)
                == "10月25日 02:00 → 01:00")
        let newYorkForward = Date(timeIntervalSince1970: 1_772_953_200)  // 2026-03-08T07:00:00Z
        #expect(ClockText.clockChange(at: newYorkForward, before: -18_000, after: -14_400, hourStyle: .force24, locale: enUS, now: sameYear, system: enUS)
                == "Mar 8 02:00 → 03:00")
    }

    @Test(arguments: [
        ("ru", 1, 41, "через 1 час 41 минуту"),
        ("ru", 2, 3, "через 2 часа 3 минуты"),
        ("ru", 5, 11, "через 5 часов 11 минут"),
        ("pl", 1, 41, "za 1 godzinę 41 minut"),
        ("pl", 2, 3, "za 2 godziny 3 minuty"),
        ("ru", 21, 21, "через 21 час 21 минуту"),
        ("pl", 5, 11, "za 5 godzin 11 minut"),
        ("en", 0, 1, "in 1 minute"),
        ("zh-Hans", 17, 24, "17小时24分钟后"),
        ("zh-Hant", 17, 24, "17小時24分鐘後")
    ])
    func relativeDurationUsesContextualForms(language: String, hours: Int, minutes: Int, expected: String) {
        #expect(ClockText.durationIn(seconds: Double(hours * 3600 + minutes * 60),
                                    locale: Locale(identifier: language)) == expected)
    }

    /// 满一天写天与小时，按方向句的格（德语 in / vor 之后是与格「Tagen」，俄语 через 之后「дня / дней」），
    /// 小时四舍五入到整点、分钟不写；不到一天照旧写到分钟。面板滑块那一句与工具窗页首天色带那一句都走这里。
    @Test(arguments: [
        ("zh-Hans", 2, 3, 0, true, "2天3小时后"),
        ("zh-Hans", 1, 0, 0, false, "1天前"),
        ("zh-Hant", 2, 3, 0, true, "2天3小時後"),
        ("ja", 2, 3, 0, true, "2日3時間後"),
        ("ko", 2, 3, 0, true, "2일 3시간 후"),
        ("en", 2, 3, 0, true, "in 2 days 3 hours"),
        ("en", 2, 0, 0, false, "2 days ago"),
        ("en", 1, 0, 20, true, "in 1 day"),
        ("en", 1, 23, 40, true, "in 2 days"),
        ("en", 2, 3, 31, true, "in 2 days 4 hours"),
        ("en", 0, 23, 59, true, "in 23 hours 59 minutes"),
        ("de", 2, 3, 0, true, "in 2 Tagen 3 Stunden"),
        ("de", 1, 0, 0, false, "vor 1 Tag"),
        ("ru", 2, 3, 0, true, "через 2 дня 3 часа"),
        ("ru", 5, 1, 0, false, "5 дней 1 час назад"),
        ("ru", 21, 0, 0, true, "через 21 день"),
        ("pl", 2, 3, 0, true, "za 2 dni 3 godziny"),
        ("pl", 1, 0, 0, false, "1 dzień temu"),
        ("fr", 2, 3, 0, true, "dans 2 jours 3 heures"),
        ("es", 2, 0, 0, false, "hace 2 días"),
        ("it", 2, 0, 0, true, "tra 2 giorni"),
        ("pt-BR", 2, 3, 0, true, "em 2 dias 3 horas"),
        ("nl", 2, 0, 0, false, "2 dagen geleden"),
        ("tr", 2, 3, 0, true, "2 gün 3 saat sonra"),
        ("vi", 2, 0, 0, true, "sau 2 ngày"),
        ("id", 2, 3, 0, false, "2 hari 3 jam yang lalu")
    ])
    func directionPhrasesCountDays(language: String, days: Int, hours: Int, minutes: Int, forward: Bool, expected: String) {
        let seconds = Double(days * 86_400 + hours * 3600 + minutes * 60)
        let locale = Locale(identifier: language)
        let text = forward ? ClockText.durationIn(seconds: seconds, locale: locale) : ClockText.durationAgo(seconds: seconds, locale: locale)
        #expect(text == expected)
        // 市场页的开收盘句还按小时与分钟写（`days` 默认关）。
        #expect(!ClockText.directionalDuration(seconds: 50 * 3600, locale: locale).isEmpty)
    }

    /// 今天、明天用系统的说法（句中小写、句首大写），再远写日期与星期；跨过午夜两头各写一次。
    @Test func relativeDaysNameTodayAndTomorrowAndDatesBeyond() {
        let la = TimeZone(identifier: "America/Los_Angeles")!
        let now = Date(timeIntervalSince1970: 1_790_000_000)          // 2026-09-21 07:13 洛杉矶
        let en = Locale(identifier: "en"), de = Locale(identifier: "de"), zh = Locale(identifier: "zh-Hans")
        #expect(ClockText.relativeDay(now.addingTimeInterval(3600), in: la, locale: en, now: now) == "today")
        #expect(ClockText.relativeDay(now.addingTimeInterval(86_400), in: la, locale: en, now: now, sentenceStart: true) == "Tomorrow")
        #expect(ClockText.relativeDay(now.addingTimeInterval(86_400), in: la, locale: de, now: now) == "morgen")
        #expect(ClockText.relativeDay(now.addingTimeInterval(86_400), in: la, locale: zh, now: now) == "明天")
        #expect(ClockText.relativeDay(now.addingTimeInterval(2 * 86_400), in: la, locale: zh, now: now)
                == ClockText.day(now.addingTimeInterval(2 * 86_400), in: la, locale: zh, now: now, weekday: true))
        let start = now.addingTimeInterval(2 * 3600 - 13 * 60)       // 今天 9:00
        #expect(ClockText.relativeInterval(from: start, to: start.addingTimeInterval(2 * 3600), in: la, hourStyle: .force24,
                                           locale: zh, now: now, sentenceStart: true, system: zh) == "今天 9:00–11:00")
        let late = now.addingTimeInterval(16 * 3600 - 13 * 60)       // 今天 23:00
        #expect(ClockText.relativeInterval(from: late, to: late.addingTimeInterval(2 * 3600), in: la, hourStyle: .force24,
                                           locale: zh, now: now, system: zh) == "今天 23:00–明天 1:00")
    }

    @Test(arguments: [
        ("ru", 1, 41, "1 час 41 минуту"),
        ("ru", 2, 3, "2 часа 3 минуты"),
        ("ru", 5, 11, "5 часов 11 минут"),
        ("ru", 21, 21, "21 час 21 минуту"),
        ("ru", 0, 1, "1 минуту"),
        ("ru", 1, 0, "1 час"),
        ("ru", 0, 0, "0 минут"),
        ("pl", 1, 41, "1 godzinę 41 minut"),
        ("pl", 2, 3, "2 godziny 3 minuty"),
        ("pl", 5, 11, "5 godzin 11 minut"),
        ("pl", 21, 21, "21 godzin 21 minut"),
        ("pl", 0, 1, "1 minutę"),
        ("pl", 1, 0, "1 godzinę"),
        ("pl", 0, 0, "0 minut")
    ])
    func marketChangesUseContextualDurationForEveryFrame(language: String, hours: Int, minutes: Int,
                                                        expectedDuration: String) {
        let locale = Locale(identifier: language)
        let seconds = Double(hours * 3600 + minutes * 60)
        let expected = language == "ru" ? [
            "Открытие через \(expectedDuration) (16:00 по времени этого Mac)",
            "Закрытие через \(expectedDuration) (16:00 по времени этого Mac)",
            "Обеденный перерыв через \(expectedDuration); торги возобновятся в 17:00 по времени этого Mac"
        ] : [
            "Otwarcie za \(expectedDuration) (16:00 na tym Macu)",
            "Zamknięcie za \(expectedDuration) (16:00 na tym Macu)",
            "Przerwa południowa za \(expectedDuration); wznowienie o 17:00 na tym Macu"
        ]
        #expect(MarketLensView.changeLine(isOpen: false, seconds: seconds, clock: "16:00", locale: locale)
                == expected[0])
        #expect(MarketLensView.changeLine(isOpen: true, seconds: seconds, clock: "16:00", locale: locale)
                == expected[1])
        #expect(MarketLensView.changeLine(isOpen: true, seconds: seconds, clock: "16:00",
                                          breakUntilClock: "17:00", locale: locale) == expected[2])
    }

    @Test(arguments: InterfaceLanguage.allCases.filter { $0 != .system })
    func weekdaysUseThePanelStyle(language: InterfaceLanguage) {
        let locale = Locale(identifier: language.localeIdentifier!)
        let friday = Date(timeIntervalSince1970: 1_790_899_200) // 2026-10-02 UTC
        let weekday = ClockText.weekday(friday, in: .gmt, locale: locale)
        #expect(weekday == friday.formatted(Date.FormatStyle(locale: locale, timeZone: .gmt).weekday(.abbreviated)))
        #expect(ClockText.weekday(6, locale: locale) == weekday)
        #expect(ClockText.day(friday, in: .gmt, locale: locale, now: friday, weekday: true).contains(weekday))
        if locale.language.languageCode?.identifier == "zh" {
            #expect(weekday == (locale.language.script?.identifier == "Hant" ? "週五" : "周五"))
        }
    }

}
