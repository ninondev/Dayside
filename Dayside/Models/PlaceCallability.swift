// SPDX-License-Identifier: GPL-3.0-only
//
//  PlaceCallability.swift
//  Dayside
//
//  「现在能打给谁」。
//  这里只做 Apple 框架那部分：用 Foundation 在每个地点自己的时区里算「现在离下班还有多久」或
//  「还要多久才上班」——用真实日期推算，所以跨周末与跨夏令时都对。谁排前面、提示行给谁，
//  在 Rust `availability.callable_order`。
//

import Foundation

/// 一个地点此刻的可联系状态。两个数字互斥：在时段内给 `minutesLeft`，不在给 `minutesUntil`。
/// 时区解析不出来时两个都没有（Rust 会把它留在最后）。
struct PlaceCallability: Equatable, Sendable {
    let minutesLeft: Int?
    let minutesUntil: Int?

    var isCallable: Bool { minutesLeft != nil }

    /// 用的就是地点自己的「可约时段」（`TimeZoneEntry.effectiveAvailability`，排会页那一份），
    /// 没改过就是默认的当地 9:00–18:00、只算工作日。别在这里另存一份默认值。

    /// 往后最多找几天的下一段（周末 + 连休也够；找不到就当不知道）。
    private static let searchDays = 9

    /// 周末按**该地所在国家 / 地区**的 ICU 数据判（以色列周五六、海湾周五六都对），
    /// 与排会页用的是同一个出口 `OverlapPlanner.calendar(for:countryCode:)`。
    static func compute(timeZone: TimeZone, now: Date, countryCode: String?,
                        window: Availability = .standard) -> PlaceCallability {
        let calendar = OverlapPlanner.calendar(for: timeZone, countryCode: countryCode)
        let parts = calendar.dateComponents([.hour, .minute], from: now)
        guard let hour = parts.hour, let minute = parts.minute else {
            return PlaceCallability(minutesLeft: nil, minutesUntil: nil)
        }
        let minuteOfDay = hour * 60 + minute
        // 可约时段允许跨午夜（22:00–06:00），判据与剩余分钟都要按这个分情况算。
        let crossesMidnight = window.endMinute <= window.startMinute
        let inWindow = crossesMidnight
            ? (minuteOfDay >= window.startMinute || minuteOfDay < window.endMinute)
            : (minuteOfDay >= window.startMinute && minuteOfDay < window.endMinute)
        // 在时段内：还剩多久按墙钟算（用户想的就是「他 18:00 下班」，换钟日那天以钟面为准）。
        if inWindow, allows(now, calendar: calendar, window: window) {
            let left = crossesMidnight
                ? (window.endMinute + 1440 - minuteOfDay) % 1440
                : window.endMinute - minuteOfDay
            return PlaceCallability(minutesLeft: left, minutesUntil: nil)
        }
        // 不在时段内：找下一次「允许的日子 + 起点钟点」的真实时刻，差值用 Date 算（跨夏令时也准）。
        for offset in 0...searchDays {
            guard let day = calendar.date(byAdding: .day, value: offset, to: now),
                  let start = calendar.date(bySettingHour: window.startMinute / 60,
                                            minute: window.startMinute % 60, second: 0, of: day),
                  start > now,
                  allows(start, calendar: calendar, window: window)
            else { continue }
            return PlaceCallability(minutesLeft: nil,
                                    minutesUntil: Int((start.timeIntervalSince(now) / 60).rounded()))
        }
        return PlaceCallability(minutesLeft: nil, minutesUntil: nil)
    }

    private static func allows(_ date: Date, calendar: Calendar, window: Availability) -> Bool {
        guard window.weekdaysOnly else { return true }
        return !calendar.isDateInWeekend(date)
    }
}

/// Rust `availability.callable_order` 的答复：排好的 id、有几个现在能打、下一个能打的是谁与还要多久。
struct CallableOrder: Decodable {
    let order: [UUID]
    let callableCount: Int
    let nextID: UUID?
    let nextInMinutes: Int?

    static func compute(_ states: [(id: UUID, state: PlaceCallability)]) -> CallableOrder {
        struct Entry: Encodable { let id: UUID; let minutesLeft: Int?; let minutesUntil: Int? }
        struct Input: Encodable { let entries: [Entry] }
        let entries = states.map { Entry(id: $0.id, minutesLeft: $0.state.minutesLeft, minutesUntil: $0.state.minutesUntil) }
        return RustCore.invoke("availability.callable_order", Input(entries: entries))
    }

    /// 提示只看本机时区之外的地点，不改变整表排序。
    static func compute(_ states: [(id: UUID, state: PlaceCallability)], zones: [TimeZoneEntry],
                        excluding home: TimeZone) -> CallableOrder {
        let excluded = Set(zones.filter { $0.timeZone == home }.map(\.id))
        return compute(states.filter { !excluded.contains($0.id) })
    }
}
