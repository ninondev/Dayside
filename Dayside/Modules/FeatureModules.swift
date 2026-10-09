// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// 登记页面工厂，打开页面时才创建模块与存储。
@MainActor
enum FeatureModules {
    static func install(into hub: FeatureHub, defaults: UserDefaults) {
        installBuiltins(into: hub, defaults: defaults)
        #if DEBUG
        if UITestFixture.isActive {
            FeatureFixture.install(into: hub, defaults: defaults)
            return
        }
        #endif
        hub.register(.agenda) { AgendaModule(store: AgendaStore(defaults: defaults)) }
        hub.register(.people) { PeopleModule(store: PeopleStore(defaults: defaults)) }
        hub.register(.timers) { TimersModule(store: TimerStore(defaults: defaults, runtimeEnabled: false)) }
        hub.register(.travel) { TravelModule(store: TravelStore(defaults: defaults)) }
    }

    static func install(into hub: FeatureHub, agenda: AgendaStore, people: PeopleStore, timers: TimerStore, travel: TravelStore) {
        installBuiltins(into: hub, defaults: hub.sharedDefaults)
        hub.register(AgendaModule(store: agenda))
        hub.register(PeopleModule(store: people))
        hub.register(TimersModule(store: timers))
        hub.register(TravelModule(store: travel))
    }

    private static func installBuiltins(into hub: FeatureHub, defaults: UserDefaults) {
        hub.register(.convert) { ConverterModule() }
        hub.register(.planner) { PlannerModule() }
        hub.register(.dstWatch) { DSTWatchModule(store: DSTWatchStore(defaults: defaults)) }
        hub.register(.astronomy) { AstronomyModule(store: AstronomyStore()) }
        hub.register(.markets) { MarketsModule(store: MarketStore()) }
        hub.register(.sharing) { SharingModule(store: SharingStore(defaults: defaults)) }
    }
}

extension FeatureHub {
    var agenda: AgendaStore { openModule(.agenda, as: AgendaModule.self).store }
    var people: PeopleStore { openModule(.people, as: PeopleModule.self).store }
    var timers: TimerStore { openModule(.timers, as: TimersModule.self).store }
    var travel: TravelStore { openModule(.travel, as: TravelModule.self).store }
    var dstWatch: DSTWatchStore { openModule(.dstWatch, as: DSTWatchModule.self).store }
    var astronomy: AstronomyStore { openModule(.astronomy, as: AstronomyModule.self).store }
    var markets: MarketStore { openModule(.markets, as: MarketsModule.self).store }
    var sharing: SharingStore { openModule(.sharing, as: SharingModule.self).store }
    /// 页面引用人物时只取已经打开的存储。
    var loadedPeople: PeopleStore? { module(.people, as: PeopleModule.self)?.store }

    @discardableResult
    func startTimer(_ spec: TimerSpec) -> Bool {
        selection = .timers
        timers.start(spec)
        reportAutomationError(timers.error)
        return timers.error == nil
    }
}

// MARK: - 模块

@MainActor
final class AgendaModule: FeatureModule, NextMeetingProviding {
    let store: AgendaStore
    let feature: DaysideFeature = .agenda
    init(store: AgendaStore) { self.store = store }
    var activeResourceCount: Int { store.activeResourceCount }

    func attach(hub: FeatureHub, model: AppModel) {
        store.preferencesDidChange = { [weak hub] in hub?.synchronizeAgendaMenuBarPreferences() }
    }
    func activate() {
        if !store.isActive { store.activate() }
    }
    func clockDidChange(now: Date) { store.clockDidChange(now: now) }
    func nextMeeting(now: Date) -> UpcomingMeeting? { store.nextMeeting(now: now).map(Self.upcoming) }
    func menuBarMeeting(now: Date) -> UpcomingMeeting? { store.menuBarMeeting(now: now).map(Self.upcoming) }
    private static func upcoming(_ meeting: AgendaMeeting) -> UpcomingMeeting {
        UpcomingMeeting(title: meeting.event.title, start: meeting.event.startDate,
                        isOngoing: meeting.isOngoing, minutesUntilStart: meeting.minutesUntilStart)
    }
    func page(hub: FeatureHub) -> AnyView { AnyView(AgendaLensView(store: store)) }
}

@MainActor
final class PeopleModule: FeatureModule, PeoplePlacesProviding {
    let store: PeopleStore
    let feature: DaysideFeature = .people
    init(store: PeopleStore) { self.store = store }
    var activeResourceCount: Int { store.activeResourceCount }
    var peoplePlaces: [PersonPlace] {
        store.people.map { PersonPlace(name: $0.name, timeZoneID: $0.timeZoneID, countryCode: $0.countryCode) }
    }
    func page(hub: FeatureHub) -> AnyView { AnyView(PeopleLensView(store: store)) }
}

@MainActor
final class TimersModule: FeatureModule {
    let store: TimerStore
    let feature: DaysideFeature = .timers
    init(store: TimerStore) { self.store = store }
    var activeResourceCount: Int { store.activeResourceCount }
    func activate() { store.setRuntimeEnabled(true) }
    func placesDidChange(model: AppModel) {
        store.configure(zones: model.zones, locale: model.uiLocale, hourStyle: model.settings.hourStyle)
    }
    func setVisible(_ visible: Bool, selected: Bool) { store.setVisible(visible && selected) }
    func handle(_ command: AutomationCommand, hub: FeatureHub, model: AppModel) -> Bool? {
        switch command.action {
        case "timer", "pomodoro":
            var spec = TimerSpec()
            if command.action == "pomodoro" { spec.mode = "pomodoro" }
            else { spec.duration = Double(Int(command.arguments["minutes"] ?? "") ?? 0) * 60 }
            return hub.startTimer(spec)
        default: return nil
        }
    }
    func page(hub: FeatureHub) -> AnyView { AnyView(TimerLensView(store: store)) }
}

@MainActor
final class TravelModule: FeatureModule {
    let store: TravelStore
    let feature: DaysideFeature = .travel
    init(store: TravelStore) { self.store = store }
    var activeResourceCount: Int { store.activeResourceCount }
    func systemTimeZoneDidChange(to identifier: String, model: AppModel) {
        guard let id = store.preferredMainClockID(systemTimeZoneID: identifier, places: model.zones),
              let index = model.zones.firstIndex(where: { $0.id == id }) else { return }
        model.moveZones(from: IndexSet(integer: index), to: 0)
    }
    func page(hub: FeatureHub) -> AnyView { AnyView(TravelLensView(store: store)) }
    var pageIsSelfScrolling: Bool { false }
}

@MainActor
final class PlannerModule: FeatureModule {
    let feature: DaysideFeature = .planner
    func page(hub: FeatureHub) -> AnyView { AnyView(PlannerPage()) }
}


@MainActor
final class ConverterModule: FeatureModule {
    let feature: DaysideFeature = .convert
    func page(hub: FeatureHub) -> AnyView {
        AnyView(TimeInputView(initialText: hub.conversionText, initialSourceID: hub.conversionSourceID)
            .id("\(hub.conversionText)|\(hub.conversionSourceID ?? "")"))
    }
}

@MainActor
final class DSTWatchModule: FeatureModule {
    let feature: DaysideFeature = .dstWatch
    let store: DSTWatchStore
    init(store: DSTWatchStore) { self.store = store }
    var activeResourceCount: Int { store.activeResourceCount }
    func placesDidChange(model: AppModel) {
        store.configure(zones: model.zones, locale: model.uiLocale,
                        displayNames: Dictionary(model.zones.map { ($0.timezoneID, $0.displayName(localizedCity: model.cityName(for: $0))) },
                                                 uniquingKeysWith: { first, _ in first }), hourStyle: model.settings.hourStyle)
    }
    func page(hub: FeatureHub) -> AnyView { AnyView(DSTWatchLensView(store: store)) }
}

@MainActor
final class AstronomyModule: FeatureModule {
    let feature: DaysideFeature = .astronomy
    let store: AstronomyStore
    init(store: AstronomyStore) { self.store = store }
    var activeResourceCount: Int { store.activeResourceCount }
    func page(hub: FeatureHub) -> AnyView { AnyView(AstronomyLensView(store: store)) }
}

@MainActor
final class MarketsModule: FeatureModule {
    let feature: DaysideFeature = .markets
    let store: MarketStore
    init(store: MarketStore) { self.store = store }
    func page(hub: FeatureHub) -> AnyView { AnyView(MarketLensView(store: store)) }
}

@MainActor
final class SharingModule: FeatureModule {
    let feature: DaysideFeature = .sharing
    let store: SharingStore
    init(store: SharingStore) { self.store = store }
    var activeResourceCount: Int { store.activeResourceCount }
    func page(hub: FeatureHub) -> AnyView { AnyView(SharingLensView(store: store)) }
}

/// 面板入口独立于工具页，不打开页面存储：面板里只有一行结论（`PanelMeetingLine`），点了开工具窗那一页。
@MainActor
final class PlannerPanelSection: PanelSectionProviding {
    func panelSection() -> AnyView { AnyView(PanelMeetingLine()) }
}
