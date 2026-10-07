// SPDX-License-Identifier: GPL-3.0-only
//
//  SettingsRootView.swift
//  TahoeTime
//
//  标准 Settings 场景的根:TabView 分"通用 / 外观 / 帮助"。各页用 Form + .formStyle(.grouped),
//  渲染出来就是 macOS 系统设置面板的样子(不自定义设置 UI)。
//

import AppKit
import SwiftUI

struct SettingsRootView: View {
    enum Tab: String, Sendable { case general, appearance, shortcuts, help }
    @State private var tab: Tab
    @State private var layouts: [Tab: SettingsPageLayout] = [:]

    init(tab: Tab = SettingsRootView.initialTab) {
        _tab = State(initialValue: tab)
    }

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettingsView()
                .tabItem { Label("通用", systemImage: "gearshape") }
                .tag(Tab.general)
            AppearanceSettingsView()
                .tabItem { Label("外观", systemImage: "paintbrush") }
                .tag(Tab.appearance)
            ShortcutsSettingsView()
                .tabItem { Label("快捷键", systemImage: "keyboard") }
                .tag(Tab.shortcuts)
            HelpSettingsView()
                .tabItem { Label("帮助", systemImage: "questionmark.circle") }
                .tag(Tab.help)
        }
        // 默认按内容定高，短窗口仍可滚动。
        .toggleStyle(.checkbox)
        .frame(width: Self.width)
        .onPreferenceChange(SettingsPageLayoutPreference.self) { layouts = $0 }
        .background(SettingsWindowFitting(request: layouts[tab].map {
            SettingsWindowFitRequest(tab: tab, height: $0.height, revision: $0.revision)
        }))
    }

    static let width: CGFloat = 520

    /// 无障碍转储要能直接打开某一页;只在测试宿主生效。
    static var initialTab: Tab {
        #if DEBUG
        if ApplicationSession.isTesting,
           let raw = ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_SETTINGS_TAB"],
           let tab = Tab(rawValue: raw) {
            return tab
        }
        #endif
        return .general
    }
}

/// 分组表单按内容定高，语言或展开状态变化后重新量。
struct SettingsPageSizing: ViewModifier {
    private let minimumContentHeight: CGFloat
    private let layoutRevision: Int
    private let page: SettingsRootView.Tab
    @State private var height: CGFloat

    init(minimumContentHeight: CGFloat, layoutRevision: Int = 0, page: SettingsRootView.Tab) {
        // 十六语最大 document 高已包含 grouped Form 的上下留白。
        // 首次布局就给足高度，不依赖异步量尺在下一轮布局前回报。
        self.minimumContentHeight = minimumContentHeight
        self.layoutRevision = layoutRevision
        self.page = page
        _height = State(initialValue: ceil(minimumContentHeight))
    }

    func body(content: Content) -> some View {
        content
            .modifier(SettingsScaledFont(style: .body))
            .frame(minHeight: 0, idealHeight: max(height, minimumContentHeight),
                   maxHeight: .infinity)
            .background(SettingsFormMeasurement(layoutRevision: layoutRevision) { measured in
                let fitted = ceil(max(minimumContentHeight, measured))
                if abs(fitted - height) >= 1 { height = fitted }
            })
            .onChange(of: minimumContentHeight) { _, minimum in height = ceil(minimum) }
            .preference(key: SettingsPageLayoutPreference.self,
                        value: [page: SettingsPageLayout(height: max(height, minimumContentHeight), revision: layoutRevision)])
    }
}

/// 标准档保留表单原生字号，大字档按语义字号放大。
struct SettingsScaledFont: ViewModifier {
    @Environment(\.textScale) private var scale
    let style: Font.TextStyle

    func body(content: Content) -> some View {
        if scale == 1 {
            content
        } else {
            content.appFont(style, weight: style == .headline ? .semibold : nil)
        }
    }
}

struct SettingsFormMeasurement: NSViewRepresentable {
    @Environment(\.textScale) private var textScale
    var layoutRevision = 0
    let onMeasure: (CGFloat) -> Void

    func makeNSView(context: Context) -> MeasurementView {
        MeasurementView(onMeasure: onMeasure)
    }

    func updateNSView(_ view: MeasurementView, context: Context) {
        view.onMeasure = onMeasure
        view.textScale = textScale
        view.scheduleMeasurement()
    }

    final class MeasurementView: NSView {
        var onMeasure: (CGFloat) -> Void
        var textScale: Double = 1
        @MainActor private static let originalControlFonts = NSMapTable<NSControl, NSFont>.weakToStrongObjects()
        private var scheduled = false
        private var settlingScheduled = false
        #if DEBUG
        private var bottomScrollScheduled = false
        private var bottomScrollApplied = false
        #endif

        init(onMeasure: @escaping (CGFloat) -> Void) {
            self.onMeasure = onMeasure
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { return nil }

        override func layout() {
            super.layout()
            scheduleMeasurement()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleMeasurement()
        }

        func scheduleMeasurement() {
            guard !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduled = false
                self.measureNow()
            }
            // Form 删行晚于首轮布局，再量一次收拢。
            guard !settlingScheduled else { return }
            settlingScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self] in
                guard let self else { return }
                self.settlingScheduled = false
                self.measureNow()
                #if DEBUG
                self.scrollToBottomIfRequested()
                #endif
            }
        }

        #if DEBUG
        /// 截图夹具在布局停稳后只滚一次，随后保留正常滚动。
        private func scrollToBottomIfRequested() {
            guard ApplicationSession.isTesting else { return }
            let environment = ProcessInfo.processInfo.environment
            let fraction: CGFloat
            if let raw = environment["MEANTIME_UI_TEST_SETTINGS_SCROLL_FRACTION"],
               let value = Double(raw), value.isFinite, (0...1).contains(value) {
                fraction = CGFloat(value)
            } else if environment["MEANTIME_UI_TEST_SETTINGS_SCROLL_BOTTOM"] == "1" {
                fraction = 1
            } else {
                return
            }
            guard !bottomScrollApplied, !bottomScrollScheduled,
                  let scroll = enclosingForm(), let window = scroll.window,
                  self.window === window,
                  window.identifier?.rawValue.hasPrefix("com_apple_SwiftUI_Settings") == true,
                  !scroll.isHiddenOrHasHiddenAncestor else { return }
            bottomScrollScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self, weak scroll, weak window] in
                guard let self else { return }
                self.bottomScrollScheduled = false
                guard !self.bottomScrollApplied, let scroll, let window,
                      self.window === window, scroll.window === window, window.isVisible,
                      !scroll.isHiddenOrHasHiddenAncestor else { return }
                window.contentView?.layoutSubtreeIfNeeded()
                guard let document = scroll.documentView,
                      document.frame.height.isFinite, document.frame.height > 0,
                      scroll.contentView.bounds.height.isFinite, scroll.contentView.bounds.height > 0 else { return }
                let viewport = scroll.contentView.bounds
                let extent = max(0, document.frame.height - viewport.height)
                let position = document.frame.minY + extent * (document.isFlipped ? fraction : 1 - fraction)
                self.bottomScrollApplied = true
                scroll.contentView.scroll(to: NSPoint(x: viewport.minX, y: position))
                scroll.reflectScrolledClipView(scroll.contentView)
                FileHandle.standardOutput.write(Data("MEANTIME_SETTINGS_SCROLL_BOTTOM y=\(scroll.contentView.bounds.minY) document=\(document.frame.height) viewport=\(viewport.height)\n".utf8))
                FileHandle.standardOutput.write(Data("MEANTIME_SETTINGS_SCROLL_FRACTION fraction=\(fraction) y=\(scroll.contentView.bounds.minY) document=\(document.frame.height) viewport=\(viewport.height) flipped=\(document.isFlipped)\n".utf8))
            }
        }
        #endif

        /// 立即量当前表单的内容。
        func measureNow() {
            guard let scroll = enclosingForm(), let document = scroll.documentView,
               document.frame.height.isFinite, document.frame.height > 0 else {
                return
            }
            let fonts = scaleNativeControlFonts(in: document)
            if fonts.changed > 0 { document.layoutSubtreeIfNeeded() }
            #if DEBUG
            if ApplicationSession.isTesting {
                print("MEANTIME_SETTINGS_NATIVE_FONT scale=\(textScale) found=\(fonts.found) changed=\(fonts.changed)")
            }
            #endif
            // 分组表单的 document 已包含上下留白，不能再次加 contentInsets。
            onMeasure(document.frame.height)
        }

        /// 原生菜单直接缩放原有字体，保留已设置的特殊字体。
        private func scaleNativeControlFonts(in view: NSView) -> (found: Int, changed: Int) {
            var found = 0, changed = 0
            if let control = view as? NSControl, control.cell is NSPopUpButtonCell {
                found = 1
                let cachedOriginal = Self.originalControlFonts.object(forKey: control)
                if let current = control.font,
                   let original = cachedOriginal ?? control.font,
                   cachedOriginal != nil || !hasConfiguredFont(current) {
                    if textScale != 1 { Self.originalControlFonts.setObject(original, forKey: control) }
                    let target = textScale == 1 ? original
                        : original.withSize(original.pointSize * textScale)
                    if !current.isEqual(target) {
                        control.font = target
                        control.invalidateIntrinsicContentSize()
                        control.needsLayout = true
                        control.needsDisplay = true
                        changed = 1
                        #if DEBUG
                        if ApplicationSession.isTesting {
                            print("MEANTIME_SETTINGS_NATIVE_FONT_CHANGE reader=\(ObjectIdentifier(self)) control=\(ObjectIdentifier(control)) cacheHit=\(cachedOriginal != nil) original=\(original.pointSize) old=\(current.pointSize) new=\(target.pointSize) frame=\(control.frame)")
                        }
                        #endif
                    }
                }
            }
            for child in view.subviews {
                let result = scaleNativeControlFonts(in: child)
                found += result.found
                changed += result.changed
            }
            return (found, changed)
        }

        private func hasConfiguredFont(_ font: NSFont) -> Bool {
            let minimum = AppFont.size(.body) * textScale - 0.1
            return font.pointSize >= minimum || font.fontDescriptor.symbolicTraits.contains(.monoSpace)
        }

        private func enclosingForm() -> NSScrollView? {
            var ancestor = superview
            while let view = ancestor {
                view.layoutSubtreeIfNeeded()
                if let scroll = Self.form(in: view) { return scroll }
                ancestor = view.superview
            }
            return nil
        }

        private static func form(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            for child in view.subviews {
                if let scroll = form(in: child) { return scroll }
            }
            return nil
        }
    }
}


nonisolated struct SettingsPageLayout: Equatable, Sendable {
    let height: CGFloat
    let revision: Int
}

nonisolated struct SettingsPageLayoutPreference: PreferenceKey {
    static var defaultValue: [SettingsRootView.Tab: SettingsPageLayout] { [:] }

    static func reduce(value: inout [SettingsRootView.Tab: SettingsPageLayout],
                       nextValue: () -> [SettingsRootView.Tab: SettingsPageLayout]) {
        value.merge(nextValue(), uniquingKeysWith: { _, current in current })
    }
}

nonisolated struct SettingsWindowFitRequest: Equatable, Sendable {
    let tab: SettingsRootView.Tab
    let height: CGFloat
    let revision: Int
}

/// 只跟随选中页的内容变化，用户缩短窗口时不反复撑回去。
@MainActor
final class SettingsWindowSizingCoordinator {
    private weak var window: NSWindow?
    private weak var lastAttachedWindow: NSWindow?
    private var handledRequest: SettingsWindowFitRequest?
    private var usesAutomaticSizing = true

    func attach(_ window: NSWindow?) {
        guard self.window !== window else { return }
        self.window = window
        handledRequest = nil
        if let window, lastAttachedWindow !== window {
            lastAttachedWindow = window
            usesAutomaticSizing = true
        }
    }

    func beginManualResize() {
        usesAutomaticSizing = false
    }

    @discardableResult
    func fit(_ request: SettingsWindowFitRequest, visibleFrame: NSRect? = nil) -> Bool {
        guard let window, handledRequest != request, request.height.isFinite, request.height > 0 else { return false }
        #if DEBUG
        if ApplicationSession.uiTestSurface == "settings", ApplicationSession.uiTestWindowSize != nil {
            handledRequest = request
            usesAutomaticSizing = false
            return false
        }
        #endif
        guard usesAutomaticSizing else {
            handledRequest = request
            return false
        }
        guard !window.inLiveResize, !window.styleMask.contains(.fullScreen),
              let visible = visibleFrame ?? window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else { return false }
        handledRequest = request
        window.contentView?.layoutSubtreeIfNeeded()
        let before = window.frame
        let fitting = window.contentView?.fittingSize ?? .zero
        let projected = window.frameRect(forContentRect: NSRect(origin: .zero, size: fitting))
        // 全尺寸内容视图可能已包含安全区，按实际布局区核对。
        let nativeInset = max(0, before.height - window.contentLayoutRect.height)
        let measuredHeight = ceil(request.height + nativeInset)
        let preferredHeight = abs(projected.height - measuredHeight) <= 1 ? projected.height : measuredHeight
        let frame = Self.boundedFrame(before: before,
                                      preferredSize: NSSize(width: SettingsRootView.width, height: preferredHeight),
                                      visibleFrame: visible)
        window.setFrame(frame, display: true, animate: false)
        #if DEBUG
        if ApplicationSession.isTesting {
            let after = window.frame
            FileHandle.standardOutput.write(Data("MEANTIME_SETTINGS_FIT tab=\(request.tab.rawValue) preferred=\(request.height) rootFit=\(fitting.width)x\(fitting.height) projected=\(projected.height) nativeInset=\(nativeInset) before=\(before.width)x\(before.height) after=\(after.width)x\(after.height) visible=\(visible.width)x\(visible.height)\n".utf8))
        }
        #endif
        return true
    }

    static func boundedFrame(before: NSRect, preferredSize: NSSize, visibleFrame: NSRect) -> NSRect {
        var frame = before
        frame.size.width = min(preferredSize.width, visibleFrame.width)
        frame.size.height = min(preferredSize.height, visibleFrame.height)
        frame.origin.y = before.maxY - frame.height
        frame.origin.x = min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - frame.height)
        return frame
    }
}

private struct SettingsWindowFitting: NSViewRepresentable {
    let request: SettingsWindowFitRequest?

    func makeNSView(context: Context) -> FittingView {
        let view = FittingView()
        view.request = request
        return view
    }

    func updateNSView(_ view: FittingView, context: Context) {
        view.request = request
        view.scheduleFit()
    }

    final class FittingView: NSView {
        var request: SettingsWindowFitRequest?
        private let coordinator = SettingsWindowSizingCoordinator()
        private var scheduled = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attachSettingsWindow()
            scheduleFit()
        }

        override func layout() {
            super.layout()
            scheduleFit()
        }

        override func viewWillStartLiveResize() {
            super.viewWillStartLiveResize()
            coordinator.beginManualResize()
        }

        private func attachSettingsWindow() {
            let settingsWindow = window?.identifier?.rawValue.hasPrefix("com_apple_SwiftUI_Settings") == true ? window : nil
            coordinator.attach(settingsWindow)
        }

        func scheduleFit() {
            guard !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduled = false
                self.attachSettingsWindow()
                if let request = self.request { self.coordinator.fit(request) }
            }
        }
    }
}
