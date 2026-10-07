// SPDX-License-Identifier: GPL-3.0-only
//
//  RowSunGraph.swift
//  TahoeTime
//
//  地点行的音频图：VoiceOver 聚焦到行时，把那地当天太阳高度的 97 个采样
//  连成一声升、一声落——读屏用户也能「听」到一天的昼夜。画面一个像素都不动。
//

import Accessibility
import SwiftUI

/// 一地一天的太阳高度音频图：横轴是当地 0...24 时（每 15 分钟一个采样，共 97 个），纵轴是高度角 -90...90。
/// 采样与串表都推迟到 `makeChartDescriptor` 才算——那是读屏系统真正索要描述符的时刻，平时零开销。
struct SunAltitudeChart: AXChartDescriptorRepresentable {
    let title: String
    let locale: Locale
    let latitude: Double
    let longitude: Double
    let timeZone: TimeZone
    let day: Date

    /// 当天 0 时到 24 时的 97 个高度角：Rust `astronomy.altitudes`，与昼夜条同一个太阳高度算法。
    private var altitudes: [Double] {
        struct Input: Encodable { let latitude, longitude, start, stepMinutes: Double; let count: Int }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let midnight = calendar.startOfDay(for: day)
        let samples: [Double] = RustCore.invoke("astronomy.altitudes", Input(latitude: latitude, longitude: longitude,
                                                start: midnight.timeIntervalSince1970, stepMinutes: 15, count: 97))
        return samples
    }

    func makeChartDescriptor() -> AXChartDescriptor {
        let xAxis = AXNumericDataAxisDescriptor(title: L10n.string("时刻", locale: locale),
                                                range: 0...24,
                                                gridlinePositions: [0, 6, 12, 18, 24]) { value in
            "\(Int(value)):00"
        }
        let yAxis = AXNumericDataAxisDescriptor(title: L10n.string("太阳高度", locale: locale),
                                                range: -90...90,
                                                gridlinePositions: [0]) { value in
            "\(Int(value.rounded()))°"
        }
        let series = AXDataSeriesDescriptor(name: title,
                                            isContinuous: true,
                                            dataPoints: altitudes.enumerated().map { AXDataPoint(x: Double($0.offset) / 4, y: $0.element) })
        return AXChartDescriptor(title: title, summary: nil, xAxis: xAxis, yAxis: yAxis, additionalAxes: [], series: [series])
    }
}

/// 给行挂音频图：有经纬度的地点行才有太阳几何可说；没有（旧存档、不带坐标的条目）就原样放过。
struct RowSunGraph: ViewModifier {
    let zone: TimeZoneEntry

    @Environment(AppModel.self) private var model

    @ViewBuilder
    func body(content: Content) -> some View {
        if let coordinate = zone.coordinate {
            content.accessibilityChartDescriptor(SunAltitudeChart(
                title: String(format: L10n.string("%@ 今天的太阳高度", locale: model.uiLocale),
                              zone.displayName(localizedCity: model.localizedCity(zone))),
                locale: model.uiLocale,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                timeZone: zone.timeZone,
                day: model.referenceDate))
        } else {
            content
        }
    }
}
