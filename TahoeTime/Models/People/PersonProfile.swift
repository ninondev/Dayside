// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct PeopleWorkSchedule: Codable, Hashable, Sendable {
    var startMinute = 540
    var endMinute = 1080
    /// Foundation weekdays: Sunday = 1. An empty list is a deliberate week off.
    var workingWeekdays = [2, 3, 4, 5, 6]
}

struct PeopleVacation: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    /// Inclusive Gregorian dates in the person's timezone, independent of this Mac's timezone.
    var startDate: String
    var endDate: String
}

struct PersonProfile: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    /// A snapshot survives removal of the linked place; an existing place takes precedence.
    var timeZoneID: String
    var placeID: UUID?
    var countryCode: String?
    var contactIdentifier: String?
    var schedule = PeopleWorkSchedule()
    var vacations: [PeopleVacation] = []
    /// 「能打给谁」按哪个时段判（与地点同一套 CallBasis，只管人物行的状态显示）：
    /// .work = 工作作息（默认，旧存档没有这字段）；.awake = 全局醒着窗口。排会与提醒仍看工作作息。
    var callBasis: CallBasis = .work
    /// 绑定地点的时区显示规则快照；地点删掉后仍能生成原来的时区说明。旧人物缺省为 nil。
    var offsetOnlyZoneName: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case id, name, timeZoneID, placeID, countryCode, contactIdentifier, schedule, vacations, callBasis, offsetOnlyZoneName
    }

    func resolvedTimeZoneID(places: [TimeZoneEntry]) -> String {
        places.first(where: { $0.id == placeID })?.timezoneID ?? timeZoneID
    }

    mutating func bind(to place: TimeZoneEntry) {
        placeID = place.id
        timeZoneID = place.timezoneID
        countryCode = place.countryCode
        offsetOnlyZoneName = place.offsetOnlyZoneName ? true : nil
    }

    mutating func choose(_ option: ZoneOption) {
        placeID = nil
        timeZoneID = option.identifier
        countryCode = option.countryCode.isEmpty ? nil : option.countryCode
        offsetOnlyZoneName = ZoneNameDisplay.offsetOnly(identifier: option.identifier, code: option.countryCode,
            admin: option.adminRegion, city: option.cityName, coordinate: option.coordinate) ? true : nil
    }

    func plannerParticipant(places: [TimeZoneEntry]) -> OverlapPlanner.Participant {
        let place = places.first { $0.id == placeID }
        return OverlapPlanner.Participant(
            id: id, name: name, timeZoneID: place?.timezoneID ?? timeZoneID,
            availability: Availability(startMinute: schedule.startMinute,
                                       endMinute: schedule.endMinute == 0 ? 1440 : schedule.endMinute,
                                       weekdaysOnly: false),
            countryCode: place?.countryCode ?? countryCode,
            workingWeekdays: schedule.workingWeekdays,
            vacations: vacations.map { OverlapPlanner.Vacation(startDate: $0.startDate, endDate: $0.endDate) },
            coordinate: place?.coordinate ?? ZoneCatalog.shared.knownCoordinate(for: place?.timezoneID ?? timeZoneID),
            offsetOnlyZoneName: place?.offsetOnlyZoneName ?? offsetOnlyZoneName ?? false)
    }

    func workStatus(at date: Date, places: [TimeZoneEntry]) -> PeopleWorkStatus {
        let identifier = resolvedTimeZoneID(places: places)
        let zone = TimeZone(identifier: identifier)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone ?? .gmt
        let previous = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: date)) ?? date
        let parts = calendar.dateComponents([.hour, .minute, .weekday], from: date)
        struct Facts: Encodable {
            let timeZoneValid: Bool
            let date: String
            let previousDate: String
            let minute: Int
            let weekday: Int
        }
        struct Input: Encodable { let person: PersonProfile; let facts: Facts }
        let result: String = RustCore.invoke("people.status", Input(person: self, facts: Facts(
            timeZoneValid: zone != nil, date: Self.civilDate(date, calendar: calendar),
            previousDate: Self.civilDate(previous, calendar: calendar),
            minute: (parts.hour ?? 0) * 60 + (parts.minute ?? 0), weekday: parts.weekday ?? 1)))
        return PeopleWorkStatus(rawValue: result) ?? .unknown
    }

    static func civilDate(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1, parts.month ?? 1, parts.day ?? 1)
    }
}

enum PeopleWorkStatus: String, Codable, Sendable {
    case working, outsideHours, dayOff, vacation, unknown
}

/// 人物行右下角最终显示的状态（callBasis 参与判定后的结果）。PeopleWorkStatus 保持五态不动：
/// 它是 Rust `people.status` 的线上格式，别处也在比较它，不能为了显示加 case。
enum PersonCallStatus: Equatable, Sendable {
    case working
    /// 上班基准的「工作时段外 / 休息日」：当地已超出醒着窗口时补一句「在休息时段」。
    case outsideHours(restingNote: Bool)
    case dayOff(restingNote: Bool)
    case vacation
    case unknown
    /// 醒着基准：醒着窗口内 / 外。
    case awake
    case resting
}

// 宽容解码 + 克制编码（写在扩展里保留成员构造器）：旧存档没有 callBasis 回 .work；
// 「醒着」之外不编码，上班基准的人物与旧版逐字相同（存档经 Rust 归一，名片等编码路径也一致）。
extension PersonProfile {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        timeZoneID = try c.decode(String.self, forKey: .timeZoneID)
        placeID = try c.decodeIfPresent(UUID.self, forKey: .placeID)
        countryCode = try c.decodeIfPresent(String.self, forKey: .countryCode)
        contactIdentifier = try c.decodeIfPresent(String.self, forKey: .contactIdentifier)
        schedule = try c.decode(PeopleWorkSchedule.self, forKey: .schedule)
        vacations = try c.decode([PeopleVacation].self, forKey: .vacations)
        callBasis = try c.decodeIfPresent(CallBasis.self, forKey: .callBasis) ?? .work
        offsetOnlyZoneName = try? c.decodeIfPresent(Bool.self, forKey: .offsetOnlyZoneName)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(timeZoneID, forKey: .timeZoneID)
        try c.encodeIfPresent(placeID, forKey: .placeID)
        try c.encodeIfPresent(countryCode, forKey: .countryCode)
        try c.encodeIfPresent(contactIdentifier, forKey: .contactIdentifier)
        try c.encode(schedule, forKey: .schedule)
        try c.encode(vacations, forKey: .vacations)
        if callBasis == .awake { try c.encode(callBasis, forKey: .callBasis) }
        if offsetOnlyZoneName == true { try c.encode(true, forKey: .offsetOnlyZoneName) }
    }
}

extension PersonProfile {
    /// 行右下角的状态（判定基准 = callBasis，视图与测试共用这一个出口）。上班基准沿用五种工作
    /// 状态；醒着基准除休假 / 时区不可用外只看全局醒着窗口（与地点「现在能打给谁」同一个判定函数）。
    /// 日条与提醒仍走 workStatus 的上班作息，不看这里。
    func callStatus(at date: Date, places: [TimeZoneEntry], awakeWindow: Availability,
                    workStatus: PeopleWorkStatus? = nil) -> PersonCallStatus {
        let work = workStatus ?? self.workStatus(at: date, places: places)
        if callBasis == .awake, work != .vacation, work != .unknown {
            return insideAwakeWindow(at: date, places: places, window: awakeWindow) ? .awake : .resting
        }
        let resting = (work == .working || work == .outsideHours || work == .dayOff)
            && !insideAwakeWindow(at: date, places: places, window: awakeWindow)
        switch work {
        case .working: return resting ? .resting : .working
        case .outsideHours: return .outsideHours(restingNote: resting)
        case .dayOff: return .dayOff(restingNote: resting)
        case .vacation: return .vacation
        case .unknown: return .unknown
        }
    }

    /// 当地此刻是否在醒着窗口内（窗口可跨午夜、按国家周末规则）；时区解析不出时按不在窗内。
    private func insideAwakeWindow(at date: Date, places: [TimeZoneEntry], window: Availability) -> Bool {
        guard let zone = TimeZone(identifier: resolvedTimeZoneID(places: places)) else { return false }
        let country = places.first { $0.id == placeID }?.countryCode ?? countryCode
        return PlaceCallability.compute(timeZone: zone, now: date, countryCode: country, window: window).isCallable
    }
}
