// SPDX-License-Identifier: GPL-3.0-only
//
//  SkyStripTests.swift
//  工具窗的外壳（2026-10-02）：页首天色带与面板滑块的轨道同一批颜色、同一个昼夜；拖过时间带不动标记动，
//  超过 12 小时改以看的那一刻为中心；年份越界是中性的带、不崩；同一分钟、同一刻不重算。
//  太阳与月亮页的主图只说调色板认识的角色；页面主数字与面板行钟点同一字号。
//

import Foundation
import SwiftUI
import Testing
@testable import Dayside

struct SkyStripTests {
    private let losAngeles = Coordinate(latitude: 34.05, longitude: -118.24)
    /// 本机（测试宿主的系统时区）放一个带坐标的地点，「这里」就不靠随包坐标表。
    private var zones: [TimeZoneEntry] {
        [.init(timezoneID: TimeZone.current.identifier, cityName: "Here", coordinate: losAngeles, countryCode: nil)]
    }

    /// 面板滑块的轨道与页首天色带是同一个 Rust 操作、同一个中心：此刻、拖过 3 小时、跳到 17 小时 24 分钟后与 3 天前，
    /// 两边都是同一批 73 个色标；圆点（`sky.panel` 的 `dayHere`）与带上那一刻同一个昼夜。
    @MainActor @Test func theStripIsThePanelSliderTrack() {
        for k in 0..<6 {
            let now = Date(timeIntervalSince1970: 1_790_000_000 + Double(k) * 14_400)
            let home = SkyPanel.homeCoordinate(zones: zones)
            for offset: TimeInterval in [0, 3 * 3600, 17 * 3600 + 24 * 60, -3 * 86_400] {
                let instant = now.addingTimeInterval(offset)
                let panel = SkyPanel.compute(instant: instant, now: now, zones: zones, need: 5.5, locale: Locale(identifier: "en"))
                let strip = SkyStripState.compute(now: now, instant: instant, coordinate: home, marks: false)
                let memo = SliderTrackMemo()
                memo.update(now: now, center: SliderPosition.center(now: now, instant: instant), coordinate: home)
                #expect(strip.stops.count == 73)
                #expect(memo.stops == strip.stops, "第 \(k) 次、偏移 \(offset)：页首的带与滑块轨道不是同一批颜色")
                #expect(strip.dayHere == panel.dayHere)
                #expect(strip.beyond == SliderPosition.isBeyond(offset))
            }
        }
    }

    @MainActor @Test func scrubbingMovesTheMarkAndFarJumpsRecentreTheStrip() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let later = SkyStripState.compute(now: now, instant: now.addingTimeInterval(3 * 3600), coordinate: losAngeles, marks: false)
        #expect(abs(later.marker - (0.5 + 3.0 / 24)) < 1e-9)
        #expect(later.now == 0.5 && !later.beyond)
        let still = SkyStripState.compute(now: now, instant: now, coordinate: losAngeles, marks: false)
        #expect(later.stops == still.stops, "拖动时带子不动")
        let far = SkyStripState.compute(now: now, instant: now.addingTimeInterval(50 * 3600), coordinate: losAngeles, marks: false)
        #expect(far.beyond && far.marker == 0.5 && far.now == nil)
        #expect(far.stops != still.stops, "超过 12 小时画的是那一刻前后的天")
    }

    @MainActor @Test func outsideTheSupportedYearsTheStripIsNeutral() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let far = SkyStripState.compute(now: now, instant: Date(timeIntervalSince1970: 4_200_000_000), coordinate: losAngeles, marks: false)
        #expect(far == .neutral)
        let nowhere = SkyStripState.compute(now: now, instant: now, coordinate: nil, marks: false)
        #expect(nowhere.stops.isEmpty && nowhere.dayHere == nil)
    }

    @MainActor @Test func theStripComputesOnOpenOnTheMinuteAndOnScrubOnly() throws {
        let memo = SkyStripMemo()
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        memo.update(now: now, instant: now, coordinate: losAngeles, marks: false)
        #expect(memo.computations == 1)
        // 同一分钟、同一刻：窗口改大小、旁边的字变了而重算 body，都不再去 Rust。
        memo.update(now: now.addingTimeInterval(20), instant: now, coordinate: losAngeles, marks: false)
        memo.update(now: now, instant: now, coordinate: losAngeles, marks: false)
        #expect(memo.computations == 1)
        memo.update(now: now.addingTimeInterval(60), instant: now.addingTimeInterval(60), coordinate: losAngeles, marks: false)
        #expect(memo.computations == 2, "下一分钟算一次")
        memo.update(now: now.addingTimeInterval(60), instant: now.addingTimeInterval(3600), coordinate: losAngeles, marks: false)
        #expect(memo.computations == 3, "拖过时间算一次")
        let ribbon = try #require(memo.ribbon)
        #expect(ribbon.width == 432 && ribbon.height == 1)
    }

    @MainActor @Test func theSunDayChartSpeaksOnlyKnownRoles() throws {
        // 伦敦 2026-09-17 当地这一天（UTC+1）。
        let start = 1_789_599_600.0
        for marks in [false, true] {
            let scene = try #require(PresentationCore.sunDay(.init(
                dayStart: start, dayEnd: start + 86_400, latitude: 51.507, longitude: -0.128, width: 540, height: 136,
                golden: [.init(start: start + 6 * 3600, end: start + 7 * 3600)], instant: start + 13 * 3600, marks: marks)))
            for command in scene.commands {
                #expect(DaysidePalette.roles.contains(command.style), "Rust 说了调色板不认识的角色 \(command.style)")
            }
            #expect(scene.commands.first?.kind == "gradient")
            #expect(scene.sun?.up == true)
        }
        #expect(PresentationCore.sunDay(.init(dayStart: start, dayEnd: start + 86_400, latitude: 51.507, longitude: -0.128,
                                              width: 0, height: 136, golden: [], instant: start, marks: false)) == nil)
    }

    @Test func pageNumbersUseThePanelClockFace() {
        for scale in [1.0, 1.15, 1.3] {
            #expect(SkyRowMetrics(settings: AppSettings(), textScale: scale).timeSize == ClockFace.largeSize(scale: scale))
        }
    }
}

@MainActor
struct SunDayAxisHeightTests {
    private static func londonTicks() -> [Double] {
        let timeZone = TimeZone(identifier: "Europe/London")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = 1_789_599_600.0
        var out: [Double] = []
        var cursor = Date(timeIntervalSince1970: start)
        let end = Date(timeIntervalSince1970: start + 86_400)
        while cursor < end, out.count < 8 {
            out.append(cursor.timeIntervalSince1970)
            guard let next = calendar.date(byAdding: .hour, value: 6, to: cursor) else { break }
            cursor = next
        }
        return out
    }

    @Test func theAxisRowIsAsTallAsItsTallestLabelAndGrowsWithTheTextSize() {
        let timeZone = TimeZone(identifier: "Europe/London")!
        let ticks = Self.londonTicks()
        let start = ticks.first ?? 0
        var standard: [HourStyle: CGFloat] = [:]
        var largest: [HourStyle: CGFloat] = [:]
        for scale in [1.0, 1.15, 1.3] {
            for style in [HourStyle.force24, .force12] {
                let labels = ticks.map { ClockText.time(Date(timeIntervalSince1970: $0), in: timeZone, hourStyle: style) }
                let axis = NSHostingView(rootView: SunDayAxis(tickInstants: ticks, dayStart: start, dayEnd: start + 86_400,
                                                              timeZone: timeZone, hourStyle: style)
                    .frame(width: 540)
                    .environment(\.textScale, scale))
                let reference = NSHostingView(rootView:
                    HStack {
                        ForEach(Array(labels.enumerated()), id: \.offset) { _, label in
                            Text(verbatim: label)
                                .appFont(.caption).foregroundStyle(.readableSecondary).monospacedDigit()
                                .fixedSize()
                        }
                    }
                    .fixedSize()
                    .environment(\.textScale, scale))
                let axisHeight = axis.fittingSize.height
                let referenceHeight = reference.fittingSize.height
                print("SUN_AXIS_HEIGHT scale=\(scale) style=\(style) axis=\(axisHeight) reference=\(referenceHeight)")
                #expect(abs(axisHeight - referenceHeight) <= 0.5,
                        "×\(scale)：轴的高 \(axisHeight) 要装得下最高的刻度字 \(referenceHeight)")
                if scale == 1.0 { standard[style] = axisHeight }
                if scale == 1.3 { largest[style] = axisHeight }
            }
        }
        for style in [HourStyle.force24, .force12] {
            #expect((largest[style] ?? 0) > (standard[style] ?? 0), "\(style)：最大一档字号比标准字号高")
        }
    }
}
