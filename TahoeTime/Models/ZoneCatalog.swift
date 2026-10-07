// SPDX-License-Identifier: GPL-3.0-only
// Apple's time-zone and ICU snapshots feed the Rust-owned catalog. Neither
// this provider nor CityIndex is created on the menu-bar-only startup path.
import Foundation

final class ZoneCatalog: Sendable {
    static let shared = ZoneCatalog()
    /// 时区层的全部条目（系统时区 ∪ zone.tab），按标识符排序。tzcoords 里有坐标的带坐标；
    /// 其余的 `coordinate == nil`，要坐标时走 `option(for:)` / `resolvingCoordinate(_:)`——
    /// 只为问到的那一个时区去城市索引里找代表城市。初始化时逐个搜索所有缺坐标的时区，
    /// 会让面板搜索框、天文页空态或欢迎页首次访问目录时产生较大的峰值，
    /// 并提前映射城市索引，所以坐标解析推迟到具体请求时。
    let zones: [ZoneOption]
    let coordinatesUnavailable: Bool
    private let index: CityIndex
    private let handle: UInt64
    private let context = SystemContext()
    /// 还没解析坐标的时区标识符；解析过的进 `resolved`（含「确实没有」的 nil）。
    private let pending: Set<String>
    private let resolved = ResolvedCoordinates()

    private struct Seed: Encodable { let identifier: String; let coordinate: Coordinate? }
    private struct OpenInput: Encodable { let zones: [Seed]; let abbreviations: [String: String] }
    private struct OpenResult: Decodable { let handle: UInt64; let zones: [ZoneOption] }
    private struct Country: Encodable { let code: String; let localized: String?; let english: String? }
    private struct Localization: Encodable {
        let countries: [Country]?
        let localizedNames: [String: String]?
        let slot: String?
    }
    private struct SearchInput: Encodable {
        let handle: UInt64
        let cityHandle: UInt64?
        let query: String
        let limit: Int
        let offsets: [String: Int]?
        let context: Localization?
        let localeID: String
        let useLocalizedNames: Bool
    }
    /// Serializes the host snapshot and query as one transaction, so concurrent
    /// searches in different languages cannot consume each other's ICU names.
    private final class SystemContext: @unchecked Sendable {
        let lock = NSLock()
    }
    /// 按需解析出来的坐标缓存（`nil` 也记，免得反复去索引里找那几个真没有的）。
    private final class ResolvedCoordinates: @unchecked Sendable {
        let lock = NSLock()
        var values: [String: Coordinate?] = [:]
    }

    private init() {
        let path = Bundle.main.url(forResource: "tzcoords", withExtension: "json")?.path ?? ""
        let coordinates: [String: Coordinate] = RustCore.invoke("catalog.load_coordinates", ["path": path])
        let index = CityIndex.shared
        self.index = index
        coordinatesUnavailable = coordinates.isEmpty && !index.isAvailable
        struct IDInput: Encodable { let system: [String]; let coordinates: [String] }
        let all: [String] = RustCore.invoke("catalog.identifiers", IDInput(system: TimeZone.knownTimeZoneIdentifiers, coordinates: Array(coordinates.keys)))
        let identifiers = all.filter { TimeZone(identifier: $0) != nil }
        pending = Set(identifiers.filter { coordinates[$0] == nil })
        let seeds = identifiers.map { Seed(identifier: $0, coordinate: coordinates[$0]) }
        let opened: OpenResult = RustCore.invoke("catalog.open", OpenInput(zones: seeds, abbreviations: TimeZone.abbreviationDictionary))
        handle = opened.handle
        zones = opened.zones
    }
    deinit { let _: Bool = RustCore.invoke("catalog.close", ["handle": handle]) }

    /// 随包 tzcoords 里这个时区代表城市的坐标；**不解析、不碰城市索引**（面板与人物页的昼夜条在空闲时也会问，
    /// 索引只许在搜索时映射）。没有就是 nil，条上只画底色。
    func knownCoordinate(for identifier: String) -> Coordinate? {
        zones.first { $0.identifier == identifier }?.coordinate
    }

    /// 这个标识符的时区层条目，坐标已解析（真没有的仍是 nil，不拿别处的坐标冒充）。
    func option(for identifier: String) -> ZoneOption? {
        zones.first { $0.identifier == identifier }.map(resolvingCoordinate)
    }

    /// 给时区层条目补坐标：tzcoords 没有的，按需在城市索引里找与该时区偏移史一致的同名城市
    /// （Rust `catalog.select_coordinate` 挑，Foundation 给 37 个月的偏移样本），结果缓存。
    /// 城市层条目自带坐标，原样返回。
    func resolvingCoordinate(_ option: ZoneOption) -> ZoneOption {
        guard option.source == .zone, option.coordinate == nil, pending.contains(option.identifier) else { return option }
        resolved.lock.lock()
        if let cached = resolved.values[option.identifier] {
            resolved.lock.unlock()
            return cached.map { ZoneOption(identifier: option.identifier, coordinate: $0) } ?? option
        }
        resolved.lock.unlock()
        // 锁外算（要跑索引搜索与 Foundation 偏移）；两个线程同时算同一个也只是重复劳动，结果一样。
        let coordinate = Self.coordinate(for: option.identifier, index: index)
        resolved.lock.lock()
        resolved.values[option.identifier] = coordinate
        resolved.lock.unlock()
        return coordinate.map { ZoneOption(identifier: option.identifier, coordinate: $0) } ?? option
    }

    /// 全部时区层条目，坐标逐个解析过（测试与「每个真实地点都该有坐标」的护栏用；会把索引整个走一遍）。
    func resolvedZones() -> [ZoneOption] { zones.map(resolvingCoordinate) }

    private static func coordinate(for id: String, index: CityIndex) -> Coordinate? {
        let rows = index.coordinateCandidates(for: [id])[id] ?? []
        // Foundation provides system offset histories. Rust chooses which
        // exact-name candidate has an equivalent history; no offset-only
        // substitute city is admitted.
        struct Candidate: Encodable { let record: CityRecord; let offsets: [Int] }
        struct Selection: Encodable { let identifier: String; let offsets: [Int]; let candidates: [Candidate] }
        let now = Date()
        let dates = (0..<37).map { now.addingTimeInterval(Double($0) * 30 * 86_400) }
        func offsets(_ name: String) -> [Int] {
            guard let zone = TimeZone(identifier: name) else { return [] }
            return dates.map { zone.secondsFromGMT(for: $0) }
        }
        return RustCore.invoke("catalog.select_coordinate", Selection(identifier: id,
            offsets: offsets(id), candidates: rows.map { Candidate(record: $0, offsets: offsets($0.timezoneID)) }))
    }

    static func parseOffsetSeconds(_ folded: String) -> Int? {
        RustCore.invoke("catalog.parse_offset", ["text": folded])
    }
    func search(_ query: String, locale: Locale?, limit: Int = 8) -> [ZoneOption] {
        context.lock.lock()
        defer { context.lock.unlock() }
        let selected = locale ?? .current
        struct Response: Decodable {
            let results: [ZoneOption]
            let needsCountries: Bool
            let needsLocalizedNames: Bool
            let needsOffsets: Bool
        }
        var snapshot: Localization?
        var offsets: [String: Int]?
        // Rust asks for native data only after stronger matches fail to fill
        // the result. A city query need not construct hundreds of ICU names.
        while true {
            let response: Response = RustCore.invoke("catalog.search", SearchInput(handle: handle, cityHandle: index.rustHandle,
                query: query, limit: limit, offsets: offsets, context: snapshot,
                localeID: selected.identifier, useLocalizedNames: locale != nil))
            guard response.needsCountries || response.needsLocalizedNames || response.needsOffsets else { return response.results }
            let countries: [Country]?
            if response.needsCountries {
                let english = Locale(identifier: "en")
                countries = Locale.Region.isoRegions.compactMap { region -> Country? in
                    let code = region.identifier
                    guard code.count == 2 else { return nil }
                    return Country(code: code, localized: selected.localizedString(forRegionCode: code),
                                   english: english.localizedString(forRegionCode: code))
                }
            } else { countries = nil }
            let names: [String: String]?
            if response.needsLocalizedNames {
                names = Dictionary(uniqueKeysWithValues: zones.map {
                    ($0.identifier, LocalizedZoneNames.shared.cityName($0.identifier, locale: selected))
                })
            } else { names = nil }
            snapshot = Localization(countries: countries, localizedNames: names, slot: CityNameLanguage.code(for: selected))
            if response.needsOffsets {
                let now = Date()
                offsets = Dictionary(uniqueKeysWithValues: zones.map {
                    ($0.identifier, TimeZone(identifier: $0.identifier)?.secondsFromGMT(for: now) ?? 0)
                })
            }
        }
    }
}
