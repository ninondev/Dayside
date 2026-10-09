// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CoreGraphics

struct TravelNights: Decodable, Sendable {
    struct Part: Decodable, Sendable {
        let place: String
        let from: Double
        let to: Double
        let stops: [SkyStripState.Stop]
        let lineStops: [SkyStripState.Stop]
        let marks: [SkyStripState.Mark]
    }
    struct Label: Decodable, Sendable {
        let kind: String
        let minutes: Double?
        let nights: Int?
    }
    struct Lane: Decodable, Sendable {
        let kind: String
        let date: String
        let parts: [Part]
        let air: [[Double]]
        let sleep: [Double]?
        let sleepClipStart: Bool?
        let sleepClipEnd: Bool?
        let seek: [[Double]]
        let avoid: [[Double]]
        let avoidKind: String?
        let departure: Double?
        let arrival: Double?
        var reference: Double?
        let label: Label
        let dateTo: String?
        let seekRange: [Double]?
        let avoidRange: [Double]?
        let midPlane: Bool
        let range: [Double]
        let checks: TravelScheduleRow.Checks?
    }
    var lanes: [Lane]
    let selected: Int
    static let empty = TravelNights(lanes: [], selected: 0)
}

struct TravelNightsInput: Encodable {
    struct Night: Encodable {
        let date: String
        let start: Double
        let end: Double
        var sleep: [Double]? = nil
        var checks: TravelScheduleRow.Checks? = nil
    }
    struct Prep: Encodable {
        let date: String
        let start: Double
        let end: Double
        let shiftMinutes: Int
        let sleep: [Double]?
        let seek: [Double]?
        let avoid: [Double]?
        let avoidKind: String?
        let checks: TravelScheduleRow.Checks
    }
    struct After: Encodable {
        let date: String
        let start: Double
        let end: Double
        let k: Int
        let sleep: [Double]
        let remainingMinutes: Int
        let checks: TravelScheduleRow.Checks
    }
    struct Window: Encodable {
        let day: Int
        let kind: String
        let span: [Double]
        let avoidKind: String?
    }
    let origin: Coordinate?
    let destination: Coordinate?
    let departure: Double
    let arrival: Double
    var reference: Double
    let marks: Bool
    let departureDate: String
    let arrivalDate: String
    let prep: [Prep]
    let departureNight: Night
    let arrivalNight: Night
    let after: [After]
    let windows: [Window]
}

enum TravelNightFacts {
    static func civilDate(_ date: Date, in zone: TimeZone) -> String {
        PersonProfile.civilDate(date, calendar: Calendar.gregorianUTC(zone))
    }
    static func date(_ text: String, in zone: TimeZone) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.gregorianUTC(zone).date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }
    /// 民用日的中午到次日中午，换钟那晚保留真实的长短。
    static func frame(on day: Date, in zone: TimeZone) -> TravelNightsInput.Night {
        let calendar = Calendar.gregorianUTC(zone)
        let start = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day
        let next = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        let end = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: next) ?? next
        return .init(date: civilDate(start, in: zone), start: start.timeIntervalSince1970, end: end.timeIntervalSince1970)
    }
    static func frame(containing instant: Date, in zone: TimeZone) -> TravelNightsInput.Night {
        let calendar = Calendar.gregorianUTC(zone)
        let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: instant) ?? instant
        let day = instant < noon ? calendar.date(byAdding: .day, value: -1, to: noon) ?? noon : noon
        return frame(on: day, in: zone)
    }
    /// 缺失的钟点取跳钟后的那一刻，重复的钟点取第一次。
    static func resolve(_ minute: Int, on day: Date, in zone: TimeZone) -> (date: Date, missing: Bool, repeated: Bool) {
        let resolution = TimeInput.resolveClock(minuteOfDay: minute, on: day, in: zone)
        if let date = resolution.dates.first { return (date, false, resolution.dates.count > 1) }
        let calendar = Calendar.gregorianUTC(zone)
        let fallback = calendar.nextDate(after: calendar.startOfDay(for: day).addingTimeInterval(-1),
            matching: DateComponents(hour: minute / 60, minute: minute % 60, second: 0),
            matchingPolicy: .nextTime, repeatedTimePolicy: .first) ?? day
        return (fallback, true, false)
    }
    /// 行前光窗口的钟面起点落在中午前时归次日。
    static func prepWindow(_ window: TravelPlan.Window, on day: Date, in zone: TimeZone) -> [Double] {
        let calendar = Calendar.gregorianUTC(zone)
        let startDay = window.startMinute >= 720 ? day : calendar.date(byAdding: .day, value: 1, to: day) ?? day
        return windowSpan(window, on: startDay, in: zone)
    }
    static func windowSpan(_ window: TravelPlan.Window, on day: Date, in zone: TimeZone) -> [Double] {
        let calendar = Calendar.gregorianUTC(zone)
        let endDay = window.endMinute <= window.startMinute ? calendar.date(byAdding: .day, value: 1, to: day) ?? day : day
        return [resolve(window.startMinute, on: day, in: zone).date.timeIntervalSince1970,
                resolve(window.endMinute, on: endDay, in: zone).date.timeIntervalSince1970]
    }
    static func input(trip: TravelTrip, summary: TravelPlan.Summary, originCoordinate: Coordinate?,
                      destinationCoordinate: Coordinate?, reference: Date, marks: Bool) -> TravelNightsInput {
        let origin = TimeZone(identifier: trip.originTimeZoneID) ?? .gmt
        let destination = TimeZone(identifier: trip.destinationTimeZoneID) ?? .gmt
        let home = Calendar.gregorianUTC(origin)
        let there = Calendar.gregorianUTC(destination)
        let departureDay = home.startOfDay(for: trip.departure)
        let prep = summary.rows.map { row -> TravelNightsInput.Prep in
            let day = home.date(byAdding: .day, value: row.relativeDay, to: departureDay) ?? departureDay
            let night = frame(on: day, in: origin)
            let sleepDay = home.date(byAdding: .day, value: row.sleepDayOffset, to: day) ?? day
            let wakeDay = home.date(byAdding: .day, value: row.wakeDayOffset, to: day) ?? day
            let sleep = resolve(row.sleepMinute, on: sleepDay, in: origin)
            let wake = resolve(row.wakeMinute, on: wakeDay, in: origin)
            let checks = TravelScheduleRow.Checks(nonexistentTime: sleep.missing || wake.missing,
                repeatedTime: sleep.repeated || wake.repeated,
                overlapsDeparture: sleep.date.timeIntervalSince1970 >= trip.departureUnix || wake.date.timeIntervalSince1970 > trip.departureUnix,
                elapsedSleepMinutes: wake.date.timeIntervalSince(sleep.date) / 60)
            return .init(date: night.date, start: night.start, end: night.end, shiftMinutes: row.shiftMinutes,
                sleep: [sleep.date.timeIntervalSince1970, wake.date.timeIntervalSince1970],
                seek: row.light?.seek.map { prepWindow($0, on: day, in: origin) },
                avoid: row.light?.avoid.map { prepWindow($0, on: day, in: origin) }, avoidKind: row.light?.avoidKind, checks: checks)
        }
        let arrivalDay = there.startOfDay(for: trip.arrival)
        let last = summary.targetShiftMinutes == 0 ? 0 : summary.arrivalRows.last?.dayAfterArrival ?? 0
        let after = (0...max(0, min(last, 31))).map { k -> TravelNightsInput.After in
            let day = there.date(byAdding: .day, value: k, to: arrivalDay) ?? arrivalDay
            let night = frame(on: day, in: destination)
            let sleepDay = trip.sleepMinute >= 720 ? day : there.date(byAdding: .day, value: 1, to: day) ?? day
            let wakeDay = trip.wakeMinute <= trip.sleepMinute ? there.date(byAdding: .day, value: 1, to: sleepDay) ?? sleepDay : sleepDay
            let sleep = resolve(trip.sleepMinute, on: sleepDay, in: destination)
            let wake = resolve(trip.wakeMinute, on: wakeDay, in: destination)
            return .init(date: night.date, start: night.start, end: night.end, k: k,
                sleep: [sleep.date.timeIntervalSince1970, wake.date.timeIntervalSince1970],
                remainingMinutes: summary.arrivalRows.first(where: { $0.dayAfterArrival == k })?.remainingMinutes ?? 0,
                checks: .init(nonexistentTime: sleep.missing || wake.missing, repeatedTime: sleep.repeated || wake.repeated,
                    overlapsDeparture: false, elapsedSleepMinutes: wake.date.timeIntervalSince(sleep.date) / 60))
        }
        let windows = summary.arrivalRows.flatMap { row -> [TravelNightsInput.Window] in
            let day = there.date(byAdding: .day, value: row.dayAfterArrival, to: arrivalDay) ?? arrivalDay
            var values: [TravelNightsInput.Window] = []
            if let seek = row.seek { values.append(.init(day: row.dayAfterArrival, kind: "seek", span: windowSpan(seek, on: day, in: destination), avoidKind: nil)) }
            if let avoid = row.avoid { values.append(.init(day: row.dayAfterArrival, kind: "avoid", span: windowSpan(avoid, on: day, in: destination), avoidKind: row.avoidKind)) }
            return values
        }
        var arrivalNight = frame(containing: trip.arrival, in: destination)
        let arrivalNoon = Date(timeIntervalSince1970: arrivalNight.start)
        let sleepDay = trip.sleepMinute >= 720 ? arrivalNoon : there.date(byAdding: .day, value: 1, to: arrivalNoon) ?? arrivalNoon
        let wakeDay = trip.wakeMinute <= trip.sleepMinute ? there.date(byAdding: .day, value: 1, to: sleepDay) ?? sleepDay : sleepDay
        let sleeping = resolve(trip.sleepMinute, on: sleepDay, in: destination)
        let waking = resolve(trip.wakeMinute, on: wakeDay, in: destination)
        arrivalNight.sleep = [sleeping.date.timeIntervalSince1970, waking.date.timeIntervalSince1970]
        arrivalNight.checks = .init(nonexistentTime: sleeping.missing || waking.missing,
            repeatedTime: sleeping.repeated || waking.repeated, overlapsDeparture: false,
            elapsedSleepMinutes: waking.date.timeIntervalSince(sleeping.date) / 60)
        return .init(origin: originCoordinate, destination: destinationCoordinate, departure: trip.departureUnix, arrival: trip.arrivalUnix,
            reference: reference.timeIntervalSince1970, marks: marks, departureDate: civilDate(trip.departure, in: origin),
            arrivalDate: civilDate(trip.arrival, in: destination), prep: summary.targetShiftMinutes == 0 ? [] : prep,
            departureNight: frame(containing: trip.departure, in: origin), arrivalNight: arrivalNight,
            after: after, windows: windows)
    }
}

@MainActor
final class TravelNightsMemo {
    struct Art {
        let ribbon: CGImage?
        let line: CGImage?
    }
    private struct Key: Equatable {
        let trip: TravelTrip
        let origin: Coordinate?
        let destination: Coordinate?
        let marks: Bool
    }
    private var key: Key?
    private var boundary: String?
    private var input: TravelNightsInput?
    private(set) var plan: TravelPlan?
    private(set) var nights = TravelNights.empty
    private(set) var art: [[Art]] = []
    private(set) var computations = 0
    private(set) var revision = 0

    func update(trip: TravelTrip, origin: Coordinate?, destination: Coordinate?, reference: Date, marks: Bool, knownPlan: TravelPlan? = nil) {
        let next = Key(trip: trip, origin: origin, destination: destination, marks: marks)
        if key != next {
            let changedTrip = key?.trip != trip
            key = next
            if changedTrip || plan == nil { plan = knownPlan ?? trip.plan() }
            guard let summary = plan?.summary else { nights = .empty; art = []; input = nil; return }
            input = TravelNightFacts.input(trip: trip, summary: summary, originCoordinate: origin,
                destinationCoordinate: destination, reference: reference, marks: marks)
            boundary = nil
        }
        guard var facts = input else { return }
        let moment = reference.timeIntervalSince1970
        let bucket = Self.boundary(for: moment, input: facts)
        if boundary != bucket {
            boundary = bucket
            facts.reference = moment
            input = facts
            nights = (try? RustCore.attempt("travel.nights", facts, as: TravelNights.self)) ?? .empty
            art = nights.lanes.map { lane in lane.parts.map { part in
                Art(ribbon: SkyStripMemo.ribbonImage(part.stops, width: 720), line: SkyStripMemo.ribbonImage(part.lineStops, width: 720))
            } }
            computations += 1
            revision += 1
        } else {
            for index in nights.lanes.indices { nights.lanes[index].reference = nil }
            for index in nights.lanes.indices {
                let lane = nights.lanes[index]
                if lane.kind == "flight", moment >= facts.departure, moment < facts.arrival {
                    let lower = lane.air.first?.first ?? 0
                    let upper = lane.air.last?.last ?? 1
                    nights.lanes[index].reference = lower + (moment - facts.departure) / max(1, facts.arrival - facts.departure) * (upper - lower)
                    break
                }
                for part in lane.parts {
                    let night: TravelNightsInput.Night
                    if lane.kind == "flight" { night = part.place == "origin" ? facts.departureNight : facts.arrivalNight }
                    else if let day = TravelNightFacts.date(lane.date, in: TimeZone(identifier: part.place == "origin" ? trip.originTimeZoneID : trip.destinationTimeZoneID) ?? .gmt) {
                        night = TravelNightFacts.frame(on: day, in: TimeZone(identifier: part.place == "origin" ? trip.originTimeZoneID : trip.destinationTimeZoneID) ?? .gmt)
                    } else { continue }
                    let position = (moment - night.start) / (night.end - night.start)
                    if position >= part.from && position < part.to { nights.lanes[index].reference = position; break }
                }
                if nights.lanes[index].reference != nil { break }
            }
        }
    }
    private static func boundary(for moment: Double, input: TravelNightsInput) -> String {
        if moment >= input.departure && moment < input.arrival { return "flight" }
        if let row = input.prep.first(where: { moment >= $0.start && moment < min($0.end, input.departure) }) { return "prep" + row.date }
        if moment >= input.departureNight.start, moment < input.departure { return "departure" + input.departureNight.date }
        if moment >= input.arrival, moment >= input.arrivalNight.start, moment < input.arrivalNight.end { return "arrival" + input.arrivalNight.date }
        if let row = input.after.first(where: { moment >= max($0.start, input.arrival) && moment < $0.end }) { return "after" + row.date }
        return moment < input.departureNight.start ? "before" : "outside"
    }
}
