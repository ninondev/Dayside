// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import CoreFoundation
import Observation
import SwiftUI

extension EnvironmentValues {
    @Entry var featureHub: FeatureHub? = nil
}

/// The hub coordinates native surfaces; each feature owns and releases its own handles.
/// 每页以工厂登记，已打开的模块自行管理资源。
@MainActor @Observable
final class FeatureHub {
    static let shared: FeatureHub = {
        let hub: FeatureHub
        #if DEBUG
        if UITestFixture.isActive {
            hub = UITestFixture.makeHub(defaults: ApplicationSession.defaults)
        } else {
            hub = FeatureHub(defaults: ApplicationSession.defaults, integrateSystemSurfaces: !ApplicationSession.isIsolated)
        }
        #else
        hub = FeatureHub(defaults: ApplicationSession.defaults, integrateSystemSurfaces: !ApplicationSession.isIsolated)
        #endif
        return hub
    }()
    @ObservationIgnored private(set) var modules: [DaysideFeature: any FeatureModule] = [:]
    @ObservationIgnored private var factories: [DaysideFeature: @MainActor () -> any FeatureModule] = [:]
    var registeredFeatures: Set<DaysideFeature> { Set(factories.keys).union(modules.keys) }
    private static let selectionKey = "dayside.tools.selection.v1"
    var selection: FeatureSelection = .agenda {
        didSet {
            if selection != oldValue { defaults.set(selection.rawValue, forKey: Self.selectionKey) }
        }
    }
    /// 面板进入排会页时通知现有页面，只清掉未存盘的人物选择。
    private(set) var panelPlannerRequest: UInt64 = 0

    func showPlannerFromPanel() {
        panelPlannerRequest &+= 1
        selection = .planner
    }
    var conversionText = ""
    /// 换算页的来源地点（地点 UUID 字符串）：面板行右键「从这里换算…」带过来，页面读一次。
    var conversionSourceID: String?
    /// 换算页里用户对某个写法的选择（「IST → 以色列」）：工具窗开着期间是之后同一写法的默认，关窗就忘（不落盘、不进设置；
    /// 没选过时用户已保存的地点仍排最前）。键是写法的小写原文（ist、cst），值是选项按意思的标识（zone:Asia/Jerusalem）。
    var zoneChoiceMemory: [String: String] = [:]
    private(set) var automationError: String?
    var uiLocale: Locale { model?.uiLocale ?? InterfaceLanguage.systemLocale() }
    @ObservationIgnored private var savedPeopleSnapshot: [PersonProfile]?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let integrateSystemSurfaces: Bool
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private let systemTimeZone: @MainActor () -> TimeZone
    @ObservationIgnored private let systemDate: @MainActor () -> Date
    @ObservationIgnored private var systemTimeZoneID: String
    @ObservationIgnored private var agendaMinute: Int?
    @ObservationIgnored private let makeAgendaMenuBarReader: @MainActor () -> AgendaMenuBarReader
    private var agendaMenuBarReader: AgendaMenuBarReader?
    /// 工具窗是否开着，用于管理页面资源与时钟活动。
    private(set) var isVisible = false

    var activeResourceCount: Int {
        modules.values.reduce(0) { $0 + $1.activeResourceCount } + (agendaMenuBarReader?.activeResourceCount ?? 0)
    }

    init(defaults: UserDefaults = Store.appDefaults, integrateSystemSurfaces: Bool = false,
         dstWatch: DSTWatchStore? = nil,
         agendaMenuBarReader: AgendaMenuBarReader? = nil,
         now: @escaping @MainActor () -> Date = Date.init,
         timeZone: @escaping @MainActor () -> TimeZone = { .current }) {
        self.defaults = defaults
        self.integrateSystemSurfaces = integrateSystemSurfaces
        systemDate = now
        systemTimeZone = timeZone
        systemTimeZoneID = timeZone().identifier
        self.agendaMenuBarReader = agendaMenuBarReader
        makeAgendaMenuBarReader = { AgendaMenuBarReader(defaults: defaults, now: now, timeZone: timeZone) }
        selection = defaults.string(forKey: Self.selectionKey).flatMap(FeatureSelection.init(rawValue:)) ?? .agenda
        FeatureModules.install(into: self, defaults: defaults)
        if let dstWatch { register(DSTWatchModule(store: dstWatch)) }
    }

    /// 是否接系统面（隔离预览与测试宿主不接）；各模块按它决定是否启用系统集成。
    var integratesSystemSurfaces: Bool { integrateSystemSurfaces }
    var sharedDefaults: UserDefaults { defaults }
    var attachedModel: AppModel? { model }

    func register(_ feature: DaysideFeature, factory: @escaping @MainActor () -> any FeatureModule) {
        factories[feature] = factory
    }

    /// 注入已创建的模块，供测试与显式内容提供者使用。
    func register(_ module: any FeatureModule) {
        if module.feature == .agenda { agendaMenuBarReader?.stop() }
        modules[module.feature] = module
        factories.removeValue(forKey: module.feature)
        if let model { attach(module, to: model) }
    }

    func module<T>(_ feature: DaysideFeature, as type: T.Type = T.self) -> T? { modules[feature] as? T }

    func openModule(_ feature: DaysideFeature) -> (any FeatureModule)? {
        if let module = modules[feature] { return module }
        guard let factory = factories.removeValue(forKey: feature) else { return nil }
        if feature == .agenda { agendaMenuBarReader?.stop() }
        let module = factory()
        precondition(module.feature == feature)
        modules[feature] = module
        if let model { attach(module, to: model) }
        return module
    }

    func openModule<T>(_ feature: DaysideFeature, as type: T.Type) -> T {
        guard let module = openModule(feature) as? T else { preconditionFailure("Missing page module") }
        return module
    }

    private func attach(_ module: any FeatureModule, to model: AppModel) {
        module.attach(hub: self, model: model)
        module.activate()
        module.placesDidChange(model: model)
    }

    func isAvailable(_ feature: FeatureSelection) -> Bool {
        guard let key = DaysideFeature(rawValue: feature.rawValue) else { return false }
        return factories[key] != nil || modules[key] != nil
    }

    /// 下一场会议（日历模块给；没有就 nil）。
    func nextMeeting(now: Date) -> UpcomingMeeting? {
        if let module = modules[.agenda] as? NextMeetingProviding { return module.nextMeeting(now: now) }
        return agendaMenuBarReader?.nextMeeting(now: now)
    }
    func menuBarMeeting(now: Date) -> UpcomingMeeting? {
        if let module = modules[.agenda] as? NextMeetingProviding { return module.menuBarMeeting(now: now) }
        return agendaMenuBarReader?.menuBarMeeting(now: now)
    }

    func synchronizeAgendaMenuBarPreferences() {
        guard model != nil else { return }
        if modules[.agenda] != nil {
            agendaMenuBarReader?.stop()
        } else {
            if agendaMenuBarReader == nil, AgendaStore.shouldActivateAtLaunch(defaults: defaults) {
                agendaMenuBarReader = makeAgendaMenuBarReader()
            }
            agendaMenuBarReader?.synchronizePreferences()
        }
    }
    /// 已保存人物的所在地（人物模块给）。
    var savedPeople: [PersonProfile] {
        if let store = loadedPeople { return store.people }
        if let savedPeopleSnapshot { return savedPeopleSnapshot }
        let people = PeopleStore.savedProfiles(defaults: defaults)
        savedPeopleSnapshot = people
        return people
    }
    var peoplePlaces: [PersonPlace] {
        savedPeople.map { PersonPlace(name: $0.name, timeZoneID: $0.timeZoneID, countryCode: $0.countryCode) }
    }
    /// 面板的规划区不创建页面存储。
    var panelSections: [(DaysideFeature, any PanelSectionProviding)] { [(.planner, PlannerPanelSection())] }

    func attach(to model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        model.onDataChange = { [weak self] in self?.refreshSnapshot() }
        model.onSystemChange = { [weak self] in self?.systemDidChange() }
        for module in modules.values { attach(module, to: model) }
        synchronizeAgendaMenuBarPreferences()
        refreshSnapshot()
    }

    /// 地点、设置或名字变了：通知各模块与夏令时哨兵（小组件快照 夜随小组件一起拆掉）。
    func refreshSnapshot() {
        guard let model else { return }
        synchronizeAgendaMenuBarPreferences()
        for module in modules.values { module.placesDidChange(model: model) }
    }

    private func systemDidChange() {
        let now = systemDate()
        agendaMenuBarReader?.refresh()
        for module in modules.values { module.clockDidChange(now: now) }
        let identifier = systemTimeZone().identifier
        if identifier != systemTimeZoneID {
            systemTimeZoneID = identifier
            if let model {
                for module in modules.values {
                    module.systemTimeZoneDidChange(to: identifier, model: model)
                }
            }
        }
        refreshSnapshot()
    }

    func clockDidTick(_ date: Date) {
        let minute = Int(date.timeIntervalSince1970 / 60)
        guard minute != agendaMinute else { return }
        agendaMinute = minute
        agendaMenuBarReader?.clockDidChange(now: date)
        for module in modules.values { module.clockDidChange(now: date) }
    }

    @discardableResult
    func handle(_ command: AutomationCommand, now: Date = .now) -> Bool {
        guard let model else { return false }
        struct Input: Encodable { let command: AutomationCommand; let now: Double; let zoneValid: Bool }
        struct Result: Decodable { let error: String? }
        let zoneID = command.arguments["timeZoneID"] ?? ""
        let validation: Result = RustCore.invoke("automation.validate", Input(command: command, now: now.timeIntervalSince1970,
                                                                               zoneValid: TimeZone(identifier: zoneID) != nil))
        guard validation.error == nil else { automationError = validation.error; return false }
        automationError = nil
        switch command.action {
        case "addPlace":
            if !model.zones.contains(where: { $0.timezoneID == zoneID }) {
                model.addZone(ZoneOption(identifier: zoneID, coordinate: nil))
                if let place = model.zones.last, let name = command.arguments["name"], !name.isEmpty { model.rename(id: place.id, to: name) }
            }
        case "primary":
            let index: Int?
            if let id = UUID(uuidString: command.arguments["id"] ?? "") {
                index = model.zones.firstIndex(where: { $0.id == id })
            } else {
                index = model.zones.firstIndex(where: { $0.timezoneID == zoneID })
            }
            guard let index else { automationError = "unknownPlace"; return false }
            model.moveZones(from: IndexSet(integer: index), to: 0)
        case "convert":
            conversionText = command.arguments["text"] ?? ""
            selection = .convert
        case "tools":
            if let value = command.arguments["feature"], let feature = FeatureSelection(rawValue: value) {
                selection = feature
                guard isAvailable(feature) else { automationError = "invalidCommand"; return false }
            }
        default:
            // 自动化可以显式创建计时器模块。
            if command.action == "timer" || command.action == "pomodoro" { _ = openModule(.timers) }
            for module in modules.values {
                if let handled = module.handle(command, hub: self, model: model) { return handled }
            }
            return false
        }
        return true
    }

    /// 模块处理命令时报错用（与自己的错误同一出口）。
    func reportAutomationError(_ code: String?) { automationError = code }

    func handle(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "dayside", let action = components.host,
              components.user == nil, components.password == nil, components.port == nil,
              components.path.isEmpty || components.path == "/" else { return }
        var arguments: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard arguments[item.name] == nil else { automationError = "invalidCommand"; return }
            arguments[item.name] = item.value ?? ""
        }
        _ = handle(.init(action: action, arguments: arguments))
    }

    func clearAutomationError() { automationError = nil }

    /// 只看不改的命令：打开某一页、换算一句话。隔离预览与测试宿主只接这两种（见 `DaysideApp` 的 `onOpenURL`）。
    nonisolated static func isNavigationOnly(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false), components.scheme == "dayside" else { return false }
        return components.host == "tools" || components.host == "convert"
    }

    func allows(_ feature: FeatureSelection) -> Bool { isAvailable(feature) }

    func setVisible(_ visible: Bool) {
        isVisible = visible
        if !visible { zoneChoiceMemory = [:] }
        model?.setWorkspaceVisible(visible)
        if visible, let feature = DaysideFeature(rawValue: selection.rawValue) { _ = openModule(feature) }
        for (feature, module) in modules {
            module.setVisible(visible, selected: selection.rawValue == feature.rawValue)
        }
    }

}
