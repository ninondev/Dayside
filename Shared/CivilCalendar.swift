// SPDX-License-Identifier: GPL-3.0-only
import Foundation

extension Calendar {
    static func gregorianUTC(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
}
