// SPDX-License-Identifier: GPL-3.0-only
//
//  SunPhase.swift
//  TahoeTime
//
//  读屏地图值用的太阳几何：直射点经度落在八段里的哪一段（决定「太阳正照着××」念哪段的名字），
//  与一地看太阳的高度角（按 白天 / 曙暮 / 夜 三档分组，判据与昼夜条一致）。全是纯函数：不碰时钟、Rust 与网络，
//  `SunPhaseTests` 直接钉住。
//

import Foundation

/// 太阳与直射点的昼夜几何：无状态、全 `nonisolated`。
nonisolated enum SunPhase {
    /// 直射点经度（度，东经为正）归入哪一段：先归一化进 -180...180，再按半开区间分八段：
    /// [-180,-135) 0 · [-135,-95) 1 · [-95,-45) 2 · [-45,-15) 3 · [-15,45) 4 · [45,90) 5 · [90,150) 6 · [150,180] 7。
    static func band(longitude: Double) -> Int {
        var λ = longitude.truncatingRemainder(dividingBy: 360)
        if λ < -180 { λ += 360 }
        if λ > 180 { λ -= 360 }
        switch λ {
        case ..<(-135): return 0
        case ..<(-95): return 1
        case ..<(-45): return 2
        case ..<(-15): return 3
        case ..<45: return 4
        case ..<90: return 5
        case ..<150: return 6
        default: return 7
        }
    }

    /// 各段的名字走本地化表：`band` 的返回值按下标取键（十六语译文；俄、波两语是放进「太阳正照着%@」要用的工具格）。
    static let bandKeys: [String] = ["太平洋中部", "美洲西部", "美洲东部", "大西洋",
                                     "欧洲与非洲", "中东与南亚", "东亚与东南亚", "大洋洲与西太平洋"]

    /// 一地看太阳的高度角（度）：`asin(sin φ sin δ + cos φ cos δ cos(λ − λs))`，φ、λ 是地点，δ、λs 是直射点。
    /// 和式的舍入可能把结果顶出 1 一点点（正对直射点时它就是 sin²+cos²），收进 [-1, 1] 免得 `asin` 吐 NaN。
    static func altitude(latitude: Double, longitude: Double, subsolarLatitude: Double, subsolarLongitude: Double) -> Double {
        let φ = latitude * .pi / 180, δ = subsolarLatitude * .pi / 180
        let apart = (longitude - subsolarLongitude) * .pi / 180
        let chord = sin(φ) * sin(δ) + cos(φ) * cos(δ) * cos(apart)
        return asin(min(1, max(-1, chord))) * 180 / .pi
    }

    /// 一地此刻的三档：太阳在地平线上（含大气折射让太阳看着还贴着地平的那 -0.833°）是白天，
    /// 地平线下 6° 之内是曙暮，再深是夜。
    enum Phase: Equatable { case day, twilight, night }

    static func phase(altitude: Double) -> Phase {
        if altitude >= -0.833 { return .day }
        if altitude >= -6 { return .twilight }
        return .night
    }
}
