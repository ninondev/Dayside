// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Dayside

private let quietTestForegroundRequested: Bool = {
    let environment = ProcessInfo.processInfo.environment
    return environment["MEANTIME_UI_TEST_FOREGROUND"] == "1"
        || environment["TEST_RUNNER_MEANTIME_UI_TEST_FOREGROUND"] == "1"
}()

@Suite(.serialized)
@MainActor
struct QuietTestHostTests {
    private func window(size: CGSize = CGSize(width: 320, height: 180)) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private func expectQuiet(_ window: NSWindow, size: CGSize) {
        #expect(window.isVisible, "后台窗口仍需参与绘制")
        #expect(!window.isKeyWindow, "后台窗口不能拿走键盘焦点")
        #expect(!window.isMainWindow, "后台窗口不能成为主窗口")
        #expect(!window.canBecomeKey, "后台窗口不能接受键盘焦点")
        #expect(!window.canBecomeMain, "后台窗口不能成为主窗口候选")
        #expect(window.contentRect(forFrameRect: window.frame).size == size,
                "移出屏幕不能改动内容尺寸")
        #expect(!NSScreen.screens.isEmpty, "需要真实显示器才能核验屏幕边界")
        for screen in NSScreen.screens {
            #expect(!window.frame.intersects(screen.frame), "窗口必须完全避开每块显示器")
        }
    }

    @Test(.enabled(if: !quietTestForegroundRequested, "前台专用运行不重复后台窗口测试"))
    func everyFrontOrderingPathKeepsTheWindowOffscreenAndNonKey() throws {
        try #require(ApplicationSession.isTesting, "只允许在隔离测试宿主内运行")
        let size = CGSize(width: 320, height: 180)
        let window = window(size: size)
        defer { window.orderOut(nil); window.close() }
        window.orderFront(nil)
        expectQuiet(window, size: size)
        window.makeKeyAndOrderFront(nil)
        expectQuiet(window, size: size)
        window.orderFrontRegardless()
        expectQuiet(window, size: size)
        window.order(.above, relativeTo: 0)
        expectQuiet(window, size: size)
        window.makeKey()
        window.makeMain()
        expectQuiet(window, size: size)
    }

    @Test(.enabled(if: !quietTestForegroundRequested, "前台专用运行不重复后台窗口测试"),
          arguments: [false, true])
    func nativePanelsAlsoRemainOffscreenAndCannotBecomeKey(nonactivating: Bool) throws {
        try #require(ApplicationSession.isTesting, "只允许在隔离测试宿主内运行")
        let size = CGSize(width: 320, height: 180)
        var style: NSWindow.StyleMask = [.titled]
        if nonactivating { style.insert(.nonactivatingPanel) }
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: size),
                            styleMask: style, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.orderOut(nil); panel.close() }
        panel.orderFront(nil)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        panel.order(.above, relativeTo: 0)
        expectQuiet(panel, size: size)
        #expect(!panel.canBecomeKey, "原生面板的子类也不能取得键盘焦点")
        #expect(!panel.canBecomeMain, "原生面板不能成为主窗口")
    }

    @Test(.enabled(if: !quietTestForegroundRequested, "前台专用运行不重复后台窗口测试"))
    func centeringAndFrameChangesPreserveSizeOutsideEveryDisplay() throws {
        try #require(ApplicationSession.isTesting, "只允许在隔离测试宿主内运行")
        let window = window()
        defer { window.orderOut(nil); window.close() }
        window.orderFront(nil)
        window.center()
        expectQuiet(window, size: CGSize(width: 320, height: 180))
        let size = CGSize(width: 480, height: 260)
        let content = CGRect(origin: NSScreen.main?.frame.origin ?? .zero, size: size)
        window.setFrame(window.frameRect(forContentRect: content), display: true)
        expectQuiet(window, size: size)
        window.setFrameOrigin(NSScreen.main?.frame.origin ?? .zero)
        expectQuiet(window, size: size)
    }

    @Test(.enabled(if: !quietTestForegroundRequested, "前台专用运行不重复后台窗口测试"))
    func activationRequestsKeepTheOwnersFrontmostApplication() async throws {
        try #require(ApplicationSession.isTesting, "只允许在隔离测试宿主内运行")
        let before = try #require(NSWorkspace.shared.frontmostApplication)
        try #require(before.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                     "后台测试开始前宿主不能已经占据前台")
        NSApp.activate(ignoringOtherApps: true)
        NSApp.activate()
        try await Task.sleep(for: .milliseconds(300))
        let after = try #require(NSWorkspace.shared.frontmostApplication)
        #expect(after.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                "请求激活后宿主不能成为前台应用")
        #expect(!NSApp.isActive, "后台测试宿主不能激活自身")
    }

    @Test(.enabled(if: !quietTestForegroundRequested, "前台专用运行不重复后台窗口测试"))
    func anOrderedOffscreenHostingViewStillProducesItsRealBitmap() async throws {
        try #require(ApplicationSession.isTesting, "只允许在隔离测试宿主内运行")
        let size = CGSize(width: 320, height: 180)
        let view = NSHostingView(rootView: Color(.sRGB, red: 1, green: 0, blue: 0, opacity: 1)
            .frame(width: size.width, height: size.height))
        let window = window(size: size)
        window.contentView = view
        view.frame = CGRect(origin: .zero, size: size)
        defer { window.contentView = nil; window.orderOut(nil); window.close() }
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(150))
        view.layoutSubtreeIfNeeded()
        view.needsDisplay = true
        window.displayIfNeeded()
        expectQuiet(window, size: size)
        // 固定目标色彩空间，避免显示器配置改变纯色像素判据。
        let scale = window.backingScaleFactor
        let storage = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let bitmap = try #require(storage.retagging(with: .sRGB))
        bitmap.size = size
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        context.cgContext.clear(CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
        let blank = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        #expect(!(blank.redComponent > 0.8 && blank.greenComponent < 0.2 && blank.blueComponent < 0.2),
                "空白位图必须被同一红色判据拒绝")
        #expect(blank.alphaComponent == 0)
        print("QUIET_BITMAP_BLANK red=\(blank.redComponent) green=\(blank.greenComponent) blue=\(blank.blueComponent) alpha=\(blank.alphaComponent)")
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = try #require(bitmap.cgImage)
        #expect(image.width > 0 && image.height > 0)
        let center = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        #expect(center.alphaComponent > 0.8)
        print("QUIET_BITMAP_REAL red=\(center.redComponent) green=\(center.greenComponent) blue=\(center.blueComponent) alpha=\(center.alphaComponent) space=\(bitmap.colorSpace)")
        #expect(center.redComponent > 0.8 && center.greenComponent < 0.2 && center.blueComponent < 0.2,
                "缓存图必须含真正画出的红色，空白位图不能算通过")
    }

    @Test(.enabled(if: quietTestForegroundRequested,
                   "DEFERRED: 工具页真实快捷键需要 MEANTIME_UI_TEST_FOREGROUND=1，屏幕空闲后单独运行"))
    func explicitForegroundOptInRunsTheAppsRealPageShortcuts() async throws {
        try #require(ApplicationSession.isTesting && quietTestForegroundRequested,
                     "工具页真实快捷键必须显式选择前台测试宿主")
        let environment = ProcessInfo.processInfo.environment
        try #require(environment["MEANTIME_UI_TEST_FEATURE"] == "agenda"
            || environment["TEST_RUNNER_MEANTIME_UI_TEST_FEATURE"] == "agenda",
            "前台运行需 MEANTIME_UI_TEST_FEATURE=agenda 创建真实工具窗场景")
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while !FeatureHub.shared.isVisible && clock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let tools = try #require(NSApp.windows.first {
            $0.identifier?.rawValue.hasPrefix("tools") == true && $0.isVisible
        }, "真实工具窗场景必须已由 App 启动钩子打开")
        try #require(FeatureHub.shared.isVisible)
        tools.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(150))
        try #require(tools.isKeyWindow && NSApp.isActive)
        let menu = try #require(NSApp.mainMenu, "必须使用 App 真正安装的菜单")
        let original = FeatureHub.shared.selection
        defer { FeatureHub.shared.selection = original }
        let keys: [(String, UInt16, FeatureSelection)] = [
            ("1", 18, .planner), ("2", 19, .agenda), ("3", 20, .people),
            ("4", 21, .convert), ("5", 23, .timers), ("6", 22, .dstWatch),
            ("7", 26, .astronomy), ("8", 28, .markets), ("9", 25, .travel),
            ("0", 29, .sharing)
        ]
        for (key, code, expected) in keys {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: tools.windowNumber, context: nil, characters: key,
                charactersIgnoringModifiers: key, isARepeat: false, keyCode: code))
            #expect(menu.performKeyEquivalent(event), "App 的真实菜单必须处理 ⌘\(key)")
            try await Task.sleep(for: .milliseconds(100))
            #expect(FeatureHub.shared.selection == expected, "⌘\(key) 必须切到对应的真实工具页")
        }
    }

    @MainActor
    private final class ButtonAction: NSObject {
        var presses = 0
        @objc func press(_ sender: Any?) { presses += 1 }
    }

    @Test(.enabled(if: quietTestForegroundRequested,
                   "DEFERRED: 真实焦点与键等价物需要 MEANTIME_UI_TEST_FOREGROUND=1，屏幕空闲后单独运行"))
    func explicitForegroundOptInAllowsRealFocusAndKeyEquivalents() async throws {
        try #require(ApplicationSession.isTesting && quietTestForegroundRequested,
                     "真实焦点测试必须显式选择前台测试宿主")
        let window = window()
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        let field = NSTextField(frame: NSRect(x: 20, y: 90, width: 260, height: 24))
        field.stringValue = "Focus witness"
        let witness = ButtonAction()
        let button = NSButton(frame: NSRect(x: 20, y: 35, width: 120, height: 32))
        button.title = "Key witness"
        button.keyEquivalent = "k"
        button.keyEquivalentModifierMask = .command
        button.target = witness
        button.action = #selector(ButtonAction.press(_:))
        content.addSubview(field)
        content.addSubview(button)
        window.contentView = content
        defer { window.contentView = nil; window.orderOut(nil); window.close() }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(300))
        #expect(NSApp.isActive)
        #expect(window.isKeyWindow)
        #expect(window.isMainWindow)
        #expect(NSScreen.screens.contains { window.frame.intersects($0.frame) })
        try #require(window.makeFirstResponder(field), "真实输入框必须接受焦点")
        let editor = try #require(field.currentEditor())
        #expect(window.firstResponder === editor, "焦点必须实际落在输入框的 field editor")
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "k",
            charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40))
        #expect(window.performKeyEquivalent(event), "原生窗口必须派发按钮的键等价物")
        #expect(witness.presses == 1, "真实按钮动作必须收到一次按键")
    }

    @Test(.enabled(if: !quietTestForegroundRequested, "前台专用运行不重复后台窗口测试"))
    func offscreenFramesCannotBecomeSavedWindowPositions() throws {
        try #require(ApplicationSession.isTesting, "只允许在隔离测试宿主内运行")
        let name = "quiet-window-\(UUID().uuidString)"
        let key = "NSWindow Frame \(name)"
        let window = window()
        defer {
            window.orderOut(nil)
            window.close()
            NSWindow.removeFrame(usingName: name)
        }
        _ = window.setFrameAutosaveName(name)
        window.isRestorable = true
        window.makeKeyAndOrderFront(nil)
        window.saveFrame(usingName: name)
        #expect(window.frameAutosaveName.isEmpty, "屏外窗口不能启用位置自动保存")
        #expect(!window.isRestorable, "屏外窗口不能进入以后启动的恢复状态")
        #expect(UserDefaults.standard.object(forKey: key) == nil,
                "屏外位置不能写进窗口偏好；只核验本次 UUID 夹具键")
        expectQuiet(window, size: CGSize(width: 320, height: 180))
    }
}

// 兼容旧调用写法，仍由 AppKit 派发原事件并返回真实结果。
private extension NSMenu {
    @MainActor @nonobjc func performKeyEquivalent(_ event: NSEvent) -> Bool {
        performKeyEquivalent(with: event)
    }
}

private extension NSResponder {
    @MainActor @nonobjc func performKeyEquivalent(_ event: NSEvent) -> Bool {
        performKeyEquivalent(with: event)
    }
}
