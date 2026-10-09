// SPDX-License-Identifier: GPL-3.0-only
// Native locale providers plus thin DTOs. Display policy, identifiers and
// deduplication are implemented in RustCore.
import Foundation

/// Time-zone names share one display policy. Classification uses stored place facts, never a city-index lookup.
nonisolated enum ZoneNameDisplay {
    static func offsetOnly(identifier: String, code: String = "", admin: String = "", city: String = "",
                           coordinate: Coordinate? = nil) -> Bool {
        struct Input: Encodable {
            let identifier: String; let code: String; let admin: String; let city: String
            let latitude: Double?; let longitude: Double?
        }
        return RustCore.invoke("catalog.offset_only_zone_name", Input(identifier: identifier, code: code, admin: admin,
            city: city, latitude: coordinate?.latitude, longitude: coordinate?.longitude))
    }

    static func offset(_ zone: TimeZone, at date: Date) -> String {
        RustCore.invoke("model.entry_label", ["mode": CoreJSON.string("offset"),
            "offset": .integer(Int64(zone.secondsFromGMT(for: date)))])
    }

    static func name(_ zone: TimeZone, at date: Date, locale: Locale, offsetOnly: Bool = false) -> String? {
        if offsetOnly || self.offsetOnly(identifier: zone.identifier) { return offset(zone, at: date) }
        return zone.localizedName(for: .generic, locale: locale)
    }

    static func abbreviation(_ zone: TimeZone, at date: Date, offsetOnly: Bool = false) -> String {
        if offsetOnly || self.offsetOnly(identifier: zone.identifier) { return offset(zone, at: date) }
        let raw = zone.abbreviation(for: date) ?? ""
        return raw.isEmpty || raw.hasPrefix("GMT") || raw.hasPrefix("UTC") ? offset(zone, at: date) : raw
    }
}

/// Country and region names come from Apple's frameworks (CLDR data) for the interface locale.
/// Rust (`catalog.region_override`) returns an empty name for Taiwan in every interface language.
enum RegionDisplayName {
    private struct Input: Encodable {
        let code: String
        let slot: String?
    }
    static func localized(_ code: String, locale: Locale) -> String? {
        guard !code.isEmpty else { return nil }
        let custom: String? = RustCore.invoke("catalog.region_override", Input(code: code, slot: CityNameLanguage.code(for: locale)))
        return custom ?? locale.localizedString(forRegionCode: code)
    }
}

struct ZoneOption: Identifiable, Codable, Hashable, Sendable {
    enum Source: String, Codable, Hashable, Sendable { case city, zone }
    let id: String
    let identifier: String
    let coordinate: Coordinate?
    let cityName: String
    let adminRegion: String
    let adminIndex: Int
    let countryCode: String
    let source: Source
    /// Runtime-only index: never persisted, since a regenerated index reorders it.
    let cityIndex: Int?

    init(identifier: String, coordinate: Coordinate?) {
        struct Input: Encodable { let identifier: String; let coordinate: Coordinate? }
        self = RustCore.invoke("catalog.zone_option", Input(identifier: identifier, coordinate: coordinate))
    }
    init(cityIndex: Int, record: CityRecord) {
        struct Input: Encodable { let index: Int; let record: CityRecord }
        self = RustCore.invoke("catalog.city_option", Input(index: cityIndex, record: record))
    }
    func subtitle(locale: Locale, displayName: String? = nil) -> String {
        struct Input: Encodable {
            let source: Source
            let identifier: String
            let code: String
            let admin: String
            let resolved: String
            let country: String
            let city: String
            let display: String
            let latitude: Double?
            let longitude: Double?
        }
        let resolved = source == .city && adminIndex >= 0
            ? (CityNameLanguage.name(from: CityIndex.shared.localizedRegionNames(admin1: adminIndex), locale: locale) ?? adminRegion)
            : adminRegion
        return RustCore.invoke("catalog.subtitle", Input(source: source, identifier: identifier, code: countryCode,
            admin: adminRegion, resolved: resolved,
            country: countryCode.isEmpty ? "" : (RegionDisplayName.localized(countryCode, locale: locale) ?? countryCode),
            city: cityName, display: displayName ?? "",
            latitude: coordinate?.latitude, longitude: coordinate?.longitude))
    }
}

extension String {
    var tzCityComponent: String { RustCore.invoke("catalog.tz_city", ["text": self]) }
}
