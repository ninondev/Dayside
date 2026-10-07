// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import TahoeTime

@MainActor
struct MapAvoidMarkerReviewTests {
    @Test(arguments: [CGFloat(512), CGFloat(1200)], [false, true])
    func textAvoidanceNeverDeletesAGeographicCircle(width: CGFloat, home: Bool) throws {
        let instant = Date(timeIntervalSince1970: 1_789_542_000)
        let size = CGSize(width: width, height: width * 138 / 360)
        let place = WorldMapPlace(latitude: 34.05, longitude: -118.24, home: home)
        // 按经纬度独立投影，避开区确实围住这个地点。
        let point = CGPoint(x: (place.longitude + 180) * Double(width) / 360,
                            y: (80 - place.latitude) * Double(size.height) / 138)
        let obstacle = CGRect(x: point.x - 18, y: point.y - 18, width: 36, height: 36)
        let scene = WorldMapScene.scene(instant: instant, size: size, places: [place],
                                       latitudes: WorldMapScene.standard)
        let pin = try #require(scene.pins.first)
        #expect(abs(pin.x - point.x) < 0.5 && abs(pin.y - point.y) < 0.5)
        #expect(obstacle.contains(CGPoint(x: pin.x, y: pin.y)))

        let empty = try pixels(instant: instant, size: size, places: [], avoid: [])
        let visible = try pixels(instant: instant, size: size, places: [place], avoid: [])
        let protectedText = try pixels(instant: instant, size: size, places: [place], avoid: [obstacle])
        // 没有标签时，避开区不得改变地图；空地图作负对照，防止三张都没画出圈。
        let markerIsVisible = visible != empty
        let circleIsUnchanged = protectedText == visible
        #expect(markerIsVisible, "负对照必须证明真实视图画出了地点圈")
        #expect(circleIsUnchanged, "避开文字只能挪标签，地点圈必须留在原坐标")
        print("MAP_AVOID_MARKER width=\(width) home=\(home) bytes=\(visible.count)")
    }

    private func pixels(instant: Date, size: CGSize, places: [WorldMapPlace], avoid: [CGRect]) throws -> Data {
        try autoreleasepool {
            let width = Int(size.width.rounded()), height = Int(size.height.rounded())
            let context = try #require(CGContext(data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            let view = WorldMapScene(instant: instant, places: places, latitudes: WorldMapScene.standard,
                large: size.width >= 900, lights: 0, showsMoon: false, rasterScale: 1,
                avoid: avoid, cornerRadius: 0)
                .frame(width: size.width, height: size.height)
                .environment(\.locale, Locale(identifier: "en"))
                .environment(\.textScale, 1)
                .environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: view)
            var drew = false
            renderer.render(rasterizationScale: 1) { _, draw in
                draw(context)
                drew = true
            }
            #expect(drew, "渲染器必须实际调用绘制")
            let storage = try #require(context.data)
            return Data(bytes: storage, count: width * height * 4)
        }
    }
}
