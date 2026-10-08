// SPDX-License-Identifier: GPL-3.0-only
//
//  WelcomeView.swift
//  TahoeTime
//
//  首次启动的欢迎页：一页、三句话、三个按钮，标准控件，
//  只出一次（`settings.didShowWelcome`）；隔离会话不出，截图与转储走 `MEANTIME_UI_TEST_SURFACE=welcome`。
//  它不替代空态——每一页空着时仍自己说去处。
//

import SwiftUI

struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool {
        #if DEBUG
        PerformanceProbe.isRequested ? false : systemReduceMotion
        #else
        systemReduceMotion
        #endif
    }
    @Environment(\.colorSchemeContrast) private var contrast
    /// 题记按打开欢迎页那一刻放（地图每分钟走一点，字不跟着跳）。
    @State private var opened = Date()
    /// 这一扇窗里拖过地图：下面那句话收起，关窗时把时间拨回现在。
    @State private var didDragMap = Self.initialDidDragMap
    @State private var dragCaptionHeight: CGFloat = 24
    @State private var options = WelcomeOptions()
    @State private var contentHeight: CGFloat = 0
    private let applicationIcon = Self.loadApplicationIcon()

    private static var initialDidDragMap: Bool {
        #if DEBUG
        UITestFixture.welcomeDragged
        #else
        false
        #endif
    }

    private static func loadApplicationIcon() -> (image: NSImage, needsMask: Bool) {
        let image = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        var rect = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return (image, false) }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        let corners = [(0, 0), (bitmap.pixelsWide - 1, 0),
                       (0, bitmap.pixelsHigh - 1), (bitmap.pixelsWide - 1, bitmap.pixelsHigh - 1)]
        let renderedImage = NSImage(cgImage: cgImage, size: image.size)
        return (renderedImage, corners.allSatisfy { (bitmap.colorAt(x: $0.0, y: $0.1)?.alphaComponent ?? 0) >= 0.99 })
    }

    var body: some View {
        ScrollView(.vertical) {
            welcomeContent
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .frame(width: 560)
        .frame(minHeight: 0, idealHeight: contentHeight > 0 ? contentHeight : nil, maxHeight: .infinity)
        .background(WelcomeWindowFitting(contentHeight: contentHeight))
        .onDisappear {
            model.settings.didShowWelcome = true
            if didDragMap, model.isScrubbing { model.resetToNow() }
        }
    }

    private var welcomeContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                // 未登记的副本有时只返回方形原图，保留图标原有的留白与圆角。
                Group {
                    if applicationIcon.needsMask {
                        Image(nsImage: applicationIcon.image).resizable()
                            .frame(width: 45, height: 45)
                            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    } else {
                        Image(nsImage: applicationIcon.image).resizable().frame(width: 56, height: 56)
                    }
                }
                    .frame(width: 56, height: 56)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("欢迎使用 Dayside").appFont(.title2, weight: .semibold)
                    Text("每个地方的几点，都在这里。").appFont(.callout).foregroundStyle(.readableSecondary)
                }
            }
            // 昼夜地图当主图：Dayside 名字的本义，第一眼就看到；首启还没有地点时只有昼夜与太阳。
            // 图标与地图呼应：暗色行星边缘上刚露头的日出。
            // 显式定高：GeometryReader 没有理想尺寸，窗口会按默认高度把地图压到 150 pt（此前实测 300 × 150）。
            // 主图的底边一角写题记「天涯共此时」（其余语言是 John Muir 的原句），与拷贝出去的海报同一种放法。
            // 学一次：欢迎页的地图也能拖（这里不连按放大，面板才有），下面那句话教一下，拖一次就收起。
            VStack(alignment: .leading, spacing: 0) {
                WorldMapView(interactive: true, highlightZone: localZone?.id, cornerRadius: 8, onTimeDragged: {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { didDragMap = true }
                }, avoid: [epigraphBox.insetBy(dx: -14, dy: -14)])
                    .frame(width: 512, height: 196)
                    .overlay {
                        MapEpigraph(instant: opened, size: mapSize,
                                    latitudes: WorldMapScene.standard, locale: model.core.uiLocale, avoidingPoint: localPoint)
                            // 题记叠在地图外层：反色开着时自己预反一次，与地图（在 WorldMapScene 里整块反）一致。
                            .modifier(SkyPreInvert())
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(contrast == .increased ? Color.primary : Color.secondary.opacity(0.9), lineWidth: contrast == .increased ? 1 : 0.75) }
                dragCaption
            }
            VStack(alignment: .leading, spacing: 12) {
                step("menubar.rectangle", "菜单栏里的时钟：点一下，就是这张图和各地几点。")
                step("magnifyingglass", "在面板顶部搜索城市来添加地点，23.5 万座城市离线可搜。")
                step("square.grid.2x2", "面板底部的“时间工具”：找碰头时间、换算，还有更多。")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { panelColors; Spacer(minLength: 8); loginToggle }
                VStack(alignment: .leading, spacing: 8) { panelColors; loginToggle }
            }
            .appFont(.callout)
            // 三个按钮一行放不下（ru「Открыть инструменты времени」被截）就退成两行。
            ViewThatFits(in: .horizontal) {
                HStack { addLocalSlot; openToolsButton; Spacer(); startButton }
                VStack(alignment: .leading, spacing: 8) {
                    HStack { addLocalSlot; openToolsButton }
                    HStack { Spacer(); startButton }
                }
                VStack(alignment: .leading, spacing: 8) {
                    addLocalSlot
                    openToolsButton
                    HStack { Spacer(); startButton }
                }
            }
        }
        .padding(24)
        // 560 宽：地图 512 × 196（裁掉两极，2.61 : 1），签名图形当海报。
        .frame(width: 560)
    }

    private var localZone: TimeZoneEntry? { model.zones.first { $0.timezoneID == TimeZone.current.identifier } }
    private var mapSize: CGSize { CGSize(width: 512, height: 196) }
    private var localPoint: CGPoint? {
        guard let coordinate = localZone?.coordinate else { return nil }
        return MapProbe.point(latitude: coordinate.latitude, longitude: coordinate.longitude, in: mapSize, latitudes: WorldMapScene.standard)
    }
    private var epigraphBox: CGRect {
        MapEpigraph.placement(instant: opened, size: mapSize, latitudes: WorldMapScene.standard, locale: model.uiLocale, avoidingPoint: localPoint).box
    }
    private var panelColors: some View {
        @Bindable var model = model
        return HStack(spacing: 8) {
            Text("面板底色").fixedSize()
            Picker("面板底色", selection: $model.settings.panelColors) {
                Text("跟着天色").tag(PanelColors.sky)
                Text("跟着系统").tag(PanelColors.system)
            }
            .labelsHidden().pickerStyle(.segmented).fixedSize()
        }
    }
    private var loginToggle: some View {
        Toggle("开机自启", isOn: $options.openAtLogin).toggleStyle(.checkbox).fixedSize()
    }

    /// 地图下面那句「拖一下地图，太阳跟着手走」：这一扇窗里第一次拖动后高度收作 0（减弱动态效果时不动画）。
    private var dragCaption: some View {
        Text("拖一下地图，太阳跟着手走")
            .appFont(.caption)
            .foregroundStyle(.readableSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 8)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if $0 > dragCaptionHeight { dragCaptionHeight = $0 } }
            .frame(height: didDragMap ? 0 : dragCaptionHeight, alignment: .top)
            .clipped()
            .accessibilityHidden(didDragMap)
    }

    /// 本机的地点那一格：没加时是「添加 …」按钮；加过后换成静态的「已添加 …」行，
    /// 不再留一个按不动的灰按钮。行高由同一行里其余的真按钮定住，换格时版面不跳。
    @ViewBuilder private var addLocalSlot: some View {
        if WelcomeLocalPlace.showsAddedRow(zones: model.zones, currentTimeZoneID: TimeZone.current.identifier) {
            HStack(spacing: 4) {
                Image(systemName: "checkmark")
                Text("已添加 \(model.core.placeName(forTimeZoneID: TimeZone.current.identifier))")
            }
            .appFont(.callout)
            .foregroundStyle(.readableSecondary)
            .fixedSize()
            .accessibilityElement(children: .combine)
        } else {
            addLocalButton
        }
    }

    private var addLocalButton: some View {
        Button {
            model.addZone(ZoneCatalog.shared.option(for: TimeZone.current.identifier)
                          ?? ZoneOption(identifier: TimeZone.current.identifier, coordinate: nil))
            AccessibilityNotification.Announcement(String(format: L10n.string("已添加 %@", locale: model.uiLocale), model.core.placeName(forTimeZoneID: TimeZone.current.identifier))).post()
        } label: {
            Text("添加 \(model.core.placeName(forTimeZoneID: TimeZone.current.identifier))")
        }
        .fixedSize()
    }

    private var openToolsButton: some View {
        Button("打开时间工具") { openWindow(id: "tools") }.fixedSize()
    }

    private var startButton: some View {
        Button("开始使用") {
            model.finishWelcome(openAtLogin: options.openAtLogin)
            dismissWindow(id: "welcome")
        }
            .keyboardShortcut(.defaultAction)
            .fixedSize()
    }

    private func step(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: {
            Image(systemName: symbol).frame(width: 22).foregroundStyle(.tint)
        }
        .appFont(.callout)
    }
}

private struct WelcomeWindowFitting: NSViewRepresentable {
    let contentHeight: CGFloat

    func makeNSView(context: Context) -> FittingView { FittingView() }

    func updateNSView(_ view: FittingView, context: Context) {
        view.contentHeight = contentHeight
        view.scheduleFit()
    }

    final class FittingView: NSView {
        var contentHeight: CGFloat = 0
        private var fittedHeight: CGFloat?
        private var scheduled = false
        private var manualResize = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            fittedHeight = nil
            manualResize = false
            scheduleFit()
        }

        override func viewWillStartLiveResize() {
            super.viewWillStartLiveResize()
            manualResize = true
        }

        func scheduleFit() {
            guard !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduled = false
                guard !self.manualResize, self.contentHeight.isFinite, self.contentHeight > 0,
                      self.fittedHeight != self.contentHeight, let window = self.window,
                      !window.inLiveResize, !window.styleMask.contains(.fullScreen),
                      let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else { return }
                #if DEBUG
                if ApplicationSession.uiTestWindowSize != nil { return }
                #endif
                self.fittedHeight = self.contentHeight
                let inset = max(0, window.frame.height - window.contentLayoutRect.height)
                let frame = SettingsWindowSizingCoordinator.boundedFrame(
                    before: window.frame,
                    preferredSize: NSSize(width: 560, height: ceil(self.contentHeight + inset)),
                    visibleFrame: visible)
                window.setFrame(frame, display: true, animate: false)
            }
        }
    }
}

struct WelcomeOptions: Sendable {
    var openAtLogin = true
}

/// 欢迎页「本机的地点」那一格的取舍（纯逻辑，便于测试）：本机时区已在列表里 → 静态的「已添加 …」，否则按钮。
enum WelcomeLocalPlace {
    static func showsAddedRow(zones: [TimeZoneEntry], currentTimeZoneID: String) -> Bool {
        zones.contains { $0.timezoneID == currentTimeZoneID }
    }
}
