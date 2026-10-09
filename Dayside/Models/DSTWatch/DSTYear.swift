// SPDX-License-Identifier: GPL-3.0-only
//
//  DSTYear.swift
//  Dayside
//
//  夏令时提醒页的一年：本机与每个地方从今天起 12 个月的时差，一段一段（时差变了才断开）；哪几段是
//  「两地不在同一天换钟，中间那几天的时差是另一个数」；以及这一年里的每一次换钟、它让谁的时差变成几。
//  Foundation 只回答「这个时区在什么时刻换成多少」（`nextDaylightSavingTimeTransition`），分段、来历与并成一次
//  都在 Rust `offsetwindows.year`。本文件不带任何时区规则。
//

import Foundation

nonisolated struct DSTYear: Decodable, Equatable, Sendable {
    struct Segment: Decodable, Equatable, Sendable {
        let from: Double
        let to: Double
        /// 本机那一行是本机的 UTC 偏移，其余各行是与本机的时差（对方减本机），都按秒。
        let value: Int
        /// 两地不在同一天换钟、中间那几天的时差：一头是本机换钟，另一头是对方换钟。
        let between: Bool
    }
    struct Transition: Decodable, Equatable, Sendable {
        let at: Double
        let before: Int
        let after: Int
    }
    struct Row: Decodable, Equatable, Sendable {
        let zone: String
        let segments: [Segment]
        /// 这个时区自己的换钟（框里的）。
        let transitions: [Transition]

        /// 某一刻落在哪一段（框外钉在两头）。
        func segment(at date: Date) -> Segment? {
            let t = date.timeIntervalSince1970
            return segments.first { $0.from <= t && t < $0.to } ?? (t < (segments.first?.from ?? 0) ? segments.first : segments.last)
        }
    }
    /// 同一刻、拨同样多的几个地方并成一次换钟。`effects` 是这一次让哪些地方与本机的时差从几变成几。
    struct Change: Decodable, Equatable, Sendable, Identifiable {
        struct Member: Decodable, Equatable, Sendable {
            let zone: String
            let local: Bool
            let before: Int
            let after: Int
        }
        struct Effect: Decodable, Equatable, Sendable {
            let zone: String
            let from: Int
            let to: Int
        }
        let at: Double
        let shift: Int
        let members: [Member]
        let effects: [Effect]
        var id: String { "\(Int(at))/\(shift)" }
        var date: Date { Date(timeIntervalSince1970: at) }
    }

    let local: Row
    let places: [Row]
    let changes: [Change]

    /// 有没有哪一行有「两地错开的那几天」（图例只在有时才列）。
    var hasWindows: Bool { places.contains { row in row.segments.contains(where: \.between) } }

    // MARK: - 怎么算

    /// 看的框：从看的那一刻所在的本机那一天起，往后 12 个月。看的那一刻在今天之前或一年以后时，框跟着它走（与页首天色带
    /// 超出 ±12 小时改画那一刻前后的天是同一个办法），否则从今天起。
    static func frame(now: Date, reference: Date, timeZone: TimeZone = .current) -> DateInterval {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = calendar.startOfDay(for: now)
        let todayEnd = calendar.date(byAdding: .month, value: 12, to: today) ?? today.addingTimeInterval(365 * 86_400)
        let start = reference < today || reference >= todayEnd ? calendar.startOfDay(for: reference) : today
        let end = calendar.date(byAdding: .month, value: 12, to: start) ?? start.addingTimeInterval(365 * 86_400)
        return DateInterval(start: start, end: end)
    }

    private struct Transport: Encodable { let at: Double; let after: Int }
    private struct Timeline: Encodable { let zone: String; let offset: Int; let transitions: [Transport] }
    private struct Input: Encodable {
        let start: Double
        let end: Double
        let origin: Double
        let horizon: Double
        let local: Timeline
        let places: [Timeline]
    }

    /// 问每个时区框前后各 400 天里的换钟，交给 Rust 分段。框头一段与最后一段的来历在框外，所以要多问那一截。
    static func compute(frame: DateInterval, local: String, places: [String]) -> DSTYear? {
        let origin = frame.start.addingTimeInterval(-400 * 86_400)
        let horizon = frame.end.addingTimeInterval(400 * 86_400)
        guard let home = timeline(local, origin: origin, horizon: horizon) else { return nil }
        var seen: Set<String> = [local]
        let others = places.filter { seen.insert($0).inserted }.compactMap { timeline($0, origin: origin, horizon: horizon) }
        let input = Input(start: frame.start.timeIntervalSince1970, end: frame.end.timeIntervalSince1970,
                          origin: origin.timeIntervalSince1970, horizon: horizon.timeIntervalSince1970,
                          local: home, places: others)
        return try? RustCore.attempt("offsetwindows.year", input, as: DSTYear.self)
    }

    private static func timeline(_ identifier: String, origin: Date, horizon: Date) -> Timeline? {
        guard let zone = TimeZone(identifier: identifier) else { return nil }
        var transitions: [Transport] = []
        var cursor = origin
        // 三年多里每个时区最多十来次；64 是保险数，也保证时区数据异常时循环有界。
        for _ in 0..<64 {
            guard let next = zone.nextDaylightSavingTimeTransition(after: cursor), next > cursor, next <= horizon else { break }
            let after = zone.secondsFromGMT(for: next)
            // 偏移没变、只翻夏令时标志的转换不是换钟（摩洛哥斋月）：不进时间线。
            if after != zone.secondsFromGMT(for: next.addingTimeInterval(-1)) {
                transitions.append(Transport(at: next.timeIntervalSince1970, after: after))
            }
            cursor = next
        }
        return Timeline(zone: identifier, offset: zone.secondsFromGMT(for: origin), transitions: transitions)
    }
}

/// 一年只在框、地点或系统时区数据变了时去 Rust 算一次；点一下、走一分钟、拖时间都只是框里的位置。
/// 跟着视图走（`@State`），工具窗关了就没了。
@MainActor
final class DSTYearMemo {
    private struct Key: Equatable {
        let start: Date
        let local: String
        let places: [String]
        let revision: Int
    }
    private var key: Key?
    private(set) var year: DSTYear?
    /// 真去 Rust 算过几次（测试用）。
    private(set) var computations = 0

    func update(frame: DateInterval, local: String, places: [String], revision: Int) {
        let next = Key(start: frame.start, local: local, places: places, revision: revision)
        guard next != key else { return }
        key = next
        computations += 1
        year = DSTYear.compute(frame: frame, local: local, places: places)
    }
}
