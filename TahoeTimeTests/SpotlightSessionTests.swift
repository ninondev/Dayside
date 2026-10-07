// SPDX-License-Identifier: GPL-3.0-only
// 地点会话更新走值类型假索引，避免系统实体关联的同步服务调用。

import CoreSpotlight
import Foundation
import Testing
@testable import TahoeTime

private actor SessionSpotlightIndex: SpotlightIndexBackend {
    nonisolated let isAvailable = true
    struct Replacement: Sendable {
        let entities: [SpotlightPlaceIndex.Entity]
        let version: String
        let hadPrevious: Bool
    }
    private var version: String?
    private var replacements: [Replacement] = []
    private var fetches = 0
    private var touchedMainThread = false
    private var holdNext = false
    private var release: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private var active = 0
    private var maxActive = 0

    private nonisolated func onMainThread() -> Bool { Thread.isMainThread }

    func lastVersion() async throws -> String? {
        touchedMainThread = touchedMainThread || onMainThread()
        fetches += 1
        return version
    }

    nonisolated func replaceAll(_ items: [CSSearchableItem], version: String, hadPrevious: Bool) async throws {
        Issue.record("the session must use the value entity seam")
    }

    func replaceEntities(_ entities: [SpotlightPlaceIndex.Entity], version: String, hadPrevious: Bool) async throws {
        touchedMainThread = touchedMainThread || onMainThread()
        active += 1
        maxActive = max(maxActive, active)
        if holdNext {
            holdNext = false
            await withCheckedContinuation { continuation in
                release = continuation
                started?.resume()
                started = nil
            }
        }
        replacements.append(.init(entities: entities, version: version, hadPrevious: hadPrevious))
        self.version = version
        active -= 1
    }

    func holdNextReplacement() { holdNext = true }
    func waitUntilReplacementStarted() async {
        if release != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func releaseReplacement() {
        release?.resume()
        release = nil
    }
    func snapshot() -> (replacements: [Replacement], fetches: Int, touchedMainThread: Bool, maxActive: Int, active: Int) {
        (replacements, fetches, touchedMainThread, maxActive, active)
    }
}

@MainActor
struct SpotlightSessionTests {
    private let identifiers = ["Asia/Tokyo", "Europe/Berlin", "Europe/London"]

    private func model() -> (AppModel, () -> Void) {
        let (defaults, cleanup) = TestDefaults.make(prefix: "dayside.spotlight.session")
        Store.saveZones([
            TimeZoneEntry(timezoneID: "Europe/Berlin", customName: "Headquarters", cityName: "Berlin"),
            TimeZoneEntry(timezoneID: "Asia/Tokyo", cityName: "Tokyo"),
        ], to: defaults)
        return (AppModel(defaults: defaults, migrate: false, applySystemIntegration: false), cleanup)
    }

    @Test func editsReachTheIndexInOneBatchWithoutRelaunch() async throws {
        let (model, cleanup) = model()
        defer { cleanup() }
        let index = SessionSpotlightIndex()
        let session = SpotlightIndexSession(backend: index, identifiers: identifiers, tzdata: "test", editDelay: .milliseconds(30))
        model.startSpotlightIndexing(session: session, startupDelay: .zero)
        await session.waitForUpdates()
        let initial = await index.snapshot()
        #expect(initial.replacements.count == 1)
        #expect(initial.replacements[0].entities.first { $0.id == "Europe/Berlin" }?.keywords.contains("Headquarters") == true)

        model.addZone(.init(identifier: "Europe/London", coordinate: .init(latitude: 51.5, longitude: -0.1)))
        let london = try #require(model.zones.first { $0.timezoneID == "Europe/London" })
        model.rename(id: london.id, to: "Temporary Office")
        model.rename(id: london.id, to: "New Office")
        model.removeZone(id: try #require(model.zones.first { $0.timezoneID == "Europe/Berlin" }).id)
        await session.waitForUpdates()

        let updated = await index.snapshot()
        #expect(updated.replacements.count == 2)
        #expect(updated.fetches == 2)
        let latest = try #require(updated.replacements.last)
        #expect(latest.hadPrevious)
        #expect(latest.entities.first { $0.id == "Europe/London" }?.keywords.contains("New Office") == true)
        #expect(!latest.entities.flatMap(\.keywords).contains("Temporary Office"))
        #expect(!latest.entities.flatMap(\.keywords).contains("Headquarters"))
        #expect(!updated.touchedMainThread)
        #expect(updated.maxActive == 1)
    }

    @Test func editsBeforeDelayedStartupUseOnlyTheLatestSavedPlaces() async throws {
        let (model, cleanup) = model()
        defer { cleanup() }
        let index = SessionSpotlightIndex()
        let session = SpotlightIndexSession(backend: index, identifiers: identifiers, tzdata: "test", editDelay: .milliseconds(30))
        model.startSpotlightIndexing(session: session, startupDelay: .seconds(5))
        let berlin = try #require(model.zones.first { $0.timezoneID == "Europe/Berlin" })
        model.rename(id: berlin.id, to: "Latest Name")
        model.removeZone(id: try #require(model.zones.first { $0.timezoneID == "Asia/Tokyo" }).id)
        await session.waitForUpdates()
        let result = await index.snapshot()
        #expect(result.replacements.count == 1)
        #expect(result.fetches == 1)
        #expect(result.replacements[0].entities.first { $0.id == "Europe/Berlin" }?.keywords.contains("Latest Name") == true)
        #expect(!result.replacements[0].entities.flatMap(\.keywords).contains("Headquarters"))
    }

    @Test func removingAllPlacesClearsSavedAliasesAndUndoRestoresThem() async {
        let (model, cleanup) = model()
        defer { cleanup() }
        let index = SessionSpotlightIndex()
        let session = SpotlightIndexSession(backend: index, identifiers: identifiers, tzdata: "test", editDelay: .milliseconds(30))
        model.startSpotlightIndexing(session: session, startupDelay: .zero)
        await session.waitForUpdates()
        model.removeZones(ids: model.zones.map(\.id))
        await session.waitForUpdates()
        let removed = await index.snapshot()
        #expect(removed.replacements.count == 2)
        #expect(removed.replacements[1].hadPrevious)
        #expect(!removed.replacements[1].entities.flatMap(\.keywords).contains("Headquarters"))
        model.restoreRemovedZones()
        await session.waitForUpdates()
        let restored = await index.snapshot()
        #expect(restored.replacements.count == 3)
        #expect(restored.replacements[2].entities.flatMap(\.keywords).contains("Headquarters"))
    }

    @Test func anEditDuringAnActiveBatchFinishesWithTheLatestSnapshot() async throws {
        let (model, cleanup) = model()
        defer { cleanup() }
        let index = SessionSpotlightIndex()
        await index.holdNextReplacement()
        let session = SpotlightIndexSession(backend: index, identifiers: identifiers, tzdata: "test", editDelay: .milliseconds(30))
        model.startSpotlightIndexing(session: session, startupDelay: .zero)
        await index.waitUntilReplacementStarted()
        let berlin = try #require(model.zones.first { $0.timezoneID == "Europe/Berlin" })
        model.rename(id: berlin.id, to: "After Startup")
        await session.waitForPendingEdit()
        let blocked = await index.snapshot()
        #expect(blocked.active == 1)
        #expect(blocked.maxActive == 1)
        #expect(blocked.fetches == 1)
        #expect(blocked.replacements.isEmpty)
        await index.releaseReplacement()
        await session.waitForUpdates()
        let result = await index.snapshot()
        #expect(result.replacements.count == 2)
        #expect(result.maxActive == 1)
        #expect(result.replacements.last?.entities.first { $0.id == "Europe/Berlin" }?.keywords.contains("After Startup") == true)
        #expect(result.replacements.last?.hadPrevious == true)
    }

    @Test func idleAndUnrelatedChangesDoNotReadOrWriteTheIndex() async throws {
        let (model, cleanup) = model()
        defer { cleanup() }
        let index = SessionSpotlightIndex()
        let session = SpotlightIndexSession(backend: index, identifiers: identifiers, tzdata: "test", editDelay: .milliseconds(30))
        model.startSpotlightIndexing(session: session, startupDelay: .zero)
        await session.waitForUpdates()
        let first = await index.snapshot()
        let berlin = try #require(model.zones.first { $0.timezoneID == "Europe/Berlin" })
        model.rename(id: berlin.id, to: "Headquarters")
        model.decorate(id: berlin.id, emoji: "A", color: nil)
        model.now = Date(timeIntervalSince1970: 1234567)
        model.settings.showSeconds.toggle()
        await session.waitForUpdates()
        try await Task.sleep(for: .milliseconds(70))
        let idle = await index.snapshot()
        #expect(idle.fetches == first.fetches)
        #expect(idle.replacements.count == first.replacements.count)
    }
}
