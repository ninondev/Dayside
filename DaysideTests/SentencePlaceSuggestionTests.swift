// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import Dayside

@MainActor
struct SentencePlaceSuggestionTests {
    private let reference = ISO8601DateFormatter().date(from: "2026-09-24T12:00:00Z")!
    private let text = "The hotel in Tokyo confirms check-in at 14:00."

    private func mention(suggestion: Bool = true) throws -> TimeUnderstanding.Mention {
        // The host contract is independent of how the engine finds the location clue.
        let city = #"{"kind":"city","cityIndex":1,"name":"Tokyo","iana":"Asia/Tokyo"}"#
        let source = suggestion ? #"{"kind":"options","reason":"sentence","options":["# + city + "]}" : city
        let json = #"{"span":[0,45],"parts":[{"kind":"time","span":[39,44]},{"kind":"place","span":[13,18]}],"time":{"hour":14,"minute":0,"second":0,"dayOffset":0},"source":"# + source + "}"
        return try JSONDecoder().decode(TimeUnderstanding.Mention.self, from: Data(json.utf8))
    }

    private func context(origin: TimeUnderstanding.Origin = .typed) throws -> TimeUnderstanding.Context {
        .init(reference: reference, now: reference,
              fallback: try #require(TimeZone(identifier: "Europe/London")),
              home: try #require(TimeZone(identifier: "America/Los_Angeles")),
              preferredZones: ["Europe/Berlin", "Asia/Tokyo", "America/Los_Angeles", "Europe/London"], origin: origin)
    }

    private func style(language: String = "zh-Hans") -> UnderstandingText.Style {
        .init(locale: Locale(identifier: language), hourStyle: .force24, now: reference,
              name: { $0.identifier == "America/Los_Angeles" ? "Los Angeles" : $0.identifier },
              cityName: { _ in "Tokyo" }, reference: reference)
    }

    @Test func suggestionPrecedesReaderLocalAndPastedPlaces() throws {
        let mention = try mention()
        let typed = TimeUnderstanding.resolve(mention, context: try context())
        #expect(typed.zoneOptions.map(\.id) == ["zone:Asia/Tokyo", "local"])
        #expect(typed.zone.identifier == "Asia/Tokyo")
        #expect(ISO8601DateFormatter().string(from: try #require(typed.start)) == "2026-09-24T05:00:00Z")
        #expect(typed.zoneOptions.first?.city?.name == "Tokyo")
        let pasted = TimeUnderstanding.resolve(mention, context: try context(origin: .pasted))
        #expect(pasted.zoneOptions.map(\.id) == ["zone:Asia/Tokyo", "local", "zone:Europe/Berlin", "zone:Europe/London"])
        #expect(pasted.zone.identifier == "Asia/Tokyo", "A preferred zone cannot replace the suggestion as default")
        let local = try #require(pasted.zoneOptions.first { $0.id == "local" })
        #expect(UnderstandingText.zoneLabel(local, among: pasted.zoneOptions, at: reference, style: style(), pasted: true)
            == "本机（Los Angeles）")
        let suggested = try #require(pasted.zoneOptions.first)
        #expect(UnderstandingText.zoneLabel(suggested, among: pasted.zoneOptions, at: reference, style: style(), pasted: true)
            == "Tokyo（UTC+9）")
    }

    @Test func noteFollowsTheResultAndRemainsAfterAnExplicitLocalChoice() throws {
        let mention = try mention()
        let ctx = try context(origin: .pasted)
        let normal = TimeUnderstanding.resolve(mention, context: ctx)
        let local = TimeUnderstanding.resolve(mention, context: ctx, choice: .init(zone: "local"))
        #expect(local.zone.identifier == "America/Los_Angeles")
        #expect(!local.notes.contains(.localMeansTheWriter))
        let expected = "钟点没写明是哪里的，先按句中提到的Tokyo算"
        for result in [normal, local] {
            #expect(UnderstandingText.sentenceNote(result, style: style()) == expected)
            let summary = UnderstandingText.summary(result, in: text, style: style(), pasted: true)
            #expect(UnderstandingText.accessibleSummary(result, in: text, style: style(), pasted: true) == summary + "。" + expected)
        }
        let attached = TimeUnderstanding.resolve(try self.mention(suggestion: false), context: ctx)
        #expect(attached.zoneOptions.map(\.id) == ["zone:Asia/Tokyo"])
        #expect(UnderstandingText.sentenceNote(attached, style: style()) == nil)
    }

    @Test(arguments: ["zh-Hans", "zh-Hant", "en", "ja", "ko", "de", "es", "fr", "ru", "pt-BR", "it", "nl", "pl", "tr", "vi", "id"])
    func noteUsesTheCatalogForEveryLanguage(_ language: String) throws {
        let result = TimeUnderstanding.resolve(try mention(), context: try context())
        let style = style(language: language)
        let note = try #require(UnderstandingText.sentenceNote(result, style: style))
        #expect(note.contains("Tokyo"))
        #expect(!note.contains("%@"))
        if language != "zh-Hans" { #expect(!note.contains("钟点没写明")) }
    }

    private func countryMention(code: String, regions: [String]) throws -> TimeUnderstanding.Mention {
        let country: [String: Any] = regions.count == 1
            ? ["kind": "region", "iana": regions[0]]
            : ["kind": "options", "reason": "country", "options": regions.map { ["kind": "region", "iana": $0] }]
        let fields: [String: Any] = [
            "span": [0, 45], "parts": [["kind": "place", "span": [13, 18]]],
            "time": ["hour": 14, "minute": 0, "second": 0, "dayOffset": 0],
            "source": ["kind": "options", "reason": "sentence", "options": [country]],
            "sentencePlaceCountry": code
        ]
        return try JSONDecoder().decode(TimeUnderstanding.Mention.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    @Test(arguments: ["zh-Hans", "en"])
    func singleRegionCountryNoteNamesJapan(_ language: String) throws {
        let mention = try countryMention(code: "JP", regions: ["Asia/Tokyo"])
        #expect(mention.sentencePlaceCountry == "JP")
        let result = TimeUnderstanding.resolve(mention, context: try context())
        let expected = language == "zh-Hans"
            ? "钟点没写明是哪里的，先按句中提到的日本算"
            : "The time doesn’t say where; using Japan from the sentence for now"
        #expect(UnderstandingText.sentenceNote(result, style: style(language: language)) == expected)
    }

    @Test(arguments: ["zh-Hans", "en"])
    func nestedCountryOptionsNoteNamesTheUnitedStates(_ language: String) throws {
        let mention = try countryMention(code: "US", regions: ["America/New_York", "America/Chicago", "America/Los_Angeles"])
        let ctx = try context(origin: .pasted)
        let initial = TimeUnderstanding.resolve(mention, context: ctx)
        let local = TimeUnderstanding.resolve(mention, context: ctx, choice: .init(zone: "local"))
        let expected = language == "zh-Hans"
            ? "钟点没写明是哪里的，先按句中提到的美国算"
            : "The time doesn’t say where; using United States from the sentence for now"
        for result in [initial, local] {
            #expect(UnderstandingText.sentenceNote(result, style: style(language: language)) == expected)
        }
        #expect(initial.zoneOptions.first?.id == "zone:America/Los_Angeles", "Existing country preferred-zone ordering stays intact")
    }

    @Test func sameZoneSuggestionAndReaderLocalRemainTwoSemanticChoices() throws {
        var ctx = try context()
        ctx.home = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let result = TimeUnderstanding.resolve(try mention(), context: ctx)
        #expect(result.zoneOptions.map(\.id) == ["zone:Asia/Tokyo", "local"])
        #expect(result.zoneOptions.map(\.zone.identifier) == ["Asia/Tokyo", "Asia/Tokyo"])
        #expect(result.zoneOptions.map(\.kind) == [.region, .readerLocal])
        #expect(result.zoneOption.id == "zone:Asia/Tokyo")
    }

    @Test func pastedPanelResolutionOffersUserPlacesAfterReaderLocal() throws {
        let selected = try #require(TimeZone(identifier: "Europe/London"))
        let preferred = ["Europe/Berlin", "Asia/Tokyo", "America/Los_Angeles"]
        let typed = TimeInput.resolve(text, relativeTo: reference, in: selected, preferredZones: preferred)
        let pasted = TimeInput.resolve(text, relativeTo: reference, in: selected, preferredZones: preferred, origin: .pasted)
        let typedOptions = try #require(typed.resolved).zoneOptions
        let pastedOptions = try #require(pasted.resolved).zoneOptions
        #expect(typedOptions.map(\.id) == ["zone:Asia/Tokyo", "local"])
        #expect(pastedOptions.first?.id == "zone:Asia/Tokyo")
        #expect(pastedOptions.dropFirst().first?.id == "local")
        let expectedPlaces = preferred.filter { $0 != "Asia/Tokyo" && $0 != TimeZone.current.identifier }.map { "zone:\($0)" }
        #expect(pastedOptions.map(\.id) == ["zone:Asia/Tokyo", "local"] + expectedPlaces)
        #expect(pastedOptions.filter { $0.id == "zone:Asia/Tokyo" }.count == 1)
        #expect(pasted.timeZone.identifier == "Asia/Tokyo")
    }

    @Test func noninteractiveEntriesTakeTheSentenceSuggestion() throws {
        let selected = try #require(TimeZone(identifier: "Europe/London"))
        let result = TimeInput.resolve(text, relativeTo: reference, in: selected, preferredZones: ["Europe/Berlin"])
        #expect(result.error == nil)
        #expect(result.timeZone.identifier == "Asia/Tokyo")
        #expect(TimeInput.sourceTimeZone(for: text, in: selected).identifier == "Asia/Tokyo")
    }
}
