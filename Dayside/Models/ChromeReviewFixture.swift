// SPDX-License-Identifier: GPL-3.0-only
#if DEBUG
import AppKit
import SwiftUI

/// 隔离测试宿主打开地球的海报与系统全屏，供截图和读屏转储。
@MainActor
enum ChromeReviewFixture {
    private static var posterWindow: NSWindow?

    private static func receipt(_ value: String) {
        FileHandle.standardOutput.write(Data((value + "\n").utf8))
    }

    static func prepareEarth(model: AppModel) async -> (name: String, prefix: String) {
        guard ApplicationSession.isTesting else { return ("earth", "earth") }
        let state = ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_EARTH_STATE"]
        if state == "poster" {
            let input = EarthPoster.input(model: model, core: model.core)
            if let png = EarthPoster.data(input) {
                let url = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("earth-poster-\(ProcessInfo.processInfo.processIdentifier).png")
                do {
                    try png.write(to: url)
                    receipt("CHROME_REVIEW_POSTER_PATH=\(url.path)")
                } catch { receipt("CHROME_REVIEW_POSTER_FAILED=\(error)") }
            }
            guard ApplicationSession.uiTestForeground else { return ("earth", "earth") }
            let content = EarthPoster.Content(instant: input.instant, places: input.places,
                                              labels: input.labels, caption: input.caption, locale: input.locale)
            let window = NSWindow(contentViewController: NSHostingController(rootView: content))
            window.identifier = NSUserInterfaceItemIdentifier("earth-poster")
            window.title = "Dayside"
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: EarthPoster.width, height: EarthPoster.height))
            window.center()
            posterWindow = window
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return ("earthPoster", "earth-poster")
        }
        if state == "fullscreen" {
            guard ApplicationSession.uiTestForeground else {
                receipt("CHROME_REVIEW_FULLSCREEN_DEFERRED=quiet")
                return ("earth", "earth")
            }
            for _ in 0..<30 {
                if let window = NSApp.windows.first(where: {
                    $0.identifier?.rawValue == "earth" && $0.isVisible && $0.contentView != nil
                }) {
                    try? await Task.sleep(for: .seconds(1))
                    NSApp.activate(ignoringOtherApps: true)
                    window.makeKeyAndOrderFront(nil)
                    receipt("CHROME_REVIEW_FULLSCREEN_WINDOW style=\(window.styleMask.rawValue) behavior=\(window.collectionBehavior.rawValue) key=\(window.isKeyWindow) main=\(window.isMainWindow) active=\(NSApp.isActive)")
                    try? await Task.sleep(for: .milliseconds(500))
                    receipt("CHROME_REVIEW_FULLSCREEN_BEGIN style=\(window.styleMask.rawValue) behavior=\(window.collectionBehavior.rawValue)")
                    window.toggleFullScreen(nil)
                    for _ in 0..<100 {
                        if window.styleMask.contains(.fullScreen) { break }
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    try? await Task.sleep(for: .seconds(1))
                    receipt("CHROME_REVIEW_FULLSCREEN=\(window.styleMask.contains(.fullScreen)) frame=\(window.frame)")
                    receipt("CHROME_REVIEW_FULLSCREEN_WINDOW_ID=\(window.windowNumber)")
                    if let primary = NSScreen.screens.first {
                        let frame = window.frame
                        receipt("CHROME_REVIEW_FULLSCREEN_CAPTURE_RECT=\(frame.minX),\(primary.frame.maxY - frame.maxY),\(frame.width),\(frame.height)")
                    }
                    break
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        return ("earth", "earth")
    }
}
#endif
