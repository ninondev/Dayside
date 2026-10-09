// SPDX-License-Identifier: GPL-3.0-only
// The TTCITY12 mapping, bounds validation and search live in RustCore.
// Swift owns only the checked handle lifetime and Apple's locale/ICU services.
import Foundation

struct CityRecord: Codable, Sendable, Hashable {
    let name: String
    let region: String
    let adminIndex: Int
    let countryCode: String
    let timezoneID: String
    let latitude: Double
    let longitude: Double
}

extension String {
    /// The same normalization as the index generator; performed in Rust.
    var searchFolded: String { RustCore.invoke("catalog.fold", ["text": self]) }
}

final class CityIndex: Sendable {
    static let shared = CityIndex()
    let rustHandle: UInt64?
    let cityCount: Int
    var isAvailable: Bool { rustHandle != nil }

    private struct OpenResult: Decodable { let handle: UInt64?; let cityCount: Int }
    private struct Request: Encodable {
        let handle: UInt64
        var index: Int? = nil
        var query: String? = nil
        var limit: Int? = nil
        var timezone: String? = nil
        var country: String? = nil
        var kind: String? = nil
    }
    struct Entry: Codable, Sendable { let index: Int; let record: CityRecord }
    struct Hit: Codable, Sendable, Hashable {
        let cityIndex: Int
        let tier: Int
    }

    private convenience init() {
        self.init(path: Bundle.main.url(forResource: "cities", withExtension: "ttcity")?.path ?? "")
    }
    convenience init(url: URL) { self.init(path: url.path) }
    private init(path: String) {
        let result: OpenResult = RustCore.invoke("city.open", ["path": path])
        rustHandle = result.handle
        cityCount = result.cityCount
    }
    deinit {
        if let rustHandle { let _: Bool = RustCore.invoke("city.close", Request(handle: rustHandle)) }
    }
    func city(at index: Int) -> CityRecord? {
        guard let rustHandle else { return nil }
        return RustCore.invoke("city.record", Request(handle: rustHandle, index: index))
    }
    func representativeCity(forTimezone id: String) -> (index: Int, record: CityRecord)? {
        guard let rustHandle else { return nil }
        let result: Entry? = RustCore.invoke("city.representative", Request(handle: rustHandle, timezone: id))
        return result.map { ($0.index, $0.record) }
    }
    func topCities(inCountry code: String, limit: Int = 8) -> [(index: Int, record: CityRecord)] {
        guard let rustHandle else { return [] }
        let result: [Entry] = RustCore.invoke("city.top", Request(handle: rustHandle, limit: limit, country: code))
        return result.map { ($0.index, $0.record) }
    }
    func localizedNames(cityIndex: Int) -> [String: String] {
        guard let rustHandle else { return [:] }
        return RustCore.invoke("city.names", Request(handle: rustHandle, index: cityIndex, kind: "city"))
    }
    func localizedRegionNames(admin1: Int) -> [String: String] {
        guard let rustHandle else { return [:] }
        return RustCore.invoke("city.names", Request(handle: rustHandle, index: admin1, kind: "region"))
    }
    func timezoneID(at index: Int) -> String {
        guard let rustHandle else { return "" }
        return RustCore.invoke("city.timezone", Request(handle: rustHandle, index: index))
    }
    func search(folded query: String, limit: Int) -> [Hit] {
        guard let rustHandle else { return [] }
        return RustCore.invoke("city.search", Request(handle: rustHandle, query: query, limit: limit))
    }
    /// 地图上某一点附近的城市：人口前 `limit` 座里、地图平面上
    /// `radius` 度以内最近的一座（Rust `city.nearest`）。第一次调用才映射索引，与搜索同一个句柄。
    func nearest(latitude: Double, longitude: Double, radius: Double, limit: Int) -> (index: Int, record: CityRecord)? {
        guard let rustHandle else { return nil }
        struct Input: Encodable { let handle: UInt64; let latitude: Double; let longitude: Double; let radius: Double; let limit: Int }
        let result: Entry? = RustCore.invoke("city.nearest", Input(handle: rustHandle, latitude: latitude, longitude: longitude,
                                                                   radius: radius, limit: limit))
        return result.map { ($0.index, $0.record) }
    }
    func coordinateCandidates(for identifiers: [String]) -> [String: [CityRecord]] {
        guard let rustHandle else { return [:] }
        struct Batch: Encodable { let handle: UInt64; let identifiers: [String] }
        return RustCore.invoke("city.coordinate_candidates", Batch(handle: rustHandle, identifiers: identifiers))
    }
}

/// Apple's locale expansion and Chinese conversion remain the native provider.
/// Selection, fallback and post-conversion protection are Rust policies.
enum CityNameLanguage {
    static let codes = ["zh-Hans", "zh-Hant", "ja", "ko", "es", "fr", "de", "ru", "pt-BR", "it", "nl", "pl", "tr", "vi", "id"]
    static func code(for locale: Locale) -> String? {
        RustCore.invoke("catalog.language_slot", ["maximal": locale.language.maximalIdentifier])
    }
    static func name(from names: [String: String], locale: Locale) -> String? {
        guard let code = code(for: locale) else { return nil }
        struct Input: Encodable { let names: [String: String]; let code: String }
        let source: String? = RustCore.invoke("catalog.select_name", Input(names: names, code: code))
        guard let source else { return nil }
        let transform: String
        switch code {
        case "zh-Hans": transform = "Hant-Hans"
        case "zh-Hant": transform = "Hans-Hant"
        default: return source
        }
        let buffer = NSMutableString(string: source)
        guard CFStringTransform(buffer as CFMutableString, nil, transform as CFString, false) else { return source }
        return RustCore.invoke("catalog.restore_chinese", ["source": source, "converted": buffer as String])
    }
}
