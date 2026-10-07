// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Foundation
import Testing
@testable import TahoeTime

struct MapOwnMarkerCollisionTests {
    @Test(arguments: [CGFloat(150), CGFloat(180), CGFloat(220)])
    func longRightEdgeLabelMovesToTheLeftOfItsOwnCircle(width: CGFloat) throws {
        let bounds = CGSize(width: 928, height: 356)
        let point = CGPoint(x: 824, y: 114)
        let size = CGSize(width: width, height: 22)
        let radius = CGFloat(4)
        let marker = CGRect(x: point.x - radius, y: point.y - radius,
                            width: 2 * radius, height: 2 * radius)
        // 原先向右放再贴边收进来的位置确实压住本地点的圈。
        let clampedRight = CGRect(x: bounds.width - size.width, y: point.y - size.height / 2,
                                  width: size.width, height: size.height)
        #expect(clampedRight.intersects(marker))
        let placed = try #require(MapLabelLayout.place(points: [(index: 0, point: point)],
                                                       sizes: [0: size], in: bounds,
                                                       dotRadius: radius).first)
        let box = Self.box(placed)
        #expect(!box.intersects(marker))
        #expect(box.maxX < marker.minX)
        #expect(CGRect(origin: .zero, size: bounds).contains(box))
        #expect(placed.size == size)
    }

    @Test(arguments: [CGPoint(x: 3, y: 3), CGPoint(x: 925, y: 3),
                      CGPoint(x: 3, y: 353), CGPoint(x: 925, y: 353)])
    func cornerLabelsKeepTheirOwnCircleClear(point: CGPoint) throws {
        let bounds = CGSize(width: 928, height: 356)
        let radius = CGFloat(4)
        let marker = CGRect(x: point.x - radius, y: point.y - radius,
                            width: 2 * radius, height: 2 * radius)
        let placed = try #require(MapLabelLayout.place(points: [(index: 0, point: point)],
                                                       sizes: [0: CGSize(width: 220, height: 22)],
                                                       in: bounds, dotRadius: radius).first)
        #expect(!Self.box(placed).intersects(marker))
        #expect(CGRect(origin: .zero, size: bounds).contains(Self.box(placed)))
    }

    @Test(arguments: [UInt64(0), 23, 97, 431])
    func seededEdgeLabelsKeepTheirFullBoundsAndOwnCircleClear(seed: UInt64) throws {
        var random = SplitMix64(seed: seed)
        let bounds = CGSize(width: 928, height: 356)
        let samples = 2_000
        for sample in 0..<samples {
            let size = CGSize(width: CGFloat(random.int(120...430)), height: CGFloat(random.int(14...42)))
            let radius = CGFloat(random.int(2...6))
            let inset = CGFloat(random.int(0...12))
            let x = CGFloat(random.int(0...928))
            let y = CGFloat(random.int(0...356))
            let point: CGPoint
            switch sample % 8 {
            case 0: point = CGPoint(x: bounds.width - inset, y: y)
            case 1: point = CGPoint(x: inset, y: y)
            case 2: point = CGPoint(x: x, y: inset)
            case 3: point = CGPoint(x: x, y: bounds.height - inset)
            case 4: point = CGPoint(x: inset, y: inset)
            case 5: point = CGPoint(x: bounds.width - inset, y: inset)
            case 6: point = CGPoint(x: inset, y: bounds.height - inset)
            default: point = CGPoint(x: bounds.width - inset, y: bounds.height - inset)
            }
            let placed = try #require(MapLabelLayout.place(points: [(index: 0, point: point)],
                                                           sizes: [0: size], in: bounds,
                                                           dotRadius: radius).first)
            let left = placed.center.x - placed.size.width / 2
            let right = placed.center.x + placed.size.width / 2
            let top = placed.center.y - placed.size.height / 2
            let bottom = placed.center.y + placed.size.height / 2
            // 用独立的轴区间判据，不复用摆放算法或 CGRect 相交实现。
            let separated = right <= point.x - radius || left >= point.x + radius
                || bottom <= point.y - radius || top >= point.y + radius
            #expect(separated, "seed \(seed), sample \(sample): 标签不得碰到本地点的圈")
            #expect(left >= 0 && top >= 0 && right <= bounds.width && bottom <= bounds.height,
                    "seed \(seed), sample \(sample): 标签必须完整留在图内")
            #expect(placed.size == size, "seed \(seed), sample \(sample): 不得缩短标签")
        }
        print("MAP_OWN_MARKER_SEED seed=\(seed) samples=\(samples)")
    }

    @MainActor
    @Test(arguments: ["en", "ru", "zh-Hans", "de"], [CGFloat(1), CGFloat(2)])
    func localizedMoonCaptionsKeepFullMeasuredBoundsAtEveryEdge(language: String, scale: CGFloat) throws {
        let bounds = CGSize(width: 928, height: 356)
        let locale = Locale(identifier: language)
        let names = WorldMapScene.phaseNames(locale: locale)
        let points = [CGPoint(x: 0, y: 178), CGPoint(x: 928, y: 178),
                      CGPoint(x: 0, y: 0), CGPoint(x: 928, y: 0),
                      CGPoint(x: 0, y: 356), CGPoint(x: 928, y: 356)]
        for phase in WorldMapScene.moonPhases {
            let name = try #require(names[phase])
            let font = NSFont.systemFont(ofSize: AppFont.size(.caption) * scale * TextSize.larger.scale)
            let measured = (name as NSString).size(withAttributes: [.font: font])
            for point in points {
                let moon = WorldMapScene.Moon(x: point.x, y: point.y, phase: phase, illumination: 0.5)
                let unbounded = try #require(WorldMapScene.moonBoxes(moon, large: true, name: name,
                    scale: scale, textScale: TextSize.larger.scale, locale: locale).last)
                let boxes = WorldMapScene.moonBoxes(moon, large: true, name: name, scale: scale,
                    textScale: TextSize.larger.scale, locale: locale, in: bounds)
                #expect(boxes.count == 2)
                let caption = try #require(boxes.last)
                #expect(caption.size == unbounded.size, "月相名不能靠缩字或缩框来避开边界")
                #expect(caption.width >= measured.width + 2 && caption.height >= measured.height + 2)
                #expect(caption.minX >= 0 && caption.minY >= 0
                        && caption.maxX <= bounds.width && caption.maxY <= bounds.height,
                        "月相名的完整文字与描边必须留在地图内")
                let radius = CGFloat(5) * scale
                let separated = caption.maxX <= point.x - radius || caption.minX >= point.x + radius
                    || caption.maxY <= point.y - radius || caption.minY >= point.y + radius
                #expect(separated, "挪动月相名时不得遮住月亮圆盘")
                #expect(boxes[0].midX == point.x && boxes[0].midY == point.y,
                        "月亮图形必须留在原来的经纬度")
                if point.y == bounds.height { #expect(caption.maxY <= point.y - radius) }
            }
        }
    }

    @MainActor
    @Test(arguments: ["en", "ru", "zh-Hans", "de"])
    func cityLabelsAvoidTheActualShiftedMoonCaption(language: String) throws {
        let bounds = CGSize(width: 928, height: 356)
        let locale = Locale(identifier: language)
        let names = WorldMapScene.phaseNames(locale: locale)
        let name = try #require(names.values.max { $0.count < $1.count })
        let moon = WorldMapScene.Moon(x: 0, y: 178, phase: "lastQuarter", illumination: 0.5)
        let original = try #require(WorldMapScene.moonBoxes(moon, large: true, name: name,
            scale: 1, textScale: TextSize.larger.scale, locale: locale).last)
        #expect(original.minX < 0, "负对照必须确实越过地图左边界")
        let obstacles = WorldMapScene.moonBoxes(moon, large: true, name: name, scale: 1,
            textScale: TextSize.larger.scale, locale: locale, in: bounds)
        let caption = try #require(obstacles.last)
        let point = CGPoint(x: caption.midX, y: caption.midY)
        let size = CGSize(width: 160, height: 22)
        let unprotected = try #require(MapLabelLayout.place(points: [(index: 0, point: point)],
            sizes: [0: size], in: bounds).first)
        #expect(Self.box(unprotected).intersects(caption), "负对照必须压到实际挪动后的月相名")
        let protected = try #require(MapLabelLayout.place(points: [(index: 0, point: point)],
            sizes: [0: size], in: bounds, avoid: obstacles).first)
        let box = Self.box(protected)
        for obstacle in obstacles {
            #expect(box.maxX <= obstacle.minX || box.minX >= obstacle.maxX
                    || box.maxY <= obstacle.minY || box.minY >= obstacle.maxY,
                    "地点标签必须避开实际月亮与月相名")
        }
        #expect(protected.size == size)
        #expect(box.minX >= 0 && box.minY >= 0 && box.maxX <= bounds.width && box.maxY <= bounds.height)
    }

    private static func box(_ label: MapLabelLayout.Placed) -> CGRect {
        CGRect(x: label.center.x - label.size.width / 2, y: label.center.y - label.size.height / 2,
               width: label.size.width, height: label.size.height)
    }
}
