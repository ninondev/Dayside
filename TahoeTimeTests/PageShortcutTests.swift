// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI
import Testing
@testable import TahoeTime

@MainActor
struct PageShortcutTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_FOREGROUND"] == "1",
                   "Real key-window shortcuts require the strict foreground lane"))
    func commandNumbersSwitchTheRealToolsWindowInSidebarOrder() async throws {
        try #require(ApplicationSession.isTesting)
        let hub = FeatureHub.shared
        let originalSelection = hub.selection
        let originalKeyWindow = NSApp.keyWindow
        let originalToolsWindow = toolsWindow
        defer {
            hub.selection = originalSelection
            originalKeyWindow?.makeKey()
        }

        // 用应用场景的开窗动作；快捷键始终交给应用自己的主菜单。
        let opener = NSHostingView(rootView: ToolsWindowOpener())
        let openingWindow = NSWindow(contentRect: NSRect(x: -2_000, y: -2_000, width: 1, height: 1),
                                     styleMask: [.borderless], backing: .buffered, defer: false)
        openingWindow.contentView = opener
        openingWindow.orderFront(nil)
        opener.layoutSubtreeIfNeeded()
        defer {
            openingWindow.orderOut(nil)
            openingWindow.contentView = nil
        }

        let deadline = Date().addingTimeInterval(5)
        while toolsWindow == nil || !hub.isVisible {
            guard Date() < deadline else { break }
            await settle()
        }
        let window = try #require(toolsWindow)
        defer { if originalToolsWindow == nil { window.close() } }
        try #require(hub.isVisible)
        let sidebarOrder: [FeatureSelection] = [.planner, .agenda, .people, .convert, .timers,
                                                .dstWatch, .astronomy, .markets, .travel, .sharing]
        #expect(FeatureSelection.Group.allCases.flatMap(\.features) == sidebarOrder)
        let keyCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

        // 显式走一次应用菜单的正常校验，模拟宿主缺少的菜单准备周期。
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        await settle()
        if let menu = NSApp.mainMenu {
            for number in 1...9 { diagnoseShortcut(String(number), in: menu, phase: "beforeValidation") }
            validateOwnMenu(menu)
            await settle()
            for number in 1...9 { diagnoseShortcut(String(number), in: menu, phase: "afterValidation") }
        }

        // 第一轮连续切页；第二轮每次都先停在另一页。
        hub.selection = .sharing
        await settle()
        for startOnAnotherPage in [false, true] {
            for number in 1...9 {
                let expected = sidebarOrder[number - 1]
                if startOnAnotherPage {
                    hub.selection = number == 1 ? .agenda : .sharing
                    await settle()
                }
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                await settle()
                let keyDeadline = Date().addingTimeInterval(5)
                while NSApp.keyWindow !== window, Date() < keyDeadline {
                    await settle()
                    if NSApp.isActive { window.makeKey() }
                }
                try #require(NSApp.keyWindow === window)
                let menu = try #require(NSApp.mainMenu)
                let key = String(number)
                diagnoseShortcut(key, in: menu, phase: "beforeDispatch")
                let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
                    modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: key,
                    charactersIgnoringModifiers: key, isARepeat: false, keyCode: keyCodes[number - 1]))
                #expect(menu.performKeyEquivalent(with: event), "⌘\(number) 未被菜单处理")
                await settle()
                diagnoseShortcut(key, in: NSApp.mainMenu ?? menu, phase: "afterDispatch")
                #expect(hub.selection == expected, "⌘\(number) 切页错误，另一页起步：\(startOnAnotherPage)")
                #expect(NSApp.keyWindow === window)
                print("PAGE_SHORTCUT command=\(number) anotherPage=\(startOnAnotherPage) selected=\(hub.selection.rawValue)")
            }
        }
    }

    private var toolsWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("tools") == true }
    }

    private func settle() async {
        pumpOwnApplicationEvents()
        try? await Task.sleep(for: .milliseconds(50))
    }

    private func pumpOwnApplicationEvents() {
        // 处理本进程已有的窗口事件，并走正常的窗口更新与运行循环。
        for _ in 0..<32 {
            guard let event = NSApp.nextEvent(matching: [.appKitDefined, .applicationDefined],
                                             until: .distantPast, inMode: .default,
                                             dequeue: true) else { break }
            NSApp.sendEvent(event)
        }
        NSApp.updateWindows()
        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }

    private func validateOwnMenu(_ menu: NSMenu) {
        menu.update()
        for item in menu.items {
            if let submenu = item.submenu { validateOwnMenu(submenu) }
        }
    }

    // 记录直接派发前后的菜单状态，便于定位快捷键失败。
    private func diagnoseShortcut(_ key: String, in menu: NSMenu, phase: String) {
        for item in menu.items {
            if item.keyEquivalent == key, item.keyEquivalentModifierMask == .command {
                let target = item.target.map { String(describing: type(of: $0)) } ?? "nil"
                let action = item.action.map(NSStringFromSelector) ?? "nil"
                let mainIdentity = NSApp.mainMenu.map { String(describing: ObjectIdentifier($0)) } ?? "nil"
                print("PAGE_SHORTCUT_MENU_DIAGNOSTIC phase=\(phase) command=\(key) enabled=\(item.isEnabled) toolsVisible=\(FeatureHub.shared.isVisible) appActive=\(NSApp.isActive) mainWindowMatches=\(NSApp.mainWindow === toolsWindow) target=\(target) action=\(action) menu=\(ObjectIdentifier(menu)) main=\(mainIdentity)")
            }
            if let submenu = item.submenu { diagnoseShortcut(key, in: submenu, phase: phase) }
        }
    }
}

private struct ToolsWindowOpener: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear.frame(width: 1, height: 1)
            .onAppear { openWindow(id: "tools") }
    }
}
