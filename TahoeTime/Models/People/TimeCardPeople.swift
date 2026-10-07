// SPDX-License-Identifier: GPL-3.0-only
import Foundation

extension PersonProfile {
    /// 把粘贴进来的时间名片（开源侧解出的 `TimeCard.Contact`）变成一个人。
    init(_ contact: TimeCard.Contact) {
        self.init(name: contact.name, timeZoneID: contact.timeZoneID)
        if let start = contact.startMinute, let end = contact.endMinute, let weekdays = contact.workingWeekdays {
            schedule.startMinute = start
            schedule.endMinute = end
            schedule.workingWeekdays = weekdays
        }
    }
}
