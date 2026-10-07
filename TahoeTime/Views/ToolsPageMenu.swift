// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI

struct ToolsPageMenu: NSViewRepresentable {
    let hub: FeatureHub
    let locale: Locale

    func makeNSView(context: Context) -> Reader { Reader(hub: hub, locale: locale) }
    func updateNSView(_ view: Reader, context: Context) {
        view.locale = locale
        view.publish()
    }
    static func dismantleNSView(_ view: Reader, coordinator: ()) { view.detach() }

    final class Reader: NSView {
        let hub: FeatureHub
        var locale: Locale
        init(hub: FeatureHub, locale: Locale) {
            self.hub = hub
            self.locale = locale
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            publish()
        }
        func publish() {
            guard let window else { return }
            ToolsPageMenuController.shared.bind(window, hub: hub, locale: locale)
        }
        func detach() { ToolsPageMenuController.shared.unbind(window) }
    }
}

@MainActor
private final class ToolsPageMenuController: NSObject, NSMenuItemValidation {
    static let shared = ToolsPageMenuController()
    private weak var window: NSWindow?
    private var hub: FeatureHub?
    private var locale = Locale.current
    private var observer: NSObjectProtocol?
    private let menu = NSMenu()
    private let item = NSMenuItem()

    override private init() {
        super.init()
        item.identifier = NSUserInterfaceItemIdentifier("dayside.tools.pages")
        item.submenu = menu
        for feature in FeatureSelection.Group.allCases.flatMap(\.features) {
            let entry = NSMenuItem(title: "", action: #selector(selectPage(_:)), keyEquivalent: feature.shortcutKey)
            entry.keyEquivalentModifierMask = .command
            entry.representedObject = feature.rawValue
            entry.target = self
            menu.addItem(entry)
        }
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didUpdateNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func bind(_ window: NSWindow, hub: FeatureHub, locale: Locale) {
        self.window = window
        self.hub = hub
        self.locale = locale
        refresh()
    }

    func unbind(_ candidate: NSWindow?) {
        guard candidate === window else { return }
        window = nil
        hub = nil
        refresh()
    }

    private var canSelect: Bool {
        guard let window, window.identifier?.rawValue.hasPrefix("tools") == true else { return false }
        return NSApp.keyWindow === window && window.isVisible
    }

    private func refresh() {
        guard let main = NSApp.mainMenu else { return }
        // 场景切换会重建主菜单，保留同一组原生动作。
        if !main.items.contains(where: { $0 === item }) {
            item.menu?.removeItem(item)
            main.addItem(item)
        }
        item.title = L10n.string("时间工具", locale: locale)
        menu.title = item.title
        for entry in menu.items {
            guard let raw = entry.representedObject as? String, let feature = FeatureSelection(rawValue: raw) else { continue }
            entry.title = L10n.string(feature.titleKey, locale: locale)
            entry.isEnabled = canSelect
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { canSelect }

    @objc private func selectPage(_ sender: NSMenuItem) {
        guard canSelect, let raw = sender.representedObject as? String,
              let feature = FeatureSelection(rawValue: raw) else { return }
        hub?.selection = feature
    }
}
