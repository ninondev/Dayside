// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI

/// 换算页的多行输入框：读懂的每一处在原文下面划一道线，选中的那一处线加粗、衬极淡的底，
/// 写得不成立的段下面一道红色点线，没认出的地名一道橙色点线。不用整块底色：淡蓝底像是选中了文字。
/// 标记走 TextKit 1 的「临时属性」（系统拼写检查的红点线就是这么画的）：只管画，不改文字本身，所以不打断中日韩输入法的组字、
/// 不进撤销栈（改 `AttributedString` 会在组字时把拼音提交掉）。TextKit 2 的 rendering attributes 不画下划线（
/// 只剩底色），所以这里用 TextKit 1。读屏不靠这些标记：换算页下面「读懂了」一栏按句子念出每一处（WCAG 1.4.1）。
struct UnderstandingEditor: NSViewRepresentable {
    struct Mark: Equatable {
        enum Kind: Equatable { case understood, selected, problem, unresolved }
        /// 原文的 UTF-16 区间（引擎给的位置就是这个单位）。
        let range: NSRange
        let kind: Kind
    }

    @Binding var text: String
    var marks: [Mark]
    var placeholder: String
    var accessibilityLabel: String
    var minLines = 3
    var maxLines = 8
    /// 光标（插入点）移到某个 UTF-16 位置：换算页据此选中光标所在的那一处。
    var onCaret: (Int) -> Void = { _ in }
    /// 用户在框里粘贴（⌘V、编辑菜单）：粘贴进来的整段，「我这边」指写信人。
    var onPaste: () -> Void = {}
    /// ⌘↩：跳到选中的那一处。
    var onCommit: () -> Void = {}
    /// 内容高度变了（行数在 `minLines` 与 `maxLines` 之间，再多就在框里滚）。
    var onHeight: (CGFloat) -> Void = { _ in }
    var focusOnAppear = false

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = EditorTextView(usingTextLayoutManager: false)
        textView.delegate = context.coordinator
        textView.coordinator = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = text
        textView.setAccessibilityLabel(accessibilityLabel)

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        context.coordinator.textView = textView
        context.coordinator.apply(marks)
        if focusOnAppear {
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
        DispatchQueue.main.async { context.coordinator.reportHeight() }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        if textView.string != text, !textView.hasMarkedText() {
            textView.string = text
            context.coordinator.reportHeight()
        }
        textView.setAccessibilityLabel(accessibilityLabel)
        context.coordinator.apply(marks)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: UnderstandingEditor
        weak var textView: EditorTextView?
        private var applied: [Mark] = []

        init(_ parent: UnderstandingEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            // 输入法组字中（拼音还没选字）不把半截的字交出去读。
            guard !textView.hasMarkedText() else { return }
            if parent.text != textView.string { parent.text = textView.string }
            reportHeight()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView, !textView.hasMarkedText() else { return }
            parent.onCaret(textView.selectedRange().location)
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            // ⌘↩ 由菜单项之外的按键路径送来时是 insertNewline + ⌘；这里只接「插入换行时按着 ⌘」。
            if selector == #selector(NSResponder.insertNewline(_:)), NSEvent.modifierFlags.contains(.command) {
                parent.onCommit()
                return true
            }
            return false
        }

        func reportHeight() {
            guard let textView, let layout = textView.layoutManager, let container = textView.textContainer, let font = textView.font else { return }
            layout.ensureLayout(for: container)
            let line = ceil(font.ascender - font.descender + font.leading) + 2
            let used = ceil(layout.usedRect(for: container).height)
            let inset = textView.textContainerInset.height * 2
            let height = min(max(used, line * CGFloat(parent.minLines)), line * CGFloat(parent.maxLines)) + inset
            parent.onHeight(height)
        }

        /// 换上新的标记：先整段清掉，再按段加。只动临时属性，不碰文字。
        func apply(_ marks: [Mark]) {
            guard marks != applied, let textView, let layout = textView.layoutManager else { return }
            applied = marks
            let length = (textView.string as NSString).length
            let whole = NSRange(location: 0, length: length)
            for key in [NSAttributedString.Key.backgroundColor, .underlineStyle, .underlineColor] {
                layout.removeTemporaryAttribute(key, forCharacterRange: whole)
            }
            for mark in marks {
                let range = NSIntersectionRange(mark.range, whole)
                guard range.length > 0 else { continue }
                switch mark.kind {
                case .understood:
                    layout.addTemporaryAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue,
                                                   .underlineColor: NSColor.controlAccentColor.withAlphaComponent(0.8)], forCharacterRange: range)
                case .selected:
                    layout.addTemporaryAttributes([.underlineStyle: NSUnderlineStyle.thick.rawValue,
                                                   .underlineColor: NSColor.controlAccentColor,
                                                   .backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.10)], forCharacterRange: range)
                case .problem, .unresolved:
                    let style = NSUnderlineStyle.thick.rawValue | NSUnderlineStyle.patternDot.rawValue
                    layout.addTemporaryAttributes([.underlineStyle: style,
                                                   .underlineColor: mark.kind == .problem ? NSColor.systemRed : NSColor.systemOrange],
                                                  forCharacterRange: range)
                }
            }
        }
    }

    /// 只多两件事：粘贴时告诉换算页；换了外观时标记跟着重画（强调色与系统色是动态色）。
    final class EditorTextView: NSTextView {
        weak var coordinator: Coordinator?

        override func paste(_ sender: Any?) {
            coordinator?.parent.onPaste()
            super.paste(sender)
        }
    }
}
