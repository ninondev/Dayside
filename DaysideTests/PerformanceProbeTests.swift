// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import Dayside

@MainActor
struct PerformanceProbeTests {
    @Test func hostGuardRejectsEveryScenarioOutsideTestHost() {
        for name in ["idle", "panel", "earth", "cold:people", "understand"] {
            #expect(PerformanceProbe.Configuration(environment: ["MEANTIME_PERF_SCENARIO": name], testHost: false) == nil)
        }
    }
    @Test func malformedScenarioCannotActivateFixture() {
        for name in ["", "cold:", "cold:unknown", "cold-earth", "whatever"] {
            #expect(PerformanceProbe.Configuration(environment: ["MEANTIME_PERF_SCENARIO": name], testHost: true) == nil)
        }
    }
    @Test func everyToolsPageHasIndependentColdScenario() {
        for page in FeatureSelection.allCases {
            let value = PerformanceProbe.Configuration(environment: ["MEANTIME_PERF_SCENARIO": "cold:\(page.rawValue)"], testHost: true)
            #expect(value?.page == page)
        }
    }
    @Test func fixturePersistsPlacesAndPeopleBeforeAnyPageOpens() throws {
        let name = "com.dayside.performance-test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { ApplicationSession.discardOneOffSuite(named: name) }
        PerformanceProbe.seed(defaults)
        let zones = Store.loadZones(from: defaults)
        #expect(zones.zones.count == 5)
        #expect(Set(zones.zones.map(\.timezoneID)).count == 5)
        #expect(zones.zones.allSatisfy { $0.coordinate != nil })
        let people = PeopleStore(defaults: defaults).people
        #expect(people.map(\.name) == ["Ana", "Mei", "Nia"])
        #expect(people.allSatisfy { person in zones.zones.contains { $0.timezoneID == person.timeZoneID } })
        let hash = PerformanceProbe.fixtureHash(defaults)
        #expect(hash.count == 64)
        PerformanceProbe.seed(defaults)
        #expect(PeopleStore(defaults: defaults).people == people)
        #expect(PerformanceProbe.fixtureHash(defaults) == hash)
        var altered = people[0]
        altered.name = "Different"
        _ = PeopleStore(defaults: defaults).save(altered)
        #expect(PerformanceProbe.fixtureHash(defaults) != hash)
    }
}
