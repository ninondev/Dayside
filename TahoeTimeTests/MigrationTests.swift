// SPDX-License-Identifier: GPL-3.0-only
//
//  MigrationTests.swift
//  TahoeTimeTests
//
//  偏好域迁移:从旧域一次性搬进沙盒容器的标准域。
//  三个独立 suite 模拟 目标 / 旧 .standard / 旧 bundle id 域,绝不碰真实偏好。
//

import XCTest
@testable import TahoeTime

final class MigrationTests: XCTestCase {

    private var target: UserDefaults!
    private var legacyStandard: UserDefaults!
    private var legacyOldBundle: UserDefaults!
    private var teardowns: [() -> Void] = []
    private let zonesKey = "tahoetime.zones.v1"
    private let settingsKey = "tahoetime.settings.v1"

    override func setUpWithError() throws {
        try super.setUpWithError()
        let targetHandle = TestDefaults.make(prefix: "com.dayside.tests.migration-target")
        let legacyStandardHandle = TestDefaults.make(prefix: "com.dayside.tests.migration-standard")
        let legacyOldBundleHandle = TestDefaults.make(prefix: "com.dayside.tests.migration-oldbundle")
        target = targetHandle.defaults
        legacyStandard = legacyStandardHandle.defaults
        legacyOldBundle = legacyOldBundleHandle.defaults
        teardowns = [targetHandle.cleanup, legacyStandardHandle.cleanup, legacyOldBundleHandle.cleanup]
    }

    override func tearDownWithError() throws {
        teardowns.forEach { $0() }
        teardowns = []
        try super.tearDownWithError()
    }

    private func seed(_ d: UserDefaults, cities: [String]) {
        let zones = cities.map { TimeZoneEntry(timezoneID: "Asia/Tokyo", cityName: $0, coordinate: nil) }
        Store.saveZones(zones, to: d)                      // 主键 + .last-nonempty
        var s = AppSettings(); s.menuBarMaxZones = cities.count
        Store.saveSettings(s, to: d)
        d.set(Data("corrupt".utf8), forKey: zonesKey + ".corrupt-backup")
    }

    func testMigratesFromFirstSourceThatHasData() {
        seed(legacyStandard, cities: ["Tokyo", "Madrid"])
        let name = Store.migrateIfNeeded(into: target, from: [legacyStandard, legacyOldBundle],
                                         sourceNames: ["standard", "old"])
        XCTAssertEqual(name, "standard")
        XCTAssertEqual(Store.loadZones(from: target).zones.map(\.cityName), ["Tokyo", "Madrid"])
        XCTAssertEqual(Store.loadSettings(from: target).menuBarMaxZones, 2)
        XCTAssertNotNil(target.data(forKey: zonesKey + Store.lastNonEmptySuffix), "快照旁键要一起搬")
        XCTAssertNotNil(target.data(forKey: zonesKey + ".corrupt-backup"), "损坏备份旁键要一起搬")
        XCTAssertEqual(target.string(forKey: Store.migrationMarkerKey), "standard")
        XCTAssertNotNil(legacyStandard.data(forKey: zonesKey), "来源不清空,留作退路")
    }

    func testSkipsEmptySourcesAndUsesLaterOne() {
        seed(legacyOldBundle, cities: ["Oslo"])
        let name = Store.migrateIfNeeded(into: target, from: [legacyStandard, legacyOldBundle],
                                         sourceNames: ["standard", "old"])
        XCTAssertEqual(name, "old")
        XCTAssertEqual(Store.loadZones(from: target).zones.map(\.cityName), ["Oslo"])
    }

    func testDoesNothingWhenTargetAlreadyHasData() {
        seed(target, cities: ["Lima"])
        seed(legacyStandard, cities: ["Tokyo"])
        XCTAssertNil(Store.migrateIfNeeded(into: target, from: [legacyStandard]))
        XCTAssertEqual(Store.loadZones(from: target).zones.map(\.cityName), ["Lima"])
        XCTAssertNil(target.string(forKey: Store.migrationMarkerKey))
    }

    func testDoesNothingWhenNoSourceHasData() {
        XCTAssertNil(Store.migrateIfNeeded(into: target, from: [legacyStandard, legacyOldBundle]))
        XCTAssertNil(target.data(forKey: zonesKey))
        XCTAssertNil(target.string(forKey: Store.migrationMarkerKey))
    }

    /// 改名后的整域搬迁：上一个 App Group 里 App 自己的键（含 meantime.* 的人物 / 旅行 / 快照）原样过来，系统与全局键不过来，
    /// 来源不清空，写标记；目标已有数据或已有标记时什么都不做；之后的旧域迁移因为标记在也不再动。
    func testCopiesWholeAppDomainFromPreviousGroupOnce() {
        seed(legacyOldBundle, cities: ["Tokyo", "Madrid"])
        legacyOldBundle.set(Data("people".utf8), forKey: "meantime.people.v1")
        legacyOldBundle.set("旧标记", forKey: Store.migrationMarkerKey)
        legacyOldBundle.set("frame", forKey: "NSWindow Frame tools")
        let copied = Store.migrateFromPreviousGroupIfNeeded(into: target, from: legacyOldBundle, sourceName: "previous-group")
        XCTAssertGreaterThanOrEqual(copied, 4, "地点、快照、损坏备份、设置、人物都该搬")
        XCTAssertEqual(Store.loadZones(from: target).zones.map(\.cityName), ["Tokyo", "Madrid"])
        XCTAssertEqual(Store.loadSettings(from: target).menuBarMaxZones, 2)
        XCTAssertEqual(target.data(forKey: "meantime.people.v1"), Data("people".utf8))
        XCTAssertNil(target.string(forKey: "NSWindow Frame tools"))
        XCTAssertEqual(target.string(forKey: Store.migrationMarkerKey), "previous-group", "标记写来源名，不照搬旧标记")
        XCTAssertNotNil(legacyOldBundle.data(forKey: zonesKey), "来源不清空")
        XCTAssertEqual(Store.migrateFromPreviousGroupIfNeeded(into: target, from: legacyOldBundle), 0, "第二次不再搬")
        XCTAssertNil(Store.migrateIfNeeded(into: target, from: [legacyStandard]), "有标记后旧域迁移也不动")
    }

    func testPreviousGroupMigrationLeavesAPopulatedTargetAlone() {
        seed(target, cities: ["Lima"])
        seed(legacyOldBundle, cities: ["Tokyo"])
        XCTAssertEqual(Store.migrateFromPreviousGroupIfNeeded(into: target, from: legacyOldBundle), 0)
        XCTAssertEqual(Store.loadZones(from: target).zones.map(\.cityName), ["Lima"])
        XCTAssertEqual(Store.migrateFromPreviousGroupIfNeeded(into: target, from: nil), 0, "没有旧 group 时安静返回")
    }

    /// 迁过一次就不再迁:哪怕之后主键被外力抹掉,也不能把旧数据再灌回来盖住快照补回。
    func testMarkerPreventsSecondMigration() {
        seed(legacyStandard, cities: ["Tokyo"])
        XCTAssertNotNil(Store.migrateIfNeeded(into: target, from: [legacyStandard]))
        target.removeObject(forKey: zonesKey)
        target.removeObject(forKey: settingsKey)
        seed(legacyStandard, cities: ["Berlin"])
        XCTAssertNil(Store.migrateIfNeeded(into: target, from: [legacyStandard]))
        XCTAssertNil(target.data(forKey: zonesKey))
    }

    /// AppModel 启动时走迁移:目标域空、旧域有数据 → 加载到的就是旧数据,且已落到目标域。
    @MainActor func testAppModelMigratesOnLaunch() {
        seed(legacyStandard, cities: ["Tokyo", "Madrid"])
        Store.migrateIfNeeded(into: target, from: [legacyStandard], sourceNames: ["standard"])
        let model = AppModel(defaults: target, migrate: false)
        XCTAssertEqual(model.zones.map(\.cityName), ["Tokyo", "Madrid"])
        XCTAssertFalse(model.zonesRecoveryNotice, "迁移不是恢复,不该弹恢复提示")
    }

    func testAppGroupSuiteIsUsableInSandbox() {
        // 测试宿主就是沙盒 app 本体:生产偏好域必须可写可读。跨进程落盘由 macOS 验收另行证明。
        let group = Store.appDefaults
        let key = "tahoetime.tests.appgroup-probe"
        group.set("ok", forKey: key)
        XCTAssertEqual(group.string(forKey: key), "ok")
        group.removeObject(forKey: key)
    }
}
