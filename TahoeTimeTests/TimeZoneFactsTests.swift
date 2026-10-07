// SPDX-License-Identifier: GPL-3.0-only
//
//  TimeZoneFactsTests.swift
//  TahoeTimeTests
//
//  真时区事实的断言。判据是 IANA 数据本身的公开事实，不是我们的实现：
//  ①偏移不变、只翻 isDST 的转换不是换钟（摩洛哥斋月）；②开罗 2026-04-24 只有 23 小时；
//  ③Kiritimati 与 Etc/GMT+12 的民用日差两天；④`Etc/GMT+5` 的偏移是 UTC−5（IANA 的符号是反的）；
//  ⑤已经不再换钟的地点（卡萨布兰卡 2027）一条换钟都不该有。
//

import Foundation
import Testing
@testable import TahoeTime

@MainActor
struct TimeZoneFactsTests {
    private func utc(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    @Test func offsetUnchangedTransitionsAreNotClockChanges() {
        // 摩洛哥：斋月前后 Foundation 会报 DST 转换，但总偏移始终是 UTC+1，钟面一分钟不动。
        let casablanca = TimeZone(identifier: "Africa/Casablanca")!
        var cursor = utc("2026-01-01T00:00:00Z")
        var offsetUnchanged = 0
        for _ in 0..<8 {
            guard let next = casablanca.nextDaylightSavingTimeTransition(after: cursor) else { break }
            if casablanca.secondsFromGMT(for: next) == casablanca.secondsFromGMT(for: next.addingTimeInterval(-1)) {
                offsetUnchanged += 1
            }
            cursor = next
        }
        // 这一条只在系统 tzdata 仍带斋月转换时有意义；有就必须被我们过滤掉。
        let changes = DSTCalendarPlan.changes(zones: ["Africa/Casablanca"], from: utc("2026-01-01T00:00:00Z"),
                                                   months: 24)
        #expect(changes.allSatisfy { $0.beforeSeconds != $0.afterSeconds },
                "偏移没变的转换被当成换钟了：\(changes.map { ($0.at, $0.beforeSeconds, $0.afterSeconds) })")
        // 时差分段也不该因此多出一段。
        let reports = OffsetWindows.reports(localZone: "Europe/London", places: ["Africa/Casablanca"],
                                            now: utc("2026-01-01T00:00:00Z"))
        #expect(reports.count <= 1)
    }

    @Test func casablancaHasNoClockChangesLeft() {
        // 摩洛哥 2026-09-20 起常年 UTC+1（tzdata 2026c）：2027 年整年没有换钟。
        let changes = DSTCalendarPlan.changes(zones: ["Africa/Casablanca"],
                                                    from: utc("2027-01-01T00:00:00Z"), months: 12)
        #expect(changes.isEmpty, "卡萨布兰卡 2027 还有换钟：\(changes.map(\.at))")
        // 对照：伦敦 2027 仍然换两次（不是所有地方都停了）。温哥华在本机 tzdata 里 2027 也没有换钟
        // （不列诺省的常年夏令时，tzdata 表里 Vancouver 2027-01 的冬季探针就是 −420），所以不拿它当对照。
        let london = DSTCalendarPlan.changes(zones: ["Europe/London"],
                                              from: utc("2027-01-01T00:00:00Z"), months: 12)
        #expect(london.count == 2, "伦敦 2027 的换钟次数是 \(london.count)")
    }

    @Test func cairoHasATwentyThreeHourCivilDay() {
        // 埃及 2026-04-24 进夏令时（周五 00:00 → 01:00）：那个民用日只有 23 小时。
        let cairo = TimeZone(identifier: "Africa/Cairo")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = cairo
        // 民用日的长度要用「相邻两天的 startOfDay 之差」量：`byAdding: .day` 保的是墙钟，
        // 换钟那天照样给 24 小时（第一版就量错了）。
        let day = calendar.startOfDay(for: calendar.date(from: DateComponents(year: 2026, month: 4, day: 24))!)
        let next = calendar.startOfDay(for: day.addingTimeInterval(25 * 3600))
        #expect(next.timeIntervalSince(day) == 23 * 3600,
                "开罗 2026-04-24 的长度是 \(next.timeIntervalSince(day) / 3600) 小时")
        // 这一天的换钟会被我们列出来（偏移真的变了）。
        let changes = DSTCalendarPlan.changes(zones: ["Africa/Cairo"], from: utc("2026-04-01T00:00:00Z"), months: 2)
        #expect(changes.contains { $0.afterSeconds - $0.beforeSeconds == 3600 })
    }

    @Test func theDateLineAndTheEtcSignsAreHandledAsIANADefinesThem() {
        // Kiritimati（UTC+14）与 Etc/GMT+12（UTC−12）的民用日差两天。
        let kiritimati = TimeZone(identifier: "Pacific/Kiritimati")!
        let west = TimeZone(identifier: "Etc/GMT+12")!
        // 两地相差 26 小时：UTC 11:00 时 Kiritimati 已是 18 日凌晨、Etc/GMT+12 还是 16 日深夜 → 差两天。
        let moment = utc("2026-09-17T11:00:00Z")
        func civilDay(_ zone: TimeZone) -> Date {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            let parts = calendar.dateComponents([.year, .month, .day], from: moment)
            var utcCalendar = Calendar(identifier: .gregorian)
            utcCalendar.timeZone = TimeZone(identifier: "UTC")!
            return utcCalendar.date(from: parts)!
        }
        let difference = Calendar(identifier: .gregorian)
            .dateComponents([.day], from: civilDay(west), to: civilDay(kiritimati)).day
        #expect(difference == 2, "日期差是 \(difference ?? -1) 天")
        // IANA 的 `Etc/GMT+5` 是 UTC−5（符号与 POSIX 一样是反的）：我们显示的偏移必须按事实来。
        let etc = TimeZone(identifier: "Etc/GMT+5")!
        #expect(etc.secondsFromGMT(for: moment) == -5 * 3600)
        let entry = TimeZoneEntry(timezoneID: "Etc/GMT+5", cityName: "")
        // 偏移文本的写法由 Rust `model.entry_label` 定：整小时写「UTC−5」，带分钟才写「UTC+5:45」。
        #expect(entry.offsetString(at: moment) == "UTC−5", "显示的是 \(entry.offsetString(at: moment))")
    }
}
