// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SwiftUI
import Testing
@testable import TahoeTime

@MainActor
struct Copy2TravelHintTests {
    /// 医疗脚注跟随实际展示的睡眠或光照建议，空表和无效行程不出现。
    @Test func medicalFooterRequiresDisplayedAdvice() throws {
        let core = TimeCore(zones: [], settings: AppSettings())
        let departure = 1_792_458_000.0 // 2026-10-20 10:00（东京）
        // 到达早于出发：画不出作息表的无效行程。
        let invalid = makeTrip(originID: "Asia/Tokyo", originLatitude: 35.6762, originLongitude: 139.6503,
                               destinationID: "America/New_York", destinationLatitude: 40.7128, destinationLongitude: -74.0060,
                               departureUnix: departure, arrivalUnix: departure - 3_600)
        // 两地钟面一致，页面仍画出睡眠安排。
        let sameClock = makeTrip(originID: "Asia/Tokyo", originLatitude: 35.6762, originLongitude: 139.6503,
                                 destinationID: "Asia/Tokyo", destinationLatitude: 35.6762, destinationLongitude: 139.6503,
                                 departureUnix: departure, arrivalUnix: departure + 3_600)
        // 纽约到东京（往东 13 小时）：会画出睡觉和光照建议。
        let eastward = makeTrip(originID: "America/New_York", originLatitude: 40.7128, originLongitude: -74.0060,
                                destinationID: "Asia/Tokyo", destinationLatitude: 35.6762, destinationLongitude: 139.6503,
                                departureUnix: 1_792_469_200, arrivalUnix: 1_792_469_200 + 50_400)

        #expect(!TravelFooterAdvice.showsAdvice(lanes: []))
        #expect(!TravelFooterAdvice.showsAdvice(lanes: displayedLanes(of: invalid, core: core)))
        let sameClockLanes = displayedLanes(of: sameClock, core: core)
        #expect(sameClockLanes.contains { $0.sleep != nil })
        #expect(TravelFooterAdvice.showsAdvice(lanes: sameClockLanes))
        #expect(TravelFooterAdvice.showsAdvice(lanes: displayedLanes(of: eastward, core: core)))

        // 分别给睡眠、晒光、避光和无建议的展示数据，避免条件成立时跳过断言。
        for (sleep, seek, avoid, expected) in [
            (true, false, false, true), (false, true, false, true),
            (false, false, true, true), (false, false, false, false)
        ] {
            let data: [String: Any] = [
                "kind": "night", "date": "2026-10-20", "parts": [], "air": [],
                "sleep": sleep ? [0, 3600] : NSNull(), "seek": seek ? [[7200, 10800]] : [],
                "avoid": avoid ? [[14400, 18000]] : [], "label": ["kind": "none"],
                "midPlane": false, "range": [0, 86400]
            ]
            let lane = try JSONDecoder().decode(TravelNights.Lane.self, from: JSONSerialization.data(withJSONObject: data))
            #expect(TravelFooterAdvice.showsAdvice(lanes: [lane]) == expected)
        }
    }

    /// 行级提示就位后，每一晚仍保留完整日期、完整读屏文本和可选中性。
    @Test func nightRowKeepsFullDatesAndSelectionWhenHintMoves() {
        let core = TimeCore(zones: [], settings: AppSettings())
        let departure = 1_792_469_200.0 // 2026-10-20 10:00（纽约）
        let trip = makeTrip(originID: "America/New_York", originLatitude: 40.7128, originLongitude: -74.0060,
                            destinationID: "Asia/Tokyo", destinationLatitude: 35.6762, destinationLongitude: 139.6503,
                            departureUnix: departure, arrivalUnix: departure + 50_400)
        let memo = TravelNightsMemo()
        let _ = memo.update(trip: trip, origin: trip.coordinate(origin: true, places: core.zones),
                            destination: trip.coordinate(origin: false, places: core.zones),
                            reference: Date(timeIntervalSince1970: departure - 86_400), marks: false, knownPlan: trip.plan())
        let lanes = memo.nights.lanes
        #expect(!lanes.isEmpty)

        for lane in lanes {
            let words = TravelNightWords(trip: trip, lane: lane, core: core)
            #expect(!words.dateText.isEmpty)
            #expect(!words.spoken.isEmpty)
            #expect(!words.dateText.contains("…"))
            #expect(!words.spoken.contains("…"))
        }

        // 换钟（飞行）那一晚：读屏文本里仍有完整的日期数字与钟点。
        let flightLane = lanes.first { !$0.air.isEmpty }
        #expect(flightLane != nil)
        if let flightLane {
            let words = TravelNightWords(trip: trip, lane: flightLane, core: core)
            #expect(words.spoken.contains { $0.isNumber })
            #expect(words.spoken.contains(":"))
        }

        // 选中值仍收拢在真实的一晚上（和视图里的收拢一致）。
        let selected = min(max(memo.nights.selected, 0), lanes.count - 1)
        #expect(lanes.indices.contains(selected))
    }

    private func makeTrip(originID: String, originLatitude: Double, originLongitude: Double,
                          destinationID: String, destinationLatitude: Double, destinationLongitude: Double,
                          departureUnix: Double, arrivalUnix: Double) -> TravelTrip {
        var trip = TravelTrip(name: "测试", originTimeZoneID: originID, destinationTimeZoneID: destinationID,
                              destinationPlaceID: nil, departureUnix: departureUnix, arrivalUnix: arrivalUnix)
        trip.originPlace = TravelPlaceSnapshot(name: "", latitude: originLatitude, longitude: originLongitude, countryCode: nil)
        trip.destinationPlace = TravelPlaceSnapshot(name: "", latitude: destinationLatitude, longitude: destinationLongitude, countryCode: nil)
        return trip
    }

    /// 和 TravelPlanView 一样跑真实的 TravelNightsMemo，取页面上真正画出的晚。
    private func displayedLanes(of trip: TravelTrip, core: TimeCore) -> [TravelNights.Lane] {
        let memo = TravelNightsMemo()
        let _ = memo.update(trip: trip, origin: trip.coordinate(origin: true, places: core.zones),
                            destination: trip.coordinate(origin: false, places: core.zones),
                            reference: Date(timeIntervalSince1970: trip.departureUnix - 86_400), marks: false, knownPlan: trip.plan())
        return memo.nights.lanes
    }
}
