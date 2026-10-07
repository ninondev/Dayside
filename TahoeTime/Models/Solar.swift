// SPDX-License-Identifier: GPL-3.0-only
// Foundation adapter: system civil dates/tzdb in, Rust NOAA results out.
import Foundation

enum Solar: Sendable {
    enum Daylight: Sendable, Equatable {
        case interval(sunrise: Double, sunset: Double), polarDay, polarNight
        init(_ value: MTSolarResult) {
            switch value.kind {
            case 1: self = .polarDay
            case 2: self = .polarNight
            default: self = .interval(sunrise: value.sunrise, sunset: value.sunset)
            }
        }
        var raw: MTSolarResult {
            switch self {
            case .interval(let sunrise, let sunset): return MTSolarResult(sunrise: sunrise, sunset: sunset, kind: 0)
            case .polarDay: return MTSolarResult(sunrise: 0, sunset: 1, kind: 1)
            case .polarNight: return MTSolarResult(sunrise: 0, sunset: 0, kind: 2)
            }
        }
    }
    static func fractionOfDay(_ date: Date, in tz: TimeZone) -> Double { localComponents(date, in: tz).fraction }
    static func localDayIndex(_ date: Date, in tz: TimeZone) -> Int { localComponents(date, in: tz).dayIndex }
    static func localComponents(_ date: Date, in tz: TimeZone) -> (dayIndex: Int, fraction: Double) {
        let value = mt_local_components(date.timeIntervalSince1970, Int32(tz.secondsFromGMT(for: date)))
        return (Int(value.day), value.fraction)
    }
    static func date(forFractionOfDay frac: Double, on date: Date, in tz: TimeZone) -> Date {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let start = cal.startOfDay(for: date)
        let minutes = Int(mt_solar_minute(frac))
        return cal.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: start)
            ?? start.addingTimeInterval(frac * 86_400)
    }
    static func daylightFraction(on date: Date, lat: Double, lon: Double, timeZone tz: TimeZone,
                                 dayIndex: Int? = nil) -> Daylight {
        SolarCache.shared.daylight(lat: lat, lon: lon, tz: tz, on: date, dayIndex: dayIndex)
    }
    static func computeDaylightFraction(on date: Date, lat: Double, lon: Double, timeZone tz: TimeZone) -> Daylight {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let c = cal.dateComponents([.year, .month, .day], from: date)
        guard let year = c.year, let month = c.month, let day = c.day else { return .interval(sunrise: 0.25, sunset: 0.75) }
        let noon = cal.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date
        return Daylight(mt_solar_compute(Int32(year), Int32(month), Int32(day), lat, lon, Int32(tz.secondsFromGMT(for: noon))))
    }
}

/// Host handles local formatting; Rust owns the bounded result caches.
final class SolarCache: Sendable {
    static let shared = SolarCache()
    func daylight(lat: Double, lon: Double, tz: TimeZone, on date: Date, dayIndex: Int? = nil) -> Solar.Daylight {
        let day = Int64(dayIndex ?? Solar.localDayIndex(date, in: tz))
        let zone = Array(tz.identifier.utf8)
        let hit = zone.withUnsafeBufferPointer { mt_solar_cached(lat, lon, $0.baseAddress, $0.count, day) }
        if hit.kind >= 0 { return Solar.Daylight(hit) }
        let result = Solar.computeDaylightFraction(on: date, lat: lat, lon: lon, timeZone: tz)
        zone.withUnsafeBufferPointer { mt_solar_store(lat, lon, $0.baseAddress, $0.count, day, result.raw) }
        return result
    }
}
