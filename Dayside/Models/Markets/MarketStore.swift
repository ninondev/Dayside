// SPDX-License-Identifier: GPL-3.0-only
//
//  MarketStore.swift
//  Dayside
//
//  市场时钟。
//  这里只做 Apple 框架那部分：把 Rust 给的「作息 + 休市日规则」在该市场的时区里变成真实时刻，
//  并把要日历事实才知道的日子问系统要——农历锚点问 Foundation 的农历（`Calendar(identifier: .chinese)`），
//  春分秋分问我们自己的天文模块。哪个市场认哪些休市日、现在算开还是关、关着是哪一种关，都在 Rust `markets.*`。
//  不做行情、不联网。页面看的那一刻由页面给（App 正在看的那一刻，或时间轴上点出来的那一刻），算好的东西跟着页面走（`MarketMemo`），
//  工具窗关了就没了。
//

import Foundation

struct MarketDefinition: Decodable, Identifiable, Sendable, Hashable {
    struct Session: Decodable, Sendable, Hashable {
        let startMinute: Int
        let endMinute: Int
    }
    let id: String
    /// 名字的字符串目录键（源语简体中文）。
    let nameKey: String
    let timeZoneID: String
    /// "exchange" 或 "fx"。
    let kind: String
    /// 休市日规则编号；"none" = 没收录，页面会写明。
    let holidaySet: String
    let sessions: [Session]
    /// 交易所所在的城市（那一行的天按它画；不是时区的代表城市）。
    let latitude: Double?
    let longitude: Double?

    var timeZone: TimeZone { TimeZone(identifier: timeZoneID) ?? .gmt }
    var hasHolidays: Bool { holidaySet != "none" }
    var coordinate: Coordinate? {
        guard let latitude, let longitude else { return nil }
        return Coordinate(latitude: latitude, longitude: longitude)
    }
}

struct MarketHoliday: Decodable, Sendable, Hashable {
    /// `YYYY-MM-DD`（该市场的民用日）。
    let date: String
    let nameKey: String
}

/// 一个市场在某一刻的状态。
struct MarketStatus: Decodable, Sendable, Hashable {
    /// "open" / "closed" / "unknown"。
    let state: String
    /// 关着是哪一种：`beforeOpen` 当地今天还没开、`break` 午休、`afterClose` 今天收了、`noSession` 当地今天不开（周末或休市日）；
    /// 开着是 `open`。没给当地日时 Rust 只说 `closed`。
    let phase: String?
    /// 下一次变化的时刻（收盘或开盘）；范围内没有下一次就是 nil。
    let changeAt: Double?
    let minutesToChange: Double?
    let sessionStart: Double?
    let sessionEnd: Double?
    let nextOpenAt: Double?
    /// 开着且当天还有下一段（午休）时，午休到几点。
    let breakUntil: Double?

    var isOpen: Bool { state == "open" }
    var changeDate: Date? { changeAt.map { Date(timeIntervalSince1970: $0) } }
    var nextOpenDate: Date? { nextOpenAt.map { Date(timeIntervalSince1970: $0) } }
    var breakUntilDate: Date? { breakUntil.map { Date(timeIntervalSince1970: $0) } }
}

@MainActor
enum MarketCatalog {
    /// 预置市场（Rust 的封闭表）。
    static let all: [MarketDefinition] = RustCore.invoke("markets.catalog", CoreJSON.object([:]))

    static func market(id: String) -> MarketDefinition? { all.first { $0.id == id } }
}

/// 休市日：规则在 Rust，农历与分点由这里问系统。这里不留缓存：一个市场一年的表由用它的那一页记住（`MarketMemo`）。
@MainActor
enum MarketHolidays {
    static func list(set: String, year: Int) -> [MarketHoliday] {
        struct Anchors: Encodable {
            let lunarNewYear: String?
            let midAutumn: String?
            let dragonBoat: String?
            let qingming: String?
            let marchEquinox: String?
            let septemberEquinox: String?
        }
        struct Input: Encodable { let set: String; let year: Int; let anchors: Anchors }
        // 只有用得上的规则才去问农历与分点（农历要逐日翻一年）。
        let lunar = set == "cn" || set == "hk"
        let anchors = Anchors(lunarNewYear: lunar ? lunarDate(year: year, month: 1, day: 1) : nil,
                              midAutumn: lunar ? lunarDate(year: year, month: 8, day: 15) : nil,
                              dragonBoat: lunar ? lunarDate(year: year, month: 5, day: 5) : nil,
                              qingming: lunar ? qingming(year: year) : nil,
                              marchEquinox: set == "jp" ? equinox(year: year, march: true) : nil,
                              septemberEquinox: set == "jp" ? equinox(year: year, march: false) : nil)
        return RustCore.invoke("markets.holidays", Input(set: set, year: year, anchors: anchors))
    }

    /// 农历某月某日在这一年的公历日期：问 Foundation 的农历（ICU 的中国农历，含闰月规则）。
    /// 农历年跨公历年，所以从这一年的 1 月 1 日往后找第一次命中。
    static func lunarDate(year: Int, month: Int, day: Int) -> String? {
        var chinese = Calendar(identifier: .chinese)
        chinese.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .gmt
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = chinese.timeZone
        guard let start = gregorian.date(from: DateComponents(year: year, month: 1, day: 1)) else { return nil }
        var cursor = start
        for _ in 0..<400 {
            let parts = chinese.dateComponents([.month, .day, .isLeapMonth], from: cursor)
            if parts.month == month, parts.day == day, parts.isLeapMonth != true {
                let civil = gregorian.dateComponents([.year, .month, .day], from: cursor)
                guard let y = civil.year, y == year, let m = civil.month, let d = civil.day else { return nil }
                return String(format: "%04d-%02d-%02d", y, m, d)
            }
            guard let next = gregorian.date(byAdding: .day, value: 1, to: cursor) else { return nil }
            cursor = next
        }
        return nil
    }

    /// 清明：太阳到黄经 15° 的那一天（公历 4 月 4–6 日）。用天文模块的节气入口。
    static func qingming(year: Int) -> String? {
        AstronomyStore.solarTermDate(year: year, longitude: 15, timeZoneID: "Asia/Shanghai")
    }

    /// 春分 / 秋分（日本的春分の日 / 秋分の日 就是这两天，按东京的民用日）。
    static func equinox(year: Int, march: Bool) -> String? {
        AstronomyStore.solarTermDate(year: year, longitude: march ? 0 : 180, timeZoneID: "Asia/Tokyo")
    }
}

/// 市场时钟的计算：某一刻每个市场的状态与下一次变化。`refresh(now:)` 是给测试与快捷入口的一次性快照；
/// 页面不用它，页面用 `MarketMemo`（跟着视图走）。
@MainActor
@Observable
final class MarketStore {
    /// 往后看几天的时段（够覆盖长假：中国春节连休一周多）。
    static let horizonDays = 16

    struct Row: Identifiable, Sendable, Hashable {
        let market: MarketDefinition
        let status: MarketStatus
        /// 该市场当地的今天是不是休市日（是的话给名字键）。
        let todayHolidayKey: String?
        /// 下一个休市日（日期字符串 + 名字键）；没收录休市日时为 nil。
        let nextHoliday: MarketHoliday?
        /// 昨天起 `horizonDays` 天里的交易时段（轴上画的那几段）。
        let spans: [DateInterval]
        var id: String { market.id }
    }

    private(set) var rows: [Row] = []

    func refresh(now: Date) {
        rows = MarketCatalog.all.map { market in
            let holidays = market.hasHolidays ? Self.holidays(for: market, around: now) : []
            return Self.row(market, at: now, holidays: holidays, spans: Self.spans(for: market, from: now, holidays: holidays))
        }
    }

    /// 一个市场在某一刻：状态（含当地日，分得清哪一种关）、今天是不是休市日、下一个休市日。
    static func row(_ market: MarketDefinition, at date: Date, holidays: [MarketHoliday], spans: [DateInterval]) -> Row {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = market.timeZone
        let day = calendar.dateInterval(of: .day, for: date)
        struct Span: Encodable { let start: Double; let end: Double }
        struct Input: Encodable { let now: Double; let spans: [Span]; let dayStart: Double?; let dayEnd: Double? }
        let status: MarketStatus = RustCore.invoke(
            "markets.status",
            Input(now: date.timeIntervalSince1970,
                  spans: spans.map { Span(start: $0.start.timeIntervalSince1970, end: $0.end.timeIntervalSince1970) },
                  dayStart: day?.start.timeIntervalSince1970, dayEnd: day?.end.timeIntervalSince1970))
        let today = civilDate(date, in: market.timeZone)
        return Row(market: market, status: status,
                   todayHolidayKey: holidays.first { $0.date == today }?.nameKey,
                   nextHoliday: holidays.first { $0.date > today },
                   spans: spans)
    }

    /// 该市场从 `from` 前一天起 `horizonDays` 天里的交易时段（跳过周末与休市日；按当地墙钟造真实时刻，所以跨换钟也对）。
    static func spans(for market: MarketDefinition, from now: Date) -> [DateInterval] {
        spans(for: market, from: now, holidays: market.hasHolidays ? holidays(for: market, around: now) : [])
    }

    static func spans(for market: MarketDefinition, from now: Date, holidays list: [MarketHoliday]) -> [DateInterval] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = market.timeZone
        let holidays = Set(list.map(\.date))
        var out: [DateInterval] = []
        // 从昨天开始：现在可能落在昨天开始、今天才结束的时段里（悉尼那种早开的市场跨不到，但便宜）。
        guard let first = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)) else { return [] }
        for offset in 0...(horizonDays + 1) {
            guard let day = calendar.date(byAdding: .day, value: offset, to: first) else { break }
            if calendar.isDateInWeekend(day) { continue }
            if holidays.contains(civilDate(day, in: market.timeZone)) { continue }
            let midnight = calendar.startOfDay(for: day)
            for session in market.sessions {
                guard let start = calendar.date(byAdding: .minute, value: session.startMinute, to: midnight),
                      let end = calendar.date(byAdding: .minute, value: session.endMinute, to: midnight),
                      end > start
                else { continue }
                out.append(DateInterval(start: start, end: end))
            }
        }
        return out.sorted { $0.start < $1.start }
    }

    /// 这一年与下一年的休市日（跨年时也要有下一年的头几天）。
    static func holidays(for market: MarketDefinition, around date: Date,
                         list: @MainActor (String, Int) -> [MarketHoliday] = MarketHolidays.list) -> [MarketHoliday] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = market.timeZone
        let year = calendar.component(.year, from: date)
        return (list(market.holidaySet, year) + list(market.holidaySet, year + 1)).sorted { $0.date < $1.date }
    }

    static func civilDate(_ date: Date, in zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

/// 页面那一份：休市日表每个规则每年只算一次，交易时段按「看的那一刻在当地是哪一天」算一次，状态按分钟算一次。
/// 跟着视图走（`@State`），工具窗关了就没了；不留全局缓存。
@MainActor
final class MarketMemo {
    private var holidayTables: [String: [MarketHoliday]] = [:]
    private var spanTables: [String: [DateInterval]] = [:]
    private var key: (minute: Int, markets: [String])?
    private(set) var rows: [MarketStore.Row] = []

    func rows(at date: Date, markets: [MarketDefinition]) -> [MarketStore.Row] {
        let minute = Int(date.timeIntervalSince1970 / 60)
        let ids = markets.map(\.id)
        if let key, key.minute == minute, key.markets == ids { return rows }
        key = (minute, ids)
        rows = markets.map { market in
            let holidays = market.hasHolidays ? MarketStore.holidays(for: market, around: date, list: table) : []
            let day = MarketStore.civilDate(date, in: market.timeZone)
            let spanKey = "\(market.id)@\(day)"
            let spans: [DateInterval]
            if let cached = spanTables[spanKey] {
                spans = cached
            } else {
                if spanTables.count >= 64 { spanTables.removeAll(keepingCapacity: true) }
                spans = MarketStore.spans(for: market, from: date, holidays: holidays)
                spanTables[spanKey] = spans
            }
            return MarketStore.row(market, at: date, holidays: holidays, spans: spans)
        }
        return rows
    }

    private func table(_ set: String, _ year: Int) -> [MarketHoliday] {
        let key = "\(set)-\(year)"
        if let cached = holidayTables[key] { return cached }
        let list = MarketHolidays.list(set: set, year: year)
        holidayTables[key] = list
        return list
    }
}
