// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SwiftUI
import Testing
@testable import TahoeTime

@MainActor
struct ModuleRegistryTests {
    @Test func everyToolPageHasOneFactoryAtColdStart() {
        let (defaults, cleanup) = TestDefaults.make(prefix: "dayside.module-registry")
        defer { cleanup() }
        let hub = FeatureHub(defaults: defaults)
        let pages = Set(FeatureSelection.allCases.compactMap { DaysideFeature(rawValue: $0.rawValue) })
        #expect(hub.registeredFeatures == pages)
        #expect(hub.registeredFeatures.count == FeatureSelection.allCases.count)
        #expect(FeatureSelection.allCases.allSatisfy(hub.isAvailable))
        #expect(hub.modules.isEmpty)
        #expect(hub.activeResourceCount == 0)
    }

    @Test func attachingAndReadingPanelSummariesDoNotCreatePageStores() {
        let (defaults, cleanup) = TestDefaults.make(prefix: "dayside.module-peek")
        defer { cleanup() }
        let hub = FeatureHub(defaults: defaults)
        let model = AppModel(defaults: defaults, migrate: false, applySystemIntegration: false)
        hub.attach(to: model)
        hub.refreshSnapshot()
        hub.clockDidTick(.now)
        #expect(hub.nextMeeting(now: .now) == nil)
        #expect(hub.menuBarMeeting(now: .now) == nil)
        #expect(hub.peoplePlaces.isEmpty)
        #expect(hub.loadedPeople == nil)
        #expect(hub.panelSections.map(\.0) == [.planner])
        #expect(hub.modules.isEmpty)
        #expect(hub.activeResourceCount == 0)
    }

    @Test func selectingAClosedPageDoesNotCreateItsModule() {
        let (defaults, cleanup) = TestDefaults.make(prefix: "dayside.module-selection")
        defer { cleanup() }
        let hub = FeatureHub(defaults: defaults)
        let model = AppModel(defaults: defaults, migrate: false, applySystemIntegration: false)
        hub.attach(to: model)
        #expect(hub.handle(.init(action: "tools", arguments: ["feature": "people"])))
        #expect(hub.selection == .people)
        #expect(hub.modules.isEmpty)
        hub.setVisible(false)
        #expect(hub.modules.isEmpty)
        hub.setVisible(true)
        #expect(Set(hub.modules.keys) == [.people])
        hub.setVisible(false)
        #expect(hub.activeResourceCount == 0)
    }

    @Test func openingAPageCreatesOnlyThatModuleAndReusesIt() {
        let (defaults, cleanup) = TestDefaults.make(prefix: "dayside.module-open")
        defer { cleanup() }
        let hub = FeatureHub(defaults: defaults)
        let model = AppModel(defaults: defaults, migrate: false, applySystemIntegration: false)
        hub.attach(to: model)
        hub.selection = .people
        hub.setVisible(true)
        let first = hub.module(.people, as: PeopleModule.self)
        #expect(first != nil)
        #expect(Set(hub.modules.keys) == [.people])
        hub.setVisible(false)
        hub.setVisible(true)
        #expect(hub.module(.people, as: PeopleModule.self) === first)
        #expect(Set(hub.modules.keys) == [.people])
        hub.selection = .planner
        hub.setVisible(true)
        #expect(Set(hub.modules.keys) == [.people, .planner])
        #expect(hub.registeredFeatures.count == FeatureSelection.allCases.count)
        hub.setVisible(false)
        #expect(hub.activeResourceCount == 0)
    }

    @Test func enabledSavedPreferencesStayDormantUntilOnePageOpens() throws {
        let (defaults, cleanup) = TestDefaults.make(prefix: "dayside.module-persisted")
        defer { cleanup() }
        defaults.set(try JSONEncoder().encode(AgendaPreferences(isEnabled: true, showInMenuBar: true,
            selectedCalendarIDs: ["work"], days: 3)), forKey: AgendaStore.preferencesKey)
        defaults.set(try JSONEncoder().encode(DSTWatchState(version: 1, enabled: true,
            leadSeconds: 86_400, receipts: [])), forKey: DSTWatchStore.storageKey)
        let now = Date.now.timeIntervalSince1970
        let clock = TimerClockFacts.now()
        let session = TimerSession(id: "saved-timer", spec: TimerSpec(), status: "running", elapsed: 0,
            startedAt: now, continuousAt: clock.continuous, bootID: clock.bootID, creditedFocus: 0)
        defaults.set(try JSONEncoder().encode(TimerMachineState(version: 1, notifications: true,
            session: session, ledger: [])), forKey: TimerStore.storageKey)
        let agendaBefore = defaults.data(forKey: AgendaStore.preferencesKey)
        let timerBefore = defaults.data(forKey: TimerStore.storageKey)
        let dstBefore = defaults.data(forKey: DSTWatchStore.storageKey)
        let reader = AgendaMenuBarReader(defaults: defaults, authorization: { .fullAccess },
            read: { _, calendarIDs in
                #expect(calendarIDs == ["work"])
                return []
            }, observeSystemEvents: false)
        defer { reader.stop() }
        let hub = FeatureHub(defaults: defaults, agendaMenuBarReader: reader)
        let model = AppModel(defaults: defaults, migrate: false, applySystemIntegration: false)
        hub.attach(to: model)
        hub.clockDidTick(.now)
        model.settings.hourStyle = .force24
        hub.refreshSnapshot()
        model.onSystemChange?()
        #expect(hub.modules.isEmpty)
        #expect(reader.isActive)
        #expect(reader.activeResourceCount == 1)
        #expect(hub.activeResourceCount == 1)
        #expect(defaults.data(forKey: AgendaStore.preferencesKey) == agendaBefore)
        #expect(defaults.data(forKey: TimerStore.storageKey) == timerBefore)
        #expect(defaults.data(forKey: DSTWatchStore.storageKey) == dstBefore)
        hub.selection = .people
        hub.setVisible(true)
        #expect(Set(hub.modules.keys) == [.people])
        #expect(reader.isActive)
        #expect(reader.activeResourceCount == 1)
        #expect(hub.activeResourceCount == 1)
        hub.setVisible(false)
        #expect(reader.isActive)
        #expect(reader.activeResourceCount == 1)
        #expect(hub.activeResourceCount == 1)
        reader.stop()
        #expect(reader.activeResourceCount == 0)
        #expect(hub.activeResourceCount == 0)
        #expect(defaults.data(forKey: AgendaStore.preferencesKey) == agendaBefore)
        #expect(defaults.data(forKey: TimerStore.storageKey) == timerBefore)
        #expect(defaults.data(forKey: DSTWatchStore.storageKey) == dstBefore)
    }

    @Test func savedPeopleReachColdPlannerAndSummariesWithoutOpeningTheirPage() {
        let (defaults, cleanup) = TestDefaults.make(prefix: "dayside.module-people-snapshot")
        defer { cleanup() }
        let person = PersonProfile(name: "Saved person", timeZoneID: "Asia/Tokyo", countryCode: "JP")
        let seed = PeopleStore(defaults: defaults)
        #expect(seed.save(person).isEmpty)
        let stored = defaults.data(forKey: PeopleStore.storageKey)
        let hub = FeatureHub(defaults: defaults)
        let model = AppModel(defaults: defaults, migrate: false, applySystemIntegration: false)
        hub.attach(to: model)
        #expect(hub.savedPeople == [person])
        #expect(hub.peoplePlaces == [PersonPlace(name: person.name, timeZoneID: person.timeZoneID, countryCode: person.countryCode)])
        #expect(hub.loadedPeople == nil)
        #expect(hub.modules.isEmpty)
        #expect(hub.savedPeople.map { $0.plannerParticipant(places: model.zones).timeZoneID } == ["Asia/Tokyo"])
        hub.selection = .planner
        hub.setVisible(true)
        #expect(Set(hub.modules.keys) == [.planner])
        #expect(hub.savedPeople.map(\.id) == [person.id])
        #expect(hub.loadedPeople == nil)
        #expect(hub.activeResourceCount == 0)
        #expect(defaults.data(forKey: PeopleStore.storageKey) == stored)
        hub.setVisible(false)
    }

    @Test func factoryAndAttachmentRunOnceAcrossPageReopening() {
        let (defaults, cleanup) = TestDefaults.make(prefix: "dayside.module-lifecycle")
        defer { cleanup() }
        let hub = FeatureHub(defaults: defaults)
        let model = AppModel(defaults: defaults, migrate: false, applySystemIntegration: false)
        let module = RegistryProbeModule()
        var creations = 0
        hub.register(.people) { creations += 1; return module }
        hub.attach(to: model)
        #expect(creations == 0)
        hub.selection = .people
        hub.setVisible(true)
        hub.setVisible(false)
        hub.setVisible(true)
        hub.attach(to: model)
        #expect(creations == 1)
        #expect(module.attachments == 1)
        #expect(module.activations == 1)
        #expect(module.visibility == [true, false, true])
        hub.setVisible(false)
    }
}

@MainActor
private final class RegistryProbeModule: FeatureModule {
    let feature: DaysideFeature = .people
    var attachments = 0
    var activations = 0
    var visibility: [Bool] = []
    func attach(hub: FeatureHub, model: AppModel) { attachments += 1 }
    func activate() { activations += 1 }
    func setVisible(_ visible: Bool, selected: Bool) { visibility.append(visible && selected) }
    func page(hub: FeatureHub) -> AnyView { AnyView(EmptyView()) }
}
