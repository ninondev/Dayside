// SPDX-License-Identifier: GPL-3.0-only
//
//  SpotlightIndexTests.swift
//  DaysideTests
//
//  Spotlight 地点索引：事实收集（只有地点、没有人物）、Rust 计划、版本门（没变不写）、条目形状，
//  以及「打开地点」意图的模型效果。真实的 CoreSpotlight 一律不碰——测试宿主与安装版同一个 bundle id，
//  写进去就是污染用户的 Spotlight。
//

import AppIntents
import CoreSpotlight
import Foundation
import Testing
@testable import Dayside

/// 记录器：假装是 CoreSpotlight，记下每次调用。
final class SpotlightIndexSpy: SpotlightIndexBackend, @unchecked Sendable {
    var isAvailable = true
    var storedVersion: String?
    var fetchError: Error?
    var replaceError: Error?
    private(set) var fetches = 0
    private(set) var replacements: [(count: Int, version: String, hadPrevious: Bool, items: [CSSearchableItem])] = []

    init(storedVersion: String? = nil) { self.storedVersion = storedVersion }

    func lastVersion() async throws -> String? {
        fetches += 1
        if let fetchError { throw fetchError }
        return storedVersion
    }

    func replaceAll(_ items: [CSSearchableItem], version: String, hadPrevious: Bool) async throws {
        if let replaceError { throw replaceError }
        replacements.append((items.count, version, hadPrevious, items))
        storedVersion = version
    }
}

@MainActor
struct SpotlightIndexTests {
    private func makeModel() -> (AppModel, () -> Void) {
        let (defaults, cleanup) = TestDefaults.make(prefix: "meantime.spotlight.tests")
        Store.saveZones([
            TimeZoneEntry(timezoneID: "Europe/Berlin", customName: "慕尼黑", cityName: "Munich", usesExemplarName: false),
            TimeZoneEntry(timezoneID: "Asia/Tokyo", cityName: "Tokyo"),
        ], to: defaults)
        let model = AppModel(defaults: defaults, migrate: false,
                             applySystemIntegration: false)
        return (model, cleanup)
    }

    @Test func theSeedCarriesOnlySavedPlacesWithTheirDisplayNames() {
        let (model, cleanup) = makeModel()
        defer { cleanup() }
        let seed = SpotlightPlaceIndex.seed(model: model)
        #expect(seed.places.map(\.timeZoneID) == ["Europe/Berlin", "Asia/Tokyo"])
        #expect(seed.places.first?.name == "慕尼黑", "the custom name is what people will type")
        #expect(seed.locale.identifier == model.uiLocale.identifier)
        // 事实结构里没有人物字段：按构造进不了索引。
        let mirror = Mirror(reflecting: SpotlightPlaceIndex.facts(seed: seed, identifiers: ["Asia/Tokyo"], tzdata: "2026c"))
        #expect(mirror.children.map { $0.label ?? "" }.sorted() == ["catalog", "locale", "places", "tzdata"])
    }

    @Test func catalogRowsNameEveryIdentifierInEachLocaleAndTheZoneInThePrimaryOne() {
        let rows = SpotlightPlaceIndex.catalogRows(identifiers: ["Asia/Tokyo", "America/Argentina/Buenos_Aires", "UTC"],
                                                   locales: [Locale(identifier: "zh-Hans"), Locale(identifier: "en"), Locale(identifier: "zh-Hans")])
        #expect(rows.count == 3)
        #expect(rows[0].names == ["东京", "Tokyo"], "duplicate locales collapse to one formatter each")
        #expect(rows[0].zone.contains("日本"))
        #expect(rows[1].names == ["布宜诺斯艾利斯", "Buenos Aires"])
        #expect(rows[2].names.allSatisfy { !$0.isEmpty })
        // 全目录一遍是启动后的真实工作量：几百个标识符、三种语言，应在几十毫秒内。
        let started = ContinuousClock.now
        let all = SpotlightPlaceIndex.catalogRows(identifiers: TimeZonePlaceCatalog.identifiers,
                                                  locales: [Locale(identifier: "zh-Hans"), Locale.current, Locale(identifier: "en")])
        let elapsed = ContinuousClock.now - started
        #expect(all.count == TimeZonePlaceCatalog.identifiers.count)
        #expect(all.count > 300)
        #expect(elapsed < .seconds(2), "\(elapsed)")
    }

    @Test func thePlanIndexesTheCatalogPlusSavedPlaceNamesAndNeverPeople() {
        let (model, cleanup) = makeModel()
        defer { cleanup() }
        let seed = SpotlightPlaceIndex.seed(model: model)
        let facts = SpotlightPlaceIndex.facts(seed: seed, identifiers: ["Asia/Tokyo", "Europe/Berlin", "Europe/London"], tzdata: "2026c")
        let plan = SpotlightPlaceIndex.plan(facts)
        #expect(plan.entities.map(\.id) == ["Asia/Tokyo", "Europe/Berlin", "Europe/London"])
        let berlin = try! #require(plan.entities.first { $0.id == "Europe/Berlin" })
        #expect(berlin.keywords.contains("慕尼黑"), "\(berlin.keywords)")
        #expect(berlin.keywords.contains("Europe/Berlin"))
        #expect(berlin.keywords.contains("Berlin"))
        #expect(!berlin.displayName.isEmpty)
        #expect(plan.version.hasPrefix("2026c|3|2|"), Comment(rawValue: plan.version))
        let london = try! #require(plan.entities.first { $0.id == "Europe/London" })
        #expect(!london.keywords.contains("慕尼黑"))
    }

    @Test func aRebuildOnlyHappensWhenTheVersionChanged() async {
        let (model, cleanup) = makeModel()
        defer { cleanup() }
        let ids = ["Asia/Tokyo", "Europe/Berlin"]
        let spy = SpotlightIndexSpy()
        let first = await SpotlightPlaceIndex.rebuildIfNeeded(seed: SpotlightPlaceIndex.seed(model: model), identifiers: ids, tzdata: "2026c", backend: spy)
        guard case .rebuilt(let count, let version) = first else { Issue.record("expected a rebuild, got \(first)"); return }
        #expect(count == 2)
        #expect(spy.replacements.count == 1)
        #expect(spy.replacements[0].hadPrevious == false, "first run: nothing to delete")
        #expect(spy.replacements[0].version == version)

        let second = await SpotlightPlaceIndex.rebuildIfNeeded(seed: SpotlightPlaceIndex.seed(model: model), identifiers: ids, tzdata: "2026c", backend: spy)
        #expect(second == .unchanged(version))
        #expect(spy.replacements.count == 1, "same version: the index is left alone")
        #expect(spy.fetches == 2)

        // 改名后版本变了：重建，且因为有旧索引要先清。
        model.rename(id: model.zones[0].id, to: "总部")
        let third = await SpotlightPlaceIndex.rebuildIfNeeded(seed: SpotlightPlaceIndex.seed(model: model), identifiers: ids, tzdata: "2026c", backend: spy)
        guard case .rebuilt(_, let newVersion) = third else { Issue.record("expected a rebuild, got \(third)"); return }
        #expect(newVersion != version)
        #expect(spy.replacements.count == 2)
        #expect(spy.replacements[1].hadPrevious == true)
        let berlin = spy.replacements[1].items.first { $0.uniqueIdentifier == "Europe/Berlin" }
        #expect(berlin?.attributeSet.keywords?.contains("总部") == true)
        #expect(berlin?.attributeSet.keywords?.contains("慕尼黑") == false, "an old name leaves the keywords")

        // tzdata 换代同样重建。
        _ = await SpotlightPlaceIndex.rebuildIfNeeded(seed: SpotlightPlaceIndex.seed(model: model), identifiers: ids, tzdata: "2026d", backend: spy)
        #expect(spy.replacements.count == 3)
        // 版本串的便宜路径与完整计划一致：没变的启动不该去取 445 个名字。
        let seed = SpotlightPlaceIndex.seed(model: model)
        #expect(SpotlightPlaceIndex.version(seed: seed, identifiers: ids, tzdata: "2026d")
                == SpotlightPlaceIndex.plan(SpotlightPlaceIndex.facts(seed: seed, identifiers: ids, tzdata: "2026d")).version)
    }

    @Test func failuresStaySilentAndUnavailabilitySkipsAllWork() async {
        let (model, cleanup) = makeModel()
        defer { cleanup() }
        let seed = SpotlightPlaceIndex.seed(model: model)
        let offline = SpotlightIndexSpy()
        offline.isAvailable = false
        #expect(await SpotlightPlaceIndex.rebuildIfNeeded(seed: seed, identifiers: ["Asia/Tokyo"], tzdata: "2026c", backend: offline) == .unavailable)
        #expect(offline.fetches == 0)

        let unreadable = SpotlightIndexSpy(storedVersion: "stale")
        unreadable.fetchError = CocoaError(.fileReadUnknown)
        let outcome = await SpotlightPlaceIndex.rebuildIfNeeded(seed: seed, identifiers: ["Asia/Tokyo"], tzdata: "2026c", backend: unreadable)
        guard case .rebuilt = outcome else { Issue.record("unreadable state must rebuild, got \(outcome)"); return }
        #expect(unreadable.replacements[0].hadPrevious == false, "unknown state is treated as no index")

        let broken = SpotlightIndexSpy()
        broken.replaceError = CocoaError(.fileWriteUnknown)
        let failed = await SpotlightPlaceIndex.rebuildIfNeeded(seed: seed, identifiers: ["Asia/Tokyo"], tzdata: "2026c", backend: broken)
        guard case .failed = failed else { Issue.record("expected .failed, got \(failed)"); return }
        #expect(broken.storedVersion == nil)
    }

    @Test func itemsCarryDisplayNameKeywordsNoExpiryAndTheEntityAssociation() {
        let entity = SpotlightPlaceIndex.Entity(id: "Asia/Tokyo", displayName: "东京", description: "日本标准时间",
                                                keywords: ["Asia/Tokyo", "Asia", "Tokyo", "东京"])
        let item = SpotlightPlaceIndex.item(for: entity)
        #expect(item.uniqueIdentifier == "Asia/Tokyo")
        #expect(item.domainIdentifier == SpotlightPlaceIndex.domain)
        #expect(item.expirationDate == .distantFuture, "CoreSpotlight expires items after a month by default")
        #expect(item.attributeSet.displayName == "东京")
        #expect(item.attributeSet.title == "东京")
        #expect(item.attributeSet.contentDescription == "日本标准时间")
        #expect(item.attributeSet.keywords == ["Asia/Tokyo", "Asia", "Tokyo", "东京"])
        #expect(item.attributeSet.alternateNames == ["Asia", "Tokyo", "东京"])
        let bare = SpotlightPlaceIndex.item(for: .init(id: "UTC", displayName: "UTC", description: "", keywords: ["UTC"]))
        #expect(bare.attributeSet.contentDescription == nil)
        // 实体自己的属性集走同一套规则：名字与标识符关键词都在。
        let set = TimeZonePlaceEntity(id: "Europe/Paris").attributeSet
        #expect(set.displayName?.isEmpty == false)
        #expect(set.keywords?.contains("Europe/Paris") == true)
        #expect(set.keywords?.contains("Paris") == true)
    }

    @Test func openingAPlaceAddsItOnceAndLeavesExistingOnesAlone() async throws {
        // 意图读的是 AppModel.shared（测试宿主的一次性偏好域），这里只核模型效果；开窗走 URL，隔离会话里不开。
        let model = AppModel.shared
        let hub = FeatureHub.shared
        hub.attach(to: model)
        let before = model.zones.count
        let candidate = ["Pacific/Auckland", "Africa/Nairobi", "America/Halifax", "Asia/Yerevan"]
            .first { id in !model.zones.contains { $0.timezoneID == id } }
        let zoneID = try #require(candidate)
        _ = try await OpenPlaceIntent(target: TimeZonePlaceEntity(id: zoneID)).perform()
        #expect(model.zones.count == before + 1)
        #expect(model.zones.last?.timezoneID == zoneID)
        _ = try await OpenPlaceIntent(target: TimeZonePlaceEntity(id: zoneID)).perform()
        #expect(model.zones.count == before + 1, "opening an already saved place does not duplicate it")
        if let added = model.zones.last(where: { $0.timezoneID == zoneID }) { model.removeZone(id: added.id) }
        #expect(model.zones.count == before)
    }

    @Test func theOpenIntentAndTheFourActionsAllDeclareSummariesAndPhrases() {
        // 摘要必须覆盖没有默认值的必填参数（换算的表达式、添加地点的时区标识），Spotlight 才列出动作。
        _ = ConvertTimeIntent.parameterSummary
        _ = FindOverlapIntent.parameterSummary
        _ = AddPlaceIntent.parameterSummary
        _ = CheckTimeZoneDataIntent.parameterSummary
        _ = OpenPlaceIntent.parameterSummary
        #expect(DaysideShortcuts.appShortcuts.count == 5)
        #expect(OpenPlaceIntent.supportedModes == .foreground)
    }
}
