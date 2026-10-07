// SPDX-License-Identifier: GPL-3.0-only
//
//  MenuBarLabelBudgetTests.swift
//  TahoeTimeTests
//
//  菜单栏标签宽度降级的回归测试。
//  两层:①用「字符数当宽度」的确定性度量钉住降级顺序与截断边界;②用真实 NSFont 在 180pt 预算下
//  跑 系统/圆角/衬线/等宽 × 四档字重 × tabular-number,断言两个完整时间都保留且不超 180.5pt。
//

import AppKit
import XCTest
@testable import TahoeTime

final class MenuBarLabelBudgetTests: XCTestCase {

    private typealias Item = MenuBarLabelFormatter.Item
    private let sep = MenuBarLabelFormatter.itemSeparator
    /// 确定性度量:1 个 Character = 1pt。
    private let byCharacter: (String) -> CGFloat = { CGFloat($0.count) }

    // MARK: - ① 确定性降级顺序

    func testFullLabelKeptWhenItFits() {
        let items = [Item(name: "HK", time: "20:00"), Item(name: "Madrid", time: "14:00")]
        let result = MenuBarLabelFormatter.compose(items: items, separator: " ", nameFirst: true,
                                                   maxWidth: 100, measuring: byCharacter)
        XCTAssertEqual(result, "HK 20:00" + sep + "Madrid 14:00")
    }

    func testTimeFirstOrdering() {
        let items = [Item(name: "HK", time: "20:00"), Item(name: "Madrid", time: "14:00")]
        let result = MenuBarLabelFormatter.compose(items: items, separator: " ", nameFirst: false,
                                                   maxWidth: 100, measuring: byCharacter)
        XCTAssertEqual(result, "20:00 HK" + sep + "14:00 Madrid")
    }

    func testEmptyNamesShowOnlyTimes() {
        let items = [Item(name: "", time: "20:00"), Item(name: "", time: "14:00")]
        let result = MenuBarLabelFormatter.compose(items: items, separator: " ", nameFirst: true,
                                                   maxWidth: 100, measuring: byCharacter)
        XCTAssertEqual(result, "20:00" + sep + "14:00", "空名称不该留下孤零零的分隔符")
    }

    /// 超预算的第一步:去名称,保留每个时区的完整时间。
    func testOverBudgetDropsNamesBeforeAnything() {
        let items = [Item(name: "Hong Kong", time: "20:00"), Item(name: "Madrid", time: "14:00")]
        let full = "Hong Kong 20:00" + sep + "Madrid 14:00"                 // 29 字符
        let result = MenuBarLabelFormatter.compose(items: items, separator: " ", nameFirst: true,
                                                   maxWidth: CGFloat(full.count - 1), measuring: byCharacter)
        XCTAssertEqual(result, "20:00" + sep + "14:00")
    }

    /// 第二步:时间也放不下时,从尾部逐个去掉时区,保留尽可能多的完整时间并加省略号。
    func testKeepsAsManyFullTimesAsFit() {
        let times = ["01:00", "02:00", "03:00", "04:00", "05:00", "06:00"]
        let items = times.map { Item(name: "", time: $0) }
        // 3 个时间 + 省略号 = 5*3 + 3*2 + 1 = 22 字符;4 个 = 5*4 + 3*3 + 1 = 30。
        let result = MenuBarLabelFormatter.compose(items: items, separator: " ", nameFirst: true,
                                                   maxWidth: 25, measuring: byCharacter)
        XCTAssertEqual(result, "01:00" + sep + "02:00" + sep + "03:00…")
    }

    /// 六个时区、预算只够一个:退到第一个完整时间。
    func testSixZonesTightBudgetKeepsFirstTime() {
        let items = (1...6).map { Item(name: "Z\($0)", time: "0\($0):00") }
        let result = MenuBarLabelFormatter.compose(items: items, separator: " ", nameFirst: true,
                                                   maxWidth: 8, measuring: byCharacter)
        XCTAssertEqual(result, "01:00…")
    }

    /// 最后一步:连一个时间都放不下,按 Character 边界截断。
    func testTruncatesSingleTimeAtCharacterBoundary() {
        let result = MenuBarLabelFormatter.fit(full: "20:00", compactTimes: ["20:00"],
                                               maxWidth: 3, measuring: byCharacter)
        XCTAssertEqual(result, "20…")
    }

    func testTruncationNeverSplitsEmojiCharacter() {
        // 旗帜 emoji 是一个 Character(两个 regional indicator 标量);截断不得把它劈成半个。
        let flagged = "🇭🇰 20:00"
        let result = MenuBarLabelFormatter.fit(full: flagged, compactTimes: [flagged],
                                               maxWidth: 2, measuring: byCharacter)
        XCTAssertEqual(result, "🇭🇰…")
        XCTAssertEqual(result.count, 2)
    }

    func testZeroBudgetYieldsEmptyString() {
        let result = MenuBarLabelFormatter.fit(full: "20:00", compactTimes: ["20:00"],
                                               maxWidth: 0, measuring: byCharacter)
        XCTAssertEqual(result, "")
    }

    func testFitReturnsFullWhenWithinBudget() {
        let result = MenuBarLabelFormatter.fit(full: "abc", compactTimes: ["a"], maxWidth: 3, measuring: byCharacter)
        XCTAssertEqual(result, "abc")
    }

    // MARK: - ② 真实字体、180pt 预算

    private struct FontCase: CustomStringConvertible {
        let design: NSFontDescriptor.SystemDesign
        let weight: NSFont.Weight
        let label: String
        var description: String { label }
    }

    private var fontCases: [FontCase] {
        let designs: [(NSFontDescriptor.SystemDesign, String)] = [
            (.default, "system"), (.rounded, "rounded"), (.serif, "serif"), (.monospaced, "monospaced"),
        ]
        let weights: [(NSFont.Weight, String)] = [
            (.regular, "regular"), (.medium, "medium"), (.semibold, "semibold"), (.bold, "bold"),
        ]
        return designs.flatMap { design in
            weights.map { weight in FontCase(design: design.0, weight: weight.0, label: "\(design.1)/\(weight.1)") }
        }
    }

    private func font(for c: FontCase, tabular: Bool) -> NSFont {
        let size = NSFont.menuBarFont(ofSize: 0).pointSize
        let base = NSFont.systemFont(ofSize: size, weight: c.weight)
        let descriptor = base.fontDescriptor.withDesign(c.design) ?? base.fontDescriptor
        let styled = NSFont(descriptor: descriptor, size: size) ?? base
        return tabular ? MenuBarLabelFormatter.withMonospacedDigits(styled) : styled
    }

    /// 两个带秒时间 + 名称,在每种字体设计与字重下都必须收进 180pt,且两个完整时间都在。
    func testTwoZonesWithSecondsFitInBudgetAcrossFonts() {
        let items = [Item(name: "Hong Kong", time: "20:00:00"), Item(name: "Madrid", time: "14:00:00")]
        for c in fontCases {
            let f = font(for: c, tabular: true)
            let result = MenuBarLabelFormatter.compose(items: items, separator: " ", nameFirst: true, font: f)
            let width = MenuBarLabelFormatter.width(result, font: f)
            XCTAssertLessThanOrEqual(width, MenuBarLabelFormatter.maximumWidth + 0.5, "\(c): \(result) = \(width)pt")
            XCTAssertTrue(result.contains("20:00:00"), "\(c): 第一个时间丢了 → \(result)")
            XCTAssertTrue(result.contains("14:00:00"), "\(c): 第二个时间丢了 → \(result)")
        }
    }

    /// 不显示秒、短名称:系统/圆角/衬线设计下完整标签本身就在预算内(不降级);
    /// 等宽设计字形更宽,`HK 20:00   Madrid 14:00` 本就超 180pt,按设计降级为两个完整时间。
    func testShortNamesWithoutSecondsKeepFullLabelAcrossFonts() {
        let items = [Item(name: "HK", time: "20:00"), Item(name: "Madrid", time: "14:00")]
        let expectedFull = "HK 20:00" + sep + "Madrid 14:00"
        let expectedCompact = "20:00" + sep + "14:00"
        for c in fontCases {
            let f = font(for: c, tabular: false)
            let result = MenuBarLabelFormatter.compose(items: items, separator: " ", nameFirst: true, font: f)
            if c.design == .monospaced {
                XCTAssertTrue(result == expectedFull || result == expectedCompact, "\(c): \(result)")
                XCTAssertLessThanOrEqual(MenuBarLabelFormatter.width(result, font: f), MenuBarLabelFormatter.maximumWidth + 0.5, "\(c)")
            } else {
                XCTAssertEqual(result, expectedFull, "\(c)")
            }
        }
    }

    /// tabular-number 只会让数字更宽:同一字符串等宽数字宽度 ≥ 普通数字宽度(显示秒时必须按它测)。
    func testTabularDigitsNeverNarrowerThanProportional() {
        for c in fontCases {
            let plain = font(for: c, tabular: false)
            let tabular = font(for: c, tabular: true)
            let s = "11:11:11" + sep + "10:10:10"
            XCTAssertGreaterThanOrEqual(MenuBarLabelFormatter.width(s, font: tabular) + 0.01,
                                        MenuBarLabelFormatter.width(s, font: plain), "\(c)")
        }
    }

    /// 时间优先排列在同样条件下也必须收进预算并保留两个时间。
    func testTimeFirstAlsoFitsAcrossFonts() {
        let items = [Item(name: "Hong Kong", time: "20:00:00"), Item(name: "Madrid", time: "14:00:00")]
        for c in fontCases {
            let f = font(for: c, tabular: true)
            let result = MenuBarLabelFormatter.compose(items: items, separator: " ", nameFirst: false, font: f)
            XCTAssertLessThanOrEqual(MenuBarLabelFormatter.width(result, font: f), MenuBarLabelFormatter.maximumWidth + 0.5, "\(c)")
            XCTAssertTrue(result.contains("20:00:00") && result.contains("14:00:00"), "\(c): \(result)")
        }
    }

    /// 六个时区显示秒:结果仍 ≤ 180.5pt,且至少保留一个完整时间。
    func testSixZonesWithSecondsStayWithinBudget() {
        let items = (1...6).map { Item(name: "City \($0)", time: "1\($0):00:00") }
        for c in fontCases {
            let f = font(for: c, tabular: true)
            let result = MenuBarLabelFormatter.compose(items: items, separator: " ", nameFirst: true, font: f)
            XCTAssertLessThanOrEqual(MenuBarLabelFormatter.width(result, font: f), MenuBarLabelFormatter.maximumWidth + 0.5, "\(c)")
            XCTAssertTrue(result.contains("11:00:00"), "\(c): 至少第一个完整时间要在 → \(result)")
        }
    }
}
