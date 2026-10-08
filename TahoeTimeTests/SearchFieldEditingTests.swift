// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI
import Testing
@testable import TahoeTime

@Suite(.serialized)
@MainActor
struct SearchFieldEditingTests {
    private func withField(onPaste: (() -> Void)? = nil,
                           _ body: (NSSearchField, NSWindow) throws -> Void) throws {
        let host = NSHostingView(rootView: SearchField(text: .constant(""),
            placeholder: "Search", onPaste: onPaste).frame(width: 300, height: 30))
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 320, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.makeFirstResponder(nil); window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        func find(_ view: NSView) -> NSSearchField? {
            if let field = view as? NSSearchField { return field }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        let field = try #require(find(host), "必须检查 representable 创建的原生搜索框")
        try body(field, window)
    }

    @Test func representablePreservesNativeEditingAndAccessibilityDefaults() throws {
        try withField { field, _ in
            #expect(field.isEditable)
            #expect(field.isSelectable)
            let cell = try #require(field.cell as? SearchField.PasteAwareCell)
            let nativeCell = try #require(NSSearchField().cell as? NSSearchFieldCell)
            #expect(cell.isScrollable == nativeCell.isScrollable)
            #expect(cell.usesSingleLineMode)
            #expect(!cell.wraps)
            // 原生控件把可达输入元素放在单元上，外层视图自身不承担文字角色。
            let accessibleCell = try #require(field.accessibilityChildren()?.compactMap {
                $0 as? NSSearchFieldCell
            }.first)
            #expect(accessibleCell === cell)
            #expect(accessibleCell.accessibilityRole() == .textField)
            #expect(accessibleCell.accessibilitySubrole() == .searchField)
        }
    }

    @Test func firstResponderUsesPasteAwareEditorAndReportsPaste() throws {
        var pasteCount = 0
        try withField(onPaste: { pasteCount += 1 }) { field, window in
            try #require(window.makeFirstResponder(field))
            let editor = try #require(field.currentEditor() as? SearchField.PasteAwareEditor,
                                      "原生焦点必须启动专用 field editor")
            #expect(window.firstResponder === editor)
            #expect(editor === (field.cell as? SearchField.PasteAwareCell)?.editor)
            #expect(editor.isFieldEditor)
            #expect(editor.isEditable)
            editor.insertText("Tokyo", replacementRange: NSRange(location: 0, length: 0))
            #expect(editor.string == "Tokyo")
            editor.paste(nil)
            #expect(pasteCount == 1)
        }
    }
}
