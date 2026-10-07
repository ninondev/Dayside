// SPDX-License-Identifier: GPL-3.0-only
//
//  Epigraph.swift
//  TahoeTime
//
//  题记「天涯共此时」（张九龄《望月怀远》）与「It is always sunrise somewhere.」
//  （John Muir，《John of the Mountains》，1938）。只用在安静、要打动人的地方：首启欢迎页的主图、拷贝出去的地图海报；
//  与口号「时差不差」（帮助页头图、商店副标题）不在同一个画面。图上不署名，
//  出处写在帮助页「数据来源」。中文界面只写这五个字，竖排一列（竖排旁边再横放一行英文会把画面割开，
//  所以中文界面不带英文原句），而且是毛笔字，不是印刷体：一幅按书法行气排好的草书竖幅，矢量图 `EpigraphZh`（`Tools/make_epigraph.swift`
//  从流江毛草的字形生成，SIL OFL 1.1），颜色由这里给；其余语言写英文原句，横排两行，不译。
//  放法两处一样：底边那一条里夜最宽的一段，墨或纸按底下的明暗实算，外面衬一圈反色（与地图上的地名同一种写法）。
//

import AppKit
import SwiftUI

enum Epigraph {
    static let english = "It is always sunrise somewhere."

    /// 横排的一行：字、SwiftUI 字体、量尺寸用的 `NSFont`、字距。
    struct Line {
        let text: String
        let font: Font
        let measure: NSFont
        let kern: CGFloat
        var size: CGSize {
            let measured = (text as NSString).size(withAttributes: [.font: measure, .kern: kern])
            return CGSize(width: ceil(measured.width), height: ceil(measured.height))
        }
    }

    /// 一段题记怎么排。竖排是一幅书法竖幅（`artwork` 素材名，高 `height`，宽按竖幅的比例）；`lines` 留着整句给读屏。
    struct Setting {
        let lines: [Line]
        let vertical: Bool
        /// 横排两行之间的空。
        let spacing: CGFloat
        /// 竖幅的素材名与高。
        let artwork: String?
        let height: CGFloat

        var text: String { lines.map(\.text).joined(separator: " ") }

        var size: CGSize {
            guard vertical else {
                return CGSize(width: lines.map(\.size.width).max() ?? 0, height: lines.map(\.size.height).reduce(0, +) + spacing)
            }
            let art = artwork.flatMap { NSImage(named: $0)?.size } ?? CGSize(width: 82, height: 470)
            return CGSize(width: ceil(height * art.width / max(art.height, 1)), height: height)
        }
    }

    /// 图宽 1200 点（海报）时的大小，别的宽度按比例缩（欢迎页 512 宽约 0.43 倍）。
    /// 中文：书法竖幅高 310 点（海报高 460，上面留出字标那一行）。
    /// 英文：衬线斜体 30 点断成两行；小图的字重从细体换成常规（13 点的细斜体在夜色上发虚）。
    static func setting(locale: Locale, scale: CGFloat) -> Setting {
        guard locale.language.languageCode?.identifier == "zh" else {
            let compact = scale < 0.6
            let size = (30 * scale).rounded()
            let weight: NSFont.Weight = compact ? .regular : .light
            let base = NSFont.systemFont(ofSize: size, weight: weight)
            let serif = base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor
            let measure = NSFont(descriptor: serif.withSymbolicTraits(.italic), size: size) ?? base
            let lines = ["It is always sunrise", "somewhere."].map {
                Line(text: $0, font: .system(size: size, weight: compact ? .regular : .light, design: .serif).italic(), measure: measure, kern: 0.3 * scale)
            }
            return Setting(lines: lines, vertical: false, spacing: 2 * scale, artwork: nil, height: 0)
        }
        let chinese = SerifFace.isTraditional(locale) ? "天涯共此時" : "天涯共此时"
        let han = Line(text: chinese, font: .body, measure: .systemFont(ofSize: 13), kern: 0)
        return Setting(lines: [han], vertical: true, spacing: 0, artwork: "EpigraphZh", height: (310 * scale).rounded())
    }

    /// 题记离图边的距离：图宽的 4.5%。
    static func margin(width: CGFloat) -> CGFloat { (width * 0.045).rounded() }

    /// 放在哪：底边那一条（题记那么高）里夜最宽的一段，够放下题记、两边还留半个页边距才算。这段贴着图边就靠那一边；
    /// 不贴边时横排从这段的开头起，竖排的一列立在这段夜的正中。没有够宽的夜（两个下角都是白天的时候）就放在更暗的那一角，
    /// 字色另按底下实算。`luminance` 量图上一块地方的相对亮度（海报量自己的位图，屏幕上的图问 Rust），没有就放左下。
    /// 返回题记的框与是否靠右对齐。
    static func placement(block: CGSize, in size: CGSize, margin: CGFloat, vertical: Bool = false,
                          luminance: ((CGRect) -> Double)?) -> (box: CGRect, trailing: Bool) {
        let top = size.height - margin - block.height
        let left = CGRect(x: margin, y: top, width: block.width, height: block.height)
        let right = CGRect(x: size.width - margin - block.width, y: top, width: block.width, height: block.height)
        guard let luminance else { return (left, false) }
        // 每 4 点一列，看这一列在题记那几行里暗不暗（相对亮度 < 0.1：夜里的海与陆，不含晨昏线那道光）。
        let step: CGFloat = 4
        let dark = (0..<Int(size.width / step)).map { i in
            luminance(CGRect(x: CGFloat(i) * step, y: top, width: step, height: block.height)) < 0.1
        }
        var best = (start: 0, length: 0), run = 0
        for (i, isDark) in dark.enumerated() {
            run = isDark ? run + 1 : 0
            if run > best.length { best = (i - run + 1, run) }
        }
        let start = CGFloat(best.start) * step, end = CGFloat(best.start + best.length) * step
        if end - start >= block.width + margin {
            if end >= size.width - step { return (right, true) }
            if start <= step { return (left, false) }
            let x = vertical ? (start + end - block.width) / 2 : start + margin / 2
            return (CGRect(x: min(max(x, margin), size.width - margin - block.width), y: top, width: block.width, height: block.height), false)
        }
        let onRight = luminance(right) < luminance(left)
        return (onRight ? right : left, onRight)
    }
}

/// 题记的字本身（海报与欢迎页共用；衬底由外面给：海报是模糊的光晕，屏幕上是四个方向各挪一点的描边）。
struct EpigraphText: View {
    let setting: Epigraph.Setting
    let trailing: Bool

    var body: some View {
        if setting.vertical, let artwork = setting.artwork {
            let size = setting.size
            Image(artwork)
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .frame(width: size.width, height: size.height)
                .accessibilityLabel(Text(verbatim: setting.text))
        } else {
            VStack(alignment: trailing ? .trailing : .leading, spacing: setting.spacing) {
                ForEach(Array(setting.lines.enumerated()), id: \.offset) { _, line in
                    Text(verbatim: line.text).font(line.font).kerning(line.kern)
                }
            }
        }
    }
}

/// 屏幕上的地图写题记（欢迎页的主图）：位置与墨 / 纸按 `instant` 那一刻算一次（地图每分钟走一点，字不跟着跳）；
/// 读屏读到的是题记本身（衬边那几份不念）。
struct MapEpigraph: View {
    let instant: Date
    let size: CGSize
    let latitudes: ClosedRange<Double>
    let locale: Locale
    var avoidingPoint: CGPoint? = nil

    static func placement(instant: Date, size: CGSize, latitudes: ClosedRange<Double>, locale: Locale,
                          avoidingPoint: CGPoint? = nil) -> (box: CGRect, trailing: Bool) {
        let setting = Epigraph.setting(locale: locale, scale: size.width / 1200)
        let margin = Epigraph.margin(width: size.width)
        let luma = { (rect: CGRect) in MapRaster.luminance(instant: instant, size: size, scale: 2, latitudes: latitudes, in: rect) }
        let original = Epigraph.placement(block: setting.size, in: size, margin: margin, vertical: setting.vertical, luminance: luma)
        guard let point = avoidingPoint, original.box.insetBy(dx: -14, dy: -14).contains(point) else { return original }
        let y = original.box.minY
        let left = CGRect(x: margin, y: y, width: setting.size.width, height: setting.size.height)
        let right = CGRect(x: size.width - margin - setting.size.width, y: y, width: setting.size.width, height: setting.size.height)
        // 在同一片夜里向离圈远的一端挪；没有空位就换到另一个下角。
        let step: CGFloat = 4
        let columns = max(1, Int(size.width / step))
        let origin = min(columns - 1, max(0, Int(original.box.midX / step)))
        let dark = { (column: Int) in luma(CGRect(x: CGFloat(column) * step, y: y, width: step, height: setting.size.height)) < 0.1 }
        let originDark = dark(origin)
        var first = origin, last = origin
        if originDark {
            while first > 0, dark(first - 1) { first -= 1 }
            while last + 1 < columns, dark(last + 1) { last += 1 }
        }
        let candidates = stride(from: margin, through: size.width - margin - setting.size.width, by: step).map {
            CGRect(x: $0, y: y, width: setting.size.width, height: setting.size.height)
        }.filter { originDark && $0.minX >= CGFloat(first) * step && $0.maxX <= CGFloat(last + 1) * step && !$0.insetBy(dx: -14, dy: -14).contains(point) }
        if let box = candidates.max(by: { abs($0.midX - point.x) < abs($1.midX - point.x) }) {
            return (box, box.midX > size.width / 2)
        }
        let corners = [left, right].filter { !$0.insetBy(dx: -14, dy: -14).contains(point) }
        let box = corners.min(by: { luma($0) < luma($1) }) ?? (abs(left.midX - point.x) > abs(right.midX - point.x) ? left : right)
        return (box, box.midX > size.width / 2)
    }

    var body: some View {
        let setting = Epigraph.setting(locale: locale, scale: size.width / 1200)
        let block = setting.size
        let (instant, size, latitudes) = (instant, size, latitudes)
        let luminance = { (rect: CGRect) in MapRaster.luminance(instant: instant, size: size, scale: 2, latitudes: latitudes, in: rect) }
        let (box, trailing) = Self.placement(instant: instant, size: size, latitudes: latitudes, locale: locale, avoidingPoint: avoidingPoint)
        MapText(paper: LightPalette.paperReads(on: luminance(box))) {
            EpigraphText(setting: setting, trailing: trailing)
        }
        .fixedSize()
        .frame(width: block.width, height: block.height, alignment: trailing ? .trailing : .leading)
        // 读屏范围随字列走，衬边副本仍只念一次。
        .accessibilityRepresentation { Text(verbatim: setting.text) }
        .position(x: box.midX, y: box.midY)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}
