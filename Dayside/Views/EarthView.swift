// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI

struct EarthView: View {
    var copyPasteboard: NSPasteboard? = nil
    @Environment(AppModel.self) private var model
    @Environment(TimeCore.self) private var core
    @Environment(\.textScale) private var textScale
    @FocusState private var mapFocused: Bool
    @State private var status: CopyStatus?
    @State private var statusStamp = 0
    @State private var window: NSWindow?
    @State private var fullScreen = false
    @State private var footerHeight: CGFloat = 24

    private enum CopyStatus { case copied, failed }
    private var earthInk: Color { SkyTextRole.earthLabel.foreground(on: LightPalette.luminanceOfNightSky) }

    var body: some View {
        GeometryReader { proxy in
            let ratio = 360 / (WorldMapScene.standard.upperBound - WorldMapScene.standard.lowerBound)
            let width = min(proxy.size.width, max(1, proxy.size.height - footerHeight - 10) * ratio)
            let scale = min(2, max(1, width / 928))
            VStack(spacing: 10) {
                WorldMapView(interactive: true, showsLabels: true, scale: scale, onCopied: report)
                    .frame(width: width, height: width / ratio)
                    .focusable(interactions: .edit)
                    .focused($mapFocused)
                    .focusEffectDisabled()
                    .onCommand(#selector(NSText.copy(_:))) { copyImage() }
                    .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
                        let minutes = press.modifiers.contains(.option) ? 15 : 60
                        model.jump(to: MapScrub.step(from: core.referenceDate, minutes: minutes, forward: press.key == .rightArrow, in: .current),
                                   animated: press.phase == .down)
                        return .handled
                    }
                statusLine(scale: scale)
                    .frame(width: width, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                        if abs(footerHeight - $0) > 0.5 { footerHeight = max(24, $0) }
                    }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)
        .ignoresSafeArea(.container, edges: fullScreen ? .top : [])
        .foregroundStyle(earthInk)
        #if DEBUG
        .modifier(SkyA11yFixtures())
        #endif
        .frame(minWidth: 560, idealWidth: 960, minHeight: 360, idealHeight: 418)
        .background(LightPalette.nightSky.ignoresSafeArea())
        .background(EarthWindowAccess(window: $window, fullScreen: $fullScreen))
        .preferredColorScheme(.dark)
        .toolbarBackground(LightPalette.nightSky, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .navigationTitle(L10n.string("地球", locale: core.uiLocale))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { report(model.copyAllPlaceTimes() != nil) } label: {
                    Label("复制全部各地时间", systemImage: "doc.on.doc")
                        .foregroundStyle(earthInk)
                }
                .help(Text("复制全部各地时间"))
                .disabled(core.zones.isEmpty)
                Button { copyImage() } label: {
                    Label("拷贝这张图", systemImage: "photo").foregroundStyle(earthInk)
                }
                    .help(Text("拷贝这张图"))
                    .keyboardShortcut("c", modifiers: .command)
                Button { EarthWindowActions.toggleFullscreen(in: window) } label: {
                    Label(L10n.string(fullScreen ? "退出全屏" : "全屏", locale: core.uiLocale), systemImage: fullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .foregroundStyle(earthInk)
                }
                .help(Text("全屏，可以放在副屏上当桌钟（⌃⌘F）"))
                .keyboardShortcut("f", modifiers: [.control, .command])
            }
        }
        .task(id: statusStamp) {
            guard status != nil else { return }
            #if DEBUG
            if ApplicationSession.isTesting,
               ["copied", "copyFailed"].contains(ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_EARTH_STATE"] ?? "") { return }
            #endif
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled { status = nil }
        }
        .onAppear {
            model.setEarthVisible(true); mapFocused = true
            #if DEBUG
            if ApplicationSession.isTesting {
                switch ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_EARTH_STATE"] {
                case "copyFailed": report(false)
                case "copied":
                    let pasteboard = NSPasteboard(name: .init("com.dayside.review.\(UUID().uuidString)"))
                    report(EarthPoster.copy(model: model, core: core, pasteboard: pasteboard))
                    pasteboard.releaseGlobally()
                default: break
                }
            }
            #endif
        }
        .onDisappear { model.setEarthVisible(false) }
    }

    private func statusLine(scale: CGFloat) -> some View {
        ViewThatFits(in: .horizontal) {
            footer(compact: false, iconOnly: false, date: true, scale: scale)
            footer(compact: true, iconOnly: false, date: true, scale: scale)
            footer(compact: true, iconOnly: true, date: true, scale: scale)
            footer(compact: true, iconOnly: true, date: false, scale: scale)
        }
        .font(.system(size: AppFont.size(.callout) * min(scale, 1.5) * textScale).monospacedDigit())
        .foregroundStyle(earthInk)
        .frame(minHeight: 24)
    }

    private func footer(compact: Bool, iconOnly: Bool, date: Bool, scale: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            let caption = footerCaption(compact: compact, date: date, scale: scale)
            caption.text
                .fixedSize()
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(verbatim: caption.spoken))
            Spacer(minLength: 8)
            if let status {
                if status == .copied { Label("已复制", systemImage: "checkmark").fixedSize() }
                else { ErrorLine(Text("无法复制，请重试。")).fixedSize() }
            } else if !core.zones.contains(where: { $0.coordinate != nil }) {
                Text("在菜单栏面板里添加的地点会出现在这张图上。")
                    .font(.system(size: AppFont.size(.caption) * min(scale, 1.5) * textScale))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if core.isScrubbing {
                Button { model.resetToNow() } label: {
                    if iconOnly { Image(systemName: "arrow.uturn.backward").frame(minWidth: 24, minHeight: 24).contentShape(Rectangle()) }
                    else { Label("回到现在", systemImage: "arrow.uturn.backward").frame(minWidth: 24, minHeight: 24).contentShape(Rectangle()) }
                }
                .fontWeight(.semibold).buttonStyle(.plain).fixedSize()
                .accessibilityLabel(Text("回到现在")).help(Text("回到现在"))
                .keyboardShortcut(.cancelAction)
            }
        }
    }

    private func footerCaption(compact: Bool, date: Bool, scale: CGFloat) -> (text: Text, spoken: String) {
        let day = ClockText.day(core.referenceDate, in: .current, locale: core.uiLocale, now: core.now, weekday: true)
        guard core.isScrubbing else { return (Text(verbatim: day), day) }
        let caption = Self.scrubCaption(day: day,
                                        clock: ClockText.time(core.referenceDate, in: .current, hourStyle: core.settings.hourStyle),
                                        fullShift: SliderPosition.offsetLabel(seconds: core.displayOffset, locale: core.uiLocale),
                                        compactShift: compact ? PresentationCore.call("scroll_label", ["seconds": core.displayOffset]) : nil,
                                        date: date,
                                        clockFont: .system(size: AppFont.size(.callout) * min(scale, 1.5) * textScale, weight: .semibold).monospacedDigit(),
                                        locale: core.uiLocale)
        return (caption.visual, caption.spoken)
    }

    /// 视觉底栏可省日期；读屏始终保留完整日期、钟点和时间偏移。
    static func scrubCaption(day: String, clock: String, fullShift: String, compactShift: String?, date: Bool,
                             clockFont: Font, locale: Locale) -> (visual: Text, spoken: String) {
        var clockText = AttributedString(clock)
        clockText.font = clockFont
        let shift = compactShift ?? fullShift
        let visual = Text(AttributedString(date ? day + " · " : "") + clockText + AttributedString(" · " + shift))
        let spoken = String(format: L10n.string("本机%1$@ %2$@，%3$@", locale: locale), day, clock, fullShift)
        return (visual, spoken)
    }

    private func copyImage() { report(EarthPoster.copy(model: model, core: core, pasteboard: copyPasteboard ?? .general)) }

    private func report(_ ok: Bool) {
        status = ok ? .copied : .failed
        statusStamp += 1
        AccessibilityNotification.Announcement(L10n.string(ok ? "已复制" : "无法复制，请重试。", locale: core.uiLocale)).post()
    }
}

private struct EarthWindowAccess: NSViewRepresentable {
    @Binding var window: NSWindow?
    @Binding var fullScreen: Bool
    func makeNSView(context: Context) -> Reader { Reader() }
    func updateNSView(_ view: Reader, context: Context) {
        view.changed = { window = $0; fullScreen = $0?.styleMask.contains(.fullScreen) ?? false }
    }
    static func dismantleNSView(_ view: Reader, coordinator: ()) { view.changed = nil; view.stopObserving() }
    final class Reader: NSView {
        var changed: ((NSWindow?) -> Void)?
        private var observers: [NSObjectProtocol] = []
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            DispatchQueue.main.async { [weak self] in guard let self else { return }; self.changed?(self.window) }
            guard let window else { return }
            for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            self.changed?(self.window)
                        }
                    }
                })
            }
        }
        func stopObserving() { observers.forEach(NotificationCenter.default.removeObserver); observers = [] }
    }
}

/// 「拷贝地图图片」：此刻的整张地图（天色、海陆与地形、晨昏线、太阳、城市灯火、地点的名字与当地时间）
/// 当一张海报：左上角字标「DAYSIDE」、右上角本机那一刻，底边一角题「天涯共此时」（中文界面，下面一行英文原句
/// 「It is always sunrise somewhere.」，John Muir；其余语言只有英文那一句），不署名。
/// 题字放在底边更暗的那一角，字色按底下的明暗实算选墨或纸，地点的标签绕开字。1200 pt 宽（2.61 : 1）、2 倍像素
/// （2400 × 920），`ImageRenderer` 离屏渲染，与名片同一条复制路（PNG + TIFF，聊天软件与备忘录都收）；不联网、不写文件。
@MainActor
enum EarthPoster {
    static let width: CGFloat = 1200
    static var height: CGFloat { (width * (WorldMapScene.standard.upperBound - WorldMapScene.standard.lowerBound) / 360).rounded() }
    /// 字标、时刻、题字离图边的距离：宽的 4.5%。
    static var margin: CGFloat { (width * 0.045).rounded() }
    static let lights = 1.1

    struct Content: View {
        let instant: Date
        let places: [WorldMapPlace]
        let labels: [MapLabel]
        let caption: String
        let locale: Locale

        var body: some View {
            let size = CGSize(width: EarthPoster.width, height: EarthPoster.height)
            let margin = EarthPoster.margin
            let raster = MapRaster.render(instant: instant, size: size, scale: 2, latitudes: WorldMapScene.standard, lights: EarthPoster.lights, large: true)
            let setting = Epigraph.setting(locale: locale, scale: 1)
            let block = setting.size
            let (box, onRight) = Epigraph.placement(block: block, in: size, margin: margin, vertical: setting.vertical,
                                                    luminance: raster.map { r in { r.luminance(in: $0) } })
            let titlePaper = LightPalette.paperReads(on: raster?.luminance(in: box) ?? 0)
            let small = NSFont.systemFont(ofSize: 13, weight: .medium)
            let markSize = ("DAYSIDE" as NSString).size(withAttributes: [.font: small, .kern: 4.2])
            let captionSize = (caption as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular), .kern: 0.4])
            let markBox = CGRect(x: margin, y: margin * 0.8, width: markSize.width, height: markSize.height)
            let captionBox = CGRect(x: size.width - margin - captionSize.width, y: margin * 0.8, width: captionSize.width, height: captionSize.height)
            ZStack(alignment: .topLeading) {
                WorldMapScene(instant: instant, places: places, latitudes: WorldMapScene.standard, labels: labels, labelSize: 19, large: true,
                              lights: EarthPoster.lights, showsMoon: false, rasterScale: 2,
                              avoid: [box.insetBy(dx: -14, dy: -14), markBox.insetBy(dx: -8, dy: -8), captionBox.insetBy(dx: -8, dy: -8)])
                    .frame(width: size.width, height: size.height)
                PosterText(paper: LightPalette.paperReads(on: raster?.luminance(in: markBox) ?? 0)) {
                    Text(verbatim: "DAYSIDE").font(.system(size: 13, weight: .medium)).kerning(4.2)
                }
                .fixedSize()
                .position(x: markBox.midX, y: markBox.midY)
                PosterText(paper: LightPalette.paperReads(on: raster?.luminance(in: captionBox) ?? 0)) {
                    Text(verbatim: caption).font(.system(size: 13).monospacedDigit()).kerning(0.4)
                }
                .fixedSize()
                .position(x: captionBox.midX, y: captionBox.midY)
                PosterText(paper: titlePaper) {
                    EpigraphText(setting: setting, trailing: onRight)
                }
                .fixedSize()
                .frame(width: block.width, alignment: onRight ? .trailing : .leading)
                .position(x: box.midX, y: box.midY)
            }
            .frame(width: size.width, height: size.height)
            .environment(\.locale, locale)
        }
    }

    /// 海报上的字：纸色衬深色光晕、墨色衬浅色光晕（与地图上的标签同一种写法，光晕更宽一点）。
    private struct PosterText<Content: View>: View {
        let paper: Bool
        @ViewBuilder let content: Content
        var body: some View {
            let halo = paper ? LightPalette.haloDark : LightPalette.haloLight
            MapText(paper: paper, role: .earthLabel) { content }
                .compositingGroup()
                .shadow(color: halo.opacity(0.85), radius: 1.5)
                .shadow(color: halo.opacity(0.6), radius: 6)
        }
    }

    struct Input {
        let instant: Date
        let places: [WorldMapPlace]
        let labels: [MapLabel]
        let caption: String
        let locale: Locale
    }

    static func input(model: AppModel, core: TimeCore) -> Input {
        let (zones, places) = WorldMapView.places(in: core)
        let labels = zones.map { WorldMapView.label(for: $0, model: model, core: core) }
        let home = core.placeName(forTimeZoneID: TimeZone.current.identifier)
        let moment = ClockText.dateTime(core.referenceDate, in: .current, hourStyle: core.settings.hourStyle,
                                       locale: core.uiLocale, now: core.now, weekday: true)
        return Input(instant: core.referenceDate, places: places, labels: labels,
                     caption: home.isEmpty ? moment : "\(home) · \(moment)", locale: core.uiLocale)
    }

    /// 像素直接画进系统页，编码器顺着写出，不留大块 malloc 缓冲。
    /// 页由图的数据源在 CoreGraphics 放掉这张图时交回 `PixelPool`（与 `MapRaster` 同法）：ImageIO 可能比本函数
    /// 更晚放手，按作用域归还会让还活着的图指向已复用或已 `vm_deallocate` 的页。
    static func data(_ input: Input, type: CFString = "public.png" as CFString) -> Data? {
        defer { MapRelief.usedOffscreen() }
        let pixelWidth = Int(width * 2), pixelHeight = Int(height * 2)
        let length = pixelWidth * pixelHeight * 4
        guard let pixels = PixelPool.take(length) else { return nil }
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let rendered: Bool = {
            guard let context = CGContext(data: pixels, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
                                          bytesPerRow: pixelWidth * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            let renderer = ImageRenderer(content: Content(instant: input.instant, places: input.places, labels: input.labels,
                                                           caption: input.caption, locale: input.locale))
            renderer.render(rasterizationScale: 2) { _, draw in
                context.scaleBy(x: 2, y: 2)
                draw(context)
            }
            return true
        }()
        guard rendered, let provider = CGDataProvider(dataInfo: nil, data: pixels, size: length, releaseData: { _, data, size in
            PixelPool.give(data, length: size)
        }) else {
            PixelPool.give(pixels, length: length)
            return nil
        }
        guard let image = CGImage(width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: pixelWidth * 4, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        let bytes = EncodedBytes()
        var callbacks = CGDataConsumerCallbacks(putBytes: { info, buffer, count in
            guard let info else { return 0 }
            return Unmanaged<EncodedBytes>.fromOpaque(info).takeUnretainedValue().append(buffer, count: count) ? count : 0
        }, releaseConsumer: { _ in })
        guard let consumer = CGDataConsumer(info: Unmanaged.passUnretained(bytes).toOpaque(), cbks: &callbacks),
              let destination = CGImageDestinationCreateWithDataConsumer(consumer, type, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return bytes.finish()
    }

    @discardableResult
    static func copy(model: AppModel, core: TimeCore, pasteboard: NSPasteboard = .general) -> Bool {
        copy(input(model: model, core: core), pasteboard: pasteboard)
    }

    @discardableResult
    static func copy(_ input: Input, pasteboard: NSPasteboard) -> Bool {
        guard let png = data(input) else { return false }
        let item = NSPasteboardItem()
        guard item.setData(png, forType: .png) else { return false }
        let provider = TIFFProvider(input: input)
        item.setDataProvider(provider, forTypes: [.tiff])
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }

    /// 剪贴板只留输入；其它 App 索要 TIFF 时才重画。
    @MainActor final class TIFFProvider: NSObject, NSPasteboardItemDataProvider {
        private let input: Input
        private(set) var renderCount = 0

        init(input: Input) { self.input = input }

        nonisolated func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
            guard type == .tiff else { return }
            let request = ItemRequest(item: item)
            if Thread.isMainThread {
                MainActor.assumeIsolated { provideTIFF(request) }
            } else {
                DispatchQueue.main.sync { provideTIFF(request) }
            }
        }

        private func provideTIFF(_ request: ItemRequest) {
            renderCount += 1
            if let tiff = EarthPoster.data(input, type: "public.tiff" as CFString) { request.item.setData(tiff, forType: .tiff) }
        }

        /// 调用方同步等待，交接期间只有主线程访问这个 AppKit 对象。
        nonisolated private struct ItemRequest: @unchecked Sendable {
            let item: NSPasteboardItem
        }
    }

    /// 编码字节用可增长的系统页，交给 Data 后由它还给系统。
    nonisolated private final class EncodedBytes {
        private var address: vm_address_t = 0
        private var capacity = 0
        private var count = 0

        deinit {
            if capacity > 0 { vm_deallocate(mach_task_self_, address, vm_size_t(capacity)) }
        }

        func append(_ source: UnsafeRawPointer, count added: Int) -> Bool {
            guard added <= Int.max - count else { return false }
            let needed = count + added
            if needed > capacity {
                let next = max(needed, max(1_048_576, capacity * 2))
                var grown: vm_address_t = 0
                guard vm_allocate(mach_task_self_, &grown, vm_size_t(next), VM_FLAGS_ANYWHERE) == KERN_SUCCESS,
                      let destination = UnsafeMutableRawPointer(bitPattern: UInt(grown)) else { return false }
                if count > 0, let old = UnsafeRawPointer(bitPattern: UInt(address)) { destination.copyMemory(from: old, byteCount: count) }
                if capacity > 0 { vm_deallocate(mach_task_self_, address, vm_size_t(capacity)) }
                address = grown
                capacity = next
            }
            guard let destination = UnsafeMutableRawPointer(bitPattern: UInt(address)) else { return false }
            destination.advanced(by: count).copyMemory(from: source, byteCount: added)
            count = needed
            return true
        }

        func finish() -> Data? {
            guard count > 0, let pointer = UnsafeMutableRawPointer(bitPattern: UInt(address)) else { return nil }
            let page = Int(getpagesize())
            let allocation = ((count + page - 1) / page) * page
            if allocation < capacity {
                vm_deallocate(mach_task_self_, address + vm_address_t(allocation), vm_size_t(capacity - allocation))
            }
            capacity = 0
            return Data(bytesNoCopy: pointer, count: count, deallocator: .custom { pointer, _ in
                vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: pointer)), vm_size_t(allocation))
            })
        }
    }
}

@MainActor
enum EarthWindowActions {
    static func toggleFullscreen(in window: NSWindow?) { window?.toggleFullScreen(nil) }
}
