// SPDX-License-Identifier: GPL-3.0-only
//
//  SchedulingCore.swift
//  TahoeTime
//
//  `OverlapPlanner` 的基础模型与区间投影：
//  一个人是谁（所在时区、作息、工作日、休假）、他的作息在真实日历上落成哪些区间、
//  某地某天算不算周末。面板「现在能打给谁」排序、分享页的可约时段、
//  地点可约性判断、夏令时提醒的换钟进日历都要。
//
//  「N 个人的重叠搜索、例会轮换、拆场」在 `Models/Planner/OverlapPlanner.swift`，
//  那边是本文件的 `extension`；本文件不引用它，反过来可以。
//
//  时间层的三条硬规矩照旧（与 Solar 的 DST 修正同源）：可约时段按**墙钟**落到真实时刻并按偏移
//  换轨点分段投影（不能用 startOfDay + 秒数）；周末按该地国家 / 地区的 ICU 数据（以色列周五六、
//  印度周日、阿富汗周四五），不知道国家就按周六日。
//

import Foundation

enum OverlapPlanner: Sendable {

    struct Participant: Hashable, Sendable {
        let id: UUID
        let name: String
        let timeZoneID: String
        let availability: Availability
        /// ISO 3166-1 alpha-2;nil = 周末按周六日。
        let countryCode: String?

        /// nil retains the region's weekend rule; explicit days belong to the shift's start date.
        var workingWeekdays: [Int]? = nil
        var vacations: [Vacation] = []
        /// 昼夜条要的经纬度；nil = 没有坐标，条上只有底色，不拿别处的坐标冒充。
        var coordinate: Coordinate? = nil
        /// 地点的时区显示规则随参与者保留，生成日历说明时不能只剩共享的时区 ID。
        var offsetOnlyZoneName = false

        var timeZone: TimeZone { TimeZone(identifier: timeZoneID) ?? .gmt }
    }

    struct Vacation: Codable, Hashable, Sendable {
        let startDate: String
        let endDate: String
    }

    // MARK: - 输出

    /// 某个候选开始时刻下,一位参与者的处境。
    enum Fit: Hashable, Sendable {
        /// 整场都在可约时段内。
        case inside
        /// 有部分在时段外:`outsideMinutes` 是超出时段边缘的分钟数(开始前或结束后取大者)。
        case stretched(outsideMinutes: Int)
        /// 当天休息(周末)或距离时段太远,无法折中。
        case unavailable
    }

    static func availabilityIntervals(for participant: Participant, coveringFrom from: Date, to: Date) -> [DateInterval] {
        let input = Schedule(availability: participant.availability, workingWeekdays: participant.workingWeekdays,
                             vacations: participant.vacations, calendar: facts(calendar(for: participant.timeZone, countryCode: participant.countryCode),
                                             from: from, through: to))
        return RustCore.invoke("availability.intervals", input, as: [IntervalOutput].self).map {
            DateInterval(start: Date(timeIntervalSince1970: $0.start), end: Date(timeIntervalSince1970: $0.end))
        }
    }

    struct OffsetSegment: Encodable {
        let start: Double
        let end: Double
        let offsetSeconds: Int
    }

    struct DayFacts: Encodable {
        let start: Double
        let end: Double
        let wallDay: Double
        let weekend: Bool
        let weekday: Int
        let date: String
        let segments: [OffsetSegment]
    }

    struct CalendarFacts: Encodable {
        let days: [DayFacts]
        let anchorCount: Int
    }

    struct Schedule: Encodable {
        let availability: Availability
        let workingWeekdays: [Int]?
        let vacations: [Vacation]
        let calendar: CalendarFacts
    }

    struct IntervalOutput: Decodable {
        let start: Double
        let end: Double
    }

    /// Snapshot the system Calendar/ICU/tzdb once per day and transition, never once per candidate slot.
    /// Include one successor day so Rust can project a final overnight shift without another FFI call.
    static func facts(_ calendar: Calendar, from: Date, through: Date) -> CalendarFacts {
        var days: [DayFacts] = []
        var day = calendar.startOfDay(for: from)
        while day <= through {
            guard let value = dayFacts(day, calendar: calendar), value.end > day.timeIntervalSince1970 else { break }
            days.append(value)
            day = Date(timeIntervalSince1970: value.end)
        }
        let anchorCount = days.count
        if anchorCount > 0, let successor = dayFacts(day, calendar: calendar) { days.append(successor) }
        return CalendarFacts(days: days, anchorCount: anchorCount)
    }

    static func dayFacts(_ day: Date, calendar: Calendar) -> DayFacts? {
        guard let nextDay = calendar.dateInterval(of: .day, for: day)?.end else { return nil }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        guard let wallDay = utc.date(from: calendar.dateComponents([.year, .month, .day], from: day)) else { return nil }
        var segmentStart = day
        var segments: [OffsetSegment] = []
        while segmentStart < nextDay {
            let transition = calendar.timeZone.nextDaylightSavingTimeTransition(after: segmentStart)
            let segmentEnd = transition.map { min($0, nextDay) } ?? nextDay
            guard segmentEnd > segmentStart else { break }
            segments.append(OffsetSegment(start: segmentStart.timeIntervalSince1970,
                                          end: segmentEnd.timeIntervalSince1970,
                                          offsetSeconds: calendar.timeZone.secondsFromGMT(for: segmentStart)))
            segmentStart = segmentEnd
        }
        return DayFacts(start: day.timeIntervalSince1970, end: nextDay.timeIntervalSince1970,
                        wallDay: wallDay.timeIntervalSince1970, weekend: calendar.isDateInWeekend(day),
                        weekday: calendar.component(.weekday, from: day),
                        date: String(format: "%04d-%02d-%02d", calendar.component(.year, from: day),
                                     calendar.component(.month, from: day), calendar.component(.day, from: day)),
                        segments: segments)
    }

    /// 带时区与地区的公历:`isDateInWeekend` 用 ICU 的地区周末数据。
    static func calendar(for tz: TimeZone, countryCode: String?) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        if let cc = countryCode, cc.count == 2 {
            cal.locale = Locale(identifier: "und_\(cc.uppercased())")
        } else {
            cal.locale = Locale(identifier: "und_US")   // 周六日;不知道国家时的中性默认
        }
        return cal
    }

    /// 某地某天的周末判定(供 UI 与测试)。
    static func isWeekend(_ date: Date, timeZone: TimeZone, countryCode: String?) -> Bool {
        calendar(for: timeZone, countryCode: countryCode).isDateInWeekend(date)
    }
}
