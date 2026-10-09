// SPDX-License-Identifier: GPL-3.0-only
//
//  WindowCloseProbe.swift
//  Dayside
//
//  自证钩子(只在测试宿主):关掉工具窗后 App 必须还活着——菜单栏 App 关窗不等于退出。
//  `MEANTIME_UI_TEST_CLOSE_TOOLS_AFTER=<秒>`:到时对工具窗调 `performClose`(与点红色按钮同一条路),
//  再过 2 秒还活着就往标准输出写 `MEANTIME_TOOLS_CLOSED_STILL_RUNNING` 并退出 0;若关窗把 App 退出了,这一行永远不会出现。
//

import AppKit
import Darwin
import Foundation
import QuartzCore
#if DEBUG
import Carbon.HIToolbox

@MainActor
enum WindowCloseProbe {
    static func runIfRequested() {
        guard ApplicationSession.isTesting,
              let raw = ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_CLOSE_TOOLS_AFTER"],
              let seconds = Double(raw) else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            let tools = NSApp.windows.filter { ($0.identifier?.rawValue ?? "").hasPrefix("tools") && $0.isVisible }
            FileHandle.standardOutput.write(Data("MEANTIME_TOOLS_WINDOWS=\(tools.count)\n".utf8))
            tools.forEach { $0.performClose(nil) }
            try? await Task.sleep(for: .seconds(2))
            let stillOpen = NSApp.windows.filter { ($0.identifier?.rawValue ?? "").hasPrefix("tools") && $0.isVisible }.count
            FileHandle.standardOutput.write(Data("MEANTIME_TOOLS_CLOSED_STILL_RUNNING open=\(stillOpen)\n".utf8))
            exit(0)
        }
    }
}

/// 自证钩子(只在测试宿主):工具窗边栏的 ⌘1…⌘9 是否真进了主菜单（LSUIElement 的主菜单不可见，
/// 但 ⌘ 组合键就是靠它派发的）。`MEANTIME_UI_TEST_DUMP_MENU=1`:开窗 1.5 秒后把主菜单里
/// 键等价物为 1–9、修饰键为 ⌘ 的菜单项逐条写到标准输出（`MEANTIME_MENU_SHORTCUT ⌘n 路径/标题`）并退出 0。
/// 启用状态不在这里读：SwiftUI 的命令项在菜单要显示时才校验 `disabled`，此刻读到的值不作数。
@MainActor
enum MenuShortcutProbe {
    static func runIfRequested() {
        guard ApplicationSession.isTesting,
              ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_DUMP_MENU"] == "1" else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1500))
            var lines: [String] = []
            func walk(_ menu: NSMenu, path: String) {
                for item in menu.items {
                    if item.keyEquivalent.count == 1, "123456789".contains(item.keyEquivalent),
                       item.keyEquivalentModifierMask == .command {
                        lines.append("MEANTIME_MENU_SHORTCUT ⌘\(item.keyEquivalent) \(path)/\(item.title)")
                    }
                    if let submenu = item.submenu { walk(submenu, path: "\(path)/\(item.title)") }
                }
            }
            if let main = NSApp.mainMenu { walk(main, path: "") }
            FileHandle.standardOutput.write(Data((lines + ["MEANTIME_MENU_SHORTCUT_COUNT=\(lines.count)"]).joined(separator: "\n").appending("\n").utf8))
            exit(0)
        }
    }
}

/// 自证钩子（只在测试宿主）：全局快捷键那一下究竟能不能呼出菜单栏面板。
/// `MEANTIME_UI_TEST_HOTKEY_PROBE=1`：标签出现 2 秒后先把本进程的窗口清单写出来，
/// 再走一遍 `MenuBarPanel.toggle`，1 秒后数「面板窗口开了几个」，最后退出 0。
/// 面板由系统托管、没有公开的 isPresented，所以这条路必须实机自证，不能只靠读文档。
@MainActor
enum HotkeyProbe {
    static func runIfRequested() {
        guard ApplicationSession.isTesting,
              ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_HOTKEY_PROBE"] == "1" else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            var lines = ["MEANTIME_HOTKEY_WINDOWS_BEFORE \(MenuBarPanel.windowInventory())"]
            lines.append("MEANTIME_HOTKEY_BUTTON=\(MenuBarPanel.statusItemButton().map { String(describing: type(of: $0)) } ?? "none")")
            // 真注册一次 ⌥⌘T，再让系统对同一个组合注册第二次：第二次必须失败，
            // 这就证明第一次那个是真被系统收下了（没有公开 API 能查「某组合是否已注册」）。
            let setting = HotkeySetting(enabled: true, keyCode: 17, modifiers: 1 | 2)
            GlobalHotkeyCenter.shared.apply(setting)
            lines.append("MEANTIME_HOTKEY_TAKEN=\(GlobalHotkeyCenter.shared.isTaken)")
            var second: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(setting.keyCode), GlobalHotkeyCenter.carbonModifiers(setting.modifiers),
                                             EventHotKeyID(signature: OSType(0x5052_4F42), id: 9),
                                             GetEventDispatcherTarget(), 0, &second)
            lines.append("MEANTIME_HOTKEY_SECOND_REGISTER=\(status)")
            if let second { UnregisterEventHotKey(second) }
            // 按下那一下走的就是生产路径（Carbon 回调 → handlePress → 点菜单栏项）。
            GlobalHotkeyCenter.shared.handlePress()
            try? await Task.sleep(for: .milliseconds(600))
            lines.append("MEANTIME_HOTKEY_PRESS_WINDOWS \(MenuBarPanel.windowInventory())")
            let outcome = MenuBarPanel.toggle()
            lines.append("MEANTIME_HOTKEY_TOGGLE=\(outcome.rawValue)")
            try? await Task.sleep(for: .seconds(1))
            lines.append("MEANTIME_HOTKEY_WINDOWS_AFTER \(MenuBarPanel.windowInventory())")
            FileHandle.standardOutput.write(Data(lines.joined(separator: "\n").appending("\n").utf8))
            exit(0)
        }
    }
}
#endif
/// 量尺钩子（测试宿主或隔离预览，装机版永远不认）：用完之后内存回不回得去。`MEANTIME_UI_TEST_MEMORY_TOUR=1`：就绪 4 秒后点开面板 3 秒再关，
/// 开工具窗按边栏顺序走完每一页（各 1.5 秒），关掉工具窗，之后每 10 秒写一行 `MEANTIME_TOUR <阶段>`，
/// 外面的脚本（`Tools/memory_tour_probe.sh`）在每个阶段量一次 footprint。不自己退出，脚本负责结束。
/// `MEANTIME_UI_TEST_MEMORY_EARTH=1`：关掉工具窗之后再开地球窗 3 秒、前后跳六次时刻（每次带动画，
/// 事务里逐帧重算昼夜与灯火）、通过私有剪贴板拷贝一次海报（不碰用户剪贴板），关窗；
/// 各记一个阶段，峰值与「关窗后回不回去」都在表里。
/// 每行带上 App 自己当场量的数（`ProcessMeter`：footprint、一生的峰值、CPU、能耗、GPU 时间），
/// 写完停 2.5 秒再做下一步——外面的 vmmap 要一两秒，不停的话下一步（开地球窗、出海报）会被算进上一格。
@MainActor
enum MemoryTourProbe {
    static func runIfRequested(hub: FeatureHub, open: @escaping () -> Void, openEarth: (() -> Void)? = nil) {
        guard ApplicationSession.isTesting || ApplicationSession.isIsolated,
              ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_MEMORY_TOUR"] == "1" else { return }
        Task { @MainActor in
            @MainActor func mark(_ phase: String) async {
                #if DEBUG
                TestHostWindowPolicy.validateVisibleWindows(phase: phase)
                #endif
                if phase == "earthOpen" || phase == "earthScrubbed" || phase == "earthPoster" {
                    // 单个原生地球窗才可作为前台量尺。
                    let earthWindows = NSApp.windows.filter { ($0.identifier?.rawValue ?? "").hasPrefix("earth") }
                    let unique = earthWindows.count == 1
                    let visible = unique && earthWindows[0].isVisible
                    let unoccluded = unique && earthWindows[0].occlusionState.contains(.visible)
                    let active = unique && NSApp.isActive
                    let frontWindow = NSApp.orderedWindows.first { $0.isVisible }
                    let front = unique && (frontWindow === earthWindows.first)
                    FileHandle.standardOutput.write(Data("MEANTIME_TOUR_EARTH_FRONT \(phase) count=\(earthWindows.count) visible=\(visible) unoccluded=\(unoccluded) active=\(active) front=\(front)\n".utf8))
                }
                FileHandle.standardOutput.write(Data("MEANTIME_TOUR \(phase) \(ProcessMeter.line())\n".utf8))
                try? await Task.sleep(for: .seconds(2.5))
            }
            @MainActor func requirePanel(_ outcome: MenuBarPanel.Outcome, visible: Bool, phase: String) {
                #if DEBUG
                guard ApplicationSession.isTesting else { return }
                let actual = AppModel.shared.isPanelVisible
                FileHandle.standardOutput.write(Data("MEANTIME_TOUR_PANEL phase=\(phase) toggle=\(outcome.rawValue) visible=\(actual) expected=\(visible)\n".utf8))
                guard outcome == .clicked, actual == visible else {
                    FileHandle.standardError.write(Data("Memory tour panel transition failed at \(phase)\n".utf8))
                    exit(1)
                }
                TestHostWindowPolicy.validateVisibleWindows(phase: phase)
                #endif
            }
            try? await Task.sleep(for: .seconds(4)); await mark("launched")
            let environment = ProcessInfo.processInfo.environment
            let earthOnly = environment["MEANTIME_UI_TEST_MEMORY_EARTH_ONLY"] == "1"
            let relief = environment["MEANTIME_UI_TEST_MEMORY_RELIEF"] == "1"
            let cycles = Int(environment["MEANTIME_UI_TEST_MEMORY_CYCLES"] ?? "") ?? 0
            let fixture = environment["MEANTIME_UI_TEST_FIXTURE"] ?? ""
            let model = AppModel.shared
            model.animatesScrub = environment["MEANTIME_UI_TEST_MEMORY_ANIMATION"] != "0"
            FileHandle.standardOutput.write(Data("MEANTIME_TOUR_CONDITIONS reduceMotion=\(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) animated=\(model.animatesScrub) earthOnly=\(earthOnly) relief=\(relief) cycles=\(cycles) fixture=\(fixture) pid=\(ProcessInfo.processInfo.processIdentifier)\n".utf8))
            if !earthOnly {
                let opened = MenuBarPanel.toggle()
                try? await Task.sleep(for: .seconds(3))
                requirePanel(opened, visible: true, phase: "panelOpen")
                await mark("panelOpen")
                let closed = MenuBarPanel.toggle()
                try? await Task.sleep(for: .seconds(3))
                requirePanel(closed, visible: false, phase: "panelClosed")
                await mark("panelClosed")
                // `MEANTIME_UI_TEST_MEMORY_PANEL_ONLY=1`：只量面板，关上之后直接静置（量「面板关着时还有没有东西在跑」，不让工具窗那一段混进来）。
                if ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_MEMORY_PANEL_ONLY"] == "1" {
                    for step in 1...6 {
                        try? await Task.sleep(for: .seconds(10))
                        await mark("idle\(step * 10)")
                    }
                    await mark("done")
                    return
                }
                open()
                for page in FeatureSelection.allCases where hub.isAvailable(page) {
                    hub.selection = page
                    try? await Task.sleep(for: .milliseconds(1500))
                    #if DEBUG
                    if ApplicationSession.isTesting && (!hub.isVisible || !NSApp.windows.contains {
                        ($0.identifier?.rawValue ?? "").hasPrefix("tools") && $0.isVisible
                    }) {
                        FileHandle.standardError.write(Data("Memory tour tools window did not open\n".utf8))
                        exit(1)
                    }
                    TestHostWindowPolicy.validateVisibleWindows(phase: "page-\(page.rawValue)")
                    #endif
                    FileHandle.standardOutput.write(Data("MEANTIME_TOUR_PAGE \(page) \(ProcessMeter.line())\n".utf8))
                }
                await mark("toured")
                do {
                    let tools = NSApp.windows.filter { ($0.identifier?.rawValue ?? "").hasPrefix("tools") && $0.isVisible }
                    let closingStarted = mach_continuous_time()
                    tools.forEach { $0.performClose(nil) }
                    let closingFinished = mach_continuous_time()
                    let remaining = NSApp.windows.filter { ($0.identifier?.rawValue ?? "").hasPrefix("tools") && $0.isVisible }.count
                    let windowIDs = tools.map { String($0.windowNumber) }.joined(separator: ",")
                    // 记录实际关窗区间，让外部量尺从这一刻数六十秒。
                    FileHandle.standardOutput.write(Data("MEANTIME_TOUR_TOOLS_CLOSED start=\(closingStarted) end=\(closingFinished) before=\(tools.count) remaining=\(remaining) ids=\(windowIDs)\n".utf8))
                }
                try? await Task.sleep(for: .seconds(2)); await mark("closed")
            }
            if let openEarth, environment["MEANTIME_UI_TEST_MEMORY_EARTH"] == "1" || earthOnly {
                openEarth()
                try? await Task.sleep(for: .milliseconds(400))
                #if DEBUG
                if !TestHostWindowPolicy.isQuiet {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.windows.filter { ($0.identifier?.rawValue ?? "").hasPrefix("earth") }.forEach { $0.orderFrontRegardless() }
                }
                #else
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.filter { ($0.identifier?.rawValue ?? "").hasPrefix("earth") }.forEach { $0.orderFrontRegardless() }
                #endif
                try? await Task.sleep(for: .seconds(3)); await mark("earthOpen")
                for hours in [3.0, 6, 9, 12, -6, -12] {
                    model.jump(to: Date().addingTimeInterval(hours * 3600), animated: true)
                    try? await Task.sleep(for: .milliseconds(700))
                }
                model.resetToNow()
                try? await Task.sleep(for: .seconds(1)); await mark("earthScrubbed")
                let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.dayside.memory-tour.\(UUID().uuidString)"))
                let copied = EarthPoster.copy(model: model, core: model.core, pasteboard: pasteboard)
                let png = pasteboard.data(forType: .png)
                #if DEBUG
                if ApplicationSession.isTesting && (!copied || png?.isEmpty != false) {
                    FileHandle.standardError.write(Data("Memory tour poster did not render\n".utf8))
                    exit(1)
                }
                #endif
                FileHandle.standardOutput.write(Data("MEANTIME_TOUR_POSTER copied=\(copied) pixels=2400x920 png=\(png?.count ?? 0)\n".utf8))
                try? await Task.sleep(for: .seconds(1)); await mark("earthPoster")
                pasteboard.clearContents()
                pasteboard.releaseGlobally()
                do {
                    let earthWindows = NSApp.windows.filter { ($0.identifier?.rawValue ?? "").hasPrefix("earth") && $0.isVisible }
                    let closingStarted = mach_continuous_time()
                    earthWindows.forEach { $0.performClose(nil) }
                    let closingFinished = mach_continuous_time()
                    let remaining = NSApp.windows.filter { ($0.identifier?.rawValue ?? "").hasPrefix("earth") && $0.isVisible }.count
                    FileHandle.standardOutput.write(Data("MEANTIME_TOUR_EARTH_CLOSED start=\(closingStarted) end=\(closingFinished) before=\(earthWindows.count) remaining=\(remaining)\n".utf8))
                    if !relief && cycles == 0 {
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(15))
                            var timebase = mach_timebase_info_data_t()
                            mach_timebase_info(&timebase)
                            let elapsed = Double(mach_continuous_time() - closingFinished) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
                            FileHandle.standardOutput.write(Data("MEANTIME_TOUR_EARTH_IDLE15 elapsedSeconds=\(elapsed) \(ProcessMeter.line())\n".utf8))
                        }
                    }
                }
                try? await Task.sleep(for: .seconds(2)); await mark("earthClosed")
            }
            // `MEANTIME_UI_TEST_MEMORY_RELIEF=1`：关窗之后逐样试「还内存」的办法，各记一个阶段，外面量出哪一样真有用。
            if relief {
                let inventory = NSApp.windows.map { "\($0.identifier?.rawValue ?? String(describing: type(of: $0)))\($0.isVisible ? "*" : "")" }
                FileHandle.standardOutput.write(Data("MEANTIME_TOUR_WINDOWS \(inventory.joined(separator: " "))\n".utf8))
                let freed = malloc_zone_pressure_relief(nil, 0)
                FileHandle.standardOutput.write(Data("MEANTIME_TOUR_RELIEF bytes=\(freed)\n".utf8))
                try? await Task.sleep(for: .seconds(2)); await mark("reliefMalloc")
                CATransaction.flush()
                try? await Task.sleep(for: .seconds(2)); await mark("reliefCA")
            }
            // `MEANTIME_UI_TEST_MEMORY_CYCLES=n`：面板再开关 n 次、工具窗再开关 n 次，每次关掉后各记一个阶段——
            // 分清「首次预热」与「每次都涨」（后者才是泄漏）。
            for cycle in 0..<cycles {
                let opened = MenuBarPanel.toggle()
                try? await Task.sleep(for: .seconds(2))
                requirePanel(opened, visible: true, phase: "panelCycle\(cycle + 1)Open")
                let closed = MenuBarPanel.toggle()
                try? await Task.sleep(for: .seconds(2))
                requirePanel(closed, visible: false, phase: "panelCycle\(cycle + 1)Closed")
                await mark("panelCycle\(cycle + 1)")
            }
            for cycle in 0..<cycles {
                open(); try? await Task.sleep(for: .seconds(2))
                do {
                    let tools = NSApp.windows.filter { ($0.identifier?.rawValue ?? "").hasPrefix("tools") && $0.isVisible }
                    let closingStarted = mach_continuous_time()
                    tools.forEach { $0.performClose(nil) }
                    let closingFinished = mach_continuous_time()
                    let remaining = NSApp.windows.filter { ($0.identifier?.rawValue ?? "").hasPrefix("tools") && $0.isVisible }.count
                    let windowIDs = tools.map { String($0.windowNumber) }.joined(separator: ",")
                    // 记录实际关窗区间，让外部量尺从这一刻数六十秒。
                    FileHandle.standardOutput.write(Data("MEANTIME_TOUR_TOOLS_CLOSED start=\(closingStarted) end=\(closingFinished) before=\(tools.count) remaining=\(remaining) ids=\(windowIDs)\n".utf8))
                }
                try? await Task.sleep(for: .seconds(2)); await mark("toolsCycle\(cycle + 1)")
            }
            for step in 1...(cycles > 0 ? 2 : 6) {
                try? await Task.sleep(for: .seconds(10))
                await mark("idle\(step * 10)")
            }
            await mark("done")
        }
    }
}

/// 量尺（内存巡回用，光）：此刻本进程的 footprint 与一生的峰值（字节）、CPU 时间（纳秒）、
/// 能耗（纳焦，`proc_pid_rusage` v6 的 `ri_energy_nj`）、GPU 时间（`TASK_POWER_INFO_V2` 的 `task_gpu_utilisation`，内核原值）
/// 与两种唤醒次数，一行 `键=值`，外面的脚本按阶段相减。读的都是内核记账，不采样、不起线程。
nonisolated enum ProcessMeter {
    static func line() -> String {
        var usage = rusage_info_v6()
        let rusageOK = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0) }
        } == 0
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        // rusage 的时间是 mach 时基的刻数（Apple 芯片上一刻不是一纳秒）。
        let nanoseconds = { (ticks: UInt64) in timebase.denom == 0 ? ticks : ticks / UInt64(timebase.denom) * UInt64(timebase.numer) }
        var power = task_power_info_v2()
        var count = mach_msg_type_number_t(MemoryLayout<task_power_info_v2>.size / MemoryLayout<natural_t>.size)
        let powerOK = withUnsafeMutablePointer(to: &power) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_POWER_INFO_V2), $0, &count) }
        } == KERN_SUCCESS
        var fields: [String] = []
        if rusageOK {
            fields += ["fp=\(usage.ri_phys_footprint)", "peak=\(usage.ri_lifetime_max_phys_footprint)",
                       "cpu_ns=\(nanoseconds(usage.ri_user_time + usage.ri_system_time))", "energy_nj=\(usage.ri_energy_nj)",
                       "wake=\(usage.ri_interrupt_wkups)", "idlewake=\(usage.ri_pkg_idle_wkups)"]
        }
        if powerOK {
            fields.append("gpu=\(power.gpu_energy.task_gpu_utilisation)")
            #if arch(arm64)
            // `task_energy` 只在 Apple 芯片上有（头文件按 __arm64__ 条件定义），Intel 切片编不过（0927a 打包查出）。
            fields.append("task_energy=\(power.task_energy)")
            #endif
        }
        return fields.joined(separator: " ")
    }
}
