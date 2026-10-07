// SPDX-License-Identifier: GPL-3.0-only
//
//  OverlapPlanner.swift
//  TahoeTime
//
//  重叠规划器:N 个地点各自的可约时段 → 未来几天里所有人都合适的
//  碰头窗口,按舒适度排序;找不到完全重叠时给出「折中」窗口(有人在时段外但不超过两小时)。
//
//  纯函数、nonisolated、Sendable(仿 Solar / TimeFormatting):输入是值拷贝,不碰任何共享状态,
//  没有定时器、没有观察者——这是透镜的资源契约,规划器只在面板里展开时被调用。
//
//  时间层的三条硬规矩(与 Solar 的 DST 修正同源):
//  ① 可约时段按**墙钟**落到真实时刻,按偏移换轨点分段投影;跳过不存在的时刻,保留回拨后的重复时刻。
//     不能用 startOfDay + 秒数,也不能只选择重复墙钟的第一次出现。
//  ② 候选时刻走 UTC 的 15 分钟网格:所有 IANA 偏移都是 15 分钟的整数倍(加德满都 +5:45、
//     加尔各答 +5:30、查塔姆 +12:45),网格对每个地点都落在整刻上。
//  ③ 周末按该地国家/地区的 ICU 数据(以色列周五六、印度周日、阿富汗周四五);
//     不知道国家就按周六日。周末整天不可约,**不参与折中**(折中只针对「几点」,不针对「哪天」)。
//

import Foundation

extension OverlapPlanner {
    struct Request: Hashable, Sendable {
        var participants: [Participant]
        /// 搜索起点(通常是「现在」或穿梭到的日期)。早于它的候选一律不出。
        var from: Date
        /// 从 `from` 所在的**本机日**起往后看几天(1 = 只看当天)。
        var days: Int
        /// 会议时长(分钟)。
        var durationMinutes: Int
        /// 本机时区(决定「天」怎么切、结果按哪个钟显示)。
        var localTimeZoneID: String
        /// 折中容忍:在时段外最多多少分钟(超出即不出现在折中里)。
        var toleranceMinutes: Int = 120
        /// 最多返回多少个窗口。
        var limit: Int = 8
        /// 理想时段：起点落在里面的候选同档内排前面，不改结论。
        var idealWindow: IdealWindow? = nil

        var localTimeZone: TimeZone { TimeZone(identifier: localTimeZoneID) ?? .current }
    }

    struct ParticipantFit: Hashable, Sendable {
        let participant: Participant
        let fit: Fit
        /// 该开始时刻在参与者本地的墙钟(便于 UI 直接显示)。
        let localStart: Date
    }

    /// 一个碰头窗口:`start ..< end` 是「开始时刻可以落在其中任何一刻」的连续区间的外延——
    /// 即从最早可开始到最晚可结束;`best` 是其中最舒适的开始时刻。
    struct Window: Hashable, Sendable, Identifiable {
        enum Tier: Int, Hashable, Sendable { case everyone = 0, compromise = 1 }
        let tier: Tier
        let start: Date
        let end: Date
        let best: Date
        let durationMinutes: Int
        let score: Double
        /// `best` 时刻各参与者的处境(顺序同请求)。
        let fits: [ParticipantFit]

        var id: Date { best }
        var bestEnd: Date { best.addingTimeInterval(TimeInterval(durationMinutes * 60)) }
        /// 折中时在时段外的人。
        var stretched: [Participant] {
            fits.compactMap { if case .stretched = $0.fit { return $0.participant } else { return nil } }
        }
    }

    struct Result: Hashable, Sendable {
        let windows: [Window]
        var everyone: [Window] { windows.filter { $0.tier == .everyone } }
        var compromises: [Window] { windows.filter { $0.tier == .compromise } }
    }

    // MARK: - Rust adapter
    static let stepMinutes = 15

    /// Foundation supplies civil-day and timezone facts in one batch. Rust owns every scheduling decision.
    static func plan(_ request: Request) -> Result {
        let localCal = calendar(for: request.localTimeZone, countryCode: nil)
        let dayStart = localCal.startOfDay(for: request.from)
        let days = max(1, request.days)
        guard let finalDay = localCal.date(byAdding: .day, value: days, to: dayStart) else {
            return Result(windows: [])
        }
        let rangeEnd = localCal.startOfDay(for: finalDay)
        let schedules = request.participants.map { participant in
            Schedule(availability: participant.availability, workingWeekdays: participant.workingWeekdays,
                     vacations: participant.vacations, calendar: facts(calendar(for: participant.timeZone, countryCode: participant.countryCode),
                                     from: dayStart.addingTimeInterval(-86_400),
                                     through: rangeEnd.addingTimeInterval(86_400)))
        }
        let input = PlanInput(participants: schedules, from: request.from.timeIntervalSince1970,
                              rangeEnd: rangeEnd.timeIntervalSince1970, durationMinutes: request.durationMinutes,
                              toleranceMinutes: request.toleranceMinutes, limit: request.limit,
                              localCalendar: facts(localCal, from: dayStart, through: rangeEnd),
                              scoringDayStarts: (0...days).compactMap {
                                  localCal.date(byAdding: .day, value: $0, to: dayStart)?.timeIntervalSince1970
                              },
                              idealStartMinute: request.idealWindow?.startMinute, idealEndMinute: request.idealWindow?.endMinute)
        let windows = RustCore.invoke("planner.plan", input, as: [WindowOutput].self)
        return Result(windows: windows.map { window($0, participants: request.participants) })
    }

    // MARK: - 找碰头时间页的候选单

    /// 页面上的一项：大家都在时段内的一个本机钟点（几天并成一项），或最接近的一种「谁让一点」的分法。
    /// `days` 是同一个本机钟点、同一批人在付的各天的开始时刻（含 `best`，从早到晚）。
    struct Option: Hashable, Sendable, Identifiable {
        let tier: Window.Tier
        let start: Date
        let end: Date
        let best: Date
        let durationMinutes: Int
        let score: Double
        let fits: [ParticipantFit]
        /// 各人按当地钟点折合的时段外分钟（在时段内为 0），顺序同参与者。
        let cost: [Int]
        let days: [Date]
        var id: Date { best }
        var bestEnd: Date { best.addingTimeInterval(TimeInterval(durationMinutes * 60)) }
        /// 在这一天开的那一场（`day` 是 `days` 里的一个开始时刻；处境与代表的那天同一批人在付）。
        func window(startingAt day: Date) -> Window {
            Window(tier: tier, start: day == best ? start : day, end: day == best ? end : day.addingTimeInterval(TimeInterval(durationMinutes * 60)),
                   best: day, durationMinutes: durationMinutes, score: score,
                   fits: fits.map { ParticipantFit(participant: $0.participant, fit: $0.fit, localStart: day) })
        }
    }

    struct Options: Hashable, Sendable {
        /// true = 几项都是大家都在时段内；false = 没有这样的时刻，下面是最接近的（可能一项都没有：有人休息）。
        let everyone: Bool
        let options: [Option]
    }

    /// 候选单（Rust `planner.options`）：与 `plan` 同一份事实，另给按当地钟点折合负担用的加权（与例会轮换同一个设置）。
    static func options(_ request: Request, clockWeight: String) -> Options {
        let localCal = calendar(for: request.localTimeZone, countryCode: nil)
        let dayStart = localCal.startOfDay(for: request.from)
        let days = max(1, request.days)
        guard let finalDay = localCal.date(byAdding: .day, value: days, to: dayStart) else {
            return Options(everyone: false, options: [])
        }
        let rangeEnd = localCal.startOfDay(for: finalDay)
        let schedules = request.participants.map { participant in
            Schedule(availability: participant.availability, workingWeekdays: participant.workingWeekdays,
                     vacations: participant.vacations, calendar: facts(calendar(for: participant.timeZone, countryCode: participant.countryCode),
                                     from: dayStart.addingTimeInterval(-86_400),
                                     through: rangeEnd.addingTimeInterval(86_400)))
        }
        let input = OptionsInput(participants: schedules, from: request.from.timeIntervalSince1970,
                                 rangeEnd: rangeEnd.timeIntervalSince1970, durationMinutes: request.durationMinutes,
                                 localCalendar: facts(localCal, from: dayStart, through: rangeEnd),
                                 scoringDayStarts: (0...days).compactMap {
                                     localCal.date(byAdding: .day, value: $0, to: dayStart)?.timeIntervalSince1970
                                 },
                                 idealStartMinute: request.idealWindow?.startMinute, idealEndMinute: request.idealWindow?.endMinute,
                                 clockWeight: clockWeight)
        let output = RustCore.invoke("planner.options", input, as: OptionsOutput.self)
        return Options(everyone: output.everyone, options: output.options.map { option in
            Option(tier: Window.Tier(rawValue: option.tier) ?? .compromise,
                   start: Date(timeIntervalSince1970: option.start), end: Date(timeIntervalSince1970: option.end),
                   best: Date(timeIntervalSince1970: option.best), durationMinutes: option.durationMinutes, score: option.score,
                   fits: option.fits.enumerated().compactMap { index, fit in
                       request.participants.indices.contains(index)
                           ? ParticipantFit(participant: request.participants[index], fit: fit.value,
                                            localStart: Date(timeIntervalSince1970: option.best))
                           : nil
                   },
                   cost: option.cost, days: option.days.map { Date(timeIntervalSince1970: $0) })
        })
    }

    /// 试一个时刻（时间轴上点一下）：每人按自己的工作时段区间（`availabilityIntervals` 给的）算处境（Rust `planner.fit`）。
    static func fits(intervals: [[DateInterval]], participants: [Participant], start: Date, durationMinutes: Int) -> [ParticipantFit] {
        struct Span: Encodable { let start: Double; let end: Double }
        struct Input: Encodable { let intervals: [[Span]]; let start: Double; let durationMinutes: Int }
        let input = Input(intervals: intervals.map { $0.map { Span(start: $0.start.timeIntervalSince1970, end: $0.end.timeIntervalSince1970) } },
                          start: start.timeIntervalSince1970, durationMinutes: durationMinutes)
        guard let output = try? RustCore.attempt("planner.fit", input, as: [FitOutput].self) else { return [] }
        return zip(participants, output).map { ParticipantFit(participant: $0, fit: $1.value, localStart: start) }
    }

    private struct OptionsInput: Encodable {
        let participants: [Schedule]
        let from: Double
        let rangeEnd: Double
        let durationMinutes: Int
        let localCalendar: CalendarFacts
        let scoringDayStarts: [Double]
        let idealStartMinute: Int?
        let idealEndMinute: Int?
        let clockWeight: String
    }

    private struct OptionOutput: Decodable {
        let tier: Int
        let start: Double
        let end: Double
        let best: Double
        let durationMinutes: Int
        let score: Double
        let fits: [FitOutput]
        let cost: [Int]
        let days: [Double]
    }

    private struct OptionsOutput: Decodable {
        let everyone: Bool
        let options: [OptionOutput]
    }

    private static func window(_ output: WindowOutput, participants: [Participant]) -> Window {
        Window(tier: Window.Tier(rawValue: output.tier)!,
               start: Date(timeIntervalSince1970: output.start), end: Date(timeIntervalSince1970: output.end),
               best: Date(timeIntervalSince1970: output.best), durationMinutes: output.durationMinutes,
               score: output.score, fits: output.fits.enumerated().map { index, fit in
                   ParticipantFit(participant: participants[index], fit: fit.value,
                                  localStart: Date(timeIntervalSince1970: output.best))
               })
    }

    // MARK: - 例会轮换

    /// 让一个例会在接下来几次里轮着开:每次挑一个开始时刻,使各人「在时段外的分钟」尽量均摊。
    /// 规则全在 Rust `planner.rotate`(先压最重的人,再压总量,再看舒适度;确定性);这里只供事实。
    struct RotationRequest: Hashable, Sendable {
        var participants: [Participant]
        /// 第一次发生所在的本机日;之后每 `intervalWeeks` 周一次。
        var fromDay: Date
        /// 第一次不早于此刻(通常是「现在」)。
        var notBefore: Date
        var count: Int
        var intervalWeeks: Int = 1
        var durationMinutes: Int
        var localTimeZoneID: String
        /// 单次最多让一个人在时段外多少分钟。
        var maxStretchMinutes: Int = 480
        var split: String = "rotate"
        var clockWeight: String = "off"

        var localTimeZone: TimeZone { TimeZone(identifier: localTimeZoneID) ?? .current }
    }

    struct Rotation: Hashable, Sendable {
        struct Occurrence: Hashable, Sendable, Identifiable {
            let index: Int
            /// 这次发生所在的本机日 0 点。
            let day: Date
            /// nil = 这天开不成(有人休息、假期,或没人能在上限内)。
            let window: Window?
            /// 各参与者在时段外的分钟(顺序同请求);开不成时全 0。
            let stretch: [Int]
            // 折合分钟的顺序与请求一致。
            let cost: [Int]
            var id: Int { index }
        }
        struct Total: Hashable, Sendable {
            let participant: Participant
            let outsideMinutes: Int
            let outsideCount: Int
            let weightedMinutes: Int
            let nightMinutes: Int
        }
        let occurrences: [Occurrence]
        let totals: [Total]
        /// 最重与最轻的人相差的分钟;0 = 完全均摊。
        let spreadMinutes: Int
        let weightedSpread: Int
        /// false = 每次都有大家都在时段内的时刻,没什么可轮。
        let needed: Bool
        let skipped: Int
        var held: [Occurrence] { occurrences.filter { $0.window != nil } }
    }

    // MARK: - 拆成 N 场
    struct SplitRequest: Hashable, Sendable {
        var participants: [Participant]
        /// 起点（通常是「现在」）与范围（天）。
        var from: Date
        var days: Int
        var durationMinutes: Int
        /// 2 或 3（Rust 只认这两个）。
        var sessions: Int
        var localTimeZoneID: String

        var localTimeZone: TimeZone { TimeZone(identifier: localTimeZoneID) ?? .current }
    }

    struct Split: Hashable, Sendable {
        struct Session: Hashable, Sendable, Identifiable {
            /// 第几场（1 起）。
            let index: Int
            let start: Date
            let end: Date
            /// 这一场在自己工作时段内的参与者。
            let inside: [Participant]
            var id: Int { index }
        }
        let sessions: [Session]
        /// 一场都不在工作时段内的人。
        let uncovered: [Participant]
        /// false = 有一个时刻就能让所有人都在时段内，不用拆。
        let needed: Bool
    }

    /// 把一场会拆成 N 场，让每个人都至少有一场在自己的工作时段内。挑法在 Rust `planner.split`。
    static func split(_ request: SplitRequest) -> Split {
        let empty = Split(sessions: [], uncovered: request.participants, needed: false)
        guard !request.participants.isEmpty, request.durationMinutes > 0 else { return empty }
        let localCal = calendar(for: request.localTimeZone, countryCode: nil)
        let start = request.from
        guard let end = localCal.date(byAdding: .day, value: max(1, request.days), to: localCal.startOfDay(for: start))
        else { return empty }
        let schedules = request.participants.map { participant in
            Schedule(availability: participant.availability, workingWeekdays: participant.workingWeekdays,
                     vacations: participant.vacations,
                     calendar: facts(calendar(for: participant.timeZone, countryCode: participant.countryCode),
                                     from: start.addingTimeInterval(-86_400), through: end.addingTimeInterval(86_400)))
        }
        // 打分用的民用日起点（与 plan 同一套：越靠后的日子略微降分）。
        var dayStarts: [Double] = []
        var cursor = localCal.startOfDay(for: start)
        while cursor < end {
            dayStarts.append(cursor.timeIntervalSince1970)
            guard let next = localCal.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        let input = SplitInput(participants: schedules, from: start.timeIntervalSince1970,
                               rangeEnd: end.timeIntervalSince1970, durationMinutes: request.durationMinutes,
                               sessions: request.sessions,
                               localCalendar: facts(localCal, from: start, through: end),
                               scoringDayStarts: dayStarts)
        let output = RustCore.invoke("planner.split", input, as: SplitOutput.self)
        return Split(
            sessions: output.sessions.map { session in
                Split.Session(index: session.index,
                              start: Date(timeIntervalSince1970: session.start),
                              end: Date(timeIntervalSince1970: session.end),
                              inside: session.inside.compactMap { index in
                                  request.participants.indices.contains(index) ? request.participants[index] : nil
                              })
            },
            uncovered: output.uncovered.compactMap { index in
                request.participants.indices.contains(index) ? request.participants[index] : nil
            },
            needed: output.needed)
    }

    /// 例会默认落在参考日起第一个不是周末的日子:周六打开排会页,例会不该被排成「每周六」。
    static func defaultRotationWeekday(onOrAfter day: Date, in tz: TimeZone, countryCode: String?) -> Int {
        let cal = calendar(for: tz, countryCode: countryCode)
        var candidate = cal.startOfDay(for: day)
        for _ in 0..<7 {
            if !cal.isDateInWeekend(candidate) { return cal.component(.weekday, from: candidate) }
            guard let next = cal.date(byAdding: .day, value: 1, to: candidate) else { break }
            candidate = next
        }
        return cal.component(.weekday, from: cal.startOfDay(for: day))
    }

    /// 带参与者的默认星期：参考日起第一个「对每个人都整天是工作日」的日子，即组织者这一天在每个人那边跨到的一两个日子
    /// 都不是他的休息日。洛杉矶的周五是东京与伦敦的周六：周五开的例会，凡是让伦敦或东京付的分法都碰到周末，
    /// 轮下来伦敦一次也轮不到（实测）；东京的周一是洛杉矶的周日，同理。七天里找不到（有人每天都休息）就退回上面那一条。
    static func defaultRotationWeekday(onOrAfter day: Date, in tz: TimeZone, countryCode: String?,
                                       participants: [Participant]) -> Int {
        let cal = calendar(for: tz, countryCode: countryCode)
        func works(_ participant: Participant, on date: Date, in calendar: Calendar) -> Bool {
            if let days = participant.workingWeekdays { return days.contains(calendar.component(.weekday, from: date)) }
            return !participant.availability.weekdaysOnly || !calendar.isDateInWeekend(date)
        }
        var candidate = cal.startOfDay(for: day)
        for _ in 0..<7 {
            guard let next = cal.date(byAdding: .day, value: 1, to: candidate) else { break }
            if !cal.isDateInWeekend(candidate), participants.allSatisfy({ participant in
                let theirs = calendar(for: participant.timeZone, countryCode: participant.countryCode)
                var local = theirs.startOfDay(for: candidate)
                let last = theirs.startOfDay(for: next.addingTimeInterval(-1))
                while local <= last {
                    guard works(participant, on: local, in: theirs) else { return false }
                    guard let following = theirs.date(byAdding: .day, value: 1, to: local) else { break }
                    local = following
                }
                return true
            }) {
                return cal.component(.weekday, from: candidate)
            }
            candidate = next
        }
        return defaultRotationWeekday(onOrAfter: day, in: tz, countryCode: countryCode)
    }

    /// 参考日起(含当天)第一个是 `weekday`(Calendar 编号,1 = 周日)的日子的 0 点。
    static func firstDate(weekday: Int, onOrAfter day: Date, in tz: TimeZone) -> Date {
        let cal = calendar(for: tz, countryCode: nil)
        var candidate = cal.startOfDay(for: day)
        for _ in 0..<7 {
            if cal.component(.weekday, from: candidate) == weekday { return candidate }
            guard let next = cal.date(byAdding: .day, value: 1, to: candidate) else { break }
            candidate = next
        }
        return cal.startOfDay(for: day)
    }

    static func rotate(_ request: RotationRequest) -> Rotation {
        let empty = Rotation(occurrences: [],
                             totals: request.participants.map {
                                 Rotation.Total(participant: $0, outsideMinutes: 0, outsideCount: 0,
                                                weightedMinutes: 0, nightMinutes: 0)
                             },
                             spreadMinutes: 0, weightedSpread: 0, needed: false, skipped: 0)
        guard !request.participants.isEmpty, request.durationMinutes > 0 else { return empty }
        let localCal = calendar(for: request.localTimeZone, countryCode: nil)
        let firstDay = localCal.startOfDay(for: request.fromDay)
        let stride = max(1, request.intervalWeeks) * 7
        var occurrences: [OccurrenceInput] = []
        var days: [Date] = []
        for k in 0..<max(1, request.count) {
            guard let day = localCal.date(byAdding: .day, value: k * stride, to: firstDay),
                  let next = localCal.date(byAdding: .day, value: 1, to: day) else { break }
            let dayStart = localCal.startOfDay(for: day)
            let from = k == 0 ? max(request.notBefore, dayStart) : dayStart
            occurrences.append(OccurrenceInput(from: from.timeIntervalSince1970,
                                               rangeEnd: localCal.startOfDay(for: next).timeIntervalSince1970))
            days.append(dayStart)
        }
        guard let firstStart = days.first, let last = occurrences.last else { return empty }
        let lastEnd = Date(timeIntervalSince1970: last.rangeEnd)
        let schedules = request.participants.map { participant in
            Schedule(availability: participant.availability, workingWeekdays: participant.workingWeekdays,
                     vacations: participant.vacations,
                     calendar: facts(calendar(for: participant.timeZone, countryCode: participant.countryCode),
                                     from: firstStart.addingTimeInterval(-86_400), through: lastEnd.addingTimeInterval(86_400)))
        }
        let input = RotateInput(participants: schedules, occurrences: occurrences,
                                durationMinutes: request.durationMinutes, maxStretchMinutes: request.maxStretchMinutes,
                                split: request.split, clockWeight: request.clockWeight,
                                localCalendar: facts(localCal, from: firstStart, through: lastEnd))
        let output = RustCore.invoke("planner.rotate", input, as: RotationOutput.self)
        return Rotation(
            occurrences: output.occurrences.map { occurrence in
                Rotation.Occurrence(index: occurrence.index, day: days[min(occurrence.index, days.count - 1)],
                                    window: occurrence.window.map { window($0, participants: request.participants) },
                                    stretch: occurrence.stretch, cost: occurrence.cost)
            },
            totals: zip(request.participants, output.totals).map {
                Rotation.Total(participant: $0, outsideMinutes: $1.outsideMinutes, outsideCount: $1.outsideCount,
                               weightedMinutes: $1.weightedMinutes, nightMinutes: $1.nightMinutes)
            },
            spreadMinutes: output.spreadMinutes, weightedSpread: output.weightedSpread,
            needed: output.needed, skipped: output.skipped)
    }

    private struct PlanInput: Encodable {
        let participants: [Schedule]
        let from: Double
        let rangeEnd: Double
        let durationMinutes: Int
        let toleranceMinutes: Int
        let limit: Int
        let localCalendar: CalendarFacts
        let scoringDayStarts: [Double]
        let idealStartMinute: Int?
        let idealEndMinute: Int?
    }

    private struct OccurrenceInput: Encodable {
        let from: Double
        let rangeEnd: Double
    }

    private struct RotateInput: Encodable {
        let participants: [Schedule]
        let occurrences: [OccurrenceInput]
        let durationMinutes: Int
        let maxStretchMinutes: Int
        let split: String
        let clockWeight: String
        let localCalendar: CalendarFacts
    }

    private struct SplitInput: Encodable {
        let participants: [Schedule]
        let from: Double
        let rangeEnd: Double
        let durationMinutes: Int
        let sessions: Int
        let localCalendar: CalendarFacts
        let scoringDayStarts: [Double]
    }

    private struct SplitOutput: Decodable {
        struct Session: Decodable {
            let index: Int
            let start: Double
            let end: Double
            let inside: [Int]
        }
        let sessions: [Session]
        let uncovered: [Int]
        let needed: Bool
    }

    private struct RotationOccurrenceOutput: Decodable {
        let index: Int
        let from: Double
        let window: WindowOutput?
        let stretch: [Int]
        let cost: [Int]
    }

    private struct RotationTotalOutput: Decodable {
        let outsideMinutes: Int
        let outsideCount: Int
        let weightedMinutes: Int
        let nightMinutes: Int
    }

    private struct RotationOutput: Decodable {
        let occurrences: [RotationOccurrenceOutput]
        let totals: [RotationTotalOutput]
        let spreadMinutes: Int
        let weightedSpread: Int
        let needed: Bool
        let skipped: Int
    }

    private struct FitOutput: Decodable {
        let kind: Int
        let outsideMinutes: Int
        var value: Fit {
            switch kind {
            case 0: return .inside
            case 1: return .stretched(outsideMinutes: outsideMinutes)
            case 2: return .unavailable
            default: preconditionFailure("Rust planner returned an unknown participant fit")
            }
        }
    }

    private struct WindowOutput: Decodable {
        let tier: Int
        let start: Double
        let end: Double
        let best: Double
        let durationMinutes: Int
        let score: Double
        let fits: [FitOutput]
    }
}

extension MeetingEvent {
    /// 从排会结果的一个时段生成事件。`names` 与 `timeZones` 一一对应;日期 / 时间按 `locale` 与小时制格式化。
    static func make(window: OverlapPlanner.Window, names: [String], timeZones: [TimeZone],
                     offsetOnlyZoneNames: [Bool] = [],
                     title: String, footer: String, locale: Locale, hourStyle: HourStyle) -> MeetingEvent {
        make(start: window.best, end: window.bestEnd, names: names, timeZones: timeZones,
             offsetOnlyZoneNames: offsetOnlyZoneNames,
             title: title, footer: footer, locale: locale, hourStyle: hourStyle)
    }
}
