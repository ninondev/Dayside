// SPDX-License-Identifier: GPL-3.0-only
//
//  SettingsLayoutTests.swift
//  DaysideTests
//
//  设置页在 520 pt 宽下按内容定高；十六种语言的内容必须完整落在可见区。
//  同时保存每页实际内容高，供重新设置高度上限。
//

import AppKit
import SwiftUI
import Testing
@testable import Dayside

@MainActor
struct SettingsLayoutTests {
    /// 设置窗的固定宽度（SettingsRootView）。
    private static let settingsWidth = SettingsRootView.width

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_FOREGROUND"] == "1",
        "Real scroll-wheel delivery requires the strict idle foreground lane."))
    func russianLargestTextPageScrollsInAShortWindow() async throws {
        let enabled = try await Self.shortWindowScrollResponse(disabled: false)
        #expect(enabled.after > enabled.before, "短窗口中的设置页必须响应滚动")
        let disabled = try await Self.shortWindowScrollResponse(disabled: true)
        #expect(disabled.after == disabled.before, "滚动锁对照必须拒绝同一种滚动事件")
    }

    private static func shortWindowScrollResponse(disabled: Bool) async throws -> (before: CGFloat, after: CGFloat) {
        let (defaults, cleanup) = TestDefaults.make(prefix: disabled ? "settings-short-scroll-disabled" : "settings-short-scroll-enabled")
        defer { cleanup() }
        let model = AppModel(defaults: defaults, migrate: false, applySystemIntegration: false)
        model.settings.interfaceLanguage = .ru
        model.settings.textSize = .larger
        let host = NSHostingView(rootView: GeneralSettingsView()
            .environment(model).environment(model.core)
            .environment(\.locale, Locale(identifier: "ru"))
            .environment(\.textScale, TextSize.larger.scale)
            .toggleStyle(.checkbox).scrollDisabled(disabled))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.settingsWidth, height: 320),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.orderOut(nil); window.contentView = nil }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        let scroll = try #require(Self.formScrollView(in: host))
        let document = try #require(scroll.documentView)
        #expect(abs(host.frame.height - 320) <= 1, "测试窗口必须保持强制短高")
        #expect(scroll.contentView.bounds.height <= 321, "表单可见区必须受短窗口约束")
        #expect(document.frame.height > scroll.contentView.bounds.height)
        let initial = scroll.contentView.bounds.origin.y
        let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                        wheelCount: 1, wheel1: -240, wheel2: 0, wheel3: 0))
        scroll.scrollWheel(with: try #require(NSEvent(cgEvent: event)))
        try? await Task.sleep(for: .milliseconds(100))
        print("SETTINGS_SCROLL\t\(disabled ? "disabled" : "enabled")\t\(host.frame.height)\t\(document.frame.height)\t\(scroll.contentView.bounds.height)\t\(initial)\t\(scroll.contentView.bounds.origin.y)")
        return (initial, scroll.contentView.bounds.origin.y)
    }

    @Test func nativeSizingFollowsSelectedPageWithoutFightingAnUnchangedShortWindow() throws {
        let window = NSWindow(contentRect: NSRect(x: 180, y: 280, width: Self.settingsWidth, height: 100),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: Self.settingsWidth, height: 100))
        defer { window.contentView = nil }
        let coordinator = SettingsWindowSizingCoordinator()
        coordinator.attach(window)
        let first = SettingsWindowFitRequest(tab: .general, height: 240, revision: 0)
        #expect(coordinator.fit(first))
        #expect(abs(window.contentLayoutRect.height - first.height) <= 1)
        var short = window.frame
        short.size.height = 160
        window.setFrame(short, display: false, animate: false)
        let shortened = window.frame
        #expect(!coordinator.fit(first))
        #expect(window.frame == shortened)
        let next = SettingsWindowFitRequest(tab: .appearance, height: 280, revision: 1)
        #expect(coordinator.fit(next))
        #expect(abs(window.contentLayoutRect.height - next.height) <= 1)
        #expect(window.frame.height > shortened.height)
    }

    @Test func manualNativeSizingSurvivesTabChangesAndSameWindowReattachment() {
        func makeWindow() -> NSWindow {
            let window = NSWindow(contentRect: NSRect(x: 180, y: 280, width: Self.settingsWidth, height: 100),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: Self.settingsWidth, height: 100))
            return window
        }
        let window = makeWindow()
        let other = makeWindow()
        defer { window.contentView = nil; other.contentView = nil }
        let coordinator = SettingsWindowSizingCoordinator()
        coordinator.attach(window)
        #expect(coordinator.fit(SettingsWindowFitRequest(tab: .general, height: 240, revision: 0)))
        coordinator.beginManualResize()
        var short = window.frame
        short.size.height = 160
        window.setFrame(short, display: false, animate: false)
        let shortened = window.frame
        #expect(!coordinator.fit(SettingsWindowFitRequest(tab: .appearance, height: 280, revision: 1)))
        #expect(!coordinator.fit(SettingsWindowFitRequest(tab: .appearance, height: 320, revision: 2)))
        #expect(window.frame == shortened)
        coordinator.attach(nil)
        coordinator.attach(window)
        #expect(!coordinator.fit(SettingsWindowFitRequest(tab: .help, height: 300, revision: 0)))
        #expect(window.frame == shortened)
        coordinator.attach(other)
        #expect(coordinator.fit(SettingsWindowFitRequest(tab: .help, height: 300, revision: 0)))
        #expect(abs(other.contentLayoutRect.height - 300) <= 1)
    }

    @Test func nativeSizingPreservesTheTopEdgeAndClampsToTheVisibleScreen() {
        let visible = NSRect(x: 100, y: 80, width: 1_280, height: 859)
        let before = NSRect(x: visible.minX + 20, y: visible.midY,
                            width: Self.settingsWidth, height: 100)
        let nativeInset: CGFloat = 28
        let fitted = SettingsWindowSizingCoordinator.boundedFrame(
            before: before, preferredSize: NSSize(width: Self.settingsWidth, height: 200 + nativeInset),
            visibleFrame: visible)
        #expect(abs(fitted.maxY - before.maxY) <= 1)
        let small = NSRect(x: visible.minX + 40, y: visible.minY + 40, width: 600, height: 300)
        let clamped = SettingsWindowSizingCoordinator.boundedFrame(
            before: fitted, preferredSize: NSSize(width: Self.settingsWidth, height: 900 + nativeInset),
            visibleFrame: small)
        #expect(abs(clamped.height - small.height) <= 1)
        #expect(clamped.minX >= small.minX && clamped.maxX <= small.maxX + 1)
        #expect(clamped.minY >= small.minY && clamped.maxY <= small.maxY + 1)
        #expect(clamped.height - nativeInset < 900)
    }

    private static func formScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { formScrollView(in: $0) }.first
    }

    @Test func generalPageFitsItsContentHeightInEveryLanguage() async throws {
        let (defaults, cleanup) = TestDefaults.make(prefix: "settings-layout")
        defer { cleanup() }
        let model = AppModel(defaults: defaults, migrate: false, applySystemIntegration: false)
        for language in InterfaceLanguage.allCases where language != .system {
            let measurement = try #require(await Self.measurement(of: GeneralSettingsView(), model: model, language: language))
            let height = measurement.document
            #expect(measurement.document <= measurement.viewport + 1, "内容超过可见区：\(language.rawValue)")
            #expect(measurement.documentWidth <= measurement.viewportWidth + 1, "内容超出窗口宽度：\(language.rawValue)")
            #expect(height <= GeneralSettingsView.maximumDefaultHeight,
                    "通用页在 \(language.rawValue) 下内容高 \(height) pt，超过 maximumDefaultHeight \(GeneralSettingsView.maximumDefaultHeight)")
        }
    }

    @Test func appearancePageFitsItsContentHeightInEveryLanguage() async throws {
        let (defaults, cleanup) = TestDefaults.make(prefix: "settings-layout")
        defer { cleanup() }
        let model = AppModel(defaults: defaults, migrate: false, applySystemIntegration: false)
        for language in InterfaceLanguage.allCases where language != .system {
            let measurement = try #require(await Self.measurement(of: AppearanceSettingsView(), model: model, language: language))
            let height = measurement.document
            #expect(measurement.document <= measurement.viewport + 1, "内容超过可见区：\(language.rawValue)")
            #expect(measurement.documentWidth <= measurement.viewportWidth + 1, "内容超出窗口宽度：\(language.rawValue)")
            #expect(height <= AppearanceSettingsView.maximumDefaultHeight,
                    "外观页在 \(language.rawValue) 下内容高 \(height) pt，超过 maximumDefaultHeight \(AppearanceSettingsView.maximumDefaultHeight)")
        }
    }

    @Test func expandedAppearancePageFitsItsContentHeightInEveryLanguage() async throws {
        let (defaults, cleanup) = TestDefaults.make(prefix: "settings-expanded-layout")
        defer { cleanup() }
        let model = AppModel(defaults: defaults, migrate: false, applySystemIntegration: false)
        model.settings.panelColors = .system
        model.settings.useCustomColor = true
        for language in InterfaceLanguage.allCases where language != .system {
            let measurement = try #require(await Self.measurement(of: AppearanceSettingsView(), model: model, language: language))
            #expect(measurement.document <= measurement.viewport + 1)
            #expect(measurement.documentWidth <= measurement.viewportWidth + 1)
            #expect(measurement.document <= AppearanceSettingsView.maximumExpandedHeight)
            let root = try #require(await Self.rootMeasurement(tab: .appearance, model: model, language: language))
            #expect(root.document <= root.viewport + 1)
            #expect(root.pageHeight <= AppearanceSettingsView.maximumExpandedHeight + 1)
            #expect(root.windowHeight <= 859)
        }
    }

    @Test func appearanceViewportGrowsAndShrinksWhenCustomColoursChange() async throws {
        let (defaults, cleanup) = TestDefaults.make(prefix: "settings-live-expansion")
        defer { cleanup() }
        let model = AppModel(defaults: defaults, migrate: false, applySystemIntegration: false)
        let host = NSHostingView(rootView: AppearanceSettingsView()
            .environment(model).environment(model.core)
            .environment(\.locale, Locale(identifier: "en"))
            .toggleStyle(.checkbox))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.settingsWidth, height: 1_400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        // 离屏 NSWindow 不由 Settings 场景管理，按当前拟合尺寸更新。
        @MainActor func fittedPhase(_ phase: String) async throws -> Measurement {
            var fitting = host.fittingSize
            for attempt in 0..<6 {
                host.layoutSubtreeIfNeeded()
                try? await Task.sleep(for: .milliseconds(100))
                host.layoutSubtreeIfNeeded()
                fitting = host.fittingSize
                #expect(fitting.height <= AppearanceSettingsView.maximumExpandedHeight + 1)
                window.setContentSize(fitting)
                try? await Task.sleep(for: .milliseconds(100))
                host.layoutSubtreeIfNeeded()
                let settled = host.fittingSize
                print("SETTINGS_TRANSITION\t\(phase)\t\(attempt)\t\(model.settings.panelColors.rawValue)\t\(model.settings.useCustomColor)\t\(fitting.height)\t\(settled.height)\t\(host.frame.height)")
                if attempt >= 2, abs(settled.height - fitting.height) <= 1 { break }
            }
            let scroll = try #require(Self.formScrollView(in: host))
            let document = try #require(scroll.documentView)
            let measurement = Measurement(document: document.frame.height,
                                          viewport: scroll.contentView.bounds.height,
                                          documentWidth: document.frame.width,
                                          viewportWidth: scroll.contentView.bounds.width)
            #expect(abs(host.frame.height - fitting.height) <= 1)
            #expect(measurement.document <= measurement.viewport + 1)
            #expect(measurement.documentWidth <= measurement.viewportWidth + 1)
            print("SETTINGS_EXPANSION_PHASE\t\(phase)\t\(ObjectIdentifier(scroll))\t\(ObjectIdentifier(document))\t\(fitting.height)\t\(host.frame.height)\t\(measurement.document)\t\(measurement.viewport)")
            return measurement
        }
        let original = try await fittedPhase("default")
        #expect(original.viewport <= AppearanceSettingsView.maximumDefaultHeight + 1)
        model.settings.panelColors = .system
        model.settings.useCustomColor = true
        let expanded = try await fittedPhase("custom-on")
        #expect(expanded.viewport > original.viewport)
        #expect(expanded.document <= AppearanceSettingsView.maximumExpandedHeight)
        model.settings.useCustomColor = false
        let collapsed = try await fittedPhase("custom-off")
        #expect(collapsed.viewport < expanded.viewport)
        #expect(collapsed.viewport > original.viewport)
        model.settings.panelColors = .sky
        let restored = try await fittedPhase("restored")
        #expect(restored.viewport <= original.viewport + 1)
        #expect(restored.viewport <= AppearanceSettingsView.maximumDefaultHeight + 1)
        print("SETTINGS_EXPANSION\t\(original.viewport)\t\(expanded.viewport)\t\(collapsed.viewport)\t\(restored.viewport)")
    }

    @Test func shortcutsPageFitsItsContentHeightInEveryLanguage() async throws {
        let (defaults, cleanup) = TestDefaults.make(prefix: "settings-layout")
        defer { cleanup() }
        let model = AppModel(defaults: defaults, migrate: false, applySystemIntegration: false)
        for language in InterfaceLanguage.allCases where language != .system {
            let measurement = try #require(await Self.measurement(of: ShortcutsSettingsView(), model: model, language: language))
            let height = measurement.document
            #expect(measurement.document <= measurement.viewport + 1, "内容超过可见区：\(language.rawValue)")
            #expect(measurement.documentWidth <= measurement.viewportWidth + 1, "内容超出窗口宽度：\(language.rawValue)")
            #expect(height <= ShortcutsSettingsView.maximumDefaultHeight,
                    "快捷键页在 \(language.rawValue) 下内容高 \(height) pt，超过 maximumDefaultHeight \(ShortcutsSettingsView.maximumDefaultHeight)")
        }
    }

    /// 帮助页默认折叠时，头图、脚注与全部入口都完整可见。
    @Test func helpPageFitsItsContentHeightInEveryLanguage() async throws {
        let (defaults, cleanup) = TestDefaults.make(prefix: "settings-layout")
        defer { cleanup() }
        let model = AppModel(defaults: defaults, migrate: false, applySystemIntegration: false)
        for language in InterfaceLanguage.allCases where language != .system {
            let measurement = try #require(await Self.measurement(of: HelpSettingsView(), model: model, language: language))
            let height = measurement.document
            #expect(measurement.document <= measurement.viewport + 1, "内容超过可见区：\(language.rawValue)")
            #expect(measurement.documentWidth <= measurement.viewportWidth + 1, "内容超出窗口宽度：\(language.rawValue)")
            #expect(height <= HelpSettingsView.maximumDefaultHeight,
                    "帮助页在 \(language.rawValue) 下内容高 \(height) pt，超过 maximumDefaultHeight \(HelpSettingsView.maximumDefaultHeight)")
        }
    }

    private struct Measurement {
        let document: CGFloat
        let viewport: CGFloat
        let documentWidth: CGFloat
        let viewportWidth: CGFloat
    }

    /// 不激活离屏窗口，量页面自身拟合后的可见区与内容。
    private static func measurement(of page: some View, model: AppModel, language: InterfaceLanguage) async -> Measurement? {
        model.settings.interfaceLanguage = language
        let locale = Locale(identifier: language.localeIdentifier ?? "en")
        let host = NSHostingView(rootView: page.environment(model).environment(model.core).environment(\.locale, locale).toggleStyle(.checkbox))
        host.frame = NSRect(x: 0, y: 0, width: settingsWidth, height: 1_400)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(200))   // Form 的行在下一轮布局才落定
        host.layoutSubtreeIfNeeded()
        var scrollViews: [NSScrollView] = []
        func walk(_ view: NSView) {
            if let scrollView = view as? NSScrollView { scrollViews.append(scrollView) }
            view.subviews.forEach(walk)
        }
        walk(host)
        guard let scroll = scrollViews.first, let document = scroll.documentView else { return nil }
        print("SETTINGS_HEIGHT\t\(String(describing: type(of: page)))\t\(language.rawValue)\t\(document.frame.height)\t\(scroll.contentView.bounds.height)")
        return Measurement(document: document.frame.height, viewport: scroll.contentView.bounds.height,
                           documentWidth: document.frame.width, viewportWidth: scroll.contentView.bounds.width)
    }

    @Test(arguments: [SettingsRootView.Tab.general, .appearance, .shortcuts, .help])
    func fittedSettingsWindowIncludesNativeInsetsOnce(tab: SettingsRootView.Tab) async throws {
        let (defaults, cleanup) = TestDefaults.make(prefix: "settings-root-layout")
        defer { cleanup() }
        let model = AppModel(defaults: defaults, migrate: false, applySystemIntegration: false)
        let maximum: CGFloat = switch tab {
        case .general: GeneralSettingsView.maximumDefaultHeight
        case .appearance: AppearanceSettingsView.maximumDefaultHeight
        case .shortcuts: ShortcutsSettingsView.maximumDefaultHeight
        case .help: HelpSettingsView.maximumDefaultHeight
        }
        for language in InterfaceLanguage.allCases where language != .system {
            let measured = try #require(await Self.rootMeasurement(tab: tab, model: model, language: language))
            #expect(measured.document <= measured.viewport + 1, "内容超过可见区：\(language.rawValue)")
            #expect(measured.documentWidth <= measured.viewportWidth + 1, "内容超出窗口宽度：\(language.rawValue)")
            #expect(measured.pageHeight <= maximum + 1, "表单重复计算留白：\(language.rawValue)")
            #expect(measured.windowHeight <= 859, "设置窗超出 859 pt 可见屏幕：\(language.rawValue)")
        }
    }


    @Test func largestTextSettingsAndWelcomeStayScreenBoundedAndReachTheirBottom() async throws {
        let (defaults, cleanup) = TestDefaults.make(prefix: "largest-scroll-policy")
        defer { cleanup() }
        let model = AppModel(defaults: defaults, migrate: false, applySystemIntegration: false)
        model.settings.textSize = .larger
        let visible = try #require(NSScreen.main?.visibleFrame)
        for language in [InterfaceLanguage.en, .ru, .de, .ja] {
            model.settings.interfaceLanguage = language
            let locale = Locale(identifier: language.localeIdentifier ?? "en")
            for tab in [SettingsRootView.Tab.general, .help] {
                let root = SettingsRootView(tab: tab).environment(model).environment(model.core)
                    .environment(\.locale, locale).environment(\.textScale, TextSize.larger.scale)
                try await Self.assertScrollGeometry(root, width: Self.settingsWidth, visible: visible,
                                                    label: "\(tab.rawValue)-\(language.rawValue)", short: false)
                if language == .ru {
                    try await Self.assertScrollGeometry(root, width: Self.settingsWidth, visible: visible,
                                                        label: "\(tab.rawValue)-ru-short", short: true)
                }
            }
            let welcome = WelcomeView().environment(model).environment(model.core)
                .environment(\.locale, locale).environment(\.textScale, TextSize.larger.scale)
            try await Self.assertScrollGeometry(welcome, width: 560, visible: visible,
                                                label: "welcome-\(language.rawValue)", short: false)
            if language == .ru {
                try await Self.assertScrollGeometry(welcome, width: 560, visible: visible,
                                                    label: "welcome-ru-short", short: true)
            }
        }
    }

    private static func assertScrollGeometry<Content: View>(_ content: Content, width: CGFloat,
                                                            visible: NSRect, label: String,
                                                            short: Bool) async throws {
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: visible.height - 28),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        window.orderFront(nil)
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
        }
        let fitting = host.fittingSize
        let preferred = window.frameRect(forContentRect: NSRect(origin: .zero, size: fitting)).size
        window.setFrame(SettingsWindowSizingCoordinator.boundedFrame(
            before: window.frame, preferredSize: preferred, visibleFrame: visible), display: false)
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        if short {
            var frame = window.frame
            frame.size.height -= host.frame.height - 320
            window.setFrame(frame, display: false)
            try await Task.sleep(for: .milliseconds(200))
            host.layoutSubtreeIfNeeded()
            #expect(abs(host.frame.height - 320) <= 1)
        }
        let scroll = try #require(Self.formScrollView(in: host))
        let document = try #require(scroll.documentView)
        let viewport = scroll.contentView.bounds
        #expect(window.frame.height <= visible.height + 1)
        #expect(window.frame.width <= visible.width + 1)
        #expect(abs(host.frame.width - width) <= 1)
        #expect(document.frame.width <= viewport.width + 1)
        #expect(viewport.height > 0)
        if short {
            #expect(viewport.height <= 321)
            #expect(document.frame.height > viewport.height)
        }
        let bottomY = document.isFlipped
            ? max(document.frame.minY, document.frame.maxY - viewport.height) : document.frame.minY
        scroll.contentView.scroll(to: NSPoint(x: viewport.minX, y: bottomY))
        scroll.reflectScrolledClipView(scroll.contentView)
        host.layoutSubtreeIfNeeded()
        let bottom = scroll.contentView.bounds
        if document.isFlipped {
            #expect(bottom.maxY >= document.frame.maxY - 1)
        } else {
            #expect(bottom.minY <= document.frame.minY + 1)
        }
        #expect(document.frame.width <= bottom.width + 1)
        if document.frame.height > viewport.height + 1 {
            #expect(abs(bottom.origin.y - bottomY) <= 1)
        }
        print("LARGEST_SCROLL_GEOMETRY\t\(label)\t\(window.frame.height)\t\(visible.height)\t\(document.frame.height)\t\(viewport.height)\t\(document.frame.width)\t\(viewport.width)\t\(bottom.minY)\t\(bottom.maxY)\t\(document.isFlipped)")
    }

    @Test func formMeasurementReportsTheDocumentWithoutAddingItsInsetsAgain() throws {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 300))
        let scroll = NSScrollView(frame: container.bounds)
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 44, left: 0, bottom: 44, right: 0)
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 612))
        scroll.documentView = document
        container.addSubview(scroll)
        var measured: CGFloat?
        let probe = SettingsFormMeasurement.MeasurementView { measured = $0 }
        container.addSubview(probe)
        probe.measureNow()
        let reported = try #require(measured)
        #expect(reported == 612)
        #expect(scroll.contentInsets.top + scroll.contentInsets.bottom == 88)
    }

    private struct RootMeasurement {
        let document: CGFloat
        let viewport: CGFloat
        let documentWidth: CGFloat
        let viewportWidth: CGFloat
        let pageHeight: CGFloat
        let windowHeight: CGFloat
    }

    /// 不激活离屏窗口，量实际 TabView 根视图拟合后的窗口与内容。
    private static func rootMeasurement(tab: SettingsRootView.Tab, model: AppModel, language: InterfaceLanguage) async -> RootMeasurement? {
        model.settings.interfaceLanguage = language
        let locale = Locale(identifier: language.localeIdentifier ?? "en")
        let host = NSHostingView(rootView: SettingsRootView(tab: tab).environment(model).environment(model.core).environment(\.locale, locale).toggleStyle(.checkbox))
        host.frame = NSRect(x: 0, y: 0, width: settingsWidth, height: 1_400)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(200))   // Form 的行在下一轮布局才落定
        host.layoutSubtreeIfNeeded()
        window.setContentSize(host.fittingSize)
        try? await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        var scrollViews: [NSScrollView] = []
        func walk(_ view: NSView) {
            if let scrollView = view as? NSScrollView { scrollViews.append(scrollView) }
            view.subviews.forEach(walk)
        }
        walk(host)
        guard let scroll = scrollViews.first, let document = scroll.documentView else { return nil }
        print("SETTINGS_HEIGHT\t\(tab.rawValue)\t\(language.rawValue)\t\(document.frame.height)\t\(scroll.contentView.bounds.height)\t\(scroll.frame.height)\t\(window.frame.height)")
        return RootMeasurement(document: document.frame.height, viewport: scroll.contentView.bounds.height,
                           documentWidth: document.frame.width, viewportWidth: scroll.contentView.bounds.width,
                           pageHeight: scroll.frame.height, windowHeight: window.frame.height)
    }
}

/// 全局快捷键：组合的合法性、位掩码换算与设置的往返。按键与注册要真机（`Tools/hotkey_probe.sh`），
/// 这里只钉规则与桥接：Rust 判合法，Swift 只做 Carbon 掩码与存取。
@MainActor
struct GlobalHotkeyTests {
    @Test func rustDecidesWhichCombinationsAreLegal() {
        // ⌥⌘T 合法，写法按 Apple 的次序。
        let good = HotkeyCandidate(keyCode: 17, modifiers: 1 | 2)
        #expect(good.ok)
        #expect(good.label == "⌥⌘T")
        #expect(good.keyCode == 17 && good.modifiers == 3)
        // 裸键 / ⌘ 单独 / 表外的键各有各的说法。
        #expect(HotkeyRecorder.rejection(HotkeyCandidate(keyCode: 17, modifiers: 0).error) == .needsModifier)
        #expect(HotkeyRecorder.rejection(HotkeyCandidate(keyCode: 17, modifiers: 1).error) == .commandOnly)
        #expect(HotkeyRecorder.rejection(HotkeyCandidate(keyCode: 52, modifiers: 2).error) == .unknownKey)
    }

    @Test func modifierMasksSurviveTheRoundTripThroughAppKitAndCarbon() {
        #expect(GlobalHotkeyCenter.mask(from: [.command, .option]) == 3)
        #expect(GlobalHotkeyCenter.mask(from: [.control, .shift]) == 12)
        // Carbon 的掩码（cmdKey 0x0100、optionKey 0x0800、controlKey 0x1000、shiftKey 0x0200）。
        #expect(GlobalHotkeyCenter.carbonModifiers(3) == 0x0100 | 0x0800)
        #expect(GlobalHotkeyCenter.carbonModifiers(12) == 0x1000 | 0x0200)
    }

    @Test func theSettingDefaultsToOffAndDropsAnUnusableCombination() throws {
        let (defaults, cleanup) = TestDefaults.make(prefix: "hotkey")
        defer { cleanup() }
        let model = AppModel(defaults: defaults, migrate: false, applySystemIntegration: false)
        // 默认：关着，⌥⌘T。
        #expect(model.settings.hotkey.enabled == false)
        #expect(model.settings.hotkey.label == "⌥⌘T")
        // 改成 ⌥␣ 并打开 → 原样落盘。
        model.settings.hotkey = HotkeySetting(enabled: true, keyCode: 49, modifiers: 2)
        let reloaded = Store.loadSettings(from: defaults)
        #expect(reloaded.hotkey == HotkeySetting(enabled: true, keyCode: 49, modifiers: 2))
        #expect(reloaded.hotkey.label == "⌥␣")
        // 偏好里存着一个注册不了的组合（⌘T）→ 读回来是「关着的默认」，不留一个按不动的状态。
        let bad = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"hotkey":{"enabled":true,"keyCode":17,"modifiers":1}}"#.utf8))
        #expect(bad.hotkey == HotkeySetting(enabled: false, keyCode: 17, modifiers: 3))
    }

    @Test func pressingTheHotkeyGoesThroughTheMenuBarItem() {
        // 生产路径是「按下 → 点我们自己的菜单栏项」；这里只证按下确实走到那一步
        // （真按键与真面板由 Tools/hotkey_probe.sh 在实机上验）。
        let center = GlobalHotkeyCenter.shared
        let previous = center.onPress
        defer { center.onPress = previous }
        var pressed = 0
        center.onPress = { pressed += 1 }
        center.handlePress()
        center.handlePress()
        #expect(pressed == 2)
    }
}

/// 文字大小三档：macOS 不支持 Dynamic Type，所以自己按倍数换字号。
/// 这里钉住三件事：标准档必须是 1.0（渲染逐像素与从前相同）、坏值回标准、字号出口跟着系统字号走。
@MainActor
struct TextSizeTests {
    @Test func theThreeStepsAreClosedAndStandardChangesNothing() throws {
        #expect(TextSize.allCases.map(\.rawValue) == ["standard", "large", "larger"])
        #expect(TextSize.standard.scale == 1.0)
        #expect(TextSize.large.scale > 1.0 && TextSize.larger.scale > TextSize.large.scale)
        let (defaults, cleanup) = TestDefaults.make(prefix: "textsize")
        defer { cleanup() }
        let model = AppModel(defaults: defaults, migrate: false, applySystemIntegration: false)
        #expect(model.settings.textSize == .standard)
        model.settings.textSize = .larger
        #expect(Store.loadSettings(from: defaults).textSize == .larger)
        // 偏好里存了个不认识的档 → 回标准，别把界面搞成半大不小。
        let bad = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"textSize":"huge"}"#.utf8))
        #expect(bad.textSize == .standard)
    }

    @Test func theFontSizesComeFromTheSystemNotFromHardCodedPoints() {
        // 字号取系统当前该文本样式的字号（用户改了系统字号也跟着走），不是写死的 13 / 11 pt。
        for style in [Font.TextStyle.caption2, .caption, .callout, .headline, .title3] {
            let size = AppFont.size(style)
            #expect(size >= 9 && size <= 40, "\(style) 的字号 \(size) 不像系统字号")
        }
        // macOS 的 caption1 与 caption2 都是 10 pt（HIG：caption2 = 10 pt Medium），只能断言不大于。
        #expect(AppFont.size(.caption2) <= AppFont.size(.caption))
        #expect(AppFont.size(.callout) <= AppFont.size(.headline))
    }
}
