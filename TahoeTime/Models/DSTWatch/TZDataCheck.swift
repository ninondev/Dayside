// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Asks the installed time zone data what it believes at instants after known rule changes and
/// lets the Rust core compare. Foundation is the only source of "what this Mac thinks"; the table
/// of what the world decided lives in Rust. Nothing here changes any clock.
nonisolated enum TZDataCheck {
    struct Probe: Decodable, Equatable, Sendable {
        let zone: String
        let at: String
    }
    struct Stale: Decodable, Equatable, Identifiable, Sendable {
        let zone: String
        let since: String
        let expectedMinutes: Int
        let observedMinutes: Int
        var id: String { "\(zone)@\(since)" }
    }
    struct Report: Decodable, Equatable, Sendable {
        let version: String?
        let coverage: String
        let checked: Int
        let stale: [Stale]
        let unknown: [String]
    }

    /// `/usr/share/zoneinfo/+VERSION` names the tzdata release macOS installed, e.g. `2026c`.
    static var installedVersion: String? {
        guard let text = try? String(contentsOfFile: "/usr/share/zoneinfo/+VERSION", encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.count > 12 ? nil : trimmed
    }

    static func run(version: String? = installedVersion) -> Report {
        struct Probes: Decodable { let probes: [Probe] }
        let probes: Probes = RustCore.invoke("tzdata.probes", [String: String]())
        struct Observation: Encodable { let zone: String; let at: String; let offsetMinutes: Int? }
        struct Input: Encodable { let version: String?; let observed: [Observation] }
        let parser = ISO8601DateFormatter()
        let observed = probes.probes.map { probe -> Observation in
            guard let zone = TimeZone(identifier: probe.zone), let instant = parser.date(from: probe.at) else {
                return Observation(zone: probe.zone, at: probe.at, offsetMinutes: nil)
            }
            return Observation(zone: probe.zone, at: probe.at, offsetMinutes: zone.secondsFromGMT(for: instant) / 60)
        }
        return RustCore.invoke("tzdata.check", Input(version: version, observed: observed))
    }

    /// What the app shows: the real report, or under the UI-test host a fake outdated Mac so audits
    /// and screenshots can see the warning path (`MEANTIME_UI_TEST_TZDATA=stale`).
    @MainActor static func currentReport() -> Report {
        let report = run()
        #if DEBUG
        if ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_TZDATA"] == "stale", ApplicationSession.isTesting {
            return Report(version: "2023c", coverage: report.coverage, checked: report.checked, stale: [
                Stale(zone: "Asia/Almaty", since: "2024-03", expectedMinutes: 300, observedMinutes: 360),
                Stale(zone: "America/Asuncion", since: "2024-10", expectedMinutes: -180, observedMinutes: -240),
                Stale(zone: "Asia/Tokyo", since: "2026-01", expectedMinutes: 540, observedMinutes: 600),
            ], unknown: [])
        }
        #endif
        return report
    }

    /// "UTC−6", "UTC+5:30", "UTC"; the minus sign is the typographic one.
    static func offsetLabel(_ minutes: Int) -> String {
        if minutes == 0 { return "UTC" }
        let sign = minutes < 0 ? "−" : "+"
        let magnitude = abs(minutes)
        let hours = magnitude / 60, rest = magnitude % 60
        return rest == 0 ? "UTC\(sign)\(hours)" : "UTC\(sign)\(hours):" + String(format: "%02d", rest)
    }
}
