// SPDX-License-Identifier: GPL-3.0-only
//
//  CrashDiagnostics.swift
//  Dayside
//
//  崩溃与卡顿诊断，零遥测：MetricKit 在下一次启动时把系统记到的崩溃 / 卡顿 / 磁盘写入超标交给 App，
//  这里只做两件事——在 App 自己的诊断日志里记一行摘要（进诊断包），把原始 JSON 存进容器
//  Application Support/Dayside/metrickit/（最多留 12 份，用户导出诊断包时可以自己看），不上传任何东西。
//  MetricKit 在 ad-hoc 分发下能不能收到只能等真崩过一次再看：本文件让那次能被记下来。
//

import Foundation
import MetricKit

final class CrashDiagnostics: NSObject, MXMetricManagerSubscriber, Sendable {
    static let shared = CrashDiagnostics()
    /// 原始负载最多留这么多份（每份通常几十 KB）。
    static let keptPayloads = 12

    static var directory: URL? {
        DiagnosticsLog.fileURL?.deletingLastPathComponent().appendingPathComponent("metrickit", isDirectory: true)
    }

    /// 只在真实 App 里订阅；测试宿主与本地预览不订阅（各有各的容器，没意义）。
    @MainActor static func startIfAppropriate() {
        guard !ApplicationSession.isIsolated else { return }
        MXMetricManager.shared.add(shared)
    }

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads { Self.record(payload) }
    }

    /// 每日指标只记一行（启动耗时与 CPU 都是系统汇总的粗数），不存文件。
    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            DiagnosticsLog.note("metrics", "daily metrics received · \(DiagnosticsReport.iso(payload.timeStampBegin)) to \(DiagnosticsReport.iso(payload.timeStampEnd))")
        }
    }

    nonisolated static func record(_ payload: MXDiagnosticPayload) {
        let crashes = payload.crashDiagnostics?.count ?? 0
        let hangs = payload.hangDiagnostics?.count ?? 0
        let disk = payload.diskWriteExceptionDiagnostics?.count ?? 0
        let cpu = payload.cpuExceptionDiagnostics?.count ?? 0
        guard crashes + hangs + disk + cpu > 0 else { return }
        let summary = Self.summary(crashes: crashes, hangs: hangs, disk: disk, cpu: cpu,
                                   begin: DiagnosticsReport.iso(payload.timeStampBegin), end: DiagnosticsReport.iso(payload.timeStampEnd))
        DiagnosticsLog.note("crash", summary, level: crashes > 0 ? .error : .default)
        for crash in payload.crashDiagnostics ?? [] {
            // 只记技术事实：信号、异常类型、终止原因；不记任何路径或用户内容。
            let reason = crash.terminationReason ?? "?"
            DiagnosticsLog.note("crash", "crash · version \(crash.applicationVersion) · signal \(crash.signal?.stringValue ?? "?") · exception \(crash.exceptionType?.stringValue ?? "?") · reason \(reason)", level: .error)
        }
        store(payload.jsonRepresentation(), at: payload.timeStampEnd)
    }

    /// 「crashes 1 · hangs 0 · 2026-09-14T00:00:00Z to 2026-09-15T00:00:00Z」，纯技术事实。
    nonisolated static func summary(crashes: Int, hangs: Int, disk: Int, cpu: Int, begin: String, end: String) -> String {
        "diagnostics received · crashes \(crashes) · hangs \(hangs) · disk write exceptions \(disk) · cpu exceptions \(cpu) · \(begin) to \(end)"
    }

    nonisolated static func store(_ json: Data, at date: Date) {
        guard let directory else { return }
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let stamp = DiagnosticsReport.iso(date).replacingOccurrences(of: ":", with: "-")
            try json.write(to: directory.appendingPathComponent("mx-\(stamp).json"), options: .atomic)
            prune(in: directory, keep: keptPayloads)
        } catch {
            DiagnosticsLog.note("crash", "could not store diagnostic payload: \(error.localizedDescription)", level: .error)
        }
    }

    /// 只留最新的 `keep` 份，按文件名（含时间戳）排序删旧的。
    nonisolated static func prune(in directory: URL, keep: Int) {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return }
        let payloads = names.filter { $0.hasPrefix("mx-") && $0.hasSuffix(".json") }.sorted()
        for name in payloads.dropLast(keep) {
            try? manager.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// 诊断包里的一句话：存了几份原始负载。
    nonisolated static var storedPayloadCount: Int {
        guard let directory, let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return 0 }
        return names.filter { $0.hasPrefix("mx-") && $0.hasSuffix(".json") }.count
    }
}
