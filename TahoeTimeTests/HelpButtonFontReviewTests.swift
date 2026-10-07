// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI
import Testing
@testable import TahoeTime

@Suite(.serialized)
@MainActor
struct HelpButtonFontReviewTests {
    @Test(arguments: [InterfaceLanguage.zhHans, .en, .ru, .de, .ja])
    func diagnosticTitlesMatchBodyAndRestore(language: InterfaceLanguage) async throws {
        let (defaults, cleanup) = TestDefaults.make(prefix: "help-button-font-review")
        defer { cleanup() }
        let model = AppModel(defaults: defaults, migrate: false, applySystemIntegration: false)
        model.settings.interfaceLanguage = language
        let names = ["导出诊断包…", "复制诊断摘要"].map { L10n.string($0, locale: model.uiLocale) }
        let host = NSHostingView(rootView: ReferenceRoot(model: model, names: names))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SettingsRootView.width, height: 1_700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        TestHostWindowPolicy.prepare(window)
        window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        TestHostWindowPolicy.validateVisibleWindows(phase: "help-button-font-review")
        let previousAX = Self.attribute(NSApp, "accessibilityEnhancedUserInterface") as? Bool ?? false
        Self.enhanceAccessibility(true)
        defer { Self.enhanceAccessibility(previousAX) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("help-button-font-review-\(language.rawValue)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        print("HELP_BUTTON_FONT_REVIEW_DIR=\(directory.path)")
        var baseline: [String: NSSize] = [:]
        let stages: [(String, TextSize)] = [
            ("standard-start", .standard), ("larger", .larger),
            ("large", .large), ("standard-restored", .standard)
        ]
        for (stage, size) in stages {
            model.settings.textSize = size
            try await Task.sleep(for: .milliseconds(400))
            host.layoutSubtreeIfNeeded()
            host.needsDisplay = true
            window.displayIfNeeded()
            let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.effectiveAppearance.performAsCurrentDrawingAppearance {
                host.cacheDisplay(in: host.bounds, to: image)
            }
            let png = try #require(image.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("\(stage)-light.png"))
            let scale = CGFloat(image.pixelsWide) / host.bounds.width
            try #require(scale.isFinite && scale > 0)
            let content = window.convertToScreen(host.convert(host.bounds, to: nil))
            let elements = Self.elements(in: host)
            for (index, name) in names.enumerated() {
                let button = try #require(elements.first { $0.role == "AXButton" && $0.text == name },
                                          "必须找到真实诊断按钮")
                let reference = try #require(elements.first { $0.identifier == "help-body-reference-\(index)" },
                                             "必须找到同文的正文参照")
                let actual = try Self.ink(in: button.frame, image: image, content: content, scale: scale, button: true)
                let expected = try Self.ink(in: reference.frame, image: image, content: content, scale: scale, button: false)
                #expect(abs(actual.height - expected.height) <= 1,
                        "按钮标题与同文正文的真实字形高度差不能超过一点")
                let bodyFont = NSFont.preferredFont(forTextStyle: .body)
                    .withSize(AppFont.size(.body) * size.scale)
                let widthPointDelta = abs(actual.width - expected.width) * bodyFont.pointSize / expected.width
                #expect(widthPointDelta <= 1,
                        "同文标题的墨迹宽度差对应的字号差不能超过一点，截字不能通过")
                let nativeFonts = Self.nativeTitleFonts(named: name, matching: button.frame, in: host)
                for font in nativeFonts {
                    #expect(abs(font.pointSize - bodyFont.pointSize) <= 1,
                            "原生按钮实际标题字体与周围正文字号差不能超过一点")
                }
                let required = (name as NSString).size(withAttributes: [.font: bodyFont])
                #expect(required.width <= button.frame.width + 0.5 && required.height <= button.frame.height + 0.5,
                        "正文目标字号的完整标题必须装进实际按钮")
                if stage == "standard-start" { baseline[name] = actual.size }
                let original = try #require(baseline[name])
                if size == .standard {
                    #expect(abs(actual.height - original.height) <= 0.5 && abs(actual.width - original.width) <= 0.5,
                            "恢复标准档必须还原实际绘制的标题")
                } else {
                    #expect(actual.height > original.height, "大字档的实际标题必须增大")
                }
                print("HELP_BUTTON_FONT_REVIEW\t\(language.rawValue)\t\(stage)\t\(index)\tbody=\(bodyFont.pointSize)\tbuttonInk=\(actual.height)\tbodyInk=\(expected.height)\tbuttonInkWidth=\(actual.width)\tbodyInkWidth=\(expected.width)\twidthPointDelta=\(widthPointDelta)\tnativeTitlePoints=\(nativeFonts.map(\.pointSize))\tframe=\(button.frame)")
            }
        }
    }

    private struct ReferenceRoot: View {
        let model: AppModel
        let names: [String]

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                HelpSettingsView()
                ForEach(names.indices, id: \.self) { index in
                    Text(verbatim: names[index])
                        .appFont(.body)
                        .fixedSize()
                        .accessibilityIdentifier("help-body-reference-\(index)")
                }
            }
            .padding(.bottom, 12)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(model).environment(model.core)
            .environment(\.locale, model.uiLocale)
            .environment(\.textScale, model.settings.textSize.scale)
        }
    }

    private struct Element {
        let role: String
        let text: String
        let identifier: String
        let frame: NSRect
    }

    private static func nativeTitleFonts(named name: String, matching frame: NSRect, in view: NSView) -> [NSFont] {
        guard !view.isHiddenOrHasHiddenAncestor else { return [] }
        if let button = view as? NSButton, button.title == name, let window = button.window {
            let actualFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
            if abs(actualFrame.minX - frame.minX) <= 1, abs(actualFrame.minY - frame.minY) <= 1,
               abs(actualFrame.width - frame.width) <= 1, abs(actualFrame.height - frame.height) <= 1 {
                var fonts: [NSFont] = []
                let title = button.attributedTitle
                title.enumerateAttribute(.font, in: NSRange(location: 0, length: title.length)) { value, _, _ in
                    if let font = value as? NSFont { fonts.append(font) }
                }
                if fonts.isEmpty, let font = button.font { fonts.append(font) }
                return fonts
            }
        }
        return view.subviews.flatMap { nativeTitleFonts(named: name, matching: frame, in: $0) }
    }

    private static func attribute(_ object: NSObject, _ key: String) -> Any? {
        let alternate = "is" + key.prefix(1).uppercased() + key.dropFirst()
        if object.responds(to: NSSelectorFromString(key)) || object.responds(to: NSSelectorFromString(alternate)) {
            let value = object.value(forKey: key)
            if key != "accessibilityChildren" || !((value as? [Any])?.isEmpty ?? true) { return value }
        }
        let legacy = ["accessibilityChildren": "AXChildren", "accessibilityRole": "AXRole",
                      "accessibilityLabel": "AXDescription", "accessibilityTitle": "AXTitle",
                      "accessibilityValue": "AXValue", "accessibilityIdentifier": "AXIdentifier",
                      "accessibilityEnhancedUserInterface": "AXEnhancedUserInterface"][key]
        guard let legacy, object.responds(to: NSSelectorFromString("accessibilityAttributeValue:")) else { return nil }
        return object.perform(NSSelectorFromString("accessibilityAttributeValue:"), with: legacy)?.takeUnretainedValue()
    }

    private static func enhanceAccessibility(_ value: Bool) {
        let app = NSApp as NSObject
        if app.responds(to: NSSelectorFromString("setAccessibilityEnhancedUserInterface:")) {
            app.setValue(value, forKey: "accessibilityEnhancedUserInterface")
        }
        if app.responds(to: NSSelectorFromString("accessibilitySetValue:forAttribute:")) {
            _ = app.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"),
                            with: NSNumber(value: value), with: "AXEnhancedUserInterface")
        }
    }

    private static func elements(in root: NSView) -> [Element] {
        var visited = Set<ObjectIdentifier>()
        var result: [Element] = []
        func visit(_ object: NSObject, depth: Int) {
            guard depth < 48, visited.count < 10_000, visited.insert(ObjectIdentifier(object)).inserted else { return }
            if let role = attribute(object, "accessibilityRole") as? String {
                let text = (attribute(object, "accessibilityLabel") as? String)
                    ?? (attribute(object, "accessibilityTitle") as? String)
                    ?? (attribute(object, "accessibilityValue") as? String) ?? ""
                let identifier = attribute(object, "accessibilityIdentifier") as? String ?? ""
                let frame = (attribute(object, "accessibilityFrame") as? NSValue)?.rectValue ?? .zero
                result.append(Element(role: role, text: text, identifier: identifier, frame: frame))
            }
            for case let child as NSObject in (attribute(object, "accessibilityChildren") as? [Any]) ?? [] {
                visit(child, depth: depth + 1)
            }
        }
        visit(root, depth: 0)
        return result
    }

    private static func ink(in frame: NSRect, image: NSBitmapImageRep, content: NSRect,
                            scale: CGFloat, button: Bool) throws -> NSRect {
        try #require([frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite)
                     && frame.width > 4 && frame.height > 4)
        #expect(content.insetBy(dx: -0.5, dy: -0.5).contains(frame), "标题及参照必须完整显示")
        // 原生按钮边框不计入文字像素；正文完整取样。
        let inner = button ? frame.insetBy(dx: 2, dy: 2) : frame
        let minX = max(0, Int(ceil((inner.minX - content.minX) * scale)))
        let maxX = min(image.pixelsWide - 1, Int(floor((inner.maxX - content.minX) * scale)))
        let minY = max(0, Int(ceil(CGFloat(image.pixelsHigh) - (inner.maxY - content.minY) * scale)))
        let maxY = min(image.pixelsHigh - 1, Int(floor(CGFloat(image.pixelsHigh) - (inner.minY - content.minY) * scale)))
        try #require(minX < maxX && minY < maxY)
        var ink: NSRect?
        for y in minY...maxY {
            for x in minX...maxX {
                guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let alpha = color.alphaComponent
                let red = color.redComponent * alpha + 1 - alpha
                let green = color.greenComponent * alpha + 1 - alpha
                let blue = color.blueComponent * alpha + 1 - alpha
                guard 0.2126 * red + 0.7152 * green + 0.0722 * blue < 0.45,
                      max(red, green, blue) - min(red, green, blue) < 0.12 else { continue }
                let pixel = NSRect(x: x, y: y, width: 1, height: 1)
                ink = ink.map { $0.union(pixel) } ?? pixel
            }
        }
        let pixels = try #require(ink, "空白像素不能证明字号正确")
        if button {
            #expect(pixels.minX > CGFloat(minX) && pixels.maxX < CGFloat(maxX + 1)
                    && pixels.minY > CGFloat(minY) && pixels.maxY < CGFloat(maxY + 1),
                    "完整标题字形不得碰到取样边界")
        }
        return NSRect(x: pixels.minX / scale, y: pixels.minY / scale,
                      width: pixels.width / scale, height: pixels.height / scale)
    }
}
