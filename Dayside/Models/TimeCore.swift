// SPDX-License-Identifier: GPL-3.0-only
//
//  TimeCore.swift
//  Dayside
//
//  只读的时间核。面板各行、菜单栏标签与透镜只依赖它：
//  当前时刻、穿梭偏移、条目表、设置、系统变更版本号,以及由设置推出的语言与命名。
//  **只有 AppModel 写它**(同模块 internal setter),视图一律只读;
//  写操作(增删改、跳转、面板可见性、持久化)全在 AppModel。
//

import Foundation
import Observation

@MainActor
@Observable
final class TimeCore {
    /// 当前时刻,仅在面板打开时由 AppModel 的时钟推进;菜单栏标签用局部 tick 自己走。
    var now: Date = .now

    /// 面板行 / 太阳弧实际读的偏移(经 AppModel 节流,≤~30Hz)。
    var displayOffset: TimeInterval = 0

    /// 时区条目。增删改一律走 AppModel 的方法(方法内显式持久化)。
    var zones: [TimeZoneEntry]

    /// 全局设置。改动走 AppModel.settings 的 setter(那里分发副作用与落盘)。
    var settings: AppSettings

    /// 系统环境(语言 / 时区 / 时钟)的变更版本号,菜单栏与面板读它重渲。
    var systemRevision = 0

    init(zones: [TimeZoneEntry], settings: AppSettings) {
        self.zones = zones
        self.settings = settings
    }

    /// 面板里所有时区行读这个;= now + 节流后的偏移。
    var referenceDate: Date { Date(timeIntervalSince1970: mt_reference_date(now.timeIntervalSince1970, displayOffset)) }

    /// 是否处于穿梭(非实时)状态。读 displayOffset,拖动时整条面板只按 ~30Hz 重渲。
    var isScrubbing: Bool { mt_is_scrubbing(displayOffset) }

    // MARK: - 语言(界面 / 城市,各自独立)

    /// 界面语言对应的 locale;.system 跟随系统,但只落在有译文的语言上,没有就用英文(`InterfaceLanguage.systemLocale`)。
    var uiLocale: Locale {
        if let id = settings.interfaceLanguage.localeIdentifier { return Locale(identifier: id) }
        return InterfaceLanguage.systemLocale()
    }

    /// 城市显示语言对应的 locale:跟随界面 / 跟随系统 / 指定语言。`.none` 不参与(走原始名)。
    var cityLocale: Locale {
        let language: String = RustCore.invoke("model.city_locale", ["city": settings.cityLanguage.rawValue, "interface": settings.interfaceLanguage.rawValue])
        return locale(for: language)
    }
    private func locale(for language: String) -> Locale {
        let identifier: String? = RustCore.invoke("settings.locale", ["language": language])
        return identifier.map(Locale.init(identifier:)) ?? .autoupdatingCurrent
    }

    /// 城市搜索用 locale:`.none` 时为 nil(只按英文/identifier 搜,不叠本地化名)。
    var citySearchLocale: Locale? {
        let language: String? = RustCore.invoke("model.city_search_locale", ["city": settings.cityLanguage.rawValue, "interface": settings.interfaceLanguage.rawValue])
        return language.map { locale(for: $0) }
    }

    // MARK: - 命名

    /// 始终可读的城市名(给「重命名默认值」用,绝不为空)。
    /// 具体城市条目(Munich / 时区 Europe/Berlin)必须用存下来的名字:ICU 只认时区,会答"柏林"。
    private func resolveName(raw: String, identifier: String, exemplar: Bool, hide: Bool, names: () -> [String: String]?) -> String {
        struct Source: Encodable { let cityLanguage: String; let exemplar: Bool; let hide: Bool }
        let source: String = RustCore.invoke("model.name_source", Source(cityLanguage: settings.cityLanguage.rawValue, exemplar: exemplar, hide: hide))
        switch source {
        case "hidden": return ""
        case "raw": return raw
        case "system": return LocalizedZoneNames.shared.cityName(identifier, locale: cityLocale)
        default:
            struct Input: Encodable { let candidate: String?; let raw: String }
            let candidate = names().flatMap { CityNameLanguage.name(from: $0, locale: cityLocale) }
            return RustCore.invoke("model.stored_name", Input(candidate: candidate, raw: raw))
        }
    }
    func cityName(for entry: TimeZoneEntry) -> String {
        resolveName(raw: entry.cityName, identifier: entry.timezoneID, exemplar: entry.usesExemplarName, hide: false) { entry.localizedNames }
    }
    func displayName(for option: ZoneOption) -> String {
        resolveName(raw: option.cityName, identifier: option.identifier, exemplar: option.source == .zone, hide: false) {
            option.cityIndex.map { CityIndex.shared.localizedNames(cityIndex: $0) }
        }
    }
    func localizedCity(_ entry: TimeZoneEntry) -> String {
        resolveName(raw: entry.cityName, identifier: entry.timezoneID, exemplar: entry.usesExemplarName, hide: true) { entry.localizedNames }
    }
    /// 时区标识符的用户可读地名：已添加的地点用其显示名，否则用本地化代表城市名（Rust catalog 缓存），
    /// 两者都没有才退回去掉下划线的标识符。界面上不直接显示 `Europe/London` 这类内部 ID。
    func placeName(forTimeZoneID identifier: String) -> String {
        if let entry = zones.first(where: { $0.timezoneID == identifier }) {
            return entry.displayName(localizedCity: cityName(for: entry))
        }
        let name = LocalizedZoneNames.shared.cityName(identifier, locale: cityLocale)
        return name.isEmpty ? identifier.replacingOccurrences(of: "_", with: " ") : name
    }
    /// 地名加通用时区名；指定地点按自己的显示规则取名，不能借同一时区里另一座城的规则。
    /// 没有地点上下文时只按时区本身判断，Asia/Jerusalem 不因已添加戈兰居民点而改名。
    func zoneCaption(for timeZone: TimeZone, entry: TimeZoneEntry? = nil, at date: Date? = nil) -> String {
        let place = entry.map { $0.displayName(localizedCity: cityName(for: $0)) }
            ?? LocalizedZoneNames.shared.cityName(timeZone.identifier, locale: cityLocale)
        guard let generic = ZoneNameDisplay.name(timeZone, at: date ?? referenceDate, locale: uiLocale,
                                                offsetOnly: entry?.offsetOnlyZoneName ?? false), generic != place else { return place }
        return "\(place) · \(generic)"
    }

    /// 旅行等页面按选中的地点取时区缩写；同一时区的其他条目不能替它决定显示规则。
    func zoneAbbreviation(forTimeZoneID identifier: String, placeID: UUID?, at date: Date) -> String {
        let entry = zones.first { $0.id == placeID && $0.timezoneID == identifier }
        return ZoneNameDisplay.abbreviation(TimeZone(identifier: identifier) ?? .gmt, at: date,
                                            offsetOnly: entry?.offsetOnlyZoneName ?? false)
    }
}
