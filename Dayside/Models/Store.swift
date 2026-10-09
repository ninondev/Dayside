// SPDX-License-Identifier: GPL-3.0-only
// UserDefaults is an Apple host service; Rust owns serialization, repair and migration decisions.
import Foundation

enum Store {
    private static let keys: CoreJSON = RustCore.invoke("store.keys", CoreJSON.object([:]))
    private static let zonesKey: String = keys["zones"].decode()
    private static let settingsKey: String = keys["settings"].decode()
    private static let snapshotKey: String = keys["snapshot"].decode()
    static let migrationMarkerKey: String = keys["marker"].decode()
    static let lastNonEmptySuffix: String = keys["lastNonEmptySuffix"].decode()
    private static let corruptBackupSuffix: String = keys["corruptBackupSuffix"].decode()
    private static let migratedKeys: [String] = keys["migrated"].decode()
    /// 沙盒容器自己的偏好域。没有扩展共享数据，不用 App Group：`group.` 前缀的群组在 macOS 15+ 要 provisioning
    /// profile 授权，ad-hoc 签名下写入只留在进程缓存里，换个进程就读不到。
    static var appDefaults: UserDefaults { .standard }
    static var legacySources: [UserDefaults] {
        [UserDefaults(suiteName: "com.dayside.Dayside.legacy")].compactMap { $0 }
    }
    /// 旧版 Meantime 的 App Group。签名不再声明任何 App Group，启动不再搬它；保留给显式传入来源的整域搬迁。
    static let previousAppGroupIdentifier = "group.com.meantime.Meantime"
    /// 改名后的一次性整域搬迁：目标域空白时把上一个 App Group 里 App 自己的键（地点、设置、人物、旅行、计时器、
    /// 夏令时提醒、扩展快照……）原样复制过来并写迁移标记；哪些键算「App 自己的」由 Rust 决定，来源不清空。返回搬了几个键。
    @discardableResult
    static func migrateFromPreviousGroupIfNeeded(into target: UserDefaults,
                                                 from source: UserDefaults? = UserDefaults(suiteName: previousAppGroupIdentifier),
                                                 sourceName: String = previousAppGroupIdentifier) -> Int {
        guard let source else { return 0 }
        struct Input: Encodable { let target: CoreJSON; let keys: [String] }
        struct Result: Decodable { let copy: [String] }
        let facts: CoreJSON = .object(["marker": CoreJSON(target.string(forKey: migrationMarkerKey)),
            zonesKey: CoreJSON(target.data(forKey: zonesKey)), settingsKey: CoreJSON(target.data(forKey: settingsKey))])
        let available = source.dictionaryRepresentation()
        let result: Result? = RustCore.invoke("store.migrate_domain", Input(target: facts, keys: available.keys.sorted()))
        guard let result, !result.copy.isEmpty else { return 0 }
        for key in result.copy { if let value = available[key] { target.set(value, forKey: key) } }
        target.set(sourceName, forKey: migrationMarkerKey)
        return result.copy.count
    }
    private static func apply(_ writes: [String: Data], to defaults: UserDefaults) {
        for (key, data) in writes { defaults.set(data, forKey: key) }
    }
    @discardableResult
    static func migrateIfNeeded(into target: UserDefaults, from sources: [UserDefaults], sourceNames: [String]? = nil) -> String? {
        struct Input: Encodable { let target: CoreJSON; let sources: [[String: Data]]; let names: [String]? }
        struct Result: Decodable { let name: String; let writes: [String: Data] }
        let facts: CoreJSON = .object(["marker": CoreJSON(target.string(forKey: migrationMarkerKey)),
            zonesKey: CoreJSON(target.data(forKey: zonesKey)),settingsKey: CoreJSON(target.data(forKey: settingsKey))])
        let records = sources.map { source in Dictionary(uniqueKeysWithValues: migratedKeys.compactMap { key in
            source.data(forKey: key).map { (key, $0) }
        }) }
        let result: Result? = RustCore.invoke("store.migrate", Input(target: facts, sources: records, names: sourceNames))
        guard let result else { return nil }
        apply(result.writes, to: target); target.set(result.name, forKey: migrationMarkerKey)
        return result.name
    }
    static func loadZones(from defaults: UserDefaults = .standard) -> (zones: [TimeZoneEntry], recovered: Bool) {
        struct Input: Encodable { let primary: Data?; let snapshot: Data? }
        struct Result: Decodable { let zones: [TimeZoneEntry]; let recovered: Bool; let writes: [String: Data] }
        let primary = defaults.data(forKey: zonesKey)
        let result: Result = RustCore.invoke("store.load_zones", Input(primary: primary, snapshot: defaults.data(forKey: snapshotKey)))
        // Rust 只能查字段形状；一个标识符是不是这台 Mac 认得的时区，只有 Foundation 知道。认不得的条目
        // 显示出来就是 GMT 时间冒充那座城市，所以与字段不可用的条目采用同一套恢复处理：
        // 整条丢弃、原始字节备份到旁键、置恢复标记（Swift 侧 fuzz 查出）。
        var writes = result.writes
        var recovered = result.recovered
        let usable = result.zones.filter { TimeZone(identifier: $0.timezoneID) != nil }
        if usable.count != result.zones.count {
            recovered = true
            if let original = primary ?? writes[zonesKey] { writes[zonesKey + corruptBackupSuffix] = original }
        }
        apply(writes, to: defaults)
        return (usable, recovered)
    }
    static func saveZones(_ zones: [TimeZoneEntry], to defaults: UserDefaults = .standard) {
        let writes: [String: Data] = RustCore.invoke("store.save_zones", zones)
        apply(writes, to: defaults)
    }
    static func loadSettings(from defaults: UserDefaults = .standard) -> AppSettings {
        struct Result: Decodable { let settings: AppSettings; let writes: [String: Data] }
        let result: Result = RustCore.invoke("store.load_settings", defaults.data(forKey: settingsKey))
        apply(result.writes, to: defaults)
        return result.settings
    }
    static func saveSettings(_ settings: AppSettings, to defaults: UserDefaults = .standard) {
        let writes: [String: Data] = RustCore.invoke("store.save_settings", settings)
        apply(writes, to: defaults)
    }
}
