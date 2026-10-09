// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// 单个时刻的入口（快捷指令、计时器闹钟框、面板搜索框、语言模型给的写法的校验）：交给「听懂时间」引擎读，
/// 取第一处能落成时刻的；换算页要看全部几处，直接用 `TimeUnderstanding`。Foundation 给民用时间的规则。
//  民用时间的候选与缺口均由 Foundation 提供，避免另写时区规则。
nonisolated enum TimeInput {
    struct Resolution {
        /// nil = 读成了。`unrecognized`（一处时间都没读出）、`nonexistentTime`（落在拨快的缺口里，见 `gap`）、
        /// `invalidDate`（这一天在那里不存在）、`unknownPlace`（有线索的地名没认出）、`invalid`（写得不成立，Rust 报的问题）。
        let error: String?
        let dates: [Date]
        let timeZone: TimeZone
        /// 时刻不存在时：那天拨快时钟的那一瞬与前后偏移，错误句用它点名缺口「3月8日 2:00 → 3:00」。
        var gap: (at: Date, before: Int, after: Int)? = nil
        /// 时间段的终点（与 `dates` 同样是候选列表；没写终点时为空）。
        var endDates: [Date] = []
        /// 读成的那一处（换算页之外的入口只用第一处）。
        var resolved: TimeUnderstanding.Resolved? = nil
    }

    struct Timestamps: Decodable {
        let iso8601: String
        /// 这个地点在这个年份用的是真太阳时（偏移带秒，tzdata 里叫 LMT），ISO 串里的偏移已四舍五入
        /// 到分钟（RFC 3339 只认 ±HH:MM）。界面据此加一句脚注（调研 #35）。
        var offsetRounded = false
        let unix: String
        /// Discord `<t:unix:F>`（完整日期时间）与 `<t:unix:R>`（相对），Slack `<!date^unix^…|fallback>`；收方按各自时区显示。
        let discord: String
        let discordRelative: String
        let slack: String
    }

    private struct Candidates: Decodable {
        let error: String?
        let instants: [Double]
    }

    /// 文字里写的来源时区（第一处有钟点的那处），没写就是 `selectedZone`。
    static func sourceTimeZone(for text: String, in selectedZone: TimeZone) -> TimeZone {
        guard let first = TimeUnderstanding.read(text).mentions.first(where: { $0.time != nil || $0.relativeMinutes != nil || $0.instant != nil }) else {
            return selectedZone
        }
        let context = TimeUnderstanding.Context(reference: .now, fallback: selectedZone)
        return TimeUnderstanding.zoneOptions(first.source, date: first.date, context: context).first?.zone ?? selectedZone
    }

    /// 读 `text` 里第一处能落成时刻的。`reference` 是「今天」（只有钟点时落在这一天），`now` 是「两小时后」的起点。
    /// `choice` 按意思的标识记（面板「跳到」行第二行切换读法时用）；对不上某一处的就当没选。
    static func resolve(_ text: String, relativeTo reference: Date, now: Date = .now, in selectedZone: TimeZone,
                        preferredZones: [String] = [], origin: TimeUnderstanding.Origin = .typed,
                        choice: TimeUnderstanding.Choice = .init()) -> Resolution {
        resolve(TimeUnderstanding.read(text), relativeTo: reference, now: now, in: selectedZone,
                preferredZones: preferredZones, origin: origin, choice: choice)
    }

    /// 已读过的文字复用同一份结果，候选与错误选择沿用单个时刻入口。
    static func resolve(_ output: TimeUnderstanding.Output, relativeTo reference: Date, now: Date = .now, in selectedZone: TimeZone,
                        preferredZones: [String] = [], origin: TimeUnderstanding.Origin = .typed,
                        choice: TimeUnderstanding.Choice = .init()) -> Resolution {
        let context = TimeUnderstanding.Context(reference: reference, now: now, fallback: selectedZone, preferredZones: preferredZones, origin: origin)
        let choices = Dictionary(uniqueKeysWithValues: output.mentions.indices.map { ($0, choice) })
        let all = TimeUnderstanding.resolveAll(output, context: context, choices: choices)
        // 先取读成了的第一处；都没读成时报第一处有钟点的毛病（只有日期的几处不算：换算要钟点）。
        let chosen = all.first { $0.problem == nil } ?? all.first { $0.problem != .dateOnly }
        guard let chosen else { return Resolution(error: "unrecognized", dates: [], timeZone: selectedZone) }
        var resolution = Resolution(error: nil, dates: chosen.intervals.map(\.start), timeZone: chosen.zone,
                                    endDates: chosen.intervals.compactMap(\.end), resolved: chosen)
        switch chosen.problem {
        case nil: break
        case .nonexistentTime(let gap):
            resolution = Resolution(error: "nonexistentTime", dates: [], timeZone: chosen.zone, gap: gap.map { ($0.at, $0.before, $0.after) },
                                    resolved: chosen)
        case .invalidDate: resolution = Resolution(error: "invalidDate", dates: [], timeZone: chosen.zone, resolved: chosen)
        case .unresolvedPlace: resolution = Resolution(error: "unknownPlace", dates: [], timeZone: selectedZone, resolved: chosen)
        case .issues: resolution = Resolution(error: "invalid", dates: [], timeZone: chosen.zone, resolved: chosen)
        case .dateOnly: resolution = Resolution(error: "unrecognized", dates: [], timeZone: selectedZone)
        }
        return resolution
    }

    /// 整段文字就是一个合格写法（一处、从头到尾、读成了）：语言模型给的写法要过这一关，「里面找得到一段」不算。
    static func resolveWhole(_ text: String, relativeTo reference: Date, in selectedZone: TimeZone) -> Resolution {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let output = TimeUnderstanding.read(trimmed)
        let length = trimmed.utf16.count
        guard output.mentions.count == 1, let mention = output.mentions.first,
              mention.span.first == 0, mention.span.last == length else {
            return Resolution(error: "unrecognized", dates: [], timeZone: selectedZone)
        }
        return resolve(trimmed, relativeTo: reference, in: selectedZone)
    }

    /// 某一天（`day` 所在的民用日）某个钟点在 `zone` 里的全部候选时刻；旅行页的作息表用（钟点是自己的数据，不用读文字）。
    static func resolveClock(minuteOfDay: Int, on day: Date, in zone: TimeZone) -> Resolution {
        let calendar = Calendar.gregorianUTC(zone)
        var wallTime = calendar.dateComponents([.year, .month, .day], from: day)
        wallTime.hour = minuteOfDay / 60
        wallTime.minute = minuteOfDay % 60
        wallTime.second = 0
        return resolveWallTime(wallTime, on: day, in: zone)
    }

    /// 某个时区里一个具体的年月日时分秒的全部候选时刻，供理解引擎与显式输入共用。
    static func resolveWallTime(_ wallTime: DateComponents, on targetDay: Date, in zone: TimeZone) -> Resolution {
        func failure(_ code: String, in zone: TimeZone) -> Resolution {
            Resolution(error: code, dates: [], timeZone: zone)
        }
        let calendar = Calendar.gregorianUTC(zone)
        let utc = Calendar.gregorianUTC(TimeZone(secondsFromGMT: 0)!)
        guard let nominal = utc.date(from: wallTime), let interval = calendar.dateInterval(of: .day, for: targetDay) else {
            return failure("nonexistentTime", in: zone)
        }
        // Foundation's repeatedTimePolicy misses Lord Howe's second occurrence on this SDK.
        // Read offset facts across the actual civil day instead; Rust constructs the candidates.
        var offsets = [zone.secondsFromGMT(for: interval.start),
                       zone.secondsFromGMT(for: interval.end.addingTimeInterval(-1))]
        var cursor = interval.start.addingTimeInterval(-1)
        while let transition = zone.nextDaylightSavingTimeTransition(after: cursor), transition < interval.end {
            guard transition > cursor else { break }
            offsets.append(zone.secondsFromGMT(for: transition.addingTimeInterval(-1)))
            offsets.append(zone.secondsFromGMT(for: transition))
            cursor = transition
        }
        struct CandidateInput: Encodable { let localTimestamp: Double; let offsets: [Int] }
        let proposed: Candidates = RustCore.invoke("converter.candidates", CandidateInput(
            localTimestamp: nominal.timeIntervalSince1970, offsets: offsets))
        let candidates = proposed.instants.filter { timestamp in
            calendar.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                    from: Date(timeIntervalSince1970: timestamp)) == wallTime
        }
        let resolved: Candidates = RustCore.invoke("converter.resolve", ["candidates": candidates])
        var resolution = Resolution(error: resolved.error, dates: resolved.instants.map(Date.init(timeIntervalSince1970:)), timeZone: zone)
        if resolved.error == "nonexistentTime" {
            // 那天里偏移变大（拨快）的那一次换钟就是缺口。
            var probe = interval.start.addingTimeInterval(-1)
            while let transition = zone.nextDaylightSavingTimeTransition(after: probe), transition < interval.end, transition > probe {
                let before = zone.secondsFromGMT(for: transition.addingTimeInterval(-1)), after = zone.secondsFromGMT(for: transition)
                if after > before { resolution.gap = (transition, before, after); break }
                probe = transition
            }
        }
        return resolution
    }

    static func timestamps(for date: Date, in zone: TimeZone) -> Timestamps? {
        struct Input: Encodable { let timestamp: Double; let offsetSeconds: Int }
        struct Output: Decodable { let error: String?; let iso8601: String?; let unix: String?; let discord: String?; let discordRelative: String?; let slack: String?; let offsetRounded: Bool? }
        guard date.timeIntervalSince1970.isFinite else { return nil }
        let result: Output = RustCore.invoke("converter.timestamps", Input(timestamp: date.timeIntervalSince1970,
                                                                         offsetSeconds: zone.secondsFromGMT(for: date)))
        guard result.error == nil, let iso = result.iso8601, let unix = result.unix,
              let discord = result.discord, let relative = result.discordRelative, let slack = result.slack else { return nil }
        return Timestamps(iso8601: iso, offsetRounded: result.offsetRounded ?? false, unix: unix,
                          discord: discord, discordRelative: relative, slack: slack)
    }

    /// 「东京 9月17日 3:00–5:00 / 洛杉矶 9月16日 11:00–13:00 / 伦敦 19:00–21:00」：各地一段，用「 / 」相接，能直接贴进聊天。
    /// 日期只在与来源地那天不同时写；时段终点在同一天才只写钟点，跨日就连日期一起写。
    static func pasteLine(start: Date, end: Date?, zones: [(name: String, zone: TimeZone)], source: TimeZone,
                          hourStyle: HourStyle, locale: Locale, now: Date) -> String {
        let sourceDay = Calendar.gregorianUTC(source).dateComponents([.year, .month, .day], from: start)
        return zones.map { entry in
            let calendar = Calendar.gregorianUTC(entry.zone)
            let day = calendar.dateComponents([.year, .month, .day], from: start)
            var text = entry.name
            if day != sourceDay { text += " " + ClockText.day(start, in: entry.zone, locale: locale, now: now) }
            text += " " + ClockText.time(start, in: entry.zone, hourStyle: hourStyle)
            if let end {
                let sameDay = calendar.dateComponents([.year, .month, .day], from: end) == day
                text += "–" + (sameDay ? "" : ClockText.day(end, in: entry.zone, locale: locale, now: now) + " ") + ClockText.time(end, in: entry.zone, hourStyle: hourStyle)
            }
            return text
        }.joined(separator: " / ")
    }
}
