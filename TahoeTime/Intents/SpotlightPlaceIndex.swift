// SPDX-License-Identifier: GPL-3.0-only
//
//  SpotlightPlaceIndex.swift
//  TahoeTime
//
//  让系统时区目录里的地点进 Spotlight（macOS 15 起的 IndexedEntity + CoreSpotlight）。
//  规则在 Rust `spotlight.plan`：每条实体的显示名、说明、关键词与「索引版本」串；Swift 只收事实
//  （tzdata 发行号、界面语言、ICU 城市名、已保存地点的名字——人物永远不进来）并执行 CoreSpotlight。
//  时机：菜单栏就绪后 5 秒、地点编辑后合并更新；后台执行，版本没变就什么都不做。
//  失败静默（只记 DiagnosticsLog），不需要任何权限，隔离会话（测试宿主、本地预览）不索引。
//

import AppIntents
import AppKit
import CoreSpotlight
import Foundation

/// 只在主程序里承认自己可被索引（小组件时代扩展进程也编这份实体、却不写 Spotlight；小组件已拆）。
extension TimeZonePlaceEntity: IndexedEntity {
    /// 单条实体的属性：目录名字（当前语言 + 英文）与标识符关键词，同一套 Rust 规则。
    var attributeSet: CSSearchableItemAttributeSet {
        let plan = SpotlightPlaceIndex.plan(.init(
            tzdata: TZDataCheck.installedVersion ?? "",
            locale: Locale.current.identifier,
            catalog: SpotlightPlaceIndex.catalogRows(identifiers: [id], locales: [Locale.current, Locale(identifier: "en")]),
            places: []))
        let entity = plan.entities.first ?? SpotlightPlaceIndex.Entity(id: id, displayName: TimeZonePlaceCatalog.rawCity(id), description: "", keywords: [id])
        return SpotlightPlaceIndex.attributeSet(for: entity)
    }
}

/// 从 Spotlight 结果（或快捷指令）打开一个地点：不在时钟列表里就先加入，再打开工具窗的换算页——
/// 空闲时它列出每个地点此刻的时间。面板本身没有可编程打开的接口。
struct OpenPlaceIntent: OpenIntent {
    static let title: LocalizedStringResource = "打开地点"
    static let description = IntentDescription("在 Dayside 中查看这个地点：不在时钟列表里就先加入，再打开时间工具。")
    static let supportedModes: IntentModes = .foreground
    static var parameterSummary: some ParameterSummary { Summary("打开 \(\.$target)") }

    @Parameter(title: "地点") var target: TimeZonePlaceEntity

    init() {}
    init(target: TimeZonePlaceEntity) { self.target = target }

    @MainActor
    func perform() async throws -> some IntentResult {
        let hub = FeatureHub.shared
        let model = AppModel.shared
        hub.attach(to: model)
        if !model.zones.contains(where: { $0.timezoneID == target.id }) {
            guard hub.handle(.init(action: "addPlace", arguments: ["timeZoneID": target.id, "name": ""])) else {
                throw DaysideIntentFailure.failed
            }
        }
        SpotlightPlaceIndex.openTools(feature: .convert)
        return .result()
    }
}

/// 快捷指令 / Spotlight 动作的两种失败（原在控制项的错误枚举里；控制项 夜随小组件拆掉）。
enum DaysideIntentFailure: Error, CustomLocalizedStringResourceConvertible {
    case failed
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .failed: "操作未完成，请打开 Dayside 后重试。"
        }
    }
}

/// 索引的执行面：真实实现走 CoreSpotlight，测试注入记录器。整个协议只在一个任务里用。
protocol SpotlightIndexBackend: Sendable {
    var isAvailable: Bool { get }
    /// 上次批量写入时存进索引的版本串；索引空白或读不到时为 nil。
    func lastVersion() async throws -> String?
    /// 清掉旧条目、写入全部条目并把版本串存进索引（同一批）。
    func replaceAll(_ items: [CSSearchableItem], version: String, hadPrevious: Bool) async throws
    /// 值类型执行口：假索引直接记录实体，不需要构造系统条目。
    func replaceEntities(_ entities: [SpotlightPlaceIndex.Entity], version: String, hadPrevious: Bool) async throws
}

extension SpotlightIndexBackend {
    func replaceEntities(_ entities: [SpotlightPlaceIndex.Entity], version: String, hadPrevious: Bool) async throws {
        try await replaceAll(entities.map(SpotlightPlaceIndex.item(for:)), version: version, hadPrevious: hadPrevious)
    }
}

nonisolated enum SpotlightPlaceIndex {
    static let indexName = "com.dayside.places"
    static let domain = "places"
    static let startupDelay: Duration = .seconds(5)
    static let editDelay: Duration = .milliseconds(250)

    struct Row: Encodable, Sendable { let id: String; let names: [String]; let zone: String }
    struct Place: Encodable, Equatable, Sendable { let timeZoneID: String; let name: String }
    struct Facts: Encodable, Sendable {
        let tzdata: String
        let locale: String
        let catalog: [Row]
        let places: [Place]
    }
    struct Entity: Decodable, Equatable, Sendable {
        let id: String
        let displayName: String
        let description: String
        let keywords: [String]
    }
    struct Plan: Decodable, Sendable {
        let version: String
        let entities: [Entity]
    }
    /// 主线程上收齐的事实：只有地点（时区 + 显示名）与界面语言。没有人物字段——按构造进不来。
    struct Seed: Equatable, Sendable {
        let locale: Locale
        let places: [Place]
    }
    enum Outcome: Equatable, Sendable {
        case unavailable
        case unchanged(String)
        case rebuilt(count: Int, version: String)
        case failed(String)
    }

    static func plan(_ facts: Facts) -> Plan { RustCore.invoke("spotlight.plan", facts) }

    /// 便宜的版本串：只看发行号、目录条数、界面语言与已保存地点，不取任何 ICU 名字。
    static func version(seed: Seed, identifiers: [String], tzdata: String?) -> String {
        struct Version: Decodable { let version: String }
        let facts = Facts(tzdata: tzdata ?? "", locale: seed.locale.identifier,
                          catalog: identifiers.map { Row(id: $0, names: [], zone: "") }, places: seed.places)
        let result: Version = RustCore.invoke("spotlight.version", facts)
        return result.version
    }

    /// 目录里每个标识符在各语言下的名字（第一个是界面语言）与通用时区名。一个语言一个格式化器。
    static func catalogRows(identifiers: [String], locales: [Locale]) -> [Row] {
        var seen = Set<String>()
        let distinct = locales.filter { seen.insert($0.identifier).inserted }
        let formatters = distinct.map { TimeZonePlaceCatalog.exemplarFormatter(locale: $0) }
        let primary = distinct.first ?? .current
        return identifiers.map { id in
            Row(id: id,
                names: formatters.map { TimeZonePlaceCatalog.cityName(id, formatter: $0) },
                zone: TimeZonePlaceCatalog.zoneName(id, locale: primary))
        }
    }

    static func attributeSet(for entity: Entity) -> CSSearchableItemAttributeSet {
        let set = CSSearchableItemAttributeSet(contentType: .item)
        set.displayName = entity.displayName
        set.title = entity.displayName
        set.contentDescription = entity.description.isEmpty ? nil : entity.description
        set.keywords = entity.keywords
        set.alternateNames = Array(entity.keywords.dropFirst())
        return set
    }

    static func item(for entity: Entity) -> CSSearchableItem {
        let set = attributeSet(for: entity)
        let item = CSSearchableItem(uniqueIdentifier: entity.id, domainIdentifier: domain, attributeSet: set)
        // CoreSpotlight 条目默认一个月过期；这份索引只在版本变化时重写，所以不能让它自己消失。
        item.expirationDate = .distantFuture
        item.associateAppEntity(TimeZonePlaceEntity(id: entity.id))
        return item
    }

    @MainActor static func seed(model: AppModel) -> Seed {
        Seed(locale: model.uiLocale, places: model.zones.map {
            Place(timeZoneID: $0.timezoneID, name: $0.displayName(localizedCity: model.cityName(for: $0)))
        })
    }

    /// 把主线程的种子补成完整事实：目录名字按界面语言、系统语言、英文三份收，Rust 去重。
    static func facts(seed: Seed, identifiers: [String] = TimeZonePlaceCatalog.identifiers, tzdata: String? = TZDataCheck.installedVersion) -> Facts {
        Facts(tzdata: tzdata ?? "",
              locale: seed.locale.identifier,
              catalog: catalogRows(identifiers: identifiers, locales: [seed.locale, Locale.current, Locale(identifier: "en")]),
              places: seed.places)
    }

    /// 版本没变就不碰索引（也不取名字）；变了才收齐名字、整批重写。任何错误都只记日志。
    @concurrent static func rebuildIfNeeded(seed: Seed, identifiers: [String] = TimeZonePlaceCatalog.identifiers,
                                tzdata: String? = TZDataCheck.installedVersion, backend: some SpotlightIndexBackend) async -> Outcome {
        guard backend.isAvailable else {
            DiagnosticsLog.note("spotlight", "indexing unavailable; skipped")
            return .unavailable
        }
        let expected = version(seed: seed, identifiers: identifiers, tzdata: tzdata)
        let previous: String?
        do {
            previous = try await backend.lastVersion()
        } catch {
            previous = nil
            DiagnosticsLog.note("spotlight", "no previous index state (\(error.localizedDescription)); rebuilding")
        }
        if previous == expected {
            DiagnosticsLog.note("spotlight", "index unchanged · version \(expected)")
            return .unchanged(expected)
        }
        let started = ContinuousClock.now
        let plan = plan(facts(seed: seed, identifiers: identifiers, tzdata: tzdata))
        do {
            try await backend.replaceEntities(plan.entities, version: plan.version, hadPrevious: previous != nil)
        } catch {
            DiagnosticsLog.note("spotlight", "index rebuild failed: \(error.localizedDescription)", level: .error)
            return .failed(error.localizedDescription)
        }
        let elapsed = ContinuousClock.now - started
        DiagnosticsLog.note("spotlight", "indexed \(plan.entities.count) places · version \(plan.version) · \(elapsed.formatted(.units(allowed: [.milliseconds], width: .narrow)))")
        return .rebuilt(count: plan.entities.count, version: plan.version)
    }

    // MARK: - 启动时机

    /// 菜单栏就绪后调用一次（标签可能因恢复脉冲重新出现，第二次起忽略）：5 秒后在后台核对并按需重建。
    @MainActor static func scheduleAfterMenuBarReady(model: AppModel) {
        guard !ApplicationSession.isIsolated else { return }
        model.startSpotlightIndexing()
    }

    /// 通过自己的 URL scheme 打开工具窗：`Window("tools")` 只在显式操作时打开，意图进程里没有 openWindow。
    /// 指明用本进程的 bundle 打开，免得 LaunchServices 把 URL 派给另一份同 bundle id 的副本。
    @MainActor static func openTools(feature: FeatureSelection) {
        guard !ApplicationSession.isIsolated else { return }
        var components = URLComponents()
        components.scheme = "dayside"
        components.host = "tools"
        components.queryItems = [.init(name: "feature", value: feature.rawValue)]
        guard let url = components.url else { return }
        NSWorkspace.shared.open([url], withApplicationAt: Bundle.main.bundleURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { DiagnosticsLog.note("spotlight", "open tools via URL failed: \(error.localizedDescription)", level: .error) }
        }
    }
}

/// 编辑只重置一个延后任务；已经开始的批次串行完成，下一批永远使用最新快照。
@MainActor
final class SpotlightIndexSession {
    private let backend: any SpotlightIndexBackend
    private let identifiers: [String]
    private let tzdata: String?
    private let editDelay: Duration
    private var lastSeed: SpotlightPlaceIndex.Seed?
    private var readySeed: SpotlightPlaceIndex.Seed?
    private var debounceTask: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?

    init(backend: some SpotlightIndexBackend, identifiers: [String] = TimeZonePlaceCatalog.identifiers,
         tzdata: String? = TZDataCheck.installedVersion, editDelay: Duration = SpotlightPlaceIndex.editDelay) {
        self.backend = backend
        self.identifiers = identifiers
        self.tzdata = tzdata
        self.editDelay = editDelay
    }

    func start(seed: SpotlightPlaceIndex.Seed, delay: Duration = SpotlightPlaceIndex.startupDelay) {
        guard lastSeed == nil else { return }
        enqueue(seed, delay: delay)
    }

    func savedPlacesChanged(seed: SpotlightPlaceIndex.Seed) {
        guard lastSeed != seed else { return }
        enqueue(seed, delay: editDelay)
    }

    private func enqueue(_ seed: SpotlightPlaceIndex.Seed, delay: Duration) {
        lastSeed = seed
        readySeed = nil
        debounceTask?.cancel()
        debounceTask = Task(priority: .utility) { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.readySeed = seed
            self.debounceTask = nil
            self.beginUpdate()
        }
    }

    private func beginUpdate() {
        guard updateTask == nil else { return }
        updateTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            while let seed = self.readySeed {
                self.readySeed = nil
                _ = await SpotlightPlaceIndex.rebuildIfNeeded(seed: seed, identifiers: self.identifiers,
                                                            tzdata: self.tzdata, backend: self.backend)
            }
            self.updateTask = nil
        }
    }

    /// 等待当前编辑批次，供假索引验证；没有定时轮询。
    func waitForUpdates() async {
        await waitForPendingEdit()
        await updateTask?.value
    }

    func waitForPendingEdit() async {
        await debounceTask?.value
    }
}

/// 真实的 CoreSpotlight：具名私有索引，版本串存在索引自己的 client state 里——索引被系统清掉时状态
/// 一起消失，下次启动自然重建；存进偏好域反而会在那种情况下永远不重建。
struct CoreSpotlightBackend: SpotlightIndexBackend {
    var isAvailable: Bool { CSSearchableIndex.isIndexingAvailable() }

    func replaceEntities(_ entities: [SpotlightPlaceIndex.Entity], version: String, hadPrevious: Bool) async throws {
        try await replaceAll(entities.map(SpotlightPlaceIndex.item(for:)), version: version, hadPrevious: hadPrevious)
    }

    func lastVersion() async throws -> String? {
        let data = try await CSSearchableIndex(name: SpotlightPlaceIndex.indexName).fetchLastClientState()
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    func replaceAll(_ items: [CSSearchableItem], version: String, hadPrevious: Bool) async throws {
        let index = CSSearchableIndex(name: SpotlightPlaceIndex.indexName)
        // 目录换代后可能少了标识符：有旧索引就先整体清掉，再写全量。
        if hadPrevious { try await index.deleteAllSearchableItems() }
        stage(items, in: index)
        try await index.endBatch(withClientState: Data(version.utf8))
    }

    /// 批内的写入不等它自己的回调（批模式下回调随批一起提交，等它会死锁），只等 endBatch 的结果。
    private func stage(_ items: [CSSearchableItem], in index: CSSearchableIndex) {
        index.beginBatch()
        index.indexSearchableItems(items, completionHandler: nil)
    }
}
