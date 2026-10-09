// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI
import Testing
@testable import Dayside

@Suite(.serialized)
@MainActor
struct SettingsScrollReviewTests {
    enum Page: String, CaseIterable {
        case general, appearance, appearanceExpanded, shortcuts, help

        var tab: SettingsRootView.Tab {
            switch self {
            case .general: .general
            case .appearance, .appearanceExpanded: .appearance
            case .shortcuts: .shortcuts
            case .help: .help
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_FOREGROUND"] == "1",
        "Real scroll-wheel delivery requires the strict idle foreground lane."),
        arguments: Page.allCases, [InterfaceLanguage.ru, .de])
    func largestTextScrollsToTheBottomInAShortWindow(page: Page, language: InterfaceLanguage) async throws {
        let (defaults, cleanup) = TestDefaults.make(prefix: "settings-scroll-review")
        defer { cleanup() }
        let model = AppModel(defaults: defaults, migrate: false, applySystemIntegration: false)
        model.settings.interfaceLanguage = language
        model.settings.textSize = .larger
        if page == .appearanceExpanded {
            model.settings.panelColors = .system
            model.settings.useCustomColor = true
        }
        let host = NSHostingView(rootView: SettingsRootView(tab: page.tab)
            .environment(model).environment(model.core)
            .environment(\.locale, Locale(identifier: language.rawValue))
            .environment(\.textScale, TextSize.larger.scale))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SettingsRootView.width, height: 320),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.orderOut(nil); window.contentView = nil }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        // 原生标签栏挂上窗口后会改变内容区，按实际宿主高度缩到短窗口。
        var shortFrame = window.frame
        shortFrame.size.height -= host.frame.height - 320
        window.setFrame(shortFrame, display: false, animate: false)
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()

        let scroll = try #require(Self.visibleForm(in: host))
        let document = try #require(scroll.documentView)
        let viewport = scroll.contentView.bounds.size
        #expect(abs(host.frame.height - 320) <= 1)
        #expect(viewport.height <= 321)
        #expect(document.frame.height > viewport.height)
        #expect(document.frame.width <= viewport.width + 1)

        let output = try Self.captureDirectory(page: page, language: language)
        if let output { try await Self.capture(host, window: window, position: "top", directory: output) }
        let initial = scroll.contentView.bounds.origin.y
        try Self.scroll(scroll, pixels: -240)
        try await Task.sleep(for: .milliseconds(100))
        let afterWheel = scroll.contentView.bounds.origin.y
        #expect(afterWheel > initial, "短设置窗口必须响应垂直滚动")

        if let output {
            try await Self.capture(host, window: window, position: "middle-00", directory: output)
            let step = Int32(max(1, floor(viewport.height * 0.75)))
            let limit = Int(ceil(document.frame.height / CGFloat(step))) + 1
            for index in 1...limit {
                if scroll.contentView.bounds.maxY >= document.frame.maxY - 1 { break }
                let before = scroll.contentView.bounds.origin.y
                try Self.scroll(scroll, pixels: -step)
                try await Task.sleep(for: .milliseconds(100))
                let after = scroll.contentView.bounds.origin.y
                #expect(after > before, "中间截图必须来自真实的滚动位置")
                if after <= before { break }
                try await Self.capture(host, window: window,
                                       position: String(format: "middle-%02d", index), directory: output)
            }
        }
        try Self.scroll(scroll, pixels: -10_000)
        try await Task.sleep(for: .milliseconds(100))
        let bottom = scroll.contentView.bounds
        #expect(bottom.maxY >= document.frame.maxY - 1, "滚动必须能到达表单底部")
        #expect(document.frame.width <= bottom.width + 1)
        if let output { try await Self.capture(host, window: window, position: "bottom", directory: output) }

        try Self.scroll(scroll, pixels: 10_000)
        try await Task.sleep(for: .milliseconds(100))
        #expect(abs(scroll.contentView.bounds.origin.y - initial) <= 1,
                "向上滚动必须能返回表单顶部")
        print("SETTINGS_SCROLL_REVIEW\t\(page.rawValue)\t\(language.rawValue)\tlarger\t\(host.frame.height)\t\(document.frame.height)\t\(viewport.height)\t\(document.frame.width)\t\(viewport.width)\t\(initial)\t\(afterWheel)\t\(bottom.origin.y)\t\(bottom.maxY)")
    }

    @Test(arguments: [InterfaceLanguage.ru, .de])
    func nativePopupFontsRestoreThroughLiveTextSizeChanges(language: InterfaceLanguage) async throws {
        let page = Page.general
        let (defaults, cleanup) = TestDefaults.make(prefix: "settings-font-restoration")
        defer { cleanup() }
        let model = AppModel(defaults: defaults, migrate: false, applySystemIntegration: false)
        model.settings.interfaceLanguage = language
        model.settings.textSize = .standard
        let host = NSHostingView(rootView: LiveSettingsRoot(model: model, tab: page.tab))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SettingsRootView.width, height: 1_400),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(350))
        host.layoutSubtreeIfNeeded()
        let document = try #require(Self.visibleForm(in: host)?.documentView)
        let controls = Self.nativePopups(in: document)
        if #available(macOS 27, *), controls.isEmpty {
            try await Self.drawnPopupFontsRestore(model: model)
            return
        }
        #expect(controls.count == 8, "必须取得页面真正显示的八个原生菜单")
        let baseline = try controls.map { try #require($0.font) }
        let popupNames = controls.map(Self.nativeLogicalName)
        let identities = popupNames.enumerated().map { $0.element ?? "order:\($0.offset)" }
        #expect(Set(identities).count == 8, "通用设置必须对应八个不同的逻辑控件")
        let output = try Self.captureDirectory(page: page, language: language, kind: "font-restoration")
        let stages: [(name: String, size: TextSize)] = [
            ("standard-start", .standard), ("larger", .larger),
            ("large", .large), ("standard-restored", .standard)
        ]
        for stage in stages {
            model.settings.textSize = stage.size
            try await Task.sleep(for: .milliseconds(350))
            host.layoutSubtreeIfNeeded()
            let currentDocument = try #require(Self.visibleForm(in: host)?.documentView)
            let currentControls = Self.nativePopups(in: currentDocument)
            #expect(currentControls.count == controls.count)
            let identities = currentControls.enumerated().map {
                Self.nativeLogicalName($0.element) ?? "order:\($0.offset)"
            }
            #expect(Set(identities).count == 8, "字号切换后仍必须对应八个不同的逻辑控件")
            for (index, control) in currentControls.enumerated() {
                let baselineIndex: Int
                if let name = Self.nativeLogicalName(control) {
                    baselineIndex = try #require(popupNames.firstIndex { $0 == name },
                                                 "字号切换后的菜单必须对应原来的标签")
                } else {
                    // 原生标签关联不可读时，才按表单中的稳定顺序对应。
                    baselineIndex = index
                }
                let original = try #require(baseline.indices.contains(baselineIndex) ? baseline[baselineIndex] : nil)
                let actual = try #require(control.font)
                let expected = original.pointSize * stage.size.scale
                let tolerance = max(CGFloat(0.05), expected * 0.005)
                #expect(abs(actual.pointSize - expected) <= tolerance,
                        "原生控件字号必须按实测基线缩放，并能还原")
                #expect(actual.fontName == original.fontName, "缩放必须保留原生控件的字体")
                print("SETTINGS_FONT_RESTORE\t\(page.rawValue)\t\(language.rawValue)\t\(stage.name)\t\(index)\t\(original.pointSize)\t\(actual.pointSize)\t\(control.frame)")
            }
            if let output { try await Self.capture(host, window: window, position: stage.name, directory: output) }
        }
    }

    @Test(arguments: [Page.help, .shortcuts], [InterfaceLanguage.ru, .de])
    func drawnButtonLabelsScaleRestoreAndFitThroughLiveChanges(page: Page, language: InterfaceLanguage) async throws {
        let (defaults, cleanup) = TestDefaults.make(prefix: "settings-button-restoration")
        defer { cleanup() }
        let model = AppModel(defaults: defaults, migrate: false, applySystemIntegration: false)
        model.settings.interfaceLanguage = language
        model.settings.textSize = .standard
        let host = NSHostingView(rootView: LiveSettingsRoot(model: model, tab: page.tab))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SettingsRootView.width, height: 1_400),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        let previousAX = Self.enhancedAccessibilityValue()
        Self.setEnhancedAccessibility(true)
        defer { Self.setEnhancedAccessibility(previousAX) }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(350))
        host.layoutSubtreeIfNeeded()
        let expectedNames = page == .help
            ? ["导出诊断包…", "复制诊断摘要"].map { L10n.string($0, locale: model.uiLocale) }
            : [L10n.string("组合键", locale: model.uiLocale)]
        let baselineButtons = Self.accessibilityButtons(in: host).filter { expectedNames.contains($0.name) }
        #expect(baselineButtons.count == expectedNames.count, "必须取得两个诊断按钮或一个组合键按钮")
        #expect(Set(baselineButtons.map(\.name)) == Set(expectedNames), "实际按钮必须有完整的本地化名称")
        let baselineBitmap = try Self.lightBitmap(host, window: window)
        var baselineHeights: [String: CGFloat] = [:]
        for button in baselineButtons {
            baselineHeights[button.name] = try Self.glyphBounds(button, bitmap: baselineBitmap).height
        }
        let originalKeyCode = model.settings.hotkey.keyCode
        let originalKeyLabel = model.settings.hotkey.label
        let output = try Self.captureDirectory(page: page, language: language, kind: "font-restoration")
        let stages: [(name: String, size: TextSize)] = [
            ("standard-start", .standard), ("larger", .larger),
            ("large", .large), ("standard-restored", .standard)
        ]
        for stage in stages {
            model.settings.textSize = stage.size
            if page == .shortcuts, stage.name == "larger" {
                model.settings.hotkey.keyCode = originalKeyCode == 2 ? 0 : 2
                #expect(model.settings.hotkey.label != originalKeyLabel, "组合键模型变化必须改变实际标题")
            }
            try await Task.sleep(for: .milliseconds(350))
            host.layoutSubtreeIfNeeded()
            let current = Self.accessibilityButtons(in: host).filter { expectedNames.contains($0.name) }
            #expect(current.count == expectedNames.count)
            #expect(Set(current.map(\.name)) == Set(expectedNames))
            let bitmap = try Self.lightBitmap(host, window: window)
            for (index, button) in current.enumerated() {
                let baseline = try #require(baselineHeights[button.name], "字号切换后的按钮必须对应原来的名称")
                if page == .shortcuts {
                    #expect(button.value == model.settings.hotkey.label, "录制按钮必须显示当前模型的组合键")
                }
                let title = page == .shortcuts ? model.settings.hotkey.label : button.name
                let glyphs = try Self.glyphBounds(button, bitmap: bitmap)
                let expectedHeight = baseline * stage.size.scale
                // Raster antialiasing and integer-pixel coverage can move the glyph edge by one point.
                #expect(abs(glyphs.height - expectedHeight) <= 1,
                        "实际绘制的字形必须按实测基线缩放并还原，光栅误差最多一点")
                if stage.size != .standard {
                    #expect(glyphs.height > baseline, "较大字号必须使按钮字形真正增大")
                }
                let body = NSFont.preferredFont(forTextStyle: .body)
                let expectedFont = body.withSize(body.pointSize * stage.size.scale)
                let metrics = (title as NSString).size(withAttributes: [.font: expectedFont])
                #expect(metrics.width <= button.frame.width + 0.5 && metrics.height <= button.frame.height + 0.5,
                        "完整标题的目标字号必须放进实际按钮区域")
                print("SETTINGS_DRAWN_BUTTON_RESTORE\t\(page.rawValue)\t\(language.rawValue)\t\(stage.name)\t\(index)\t\(baseline)\t\(glyphs.height)\t\(button.frame)\t\(glyphs)\t\(metrics)\t\(bitmap.scale)")
            }
            if let output { try await Self.capture(host, window: window, position: stage.name, directory: output) }
        }
    }

    private static func popupValues(_ model: AppModel) -> [String: String] {
        let locale = model.uiLocale
        let values = [
            ("界面语言", model.settings.interfaceLanguage.autonym),
            ("城市显示语言", L10n.string("跟随界面", locale: locale)),
            ("小时制", L10n.string("24 小时", locale: locale)),
            ("字体", L10n.string("默认", locale: locale)),
            ("字重", L10n.string("常规", locale: locale)),
            ("文字大小", L10n.string(model.settings.textSize == .standard ? "标准" : model.settings.textSize == .large ? "大" : "更大", locale: locale)),
            ("醒着时段开始", ClockText.minute(model.settings.awakeWindow.startMinute, hourStyle: model.settings.hourStyle)),
            ("醒着时段结束", ClockText.minute(model.settings.awakeWindow.endMinute, hourStyle: model.settings.hourStyle))
        ]
        return Dictionary(uniqueKeysWithValues: values.map { (L10n.string($0.0, locale: locale), $0.1) })
    }

    private struct PopupReferenceRoot: View {
        let model: AppModel
        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                GeneralSettingsView()
                ForEach(Self.names(model), id: \.self) { name in
                    Text(verbatim: SettingsScrollReviewTests.popupValues(model)[name]!)
                        .appFont(.body).fixedSize()
                        .accessibilityIdentifier("popup-reference-" + name)
                        .padding(.leading, 8)
                }
            }
            .padding(8)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(model).environment(model.core)
            .environment(\.locale, model.uiLocale)
            .environment(\.textScale, model.settings.textSize.scale)
        }
        private static func names(_ model: AppModel) -> [String] {
            SettingsScrollReviewTests.popupValues(model).keys.sorted()
        }
    }

    private static func drawnPopupFontsRestore(model: AppModel) async throws {
        model.settings.hourStyle = .force24
        model.settings.fontDesign = .system
        model.settings.weight = .regular
        model.settings.cityLanguage = .followInterface
        let host = NSHostingView(rootView: PopupReferenceRoot(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SettingsRootView.width, height: 1700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        TestHostWindowPolicy.prepare(window)
        window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        let previousAX = enhancedAccessibilityValue()
        setEnhancedAccessibility(true)
        defer { setEnhancedAccessibility(previousAX) }
        var baseline: [String: NSSize] = [:]
        for (stage, size) in [("standard-start", TextSize.standard), ("larger", .larger),
                              ("large", .large), ("standard-restored", .standard)] {
            model.settings.textSize = size
            try await Task.sleep(for: .milliseconds(400))
            host.layoutSubtreeIfNeeded()
            let bitmap = try lightBitmap(host, window: window)
            let nodes = popupElements(in: host)
            let popups = nodes.filter { $0.role == "AXPopUpButton" }
            let expected = popupValues(model)
            #expect(popups.count == 8)
            #expect(Set(popups.map(\.name)) == Set(expected.keys))
            for popup in popups {
                let value = try #require(expected[popup.name])
                #expect(popup.enabled)
                #expect(popup.value == value)
                #expect(bitmap.contentRect.insetBy(dx: -0.5, dy: -0.5).contains(popup.frame))
                let reference = try #require(nodes.first { $0.identifier == "popup-reference-" + popup.name })
                // 右侧的原生箭头不属于文字取样区。
                let textFrame = NSRect(x: popup.frame.minX, y: popup.frame.minY,
                                       width: popup.frame.width - 22, height: popup.frame.height)
                let actual = try glyphBounds(DrawnButton(name: popup.name, value: value, frame: textFrame), bitmap: bitmap)
                let wanted = try glyphBounds(DrawnButton(name: popup.name, value: value,
                                                         frame: reference.frame.insetBy(dx: -3, dy: -3)), bitmap: bitmap)
                let points = AppFont.size(.body) * size.scale
                #expect(abs(actual.height - wanted.height) <= 1)
                #expect(abs(actual.width - wanted.width) * points / wanted.width <= 1,
                        "选中值必须按正文目标字号完整绘制")
                if stage == "standard-start" { baseline[popup.name] = actual.size }
                // 文字大小这一项会随档位改标题，其余七项可以直接比实际墨迹。
                if popup.name != L10n.string("文字大小", locale: model.uiLocale) {
                    let original = try #require(baseline[popup.name])
                    if size == .standard {
                        #expect(abs(actual.width - original.width) <= 0.5 && abs(actual.height - original.height) <= 0.5)
                    } else {
                        #expect(actual.height > original.height)
                    }
                }
                print("SETTINGS_POPUP_INK \(stage) \(popup.name) value=\(value) actual=\(actual.size) reference=\(wanted.size)")
            }
        }
    }

    private struct PopupElement {
        let role: String
        let name: String
        let value: String?
        let identifier: String
        let frame: NSRect
        let enabled: Bool
    }

    private static func popupElements(in root: NSView) -> [PopupElement] {
        var visited = Set<ObjectIdentifier>()
        var result: [PopupElement] = []
        func text(_ object: NSObject) -> String {
            for key in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"] {
                if let value = axAttribute(object, key) as? String, !value.isEmpty { return value }
            }
            return ""
        }
        func visit(_ object: NSObject, depth: Int) {
            guard depth < 48, visited.count < 10_000, visited.insert(ObjectIdentifier(object)).inserted else { return }
            if let role = axAttribute(object, "accessibilityRole") as? String {
                var name = (axAttribute(object, "accessibilityLabel") as? String) ?? ""
                if name.isEmpty, let label = axAttribute(object, "accessibilityTitleUIElement") as? NSObject {
                    name = text(label)
                }
                result.append(PopupElement(role: role, name: name,
                    value: axAttribute(object, "accessibilityValue") as? String,
                    identifier: axAttribute(object, "accessibilityIdentifier") as? String ?? "",
                    frame: (axAttribute(object, "accessibilityFrame") as? NSValue)?.rectValue ?? .zero,
                    enabled: axAttribute(object, "accessibilityEnabled") as? Bool ?? false))
            }
            for case let child as NSObject in (axAttribute(object, "accessibilityChildren") as? [Any]) ?? [] {
                visit(child, depth: depth + 1)
            }
        }
        visit(root, depth: 0)
        return result
    }

    private struct LiveSettingsRoot: View {
        let model: AppModel
        let tab: SettingsRootView.Tab

        var body: some View {
            SettingsRootView(tab: tab)
                .environment(model).environment(model.core)
                .environment(\.locale, model.uiLocale)
                .environment(\.textScale, model.settings.textSize.scale)
        }
    }

    private static func nativePopups(in view: NSView) -> [NSControl] {
        guard !view.isHiddenOrHasHiddenAncestor else { return [] }
        var controls: [NSControl] = []
        if let popup = view as? NSControl,
           popup.cell is NSPopUpButtonCell,
           popup.frame.width > 0, popup.frame.height > 0 { controls.append(popup) }
        return controls + view.subviews.flatMap { nativePopups(in: $0) }
    }

    private struct DrawnButton {
        let name: String
        let value: String?
        let frame: NSRect
    }

    private struct ButtonBitmap {
        let image: NSBitmapImageRep
        let contentRect: NSRect
        let scale: CGFloat
    }

    // The same guarded public getters as AccessibilityDump: SwiftUI nodes do not advertise
    // NSAccessibility to a Swift protocol cast. No private view/font API is used.
    private static func axAttribute(_ object: NSObject, _ key: String) -> Any? {
        let isForm = "is" + key.prefix(1).uppercased() + key.dropFirst()
        var modern: Any?
        if object.responds(to: Selector(key)) || object.responds(to: Selector(isForm)) {
            modern = object.value(forKey: key)
            if key != "accessibilityChildren" || !((modern as? [Any])?.isEmpty ?? true) { return modern }
        }
        let legacy = ["accessibilityChildren": "AXChildren", "accessibilityRole": "AXRole",
                      "accessibilityLabel": "AXDescription", "accessibilityTitle": "AXTitle",
                      "accessibilityValue": "AXValue"][key]
        guard let legacy, object.responds(to: NSSelectorFromString("accessibilityAttributeValue:")) else { return modern }
        return object.perform(NSSelectorFromString("accessibilityAttributeValue:"), with: legacy)?.takeUnretainedValue() ?? modern
    }

    private static func enhancedAccessibilityValue() -> Bool {
        let app = NSApp as NSObject
        if app.responds(to: NSSelectorFromString("accessibilityEnhancedUserInterface")),
           let value = app.value(forKey: "accessibilityEnhancedUserInterface") as? Bool { return value }
        if app.responds(to: NSSelectorFromString("accessibilityAttributeValue:")),
           let value = app.perform(NSSelectorFromString("accessibilityAttributeValue:"), with: "AXEnhancedUserInterface")?.takeUnretainedValue() as? Bool { return value }
        return false
    }

    private static func setEnhancedAccessibility(_ value: Bool) {
        let app = NSApp as NSObject
        if app.responds(to: NSSelectorFromString("setAccessibilityEnhancedUserInterface:")) {
            app.setValue(value, forKey: "accessibilityEnhancedUserInterface")
        }
        if app.responds(to: NSSelectorFromString("accessibilitySetValue:forAttribute:")) {
            _ = app.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: value), with: "AXEnhancedUserInterface")
        }
    }

    private static func accessibilityButtons(in root: NSView) -> [DrawnButton] {
        var visited = Set<ObjectIdentifier>()
        var buttons: [DrawnButton] = []
        func visit(_ object: NSObject, depth: Int) {
            guard depth < 48, visited.count < 10_000, visited.insert(ObjectIdentifier(object)).inserted else { return }
            if axAttribute(object, "accessibilityRole") as? String == "AXButton" {
                let name = (axAttribute(object, "accessibilityLabel") as? String)
                    ?? (axAttribute(object, "accessibilityTitle") as? String) ?? ""
                let value = axAttribute(object, "accessibilityValue") as? String
                let frame: NSRect
                if let rect = axAttribute(object, "accessibilityFrame") as? NSValue {
                    frame = rect.rectValue
                } else if object.responds(to: NSSelectorFromString("accessibilityAttributeValue:")),
                          let position = object.perform(NSSelectorFromString("accessibilityAttributeValue:"), with: "AXPosition")?.takeUnretainedValue() as? NSValue,
                          let size = object.perform(NSSelectorFromString("accessibilityAttributeValue:"), with: "AXSize")?.takeUnretainedValue() as? NSValue {
                    frame = NSRect(origin: position.pointValue, size: size.sizeValue)
                } else { frame = .zero }
                buttons.append(DrawnButton(name: name, value: value, frame: frame))
            }
            for case let child as NSObject in (axAttribute(object, "accessibilityChildren") as? [Any]) ?? [] {
                visit(child, depth: depth + 1)
            }
        }
        visit(root, depth: 0)
        return buttons
    }

    private static func lightBitmap<Content: View>(_ host: NSHostingView<Content>, window: NSWindow) throws -> ButtonBitmap {
        window.appearance = NSAppearance(named: .aqua)
        host.layoutSubtreeIfNeeded()
        host.needsDisplay = true
        window.displayIfNeeded()
        let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.effectiveAppearance.performAsCurrentDrawingAppearance {
            host.cacheDisplay(in: host.bounds, to: image)
        }
        let scale = CGFloat(image.pixelsWide) / host.bounds.width
        try #require(scale > 0 && scale.isFinite)
        return ButtonBitmap(image: image, contentRect: window.convertToScreen(host.convert(host.bounds, to: nil)), scale: scale)
    }

    private static func glyphBounds(_ button: DrawnButton, bitmap: ButtonBitmap) throws -> NSRect {
        let frame = button.frame
        try #require(frame.origin.x.isFinite && frame.origin.y.isFinite && frame.width.isFinite && frame.height.isFinite)
        try #require(frame.width > 4 && frame.height > 4)
        #expect(bitmap.contentRect.insetBy(dx: -0.5, dy: -0.5).contains(frame), "按钮必须完整显示在实际宿主中")
        // Exclude the native bezel; neutral dark ink excludes blue focus rings in forced Aqua.
        let inner = frame.insetBy(dx: 2, dy: 2)
        let minX = max(0, Int(ceil((inner.minX - bitmap.contentRect.minX) * bitmap.scale)))
        let maxX = min(bitmap.image.pixelsWide - 1, Int(floor((inner.maxX - bitmap.contentRect.minX) * bitmap.scale)))
        let minY = max(0, Int(ceil(CGFloat(bitmap.image.pixelsHigh) - (inner.maxY - bitmap.contentRect.minY) * bitmap.scale)))
        let maxY = min(bitmap.image.pixelsHigh - 1, Int(floor(CGFloat(bitmap.image.pixelsHigh) - (inner.minY - bitmap.contentRect.minY) * bitmap.scale)))
        try #require(minX < maxX && minY < maxY, "实际按钮必须有可取样的像素区域")
        var ink: NSRect?
        for y in minY...maxY {
            for x in minX...maxX {
                guard let color = bitmap.image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let alpha = color.alphaComponent
                let red = color.redComponent * alpha + 1 - alpha
                let green = color.greenComponent * alpha + 1 - alpha
                let blue = color.blueComponent * alpha + 1 - alpha
                let luma = 0.2126 * red + 0.7152 * green + 0.0722 * blue
                guard luma < 0.45, max(red, green, blue) - min(red, green, blue) < 0.12 else { continue }
                let pixel = NSRect(x: x, y: y, width: 1, height: 1)
                ink = ink.map { $0.union(pixel) } ?? pixel
            }
        }
        let pixels = try #require(ink, "必须在实际按钮区域中取得标题字形，空像素不能通过")
        #expect(pixels.minX > CGFloat(minX) && pixels.maxX < CGFloat(maxX + 1)
                && pixels.minY > CGFloat(minY) && pixels.maxY < CGFloat(maxY + 1),
                "完整标题字形不得碰到取样边界")
        return NSRect(x: pixels.minX / bitmap.scale, y: pixels.minY / bitmap.scale,
                      width: pixels.width / bitmap.scale, height: pixels.height / bitmap.scale)
    }

    private static func nativeLogicalName(_ control: NSControl) -> String? {
        if let name = accessibilityText(control, attributes: ["accessibilityLabel", "accessibilityTitle"]) {
            return name
        }
        let titleSelector = NSSelectorFromString("accessibilityTitleUIElement")
        if control.responds(to: titleSelector),
           let title = control.perform(titleSelector)?.takeUnretainedValue() as? NSObject,
           let name = accessibilityText(title, attributes: ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"]) {
            return name
        }
        return nil
    }

    private static func accessibilityText(_ object: NSObject, attributes: [String]) -> String? {
        for attribute in attributes {
            let selector = NSSelectorFromString(attribute)
            if object.responds(to: selector),
               let text = object.perform(selector)?.takeUnretainedValue() as? String,
               !text.isEmpty { return text }
        }
        return nil
    }

    private static func captureDirectory(page: Page, language: InterfaceLanguage, kind: String = "scroll") throws -> URL? {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MEANTIME_SETTINGS_SCROLL_OUT"] == "1"
                || environment["TEST_RUNNER_MEANTIME_SETTINGS_SCROLL_OUT"] == "1" else { return nil }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("settings-\(kind)-review-\(page.rawValue)-\(language.rawValue)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        print("\(kind == "scroll" ? "SETTINGS_SCROLL_REVIEW_DIR" : "SETTINGS_FONT_RESTORE_DIR")=\(directory.path)")
        return directory
    }

    private static func capture<Content: View>(_ host: NSHostingView<Content>, window: NSWindow,
                                               position: String, directory: URL) async throws {
        let originalAppearance = window.appearance
        defer { window.appearance = originalAppearance }
        for (shade, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            host.needsDisplay = true
            window.displayIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("\(position)-\(shade).png"))
        }
    }

    private static func scroll(_ view: NSScrollView, pixels: Int32) throws {
        let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                        wheelCount: 1, wheel1: pixels, wheel2: 0, wheel3: 0))
        view.scrollWheel(with: try #require(NSEvent(cgEvent: event)))
    }

    private static func visibleForm(in view: NSView) -> NSScrollView? {
        guard !view.isHiddenOrHasHiddenAncestor else { return nil }
        if let scroll = view as? NSScrollView, scroll.frame.width > 0, scroll.frame.height > 0 {
            return scroll
        }
        return view.subviews.lazy.compactMap { visibleForm(in: $0) }.first
    }
}
