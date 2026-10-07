// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI
import Testing
@testable import TahoeTime

@Suite(.serialized)
@MainActor
struct EpigraphAccessibilityTests {
    @Test(arguments: ["zh-Hans", "zh-Hant", "en"])
    func spokenTextFrameMatchesTheLetteringColumn(language: String) async throws {
        let size = CGSize(width: 512, height: 196)
        let instant = Date(timeIntervalSince1970: 1_791_003_600)
        let locale = Locale(identifier: language)
        let setting = Epigraph.setting(locale: locale, scale: size.width / 1200)
        let original = MapEpigraph.placement(instant: instant, size: size,
            latitudes: WorldMapScene.standard, locale: locale).box
        for avoidingPoint in [nil, CGPoint(x: original.midX, y: original.midY)] as [CGPoint?] {
            let box = MapEpigraph.placement(instant: instant, size: size,
                latitudes: WorldMapScene.standard, locale: locale, avoidingPoint: avoidingPoint).box
            let host = NSHostingView(rootView: MapEpigraph(instant: instant, size: size,
                latitudes: WorldMapScene.standard, locale: locale, avoidingPoint: avoidingPoint))
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            TestHostWindowPolicy.prepare(window)
            window.orderBack(nil)
            defer { window.orderOut(nil); window.contentView = nil; window.close() }
            let app = NSApp as NSObject
            let previousAX = attribute(app, "accessibilityEnhancedUserInterface") as? Bool ?? false
            setEnhancedAccessibility(true)
            defer { setEnhancedAccessibility(previousAX) }
            try await Task.sleep(for: .milliseconds(250))
            host.layoutSubtreeIfNeeded()
            let matches = textElements(in: host, text: setting.text)
            try #require(matches.count == 1)
            let frame = try #require((attribute(matches[0], "accessibilityFrame") as? NSValue)?.rectValue)
            let local = CGRect(x: box.minX, y: host.isFlipped ? box.minY : size.height - box.maxY,
                width: box.width, height: box.height)
            let expected = window.convertToScreen(host.convert(local, to: nil))
            #expect(abs(frame.minX - expected.minX) <= 0.5)
            #expect(abs(frame.minY - expected.minY) <= 0.5)
            #expect(abs(frame.width - expected.width) <= 0.5)
            #expect(abs(frame.height - expected.height) <= 0.5)
            #expect(frame.width < size.width && frame.height < size.height)
            print("EPIGRAPH_AX_FRAME language=\(language) avoiding=\(avoidingPoint != nil) actual=\(frame) lettering=\(expected) map=\(size)")
        }
    }

    private func attribute(_ object: NSObject, _ key: String) -> Any? {
        let alternate = "is" + key.prefix(1).uppercased() + key.dropFirst()
        guard object.responds(to: NSSelectorFromString(key))
            || object.responds(to: NSSelectorFromString(alternate)) else { return nil }
        return object.value(forKey: key)
    }

    private func setEnhancedAccessibility(_ value: Bool) {
        let app = NSApp as NSObject
        if app.responds(to: NSSelectorFromString("setAccessibilityEnhancedUserInterface:")) {
            app.setValue(value, forKey: "accessibilityEnhancedUserInterface")
        }
        if app.responds(to: NSSelectorFromString("accessibilitySetValue:forAttribute:")) {
            _ = app.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"),
                with: NSNumber(value: value), with: "AXEnhancedUserInterface")
        }
    }

    private func textElements(in root: NSObject, text: String) -> [NSObject] {
        var visited = Set<ObjectIdentifier>()
        var matches: [NSObject] = []
        func visit(_ object: NSObject, depth: Int) {
            guard depth < 48, visited.insert(ObjectIdentifier(object)).inserted else { return }
            if attribute(object, "accessibilityRole") as? String == "AXStaticText",
               ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].contains(where: {
                   attribute(object, $0) as? String == text
               }) {
                matches.append(object)
            }
            for case let child as NSObject in (attribute(object, "accessibilityChildren") as? [Any]) ?? [] {
                visit(child, depth: depth + 1)
            }
        }
        visit(root, depth: 0)
        return matches
    }
}
