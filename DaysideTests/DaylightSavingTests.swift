// SPDX-License-Identifier: GPL-3.0-only
//
//  DaylightSavingTests.swift
//  DaysideTests
//
//  夏令时与各类"特殊时间"的回归护栏。
//
//  时钟本身的偏移由系统 tzdata 决定,App 不自己算——所以这里钉的不是"我们算得对不对",
//  而是**我们有没有把它用对**:穿梭到别的日期时用的是那一刻的偏移(而不是此刻的)、
//  半小时/三刻钟偏移不被抹平、太阳算法在 23 小时和 25 小时的日子里不整体错一格。
//
//  太阳侧尤其危险:一旦退回"按查询时刻取偏移"或"按 86400 秒换算",
//  换轨日的日出日落会整体偏一个切换步长,而且**只在一年两天出现**,人工很难撞见
//  (就是这么漏掉的)。
//

import XCTest
@testable import Dayside

final class DaylightSavingTests: XCTestCase {

    private func date(_ iso: String) throws -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return try XCTUnwrap(f.date(from: iso), "无法解析 \(iso)")
    }

    private func zone(_ id: String) throws -> TimeZone {
        try XCTUnwrap(TimeZone(identifier: id), "系统不认得时区 \(id)")
    }

    // MARK: - 偏移本身

    /// 北半球与南半球的换轨方向相反,别把其中一个写死。
    func testBothHemispheresSwitchInOppositeDirections() throws {
        let newYork = try zone("America/New_York")
        let sydney = try zone("Australia/Sydney")
        let january = try date("2026-01-15T12:00:00Z")
        let july = try date("2026-07-15T12:00:00Z")

        XCTAssertEqual(newYork.secondsFromGMT(for: january), -5 * 3600, "纽约 1 月是标准时")
        XCTAssertEqual(newYork.secondsFromGMT(for: july), -4 * 3600, "纽约 7 月是夏令时")
        XCTAssertEqual(sydney.secondsFromGMT(for: january), 11 * 3600, "悉尼 1 月是夏令时")
        XCTAssertEqual(sydney.secondsFromGMT(for: july), 10 * 3600, "悉尼 7 月是标准时")
    }

    /// 非整小时偏移必须原样保留——把它们当整小时处理会让整个印度差半小时。
    func testFractionalOffsetsSurvive() throws {
        let reference = try date("2026-06-15T12:00:00Z")
        XCTAssertEqual(try zone("Asia/Kolkata").secondsFromGMT(for: reference), 5 * 3600 + 1800)
        XCTAssertEqual(try zone("Asia/Kathmandu").secondsFromGMT(for: reference), 5 * 3600 + 2700)
        XCTAssertEqual(try zone("Pacific/Chatham").secondsFromGMT(for: reference), 12 * 3600 + 2700)
        XCTAssertEqual(try zone("Australia/Eucla").secondsFromGMT(for: reference), 8 * 3600 + 2700)
    }

    /// 豪勋爵岛的夏令时步长是 **30 分钟**,不是一小时——按小时取整会错半小时。
    func testLordHoweUsesHalfHourDaylightStep() throws {
        let lordHowe = try zone("Australia/Lord_Howe")
        let summer = lordHowe.secondsFromGMT(for: try date("2026-01-15T12:00:00Z"))
        let winter = lordHowe.secondsFromGMT(for: try date("2026-07-15T12:00:00Z"))
        XCTAssertEqual(summer - winter, 1800, "换轨步长必须是 30 分钟")
    }

    /// 这些地区已废除夏令时:全年偏移恒定。若哪天上游改了,这条会红,提醒我们跟随 tzdata。
    func testZonesWithoutDaylightSavingStayConstant() throws {
        for id in ["Asia/Tehran", "Asia/Shanghai", "Asia/Tokyo", "Asia/Kolkata"] {
            let tz = try zone(id)
            let january = tz.secondsFromGMT(for: try date("2026-01-15T12:00:00Z"))
            let july = tz.secondsFromGMT(for: try date("2026-07-15T12:00:00Z"))
            XCTAssertEqual(january, july, "\(id) 不该有夏令时切换")
        }
    }

    /// 摩洛哥直到 2026-09-20 都是一年切换两次以上（斋月前后各一次），用「一年最多两次」的假设会漏：2025 年 2 次、
    /// 2026 年 3 次（含 09-20 01:00Z 那次改为常年 UTC+0，tzdata 2026c）、2027 年 0 次。Apple 编的是 rearguard 数据，
    /// 所以摩洛哥的 +01 报成 isDST = true、不会出现负夏令时。
    func testMoroccoTransitionsEndWithThePermanentUTCSwitch() throws {
        let tz = try zone("Africa/Casablanca")
        func count(_ year: Int) throws -> Int {
            var cursor = try date("\(year)-01-01T00:00:00Z")
            let end = try date("\(year + 1)-01-01T00:00:00Z")
            var transitions = 0
            while let next = tz.nextDaylightSavingTimeTransition(after: cursor), next < end {
                transitions += 1
                cursor = next.addingTimeInterval(1)
            }
            return transitions
        }
        XCTAssertEqual(try count(2025), 2, "2025 年斋月前后各一次")
        XCTAssertEqual(try count(2026), 3, "2026 年斋月两次加 09-20 停用夏令时那次")
        XCTAssertEqual(try count(2027), 0, "2027 年起常年 UTC+0")
        XCTAssertEqual(tz.secondsFromGMT(for: try date("2026-10-15T12:00:00Z")), 0)
        XCTAssertTrue(tz.isDaylightSavingTime(for: try date("2026-07-15T12:00:00Z")), "rearguard：+01 报成夏令时")
    }

    // MARK: - 穿梭:必须用"那一刻"的偏移,不是"此刻"的

    /// 从标准时穿梭到夏令时期间,显示的墙钟时间必须按目标时刻的偏移换算。
    func testScrubbingAcrossTransitionUsesTargetOffset() throws {
        let tz = try zone("Europe/Berlin")
        let winter = try date("2026-01-15T12:00:00Z")     // 柏林 13:00(UTC+1)
        let summer = try date("2026-07-15T12:00:00Z")     // 柏林 14:00(UTC+2)
        let format = ClockFormat(hourStyle: .force24, showSeconds: false)
        XCTAssertEqual(TimeFormatting.string(for: winter, in: tz, format: format), "13:00")
        XCTAssertEqual(TimeFormatting.string(for: summer, in: tz, format: format), "14:00")
    }

    /// 秋天重复的那一小时里,同一个 UTC 时刻只能有一个答案,且必须自洽。
    func testRepeatedHourIsStable() throws {
        let tz = try zone("America/New_York")
        let format = ClockFormat(hourStyle: .force24, showSeconds: false)
        // 2026-11-01 05:30Z 与 06:30Z 都落在纽约当地 01:30,前者是 EDT 后者是 EST
        let first = try date("2026-11-01T05:30:00Z")
        let second = try date("2026-11-01T06:30:00Z")
        // 24 小时制在本地 locale 下不补前导零,故是 "1:30" 而非 "01:30"。
        XCTAssertEqual(TimeFormatting.string(for: first, in: tz, format: format),
                       TimeFormatting.string(for: second, in: tz, format: format),
                       "重复的那一小时两次都必须念作同一个墙钟时间")
        XCTAssertTrue(TimeFormatting.string(for: first, in: tz, format: format).hasSuffix("1:30"))
        XCTAssertNotEqual(tz.secondsFromGMT(for: first), tz.secondsFromGMT(for: second),
                          "两次 01:30 的偏移必须不同")
    }

    // MARK: - 太阳侧:换轨日不得整体错一格

    /// 换轨日**当天任何时刻**问日出日落,都必须得到同一个答案。
    /// 退回"按查询时刻取偏移"会让 00:30 与 12:00 得到相差一小时的两个答案,
    /// 而按日缓存会把当天第一次问到的那个答案钉死一整天。
    func testSolarAnswerIsStableThroughoutATransitionDay() throws {
        let cases: [(String, Double, Double, String)] = [
            ("America/New_York", 40.71, -74.01, "2026-11-01"),   // 秋退
            ("America/New_York", 40.71, -74.01, "2026-03-08"),   // 春进
            ("Europe/Berlin", 52.52, 13.40, "2026-03-29"),
            ("Australia/Lord_Howe", -31.55, 159.08, "2026-04-05"),
        ]
        for (id, lat, lon, day) in cases {
            let tz = try zone(id)
            var answers = Set<String>()
            for hour in ["T00:30", "T06:00", "T12:00", "T18:00", "T23:30"] {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = tz
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
                formatter.timeZone = tz
                let moment = try XCTUnwrap(formatter.date(from: day + hour))
                let daylight = Solar.computeDaylightFraction(on: moment, lat: lat, lon: lon, timeZone: tz)
                answers.insert(String(describing: daylight))
            }
            XCTAssertEqual(answers.count, 1, "\(id) \(day):当天不同时刻问出了不同的日出日落")
        }
    }

    /// 换轨日是 23 或 25 小时;把占比换算回时刻若按固定 86400 秒做,会整体偏一格。
    func testFractionToDateLandsOnWallClockAcrossTransition() throws {
        let tz = try zone("America/New_York")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        formatter.timeZone = tz
        let day = try XCTUnwrap(formatter.date(from: "2026-11-01T12:00"))
        // 占比 0.5 应落在当地 12:00 整,不论这天有几个小时
        let midday = Solar.date(forFractionOfDay: 0.5, on: day, in: tz)
        XCTAssertEqual(calendar.component(.hour, from: midday), 12)
        XCTAssertEqual(calendar.component(.minute, from: midday), 0)
    }

    /// 按**城市自己的**坐标算日出日落时,换轨日的自洽性同样必须成立——
    /// 慕尼黑(Europe/Berlin)与柏林是不同的经纬度,不能因为共用时区就退回代表城市。
    func testPerCityCoordinatesRemainConsistentOnTransitionDay() throws {
        let tz = try zone("Europe/Berlin")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        formatter.timeZone = tz
        let munich = (lat: 48.14, lon: 11.58)
        let berlin = (lat: 52.52, lon: 13.40)

        var munichAnswers = Set<String>()
        for hour in ["T00:30", "T12:00", "T23:30"] {
            let moment = try XCTUnwrap(formatter.date(from: "2026-03-29" + hour))
            munichAnswers.insert(String(describing:
                Solar.computeDaylightFraction(on: moment, lat: munich.lat, lon: munich.lon, timeZone: tz)))
        }
        XCTAssertEqual(munichAnswers.count, 1, "慕尼黑在换轨日也必须当天同一个答案")

        let noon = try XCTUnwrap(formatter.date(from: "2026-06-21T12:00"))
        let m = Solar.computeDaylightFraction(on: noon, lat: munich.lat, lon: munich.lon, timeZone: tz)
        let b = Solar.computeDaylightFraction(on: noon, lat: berlin.lat, lon: berlin.lon, timeZone: tz)
        XCTAssertNotEqual(String(describing: m), String(describing: b),
                          "慕尼黑与柏林纬度差 4°,夏至日照长度必须不同——否则说明坐标退回了代表城市")
    }

    /// 高纬度极昼极夜必须仍被正确识别(极地的"特殊时间"更极端)。
    func testPolarConditionsStillDetected() throws {
        let tz = try zone("Arctic/Longyearbyen")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        formatter.timeZone = tz
        let midsummer = try XCTUnwrap(formatter.date(from: "2026-06-21T12:00"))
        let midwinter = try XCTUnwrap(formatter.date(from: "2026-12-21T12:00"))
        XCTAssertEqual(Solar.computeDaylightFraction(on: midsummer, lat: 78.22, lon: 15.65, timeZone: tz),
                       .polarDay)
        XCTAssertEqual(Solar.computeDaylightFraction(on: midwinter, lat: 78.22, lon: 15.65, timeZone: tz),
                       .polarNight)
    }
}
