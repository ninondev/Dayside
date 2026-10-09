// SPDX-License-Identifier: GPL-3.0-only
//
//  TimeFormatting.swift
//  Dayside
//
//  时间格式化。**默认跟随系统**:.current locale 已反映系统"24 小时制"开关。
//  秒制与分钟制**统一走 Date.FormatStyle**(经 localeAndSignature 记忆化 + style 缓存后 ~1µs/次),
//  保证 AM/PM 位置、中文弹性时段(清晨/上午/下午/晚上)、各语言数字全部本地化正确。
//  强制 12/24 通过改 locale 的 hourCycle 实现,默认不强制。
//  优化:① localeAndSignature 记忆化(见下);② FormatStyle 按 style 缓存;
//  ③ **分钟制**结果按 (分钟桶,时区,制式,locale) 缓存(菜单栏+面板常在同一 tick 对同一时区重复格式化);
//  秒制每秒只用一次、缓存无益,故不缓存、直接格式化。
//

import Foundation

/// 时钟 tick 的边界对齐。**唯一实现**——AppModel 的面板时钟与 MenuBarTick 的菜单栏时钟过去
/// 各写了一份逐字相同的表达式,改一处漏一处的风险白拿。
enum ClockTick {
    /// 距下一个整秒(显示秒)/ 整分(否则)的时长。对齐边界 → 数字恰好在边界翻动、不漂移。
    static func nextBoundary(showSeconds: Bool, now: Date = .now) -> Duration {
        .seconds(mt_clock_boundary(now.timeIntervalSince1970, showSeconds))
    }
}

enum TimeFormatting {
    private struct CacheKey: Codable {
        let unix: Double
        let timeZoneID: String
        let hourStyle: String
        let localeSignature: String
    }

    private struct StyleKey: Hashable {
        var timeZoneID: String
        var hourStyle: HourStyle
        var showSeconds: Bool
        var localeSignature: String
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var styles: [StyleKey: Date.FormatStyle] = [:]

    // localeAndSignature 的记忆化:它在每次 string(...) 里、缓存查找**之前**都要跑,原实现每次都
    // `Locale.Components(locale:)` 分解整个 locale(~1.3µs)+ `String(describing:)` 反射(~0.4µs),
    // 而结果只由 (系统 locale 标识, 有效 hourCycle, 日历) 决定——这三者正是签名依赖的全部输入。
    // 用这三者作令牌(全是便宜的直接属性:identifier/hourCycle/calendar.identifier ~50ns 合计)记忆化,
    // 系统改「24 小时制」/ 语言 / 日历时令牌变→重算,故对系统设置切换仍**实时**(与旧版同源、行为不变)。
    private struct LocaleToken: Equatable {
        var identifier: String
        var hourCycle: Locale.HourCycle
        var calendar: Calendar.Identifier
    }
    private nonisolated(unsafe) static var localeToken: LocaleToken?
    private nonisolated(unsafe) static var localeResolved: [HourStyle: (Locale, String)] = [:]

    static func string(for date: Date, in tz: TimeZone, format: ClockFormat) -> String {
        let (locale, signature) = localeAndSignature(for: format.hourStyle)
        let style = style(for: format, timeZone: tz, locale: locale, localeSignature: signature)

        // 秒制:每秒的值只用一次,缓存无益;直接用(已缓存的)FormatStyle 格式化。
        // 与分钟制走同一条本地化路径 → AM/PM 位置、中文弹性时段、各语言数字全部正确。
        if format.showSeconds {
            return date.formatted(style)
        }

        // 分钟制:菜单栏 + 面板常在同一 tick 对同一 (分钟桶,时区) 重复格式化 → 缓存命中省重复格式化。
        let key = CacheKey(unix: date.timeIntervalSince1970, timeZoneID: tz.identifier,
                           hourStyle: format.hourStyle.rawValue, localeSignature: signature)
        let hit: String? = RustCore.invoke("cache.time_get", key)
        if let hit { return hit }
        let value = date.formatted(style)
        struct Insert: Encodable { let key: CacheKey; let value: String }
        let _: Bool = RustCore.invoke("cache.time_put", Insert(key: key, value: value))
        return value
    }

    private static func style(for format: ClockFormat, timeZone: TimeZone,
                              locale: Locale, localeSignature: String) -> Date.FormatStyle {
        let key = StyleKey(timeZoneID: timeZone.identifier, hourStyle: format.hourStyle,
                           showSeconds: format.showSeconds, localeSignature: localeSignature)

        lock.lock()
        if let hit = styles[key] { lock.unlock(); return hit }
        lock.unlock()

        let time: Date.FormatStyle.TimeStyle = format.showSeconds ? .standard : .shortened
        let style = Date.FormatStyle(date: .omitted, time: time,
                                     locale: locale,
                                     calendar: .current, timeZone: timeZone)

        lock.lock()
        if styles.count > 128 { styles.removeAll(keepingCapacity: true) }
        styles[key] = style
        lock.unlock()
        return style
    }

    /// hourCycle 的稳定短标签(免 `String(describing:)` 反射,仅作缓存键的区分符)。
    private static func hourCycleTag(_ hc: Locale.HourCycle) -> String {
        switch hc {
        case .zeroToEleven:      return "h11"
        case .oneToTwelve:       return "h12"
        case .zeroToTwentyThree: return "h23"
        case .oneToTwentyFour:   return "h24"
        @unknown default:        return "h?"
        }
    }

    private static func localeAndSignature(for style: HourStyle) -> (Locale, String) {
        let current = Locale.current
        // 令牌用便宜的直接属性(current.hourCycle 与旧版 Locale.Components(...).hourCycle 取值一致,
        // 已用 15 时区 × 3 制 × 2 秒 × 4000 时刻 = 36 万例逐字节等价核对)。
        let token = LocaleToken(identifier: current.identifier,
                                hourCycle: current.hourCycle,
                                calendar: Calendar.current.identifier)
        lock.lock()
        if localeToken != token { localeToken = token; localeResolved.removeAll(keepingCapacity: true) }
        if let hit = localeResolved[style] { lock.unlock(); return hit }
        lock.unlock()

        let result: (Locale, String)
        switch style {
        case .followSystem:
            result = (current, "\(token.identifier)|\(hourCycleTag(token.hourCycle))|\(token.calendar)")
        case .force24:
            var c = Locale.Components(locale: current); c.hourCycle = .zeroToTwentyThree
            result = (Locale(components: c), "\(token.identifier)|24|\(token.calendar)")
        case .force12:
            var c = Locale.Components(locale: current); c.hourCycle = .oneToTwelve
            result = (Locale(components: c), "\(token.identifier)|12|\(token.calendar)")
        }
        lock.lock(); localeResolved[style] = result; lock.unlock()
        return result
    }
}
