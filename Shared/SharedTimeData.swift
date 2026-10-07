// SPDX-License-Identifier: GPL-3.0-only
import AppIntents
import Foundation

// 自动化命令的值类型与系统时区目录（Spotlight 与快捷指令用）。

nonisolated struct AutomationCommand: Codable, Sendable {
    var version = 1
    var id: UUID = UUID()
    var createdAt: Double = Date.now.timeIntervalSince1970
    let action: String
    var arguments: [String: String] = [:]
}

/// Each invocation has its own atomically written file, so independent extensions cannot lose each other's edits.
nonisolated enum TimeZonePlaceCatalog {
    struct Row: Sendable { let identifier: String; let city: String; let rawCity: String; let zone: String }

    static func cityName(_ identifier: String, locale: Locale = .current) -> String {
        cityName(identifier, formatter: exemplarFormatter(locale: locale))
    }
    /// One formatter can serve a whole locale (the Spotlight index names every identifier): only the zone changes.
    static func exemplarFormatter(locale: Locale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateFormat = "VVV"
        return formatter
    }
    static func cityName(_ identifier: String, formatter: DateFormatter) -> String {
        guard let zone = TimeZone(identifier: identifier) else { return rawCity(identifier) }
        formatter.timeZone = zone
        let name = formatter.string(from: Date(timeIntervalSinceReferenceDate: 0))
        if name.isEmpty || name == identifier || name.lowercased().contains("unknown") { return rawCity(identifier) }
        return name
    }
    static func rawCity(_ identifier: String) -> String {
        (identifier.split(separator: "/").last.map(String.init) ?? identifier).replacingOccurrences(of: "_", with: " ")
    }
    static func zoneName(_ identifier: String, locale: Locale = .current, at date: Date = .now) -> String {
        guard let zone = TimeZone(identifier: identifier) else { return "" }
        return ZoneNameDisplay.name(zone, at: date, locale: locale) ?? ""
    }
    static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil).lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// 随包 tzcoords.json（312 个时区代表城市）里这个标识符的经纬度；主程序的包里有这份文件。
    /// 昼夜地图给系统目录配置的地点定位用；没有就 nil（图上不画）。
    static func coordinate(for identifier: String) -> (latitude: Double, longitude: Double)? {
        coordinates[identifier].map { (latitude: $0[0], longitude: $0[1]) }
    }
    private static let coordinates: [String: [Double]] = {
        guard let url = Bundle.main.url(forResource: "tzcoords", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let table = try? JSONDecoder().decode([String: [Double]].self, from: data) else { return [:] }
        return table.filter { $0.value.count == 2 }
    }()

    static let suggestedIdentifiers: [String] = {
        var seen = Set<String>()
        return ([TimeZone.current.identifier, "America/Los_Angeles", "America/New_York", "America/Sao_Paulo", "Europe/London",
                 "Europe/Paris", "Europe/Berlin", "Europe/Moscow", "Asia/Dubai", "Asia/Kolkata", "Asia/Shanghai", "Asia/Tokyo",
                 "Asia/Seoul", "Asia/Singapore", "Australia/Sydney", "UTC"])
            .filter { TimeZone(identifier: $0) != nil && seen.insert($0).inserted }
    }()
    /// Every identifier the catalog offers: the system list plus the bare UTC/GMT identifiers that
    /// people type most often (knownTimeZoneIdentifiers omits them). Also what the Spotlight index covers.
    static let identifiers: [String] = {
        var identifiers = TimeZone.knownTimeZoneIdentifiers
        for extra in ["UTC", "GMT"] where TimeZone(identifier: extra) != nil && !identifiers.contains(extra) { identifiers.append(extra) }
        return identifiers
    }()
    /// Built once per process for the current locale (about 600 identifiers, a few dozen milliseconds).
    static let rows: [Row] = {
        identifiers.map { id in
            Row(identifier: id, city: fold(cityName(id)), rawCity: fold(rawCity(id)), zone: fold(zoneName(id)))
        }
    }()
    /// Prefix matches on the city first, then substring matches on city/identifier, then on the zone name.
    static func search(_ query: String, limit: Int = 40) -> [String] {
        let needle = fold(query)
        guard !needle.isEmpty else { return suggestedIdentifiers }
        var scored: [(String, Int)] = []
        for row in rows {
            let score: Int
            if row.city.hasPrefix(needle) || row.rawCity.hasPrefix(needle) { score = 0 }
            else if row.city.contains(needle) || row.rawCity.contains(needle) || fold(row.identifier.replacingOccurrences(of: "_", with: " ")).contains(needle) { score = 1 }
            else if row.zone.contains(needle) { score = 2 }
            else { continue }
            scored.append((row.identifier, score))
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0 < $1.0 }.prefix(limit).map(\.0)
    }
}

nonisolated struct TimeZonePlaceEntity: AppEntity, Sendable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "地点"
    static let defaultQuery = TimeZonePlaceQuery()
    let id: String
    var timeZone: TimeZone? { TimeZone(identifier: id) }
    var cityName: String { TimeZonePlaceCatalog.cityName(id) }
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(TimeZonePlaceCatalog.cityName(id))", subtitle: "\(TimeZonePlaceCatalog.zoneName(id))")
    }
}

nonisolated struct TimeZonePlaceQuery: EntityStringQuery, Sendable {
    func entities(for identifiers: [String]) async throws -> [TimeZonePlaceEntity] {
        identifiers.filter { TimeZone(identifier: $0) != nil }.map { TimeZonePlaceEntity(id: $0) }
    }
    func entities(matching string: String) async throws -> [TimeZonePlaceEntity] {
        TimeZonePlaceCatalog.search(string).map { TimeZonePlaceEntity(id: $0) }
    }
    func suggestedEntities() async throws -> [TimeZonePlaceEntity] {
        TimeZonePlaceCatalog.suggestedIdentifiers.map { TimeZonePlaceEntity(id: $0) }
    }
}
