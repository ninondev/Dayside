// SPDX-License-Identifier: GPL-3.0-only
//
//  Localization.swift
//  Dayside
//
//  两件本地化基础设施:
//  ① `L10n.string` —— 按指定语言的 .lproj 直接查表,在任意语言下取串(不受系统当前语言影响)。
//     SwiftUI 的 `Text` 会随环境 `\.locale` 自动本地化;但必须是 `String` 的 AppKit 接口
//     (NSSearchField 的 placeholder)拿不到环境,改用本助手按界面语言取串。
//  ② `LocalizedZoneNames` —— 时区"代表城市"的本地化名(Tokyo→东京/東京/도쿄/Tokio…)。
//     数据源是系统 ICU(`DateFormatter` 的 "VVV" 字段),与苹果世界时钟同源,**不手工维护城市表**。
//     按 locale 缓存,搜索热路径也够快。
//

import Foundation

enum L10n {
    // 已解析的 .lproj bundle 按 locale 缓存:避免每次(尤其搜索每个按键都重渲)再做文件系统
    // `path(forResource:)` 查找。bundle 数极少、有界。
    private static let lock = NSLock()
    private nonisolated(unsafe) static var bundleCache: [String: Bundle] = [:]

    /// 取 `key` 在 `locale` 对应语言下的本地化串;找不到该语言则回退主 bundle(= 开发语言)。
    static func string(_ key: String, locale: Locale) -> String {
        localizedBundle(for: locale).localizedString(forKey: key, value: key, table: nil)
    }

    private static func localizedBundle(for locale: Locale) -> Bundle {
        let id = locale.identifier
        lock.lock()
        if let hit = bundleCache[id] { lock.unlock(); return hit }
        lock.unlock()

        let candidates: [String?] = [
            locale.identifier,                       // "zh-Hans" / "pt-BR" / "en_US"
            locale.language.minimalIdentifier,       // 收敛形
            locale.language.languageCode?.identifier // "en" / "zh" …
        ]
        var resolved = Bundle.main
        var found = false
        for code in candidates.compactMap({ $0 }) where !code.isEmpty {
            if let path = Bundle.main.path(forResource: code, ofType: "lproj"),
               let bundle = Bundle(path: path) {
                resolved = bundle
                found = true
                break
            }
        }
        // 名字对不上文件夹时交给系统的语言匹配：葡萄牙的 pt-PT 用 pt-BR、zh-HK 用 zh-Hant、fr-CA 用 fr。
        // 只认同一种语言的匹配，系统找不到时塞回来的别的语言不算（那种情况照旧退回主 bundle）。
        if !found,
           let match = Bundle.preferredLocalizations(from: Bundle.main.localizations.filter { $0 != "Base" },
                                                     forPreferences: [locale.language.maximalIdentifier]).first,
           Locale.Language(identifier: match).languageCode == locale.language.languageCode,
           let path = Bundle.main.path(forResource: match, ofType: "lproj"), let bundle = Bundle(path: path) {
            resolved = bundle
        }
        lock.lock(); bundleCache[id] = resolved; lock.unlock()
        return resolved
    }
}

/// ICU is the native name provider. Cache lifetime, folding and fallback
/// decisions live in Rust and are shared by the search and display adapters.
final class LocalizedZoneNames: Sendable {
    static let shared = LocalizedZoneNames()
    private struct Query: Encodable {
        let localeID: String
        let timezoneID: String
        var folded: Bool = false
        var computed: String? = nil
        var name: String? = nil
    }
    func cityName(_ timezoneID: String, locale: Locale) -> String {
        let query = Query(localeID: locale.identifier, timezoneID: timezoneID)
        if let cached: String = RustCore.invoke("catalog.name_get", query) { return cached }
        let computed: String?
        if let zone = TimeZone(identifier: timezoneID) {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = zone
            formatter.dateFormat = "VVV"
            computed = formatter.string(from: Date(timeIntervalSinceReferenceDate: 0))
        } else { computed = nil }
        return RustCore.invoke("catalog.name_finish", Query(localeID: locale.identifier, timezoneID: timezoneID, computed: computed))
    }
}
