// SPDX-License-Identifier: GPL-3.0-only
//
//  PersistenceTests.swift
//  DaysideTests
//
//  持久化容错的回归测试：一个坏字段不得清空全部数据，
//  menuBarMaxZones 必须钳制，负数会让 `zones.prefix(n)` 直接崩溃。
//
//  这些用例走**真实的 Store API**,不自己 new JSONDecoder——要测的正是 Store 的容错行为本身。
//

import XCTest
@testable import Dayside

final class PersistenceTests: XCTestCase {

    /// 独立的偏好域:测试宿主是 App 本体,若用 .standard 会把用户真实存下的时区清掉。
    private var defaults: UserDefaults!
    private var teardownDefaults: (() -> Void)!

    private let zonesKey = "dayside.zones.v1"
    private let settingsKey = "dayside.settings.v1"
    private var backupKey: String { zonesKey + ".corrupt-backup" }
    private var snapshotKey: String { zonesKey + Store.lastNonEmptySuffix }
    private var settingsBackupKey: String { settingsKey + ".corrupt-backup" }

    override func setUpWithError() throws {
        try super.setUpWithError()
        let (value, cleanup) = TestDefaults.make(prefix: "com.dayside.Dayside.legacy.tests")
        defaults = value
        teardownDefaults = cleanup
        clearKeys()
    }

    override func tearDownWithError() throws {
        clearKeys()
        teardownDefaults()
        teardownDefaults = nil
        defaults = nil
        try super.tearDownWithError()
    }

    private func clearKeys() {
        [zonesKey, settingsKey, backupKey, settingsBackupKey, snapshotKey]
            .forEach(defaults.removeObject(forKey:))
    }

    private func write(_ json: String, to key: String) {
        defaults.set(Data(json.utf8), forKey: key)
    }

    // MARK: - zones 的逐条容错

    func testValidArchiveRoundTripsWithoutRecoveryFlag() {
        let zones = [
            TimeZoneEntry(timezoneID: "Asia/Tokyo", cityName: "Tokyo",
                          coordinate: Coordinate(latitude: 35.68, longitude: 139.69)),
            TimeZoneEntry(timezoneID: "Europe/Madrid", cityName: "Madrid",
                          coordinate: Coordinate(latitude: 40.4, longitude: -3.68)),
        ]
        Store.saveZones(zones, to: defaults)

        let loaded = Store.loadZones(from: defaults)
        XCTAssertEqual(loaded.zones.count, 2)
        XCTAssertFalse(loaded.recovered)
        XCTAssertNil(defaults.data(forKey: backupKey), "健康数据不该产生备份")
    }

    /// 单个字段坏掉不该赔上整条记录。`id` 是内部身份令牌、对用户没有意义,
    /// 类型错时补一个新的即可——为了一个坏 UUID 丢掉用户的时区,代价远大于收益。
    /// (更早的版本会丢掉整条;更早之前会丢掉**整个数组**。)
    func testCorruptIdentityFieldIsRepairedInsteadOfDroppingTheEntry() {
        write("""
        [{"id":"1E240DD1-0000-4000-8000-000000000001","timezoneID":"Asia/Tokyo","cityName":"Tokyo"},
         {"id":12345,"timezoneID":"Europe/Madrid","cityName":"Madrid"},
         {"id":"1E240DD1-0000-4000-8000-000000000002","timezoneID":"Asia/Hong_Kong","cityName":"Hong Kong"}]
        """, to: zonesKey)

        let loaded = Store.loadZones(from: defaults)
        XCTAssertEqual(loaded.zones.map(\.cityName), ["Tokyo", "Madrid", "Hong Kong"],
                       "内容完好、只有身份令牌坏掉的条目应被修好保留,顺序不变")
        XCTAssertEqual(Set(loaded.zones.map(\.id)).count, 3, "补发的 UUID 不能与既有条目撞号")
        XCTAssertFalse(loaded.recovered, "没有丢任何条目就不该打扰用户")
    }

    /// 但**真正不可用**的条目仍须整条丢弃、备份原始字节、置恢复标记——
    /// 宽容解码不得让一个坏字段清空全部数据。
    func testUnusableEntryIsStillDroppedAndBackedUp() {
        write("""
        [{"id":"1E240DD1-0000-4000-8000-000000000001","timezoneID":"Asia/Tokyo","cityName":"Tokyo"},
         {"id":"1E240DD1-0000-4000-8000-000000000003","cityName":"没有时区的条目"},
         {"id":"1E240DD1-0000-4000-8000-000000000002","timezoneID":"Asia/Hong_Kong","cityName":"Hong Kong"}]
        """, to: zonesKey)

        let loaded = Store.loadZones(from: defaults)
        XCTAssertEqual(loaded.zones.map(\.cityName), ["Tokyo", "Hong Kong"], "健康条目应被抢救且保持原顺序")
        XCTAssertTrue(loaded.recovered, "丢了条目就必须置恢复标记")
        XCTAssertNotNil(defaults.data(forKey: backupKey), "原始字节必须备份到旁键")
    }

    /// 时区标识符这台 Mac 认不得(坏文件、手改、未来才有的名字)的条目同样是「真正不可用」:Rust 只能查
    /// 它是不是字符串,Foundation 才知道它是不是时区。留下来会以 GMT 时间冒充那座城市,所以整条丢弃、
    /// 备份原始字节、置恢复标记;健康条目照旧抢救(Swift 侧 fuzz 查出)。
    func testUnknownTimeZoneIdentifierIsDroppedAndBackedUp() {
        write("""
        [{"id":"1E240DD1-0000-4000-8000-000000000001","timezoneID":"Asia/Tokyo","cityName":"Tokyo"},
         {"id":"1E240DD1-0000-4000-8000-000000000003","timezoneID":"Not/AZone","cityName":"Nowhere"},
         {"id":"1E240DD1-0000-4000-8000-000000000004","timezoneID":"","cityName":"Blank"},
         {"id":"1E240DD1-0000-4000-8000-000000000002","timezoneID":"Asia/Hong_Kong","cityName":"Hong Kong"}]
        """, to: zonesKey)

        let loaded = Store.loadZones(from: defaults)
        XCTAssertEqual(loaded.zones.map(\.cityName), ["Tokyo", "Hong Kong"], "只留这台 Mac 认得的时区,顺序不变")
        XCTAssertTrue(loaded.recovered, "丢了条目就必须置恢复标记")
        XCTAssertNotNil(defaults.data(forKey: backupKey), "原始字节必须备份到旁键")
        let again = Store.loadZones(from: defaults)
        XCTAssertEqual(again.zones, loaded.zones, "备份不影响再次读取")
    }

    /// 旧存档没有 `usesExemplarName` 字段:必须默认 true,保持"时区代表城市名走 ICU"的旧行为。
    func testLegacyArchiveKeepsExemplarNaming() {
        write("""
        [{"id":"1E240DD1-0000-4000-8000-000000000001","timezoneID":"Asia/Tokyo","cityName":"Tokyo"}]
        """, to: zonesKey)
        let loaded = Store.loadZones(from: defaults)
        XCTAssertEqual(loaded.zones.count, 1)
        XCTAssertTrue(loaded.zones[0].usesExemplarName, "旧存档必须继续走 ICU 本地化代表城市名")
        XCTAssertFalse(loaded.recovered)
    }

    func testNonJSONArchiveIsBackedUpNotSilentlyDiscarded() {
        write("junk", to: zonesKey)

        let loaded = Store.loadZones(from: defaults)
        XCTAssertTrue(loaded.zones.isEmpty)
        XCTAssertTrue(loaded.recovered)
        XCTAssertEqual(defaults.data(forKey: backupKey), Data("junk".utf8))
    }

    /// 空数组是合法状态,不能被当成损坏(否则每个新用户一启动就看到恢复提示)。
    func testEmptyArrayIsNotTreatedAsCorruption() {
        write("[]", to: zonesKey)

        let loaded = Store.loadZones(from: defaults)
        XCTAssertTrue(loaded.zones.isEmpty)
        XCTAssertFalse(loaded.recovered)
        XCTAssertNil(defaults.data(forKey: backupKey))
    }

    /// 旧版存档没有 coordinate 字段,必须仍能解出来，以兼容旧版存档。
    func testLegacyEntryWithoutCoordinateStillDecodes() {
        write("""
        [{"id":"1E240DD1-0000-4000-8000-000000000003","timezoneID":"Asia/Tokyo","cityName":"Tokyo"}]
        """, to: zonesKey)

        let loaded = Store.loadZones(from: defaults)
        XCTAssertEqual(loaded.zones.count, 1)
        XCTAssertNil(loaded.zones.first?.coordinate)
        XCTAssertFalse(loaded.recovered, "缺可选字段是兼容,不是损坏")
    }

    // MARK: - settings 的逐字段容错

    /// 修复前:17 个字段里坏 1 个 → 整份设置打回默认,连 didAskLaunchAtLogin 都归零,
    /// 于是首启弹窗又冒出来一次。
    func testOneBadSettingsFieldDoesNotResetEverythingElse() throws {
        var settings = AppSettings()
        settings.weight = .bold
        settings.menuBarMaxZones = 6
        settings.didAskLaunchAtLogin = true
        settings.showSeconds = false

        var dict = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(settings)) as? [String: Any])
        dict["showSeconds"] = "yes"   // 类型错
        dict["showOffsetBesideName"] = 7   // 类型错（调研 #9 的开关，默认关）
        defaults.set(try JSONSerialization.data(withJSONObject: dict), forKey: settingsKey)

        let loaded = Store.loadSettings(from: defaults)
        XCTAssertFalse(loaded.showSeconds, "坏字段回退默认")
        XCTAssertEqual(loaded.weight, .bold, "其余字段必须保留")
        XCTAssertEqual(loaded.menuBarMaxZones, 6)
        XCTAssertTrue(loaded.didAskLaunchAtLogin, "不能因为别的字段坏掉就重弹首启询问")
        XCTAssertFalse(loaded.showOffsetBesideName, "坏字段回退默认关（默认外观逐像素不变）")
    }

    func testUnknownEnumValueOnlyResetsThatField() throws {
        var settings = AppSettings()
        settings.weight = .bold

        var dict = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(settings)) as? [String: Any])
        dict["displayMode"] = "hologram"   // 未来版本写的新枚举值
        defaults.set(try JSONSerialization.data(withJSONObject: dict), forKey: settingsKey)

        let loaded = Store.loadSettings(from: defaults)
        XCTAssertEqual(loaded.displayMode, .name)
        XCTAssertEqual(loaded.weight, .bold)
    }

    func testMissingKeysFallBackPerFieldNotWholesale() throws {
        var settings = AppSettings()
        settings.weight = .semibold

        var dict = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(settings)) as? [String: Any])
        ["showSeconds", "separator", "cityLanguage"].forEach { dict.removeValue(forKey: $0) }
        defaults.set(try JSONSerialization.data(withJSONObject: dict), forKey: settingsKey)

        let loaded = Store.loadSettings(from: defaults)
        XCTAssertEqual(loaded.weight, .semibold)
        XCTAssertEqual(loaded.separator, .space)
        XCTAssertEqual(loaded.cityLanguage, .followInterface)
    }

    func testWhollyUnparseableSettingsAreBackedUp() {
        defaults.set(Data([0xde, 0xad]), forKey: settingsKey)

        XCTAssertEqual(Store.loadSettings(from: defaults), AppSettings())
        XCTAssertNotNil(defaults.data(forKey: settingsBackupKey))
    }

    /// 例会轮换的控件值嵌在 planner 里:一份真实编码出的设置,只把 rotation 的一个字段改坏,
    /// 读回时只有那个字段回默认——旁边的星期、planner 的时长、外层的字重都不受影响。
    func testOneBadRotationFieldOnlyResetsItself() throws {
        var settings = AppSettings()
        settings.weight = .bold
        settings.planner.durationMinutes = 90
        settings.planner.rotation.weekday = 6
        settings.planner.rotation.count = 12

        var dict = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(settings)) as? [String: Any])
        var planner = try XCTUnwrap(dict["planner"] as? [String: Any])
        var rotation = try XCTUnwrap(planner["rotation"] as? [String: Any])
        rotation["count"] = "twelve"   // 类型错
        planner["rotation"] = rotation
        dict["planner"] = planner
        defaults.set(try JSONSerialization.data(withJSONObject: dict), forKey: settingsKey)

        let loaded = Store.loadSettings(from: defaults)
        XCTAssertEqual(loaded.planner.rotation.count, 6, "坏字段回退默认")
        XCTAssertEqual(loaded.planner.rotation.weekday, 6, "同一对象里的其他字段必须保留")
        XCTAssertEqual(loaded.planner.durationMinutes, 90)
        XCTAssertEqual(loaded.weight, .bold)
        XCTAssertNil(defaults.data(forKey: settingsBackupKey), "逐字段回退不是损坏,不该留备份")
    }

    // MARK: - menuBarMaxZones 必须钳到 UI 允许的范围

    /// 负数尤其致命:MenuBarLabelView 会拿它做 `zones.prefix(n)`,负数直接 precondition 崩溃。
    func testMenuBarMaxZonesIsClampedToStepperRange() throws {
        for (injected, expected) in [(99, 6), (-3, 1), (0, 1), (4, 4), (6, 6)] {
            var dict = try XCTUnwrap(
                JSONSerialization.jsonObject(with: try JSONEncoder().encode(AppSettings())) as? [String: Any])
            dict["menuBarMaxZones"] = injected
            defaults.set(try JSONSerialization.data(withJSONObject: dict), forKey: settingsKey)

            XCTAssertEqual(Store.loadSettings(from: defaults).menuBarMaxZones, expected,
                           "注入 \(injected) 应钳到 \(expected)")
        }
    }
}

extension PersistenceTests {
    /// 每次非空保存都镜像一份「最后已知良好」。旧写法只在清空那一刻抓上一份,
    /// 覆盖不了「键被整个抹掉」——那种情形下根本没有"清空那一刻"。
    func testEveryNonEmptySaveMirrorsASnapshot() throws {
        let zones = [TimeZoneEntry(timezoneID: "Asia/Hong_Kong", cityName: "Hong Kong"),
                     TimeZoneEntry(timezoneID: "Europe/Madrid", cityName: "Madrid")]
        Store.saveZones(zones, to: defaults)
        let snapshot = try XCTUnwrap(defaults.data(forKey: snapshotKey), "非空保存必须留快照")
        XCTAssertEqual(try JSONDecoder().decode([TimeZoneEntry].self, from: snapshot).map(\.cityName),
                       ["Hong Kong", "Madrid"])

        Store.saveZones([], to: defaults)
        XCTAssertEqual(defaults.data(forKey: snapshotKey), snapshot, "清空不得冲掉快照")
        Store.saveZones([], to: defaults)
        XCTAssertEqual(defaults.data(forKey: snapshotKey), snapshot, "重复清空同样不得冲掉")
    }

    /// **键整个不见**只可能是 App 之外的东西抹的——App 自己从不删这个键。
    /// 有快照就自动补回,并报 recovered 让面板提示。
    /// 恢复后写回偏好键，避免每次启动都重复补回。
    func testMissingKeyIsRestoredFromSnapshot() throws {
        let zones = [TimeZoneEntry(timezoneID: "Asia/Hong_Kong", cityName: "Hong Kong"),
                     TimeZoneEntry(timezoneID: "Europe/Madrid", cityName: "Madrid")]
        Store.saveZones(zones, to: defaults)
        defaults.removeObject(forKey: zonesKey)          // 模拟 defaults delete / 偏好域被清

        let loaded = Store.loadZones(from: defaults)
        XCTAssertEqual(loaded.zones.map(\.cityName), ["Hong Kong", "Madrid"])
        XCTAssertTrue(loaded.recovered, "自动补回必须报 recovered,否则用户不知道发生过什么")
        XCTAssertNotNil(defaults.data(forKey: zonesKey), "补回后要把键写回去,别每次启动都恢复一遍")
    }

    /// 反面:用户自己删光时区是合法操作,**不得**被"恢复"回来。
    /// 判据就是键还在(值为空数组),走不到补回那条路。
    func testUserEmptyingTheListIsNotUndone() throws {
        Store.saveZones([TimeZoneEntry(timezoneID: "Europe/Madrid", cityName: "Madrid")], to: defaults)
        Store.saveZones([], to: defaults)

        let loaded = Store.loadZones(from: defaults)
        XCTAssertTrue(loaded.zones.isEmpty, "用户主动清空必须保持为空")
        XCTAssertFalse(loaded.recovered)
    }

    /// 老用户升上来时还没有快照:读到一份完好的非空表就地补一份,
    /// 否则防线要等到下次编辑时区才武装。
    func testLoadingBackfillsAMissingSnapshot() throws {
        let zones = [TimeZoneEntry(timezoneID: "Europe/Madrid", cityName: "Madrid")]
        Store.saveZones(zones, to: defaults)
        defaults.removeObject(forKey: snapshotKey)          // 模拟旧版本存下的数据

        let loaded = Store.loadZones(from: defaults)
        XCTAssertEqual(loaded.zones.map(\.cityName), ["Madrid"])
        XCTAssertFalse(loaded.recovered, "只是补快照,不是恢复,不该打扰用户")
        XCTAssertNotNil(defaults.data(forKey: snapshotKey), "读到完好数据就该补上快照")
    }

    /// 首次启动:无键也无快照,老老实实给空列表,不报恢复。
    func testFirstLaunchStaysEmpty() throws {
        let loaded = Store.loadZones(from: defaults)
        XCTAssertTrue(loaded.zones.isEmpty)
        XCTAssertFalse(loaded.recovered)
    }
}
