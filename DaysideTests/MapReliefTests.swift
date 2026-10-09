// SPDX-License-Identifier: GPL-3.0-only
//
//  MapReliefTests.swift
//  地形与逐像素地图的宿主那一半。①地形什么时候放掉（空闲时不占内存，发布门量的是面板关着的时候）：
//  最后一张地图消失、到点时这期间没人再碰过才放；②随包的 relief.png 真能读进 Rust，画出来的图白天亮、夜里暗；
//  ③在图上量明暗与 WCAG 公式一致。
//

import Foundation
import AppKit
import Testing
@testable import Dayside

struct MapReliefTests {
    @MainActor @Test func mapReturnsBorrowedSurfaceWhileSecondsKeepTicking() async throws {
        let view = MapSurfaceView(frame: CGRect(x: 0, y: 0, width: 32, height: 16))
        defer { view.releaseSurfaces(); MapRelief.usedOffscreen() }
        @MainActor func draw(_ seconds: Double) {
            view.render(seconds: seconds, size: CGSize(width: 32, height: 16), scale: 1,
                        latitudes: WorldMapScene.standard, lights: 1, large: true)
        }
        let start = 1_790_000_000.0
        draw(start)
        try await Task.sleep(for: .milliseconds(300))
        for frame in 1...3 { draw(start + Double(frame) / 30) }
        try #require(view.ownedSurfaceCount == 2, "动画确实借过第二块像素面")
        try #require(view.layer?.contents != nil, "真实像素面已交给图层")
        for second in 1...2 {
            try await Task.sleep(for: .seconds(1))
            draw(start + Double(second))
        }
        try await Task.sleep(for: .milliseconds(400))
        print("MAP_SURFACE_LIVE_TICK owned=\(view.ownedSurfaceCount)")
        #expect(view.ownedSurfaceCount == 1, "秒钟还在走，动画借的像素面须已归还")
        try await Task.sleep(for: .milliseconds(600))
        draw(start + 3)
        #expect(view.ownedSurfaceCount == 1)
    }

    @Test func reliefIsReleasedOnlyWhenNobodyHasLookedSinceTheLastMapWentAway() {
        var life = ReliefLifecycle(loaded: true)
        life.retain()                                   // 面板打开
        life.retain()                                   // 地球窗打开
        let first = life.release()                      // 地球窗关了：面板还开着
        let whileThePanelIsOpen = life.releaseIfIdle(since: first)
        let second = life.release()                     // 面板也关了
        let afterBothClosed = life.releaseIfIdle(since: second)
        #expect(!whileThePanelIsOpen)
        #expect(afterBothClosed)
        #expect(!life.loaded)

        var reopened = ReliefLifecycle(loaded: true)
        reopened.retain()
        let closed = reopened.release()
        reopened.retain()                               // 10 秒内又打开：到点时不放
        let whileReopened = reopened.releaseIfIdle(since: closed)
        #expect(!whileReopened)
        #expect(reopened.loaded)

        var offscreen = ReliefLifecycle(loaded: true)   // 导出名片：没有地图在屏幕上
        let touched = offscreen.touch()
        let later = offscreen.touch()                   // 又导出一张：只认最后一次
        let early = offscreen.releaseIfIdle(since: touched)
        let last = offscreen.releaseIfIdle(since: later)
        #expect(!early)
        #expect(last)

        var never = ReliefLifecycle(loaded: false)
        let neverLoaded = never.releaseIfIdle(since: never.generation)
        #expect(!neverLoaded, "没读过就不放")
        var unbalanced = ReliefLifecycle(loaded: true)
        let generation = unbalanced.release()
        #expect(generation == 1 && unbalanced.users == 0, "多减一次不变负数")
    }

    /// 随包地形读进 Rust 后画一张图：离直射点 30° 以内的格子亮（白天），离反日点 30° 以内的格子暗（夜）；
    /// 量明暗的函数与 WCAG 公式在黑白两端一致。
    @MainActor @Test func theBundledReliefDrawsADayThatIsLightAndANightThatIsDark() throws {
        let instant = Date(timeIntervalSince1970: 1_790_000_000)   // 2026-09-21 14:13 UTC
        let size = CGSize(width: 360, height: 138)
        let raster = try #require(MapRaster.render(instant: instant, size: size, scale: 2, latitudes: WorldMapScene.standard, lights: 1))
        #expect(MapRelief.isLoaded)
        #expect(raster.width == 720 && raster.height == 276)
        let scene = WorldMapScene.scene(instant: instant, size: size, places: [], latitudes: WorldMapScene.standard)
        let sun = CGPoint(x: scene.sun[0], y: scene.sun[1])
        // 反日点：经度差 180°、纬度取反（等距柱状投影 1 点 = 1°，北边界 80°N）。
        let antipode = CGPoint(x: sun.x < 180 ? sun.x + 180 : sun.x - 180, y: 2 * MapRelief.north - sun.y)
        let day = raster.luminance(in: CGRect(x: sun.x - 20, y: sun.y - 10, width: 40, height: 20))
        let night = raster.luminance(in: CGRect(x: antipode.x - 20, y: antipode.y - 10, width: 40, height: 20))
        #expect(day > 0.35, "白天 \(day)")
        #expect(night < 0.08, "夜 \(night)")
        #expect(MapRaster.luminance(r: 1, g: 1, b: 1) == 1)
        #expect(MapRaster.luminance(r: 0, g: 0, b: 0) == 0)
        #expect(abs(MapRaster.luminance(r: 0.5, g: 0.5, b: 0.5) - 0.2140) < 0.0005)
        MapRelief.usedOffscreen()
    }
}
