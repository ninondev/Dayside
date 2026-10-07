// SPDX-License-Identifier: GPL-3.0-only
//
//  SunPhaseTests.swift
//  TahoeTime
//
//  `SunPhase` 的纯几何：段的每条边界与经度归一化、特殊点的高度角、三档的分界。
//

import Testing
@testable import TahoeTime

struct SunPhaseTests {
    @Test func bandAtEveryBoundary() {
        // 区间半开：端点归下一段，差一个 ulp 的邻居归上一段。
        #expect(SunPhase.band(longitude: -180) == 0)
        #expect(SunPhase.band(longitude: (-135.0).nextDown) == 0)
        #expect(SunPhase.band(longitude: -135) == 1)
        #expect(SunPhase.band(longitude: (-95.0).nextDown) == 1)
        #expect(SunPhase.band(longitude: -95) == 2)
        #expect(SunPhase.band(longitude: (-45.0).nextDown) == 2)
        #expect(SunPhase.band(longitude: -45) == 3)
        #expect(SunPhase.band(longitude: (-15.0).nextDown) == 3)
        #expect(SunPhase.band(longitude: -15) == 4)
        #expect(SunPhase.band(longitude: 45.0.nextDown) == 4)
        #expect(SunPhase.band(longitude: 45) == 5)
        #expect(SunPhase.band(longitude: 90.0.nextDown) == 5)
        #expect(SunPhase.band(longitude: 90) == 6)
        #expect(SunPhase.band(longitude: 150.0.nextDown) == 6)
        #expect(SunPhase.band(longitude: 150) == 7)
        #expect(SunPhase.band(longitude: 180) == 7)
    }

    @Test func bandSamples() {
        #expect(SunPhase.band(longitude: -179.9) == 0)
        #expect(SunPhase.band(longitude: -157.9) == 0)
        #expect(SunPhase.band(longitude: -118.2) == 1)
        #expect(SunPhase.band(longitude: -74.0) == 2)
        #expect(SunPhase.band(longitude: -30.0) == 3)
        #expect(SunPhase.band(longitude: -0.1) == 4)
        #expect(SunPhase.band(longitude: 31.2) == 4)
        #expect(SunPhase.band(longitude: 77.2) == 5)
        #expect(SunPhase.band(longitude: 139.7) == 6)
        #expect(SunPhase.band(longitude: 151.2) == 7)
        #expect(SunPhase.band(longitude: 179.9) == 7)
    }

    @Test func bandNormalizesLongitudeFirst() {
        // 先归一化进 -180...180 再分段：出了区间照样归对的那段。
        #expect(SunPhase.band(longitude: 185) == 0)
        #expect(SunPhase.band(longitude: -185) == 7)
        #expect(SunPhase.band(longitude: 540) == 7)
        #expect(SunPhase.band(longitude: -540) == 0)
    }

    @Test func altitudeAtSpecialPoints() {
        // 直射点正上方是 90°，对跖点是 -90°，弧距 90° 处正好在地平线上——都是一手可算、舍入远小于 1e-9 度的点。
        #expect(abs(SunPhase.altitude(latitude: 0, longitude: 0, subsolarLatitude: 0, subsolarLongitude: 0) - 90) < 1e-9)
        #expect(abs(SunPhase.altitude(latitude: 0, longitude: 180, subsolarLatitude: 0, subsolarLongitude: 0) + 90) < 1e-9)
        #expect(abs(SunPhase.altitude(latitude: 0, longitude: 90, subsolarLatitude: 0, subsolarLongitude: 0)) < 1e-9)
        #expect(abs(SunPhase.altitude(latitude: 90, longitude: 0, subsolarLatitude: 0, subsolarLongitude: 0)) < 1e-9)
        // 直射点在赤道时，赤道上经度差 45° 的地点高度角就是 45°（顺带钉住返回的是度不是弧度）。
        #expect(abs(SunPhase.altitude(latitude: 0, longitude: 45, subsolarLatitude: 0, subsolarLongitude: 0) - 45) < 1e-9)
    }

    @Test func phaseThresholds() {
        #expect(SunPhase.phase(altitude: 10) == .day)
        #expect(SunPhase.phase(altitude: -0.833) == .day)   // 地平线含折射：-0.833° 仍算白天
        #expect(SunPhase.phase(altitude: -0.84) == .twilight)
        #expect(SunPhase.phase(altitude: -6) == .twilight)
        #expect(SunPhase.phase(altitude: -6.01) == .night)
    }
}
