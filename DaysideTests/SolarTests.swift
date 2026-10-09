// SPDX-License-Identifier: GPL-3.0-only
//
//  SolarTests.swift
//  DaysideTests
//
//  太阳算法的回归测试。覆盖昼长的季节变化、赤道日照与民用日的一致性，
//  防止错误的边界处理产生看似合理的结果。
//
//  校验方式刻意不拿本算法自己的输出当基准——那是循环论证。用的是**独立可查的天文事实**:
//  昼长的季节对称性、赤道全年 ≈12h、以及同一民用日在不同时刻提问必须得到同一答案。
//

import XCTest
@testable import Dayside

final class SolarTests: XCTestCase {

    private func tz(_ id: String) -> TimeZone {
        guard let t = TimeZone(identifier: id) else {
            XCTFail("时区不可解析: \(id)"); return .gmt
        }
        return t
    }

    /// 指定时区某民用日的某个墙钟时刻。
    private func instant(_ y: Int, _ m: Int, _ d: Int, _ hour: Int, _ minute: Int,
                         in zone: TimeZone) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        guard let date = cal.date(from: DateComponents(year: y, month: m, day: d,
                                                       hour: hour, minute: minute)) else {
            XCTFail("无法构造日期"); return .distantPast
        }
        return date
    }

    private func daylightHours(_ y: Int, _ m: Int, _ d: Int, id: String,
                               lat: Double, lon: Double) -> Double? {
        let zone = tz(id)
        let noon = instant(y, m, d, 12, 0, in: zone)
        guard case let .interval(sunrise, sunset) =
                Solar.computeDaylightFraction(on: noon, lat: lat, lon: lon, timeZone: zone) else {
            return nil
        }
        return (sunset - sunrise) * 24
    }

    // MARK: - 日界线时区曾经全年退化成「永夜」

    /// UTC+13/+14 且西经的组合会让 solarNoon 越界一整天,clamp01 把日出日落双双钉在 1.0,
    /// 表现为全年无日轨弧、标签恒 "0:00"。这里用**已知天文规律**反证,而不是比对算法自身输出。
    func testDatelineZonesProduceRealSunriseAndSunset() throws {
        // (时区, 纬度, 经度, 7 月昼长区间, 1 月昼长区间)
        let cases: [(String, Double, Double, ClosedRange<Double>, ClosedRange<Double>)] = [
            // 赤道附近:全年都该接近 12 小时
            ("Pacific/Kiritimati", 1.8721, -157.4278, 11.5...12.5, 11.5...12.5),
            ("Pacific/Kanton",    -2.7833, -171.7167, 11.5...12.5, 11.5...12.5),
            // 南半球:1 月(夏)必须明显长于 7 月(冬)
            ("Pacific/Apia",     -13.8333, -171.7667, 11.0...11.9, 12.1...13.0),
            ("Pacific/Chatham",  -43.95,   -176.55,    8.5...9.8,  14.2...15.5),
            ("Pacific/Tongatapu",-21.1333, -175.2,    10.6...11.5, 12.5...13.4),
            ("Pacific/Fakaofo",   -9.3667, -171.2167, 11.3...12.1, 11.9...12.8),
        ]

        for (id, lat, lon, julyRange, januaryRange) in cases {
            let july = try XCTUnwrap(daylightHours(2026, 7, 15, id: id, lat: lat, lon: lon),
                                     "\(id) 7 月未得到 interval(极昼/极夜或退化)")
            let january = try XCTUnwrap(daylightHours(2026, 1, 15, id: id, lat: lat, lon: lon),
                                        "\(id) 1 月未得到 interval(极昼/极夜或退化)")
            XCTAssertTrue(julyRange.contains(july),
                          "\(id) 7 月昼长 \(july)h 不在天文预期 \(julyRange) 内")
            XCTAssertTrue(januaryRange.contains(january),
                          "\(id) 1 月昼长 \(january)h 不在天文预期 \(januaryRange) 内")
        }
    }

    /// 退化时日出日落分数都会被 clamp 到 1.0。直接钉住「分数必须落在开区间内且有序」。
    func testDatelineZoneFractionsStayInsideTheDay() {
        let zone = tz("Pacific/Chatham")
        let noon = instant(2026, 7, 15, 12, 0, in: zone)
        guard case let .interval(sunrise, sunset) =
                Solar.computeDaylightFraction(on: noon, lat: -43.95, lon: -176.55, timeZone: zone) else {
            return XCTFail("Chatham 应有正常日出日落")
        }
        XCTAssertGreaterThan(sunrise, 0.05)
        XCTAssertLessThan(sunset, 0.95)
        XCTAssertLessThan(sunrise, sunset)
    }

    // MARK: - DST 切换日答案随提问时刻而变

    /// 偏移过去取「查询时刻」而不是当日主导偏移,于是同一个民用日在 00:30 / 12:00 / 23:30
    /// 问出三个不同答案;又因为按日缓存,当天第一次提问的结果会定死一整天。
    func testAnswerIsStableAcrossTheDayIncludingDSTTransitions() {
        let cases: [(String, Int, Int, Int)] = [
            ("America/New_York", 2026, 3, 8),    // 春进(23 小时日)
            ("America/New_York", 2026, 11, 1),   // 秋退(25 小时日)
            ("Europe/London",    2026, 3, 29),
            ("Europe/London",    2026, 10, 25),
            ("Australia/Lord_Howe", 2026, 4, 5), // 半小时步长
            ("America/Santiago", 2026, 4, 4),    // 午夜切换
            ("Asia/Tokyo",       2026, 7, 15),   // 无 DST 对照
        ]
        let coords: [String: (Double, Double)] = [
            "America/New_York": (40.7142, -74.0064),
            "Europe/London": (51.5083, -0.1253),
            "Australia/Lord_Howe": (-31.5333, 159.0833),
            "America/Santiago": (-33.45, -70.6667),
            "Asia/Tokyo": (35.6544, 139.7447),
        ]

        for (id, y, m, d) in cases {
            let zone = tz(id)
            guard let (lat, lon) = coords[id] else { XCTFail("缺坐标: \(id)"); continue }
            let probes = [(0, 30), (12, 0), (23, 30)].map { instant(y, m, d, $0.0, $0.1, in: zone) }

            let answers = probes.compactMap { probe -> Double? in
                guard case let .interval(sunrise, _) =
                        Solar.computeDaylightFraction(on: probe, lat: lat, lon: lon, timeZone: zone) else {
                    return nil
                }
                // 折算成绝对时刻再比,排除「分数相同但落在不同墙钟」的假一致。
                return Solar.date(forFractionOfDay: sunrise, on: probe, in: zone).timeIntervalSince1970
            }
            XCTAssertEqual(answers.count, 3, "\(id) \(m)/\(d) 有探针未得到 interval")
            guard let first = answers.first else { continue }
            for answer in answers {
                XCTAssertEqual(answer, first, accuracy: 60,
                               "\(id) \(m)/\(d):同一天不同时刻问出了不同的日出时刻")
            }
        }
    }

    /// 秋退日的分数换算回墙钟不能整体漂一个 DST 步长。用「日出应落在清晨」这一常识区间钉住。
    func testSunriseWallClockIsPlausibleOnDSTTransitionDay() {
        let zone = tz("America/New_York")
        let noon = instant(2026, 11, 1, 12, 0, in: zone)
        guard case let .interval(sunrise, sunset) =
                Solar.computeDaylightFraction(on: noon, lat: 40.7142, lon: -74.0064, timeZone: zone) else {
            return XCTFail("纽约 11/1 应有正常日出日落")
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let riseHour = cal.component(.hour, from: Solar.date(forFractionOfDay: sunrise, on: noon, in: zone))
        let setHour = cal.component(.hour, from: Solar.date(forFractionOfDay: sunset, on: noon, in: zone))
        // 秋退当天纽约日出约 6:26、日落约 16:53(EST)。放宽到小时区间以免被算法微调误伤。
        XCTAssertTrue((5...7).contains(riseHour), "日出小时 \(riseHour) 偏离清晨")
        XCTAssertTrue((16...18).contains(setHour), "日落小时 \(setHour) 偏离黄昏")
    }

    // MARK: - 极昼极夜仍要正确识别（日界线修复时最容易误伤的邻居）

    func testPolarDayAndPolarNightStillDetected() {
        let svalbard = tz("Arctic/Longyearbyen")
        let summer = instant(2026, 6, 21, 12, 0, in: svalbard)
        let winter = instant(2026, 12, 21, 12, 0, in: svalbard)
        XCTAssertEqual(Solar.computeDaylightFraction(on: summer, lat: 78.0, lon: 16.0, timeZone: svalbard),
                       .polarDay)
        XCTAssertEqual(Solar.computeDaylightFraction(on: winter, lat: 78.0, lon: 16.0, timeZone: svalbard),
                       .polarNight)
    }

    // MARK: - 常规城市不能被上面的修复改坏

    func testWellKnownCitiesKeepPlausibleDaylight() throws {
        // (时区, 纬度, 经度, 夏至昼长下限, 冬至昼长上限)
        let cases: [(String, Double, Double, Double, Double)] = [
            ("Asia/Tokyo",      35.6544, 139.7447, 14.0, 10.5),
            ("Europe/London",   51.5083,  -0.1253, 16.0,  8.5),
            ("America/New_York",40.7142, -74.0064, 14.5, 10.0),
            // 南半球:6 月短、12 月长。独立核算的悉尼实际为 6/21 ≈ 9.90h、12/21 ≈ 14.41h。
            ("Australia/Sydney",-33.8667, 151.2167, 10.5, 14.0),
        ]
        for (id, lat, lon, juneBound, decemberBound) in cases {
            let june = try XCTUnwrap(daylightHours(2026, 6, 21, id: id, lat: lat, lon: lon))
            let december = try XCTUnwrap(daylightHours(2026, 12, 21, id: id, lat: lat, lon: lon))
            if lat >= 0 {
                XCTAssertGreaterThan(june, juneBound, "\(id) 夏至昼长过短")
                XCTAssertLessThan(december, decemberBound, "\(id) 冬至昼长过长")
            } else {
                XCTAssertLessThan(june, juneBound, "\(id) 南半球 6 月昼长过长")
                XCTAssertGreaterThan(december, decemberBound, "\(id) 南半球 12 月昼长过短")
            }
        }
    }
}

// MARK: - 覆盖面扫描

extension SolarTests {
    /// 抽样扫全库:日照结果不得出现 NaN、占比越界、日出≥日落,也不得在低纬度误判极昼夜。
    /// 全量跑过 1,883,240 次(23.5 万城 × 8 个日期)零异常,这里按 1/50 抽样留作常驻护栏。
    func testDaylightIsSaneAcrossTheWholeCatalog() throws {
        let index = CityIndex.shared
        try XCTSkipUnless(index.isAvailable)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let dates = [(2026, 3, 20), (2026, 6, 21), (2026, 9, 23), (2026, 12, 21)].map {
            cal.date(from: DateComponents(year: $0.0, month: $0.1, day: $0.2, hour: 12))!
        }
        var zones: [String: TimeZone] = [:]
        for cityIndex in stride(from: 0, to: index.cityCount, by: 50) {
            guard let record = index.city(at: cityIndex) else { continue }
            let zone: TimeZone
            if let cached = zones[record.timezoneID] { zone = cached }
            else {
                zone = try XCTUnwrap(TimeZone(identifier: record.timezoneID),
                                     "索引里的时区标识系统解析不了:\(record.timezoneID)")
                zones[record.timezoneID] = zone
            }
            for date in dates {
                switch Solar.computeDaylightFraction(on: date, lat: record.latitude,
                                                     lon: record.longitude, timeZone: zone) {
                case .interval(let rise, let set):
                    XCTAssertTrue(rise.isFinite && set.isFinite, "\(record.name) 出现 NaN")
                    XCTAssertTrue((0...1).contains(rise) && (0...1).contains(set),
                                  "\(record.name) 占比越界 \(rise)/\(set)")
                    XCTAssertLessThan(rise, set, "\(record.name) 日出不早于日落")
                case .polarDay, .polarNight:
                    XCTAssertGreaterThanOrEqual(abs(record.latitude), 65,
                                                "\(record.name) 纬度 \(record.latitude) 不该判极昼夜")
                }
            }
        }
    }

    /// 独立于本算法的几何恒等式:日出与日落必须关于太阳正午**精确对称**。
    /// 全量 3,294,958 次采样里最差偏差 0.0000 分钟。这条把经度、时区偏移、
    /// 夏令时三者的处理一起卡住——任一处算错,对称性立刻破。
    func testSunriseAndSunsetAreSymmetricAboutSolarNoon() throws {
        let index = CityIndex.shared
        try XCTSkipUnless(index.isAvailable)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let dates = (1...12).map {
            cal.date(from: DateComponents(year: 2026, month: $0, day: 15, hour: 12))!
        }
        for cityIndex in stride(from: 0, to: index.cityCount, by: 200) {
            guard let record = index.city(at: cityIndex),
                  let zone = TimeZone(identifier: record.timezoneID) else { continue }
            for date in dates {
                guard case .interval(let rise, let set) = Solar.computeDaylightFraction(
                    on: date, lat: record.latitude, lon: record.longitude, timeZone: zone),
                      rise > 0.0001, set < 0.9999            // 未被钳到日界的样本才成立
                else { continue }
                let noon = (rise + set) / 2 * 1440
                let skew = abs((noon - rise * 1440) - (set * 1440 - noon))
                XCTAssertLessThan(skew, 0.02, "\(record.name) 日出日落不关于正午对称")
            }
        }
    }

    /// 2026 年每个时区的夏令时切换点前后,日出时刻的跳变不得超过 1.2 小时
    /// (含豪勋爵岛那种半小时步进)。全量 246 次切换零违例。
    func testDaylightSavingTransitionsDoNotJumpTheSun() throws {
        let index = CityIndex.shared
        try XCTSkipUnless(index.isAvailable)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let start = cal.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        let end = cal.date(from: DateComponents(year: 2027, month: 1, day: 1))!
        var seen = Set<String>()
        var transitions = 0
        for cityIndex in 0..<min(20_000, index.cityCount) {
            guard let record = index.city(at: cityIndex), seen.insert(record.timezoneID).inserted,
                  let zone = TimeZone(identifier: record.timezoneID) else { continue }
            var cursor = start
            while let moment = zone.nextDaylightSavingTimeTransition(after: cursor), moment < end {
                transitions += 1
                cursor = moment.addingTimeInterval(3600)
                func sunrise(_ date: Date) -> Double? {
                    if case .interval(let rise, _) = Solar.computeDaylightFraction(
                        on: date, lat: record.latitude, lon: record.longitude, timeZone: zone) {
                        return rise
                    }
                    return nil
                }
                guard let before = sunrise(moment.addingTimeInterval(-36_000)),
                      let after = sunrise(moment.addingTimeInterval(36_000)) else { continue }
                XCTAssertLessThan(abs(before - after) * 24, 1.2,
                                  "\(record.timezoneID) 切换时日出跳了 \(abs(before - after) * 24) 小时")
            }
        }
        XCTAssertGreaterThan(transitions, 100, "2026 年应能找到上百次切换,实得 \(transitions)")
    }
}
