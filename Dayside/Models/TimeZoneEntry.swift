// SPDX-License-Identifier: GPL-3.0-only
//
//  TimeZoneEntry.swift
//  Dayside
//
//  用户添加的一个时区条目。value type、Codable,直接序列化进 UserDefaults。
//

import Foundation

struct TimeZoneEntry: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var timezoneID: String
    var customName: String?
    var cityName: String          // 没设自定义名时的回退显示
    var coordinate: Coordinate?   // 添加时从 ZoneOption 带过来,随条目持久化,供昼夜用。
                                  // optional:旧版持久化数据没这字段也能正常解码。

    /// 显示名是否该交给 ICU 按语言重算。
    /// **时区代表条目**(Asia/Tokyo)= true:ICU 能给出 东京 / Tokio / 도쿄。
    /// **具体城市条目**(Munich,时区 Europe/Berlin)= false:ICU 只认时区,会答"柏林"——
    /// 必须用添加时存下的城市名。旧存档没有这个字段,解码默认 true,行为与从前一致。
    var usesExemplarName: Bool

    /// 该城市在各界面语言下的名字(只存与拉丁主名不同的那些)。**随条目持久化**:
    /// 城市索引的下标不能持久化(重建索引会移位),而若改为显示时回查索引,菜单栏标签
    /// 就会在启动时把 25MB 索引映射进来。用户只有几个时区,存几百字节远比这划算。
    var localizedNames: [String: String]?

    /// ISO 3166-1 alpha-2 国家/地区码(添加时从 ZoneOption 带过来)。重叠规划器用它按该地的
    /// ICU 周末数据决定哪几天是周末(以色列周五六、印度周日、阿富汗周四五)。时区代表条目与旧存档
    /// 没有这字段 → nil → 按周六日。
    var countryCode: String?

    /// 重叠规划器用的可约时段(L2)。nil = 默认 09:00–18:00、只算工作日;用户改过才存。
    var availability: Availability?
    /// 地点的 emoji（一个符号，进菜单栏与面板标识前面）与语义色点（封闭名单，见 `ZoneColor`）。
    var emoji: String?
    var color: String?
    /// 「现在能打给谁」按哪个时段判定这一行（面板右键菜单就地换）。默认上班时段 = 从前的唯一行为；
    /// 旧存档没有这字段，解码回 .work。
    var callBasis: CallBasis

    init(id: UUID = UUID(), timezoneID: String, customName: String? = nil,
         cityName: String, coordinate: Coordinate? = nil, usesExemplarName: Bool = true,
         localizedNames: [String: String]? = nil, countryCode: String? = nil,
         availability: Availability? = nil, emoji: String? = nil, color: String? = nil,
         callBasis: CallBasis = .work) {
        self.id = id
        self.timezoneID = timezoneID
        self.customName = customName
        self.cityName = cityName
        self.coordinate = coordinate
        self.usesExemplarName = usesExemplarName
        self.localizedNames = localizedNames
        self.countryCode = countryCode
        self.availability = availability
        self.emoji = emoji
        self.color = color
        self.callBasis = callBasis
    }

    init(zone: ZoneOption) {
        let names = zone.cityIndex.map { CityIndex.shared.localizedNames(cityIndex: $0) }
        self.init(timezoneID: zone.identifier, customName: nil,
                  cityName: zone.cityName, coordinate: zone.coordinate,
                  usesExemplarName: zone.source == .zone,
                  localizedNames: (names?.isEmpty ?? true) ? nil : names,
                  countryCode: zone.countryCode.isEmpty ? nil : zone.countryCode)
    }

    /// 生效的可约时段(未设置即默认)。
    var effectiveAvailability: Availability { availability ?? .standard }

    /// 无效 ID 回退到 GMT,避免崩溃(理论上不会发生,但 TimeZone(identifier:) 是 optional)。
    var timeZone: TimeZone { TimeZone(identifier: timezoneID) ?? .gmt }

    var offsetOnlyZoneName: Bool {
        ZoneNameDisplay.offsetOnly(identifier: timezoneID, code: countryCode ?? "", city: cityName, coordinate: coordinate)
    }

    /// 显示名,回退用「本地化的代表城市名」(由调用方按 cityLocale 算好传入)。自定义名优先。
    func displayName(localizedCity: String) -> String {
        nativeLabel(mode: "name", localized: localizedCity, offset: 0, abbreviation: nil)
    }
    private func nativeLabel(mode: String, localized: String, offset: Int, abbreviation: String?,
                             withOffset: Bool = false, includeEmoji: Bool = true) -> String {
        struct Input: Encodable { let mode: String; let customName: String?; let localized: String; let offset: Int; let abbreviation: String?; let emoji: String?; let withOffset: Bool }
        return RustCore.invoke("model.entry_label", Input(mode: mode, customName: customName, localized: localized, offset: offset, abbreviation: abbreviation, emoji: includeEmoji ? emoji : nil, withOffset: withOffset))
    }
    func offsetString(at date: Date) -> String {
        nativeLabel(mode: "offset", localized: "", offset: timeZone.secondsFromGMT(for: date), abbreviation: nil)
    }
    func abbreviation(at date: Date) -> String {
        nativeLabel(mode: "abbreviation", localized: "", offset: timeZone.secondsFromGMT(for: date),
                    abbreviation: zoneAbbreviation(at: date))
    }
    private func zoneAbbreviation(at date: Date) -> String {
        ZoneNameDisplay.abbreviation(timeZone, at: date, offsetOnly: offsetOnlyZoneName)
    }
    /// 一行里的标识。`includeEmoji` = false 供**面板行**用：那里 emoji 是单画的一段
    /// （自己的字号、读屏跳过），串里再带一个就重复了。菜单栏是一整条 Text，要带。
    func label(mode: DisplayMode, at date: Date, localizedCity: String, withOffset: Bool = false,
               includeEmoji: Bool = true) -> String {
        nativeLabel(mode: mode.rawValue, localized: localizedCity, offset: timeZone.secondsFromGMT(for: date),
                    abbreviation: mode == .abbreviation ? zoneAbbreviation(at: date) : nil, withOffset: withOffset,
                    includeEmoji: includeEmoji)
    }

}

// 宽容解码(与 AppSettings 同教义):每个字段独立回退,缺键或类型错都不让整条记录陪葬。
// 写在扩展里以保留成员构造器。
extension TimeZoneEntry {
    init(from decoder: Decoder) throws {
        let normalized: CoreJSON = RustCore.invoke("store.entry", try CoreJSON(from: decoder))
        guard normalized != .null else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Missing timezoneID"))
        }
        // 旧存档没有 callBasis 时回 .work，保持原来的上班基准。
        let callBasis: CallBasis? = normalized["callBasis"].decode()
        self.init(id: normalized["id"].decode(), timezoneID: normalized["timezoneID"].decode(),
                  customName: normalized["customName"].decode(), cityName: normalized["cityName"].decode(),
                  coordinate: normalized["coordinate"].decode(), usesExemplarName: normalized["usesExemplarName"].decode(),
                  localizedNames: normalized["localizedNames"].decode(), countryCode: normalized["countryCode"].decode(),
                  availability: normalized["availability"].decode(), emoji: normalized["emoji"].decode(), color: normalized["color"].decode(),
                  callBasis: callBasis ?? .work)
    }
}

/// 「现在能打给谁」的判定基准：上班 = 该行自己的可约时段（含工作日 / 周末规则）；
/// 醒着 = 全局设置的醒着窗口（默认 08:00–22:00，每天生效，不看周末）。
enum CallBasis: String, Codable, CaseIterable, Sendable {
    case work, awake
}


/// 地点色点的封闭名单（与 Rust `model::COLORS` 一致）：系统色，面板行画 6 pt 圆点，名字进无障碍标签。
enum ZoneColor: String, CaseIterable, Identifiable, Sendable {
    case red, orange, yellow, green, blue, purple, gray
    var id: String { rawValue }
    var localizedKey: String {
        switch self {
        case .red: "红色"
        case .orange: "橙色"
        case .yellow: "黄色"
        case .green: "绿色"
        case .blue: "蓝色"
        case .purple: "紫色"
        case .gray: "灰色"
        }
    }
}
