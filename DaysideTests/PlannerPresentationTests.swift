// SPDX-License-Identifier: GPL-3.0-only
//
//  PlannerPresentationTests.swift
//  DaysideTests
//
//  排会页的纯函数：周末名、跨午夜的分钟文本、时长文本、深夜找时段不滚到明天。
//

import Foundation
import Testing
@testable import Dayside

@MainActor
struct PlannerPresentationTests {
    @Test(arguments: ["America/Los_Angeles", "Asia/Tokyo", "Pacific/Honolulu"])
    func weekendNamesUseTheParticipantsCalendar(timeZoneID: String) throws {
        let zone = try #require(TimeZone(identifier: timeZoneID))
        let names = AvailabilityEditor.weekendDescription(timeZone: zone, countryCode: "US",
                                                         locale: Locale(identifier: "en_US"))
        #expect(names == "Saturday and Sunday")
    }

    @Test
    func weekendNamesUseTheSelectedInterfaceLanguage() throws {
        let zone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let names = AvailabilityEditor.weekendDescription(timeZone: zone, countryCode: "US",
                                                         locale: Locale(identifier: "fr_FR"))
        #expect(names == "samedi et dimanche")
    }

    @Test
    func endOfDayIsMidnightInsteadOf2359() {
        #expect(PlannerPage.minuteText(1440, style: .force24)
                == PlannerPage.minuteText(0, style: .force24))
    }

    @Test
    func meetingDurationUsesTheInterfaceLanguage() {
        #expect(PlannerPage.durationText(60, locale: Locale(identifier: "en_US")) == "1 hour")
        #expect(PlannerPage.durationText(60, locale: Locale(identifier: "fr_FR")) == "1 heure")
        #expect(PlannerPage.durationText(90, locale: Locale(identifier: "zh-Hans")) == "1小时30分钟")
    }

    @Test
    func lateNightTodaySearchDoesNotRollIntoTomorrow() throws {
        let zone = try #require(TimeZone(identifier: "UTC"))
        let day = Date(timeIntervalSince1970: 1_767_225_600)
        let now = day.addingTimeInterval(23 * 3600 + 46 * 60)
        let from = PlannerPage.planningStart(fromDay: day, now: now, timeZone: zone)
        let participant = OverlapPlanner.Participant(id: UUID(), name: "UTC", timeZoneID: "UTC",
            availability: Availability(startMinute: 0, endMinute: 1440, weekdaysOnly: false), countryCode: nil)
        let result = OverlapPlanner.plan(.init(participants: [participant], from: from, days: 1,
                                              durationMinutes: 30, localTimeZoneID: "UTC"))
        #expect(result.windows.isEmpty)
    }
}

/// 找碰头时间页（2026-10-02 重做）：候选单、谁在付的写法、例会的默认星期。
@MainActor
struct PlannerPageTests {
    private func participant(_ name: String, _ zone: String, _ country: String) -> OverlapPlanner.Participant {
        OverlapPlanner.Participant(id: UUID(), name: name, timeZoneID: zone,
                                   availability: Availability(startMinute: 540, endMinute: 1080, weekdaysOnly: true),
                                   countryCode: country)
    }

    private func utc(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    private func paying(_ option: OverlapPlanner.Option) -> Set<String> {
        Set(option.fits.filter { if case .inside = $0.fit { return false } else { return true } }.map(\.participant.name))
    }

    /// 洛杉矶、伦敦、东京各自 9–18：没有大家都在的时刻；最接近的三项各是另一对人在付（两人各让一点），
    /// 不是同一个钟点排三天；每项都列出同一个钟点也行的那几天。
    @Test func threeContinentsGetThreeWaysToShareTheBurden() {
        let people = [participant("Los Angeles", "America/Los_Angeles", "US"), participant("London", "Europe/London", "GB"),
                      participant("Tokyo", "Asia/Tokyo", "JP")]
        let monday = utc("2026-10-05T07:00:00Z")   // 2026-10-05 0:00 PDT
        let result = OverlapPlanner.options(.init(participants: people, from: monday, days: 3, durationMinutes: 60,
                                                  localTimeZoneID: "America/Los_Angeles"), clockWeight: "gentle")
        #expect(!result.everyone)
        #expect(result.options.count == 3)
        let sets = result.options.map(paying)
        #expect(Set(sets).count == 3, Comment(rawValue: "\(sets)"))
        #expect(sets.allSatisfy { $0.count == 2 }, Comment(rawValue: "\(sets)"))
        for option in result.options {
            #expect(option.tier == .compromise)
            #expect(option.days.first == option.best)
            #expect(option.days.count == 3)
            #expect(option.cost.reduce(0, +) > 0)
        }
    }

    /// 洛杉矶与伦敦：每个工作日洛杉矶 9:00（伦敦 17:00）大家都在，几天并成一项，没有人在付。
    @Test func everyoneFitsAtOneClockAcrossTheWeekdays() throws {
        let people = [participant("Los Angeles", "America/Los_Angeles", "US"), participant("London", "Europe/London", "GB")]
        let friday = utc("2026-10-02T07:00:00Z")   // 2026-10-02 0:00 PDT（周五）
        let result = OverlapPlanner.options(.init(participants: people, from: friday, days: 7, durationMinutes: 60,
                                                  localTimeZoneID: "America/Los_Angeles"), clockWeight: "gentle")
        #expect(result.everyone)
        #expect(result.options.count == 1)
        let option = try #require(result.options.first)
        #expect(option.best == utc("2026-10-02T16:00:00Z"))
        #expect(paying(option).isEmpty)
        // 周五、下周一到周四：周末两天不在里面。
        #expect(option.days.count == 5, Comment(rawValue: "\(option.days)"))
        #expect(option.window(startingAt: option.days[1]).best == option.days[1])
    }

    /// 洛杉矶的周五是东京的周六：带参与者时例会默认挪到周一；东京组织者的周一是洛杉矶的周日，挪到周二。
    @Test func aRotationDoesNotDefaultToADayThatIsTheWeekendSomewhereElse() throws {
        let la = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let people = [participant("Los Angeles", "America/Los_Angeles", "US"), participant("Tokyo", "Asia/Tokyo", "JP")]
        let friday = utc("2026-10-02T19:00:00Z")    // 12:00 PDT 周五
        #expect(OverlapPlanner.defaultRotationWeekday(onOrAfter: friday, in: la, countryCode: "US") == 6)
        #expect(OverlapPlanner.defaultRotationWeekday(onOrAfter: friday, in: la, countryCode: "US", participants: people) == 2)
        let monday = utc("2026-10-05T03:00:00Z")    // 12:00 JST 周一
        #expect(OverlapPlanner.defaultRotationWeekday(onOrAfter: monday, in: tokyo, countryCode: "JP", participants: people) == 3)
        // 同一个时区的两个人：周五照旧（只看周末，不看别人）。
        let neighbours = [participant("Los Angeles", "America/Los_Angeles", "US"), participant("Seattle", "America/Los_Angeles", "US")]
        #expect(OverlapPlanner.defaultRotationWeekday(onOrAfter: friday, in: la, countryCode: "US", participants: neighbours) == 6)
    }

    /// 谁在付的钟点：与本机不是同一天时写「次日」并带那边的星期（换算页同一种说法）。
    @Test func aPayerOnTheNextDayIsWrittenWithTheWeekday() throws {
        let la = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let start = utc("2026-10-05T21:00:00Z")      // 14:00 PDT 周一 = 6:00 JST 周二
        let format = ClockFormat(hourStyle: .force24, showSeconds: false)
        #expect(PlannerText.clock(start, in: tokyo, from: la, format: format, locale: Locale(identifier: "zh-Hans")) == "次日（周二）6:00")
        #expect(PlannerText.clock(start, in: tokyo, from: la, format: format, locale: Locale(identifier: "en")) == "6:00 next day (Tue)")
        #expect(PlannerText.clock(start, in: la, from: la, format: format, locale: Locale(identifier: "en")) == "14:00")
        let early = utc("2026-10-05T08:00:00Z")      // 1:00 PDT 周一 = 夏威夷周日 22:00
        let honolulu = try #require(TimeZone(identifier: "Pacific/Honolulu"))
        #expect(PlannerText.clock(early, in: honolulu, from: la, format: format, locale: Locale(identifier: "zh-Hans")) == "前一日（周日）22:00")
    }

    /// 同一时间也行的其余日子：一周以内写星期，再远只写几天。
    @Test func otherDaysAreWeekdaysWithinAWeekAndACountBeyond() throws {
        let la = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let monday = utc("2026-10-05T16:00:00Z")
        let week = (0..<4).map { monday.addingTimeInterval(Double($0) * 86_400) }
        #expect(PlannerText.otherDays(week, first: monday, in: la, locale: Locale(identifier: "en"), now: monday)
                == "Same time also works: Tue, Wed, and Thu")
        #expect(PlannerText.otherDays([monday], first: monday, in: la, locale: Locale(identifier: "en"), now: monday) == nil)
        let month = (0..<10).map { monday.addingTimeInterval(Double($0) * 86_400) }
        #expect(PlannerText.otherDays(month, first: monday, in: la, locale: Locale(identifier: "en"), now: monday)
                == "Same time also works on 9 more days")
    }
}


import AppKit
import SwiftUI

@MainActor
private enum PlannerAXHarness {
    struct Node {
        let label: String
        let role: String
        let frame: NSRect
        let hasFrame: Bool
    }

    static func enable() {
        guard let app = NSApp else { return }
        if app.responds(to: NSSelectorFromString("setAccessibilityEnhancedUserInterface:")) {
            app.setValue(true, forKey: "accessibilityEnhancedUserInterface")
        }
    }

    private static let legacyKeys = ["accessibilityChildren": "AXChildren", "accessibilityRole": "AXRole",
                                     "accessibilityLabel": "AXDescription", "accessibilityTitle": "AXTitle",
                                     "accessibilityValue": "AXValue"]

    private static func attribute(_ object: NSObject, _ key: String) -> Any? {
        var modern: Any?
        if object.responds(to: Selector(key)) {
            modern = object.value(forKey: key)
            if key != "accessibilityChildren" || !((modern as? [Any])?.isEmpty ?? true) { return modern }
        }
        guard let legacy = legacyKeys[key],
              object.responds(to: NSSelectorFromString("accessibilityAttributeValue:")) else { return modern }
        return object.perform(NSSelectorFromString("accessibilityAttributeValue:"), with: legacy)?.takeUnretainedValue() ?? modern
    }

    private static func frame(of object: NSObject, host: NSView, window: NSWindow) -> (rect: NSRect, known: Bool)? {
        if let value = attribute(object, "accessibilityFrame") as? NSValue {
            return (host.convert(window.convertFromScreen(value.rectValue), from: nil), true)
        }
        guard object.responds(to: NSSelectorFromString("accessibilityAttributeValue:")) else { return nil }
        let legacy = NSSelectorFromString("accessibilityAttributeValue:")
        guard let position = object.perform(legacy, with: "AXPosition")?.takeUnretainedValue() as? NSValue,
              let size = object.perform(legacy, with: "AXSize")?.takeUnretainedValue() as? NSValue else { return nil }
        return (host.convert(window.convertFromScreen(NSRect(origin: position.pointValue, size: size.sizeValue)), from: nil), true)
    }

    private static func collect(from element: Any, host: NSView, window: NSWindow, depth: Int, into nodes: inout [Node]) {
        guard depth < 48, nodes.count < 10_000, let object = element as? NSObject else { return }
        // 菜单的标题在不同系统上可能由 label、title 或 value 暴露。
        let label = ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"]
            .compactMap { attribute(object, $0) as? String }.first { !$0.isEmpty } ?? ""
        let role = attribute(object, "accessibilityRole") as? String ?? ""
        if !label.isEmpty || !role.isEmpty {
            let resolved = frame(of: object, host: host, window: window)
            nodes.append(Node(label: label, role: role, frame: resolved?.rect ?? .zero, hasFrame: resolved != nil))
        }
        for child in (attribute(object, "accessibilityChildren") as? [Any]) ?? [] {
            collect(from: child, host: host, window: window, depth: depth + 1, into: &nodes)
        }
    }

    static func nodes<V: View>(hosting view: V, width: CGFloat) async throws -> (window: NSWindow, nodes: [Node]) {
        enable()
        let host = NSHostingView(rootView: view.frame(width: width))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 900)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: -8000, y: -8000))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        var collected: [Node] = []
        collect(from: host, host: host, window: window, depth: 0, into: &collected)
        if collected.filter(\.hasFrame).isEmpty {
            try? await Task.sleep(for: .milliseconds(300))
            host.layoutSubtreeIfNeeded()
            collected = []
            collect(from: host, host: host, window: window, depth: 0, into: &collected)
        }
        return (window, collected)
    }
}

@MainActor
struct PlannerActionWrappingTests {
    private static let narrowWidth: CGFloat = 473
    private static let wideWidth: CGFloat = 1600

    private static func actions(model: AppModel, locale: Locale, scale: Double, onReturn: (() -> Void)?) -> some View {
        PlannerActionButtons(stale: false, isExporting: false,
                             onReturnToOriginal: onReturn,
                             onAddToCalendar: {}, onCopyTimes: {}, onImage: { _ in }, onJump: {})
            .environment(model).environment(model.core)
            .environment(\.locale, locale).environment(\.textScale, scale)
    }

    private static func labels(_ locale: Locale, hasReturn: Bool) -> [String] {
        var expected = [L10n.string("加入日历", locale: locale), L10n.string("复制各地时间", locale: locale),
                        L10n.string("图片", locale: locale), L10n.string("在面板里看这一刻", locale: locale)]
        if hasReturn { expected.append(L10n.string("回到原来的时刻", locale: locale)) }
        return expected
    }

    private static func height<V: View>(_ view: V, width: CGFloat) -> CGFloat {
        NSHostingView(rootView: view.frame(width: width)).fittingSize.height
    }

    @Test(arguments: ["ru", "de", "fr", "pt-BR"])
    func narrowActionRowsKeepEveryControlInside(language: String) async throws {
        let (defaults, cleanup) = TestDefaults.make(prefix: "planner-actions-wrap")
        defer { cleanup() }
        let model = AppModel(defaults: defaults, migrate: false, applySystemIntegration: false)
        let locale = Locale(identifier: language)
        for scale in [1.0, 1.3] {
            for hasReturn in [false, true] {
                let expected = Self.labels(locale, hasReturn: hasReturn)
                let (window, nodes) = try await PlannerAXHarness.nodes(
                    hosting: Self.actions(model: model, locale: locale, scale: scale, onReturn: hasReturn ? {} : nil),
                    width: Self.narrowWidth)
                defer { window.close() }
                var midYs: [CGFloat] = []
                for label in expected {
                    let matches = nodes.filter { $0.label == label && ["AXButton", "AXMenuButton"].contains($0.role) }
                    #expect(matches.count == 1, "\(language)×\(scale)×回\(hasReturn)：\(label) 应恰好一个，实得 \(matches.count)")
                    guard let node = matches.first, node.hasFrame, !node.frame.isInfinite else { continue }
                    midYs.append(node.frame.midY)
                    #expect(node.frame.minX >= -0.5 && node.frame.maxX <= Self.narrowWidth + 0.5,
                            "\(language)×\(scale)：\(label) 横向越界 \(node.frame)")
                }
                #expect(midYs.count == expected.count, "\(language)×\(scale)：每个动作都要有可用的框")
                if midYs.count == expected.count, let top = midYs.max(), let bottom = midYs.min() {
                    #expect(top - bottom >= 12, "\(language)×\(scale)：窄行要折出第二行")
                    let view = Self.actions(model: model, locale: locale, scale: scale, onReturn: hasReturn ? {} : nil)
                    #expect(Self.height(view, width: Self.narrowWidth) > Self.height(view, width: Self.wideWidth) + 20,
                            "\(language)×\(scale)：折行后宿主高度要长到装得下多出来的行")
                }
            }
        }
    }

    @Test(arguments: ["ru", "de", "fr", "pt-BR"])
    func wideActionRowsKeepTheFinalActionTrailing(language: String) async throws {
        let (defaults, cleanup) = TestDefaults.make(prefix: "planner-actions-wide")
        defer { cleanup() }
        let model = AppModel(defaults: defaults, migrate: false, applySystemIntegration: false)
        let locale = Locale(identifier: language)
        let expected = Self.labels(locale, hasReturn: true)
        let (window, nodes) = try await PlannerAXHarness.nodes(
            hosting: Self.actions(model: model, locale: locale, scale: 1.3, onReturn: {}),
            width: Self.wideWidth)
        defer { window.close() }
        let midYs = expected.compactMap { label -> CGFloat? in
            guard let node = nodes.first(where: { $0.label == label && ["AXButton", "AXMenuButton"].contains($0.role) }), node.hasFrame, !node.frame.isInfinite else { return nil }
            return node.frame.midY
        }
        #expect(midYs.count == expected.count, "\(language)：宽行每个动作都要有可用的框")
        if let top = midYs.max(), let bottom = midYs.min(), midYs.count == expected.count {
            #expect(top - bottom <= 2, "\(language)：宽行仍是一行")
        }
        let jump = L10n.string("在面板里看这一刻", locale: locale)
        if let node = nodes.first(where: { $0.label == jump && ["AXButton", "AXMenuButton"].contains($0.role) }), node.hasFrame, !node.frame.isInfinite {
            #expect(abs(node.frame.maxX - Self.wideWidth) <= 1, "\(language)：最后一样要靠右缘 \(node.frame)")
        }
    }

    @Test func theOldSingleGroupArrangementCouldNotFit() {
        let (defaults, cleanup) = TestDefaults.make(prefix: "planner-actions-legacy")
        defer { cleanup() }
        let model = AppModel(defaults: defaults, migrate: false, applySystemIntegration: false)
        let locale = Locale(identifier: "ru")
        func width<V: View>(_ view: V) -> CGFloat {
            NSHostingView(rootView: view.environment(model).environment(model.core).environment(\.locale, locale).environment(\.textScale, 1.0)).fittingSize.width
        }
        let head = width(HStack(spacing: 10) {
            Button { } label: { Text(verbatim: L10n.string("加入日历", locale: locale)) }.fixedSize()
            Button { } label: { Text(verbatim: L10n.string("复制各地时间", locale: locale)) }.fixedSize()
            PlannerMenuLabel(text: L10n.string("图片", locale: locale), style: nil).padding(.horizontal, 4).fixedSize()
        })
        let jump = width(Button { } label: { Text(verbatim: L10n.string("在面板里看这一刻", locale: locale)) }.fixedSize())
        #expect(head + 8 + jump > Self.narrowWidth, "整组放不进 \(Self.narrowWidth) 点（实需 \(head + 8 + jump)）")
        let individual = [
            width(Button { } label: { Text(verbatim: L10n.string("加入日历", locale: locale)) }.fixedSize()),
            width(Button { } label: { Text(verbatim: L10n.string("复制各地时间", locale: locale)) }.fixedSize()),
            width(PlannerMenuLabel(text: L10n.string("图片", locale: locale), style: nil).padding(.horizontal, 4).fixedSize()),
            jump,
        ]
        #expect(individual.allSatisfy { $0 <= Self.narrowWidth + 0.5 }, "单个动作完整放入行宽")
    }

    @Test func actionLayoutHandlesDegenerateRows() {
        func size<V: View>(_ view: V) -> CGSize { NSHostingView(rootView: view).fittingSize }
        let empty = size(PlannerActionLayout() {})
        #expect(empty.width <= 0.5 && empty.height <= 0.5, "零个孩子是零大小")
        let alone = size(Button { } label: { Text(verbatim: "Один") }.fixedSize())
        let one = size(PlannerActionLayout() { Button { } label: { Text(verbatim: "Один") }.fixedSize() })
        #expect(abs(one.width - alone.width) <= 1 && abs(one.height - alone.height) <= 1, "未指定宽时一个孩子就占它自己的大小")
        let framed = size(PlannerActionLayout() { Button { } label: { Text(verbatim: "Один") }.fixedSize() }.frame(width: 500))
        #expect(abs(framed.width - 500) <= 0.5 && abs(framed.height - alone.height) <= 1, "给了宽也只占一行、高度不虚长")
        let first = Text(verbatim: "AAA AAA AAA").fixedSize()
        let last = Text(verbatim: "BBB BBB").fixedSize()
        let a = size(first), b = size(last)
        let wrapped = size(PlannerActionLayout() { first; last }.frame(width: a.width + 10))
        #expect(wrapped.height >= a.height + 8 + b.height - 1, "折成两行：两行行高相加加行距")
        let single = size(PlannerActionLayout() { first; last }.frame(width: a.width + b.width + 60))
        #expect(abs(single.height - max(a.height, b.height)) <= 1, "放得下时仍是一行")
    }
}

@MainActor
struct PlannerTrailingTextWrappingTests {
    private static let ru = Locale(identifier: "ru")
    private static let start = ISO8601DateFormatter().date(from: "2026-10-08T05:00:00Z")!   // 洛杉矶 22:00、伦敦 6:00
    private static let end = start.addingTimeInterval(3600)
    private static let fixture = "Лос-Анджелес 22:00 · Лондон 6:00 следующего дня (Чт)"
    private static let inner: CGFloat = 439

    private static func participant(_ name: String, _ zone: String) -> OverlapPlanner.Participant {
        OverlapPlanner.Participant(id: UUID(), name: name, timeZoneID: zone,
                                   availability: Availability(startMinute: 540, endMinute: 1080, weekdaysOnly: true),
                                   countryCode: nil)
    }

    private static func payersFits() -> [OverlapPlanner.ParticipantFit] {
        let people = [participant("Лос-Анджелес", "America/Los_Angeles"), participant("Лондон", "Europe/London")]
        let from = start.addingTimeInterval(-86_400 * 2), to = start.addingTimeInterval(86_400 * 2)
        let intervals = people.map { OverlapPlanner.availabilityIntervals(for: $0, coveringFrom: from, to: to) }
        return OverlapPlanner.fits(intervals: intervals, participants: people, start: start, durationMinutes: 60)
    }

    private static func row(trailing: PlannerSlotRow.Trailing, model: AppModel) -> some View {
        PlannerSlotRow(glyph: .closest, start: start, end: end, trailing: trailing,
                       caption: nil, selected: false, choosable: true, action: {})
            .environment(model).environment(model.core)
            .environment(\.locale, ru).environment(\.textScale, 1.3)
    }

    private static func height(trailing: PlannerSlotRow.Trailing, model: AppModel, width: CGFloat) -> CGFloat {
        NSHostingView(rootView: row(trailing: trailing, model: model).frame(width: width)).fittingSize.height
    }

    private static func referenceHeight<V: View>(_ content: V, width: CGFloat) -> CGFloat {
        NSHostingView(rootView: content.fixedSize(horizontal: false, vertical: true).frame(width: width)
            .environment(\.locale, ru).environment(\.textScale, 1.3)).fittingSize.height
    }

    @Test func narrowSlotRowsCarryTheCompleteTrailingText() async throws {
        let (defaults, cleanup) = TestDefaults.make(prefix: "planner-slot-text")
        defer { cleanup() }
        let model = AppModel(defaults: defaults, migrate: false, applySystemIntegration: false)
        model.now = Self.start
        let reference = Text(verbatim: Self.fixture).appFont(.body).foregroundStyle(.readableSecondary)
        let wrapped = Self.referenceHeight(reference, width: Self.inner)
        let single = Self.referenceHeight(reference, width: 4000)
        #expect(wrapped > single + 0.5, "夹具在行宽内确实要折行")
        let head = Self.height(trailing: .none, model: model, width: 473)
        let narrow = Self.height(trailing: .text(Self.fixture), model: model, width: 473)
        #expect(narrow >= head + 14 + wrapped - 1, "折行的尾字要给足折好的高：\(narrow) 对 \(head) + 14 + \(wrapped)")
        let wideHead = Self.height(trailing: .none, model: model, width: 1200)
        let wideText = Self.height(trailing: .text(Self.fixture), model: model, width: 1200)
        #expect(wideText <= wideHead + single + 0.5, "放得下时不虚长")
        let (window, nodes) = try await PlannerAXHarness.nodes(hosting: Self.row(trailing: .text(Self.fixture), model: model), width: 473)
        defer { window.close() }
        let spoken = nodes.first { $0.label.contains("Лос-Анджелес") }?.label ?? ""
        #expect(spoken.contains(Self.fixture), "读到的整句要含全部夹具字：\(spoken)")
    }

    @Test func narrowSlotRowsCarryTheCompletePayerLine() async throws {
        let (defaults, cleanup) = TestDefaults.make(prefix: "planner-slot-payers")
        defer { cleanup() }
        let model = AppModel(defaults: defaults, migrate: false, applySystemIntegration: false)
        model.now = Self.start
        let fits = Self.payersFits()
        let outside = fits.filter { fit in
            if case .inside = fit.fit { return false }
            return true
        }
        #expect(fits.count == 2 && outside.count == 2, "洛杉矶与伦敦都在各自时段外（深夜/清晨）")
        let format = ClockFormat(hourStyle: model.core.settings.hourStyle, showSeconds: false)
        let payers = try #require(PlannerText.payers(fits, start: Self.start, format: format, locale: Self.ru))
        let wrapped = Self.referenceHeight(payers.appFont(.body), width: Self.inner)
        let single = Self.referenceHeight(payers.appFont(.body), width: 4000)
        #expect(wrapped > single + 0.5, "两处付款串在行宽内确实要折行")
        let head = Self.height(trailing: .none, model: model, width: 473)
        let narrow = Self.height(trailing: .payers(fits), model: model, width: 473)
        #expect(narrow >= head + 14 + wrapped - 1, "折行的付款串要给足折好的高：\(narrow) 对 \(head) + 14 + \(wrapped)")
        let wideHead = Self.height(trailing: .none, model: model, width: 1200)
        let widePayers = Self.height(trailing: .payers(fits), model: model, width: 1200)
        #expect(widePayers <= wideHead + single + 0.5, "放得下时不虚长")
        let (window, nodes) = try await PlannerAXHarness.nodes(hosting: Self.row(trailing: .payers(fits), model: model), width: 473)
        defer { window.close() }
        let spoken = nodes.first { $0.label.contains("Лос-Анджелес") }?.label ?? ""
        let la = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let london = try #require(TimeZone(identifier: "Europe/London"))
        #expect(spoken.contains("Лос-Анджелес \(PlannerText.clock(Self.start, in: la, format: format, locale: Self.ru))"),
                "钟点按宿主时区现算：\(spoken)")
        #expect(spoken.contains("Лондон \(PlannerText.clock(Self.start, in: london, format: format, locale: Self.ru))"),
                "钟点按宿主时区现算：\(spoken)")
    }
}

@MainActor
struct TrailingWrapLayoutWrappingTests {
    private static let start = ISO8601DateFormatter().date(from: "2026-10-08T05:00:00Z")!

    private static func longText(_ locale: Locale) -> String {
        let london = TimeZone(identifier: "Europe/London")!
        return "Лос-Анджелес 22:00 · Лондон " + String(format: L10n.string("次日（%1$@）%2$@", locale: locale), locale: locale,
                                                        ClockText.weekday(start, in: london, locale: locale), "6:00")
    }

    @Test(arguments: [("ru", 1.0), ("ru", 1.3), ("de", 1.0), ("de", 1.3),
                      ("fr", 1.0), ("fr", 1.3), ("pt-BR", 1.0), ("pt-BR", 1.3)])
    func wrappedTrailingTextGetsItsFullConstrainedHeight(language: String, scale: Double) {
        let locale = Locale(identifier: language)
        let long = Self.longText(locale)
        func size<V: View>(_ view: V) -> CGSize {
            NSHostingView(rootView: view.environment(\.locale, locale).environment(\.textScale, scale)).fittingSize
        }
        let head = size(Text(verbatim: "22:00–23:00").fixedSize())
        let single = size(Text(verbatim: long).fixedSize())
        let longestWord = long.components(separatedBy: .whitespaces)
            .map { size(Text(verbatim: $0).fixedSize()).width }.max() ?? single.width
        let narrow = (longestWord + single.width) / 2
        #expect(narrow < single.width - 0.5 && narrow > longestWord + 0.5)
        let wrapped = size(Text(verbatim: long).fixedSize(horizontal: false, vertical: true).frame(width: narrow))
        #expect(wrapped.height > single.height + 0.5, "\(language)×\(scale)：尾样在窄行里确实折行")
        func layout(width: CGFloat) -> CGSize {
            size(TrailingWrapLayout(spacing: 8) {
                Text(verbatim: "22:00–23:00").fixedSize()
                Text(verbatim: long).fixedSize(horizontal: false, vertical: true)
            }.frame(width: width))
        }
        let wrappedLayout = layout(width: narrow)
        #expect(wrappedLayout.height >= head.height + 8 + wrapped.height - 1,
                "\(language)×\(scale)：折行后的高要容下尾样折好的高 \(wrappedLayout.height) 对 \(head.height)+8+\(wrapped.height)")
        #expect(wrappedLayout.height <= head.height + 8 + wrapped.height + 1, "\(language)×\(scale)：也不多给")
        #expect(wrappedLayout.width <= narrow + 0.5, "\(language)×\(scale)：横向不出界")
        let singleLayout = layout(width: single.width + head.width + 8 + 40)
        #expect(abs(singleLayout.height - max(head.height, single.height)) <= 1, "\(language)×\(scale)：放得下时仍是单行")
    }
}
