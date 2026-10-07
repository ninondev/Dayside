// SPDX-License-Identifier: GPL-3.0-only
//
//  TravelFixedTimes.swift
//  TahoeTime
//
//  旅行页的三样产出：
//  ①「固定时刻」——每天固定要做的事（吃药、和家里通话、打卡…）在行程期间落在当地几点，**只换算**；
//  ②一行可复制的状态文本（地点 · 时区 · 我的工作时段 = 家里看到的时段）；
//  ③行程期间「不工作」的 .ics 阻塞事件。
//  这里只做 Apple 框架那部分：用 Foundation 在两个时区之间换算真实日期。拼法、分段、校验在 Rust
//  （`travel.fixed_times` / `travel.status_line`）。
//

import Foundation

/// 设置里存的一条固定时刻：名字 + 出发地（家）的墙钟分钟。规则在 Rust `travel.fixed_time_list`。
/// Rust 给的换算结果。
struct TravelFixedTimeRows: Decodable, Sendable {
    struct Segment: Decodable, Sendable, Hashable {
        let fromDate: String
        let toDate: String
        let minute: Int
        let dayOffset: Int
        /// 当地钟点落在 22:00–06:00：只是陈述事实，不劝人改时间。
        let night: Bool
        let days: Int
    }
    struct Row: Decodable, Sendable, Identifiable, Hashable {
        let id: UUID
        let label: String
        let homeMinute: Int
        let segments: [Segment]
    }
    let rows: [Row]
    let dropped: Int
}

enum TravelFixedTimeConverter {
    /// 行程期间看几天（一周：覆盖每周的安排，也能看出这期间的换钟）。
    static let days = 7

    /// 只用来把两地的「年月日」当成日期来数天数，不做任何时区换算。
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    /// 把每条固定时刻在「到达日起的 N 天」里逐日换算到目的地时区。
    ///
    /// 锚点是**家里的墙钟**：「每天 8:00 吃药」说的是家里那个 8:00，所以先在出发地时区造出那一刻，
    /// 再问目的地时区它是几点、跨没跨日。两边都用真实日期，所以任一侧换钟都算得对。
    static func rows(times: [TravelFixedTime], trip: TravelTrip) -> TravelFixedTimeRows {
        guard let origin = TimeZone(identifier: trip.originTimeZoneID),
              let destination = TimeZone(identifier: trip.destinationTimeZoneID), !times.isEmpty
        else { return TravelFixedTimeRows(rows: [], dropped: 0) }
        var home = Calendar(identifier: .gregorian)
        home.timeZone = origin
        var there = Calendar(identifier: .gregorian)
        there.timeZone = destination
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = origin
        formatter.dateFormat = "yyyy-MM-dd"

        struct Day: Encodable { let date: String; let minute: Int; let dayOffset: Int }
        struct Entry: Encodable { let id: UUID; let label: String; let minute: Int }
        struct Input: Encodable { let times: [Entry]; let converted: [[Day]] }

        let converted: [[Day]] = times.map { time in
            (0..<days).compactMap { offset -> Day? in
                guard let day = home.date(byAdding: .day, value: offset, to: trip.arrival),
                      let moment = home.date(bySettingHour: time.minute / 60,
                                              minute: time.minute % 60, second: 0, of: day)
                else { return nil }
                let parts = there.dateComponents([.hour, .minute], from: moment)
                guard let hour = parts.hour, let minute = parts.minute else { return nil }
                // 跨日按两地的**民用日**比较：把两边的年月日搬进同一个 UTC 日历再数天数。
                // 别拿两个 startOfDay 的时刻相减——那是两个瞬间，差不到 24 小时就算 0 天
                // （洛杉矶 8:00 = 东京次日 0:00，两个午夜只差 8 小时，第一版就漏了「次日」）。
                let homeParts = home.dateComponents([.year, .month, .day], from: moment)
                let thereParts = there.dateComponents([.year, .month, .day], from: moment)
                guard let homeCivil = Self.utc.date(from: homeParts),
                      let thereCivil = Self.utc.date(from: thereParts)
                else { return nil }
                let dayOffset = Self.utc.dateComponents([.day], from: homeCivil, to: thereCivil).day ?? 0
                return Day(date: formatter.string(from: moment), minute: hour * 60 + minute,
                           dayOffset: max(-1, min(1, dayOffset)))
            }
        }
        let input = Input(times: times.map { Entry(id: $0.id, label: $0.label, minute: $0.minute) },
                          converted: converted)
        return RustCore.invoke("travel.fixed_times", input)
    }
}

/// 一行可复制的状态文本。
struct TravelStatusLine: Sendable {
    let text: String
    let parts: [String]

    static func make(place: String, zoneAbbreviation: String, offsetText: String,
                     localWindowText: String, counterpartWindowText: String, locale: Locale = .current) -> TravelStatusLine {
        struct Segments: Codable {
            let place: String
            let zoneAbbreviation: String
            let offsetText: String
            let localWindowText: String
            let counterpartWindowText: String
        }
        let result: Segments = RustCore.invoke("travel.status_line", Segments(place: place,
            zoneAbbreviation: zoneAbbreviation, offsetText: offsetText, localWindowText: localWindowText,
            counterpartWindowText: counterpartWindowText))
        guard !result.place.isEmpty else { return .init(text: "", parts: []) }
        let zone = result.zoneAbbreviation.isEmpty ? result.offsetText : result.offsetText.isEmpty ? result.zoneAbbreviation :
            String(format: L10n.string("%1$@（%2$@）", locale: locale), result.zoneAbbreviation, result.offsetText)
        var window = result.localWindowText
        if !result.counterpartWindowText.isEmpty {
            window = String(format: L10n.string("%1$@（%2$@）", locale: locale), window, result.counterpartWindowText)
        }
        let parts = [result.place, zone, window].filter { !$0.isEmpty }
        return .init(text: parts.joined(separator: " · "), parts: parts)
    }
}

/// 行程期间「不工作」的阻塞事件：把工作时段之外的时间做成日历事件，
/// 同事的日历上就能看见「这几天这些时候找不到我」。时段规则在 Rust `travel.away_blocks`，
/// 这里只把目的地的墙钟分钟变成真实时刻（当地周末按该地区的 ICU 数据判，与排会页同一出口）。
@MainActor
enum TravelAwayBlocks {
    /// 阻塞几天（与固定时刻同一个窗口：到达日起一周）。
    static var days: Int { TravelFixedTimeConverter.days }

    struct Block: Decodable, Sendable {
        let date: String
        let startMinute: Int
        let endMinute: Int
        let wholeDay: Bool
    }
    private struct Blocks: Decodable { let blocks: [Block] }

    static func events(trip: TravelTrip, availability: Availability, placeName: String,
                       countryCode: String?, locale: Locale, footer: String) -> [MeetingEvent] {
        guard let destination = TimeZone(identifier: trip.destinationTimeZoneID) else { return [] }
        let calendar = OverlapPlanner.calendar(for: destination, countryCode: countryCode)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = destination
        formatter.dateFormat = "yyyy-MM-dd"

        struct Day: Encodable { let date: String; let weekend: Bool }
        struct Input: Encodable { let startMinute: Int; let endMinute: Int; let days: [Day] }
        var starts: [String: Date] = [:]
        let days: [Day] = (0..<Self.days).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: trip.arrival) else { return nil }
            let key = formatter.string(from: day)
            starts[key] = calendar.startOfDay(for: day)
            return Day(date: key, weekend: calendar.isDateInWeekend(day))
        }
        let result: Blocks = RustCore.invoke("travel.away_blocks",
                                             Input(startMinute: availability.startMinute,
                                                   endMinute: availability.endMinute, days: days))
        let title = String(format: L10n.string("不工作（%@）", locale: locale), placeName)
        return result.blocks.compactMap { block -> MeetingEvent? in
            guard let midnight = starts[block.date],
                  let start = calendar.date(byAdding: .minute, value: block.startMinute, to: midnight),
                  let end = calendar.date(byAdding: .minute, value: block.endMinute, to: midnight),
                  end > start
            else { return nil }
            return MeetingEvent(title: title, start: start, end: end,
                                lines: [.init(name: placeName,
                                              text: ClockText.interval(from: start, to: end, in: destination,
                                                                       hourStyle: .followSystem, locale: locale))],
                                footer: footer)
        }
    }
}
