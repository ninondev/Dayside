// SPDX-License-Identifier: GPL-3.0-only
//
//  DiagnosticsReport.swift
//  TahoeTime
//
//  诊断包:用户遇到问题时一键导出的一份纯文本——本机与本 App 的状态、时区数据自检、设置(脱敏)、
//  App 自己在统一日志里的最近记录。零遥测:这里只收集与排版(排版与脱敏在 Rust `diagnostics.render`),
//  App 从不自动上传;用户自己看过、删改过再发给作者。
//

import AppKit
import Darwin
import Foundation
import UniformTypeIdentifiers

@MainActor
enum DiagnosticsReport {

    // MARK: - 事实

    struct AppFacts: Encodable {
        let name: String, version: String, build: String, bundleID: String
        let isLocalPreview: Bool, architecture: String, translated: Bool
    }
    struct SystemFacts: Encodable {
        let macOS: String, model: String, tzdata: String, systemTimeZone: String, locale: String, uiLanguage: String
    }
    struct ProcessFacts: Encodable {
        let uptimeSeconds: Double, cpuSeconds: Double, residentBytes: UInt64, footprintBytes: UInt64, indexOpen: Bool
    }
    struct Place: Encodable { let name: String; let timeZoneID: String; let countryCode: String }
    struct StateFacts: Encodable {
        let zones: [Place], zonesRecovered: Bool, peopleCount: Int, peopleTimeZones: [String]
        let menuBarInserted: Bool?, settings: CoreJSON
    }
    struct StaleFacts: Encodable { let zone: String; let since: String; let expectedMinutes: Int; let observedMinutes: Int }
    struct TZDataFacts: Encodable { let version: String; let coverage: String; let checked: Int; let stale: [StaleFacts] }
    struct LogLine: Encodable, Sendable { let date: String; let level: String; let category: String; let message: String }
    struct Facts: Encodable {
        let generatedAt: String
        let app: AppFacts, system: SystemFacts, process: ProcessFacts, state: StateFacts, tzdata: TZDataFacts
        let logs: [LogLine], logError: String?, summary: Bool
    }

    /// 完整诊断包(含设置与日志)或只有前几节的摘要。日志读取在后台线程,其余事实在主线程取。
    static func text(model: AppModel, hub: FeatureHub?, summary: Bool) async -> String {
        let logs: (lines: [LogLine], error: String?) = summary
            ? ([], nil)
            : await Task.detached(priority: .utility) { recentLogs() }.value
        let facts = facts(model: model, hub: hub, logs: logs.lines, logError: logs.error, summary: summary)
        return RustCore.invoke("diagnostics.render", facts)
    }

    static func facts(model: AppModel, hub: FeatureHub?, logs: [LogLine], logError: String?, summary: Bool) -> Facts {
        let bundle = Bundle.main
        let info = bundle.infoDictionary ?? [:]
        let core = model.core
        let report = TZDataCheck.currentReport()
        let settings: CoreJSON = (try? JSONDecoder().decode(CoreJSON.self, from: JSONEncoder().encode(core.settings))) ?? .null
        let people = hub?.peoplePlaces ?? []
        return Facts(
            generatedAt: iso(.now),
            app: AppFacts(
                name: (info["CFBundleName"] as? String) ?? "Dayside",
                version: (info["CFBundleShortVersionString"] as? String) ?? "?",
                build: (info["CFBundleVersion"] as? String) ?? "?",
                bundleID: bundle.bundleIdentifier ?? "?",
                isLocalPreview: ApplicationSession.isLocalPreview,
                architecture: architecture, translated: isTranslated),
            system: SystemFacts(
                macOS: ProcessInfo.processInfo.operatingSystemVersionString,
                model: sysctlString("hw.model") ?? "?",
                tzdata: TZDataCheck.installedVersion ?? "?",
                systemTimeZone: TimeZone.current.identifier,
                locale: Locale.current.identifier, uiLanguage: core.uiLocale.identifier),
            process: ProcessFacts(
                uptimeSeconds: processStart.map { Date.now.timeIntervalSince($0) } ?? 0,
                cpuSeconds: cpuSeconds, residentBytes: memory.resident, footprintBytes: memory.footprint,
                indexOpen: CityIndex.shared.isAvailable),
            state: StateFacts(
                zones: core.zones.map { Place(name: core.placeName(forTimeZoneID: $0.timezoneID), timeZoneID: $0.timezoneID, countryCode: $0.countryCode ?? "") },
                zonesRecovered: model.zonesRecoveryNotice,
                peopleCount: people.count,
                peopleTimeZones: Array(Set(people.map(\.timeZoneID))).sorted(),
                menuBarInserted: (NSApplication.shared.delegate as? MenuBarPresenceController)?.isInserted,
                settings: settings),
            tzdata: TZDataFacts(
                version: report.version ?? "?", coverage: report.coverage, checked: report.checked,
                stale: report.stale.map { StaleFacts(zone: $0.zone, since: $0.since, expectedMinutes: $0.expectedMinutes, observedMinutes: $0.observedMinutes) }),
            logs: logs, logError: logError, summary: summary)
    }

    // MARK: - 日志(App 自己的文件;OSLogStore 在沙盒里连不上 logd,见 DiagnosticsLog)

    nonisolated static func recentLogs(limit: Int = 300) -> (lines: [LogLine], error: String?) {
        DiagnosticsLog.recent(limit: limit)
    }

    // MARK: - 系统事实

    nonisolated static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    private static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    /// Rosetta 下运行时 `sysctl.proc_translated` 为 1;原生或旧系统没有这个键。
    private static var isTranslated: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("sysctl.proc_translated", &value, &size, nil, 0) == 0 && value == 1
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static var processStart: Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }

    private static var cpuSeconds: Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return user + system
    }

    /// 与发布门同一口径:footprint = `phys_footprint`,RSS = `resident_size`。
    private static var memory: (resident: UInt64, footprint: UInt64) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        return (UInt64(info.resident_size), UInt64(info.phys_footprint))
    }

    // MARK: - 导出

    /// 存盘对话框(沙盒下用户选的位置才可写)。取消返回 false,不算失败。
    static func save(_ text: String) -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        panel.nameFieldStringValue = "Dayside-diagnostics-\(formatter.string(from: .now)).txt"
        NSApplication.shared.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    #if DEBUG
    /// 自证钩子(只在测试宿主):写一条带 pid 的探针日志,两秒后把完整诊断包打到标准输出并退出。
    /// 连跑两次,第二次的输出里若有第一次的 pid,就证明沙盒里能读到上次启动的日志。
    static func runProbeIfRequested(model: AppModel, hub: FeatureHub?) {
        guard ApplicationSession.isTesting,
              ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_DIAGNOSTICS"] == "1" else { return }
        DiagnosticsLog.note("diagnostics", "diagnostics-probe pid=\(getpid())")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            DiagnosticsLog.flush()
            let text = await text(model: model, hub: hub, summary: false)
            FileHandle.standardOutput.write(Data("MEANTIME_DIAGNOSTICS_BEGIN\n\(text)MEANTIME_DIAGNOSTICS_END\n".utf8))
            exit(0)
        }
    }
    #endif
}
