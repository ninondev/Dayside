// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import TahoeTime

@MainActor
struct TravelTests {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func trip() -> TravelTrip {
        TravelTrip(name: "Tokyo", originTimeZoneID: "America/Los_Angeles", destinationTimeZoneID: "Asia/Tokyo",
            departureUnix: date("2026-09-15T18:00:00Z").timeIntervalSince1970,
            arrivalUnix: date("2026-09-16T05:00:00Z").timeIntervalSince1970)
    }

    /// 光照参考：洛杉矶 → 东京钟面 +16 小时，短边是推后 8 小时；默认 3 天 × 60 分钟后落地还剩 300 分钟，
    /// 到达后逐日列到剩余不足 1 小时；行前每行带「睡前 2 小时求光、起床后 3 小时避光」。
    /// 东行 ≥ 8 时区（东京 → 洛杉矶，钟面 −16 = 短边提前 8 小时）自动改走推后 16 小时。
    @Test func lightWindowsFollowTheDirectionAndCountDownAfterArrival() throws {
        let plan = try #require(trip().plan().summary)
        #expect(plan.direction == "delay")
        #expect(plan.targetShiftMinutes == 480)
        #expect(plan.remainingShiftMinutes == 300)
        #expect(plan.cbtOffsetMinutes == 180)
        let first = try #require(plan.rows.first?.light)
        // 第一天推后 60 分钟：入睡 0:00、起床 8:00 → 求光 22:00–0:00、避光 8:00–11:00
        #expect(first.seek?.startMinute == 22 * 60 && first.seek?.endMinute == 0)
        #expect(first.avoid?.startMinute == 8 * 60 && first.avoid?.endMinute == 11 * 60)
        #expect(first.avoidKind == "dark")
        // 落地：剩 300 → 240 → 180 → 120 → 60 → 0，列 5 天；到达当天生物钟比当地早 5 小时，CBTmin 在当地 23:00
        #expect(plan.arrivalRows.count == 5)
        #expect(plan.arrivalRows[0].dayAfterArrival == 0)
        #expect(plan.arrivalRows[0].remainingMinutes == 300)
        #expect(plan.arrivalRows[0].cbtMinute == 23 * 60)
        #expect(plan.arrivalRows[0].seek?.startMinute == 21 * 60)
        #expect(plan.arrivalRows.last?.remainingMinutes == 60)
        var back = trip()
        swap(&back.originTimeZoneID, &back.destinationTimeZoneID)
        let returning = try #require(back.plan().summary)
        #expect(returning.direction == "delay")
        #expect(returning.targetShiftMinutes == 960)
        back.direction = "earlier"
        #expect(try #require(back.plan().summary).targetShiftMinutes == -480)
        var same = trip()
        same.destinationTimeZoneID = "America/Los_Angeles"
        let none = try #require(same.plan().summary)
        #expect(none.direction == "none" && none.arrivalRows.isEmpty && none.rows.first?.light == nil)
    }

    @Test func createEditDeletePersistsAndDoesNotEnableAutomaticSwitch() {
        let (defaults, cleanup) = TestDefaults.make(prefix: "meantime.travel.tests"); defer { cleanup() }
        let store = TravelStore(defaults: defaults)
        #expect(!store.autoSwitchEnabled)
        var trip = trip()
        #expect(store.save(trip).isEmpty)
        trip.name = "Tokyo work trip"
        #expect(store.save(trip).isEmpty)
        let reloaded = TravelStore(defaults: defaults)
        #expect(reloaded.trips.count == 1)
        #expect(reloaded.trips.first?.name == trip.name)
        #expect(!reloaded.autoSwitchEnabled)
        #expect(reloaded.remove(id: trip.id))
        #expect(TravelStore(defaults: defaults).trips.isEmpty)
    }

    @Test func invalidArrivalAndSleepDoNotOverwriteSavedBytes() {
        let (defaults, cleanup) = TestDefaults.make(prefix: "meantime.travel.tests"); defer { cleanup() }
        let store = TravelStore(defaults: defaults)
        var trip = trip(); #expect(store.save(trip).isEmpty)
        let original = defaults.data(forKey: TravelStore.storageKey)
        trip.arrivalUnix = trip.departureUnix - 60
        #expect(store.save(trip).contains("arrivalBeforeDeparture"))
        #expect(defaults.data(forKey: TravelStore.storageKey) == original)
        trip.arrivalUnix = trip.departureUnix + 60
        trip.wakeMinute = trip.sleepMinute
        #expect(store.save(trip).contains("sleepHours"))
        #expect(defaults.data(forKey: TravelStore.storageKey) == original)
    }

    @Test func recoveryPreservesMalformedOriginalAndValidNeighbor() throws {
        let (defaults, cleanup) = TestDefaults.make(prefix: "meantime.travel.tests"); defer { cleanup() }
        let trip = trip()
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(trip))
        let raw = try JSONSerialization.data(withJSONObject: ["version":1,"autoSwitchEnabled":false,"trips":[object,["name":"bad"]]])
        defaults.set(raw, forKey: TravelStore.storageKey)
        let store = TravelStore(defaults: defaults)
        #expect(store.trips.map(\.id) == [trip.id])
        #expect(store.storageNeedsRecovery)
        #expect(store.rejectedCount == 1)
        #expect(defaults.data(forKey: TravelStore.storageKey) == raw)
        #expect(store.setAutoSwitchEnabled(true))
        let backups = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix(TravelStore.backupPrefix) }
        #expect(backups.count == 1)
        #expect(backups.values.first as? Data == raw)
    }

    @Test func futureSchemaRemainsReadOnlyAndOptInStaysOff() {
        let (defaults, cleanup) = TestDefaults.make(prefix: "meantime.travel.tests"); defer { cleanup() }
        let raw = Data("{\"version\":50,\"autoSwitchEnabled\":true,\"trips\":[]}".utf8)
        defaults.set(raw, forKey: TravelStore.storageKey)
        let store = TravelStore(defaults: defaults)
        #expect(store.storageReadOnly)
        #expect(!store.autoSwitchEnabled)
        #expect(!store.setAutoSwitchEnabled(true))
        #expect(defaults.data(forKey: TravelStore.storageKey) == raw)
    }

    @Test func systemZoneSwitchRequiresOptInAndDoesNotGuessFromOffset() {
        let (defaults, cleanup) = TestDefaults.make(prefix: "meantime.travel.tests"); defer { cleanup() }
        let store = TravelStore(defaults: defaults)
        let places = [TimeZoneEntry(timezoneID:"UTC",cityName:"UTC"),TimeZoneEntry(timezoneID:"Asia/Tokyo",cityName:"Tokyo")]
        #expect(store.preferredMainClockID(systemTimeZoneID:"Asia/Tokyo",places:places) == nil)
        #expect(store.setAutoSwitchEnabled(true))
        #expect(store.preferredMainClockID(systemTimeZoneID:"Asia/Tokyo",places:places) == places[1].id)
        #expect(store.preferredMainClockID(systemTimeZoneID:"Asia/Seoul",places:places) == nil)
        #expect(store.preferredMainClockID(systemTimeZoneID:"UTC",places:places) == nil)
        #expect(TravelStore(defaults: defaults).autoSwitchEnabled)
        #expect(store.setAutoSwitchEnabled(false))
        #expect(store.preferredMainClockID(systemTimeZoneID:"Asia/Tokyo",places:places) == nil)
    }

    @Test func dateLineKeepsActualOffsetAndChoosesShorterClockDirection() throws {
        let summary = try #require(trip().plan().summary)
        #expect(summary.offsetDifferenceSeconds == 16 * 3_600)
        #expect(summary.arrivalDayDifference == 1)
        #expect(summary.travelDurationMinutes == 660)
        #expect(summary.targetShiftMinutes == 480)
        #expect(summary.rows.count == 3)
        #expect(summary.rows.map(\.shiftMinutes) == [60,120,180])
        #expect(summary.remainingShiftMinutes == 300)
    }

    @Test func crossingDateLineCanArriveOnEarlierLocalDate() {
        var trip = trip()
        trip.originTimeZoneID = "Pacific/Kiritimati"
        trip.destinationTimeZoneID = "Pacific/Honolulu"
        trip.departure = date("2026-09-09T10:00:00Z")
        trip.arrival = date("2026-09-09T15:00:00Z")
        let summary = trip.plan().summary
        #expect(summary?.offsetDifferenceSeconds == -86_400)
        #expect(summary?.targetShiftMinutes == 0)
        #expect(summary?.arrivalDayDifference == -1)
    }

    @Test func fractionalTimezoneUsesMinutePrecisionWithoutOvershoot() {
        var trip = trip()
        trip.originTimeZoneID = "Asia/Kolkata"
        trip.destinationTimeZoneID = "Asia/Kathmandu"
        let summary = trip.plan().summary
        #expect(summary?.offsetDifferenceSeconds == 900)
        #expect(summary?.rows.map(\.shiftMinutes) == [-15,-15,-15])
    }

    @Test func skippedWallTimeIsFlaggedWithoutInventingAReplacement() throws {
        var trip = trip()
        trip.originTimeZoneID = "America/New_York"
        trip.departure = date("2026-03-09T16:00:00Z")
        let row = TravelPlan.Row(relativeDay:-1,shiftMinutes:0,sleepMinute:150,sleepDayOffset:0,wakeMinute:600,wakeDayOffset:0)
        let actual = trip.materialize(row)
        #expect(actual.sleepText == "2026-03-08 02:30")
        #expect(actual.checks.nonexistentTime)
        #expect(actual.checks.elapsedSleepMinutes == nil)
    }

    @Test func repeatedWallTimeRequiresReviewAndDSTNightUsesElapsedTime() {
        var trip = trip()
        trip.originTimeZoneID = "America/New_York"
        trip.departure = date("2026-11-02T16:00:00Z")
        let repeated = trip.materialize(.init(relativeDay:-1,shiftMinutes:0,sleepMinute:90,sleepDayOffset:0,wakeMinute:600,wakeDayOffset:0))
        #expect(repeated.checks.repeatedTime)
        #expect(repeated.checks.elapsedSleepMinutes == nil)
        let night = trip.materialize(.init(relativeDay:-2,shiftMinutes:0,sleepMinute:1380,sleepDayOffset:0,wakeMinute:420,wakeDayOffset:1))
        #expect(night.checks.elapsedSleepMinutes == 540)
    }

    @Test func scheduleOverlappingDepartureIsFlagged() {
        var trip = trip()
        trip.originTimeZoneID = "UTC"
        trip.departure = date("2026-09-09T06:00:00Z")
        let row = trip.materialize(.init(relativeDay:-1,shiftMinutes:0,sleepMinute:1380,sleepDayOffset:0,wakeMinute:420,wakeDayOffset:1))
        #expect(row.checks.overlapsDeparture)
    }

    @Test func travelLensOwnsNoBackgroundResources() {
        let (defaults, cleanup) = TestDefaults.make(prefix: "meantime.travel.tests"); defer { cleanup() }
        let store = TravelStore(defaults: defaults)
        #expect(store.save(trip()).isEmpty)
        #expect(store.setAutoSwitchEnabled(true))
        _ = store.trips.first?.plan()
        #expect(store.activeResourceCount == 0)
        store.deactivate()
        #expect(store.activeResourceCount == 0)
    }
}
