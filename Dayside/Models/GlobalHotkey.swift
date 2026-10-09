// SPDX-License-Identifier: GPL-3.0-only
//
//  GlobalHotkey.swift
//  Dayside
//
//  全局快捷键呼出面板。
//  Swift 只做两件 Apple 框架的活：①Carbon 的 RegisterEventHotKey 注册 / 注销（沙盒内可用、
//  不需要任何授权，NSEvent 的全局监听要「辅助功能」授权，所以不走那条）；②按下时替用户点一下
//  我们自己的菜单栏项。哪个组合合法、怎么写成 ⌥⌘T、冲突怎么说，全在 Rust 的 hotkey 模块。
//

import AppKit
import Carbon.HIToolbox

// MARK: - 呼出面板

/// 「呼出面板」的唯一出口。
///
/// `MenuBarExtra` 没有公开的 `isPresented`：面板由系统托管，程序里能做的只有「替用户点那一下」。
/// 状态项的按钮在本进程的窗口列表里（状态栏窗口的 contentView 是个 NSButton 子类），
/// 用的都是公开 API（`NSApp.windows`、`NSButton.performClick`），不碰私有 selector。
/// 菜单栏项被用户藏起来（macOS 26 的 Allow in the Menu Bar）时找不到按钮，如实返回。
@MainActor
enum MenuBarPanel {
    enum Outcome: String {
        case clicked
        case noMenuBarItem
    }

    static func toggle() -> Outcome {
        guard let button = statusItemButton() else { return .noMenuBarItem }
        button.performClick(nil)
        return .clicked
    }

    /// 状态栏窗口里的按钮。类名只用来筛窗口（字符串比较，不是私有 API 调用）。
    static func statusItemButton() -> NSButton? {
        for window in NSApp.windows where String(describing: type(of: window)).contains("StatusBar") {
            if let button = window.contentView as? NSButton { return button }
            if let button = firstButton(in: window.contentView) { return button }
        }
        return nil
    }

    private static func firstButton(in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        for child in view.subviews {
            if let button = child as? NSButton { return button }
            if let button = firstButton(in: child) { return button }
        }
        return nil
    }

    /// 探针用：把本进程的窗口列成一行（类名、可见性、contentView 类名）。
    static func windowInventory() -> String {
        NSApp.windows.map { window in
            let content = window.contentView.map { String(describing: type(of: $0)) } ?? "nil"
            return "\(type(of: window))(visible=\(window.isVisible),content=\(content))"
        }.joined(separator: " ")
    }
}

// MARK: - 注册（Carbon）

/// 全局快捷键的注册方。
///
/// 走 Carbon 的 `RegisterEventHotKey`：沙盒内可用、不需要任何授权。`NSEvent` 的**全局**键盘
/// 监听要「辅助功能」授权（会弹系统框、要用户去系统设置勾我们），为了一个可选功能不值得，
/// 所以不走那条。合法性由 Rust 判，这里只管注册 / 注销与失败如实上报。
@MainActor
@Observable
final class GlobalHotkeyCenter {
    static let shared = GlobalHotkeyCenter()

    /// 注册被系统拒了（几乎总是别的 App 先占了这个组合）。文案由视图写，模型只给事实。
    private(set) var isTaken = false

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var registered: HotkeySetting?
    /// 测试与探针用：按下时走这里，默认就是点菜单栏项。
    var onPress: () -> Void = { _ = MenuBarPanel.toggle() }

    private init() {}

    /// 设置变了就重注册（冷启动也走这里，由 Rust `settings.effects` 的 hotkey 位决定）。
    func apply(_ setting: HotkeySetting) {
        guard setting != registered || (setting.enabled && hotKey == nil) else { return }
        unregister()
        registered = setting
        isTaken = false
        guard setting.enabled else { return }
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x4441_5953), id: 1)   // 'DAYS'
        let status = RegisterEventHotKey(UInt32(setting.keyCode), Self.carbonModifiers(setting.modifiers),
                                        id, GetEventDispatcherTarget(), 0, &ref)
        if status == noErr, let ref {
            hotKey = ref
            DiagnosticsLog.note("hotkey", "registered keyCode=\(setting.keyCode) modifiers=\(setting.modifiers)")
        } else {
            // 最常见的是 −9878 eventHotKeyExistsErr：别的 App 先占了这个组合。
            isTaken = true
            DiagnosticsLog.note("hotkey", "registration failed status=\(status) keyCode=\(setting.keyCode)")
        }
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }

    /// 按下（由 Carbon 回调转到主线程）。
    func handlePress() { onPress() }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        var ref: EventHandlerRef?
        // C 回调不能捕获上下文；按下的只有一个组合，所以直接转给单例。回调在主运行循环上跑，
        // 这里仍显式回主队列，免得将来多线程注册时出岔。
        let callback: EventHandlerUPP = { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { GlobalHotkeyCenter.shared.handlePress() } }
            return noErr
        }
        InstallEventHandler(GetEventDispatcherTarget(), callback, 1, &spec, nil, &ref)
        handler = ref
    }

    /// 我们的位掩码（Rust `hotkey` 定）→ Carbon 的修饰键掩码。
    static func carbonModifiers(_ modifiers: Int) -> UInt32 {
        var out: UInt32 = 0
        if modifiers & 1 != 0 { out |= UInt32(cmdKey) }
        if modifiers & 2 != 0 { out |= UInt32(optionKey) }
        if modifiers & 4 != 0 { out |= UInt32(controlKey) }
        if modifiers & 8 != 0 { out |= UInt32(shiftKey) }
        return out
    }

    /// AppKit 的修饰键 → 我们的位掩码（录制器用）。
    static func mask(from flags: NSEvent.ModifierFlags) -> Int {
        var out = 0
        if flags.contains(.command) { out |= 1 }
        if flags.contains(.option) { out |= 2 }
        if flags.contains(.control) { out |= 4 }
        if flags.contains(.shift) { out |= 8 }
        return out
    }
}

/// 录制器按下一个组合后问 Rust 的答复。
struct HotkeyCandidate: Decodable {
    let ok: Bool
    let keyCode: Int?
    let modifiers: Int?
    let label: String?
    let error: String?

    init(keyCode: Int, modifiers: Int) {
        struct Input: Encodable { let keyCode: Int; let modifiers: Int }
        self = RustCore.invoke("hotkey.normalize", Input(keyCode: keyCode, modifiers: modifiers))
    }
}
