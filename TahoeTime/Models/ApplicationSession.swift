// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin
#if DEBUG
import AppKit
import ObjectiveC
#endif

/// The test runner's app entry point follows the same fixture isolation as its test cases.
/// Production launches use the sandbox container's standard defaults and the legacy-domain migration.
@MainActor
enum ApplicationSession {
    /// A separately identified local build uses only its own sandbox while signing is unavailable.
    /// The production identifier can never opt into this mode by changing a flag alone.
    static let isLocalPreview = Bundle.main.bundleIdentifier == "com.dayside.Dayside.localpreview"
        && Bundle.main.object(forInfoDictionaryKey: "MTLocalPreview") as? Bool == true

    static let isTesting: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.environment["MEANTIME_TEST_HOST"] == "1"
        #else
        false
        #endif
    }()

    static var isIsolated: Bool { isTesting || isLocalPreview }

    /// 截图宿主可以离屏画图，性能量尺遵守生产窗口的遮挡状态。
    static var drawsOccludedMaps: Bool {
        #if DEBUG
        isTesting && !PerformanceProbe.isRequested
        #else
        false
        #endif
    }

    /// 隔离量尺可以强制逐帧跳转，生产会话仍遵守系统偏好。
    static var forceAnimation: Bool {
        isIsolated && ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_FORCE_ANIMATION"] == "1"
    }

    /// 前台验证必须由调用方显式申请。
    static var uiTestForeground: Bool {
        isTesting && ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_FOREGROUND"] == "1"
    }

    /// A UI test names the tool page it wants opened at launch. Only the test host honors it.
    static var uiTestPage: FeatureSelection? {
        guard isTesting, let raw = ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_FEATURE"] else { return nil }
        return FeatureSelection(rawValue: raw)
    }

    /// The other two surfaces an audit can open: the menu bar panel (hosted in a plain window) or Settings.
    static var uiTestSurface: String? {
        guard isTesting, let raw = ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_SURFACE"],
              ["panel", "settings", "welcome", "earth"].contains(raw) else { return nil }
        return raw
    }

    /// 截图与转储要固定外观：`light` / `dark`；只在测试宿主生效。
    static var uiTestAppearance: String? {
        guard isTesting, let raw = ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_APPEARANCE"],
              ["light", "dark"].contains(raw) else { return nil }
        return raw
    }

    /// 商店截图要 1440×900 的工具窗（Retina 下 2880×1800）：`MEANTIME_UI_TEST_WINDOW=1440x900`，只在测试宿主生效。
    static var uiTestWindowSize: CGSize? {
        guard isTesting, let raw = ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_WINDOW"] else { return nil }
        let parts = raw.lowercased().split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, parts[0] >= 400, parts[1] >= 300 else { return nil }
        return CGSize(width: parts[0], height: parts[1])
    }

    static let defaults: UserDefaults = {
        if isLocalPreview && !isTesting {
            guard ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_MEMORY_TOUR"] == "1" else { return .standard }
            for key in UserDefaults.standard.dictionaryRepresentation().keys
            where key.hasPrefix("NSSplitView Subview Frames") || key.hasPrefix("NSWindow Frame") {
                UserDefaults.standard.removeObject(forKey: key)
            }
            let suiteName = "com.dayside.test-host.\(UUID().uuidString)"
            testHostSuiteName = suiteName
            atexit { ApplicationSession.cleanupTestHostSuiteAtExit() }
            let value = UserDefaults(suiteName: suiteName)!
            var settings = AppSettings()
            settings.didAskLaunchAtLogin = true
            settings.didShowWelcome = true
            settings.keepAliveInBackground = false
            settings.launchAtLogin = false
            settings.hourStyle = .force24
            settings.interfaceLanguage = .en
            Store.saveSettings(settings, to: value)
            Store.saveZones([
                TimeZoneEntry(timezoneID: "America/Los_Angeles", cityName: "Los Angeles", coordinate: Coordinate(latitude: 34.05, longitude: -118.24)),
                TimeZoneEntry(timezoneID: "Europe/London", cityName: "London", coordinate: Coordinate(latitude: 51.51, longitude: -0.13)),
                TimeZoneEntry(timezoneID: "Asia/Tokyo", cityName: "Tokyo", coordinate: Coordinate(latitude: 35.68, longitude: 139.69))
            ], to: value)
            return value
        }
        guard isTesting else { return Store.appDefaults }
        let suiteName = "com.dayside.test-host.\(UUID().uuidString)"
        #if DEBUG
        testHostSuiteName = suiteName
        atexit { ApplicationSession.cleanupTestHostSuiteAtExit() }
        // 窗口与分栏的自动保存不走注入的偏好域，写在容器的标准域里，跨每次测试宿主启动：上一种语言的边栏宽度
        // 会盖掉本次按语言算的 ideal（俄语页名被截成「Найти время для…」，八语截图查出）。
        // 只在测试宿主下清，安装版的窗口记忆不动。
        for key in UserDefaults.standard.dictionaryRepresentation().keys
        where key.hasPrefix("NSSplitView Subview Frames") || key.hasPrefix("NSWindow Frame") {
            UserDefaults.standard.removeObject(forKey: key)
        }
        #endif
        let value = UserDefaults(suiteName: suiteName)!
        var settings = AppSettings()
        settings.didAskLaunchAtLogin = true
        settings.keepAliveInBackground = false
        Store.saveSettings(settings, to: value)
        #if DEBUG
        if UITestFixture.isActive { UITestFixture.seed(value) }
        #endif
        return value
    }()

    /// 进程启动时写一次(`defaults` 首次访问)、进程退出时读一次(`atexit`),两端不会真正并发;
    /// `atexit` 回调跑在 C 运行时的退出路径上、不属于 MainActor,只能标 `nonisolated(unsafe)`。
    nonisolated(unsafe) private static var testHostSuiteName: String?

    /// 进程真正退出时(`atexit`,不是 `applicationWillTerminate`——后者会被
    /// `MenuBarPresenceTests.testWillTerminateStopsObserving` 之类的用例在测试运行期间手动调用,
    /// 那时进程远没退出、`AppModel.shared` 仍握着这同一个域,提前删会把还在用的偏好清空)
    /// 把测试宿主自己的一次性偏好域文件删掉。
    nonisolated private static func cleanupTestHostSuiteAtExit() {
        guard let name = testHostSuiteName else { return }
        discardOneOffSuite(named: name)
    }

    /// 一次性 UserDefaults suite 用完即删:`removePersistentDomain` 只清空内存态,
    /// cfprefsd 仍把(此时已空的)plist 留在磁盘;显式删除这个文件才算真正清理干净。
    /// `nonisolated` 是因为调用方(上面的 `atexit` 回调、各测试用例的 defer/tearDown)
    /// 不一定在 MainActor 上。`TahoeTimeTests/TestDefaults.swift` 通过 `@testable import`
    /// 复用这份实现,避免测试助手与本类各留一份同样的删除逻辑。
    /// **已知残留**:这里的删除会立刻生效(诊断过 removeItem 成功、
    /// existedBefore=true),但 cfprefsd 自己按它内部的节奏(实测约 15–20 秒,不受本进程
    /// synchronize 影响)把仍被它记着的(已清空)domain 再落一次盘,重新生成一个 42 字节的空
    /// plist——这发生在本进程退出之后,不是本函数没删干净。跨进程外部删除(该进程早已退出)不受
    /// 此影响、删了就不会再回来。真正做到零残留需要进程退出一段时间后再从外部扫一遍,不能只靠
    /// 进程内清理;这不是本函数能解决的。
    nonisolated static func discardOneOffSuite(named name: String) {
        UserDefaults.standard.removePersistentDomain(forName: name)
        guard let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return }
        let plistURL = library.appendingPathComponent("Preferences").appendingPathComponent("\(name).plist")
        try? FileManager.default.removeItem(at: plistURL)
    }
}

#if DEBUG
/// 测试宿主保留窗口与绘制，只把激活和置前请求改成屏幕外的后台窗口。
@MainActor
enum TestHostWindowPolicy {
    static var isQuiet: Bool { ApplicationSession.isTesting && !ApplicationSession.uiTestForeground && PerformanceProbe.configuration?.scenario != "surfaces" }
    private static var installed = false
    private static var screenObserver: NSObjectProtocol?
    private static var launchObserver: NSObjectProtocol?
    private static var bundleObserver: NSObjectProtocol?
    private static var installedClasses: Set<ObjectIdentifier> = []
    private static var installedImplementations: [Method: UnsafeRawPointer] = [:]
    private static var refreshingActivationGuards = false
    private static var activationRefreshPending = false

    private enum MethodTarget { case window, application, runningApplication }

    private struct MethodSnapshot {
        let declaringClass: AnyClass
        let method: Method
        let selector: Selector
        let implementation: IMP
        let target: MethodTarget
    }

    private static let windowSelectors: Set<Selector> = [
        #selector(NSWindow.order(_:relativeTo:)), #selector(NSWindow.orderFront(_:)),
        #selector(NSWindow.orderBack(_:)), #selector(NSWindow.orderFrontRegardless),
        #selector(NSWindow.makeKeyAndOrderFront(_:)), #selector(NSWindow.makeKey),
        #selector(NSWindow.makeMain), #selector(getter: NSWindow.canBecomeKey),
        #selector(getter: NSWindow.canBecomeMain), #selector(NSWindow.constrainFrameRect(_:to:)),
        #selector(NSWindow.setFrame(_:display:)), #selector(NSWindow.setFrame(_:display:animate:)),
        #selector(NSWindow.setFrameOrigin(_:)), #selector(NSWindow.setFrameTopLeftPoint(_:)),
        #selector(NSWindow.center), #selector(NSWindow.setFrameAutosaveName(_:)),
        #selector(NSWindow.saveFrame(usingName:)), #selector(setter: NSWindow.isRestorable)
    ]

    private static let applicationSelectors: Set<Selector> = [
        NSSelectorFromString("activateIgnoringOtherApps:"), NSSelectorFromString("activate"),
        #selector(NSApplication.setActivationPolicy(_:))
    ]

    private static let runningApplicationSelectors: Set<Selector> = [
        NSSelectorFromString("activateWithOptions:"), NSSelectorFromString("activateFromApplication:options:")
    ]

    static func installIfNeeded() {
        guard isQuiet else { return }
        if installed {
            refreshActivationGuards(phase: "repeat-install")
            return
        }
        installed = true
        let application = NSApplication.shared
        _ = NSRunningApplication.current
        var count: UInt32 = 0
        guard let classes = objc_copyClassList(&count) else {
            preconditionFailure("Cannot enumerate test-host window classes")
        }
        defer { free(UnsafeMutableRawPointer(classes)) }
        // 按运行时句柄读取，避免私有根类经过对象桥接。
        let classPointers = UnsafeRawPointer(classes).assumingMemoryBound(to: UnsafeRawPointer.self)
        // 原始 ObjC 句柄与 Swift 类元数据的身份不同，基类从已桥接的类型单独取。
        var snapshots = snapshot(NSWindow.self, target: .window)
            + snapshot(NSApplication.self, target: .application)
            + snapshot(NSRunningApplication.self, target: .runningApplication)
        for index in 0..<Int(count) {
            let type: AnyClass = unsafeBitCast(classPointers[index], to: AnyClass.self)
            if isSubclass(type, of: NSWindow.self) {
                snapshots += snapshot(type, target: .window)
            } else if isSubclass(type, of: NSApplication.self) {
                snapshots += snapshot(type, target: .application)
            } else if isSubclass(type, of: NSRunningApplication.self) {
                snapshots += snapshot(type, target: .runningApplication)
            }
        }
        // 先取各类自己的原实现，再一起替换，避免把继承来的方法交换两次。
        snapshots.forEach(install)
        refreshActivationGuards(phase: "install")
        bundleObserver = NotificationCenter.default.addObserver(
            forName: Bundle.didLoadNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                refreshActivationGuards(phase: "bundle-load")
            }
        }
        if !NSRunningApplication.current.isFinishedLaunching {
            launchObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didFinishLaunchingNotification, object: application, queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    if let observer = launchObserver { NotificationCenter.default.removeObserver(observer) }
                    launchObserver = nil
                    refreshActivationGuards(phase: "launch-finished")
                }
            }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                for window in NSApp.windows where window.isVisible { prepare(window) }
            }
        }
    }

    static func requestAccessoryPolicy(current: () -> NSApplication.ActivationPolicy, set: () -> Bool) -> Bool {
        guard current() != .accessory else { return true }
        _ = set()
        return current() == .accessory
    }

    static var windowGuardsAreInstalled: Bool { installed }

    static var activationGuardsAreInstalled: Bool {
        let objects: [(AnyObject, Set<Selector>)] = [
            (NSApplication.shared, applicationSelectors),
            (NSRunningApplication.current, runningApplicationSelectors)
        ]
        return objects.allSatisfy { object, selectors in
            guard let type = object_getClass(object) else { return false }
            return selectors.allSatisfy { selector in
                guard let method = class_getInstanceMethod(type, selector),
                      let replacement = installedImplementations[method] else { return false }
                return unsafeBitCast(method_getImplementation(method), to: UnsafeRawPointer.self) == replacement
            }
        }
    }

    // 框架和测试包可在启动后替换方法，按实际调用的实现补装拦截。
    private static func refreshActivationGuards(phase: String) {
        guard !refreshingActivationGuards else {
            activationRefreshPending = true
            return
        }
        refreshingActivationGuards = true
        defer { refreshingActivationGuards = false }
        let before = activationGuardsAreInstalled
        var repairs = 0
        for _ in 0..<8 {
            activationRefreshPending = false
            repairs += repairActivationGuards()
            guard activationGuardsAreInstalled else { failMissingActivationGuards(phase: phase) }
            // 策略请求被拒绝时仍保留全部后台拦截，启动完成后再试一次。
            _ = NSApp.setActivationPolicy(.accessory)
            guard activationGuardsAreInstalled else { failMissingActivationGuards(phase: phase) }
            FileHandle.standardOutput.write(Data("MEANTIME_QUIET_ACTIVATION_GUARDS phase=\(phase) before=\(before) after=true repaired=\(repairs)\n".utf8))
            if !activationRefreshPending { return }
        }
        failMissingActivationGuards(phase: "\(phase)-unstable")
    }

    private static func failMissingActivationGuards(phase: String) -> Never {
        FileHandle.standardError.write(Data("Quiet test host activation guards are missing at \(phase)\n".utf8))
        exit(1)
    }

    private static func repairActivationGuards() -> Int {
        var snapshots: [MethodSnapshot] = []
        let objects: [(AnyObject, MethodTarget)] = [
            (NSApplication.shared, .application), (NSRunningApplication.current, .runningApplication)
        ]
        for (object, target) in objects {
            var current: AnyClass? = object_getClass(object)
            while let type = current {
                snapshots += snapshot(type, target: target)
                current = class_getSuperclass(type)
            }
        }
        for method in snapshots {
            let registered = installedImplementations[method.method] != nil
            FileHandle.standardOutput.write(Data((
                "MEANTIME_QUIET_ACTIVATION_REPAIR class=\(String(cString: class_getName(method.declaringClass))) " +
                "selector=\(NSStringFromSelector(method.selector)) registered=\(registered)\n"
            ).utf8))
            install(method)
        }
        return snapshots.count
    }

    static func offscreenFrame(_ proposed: NSRect) -> NSRect {
        let screens = NSScreen.screens.map(\.frame)
        let right = screens.map(\.maxX).max() ?? 0
        let bottom = screens.map(\.minY).min() ?? 0
        return NSRect(x: right + 1024, y: bottom, width: proposed.width, height: proposed.height)
    }

    static func prepare(_ window: NSWindow) {
        isolateFramePersistence(window)
        window.animationBehavior = .none
        window.hidesOnDeactivate = false
        let frame = offscreenFrame(window.frame)
        if window.frame != frame { window.setFrame(frame, display: false) }
    }

    /// 屏外坐标只属于本次测试，不写进窗口记忆或恢复状态。
    private static func isolateFramePersistence(_ window: NSWindow) {
        installWindowClassIfNeeded(window)
        window.isRestorable = false
        _ = window.setFrameAutosaveName("")
    }

    /// 核验真实窗口状态；发现越界时直接失败，不补移窗口掩盖问题。
    static func validateVisibleWindows(phase: String) {
        guard isQuiet else { return }
        let screens = NSScreen.screens.map(\.frame)
        let windows = NSApp.windows.filter(\.isVisible)
        var failed = false
        for window in windows {
            let frame = window.frame
            let intersections = screens.indices.filter { frame.intersects(screens[$0]) }
            let validFrame = [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite)
                && frame.width > 0 && frame.height > 0
            let displays = intersections.map(String.init).joined(separator: ",")
            FileHandle.standardOutput.write(Data((
                "MEANTIME_QUIET_WINDOW phase=\(phase) class=\(type(of: window)) frame=\(NSStringFromRect(frame)) " +
                "key=\(window.isKeyWindow) main=\(window.isMainWindow) displays=[\(displays)]\n"
            ).utf8))
            if !validFrame || window.isKeyWindow || window.isMainWindow || !intersections.isEmpty { failed = true }
        }
        FileHandle.standardOutput.write(Data("MEANTIME_QUIET_WINDOWS phase=\(phase) count=\(windows.count) failed=\(failed)\n".utf8))
        if failed {
            FileHandle.standardError.write(Data("Quiet test host window violation at \(phase)\n".utf8))
            exit(1)
        }
    }

    private static func isSubclass(_ type: AnyClass, of parent: AnyClass) -> Bool {
        var current: AnyClass? = type
        while let candidate = current {
            if ObjectIdentifier(candidate) == ObjectIdentifier(parent) { return true }
            current = class_getSuperclass(candidate)
        }
        return false
    }

    private static func snapshot(_ type: AnyClass, target: MethodTarget) -> [MethodSnapshot] {
        installedClasses.insert(ObjectIdentifier(type))
        var count: UInt32 = 0
        guard let methods = class_copyMethodList(type, &count) else { return [] }
        defer { free(methods) }
        let selectors: Set<Selector>
        switch target {
        case .window: selectors = windowSelectors
        case .application: selectors = applicationSelectors
        case .runningApplication: selectors = runningApplicationSelectors
        }
        return (0..<Int(count)).compactMap { index in
            let method = methods[index]
            let selector = method_getName(method)
            guard selectors.contains(selector) else { return nil }
            let implementation = method_getImplementation(method)
            if installedImplementations[method] == unsafeBitCast(implementation, to: UnsafeRawPointer.self) { return nil }
            return MethodSnapshot(declaringClass: type, method: method, selector: selector,
                                  implementation: implementation, target: target)
        }
    }

    // 后建的窗口类首次走到已拦截的祖先方法时，补上它自己的覆盖方法。
    private static func installWindowClassIfNeeded(_ window: NSWindow) {
        var current: AnyClass? = object_getClass(window)
        var snapshots: [MethodSnapshot] = []
        while let type = current, !installedClasses.contains(ObjectIdentifier(type)) {
            snapshots += snapshot(type, target: .window)
            current = class_getSuperclass(type)
        }
        snapshots.forEach(install)
    }

    private static func install(_ snapshot: MethodSnapshot) {
        let selector = snapshot.selector
        let replacement: IMP
        if snapshot.target == .runningApplication {
            let ownPID = getpid()
            if selector == NSSelectorFromString("activateWithOptions:") {
                typealias Original = @convention(c) (NSRunningApplication, Selector, UInt) -> Bool
                let original = unsafeBitCast(snapshot.implementation, to: Original.self)
                let block: @convention(block) (NSRunningApplication, UInt) -> Bool = { app, options in
                    guard app.processIdentifier != ownPID else { return false }
                    return original(app, selector, options)
                }
                replacement = imp_implementationWithBlock(block)
            } else {
                typealias Original = @convention(c) (NSRunningApplication, Selector, NSRunningApplication, UInt) -> Bool
                let original = unsafeBitCast(snapshot.implementation, to: Original.self)
                let block: @convention(block) (NSRunningApplication, NSRunningApplication, UInt) -> Bool = { app, source, options in
                    guard app.processIdentifier != ownPID else { return false }
                    return original(app, selector, source, options)
                }
                replacement = imp_implementationWithBlock(block)
            }
        } else if snapshot.target == .application {
            if selector == #selector(NSApplication.setActivationPolicy(_:)) {
                typealias Original = @convention(c) (NSApplication, Selector, Int) -> Bool
                let original = unsafeBitCast(snapshot.implementation, to: Original.self)
                let block: @convention(block) (NSApplication, Int) -> Bool = { app, _ in
                    MainActor.assumeIsolated {
                        requestAccessoryPolicy(current: { app.activationPolicy() }, set: {
                            original(app, selector, NSApplication.ActivationPolicy.accessory.rawValue)
                        })
                    }
                }
                replacement = imp_implementationWithBlock(block)
            } else if selector == NSSelectorFromString("activateIgnoringOtherApps:") {
                let block: @convention(block) (NSApplication, Bool) -> Void = { _, _ in }
                replacement = imp_implementationWithBlock(block)
            } else {
                let block: @convention(block) (NSApplication) -> Void = { _ in }
                replacement = imp_implementationWithBlock(block)
            }
        } else if selector == #selector(NSWindow.order(_:relativeTo:)) {
            typealias Original = @convention(c) (NSWindow, Selector, Int, Int) -> Void
            let original = unsafeBitCast(snapshot.implementation, to: Original.self)
            let block: @convention(block) (NSWindow, Int, Int) -> Void = { window, mode, other in
                MainActor.assumeIsolated {
                    installWindowClassIfNeeded(window)
                    if mode == NSWindow.OrderingMode.out.rawValue {
                        original(window, selector, mode, other)
                    } else {
                        prepare(window)
                        original(window, selector, mode, other)
                    }
                }
            }
            replacement = imp_implementationWithBlock(block)
        } else if selector == #selector(NSWindow.setFrame(_:display:)) {
            typealias Original = @convention(c) (NSWindow, Selector, NSRect, Bool) -> Void
            let original = unsafeBitCast(snapshot.implementation, to: Original.self)
            let block: @convention(block) (NSWindow, NSRect, Bool) -> Void = { window, frame, display in
                MainActor.assumeIsolated {
                    isolateFramePersistence(window)
                    original(window, selector, offscreenFrame(frame), display)
                }
            }
            replacement = imp_implementationWithBlock(block)
        } else if selector == #selector(NSWindow.setFrame(_:display:animate:)) {
            typealias Original = @convention(c) (NSWindow, Selector, NSRect, Bool, Bool) -> Void
            let original = unsafeBitCast(snapshot.implementation, to: Original.self)
            let block: @convention(block) (NSWindow, NSRect, Bool, Bool) -> Void = { window, frame, display, _ in
                MainActor.assumeIsolated {
                    isolateFramePersistence(window)
                    original(window, selector, offscreenFrame(frame), display, false)
                }
            }
            replacement = imp_implementationWithBlock(block)
        } else if selector == #selector(NSWindow.setFrameOrigin(_:)) || selector == #selector(NSWindow.setFrameTopLeftPoint(_:)) {
            typealias Original = @convention(c) (NSWindow, Selector, NSPoint) -> Void
            let original = unsafeBitCast(snapshot.implementation, to: Original.self)
            let topLeft = selector == #selector(NSWindow.setFrameTopLeftPoint(_:))
            let block: @convention(block) (NSWindow, NSPoint) -> Void = { window, _ in
                MainActor.assumeIsolated {
                    isolateFramePersistence(window)
                    let frame = offscreenFrame(window.frame)
                    let origin = NSPoint(x: frame.minX, y: topLeft ? frame.maxY : frame.minY)
                    original(window, selector, origin)
                }
            }
            replacement = imp_implementationWithBlock(block)
        } else if selector == #selector(NSWindow.setFrameAutosaveName(_:)) {
            typealias Original = @convention(c) (NSWindow, Selector, NSString) -> Bool
            let original = unsafeBitCast(snapshot.implementation, to: Original.self)
            let block: @convention(block) (NSWindow, NSString) -> Bool = { window, _ in
                MainActor.assumeIsolated {
                    installWindowClassIfNeeded(window)
                    return original(window, selector, "" as NSString)
                }
            }
            replacement = imp_implementationWithBlock(block)
        } else if selector == #selector(NSWindow.saveFrame(usingName:)) {
            let block: @convention(block) (NSWindow, NSString) -> Void = { window, _ in
                MainActor.assumeIsolated { installWindowClassIfNeeded(window) }
            }
            replacement = imp_implementationWithBlock(block)
        } else if selector == #selector(setter: NSWindow.isRestorable) {
            typealias Original = @convention(c) (NSWindow, Selector, Bool) -> Void
            let original = unsafeBitCast(snapshot.implementation, to: Original.self)
            let block: @convention(block) (NSWindow, Bool) -> Void = { window, _ in
                MainActor.assumeIsolated {
                    installWindowClassIfNeeded(window)
                    original(window, selector, false)
                }
            }
            replacement = imp_implementationWithBlock(block)
        } else if selector == #selector(NSWindow.constrainFrameRect(_:to:)) {
            let block: @convention(block) (NSWindow, NSRect, NSScreen?) -> NSRect = { window, frame, _ in
                MainActor.assumeIsolated {
                    installWindowClassIfNeeded(window)
                    return offscreenFrame(frame)
                }
            }
            replacement = imp_implementationWithBlock(block)
        } else if selector == #selector(getter: NSWindow.canBecomeKey) || selector == #selector(getter: NSWindow.canBecomeMain) {
            let block: @convention(block) (NSWindow) -> Bool = { window in
                MainActor.assumeIsolated { installWindowClassIfNeeded(window) }
                return false
            }
            replacement = imp_implementationWithBlock(block)
        } else if selector == #selector(NSWindow.orderFront(_:)) || selector == #selector(NSWindow.orderBack(_:))
                    || selector == #selector(NSWindow.makeKeyAndOrderFront(_:)) {
            typealias Original = @convention(c) (NSWindow, Selector, AnyObject?) -> Void
            let original = unsafeBitCast(snapshot.implementation, to: Original.self)
            let block: @convention(block) (NSWindow, AnyObject?) -> Void = { window, sender in
                MainActor.assumeIsolated {
                    prepare(window)
                    original(window, selector, sender)
                }
            }
            replacement = imp_implementationWithBlock(block)
        } else {
            let ordersWindow = selector == #selector(NSWindow.orderFrontRegardless)
            let centersWindow = selector == #selector(NSWindow.center)
            typealias Original = @convention(c) (NSWindow, Selector) -> Void
            let original = unsafeBitCast(snapshot.implementation, to: Original.self)
            let block: @convention(block) (NSWindow) -> Void = { window in
                MainActor.assumeIsolated {
                    installWindowClassIfNeeded(window)
                    if ordersWindow || centersWindow { prepare(window) }
                    if ordersWindow { original(window, selector) }
                }
            }
            replacement = imp_implementationWithBlock(block)
        }
        // 每个闭包只调用当时捕获的原函数；子类的 super 调用照常经过父类。
        method_setImplementation(snapshot.method, replacement)
        installedImplementations[snapshot.method] = unsafeBitCast(replacement, to: UnsafeRawPointer.self)
    }
}
#endif
