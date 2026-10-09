// SPDX-License-Identifier: GPL-3.0-only
#if DEBUG
import AppKit
import Foundation
import Observation
import SwiftUI

/// 仅转储夹具：按捕获批次重画原有外观，不增加生产视图节点。
@MainActor @Observable
final class AXCaptureAppearance {
    static let shared = AXCaptureAppearance()
    var scheme: ColorScheme?

    static var isForced: Bool {
        AccessibilityDump.isRequested && ProcessInfo.processInfo.environment["MEANTIME_AX_APPEARANCE_POLICY"] == "forced-native"
    }
}

/// Debug-only, behind the UI-test fixture: the app walks the accessibility tree of its own tools
/// window in-process (the NSAccessibility protocol is exactly what VoiceOver reads through the AX
/// API) and writes it as JSON, then quits. Needs no UI-automation mode or automation permission, so
/// it runs unattended where XCUITest's audit cannot. `Tools/ax_check.py` applies the rules.
@MainActor
enum AccessibilityDump {
    static var isRequested: Bool {
        ApplicationSession.isTesting && ProcessInfo.processInfo.environment["MEANTIME_AX_DUMP"] == "1"
    }

    static var requestedScrollFraction: CGFloat? {
        guard ApplicationSession.isTesting else { return nil }
        let key = isRequested ? "MEANTIME_AX_SCROLL_FRACTION" : "MEANTIME_UI_TEST_SCROLL_FRACTION"
        guard let raw = ProcessInfo.processInfo.environment[key],
              let fraction = Double(raw), fraction.isFinite, (0...1).contains(fraction) else { return nil }
        return CGFloat(fraction)
    }

    // 正文把原生滚动代理交给转储，等布局停稳后再调用。
    static var scrollDetail: ((CGFloat) -> Void)?

    /// `minimumViews`：视图层级至少这么多个 NSView 才算「页面建好了」（工具页 25；欢迎页的宿主只有 7 个 NSView，传 4）。
    static func scheduleIfRequested(name: String, windowPrefix: String, minimumViews: Int = 25) {
        guard isRequested else { return }
        if ProcessInfo.processInfo.environment["MEANTIME_AX_NATIVE_CAPTURE"] == "1",
           !ApplicationSession.uiTestForeground {
            FileHandle.standardError.write(Data("DEFERRED: native AX capture requires MEANTIME_UI_TEST_FOREGROUND=1\n".utf8))
            exit(75)
        }
        Task { @MainActor in
            // Asking the hosting view for accessibility children before SwiftUI has attached the page
            // caches an empty list for the life of the window, so wait on the plain view hierarchy
            // (no accessibility calls) until the page's views exist, then walk exactly once.
            let started = Date()
            var window: NSWindow?
            var nodes: [[String: Any]] = []
            var scrollApplied = false
            while Date().timeIntervalSince(started) < 25 {
                try? await Task.sleep(for: .milliseconds(400))
                window = NSApp.windows.first { ($0.identifier?.rawValue ?? "").hasPrefix(windowPrefix) }
                    ?? NSApp.windows.filter { $0.isVisible && !($0 is NSPanel) }
                        .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
                guard let window, window.isVisible, viewCount(window.contentView) >= minimumViews else { continue }
                try? await Task.sleep(for: .seconds(1))
                _ = await waitForStillLayout(window)
                if let fraction = requestedScrollFraction, let scrollDetail {
                    scrollDetail(fraction)
                    scrollApplied = true
                    _ = await waitForStillLayout(window)
                }
                // Switching the flag on while the window is still being built disturbed the sidebar
                // selection once (the agenda launch dumped the DST page), so it is set only now.
                enableAccessibility()
                try? await Task.sleep(for: .milliseconds(300))
                walk(window, depth: 0, into: &nodes)
                break
            }
            // Probe: which entry points still answer on the hosting view when the modern one is empty.
            var probe: [String: Any] = [:]
            if let window, let hosting = window.contentView?.subviews.first(where: { String(describing: type(of: $0)).contains("HostingView") }) ?? window.contentView {
                probe["class"] = String(describing: type(of: hosting))
                probe["modern"] = (hosting.accessibilityChildren() ?? []).count
                probe["navigationOrder"] = (hosting.accessibilityChildrenInNavigationOrder() ?? []).count
                probe["visible"] = (hosting.accessibilityVisibleChildren() ?? []).count
                probe["contents"] = (hosting.accessibilityContents() ?? []).count
                if hosting.responds(to: NSSelectorFromString("accessibilityAttributeValue:")) {
                    let legacy = hosting.perform(NSSelectorFromString("accessibilityAttributeValue:"), with: "AXChildren")?.takeUnretainedValue() as? [Any]
                    probe["legacy"] = legacy?.count ?? -1
                }
                probe["subviews"] = viewCount(hosting)
                probe["tableHighlights"] = tableHighlights(in: hosting)
                probe["voiceOver"] = NSWorkspace.shared.isVoiceOverEnabled
                probe["accessibilityElement"] = hosting.isAccessibilityElement()
                probe["axEnhanced"] = ((NSApp as NSObject).value(forKey: "accessibilityEnhancedUserInterface") as? Bool) ?? false
            }
            // 带 pid：同 bundle id 的两份副本共用一个沙盒容器的 tmp，两个会话同时转储时同名文件会互相覆盖
            // 另一份副本的窗口可能盖掉当前页面，造成转储取错窗口。
            let stem = "dayside-ax-\(name)-\(ProcessInfo.processInfo.processIdentifier)"
            var output: [String: Any] = ["page": name, "nodeCount": nodes.count, "probe": probe,
                                         "settledAfterSeconds": (Date().timeIntervalSince(started) * 10).rounded() / 10]
            if let fraction = requestedScrollFraction {
                output["scrollRequestedFraction"] = fraction
                output["scrollApplied"] = scrollApplied
            }
            if let window {
                let previousAppAppearance = NSApp.appearance
                let previousWindowAppearance = window.appearance
                let previousCaptureScheme = AXCaptureAppearance.shared.scheme
                defer {
                    AXCaptureAppearance.shared.scheme = previousCaptureScheme
                    NSApp.appearance = previousAppAppearance
                    window.appearance = previousWindowAppearance
                }
                output["appearancePolicy"] = AXCaptureAppearance.isForced ? "forced-native" : "production"
                output["window"] = ["title": window.title, "frame": rect(window.frame),
                                    "identifier": window.identifier?.rawValue ?? ""]
                // 页面建好之后才换外观，避免首棵树被缓存成空。
                var images: [String: String] = [:]
                let nativeCapture = ProcessInfo.processInfo.environment["MEANTIME_AX_NATIVE_CAPTURE"] == "1"
                // 禁截图的静默任务设 MEANTIME_AX_SAVE_IMAGES=0：内存渲染与对比度照常，只是不落盘 PNG（默认仍保存）。
                let saveImages = ProcessInfo.processInfo.environment["MEANTIME_AX_SAVE_IMAGES"] != "0"
                output["captureMethod"] = nativeCapture ? "nativeWindow" : "cachedView"
                // 先收掉焦点：聚焦文本框的强调色焦点环会盖住相邻标签的采样框，把「显示名」量成 #418FF8（实证的抖动）。
                window.makeFirstResponder(nil)
                var appearanceNodes: [String: [[String: Any]]] = [:]
                var captures: [String: [String: Any]] = [:]
                var rewalks = 0
                for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
                    // 默认让天色决定控件外观；强制捕获另量原生浅深外观。
                    // 两种捕获都保留天色、文字、内容与选项。
                    output["requestedAppearance_\(name)"] = appearance.rawValue
                    if AXCaptureAppearance.isForced {
                        AXCaptureAppearance.shared.scheme = name == "dark" ? .dark : .light
                    }
                    NSApp.appearance = NSAppearance(named: appearance)
                    window.contentView?.layoutSubtreeIfNeeded()
                    window.contentView?.needsDisplay = true
                    window.displayIfNeeded()
                    try? await Task.sleep(for: .milliseconds(1500))
                    window.displayIfNeeded()
                    let appearanceDeadline = Date().addingTimeInterval(5)
                    @MainActor func matches() -> Bool {
                        window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == appearance &&
                            window.contentView?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == appearance
                    }
                    if AXCaptureAppearance.isForced {
                        while !matches(), Date() < appearanceDeadline {
                            try? await Task.sleep(for: .milliseconds(50))
                            window.contentView?.layoutSubtreeIfNeeded()
                            window.displayIfNeeded()
                        }
                    }
                    output["effectiveAppearance_\(name)"] = window.contentView?.effectiveAppearance.name.rawValue ?? ""
                    output["windowEffectiveAppearance_\(name)"] = window.effectiveAppearance.name.rawValue
                    output["appearanceMatched_\(name)"] = matches()
                    if AXCaptureAppearance.isForced && !matches() {
                        output["appearanceFailure_\(name)"] = "native appearance did not settle before deadline"
                        captures[name] = ["validLayout": false, "reason": "native appearance did not settle before deadline"]
                        continue
                    }
                    var status: [String: Any] = ["validLayout": false, "reason": "layout did not settle"]
                    // 每种外观独立取树，捕获前后核对版面与原生外观。
                    for attempt in 1...3 {
                        status["attempts"] = attempt
                        guard await waitForStillLayout(window) else {
                            rewalks += 1
                            continue
                        }
                        window.contentView?.layoutSubtreeIfNeeded()
                        window.displayIfNeeded()
                        let beforeWalk = layoutFingerprint(window)
                        var fresh: [[String: Any]] = []
                        walk(window, depth: 0, into: &fresh)
                        let beforeRender = layoutFingerprint(window)
                        status["layoutBefore"] = beforeWalk
                        status["layoutBeforeRender"] = beforeRender
                        guard beforeWalk == beforeRender else {
                            rewalks += 1
                            status["reason"] = "layout changed while walking accessibility"
                            continue
                        }
                        let contentAppearance = window.contentView?.effectiveAppearance.name.rawValue ?? ""
                        let windowAppearance = window.effectiveAppearance.name.rawValue
                        let nativePath = nativeCapture ? URL(fileURLWithPath: NSTemporaryDirectory())
                            .appendingPathComponent("\(stem)-\(name)-native-\(UUID().uuidString).png") : nil
                        guard let rendered = await render(window, nativePath: nativePath) else {
                            status["reason"] = "bitmap unavailable"
                            continue
                        }
                        let afterRender = layoutFingerprint(window)
                        var after: [[String: Any]] = []
                        walk(window, depth: 0, into: &after)
                        let afterWalk = layoutFingerprint(window)
                        status["layoutAfterRender"] = afterRender
                        status["layoutAfter"] = afterWalk
                        // 位图若触发布局或滚动，整次作废，不能量旧坐标。
                        guard beforeRender == afterRender, afterRender == afterWalk,
                              let geometry = treeGeometry(fresh), geometry == treeGeometry(after) else {
                            rewalks += 1
                            status["reason"] = "layout changed during bitmap capture"
                            continue
                        }
                        guard contentAppearance == (window.contentView?.effectiveAppearance.name.rawValue ?? ""),
                              windowAppearance == window.effectiveAppearance.name.rawValue,
                              !AXCaptureAppearance.isForced || matches() else {
                            status["reason"] = "native appearance changed during bitmap capture"
                            continue
                        }
                        measureContrast(&fresh, in: rendered, suffix: name)
                        let measured = fresh.filter { $0["contrast_\(name)"] != nil }.count
                        let candidates = fresh.filter { ($0["role"] as? String).map(TEXT_ROLES.contains) ?? false }.count
                        if measured * 3 < candidates, attempt < 3 {
                            status["reason"] = "text rendering incomplete"
                            try? await Task.sleep(for: .milliseconds(1500))
                            continue
                        }
                        if saveImages {
                            let png = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(stem)-\(name).png")
                            do { try rendered.png.write(to: png) } catch {
                                status["reason"] = "PNG write failed"
                                continue
                            }
                            images[name] = png.path
                        }
                        appearanceNodes[name] = fresh
                        status["validLayout"] = true
                        status.removeValue(forKey: "reason")
                        status["layoutBefore"] = beforeWalk
                        status["layoutAfter"] = afterWalk
                        status["windowFrame"] = rect(window.frame)
                        status["contentRect"] = rect(rendered.contentRect)
                        status["scale"] = rendered.scale
                        if let nativePath { output["nativeCaptureSource_\(name)"] = nativePath.path }
                        output["renderBackground_\(name)"] = hex(rendered.background)
                        output["renderBackgroundAppearance_\(name)"] = contentAppearance
                        output["windowEffectiveAppearance_\(name)"] = windowAppearance
                        output["appearanceMatched_\(name)"] = matches()
                        output["renderAttempts_\(name)"] = attempt
                        output["effectiveAppearance_\(name)"] = window.contentView?.effectiveAppearance.name.rawValue ?? ""
                        break
                    }
                    captures[name] = status
                }
                nodes = appearanceNodes["light"] ?? []
                output["nodesByAppearance"] = appearanceNodes
                output["captureByAppearance"] = captures
                output["images"] = images
                output["layoutRewalks"] = rewalks
            }
            output["nodes"] = nodes
            output["nodeCount"] = nodes.count
            if let window {
                output["window"] = ["title": window.title, "frame": rect(window.frame),
                                    "identifier": window.identifier?.rawValue ?? ""]
            }
            let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(stem).json")
            // SwiftUI hands out infinite frames for some zero-size views; JSON refuses non-finite numbers.
            if let data = try? JSONSerialization.data(withJSONObject: sanitize(output), options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: url)
                FileHandle.standardOutput.write(Data("MEANTIME_AX_DUMP_PATH=\(url.path)\n".utf8))
            } else {
                FileHandle.standardOutput.write(Data("MEANTIME_AX_DUMP_FAILED\n".utf8))
            }
            NSApp.terminate(nil)
        }
    }

    struct Rendered {
        let rep: NSBitmapImageRep
        let png: Data
        let contentRect: NSRect  // screen coordinates of the rendered view
        let scale: CGFloat
        let background: NSColor  // what the window paints under transparent pixels
    }

    /// 默认在进程内画视图层级；选用原生截图时，由转储脚本交回完整窗口像素。
    private static func render(_ window: NSWindow, nativePath: URL?) async -> Rendered? {
        if TestHostWindowPolicy.isQuiet && !window.isVisible {
            FileHandle.standardError.write(Data("Quiet AX capture requires an ordered window\n".utf8))
            exit(1)
        }
        TestHostWindowPolicy.validateVisibleWindows(phase: "axCapture")
        if let nativePath {
            FileHandle.standardOutput.write(Data("MEANTIME_AX_CAPTURE_REQUEST=\(window.windowNumber)|\(nativePath.path)\n".utf8))
            let deadline = Date().addingTimeInterval(8)
            var payload: Data?
            while Date() < deadline {
                if let data = try? Data(contentsOf: nativePath), let rep = NSBitmapImageRep(data: data), rep.pixelsWide > 0 {
                    payload = data
                    break
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let payload, let rep = NSBitmapImageRep(data: payload) else { return nil }
            var background = NSColor.white
            (window.contentView?.effectiveAppearance ?? window.effectiveAppearance).performAsCurrentDrawingAppearance {
                background = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? .white
            }
            return Rendered(rep: rep, png: payload, contentRect: window.frame,
                            scale: CGFloat(rep.pixelsWide) / max(window.frame.width, 1), background: background)
        }
        guard var view = window.contentView else { return nil }
        var captureRect = view.bounds
        // 欢迎页的离屏滚动容器不画进祖先缓存，直接画同一正文的可见区域。
        if window.identifier?.rawValue == "welcome" {
            func scrollView(in candidate: NSView) -> NSScrollView? {
                if let scroll = candidate as? NSScrollView { return scroll }
                return candidate.subviews.lazy.compactMap { scrollView(in: $0) }.first
            }
            if let document = scrollView(in: view)?.documentView {
                view = document
                captureRect = document.visibleRect.intersection(document.bounds)
            }
        }
        guard captureRect.width > 0, captureRect.height > 0 else { return nil }
        var result: Rendered?
        // 原生控件与背景用窗口实际外观，保留视图指定的深色。
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            guard var rep = view.bitmapImageRepForCachingDisplay(in: captureRect) else { return }
            view.cacheDisplay(in: captureRect, to: rep)
            let background = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? .white
            if view !== window.contentView {
                guard let canvas = NSBitmapImageRep(bitmapDataPlanes: nil,
                    pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                    let context = NSGraphicsContext(bitmapImageRep: canvas) else { return }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                let pixels = NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh)
                background.setFill()
                pixels.fill()
                rep.draw(in: pixels, from: .zero, operation: .sourceOver, fraction: 1,
                         respectFlipped: false, hints: nil)
                NSGraphicsContext.restoreGraphicsState()
                rep = canvas
            }
            guard let png = rep.representation(using: .png, properties: [:]) else { return }
            let contentRect = window.convertToScreen(view.convert(captureRect, to: nil))
            result = Rendered(rep: rep, png: png, contentRect: contentRect,
                              scale: CGFloat(rep.pixelsWide) / max(captureRect.width, 1), background: background)
        }
        return result
    }

    private static let TEXT_ROLES: Set<String> = ["AXStaticText", "AXHeading", "AXButton", "AXCheckBox", "AXRadioButton",
                                                  "AXLink", "AXPopUpButton", "AXMenuButton"]

    /// Per text element: the most common luminance in its box is the background, the pixel farthest
    /// from it is the ink; WCAG ratio between the two. Anti-aliasing biases this slightly low, so a
    /// pass here is conservative and a fail is worth a look, not a verdict.
    private static func measureContrast(_ nodes: inout [[String: Any]], in rendered: Rendered, suffix: String) {
        let rep = rendered.rep
        let pixelHeight = CGFloat(rep.pixelsHigh)
        // The sidebar pane is a system material the in-process render cannot paint; skip text inside it.
        func frame(ofFirst predicate: ([String: Any]) -> Bool) -> NSRect? {
            nodes.first(where: predicate).flatMap { $0["frame"] as? [String: Double] }
                .map { NSRect(x: $0["x"] ?? 0, y: $0["y"] ?? 0, width: $0["w"] ?? 0, height: $0["h"] ?? 0) }
        }
        let sidebar = frame { ($0["class"] as? String ?? "").contains("SidebarStyleContext") }
        // The toolbar and title bar are not part of the content view, so their pixels are not rendered.
        let toolbar = frame { ($0["role"] as? String) == "AXToolbar" }
        // An element scrolled out of its enclosing scroll view keeps its full frame in the tree but
        // paints nothing there; sampling that spot measures whatever sits behind it (another row, the
        // footer bar) and reports a false failure. Nodes are in pre-order with a depth, so the nearest
        // enclosing scroll area is the top of a depth stack; nested areas intersect.
        var clips = [NSRect?](repeating: nil, count: nodes.count)
        var scrollAreas: [(depth: Int, rect: NSRect)] = []
        for index in nodes.indices {
            let depth = nodes[index]["depth"] as? Int ?? 0
            while let last = scrollAreas.last, last.depth >= depth { scrollAreas.removeLast() }
            clips[index] = scrollAreas.last?.rect
            if (nodes[index]["role"] as? String) == "AXScrollArea", let f = nodes[index]["frame"] as? [String: Double] {
                let rect = NSRect(x: f["x"] ?? 0, y: f["y"] ?? 0, width: f["w"] ?? 0, height: f["h"] ?? 0)
                scrollAreas.append((depth, scrollAreas.last.map { $0.rect.intersection(rect) } ?? rect))
            }
        }
        for index in nodes.indices {
            guard let role = nodes[index]["role"] as? String, TEXT_ROLES.contains(role),
                  !((nodes[index]["class"] as? String) ?? "").contains("Switch"),  // a switch has no text
                  let frame = nodes[index]["frame"] as? [String: Double], let w = frame["w"], let h = frame["h"], w >= 2, h >= 2,
                  let x = frame["x"], let y = frame["y"] else { continue }
            let center = NSPoint(x: x + w / 2, y: y + h / 2)
            if let sidebar, sidebar.contains(center) {
                nodes[index]["contrastSkipped"] = "sidebar material"
                continue
            }
            if let toolbar, toolbar.contains(center) {
                nodes[index]["contrastSkipped"] = "toolbar not rendered"
                continue
            }
            if let clip = clips[index], !clip.contains(center) {
                nodes[index]["contrastSkipped"] = "clipped by scroll view"
                continue
            }
            // Sample the inner part of the box so a chip's own fill, not the page behind it, is the background.
            // 勾选框、单选按钮的框里前 18 pt 是控件自己的方框与对勾（白勾、蓝底或灰底），不是字：只量后面的标签。
            // 底是中间调（光的框）时，白对勾与黑字离底色一样远，「离底色最远的像素」会挑中白对勾，量成 1.9:1。
            let glyph = (role == "AXCheckBox" || role == "AXRadioButton") && w > 30 ? 18.0 : 0
            let insetX = (w - glyph) * 0.12, insetY = h * 0.18
            let localX = (x + glyph + insetX - rendered.contentRect.origin.x) * rendered.scale
            let localBottom = (y + insetY - rendered.contentRect.origin.y) * rendered.scale
            let innerW = (w - glyph - 2 * insetX) * rendered.scale, innerH = (h - 2 * insetY) * rendered.scale
            let px0 = Int(max(0, localX)), px1 = Int(min(CGFloat(rep.pixelsWide), localX + innerW))
            let py0 = Int(max(0, pixelHeight - localBottom - innerH)), py1 = Int(min(pixelHeight, pixelHeight - localBottom))
            guard px1 - px0 >= 2, py1 - py0 >= 2 else {
                nodes[index]["contrastDebug_\(suffix)"] = "outside: px \(px0)-\(px1) py \(py0)-\(py1) local \(Int(localX)),\(Int(localBottom)) rect \(rendered.contentRect)"
                continue
            }
            let stride = max(1, Int(sqrt(Double((px1 - px0) * (py1 - py0)) / 6000)))
            var bins = [Int](repeating: 0, count: 64)
            var samples: [(Double, NSColor)] = []
            var py = py0
            while py < py1 {
                var px = px0
                while px < px1 {
                    if let color = rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB).map({ composite($0, over: rendered.background) }) {
                        let l = luminance(color)
                        bins[min(63, Int(l * 63.999))] += 1
                        samples.append((l, color))
                    }
                    px += stride
                }
                py += stride
            }
            guard !samples.isEmpty, let modeBin = bins.indices.max(by: { bins[$0] < bins[$1] }) else {
                nodes[index]["contrastDebug_\(suffix)"] = "no samples px \(px0)-\(px1) py \(py0)-\(py1)"
                continue
            }
            let background = samples.filter { Int($0.0 * 63.999) == modeBin }
            let bg = background.map(\.0).reduce(0, +) / Double(background.count)
            guard let ink = samples.max(by: { abs($0.0 - bg) < abs($1.0 - bg) }), abs(ink.0 - bg) > 0.02 else {
                nodes[index]["contrastDebug_\(suffix)"] = "flat: \(samples.count) samples bg \(bg) px \(px0)-\(px1) py \(py0)-\(py1)"
                continue
            }
            let ratio = (max(ink.0, bg) + 0.05) / (min(ink.0, bg) + 0.05)
            nodes[index]["contrast_\(suffix)"] = (ratio * 100).rounded() / 100
            nodes[index]["ink_\(suffix)"] = hex(ink.1)
            nodes[index]["background_\(suffix)"] = hex(background.first?.1 ?? ink.1)
        }
    }

    private static func composite(_ color: NSColor, over background: NSColor) -> NSColor {
        let a = color.alphaComponent
        guard a < 0.999 else { return color }
        return NSColor(srgbRed: color.redComponent * a + background.redComponent * (1 - a),
                       green: color.greenComponent * a + background.greenComponent * (1 - a),
                       blue: color.blueComponent * a + background.blueComponent * (1 - a), alpha: 1)
    }

    private static func luminance(_ color: NSColor) -> Double {
        func channel(_ c: CGFloat) -> Double {
            let v = Double(c)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(color.redComponent) + 0.7152 * channel(color.greenComponent) + 0.0722 * channel(color.blueComponent)
    }

    private static func hex(_ color: NSColor) -> String {
        String(format: "#%02X%02X%02X", Int(color.redComponent * 255), Int(color.greenComponent * 255), Int(color.blueComponent * 255))
    }

    /// SwiftUI only materializes its accessibility nodes while the process believes an assistive
    /// client is attached. VoiceOver flips that by setting AXEnhancedUserInterface on the application
    /// element; doing the same in-process (Debug-only tooling) turns it on.
    private static func enableAccessibility() {
        let app = NSApp as NSObject
        if app.responds(to: NSSelectorFromString("setAccessibilityEnhancedUserInterface:")) {
            app.setValue(true, forKey: "accessibilityEnhancedUserInterface")
        }
        if app.responds(to: NSSelectorFromString("accessibilitySetValue:forAttribute:")) {
            _ = app.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: true), with: "AXEnhancedUserInterface")
        }
    }

    private static func viewCount(_ view: NSView?) -> Int {
        guard let view else { return 0 }
        return 1 + view.subviews.reduce(0) { $0 + viewCount($1) }
    }

    /// The window frame plus every scroll view's visible origin and document size: when any of these
    /// moves between the tree walk and a render, the frames in the tree no longer point at the pixels.
    private static func layoutFingerprint(_ window: NSWindow) -> [CGFloat] {
        var values = [window.frame.origin.x, window.frame.origin.y, window.frame.width, window.frame.height]
        func visit(_ view: NSView) {
            // 内容移位也算布局变化，不只检查滚动区。
            values += [view.frame.origin.x, view.frame.origin.y, view.frame.width, view.frame.height,
                       view.bounds.origin.x, view.bounds.origin.y, view.bounds.width, view.bounds.height]
            if let scroll = view as? NSScrollView {
                let origin = scroll.contentView.bounds.origin, size = scroll.documentView?.frame.size ?? .zero
                values += [origin.x, origin.y, size.width, size.height]
            }
            view.subviews.forEach(visit)
        }
        if let content = window.contentView { visit(content) }
        return values
    }

    /// Waits (up to 8 s) until the fingerprint has held still for a second: async results that grow a
    /// page, a panel scrolling its planner into view, a window resizing to its content.
    private static func waitForStillLayout(_ window: NSWindow) async -> Bool {
        let started = Date()
        var last = layoutFingerprint(window), stillSince = Date()
        while Date().timeIntervalSince(started) < 8 {
            try? await Task.sleep(for: .milliseconds(250))
            let now = layoutFingerprint(window)
            if now != last {
                last = now
                stillSince = Date()
            } else if Date().timeIntervalSince(stillSince) >= 1 {
                return true
            }
        }
        return false
    }

    // 树的角色与坐标也要一致，窗口大小没变不代表内容没动。
    private static func treeGeometry(_ nodes: [[String: Any]]) -> Data? {
        let geometry = nodes.map { node in
            node.filter { ["role", "class", "depth", "childCount", "frame"].contains($0.key) }
        }
        return try? JSONSerialization.data(withJSONObject: sanitize(geometry), options: [.sortedKeys])
    }

    /// Non-finite numbers become null, so one odd frame never sinks the whole dump.
    private static func sanitize(_ value: Any) -> Any {
        switch value {
        case let number as Double where !number.isFinite: return NSNull()
        case let dictionary as [String: Any]: return dictionary.mapValues(sanitize)
        case let array as [Any]: return array.map(sanitize)
        default: return value
        }
    }

    private static func rect(_ r: NSRect) -> [String: Double] {
        ["x": r.origin.x, "y": r.origin.y, "w": r.size.width, "h": r.size.height]
    }

    /// SwiftUI's accessibility nodes answer the NSAccessibility getters but do not advertise the
    /// protocol to a Swift cast, so attributes are read through KVC after a responds(to:) check.
    private static func attribute(_ object: NSObject, _ key: String) -> Any? {
        let isForm = "is" + key.prefix(1).uppercased() + key.dropFirst()
        var modern: Any?
        if object.responds(to: Selector(key)) || object.responds(to: Selector(isForm)) {
            modern = object.value(forKey: key)
            // A hosting view answers the modern children getter with an empty list unless an
            // assistive client has switched the process on; the legacy attribute still has them.
            if key != "accessibilityChildren" || !((modern as? [Any])?.isEmpty ?? true) { return modern }
        }
        // Table and outline rows are proxies that only speak the legacy attribute API.
        guard let legacy = LEGACY[key], object.responds(to: NSSelectorFromString("accessibilityAttributeValue:")) else { return modern }
        return object.perform(NSSelectorFromString("accessibilityAttributeValue:"), with: legacy)?.takeUnretainedValue() ?? modern
    }

    private static let LEGACY: [String: String] = [
        "accessibilityChildren": "AXChildren", "accessibilityRole": "AXRole", "accessibilitySubrole": "AXSubrole",
        "accessibilityRoleDescription": "AXRoleDescription", "accessibilityLabel": "AXDescription",
        "accessibilityTitle": "AXTitle", "accessibilityHelp": "AXHelp", "accessibilityValue": "AXValue",
        "accessibilityTitleUIElement": "AXTitleUIElement",
        "accessibilityNumberOfCharacters": "AXNumberOfCharacters",
        "accessibilityIdentifier": "AXIdentifier", "accessibilityPlaceholderValue": "AXPlaceholderValue", "accessibilityEnabled": "AXEnabled", "accessibilityFocused": "AXFocused",
    ]

    private static func textRangeEvidence(_ object: NSObject, value: String) -> [String: Any] {
        let getterSelector = NSSelectorFromString("accessibilityStringForRange:")
        let countSelector = NSSelectorFromString("accessibilityNumberOfCharacters")
        let allowedSelector = NSSelectorFromString("isAccessibilitySelectorAllowed:")
        var evidence: [String: Any] = [
            "valueUTF16Length": (value as NSString).length,
            "hasModernStringGetter": object.responds(to: getterSelector),
            "hasModernCountGetter": object.responds(to: countSelector),
        ]
        if object.responds(to: allowedSelector) {
            typealias Allowed = @convention(c) (AnyObject, Selector, Selector) -> ObjCBool
            let allowed = unsafeBitCast(object.method(for: allowedSelector), to: Allowed.self)
            evidence["modernStringGetterAllowed"] = allowed(object, allowedSelector, getterSelector).boolValue
            evidence["modernCountGetterAllowed"] = allowed(object, allowedSelector, countSelector).boolValue
        }
        if let count = attribute(object, "accessibilityNumberOfCharacters") as? NSNumber {
            evidence["reportedCharacterCount"] = count.intValue
        }
        let legacyNamesSelector = NSSelectorFromString("accessibilityParameterizedAttributeNames")
        var legacyNames: [String] = []
        if object.responds(to: legacyNamesSelector) {
            legacyNames = object.perform(legacyNamesSelector)?.takeUnretainedValue() as? [String] ?? []
            evidence["legacyParameterizedAttributes"] = legacyNames
        }
        let text = value as NSString
        let reportedCount = evidence["reportedCharacterCount"] as? Int
        evidence["rangeLengthSource"] = reportedCount == nil ? "AXValueUTF16Length" : "reportedCharacterCount"
        if let reportedCount {
            evidence["reportedCountMatchesValue"] = reportedCount == text.length
        }
        let version = text.range(of: HelpSettingsView.versionText)
        var ranges: [(String, NSRange)] = [("full", NSRange(location: 0, length: text.length))]
        if version.location != NSNotFound {
            ranges.append(("version", version))
            ranges.append(("versionPrefix", NSRange(location: version.location, length: min(3, version.length))))
        }
        var queries: [[String: Any]] = []
        for (name, range) in ranges {
            var query: [String: Any] = ["name": name, "location": range.location, "length": range.length,
                                        "expected": text.substring(with: range)]
            let count = reportedCount ?? text.length
            guard count >= 0, range.location <= count, range.length <= count - range.location,
                  range.location <= text.length, range.length <= text.length - range.location else {
                query["notInvoked"] = "No matching reported character range"
                queries.append(query)
                continue
            }
            if object.responds(to: getterSelector), evidence["modernStringGetterAllowed"] as? Bool != false {
                typealias Getter = @convention(c) (AnyObject, Selector, NSRange) -> Unmanaged<AnyObject>?
                let getter = unsafeBitCast(object.method(for: getterSelector), to: Getter.self)
                if let result = getter(object, getterSelector, range)?.takeUnretainedValue() as? String {
                    query["modernResult"] = result
                }
            }
            let legacyGetter = NSSelectorFromString("accessibilityAttributeValue:forParameter:")
            if legacyNames.contains("AXStringForRange"), object.responds(to: legacyGetter),
               let result = object.perform(legacyGetter, with: "AXStringForRange", with: NSValue(range: range))?.takeUnretainedValue() as? String {
                query["legacyResult"] = result
            }
            queries.append(query)
        }
        evidence["queries"] = queries
        return evidence
    }

    private static func walk(_ element: Any, depth: Int, into nodes: inout [[String: Any]]) {
        guard depth < 48, nodes.count < 10_000, let object = element as? NSObject else { return }
        let children = (attribute(object, "accessibilityChildren") as? [Any]) ?? []
        var node: [String: Any] = [
            "depth": depth,
            "class": String(describing: type(of: element)),
            "childCount": children.count,
        ]
        for key in ["accessibilityRole", "accessibilitySubrole", "accessibilityRoleDescription", "accessibilityLabel",
                    "accessibilityTitle", "accessibilityHelp", "accessibilityHint", "accessibilityPlaceholderValue", "accessibilityIdentifier"] {
            if let text = attribute(object, key) as? String, !text.isEmpty {
                node[String(key.dropFirst("accessibility".count)).lowercasedFirst] = text
            }
        }
        if let title = attribute(object, "accessibilityTitleUIElement") as? NSObject {
            for key in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"] {
                if let text = attribute(title, key) as? String, !text.isEmpty {
                    node["titleUIElement"] = text
                    break
                }
            }
        }
        if let flag = attribute(object, "accessibilityElement") as? Bool { node["isElement"] = flag }
        if let flag = attribute(object, "accessibilityEnabled") as? Bool { node["enabled"] = flag }
        if let flag = attribute(object, "accessibilityFocused") as? Bool { node["focused"] = flag }
        if let value = attribute(object, "accessibilityFrame") as? NSValue {
            node["frame"] = rect(value.rectValue)
        } else if object.responds(to: NSSelectorFromString("accessibilityAttributeValue:")),
                  let position = object.perform(NSSelectorFromString("accessibilityAttributeValue:"), with: "AXPosition")?.takeUnretainedValue() as? NSValue,
                  let size = object.perform(NSSelectorFromString("accessibilityAttributeValue:"), with: "AXSize")?.takeUnretainedValue() as? NSValue {
            node["frame"] = rect(NSRect(origin: position.pointValue, size: size.sizeValue))
        }
        if let value = attribute(object, "accessibilityValue") {
            node["value"] = String(describing: value)
        }
        if ProcessInfo.processInfo.environment["MEANTIME_AX_TEXT_RANGES"] == "1",
           [node["value"], node["label"]].compactMap({ $0 as? String }).contains(where: { $0.contains("Dayside") }) {
            node["textRangeEvidence"] = textRangeEvidence(object, value: node["value"] as? String ?? "")
        }
        nodes.append(node)
        for child in children {
            walk(child, depth: depth + 1, into: &nodes)
        }
    }

    /// 夹具里核列表高亮：面板只收自己的填色，搜索补全保留系统高亮。
    private static func tableHighlights(in root: NSView) -> [[String: Any]] {
        var tables: [NSTableView] = []
        var probes: [TableHighlightOff.Probe] = []
        func visit(_ view: NSView) {
            if let table = view as? NSTableView { tables.append(table) }
            if let probe = view as? TableHighlightOff.Probe { probes.append(probe) }
            view.subviews.forEach(visit)
        }
        visit(root)
        return tables.map { table in
            let enclosure: NSView = table.enclosingScrollView ?? table
            return ["class": String(describing: type(of: table)),
                    "frameInHost": rect(root.convert(enclosure.bounds, from: enclosure)),
                    "panelList": probes.contains { $0.appliedTable === table },
                    "standardHighlight": table.selectionHighlightStyle != .none,
                    "highlightStyle": table.selectionHighlightStyle.rawValue,
                    "rows": table.numberOfRows, "selectedRows": Array(table.selectedRowIndexes)]
        }
    }
}

private extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
#endif
