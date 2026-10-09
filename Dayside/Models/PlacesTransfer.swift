// SPDX-License-Identifier: GPL-3.0-only
//
//  PlacesTransfer.swift
//  Dayside / DaysideiOS（两端共用，只依赖 Foundation）
//
//  Mac → iPhone 的地点清单同步。
//  Mac 把已保存地点编成 `dayside://import#dp1.…` 链接（二维码 / 复制），iPhone 扫码或粘贴后解回；
//  编码、解码与全部校验在 Rust `sharing.places_*`，这里只做模型往返。不经任何服务器，不带可约时段。
//

import Foundation

nonisolated struct TransferPlace: Codable, Hashable, Sendable {
    var name: String
    var timeZoneID: String
    var countryCode: String? = nil
    var latitude: Double? = nil
    var longitude: Double? = nil
    /// 分类用的索引原名独立于发方显示名，翻译和重命名不能改变地点的显示规则。
    var rawCityName: String? = nil

    init(name: String, timeZoneID: String, countryCode: String? = nil, latitude: Double? = nil, longitude: Double? = nil) {
        self.name = name; self.timeZoneID = timeZoneID; self.countryCode = countryCode; self.latitude = latitude; self.longitude = longitude
    }
    /// `displayName` 是发方界面上实际显示的名字（自定义名，否则按界面语言的城市名），收方照样显示它。
    init(entry: TimeZoneEntry, displayName: String) {
        self.init(name: displayName, timeZoneID: entry.timezoneID, countryCode: entry.countryCode,
                  latitude: entry.coordinate?.latitude, longitude: entry.coordinate?.longitude)
        rawCityName = entry.offsetOnlyZoneName ? entry.cityName : nil
    }
    /// 收方保留发方显示名；清单带索引原名时另存它供分类，旧清单照常把显示名当城市名。坐标与国家码随行。
    var entry: TimeZoneEntry {
        let coordinate = (latitude != nil && longitude != nil) ? Coordinate(latitude: latitude!, longitude: longitude!) : nil
        return TimeZoneEntry(timezoneID: timeZoneID, customName: rawCityName == nil ? nil : name,
                             cityName: rawCityName ?? name, coordinate: coordinate, usesExemplarName: false, countryCode: countryCode)
    }
}

nonisolated struct PlacesTransferLink: Decodable, Equatable, Sendable {
    let fragment: String
    let url: String
    let count: Int
}

nonisolated struct PlacesTransferResult: Decodable, Equatable, Sendable {
    let places: [TransferPlace]
    let generatedAt: Double?
    let dropped: Int
    init(places: [TransferPlace], generatedAt: Double?, dropped: Int) { self.places = places; self.generatedAt = generatedAt; self.dropped = dropped }
}

/// Rust 那边的错误码原样带回（`count` / `places` / `notAPlaceList` / `corrupt` / `unsupported` / `tooLong`）。
nonisolated struct PlacesTransferError: Error, Equatable, Sendable { let code: String }

nonisolated enum PlacesTransfer {
    private struct EncodeInput: Encodable { let places: [TransferPlace]; let now: Double }

    /// 生成链接；地点空或超过 200 个、名字含控制字符时失败（Rust 报的错原样带回）。
    static func link(for entries: [TimeZoneEntry], displayName: (TimeZoneEntry) -> String, now: Date = .now) -> Result<PlacesTransferLink, PlacesTransferError> {
        struct Out: Decodable { let error: String?; let fragment: String?; let url: String?; let count: Int? }
        let places = entries.map { TransferPlace(entry: $0, displayName: displayName($0)) }
        let out: Out = RustCore.invoke("sharing.places_encode", EncodeInput(places: places, now: now.timeIntervalSince1970))
        if let error = out.error { return .failure(.init(code: error)) }
        guard let fragment = out.fragment, let url = out.url, let count = out.count else { return .failure(.init(code: "places")) }
        return .success(PlacesTransferLink(fragment: fragment, url: url, count: count))
    }

    /// 解一段粘贴 / 扫到的文本；时间名片（`mt1.`）与随手文字都按错误返回。
    static func decode(_ text: String) -> Result<PlacesTransferResult, PlacesTransferError> {
        struct Out: Decodable { let error: String?; let places: [TransferPlace]?; let generatedAt: Double?; let dropped: Int? }
        let out: Out = RustCore.invoke("sharing.places_decode", ["text": text])
        if let error = out.error { return .failure(.init(code: error)) }
        guard let places = out.places else { return .failure(.init(code: "corrupt")) }
        return .success(PlacesTransferResult(places: places, generatedAt: out.generatedAt, dropped: out.dropped ?? 0))
    }

    /// 合并进已有清单：同时区且名字对得上（收方显示名、自定义名、原始城市名或任一语言的名字）的不重复加；顺序按对方的清单。
    static func merge(_ incoming: [TransferPlace], into existing: [TimeZoneEntry], displayName: (TimeZoneEntry) -> String) -> [TimeZoneEntry] {
        var result = existing
        for place in incoming {
            let duplicate = result.contains { entry in
                entry.timezoneID == place.timeZoneID
                    && (displayName(entry) == place.name || entry.customName == place.name || entry.cityName == place.name
                        || entry.localizedNames?.values.contains(place.name) == true)
            }
            if !duplicate { result.append(place.entry) }
        }
        return result
    }
}
