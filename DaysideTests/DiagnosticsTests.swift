// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import Dayside

/// 诊断包:Swift 收事实、Rust 排版与脱敏;零遥测。
@MainActor
struct DiagnosticsTests {
    private func model() -> (model: AppModel, cleanup: () -> Void) {
        let (defaults, cleanup) = TestDefaults.make(prefix: "diagnostics-tests")
        Store.saveZones([.init(timezoneID: "Asia/Tokyo", cityName: "Tokyo", coordinate: nil, countryCode: "JP")], to: defaults)
        return (AppModel(defaults: defaults, migrate: false, applySystemIntegration: false), cleanup)
    }

    @Test func diagnosticsDoNotCarryPaidAccessState() async throws {
        let (appModel, cleanup) = model(); defer { cleanup() }
        let facts = DiagnosticsReport.facts(model: appModel, hub: nil, logs: [], logError: nil, summary: true)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(facts)) as? [String: Any])
        let app = try #require(object["app"] as? [String: Any])
        let state = try #require(object["state"] as? [String: Any])
        #expect(app["proGateEnforced"] == nil)
        #expect(state["proAccess"] == nil)
        let text = await DiagnosticsReport.text(model: appModel, hub: nil, summary: true)
        #expect(!text.contains("pro gate"))
        #expect(!text.contains("[access]"))
    }

    @Test func theSummaryNamesThisBuildAndTheTzdataAndStopsBeforeSettings() async {
        let (appModel, cleanup) = model(); defer { cleanup() }
        let text = await DiagnosticsReport.text(model: appModel, hub: nil, summary: true)
        #expect(text.contains("bundle: \(Bundle.main.bundleIdentifier ?? "?")"))
        #expect(text.contains("tzdata: \(TZDataCheck.installedVersion ?? "?")"))
        #expect(text.contains("  - ") && text.contains("Asia/Tokyo · JP"))
        #expect(text.contains("[tzdata self-check]"))
        #expect(!text.contains("[settings]") && !text.contains("[log"))
    }

    @Test func theFullReportCarriesSettingsAndTheAppsOwnLogAndNeverAHomePath() async {
        let (appModel, cleanup) = model(); defer { cleanup() }
        let marker = "probe-\(UUID().uuidString)"
        DiagnosticsLog.note("tests", "\(marker) written from /Users/someone/Desktop")
        DiagnosticsLog.flush()
        let text = await DiagnosticsReport.text(model: appModel, hub: nil, summary: false)
        #expect(text.contains("[settings]"))
        #expect(text.contains("\"hourStyle\""))
        #expect(text.contains("[log · app's own log file · newest last]\n"))
        #expect(text.contains("[tests] \(marker) written from ~/Desktop"), Comment(rawValue: "own log lines must reach the report, redacted"))
        #expect(!text.contains("/Users/"), Comment(rawValue: "home paths must be redacted"))
    }

    @Test func theOwnLogFileIsCappedAndKeepsTheNewestLines() {
        for i in 0..<40 { DiagnosticsLog.note("cap", "line-\(i) " + String(repeating: "x", count: 8_000)) }
        DiagnosticsLog.flush()
        let url = DiagnosticsLog.fileURL!
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        #expect(size <= UInt64(DiagnosticsLog.maxBytes) + 9_000, Comment(rawValue: "size \(size)"))
        let recent = DiagnosticsLog.recent(limit: 300).lines
        #expect(recent.last?.message.hasPrefix("line-39 ") == true)
    }

    /// 崩溃诊断只留最新 N 份原始负载，摘要行是纯技术事实。
    @Test func crashPayloadsAreCappedAndTheSummaryIsTechnical() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dayside-mx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 0..<15 {
            try Data("{}".utf8).write(to: dir.appendingPathComponent(String(format: "mx-2026-09-%02dT00-00-00Z.json", i + 1)))
        }
        try Data("{}".utf8).write(to: dir.appendingPathComponent("other.txt"))
        CrashDiagnostics.prune(in: dir, keep: 12)
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(left.filter { $0.hasPrefix("mx-") }.count == 12)
        #expect(left.contains("mx-2026-09-15T00-00-00Z.json") && !left.contains("mx-2026-09-01T00-00-00Z.json"))
        #expect(left.contains("other.txt"))
        let summary = CrashDiagnostics.summary(crashes: 1, hangs: 0, disk: 0, cpu: 2, begin: "2026-09-14T00:00:00Z", end: "2026-09-15T00:00:00Z")
        #expect(summary == "diagnostics received · crashes 1 · hangs 0 · disk write exceptions 0 · cpu exceptions 2 · 2026-09-14T00:00:00Z to 2026-09-15T00:00:00Z")
    }

    @Test func redactionIsReachableFromSwift() {
        let redacted: String = RustCore.invoke("diagnostics.redact", "see /Users/someone/Library and mail a.b@example.com")
        #expect(redacted == "see ~/Library and mail [email]")
    }
}
