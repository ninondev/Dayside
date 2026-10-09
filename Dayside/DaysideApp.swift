// SPDX-License-Identifier: GPL-3.0-only
//
//  DaysideApp.swift
//  Dayside
//
//  @main 入口。MenuBarExtra(window 风格)放菜单栏标签 + 富 UI 面板;另开 Settings 场景。
//

import SwiftUI

@main
@MainActor
enum DaysideEntry {
    static func main() {
        #if DEBUG
        TestHostWindowPolicy.installIfNeeded()
        #endif
        DaysideApp.main()
    }
}

struct DaysideApp: App {
    @NSApplicationDelegateAdaptor(MenuBarPresenceController.self)
    private var menuBarPresence
    @State private var model = AppModel.shared
    @State private var features = FeatureHub.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    init() {
        // 发布门 / 峰值量尺下把启动拆成两段（exec → App.init 是 dyld 与静态初始化，init → 就绪是我们自己的）：
        // 这一行在 AppModel.shared / FeatureHub.shared 构造之前，只在 MEANTIME_RELEASE_GATE=1 时打印。
        if ProcessInfo.processInfo.environment["MEANTIME_RELEASE_GATE"] == "1" {
            FileHandle.standardOutput.write(Data("MEANTIME_RELEASE_GATE_INIT \(LaunchClock.secondsSinceProcessStart())\n".utf8))
        }
    }

    var body: some Scene {
        MenuBarExtra(isInserted: menuBarInsertionBinding) {
            LocalizedRoot { PopoverRootView() }.environment(model).environment(model.core).environment(\.featureHub, features)
        } label: {
            LocalizedRoot { MenuBarLabelView() }.environment(model).environment(model.core).environment(\.featureHub, features)
                .onAppear {
                    features.attach(to: model)
                    #if DEBUG
                    if UITestFixture.hasLongMeeting { _ = features.agenda }
                    #endif
                    DiagnosticsLog.note("launch", "menu bar label appeared · version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")) · zones=\(model.core.zones.count) recovered=\(model.zonesRecoveryNotice) isolated=\(ApplicationSession.isIsolated)")
                    if !ApplicationSession.isIsolated {
                        NSApplication.shared.servicesProvider = TimeConversionService.shared
                    }
                    menuBarPresence.labelDidAppear()
                    // 崩溃 / 卡顿诊断的接收方（零遥测，只写本机文件）；隔离会话不订阅。
                    CrashDiagnostics.startIfAppropriate()
                    // Spotlight 里的地点目录：就绪后 5 秒、后台、版本没变就不写（隔离会话不索引）。
                    SpotlightPlaceIndex.scheduleAfterMenuBarReady(model: model)
                    if ProcessInfo.processInfo.environment["MEANTIME_RELEASE_GATE"] == "1" {
                        FileHandle.standardOutput.write(Data("MEANTIME_RELEASE_GATE_READY_AT \(LaunchClock.secondsSinceProcessStart())\nMEANTIME_RELEASE_GATE_READY\n".utf8))
                    }
                    if let page = ApplicationSession.uiTestPage {
                        features.selection = page
                        openWindow(id: "tools")
                        if ApplicationSession.uiTestForeground {
                            NSApplication.shared.activate(ignoringOtherApps: true)
                        }
                        #if DEBUG
                        AccessibilityDump.scheduleIfRequested(name: page.rawValue, windowPrefix: "tools")
                        // 商店截图：工具窗按要求的尺寸放好再拍（窗口整体尺寸含标题栏，居中）。
                        if let size = ApplicationSession.uiTestWindowSize {
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(400))
                                if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("tools") == true }) {
                                    // 先按整窗尺寸放，再核一次：屏幕装不下时 AppKit 会把 frame 钳到可见区，截图脚本从 stdout 读实际值。
                                    var frame = window.frame
                                    frame.size = size
                                    window.setFrame(frame, display: true, animate: false)
                                    window.center()
                                    let actual = window.frame
                                    FileHandle.standardOutput.write(Data("MEANTIME_UI_TEST_WINDOW applied: \(Int(actual.width))x\(Int(actual.height)) screenVisible=\(Int(NSScreen.main?.visibleFrame.height ?? 0)) styleMask=\(window.styleMask.rawValue) min=\(Int(window.minSize.height)) max=\(Int(min(window.maxSize.height, 1e6))) contentMax=\(Int(min(window.contentMaxSize.height, 1e6)))\n".utf8))
                                }
                            }
                        }
                        #endif
                    }
                    // 内存巡回量尺（隔离预览也认，装机版不认）：Release 数字才是真的。
                    MemoryTourProbe.runIfRequested(hub: features, open: { openWindow(id: "tools") }, openEarth: { openWindow(id: "earth") })
                    #if DEBUG
                    if let appearance = ApplicationSession.uiTestAppearance {
                        NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
                    }
                    PerformanceProbe.runIfRequested(model: model, hub: features, open: { openWindow(id: $0) }, settings: { openSettings() })
                    DiagnosticsReport.runProbeIfRequested(model: model, hub: features)
                    EarthFullscreenProbe.runIfRequested(open: { openWindow(id: "earth") })
                    WindowCloseProbe.runIfRequested()
                    MenuShortcutProbe.runIfRequested()
                    HotkeyProbe.runIfRequested()
                    if let surface = ApplicationSession.uiTestSurface {
                        switch surface {
                        case "panel": openWindow(id: "audit-panel")
                        case "welcome": openWindow(id: "welcome")
                        case "earth": openWindow(id: "earth")
                        default: openSettings()
                        }
                        if ApplicationSession.uiTestForeground {
                            NSApplication.shared.activate(ignoringOtherApps: true)
                        }
                        if let size = ApplicationSession.uiTestWindowSize {
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(400))
                                let prefix = surface == "panel" ? "audit-panel" : surface == "settings" ? "com_apple_SwiftUI_Settings" : surface
                                if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix(prefix) == true }) {
                                    var frame = window.frame
                                    frame.size = size
                                    window.setFrame(frame, display: true, animate: false)
                                    window.center()
                                    FileHandle.standardOutput.write(Data("MEANTIME_UI_TEST_WINDOW applied: \(Int(window.frame.width))x\(Int(window.frame.height))\n".utf8))
                                }
                            }
                        }
                        if surface == "earth", let raw = ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_JUMP_HOURS"], let hours = Double(raw) {
                            model.jump(to: model.now.addingTimeInterval(hours * 3600), animated: false)
                        }
                        if surface == "earth", ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_EARTH_STATE"] != nil {
                            Task { @MainActor in
                                let target = await ChromeReviewFixture.prepareEarth(model: model)
                                AccessibilityDump.scheduleIfRequested(name: target.name, windowPrefix: target.prefix,
                                                                      minimumViews: target.name == "earthPoster" ? 1 : 2)
                            }
                        } else {
                            AccessibilityDump.scheduleIfRequested(name: surface, windowPrefix: surface == "panel" ? "audit-panel" : surface == "welcome" ? "welcome" : surface == "earth" ? "earth" : "com_apple_SwiftUI_Settings",
                                                                  minimumViews: surface == "earth" ? 2 : surface == "welcome" ? 4 : 25)
                        }
                        // 截图 / 转储用：面板出来后删掉第一个地点并按住撤销提示（相当于指针停在上面），
                        // 让「已删除 X · 撤销」这一行能被拍到、被审计到。
                        if surface == "panel", ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_PANEL_EXPAND_AFTER"] == "1" {
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(800))
                                model.settings.planner.isExpanded = true
                            }
                        }
                        if surface == "panel", ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_PANEL_REMOVE_FIRST"] == "1" {
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(800))
                                if let first = model.zones.first { model.removeZone(id: first.id) }
                                // 转储日志里留一行：面板窗口有没有 UndoManager、删除登记进去没有（⌘Z 路径的证据）。
                                print("MEANTIME_PANEL_UNDO manager=\(model.panelUndoManager == nil ? "none" : "yes") canUndo=\(model.panelUndoManager?.canUndo ?? false)")
                            }
                        }
                    }
                    #endif
                }
                .onDisappear { menuBarPresence.labelDidDisappear() }
                .task {
                    // 等菜单栏建好后显示首次启动的欢迎页。
                    do {
                        try await Task.sleep(for: .milliseconds(600))
                    } catch {
                        return
                    }
                    // 只在一个地点都没有的首次启动显示，且只出一次。
                    if !model.settings.didShowWelcome, model.zones.isEmpty, !ApplicationSession.isIsolated {
                        openWindow(id: "welcome")
                        NSApplication.shared.activate(ignoringOtherApps: true)
                    }
                }
        }
        .menuBarExtraStyle(.window)   // window 风格:才能放富 UI 与系统玻璃

        Settings {
            LocalizedRoot { SettingsRootView() }.environment(model).environment(model.core)
        }
        .commands {
            CommandGroup(replacing: .help) {
                Button(L10n.string("帮助", locale: model.uiLocale)) {
                    SettingsNavigation.shared.tab = .help
                    openSettings()
                }
                .keyboardShortcut("?", modifiers: .command)
            }
        }

        // 首次启动的欢迎页：只出一次，隔离会话不出；`MEANTIME_UI_TEST_SURFACE=welcome` 供截图与转储。
        Window("Dayside", id: "welcome") {
            LocalizedRoot { WelcomeView() }.environment(model).environment(model.core)
        }
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        // 地球窗：面板地图连按两次或右上角的按钮打开；只在显式打开时存在。
        // 场景标题跟**系统**语言走、不跟界面语言（俄语界面下曾是「地球」），所以这里只放品牌名，
        // 窗口标题由 `EarthView` 的 `navigationTitle` 按界面语言给（`l10n_partition --check` 拦中日韩字面量的场景标题）。
        Window("Dayside", id: "earth") {
            LocalizedRoot { EarthView() }.environment(model).environment(model.core)
                .windowFullScreenBehavior(.enabled)
                .windowToolbarFullScreenVisibility(.onHover)
        }
        .defaultSize(width: 960, height: 470)
        .windowManagerRole(.principal)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Window("Dayside", id: "tools") {
            LocalizedRoot { FeatureWorkspaceView(hub: features) }
                .environment(model).environment(model.core).environment(\.featureHub, features)
                .onOpenURL { url in
                    // 隔离预览与测试宿主不接受会改数据的命令（它们不该碰共享数据）；
                    // 只放行纯导航（打开某一页、换算一句话），峰值量尺（Tools/peak_gate.sh）靠它按页打开。
                    if !ApplicationSession.isIsolated || FeatureHub.isNavigationOnly(url) { features.handle(url: url) }
                }
        }
        .defaultSize(width: 780, height: 540)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .handlesExternalEvents(matching: ["*"])

        #if DEBUG
        // Audit-only host for the menu bar panel: the same view MenuBarExtra shows, in a plain window
        // the accessibility dump can open. Never opened outside the test host.
        Window("Dayside Panel", id: "audit-panel") {
            LocalizedRoot { PopoverRootView() }.environment(model).environment(model.core).environment(\.featureHub, features)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        #endif
    }

    private var menuBarInsertionBinding: Binding<Bool> {
        Binding(
            get: { menuBarPresence.isInserted },
            set: { menuBarPresence.setInsertionFromSystem($0) }
        )
    }
}

/// 把界面语言注入环境 `\.locale`,让内部所有本地化 `Text` 随设置即时切换。
/// 做成读 `model.uiLocale` 的 View(而非在 App body 里直接注入),保证语言一改就重渲。
private struct LocalizedRoot<Content: View>: View {
    @Environment(AppModel.self) private var model
    @ViewBuilder var content: Content
    var body: some View {
        content
            .environment(\.locale, model.uiLocale)
            // 文字大小三档：所有窗口与面板都经过这里，菜单栏标签不在内（系统托管）。
            .environment(\.textScale, model.settings.textSize.scale)
    }
}
