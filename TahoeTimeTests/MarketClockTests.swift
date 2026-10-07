// SPDX-License-Identifier: GPL-3.0-only
//
//  MarketClockTests.swift
//  TahoeTimeTests
//
//  市场时钟的宿主那一半：作息在该市场时区变成真实时刻、跳过周末与休市日、
//  农历锚点来自系统农历。判据用手算的 UTC 时刻与公开的休市日（NYSE 2026 感恩节 11-26、
//  春节 2026-02-17），不照抄被测代码。挑规则本身在 Rust（`markets.rs` 八条测试）。
//

import Foundation
import Testing
@testable import TahoeTime

@MainActor
struct MarketClockTests {
    private func utc(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    @Test func theCatalogIsTheRustTableAndSessionsAreLocalWallClock() {
        let all = MarketCatalog.all
        #expect(all.count >= 15)
        let nyse = try! #require(MarketCatalog.market(id: "nyse"))
        #expect(nyse.timeZoneID == "America/New_York")
        #expect(nyse.sessions == [.init(startMinute: 570, endMinute: 960)])
        #expect(nyse.hasHolidays)
        // 东证两段（午休 11:30–12:30）。
        let tse = try! #require(MarketCatalog.market(id: "tse"))
        #expect(tse.sessions.count == 2)
        // 外汇时段没有休市日表。
        #expect(MarketCatalog.market(id: "fx-tokyo")?.hasHolidays == false)
    }

    @Test func sessionsBecomeRealInstantsAndSkipWeekendsAndHolidays() {
        let nyse = try! #require(MarketCatalog.market(id: "nyse"))
        // 2026-11-25 是周三：当天 09:30 EST = 14:30 UTC。
        let spans = MarketStore.spans(for: nyse, from: utc("2026-11-25T18:00:00Z"))
        #expect(spans.contains { $0.start == utc("2026-11-25T14:30:00Z") && $0.end == utc("2026-11-25T21:00:00Z") })
        // 11-26 是感恩节 → 没有时段；11-27（周五）有。
        #expect(!spans.contains { MarketStore.civilDate($0.start, in: nyse.timeZone) == "2026-11-26" })
        #expect(spans.contains { MarketStore.civilDate($0.start, in: nyse.timeZone) == "2026-11-27" })
        // 周末也没有。
        #expect(!spans.contains { MarketStore.civilDate($0.start, in: nyse.timeZone) == "2026-11-28" })
    }

    @Test func statusSaysOpenClosedAndWhenItChanges() {
        let store = MarketStore()
        // 2026-11-25 16:00 UTC = 纽约 11:00（开着，16:00 收盘）、东京 次日 01:00（休市）。
        store.refresh(now: utc("2026-11-25T16:00:00Z"))
        let nyse = try! #require(store.rows.first { $0.market.id == "nyse" })
        #expect(nyse.status.isOpen)
        #expect(nyse.status.changeDate == utc("2026-11-25T21:00:00Z"))
        #expect(nyse.todayHolidayKey == nil)
        // 下一个休市日就是第二天的感恩节。
        #expect(nyse.nextHoliday?.date == "2026-11-26")
        #expect(nyse.nextHoliday?.nameKey == "感恩节")
        let tse = try! #require(store.rows.first { $0.market.id == "tse" })
        #expect(!tse.status.isOpen)
        // 东京次日（11-26 周四）09:00 JST = 11-26T00:00Z。
        #expect(tse.status.changeDate == utc("2026-11-26T00:00:00Z"))
    }

    @Test func todaysHolidayIsNamedAndTheMarketStaysShut() {
        let store = MarketStore()
        // 感恩节当天纽约时间中午。
        store.refresh(now: utc("2026-11-26T17:00:00Z"))
        let nyse = try! #require(store.rows.first { $0.market.id == "nyse" })
        #expect(!nyse.status.isOpen)
        #expect(nyse.todayHolidayKey == "感恩节")
        // 下一次开盘是 11-27 09:30 EST。
        #expect(nyse.status.nextOpenDate == utc("2026-11-27T14:30:00Z"))
    }

    @Test func lunarAnchorsComeFromTheSystemCalendar() {
        // 公开日历：2026 年春节 2 月 17 日、2027 年 2 月 6 日；2026 年中秋 9 月 25 日。
        #expect(MarketHolidays.lunarDate(year: 2026, month: 1, day: 1) == "2026-02-17")
        #expect(MarketHolidays.lunarDate(year: 2027, month: 1, day: 1) == "2027-02-06")
        #expect(MarketHolidays.lunarDate(year: 2026, month: 8, day: 15) == "2026-09-25")
        // 清明与春分来自天文模块（黄经 15° / 0°）。
        #expect(MarketHolidays.qingming(year: 2026) == "2026-04-05")
        #expect(MarketHolidays.equinox(year: 2026, march: true) == "2026-03-20")
        // 上交所的休市日里有春节那几天。
        let sse = MarketHolidays.list(set: "cn", year: 2026)
        #expect(sse.contains { $0.date == "2026-02-17" && $0.nameKey == "春节" })
        // 香港休中秋翌日（2026 年走港交所公布的休市表，规则推算看 2027：中秋 9 月 15 日）。
        let hk = MarketHolidays.list(set: "hk", year: 2027)
        #expect(hk.contains { $0.date == "2027-09-16" && $0.nameKey == "中秋节翌日" })
    }

    /// 关着分四种，状态词只按它选：东证 2026-11-25（周三）当地 01:00 未开盘、11:46 午休、17:20 已收盘；周六不开；
    /// 纽约感恩节当天不开。「休市」只给当地今天不开的日子。
    @Test func closedSaysWhichKindOfClosed() {
        let tse = try! #require(MarketCatalog.market(id: "tse"))
        let nyse = try! #require(MarketCatalog.market(id: "nyse"))
        let phase = { (market: MarketDefinition, iso: String) -> String? in
            let date = self.utc(iso)
            let holidays = MarketStore.holidays(for: market, around: date)
            return MarketStore.row(market, at: date, holidays: holidays,
                                   spans: MarketStore.spans(for: market, from: date, holidays: holidays)).status.phase
        }
        #expect(phase(tse, "2026-11-24T16:00:00Z") == "beforeOpen")
        #expect(phase(tse, "2026-11-25T00:30:00Z") == "open")
        #expect(phase(tse, "2026-11-25T02:46:00Z") == "break")
        #expect(phase(tse, "2026-11-25T08:20:00Z") == "afterClose")
        #expect(phase(tse, "2026-11-28T03:00:00Z") == "noSession")
        #expect(phase(nyse, "2026-11-26T17:00:00Z") == "noSession")
        let words = ["open": "开盘中", "beforeOpen": "未开盘", "break": "午休中", "afterClose": "已收盘", "noSession": "休市"]
        for (phase, key) in words {
            let status = MarketStatus(state: phase == "open" ? "open" : "closed", phase: phase, changeAt: nil, minutesToChange: nil,
                                      sessionStart: nil, sessionEnd: nil, nextOpenAt: nil, breakUntil: nil)
            #expect(MarketLensView.statusKey(status) == key)
        }
    }

    /// 超过一天的下一次开盘写本机的星期与钟点，不写「57小时57分钟后」；一天以内照旧写还有多久。
    @Test func aWeekendAwayNamesTheDay() throws {
        let format = ClockFormat(hourStyle: .force24, showSeconds: false)
        let zh = Locale(identifier: "zh-Hans")
        let closed = { (change: String) in
            MarketStatus(state: "closed", phase: "noSession", changeAt: self.utc(change).timeIntervalSince1970, minutesToChange: nil,
                         sessionStart: nil, sessionEnd: nil, nextOpenAt: nil, breakUntil: nil)
        }
        // 周五 2026-10-02 03:00Z 起算，东证下周一 09:00 JST = 10-05 00:00Z，约 69 小时以后。
        let far = try #require(MarketLensView.nextText(closed("2026-10-05T00:00:00Z"), from: utc("2026-10-02T03:00:00Z"), format: format, locale: zh))
        let clock = TimeFormatting.string(for: utc("2026-10-05T00:00:00Z"), in: .current, format: format)
        let weekday = ClockText.weekday(utc("2026-10-05T00:00:00Z"), in: .current, locale: zh)
        #expect(far == String(format: L10n.string("本机 %@ 开盘", locale: zh), locale: zh, "\(weekday) \(clock)"))
        #expect(!far.contains("小时"))
        let near = try #require(MarketLensView.nextText(closed("2026-10-02T05:30:00Z"), from: utc("2026-10-02T03:00:00Z"), format: format, locale: zh))
        #expect(near.contains("2小时30分钟"))
    }

    /// 交易所的天按它所在的城市画：印度国家证券交易所在孟买，不是时区的代表城市加尔各答。
    @Test func eachExchangeKnowsItsCity() {
        let nse = MarketCatalog.market(id: "nse")
        #expect(nse?.coordinate == Coordinate(latitude: 19.06, longitude: 72.86))
        #expect(MarketCatalog.all.allSatisfy { $0.coordinate != nil })
    }

    /// 页面那一份按分钟记住：同一分钟再问不重算。
    @Test func theMemoKeepsAMinute() {
        let memo = MarketMemo()
        let markets = Array(MarketCatalog.all.prefix(3))
        let first = memo.rows(at: utc("2026-11-25T16:00:10Z"), markets: markets)
        let again = memo.rows(at: utc("2026-11-25T16:00:50Z"), markets: markets)
        #expect(first == again)
        #expect(first.count == 3)
        #expect(first.first?.status.isOpen == true)
    }

    @Test func theLensOwnsNoBackgroundResources() {
        // 与别的透镜同一条规矩：不常驻、不联网（这一片连网络代码都没有）。
        let store = MarketStore()
        #expect(store.rows.isEmpty)
        store.refresh(now: utc("2026-11-25T16:00:00Z"))
        #expect(store.rows.count == MarketCatalog.all.count)
    }
}
