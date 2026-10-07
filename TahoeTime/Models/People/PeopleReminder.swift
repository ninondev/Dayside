// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// 「对方上班时提醒我」（人物 → 计时器）：按人物所在地的时区、工作日与假期，
/// 找接下来 14 天里第一个上班时刻；一周都不上班或全在休假就没有。
enum PeopleReminder {
    static func nextWorkStart(for person: PersonProfile, places: [TimeZoneEntry], now: Date) -> Date? {
        guard let zone = TimeZone(identifier: person.resolvedTimeZoneID(places: places)) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = zone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        var day = calendar.startOfDay(for: now)
        for _ in 0..<14 {
            let key = formatter.string(from: day)
            let onVacation = person.vacations.contains { $0.startDate <= key && key <= $0.endDate }
            if person.schedule.workingWeekdays.contains(calendar.component(.weekday, from: day)), !onVacation,
               let start = calendar.date(byAdding: .minute, value: person.schedule.startMinute, to: day), start > now {
                return start
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            day = next
        }
        return nil
    }
}
