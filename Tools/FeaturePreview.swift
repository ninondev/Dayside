// SPDX-License-Identifier: GPL-3.0-only
// Real views with isolated preferences and fake permission providers for visual verification.
import AppKit
import SwiftUI

private actor PreviewContacts: PeopleContactsReading {
    func candidates() async throws -> [PeopleContactCandidate] {
        [.init(id: "preview-ana", name: "Ana"), .init(id: "preview-mei", name: "Mei")]
    }
}

@MainActor private final class PreviewNotifications: LensNotificationClient {
    func authorization() async -> LensNotificationAccess { .denied }
    func requestAuthorization() async throws -> Bool { false }
    func pendingIdentifiers() async -> [String] { [] }
    func deliveredIdentifiers() async -> [String] { [] }
    func add(_ request: LensNotificationRequest) async throws {}
    func removePending(_ identifiers: [String]) {}
    func removeDelivered(_ identifiers: [String]) {}
}

@MainActor private final class PreviewAgenda: AgendaService {
    var authorization: AgendaAuthorization { .fullAccess }
    var activeResourceCount: Int { 0 }
    func requestFullAccess() async throws -> Bool { true }
    func observeChanges(_ receive: @escaping @MainActor @Sendable () -> Void) {}
    func stop() {}
    func snapshot(in interval: DateInterval, calendarIDs: [String]?) async throws -> AgendaSnapshot {
        let now = Date.now.timeIntervalSince1970
        return AgendaSnapshot(calendars: [.init(id: "preview-calendar", title: "Dayside Demo", sourceTitle: "Preview")], events: [
            AgendaEvent(identifier: "preview-1", calendarID: "preview-calendar", title: "London · Tokyo project review",
                        start: now + 15 * 60, end: now + 45 * 60, isAllDay: false, isCancelled: false,
                        isDeclined: false, location: nil, urls: [AgendaURLFacts(url: URL(string: "https://meet.google.com/abc-defg-hij")!)!]),
            AgendaEvent(identifier: "preview-2", calendarID: "preview-calendar", title: "Design discussion",
                        start: now + 3600, end: now + 5400, isAllDay: false, isCancelled: false,
                        isDeclined: false, location: "Studio", urls: [])
        ], interval: interval)
    }
}

/// `MEANTIME_PREVIEW_LANGUAGE` 选界面语言,接受 `InterfaceLanguage` 的 rawValue 与常见写法
/// (`zh-Hans`/`zh`/`pt-BR`/`pt`…),大小写与 `-`/`_` 不敏感;不认识的值回退简体中文。
/// 不接受 `.system`——跟随系统会让截图随机器设置漂移,版式核对要可复现。
private enum PreviewLanguage {
    private static let aliases: [String: InterfaceLanguage] = [
        "zh": .zhHans, "zhcn": .zhHans, "hans": .zhHans, "chs": .zhHans,
        "zhtw": .zhHant, "zhhk": .zhHant, "hant": .zhHant, "cht": .zhHant,
        "pt": .ptBR, "ptpt": .ptBR, "jp": .ja, "kr": .ko
    ]

    private static func normalize(_ raw: String) -> String {
        raw.lowercased().filter { $0 != "-" && $0 != "_" && $0 != " " }
    }

    static var requested: InterfaceLanguage {
        let key = normalize(ProcessInfo.processInfo.environment["MEANTIME_PREVIEW_LANGUAGE"] ?? "")
        if let exact = InterfaceLanguage.allCases.first(where: { $0 != .system && normalize($0.rawValue) == key }) {
            return exact
        }
        return aliases[key] ?? .zhHans
    }
}

@MainActor private final class PreviewSession {
    let model: AppModel
    let hub: FeatureHub
    init() {
        let suite = "com.dayside.FeaturePreview.20260909"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        var settings = AppSettings()
        settings.interfaceLanguage = PreviewLanguage.requested
        settings.didAskLaunchAtLogin = true
        settings.keepAliveInBackground = false
        settings.hourStyle = .force24
        settings.planner.isExpanded = true
        Store.saveSettings(settings, to: defaults)
        Store.saveZones([
            .init(timezoneID: "America/Los_Angeles", cityName: "Los Angeles", coordinate: .init(latitude: 34.05, longitude: -118.24), countryCode: "US"),
            .init(timezoneID: "Europe/London", cityName: "London", coordinate: .init(latitude: 51.51, longitude: -0.13), countryCode: "GB"),
            .init(timezoneID: "Asia/Tokyo", cityName: "Tokyo", coordinate: .init(latitude: 35.68, longitude: 139.69), countryCode: "JP")
        ], to: defaults)
        model = AppModel(defaults: defaults, migrate: false)
        let people = PeopleStore(defaults: defaults, contactsReader: PreviewContacts())
        _ = people.save(PersonProfile(name: "Ana", timeZoneID: "Europe/London", countryCode: "GB"))
        _ = people.save(PersonProfile(name: "Mei", timeZoneID: "Asia/Tokyo", countryCode: "JP"))
        let notifications = PreviewNotifications()
        let agenda = AgendaStore(defaults: defaults, makeService: { PreviewAgenda() }, openURL: { _ in false })
        hub = FeatureHub(defaults: defaults, integrateSystemSurfaces: false, agenda: agenda, people: people,
                         timers: TimerStore(defaults: defaults, notificationClient: notifications, observeSystemEvents: false),
                         dstWatch: DSTWatchStore(defaults: defaults, notificationClient: notifications, observeSystemEvents: false))
        hub.selection = FeatureSelection(rawValue: ProcessInfo.processInfo.environment["MEANTIME_PREVIEW_FEATURE"] ?? "agenda") ?? .agenda
        // The sharing page shows its preview and QR code straight away instead of an empty form.
        hub.sharing.draft.timeZoneID = "Asia/Tokyo"
        hub.sharing.draft.displayName = "Mei"
        hub.sharing.prepare(now: .now, locale: model.uiLocale)  // the interface language, as the production view passes it
        if ProcessInfo.processInfo.environment["MEANTIME_PREVIEW_DEBUG"] == "1" {
            NSLog("[preview] sharing document=%d errors=%@", hub.sharing.document == nil ? 0 : 1, hub.sharing.errors.description)
        }
        hub.attach(to: model)
        agenda.setEnabled(true)
        _ = hub.travel.save(TravelTrip(name: "Tokyo trip · demo", originTimeZoneID: "America/Los_Angeles", destinationTimeZoneID: "Asia/Tokyo",
                                     departureUnix: Date.now.addingTimeInterval(4 * 86400).timeIntervalSince1970,
                                     arrivalUnix: Date.now.addingTimeInterval(4 * 86400 + 11 * 3600).timeIntervalSince1970))
    }
}

/// 商店尺寸截图用:`MEANTIME_PREVIEW_SIZE=宽x高` 指定工具窗大小,缺省 780×540。
/// 内容的理想尺寸会盖过 `defaultSize`,所以窗口出现后再按这个值定帧。
private enum PreviewWindowSize {
    static let `default` = CGSize(width: 780, height: 540)
    static var requested: CGSize {
        guard let raw = ProcessInfo.processInfo.environment["MEANTIME_PREVIEW_SIZE"] else { return `default` }
        let parts = raw.lowercased().split(separator: "x")
        guard parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]),
              width >= 200, height >= 200 else { return `default` }
        return CGSize(width: width, height: height)
    }
}

/// 把承载视图的 NSWindow 定到 `PreviewWindowSize.requested`(只在预览 harness 里用)。
private final class PreviewSizingView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        // 两处实测坑:
        // ① 在 viewDidMoveToWindow 里直接 setFrame,SwiftUI 根本不把窗口放上屏(进程在、窗口数 0),
        //    所以要等这一轮窗口创建走完再定帧;
        // ② AppKit 把窗口夹进 visibleFrame,Dock 占着高度时 900pt 要不到(只给到 852pt)。
        //    对策是请系统在本 app 前台时自动隐藏 Dock。这只是本进程的 presentation option,
        //    退出即恢复,不改用户的 Dock 设置;但它要等 app 真的激活才生效,所以分几次重试。
        Task { @MainActor [weak self] in
            for delay in [0, 200, 400, 800, 1500, 2500, 4000, 5500, 7000] {
                if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
                guard let self, !self.applyRequestedSize() else { return }
            }
        }
    }

    /// 返回 true 表示窗口已经是目标尺寸。
    @discardableResult private func applyRequestedSize() -> Bool {
        guard let window, let screen = window.screen ?? NSScreen.main else { return false }
        let size = PreviewWindowSize.requested
        if window.frame.size == size { return true }
        if screen.visibleFrame.height < size.height || screen.visibleFrame.width < size.width {
            NSApp.presentationOptions = [.autoHideDock]
        }
        let visible = screen.visibleFrame
        let origin = CGPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        window.setFrame(NSRect(origin: origin, size: size), display: true)
        return window.frame.size == size
    }
}

private struct PreviewWindowSizer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { PreviewSizingView(frame: .zero) }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

@main
struct FeaturePreviewApp: App {
    @State private var session = PreviewSession()
    var body: some Scene {
        WindowGroup("Dayside Feature Preview", id: "tools") {
            FeatureWorkspaceView(hub: session.hub)
                .environment(session.model).environment(session.model.core)
                .environment(\.featureHub, session.hub).environment(\.locale, session.model.uiLocale)
                .accessibilityHidden(ProcessInfo.processInfo.environment["MEANTIME_PREVIEW_VISUAL_ONLY"] == "1")
                .toolbar {
                    ToolbarItem(placement: .automatic) {
                        Button("中文 / English") {
                            session.model.settings.interfaceLanguage = session.model.settings.interfaceLanguage == .en ? .zhHans : .en
                        }
                    }
                }
                .background(PreviewWindowSizer())
        }.defaultSize(width: PreviewWindowSize.requested.width, height: PreviewWindowSize.requested.height)
        WindowGroup("Dayside Panel Preview", id: "panel") {
            PopoverRootView().environment(session.model).environment(session.model.core)
                .environment(\.featureHub, session.hub).environment(\.locale, session.model.uiLocale)
        }.windowResizability(.contentSize)
    }
}
