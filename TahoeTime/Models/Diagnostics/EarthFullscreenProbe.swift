// SPDX-License-Identifier: GPL-3.0-only
#if DEBUG
import AppKit
import Darwin

@MainActor
enum EarthFullscreenProbe {
    static var isRequested: Bool {
        ApplicationSession.isLocalPreview
            && ProcessInfo.processInfo.environment["DAYSIDE_EARTH_FULLSCREEN_PROBE"] == "1"
            && ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_FOREGROUND"] == "1"
    }

    static func runIfRequested(open: @escaping @MainActor () -> Void) {
        guard isRequested else { return }
        Task { @MainActor in
            open()
            do {
                for _ in 0..<100 {
                    if NSApp.windows.contains(where: { $0.identifier?.rawValue.hasPrefix("earth") == true }) { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("earth") == true }) else {
                    throw Failure.missingWindow
                }
                print("EARTH_PROBE normalLaunch=true testing=\(ApplicationSession.isTesting) quiet=\(TestHostWindowPolicy.isQuiet) guards=\(TestHostWindowPolicy.windowGuardsAreInstalled)")
                guard !ApplicationSession.isTesting, !TestHostWindowPolicy.windowGuardsAreInstalled else { throw Failure.guardsInstalled }
                try await exercise(window)
                try await Task.sleep(for: .seconds(1))
                window.close()
                print("EARTH_PROBE PASS cycles=2")
                NSApp.terminate(nil)
            } catch {
                FileHandle.standardError.write(Data("EARTH_PROBE FAIL \(error)\n".utf8))
                exit(1)
            }
        }
    }

    enum Failure: Error { case missingWindow, guardsInstalled, missingToolbar, transitionTimeout, wrongFullscreenState }

    @MainActor private final class Transitions {
        var entered = 0
        var exited = 0
    }

    static func exercise(_ window: NSWindow) async throws {
        let state = Transitions()
        let center = NotificationCenter.default
        let entered = center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { state.entered += 1 }
        }
        let exited = center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { state.exited += 1 }
        }
        defer { center.removeObserver(entered); center.removeObserver(exited) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(300))
        for cycle in 1...2 {
            EarthWindowActions.toggleFullscreen(in: window)
            try await wait { state.entered == cycle }
            guard window.styleMask.contains(.fullScreen) else { throw Failure.wrongFullscreenState }
            guard let toolbar = window.toolbar else { throw Failure.missingToolbar }
            toolbar.isVisible = false
            window.contentView?.layoutSubtreeIfNeeded()
            print("EARTH_PROBE entered=\(cycle) toolbarVisible=\(toolbar.isVisible)")
            EarthWindowActions.toggleFullscreen(in: window)
            try await wait { state.exited == cycle }
            guard !window.styleMask.contains(.fullScreen) else { throw Failure.wrongFullscreenState }
            print("EARTH_PROBE exited=\(cycle)")
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    private static func wait(_ completed: () -> Bool) async throws {
        for _ in 0..<150 {
            if completed() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw Failure.transitionTimeout
    }
}
#endif
