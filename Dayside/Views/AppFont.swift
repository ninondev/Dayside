// SPDX-License-Identifier: GPL-3.0-only
//
//  AppFont.swift
//  Dayside
//
//  文字大小三档。macOS 不支持 Dynamic Type——Apple 的 HIG 明写
//  「macOS doesn't support Dynamic Type」，`.dynamicTypeSize` 在 macOS 的 SwiftUI 上实测不缩放
//  ——所以「大 / 更大」只能自己按倍数换字号。
//
//  规矩：标准档（倍数 1）一律走系统的语义字号，渲染逐像素与从前相同；
//  只有用户主动调大时才出现显式 point size，字号取系统该文本样式的当前字号再乘倍数。
//  菜单栏标签不在此列：那是系统托管的，字号由 `NSFont.menuBarFont` 定。
//

import AppKit
import SwiftUI

extension EnvironmentValues {
    /// 文字倍数（1 / 1.15 / 1.3）。根视图注入，页面里的 `.appFont(...)` 读它。
    @Entry var textScale: Double = 1.0
}

enum AppFont {
    /// 系统当前这个文本样式的字号（随用户的系统设置走，不写死 13 pt）。
    static func size(_ style: Font.TextStyle) -> CGFloat {
        NSFont.preferredFont(forTextStyle: appKitStyle(style)).pointSize
    }

    private static func appKitStyle(_ style: Font.TextStyle) -> NSFont.TextStyle {
        switch style {
        case .largeTitle: return .largeTitle
        case .title: return .title1
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .subheadline: return .subheadline
        case .body: return .body
        case .callout: return .callout
        case .footnote: return .footnote
        case .caption: return .caption1
        case .caption2: return .caption2
        @unknown default: return .body
        }
    }

    /// 深底浅字显得细，第二行加粗半级：当前档与更重一档的中点（AppKit 字重刻度）。
    static func halfStepHeavier(_ weight: WeightOption) -> CGFloat {
        switch weight {
        case .regular:  return 0.115  // (0.00 + 0.23) / 2
        case .medium:   return 0.265  // (0.23 + 0.30) / 2
        case .semibold: return 0.35   // (0.30 + 0.40) / 2
        case .bold:     return 0.48   // (0.40 + 0.56) / 2
        }
    }

    /// 深底浅字行第二行的字体：字号照旧，比常规重半级；选了非默认设计就套上，套不上退回纯系统字。
    static func halfStepHeavierFont(size: CGFloat, design: FontDesignOption) -> Font {
        Font(detailFont(size: size, design: design, heavier: true))
    }

    /// 第二行的显示与量宽共用同一字体，包括等宽数字与深底字重。
    static func detailFont(size: CGFloat, design: FontDesignOption, heavier: Bool) -> NSFont {
        let weight: NSFont.Weight = heavier ? .init(rawValue: halfStepHeavier(.regular)) : .regular
        let base = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        return designed(base, design: heavier ? design : .system)
    }

    static func designed(_ font: NSFont, design: FontDesignOption) -> NSFont {
        guard let nsDesign = design.nsDesign,
              let descriptor = font.fontDescriptor.withDesign(nsDesign) else { return font }
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }
}

/// SwiftUI 的设计档 → AppKit 的（`.system` = 不碰设计）。
private extension FontDesignOption {
    var nsDesign: NSFontDescriptor.SystemDesign? {
        switch self {
        case .system:     return nil
        case .rounded:    return .rounded
        case .serif:      return .serif
        case .monospaced: return .monospaced
        }
    }
}

private struct AppFontModifier: ViewModifier {
    @Environment(\.textScale) private var scale
    let style: Font.TextStyle
    let weight: Font.Weight?
    let monospacedDigit: Bool

    func body(content: Content) -> some View {
        var font: Font = scale == 1.0 ? .system(style) : .system(size: AppFont.size(style) * scale, weight: style == .headline ? .bold : .regular)
        if let weight { font = font.weight(weight) }
        if monospacedDigit { font = font.monospacedDigit() }
        return content.font(font)
    }
}

extension View {
    /// 语义字号 + 用户选的倍数。等价于 `.font(.caption)`，但认「文字大小」设置。
    func appFont(_ style: Font.TextStyle, weight: Font.Weight? = nil,
                 monospacedDigit: Bool = false) -> some View {
        modifier(AppFontModifier(style: style, weight: weight, monospacedDigit: monospacedDigit))
    }
}

/// 钟点字：面板行钟点的那一种（系统字、等宽数字；外观页选了圆角 / 衬线 / 等宽或别的字重就照选的来），
/// 工具窗各页的主数字也用它，面板与页面说同一种数字。大号与面板行钟点同一字号，默认细；
/// 中号是次一级的数（黄金时刻、月相名），默认常规：细体在小字号上难读。都乘「文字大小」的倍数。
enum ClockFace {
    static func largeSize(scale: Double) -> CGFloat { (AppFont.size(.largeTitle) * 1.08 * CGFloat(scale)).rounded() }
    static func mediumSize(scale: Double) -> CGFloat { (AppFont.size(.title2) * CGFloat(scale)).rounded() }

    static func font(size: CGFloat, design: FontDesignOption, weight: WeightOption, light: Bool) -> Font {
        Font(nativeFont(size: size, design: design, weight: weight, light: light))
    }

    static func nativeFont(size: CGFloat, design: FontDesignOption, weight: WeightOption, light: Bool) -> NSFont {
        let w: NSFont.Weight = switch weight {
        case .regular: light ? .light : .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        }
        return AppFont.designed(NSFont.monospacedDigitSystemFont(ofSize: size, weight: w), design: design)
    }

    static func large(_ settings: AppSettings, scale: Double) -> Font {
        font(size: largeSize(scale: scale), design: settings.fontDesign, weight: settings.weight, light: true)
    }

    static func medium(_ settings: AppSettings, scale: Double) -> Font {
        font(size: mediumSize(scale: scale), design: settings.fontDesign, weight: settings.weight, light: false)
    }
}
