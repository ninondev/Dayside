// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct TravelTrip: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var originTimeZoneID: String
    /// A place snapshot, retained even if that saved place is later removed.
    var destinationTimeZoneID: String
    var destinationPlaceID: UUID?
    var originPlace: TravelPlaceSnapshot?
    var destinationPlace: TravelPlaceSnapshot?
    var departureUnix: Double
    var arrivalUnix: Double
    var sleepMinute = 1380
    var wakeMinute = 420
    var preparationDays = 3
    var dailyShiftMinutes = 60
    var direction = "automatic"

    var departure: Date {
        get { Date(timeIntervalSince1970: departureUnix) }
        set { departureUnix = newValue.timeIntervalSince1970 }
    }
    var arrival: Date {
        get { Date(timeIntervalSince1970: arrivalUnix) }
        set { arrivalUnix = newValue.timeIntervalSince1970 }
    }

    static let supportedDates = Date(timeIntervalSince1970: -2_208_988_800)...Date(timeIntervalSince1970: 7_258_118_399)

    /// Trips retain the timezone used when the itinerary was saved. Linking a place is a picker shortcut,
    /// not permission to reinterpret the historical departure and arrival after a place edit.
    func plan() -> TravelPlan {
        let origin = TimeZone(identifier: originTimeZoneID)
        let destination = TimeZone(identifier: destinationTimeZoneID)
        struct Input: Encodable {
            let trip: TravelTrip
            let timeZonesValid: Bool
            let offsetDifferenceAtArrival: Int
            let offsetDifferenceAtDeparture: Int
            let originArrivalDay: Int
            let destinationArrivalDay: Int
        }
        return RustCore.invoke("travel.plan", Input(trip: self, timeZonesValid: origin != nil && destination != nil,
            offsetDifferenceAtArrival: (destination?.secondsFromGMT(for: arrival) ?? 0) - (origin?.secondsFromGMT(for: arrival) ?? 0),
            offsetDifferenceAtDeparture: (destination?.secondsFromGMT(for: departure) ?? 0) - (origin?.secondsFromGMT(for: departure) ?? 0),
            originArrivalDay: civilDayNumber(arrival, in: origin ?? .gmt),
            destinationArrivalDay: civilDayNumber(arrival, in: destination ?? .gmt)))
    }

    private func civilDayNumber(_ date: Date, in zone: TimeZone) -> Int {
        let calendar = Calendar.gregorianUTC(zone)
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let wall = Calendar.gregorianUTC(.gmt).date(from: parts) ?? date
        return Int(floor(wall.timeIntervalSince1970 / 86_400))
    }

    /// Resolve each requested wall time through the same DST-aware converter as the rest of the app.
    /// No guessed replacement is supplied for a skipped or repeated civil time.
    func materialize(_ row: TravelPlan.Row) -> TravelScheduleRow {
        let origin = TimeZone(identifier: originTimeZoneID) ?? .gmt
        let calendar = Calendar.gregorianUTC(origin)
        let anchor = calendar.startOfDay(for: departure)
        let nominal = calendar.date(byAdding: .day, value: row.relativeDay, to: anchor) ?? anchor
        let sleepDate = calendar.date(byAdding: .day, value: row.sleepDayOffset, to: nominal) ?? nominal
        let wakeDate = calendar.date(byAdding: .day, value: row.wakeDayOffset, to: nominal) ?? nominal
        let sleepText = civilText(sleepDate, minute: row.sleepMinute, calendar: calendar)
        let wakeText = civilText(wakeDate, minute: row.wakeMinute, calendar: calendar)
        // These dates and minutes are already native calendar facts: resolve the wall
        // clock on the intended civil day directly, so DST validation needs no parsing.
        let sleep = TimeInput.resolveClock(minuteOfDay: row.sleepMinute, on: sleepDate, in: origin)
        let wake = TimeInput.resolveClock(minuteOfDay: row.wakeMinute, on: wakeDate, in: origin)
        struct Facts: Encodable {
            let departureUnix: Double
            let sleepCandidates: [Double]
            let wakeCandidates: [Double]
        }
        let checks: TravelScheduleRow.Checks = RustCore.invoke("travel.schedule_checks", Facts(
            departureUnix: departureUnix, sleepCandidates: sleep.dates.map(\.timeIntervalSince1970),
            wakeCandidates: wake.dates.map(\.timeIntervalSince1970)))
        return TravelScheduleRow(id: row.relativeDay, nominalDate: nominal, sleepText: sleepText,
                                 wakeText: wakeText, sleepDate: sleepDate, wakeDate: wakeDate,
                                 sleepMinute: row.sleepMinute, wakeMinute: row.wakeMinute,
                                 shiftMinutes: row.shiftMinutes, light: row.light, checks: checks)
    }

    private func civilText(_ date: Date, minute: Int, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d %02d:%02d", parts.year ?? 1, parts.month ?? 1,
                      parts.day ?? 1, minute / 60, minute % 60)
    }
}

struct TravelPlan: Decodable, Sendable {
    let error: String?
    let summary: Summary?
    struct Summary: Decodable, Sendable {
        let offsetDifferenceSeconds: Int
        let arrivalDayDifference: Int
        let offsetChangesDuringTravel: Bool
        let travelDurationMinutes: Double
        let targetShiftMinutes: Int
        let remainingShiftMinutes: Int
        /// "advance" / "delay" / "none"
        let direction: String
        /// 估计的体温最低点在起床前多少分钟（180，睡眠不足 7 小时时 150）
        let cbtOffsetMinutes: Int
        let sleepDurationMinutes: Int
        let rows: [Row]
        /// 落地后逐日的光照窗口（目的地墙钟），生物钟对齐后不再列
        let arrivalRows: [ArrivalRow]
        let homeSleepAtDestinationMinute: Int
        let destinationSleepMinute: Int
        let destinationWakeMinute: Int
    }
    struct Row: Decodable, Sendable {
        let relativeDay: Int
        let shiftMinutes: Int
        let sleepMinute: Int
        let sleepDayOffset: Int
        let wakeMinute: Int
        let wakeDayOffset: Int
        var light: Light? = nil
        init(relativeDay: Int, shiftMinutes: Int, sleepMinute: Int, sleepDayOffset: Int, wakeMinute: Int, wakeDayOffset: Int, light: Light? = nil) {
            self.relativeDay = relativeDay; self.shiftMinutes = shiftMinutes; self.sleepMinute = sleepMinute
            self.sleepDayOffset = sleepDayOffset; self.wakeMinute = wakeMinute; self.wakeDayOffset = wakeDayOffset; self.light = light
        }
    }
    /// 一天的光照窗口：求光与避光各一段（墙钟分钟，可能跨午夜），`avoidKind` 是 "dark"（深色墨镜）或 "dim"（睡前调暗）。
    struct Light: Decodable, Sendable {
        let cbtMinute: Int
        let seek: Window?
        let avoid: Window?
        let avoidKind: String
    }
    struct Window: Decodable, Sendable {
        let startMinute: Int
        let endMinute: Int
    }
    struct ArrivalRow: Decodable, Sendable {
        let dayAfterArrival: Int
        let remainingMinutes: Int
        let cbtMinute: Int
        let seek: Window?
        let avoid: Window?
        let avoidKind: String
    }
    private enum CodingKeys: String, CodingKey { case error }
    init(from decoder: Decoder) throws {
        error = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(String.self, forKey: .error)
        summary = error == nil ? try Summary(from: decoder) : nil
    }
}

struct TravelScheduleRow: Identifiable, Sendable {
    let id: Int
    let nominalDate: Date
    let sleepText: String
    let wakeText: String
    let sleepDate: Date
    let wakeDate: Date
    let sleepMinute: Int
    let wakeMinute: Int
    let shiftMinutes: Int
    let light: TravelPlan.Light?
    let checks: Checks
    struct Checks: Codable, Sendable {
        let nonexistentTime: Bool
        let repeatedTime: Bool
        let overlapsDeparture: Bool
        let elapsedSleepMinutes: Double?
    }
}

struct TravelPlaceSnapshot: Codable, Hashable, Sendable {
    var name: String
    var latitude: Double
    var longitude: Double
    var countryCode: String?
    var coordinate: Coordinate { Coordinate(latitude: latitude, longitude: longitude) }
}

extension TravelTrip {
    func savedPlace(origin: Bool, places: [TimeZoneEntry]) -> TimeZoneEntry? {
        if !origin { return places.first { $0.id == destinationPlaceID } }
        guard let snapshot = originPlace else { return places.first { $0.timezoneID == originTimeZoneID } }
        return places.first { $0.timezoneID == originTimeZoneID && $0.coordinate == snapshot.coordinate }
    }
    @MainActor func placeName(origin: Bool, core: TimeCore) -> String {
        let snapshot = origin ? originPlace : destinationPlace
        if let entry = savedPlace(origin: origin, places: core.zones) {
            return entry.displayName(localizedCity: core.cityName(for: entry))
        }
        return snapshot?.name ?? core.placeName(forTimeZoneID: origin ? originTimeZoneID : destinationTimeZoneID)
    }
    func coordinate(origin: Bool, places: [TimeZoneEntry]) -> Coordinate? {
        let snapshot = origin ? originPlace : destinationPlace
        return savedPlace(origin: origin, places: places)?.coordinate ?? snapshot?.coordinate ??
            ZoneCatalog.shared.knownCoordinate(for: origin ? originTimeZoneID : destinationTimeZoneID)
    }
    func countryCode(places: [TimeZoneEntry]) -> String? {
        savedPlace(origin: false, places: places)?.countryCode ?? destinationPlace?.countryCode
    }
    func destinationOffsetOnly(places: [TimeZoneEntry]) -> Bool {
        if let entry = savedPlace(origin: false, places: places) { return entry.offsetOnlyZoneName }
        guard let snapshot = destinationPlace else { return ZoneNameDisplay.offsetOnly(identifier: destinationTimeZoneID) }
        return ZoneNameDisplay.offsetOnly(identifier: destinationTimeZoneID, code: snapshot.countryCode ?? "",
            city: snapshot.name, coordinate: snapshot.coordinate)
    }
}
