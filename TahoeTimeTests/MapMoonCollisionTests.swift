// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI
import Testing
@testable import TahoeTime

@MainActor
struct MapMoonCollisionTests {
    @Test(arguments: ["en", "ru", "ja"], [CGFloat(1), CGFloat(2)])
    func moonObstaclesCoverTheActualLocalizedCaption(language: String, scale: CGFloat) throws {
        let locale = Locale(identifier: language)
        let names = WorldMapScene.phaseNames(locale: locale)
        for phase in WorldMapScene.moonPhases {
            let name = try #require(names[phase])
            let moon = WorldMapScene.Moon(x: 260, y: 110, phase: phase, illumination: 0.5)
            let boxes = WorldMapScene.moonBoxes(moon, large: true, name: name, scale: scale,
                                                textScale: TextSize.larger.scale, locale: locale)
            #expect(boxes.count == 2)
            let caption = try #require(boxes.last)
            // 独立用绘制月相名的系统字体量字，不按固定宽度猜。
            let font = NSFont.systemFont(ofSize: AppFont.size(.caption) * scale * TextSize.larger.scale)
            let measured = (name as NSString).size(withAttributes: [.font: font])
            #expect(caption.width >= measured.width + 2)
            #expect(caption.height >= measured.height + 2)
            #expect(caption.midX == CGFloat(moon.x))
            #expect(boxes[0].contains(CGPoint(x: moon.x, y: moon.y)))
        }
    }

    @Test func aNarrowMapMovesThePlaceLabelAwayFromTheMoonAndCaption() throws {
        let bounds = CGSize(width: 528, height: 203)
        let point = CGPoint(x: 100, y: 90)
        let size = CGSize(width: 160, height: 22)
        let moon = WorldMapScene.Moon(x: 180, y: 90, phase: "waningCrescent", illumination: 0.2)
        let locale = Locale(identifier: "ru")
        let name = try #require(WorldMapScene.phaseNames(locale: locale)[moon.phase])
        let obstacles = WorldMapScene.moonBoxes(moon, large: true, name: name, scale: 1,
                                                textScale: TextSize.larger.scale, locale: locale)
        func box(_ label: MapLabelLayout.Placed) -> CGRect {
            CGRect(x: label.center.x - label.size.width / 2, y: label.center.y - label.size.height / 2,
                   width: label.size.width, height: label.size.height)
        }
        let points = [(index: 0, point: point)]
        let unprotected = try #require(MapLabelLayout.place(points: points, sizes: [0: size], in: bounds).first)
        #expect(obstacles.contains { $0.intersects(box(unprotected)) }, "负对照必须确实压到月亮")
        let protected = try #require(MapLabelLayout.place(points: points, sizes: [0: size], in: bounds, avoid: obstacles).first)
        #expect(obstacles.allSatisfy { !$0.intersects(box(protected)) })
        #expect(CGRect(origin: .zero, size: bounds).contains(box(protected)))
    }

    @Test func anUnnamedMoonOnlyReservesItsVisibleSymbol() {
        let moon = WorldMapScene.Moon(x: 100, y: 100, phase: "full", illumination: 1)
        let boxes = WorldMapScene.moonBoxes(moon, large: false, name: nil, scale: 1,
                                            textScale: 1, locale: Locale(identifier: "en"))
        #expect(boxes.count == 1)
        #expect(boxes[0].width == 3.8)
    }
}
