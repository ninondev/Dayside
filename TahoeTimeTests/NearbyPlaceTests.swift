// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import TahoeTime

@MainActor
struct NearbyPlaceTests {
    private let reference = ISO8601DateFormatter().date(from: "2026-09-24T12:00:00Z")!
    private let home = TimeZone(identifier: "America/Los_Angeles")!

    @Test func converterOffersBerlinThenLocalAndResolvesTheSelectedReading() throws {
        let text = "Kickoff tomorrow 9am PST, Berlin sync at 18:00, report due Oct 20."
        let output = TimeUnderstanding.read(text, region: "US", language: "en")
        #expect(output.mentions.count == 3)
        let context = TimeUnderstanding.Context(reference: reference, now: reference, fallback: home, home: home,
                                                preferredZones: ["Asia/Tokyo", home.identifier], origin: .pasted)
        let initial = TimeUnderstanding.resolveAll(output, context: context)
        let berlin = try #require(initial.dropFirst().first)
        #expect(berlin.zoneOptions.map(\.id) == ["zone:Europe/Berlin", "local"])
        #expect(berlin.zoneOption.id == "zone:Europe/Berlin")
        #expect(berlin.start == ISO8601DateFormatter().date(from: "2026-09-25T16:00:00Z"))
        let local = TimeUnderstanding.resolveAll(output, context: context, choices: [1: .init(zone: "local")])
        #expect(local[1].zoneOption.id == "local")
        #expect(local[1].zoneOptions.map(\.id) == berlin.zoneOptions.map(\.id))
        #expect(local[1].start == ISO8601DateFormatter().date(from: "2026-09-26T01:00:00Z"))
        #expect(local[0].start == initial[0].start)
        #expect(local[2].day == initial[2].day)
        let style = UnderstandingText.Style(locale: Locale(identifier: "en"), hourStyle: .force24,
                                            now: reference, name: { $0.identifier }, cityName: { _ in "Berlin" },
                                            reference: reference, home: home)
        let labels = berlin.zoneOptions.map {
            UnderstandingText.zoneLabel($0, among: berlin.zoneOptions, at: berlin.start ?? reference, style: style, pasted: true)
        }
        #expect(labels.count == 2)
        #expect(labels[0] != labels[1])
        #expect(labels.allSatisfy { !$0.isEmpty })
    }

    @Test func singleTimeEntryPointsResolveTheSameCandidateIds() throws {
        let text = "Berlin sync at 18:00"
        let input = TimeInput.resolve(text, relativeTo: reference, now: reference, in: home)
        #expect(input.resolved?.zoneOption.id == "zone:Europe/Berlin")
        let alarm = AlarmReading.resolve(text, now: reference, home: home)
        #expect(alarm.item?.zoneOption.id == "zone:Europe/Berlin")
        let localAlarm = AlarmReading.resolve(text, now: reference, home: home, choice: .init(zone: "local"))
        #expect(localAlarm.item?.zoneOption.id == "local")
        #expect(localAlarm.item?.start != alarm.item?.start)
    }
}
