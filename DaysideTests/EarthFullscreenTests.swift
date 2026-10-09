// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI
import Testing
@testable import Dayside

@Suite(.serialized)
@MainActor
struct EarthFullscreenTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_FOREGROUND"] == "1",
                   "Native fullscreen requires the strict foreground lane"))
    func earthSceneEntersAndLeavesFullscreenTwice() async throws {
        try #require(ApplicationSession.isTesting && ApplicationSession.uiTestForeground)
        #expect(!TestHostWindowPolicy.isQuiet)
        #expect(!TestHostWindowPolicy.windowGuardsAreInstalled)
        let existing = NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("earth") == true }
        let opener = NSHostingView(rootView: EarthSceneOpener())
        let host = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 1, height: 1),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.contentView = opener
        host.orderFront(nil)
        defer { host.contentView = nil; host.orderOut(nil); host.close() }
        for _ in 0..<100 {
            if NSApp.windows.contains(where: { $0.identifier?.rawValue.hasPrefix("earth") == true }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let earth = try #require(NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("earth") == true })
        defer { if existing == nil { earth.close() } }
        try await EarthFullscreenProbe.exercise(earth)
        #expect(!earth.styleMask.contains(.fullScreen))
        #expect(earth.isVisible)
    }
}

private struct EarthSceneOpener: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Color.clear.frame(width: 1, height: 1).onAppear { openWindow(id: "earth") }
    }
}
