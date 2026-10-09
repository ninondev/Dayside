// SPDX-License-Identifier: GPL-3.0-only
//
//  JumpTimingTests.swift
//  跳转动画的节奏：距离越远走越久（≤ 2 h 0.25 s，6 h 0.6 s，24 h 起 0.9 s 封顶）、
//  ≥ 6 h 分两拍且两拍同刻到达、距离取绝对值、不随距离变短。
//

import Foundation
import Testing
@testable import Dayside

struct JumpTimingTests {
    /// 钉住几个整点：0 / 1 / 2 h 都是原来的 0.25 s；6 h 0.6；15 h 0.75；24 h 起封顶 0.9。
    @Test func durationFollowsTheDistance() {
        let pinned: [(hours: Double, duration: Double)] = [
            (0, 0.25), (1, 0.25), (2, 0.25), (6, 0.6), (15, 0.75), (24, 0.9), (48, 0.9), (240, 0.9),
        ]
        for case let (hours, duration) in pinned {
            #expect(abs(JumpTiming.jumpDuration(hours: hours) - duration) < 1e-9, "\(hours) h 应为 \(duration)")
        }
        // 两段都是直线：4 h 落在 0.25 与 0.6 的正中，12 h 在 0.6 之上再加 6/18 × 0.3。
        #expect(abs(JumpTiming.jumpDuration(hours: 4) - 0.425) < 1e-9)
        #expect(abs(JumpTiming.jumpDuration(hours: 12) - 0.7) < 1e-9)
    }

    /// 距离取绝对值（往后跳与往回跳一样远），非有限值当 0（不产生 NaN 时长）。
    @Test func durationTakesTheAbsoluteDistance() {
        #expect(JumpTiming.jumpDuration(hours: -15) == JumpTiming.jumpDuration(hours: 15))
        #expect(JumpTiming.jumpDuration(hours: -1) == 0.25)
        #expect(JumpTiming.jumpDuration(hours: .nan) == 0.25)
        #expect(JumpTiming.jumpDuration(hours: .infinity) == 0.25)
    }

    /// 单调不减且始终夹在 0.25 … 0.9 里：跳得越远不会越快，也不会无界。
    @Test func durationNeverDecreasesAndStaysCapped() {
        var previous = 0.0
        for k in 0...600 {
            let hours = Double(k) * 0.1                       // 0 … 60 h，每 6 分钟一采
            let duration = JumpTiming.jumpDuration(hours: hours)
            #expect(duration >= previous - 1e-12, "\(hours) h 比上一档短")
            #expect(duration >= 0.25 - 1e-12 && duration <= 0.9 + 1e-12, "\(hours) h 越界 \(duration)")
            previous = duration
        }
    }

    /// ≥ 6 h 分两拍：地图整段走，行等 0.4 d 再走 0.6 d，`delay + row == map`（与地图同刻到达）；
    /// 不足 6 h 一拍（行与地图同段）；「减弱动态效果」的淡入时长钉在 0.2 s。
    @Test func longJumpsTakeTwoBeatsAndArriveTogether() {
        let far = JumpTiming.beats(hours: 24)
        #expect(abs(far.map - 0.9) < 1e-9)
        #expect(abs(far.delay - 0.36) < 1e-9 && abs(far.row - 0.54) < 1e-9)
        let edge = JumpTiming.beats(hours: 6)
        #expect(abs(edge.map - 0.6) < 1e-9)
        #expect(edge.delay > 0 && edge.row < edge.map)
        for hours in [-30.0, -6, 6, 9.5, 15, 24, 100] {
            let beats = JumpTiming.beats(hours: hours)
            #expect(abs(beats.delay + beats.row - beats.map) < 1e-9, "\(hours) h 两拍不同刻到达")
            #expect(beats.delay > 0, "\(hours) h 没分两拍")
        }
        for hours in [0.0, 1, 2, 4, 5.9] {
            let beats = JumpTiming.beats(hours: hours)
            #expect(beats.delay == 0 && beats.row == beats.map, "\(hours) h 不该分两拍")
        }
        #expect(JumpTiming.fadeDuration == 0.2)
    }
}
