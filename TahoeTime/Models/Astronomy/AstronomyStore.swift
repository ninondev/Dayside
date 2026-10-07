// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Observation

nonisolated struct AstronomyInterval: Decodable, Equatable, Identifiable, Sendable {
    let start: Double
    let end: Double
    var id: Double { start }
}

nonisolated struct AstronomySample: Codable, Equatable, Identifiable, Sendable {
    let instant: Double
    let elevation: Double
    var id: Double { instant }
}

nonisolated struct AstronomySolar: Decodable, Equatable, Sendable {
    let kind: String
    let daylightSeconds: Double
    let sunrise: Double?
    let sunset: Double?
    let solarNoon: Double?
    let golden: [AstronomyInterval]
    let samples: [AstronomySample]
}

nonisolated struct AstronomyMoon: Decodable, Equatable, Sendable {
    let instant: Double
    let phase: String
    let cycle: Double
    let illumination: Double
    let ageDays: Double?
    let nextNewMoon: Double?
    let nextFullMoon: Double?
}

nonisolated struct AstronomyTrendDay: Decodable, Equatable, Sendable {
    let daylightSeconds: Double
    let daylightChangeSeconds: Double?
    let sunrise: Double?
    let sunset: Double?
    let kind: String
}

/// 昼长变化：今天比昨天长 / 短多少，日出日落各挪了几分钟（当地墙钟），下一次至日是哪天、那天日照多长。
/// 天文在 Rust（`astronomy.trend` 逐日算日照，`astronomy.seasons` 二分视黄经过 90° / 270°），这里只出民用日边界与墙钟。
nonisolated struct AstronomyTrend: Equatable, Sendable {
    let daylightChangeSeconds: Double
    let sunriseShiftMinutes: Int?
    let sunsetShiftMinutes: Int?
    let solsticeDay: Date
    let solsticeDaysAway: Int
    let solsticeDaylightSeconds: Double
    let solsticeIsLongest: Bool
}

nonisolated struct AstronomyResult: Decodable, Equatable, Sendable {
    let available: Bool
    let error: String?
    let dayStart: Double?
    let dayEnd: Double?
    let solar: AstronomySolar?
    let moon: AstronomyMoon?
}

/// Native calendar/tzdb adapter. All astronomy and interval mathematics run in
/// Rust. It is deliberately inert until the user opens this lens or changes a field.
@MainActor @Observable
final class AstronomyStore {
    private(set) var result: AstronomyResult?
    private(set) var trend: AstronomyTrend?
    private(set) var error: String?
    private(set) var selectedZone: TimeZoneEntry?
    private(set) var selectedDate: Date?
    /// 面板行右键「在太阳与月亮里查看」要看的地点：页面出现或它变化时接过去并清空。
    var requestedZoneID: UUID?
    private(set) var computationCount = 0
    var activeResourceCount: Int { 0 }

    init() {}

    /// 某一年某个节气在指定时区的民用日（`YYYY-MM-DD`）：黄经 0° 春分、15° 清明、180° 秋分。
    /// 算在 Rust（`astronomy.solar_term` 二分视黄经），这里只把那一刻换成该地的民用日。
    /// 市场时钟用它填日本的春分の日 / 秋分の日 与中港的清明。
    static func solarTermDate(year: Int, longitude: Double, timeZoneID: String) -> String? {
        guard let zone = TimeZone(identifier: timeZoneID) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        guard let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) else { return nil }
        struct Output: Decodable { let available: Bool; let instant: Double? }
        struct Input: Encodable { let instant: Double; let longitude: Double; let days: Double }
        let output: Output = RustCore.invoke("astronomy.solar_term",
                                             Input(instant: start.timeIntervalSince1970,
                                                   longitude: longitude, days: 400))
        guard output.available, let instant = output.instant else { return nil }
        let parts = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: instant))
        guard let y = parts.year, y == year, let m = parts.month, let d = parts.day else { return nil }
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    func compute(zone: TimeZoneEntry, on date: Date) {
        selectedZone = zone
        selectedDate = date
        guard let coordinate = zone.coordinate else {
            result = nil
            error = "missingCoordinates"
            return
        }
        guard coordinate.latitude.isFinite, coordinate.longitude.isFinite else {
            result = nil
            error = "invalidCoordinates"
            return
        }
        guard let timeZone = TimeZone(identifier: zone.timezoneID),
              (-5_364_662_400.0..<4_133_980_800.0).contains(date.timeIntervalSince1970) else {
            result = nil
            error = "unsupportedDate"
            return
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let day = calendar.dateInterval(of: .day, for: date),
              let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: date) else {
            result = nil
            error = "unsupportedDate"
            return
        }
        struct Input: Encodable {
            let dayStart: Double
            let dayEnd: Double
            let instant: Double
            let latitude: Double
            let longitude: Double
        }
        let value: AstronomyResult = RustCore.invoke("astronomy.compute", Input(
            dayStart: day.start.timeIntervalSince1970, dayEnd: day.end.timeIntervalSince1970,
            instant: noon.timeIntervalSince1970, latitude: coordinate.latitude, longitude: coordinate.longitude))
        computationCount += 1
        result = value
        error = value.error
        trend = value.available ? Self.trend(calendar: calendar, day: day, latitude: coordinate.latitude, longitude: coordinate.longitude) : nil
    }

    /// 昨天、今天、下一次至日那天各算一次日照；至日从今天零点起找（今天就是至日时也算），是最长还是最短的一天由数字说了算：
    /// 至日那天的日照不短于今天就是最长（今天就是至日时与昨天比）。日出日落的挪动按当地墙钟算分钟——换钟那天墙钟跳一小时，
    /// 用户看到的就是跳一小时，不按真实流逝的秒数。
    private static func trend(calendar: Calendar, day: DateInterval, latitude: Double, longitude: Double) -> AstronomyTrend? {
        guard let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: day.start),
              let yesterday = calendar.dateInterval(of: .day, for: yesterdayStart) else { return nil }
        struct Season: Decodable { let instant: Double; let kind: String }
        struct Seasons: Decodable { let available: Bool; let events: [Season]? }
        let seasons: Seasons = RustCore.invoke("astronomy.seasons", ["instant": day.start.timeIntervalSince1970])
        guard seasons.available, let solstice = seasons.events?.first(where: { $0.kind.hasSuffix("Solstice") }),
              let solsticeDay = calendar.dateInterval(of: .day, for: Date(timeIntervalSince1970: solstice.instant)) else { return nil }
        struct Day: Encodable { let dayStart: Double; let dayEnd: Double }
        struct Input: Encodable { let latitude: Double; let longitude: Double; let days: [Day] }
        struct Output: Decodable { let available: Bool; let days: [AstronomyTrendDay]? }
        let bounds = [yesterday, day, solsticeDay].map { Day(dayStart: $0.start.timeIntervalSince1970, dayEnd: $0.end.timeIntervalSince1970) }
        let output: Output = RustCore.invoke("astronomy.trend", Input(latitude: latitude, longitude: longitude, days: bounds))
        guard output.available, let days = output.days, days.count == 3, let change = days[1].daylightChangeSeconds else { return nil }
        func wallMinutes(_ unix: Double?) -> Int? {
            guard let unix else { return nil }
            let parts = calendar.dateComponents([.hour, .minute, .second], from: Date(timeIntervalSince1970: unix))
            guard let hour = parts.hour, let minute = parts.minute, let second = parts.second else { return nil }
            return Int((Double(hour * 60 + minute) + Double(second) / 60).rounded())
        }
        func shift(_ today: Double?, _ before: Double?) -> Int? {
            guard let today = wallMinutes(today), let before = wallMinutes(before) else { return nil }
            return today - before
        }
        let daysAway = calendar.dateComponents([.day], from: day.start, to: solsticeDay.start).day ?? 0
        let longest = daysAway == 0 ? days[1].daylightSeconds >= days[0].daylightSeconds : days[2].daylightSeconds >= days[1].daylightSeconds
        return AstronomyTrend(daylightChangeSeconds: change,
                              sunriseShiftMinutes: shift(days[1].sunrise, days[0].sunrise),
                              sunsetShiftMinutes: shift(days[1].sunset, days[0].sunset),
                              solsticeDay: solsticeDay.start, solsticeDaysAway: daysAway,
                              solsticeDaylightSeconds: days[2].daylightSeconds, solsticeIsLongest: longest)
    }

    func clear() { result = nil; trend = nil; error = nil; selectedZone = nil; selectedDate = nil }
    func deactivate() { clear() }
}
