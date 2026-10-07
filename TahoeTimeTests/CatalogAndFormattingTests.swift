// SPDX-License-Identifier: GPL-3.0-only
//
//  CatalogAndFormattingTests.swift
//  TahoeTimeTests
//
//  时区目录、菜单栏宽度防线、自定义色下限与几个纯函数的回归测试。
//

import XCTest
import AppKit
import Testing
@testable import TahoeTime

final class ZoneCatalogTests: XCTestCase {

    /// 目录过去与 `TimeZone.knownTimeZoneIdentifiers` 取交集。本机系统列表只含遗留名
    /// `Asia/Calcutta`,而 tzcoords 只有现代名 `Asia/Kolkata` → 交集把**整个印度**丢出了目录。
    func testModernIdentifiersSurviveEvenWhenSystemOnlyKnowsTheLegacyAlias() {
        let catalog = ZoneCatalog.shared
        XCTAssertFalse(catalog.coordinatesUnavailable, "坐标表必须打进测试 bundle")

        XCTAssertTrue(catalog.zones.contains { $0.identifier == "Asia/Kolkata" },
                      "Asia/Kolkata 必须在目录里(系统可能只认 Asia/Calcutta)")
        XCTAssertFalse(catalog.search("kolkata", locale: nil).isEmpty, "印度必须搜得到")
    }

    /// 目录里每个 identifier 都必须能被 Foundation 解析,否则行会静默回退到 GMT。
    func testEveryCatalogIdentifierResolves() {
        for zone in ZoneCatalog.shared.zones {
            XCTAssertNotNil(TimeZone(identifier: zone.identifier),
                            "不可解析的 identifier: \(zone.identifier)")
        }
    }

    func testCatalogIsNonTrivialAndSorted() {
        let zones = ZoneCatalog.shared.zones
        XCTAssertGreaterThanOrEqual(zones.count, 300, "目录条数异常,坐标表可能没打进包")
        XCTAssertEqual(zones.map(\.identifier), zones.map(\.identifier).sorted())
    }

    func testSearchMatchesCityPrefixAndFullIdentifier() {
        let hits = ZoneCatalog.shared.search("tok", locale: nil)
        XCTAssertTrue(hits.contains { $0.identifier == "Asia/Tokyo" })
        XCTAssertFalse(ZoneCatalog.shared.search("asia/tok", locale: nil).isEmpty,
                       "整标识也应可搜")
        XCTAssertTrue(ZoneCatalog.shared.search("", locale: nil).isEmpty, "空查询不返回结果")
    }

    /// 变音符号不敏感:用户敲带变音符的 "São Paulo",目录里存的是 ASCII 的 "Sao Paulo"。
    /// (注意搜索键里下划线已换成空格,所以查询要用空格而不是 "sao_paulo"。)
    func testSearchIsDiacriticInsensitive() {
        XCTAssertTrue(ZoneCatalog.shared.search("são paulo", locale: nil)
            .contains { $0.identifier == "America/Sao_Paulo" })
        XCTAssertTrue(ZoneCatalog.shared.search("ZURICH", locale: nil)
            .contains { $0.identifier == "Europe/Zurich" }, "大小写也应不敏感")
    }

    /// tzCityComponent 是 ZoneOption 与 LocalizedZoneNames 共用的唯一实现，避免两处规则不一致。
    func testCityComponentHandlesNestedIdentifiers() {
        XCTAssertEqual("Asia/Shanghai".tzCityComponent, "Shanghai")
        XCTAssertEqual("America/Argentina/Buenos_Aires".tzCityComponent, "Buenos Aires")
        XCTAssertEqual("UTC".tzCityComponent, "UTC")
    }

    /// 这些标识不对应任何居民点:GMT / UTC 不是地点,南极点与几个已废弃的太平洋环礁链接
    /// 在系统 zone.tab 和城市库里都没有条目。**宁可留空让昼夜带显示"未知",也不拿别处的
    /// 坐标冒充**(的教义)。
    static let placelessZones: Set<String> = [
        "GMT", "UTC", "Antarctica/South_Pole", "America/Rainy_River",
        "Pacific/Enderbury", "Pacific/Johnston", "Pacific/Ponape", "Pacific/Truk",
    ]

    func testEveryRealPlaceHasCoordinates() {
        var missing: [String] = []
        // 坐标按需解析，目录初始化不扫描城市索引；护栏覆盖惰性解析路径。
        for zone in ZoneCatalog.shared.resolvedZones() {
            guard let c = zone.coordinate else { missing.append(zone.identifier); continue }
            XCTAssertTrue((-90...90).contains(c.latitude), "纬度越界: \(zone.identifier)")
            XCTAssertTrue((-180...180).contains(c.longitude), "经度越界: \(zone.identifier)")
        }
        // 护栏:无坐标的必须仍在已知白名单内。任何**真实城市**掉进来都要当场失败,
        // 否则坐标来源退化时只会悄悄变成"昼夜未知",没人发现。
        let unexpected = Set(missing).subtracting(Self.placelessZones)
        XCTAssertTrue(unexpected.isEmpty, "这些时区不该没有坐标: \(unexpected.sorted())")
    }

    /// 日出日落必须按**城市自己的**经纬度算,而不是时区代表城市。
    func testCityEntriesCarryTheirOwnCoordinates() throws {
        let munich = try XCTUnwrap(ZoneCatalog.shared.search("Munich", locale: nil).first)
        XCTAssertEqual(munich.identifier, "Europe/Berlin", "慕尼黑用柏林的时钟")
        let c = try XCTUnwrap(munich.coordinate)
        XCTAssertEqual(c.latitude, 48.14, accuracy: 0.3, "但坐标必须是慕尼黑自己的")
        XCTAssertEqual(c.longitude, 11.58, accuracy: 0.3)
        let berlin = try XCTUnwrap(ZoneCatalog.shared.option(for: "Europe/Berlin")?.coordinate)
        XCTAssertGreaterThan(abs(c.latitude - berlin.latitude), 2.0, "慕尼黑与柏林的纬度必须明显不同")
    }
}

final class MenuBarLabelFormatterTests: XCTestCase {

    /// 用一个可预测的度量函数(每字符 1pt)把测试和真实字体解耦。
    private let measure: (String) -> CGFloat = { CGFloat($0.count) }

    /// 标签过宽时 macOS 不是截断,而是**整项不绘制**——面板是本 app 唯一入口,
    /// 状态项一消失用户连设置都打不开。所以出口必须无条件收在预算内。
    func testOutputNeverExceedsBudgetEvenWithAbsurdInput() {
        let items = (1...6).map {
            MenuBarLabelFormatter.Item(name: String(repeating: "名", count: 40) + "\($0)",
                                       time: "12:34")
        }
        let result = MenuBarLabelFormatter.compose(
            items: items, separator: " ", nameFirst: true, maxWidth: 40, measuring: measure)
        XCTAssertLessThanOrEqual(measure(result), 40)
    }

    /// 降级顺序:先丢名称保住**每个**时区的完整时间,而不是从头截断只留第一个。
    func testDropsNamesBeforeTruncatingTimes() {
        let items = [
            MenuBarLabelFormatter.Item(name: "San Francisco", time: "09:41"),
            MenuBarLabelFormatter.Item(name: "Tokyo", time: "01:41"),
        ]
        let result = MenuBarLabelFormatter.compose(
            items: items, separator: " ", nameFirst: true, maxWidth: 20, measuring: measure)
        XCTAssertTrue(result.contains("09:41"))
        XCTAssertTrue(result.contains("01:41"), "两个时间都该保住")
        XCTAssertFalse(result.contains("San Francisco"))
    }

    /// 预算充足时必须逐字节等于完整标签——默认配置不能因为防线而偏离原样。
    func testFullLabelIsUntouchedWhenItFits() {
        let items = [MenuBarLabelFormatter.Item(name: "Tokyo", time: "01:41")]
        let result = MenuBarLabelFormatter.compose(
            items: items, separator: " ", nameFirst: true, maxWidth: 1000, measuring: measure)
        XCTAssertEqual(result, "Tokyo 01:41")
    }

    func testElementOrderIsRespected() {
        let items = [MenuBarLabelFormatter.Item(name: "Tokyo", time: "01:41")]
        XCTAssertEqual(MenuBarLabelFormatter.compose(items: items, separator: " · ",
                                                     nameFirst: false, maxWidth: 1000,
                                                     measuring: measure),
                       "01:41 · Tokyo")
    }

    /// 城市语言=无 且无自定义名 → 名称为空,只显示时间,且不该留下孤零零的分隔符。
    func testEmptyNameShowsTimeOnly() {
        let items = [MenuBarLabelFormatter.Item(name: "", time: "01:41")]
        XCTAssertEqual(MenuBarLabelFormatter.compose(items: items, separator: " · ",
                                                     nameFirst: true, maxWidth: 1000,
                                                     measuring: measure),
                       "01:41")
    }

    /// 真实字体下的短名两时区应原样通过(实测 "Tokyo 01:41   Madrid 13:41" ≈ 160pt < 180pt)。
    func testShortTwoZoneLabelFitsRealBudgetUntouched() {
        let items = [
            MenuBarLabelFormatter.Item(name: "Tokyo", time: "01:41"),
            MenuBarLabelFormatter.Item(name: "Madrid", time: "13:41"),
        ]
        let result = MenuBarLabelFormatter.compose(items: items, separator: " ", nameFirst: true)
        XCTAssertTrue(result.contains("Tokyo") && result.contains("Madrid"),
                      "短名两时区不该触发降级,实得: \(result)")
        XCTAssertLessThanOrEqual(MenuBarLabelFormatter.width(result),
                                 MenuBarLabelFormatter.maximumWidth)
    }

    /// 180pt 的预算相当紧:实测 "Hong Kong 19:41   Madrid 13:41" ≈ 191pt,已经越界。
    /// 这时的正确行为是**退到只显示时间**(而不是截断掉第二个时区),这里把它钉死。
    func testSlightlyOverBudgetLabelDegradesToTimesOnly() {
        let items = [
            MenuBarLabelFormatter.Item(name: "Hong Kong", time: "19:41"),
            MenuBarLabelFormatter.Item(name: "Madrid", time: "13:41"),
        ]
        let result = MenuBarLabelFormatter.compose(items: items, separator: " ", nameFirst: true)
        XCTAssertEqual(result, "19:41   13:41", "越界时应保住两个完整时间、丢掉名称")
        XCTAssertLessThanOrEqual(MenuBarLabelFormatter.width(result),
                                 MenuBarLabelFormatter.maximumWidth)
    }

    /// 显示秒时必须按 tabular 数字测宽,否则窄的 "1" 会让临界标签实际越界。
    func testMonospacedDigitFontIsAtLeastAsWide() {
        let base = NSFont.menuBarFont(ofSize: 0)
        let mono = MenuBarLabelFormatter.withMonospacedDigits(base)
        let sample = "11:11:11"
        XCTAssertGreaterThanOrEqual(MenuBarLabelFormatter.width(sample, font: mono),
                                    MenuBarLabelFormatter.width(sample, font: base))
    }
}

final class AppearanceTests: XCTestCase {

    /// ColorPicker 允许 alpha 0,面板主文字会彻底消失且设置里看不出异常。
    /// 渲染侧必须钳——只在写入时钳救不了此前已存成 alpha 0 的存档。
    func testInvisibleCustomColorIsClampedAtRenderTime() {
        let invisible = CodableColor(red: 0, green: 0, blue: 0, opacity: 0)
        XCTAssertEqual(invisible.opacity, 0, "存储值保持用户原样")
        XCTAssertEqual(CodableColor.minimumLegibleOpacity, 0.25, accuracy: 0.001)

        // legibleColor 的不透明度应被抬到下限。
        let clamped = NSColor(invisible.legibleColor).usingColorSpace(.sRGB)
        XCTAssertEqual(Double(clamped?.alphaComponent ?? 0),
                       CodableColor.minimumLegibleOpacity, accuracy: 0.01)
    }

    /// 高于下限的自定义色必须原样通过,不能被这条防线改掉。
    func testLegibleColorLeavesAcceptableOpacityAlone() {
        let fine = CodableColor(red: 0.2, green: 0.4, blue: 0.9, opacity: 0.8)
        let rendered = NSColor(fine.legibleColor).usingColorSpace(.sRGB)
        XCTAssertEqual(Double(rendered?.alphaComponent ?? 0), 0.8, accuracy: 0.01)
    }
}

final class TimeZoneEntryTests: XCTestCase {

    /// macOS 26 的 `abbreviation(for:)` 会泄漏 "GMT+9" 这类死回退,必须落到自算的 UTC±offset。
    func testAbbreviationFallsBackToUTCOffsetWhenSystemLeaksGMTForm() {
        let entry = TimeZoneEntry(timezoneID: "Asia/Kathmandu", cityName: "Kathmandu")
        let abbreviation = entry.abbreviation(at: Date(timeIntervalSince1970: 1_784_116_800))
        XCTAssertFalse(abbreviation.hasPrefix("GMT"), "不该出现 GMT+ 形式,实得 \(abbreviation)")
        XCTAssertEqual(abbreviation, "UTC+5:45")
    }

    func testOffsetStringFormatsHalfHourZones() {
        let entry = TimeZoneEntry(timezoneID: "Asia/Kolkata", cityName: "Kolkata")
        XCTAssertEqual(entry.offsetString(at: Date(timeIntervalSince1970: 1_784_116_800)), "UTC+5:30")
    }

    func testInvalidIdentifierFallsBackToGMTInsteadOfCrashing() {
        let entry = TimeZoneEntry(timezoneID: "Not/AZone", cityName: "Nowhere")
        XCTAssertEqual(entry.timeZone, .gmt)
    }

    func testCustomNameWinsOverLocalizedCity() {
        var entry = TimeZoneEntry(timezoneID: "Asia/Tokyo", cityName: "Tokyo")
        entry.customName = "Mom"
        XCTAssertEqual(entry.displayName(localizedCity: "東京"), "Mom")
        entry.customName = nil
        XCTAssertEqual(entry.displayName(localizedCity: "東京"), "東京")
    }
}

final class ClockTickTests: XCTestCase {

    /// tick 必须对齐到边界,数字才会恰好在整秒/整分翻动；两处调用共用同一实现。
    func testBoundaryAlignment() {
        // 1970-01-01 00:00:30.25 → 距下一整秒 0.75s、距下一整分 29.75s
        let probe = Date(timeIntervalSince1970: 30.25)
        let toSecond = ClockTick.nextBoundary(showSeconds: true, now: probe)
        let toMinute = ClockTick.nextBoundary(showSeconds: false, now: probe)

        XCTAssertEqual(Double(toSecond.components.seconds) +
                       Double(toSecond.components.attoseconds) * 1e-18, 0.75, accuracy: 0.01)
        XCTAssertEqual(Double(toMinute.components.seconds) +
                       Double(toMinute.components.attoseconds) * 1e-18, 29.75, accuracy: 0.01)
    }

    func testBoundaryIsAlwaysPositive() {
        for offset in stride(from: 0.0, to: 120.0, by: 0.37) {
            let probe = Date(timeIntervalSince1970: offset)
            for showSeconds in [true, false] {
                let d = ClockTick.nextBoundary(showSeconds: showSeconds, now: probe)
                XCTAssertGreaterThan(Double(d.components.seconds) +
                                     Double(d.components.attoseconds) * 1e-18, 0,
                                     "tick 间隔必须为正,否则时钟会空转")
            }
        }
    }
}
