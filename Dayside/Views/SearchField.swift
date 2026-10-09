// SPDX-License-Identifier: GPL-3.0-only
//
//  SearchField.swift
//  Dayside
//
//  真正的系统搜索框(NSSearchField):胶囊形 + 系统放大镜 + 焦点环 + 系统圆角,和
//  Spotlight / 访达搜索一致。SwiftUI 没有 inline 搜索框原语,故桥接——与本 App 已用的
//  NSFont / NSColor / NSApplication 等 AppKit 原语一致,非第三方依赖。
//
//  键盘导航:焦点留在搜索框,↑ / ↓ / 回车 / Esc 经 NSSearchFieldDelegate 的
//  `doCommandBy` 截获并转交补全列表(AppKit 补全的标准做法)——否则键盘用户
//  完全无法到达结果列表、无法添加时区。
//

import SwiftUI
import AppKit

struct SearchField: NSViewRepresentable {
    @Environment(\.locale) private var locale
    /// 搜索框转交出来的键盘命令。
    enum KeyCommand { case moveDown, moveUp, commit, cancel }

    @Binding var text: String
    var placeholder: String = ""
    /// 悬停提示与读屏的补充说明（面板那个框：「也能输入时间，例如“明天 9:00 东京”」）；空串就不设。
    var help: String = ""
    /// 返回 true 表示命令已被(补全列表)消费;false 走 AppKit 默认行为。
    var onKeyCommand: ((KeyCommand) -> Bool)? = nil
    /// 来自剪贴板的时间句需要给出用户地点选项；编辑菜单与 ⌘V 走同一个原生 field editor。
    var onPaste: (() -> Void)? = nil

    func makeNSView(context: Context) -> NSSearchField {
        let field = PasteAwareSearchField()
        let cell = field.cell as! PasteAwareCell
        cell.editor.onPaste = { [weak coordinator = context.coordinator] in coordinator?.parent.onPaste?() }
        field.delegate = context.coordinator
        field.placeholderString = placeholder
        // 搜索框、单元与编辑器都用已按界面语言取出的名称。
        field.setAccessibilityLabel(placeholder)
        field.cell?.setAccessibilityLabel(placeholder)
        cell.editor.setAccessibilityLabel(placeholder)
        Self.applyHelp(help, to: field)
        Self.localizeButtons(cell, locale: locale)
        field.sendsWholeSearchString = false
        field.sendsSearchStringImmediately = true
        return field
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if nsView.stringValue != text { nsView.stringValue = text }
        nsView.placeholderString = placeholder
        nsView.setAccessibilityLabel(placeholder)
        nsView.cell?.setAccessibilityLabel(placeholder)
        (nsView.cell as? PasteAwareCell)?.editor.setAccessibilityLabel(placeholder)
        Self.applyHelp(help, to: nsView)
        if let cell = nsView.cell as? NSSearchFieldCell { Self.localizeButtons(cell, locale: locale) }
    }

    /// 悬停提示与读屏说明同一句（框、单元、编辑器三处都设：读屏落在哪一层都念得到）。
    static func applyHelp(_ help: String, to field: NSSearchField) {
        let value: String? = help.isEmpty ? nil : help
        guard field.toolTip != value else { return }
        field.toolTip = value
        field.setAccessibilityHelp(value)
        field.cell?.setAccessibilityHelp(value)
        (field.cell as? PasteAwareCell)?.editor.setAccessibilityHelp(value)
    }

    /// 原生搜索按钮不会自动跟随 SwiftUI 的界面语言。
    static func localizeButtons(_ cell: NSSearchFieldCell, locale: Locale) {
        let search = L10n.string("搜索", locale: locale)
        let clear = L10n.string("清除搜索", locale: locale)
        cell.searchButtonCell?.setAccessibilityLabel(search)
        cell.searchButtonCell?.setAccessibilityTitle(search)
        cell.cancelButtonCell?.setAccessibilityLabel(clear)
        cell.cancelButtonCell?.setAccessibilityTitle(clear)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// 由 AppKit 创建单元，保留原生搜索框的编辑与选择默认值。
    final class PasteAwareSearchField: NSSearchField {
        override class var cellClass: AnyClass? {
            get { PasteAwareCell.self }
            set { super.cellClass = newValue }
        }
    }

    /// 保留 NSSearchField 的编辑、输入法和键盘路径，只在原生粘贴动作前报告来源。
    final class PasteAwareCell: NSSearchFieldCell {
        let editor: PasteAwareEditor = {
            let editor = PasteAwareEditor()
            editor.isFieldEditor = true
            editor.isRichText = false
            editor.importsGraphics = false
            return editor
        }()

        override func fieldEditor(for controlView: NSView) -> NSTextView? { editor }
    }

    final class PasteAwareEditor: NSTextView {
        var onPaste: (() -> Void)?

        override func paste(_ sender: Any?) {
            onPaste?()
            super.paste(sender)
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SearchField
        init(_ parent: SearchField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy commandSelector: Selector) -> Bool {
            let command: SearchField.KeyCommand
            switch commandSelector {
            case #selector(NSResponder.moveDown(_:)):        command = .moveDown
            case #selector(NSResponder.moveUp(_:)):          command = .moveUp
            case #selector(NSResponder.insertNewline(_:)):   command = .commit
            case #selector(NSResponder.cancelOperation(_:)): command = .cancel
            default: return false
            }
            return parent.onKeyCommand?(command) ?? false
        }
    }
}
