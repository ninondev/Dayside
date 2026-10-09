// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import Dayside

struct TZDataCheckTests {
    @MainActor @Test func anIncompleteDataCheckDoesNotShowTheCurrentDataStatus() {
        let incomplete = TZDataCheck.Report(version: "2026c", coverage: "2026-07", checked: 25,
                                            stale: [], unknown: ["Asia/Almaty"])
        #expect(!DSTWatchLensView.showsCurrentDataStatus(incomplete))
        let complete = TZDataCheck.Report(version: "2026c", coverage: "2026-07", checked: 26,
                                          stale: [], unknown: [])
        #expect(DSTWatchLensView.showsCurrentDataStatus(complete))
    }

    /// This Mac's tzdata (2026c on 2026-09-11) agrees with every known rule change in the table.
    /// If this fails after a macOS update, the table needs a look before the user is warned.
    @Test func installedDataMatchesEveryKnownRuleChange() {
        let report = TZDataCheck.run()
        #expect(report.checked >= 26)
        #expect(report.unknown.isEmpty, "\(report.unknown)")
        #expect(report.stale.isEmpty, "\(report.stale)")
        #expect(report.version != nil)
        #expect(report.coverage.count == 7)
    }

    @Test func aMacWhoseDataPredatesAChangeIsNamedPreciselyWithoutTouchingTheTable() {
        let report = TZDataCheck.run(version: "2023c")
        #expect(report.version == "2023c")
        #expect(report.stale.isEmpty)
        let stale = TZDataCheck.Stale(zone: "Asia/Almaty", since: "2024-03", expectedMinutes: 300, observedMinutes: 360)
        #expect(stale.id == "Asia/Almaty@2024-03")
    }

    @Test func aTimeCardCarriesTheSendersReleaseAndOldCardsStillImport() throws {
        var draft = SharingDraft()
        draft.timeZoneID = "Asia/Tokyo"
        let now = Date(timeIntervalSince1970: 1_789_041_600)
        let document = try #require(SharingGenerator.build(draft: draft, hostURL: "", now: now).document)
        let imported = try TimeCard.person(from: document.fragment, now: now).get()
        #expect(imported.senderTZData == TZDataCheck.installedVersion)
        // A card from before the field existed: version-1 JSON without "tzdata".
        let legacy = "mt1." + Data(#"{"version":1,"timeZoneID":"Asia/Tokyo","generatedAt":1789041600,"validUntil":1790251200,"windows":[]}"#.utf8)
            .base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let old = try TimeCard.person(from: legacy, now: now).get()
        #expect(old.senderTZData == nil)
        #expect(old.contact.timeZoneID == "Asia/Tokyo")
    }

    @MainActor @Test func theShortcutsActionReportsTheSameSentenceAsThePage() async throws {
        let result = try await CheckTimeZoneDataIntent().perform()
        let text = result.value ?? ""
        let version = try #require(TZDataCheck.installedVersion)
        #expect(text.contains(version), Comment(rawValue: text))
        #expect(text.contains("26"), Comment(rawValue: text))
        // 结论在前，版本与条数跟在后面（页面上正常时收成一行「时区数据是最新的（2026c）。」，说明进悬停提示；
        // 快捷指令没有悬停，仍返回完整两句合成一行）。
        #expect(text.hasPrefix(String(localized: "时区数据是最新的。")), Comment(rawValue: text))
        #expect(!text.contains("\n"), "an up-to-date Mac gets exactly one line")
    }

    @Test func offsetLabelsReadLikeTimeZoneTables() {
        #expect(TZDataCheck.offsetLabel(-360) == "UTC−6")
        #expect(TZDataCheck.offsetLabel(330) == "UTC+5:30")
        #expect(TZDataCheck.offsetLabel(-210) == "UTC−3:30")
        #expect(TZDataCheck.offsetLabel(0) == "UTC")
        #expect(TZDataCheck.offsetLabel(780) == "UTC+13")
    }
}
