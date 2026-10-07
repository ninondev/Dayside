// SPDX-License-Identifier: GPL-3.0-only
//
//  PeopleCallBasisTests.swift
//  TahoeTime
//
//  人物行按「上班 / 醒着」判（与地点同一套 CallBasis）：旧人物解码回 .work；醒着基准的人
//  东京周日 21:59 仍醒着、22:00 关窗即在休息时段；上班基准的人 23:00（时段外且已过醒着窗口）
//  补「在休息时段」附注、19:00 不补。判定走视图用的同一个 callStatus。
//

import Foundation
import Testing
@testable import TahoeTime

@MainActor
struct PeopleCallBasisTests {

    // MARK: 旧数据升级

    /// 旧存档没有 callBasis 字段：解码回 .work，升级无感；写了 "awake" 的照读。
    @Test func personWithoutCallBasisDecodesToWork() throws {
        let json = """
        {"id": "6EC7A1B0-8E1A-4E5C-9C0B-0000000000A1", "name": "Ana", "timeZoneID": "Asia/Tokyo",
         "schedule": {"startMinute": 540, "endMinute": 1080, "workingWeekdays": [2, 3, 4, 5, 6]},
         "vacations": []}
        """
        let person = try JSONDecoder().decode(PersonProfile.self, from: Data(json.utf8))
        #expect(person.callBasis == .work)

        let awakeJSON = """
        {"id": "6EC7A1B0-8E1A-4E5C-9C0B-0000000000A2", "name": "Bo", "timeZoneID": "Asia/Tokyo",
         "schedule": {"startMinute": 540, "endMinute": 1080, "workingWeekdays": [2, 3, 4, 5, 6]},
         "vacations": [], "callBasis": "awake"}
        """
        #expect(try JSONDecoder().decode(PersonProfile.self, from: Data(awakeJSON.utf8)).callBasis == .awake)
    }

    // MARK: 醒着基准

    /// 2026-01-04 是周日：醒着窗口不看周末，东京 21:59 仍在窗内（差一分钟关窗），22:00 即在休息时段。
    @Test func awakeBasisShowsAwakeLateOnSundayAndRestingAtClose() throws {
        let person = Self.person(.awake)
        let window = Availability(startMinute: 480, endMinute: 1320, weekdaysOnly: false)
        let sunday2159 = try #require(Self.tokyo.date(from: DateComponents(year: 2026, month: 1, day: 4, hour: 21, minute: 59)))
        #expect(Self.tokyo.component(.weekday, from: sunday2159) == 1)
        #expect(person.callStatus(at: sunday2159, places: [], awakeWindow: window) == .awake)
        let sunday2200 = try #require(Self.tokyo.date(from: DateComponents(year: 2026, month: 1, day: 4, hour: 22)))
        #expect(person.callStatus(at: sunday2200, places: [], awakeWindow: window) == .resting)
    }

    // MARK: 上班基准的附注

    /// 2026-01-05 是周一（默认 9–18 上班）：23:00 是「工作时段外」且已过醒着窗口，补附注；19:00 同样
    /// 时段外但还醒着，不补。
    @Test func workBasisOutsideHoursCarriesRestingNoteOnlyPastBedtime() throws {
        let person = Self.person(.work)
        let window = Availability(startMinute: 480, endMinute: 1320, weekdaysOnly: false)
        let monday2300 = try #require(Self.tokyo.date(from: DateComponents(year: 2026, month: 1, day: 5, hour: 23)))
        #expect(Self.tokyo.component(.weekday, from: monday2300) == 2)
        #expect(person.callStatus(at: monday2300, places: [], awakeWindow: window) == .outsideHours(restingNote: true))
        let monday1900 = try #require(Self.tokyo.date(from: DateComponents(year: 2026, month: 1, day: 5, hour: 19)))
        #expect(person.callStatus(at: monday1900, places: [], awakeWindow: window) == .outsideHours(restingNote: false))
    }

    @Test func restingPrecedesAnActiveShiftAndVacationPrecedesResting() throws {
        var person = Self.person(.work)
        person.schedule = PeopleWorkSchedule(startMinute: 1200, endMinute: 120, workingWeekdays: [2])
        let window = Availability(startMinute: 480, endMinute: 1320, weekdaysOnly: false)
        let awake = try #require(Self.tokyo.date(from: DateComponents(year: 2026, month: 1, day: 5, hour: 21)))
        let resting = try #require(Self.tokyo.date(from: DateComponents(year: 2026, month: 1, day: 5, hour: 23)))
        #expect(person.callStatus(at: awake, places: [], awakeWindow: window) == .working)
        let work = person.workStatus(at: resting, places: [])
        #expect(work == .working, "工作细节仍保留夜班的实际状态")
        #expect(person.callStatus(at: resting, places: [], awakeWindow: window, workStatus: work) == .resting)
        #expect(person.callStatus(at: resting, places: [], awakeWindow: window) == .resting)
        person.vacations = [PeopleVacation(startDate: "2026-01-05", endDate: "2026-01-05")]
        #expect(person.callStatus(at: resting, places: [], awakeWindow: window) == .vacation)
    }

    private static func person(_ basis: CallBasis) -> PersonProfile {
        var person = PersonProfile(name: "Ana", timeZoneID: "Asia/Tokyo")
        person.callBasis = basis
        return person
    }

    /// 固定东京的历法：没有夏令时，分钟数才是整的。
    private static let tokyo: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }()
}
