// SPDX-License-Identifier: GPL-3.0-only
//
//  CalendarExporter.swift
//  Dayside
//
//  把 MeetingEvent 送进用户的日历。主路 EventKit **只写**权限(macOS 14 起的
//  `requestWriteOnlyAccessToEvents`:只能添加、读不到任何已有日程,这是能申请的最小权限);
//  被拒 / 受限 / 没有可写日历 / 保存失败 → 退路是写一份 .ics 交给系统默认日历 app 打开,
//  用户在日历 app 的导入框里自己挑日历。两条路都不常驻:EKEventStore 每次导出临时建、用完即弃,
//  没有变更观察者。
//

import AppKit
import EventKit
import Foundation

@MainActor
enum CalendarExporter {
    enum Outcome: Equatable, Sendable {
        /// 已直接写进日历(默认日历)。
        case added(calendarTitle: String)
        /// 没有写权限或写入失败,已改为让日历 app 打开 .ics。
        case openedICS(reason: Reason)
        /// 连 .ics 都没法交出去(极端情况)。
        case failed(String)
    }

    enum Reason: Equatable, Sendable {
        case accessDenied, noWritableCalendar, saveFailed
    }

    /// 是否可能拿到写权限(未决定 / 已授权 / 只写)。`.denied` 与 `.restricted` 直接走 .ics,不再打扰用户。
    static var canAskForAccess: Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined, .fullAccess, .writeOnly: return true
        default: return false
        }
    }

    static func export(_ event: MeetingEvent) async -> Outcome { await export(series: [event]) }

    /// 多场一起写(例会轮换):全部保存成功才算加入,任何一场失败就整批改走 .ics,不留半批。
    static func export(series events: [MeetingEvent]) async -> Outcome {
        guard !events.isEmpty else { return .failed("no events") }
        if canAskForAccess {
            let store = EKEventStore()
            let granted = (try? await store.requestWriteOnlyAccessToEvents()) ?? false
            if granted {
                guard let calendar = store.defaultCalendarForNewEvents else {
                    return openICS(series: events, reason: .noWritableCalendar)
                }
                do {
                    for event in events {
                        let ek = EKEvent(eventStore: store)
                        ek.title = event.title
                        ek.startDate = event.start
                        ek.endDate = event.end
                        ek.notes = event.notes
                        ek.calendar = calendar
                        try store.save(ek, span: .thisEvent, commit: false)
                    }
                    try store.commit()
                    return .added(calendarTitle: calendar.title)
                } catch {
                    store.reset()
                    return openICS(series: events, reason: .saveFailed)
                }
            }
            return openICS(series: events, reason: .accessDenied)
        }
        return openICS(series: events, reason: .accessDenied)
    }

    /// 写一份 .ics 到临时目录并交给系统默认日历 app。
    static func openICS(_ event: MeetingEvent, reason: Reason) -> Outcome { openICS(series: [event], reason: reason) }

    static func openICS(series events: [MeetingEvent], reason: Reason) -> Outcome {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Dayside-\(UUID().uuidString.prefix(8)).ics")
        do {
            try MeetingEvent.icsSeriesText(events).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return .failed(error.localizedDescription)
        }
        guard NSWorkspace.shared.open(url) else {
            return .failed("open .ics failed")
        }
        return .openedICS(reason: reason)
    }
}
