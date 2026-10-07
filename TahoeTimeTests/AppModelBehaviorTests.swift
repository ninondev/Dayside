// SPDX-License-Identifier: GPL-3.0-only
//
//  AppModelBehaviorTests.swift
//  TahoeTimeTests
//
//  AppModel 行为护栏：覆盖状态转发与交互行为。
//  持久化落盘点、settings.didSet 的幂等与副作用、面板时钟起停、穿梭偏移复位、系统事件版本号、
//  面板打开时的显示名校正。全部走独立 UserDefaults suite,绝不碰用户真实偏好。
//

import XCTest
@testable import TahoeTime

@MainActor
final class AppModelBehaviorTests: XCTestCase {

    private var defaults: UserDefaults!
    private var teardownDefaults: (() -> Void)!
    private let zonesKey = "tahoetime.zones.v1"
    private let settingsKey = "tahoetime.settings.v1"

    // XCTest 的 setUp/tearDown 是 nonisolated;类是 @MainActor,准备与清理显式回到主执行器。
    override func setUp() async throws {
        try await super.setUp()
        try await MainActor.run { try prepare() }
    }

    override func tearDown() async throws {
        await MainActor.run { cleanup() }
        try await super.tearDown()
    }

    private func prepare() throws {
        let (value, cleanup) = TestDefaults.make(prefix: "com.tahoetime.TahoeTime.appmodel-tests")
        defaults = value
        teardownDefaults = cleanup
    }

    private func cleanup() {
        teardownDefaults()
        teardownDefaults = nil
        defaults = nil
    }

    private func tokyo() -> TimeZoneEntry {
        TimeZoneEntry(timezoneID: "Asia/Tokyo", cityName: "Tokyo",
                      coordinate: Coordinate(latitude: 35.68, longitude: 139.69))
    }

    private func madrid() -> TimeZoneEntry {
        TimeZoneEntry(timezoneID: "Europe/Madrid", cityName: "Madrid",
                      coordinate: Coordinate(latitude: 40.4, longitude: -3.68))
    }

    private func catalogOption(_ query: String) throws -> ZoneOption {
        try XCTUnwrap(ZoneCatalog.shared.search(query, locale: nil).first { $0.cityIndex != nil },
                      "目录里搜不到 \(query)")
    }

    // MARK: - 加载

    func testInitLoadsZonesAndSettingsFromInjectedDefaults() {
        Store.saveZones([tokyo(), madrid()], to: defaults)
        var s = AppSettings()
        s.showSeconds = true
        s.menuBarMaxZones = 3
        Store.saveSettings(s, to: defaults)

        let model = AppModel(defaults: defaults, migrate: false)
        XCTAssertEqual(model.zones.map(\.timezoneID), ["Asia/Tokyo", "Europe/Madrid"])
        XCTAssertTrue(model.settings.showSeconds)
        XCTAssertEqual(model.settings.menuBarMaxZones, 3)
        XCTAssertFalse(model.zonesRecoveryNotice)
    }

    /// init 里的赋值不触发 didSet:加载时绝不回写(否则空表也会被写成"用户删光了")。
    func testInitDoesNotWriteBack() {
        let model = AppModel(defaults: defaults, migrate: false)
        XCTAssertNil(defaults.data(forKey: settingsKey))
        XCTAssertNil(defaults.data(forKey: zonesKey))
        XCTAssertTrue(model.zones.isEmpty)
    }

    /// 键被外力抹掉、快照还在 → 自动补回并报 recovered。
    func testInitRecoversFromSnapshotWhenKeyMissing() {
        Store.saveZones([tokyo()], to: defaults)
        defaults.removeObject(forKey: zonesKey)

        let model = AppModel(defaults: defaults, migrate: false)
        XCTAssertEqual(model.zones.map(\.timezoneID), ["Asia/Tokyo"])
        XCTAssertTrue(model.zonesRecoveryNotice)
    }

    // MARK: - settings.didSet

    func testAssigningEqualSettingsDoesNotPersist() {
        let model = AppModel(defaults: defaults, migrate: false)
        let same = model.settings
        model.settings = same
        XCTAssertNil(defaults.data(forKey: settingsKey), "同值赋值不该落盘")
    }

    func testChangedSettingsPersistImmediately() {
        let model = AppModel(defaults: defaults, migrate: false)
        model.settings.menuBarMaxZones = 6
        XCTAssertEqual(Store.loadSettings(from: defaults).menuBarMaxZones, 6)
        model.settings.showSeconds = true
        XCTAssertTrue(Store.loadSettings(from: defaults).showSeconds)
    }

    // MARK: - 时区增删改的落盘点

    func testAddZonePersistsImmediately() throws {
        let model = AppModel(defaults: defaults, migrate: false)
        model.addZone(try catalogOption("Tokyo"))
        XCTAssertEqual(model.zones.count, 1)
        XCTAssertEqual(Store.loadZones(from: defaults).zones.map(\.timezoneID), ["Asia/Tokyo"])
    }

    func testRemoveMoveAndRenamePersist() {
        Store.saveZones([tokyo(), madrid()], to: defaults)
        let model = AppModel(defaults: defaults, migrate: false)

        model.moveZones(from: IndexSet(integer: 1), to: 0)
        XCTAssertEqual(Store.loadZones(from: defaults).zones.map(\.cityName), ["Madrid", "Tokyo"])

        let madridID = model.zones[0].id
        model.rename(id: madridID, to: "  Oficina  ")
        XCTAssertEqual(Store.loadZones(from: defaults).zones[0].customName, "Oficina", "重命名要去首尾空白")

        model.rename(id: madridID, to: "   ")
        XCTAssertNil(Store.loadZones(from: defaults).zones[0].customName, "空名 = 取消自定义名")

        model.removeZone(id: madridID)
        XCTAssertEqual(Store.loadZones(from: defaults).zones.map(\.cityName), ["Tokyo"])

        model.removeZones(at: IndexSet(integer: 0))
        XCTAssertTrue(Store.loadZones(from: defaults).zones.isEmpty)
    }

    /// 面板里删掉的地点几秒内可撤销：放回原位、落盘，撤销后提示清空；连按两次撤销不重复插入。
    func testRemovalCanBeUndoneIntoItsOriginalPosition() {
        Store.saveZones([tokyo(), madrid()], to: defaults)
        let model = AppModel(defaults: defaults, migrate: false)
        XCTAssertNil(model.pendingRemoval)

        let tokyoID = model.zones[0].id
        model.removeZone(id: tokyoID)
        XCTAssertEqual(model.zones.map(\.cityName), ["Madrid"])
        XCTAssertEqual(model.pendingRemoval?.names, ["Tokyo"])
        XCTAssertEqual(model.pendingRemoval?.items.first?.index, 0)

        model.restoreRemovedZones()
        XCTAssertEqual(model.zones.map(\.cityName), ["Tokyo", "Madrid"], "撤销后回到原来的位置")
        XCTAssertEqual(model.zones[0].id, tokyoID, "放回的是同一个条目（同 id、同设置）")
        XCTAssertEqual(Store.loadZones(from: defaults).zones.map(\.cityName), ["Tokyo", "Madrid"], "撤销也落盘")
        XCTAssertNil(model.pendingRemoval, "撤销后提示清空")

        model.restoreRemovedZones()
        XCTAssertEqual(model.zones.count, 2, "没有待撤销的删除时什么都不做")

        // 删掉最后一个再撤销：空列表也能放回。
        model.removeZones(at: IndexSet([0, 1]))
        XCTAssertTrue(model.zones.isEmpty)
        XCTAssertEqual(model.pendingRemoval?.names, ["Tokyo", "Madrid"])
        model.restoreRemovedZones()
        XCTAssertEqual(model.zones.map(\.cityName), ["Tokyo", "Madrid"])
    }

    /// 地点 emoji 与色点：只取第一个字素簇、落盘、进标识；坏色名当没有；清空即删。
    func testDecorateStoresOneEmojiAndAColorAndTheLabelShowsIt() {
        Store.saveZones([tokyo()], to: defaults)
        let model = AppModel(defaults: defaults, migrate: false)
        let id = model.zones[0].id
        model.decorate(id: id, emoji: " 🇯🇵🌸 ", color: "blue")
        XCTAssertEqual(model.zones[0].emoji, "🇯🇵", "只取第一个字素簇，国旗是一个")
        XCTAssertEqual(model.zones[0].color, "blue")
        XCTAssertEqual(model.zones[0].displayName(localizedCity: "东京"), "🇯🇵 东京")
        XCTAssertEqual(model.zones[0].label(mode: .offset, at: Date(timeIntervalSince1970: 1_789_041_600), localizedCity: "东京"), "🇯🇵 UTC+9")
        // 面板行的 emoji 是单画的一段，串里不再带（includeEmoji: false）；名称旁附偏移是调研 #9 的开关。
        let winter = Date(timeIntervalSince1970: 1_789_041_600)
        XCTAssertEqual(model.zones[0].label(mode: .name, at: winter, localizedCity: "东京", includeEmoji: false), "东京")
        XCTAssertEqual(model.zones[0].label(mode: .name, at: winter, localizedCity: "东京",
                                            withOffset: true, includeEmoji: false), "东京 UTC+9")
        XCTAssertEqual(model.zones[0].label(mode: .offset, at: winter, localizedCity: "东京",
                                            withOffset: true, includeEmoji: false), "UTC+9")
        XCTAssertEqual(Store.loadZones(from: defaults).zones[0].emoji, "🇯🇵", "落盘")
        model.decorate(id: id, emoji: nil, color: "neon")
        XCTAssertNil(model.zones[0].emoji)
        XCTAssertNil(model.zones[0].color, "不在名单里的颜色当没有")
        XCTAssertEqual(model.zones[0].displayName(localizedCity: "东京"), "东京")
    }

    /// 撤销提示不再定时消失：留到下一次编辑（添加 / 移动 / 重命名）才清。
    func testRemovalUndoStaysUntilTheNextEdit() async throws {
        Store.saveZones([tokyo(), madrid()], to: defaults)
        let model = AppModel(defaults: defaults, migrate: false)
        model.removeZone(id: model.zones[0].id)
        XCTAssertNotNil(model.pendingRemoval)
        try await Task.sleep(for: .seconds(4))
        XCTAssertNotNil(model.pendingRemoval, "4 秒后提示还在")
        model.rename(id: model.zones[0].id, to: "M")
        XCTAssertNil(model.pendingRemoval, "下一次编辑后提示清空")
        model.restoreRemovedZones()
        XCTAssertEqual(model.zones.count, 1, "提示清掉后按钮路径不再放回")
    }

    /// 接上窗口的 UndoManager 后：⌘Z（undo）放回、⇧⌘Z（redo）再删、连删两次能连续撤销两次；「撤销」按钮走同一个管理器。
    func testRemovalUndoAndRedoGoThroughTheUndoManager() {
        Store.saveZones([tokyo(), madrid()], to: defaults)
        let model = AppModel(defaults: defaults, migrate: false)
        let manager = UndoManager()
        model.panelUndoManager = manager
        let tokyoID = model.zones[0].id
        model.removeZone(id: tokyoID)
        XCTAssertTrue(manager.canUndo)
        XCTAssertEqual(manager.undoActionName, "删除地点")
        manager.undo()
        XCTAssertEqual(model.zones.map(\.cityName), ["Tokyo", "Madrid"], "⌘Z 放回原位")
        XCTAssertNil(model.pendingRemoval)
        XCTAssertTrue(manager.canRedo)
        manager.redo()
        XCTAssertEqual(model.zones.map(\.cityName), ["Madrid"], "⇧⌘Z 再删")
        XCTAssertEqual(model.pendingRemoval?.names, ["Tokyo"], "再删后提示又出现")
        // 连删两次：先撤销第二次再撤销第一次
        model.removeZone(id: model.zones[0].id)
        XCTAssertTrue(model.zones.isEmpty)
        manager.undo()
        XCTAssertEqual(model.zones.map(\.cityName), ["Madrid"])
        manager.undo()
        XCTAssertEqual(model.zones.map(\.cityName), ["Tokyo", "Madrid"])
        XCTAssertEqual(Store.loadZones(from: defaults).zones.map(\.cityName), ["Tokyo", "Madrid"], "撤销也落盘")
        // 「撤销」按钮走管理器，所以之后还能 redo
        model.removeZone(id: tokyoID)
        model.restoreRemovedZones()
        XCTAssertEqual(model.zones.map(\.cityName), ["Tokyo", "Madrid"])
        XCTAssertTrue(manager.canRedo)
    }

    // MARK: - Time Scroller 偏移

    func testJumpAndResetToNow() {
        Store.saveZones([tokyo()], to: defaults)
        let model = AppModel(defaults: defaults, migrate: false)

        model.jump(to: model.now.addingTimeInterval(3 * 3600))
        XCTAssertEqual(model.displayOffset, 3 * 3600, accuracy: 1)
        XCTAssertTrue(model.isScrubbing)

        model.resetToNow()
        XCTAssertEqual(model.displayOffset, 0)
        XCTAssertEqual(model.scrollOffset, 0)
        XCTAssertFalse(model.isScrubbing)
    }

    /// 删光时区时穿梭偏移必须清零:否则再添加一个时区会显示莫名其妙的非实时时间。
    func testRemovingLastZoneResetsScrub() {
        Store.saveZones([tokyo()], to: defaults)
        let model = AppModel(defaults: defaults, migrate: false)
        model.jump(to: model.now.addingTimeInterval(7200))
        XCTAssertTrue(model.isScrubbing)

        model.removeZone(id: model.zones[0].id)
        XCTAssertEqual(model.displayOffset, 0)
        XCTAssertEqual(model.scrollOffset, 0)
    }

    // MARK: - 面板时钟只在「面板可见且有时区」时跑

    func testClockAdvancesWhilePanelVisible() async throws {
        Store.saveZones([tokyo()], to: defaults)
        let model = AppModel(defaults: defaults, migrate: false)
        model.settings.showSeconds = true          // 每整秒醒
        model.setPanelVisible(true)
        let t0 = model.now
        try await Task.sleep(for: .milliseconds(1400))
        XCTAssertGreaterThan(model.now, t0, "面板打开且显示秒,1.4s 内 now 至少推进一次")
    }

    func testClockStaysIdleWhilePanelHidden() async throws {
        Store.saveZones([tokyo()], to: defaults)
        let model = AppModel(defaults: defaults, migrate: false)
        model.settings.showSeconds = true
        let t0 = model.now
        try await Task.sleep(for: .milliseconds(1400))
        XCTAssertEqual(model.now, t0, "面板没开,AppModel 不该周期性唤醒")
    }

    func testClockStopsWhenPanelHides() async throws {
        Store.saveZones([tokyo()], to: defaults)
        let model = AppModel(defaults: defaults, migrate: false)
        model.settings.showSeconds = true
        model.setPanelVisible(true)
        try await Task.sleep(for: .milliseconds(1400))
        model.setPanelVisible(false)
        let frozen = model.now
        try await Task.sleep(for: .milliseconds(1400))
        XCTAssertEqual(model.now, frozen, "面板关闭后时钟必须停")
    }

    func testClockStaysIdleWithoutZonesEvenIfPanelVisible() async throws {
        let model = AppModel(defaults: defaults, migrate: false)
        model.settings.showSeconds = true
        model.setPanelVisible(true)
        let t0 = model.now
        try await Task.sleep(for: .milliseconds(1400))
        XCTAssertEqual(model.now, t0, "空表不需要时钟")
    }

    // MARK: - 系统事件

    /// 系统语言 / 时区 / 时钟变更 → systemRevision +1（菜单栏城市名不再滞留）。
    func testSystemTimeZoneChangeBumpsRevision() async throws {
        let model = AppModel(defaults: defaults, migrate: false)
        let before = model.systemRevision
        NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)
        try await Task.sleep(for: .milliseconds(100))   // 观察者回调排在主队列
        XCTAssertEqual(model.systemRevision, before + 1)
    }

    // MARK: - 城市语言

    func testCityLanguageNoneHidesCityNames() {
        Store.saveZones([tokyo()], to: defaults)
        let model = AppModel(defaults: defaults, migrate: false)
        model.settings.cityLanguage = .none
        XCTAssertEqual(model.localizedCity(model.zones[0]), "", "城市语言=无 → 面板不显示城市名")
        XCTAssertEqual(model.cityName(for: model.zones[0]), "Tokyo", "重命名默认值仍要有名字")
    }

    /// 面板打开时把老条目缺失的多语言显示名补齐并落盘。
    func testPanelOpenRefreshesStaleLocalizedNamesAndPersists() throws {
        var entry = TimeZoneEntry(zone: try catalogOption("Munich"))
        XCTAssertFalse(entry.usesExemplarName)
        entry.localizedNames = nil
        Store.saveZones([entry], to: defaults)

        let model = AppModel(defaults: defaults, migrate: false)
        XCTAssertNil(model.zones[0].localizedNames)
        model.setPanelVisible(true)
        let refreshed = model.zones[0].localizedNames
        XCTAssertNotNil(refreshed)
        XCTAssertEqual(Store.loadZones(from: defaults).zones[0].localizedNames, refreshed, "补齐的名字要落盘")
    }

    /// 面板「复制全部各地时间」（调研 #11）：按面板当前顺序、当前显示的时刻拼一行；跨日的那一地带日期。
    func testCopyAllPlaceTimesFollowsThePanelOrderAndTheScrolledTime() {
        Store.saveZones([tokyo(), madrid()], to: defaults)
        let model = AppModel(defaults: defaults, migrate: false)
        // 2026-09-17 12:00 UTC：东京 21:00 当天、马德里 14:00 当天。
        let noonUTC = Date(timeIntervalSince1970: 1_789_041_600)
        model.jump(to: noonUTC)
        let text = model.panelTimesLine() ?? ""
        // 名字用面板行上看到的那个（默认界面语言是简体，所以是「东京」「马德里」）。
        let names = model.zones.map { model.localizedCity($0) }
        XCTAssertEqual(names.count, 2)
        for name in names { XCTAssertTrue(text.contains(name), "\(name) 不在复制的一行里：\(text)") }
        XCTAssertTrue(text.range(of: names[0])!.lowerBound < text.range(of: names[1])!.lowerBound,
                      "顺序跟面板一致（默认按添加顺序）：\(text)")
        // 跟着穿梭时刻：各地钟点与 Foundation 自算的一致（东京 21:00、马德里 14:00）。
        for (index, id) in ["Asia/Tokyo", "Europe/Madrid"].enumerated() {
            let expected = ClockText.time(noonUTC, in: TimeZone(identifier: id)!, hourStyle: model.settings.hourStyle)
            XCTAssertTrue(text.contains("\(names[index]) \(expected)"), "\(id) 的钟点：\(text)")
        }
        // 一个地点都没有时不复制空串。
        Store.saveZones([], to: defaults)
        let empty = AppModel(defaults: defaults, migrate: false)
        XCTAssertNil(empty.panelTimesLine())
    }
}
