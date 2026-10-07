// SPDX-License-Identifier: GPL-3.0-only
//
//  Availability.swift
//  TahoeTime
//
//  一个地点(或本机)的「可约时段」:本地墙钟的开始 / 结束分钟 + 是否只算工作日。
//  value type、Codable、宽容解码(与 AppSettings / TimeZoneEntry 同教义):缺键或越界都回退默认,
//  绝不让一条坏字段把条目拖垮。默认 09:00–18:00、只算工作日,与多数日程工具的默认一致。
//  结束 ≤ 开始表示跨午夜(22:00–06:00 的夜班);两者相等按「整天可约」处理,不会出现零长时段。
//

import Foundation

struct Availability: Codable, Hashable, Sendable {
    /// 本地墙钟的开始分钟(0 ..< 1440)。
    var startMinute: Int
    /// 本地墙钟的结束分钟(1 ... 1440);≤ startMinute 表示跨午夜。
    var endMinute: Int
    /// 只算该地的工作日(周末由该地所在国家/地区的 ICU 数据决定,见 `OverlapPlanner.Participant`)。
    var weekdaysOnly: Bool

    static let standard = Availability()

    init(startMinute: Int? = nil, endMinute: Int? = nil, weekdaysOnly: Bool? = nil) {
        let value = RustCore.invoke("availability.normalize",
                                   InitInput(startMinute: startMinute, endMinute: endMinute, weekdaysOnly: weekdaysOnly),
                                   as: Normalized.self)
        self.startMinute = value.startMinute
        self.endMinute = value.endMinute
        self.weekdaysOnly = value.weekdaysOnly
    }

    /// 跨午夜(夜班):结束时刻落在次日。
    var crossesMidnight: Bool { rules.crossesMidnight }

    /// 开始 == 结束 视为整天可约(24h)。
    var isWholeDay: Bool { rules.isWholeDay }

    /// 时段长度(分钟),1 ... 1440。
    var lengthMinutes: Int { rules.lengthMinutes }

    private struct RuleInput: Encodable { let startMinute: Int; let endMinute: Int }
    private struct InitInput: Encodable { let startMinute: Int?; let endMinute: Int?; let weekdaysOnly: Bool? }
    private struct Normalized: Decodable { let startMinute: Int; let endMinute: Int; let weekdaysOnly: Bool }
    private struct Rules: Decodable {
        let startMinute: Int
        let endMinute: Int
        let crossesMidnight: Bool
        let isWholeDay: Bool
        let lengthMinutes: Int
    }
    private var rules: Rules { Self.rules(startMinute: startMinute, endMinute: endMinute) }
    private static func rules(startMinute: Int, endMinute: Int) -> Rules {
        RustCore.invoke("availability.rules", RuleInput(startMinute: startMinute, endMinute: endMinute))
    }

    enum CodingKeys: String, CodingKey { case startMinute, endMinute, weekdaysOnly }

    init(from decoder: Decoder) throws {
        let raw = try CoreJSON(from: decoder)
        guard let value = RustCore.invoke("availability.decode", raw, as: Normalized?.self) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                   debugDescription: "Availability must be an object"))
        }
        startMinute = value.startMinute
        endMinute = value.endMinute
        weekdaysOnly = value.weekdaysOnly
    }
}
