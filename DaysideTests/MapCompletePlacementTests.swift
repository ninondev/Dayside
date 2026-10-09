// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Foundation
import Testing
@testable import Dayside

@MainActor
struct MapCompletePlacementTests {
    private func box(_ label: MapLabelLayout.Placed) -> CGRect {
        CGRect(x: label.center.x - label.size.width / 2,
               y: label.center.y - label.size.height / 2,
               width: label.size.width, height: label.size.height)
    }

    @Test(arguments: [CGFloat(70), CGFloat(90)], [CGFloat(0), CGFloat(6), CGFloat(10)])
    func findsFreeSpaceWhenSomeNearbyCandidatesClearSymbolsButHitAnotherLabel(y: CGFloat, gap: CGFloat) throws {
        let bounds = CGSize(width: 300, height: 160)
        let points = [(index: 0, point: CGPoint(x: 100, y: y)),
                      (index: 1, point: CGPoint(x: 180, y: y))]
        let sizes = [0: CGSize(width: 160, height: 20), 1: CGSize(width: 200, height: 20)]
        let avoid = [CGRect(x: 170, y: y - 45, width: 130, height: 30),
                     CGRect(x: 170, y: y + 15, width: 130, height: 30)]
        // 圈旁六处全撞，但下面确实有装得下整行字的空位。
        let witness = CGRect(x: 100, y: y + 46, width: 200, height: 20)
        #expect(CGRect(origin: .zero, size: bounds).contains(witness))
        #expect(avoid.allSatisfy { !$0.intersects(witness) })
        let placed = MapLabelLayout.place(points: points, sizes: sizes, in: bounds, gap: gap, avoid: avoid)
        #expect(placed.count == 2)
        let first = try #require(placed.first { $0.index == 0 })
        let second = try #require(placed.first { $0.index == 1 })
        #expect(!box(first).intersects(witness))
        #expect(!box(first).intersects(box(second)))
        for label in placed {
            #expect(CGRect(origin: .zero, size: bounds).contains(box(label)))
            #expect(avoid.allSatisfy { !$0.intersects(box(label)) })
            for other in points where other.index != label.index {
                let dot = CGRect(x: other.point.x - 4, y: other.point.y - 4, width: 8, height: 8)
                #expect(!dot.intersects(box(label)))
            }
        }
    }

    @Test func narrowRussianEarthKeepsAllThreeCompleteLabelsClearOfEachOtherSunAndMoon() throws {
        let locale = Locale(identifier: "ru")
        let instant = try #require(ISO8601DateFormatter().date(from: "2026-10-06T02:13:00Z"))
        let reference = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let bounds = CGSize(width: 528, height: 528 * CGFloat(138) / 360)
        let textSize = CGFloat(13) * CGFloat(TextSize.larger.scale)
        let zones = [
            TimeZoneEntry(timezoneID: "America/Los_Angeles", cityName: "Los Angeles",
                          coordinate: .init(latitude: 34.05, longitude: -118.24), countryCode: "US"),
            TimeZoneEntry(timezoneID: "Europe/London", cityName: "London",
                          coordinate: .init(latitude: 51.51, longitude: -0.13), countryCode: "GB"),
            TimeZoneEntry(timezoneID: "Asia/Tokyo", cityName: "Tokyo",
                          coordinate: .init(latitude: 35.68, longitude: 139.69), countryCode: "JP", emoji: "🗼", color: "blue")
        ]
        let names = ["Лос-Анджелес", "Лондон", "Токио"]
        let labels = zones.enumerated().map { index, zone in
            MapLabel(name: zone.displayName(localizedCity: names[index]),
                     time: WorldMapView.clock(instant, in: zone.timeZone, hourStyle: .force24,
                                              locale: locale, reference: reference))
        }
        let places = try zones.enumerated().map { index, zone in
            let coordinate = try #require(zone.coordinate)
            return WorldMapPlace(latitude: coordinate.latitude, longitude: coordinate.longitude, home: index == 0)
        }
        let scene = WorldMapScene.scene(instant: instant, size: bounds, places: places, latitudes: WorldMapScene.standard)
        let moon = try #require(scene.moon)
        let phase = try #require(WorldMapScene.phaseNames(locale: locale)[moon.phase])
        let avoid = WorldMapScene.sunBox(scene.sun, large: true)
            + WorldMapScene.moonBoxes(moon, large: true, name: phase, scale: 1,
                                       textScale: CGFloat(TextSize.larger.scale), locale: locale)
        // 独立按当前画字的字体量整行，不借摆放函数的量字缓存。
        let sizes = Dictionary(uniqueKeysWithValues: labels.enumerated().map { index, label in
            let base = NSFont.systemFont(ofSize: textSize, weight: index == 0 ? .semibold : .medium)
            let serif = base.fontDescriptor.withDesign(.serif)
                .flatMap { NSFont(descriptor: $0, size: textSize) } ?? base
            let clock = NSFont.monospacedDigitSystemFont(ofSize: textSize, weight: .regular)
            let nameSize = (label.name as NSString).size(withAttributes: [.font: serif])
            let timeSize = (label.time as NSString).size(withAttributes: [.font: clock])
            return (index, CGSize(width: ceil(nameSize.width + textSize * 0.4 + timeSize.width) + 2,
                                  height: ceil(max(nameSize.height, timeSize.height)) + 2))
        })
        let points = scene.pins.map { (index: $0.index, point: CGPoint(x: CGFloat($0.x), y: CGFloat($0.y))) }
        let radius = CGFloat(4) * WorldMapScene.unit(width: bounds.width)
        let placed = MapLabelLayout.place(points: points, sizes: sizes, in: bounds, gap: 6,
                                          avoid: avoid, dotRadius: radius)
        #expect(placed.map(\.index) == [0, 1, 2])
        for label in placed {
            #expect(CGRect(origin: .zero, size: bounds).contains(box(label)))
            #expect(avoid.allSatisfy { !$0.intersects(box(label)) })
            for other in placed where other.index > label.index {
                #expect(!box(label).intersects(box(other)))
            }
            for other in points where other.index != label.index {
                let dot = CGRect(x: other.point.x - radius, y: other.point.y - radius,
                                 width: 2 * radius, height: 2 * radius)
                #expect(!dot.intersects(box(label)))
            }
        }
    }
}
