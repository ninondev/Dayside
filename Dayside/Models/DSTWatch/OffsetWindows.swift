// SPDX-License-Identifier: GPL-3.0-only
//
//  OffsetWindows.swift
//  Dayside
//
//  各地与本机的「时差变化窗口」：两地不在同一天换钟时，时差会在中间几天变成另一个数。
//  Foundation 只回答「这个时区下一次换钟在什么时候、换成多少」；比较与分段在 Rust `offsetwindows.compute`。
//

import Foundation

nonisolated struct OffsetChange: Decodable, Equatable, Identifiable, Sendable {
    let at: Double
    let from: Int
    let to: Int
    /// `local` 本机换钟、`place` 对方换钟、`both` 同一刻都换（时差仍变时才会出现）。
    let cause: String
    var id: Double { at }
    var date: Date { Date(timeIntervalSince1970: at) }
}

nonisolated struct OffsetPlaceReport: Decodable, Equatable, Identifiable, Sendable {
    let zone: String
    let diffNow: Int
    let changes: [OffsetChange]
    var id: String { zone }
}

nonisolated enum OffsetWindows {
    private struct Transition: Encodable { let at: Double; let after: Int }
    private struct Timeline: Encodable { let zone: String; let offsetNow: Int; let transitions: [Transition] }
    private struct Input: Encodable { let now: Double; let horizonDays: Int; let local: Timeline; let places: [Timeline] }
    private struct Output: Decodable { let places: [OffsetPlaceReport] }

    static let horizonDays = 365

    private static func timeline(_ identifier: String, now: Date) -> Timeline? {
        guard let zone = TimeZone(identifier: identifier) else { return nil }
        let end = now.addingTimeInterval(Double(horizonDays) * 86_400)
        var transitions: [Transition] = []
        var cursor = now
        for _ in 0..<16 {
            guard let next = zone.nextDaylightSavingTimeTransition(after: cursor), next > cursor, next <= end else { break }
            // 偏移没变的转换不进时间线（摩洛哥斋月只翻 isDST）：
            // 时差分段本来就按偏移算，加进来只会多出两段一样的。
            let after = zone.secondsFromGMT(for: next)
            if after != zone.secondsFromGMT(for: next.addingTimeInterval(-1)) {
                transitions.append(Transition(at: next.timeIntervalSince1970, after: after))
            }
            cursor = next
        }
        return Timeline(zone: identifier, offsetNow: zone.secondsFromGMT(for: now), transitions: transitions)
    }

    /// 本机 vs 每个地点；同一时区去重，本机自己的时区不列（时差恒为 0）。
    static func reports(localZone: String = TimeZone.current.identifier, places: [String], now: Date) -> [OffsetPlaceReport] {
        guard let local = timeline(localZone, now: now) else { return [] }
        var seen: Set<String> = [localZone]
        let timelines = places.filter { seen.insert($0).inserted }.compactMap { timeline($0, now: now) }
        guard !timelines.isEmpty else { return [] }
        let out: Output = RustCore.invoke("offsetwindows.compute", Input(now: now.timeIntervalSince1970, horizonDays: horizonDays, local: local, places: timelines))
        return out.places
    }
}
