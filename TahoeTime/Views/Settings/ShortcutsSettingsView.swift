// SPDX-License-Identifier: GPL-3.0-only
//
//  ShortcutsSettingsView.swift
//  TahoeTime
//
//  设置的「快捷键」页：呼出面板的全局组合 + 那张
//  键盘快捷键表（从帮助页的折叠区搬来，快捷键的事集中在一页）。
//  快捷键集中在一页，窗口按当前内容高度展开。
//

import SwiftUI

struct ShortcutsSettingsView: View {
    @Environment(AppModel.self) private var model
    private var center: GlobalHotkeyCenter { .shared }
    @State private var rejection: HotkeyRecorder.Rejection?
    @State private var suppressTaken = false

    private var errorKey: String? {
        if let rejection { return rejection.key }
        return model.settings.hotkey.enabled && center.isTaken && !suppressTaken
            ? "这个组合已被其他 App 占用，换一个。" : nil
    }

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("用快捷键呼出面板", isOn: $model.settings.hotkey.enabled)
                LabeledContent("组合键") {
                    HotkeyRecorder(setting: $model.settings.hotkey, rejection: $rejection,
                                   onStart: { suppressTaken = true }, onSuccess: { suppressTaken = false })
                }
                if let errorKey { ErrorLine(Text(LocalizedStringKey(errorKey))) }
            } header: { Text("菜单栏面板").modifier(SettingsScaledFont(style: .headline)) } footer: {
                Text("打开后，在任何 App 里按这个组合都会打开 Dayside 面板，再按一次关上。菜单栏项被隐藏时按了不会有反应。")
                    .modifier(SettingsScaledFont(style: .caption))
                    .foregroundStyle(.readableSecondary)
            }
            Section {
                row("改变时间", "拖动地图或滑块，或左右轻扫")
                symbolRow("走一小时 · 一刻钟", "← → · ⌥ ← →")
                row("打开地球窗", "连按两次地图")
                symbolRow("地球窗全屏", "⌃⌘F")
                row("拷贝这张图", "右键点地图，或在地球窗按 ⌘C")
                symbolRow("撤销删除的地点", "⌘Z")
                row("地点的快捷操作", "右键点地点行")
                symbolRow("切换时间工具的页", "⌘1 … ⌘0")
                row("在面板里看换算的时刻", "换算页里按 ⌘↩")
            } header: { Text("快捷键与手势").modifier(SettingsScaledFont(style: .headline)) } footer: {
                Text("← → 在地图、滑块或地球窗有焦点时可用；⌘1 … ⌘0 在时间工具窗打开时可用。")
                    .modifier(SettingsScaledFont(style: .caption))
                    .foregroundStyle(.readableSecondary)
            }
            .labeledContentStyle(.readable)
        }
        .formStyle(.grouped)
        .modifier(SettingsPageSizing(minimumContentHeight: Self.maximumDefaultHeight, page: .shortcuts))
        #if DEBUG
        .onAppear {
            if ApplicationSession.isTesting,
               ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_SHORTCUT_ERROR"] == "1" { rejection = .commandOnly }
        }
        #endif
        .onChange(of: model.settings.hotkey.enabled) { _, enabled in
            if !enabled { rejection = nil; suppressTaken = true }
            else { suppressTaken = false }
        }
        .onChange(of: errorKey) { _, key in
            if let key { AccessibilityNotification.Announcement(L10n.string(key, locale: model.uiLocale)).post() }
        }
    }

    private func row(_ action: LocalizedStringKey, _ how: LocalizedStringKey) -> some View {
        LabeledContent { Text(how) } label: { Text(action) }
            .accessibilityElement(children: .combine)
    }

    private func symbolRow(_ action: LocalizedStringKey, _ how: String) -> some View {
        LabeledContent { Text(verbatim: how) } label: { Text(action) }
            .accessibilityElement(children: .combine)
    }

    static let maximumDefaultHeight: CGFloat = 678
}

/// 快捷键录制器：点一下开始听，按下的第一个组合交 Rust 判（`hotkey.normalize`），
/// 合法就存下来，不合法就当场说为什么。用 `addLocalMonitorForEvents` 只听本进程的按键——
/// 全局监听要「辅助功能」授权，录制不需要那个。⎋ 取消。
struct HotkeyRecorder: View {
    @Binding var setting: HotkeySetting
    @State private var isRecording = false
    @State private var monitor: Any?
    @Binding var rejection: Rejection?
    let onStart: () -> Void
    let onSuccess: () -> Void

    /// 三种拒绝理由与页面共用同一个错误出口。
    enum Rejection: Equatable {
        case needsModifier, commandOnly, unknownKey
        var key: String {
            switch self {
            case .needsModifier: "组合里要有 ⌥ 或 ⌃。"
            case .commandOnly: "⌘ 加单键是各 App 自己的快捷键，请再加 ⌥ 或 ⌃。"
            case .unknownKey: "这个键不能用作快捷键。"
            }
        }
    }

    var body: some View {
        Button {
            if isRecording { stop() } else { start() }
        } label: {
            if isRecording {
                Text("按下组合…").modifier(SettingsScaledFont(style: .body))
                    .frame(minWidth: 72, minHeight: 20)
            } else {
                Text(verbatim: setting.label).modifier(SettingsScaledFont(style: .body))
                    .frame(minWidth: 72, minHeight: 20)
            }
        }
        .accessibilityLabel(Text("组合键"))
        .accessibilityValue(Text(verbatim: setting.label))
        .onDisappear { stop() }
        .onChange(of: setting.enabled) { _, enabled in if !enabled { stop() } }
    }

    private func start() {
        rejection = nil
        onStart()
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            guard isRecording else { return event }
            if event.keyCode == 53 {   // ⎋ 取消录制
                stop()
                return nil
            }
            let candidate = HotkeyCandidate(keyCode: Int(event.keyCode),
                                            modifiers: GlobalHotkeyCenter.mask(from: event.modifierFlags))
            if candidate.ok, let key = candidate.keyCode, let modifiers = candidate.modifiers {
                rejection = nil
                setting.keyCode = key
                setting.modifiers = modifiers
                onSuccess()
                stop()
            } else {
                rejection = Self.rejection(candidate.error)
            }
            return nil   // 录制中不把按键放给界面（免得 ⌘W 把设置窗关了）
        }
    }

    private func stop() {
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    static func rejection(_ error: String?) -> Rejection {
        switch error {
        case "needsModifier": return .needsModifier
        case "commandOnly":   return .commandOnly
        default:              return .unknownKey
        }
    }
}
