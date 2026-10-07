// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import TahoeTime

struct BusinessReviewTests {
    @Test func supportedTravelDatesBeyondConverterGrammarStillResolveSleep() throws {
        let departure = date("2150-09-15T18:00:00Z")
        let trip = TravelTrip(name: "Future itinerary", originTimeZoneID: "America/Los_Angeles",
            destinationTimeZoneID: "Asia/Tokyo", departureUnix: departure.timeIntervalSince1970,
            arrivalUnix: departure.addingTimeInterval(11 * 3_600).timeIntervalSince1970)
        #expect(TravelTrip.supportedDates.contains(departure))
        let summary = try #require(trip.plan().summary)
        #expect(!summary.rows.isEmpty)
        for row in summary.rows {
            let actual = trip.materialize(row)
            #expect(!actual.checks.nonexistentTime)
            #expect(!actual.checks.repeatedTime)
            #expect(actual.checks.elapsedSleepMinutes == 480.0)
        }
    }

    @Test func travelReferenceDateKeepsDSTGapAndFoldChecks() {
        var trip = TravelTrip(name: "DST itinerary", originTimeZoneID: "America/New_York",
            destinationTimeZoneID: "Europe/Paris", departureUnix: date("2026-03-09T16:00:00Z").timeIntervalSince1970,
            arrivalUnix: date("2026-03-10T05:00:00Z").timeIntervalSince1970)
        let gap = trip.materialize(.init(relativeDay: -1, shiftMinutes: 0,
            sleepMinute: 150, sleepDayOffset: 0, wakeMinute: 600, wakeDayOffset: 0))
        #expect(gap.sleepText == "2026-03-08 02:30")
        #expect(gap.checks.nonexistentTime)
        #expect(gap.checks.elapsedSleepMinutes == nil)
        trip.departureUnix = date("2026-11-02T16:00:00Z").timeIntervalSince1970
        let fold = trip.materialize(.init(relativeDay: -1, shiftMinutes: 0,
            sleepMinute: 90, sleepDayOffset: 0, wakeMinute: 600, wakeDayOffset: 0))
        #expect(fold.sleepText == "2026-11-01 01:30")
        #expect(fold.checks.repeatedTime)
        #expect(fold.checks.elapsedSleepMinutes == nil)
    }

    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
}
