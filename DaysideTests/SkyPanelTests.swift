// SPDX-License-Identifier: GPL-3.0-only
//
//  SkyPanelTests.swift
//  面板的天色。每个地点都有一行颜色（没有坐标的是纸色、没有词），框的底色对墨 / 纸 ≥ 8:1，
//  滑块轨道 73 个色标；一天里的词都有英文译文；太阳弧上太阳的点位按原型的几何走；行高按字号算、随「文字大小」长高；
//  新设置「面板底色」默认跟着天色。
//

import AppKit
import Foundation
import Testing
import SwiftUI
@testable import Dayside

struct SkyPanelTests {
    private let zones: [TimeZoneEntry] = [
        .init(timezoneID: "America/Los_Angeles", cityName: "Los Angeles", coordinate: .init(latitude: 34.05, longitude: -118.24), countryCode: "US"),
        .init(timezoneID: "Asia/Tokyo", cityName: "Tokyo", coordinate: .init(latitude: 35.68, longitude: 139.69), countryCode: "JP"),
        .init(timezoneID: "UTC", cityName: "UTC", coordinate: nil, countryCode: nil),
    ]

    @MainActor @Test func everyPlaceGetsAReadableRowAndTheFrameReadsAtEightToOne() throws {
        for k in 0..<24 {
            let instant = Date(timeIntervalSince1970: 1_790_000_000 + Double(k) * 3600)
            let sky = SkyPanel.compute(instant: instant, now: instant, zones: zones, need: 5.5, locale: Locale(identifier: "de"))
            #expect(sky.rows.count == zones.count)
            #expect(sky.chrome.ratio >= 8, "\(instant): 框 \(sky.chrome.ratio)")
            for zone in zones {
                let candidate = sky.rows[zone.id]
                let row = try #require(candidate)
                #expect(row.colors.ratio >= 5.5)
                if zone.coordinate == nil {
                    #expect(row.known == false && row.word == nil)
                } else {
                    // 一天里的词按界面语言自己的表给（这里是德语），不是中文键。
                    let word = row.word ?? ""
                    #expect(!word.isEmpty && !SerifFace.isCJK(word), "「\(word)」不是德语")
                }
            }
            // 本机（测试宿主的系统时区）在随包坐标里：圆点知道这里是昼是夜（轨道的色标在 `SliderTrackMemo`，见 SkyStripTests）。
            if ZoneCatalog.shared.knownCoordinate(for: TimeZone.current.identifier) != nil {
                #expect(sky.dayHere != nil)
            }
        }
        let increased = SkyPanel.compute(instant: Date(timeIntervalSince1970: 1_790_000_000), now: Date(timeIntervalSince1970: 1_790_000_000),
                                         zones: zones, need: 7, locale: Locale(identifier: "zh-Hans"))
        #expect(increased.rows.values.allSatisfy { $0.colors.ratio >= 7 })
    }

    /// 界面语言 → 一天里的词的语言码：简繁按文字系统（zh-Hans locale 配 TW 地区仍是简体）、葡萄牙语用巴西那张表。
    @Test func dayWordsFollowTheInterfaceLanguage() {
        #expect(SkyPanel.languageCode(Locale(identifier: "zh-Hans_TW")) == "zh-Hans")
        #expect(SkyPanel.languageCode(Locale(identifier: "zh-Hant")) == "zh-Hant")
        #expect(SkyPanel.languageCode(Locale(identifier: "pt-PT")) == "pt-BR")
        #expect(SkyPanel.languageCode(Locale(identifier: "de_CH")) == "de")
        #expect(SkyPanel.languageCode(Locale(identifier: "en_GB")) == "en")
    }

    @MainActor @Test func theSunOnTheLittleArcWalksFromRiseToSetAndSinksAtNight() {
        let (rise, _) = SunPathGlyph.sun(.init(up: true, fraction: 0))
        let (noon, noonRadius) = SunPathGlyph.sun(.init(up: true, fraction: 0.5))
        let (set, _) = SunPathGlyph.sun(.init(up: true, fraction: 1))
        #expect(abs(rise.x - 2) < 1e-9 && abs(rise.y - 9.5) < 1e-9)
        #expect(abs(noon.x - 11) < 1e-9 && abs(noon.y - 2) < 1e-9 && noonRadius == 2.6)
        #expect(abs(set.x - 20) < 1e-9 && abs(set.y - 9.5) < 1e-9)
        // 夜里沉在地平线下，从落下的一端（右）往升起的一端（左）挪。
        let (dusk, nightRadius) = SunPathGlyph.sun(.init(up: false, fraction: 0))
        let (dawn, _) = SunPathGlyph.sun(.init(up: false, fraction: 1))
        #expect(dusk.x == 20 && dawn.x == 2 && dusk.y > 9.5 && nightRadius == 2.2)
        // 越界的比例钉在两端。
        #expect(SunPathGlyph.sun(.init(up: true, fraction: 3)).0 == set)
    }

    @MainActor @Test func rowHeightFollowsTheTextSizeAndTheOptionalLines() {
        var settings = AppSettings()
        #expect(settings.panelColors == .sky, "新设置默认跟着天色")
        let standard = SkyRowMetrics(settings: settings, textScale: 1).rowHeight
        let larger = SkyRowMetrics(settings: settings, textScale: 1.3).rowHeight
        settings.panelShowsSunTimes = true
        let withSunTimes = SkyRowMetrics(settings: settings, textScale: 1).rowHeight
        settings.displayMode = .abbreviation
        let codes = SkyRowMetrics(settings: settings, textScale: 1).rowHeight
        #expect(standard >= 70)
        #expect(larger > standard)
        #expect(withSunTimes > standard)
        #expect(codes > withSunTimes)
    }

    /// 滑块那 24 小时：此刻前后 12 小时以内以此刻为中心，圆点按偏移落在轨道上；超过 12 小时以看的那一刻为中心，
    /// 圆点回到正中（与工具窗页首天色带同一个判据）。方向句满一天写天与小时。
    @MainActor @Test func farMomentsRecentreTheSliderAndTheDotStaysWithTheCaption() {
        let zh = Locale(identifier: "zh-Hans")
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(SliderPosition.offsetLabel(seconds: 101 * 60, locale: Locale(identifier: "ru")) == "через 1 час 41 минуту")
        #expect(SliderPosition.offsetLabel(seconds: 123 * 60, locale: Locale(identifier: "pl")) == "za 2 godziny 3 minuty")
        for seconds: TimeInterval in [-43_200, -3600, 0, 5400, 43_200] {
            let instant = now.addingTimeInterval(seconds)
            #expect(!SliderPosition.isBeyond(seconds))
            #expect(SliderPosition.center(now: now, instant: instant) == now, "12 小时以内轨道以此刻为中心")
            #expect(abs(SliderPosition.fraction(of: instant, center: now) - (0.5 + seconds / 86_400)) < 1e-12)
        }
        let far = 17 * 3600.0 + 24 * 60
        for seconds: TimeInterval in [far, -far, 3 * 86_400, -43_201] {
            let instant = now.addingTimeInterval(seconds)
            #expect(SliderPosition.isBeyond(seconds))
            let center = SliderPosition.center(now: now, instant: instant)
            #expect(center == instant, "超过 12 小时以看的那一刻为中心")
            #expect(SliderPosition.fraction(of: instant, center: center) == 0.5, "圆点在正中")
            #expect(SliderPosition.fraction(of: now, center: center) == (seconds > 0 ? 0 : 1), "此刻不在轨道上，钉在那一头")
        }
        #expect(SliderPosition.offsetLabel(seconds: far, locale: zh) == "17小时24分钟后")
        #expect(SliderPosition.offsetLabel(seconds: -far, locale: zh) == "17小时24分钟前")
        #expect(SliderPosition.offsetLabel(seconds: 2 * 86_400 + 3 * 3600, locale: zh) == "2天3小时后")
        #expect(SliderPosition.offsetLabel(seconds: -(2 * 86_400 + 3 * 3600), locale: Locale(identifier: "en")) == "2 days 3 hours ago")
    }

    /// 轨道的色标只在每分钟与换中心时去 Rust 算：同一分钟、同一个中心不重算；换了中心才换色标。
    @MainActor @Test func theSliderTrackComputesOnTheMinuteAndOnANewCentreOnly() {
        let memo = SliderTrackMemo()
        let la = Coordinate(latitude: 34.05, longitude: -118.24)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        memo.update(now: now, center: now, coordinate: la)
        #expect(memo.computations == 1 && memo.stops.count == 73 && memo.gradient?.stops.count == 73)
        memo.update(now: now.addingTimeInterval(20), center: now, coordinate: la)
        #expect(memo.computations == 1, "同一分钟、同一个中心")
        let before = memo.stops
        memo.update(now: now, center: now.addingTimeInterval(20 * 3600), coordinate: la)
        #expect(memo.computations == 2)
        #expect(memo.stops != before, "换了中心，轨道画的是那一刻前后的天")
        memo.update(now: now, center: now.addingTimeInterval(20 * 3600), coordinate: nil)
        #expect(memo.stops.isEmpty && memo.gradient == nil, "没有本机坐标：中性的灰，不猜")
    }

    @MainActor @Test func theWidestRowChoosesOneOffsetStyleForTheWholeLayout() {
        let widths: [CGFloat] = [140, 321, 230]
        #expect(RowOffsetLayout.usesCompact(requiredWidths: widths, availableWidth: 320))
        #expect(RowOffsetLayout.usesCompact(requiredWidths: Array(widths.reversed()), availableWidth: 320))
        #expect(!RowOffsetLayout.usesCompact(requiredWidths: widths, availableWidth: 321))
        #expect(!RowOffsetLayout.usesCompact(requiredWidths: [], availableWidth: 320))
    }

    @MainActor @Test func offsetMeasurementFollowsTheRealClockFontAndTextSize() {
        let (defaults, cleanup) = TestDefaults.make(prefix: "row-offset-layout")
        defer { cleanup() }
        let model = AppModel(defaults: defaults, migrate: false, applySystemIntegration: false)
        model.now = Date(timeIntervalSince1970: 1_790_000_000)
        let widths = zones.map { RowOffsetLayout.requiredWidth(zone: $0, core: model.core, sky: nil, followsSky: false, textScale: 1) }
        let larger = zones.map { RowOffsetLayout.requiredWidth(zone: $0, core: model.core, sky: nil, followsSky: false, textScale: 1.3) }
        let widest = widths.max() ?? 0
        #expect(widest > 0)
        #expect((larger.max() ?? 0) > widest)
        #expect(RowOffsetLayout.usesCompact(requiredWidths: widths, availableWidth: widest - 1))
        #expect(!RowOffsetLayout.usesCompact(requiredWidths: widths, availableWidth: widest))
        let local = TimeZoneEntry(timezoneID: TimeZone.current.identifier, cityName: "Home")
        #expect(RowOffsetLayout.requiredWidth(zone: local, core: model.core, sky: nil, followsSky: false, textScale: 1) == 0)
    }

    @MainActor @Test(arguments: ["fr", "pt-BR"])
    func wideLanguageUsesCompactAtTheActualListRowWidth(language: String) {
        let locale = Locale(identifier: language)
        let metrics = SkyRowMetrics(settings: AppSettings(), textScale: 1)
        let font = AppFont.detailFont(size: metrics.detailSize, design: .system, heavier: false)
        let full = String(format: L10n.string("快 %@", locale: locale),
                          ClockText.duration(seconds: 16 * 3600, locale: locale))
        let clockFont = ClockFace.nativeFont(size: metrics.timeSize, design: .system, weight: .regular, light: true)
        let word = language == "fr" ? "Matin" : "Manhã"
        let rowWidth: CGFloat = 304
        let detail = RowOffsetLayout.detailWidth(offset: full, word: word, resting: false, path: true, locale: locale, font: font)
        let required = detail + RowOffsetLayout.width("22:10", font: clockFont) + 32 + 28
        #expect(required > rowWidth)
        #expect(RowOffsetLayout.usesCompact(requiredWidths: [required - 20, required], availableWidth: rowWidth))
        let host = NSHostingView(rootView: Text(verbatim: full).font(Font(font)).fixedSize())
        #expect(abs(host.fittingSize.width - RowOffsetLayout.width(full, font: font)) <= 1)
    }

    @MainActor @Test func theIndonesianSkyWordGivesWayBeforeTheCompactOffset() {
        let font = AppFont.detailFont(size: SkyRowMetrics(settings: AppSettings(), textScale: 1.3).detailSize,
                                      design: .system, heavier: false)
        let locale = Locale(identifier: "id")
        let offset: String = PresentationCore.call("scroll_label", ["seconds": 16 * 3600])
        let available: CGFloat = 150
        let whole = RowOffsetLayout.detailWidth(offset: offset, word: "Matahari terbit", resting: false,
                                                path: true, locale: locale, font: font)
        #expect(whole > available)
        let layout = RowOffsetLayout.detailLayout(offset: offset, word: "Matahari terbit", resting: false,
            path: true, locale: locale, font: font, availableWidth: available)
        #expect(!layout.showsSkyWord)
        #expect(layout.showsPath)
        #expect(layout.width <= available)
        let host = NSHostingView(rootView: Text(verbatim: offset).font(Font(font)).fixedSize())
        #expect(host.fittingSize.width <= layout.width)
    }

    @MainActor @Test(arguments: InterfaceLanguage.allCases.filter { $0 != .system })
    func offsetsFitTheDefaultPanelInEveryTextSize(language: InterfaceLanguage) throws {
        let (defaults, cleanup) = TestDefaults.make(prefix: "row-offset-matrix")
        defer { cleanup() }
        let model = AppModel(defaults: defaults, migrate: false, applySystemIntegration: false)
        model.settings.interfaceLanguage = language
        model.settings.hourStyle = .force24
        model.now = Date(timeIntervalSince1970: 1_791_018_600)
        let places = zones + [.init(timezoneID: "Europe/London", cityName: "London", coordinate: .init(latitude: 51.51, longitude: -0.13), countryCode: "GB")]
        for size in TextSize.allCases {
            let sky = SkyPanel.compute(instant: model.now, now: model.now, zones: places, need: 5.5, locale: model.uiLocale)
            let compact = RowOffsetLayout.usesCompact(requiredWidths: places.map {
                RowOffsetLayout.requiredWidth(zone: $0, core: model.core, sky: sky.rows[$0.id], followsSky: true, textScale: size.scale)
            }, availableWidth: 304)
            for zone in places {
                guard let relative = PanelRowDetail.relative(zone: zone, at: model.now, locale: model.uiLocale) else { continue }
                let metrics = SkyRowMetrics(settings: model.settings, textScale: size.scale)
                let font = RowOffsetLayout.detailFont(settings: model.settings, metrics: metrics, sky: sky.rows[zone.id], followsSky: true)
                let available = 304 - RowOffsetLayout.reservedWidth(zone: zone, core: model.core, sky: sky.rows[zone.id], followsSky: true, metrics: metrics)
                let offset = compact ? relative.compact : relative.full
                let layout = RowOffsetLayout.detailLayout(offset: offset,
                    word: sky.rows[zone.id]?.word, resting: false, path: sky.rows[zone.id]?.path != nil,
                    locale: model.uiLocale, font: font, availableWidth: available)
                #expect(layout.width <= available, "\(language.rawValue), \(size.rawValue), \(zone.timezoneID)")
                let renderedWidth = { (text: String) in
                    NSHostingView(rootView: Text(verbatim: text).font(Font(font)).fixedSize()).fittingSize.width
                }
                var pieces = [CGFloat]()
                if layout.showsPath { pieces.append(22) }
                if layout.showsSkyWord, let word = sky.rows[zone.id]?.word {
                    pieces.append(renderedWidth(word))
                    pieces.append(renderedWidth("·"))
                }
                pieces.append(renderedWidth(offset))
                let rendered = pieces.reduce(0, +) + CGFloat(pieces.count - 1) * 6
                #expect(rendered <= available, "Text 实量：\(language.rawValue), \(size.rawValue), \(zone.timezoneID)")
            }
        }
    }

}

/// 面板外围（2026-10-02）：找碰头时间那一行与那一页同一套参与者规则，说的是最早一段所有人都合适的时段。
struct PanelPeripheryTests {
    private func window(_ tier: OverlapPlanner.Window.Tier, start: Double, hours: Double, score: Double) -> OverlapPlanner.Window {
        OverlapPlanner.Window(tier: tier, start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: start + hours * 3600),
                              best: Date(timeIntervalSince1970: start), durationMinutes: 60, score: score, fits: [])
    }

    /// 结果按舒适度排；那一行要的是「最早」的那一段，折中的不算。
    @Test func theLineNamesTheEarliestSlotEveryoneCanMake() {
        let result = OverlapPlanner.Result(windows: [
            window(.everyone, start: 1_790_100_000, hours: 2, score: 9),
            window(.everyone, start: 1_790_010_000, hours: 1, score: 3),
            window(.compromise, start: 1_790_000_000, hours: 1, score: 10),
        ])
        #expect(PanelMeetingSummary.conclusion(result)
                == .slot(start: Date(timeIntervalSince1970: 1_790_010_000), end: Date(timeIntervalSince1970: 1_790_013_600)))
        #expect(PanelMeetingSummary.conclusion(OverlapPlanner.Result(windows: [window(.compromise, start: 1_790_000_000, hours: 1, score: 1)]))
                == .noSlot)
    }

    /// 洛杉矶与伦敦（东京不参加、本机不参加），2026-09-21 周一上午 7:13：今天洛杉矶 9:00–10:00 = 伦敦 17:00–18:00，
    /// 两边都在 9:00–18:00 里，是最早的那一段。只有一个地点参加时算不了，那一行只写页名。
    @MainActor @Test func theLineUsesThePagesParticipantsAndFindsTodaysOverlap() throws {
        let (defaults, cleanup) = TestDefaults.make(prefix: "panel-meeting-line")
        defer { cleanup() }
        let la = TimeZone(identifier: "America/Los_Angeles")!
        let zones: [TimeZoneEntry] = [
            .init(timezoneID: "America/Los_Angeles", cityName: "Los Angeles", coordinate: .init(latitude: 34.05, longitude: -118.24), countryCode: "US"),
            .init(timezoneID: "Europe/London", cityName: "London", coordinate: .init(latitude: 51.51, longitude: -0.13), countryCode: "GB"),
            .init(timezoneID: "Asia/Tokyo", cityName: "Tokyo", coordinate: .init(latitude: 35.68, longitude: 139.69), countryCode: "JP"),
        ]
        Store.saveZones(zones, to: defaults)
        var settings = Store.loadSettings(from: defaults)
        settings.planner.includeLocal = false
        settings.planner.excludedZoneIDs = [zones[2].id]
        Store.saveSettings(settings, to: defaults)
        let model = AppModel(defaults: defaults, migrate: false, applySystemIntegration: false)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = la
        let inputs = PanelMeetingSummary.inputs(core: model.core, day: calendar.startOfDay(for: now), now: now, local: la)
        #expect(inputs.fromToday && inputs.days == 7)
        let request = try #require(inputs.request)
        #expect(Set(request.participants.map(\.timeZoneID)) == ["America/Los_Angeles", "Europe/London"])
        #expect(PanelMeetingSummary.conclusion(OverlapPlanner.plan(request))
                == .slot(start: Date(timeIntervalSince1970: 1_790_006_400), end: Date(timeIntervalSince1970: 1_790_010_000)))
        model.setParticipates(id: zones[1].id, false)
        #expect(PanelMeetingSummary.inputs(core: model.core, day: calendar.startOfDay(for: now), now: now, local: la).request == nil)
    }
}

@MainActor
struct RowDetailWrappingTests {
    private static func halfHourZone(now: Date) -> TimeZone? {
        let home = TimeZone.current
        for id in ["Asia/Kolkata", "Asia/Yangon", "Australia/Adelaide", "America/St_Johns",
                   "Asia/Kathmandu", "Pacific/Chatham", "Asia/Tokyo", "Europe/Berlin", "America/New_York"] {
            guard let zone = TimeZone(identifier: id), id != home.identifier else { continue }
            let difference = zone.secondsFromGMT(for: now) - home.secondsFromGMT(for: now)
            if difference != 0, abs(difference % 3600) == 1800 { return zone }
        }
        return nil
    }

    private static func singleLineSize(_ text: String, font: NSFont, scale: Double) -> CGSize {
        NSHostingView(rootView: Text(verbatim: text).font(Font(font)).fixedSize()
            .environment(\.textScale, scale)).fittingSize
    }

    private static func wrappedSize(_ text: String, font: NSFont, scale: Double, width: CGFloat) -> CGSize {
        NSHostingView(rootView: Text(verbatim: text).font(Font(font)).lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true).frame(width: width)
            .environment(\.textScale, scale)).fittingSize
    }

    private static func detailSize(zone: TimeZoneEntry, model: AppModel, metrics: SkyRowMetrics,
                                   style: RowPrimaryTextStyle, locale: Locale, scale: Double,
                                   width: CGFloat, compact: Bool) -> CGSize {
        NSHostingView(rootView: ClockDrivenRowDetail(zone: zone, sky: nil, metrics: metrics, style: style,
                                                     compactOffsets: compact, availableWidth: width)
            .frame(width: width)
            .environment(model).environment(model.core)
            .environment(\.locale, locale).environment(\.textScale, scale)).fittingSize
    }

    @Test(arguments: ["de", "ru", "fr", "pt-BR"])
    func narrowRowsWrapTheCompleteDetailInsteadOfOverflowing(language: String) throws {
        let (defaults, cleanup) = TestDefaults.make(prefix: "row-detail-wrap")
        defer { cleanup() }
        var settings = Store.loadSettings(from: defaults)
        settings.interfaceLanguage = try #require(InterfaceLanguage.allCases.first { $0.localeIdentifier == language })
        Store.saveSettings(settings, to: defaults)
        let model = AppModel(defaults: defaults, migrate: false, applySystemIntegration: false)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        model.now = now
        let zone = TimeZoneEntry(timezoneID: try #require(Self.halfHourZone(now: now)).identifier, cityName: "Half Hour")
        let locale = model.uiLocale
        let relative = try #require(PanelRowDetail.relative(zone: zone, at: now, locale: locale))
        let scale = 1.3
        let metrics = SkyRowMetrics(settings: settings, textScale: scale)
        let style = RowPrimaryTextStyle(settings: settings, metrics: metrics, followsSky: false, skyColors: nil)
        let font = RowOffsetLayout.detailFont(settings: settings, metrics: metrics, sky: nil, followsSky: false)

        let full = Self.singleLineSize(relative.full, font: font, scale: scale)
        let longest = relative.full.components(separatedBy: .whitespaces)
            .map { Self.singleLineSize($0, font: font, scale: scale).width }.max() ?? full.width
        let narrow = (longest + full.width) / 2
        #expect(narrow < full.width - 0.5 && narrow > longest + 0.5)

        let narrowView = Self.detailSize(zone: zone, model: model, metrics: metrics, style: style, locale: locale,
                                    scale: scale, width: narrow, compact: false)
        #expect(narrowView.width <= narrow + 0.5, "\(language)：不得超出所给的宽度")
        #expect(narrowView.height > full.height, "\(language)：窄行要长高（换行铺开）")
        #expect(abs(narrowView.height - Self.wrappedSize(relative.full, font: font, scale: scale, width: narrow).height) <= 0.5,
                "\(language)：换行的高与同一字体的参照 Text 一致")

        let wide = Self.detailSize(zone: zone, model: model, metrics: metrics, style: style, locale: locale,
                              scale: scale, width: full.width + 60, compact: false)
        #expect(abs(wide.height - full.height) <= 0.5, "\(language)：放得下时仍是单行")

        let legacy = NSHostingView(rootView:
            HStack(spacing: 6) {
                Text(verbatim: relative.full)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(2)
                    .accessibilityLabel(Text(verbatim: relative.full))
            }
            .font(Font(font))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: true))
        #expect(legacy.fittingSize.width > narrow, "\(language)：原单行写法在这个宽度放不下")

        let compactWidth = Self.singleLineSize(relative.compact, font: font, scale: scale).width
        let extreme = max(24, compactWidth - 8)
        #expect(extreme < compactWidth)
        let extremeView = Self.detailSize(zone: zone, model: model, metrics: metrics, style: style, locale: locale,
                                     scale: scale, width: extreme, compact: true)
        #expect(extremeView.height > full.height, "\(language)：极窄也走换行兜底")
        #expect(abs(extremeView.height - Self.wrappedSize(relative.full, font: font, scale: scale, width: extreme).height) <= 0.5,
                "\(language)：兜底给的是偏移全写的换行")
    }
}
