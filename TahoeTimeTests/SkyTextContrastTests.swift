// SPDX-License-Identifier: GPL-3.0-only
// 天色上的文字按实际色板与合成后的颜色量对比度，次要文字不能退回框的字色。

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import TahoeTime

@Suite(.serialized)
@MainActor
struct SkyTextContrastTests {
    private struct RGB {
        let r, g, b: Double
        var luminance: Double { MapRaster.luminance(r: r, g: g, b: b) }
        func blended(over background: RGB, opacity: Double) -> RGB {
            RGB(r: r * opacity + background.r * (1 - opacity),
                g: g * opacity + background.g * (1 - opacity),
                b: b * opacity + background.b * (1 - opacity))
        }
    }

    private struct Sample {
        let name: String
        let colors: SkyPanel.Colors
        let chrome: SkyPanel.Colors
    }

    private func rgb(_ color: Color) throws -> RGB {
        let value = try #require(NSColor(color).usingColorSpace(.sRGB))
        return RGB(r: value.redComponent, g: value.greenComponent, b: value.blueComponent)
    }

    private func contrast(_ foreground: RGB, _ background: RGB) -> Double {
        (max(foreground.luminance, background.luminance) + 0.05) /
        (min(foreground.luminance, background.luminance) + 0.05)
    }

    private func colors(in sample: SkyPanel.Colors) -> [RGB] {
        let top = LightPalette.components(sample.top)
        let horizon = LightPalette.components(sample.horizon)
        // SwiftUI 渐变按 sRGB 插值，端点之间也逐段实量。
        return (0...100).map { step in
            let f = Double(step) / 100
            return RGB(r: top.0 * (1 - f) + horizon.0 * f,
                       g: top.1 * (1 - f) + horizon.1 * f,
                       b: top.2 * (1 - f) + horizon.2 * f)
        } + [LightPalette.components(sample.mid)].map { RGB(r: $0.0, g: $0.1, b: $0.2) }
    }

    private func samples(increased: Bool) throws -> [Sample] {
        let london = TimeZoneEntry(timezoneID: "Europe/London", cityName: "London",
                                  coordinate: .init(latitude: 51.51, longitude: -0.13), countryCode: "GB")
        let polar = TimeZoneEntry(timezoneID: "Arctic/Longyearbyen", cityName: "Longyearbyen",
                                 coordinate: .init(latitude: 78.22, longitude: 15.65), countryCode: "NO")
        var result = [Sample]()
        // 伦敦一整天包含正午、清晨、破晓、黄昏与深夜；两至日另取极昼、极夜。
        let summer = Date(timeIntervalSince1970: 1_782_000_000)
        for hour in 0..<24 {
            let instant = summer.addingTimeInterval(Double(hour) * 3600)
            let panel = SkyPanel.compute(instant: instant, now: instant, zones: [london],
                                         need: increased ? 7 : 5.5, locale: Locale(identifier: "en"))
            result.append(Sample(name: "London hour \(hour)", colors: try #require(panel.rows[london.id]).colors, chrome: panel.chrome))
        }
        for (name, unix) in [("polar day", 1_782_043_200.0), ("polar night", 1_797_854_400.0)] {
            let instant = Date(timeIntervalSince1970: unix)
            let panel = SkyPanel.compute(instant: instant, now: instant, zones: [polar],
                                         need: increased ? 7 : 5.5, locale: Locale(identifier: "en"))
            let row = try #require(panel.rows[polar.id])
            #expect(row.sunrise == nil && row.sunset == nil, "\(name) 夹具不是极地全天")
            #expect(row.path?.up == (name == "polar day"))
            result.append(Sample(name: name, colors: row.colors, chrome: panel.chrome))
        }
        #expect(result.contains { $0.colors.ink } && result.contains { !$0.colors.ink })
        return result
    }

    private func rendered(_ style: AnyShapeStyle, scheme: ColorScheme, inherited: Color, background: Color, increased: Bool = false, sky: SkyPanel? = nil, followsSky: Bool = false) throws -> RGB {
        // 渲染实际的 AnyShapeStyle，能抓住 .foreground 取到框字色或层级不透明度的问题。
        let renderer = ImageRenderer(content: Rectangle().fill(style).frame(width: 4, height: 4)
            .foregroundStyle(inherited).background(background).environment(\.colorScheme, scheme)
            .environment(\.colorSchemeContrast, increased ? .increased : .standard)
            .environment(\.panelSky, sky).environment(\.panelFollowsSky, followsSky))
        let image = try #require(renderer.cgImage)
        var bytes = [UInt8](repeating: 0, count: 4 * 4 * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: 4, height: 4,
                                                 bitsPerComponent: 8, bytesPerRow: 16,
                                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        return RGB(r: Double(bytes[40]) / 255, g: Double(bytes[41]) / 255, b: Double(bytes[42]) / 255)
    }

    @Test(arguments: ["light", "dark"], [false, true])
    func actualSecondaryStylesReadWithEveryPanelOption(appearance: String, increased: Bool) async throws {
        let scheme: ColorScheme = appearance == "light" ? .light : .dark
        let samples = try samples(increased: increased)
        var minimum = Double.infinity
        var renderedColors = [String: RGB]()
        for colors in PanelColors.allCases {
            for sunTimes in [false, true] {
                for besideName in [false, true] {
                    for mode in DisplayMode.allCases {
                        for size in TextSize.allCases {
                            var settings = AppSettings()
                            settings.panelColors = colors
                            settings.panelShowsSunTimes = sunTimes
                            settings.showOffsetBesideName = besideName
                            settings.displayMode = mode
                            settings.textSize = size
                            let followsSky = colors == .sky
                            let opposing = [try #require(samples.first { $0.colors.ink }), try #require(samples.first { !$0.colors.ink })]
                            for sample in followsSky ? opposing : [opposing[0]] {
                                let metrics = SkyRowMetrics(settings: settings, textScale: size.scale)
                                let style = RowPrimaryTextStyle(settings: settings, metrics: metrics,
                                                                followsSky: followsSky, skyColors: sample.colors)
                                let background = followsSky ? sample.colors.midColor : (scheme == .light ? LightPalette.paper : LightPalette.ink)
                                let inherited = followsSky ? (sample.colors.ink ? LightPalette.paper : LightPalette.ink) : Color.primary
                                // 每组设置真正画一遍两种相反的天，缓存只用于后面的全色板扫查。
                                let ink = try rendered(sunTimes ? style.sunTimes : style.secondary, scheme: scheme,
                                                       inherited: inherited, background: background, increased: increased)
                                for background in followsSky ? self.colors(in: sample.colors) : [try rgb(background)] {
                                    #expect(contrast(ink, background) >= 4.5, "设置实绘 \(colors), \(mode), \(size), sun=\(sunTimes), offset=\(besideName), \(sample.name)")
                                }
                                if followsSky {
                                    let glyph = try #require(style.glyph)
                                    let chosen = try rgb(glyph)
                                    let expected = try rgb(SkyTextRole.panelGlyph.foreground(in: sample.colors))
                                    #expect(chosen.luminance == expected.luminance)
                                }
                            }
                            await Task.yield()
                            for sample in samples {
                                let metrics = SkyRowMetrics(settings: settings, textScale: size.scale)
                                let style = RowPrimaryTextStyle(settings: settings, metrics: metrics,
                                                                followsSky: followsSky, skyColors: sample.colors)
                                // 故意用与行相反的框字色，防止行内次要色偷拿框的角色。
                                let inherited = followsSky ? (sample.colors.ink ? LightPalette.paper : LightPalette.ink) : Color.primary
                                let background = followsSky ? sample.colors.midColor : (scheme == .light ? LightPalette.paper : LightPalette.ink)
                                let stages = sunTimes ? [style.secondary, style.sunTimes] : [style.secondary]
                                for (index, stage) in stages.enumerated() {
                                    // 这些选项只改文字内容与字号，同色同外观只渲染一次，避免重复离屏绘图挤占钟的调度。
                                    let key = "\(colors.rawValue):\(sample.name):\(index)"
                                    let ink: RGB
                                    if let cached = renderedColors[key] {
                                        ink = cached
                                    } else {
                                        ink = try rendered(stage, scheme: scheme, inherited: inherited, background: background, increased: increased)
                                        renderedColors[key] = ink
                                    }
                                    let backgrounds = followsSky ? self.colors(in: sample.colors) : [try rgb(background)]
                                    let ratio = try #require(backgrounds.map { contrast(ink, $0) }.min())
                                    minimum = min(minimum, ratio)
                                    #expect(ratio >= 4.5, "\(sample.name), \(colors), \(mode), \(size), sun=\(sunTimes), offset=\(besideName), \(appearance), increased=\(increased): \(ratio)")
                                }
                            }
                        }
                    }
                }
            }
        }
        print("SKY_TEXT_SECONDARY \(appearance) increased=\(increased) minimum=\(minimum)")
    }

    @Test(arguments: [false, true])
    func opaqueTextAndGlyphRolesReadAcrossAllRustRowGradients(increased: Bool) throws {
        var minimum = Double.infinity
        for sample in try samples(increased: increased) {
            for role in SkyTextRole.allCases {
                let chrome = [SkyTextRole.panelChromeSecondary, .sliderCaption, .sliderScale].contains(role)
                let palette = chrome ? sample.chrome : sample.colors
                let foreground = try rgb(role.foreground(in: palette))
                for background in colors(in: palette) {
                    let ratio = contrast(foreground, background)
                    minimum = min(minimum, ratio)
                    #expect(ratio >= role.minimumContrast, "\(sample.name), \(role): \(ratio)")
                }
            }
        }
        print("SKY_TEXT_ROLES increased=\(increased) minimum=\(minimum)")
    }

    @Test(arguments: ["light", "dark"], [false, true])
    func chromeSecondaryStyleResolvesItsActualEnvironment(appearance: String, increased: Bool) throws {
        let scheme: ColorScheme = appearance == "light" ? .light : .dark
        for sample in try samples(increased: increased) {
            let panel = SkyPanel(rows: [:], dividers: [:], chrome: sample.chrome, dayHere: nil)
            let foreground = try rendered(AnyShapeStyle(.panelSecondary), scheme: scheme,
                inherited: sample.chrome.ink ? LightPalette.paper : LightPalette.ink,
                background: sample.chrome.midColor, increased: increased, sky: panel, followsSky: true)
            for background in colors(in: sample.chrome) {
                #expect(contrast(foreground, background) >= 4.5, "框次要色 \(appearance), \(sample.name)")
            }
        }
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> RGB {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        let index = (y * image.width + x) * 4
        return RGB(r: Double(bytes[index]) / 255, g: Double(bytes[index + 1]) / 255, b: Double(bytes[index + 2]) / 255)
    }

    @Test(arguments: [false, true])
    func actualSunPathGlyphUsesTheRowRoleWithoutNightFade(increased: Bool) throws {
        for sample in try samples(increased: increased) {
            for up in [false, true] {
                let path = SkyPanel.SunPath(up: up, fraction: 0.5)
                let foreground = SkyTextRole.panelGlyph.foreground(in: sample.colors)
                let renderer = ImageRenderer(content: SunPathGlyph(path: path, foreground: foreground)
                    .foregroundStyle(sample.colors.ink ? LightPalette.paper : LightPalette.ink)
                    .background(sample.colors.midColor))
                renderer.scale = 10
                let image = try #require(renderer.cgImage)
                let (center, _) = SunPathGlyph.sun(path)
                // 同时取太阳实心处与地平线实线处，验证真正画出的字色，没有夜间透明度回退。
                for point in [center, CGPoint(x: 6, y: 9.5)] {
                    let ink = try pixel(image, x: Int(point.x * 10), y: Int(point.y * 10))
                    #expect(contrast(ink, try rgb(sample.colors.midColor)) >= 3, "太阳弧 \(sample.name), up=\(up)")
                }
            }
        }
    }

    @Test(arguments: ["light", "dark"], [false, true])
    func actualRimChoosesSkyAtTheSidesAndChromeAboveAndBelow(appearance: String, increased: Bool) throws {
        let scheme: ColorScheme = appearance == "light" ? .light : .dark
        let samples = try samples(increased: increased)
        for sample in [try #require(samples.first { $0.colors.ink }), try #require(samples.first { !$0.colors.ink })] {
            let panel = SkyPanel(rows: [:], dividers: [:], chrome: sample.chrome, dayHere: nil)
            for followsSky in [false, true] {
                let chrome = followsSky ? sample.chrome.midColor : (scheme == .light ? LightPalette.paper : LightPalette.ink)
                let content = Circle().strokeBorder(SkyGlyphRimStyle(luminance: LightPalette.luminance(sample.colors.mid),
                    role: .sliderGlyph, radius: 9.25, halfBand: 4), lineWidth: 1.5)
                    .frame(width: 20, height: 20)
                    .background {
                        ZStack { chrome; Rectangle().fill(sample.colors.midColor).frame(height: 8) }
                    }
                    .environment(\.colorScheme, scheme).environment(\.panelSky, panel)
                    .environment(\.panelFollowsSky, followsSky)
                let renderer = ImageRenderer(content: content)
                renderer.scale = 10
                let image = try #require(renderer.cgImage)
                let side = try pixel(image, x: 7, y: 100)
                let top = try pixel(image, x: 100, y: 7)
                #expect(contrast(side, try rgb(sample.colors.midColor)) >= 3, "圆点两侧 \(sample.name)")
                #expect(contrast(top, try rgb(chrome)) >= 3, "圆点上下 \(sample.name), system=\(!followsSky), \(appearance)")
            }
        }
    }

    private struct Lane: Decodable {
        struct Stop: Decodable { let at: Double; let color: String }
        let stops: [Stop]
    }
    private struct LaneInput: Encodable { let start, end, latitude, longitude, step: Double }

    @Test(arguments: ["light", "dark"], [false, true])
    func stripMarksAndSliderRimsReadOnTheirLocallyShadedSky(appearance: String, increased: Bool) throws {
        let lane: Lane = RustCore.invoke("sky.lane", LaneInput(start: 1_782_000_000, end: 1_782_086_400,
                                                              latitude: 51.51, longitude: -0.13, step: 2))
        let stops = lane.stops.map { SkyStripState.Stop(at: $0.at, color: $0.color) }
        let shade = appearance == "dark" && !increased ? 0.22 : 0
        var minimum = Double.infinity
        for step in 0...1440 {
            let fraction = Double(step) / 1440
            for (role, dim) in [(SkyTextRole.sliderGlyph, 0.0), (.stripGlyph, shade)] {
                let background = try #require(LightPalette.skyLuminance(stops: stops, at: fraction, shade: dim))
                let foreground = try rgb(role.foreground(on: background))
                let ratio = (max(foreground.luminance, background) + 0.05) / (min(foreground.luminance, background) + 0.05)
                minimum = min(minimum, ratio)
                #expect(ratio >= 3, "\(role), \(appearance), increased=\(increased), minute=\(step): \(ratio)")
            }
        }
        print("SKY_STRIP_GLYPH \(appearance) increased=\(increased) minimum=\(minimum)")
    }

    @Test func mapLabelsProbeAndGlyphsReadOnRawSkyWithTheirActualBacking() throws {
        var textMinimum = Double.infinity
        var glyphMinimum = Double.infinity
        // 取 Rust 未为小字让路的天色：地图的地形会变亮暗，文字另有反色衬边，指针标签有不透明反色底。
        let lane: Lane = RustCore.invoke("sky.lane", LaneInput(start: 1_782_000_000, end: 1_782_086_400,
                                                              latitude: 51.51, longitude: -0.13, step: 2))
        for stop in lane.stops {
            let background = try rgb(LightPalette.color(stop.color))
            let paper = LightPalette.paperReads(on: background.luminance)
            let halo = try rgb(paper ? LightPalette.haloDark : LightPalette.haloLight)
            for role in [SkyTextRole.mapLabel, .earthLabel] {
                let foreground = try rgb(role.foreground(paper: paper))
                let ratio = contrast(foreground, halo.blended(over: background, opacity: 0.85))
                textMinimum = min(textMinimum, ratio)
                #expect(ratio >= 4.5, "\(role), \(stop.color), 衬边合成: \(ratio)")
            }
            let probe = try rgb(SkyTextRole.mapProbe.foreground(paper: paper))
            let backing = try rgb(paper ? LightPalette.ink : LightPalette.paper)
            #expect(contrast(probe, backing) >= 4.5)
            let glyph = try rgb(SkyTextRole.mapGlyph.foreground(on: background.luminance))
            let ratio = contrast(glyph, background)
            glyphMinimum = min(glyphMinimum, ratio)
            #expect(ratio >= 3, "地图圈 \(stop.color): \(ratio)")
        }
        print("SKY_MAP_TEXT minimum=\(textMinimum) glyphMinimum=\(glyphMinimum) stops=\(lane.stops.count)")
    }

    @Test func finiteWidthRimsSwitchAtTheHorizontalBandBoundaries() throws {
        // 按整数色阶比较，保留一个色阶的容差。
        func byteChannelDelta(_ drawn: Double, _ reference: Double) -> Double {
            let drawnByte = Int((drawn * 255).rounded())
            let referenceByte = Int((reference * 255).rounded())
            return Double(abs(drawnByte - referenceByte)) / 255
        }
        let samples = try samples(increased: false)
        let light = try #require(samples.first { $0.colors.ink })
        let dark = try #require(samples.first { !$0.colors.ink })
        for (sample, chrome) in [(light, dark.colors), (dark, light.colors)] {
            let panel = SkyPanel(rows: [:], dividers: [:], chrome: chrome, dayHere: nil)
            for (role, radius, lineWidth, points) in [
                (SkyTextRole.sliderGlyph, 10.0, 1.5, [CGPoint(x: 1.2, y: 5.9), CGPoint(x: 2.2, y: 6.2)]),
                (.stripGlyph, 5.5, 1.25, [CGPoint(x: 2.5, y: 1.4), CGPoint(x: 2.9, y: 1.6)])
            ] {
                let diameter = radius * 2
                let content = Circle().strokeBorder(SkyGlyphRimStyle(luminance: LightPalette.luminance(sample.colors.mid),
                    role: role, radius: radius, halfBand: 4), lineWidth: lineWidth)
                    .frame(width: diameter, height: diameter)
                    .background {
                        ZStack { chrome.midColor; Rectangle().fill(sample.colors.midColor).frame(height: 8) }
                    }
                    .environment(\.colorScheme, chrome.scheme).environment(\.panelSky, panel)
                    .environment(\.panelFollowsSky, true)
                let renderer = ImageRenderer(content: content)
                renderer.scale = 20
                let image = try #require(renderer.cgImage)
                // 在描边的内外缘之间取点；上下镜像都要在真正的水平边界换角色。
                for point in points + points.map({ CGPoint(x: $0.x, y: diameter - $0.y) }) {
                    let inside = abs(point.y - radius) < 4
                    let background = inside ? sample.colors.midColor : chrome.midColor
                    let expected = inside ? role.foreground(in: sample.colors) : role.foreground(in: chrome)
                    let drawn = try pixel(image, x: Int(point.x * 20), y: Int(point.y * 20))
                    let reference = try rgb(expected)
                    #expect(byteChannelDelta(drawn.r, reference.r) <= 1.0 / 255 &&
                            byteChannelDelta(drawn.g, reference.g) <= 1.0 / 255 &&
                            byteChannelDelta(drawn.b, reference.b) <= 1.0 / 255,
                            "\(role), \(point), skyInk=\(sample.colors.ink), inside=\(inside)")
                    #expect(contrast(drawn, try rgb(background)) >= 3,
                            "水平边界 \(role), \(point), inside=\(inside)")
                }
            }
        }
    }
}
