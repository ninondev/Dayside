// SPDX-License-Identifier: GPL-3.0-only
//
//  Coordinate.swift
//  Dayside
//
//  经纬度。来源:IANA 官方 zone1970.tab 的代表坐标(全集、外部维护、对每个时区
//  一视同仁,不含人工挑选)。供后续阶段的昼夜着色等用。
//

import Foundation

struct Coordinate: Codable, Hashable, Sendable {
    let latitude: Double
    let longitude: Double
}
