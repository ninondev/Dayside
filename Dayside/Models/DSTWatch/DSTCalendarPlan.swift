// SPDX-License-Identifier: GPL-3.0-only
//
//  DSTCalendarPlan.swift
//  Dayside
//
//  把「未来 12 个月里这些地点的每一次时钟调整」做成可以加进日历的事件。
//  事实只问 Foundation 的 `nextDaylightSavingTimeTransition(after:)`——本文件不自带任何时区规则表
//  (那张表在 Rust `tzdata.rs`,只用来判断本机数据是否落后,不用来算换钟时刻)。
//  说明文字复用 `MeetingEvent` 那条管道(`meeting.notes` 排版、`meeting.ics_series` 序列化),
//  写日历那一侧仍是 `CalendarExporter.export(series:)`,这里不碰 EventKit。
//

import Foundation

/// 一次时钟调整:哪个时区、什么时刻、调整前后的 UTC 偏移(秒)。
nonisolated struct DSTClockChange: Hashable, Identifiable, Sendable {
    let zone: String
    let at: Date
    let beforeSeconds: Int
    let afterSeconds: Int

    /// 偏移变大 = 进入夏令时,变小 = 退出。南半球同理(悉尼 +10 → +11 是进入)。
    var entersDaylightTime: Bool { afterSeconds > beforeSeconds }
    var id: String { "\(zone)@\(at.timeIntervalSince1970)" }
}

nonisolated enum DSTCalendarPlan {
    /// 只看未来一年:再远的规则常常还没定,日历里摆着也没用。
    static let months = 12
    /// 事件时长:换钟是一个时刻,给一小时的块让它在日历里看得见。
    static let eventDuration: TimeInterval = 3600
    /// 单个时区在窗口内最多取这么多次。一年最多 4 次(斋月前后停复夏令时的几个时区),8 是保险数,
    /// 也保证时区数据异常时循环有界。
    private static let perZoneLimit = 8

    /// 各地点未来 `months` 个月内的每一次时钟调整,按时刻排序;同一 IANA 标识符只算一次。
    static func changes(zones: [String], from: Date, months: Int = months) -> [DSTClockChange] {
        let end = Calendar.gregorianUTC(TimeZone(secondsFromGMT: 0) ?? .gmt)
            .date(byAdding: .month, value: months, to: from) ?? from
        guard end > from else { return [] }
        var seen: Set<String> = []
        var result: [DSTClockChange] = []
        for identifier in zones where seen.insert(identifier).inserted {
            guard let zone = TimeZone(identifier: identifier) else { continue }
            var cursor = from
            for _ in 0..<perZoneLimit {
                guard let transition = zone.nextDaylightSavingTimeTransition(after: cursor),
                      transition > cursor, transition <= end else { break }
                let before = zone.secondsFromGMT(for: transition.addingTimeInterval(-1))
                let after = zone.secondsFromGMT(for: transition)
                // 偏移没变的「转换」不是换钟：摩洛哥斋月前后只翻 isDST 标志，钟面一分钟都不动
                // 。放进列表会让用户以为要拨钟，也会让「加进日历」排出空事件。
                if before != after {
                    result.append(DSTClockChange(zone: identifier, at: transition,
                                                 beforeSeconds: before, afterSeconds: after))
                }
                cursor = transition
            }
        }
        return result.sorted { ($0.at, $0.zone) < ($1.at, $1.zone) }
    }

    /// 做成日历事件。`names` 是「时区标识符 → 地名」,由调用方从 `TimeCore.placeName` 取(界面上不出现
    /// `Europe/London` 这类内部 ID);缺名时退回去掉下划线的标识符。
    /// 标题与说明都是模型层文本,按界面语言查表,不用 `String(localized:locale:)`。
    static func events(changes: [DSTClockChange], names: [String: String] = [:],
                       locale: Locale, hourStyle: HourStyle) -> [MeetingEvent] {
        let footer = L10n.string("用 Dayside 生成", locale: locale)
        let template = L10n.string("%1$@ → %2$@，%3$@ → %4$@", locale: locale)
        let format = ClockFormat(hourStyle: hourStyle, showSeconds: false)
        return changes.map { change in
            let place = placeName(change.zone, names: names)
            let title = String(format: L10n.string(change.entersDaylightTime ? "%@ 进入夏令时" : "%@ 退出夏令时",
                                                   locale: locale), locale: locale, place)
            // 换钟当刻的两个墙钟读数:用固定偏移的时区各渲染一次,避开「这一小时不存在 / 重复一次」的歧义。
            let before = TimeFormatting.string(for: change.at, in: TimeZone(secondsFromGMT: change.beforeSeconds) ?? .gmt,
                                               format: format)
            let after = TimeFormatting.string(for: change.at, in: TimeZone(secondsFromGMT: change.afterSeconds) ?? .gmt,
                                              format: format)
            let text = String(format: template, locale: locale, before, after,
                              TZDataCheck.offsetLabel(change.beforeSeconds / 60),
                              TZDataCheck.offsetLabel(change.afterSeconds / 60))
            return MeetingEvent(title: title, start: change.at, end: change.at.addingTimeInterval(eventDuration),
                                lines: [MeetingEvent.Line(name: place, text: text)], footer: footer)
        }
    }

    static func placeName(_ identifier: String, names: [String: String]) -> String {
        let name = names[identifier] ?? ""
        return name.isEmpty ? identifier.replacingOccurrences(of: "_", with: " ") : name
    }
}
