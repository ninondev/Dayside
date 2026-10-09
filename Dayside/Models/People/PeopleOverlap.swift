// SPDX-License-Identifier: GPL-3.0-only
//
//  PeopleOverlap.swift
//  Dayside
//
//  人物页「下一段共同时段」：把本机的工作时段与这个人的工作时段求交，
//  给出接下来 7 天里第一段至少 30 分钟的重叠——人物行一眼看到「今天 9:00–11:00 都方便」。
//  两侧区间都由 Rust `availability.intervals` 算（含休假、周末、跨午夜班次），这里只做求交与挑选。
//

import Foundation

nonisolated struct SharedWindow: Equatable, Sendable {
    let start: Date
    let end: Date
    /// 相对本机今天的天数：0 今天、1 明天、2+ 更远。
    let dayOffset: Int
}

nonisolated enum PeopleOverlap {
    static let lookaheadDays = 7
    static let minimumMinutes = 30

    static func localParticipant(availability: Availability, timeZoneID: String = TimeZone.current.identifier) -> OverlapPlanner.Participant {
        OverlapPlanner.Participant(id: UUID(uuidString: "00000000-0000-0000-0000-00000000C0DE")!, name: "", timeZoneID: timeZoneID,
                                   availability: availability, countryCode: Locale.current.region?.identifier)
    }

    /// 从 `now` 起 7 天里第一段两人都在工作时段内、且至少 30 分钟的重叠；没有就 nil。
    static func nextSharedWindow(person: OverlapPlanner.Participant, local: OverlapPlanner.Participant, now: Date,
                                 days: Int = lookaheadDays, minimumMinutes: Int = minimumMinutes) -> SharedWindow? {
        let from = now.addingTimeInterval(-86_400), to = now.addingTimeInterval(Double(days) * 86_400)
        let mine = OverlapPlanner.availabilityIntervals(for: local, coveringFrom: from, to: to)
        let theirs = OverlapPlanner.availabilityIntervals(for: person, coveringFrom: from, to: to)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = local.timeZone
        let today = calendar.startOfDay(for: now)
        for a in mine {
            for b in theirs {
                let start = max(a.start, b.start, now), end = min(a.end, b.end)
                guard end.timeIntervalSince(start) >= Double(minimumMinutes) * 60 else { continue }
                let dayOffset = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: start)).day ?? 0
                return SharedWindow(start: start, end: end, dayOffset: dayOffset)
            }
        }
        return nil
    }
}

/// 「每工作日重叠多久」与「对方下班 = 我几点」（调研 #6）。人物页与排会页用同一个数字。
nonisolated struct OverlapSummary: Equatable, Sendable {
    /// 两边那天都要上班的日子里，重叠分钟数的中位数；一天都没有就 nil。
    let typicalMinutes: Int?
    let minMinutes: Int?
    let maxMinutes: Int?
    /// 统计了几个「两边都上班」的日子。
    let workdays: Int
    /// 对方下一段还没结束的工作时段的结束时刻（本机怎么显示由视图定）。
    let theirDayEnd: Date?

    var isUniform: Bool { minMinutes == maxMinutes }
}

extension PeopleOverlap {
    /// 接下来 `days` 天的重叠汇总。区间两侧都由 Rust `availability.intervals` 算（含休假、周末、跨午夜班次），
    /// 日界由 Foundation 按**本机**时区给（日界是日历事实），统计与挑选的规则在 Rust `people.overlap_summary`。
    static func summary(person: OverlapPlanner.Participant, local: OverlapPlanner.Participant, now: Date,
                        days: Int = lookaheadDays) -> OverlapSummary {
        let from = now.addingTimeInterval(-86_400), to = now.addingTimeInterval(Double(days) * 86_400)
        let mine = OverlapPlanner.availabilityIntervals(for: local, coveringFrom: from, to: to)
        let theirs = OverlapPlanner.availabilityIntervals(for: person, coveringFrom: from, to: to)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = local.timeZone
        let today = calendar.startOfDay(for: now)
        // 本机的日界：今天起 days + 1 个，最后一个当右边界。
        let dayStarts = (0...days).compactMap { calendar.date(byAdding: .day, value: $0, to: today)?.timeIntervalSince1970 }
        struct Span: Encodable { let start: Double; let end: Double }
        struct Input: Encodable { let mine: [Span]; let theirs: [Span]; let now: Double; let dayStarts: [Double] }
        struct Output: Decodable {
            let typicalMinutes: Int?
            let minMinutes: Int?
            let maxMinutes: Int?
            let workdays: Int
            let theirDayEnd: Double?
        }
        let spans = { (intervals: [DateInterval]) in
            intervals.map { Span(start: $0.start.timeIntervalSince1970, end: $0.end.timeIntervalSince1970) }
        }
        let output: Output = RustCore.invoke("people.overlap_summary", Input(
            mine: spans(mine), theirs: spans(theirs), now: now.timeIntervalSince1970, dayStarts: dayStarts))
        return OverlapSummary(typicalMinutes: output.typicalMinutes, minMinutes: output.minMinutes,
                              maxMinutes: output.maxMinutes, workdays: output.workdays,
                              theirDayEnd: output.theirDayEnd.map { Date(timeIntervalSince1970: $0) })
    }
}
