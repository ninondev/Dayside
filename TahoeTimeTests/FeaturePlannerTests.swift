// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import TahoeTime

struct FeaturePlannerTests {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    private func nightShift(vacations: [OverlapPlanner.Vacation] = []) -> OverlapPlanner.Participant {
        .init(id: UUID(), name: "Night shift", timeZoneID: "Etc/UTC",
              availability: Availability(startMinute: 1320, endMinute: 360, weekdaysOnly: true),
              countryCode: "US", workingWeekdays: [6], vacations: vacations)
    }

    @Test func explicitFridayShiftContinuesIntoSaturday() {
        let spans = OverlapPlanner.availabilityIntervals(for: nightShift(),
            coveringFrom: date("2026-09-11T00:00:00Z"), to: date("2026-09-13T00:00:00Z"))
        #expect(spans == [DateInterval(start: date("2026-09-11T22:00:00Z"),
                                      end: date("2026-09-12T06:00:00Z"))])
    }

    @Test func vacationBlocksTheEntireLocalDayIncludingIncomingNightShift() {
        let person = nightShift(vacations: [.init(startDate: "2026-09-12", endDate: "2026-09-12")])
        let spans = OverlapPlanner.availabilityIntervals(for: person,
            coveringFrom: date("2026-09-11T00:00:00Z"), to: date("2026-09-13T00:00:00Z"))
        #expect(spans == [DateInterval(start: date("2026-09-11T22:00:00Z"),
                                      end: date("2026-09-12T00:00:00Z"))])
        let result = OverlapPlanner.plan(.init(participants: [person],
            from: date("2026-09-12T00:00:00Z"), days: 1, durationMinutes: 30,
            localTimeZoneID: "Etc/UTC", toleranceMinutes: 120))
        #expect(result.windows.isEmpty)
    }

    @Test func emptyExplicitWorkWeekHasNoAvailability() {
        var person = nightShift()
        person.workingWeekdays = []
        let spans = OverlapPlanner.availabilityIntervals(for: person,
            coveringFrom: date("2026-09-11T00:00:00Z"), to: date("2026-09-13T00:00:00Z"))
        #expect(spans.isEmpty)
    }
}
