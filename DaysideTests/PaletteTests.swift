// SPDX-License-Identifier: GPL-3.0-only
//
//  PaletteTests.swift
//  一套两色：Rust 画昼夜条 / 昼夜地图 / 太阳弧 / 排会窗口时只说角色，宿主 `DaysidePalette`
//  把角色配成昼的蓝与太阳的橙。地图的晨昏线另有 dawn / dusk 两个角色，颜色来自 Rust `sky.palette`。这里拿 Rust 的真实输出核对：每个角色都在封闭表里（不认识的角色在运行时是
//  preconditionFailure，得在测试里先撞到），没有谁再说「accent」，深色只抬昼 / 曙暮 / 晨昏线，参考线仍是 primary。
//

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Dayside

struct PaletteTests {

    private struct Span: Encodable { let start: Double; let end: Double }
    private struct Window: Encodable { let start: Double; let end: Double; let tier: Int }
    private struct LaneInput: Encodable {
        let start: Double; let length: Double; let reference: Double; let width: Double; let height: Double
        let latitude: Double; let longitude: Double; let available: [Span]; let inset: Double; let availableStyle: String
        let windows: [Window]
        /// App 里的昼夜条都是天色版（`DayLane.Input.sky`）。
        var sky = true
    }

    private func laneCommands() -> [SceneCommand] {
        let start = 1_789_542_000.0
        return PresentationCore.call("day_lane", LaneInput(
            start: start, length: 86_400, reference: start + 7 * 3600, width: 240, height: 10,
            latitude: 34.0522, longitude: -118.2437,
            available: [Span(start: start + 9 * 3600, end: start + 18 * 3600)], inset: 2, availableStyle: "accent",
            windows: [Window(start: start + 10 * 3600, end: start + 11 * 3600, tier: 0)]))
    }

    @Test func everyRoleRustEmitsIsInTheClosedPalette() {
        // 地图的底图在位图里（`sky`），场景不带绘图命令；会说角色的是昼夜条。
        for command in laneCommands() {
            #expect(DaysidePalette.roles.contains(command.style), "Rust 说了调色板不认识的角色 \(command.style)")
            #expect(command.style != "accent", "颜色不再跟强调色走")
        }
    }

    /// 简繁按文字系统选择；zh-Hans_TW 也应使用简体题记。
    @Test func traditionalChineseFollowsTheScriptBeforeTheRegion() {
        #expect(!SerifFace.isTraditional(Locale(identifier: "zh-Hans_TW")))
        #expect(SerifFace.songti(for: Locale(identifier: "zh-Hans_TW")) == "Songti SC")
        #expect(SerifFace.isTraditional(Locale(identifier: "zh-Hant")))
        #expect(SerifFace.isTraditional(Locale(identifier: "zh-Hant_CN")))
        #expect(SerifFace.isTraditional(Locale(identifier: "zh_TW")))
        #expect(SerifFace.isTraditional(Locale(identifier: "zh_HK")))
        #expect(!SerifFace.isTraditional(Locale(identifier: "zh_CN")))
        #expect(!SerifFace.isTraditional(Locale(identifier: "en_TW")) || Locale(identifier: "en_TW").language.script == nil)
        #expect(Epigraph.setting(locale: Locale(identifier: "zh-Hans_TW"), scale: 1).text == "天涯共此时")
        #expect(Epigraph.setting(locale: Locale(identifier: "zh-Hant"), scale: 1).text == "天涯共此時")
        #expect(Epigraph.setting(locale: Locale(identifier: "en"), scale: 1).lines.map(\.text) == ["It is always sunrise", "somewhere."])
    }

    /// 中文题记是一幅书法竖幅：
    /// 素材在包里、是窄高的一列，读屏念的是字；英文横排两行。
    @Test func theChineseEpigraphIsABrushColumn() {
        let chinese = Epigraph.setting(locale: Locale(identifier: "zh-Hans"), scale: 1)
        #expect(chinese.vertical)
        #expect(chinese.text == "天涯共此时")
        #expect(chinese.artwork.flatMap { NSImage(named: $0) } != nil, "EpigraphZh 竖幅不在包里")
        #expect(chinese.size.height == 310)
        #expect(chinese.size.height > chinese.size.width * 4)
        // 海报 1200 × 460：一列立得下，顶在字标那一行下面。
        #expect(chinese.size.height <= 460 - 2 * Epigraph.margin(width: 1200) - 40)
        let english = Epigraph.setting(locale: Locale(identifier: "en"), scale: 1)
        #expect(!english.vertical)
        #expect(english.size.width > english.size.height)
        // 竖排的一列立在一段夜的正中：左右都有夜时不贴边。
        let size = CGSize(width: 1200, height: 460)
        let nightBetween = { (rect: CGRect) in rect.minX >= 300 && rect.maxX <= 700 ? 0.01 : 0.5 }
        let (box, _) = Epigraph.placement(block: chinese.size, in: size, margin: Epigraph.margin(width: 1200), vertical: true, luminance: nightBetween)
        #expect(abs(box.midX - 500) <= 4)
    }

    @MainActor @Test func welcomeTitleAndHighlightedPlaceKeepTheirOwnSpace() {
        let size = CGSize(width: 512, height: 196)
        let instant = Date(timeIntervalSince1970: 1_791_003_600)
        for language in ["zh-Hans", "en", "ru", "ja"] {
            let locale = Locale(identifier: language)
            let original = MapEpigraph.placement(instant: instant, size: size, latitudes: WorldMapScene.standard, locale: locale)
            let point = CGPoint(x: original.box.midX, y: original.box.midY)
            let moved = MapEpigraph.placement(instant: instant, size: size, latitudes: WorldMapScene.standard, locale: locale, avoidingPoint: point)
            #expect(!moved.box.insetBy(dx: -14, dy: -14).contains(point))
            #expect(CGRect(origin: .zero, size: size).contains(moved.box))
            let label = MapLabelLayout.place(points: [(0, point)], sizes: [0: CGSize(width: 160, height: 18)], in: size,
                                            avoid: [moved.box.insetBy(dx: -14, dy: -14)]).first!
            let frame = CGRect(x: label.center.x - 80, y: label.center.y - 9, width: 160, height: 18)
            #expect(!frame.intersects(moved.box.insetBy(dx: -14, dy: -14)))
        }
        #expect(WorldMapScene.unit(width: 1438, scale: 1438 / 928) > WorldMapScene.unit(width: 928))
        #expect(WorldMapScene.sunBox([100, 100], large: true, scale: 2)[0].width == 48)
    }

    /// 地图上的字只有墨与纸，两者互相读得清（7:1 以上）；「这块地上写墨还是写纸」按实算对比度选。
    @Test func inkAndPaperReadOnEachOtherAndTheMapPicksTheOneThatReads() {
        let contrast = (LightPalette.paperLuminance + 0.05) / (LightPalette.inkLuminance + 0.05)
        #expect(contrast >= 7, "墨与纸只有 \(contrast):1")
        #expect(LightPalette.paperReads(on: 0))       // 夜里的墨色地上写纸
        #expect(!LightPalette.paperReads(on: 1))      // 白天的纸色地上写墨
        #expect(!LightPalette.paperReads(on: MapRaster.luminance(r: 0.95, g: 0.93, b: 0.88)))
        #expect(LightPalette.paperReads(on: MapRaster.luminance(r: 0.10, g: 0.11, b: 0.16)))
    }

    /// 昼夜条上面一截是那里真实的天（一条带色标的渐变），可约段在底下的细轨里；
    /// 地图的昼夜、晨昏线（破晓 / 黄昏两色）、灯火与太阳的光晕都是 Rust 逐像素画的底图，两段晨昏线的颜色由 `sky.palette` 给宿主。
    @Test func skyLanesCarryTheSkyAndTheScheduleSitsInTheTrack() throws {
        let lane = laneCommands()
        let gradient = lane.first { $0.kind == "gradient" }
        let sky = try #require(gradient)
        #expect((sky.stops?.count ?? 0) > 100, "一天每 10 分钟一个色标")
        #expect(lane.contains { $0.style == "available" })
        #expect(!lane.contains { $0.style == "day" }, "天色版不再有半透明的昼色块")
        #expect(LightPalette.dawn != LightPalette.dusk)
    }

    @Test func darkModeOnlyBrightensTheLitParts() {
        #expect(DaysidePalette.opacity("day", 0.22, dark: false) == 0.22)
        #expect(abs(DaysidePalette.opacity("day", 0.22, dark: true) - 0.33) < 1e-9)
        #expect(abs(DaysidePalette.opacity("terminator", 0.6, dark: true) - 0.84) < 1e-9)
        #expect(abs(DaysidePalette.opacity("available", 0.55, dark: true) - 0.825) < 1e-9)
        #expect(DaysidePalette.opacity("primary", 1.0, dark: true) == 1.0)
        #expect(DaysidePalette.opacity("green", 0.55, dark: true) == 0.55)
        #expect(DaysidePalette.opacity("day", 0.9, dark: true) == 1.0)
    }

    @Test func laneAndMapReferenceAreAnimatable() {
        var lane = DayLane(frame: .homeDay(containing: Date(timeIntervalSince1970: 1_789_542_000), timeZone: TimeZone(identifier: "America/Los_Angeles")!),
                           coordinate: nil, reference: Date(timeIntervalSince1970: 1_789_542_000))
        lane.animatableData = 1_789_545_600
        #expect(lane.reference.timeIntervalSince1970 == 1_789_545_600)
    }
}

@MainActor
struct DayLaneRibbonTests {
    private struct Span: Encodable { let start: Double; let end: Double }
    private struct Window: Encodable { let start: Double; let end: Double; let tier: Int }
    private struct Input: Encodable {
        let start: Double
        let length: Double
        let reference: Double
        let width: Double
        let height: Double
        let latitude: Double
        let longitude: Double
        let available: [Span]
        let availableStyle = "green"
        let windows: [Window]
        let inset = 2.0
        let sky = true
        let marks: Bool
    }

    private func commands(width: Double, caseIndex: Int, referenceOffset: Double? = nil, height: Double = 10) -> [SceneCommand] {
        let start = 1_790_000_000.0 + (caseIndex == 1 ? 43_200 : 0)
        let coordinates: [(Double, Double)] = [(51.507, -0.128), (51.507, -0.128), (34.05, -118.24), (35.68, 139.76)]
        let coordinate = coordinates[caseIndex]
        let scheduled = caseIndex >= 2
        let length = caseIndex == 3 ? 90_000.0 : 86_400.0
        return PresentationCore.call("day_lane", Input(
            start: start, length: length, reference: start + (referenceOffset ?? (scheduled ? 64_800 : 21_600)),
            width: width, height: height, latitude: coordinate.0, longitude: coordinate.1,
            available: scheduled ? [.init(start: start + 30_000, end: start + 54_000)] : [],
            windows: scheduled ? [.init(start: start + 48_000, end: start + 60_000, tier: 1),
                                  .init(start: start + 36_000, end: start + 42_000, tier: 0)] : [],
            marks: caseIndex != 0))
    }

    /// 宽度、浅深色、昼夜顺序、刻度、细轨与裁角都要对照原画法。
    @Test(arguments: [140.0, 360.0, 720.0], [false, true])
    func rasterMatchesOriginalGradient(width: Double, dark: Bool) throws {
        // 固定容差：量化最多一档，重采样另留两档；失败后不放宽。
        let channelTolerance = 3
        for height in [10.0, 24.0] {
        let size = CGSize(width: width, height: height)
        for caseIndex in 0..<4 {
            let scene = commands(width: width, caseIndex: caseIndex, height: height)
            #expect(scene.first?.kind == "gradient")
            for scale in [1.0, 2.0] {
                let old = try render(scene: scene, size: size, raster: false, dark: dark, scale: scale)
                let new = try render(scene: scene, size: size, raster: true, dark: dark, scale: scale)
                #expect(old.width == new.width && old.height == new.height)
                #expect(old.width == Int((width * scale).rounded()) && old.height == Int((height * scale).rounded()))
                let oldPixels = try rgba(old)
                let newPixels = try rgba(new)
                try #require(oldPixels.count == newPixels.count)
                let maxDifference = zip(oldPixels, newPixels).reduce(0) { max($0, abs(Int($1.0) - Int($1.1))) }
                let worst = zip(oldPixels, newPixels).enumerated().max {
                    abs(Int($0.element.0) - Int($0.element.1)) < abs(Int($1.element.0) - Int($1.element.1))
                }
                if let worst {
                    let pixel = worst.offset / 4
                    print("MEANTIME_RIBBON_COMPARE width=\(width) height=\(height) dark=\(dark) case=\(caseIndex) scale=\(scale) max=\(maxDifference) x=\(pixel % old.width) y=\(pixel / old.width) channel=\(worst.offset % 4) old=\(worst.element.0) new=\(worst.element.1)")
                }
                #expect(maxDifference <= channelTolerance,
                        "宽 \(width)，深色 \(dark)，序列 \(caseIndex)，倍率 \(scale)，最大通道差 \(maxDifference)")
            }
        }
    }

    }

    /// 参考线逐帧移动时复用天色；换地点或时间框后重新画。
    @Test func referenceChangesReuseTheRibbonButNewSkyReplacesIt() throws {
        let memo = DayLaneRibbonMemo()
        let first = try #require(commands(width: 360, caseIndex: 0).first?.stops)
        let moved = try #require(commands(width: 720, caseIndex: 0, referenceOffset: 64_800).first?.stops)
        memo.update(first)
        let ribbon = try #require(memo.ribbon)
        #expect(ribbon.width == 720 && ribbon.height == 1)
        memo.update(moved)
        #expect(memo.ribbon === ribbon, "参考线和宽度变化不重画天色")
        memo.update(try #require(commands(width: 360, caseIndex: 1).first?.stops))
        let shifted = try #require(memo.ribbon)
        #expect(try rgba(shifted) != rgba(ribbon), "新时间框更新天色像素")
        memo.update(try #require(commands(width: 360, caseIndex: 2).first?.stops))
        #expect(try rgba(#require(memo.ribbon)) != rgba(shifted), "新地点更新天色像素")
        memo.update([])
        #expect(memo.ribbon == nil)
    }

    @Test func nestedRenderingUsesTheRibbonInsteadOfTheFallback() throws {
        for caseIndex in 0..<4 {
            let command = try #require(commands(width: 360, caseIndex: caseIndex).first)
            var usedRibbon = false
            let content = DayLaneGradient(command: command, size: CGSize(width: 360, height: 10),
                                          onRibbonUse: { usedRibbon = true })
            let renderer = ImageRenderer(content: content)
            renderer.proposedSize = ProposedViewSize(width: 360, height: 10)
            _ = try #require(renderer.cgImage)
            #expect(usedRibbon, "原生转位图在嵌套渲染里必须成功，不能靠原画法兜底通过")
        }
    }

    @Test func rasterDensityChangesReplaceTheBitmapAndStableDensityReusesIt() throws {
        let stops = try #require(commands(width: 360, caseIndex: 0).first?.stops)
        let memo = DayLaneRibbonMemo()
        memo.update(stops, width: 360)
        let first = try #require(memo.ribbon)
        #expect(first.width == 360 && first.height == 1)
        memo.update(stops, width: 720)
        let retina = try #require(memo.ribbon)
        #expect(retina.width == 720 && retina.height == 1)
        #expect(retina !== first)
        memo.update(stops, width: 720)
        #expect(memo.ribbon === retina)
    }

    private func render(scene: [SceneCommand], size: CGSize, raster: Bool, dark: Bool, scale: Double, oracle: Bool = false) throws -> CGImage {
        let references = try scene.map { command -> CGImage? in
            guard oracle && command.kind == "gradient" else { return nil }
            return try independentRibbon(command, scale: scale)
        }
        let content = ZStack(alignment: .topLeading) {
            ForEach(Array(scene.enumerated()), id: \.offset) { index, command in
                if oracle, let reference = references[index] {
                    Image(decorative: reference, scale: 1)
                        .resizable().interpolation(.low)
                        .frame(width: CGFloat(reference.width) / scale, height: size.height)
                        .offset(x: command.geometry[0], y: command.geometry[1])
                        .frame(width: size.width, height: size.height, alignment: .topLeading)
                        .clipShape(SceneShape.path(for: command))
                        .overlay {
                            if dark { SceneShape.path(for: command).fill(Color.black.opacity(0.22)) }
                        }
                } else if raster && command.kind == "gradient" {
                    DayLaneGradient(command: command, size: size)
                } else {
                    SceneShape(command: command)
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.secondary.opacity(0.9), lineWidth: 0.75))
        .background(dark ? Color(.sRGB, white: 0.12, opacity: 1) : Color(.sRGB, white: 0.95, opacity: 1))
        .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(width: size.width, height: size.height)
        renderer.scale = scale
        return try #require(renderer.cgImage)
    }

    private func independentRibbon(_ command: SceneCommand, scale: Double) throws -> CGImage {
        let width = max(2, Int((command.geometry[2] * scale).rounded(.up)))
        let stops = try #require(command.stops)
        try #require(stops.count >= 2)
        let colors = try stops.map { stop -> (at: Double, rgb: [Double]) in
            let hex = try #require(UInt32(stop.color.dropFirst(), radix: 16))
            return (stop.at, [Double((hex >> 16) & 255), Double((hex >> 8) & 255), Double(hex & 255)])
        }
        var bytes = [UInt8](repeating: 255, count: width * 4)
        for x in 0..<width {
            let position = (Double(x) + 0.5) / Double(width)
            let upper = colors.firstIndex { $0.at > position } ?? colors.count - 1
            let first = colors[max(0, upper - 1)], last = colors[upper]
            let fraction = last.at > first.at ? min(1, max(0, (position - first.at) / (last.at - first.at))) : 0
            for channel in 0..<3 {
                bytes[x * 4 + channel] = UInt8((first.rgb[channel] * (1 - fraction) + last.rgb[channel] * fraction).rounded())
            }
        }
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        return try #require(CGImage(width: width, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
    }

    private func rgba(_ image: CGImage) throws -> [UInt8] {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data)
        return Array(UnsafeBufferPointer(start: bytes.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }
}


extension DayLaneRibbonTests {
    /// 新地点、季节与非整数宽度独立核对取样规则。
    @Test func rasterMatchesAdditionalSkiesAndFractionalWidths() throws {
        let coordinates: [(Double, Double)] = [(78.22, 15.65), (-33.87, 151.21), (27.72, 85.32), (0, 0)]
        for width in [173.5, 293.0, 517.5] {
            let size = CGSize(width: width, height: 12)
            for (index, coordinate) in coordinates.enumerated() {
                let start = 1_770_000_000.0 + Double(index) * 15_552_000
                let scene: [SceneCommand] = PresentationCore.call("day_lane", Input(
                    start: start, length: 86_400, reference: start + 43_200,
                    width: width, height: 12, latitude: coordinate.0, longitude: coordinate.1,
                    available: [], windows: [], marks: true))
                for dark in [false, true] {
                    for scale in [1.0, 2.0] {
                        let originalImage = try render(scene: scene, size: size, raster: false, dark: dark, scale: scale)
                        let rasterImage = try render(scene: scene, size: size, raster: true, dark: dark, scale: scale)
                        #expect(originalImage.width == rasterImage.width && originalImage.height == rasterImage.height)
                        #expect(rasterImage.width == Int((width * scale).rounded()))
                        #expect(rasterImage.height == Int((size.height * scale).rounded()))
                        let raster = try rgba(rasterImage)
                        let expectedImage = try render(scene: scene, size: size, raster: false, dark: dark, scale: scale, oracle: true)
                        let expected = try rgba(expectedImage)
                        try #require(expectedImage.width == rasterImage.width && expectedImage.height == rasterImage.height)
                        try #require(expected.count == raster.count)
                        let difference = zip(expected, raster).map { abs(Int($0) - Int($1)) }.max() ?? 0
                        // 独立 sRGB 插值经过完整渲染，核对颜色、裁角、刻度、参考线和深色遮罩。
                        print("MEANTIME_RIBBON_ADDITIONAL width=\(width) case=\(index) dark=\(dark) scale=\(scale) max=\(difference)")
                        #expect(difference <= 3, "新天空与非整数宽度的所有像素通道差不超过三档")
                    }
                }
            }
        }
    }
}


extension DayLaneRibbonTests {
    @Test func fractionalRasterSpansReplaceTheBitmapAndStableSpansReuseIt() throws {
        let stops = try #require(commands(width: 360, caseIndex: 0).first?.stops)
        let memo = DayLaneRibbonMemo()
        memo.update(stops, width: 174, span: 173.5)
        let first = try #require(memo.ribbon)
        #expect(first.width == 174 && first.height == 1)
        memo.update(stops, width: 174, span: 173.25)
        let changed = try #require(memo.ribbon)
        #expect(changed !== first)
        memo.update(stops, width: 174, span: 173.25)
        #expect(memo.ribbon === changed)
    }

    @Test func additionalSkyFixturesContainGradientStops() throws {
        let coordinates: [(Double, Double)] = [(78.22, 15.65), (-33.87, 151.21), (27.72, 85.32), (0, 0)]
        for width in [173.5, 293.0, 517.5] {
            for (index, coordinate) in coordinates.enumerated() {
                let start = 1_770_000_000.0 + Double(index) * 15_552_000
                let scene: [SceneCommand] = PresentationCore.call("day_lane", Input(
                    start: start, length: 86_400, reference: start + 43_200,
                    width: width, height: 12, latitude: coordinate.0, longitude: coordinate.1,
                    available: [], windows: [], marks: true))
                let gradient = try #require(scene.first)
                #expect(gradient.kind == "gradient")
                #expect(try #require(gradient.stops).count > 1)
            }
        }
    }
}

@MainActor
struct DayLaneSceneMemoTests {
    private static let start = 1_790_000_000.0

    private func input(
        start: Double = 1_790_000_000,
        length: Double = 86_400,
        reference: Double = 1_790_000_000 + 43_200,
        width: Double = 293,
        height: Double = 12,
        latitude: Double? = 35.68,
        longitude: Double? = 139.76,
        available: [PresentationCore.BandSpan] = [
            .init(start: 1_790_000_000 + 28_800, end: 1_790_000_000 + 43_200),
            .init(start: 1_790_000_000 + 46_800, end: 1_790_000_000 + 64_800)
        ],
        availableStyle: String = "green",
        windows: [DayLane.Window] = [
            .init(start: 1_790_000_000 + 32_400, end: 1_790_000_000 + 39_600, tier: 0),
            .init(start: 1_790_000_000 + 50_400, end: 1_790_000_000 + 57_600, tier: 1)
        ],
        inset: Double = 2,
        marks: Bool = true
    ) -> DayLane.Input {
        DayLane.Input(start: start, length: length, reference: reference, width: width, height: height,
                      latitude: latitude, longitude: longitude, available: available,
                      availableStyle: availableStyle, windows: windows, inset: inset, marks: marks)
    }

    private func direct(_ input: DayLane.Input) -> [SceneCommand] {
        PresentationCore.call("day_lane", input)
    }

    private func expectSameScene(_ actual: [SceneCommand], _ expected: [SceneCommand]) throws {
        try #require(actual.count == expected.count)
        for (a, b) in zip(actual, expected) {
            #expect(a.kind == b.kind)
            #expect(a.geometry == b.geometry)
            #expect(a.style == b.style)
            #expect(a.opacity == b.opacity)
            #expect(a.lineWidth == b.lineWidth)
            try #require(a.stops?.count == b.stops?.count)
            for (left, right) in zip(a.stops ?? [], b.stops ?? []) {
                #expect(left.at == right.at)
                #expect(left.color == right.color)
            }
        }
    }

    @Test func exactInputHitsAndEveryVariableFieldInvalidates() throws {
        let base = input()
        let a = base.available[0]
        let b = base.available[1]
        let w = base.windows[0]
        let z = base.windows[1]
        let latitude = try #require(base.latitude)
        let longitude = try #require(base.longitude)
        let variants: [(String, DayLane.Input)] = [
            ("start", input(start: base.start.nextUp)),
            ("length", input(length: base.length.nextUp)),
            ("adjacent reference timestamp", input(reference: base.reference.nextUp)),
            ("width", input(width: base.width.nextUp)),
            ("height", input(height: base.height.nextUp)),
            ("latitude", input(latitude: latitude.nextUp)),
            ("missing latitude", input(latitude: nil)),
            ("longitude", input(longitude: longitude.nextUp)),
            ("missing longitude", input(longitude: nil)),
            ("available start", input(available: [.init(start: a.start.nextUp, end: a.end), b])),
            ("available end", input(available: [.init(start: a.start, end: a.end.nextUp), b])),
            ("available count", input(available: [a])),
            ("available order", input(available: [b, a])),
            ("available style", input(availableStyle: "accent")),
            ("window start", input(windows: [.init(start: w.start.nextUp, end: w.end, tier: w.tier), z])),
            ("window end", input(windows: [.init(start: w.start, end: w.end.nextUp, tier: w.tier), z])),
            ("window tier", input(windows: [.init(start: w.start, end: w.end, tier: 1), z])),
            ("window count", input(windows: [w])),
            ("window order", input(windows: [z, w])),
            ("inset", input(inset: base.inset.nextUp)),
            ("marks", input(marks: false))
        ]
        // sky 固定为 true。
        for (name, changed) in variants {
            try #require(changed != base, Comment(rawValue: name))
            let memo = DayLaneSceneMemo()
            memo.update(base)
            #expect(memo.computations == 1, Comment(rawValue: name))
            try expectSameScene(memo.commands, direct(base))
            memo.update(base)
            #expect(memo.computations == 1, Comment(rawValue: name))
            memo.update(changed)
            #expect(memo.computations == 2, Comment(rawValue: name))
            try expectSameScene(memo.commands, direct(changed))
            memo.update(changed)
            #expect(memo.computations == 2, Comment(rawValue: name))
        }
    }

    @Test func onlyTheCurrentSceneIsCached() throws {
        let first = input()
        let second = input(reference: first.reference.nextUp)
        let memo = DayLaneSceneMemo()
        memo.update(first)
        memo.update(second)
        memo.update(first)
        #expect(memo.computations == 3, "Returning to an older input recomputes rather than retaining historical scenes")
        try expectSameScene(memo.commands, direct(first))
    }

    private func requireAnimationOwnership<V: View & Animatable>(_ leaf: V) {}

    private func expectReferenceTrajectory(frame: DayLaneFrame, from: Double, to: Double) throws {
        let width = 293.0
        let targetInput = input(start: frame.start.timeIntervalSince1970, length: frame.length,
                                reference: to, width: width)
        let targetLines = Array(direct(targetInput).suffix(2))
        try #require(targetLines.count == 2)
        try #require(targetLines.allSatisfy { $0.kind == "line" && $0.geometry.count == 4 })
        #expect(targetLines.map(\.style) == ["background", "primary"])
        #expect(targetLines.map(\.lineWidth) == [3.5, 1.5])
        var leaf = DayLaneReferenceLines(commands: targetLines, frame: frame,
                                         reference: Date(timeIntervalSince1970: to), width: width)
        requireAnimationOwnership(leaf)
        #expect(leaf.animatableData == to)
        #expect(leaf.animatedOffset == 0)
        for progress in [0.0, 0.25, 0.5, 0.75, 1.0] {
            let timestamp = from + (to - from) * progress
            leaf.animatableData = timestamp
            #expect(leaf.reference.timeIntervalSince1970 == timestamp)
            let expected = Array(direct(input(start: frame.start.timeIntervalSince1970, length: frame.length,
                                               reference: timestamp, width: width)).suffix(2))
            try #require(expected.count == targetLines.count)
            for (target, original) in zip(targetLines, expected) {
                let translatedX = target.geometry[0] + Double(leaf.animatedOffset)
                #expect(abs(translatedX - original.geometry[0]) <= 1e-9,
                        "Timestamp interpolation must retain Rust's frame-boundary clamp")
                #expect(abs(target.geometry[2] + Double(leaf.animatedOffset) - original.geometry[2]) <= 1e-9)
                #expect(target.geometry[1] == original.geometry[1])
                #expect(target.geometry[3] == original.geometry[3])
            }
            let actualImage = try renderReference(leaf, width: width)
            let nativeImage = try renderReferenceCommands(expected, width: width)
            try expectPixels(actualImage, nativeImage, label: "reference progress=\(progress)")
        }
    }

    @Test func timestampReferenceClampsBeforeAndAfterTheFrame() throws {
        let frame = DayLaneFrame.homeDay(containing: Date(timeIntervalSince1970: Self.start), timeZone: .gmt)
        let start = frame.start.timeIntervalSince1970
        let end = frame.end.timeIntervalSince1970
        try expectReferenceTrajectory(frame: frame, from: start - 7_200, to: start + 7_200)
        try expectReferenceTrajectory(frame: frame, from: end - 7_200, to: end + 7_200)
        try expectReferenceTrajectory(frame: frame, from: start - 7_200, to: end + 7_200)
        try expectReferenceTrajectory(frame: frame, from: end + 7_200, to: start - 7_200)
        try expectReferenceTrajectory(frame: frame, from: start + 7_200, to: start + 64_800)
    }

    @Test func replacingTheFrameAtMidnightKeepsTimestampSemantics() throws {
        let old = DayLaneFrame.homeDay(containing: Date(timeIntervalSince1970: Self.start), timeZone: .gmt)
        let next = DayLaneFrame.homeDay(containing: old.end.addingTimeInterval(3_600), timeZone: .gmt)
        #expect(old.end == next.start)
        // 新时间框沿用旧时间戳，重现跨午夜的插值。
        try expectReferenceTrajectory(frame: next, from: old.end.timeIntervalSince1970 - 3_600,
                                      to: next.start.timeIntervalSince1970 + 3_600)
        try expectReferenceTrajectory(frame: old, from: next.start.timeIntervalSince1970 + 3_600,
                                      to: old.end.timeIntervalSince1970 - 3_600)
    }

    @Test func productionLaneTargetsMatchNativeRustScenes() throws {
        let cases = [
            input(),
            input(length: 90_000, reference: Self.start + 87_000, width: 173.5, height: 10,
                  latitude: 51.507, longitude: -0.128),
            input(length: 82_800, reference: Self.start - 7_200, width: 140, height: 24,
                  latitude: 34.05, longitude: -118.24),
            input(reference: Self.start + 93_600, width: 360, latitude: nil, longitude: nil, marks: false)
        ]
        for (caseIndex, value) in cases.enumerated() {
            let commands = direct(value)
            try #require(commands.count >= 3)
            if value.latitude != nil && value.longitude != nil {
                #expect(commands.first?.kind == "gradient")
                #expect(try #require(commands.first?.stops).count > 1)
            } else {
                #expect(commands.first?.kind == "rect")
            }
            let frame = DayLaneFrame(start: Date(timeIntervalSince1970: value.start), length: value.length,
                                     timeZoneID: "Etc/UTC")
            let coordinate: Coordinate? = if let latitude = value.latitude, let longitude = value.longitude {
                Coordinate(latitude: latitude, longitude: longitude)
            } else { nil }
            let lane = DayLane(frame: frame, coordinate: coordinate,
                               reference: Date(timeIntervalSince1970: value.reference),
                               available: value.available.map { DateInterval(start: Date(timeIntervalSince1970: $0.start),
                                                                            end: Date(timeIntervalSince1970: $0.end)) },
                               availableStyle: .green, windows: value.windows, inset: value.inset)
            for dark in [false, true] {
                for scale in [1.0, 2.0] {
                    let stops = commands.first { $0.kind == "gradient" }?.stops?.map {
                        SkyStripState.Stop(at: $0.at, color: $0.color)
                    } ?? []
                    let native = ZStack(alignment: .topLeading) {
                        ForEach(Array(commands.enumerated()), id: \.offset) { _, command in
                            if command.kind == "line", command.style == "primary" || command.style == "background" {
                                SceneShape.path(for: command).stroke(SkyLaneForegroundStyle(stops: stops,
                                    backing: command.style == "background", shadeWhenContrastIncreased: true),
                                    lineWidth: command.lineWidth)
                            } else {
                                SceneShape(command: command)
                            }
                        }
                    }
                    .frame(width: value.width, height: value.height, alignment: .topLeading)
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(
                        SkyLaneForegroundStyle(stops: stops, shadeWhenContrastIncreased: true), lineWidth: 0.75))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    let actualImage = try render(lane, size: CGSize(width: value.width, height: value.height),
                                                 dark: dark, scale: scale, marks: value.marks)
                    let nativeImage = try render(native, size: CGSize(width: value.width, height: value.height),
                                                 dark: dark, scale: scale, marks: value.marks)
                    try expectPixels(actualImage, nativeImage,
                                     label: "production case=\(caseIndex) dark=\(dark) scale=\(scale)")
                }
            }
        }
    }

    private func renderReference(_ leaf: DayLaneReferenceLines, width: Double) throws -> CGImage {
        try render(leaf, size: CGSize(width: width, height: 12), dark: false, scale: 2, marks: false)
    }

    private func renderReferenceCommands(_ commands: [SceneCommand], width: Double) throws -> CGImage {
        let content = ZStack(alignment: .topLeading) {
            ForEach(Array(commands.enumerated()), id: \.offset) { _, command in SceneShape(command: command) }
        }
        return try render(content, size: CGSize(width: width, height: 12), dark: false, scale: 2, marks: false)
    }

    private func render<V: View>(_ content: V, size: CGSize, dark: Bool, scale: Double, marks: Bool) throws -> CGImage {
        let view = content
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(dark ? Color(.sRGB, white: 0.12, opacity: 1) : Color(.sRGB, white: 0.95, opacity: 1))
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.accessibilityDifferentiateWithoutColor, marks)
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(width: size.width, height: size.height)
        renderer.scale = scale
        return try #require(renderer.cgImage)
    }

    private func rgba(_ image: CGImage) throws -> [UInt8] {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
                                            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try #require(context.data)
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }

    private func expectPixels(_ actual: CGImage, _ expected: CGImage, label: String) throws {
        try #require(actual.width == expected.width && actual.height == expected.height)
        let a = try rgba(actual)
        let b = try rgba(expected)
        try #require(a.count == b.count)
        let maximum = zip(a, b).reduce(0) { max($0, abs(Int($1.0) - Int($1.1))) }
        print("MEANTIME_DAYLANE_SCENE_COMPARE \(label) max=\(maximum)")
        #expect(maximum <= 3, Comment(rawValue: label))
    }
}


// SDK 的公开属性只读；夹具通过原生可写入口设置同一个无障碍环境值。
private extension View {
    func environment(_ keyPath: KeyPath<EnvironmentValues, Bool>, _ value: Bool) -> some View {
        precondition(keyPath == \.accessibilityDifferentiateWithoutColor,
                     "Only the native differentiate-without-color override is supported")
        return transformEnvironment(\._accessibilityDifferentiateWithoutColor) { $0 = value }
    }
}

@MainActor
private final class AccessibilityEnvironmentProbeRecorder {
    var values: [Bool] = []

    func record(_ value: Bool) {
        values.append(value)
    }
}

@MainActor
private struct AccessibilityEnvironmentProbe: View {
    @Environment(\.accessibilityDifferentiateWithoutColor) private var marks
    let recorder: AccessibilityEnvironmentProbeRecorder

    var body: some View {
        recorder.record(marks)
        return Color.black.frame(width: 8, height: 8)
    }
}

@MainActor
struct AccessibilityEnvironmentBridgeTests {
    @Test func writableSDKEntryReachesPublicEnvironmentGetter() throws {
        for value in [false, true] {
            let recorder = AccessibilityEnvironmentProbeRecorder()
            let content = AccessibilityEnvironmentProbe(recorder: recorder)
                .environment(\.accessibilityDifferentiateWithoutColor, value)
            let renderer = ImageRenderer(content: content)
            renderer.proposedSize = ProposedViewSize(width: 8, height: 8)
            _ = try #require(renderer.cgImage)
            #expect(!recorder.values.isEmpty)
            #expect(recorder.values.allSatisfy { $0 == value })
        }
    }
}
