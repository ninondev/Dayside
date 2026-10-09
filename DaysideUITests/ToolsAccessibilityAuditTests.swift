// SPDX-License-Identifier: GPL-3.0-only
import XCTest

/// Apple's accessibility audit, run against every tool page of the real Dayside build. The app opens
/// the requested page itself from a Debug-only launch environment; the test never clicks anything and
/// never touches the user's data, because the test host uses a throwaway defaults suite.
@MainActor
final class ToolsAccessibilityAuditTests: XCTestCase {
    private static let pages = ["planner", "agenda", "people", "convert", "timers", "dstWatch", "astronomy", "travel", "sharing"]
    private static let auditTypes: XCUIAccessibilityAuditType = [.contrast, .elementDetection, .hitRegion, .sufficientElementDescription]

    override func setUp() {
        continueAfterFailure = true
    }

    func testEveryToolPagePassesTheAccessibilityAudit() throws {
        // The runner is sandboxed, so the report lands in its own container unless a writable path is given.
        let outputDirectory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MEANTIME_UI_AUDIT_DIR"]
            ?? NSTemporaryDirectory().appending("dayside-audit"))
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        print("MEANTIME_UI_AUDIT_DIR=\(outputDirectory.path)")
        var report = ["page\tkind\tdescription\telement"]
        var failures: [String] = []
        for page in Self.pages {
            let app = XCUIApplication()
            app.launchEnvironment["MEANTIME_TEST_HOST"] = "1"
            app.launchEnvironment["MEANTIME_UI_TEST_FEATURE"] = page
            app.launch()
            let window = app.windows.firstMatch
            guard window.waitForExistence(timeout: 30) else {
                XCTFail("\(page): the tools window never appeared")
                failures.append("\(page): no window")
                app.terminate()
                continue
            }
            // Let lazy lists and async stores settle before the audit walks the tree.
            _ = window.staticTexts.firstMatch.waitForExistence(timeout: 5)
            var issues: [String] = []
            do {
                try app.performAccessibilityAudit(for: Self.auditTypes) { issue in
                    let element = issue.element.map { "\($0)" } ?? "-"
                    issues.append("\(Self.name(of: issue.auditType))\t\(issue.compactDescription)\t\(element)")
                    return true // recorded here and asserted below, so one finding never stops the sweep
                }
            } catch {
                XCTFail("\(page): the audit could not run: \(error)")
                failures.append("\(page): audit error \(error)")
            }
            report += issues.map { "\(page)\t\($0)" }
            let shot = window.screenshot()
            try? shot.pngRepresentation.write(to: outputDirectory.appendingPathComponent("\(page).png"))
            let attachment = XCTAttachment(screenshot: shot)
            attachment.name = page
            attachment.lifetime = .keepAlways
            add(attachment)
            if !issues.isEmpty { failures.append("\(page): \(issues.count) finding(s)") }
            app.terminate()
        }
        let text = report.joined(separator: "\n") + "\n"
        try text.write(to: outputDirectory.appendingPathComponent("audit.tsv"), atomically: true, encoding: .utf8)
        XCTAssertTrue(failures.isEmpty, "accessibility audit findings:\n" + failures.joined(separator: "\n"))
    }

    private static func name(of type: XCUIAccessibilityAuditType) -> String {
        var names: [String] = []
        if type.contains(.contrast) { names.append("contrast") }
        if type.contains(.elementDetection) { names.append("elementDetection") }
        if type.contains(.hitRegion) { names.append("hitRegion") }
        if type.contains(.sufficientElementDescription) { names.append("sufficientElementDescription") }
        return names.isEmpty ? "\(type.rawValue)" : names.joined(separator: "+")
    }
}
