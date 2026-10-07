// SPDX-License-Identifier: GPL-3.0-only
//
//  DiagnosticsLog.swift
//  TahoeTime
//
//  App 自己的小日志文件。沙盒里 `OSLogStore.local` 可能连不上 logd（错误为
//  OSLogErrorDomain 10「Connection to logd failed」),所以想在诊断包里带上「上次启动发生了什么」,
//  只能自己写一份:每行「时刻 级别 类别 消息」,放在本 App 容器的 Application Support 里,
//  超过上限就只留后半;同一条也照旧发给统一日志,Console 里还是看得到。只记技术事件,不记任何个人内容。
//

import Foundation
import OSLog

nonisolated enum DiagnosticsLog {
    static let subsystem = "com.dayside.Dayside"
    /// 超过这个大小就把前半截丢掉。
    static let maxBytes = 256 * 1024
    private static let queue = DispatchQueue(label: "com.dayside.diagnostics-log", qos: .utility)

    /// 测试宿主写到另一个文件名,不碰安装版的记录。
    static var fileURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("Dayside", isDirectory: true)
        let name = ProcessInfo.processInfo.environment["MEANTIME_TEST_HOST"] == "1" ? "diagnostics-testhost.log" : "diagnostics.log"
        return dir.appendingPathComponent(name)
    }

    /// 记一条:同时进统一日志(公开字段)与本地文件。消息只放技术事实,不放地点名、人名、文件路径。
    static func note(_ category: String, _ message: String, level: OSLogType = .default) {
        Logger(subsystem: subsystem, category: category).log(level: level, "\(message, privacy: .public)")
        let line = "\(DiagnosticsReport.iso(.now)) \(levelName(level)) [\(category)] \(message)\n"
        queue.async { append(line) }
    }

    /// 最近的记录(最旧在前),读不到时给出原因。
    static func recent(limit: Int = 300) -> (lines: [DiagnosticsReport.LogLine], error: String?) {
        guard let url = fileURL else { return ([], "no Application Support directory") }
        guard FileManager.default.fileExists(atPath: url.path) else { return ([], nil) }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let parsed = text.split(separator: "\n").compactMap(parse)
            return (Array(parsed.suffix(limit)), nil)
        } catch {
            return ([], String(describing: error))
        }
    }

    /// 等待已排队的写入落盘(测试与自证钩子用)。
    static func flush() {
        queue.sync {}
    }

    private static func append(_ line: String) {
        guard let url = fileURL else { return }
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !manager.fileExists(atPath: url.path) {
                manager.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } catch {
            // 写不进日志文件不能反过来影响 App;统一日志那一份还在。
        }
        trimIfNeeded(url)
    }

    /// 文件超限时只留后半截(按行切)。
    private static func trimIfNeeded(_ url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? UInt64, size > UInt64(maxBytes),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let half = text.index(text.startIndex, offsetBy: text.count / 2)
        let tail = text[half...]
        let fromLine = tail.firstIndex(of: "\n").map { tail.index(after: $0) } ?? tail.startIndex
        try? String(tail[fromLine...]).write(to: url, atomically: true, encoding: .utf8)
    }

    private static func parse(_ line: Substring) -> DiagnosticsReport.LogLine? {
        // 「2026-09-13T06:27:34Z notice [MenuBarPresence] message …」
        let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4, parts[2].hasPrefix("["), parts[2].hasSuffix("]") else { return nil }
        return DiagnosticsReport.LogLine(date: String(parts[0]), level: String(parts[1]),
                                         category: String(parts[2].dropFirst().dropLast()), message: String(parts[3]))
    }

    private static func levelName(_ level: OSLogType) -> String {
        switch level {
        case .debug: return "debug"
        case .info: return "info"
        case .error: return "error"
        case .fault: return "fault"
        default: return "notice"
        }
    }
}
