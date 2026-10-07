// SPDX-License-Identifier: GPL-3.0-only
//
//  MenuBarLabelFormatter.swift
//  TahoeTime
//
//  菜单栏字符串的纯格式化出口。优先保留完整标签;空间预算超限时先移除城市 / 缩写,
//  尽量保留每个时区的完整时间,最后才按 Character 边界截断。
//

import AppKit
import CoreText

enum MenuBarLabelFormatter {
    /// 300pt 在空菜单栏可见,在刘海屏 + 多状态项环境仍容易整项被系统隐藏。
    /// 180pt 足以容纳两个带秒时间,同时给系统状态项留出更稳定的余量。
    static let maximumWidth: CGFloat = CoreConstants.value["maximumLabelWidth"].decode(Double.self)
    static let itemSeparator: String = CoreConstants.value["itemSeparator"].decode()

    struct Item: Codable, Equatable, Sendable {
        let name: String
        let time: String
    }

    /// 先按用户的排列设置生成完整标签,宽度不足时再交给 `fit`。
    /// 名称降级后仍按原顺序保留各时区的完整时间。
    static func compose(
        items: [Item],
        separator: String,
        nameFirst: Bool,
        maxWidth: CGFloat = maximumWidth,
        font: NSFont = NSFont.menuBarFont(ofSize: 0),
        measuring customMeasure: ((String) -> CGFloat)? = nil
    ) -> String {
        struct Input: Encodable { let items: [Item]; let separator: String; let nameFirst: Bool }
        let full: String = RustCore.invoke("label.compose", Input(items: items, separator: separator, nameFirst: nameFirst))
        return fit(full: full, compactTimes: items.map(\.time), maxWidth: maxWidth, font: font, measuring: customMeasure)
    }

    private final class MeasureContext {
        let measure: (String) -> CGFloat
        init(_ measure: @escaping (String) -> CGFloat) { self.measure = measure }
    }
    static func fit(full: String, compactTimes: [String], maxWidth: CGFloat = maximumWidth,
                    font: NSFont = NSFont.menuBarFont(ofSize: 0), measuring customMeasure: ((String) -> CGFloat)? = nil) -> String {
        struct Input: Encodable { let full: String; let compactTimes: [String] }
        struct Output: Decodable { let value: String }
        let context = MeasureContext(customMeasure ?? { width($0, font: font) })
        do {
            let data = try JSONEncoder().encode(Input(full: full, compactTimes: compactTimes))
            let result = withExtendedLifetime(context) {
                data.withUnsafeBytes { bytes in
                    mt_label_fit(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, maxWidth,
                                 Unmanaged.passUnretained(context).toOpaque()) { opaque, pointer, count in
                        guard let opaque, let pointer else { return .infinity }
                        let box = Unmanaged<MeasureContext>.fromOpaque(opaque).takeUnretainedValue()
                        return box.measure(String(decoding: UnsafeBufferPointer(start: pointer, count: count), as: UTF8.self))
                    }
                }
            }
            defer { mt_core_free(result) }
            guard let pointer = result.data else { preconditionFailure("Missing label result") }
            return try JSONDecoder().decode(Output.self, from: Data(bytes: pointer, count: result.len)).value
        } catch { preconditionFailure("Label transport failed: \(error)") }
    }

    static func width(_ string: String, font: NSFont = NSFont.menuBarFont(ofSize: 0)) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font
        ]
        return (string as NSString).size(withAttributes: attributes).width
    }

    /// 与 SwiftUI `.monospacedDigit` 相同的 tabular-number 字体特性。
    /// 显示秒时必须用它测宽;数字 `1` 在普通字体中很窄,换成等宽后会让
    /// 临界标签明显变宽。
    static func withMonospacedDigits(_ font: NSFont) -> NSFont {
        let features: [[NSFontDescriptor.FeatureKey: Int]] = [[
            .typeIdentifier: kNumberSpacingType,
            .selectorIdentifier: kMonospacedNumbersSelector
        ]]
        let descriptor = font.fontDescriptor.addingAttributes([.featureSettings: features])
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }
}
