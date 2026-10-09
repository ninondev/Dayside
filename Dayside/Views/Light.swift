// SPDX-License-Identifier: GPL-3.0-only
//
//  Light.swift
//  Dayside
//
//  光的两样基础材料：颜色与字。颜色只有天色（Rust `sky.rs` 按太阳高度算）与几样固定的颜色
//  （墨与纸、晨昏线、太阳、月亮，同样由 Rust 给，`sky.palette`）；字只有墨与纸两种颜色，地名用衬线、钟点用等宽数字。
//

import AppKit
import SwiftUI

/// 地图上几样固定的颜色（Rust `sky.palette`，进程里只取一次）。不透明度按用处写在画的地方。
nonisolated enum LightPalette {
    private struct Hexes: Decodable {
        let ink, paper, dawn, dusk, sun, sunRim, sunRing, sunGlow, moonDark, moonLit, haloDark, haloLight, nightSky: String
    }
    private struct Empty: Encodable {}
    private static let hexes: Hexes = RustCore.invoke("sky.palette", Empty())

    /// 墨与纸：地图上的字与地点的圈只用这两种颜色（面板的行也是）。
    static let ink = color(hexes.ink)
    static let paper = color(hexes.paper)
    /// 地图深夜海面的边色，也用于地球窗四周。
    static let nightSky = color(hexes.nightSky)
    static let luminanceOfNightSky = luminance(hexes.nightSky)
    /// 晨昏线：破晓那一侧偏玫瑰、黄昏那一侧偏琥珀。
    static let dawn = color(hexes.dawn)
    static let dusk = color(hexes.dusk)
    /// 太阳：金盘、深色外沿（浅底上看得见）、浅色细圈（深底上看得见）、光晕。
    static let sun = color(hexes.sun)
    static let sunRim = color(hexes.sunRim)
    static let sunRing = color(hexes.sunRing)
    static let sunGlow = color(hexes.sunGlow)
    /// 月亮：暗面与亮面。
    static let moonDark = color(hexes.moonDark)
    static let moonLit = color(hexes.moonLit)
    /// 地图上的字的衬底（光晕）：字是纸就衬深色，字是墨就衬浅色。
    static let haloDark = color(hexes.haloDark)
    static let haloLight = color(hexes.haloLight)
    /// 墨与纸的相对亮度（WCAG），给「这块地方上写墨还是写纸」实算对比度用。
    static let inkLuminance = luminance(hexes.ink)
    static let paperLuminance = luminance(hexes.paper)

    /// "#rrggbb" → sRGB 颜色（Rust 给的全是 sRGB 8 位值）。
    static func color(_ hex: String) -> Color {
        let (r, g, b) = components(hex)
        return Color(.sRGB, red: r, green: g, blue: b)
    }

    static func components(_ hex: String) -> (Double, Double, Double) {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return (Double((value >> 16) & 0xff) / 255, Double((value >> 8) & 0xff) / 255, Double(value & 0xff) / 255)
    }

    static func luminance(_ hex: String) -> Double {
        let (r, g, b) = components(hex)
        return MapRaster.luminance(r: r, g: g, b: b)
    }

    /// 天色带上的任意一点，按实际 sRGB 色标插值后量亮度；压暗量也一起算。
    static func skyLuminance(stops: [SkyStripState.Stop], at fraction: Double, shade: Double = 0) -> Double? {
        guard let first = stops.first, let last = stops.last else { return nil }
        let at = min(1, max(0, fraction))
        let upper = stops.firstIndex { $0.at >= at } ?? (stops.count - 1)
        let right = stops[upper]
        let left = upper > 0 ? stops[upper - 1] : first
        let f = right.at > left.at ? min(1, max(0, (at - left.at) / (right.at - left.at))) : 0
        let a = components(at >= last.at ? last.color : left.color)
        let b = components(right.color)
        let dim = 1 - min(1, max(0, shade))
        return MapRaster.luminance(r: (a.0 * (1 - f) + b.0 * f) * dim,
                                   g: (a.1 * (1 - f) + b.1 * f) * dim,
                                   b: (a.2 * (1 - f) + b.2 * f) * dim)
    }

    /// 行里的文字按它脚下的天取色；纯色行与提高对比度时，脚下始终是整体色。
    static func rowLuminance(_ row: SkyPanel.Row, at fraction: Double, flat: Bool) -> Double {
        guard row.gradient && !flat else { return luminance(row.colors.mid) }
        let top = components(row.colors.top)
        let horizon = components(row.colors.horizon)
        let f = min(1, max(0, fraction))
        return MapRaster.luminance(r: top.0 * (1 - f) + horizon.0 * f,
                                   g: top.1 * (1 - f) + horizon.1 * f,
                                   b: top.2 * (1 - f) + horizon.2 * f)
    }

    /// 底的相对亮度为 `background` 时，写纸（true）还是写墨：谁的对比度高写谁。
    static func paperReads(on background: Double) -> Bool {
        let contrast = { (a: Double, b: Double) in (max(a, b) + 0.05) / (min(a, b) + 0.05) }
        return contrast(paperLuminance, background) > contrast(inkLuminance, background)
    }

    /// 墨与纸在两色标之间换手时用硬边，避免中间混出对比度不足的灰。
    static func laneInkStops(_ stops: [SkyStripState.Stop], shade: Double, backing: Bool = false) -> [Gradient.Stop] {
        guard let first = stops.first, let last = stops.last else { return [] }
        func paper(_ at: Double) -> Bool {
            paperReads(on: skyLuminance(stops: stops, at: at, shade: shade)!)
        }
        func color(_ value: Bool) -> Color {
            (value != backing) ? Self.paper : ink
        }
        var result = [Gradient.Stop(color: color(paper(first.at)), location: first.at)]
        for index in 1..<stops.count {
            let left = stops[index - 1].at
            let right = stops[index].at
            let a = paper(left)
            let b = paper(right)
            if a != b {
                var low = left
                var high = right
                for _ in 0..<32 {
                    let middle = (low + high) / 2
                    if paper(middle) == a { low = middle } else { high = middle }
                }
                let crossing = (low + high) / 2
                result.append(.init(color: color(a), location: crossing))
                result.append(.init(color: color(b), location: crossing))
            }
        }
        result.append(.init(color: color(paper(last.at)), location: 1))
        return result
    }
}

/// 天色上的文字与符号共用墨、纸；次要文字也不再按层级冲淡。
nonisolated enum SkyTextRole: String, CaseIterable, Sendable {
    case panelName, panelClock, panelSecondary, panelSunTimes, panelGlyph, panelChromeSecondary
    case sliderCaption, sliderScale, sliderGlyph, stripGlyph, mapLabel, mapProbe, mapGlyph, earthLabel
    case laneGlyph

    var minimumContrast: Double {
        switch self {
        case .panelGlyph, .sliderGlyph, .stripGlyph, .mapGlyph, .laneGlyph: 3
        default: 4.5
        }
    }

    func foreground(in colors: SkyPanel.Colors) -> Color {
        foreground(paper: !colors.ink)
    }

    func foreground(paper: Bool) -> Color {
        paper ? LightPalette.paper : LightPalette.ink
    }

    func foreground(on luminance: Double) -> Color {
        foreground(paper: LightPalette.paperReads(on: luminance))
    }
}

/// 昼夜条上的细线与刻度按脚下每一段天选墨或纸，衬边取反色。
struct SkyLaneForegroundStyle: ShapeStyle {
    let stops: [SkyStripState.Stop]
    var backing = false
    var shadeInDarkAppearance = true
    var shadeWhenContrastIncreased = false

    func resolve(in environment: EnvironmentValues) -> AnyShapeStyle {
        guard !stops.isEmpty else { return backing ? AnyShapeStyle(.background) : AnyShapeStyle(.primary) }
        let shade = environment.colorScheme == .dark && shadeInDarkAppearance &&
            (shadeWhenContrastIncreased || environment.colorSchemeContrast != .increased) ? 0.22 : 0
        return AnyShapeStyle(LinearGradient(stops: LightPalette.laneInkStops(stops, shade: shade, backing: backing),
                                            startPoint: .leading, endPoint: .trailing))
    }
}

/// 系统底色面板的竖天色带，描边取每一高度实际画的天色。
struct SkyRowForegroundStyle: ShapeStyle {
    let row: SkyPanel.Row

    func resolve(in environment: EnvironmentValues) -> AnyShapeStyle {
        guard row.gradient && environment.colorSchemeContrast != .increased else {
            return AnyShapeStyle(SkyTextRole.laneGlyph.foreground(on: LightPalette.luminance(row.colors.mid)))
        }
        let stops = [SkyStripState.Stop(at: 0, color: row.colors.top),
                     SkyStripState.Stop(at: 1, color: row.colors.horizon)]
        return AnyShapeStyle(LinearGradient(stops: LightPalette.laneInkStops(stops, shade: 0),
                                            startPoint: .top, endPoint: .bottom))
    }
}

/// 面板框上的次要文字跟着框的天色；工具窗与系统底色保留系统的可读次要色。
struct PanelSecondaryStyle: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> AnyShapeStyle {
        if environment.panelFollowsSky, let colors = environment.panelSky?.chrome {
            AnyShapeStyle(SkyTextRole.panelChromeSecondary.foreground(in: colors))
        } else {
            AnyShapeStyle(.readableSecondary)
        }
    }
}

/// 可选的日出日落文字按行内实际位置取色，名称与框的字色都不参与决定。
struct SkyRowLocalForeground: ViewModifier {
    let row: SkyPanel.Row
    let rowID: UUID
    let height: CGFloat
    let followsSky: Bool
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var fraction = 0.5

    func body(content: Content) -> some View {
        content
            .foregroundStyle(followsSky
                ? AnyShapeStyle(SkyTextRole.panelSunTimes.foreground(on: LightPalette.rowLuminance(row, at: fraction, flat: contrast == .increased)))
                : AnyShapeStyle(.readableSecondary))
            .onGeometryChange(for: Double.self, of: { geometry in
                guard height > 0 else { return 0.5 }
                return Double(geometry.frame(in: .named(rowID)).midY / height)
            }) { fraction = $0 }
    }
}

extension ShapeStyle where Self == PanelSecondaryStyle {
    static var panelSecondary: PanelSecondaryStyle { PanelSecondaryStyle() }
}

/// 圆点两侧压在窄天色带上，上下仍在窗口底上；同一道描边按脚下的底选字色。
struct SkyGlyphRimStyle: ShapeStyle {
    let luminance: Double?
    let role: SkyTextRole
    let radius: Double
    let halfBand: Double

    func resolve(in environment: EnvironmentValues) -> AnyShapeStyle {
        guard let luminance else { return AnyShapeStyle(.primary) }
        let side = role.foreground(on: luminance)
        let outer: Color
        if environment.panelFollowsSky, let colors = environment.panelSky?.chrome {
            outer = role.foreground(in: colors)
        } else {
            outer = .primary
        }
        let a = (1 - min(1, halfBand / radius)) / 2
        let stops: [Gradient.Stop] = [
            .init(color: outer, location: 0), .init(color: outer, location: a), .init(color: side, location: a),
            .init(color: side, location: 1 - a), .init(color: outer, location: 1 - a), .init(color: outer, location: 1)
        ]
        return AnyShapeStyle(LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom))
    }
}

/// 地名用的衬线字：拉丁字母走系统的衬线（New York），带汉字的走宋体（系统自带的 Songti：`.serif` 设计遇到汉字
/// 会退回黑体，一行里拉丁是衬线、汉字是黑体就不成一套）；日文假名、韩文由系统按字补齐。
nonisolated enum SerifFace {
    /// 这段字里有没有汉字、假名或谚文。
    static func isCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { s in
            switch s.value {
            case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0x20000...0x2FA1F: true
            default: false
            }
        }
    }

    /// 汉字用哪一套宋体：繁体界面用 Songti TC，其余用 Songti SC。
    static func songti(for locale: Locale?) -> String {
        isTraditional(locale) ? "Songti TC" : "Songti SC"
    }

    /// 界面写的是不是繁体字：先看文字系统（zh-Hans / zh-Hant 写明了就按它），没写才按地区（台湾、香港、澳门默认繁体）。
    /// 先看地区会让 zh-Hans_TW 的题记写成繁体、地名使用繁体宋体；应优先遵循文字系统。
    static func isTraditional(_ locale: Locale?) -> Bool {
        guard let locale else { return false }
        if let script = locale.language.script?.identifier { return script == "Hant" }
        return ["TW", "HK", "MO"].contains(locale.region?.identifier ?? "")
    }

    static func font(_ text: String, size: CGFloat, weight: Font.Weight, locale: Locale? = nil) -> Font {
        isCJK(text) ? Font.custom(songti(for: locale), fixedSize: size).weight(weight) : .system(size: size, weight: weight, design: .serif)
    }

    /// 量宽用的 `NSFont`（与 `font` 同一个字面）。
    static func nsFont(_ text: String, size: CGFloat, weight: NSFont.Weight, locale: Locale? = nil) -> NSFont {
        if isCJK(text), let face = NSFont(name: songti(for: locale), size: size) {
            return weight >= .semibold ? NSFontManager.shared.convert(face, toHaveTrait: .boldFontMask) : face
        }
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        return base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? base
    }
}
