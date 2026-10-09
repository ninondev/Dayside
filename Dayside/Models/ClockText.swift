// SPDX-License-Identifier: GPL-3.0-only
//
//  ClockText.swift
//  Dayside
//
//  工具页的钟点文本。所有只写钟点的地方（天文页的日出日落与图表横轴、夏令时页的换钟时刻、
//  分享预览的大字、旅行页的出发到达）都走这里，小时制解析与 `TimeFormatting` 完全同一套：
//  跟随系统时取系统 locale（已反映系统「24 小时制」开关），强制 12 / 24 时只改 hourCycle。
//  这些地方各自构造 DateFormatter 会让小时制设置失效，英文界面仍可能显示 6:35 AM；
//  中文界面则一边「6:35」一边「06:35」（DateFormatter 与 Date.FormatStyle 的前导零不同）。
//  前导零只留 Date.FormatStyle 一种，与菜单栏、面板和排会页一致。
//  日期部分按界面语言（其他页的日期都这样），钟点部分按系统 locale + 小时制（其他页的钟点都这样），
//  两者以空格相接（旅行页既有写法）。
//  统一格式化的调用方还包括：计时器会话页的「本地响铃时间」、夏令时通知正文、日历页的日程区间
//  与例会漂移的钟点（原来是 DateIntervalFormatter 的「09:04 – 09:34」和 `%02d:%02d`）。区间只有一种写法：
//  「9:00–18:00」，短横两侧不带空格（排会页与天文页既有写法）；日期只在不是今年时才写年份。
//  `dateTime` 与换算页也改走 `day` 的年份规则，全 App 只剩旅行页行程一律写年（`Year.always`）；
//  各地时间行的跨日标注靠 `dayOffset`（Rust `window_places` 按它套「次日 / 前一日」模板）。
//

import Foundation

enum ClockText {
    /// 小时制对应的 hourCycle。跟随系统时取 `system` 的（`Locale.current.hourCycle` 已反映系统开关）。
    static func hourCycle(for style: HourStyle, system: Locale = .current) -> Locale.HourCycle {
        switch style {
        case .followSystem: system.hourCycle
        case .force12: .oneToTwelve
        case .force24: .zeroToTwentyThree
        }
    }

    /// 钟点用的 locale：与 `TimeFormatting.localeAndSignature` 同一套解析——跟随系统原样用，
    /// 强制时在系统 locale 上改 hourCycle。
    static func clockLocale(hourStyle: HourStyle, system: Locale = .current) -> Locale {
        switch hourStyle {
        case .followSystem:
            return system
        case .force12, .force24:
            var components = Locale.Components(locale: system)
            components.hourCycle = hourCycle(for: hourStyle, system: system)
            return Locale(components: components)
        }
    }

    /// 只有钟点的 FormatStyle（图表横轴等要交给别人格式化的地方用它，保证同一 hourCycle 与前导零）。
    static func timeStyle(in timeZone: TimeZone, hourStyle: HourStyle, system: Locale = .current) -> Date.FormatStyle {
        Date.FormatStyle(date: .omitted, time: .shortened,
                         locale: clockLocale(hourStyle: hourStyle, system: system),
                         calendar: .current, timeZone: timeZone)
    }

    /// 钟点文本：24 小时制「06:35」（en）/「6:35」（zh），12 小时制「6:35 AM」/「上午6:35」。
    static func time(_ date: Date, in timeZone: TimeZone, hourStyle: HourStyle, system: Locale = .current) -> String {
        date.formatted(timeStyle(in: timeZone, hourStyle: hourStyle, system: system))
    }

    /// 写不写年份。全 App 的日期默认只在不是「今年」时写年（`day` 的规则）；旅行页的行程日期是唯一例外，
    /// 一律写年。统一前有三种做法：`day` 同年不写、`dateTime` 一律写、
    /// 换算页另用 `Date.FormatStyle(date: .abbreviated)`。
    enum Year: Sendable {
        case whenNotCurrent
        case always
    }

    /// 日期加钟点：日期按界面语言 `locale`（年份规则同 `day`），钟点按系统 locale 与小时制，空格相接。
    /// 日期与星期按界面语言，钟点按小时制。
    static func dateTime(_ date: Date, in timeZone: TimeZone, hourStyle: HourStyle, locale: Locale,
                         now: Date = .now, year: Year = .whenNotCurrent, weekday: Bool = false,
                         system: Locale = .current) -> String {
        let day = day(date, in: timeZone, locale: locale, now: now, year: year, weekday: weekday)
        return "\(day) \(time(date, in: timeZone, hourStyle: hourStyle, system: system))"
    }

    /// 时钟调整那一刻的人话写法：「10月25日 2:00 → 1:00」——换钟前按旧偏移读、换钟后按新偏移读，
    /// 日期跟换钟前的读法（此前只按新偏移排版成「1:00」，读起来像「1 点再拨慢一小时」）。
    static func clockChange(at date: Date, before: Int, after: Int, hourStyle: HourStyle, locale: Locale,
                            now: Date = .now, weekday: Bool = false, system: Locale = .current) -> String {
        let old = TimeZone(secondsFromGMT: before) ?? .gmt
        let new = TimeZone(secondsFromGMT: after) ?? .gmt
        let day = day(date, in: old, locale: locale, now: now, weekday: weekday)
        return "\(day) \(time(date, in: old, hourStyle: hourStyle, system: system)) → \(time(date, in: new, hourStyle: hourStyle, system: system))"
    }

    /// 该地在 `date` 这一刻的当地日期比 `reference` 时区的当地日期晚几天：+1 = 次日，−1 = 前一日，0 = 同一天。
    /// 排会、例会轮换与日历页的「各地时间」行只在行首写一次日期，其余地点跨日时靠它标「次日 / 前一日」
    /// （Rust `presentation.window_places` 的 `dayOffset`）。比较的是各自时区里的年月日，不是 24 小时的倍数。
    static func dayOffset(of date: Date, in zone: TimeZone, from reference: TimeZone) -> Int {
        let components: Set<Calendar.Component> = [.year, .month, .day]
        let utc = Calendar.gregorianUTC(TimeZone(secondsFromGMT: 0)!)
        guard let here = utc.date(from: Calendar.gregorianUTC(zone).dateComponents(components, from: date)),
              let there = utc.date(from: Calendar.gregorianUTC(reference).dateComponents(components, from: date))
        else { return 0 }
        return utc.dateComponents([.day], from: there, to: here).day ?? 0
    }

    /// 一天里的第几分钟 → 钟点文本（可约时段、例会漂移的「此前 4:00」、分享页的可约时段）。
    /// 参照日固定为 2026-01-01 UTC（与排会页 `availability_label_date` 同一个），只取时间部分。
    static func minute(_ minuteOfDay: Int, hourStyle: HourStyle, system: Locale = .current) -> String {
        let date = Date(timeIntervalSince1970: PresentationCore.scalar("availability_label_date", ["minute": Double(minuteOfDay)]))
        return time(date, in: TimeZone(identifier: "UTC")!, hourStyle: hourStyle, system: system)
    }

    /// 「9:00–18:00」：全 App 的区间只有这一种写法，短横（U+2013）两侧不带空格。
    static func range(_ start: String, _ end: String) -> String { "\(start)–\(end)" }

    /// 一天里的两个分钟 → 「9:00–18:00」。
    static func minuteRange(_ start: Int, _ end: Int, hourStyle: HourStyle, system: Locale = .current) -> String {
        range(minute(start, hourStyle: hourStyle, system: system), minute(end, hourStyle: hourStyle, system: system))
    }

    /// 日期按界面语言，只在不是 `now` 那一年时才带年份：今天的日程写「9月14日」，明年的才写「2027年1月3日」；
    /// `year: .always` 一律写年，星期沿用面板的简称。
    static func day(_ date: Date, in timeZone: TimeZone, locale: Locale, now: Date = .now,
                    year: Year = .whenNotCurrent, weekday: Bool = false) -> String {
        var calendar = Calendar.current
        calendar.timeZone = timeZone
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: timeZone).month(.abbreviated).day()
        if year == .always || !sameYear { style = style.year() }
        if weekday { style = style.weekday(.abbreviated) }
        return date.formatted(style)
    }

    /// 「今天」「明天」或「10月5日 周一」：离 `now` 那一天差 0 或 1 天时用系统自己的说法（`RelativeDateTimeFormatter`
    /// 的命名写法，十六语都由系统给；`sentenceStart` 时按句首写法「Tomorrow」「Morgen」，否则句中小写），
    /// 再远照 `day` 的写法带星期。面板「找碰头时间」那一行用。
    static func relativeDay(_ date: Date, in timeZone: TimeZone, locale: Locale, now: Date = .now, sentenceStart: Bool = false) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day
        guard let days, days == 0 || days == 1 else {
            return day(date, in: timeZone, locale: locale, now: now, weekday: true)
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        formatter.formattingContext = sentenceStart ? .beginningOfSentence : .middleOfSentence
        return formatter.localizedString(from: DateComponents(day: days))
    }

    /// 「今天 9:00–11:00」「明天 7:00–8:00」「10月5日 周一 7:00–8:00」；跨过午夜写「今天 23:00–明天 1:00」。
    /// 日期用 `relativeDay`，钟点与区间写法同 `interval`。
    static func relativeInterval(from start: Date, to end: Date, in timeZone: TimeZone, hourStyle: HourStyle,
                                 locale: Locale, now: Date = .now, sentenceStart: Bool = false, system: Locale = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let startDay = relativeDay(start, in: timeZone, locale: locale, now: now, sentenceStart: sentenceStart)
        let startTime = time(start, in: timeZone, hourStyle: hourStyle, system: system)
        let endTime = time(end, in: timeZone, hourStyle: hourStyle, system: system)
        if calendar.isDate(start, inSameDayAs: end) { return "\(startDay) \(range(startTime, endTime))" }
        return range("\(startDay) \(startTime)", "\(relativeDay(end, in: timeZone, locale: locale, now: now)) \(endTime)")
    }

    /// 星期简称与面板相同，按该地日期取星期。
    static func weekday(_ date: Date, in timeZone: TimeZone, locale: Locale) -> String {
        date.formatted(Date.FormatStyle(locale: locale, timeZone: timeZone).weekday(.abbreviated))
    }

    /// 日历编号的星期简称：周日为 1。
    static func weekday(_ index: Int, locale: Locale) -> String {
        guard (1...7).contains(index) else { return "" }
        let sunday = Date(timeIntervalSince1970: 1_767_484_800) // 2026-01-04 UTC
        return weekday(sunday.addingTimeInterval(Double(index - 1) * 86_400), in: .gmt, locale: locale)
    }

    /// 日程区间：同一天「9月14日 18:40–19:10」，跨天「9月14日 23:30–9月15日 0:30」；
    /// 全天日程只写日期（多天「9月14日–9月16日」）。年份规则同 `day`。
    static func interval(from start: Date, to end: Date, in timeZone: TimeZone, hourStyle: HourStyle,
                         locale: Locale, allDay: Bool = false, now: Date = .now, system: Locale = .current) -> String {
        var calendar = Calendar.current
        calendar.timeZone = timeZone
        let sameDay = calendar.isDate(start, inSameDayAs: end)
        let startDay = day(start, in: timeZone, locale: locale, now: now)
        if allDay {
            return sameDay ? startDay : range(startDay, day(end, in: timeZone, locale: locale, now: now))
        }
        let startTime = time(start, in: timeZone, hourStyle: hourStyle, system: system)
        let endTime = time(end, in: timeZone, hourStyle: hourStyle, system: system)
        if sameDay { return "\(startDay) \(range(startTime, endTime))" }
        return range("\(startDay) \(startTime)", "\(day(end, in: timeZone, locale: locale, now: now)) \(endTime)")
    }

    // MARK: - 时长

    /// 时长文本「11小时30分钟」「1 day 2 hours」：拆成天 / 小时 / 分钟，各走字符串目录的「%lld 天」「%lld 小时」
    /// 「%lld 分钟」（数字与单位之间的空格由各语言译文定，单复数走目录的变体），为零的段不写，
    /// 不足一分钟写「0分钟」。此前各页各自用 DateComponentsFormatter / Duration.formatted，中文出来是「11小时」
    /// 「1小时5分钟」，与目录里的「1 小时」「8 小时」两种写法并存。
    /// 菜单栏的「◷ 12 min」不走这里：那里要的是最窄的系统缩写。
    ///
    /// 段与段的分隔：中文与日文不留空格（Apple 写法「11時間30分」「1天2小时」；
    /// 目录里单位前的空格也一并去掉了，这里再留空格就成了「11小时 30分钟」），其余语言一个空格。
    static func duration(seconds: Double, days: Bool = false, locale: Locale) -> String {
        var minutes = Int((seconds / 60).rounded())
        var parts: [(Int, String)] = []
        if days {
            parts.append((minutes / 1440, "%lld 天"))
            minutes %= 1440
        }
        parts.append((minutes / 60, "%lld 小时"))
        parts.append((minutes % 60, "%lld 分钟"))
        let written = parts.filter { $0.0 > 0 }
        return (written.isEmpty ? [(0, "%lld 分钟")] : written)
            .map { String(format: L10n.string($0.1, locale: locale), locale: locale, $0.0) }
            .joined(separator: separator(for: locale))
    }

    /// 方向句「3小时后」「2天3小时后」「2 days ago」：单位有独立的变格与复数模板（俄语「через 2 дня」、
    /// 德语「in 2 Tagen」）。一天以上写天与小时，面板滑块上面那一句与工具窗页首天色带那一句都走这里。
    static func durationIn(seconds: Double, locale: Locale) -> String {
        relativeDuration(seconds: seconds, locale: locale, template: "%@后")
    }

    static func durationAgo(seconds: Double, locale: Locale) -> String {
        relativeDuration(seconds: seconds, locale: locale, template: "%@前")
    }

    private static func relativeDuration(seconds: Double, locale: Locale, template: String) -> String {
        String(format: L10n.string(template, locale: locale), locale: locale,
               directionalDuration(seconds: seconds, locale: locale, days: true))
    }

    /// 方向句中的时长单位；介词与语序由调用方的句子模板给出。
    /// `days`：满一天时写「2天3小时」（小时四舍五入到整点，分钟不写：旁边总写着那一刻的钟点）；
    /// 不到一天照旧「17小时24分钟」。市场页的开收盘句还按小时与分钟写（`days` 默认关），轮到那一页时再定。
    static func directionalDuration(seconds: Double, locale: Locale, days: Bool = false) -> String {
        let minutes = Int((abs(seconds) / 60).rounded())
        let parts: [(Int, String)]
        if days, minutes >= 1440 {
            let hours = Int((Double(minutes) / 60).rounded())
            parts = [(hours / 24, "方向时长：%lld 天"), (hours % 24, "方向时长：%lld 小时")]
        } else {
            parts = [(minutes / 60, "方向时长：%lld 小时"), (minutes % 60, "方向时长：%lld 分钟")]
        }
        let written = parts.filter { $0.0 > 0 }
        return (written.isEmpty ? [(0, "方向时长：%lld 分钟")] : written)
            .map { String(format: L10n.string($0.1, locale: locale), locale: locale, $0.0) }
            .joined(separator: separator(for: locale))
    }

    /// 「0–1小时」「30–45分钟」：范围两端同一个单位时，前端只写数字（此前写成「0分钟–1小时」，一眼要读两遍单位；
    /// 读法因此更紧凑）。两端单位不同（「45分钟–2小时」）或后端不是整段时仍各写全。
    static func durationRange(lowSeconds: Double, highSeconds: Double, locale: Locale) -> (low: String, high: String) {
        let (low, high) = (Int((lowSeconds / 60).rounded()), Int((highSeconds / 60).rounded()))
        let high_text = duration(seconds: highSeconds, locale: locale)
        let sameUnit = (low % 60 == 0 && high % 60 == 0) || (low < 60 && high < 60)
        if low == 0 || sameUnit {
            let number = low % 60 == 0 && high % 60 == 0 && low > 0 ? low / 60 : low
            return (String(format: "%lld", locale: locale, number), high_text)
        }
        return (duration(seconds: lowSeconds, locale: locale), high_text)
    }

    /// 时长各段之间的分隔符。中文、日文不留空格，其余语言一个空格。
    private static func separator(for locale: Locale) -> String {
        switch locale.language.languageCode?.identifier {
        case "zh", "ja": return ""
        default: return " "
        }
    }
}
