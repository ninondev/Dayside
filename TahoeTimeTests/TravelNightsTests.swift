// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import TahoeTime

@MainActor
struct TravelNightsTests {
    private let origin = TimeZone(identifier: "America/Los_Angeles")!
    private let destination = TimeZone(identifier: "Asia/Tokyo")!
    private let originCoordinate = Coordinate(latitude: 34.05, longitude: -118.24)
    private let destinationCoordinate = Coordinate(latitude: 35.68, longitude: 139.69)
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func west() -> TravelTrip {
        let departure = date("2026-10-06T18:20:00Z")
        return TravelTrip(name: "Tokyo", originTimeZoneID: origin.identifier, destinationTimeZoneID: destination.identifier,
            departureUnix: departure.timeIntervalSince1970, arrivalUnix: departure.addingTimeInterval(705 * 60).timeIntervalSince1970)
    }
    @Test func noonFramesFollowActualDSTNightLength() {
        let ny = TimeZone(identifier: "America/New_York")!
        let short = TravelNightFacts.frame(on: date("2026-03-07T17:00:00Z"), in: ny)
        let long = TravelNightFacts.frame(on: date("2026-10-31T16:00:00Z"), in: ny)
        #expect(short.end - short.start == 23 * 3600)
        #expect(long.end - long.start == 25 * 3600)
        #expect(short.date == "2026-03-07")
        #expect(long.date == "2026-10-31")
    }
    @Test func preparationLightBelongsToTheCorrectCivilDay() {
        let day = date("2026-10-03T19:00:00Z")
        let late = TravelNightFacts.prepWindow(.init(startMinute: 1320, endMinute: 0), on: day, in: origin)
        let early = TravelNightFacts.prepWindow(.init(startMinute: 480, endMinute: 660), on: day, in: origin)
        #expect(TravelNightFacts.civilDate(Date(timeIntervalSince1970: late[0]), in: origin) == "2026-10-03")
        #expect(TravelNightFacts.civilDate(Date(timeIntervalSince1970: late[1]), in: origin) == "2026-10-04")
        #expect(TravelNightFacts.civilDate(Date(timeIntervalSince1970: early[0]), in: origin) == "2026-10-04")
        #expect(TravelNightFacts.civilDate(Date(timeIntervalSince1970: early[1]), in: origin) == "2026-10-04")
    }
    @Test func missingClockUsesTheGapEndAndRepeatedClockUsesTheFirst() {
        let ny = TimeZone(identifier: "America/New_York")!
        let missing = TravelNightFacts.resolve(150, on: date("2026-03-08T16:00:00Z"), in: ny)
        #expect(missing.missing)
        #expect(missing.date == date("2026-03-08T07:00:00Z"))
        let repeated = TravelNightFacts.resolve(90, on: date("2026-11-01T17:00:00Z"), in: ny)
        #expect(repeated.repeated)
        #expect(repeated.date == date("2026-11-01T05:30:00Z"))
    }
    @Test func westFoundationFactsAndRustGeometryAgree() throws {
        let trip = west()
        let summary = try #require(trip.plan().summary)
        let input = TravelNightFacts.input(trip: trip, summary: summary, originCoordinate: originCoordinate,
            destinationCoordinate: destinationCoordinate, reference: date("2026-10-02T19:00:00Z"), marks: false)
        #expect(input.prep.count == 3)
        #expect(input.after.count == 5)
        #expect(input.departureDate == "2026-10-06")
        #expect(input.arrivalDate == "2026-10-07")
        #expect(input.prep[0].start == 1_791_054_000)
        #expect(input.prep[0].sleep == [1_791_097_200, 1_791_126_000])
        #expect(input.departureNight.date == "2026-10-05")
        let output = try RustCore.attempt("travel.nights", input, as: TravelNights.self)
        #expect(output.lanes.count == 7)
        #expect(output.lanes.last?.label.kind == "quiet")
        #expect(output.lanes.last?.label.nights == 3)
        let lastPrep = try #require(output.lanes.last(where: { $0.kind == "prep" }))
        #expect(abs((lastPrep.departure ?? 0) - 1400.0 / 1440.0) < 1e-10)
        if ProcessInfo.processInfo.environment["MEANTIME_TRAVEL_TEST_EXPORT_INPUT"] != nil {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let encoded = try encoder.encode(input).base64EncodedString()
            FileHandle.standardOutput.write(Data("MEANTIME_TRAVEL_TEST_INPUT_BASE64=\(encoded)\n".utf8))
        }
    }
    @Test func ribbonMemoReusesWithinNightAndRecomputesAtBoundaries() throws {
        let trip = west()
        let memo = TravelNightsMemo()
        let first = date("2026-10-03T20:00:00Z")
        memo.update(trip: trip, origin: originCoordinate, destination: destinationCoordinate, reference: first, marks: false)
        let computations = memo.computations
        let revision = memo.revision
        let before = try #require(memo.nights.lanes.first?.reference)
        memo.update(trip: trip, origin: originCoordinate, destination: destinationCoordinate, reference: first.addingTimeInterval(3600), marks: false)
        #expect(memo.computations == computations)
        #expect(memo.revision == revision)
        #expect((memo.nights.lanes.first?.reference ?? 0) > before)
        memo.update(trip: trip, origin: originCoordinate, destination: destinationCoordinate, reference: first.addingTimeInterval(86400), marks: false)
        #expect(memo.computations == computations + 1)
        memo.update(trip: trip, origin: originCoordinate, destination: destinationCoordinate, reference: first.addingTimeInterval(86400), marks: true)
        #expect(memo.computations == computations + 2)
        var edited = trip
        edited.dailyShiftMinutes = 90
        memo.update(trip: edited, origin: originCoordinate, destination: destinationCoordinate, reference: first, marks: true)
        #expect(memo.computations == computations + 3)
    }
    @Test func snapshotsKeepSpecificCityAndSavedDestinationTakesPrecedence() {
        var trip = west()
        trip.destinationPlace = .init(name: "Osaka", latitude: 34.69, longitude: 135.5, countryCode: "JP")
        let core = TimeCore(zones: [], settings: AppSettings())
        #expect(trip.placeName(origin: false, core: core) == "Osaka")
        #expect(trip.coordinate(origin: false, places: []) == Coordinate(latitude: 34.69, longitude: 135.5))
        let saved = TimeZoneEntry(timezoneID: "Asia/Tokyo", customName: "Kyoto", cityName: "Kyoto",
            coordinate: Coordinate(latitude: 35.01, longitude: 135.77), usesExemplarName: false, countryCode: "JP")
        trip.destinationPlaceID = saved.id
        let linked = TimeCore(zones: [saved], settings: AppSettings())
        #expect(trip.placeName(origin: false, core: linked) == "Kyoto")
        #expect(trip.coordinate(origin: false, places: [saved]) == saved.coordinate)
        #expect(trip.placeName(origin: false, core: core) == "Osaka")
    }
}
