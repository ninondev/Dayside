// SPDX-License-Identifier: GPL-3.0-only
//
//  MeetingEvent.swift
//  Dayside
//
//  把一个碰头窗口做成「可以加进日历的事件」:标题、各地时间写全的说明、iCalendar(.ics)文本。
//  纯值类型 + 纯函数;EventKit 那一侧在 CalendarExporter。
//
//  说明里每个地点一行(城市 · 该地日期 · 该地时间段 · 缩写)，保留各地的完整读法：
//  「一键生成日历事件,描述里写全各地时间」——对方打开邀请就看到自己那边几点,不用再换算。
//

import Foundation

struct MeetingEvent: Hashable, Sendable {
    struct Line: Codable, Hashable, Sendable {
        let name: String
        let text: String
    }

    let title: String
    let start: Date
    let end: Date
    /// 各地时间行(顺序同参与者)。
    let lines: [Line]
    /// 结尾署名行。
    let footer: String

    /// 事件说明(多行文本):各地时间 + 署名。
    var notes: String {
        RustCore.invoke("meeting.notes", NotesInput(lines: lines, footer: footer))
    }

    /// 起止时刻直接给（拆成 N 场的每一场没有 `Window`，用的是同一套各地时间行）。
    static func make(start: Date, end: Date, names: [String], timeZones: [TimeZone],
                     offsetOnlyZoneNames: [Bool] = [],
                     title: String, footer: String, locale: Locale, hourStyle: HourStyle) -> MeetingEvent {
        let inputs = zip(names, timeZones).enumerated().map { index, pair in
            let (name, tz) = pair
            let offsetOnly = offsetOnlyZoneNames.indices.contains(index) && offsetOnlyZoneNames[index]
            return LocalTimeInput(
                name: name,
                day: start.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale, timeZone: tz).weekday(.abbreviated)),
                startTime: TimeFormatting.string(for: start, in: tz, format: ClockFormat(hourStyle: hourStyle, showSeconds: false)),
                endTime: TimeFormatting.string(for: end, in: tz, format: ClockFormat(hourStyle: hourStyle, showSeconds: false)),
                endDay: end.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale, timeZone: tz)),
                sameDay: Calendar.gregorianUTC(tz).isDate(start, inSameDayAs: end),
                offsetChanged: tz.secondsFromGMT(for: start) != tz.secondsFromGMT(for: end),
                startAbbreviation: ZoneNameDisplay.abbreviation(tz, at: start, offsetOnly: offsetOnly),
                endAbbreviation: ZoneNameDisplay.abbreviation(tz, at: end, offsetOnly: offsetOnly))
        }
        let lines = RustCore.invoke("meeting.lines", inputs, as: [Line].self)
        return MeetingEvent(title: title, start: start, end: end, lines: lines, footer: footer)
    }

    // MARK: - Rust serialization

    /// RFC 5545 escaping, UTC timestamps and byte-limited line folding are owned by Rust.
    func icsText(uid: String = UUID().uuidString, stamp: Date = .now) -> String {
        RustCore.invoke("meeting.ics", EventInput(title: title, start: start.timeIntervalSince1970,
                                                 end: end.timeIntervalSince1970, lines: lines, footer: footer,
                                                 uid: uid, stamp: stamp.timeIntervalSince1970))
    }

    /// 多场会议合成一份 .ics(一个 VCALENDAR 里多个 VEVENT),例会轮换一次导入。
    static func icsSeriesText(_ events: [MeetingEvent], stamp: Date = .now) -> String {
        RustCore.invoke("meeting.ics_series", events.map { event in
            EventInput(title: event.title, start: event.start.timeIntervalSince1970, end: event.end.timeIntervalSince1970,
                       lines: event.lines, footer: event.footer, uid: UUID().uuidString, stamp: stamp.timeIntervalSince1970)
        })
    }

    static func utcStamp(_ date: Date) -> String {
        RustCore.invoke("meeting.utc_stamp", date.timeIntervalSince1970)
    }

    static func escape(_ text: String) -> String { RustCore.invoke("meeting.escape", text) }
    static func fold(_ line: String) -> [String] { RustCore.invoke("meeting.fold", line) }

    private struct NotesInput: Encodable {
        let lines: [Line]
        let footer: String
    }

    private struct EventInput: Encodable {
        let title: String
        let start: Double
        let end: Double
        let lines: [Line]
        let footer: String
        let uid: String
        let stamp: Double
    }

    /// Foundation must still format system-localized dates, time styles and timezone abbreviations.
    private struct LocalTimeInput: Encodable {
        let name: String
        let day: String
        let startTime: String
        let endTime: String
        let endDay: String
        let sameDay: Bool
        let offsetChanged: Bool
        let startAbbreviation: String
        let endAbbreviation: String
    }

}
