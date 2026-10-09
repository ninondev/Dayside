// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// 「读懂了」一栏、候选菜单与提醒行的句子。纯函数：给定落成的结果与原文，拼出界面上的一行；
/// 读屏念的也是这一行，所以不靠颜色、不靠位置，一句话说全（日期、钟点或时间段、地点、目标）。
@MainActor
enum UnderstandingText {
    struct Style {
        let locale: Locale
        let hourStyle: HourStyle
        let now: Date
        /// 时区 → 界面上的地名（已添加的地点用用户起的名字）。
        let name: @MainActor (TimeZone) -> String
        /// 城市索引里的城 → 界面语言里它自己的名字（没有就 nil，退回索引里的主名）。
        var cityName: @MainActor (Int) -> String? = { _ in nil }
        /// 「今天」那一刻与这台 Mac 的时区：没写日期的一处落在那边的今天，与这里的今天不是同一天时要标出来。
        var reference: Date = .now
        var home: TimeZone = .current
    }

    private static func string(_ key: String, _ style: Style) -> String { L10n.string(key, locale: style.locale) }
    private static func format(_ key: String, _ style: Style, _ arguments: CVarArg...) -> String {
        String(format: L10n.string(key, locale: style.locale), locale: style.locale, arguments: arguments)
    }

    /// 原文里 `span`（UTF-16）那一段；越界时给空串。
    static func snippet(_ span: [Int], in text: String) -> String {
        let units = text.utf16
        guard span.count == 2, 0 <= span[0], span[0] <= span[1], span[1] <= units.count,
              let from = units.index(units.startIndex, offsetBy: span[0], limitedBy: units.endIndex),
              let to = units.index(units.startIndex, offsetBy: span[1], limitedBy: units.endIndex),
              let start = String.Index(from, within: text), let end = String.Index(to, within: text) else { return "" }
        return String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 这一处里写时区或地点的那几个字（「PST」「东京」「Central」）；没写时给 nil。
    static func zoneText(_ mention: TimeUnderstanding.Mention, in text: String) -> String? {
        mention.parts.first { $0.kind == "zone" }.map { snippet($0.span, in: text) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// 固定偏移的写法「UTC−8」「UTC+5:30」（真减号，与全 App 一致）。
    static func offset(_ seconds: Int) -> String {
        let sign = seconds < 0 ? "\u{2212}" : "+"
        let magnitude = abs(seconds) / 60
        return magnitude % 60 == 0 ? "UTC\(sign)\(magnitude / 60)" : String(format: "UTC%@%d:%02d", sign, magnitude / 60, magnitude % 60)
    }

    /// 系统给的通用时区名（「北美太平洋时间」「中欧时间」「印度时间」）；没有时用地名。
    static func generic(_ zone: TimeZone, at date: Date, style: Style) -> String {
        ZoneNameDisplay.name(zone, at: date, locale: style.locale) ?? style.name(zone)
    }

    /// 重复钟点的缩写也保留原文指向的城市，不能把戈兰居民点当成时区代表城市。
    static func abbreviation(_ option: TimeUnderstanding.ZoneOption, at date: Date, offsetOnly: Bool = false) -> String {
        let record = option.city.flatMap { CityIndex.shared.city(at: $0.index) }
        let placeRule = record.map { ZoneNameDisplay.offsetOnly(identifier: $0.timezoneID, code: $0.countryCode,
            admin: $0.region, city: $0.name, coordinate: Coordinate(latitude: $0.latitude, longitude: $0.longitude)) } ?? false
        let useOffset = offsetOnly || placeRule || ZoneNameDisplay.offsetOnly(identifier: option.zone.identifier)
        let abbreviation = ZoneNameDisplay.abbreviation(option.zone, at: date, offsetOnly: useOffset)
        guard !useOffset, abbreviation.hasPrefix("UTC") else { return abbreviation }
        // 系统语言可能只给偏移；重复钟点仍用系统的英文短名区分夏令与标准时间。
        let style: TimeZone.NameStyle = option.zone.isDaylightSavingTime(for: date) ? .shortDaylightSaving : .shortStandard
        guard let shortName = option.zone.localizedName(for: style, locale: Locale(identifier: "en_US_POSIX")),
              !shortName.isEmpty, !shortName.hasPrefix("GMT"), !shortName.hasPrefix("UTC") else { return abbreviation }
        return shortName
    }

    /// 读成的地点怎么称呼：写的是城市就用城市自己的名字（「Winston-Salem」不写成时区的代表城市纽约）；写的是时区词、缩写或国家
    /// 就用通用时区名；按字面的固定偏移写「UTC−8」；「我这边」写「本机（洛杉矶）」。
    static func zoneName(_ option: TimeUnderstanding.ZoneOption, at date: Date, style: Style, pasted: Bool) -> String {
        switch option.kind {
        case .literal, .writerInferred: return offset(option.zone.secondsFromGMT(for: date))
        case .readerLocal: return format("本机（%@）", style, style.name(option.zone))
        case .local: return pasted ? string("写信人那边（先按你这里算）", style) : format("本机（%@）", style, style.name(option.zone))
        case .region, .regionalClock, .writer:
            if let city = option.city { return style.cityName(city.index) ?? city.name }
            return generic(option.zone, at: date, style: style)
        }
    }

    /// 候选菜单里一个时区选项的叫法：「北美太平洋时间（UTC−7）」「印度时间（UTC+5:30）」；有地区现在的钟可选时，字面那一项写
    /// 「按字面 UTC−8」；「本机（洛杉矶）」。
    static func zoneLabel(_ option: TimeUnderstanding.ZoneOption, among options: [TimeUnderstanding.ZoneOption], at date: Date,
                          style: Style, pasted: Bool, written: String? = nil) -> String {
        let shift = offset(option.zone.secondsFromGMT(for: date))
        switch option.kind {
        // 括号按语言排（中日全角、韩语不留空格、其余半角前留空格）：此前写死全角，拉丁字母的语言成了「Pacific Time（UTC−7）」。
        case .region, .regionalClock, .writer:
            var name = zoneName(option, at: date, style: style, pasted: pasted)
            // 同名城市沿用地点搜索的副标题；空副标题仍只写城市名与偏移。
            if let city = option.city,
               options.filter({ $0.city != nil && zoneName($0, at: date, style: style, pasted: pasted) == name }).count > 1,
               let record = CityIndex.shared.city(at: city.index) {
                let subtitle = ZoneOption(cityIndex: city.index, record: record).subtitle(locale: style.locale, displayName: name)
                if !subtitle.isEmpty { name += " · " + subtitle }
            }
            return name == shift ? shift : format("%1$@（%2$@）", style, name, shift)
        case .writerInferred: return shift
        case .literal:
            let regional = options.contains { if case .regionalClock = $0.kind { $0.anchor == option.anchor } else { false } }
            guard regional else { return shift }
            // 写出原文的缩写（「按字面 PST（UTC−8）」）：只写「按字面 UTC−8」时看不出是在说 PST。
            if let written, !written.isEmpty { return format("按字面 %1$@（%2$@）", style, written, shift) }
            return format("按字面 %@", style, shift)
        case .local, .readerLocal: return zoneName(option, at: date, style: style, pasted: pasted)
        }
    }

    /// 读法菜单里一种读法的叫法：日期与钟点按它自己写（「10月3日 9:00」「3月10日 9:00」「15:03」「3月15日」）。
    static func readingLabel(_ reading: TimeUnderstanding.Reading, of resolved: TimeUnderstanding.Resolved, style: Style) -> String {
        var parts: [String] = []
        if let date = reading.date, let day = TimeUnderstanding.civilDay(date, reference: style.now, in: resolved.zone),
           let noon = Calendar.gregorianUTC(resolved.zone).date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12)) {
            parts.append(ClockText.day(noon, in: resolved.zone, locale: style.locale, now: style.now))
        }
        if let time = reading.time {
            let clock = ClockText.minute(time.hour * 60 + time.minute, hourStyle: style.hourStyle)
            parts.append(resolved.mention.timeImplied == "eod" ? format("下班前按 %@ 算", style, clock) : clock)
        }
        return parts.joined(separator: " ")
    }

    /// 读不成时的那一句（错误句带句号）；读成了给 nil。
    static func problem(_ resolved: TimeUnderstanding.Resolved, in text: String, style: Style) -> String? {
        switch resolved.problem {
        case nil, .dateOnly: return nil
        case .issues(let issues):
            guard let issue = issues.first else { return nil }
            let quoted = issue.text
            switch issue.kind {
            case "invalidDate": return format("“%@”这一天不存在。", style, quoted)
            case "invalidTime": return format("“%@”这个钟点不成立。", style, quoted)
            case "invalidOffset": return format("“%@”这个时区偏移不成立。", style, quoted)
            case "conflictingPeriod": return format("“%@”上午下午对不上。", style, quoted)
            case "conflictingDeadline": return format("“%@”比截止时间还晚。", style, quoted)
            default: return format("“%@”写了两个不同的日子。", style, quoted)
            }
        case .invalidDate: return format("这一天在%@不存在。", style, style.name(resolved.zone))
        case .nonexistentTime(let gap):
            guard let gap else { return string("这个当地时刻不存在，可能处于夏令时跳转。请换一个时刻。", style) }
            let range = ClockText.clockChange(at: gap.at, before: gap.before, after: gap.after, hourStyle: style.hourStyle,
                                              locale: style.locale, now: style.now)
            let shiftText = ClockText.duration(seconds: Double(gap.after - gap.before), locale: style.locale)
            return format("%@ %@ 这段不存在（时钟拨快 %@）。请换一个时刻。", style, style.name(resolved.zone), range, shiftText)
        case .unresolvedPlace(let place): return format("没认出地名“%@”。", style, place)
        }
    }

    /// 「读懂了」里的一行：日期（沿用的加「（沿用）」）+ 钟点或时间段（默认钟点加「（按默认）」）+ 写了的地点 + 目标。
    /// 只有日期的写「只有日期」；读不成的给那一句错误。
    static func summary(_ resolved: TimeUnderstanding.Resolved, in text: String, style: Style, pasted: Bool) -> String {
        if let problem = problem(resolved, in: text, style: style) { return problem }
        let zone = resolved.zone
        var pieces: [String] = []
        if resolved.problem == .dateOnly {
            if let day = resolved.day, let noon = Calendar.gregorianUTC(zone).date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12)) {
                pieces.append(ClockText.day(noon, in: zone, locale: style.locale, now: style.now))
            }
            pieces.append(string("没写钟点", style))
            return pieces.joined(separator: " · ")
        }
        guard let start = resolved.start else { return "" }
        var day = ClockText.day(start, in: zone, locale: style.locale, now: style.now)
        let mention = resolved.mention
        if mention.dateInherited {
            day += string("（同上）", style)
        } else if !resolved.anchoredToGroup, mention.date == nil, mention.relativeMinutes == nil, mention.instant == nil, let there = resolved.day,
                  Calendar.gregorianUTC(style.home).dateComponents([.year, .month, .day], from: style.reference)
                    != DateComponents(year: there.year, month: there.month, day: there.day) {
            // 没写日期，落在那边的今天，而那边的今天不是这里的今天（下午在洛杉矶打「10:00 IST」，印度已是次日）：标出来。
            // 锚到等价组那一天的一处不是「那边的今天」，不这样标。
            day += string("（那边的今天）", style)
        }
        var clock = ClockText.time(start, in: zone, hourStyle: style.hourStyle)
        if let end = resolved.end {
            let sameDay = Calendar.gregorianUTC(zone).isDate(start, inSameDayAs: end)
            let endClock = ClockText.time(end, in: zone, hourStyle: style.hourStyle)
            clock = ClockText.range(clock, sameDay ? endClock : "\(ClockText.day(end, in: zone, locale: style.locale, now: style.now)) \(endClock)")
        }
        if resolved.mention.timeImplied != nil { clock = format("%@（按默认）", style, clock) }
        pieces.append("\(day) \(clock)")
        if resolved.zoneWritten { pieces.append(zoneName(resolved.zoneOption, at: start, style: style, pasted: pasted)) }
        var line = pieces.joined(separator: " · ")
        if let target = resolved.target { line += " → \(style.name(target))" }
        return line
    }

    /// 一处是哪一天（带星期，与面板日期片同一写法）：那一处的来源时区里的民用日。几天一组时「哪一天」菜单与这一行都用它。
    static func dayLabel(_ resolved: TimeUnderstanding.Resolved, style: Style) -> String? {
        let zone = resolved.zone
        if let day = resolved.day,
           let noon = Calendar.gregorianUTC(zone).date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12)) {
            return ClockText.day(noon, in: zone, locale: style.locale, now: style.now, weekday: true)
        }
        return resolved.start.map { ClockText.day($0, in: zone, locale: style.locale, now: style.now, weekday: true) }
    }

    /// 几天共用一个钟点的一组（引擎每天给一处，CONVENTIONS 第 12 条）并成「读懂了」的一行：
    /// 三天以上连着的写成一段「10月6日 周二–10月8日 周四」，其余列出来「10月3日 周六和10月19日 周一」（列举按界面语言的连词）；
    /// 后面是几天共用的钟点或时间段、写了的地点、目标，与单独一处同一写法。几天里读不成的不列（页面另写它们的错误句）；
    /// 都读不成时就是第一天的那一句错误。
    static func seriesSummary(_ days: [TimeUnderstanding.Resolved], in text: String, style: Style, pasted: Bool) -> String {
        let readable = days.filter { $0.problem == nil || $0.problem == .dateOnly }
        guard let first = readable.first else { return days.first.map { summary($0, in: text, style: style, pasted: pasted) } ?? "" }
        let labels = readable.compactMap { dayLabel($0, style: style) }
        let dayText: String
        if labels.count >= 3, consecutive(readable) {
            dayText = ClockText.range(labels[0], labels[labels.count - 1])
        } else {
            let formatter = ListFormatter()
            formatter.locale = style.locale
            dayText = formatter.string(from: labels) ?? labels.joined(separator: ", ")
        }
        if first.problem == .dateOnly {
            return [dayText, string("没写钟点", style)].joined(separator: " · ")
        }
        guard let start = first.start else { return dayText }
        let zone = first.zone
        var clock = ClockText.time(start, in: zone, hourStyle: style.hourStyle)
        if let end = first.end {
            let sameDay = Calendar.gregorianUTC(zone).isDate(start, inSameDayAs: end)
            let endClock = ClockText.time(end, in: zone, hourStyle: style.hourStyle)
            clock = ClockText.range(clock, sameDay ? endClock : format("次日 %@", style, endClock))
        }
        if first.mention.timeImplied != nil { clock = format("%@（按默认）", style, clock) }
        var pieces = ["\(dayText) \(clock)"]
        if first.zoneWritten { pieces.append(zoneName(first.zoneOption, at: start, style: style, pasted: pasted)) }
        var line = pieces.joined(separator: " · ")
        if let target = first.target { line += " → \(style.name(target))" }
        return line
    }

    /// 读屏念的一组：先念那一行，再念紧贴结果的地点建议说明（与单独一处同一个做法）。
    static func accessibleSeriesSummary(_ days: [TimeUnderstanding.Resolved], in text: String, style: Style, pasted: Bool) -> String {
        let result = seriesSummary(days, in: text, style: style, pasted: pasted)
        return [result, days.first.flatMap { sentenceNote($0, style: style) }].compactMap { $0 }.joined(separator: "。")
    }

    /// 几天是不是一天接一天（各按自己的来源时区的民用日，一天也不缺）。
    private static func consecutive(_ days: [TimeUnderstanding.Resolved]) -> Bool {
        let utc = Calendar.gregorianUTC(TimeZone(secondsFromGMT: 0)!)
        let dates = days.compactMap { $0.day.flatMap { utc.date(from: DateComponents(year: $0.year, month: $0.month, day: $0.day, hour: 12)) } }
        guard dates.count == days.count, dates.count > 1 else { return false }
        return zip(dates, dates.dropFirst()).allSatisfy { utc.dateComponents([.day], from: $0, to: $1).day == 1 }
    }

    /// 句中地点建议的说明紧跟在结果后，原地名按界面语言显示。
    static func sentenceNote(_ resolved: TimeUnderstanding.Resolved, style: Style) -> String? {
        guard let suggested = resolved.notes.compactMap({ note -> TimeUnderstanding.ZoneOption? in
            if case .sentenceSuggestion(let option) = note { return option }
            return nil
        }).first else { return nil }
        let country = resolved.mention.sentencePlaceCountry.flatMap { code in
            let displayed = RegionDisplayName.localized(code, locale: style.locale)
            // 地点搜索有些副标题按政策省略国家；此处仍要明确读出原句里的地点。
            return displayed.flatMap { $0.isEmpty ? nil : $0 } ?? style.locale.localizedString(forRegionCode: code)
        }
        let name = country ?? zoneName(suggested, at: resolved.start ?? style.now, style: style, pasted: false)
        return format("钟点没写明是哪里的，先按句中提到的 %@ 算", style, name)
    }

    /// VoiceOver 先念结果，再念紧贴结果的地点建议说明。
    static func accessibleSummary(_ resolved: TimeUnderstanding.Resolved, in text: String, style: Style, pasted: Bool) -> String {
        let result = summary(resolved, in: text, style: style, pasted: pasted)
        return [result, sentenceNote(resolved, style: style)].compactMap { $0 }.joined(separator: "。")
    }

    /// 选中那一处的提醒（灰三角，一句话，不带句号）：按默认算的钟点、七月的 PST、粘贴文字里的「我这边」、没认出的目标。
    static func notes(_ resolved: TimeUnderstanding.Resolved, in text: String, style: Style) -> [String] {
        resolved.notes.compactMap { note in
            switch note {
            case .sentenceSuggestion: return nil
            case .standardAbbreviationDuringDaylightTime(_, let region):
                let written = zoneText(resolved.mention, in: text) ?? ""
                let at = resolved.start ?? style.now
                return format("%1$@ 所在地区正值夏令时，按 %2$@ 算", style, written, offset(region.secondsFromGMT(for: at)))
            case .impliedTime(let key):
                guard let time = resolved.reading.time else { return nil }
                let clock = ClockText.minute(time.hour * 60 + time.minute, hourStyle: style.hourStyle)
                return key == "eod" ? format("下班前没写钟点，按 %@ 算", style, clock) : format("没写钟点，按当天结束 %@ 算", style, clock)
            case .localMeansTheWriter:
                return string("“我这边”指写信人那边，这里没写在哪，先按你这里算", style)
            case .localIsTheWriter(let place):
                // 地名按界面语言写（「我在上海」在英文界面是 Shanghai）；叫不出时用原文那句里的地名。
                let named = zoneName(resolved.zoneOption, at: resolved.start ?? style.now, style: style, pasted: false)
                let there = named.isEmpty ? place : named
                return format("“我这边”按 %@ 算（原文写了在那里）", style, there)
            case .localInferredFrom(let offsetMinutes, let placeAndClock, let other):
                // 另一处照原文的写法称呼（ET、纽约、東京），钟点按用户的小时制；原文里找不到才用模型给的叫法。
                let there = zoneText(other, in: text).flatMap { written in
                    other.time.map { "\(written) " + ClockText.minute($0.hour * 60 + $0.minute, hourStyle: style.hourStyle) }
                } ?? placeAndClock
                return format("“我这边”按 %1$@ 算：由同一行的 %2$@ 推出", style, offset(offsetMinutes * 60), there)
            case .unresolvedTarget(let place):
                return format("没认出目标地名“%@”", style, place)
            case .unresolvedPlace(let place):
                return format("没认出地名“%@”，按来源地点算", style, place)
            }
        }
    }

    /// 等价组核对差出来的那几处各一句（dstSuspect）：两边各写「地名 钟点」，再说差多少，让人看出哪一处没按夏令时改。
    static func crosscheckNotes(_ check: TimeUnderstanding.Crosscheck, _ resolved: [TimeUnderstanding.Resolved],
                                style: Style, pasted: Bool) -> [String] {
        func side(_ index: Int) -> String? {
            guard resolved.indices.contains(index), let start = resolved[index].start else { return nil }
            return "\(zoneName(resolved[index].zoneOption, at: start, style: style, pasted: pasted)) " +
                ClockText.time(start, in: resolved[index].zone, hourStyle: style.hourStyle)
        }
        return check.suspects.compactMap { note in
            guard let a = side(note.a), let b = side(note.b) else { return nil }
            return format("%1$@ 与 %2$@ 差 %3$@：可能有一处没按夏令时改", style, a, b,
                          ClockText.duration(seconds: Double(abs(note.deltaMinutes)) * 60, locale: style.locale))
        }
    }
}
