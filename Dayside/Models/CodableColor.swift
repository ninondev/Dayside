// SPDX-License-Identifier: GPL-3.0-only
//
//  CodableColor.swift
//  Dayside
//
//  把 SwiftUI Color 做成可持久化:存 sRGB 的 RGBA 分量(确定性、跨显示器稳定)。
//  Color 本身 Sendable 但不 Codable,故有此桥接。
//

import SwiftUI
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

struct CodableColor: Codable, Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var opacity: Double

    init(red: Double, green: Double, blue: Double, opacity: Double) {
        self.red = red; self.green = green; self.blue = blue; self.opacity = opacity
    }

    /// 从 SwiftUI Color 取分量。经 sRGB 归一,避免随显示器工作空间漂移。
    /// @MainActor:NSColor(_:) 桥接是主线程隔离的(只从 Settings 的 ColorPicker 绑定里调)。
    @MainActor init?(_ color: Color) {
        #if canImport(AppKit)
        guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        self.init(red: Double(srgb.redComponent),
                  green: Double(srgb.greenComponent),
                  blue: Double(srgb.blueComponent),
                  opacity: Double(srgb.alphaComponent))
        #else
        // iOS 原型：UIColor 的分量已在 sRGB 扩展空间里，直接取。
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        self.init(red: Double(r), green: Double(g), blue: Double(b), opacity: Double(a))
        #endif
    }

    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
    }

    /// 文字用的最低不透明度。低于此值文字实质不可见,而界面上看不出任何异常。
    static let minimumLegibleOpacity: Double = CoreConstants.value["minimumLegibleOpacity"].decode()

    /// 保证可读的颜色:半透明仍然允许(合理的排版选择),但不允许淡到看不见。
    /// **渲染侧也要钳**——只在 ColorPicker 写入时钳,救不了此前已经存成 alpha 0 的存档
    /// 。
    var legibleColor: Color {
        Color(.sRGB, red: red, green: green, blue: blue,
              opacity: mt_legible_opacity(opacity))
    }
}
