// SPDX-License-Identifier: GPL-3.0-only
// 真正的地点行同屏画明暗两种天，最后一行文字从自己的位置量底色。

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Dayside

@Suite(.serialized)
@MainActor
struct SkyLocalRenderTests {
    private struct Pixel {
        let r, g, b: Double
        var luminance: Double { MapRaster.luminance(r: r, g: g, b: b) }
        func distance(to other: Pixel) -> Double {
            max(max(abs(r - other.r), abs(g - other.g)), abs(b - other.b))
        }
    }

    private struct Raster {
        let width, height: Int
        let bytes: [UInt8]
        let image: CGImage
        init(_ image: CGImage) throws {
            let width = image.width
            let height = image.height
            var values = [UInt8](repeating: 0, count: width * height * 4)
            try values.withUnsafeMutableBytes { buffer in
                guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                    throw OracleFailure.unresolved("RGBA capture context is missing")
                }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            self.image = image
            self.width = width
            self.height = height
            bytes = values
        }
        func pixel(x: Int, y: Int) -> Pixel {
            let i = (y * width + x) * 4
            return Pixel(r: Double(bytes[i]) / 255, g: Double(bytes[i + 1]) / 255, b: Double(bytes[i + 2]) / 255)
        }
    }

    private func diagnostic(_ raster: Raster, name: String, notes: [String: String] = [:]) throws {
        // 诊断任务名只选容器内的临时子目录，不改变沙盒。
        let environment = ProcessInfo.processInfo.environment
        guard let output = environment["DAYSIDE_SKY_TEST_ARTIFACT_DIR"] ?? environment["TEST_RUNNER_DAYSIDE_SKY_TEST_ARTIFACT_DIR"],
              !output.isEmpty else { return }
        let job = URL(fileURLWithPath: output, isDirectory: true).lastPathComponent
        try #require(job.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil,
                     "诊断任务名必须是单个有效目录名")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(job, isDirectory: true)
        let safeName = name.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" }
        let stem = String(safeName) + "-" + UUID().uuidString
        let png = directory.appendingPathComponent(stem + ".png")
        let jsonPath = directory.appendingPathComponent(stem + ".json")
        var receipt: [String: Any] = ["source": "SkyLocalRenderTests", "stage": "before-write",
            "requested": output, "jobBasename": job, "directory": directory.path,
            "png": png.path, "json": jsonPath.path]
        try artifactReceipt(receipt)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try #require(NSBitmapImageRep(cgImage: raster.image).representation(using: .png, properties: [:]))
        try data.write(to: png)
        var metadata = notes
        metadata["width"] = String(raster.width)
        metadata["height"] = String(raster.height)
        metadata["png"] = png.path
        let json = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: jsonPath)
        receipt["stage"] = "written"
        receipt["pngBytes"] = data.count
        receipt["jsonBytes"] = json.count
        try artifactReceipt(receipt)
        print("SKY_RENDER_ARTIFACT \(png.path) \(notes)")
    }

    private func artifactReceipt(_ receipt: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
        print("SKY_TEST_ARTIFACT " + String(decoding: data, as: UTF8.self))
    }

    private func rgb(_ pixel: Pixel) -> String {
        "\(pixel.r),\(pixel.g),\(pixel.b)"
    }

    @Test func nativeRasterTopAndBottomLandmarksAgreeBetweenRenderers() async throws {
        // 非对称地标先量坐标方向，不拿太阳弧或文字形状猜上下。
        let bars = VStack(spacing: 0) {
            Color(.sRGB, red: 1, green: 0, blue: 0).frame(height: 40)
            Color(.sRGB, red: 0, green: 0, blue: 1).frame(height: 40)
        }.frame(width: 80, height: 80)
        let renderer = ImageRenderer(content: bars)
        renderer.scale = 2
        let rendered = try Raster(#require(renderer.cgImage))
        let native = try await hosted(bars, size: CGSize(width: 80, height: 80), scheme: .light)
        for (name, raster) in [("image-renderer-landmark", rendered), ("ns-host-landmark", native)] {
            let x = raster.width / 2
            let upperY = raster.height / 4
            let lowerY = raster.height * 3 / 4
            let top = raster.pixel(x: x, y: upperY)
            let bottom = raster.pixel(x: x, y: lowerY)
            let rawIndex = (upperY * raster.width + x) * 4
            let rawTop = "\(raster.bytes[rawIndex]),\(raster.bytes[rawIndex + 1]),\(raster.bytes[rawIndex + 2])"
            try diagnostic(raster, name: name, notes: ["sampledTop": rgb(top), "sampledBottom": rgb(bottom), "rawTopBytes": rawTop])
            #expect(top.r > 0.9 && top.b < 0.1, "\(name) 的 top-left 像素应是红色，实际 \(rgb(top)); rawTop=\(rawTop)")
            #expect(bottom.b > 0.9 && bottom.r < 0.1, "\(name) 的下半部应是蓝色，实际 \(rgb(bottom))")
        }
    }

    @Test func actualSunGlyphDiagnosticAtTenTimesScale() throws {
        let instant = Date(timeIntervalSince1970: 1_791_021_600)
        let places = zones()
        let rows = SkyPanel.compute(instant: instant, now: instant, zones: places, need: 5.5, locale: Locale(identifier: "en"))
        for zone in places {
            let row = try #require(rows.rows[zone.id])
            for up in [false, true] {
                let path = SkyPanel.SunPath(up: up, fraction: 0.5)
                let renderer = ImageRenderer(content: SunPathGlyph(path: path, foreground: SkyTextRole.panelGlyph.foreground(in: row.colors))
                    .background(row.colors.midColor))
                renderer.scale = 10
                let raster = try Raster(#require(renderer.cgImage))
                let (center, _) = SunPathGlyph.sun(path)
                try diagnostic(raster, name: "sun-glyph-\(zone.cityName)-up-\(up)", notes: ["center": "\(center.x),\(center.y)", "rowMid": row.colors.mid, "rowInk": String(row.colors.ink)])
            }
        }
    }

    private final class GeometryEvent {
        private(set) var frame: CGRect?
        private(set) var revision = 0
        func observe(_ value: CGRect) {
            if value != frame { frame = value; revision += 1 }
        }
    }

    private struct TokenSpan {
        let token: String
        let minX, maxX: Double
        var geometrySource = "font-estimated"
    }

    private struct CoreReading {
        let token: String
        let foreground: Pixel
        let background: Pixel
        let pixels: Int
        let minimumContrast: Double
        let plateauScore: Double
        let supportedCohorts: Int
        let spanMinX, spanMaxX, changedMinX, changedMaxX, coreMinX, coreMaxX: Double
        let geometrySource: String
    }

    private struct SunLineReading {
        let first, last: Int
        let cores: [CoreReading]
        var passes: Bool { !cores.isEmpty && cores.allSatisfy { $0.minimumContrast >= 4.5 } }
    }

    private enum OracleFailure: Error {
        case unresolved(String)
        case wordValidity(token: String, reason: String)
    }

    // 语义字块只定待检位置，不用预期字色选择像素。
    private func tokenSpans(_ text: String, font: NSFont, origin: Double = 16) throws -> [TokenSpan] {
        let ns = text as NSString
        let words = try NSRegularExpression(pattern: "\\S+")
        return words.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            let left = ns.substring(to: match.range.location) as NSString
            let right = ns.substring(to: NSMaxRange(match.range)) as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: font]
            return TokenSpan(token: ns.substring(with: match.range),
                minX: origin + Double(left.size(withAttributes: attributes).width),
                maxX: origin + Double(right.size(withAttributes: attributes).width))
        }
    }

    private func sunSentence(_ row: SkyPanel.Row, zone: TimeZoneEntry, settings: AppSettings, locale: Locale) -> String {
        let format = { (unix: Double) in
            TimeFormatting.string(for: Date(timeIntervalSince1970: unix), in: zone.timeZone,
                format: ClockFormat(hourStyle: settings.clockFormat.hourStyle, showSeconds: false))
        }
        return [row.sunrise.map { String(format: L10n.string("日出 %@", locale: locale), format($0)) },
                row.sunset.map { String(format: L10n.string("日落 %@", locale: locale), format($0)) }]
            .compactMap { $0 }.joined(separator: "  ")
    }

    private func sunLine(_ raster: Raster, row: CGRect, scale: Double, detailSize: Double,
                         spans: [TokenSpan]) throws -> SunLineReading {
        guard spans.count >= 4 else { throw OracleFailure.unresolved("Both semantic sun events need their words and times") }
        let x0 = Int(ceil((row.minX + 16) * scale))
        let x1 = Int(floor((row.minX + min(390, row.width - 40)) * scale))
        let y0 = Int(ceil((row.minY + row.height * 0.67) * scale))
        let y1 = Int(floor(row.maxY * scale)) - Int(7 * scale)
        guard x0 >= 0, x1 <= raster.width, y0 >= 0, y1 <= raster.height, x1 > x0, y1 > y0 else {
            throw OracleFailure.unresolved("Actual row or sun scan is clipped")
        }
        let referenceX = Array(Int((row.minX + 8) * scale)..<Int((row.minX + 12) * scale)) +
            Array(Int((row.maxX - 8) * scale)..<Int((row.maxX - 4) * scale))
        struct Changed { let x, y: Int; let pixel: Pixel; let delta: Double }
        var backgrounds = [Int: Pixel]()
        var changed = [Changed]()
        var active = [Int]()
        for y in y0..<y1 {
            let refs = referenceX.map { raster.pixel(x: $0, y: y) }
            guard !refs.isEmpty else { throw OracleFailure.unresolved("No blank sky margin") }
            func median(_ values: [Double]) -> Double {
                let sorted = values.sorted()
                return sorted[sorted.count / 2]
            }
            let sky = Pixel(r: median(refs.map(\.r)), g: median(refs.map(\.g)), b: median(refs.map(\.b)))
            guard refs.allSatisfy({ $0.distance(to: sky) <= 8.0 / 255 }) else {
                throw OracleFailure.unresolved("Same-y blank sky margins disagree")
            }
            backgrounds[y] = sky
            var hits = 0
            for x in x0..<x1 {
                let value = raster.pixel(x: x, y: y)
                let delta = value.distance(to: sky)
                if delta >= 4.0 / 255 {
                    changed.append(Changed(x: x, y: y, pixel: value, delta: delta))
                    hits += 1
                }
            }
            if hits >= 3 { active.append(y) }
        }
        guard let last = active.last else { throw OracleFailure.unresolved("Sun text is absent or indistinguishable") }
        guard Double(last) / scale - row.minY >= row.height * 0.78 else {
            throw OracleFailure.unresolved("Last cluster is above the sun line")
        }
        var first = last
        for y in active.reversed() {
            if first - y > Int(3 * scale) { break }
            first = y
        }
        guard last - first >= Int(detailSize * 0.25 * scale) else {
            throw OracleFailure.unresolved("Sun cluster has no meaningful glyph height")
        }
        let cluster = changed.filter { $0.y >= first && $0.y <= last }
        guard let left = cluster.map(\.x).min(), let right = cluster.map(\.x).max(),
              Double(right - left) >= 24 * scale else { throw OracleFailure.unresolved("Sun cluster is too narrow") }
        var cores = [CoreReading]()
        for span in spans {
            let low = Int(floor((row.minX + span.minX) * scale))
            let high = Int(ceil((row.minX + span.maxX) * scale))
            guard low >= x0 - 1, high <= x1 + 1 else {
                throw OracleFailure.unresolved("Expected semantic word is outside the scan")
            }
            let word = cluster.filter { $0.x >= max(x0, low) && $0.x < min(x1, high) }
            guard word.contains(where: { $0.delta >= 4.0 / 255 }) else {
                throw OracleFailure.wordValidity(token: span.token, reason: "Expected word \(span.token) is missing or invisible")
            }
            guard let changedLeft = word.map(\.x).min(), let changedRight = word.map(\.x).max() else {
                throw OracleFailure.wordValidity(token: span.token, reason: "Missing horizontal glyph coverage")
            }
            let expectedWidth = max(1, Double(high - low))
            guard Double(changedRight - changedLeft + 1) >= expectedWidth * 0.5 else {
                throw OracleFailure.wordValidity(token: span.token, reason: "Changed glyph coverage does not validate semantic span")
            }
            func key(_ value: Pixel) -> Int {
                (Int((value.r * 255).rounded()) << 16) | (Int((value.g * 255).rounded()) << 8) | Int((value.b * 255).rounded())
            }
            struct Cohort {
                let center: Pixel
                let key: Int
                let points: [Changed]
                let score: Double
                let left, right: Int
                let direction: Pixel
            }
            let observed = Dictionary(grouping: word, by: { key($0.pixel) })
            var supported = [Cohort]()
            // 日出日落整句同色；同字内的同向淡片可能是抗锯齿。
            // 重复实测色块按离底色的距离排，不看对比度或预期字色。
            for (centerKey, sameColor) in observed {
                guard let center = sameColor.first?.pixel else { continue }
                let red = centerKey >> 16
                let green = (centerKey >> 8) & 255
                let blue = centerKey & 255
                var points = [Changed]()
                for r in max(0, red - 2)...min(255, red + 2) {
                    for g in max(0, green - 2)...min(255, green + 2) {
                        for b in max(0, blue - 2)...min(255, blue + 2) {
                            if let nearby = observed[(r << 16) | (g << 8) | b] {
                                // 循环已按整数色阶限定两格，避免浮点除法在边界误差一格。
                                points.append(contentsOf: nearby)
                            }
                        }
                    }
                }
                guard points.count >= 8, let coreLeft = points.map(\.x).min(),
                      let coreRight = points.map(\.x).max(),
                      Double(coreRight - coreLeft + 1) >= expectedWidth * 0.35,
                      let score = points.map(\.delta).min() else { continue }
                let count = Double(points.count)
                let direction = Pixel(
                    r: points.reduce(0) { $0 + $1.pixel.r - backgrounds[$1.y]!.r } / count,
                    g: points.reduce(0) { $0 + $1.pixel.g - backgrounds[$1.y]!.g } / count,
                    b: points.reduce(0) { $0 + $1.pixel.b - backgrounds[$1.y]!.b } / count)
                supported.append(Cohort(center: center, key: centerKey, points: points, score: score,
                    left: coreLeft, right: coreRight, direction: direction))
            }
            guard let selected = supported.max(by: {
                if $0.score != $1.score { return $0.score < $1.score }
                if $0.points.count != $1.points.count { return $0.points.count < $1.points.count }
                return $0.key < $1.key
            }) else {
                throw OracleFailure.wordValidity(token: span.token,
                    reason: "No repeated observed plateau has eight pixels and validated horizontal coverage: source=\(span.geometrySource)")
            }
            // 反向的独立色块不能借正确字块通过；同方向淡片仍可能是抗锯齿。
            guard supported.allSatisfy({
                $0.direction.r * selected.direction.r + $0.direction.g * selected.direction.g + $0.direction.b * selected.direction.b >= 0
            }) else {
                throw OracleFailure.wordValidity(token: span.token, reason: "Separately supported opposing foreground directions")
            }
            let dominant = selected.center
            let core = selected.points
            let coreLeft = selected.left
            let coreRight = selected.right
            let readings = core.map { (ratio($0.pixel, backgrounds[$0.y]!), $0) }
            guard let worst = readings.min(by: { $0.0 < $1.0 }) else { throw OracleFailure.wordValidity(token: span.token, reason: "No actual word core") }
            cores.append(CoreReading(token: span.token, foreground: dominant,
                background: backgrounds[worst.1.y]!, pixels: core.count, minimumContrast: worst.0,
                plateauScore: selected.score, supportedCohorts: supported.count,
                spanMinX: Double(low), spanMaxX: Double(high), changedMinX: Double(changedLeft), changedMaxX: Double(changedRight),
                coreMinX: Double(coreLeft), coreMaxX: Double(coreRight), geometrySource: span.geometrySource))
        }
        return SunLineReading(first: first, last: last, cores: cores)
    }

    private func wordReceipt(_ reading: SunLineReading, context: String) throws {
        for core in reading.cores {
            let receipt: [String: Any] = ["context": context, "token": core.token,
                "foregroundRGB": [core.foreground.r, core.foreground.g, core.foreground.b],
                "backgroundRGB": [core.background.r, core.background.g, core.background.b],
                "contrast": core.minimumContrast, "requiredContrast": 4.5, "corePixels": core.pixels,
                "spanPixels": [core.spanMinX, core.spanMaxX], "changedPixels": [core.changedMinX, core.changedMaxX],
                "coreExtentPixels": [core.coreMinX, core.coreMaxX], "geometrySource": core.geometrySource,
                "plateauScoreSkyRGBDistance": core.plateauScore, "supportedCohorts": core.supportedCohorts,
                "selection": "strongest repeated observed plateau; score independent of contrast and expected pigment"]
            let data = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
            print("SKY_NATIVE_WORD_CORE " + String(decoding: data, as: UTF8.self))
        }
    }

    private func pigment(_ color: Color) throws -> Pixel {
        let c = try #require(NSColor(color).usingColorSpace(.sRGB))
        return Pixel(r: c.redComponent, g: c.greenComponent, b: c.blueComponent)
    }

    private func ratio(_ a: Pixel, _ b: Pixel) -> Double {
        (max(a.luminance, b.luminance) + 0.05) / (min(a.luminance, b.luminance) + 0.05)
    }

    private struct NativeSnapshot {
        let raster: Raster
        let windowAppearance: NSAppearance.Name
        let contentAppearance: NSAppearance.Name
        let windowMatches: Bool
        let contentMatches: Bool
    }

    @MainActor
    private final class NativeRenderHost<Content: View> {
        private var view: NSHostingView<Content>?
        private var window: NSWindow?
        private let requested: NSAppearance.Name

        init(content: Content, size: CGSize, scheme: ColorScheme) {
            requested = scheme == .dark ? .darkAqua : .aqua
            let pair = autoreleasepool { () -> (NSHostingView<Content>, NSWindow) in
                let view = NSHostingView(rootView: content)
                let appearance = NSAppearance(named: requested)
                view.appearance = appearance
                let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10000, y: -10000), size: size),
                    styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = appearance
                window.contentView = view
                view.frame = CGRect(origin: .zero, size: size)
                window.orderFront(nil)
                return (view, window)
            }
            view = pair.0
            window = pair.1
        }

        func capture() throws -> NativeSnapshot {
            try autoreleasepool {
                guard let view = self.view else { throw OracleFailure.unresolved("Native host view is missing") }
                guard let window = self.window else { throw OracleFailure.unresolved("Native host window is missing") }
                view.layoutSubtreeIfNeeded()
                view.needsDisplay = true
                window.displayIfNeeded()
                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                    throw OracleFailure.unresolved("Native capture bitmap representation is missing")
                }
                view.cacheDisplay(in: view.bounds, to: rep)
                guard let image = rep.cgImage else { throw OracleFailure.unresolved("Native capture CGImage is missing") }
                let raster = try Raster(image)
                let windowActual = window.effectiveAppearance
                let contentActual = view.effectiveAppearance
                return NativeSnapshot(raster: raster, windowAppearance: windowActual.name,
                    contentAppearance: contentActual.name,
                    windowMatches: windowActual.bestMatch(from: [.aqua, .darkAqua]) == requested,
                    contentMatches: contentActual.bestMatch(from: [.aqua, .darkAqua]) == requested)
            }
        }

        func close() {
            autoreleasepool {
                window?.orderOut(nil)
                window?.contentView = nil
                window?.close()
                view = nil
                window = nil
            }
        }

    }

    private func hosted<Content: View>(_ content: Content, size: CGSize, scheme: ColorScheme,
                                       ready: @escaping @MainActor () -> Bool = { true },
                                       geometryRevision: @escaping @MainActor () -> Int = { 0 }) async throws -> Raster {
        let geometryEvent = GeometryEvent()
        let root = content.onGeometryChange(for: CGRect.self, of: { $0.frame(in: .local) }) { geometryEvent.observe($0) }
        let host = NativeRenderHost(content: root, size: size, scheme: scheme)
        defer { host.close() }
        // 真正的测量事件与连续稳定绘制都到齐才读图，超时直接失败。
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        var previous: [UInt8]?
        var priorRevision: Int?
        var stable = 0
        repeat {
            let snapshot = try host.capture()
            let raster = snapshot.raster
            let requested: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
            let nativeMatches = snapshot.windowMatches && snapshot.contentMatches
            let revision = geometryEvent.revision + geometryRevision()
            let measured = geometryEvent.frame?.size == size && ready() && nativeMatches
            if measured && priorRevision == revision && previous == raster.bytes { stable += 1 } else { stable = 0 }
            previous = measured ? raster.bytes : nil
            priorRevision = measured ? revision : nil
            if stable >= 3 {
                #expect(snapshot.windowMatches)
                #expect(snapshot.contentMatches)
                let receipt: [String: Any] = ["requestedAppearance": requested.rawValue,
                    "windowEffectiveAppearance": snapshot.windowAppearance.rawValue,
                    "contentEffectiveAppearance": snapshot.contentAppearance.rawValue,
                    "geometryRevision": revision, "stablePaints": stable, "width": raster.width, "height": raster.height]
                let data = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
                print("SKY_NATIVE_HOST_STATE " + String(decoding: data, as: UTF8.self))
                host.close()
                return raster
            }
            try await Task.sleep(for: .milliseconds(50))
        } while clock.now < deadline
        throw OracleFailure.unresolved("Native geometry event and stable paint did not settle within five seconds")
    }

    private func zones() -> [TimeZoneEntry] {
        [TimeZoneEntry(timezoneID: "Europe/London", cityName: "London",
                       coordinate: Coordinate(latitude: 51.51, longitude: -0.13), countryCode: "GB"),
         TimeZoneEntry(timezoneID: "Asia/Tokyo", cityName: "Tokyo",
                       coordinate: Coordinate(latitude: 35.68, longitude: 139.69), countryCode: "JP")]
    }

    @Test(arguments: ["light", "dark"], [false, true])
    func fullProductionRowsKeepBothSunLinesReadableInOnePanel(appearance: String, increased: Bool) async throws {
        let scheme: ColorScheme = appearance == "dark" ? .dark : .light
        let instant = Date(timeIntervalSince1970: 1_791_021_600) // 伦敦上午、东京夜里。
        let places = zones()
        let panel = SkyPanel.compute(instant: instant, now: instant, zones: places,
                                     need: increased ? 7 : 5.5, locale: Locale(identifier: "en"), flat: increased)
        let rows = try places.map { try #require(panel.rows[$0.id]) }
        #expect(rows[0].colors.ink && !rows[1].colors.ink, "同屏夹具必须一明一暗")
        #expect(rows.allSatisfy { $0.sunrise != nil && $0.sunset != nil }, "真正的日出日落文字不能缺席")
        let (defaults, cleanup) = TestDefaults.make(prefix: "dayside.sky.fullrow")
        defer { cleanup() }
        Store.saveZones(places, to: defaults)
        let model = AppModel(defaults: defaults, migrate: false, applySystemIntegration: false)
        model.now = instant
        for size in TextSize.allCases {
            for mode in DisplayMode.allCases {
                for offset in [false, true] {
                    var settings = model.settings
                    settings.panelColors = .sky
                    settings.panelShowsSunTimes = true
                    settings.textSize = size
                    settings.displayMode = mode
                    settings.showOffsetBesideName = offset
                    settings.interfaceLanguage = .en
                    model.settings = settings
                    let metrics = SkyRowMetrics(settings: settings, textScale: size.scale)
                    let rowEvents = places.map { _ in GeometryEvent() }
                    let panelID = UUID()
                    let content = VStack(spacing: 0) {
                        ForEach(places) { zone in
                            TimeZoneRowView(zone: zone, availableWidth: 640, onRename: {})
                                .background(SkyRowBackground(row: panel.rows[zone.id]!))
                                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(panelID)) }) { frame in
                                    if let index = places.firstIndex(where: { $0.id == zone.id }) { rowEvents[index].observe(frame) }
                                }
                        }
                    }
                    .environment(model).environment(model.core)
                    .environment(\.panelSky, panel).environment(\.panelFollowsSky, true)
                    .environment(\.textScale, size.scale).environment(\.locale, Locale(identifier: "en"))
                    .environment(\.colorScheme, scheme)
                    .environment(\.colorSchemeContrast, increased ? .increased : .standard)
                    .foregroundStyle(panel.chrome.foreground)
                    .frame(width: 640, height: metrics.rowHeight * 2).coordinateSpace(name: panelID)
                    let raster = try await hosted(content, size: CGSize(width: 640, height: metrics.rowHeight * 2), scheme: scheme,
                        ready: { rowEvents.allSatisfy { $0.frame?.height == metrics.rowHeight && $0.frame?.width == 640 } },
                        geometryRevision: { rowEvents.reduce(0) { $0 + $1.revision } })
                    let scale = Double(raster.height) / Double(metrics.rowHeight * 2)
                    for index in rows.indices {
                        let text = sunSentence(rows[index], zone: places[index], settings: settings, locale: model.uiLocale)
                        let spans = try tokenSpans(text, font: NSFont.monospacedDigitSystemFont(ofSize: metrics.detailSize, weight: .regular))
                        let actualFrame = try #require(rowEvents[index].frame)
                        let reading: SunLineReading
                        do {
                            reading = try sunLine(raster, row: actualFrame, scale: scale, detailSize: metrics.detailSize, spans: spans)
                        } catch {
                            try diagnostic(raster, name: "unresolved-row-\(places[index].cityName)-\(appearance)-\(increased)-\(size)-\(mode)-\(offset)",
                                notes: ["unresolved": String(describing: error)])
                            throw error
                        }
                        if !reading.passes {
                            try diagnostic(raster, name: "row-\(places[index].cityName)-\(appearance)-\(increased)-\(size)-\(mode)-\(offset)")
                        }
                        try wordReceipt(reading, context: "production-\(places[index].cityName)-\(appearance)-\(increased)-\(size)-\(mode)-\(offset)")
                        #expect(reading.passes, "Every actual sun-event word must reach 4.5 against its same-y sky")
                        for core in reading.cores {
                            #expect(core.pixels >= 8)
                            #expect(core.minimumContrast >= 4.5)
                            print("SKY_FULL_ROW_CORE \(places[index].cityName) token=\(core.token) foreground=\(rgb(core.foreground)) background=\(rgb(core.background)) ratio=\(core.minimumContrast) pixels=\(core.pixels) \(appearance) contrast=\(increased) size=\(size) mode=\(mode) offset=\(offset)")
                        }
                    }
                }
            }
        }
    }

    @Test func localModifierUsesTheColorBehindTheLineInsteadOfTopOrInkFlag() async throws {
        let panel = SkyPanel.compute(instant: Date(timeIntervalSince1970: 1_791_021_600), now: Date(timeIntervalSince1970: 1_791_021_600),
                                     zones: zones(), need: 5.5, locale: Locale(identifier: "en"))
        let rows = Array(panel.rows.values)
        let light = try #require(rows.first { $0.colors.ink })
        let dark = try #require(rows.first { !$0.colors.ink })
        let colors = SkyPanel.Colors(top: light.colors.mid, horizon: dark.colors.mid, mid: dark.colors.mid, ink: true, ratio: 0)
        let row = SkyPanel.Row(known: true, colors: colors, gradient: true, word: nil, path: nil, sunrise: nil, sunset: nil)
        let id = UUID()
        let localLine = GeometryEvent()
        let content = VStack(spacing: 0) {
            Color.clear.frame(height: 78)
            Text(verbatim: "SUNRISE 07:00 SUNSET 18:00").font(.system(size: 12, weight: .bold))
                .modifier(SkyRowLocalForeground(row: row, rowID: id, height: 100, followsSky: true))
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(id)) }) { localLine.observe($0) }
            Spacer(minLength: 0)
        }.frame(width: 260, height: 100).coordinateSpace(name: id).background(SkyRowBackground(row: row))
        let raster = try await hosted(content, size: CGSize(width: 260, height: 100), scheme: .light,
            ready: { (localLine.frame?.midY ?? 0) >= 78 }, geometryRevision: { localLine.revision })
        let scale = Double(raster.height) / 100
        let paper = try pigment(LightPalette.paper)
        var found = 0
        for y in Int(79 * scale)..<Int(96 * scale) {
            for x in 0..<raster.width where raster.pixel(x: x, y: y).distance(to: paper) < 0.025 { found += 1 }
        }
        if found < 8 { try diagnostic(raster, name: "local-modifier-stress", notes: ["top": row.colors.top, "horizon": row.colors.horizon, "mid": row.colors.mid, "found": String(found)]) }
        #expect(found >= 8, "文字脚下是深天，顶上浅天与故意反向的 ink 标志都不能让它变成墨字")
    }

    @Test(arguments: ["light", "dark"], [false, true])
    func observedSunCoreOracleRejectsWrongAndAbsentWords(appearance: String, increased: Bool) async throws {
        let scheme: ColorScheme = appearance == "dark" ? .dark : .light
        let instant = Date(timeIntervalSince1970: 1_791_021_600)
        let places = zones()
        let panel = SkyPanel.compute(instant: instant, now: instant, zones: places, need: 5.5, locale: Locale(identifier: "en"))
        let sentence = "Sunrise 07:00  Sunset 18:00"
        let tokens = ["Sunrise", "07:00", "Sunset", "18:00"]
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let estimatedSpans = try tokenSpans(sentence, font: font)
        let space = (" " as NSString).size(withAttributes: [.font: font]).width
        for place in places {
            let actual = try #require(panel.rows[place.id])
            let flat = SkyPanel.Row(known: true, colors: actual.colors, gradient: false,
                word: nil, path: nil, sunrise: nil, sunset: nil)
            let good = SkyTextRole.panelSunTimes.foreground(on: LightPalette.luminance(flat.colors.mid))
            let bad = LightPalette.paperReads(on: LightPalette.luminance(flat.colors.mid)) ? LightPalette.ink : LightPalette.paper
            for witness in ["good", "good-split", "wrong", "absent", "mixed"] {
                let lower = GeometryEvent()
                let words = tokens.map { _ in GeometryEvent() }
                let coordinateID = UUID()
                let content = ZStack(alignment: .topLeading) {
                    SkyRowBackground(row: flat)
                    Text(verbatim: "Correct day-word line").font(.system(size: 12))
                        .foregroundStyle(good).offset(x: 16, y: 48)
                    Group {
                        if witness == "good" {
                            Text(verbatim: sentence).foregroundStyle(good)
                        } else {
                            HStack(spacing: space) {
                                ForEach(tokens.indices, id: \.self) { index in
                                    Group {
                                        if witness == "absent" {
                                            Color.clear.frame(width: (tokens[index] as NSString).size(withAttributes: [.font: font]).width, height: 16)
                                        } else {
                                            Text(verbatim: tokens[index])
                                                .foregroundStyle(witness == "wrong" || (witness == "mixed" && index >= 2) ? bad : good)
                                        }
                                    }
                                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(coordinateID)) }) { words[index].observe($0) }
                                }
                            }
                        }
                    }
                    .font(.system(size: 12).monospacedDigit()).fixedSize()
                    .offset(x: 16, y: 78)
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(coordinateID)) }) { lower.observe($0) }
                }
                .frame(width: 640, height: 100).coordinateSpace(name: coordinateID)
                .environment(\.colorScheme, scheme)
                .environment(\.colorSchemeContrast, increased ? .increased : .standard)
                let raster = try await hosted(content, size: CGSize(width: 640, height: 100), scheme: scheme,
                    ready: { lower.frame != nil && (witness == "good" || words.allSatisfy { $0.frame != nil }) },
                    geometryRevision: { lower.revision + words.reduce(0) { $0 + $1.revision } })
                let scale = Double(raster.height) / 100
                let spans: [TokenSpan]
                if witness == "good" { spans = estimatedSpans } else {
                    spans = try tokens.indices.map { index in
                        let frame = try #require(words[index].frame)
                        return TokenSpan(token: tokens[index], minX: Double(frame.minX), maxX: Double(frame.maxX), geometrySource: "measured-native-word")
                    }
                }
                var reading: SunLineReading?
                var failure: OracleFailure?
                do {
                    reading = try sunLine(raster, row: CGRect(x: 0, y: 0, width: 640, height: 100), scale: scale, detailSize: 12, spans: spans)
                } catch let error as OracleFailure { failure = error }
                let failedTokens = reading?.cores.filter { $0.minimumContrast < 4.5 }.map(\.token) ?? []
                var causalToken: String?
                if case .wordValidity(let token, _)? = failure { causalToken = token }
                let accepted = reading?.passes == true
                let context = "oracle-\(witness)-\(place.cityName)-\(appearance)-\(increased)"
                if let reading { try wordReceipt(reading, context: context) }
                let receipt: [String: Any] = ["context": context, "accepted": accepted,
                    "failedTokens": failedTokens, "failure": failure.map { String(describing: $0) } ?? "none",
                    "causalToken": causalToken ?? "none", "wordFrames": words.map { String(describing: $0.frame) }]
                let data = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
                print("SKY_NATIVE_WORD_WITNESS " + String(decoding: data, as: UTF8.self))
                try diagnostic(raster, name: context, notes: ["witness": witness, "accepted": String(accepted), "failure": failure.map { String(describing: $0) } ?? "none"])
                if witness == "good" || witness == "good-split" {
                    let measured = try #require(reading, "Good single and same-layout split words must resolve solid cores")
                    #expect(measured.passes)
                    #expect(measured.cores.allSatisfy { $0.pixels >= 8 && $0.minimumContrast >= 4.5 })
                } else if witness == "mixed" {
                    #expect(!accepted)
                    #expect(failedTokens.contains(where: { ["Sunset", "18:00"].contains($0) }) || causalToken.map { ["Sunset", "18:00"].contains($0) } == true,
                        "Mixed rejection must identify the deliberately bad word, not an unrelated fixture failure")
                } else if witness == "wrong" {
                    #expect(!accepted)
                    let indistinguishable: Bool
                    if case .unresolved(let reason)? = failure { indistinguishable = reason == "Sun text is absent or indistinguishable" }
                    else { indistinguishable = false }
                    #expect(!failedTokens.isEmpty || causalToken.map { tokens.contains($0) } == true || indistinguishable,
                        "Wrong pigment must cause actual word rejection or wholly indistinguishable glyphs")
                } else {
                    #expect(!accepted)
                    if case .unresolved(let reason)? = failure {
                        #expect(reason == "Sun text is absent or indistinguishable")
                    } else {
                        #expect(Bool(false), "Absent last line must fail actual presence")
                    }
                }
            }
        }
    }

    private struct Lane: Decodable { let stops: [SkyStripState.Stop] }
    private struct Input: Encodable { let start, end, latitude, longitude, step: Double }

    @Test(arguments: ["light", "dark"], [false, true])
    func actualVerticalRowStripAndLegendSwatchesKeepTheirBordersReadable(appearance: String, increased: Bool) throws {
        let scheme: ColorScheme = appearance == "dark" ? .dark : .light
        let instant = Date(timeIntervalSince1970: 1_791_021_600)
        let rows = Array(SkyPanel.compute(instant: instant, now: instant, zones: zones(),
            need: 5.5, locale: Locale(identifier: "en")).rows.values)
        let light = try #require(rows.first { $0.colors.ink })
        let night = try #require(rows.first { !$0.colors.ink })
        let reversedFlag = SkyPanel.Row(known: true,
            colors: SkyPanel.Colors(top: light.colors.mid, horizon: night.colors.mid,
                                   mid: night.colors.mid, ink: true, ratio: 0),
            gradient: true, word: nil, path: nil, sunrise: nil, sunset: nil)
        for row in rows + [reversedFlag] {
            let strip = ImageRenderer(content: SkyRowBackground(row: row)
                .frame(width: 4, height: 100).clipShape(Capsule())
                .overlay(Capsule().strokeBorder(SkyRowForegroundStyle(row: row), lineWidth: 0.5))
                .environment(\.colorScheme, scheme)
                .environment(\.colorSchemeContrast, increased ? .increased : .standard))
            strip.scale = 20
            let actual = try Raster(#require(strip.cgImage))
            for y in [400, 1600] {
                let ink = actual.pixel(x: 5, y: y)
                let sky = actual.pixel(x: 40, y: y)
                #expect(ratio(ink, sky) >= 3, "系统底色行的真实竖天色带描边 \(appearance), contrast=\(increased), y=\(y)")
                #expect(ink.distance(to: try pigment(SkyTextRole.laneGlyph.foreground(on: sky.luminance))) < 0.025)
            }
        }
        for sample in [MeetingLegend.nightSample, MeetingLegend.twilightSample, MeetingLegend.daySample] {
            let swatch = ImageRenderer(content: SkyLegendSwatch(color: sample.color, luminance: sample.luminance)
                .environment(\.colorScheme, scheme)
                .environment(\.colorSchemeContrast, increased ? .increased : .standard))
            swatch.scale = 20
            let actual = try Raster(#require(swatch.cgImage))
            let ink = actual.pixel(x: 100, y: increased ? 10 : 8)
            let sky = actual.pixel(x: 100, y: 80)
            #expect(ratio(ink, sky) >= 3, "真实排会图例天色样描边 \(appearance), contrast=\(increased)")
            #expect(ink.distance(to: try pigment(SkyTextRole.laneGlyph.foreground(on: sky.luminance))) < 0.025)
        }
    }

    @Test(arguments: ["light", "dark"], [false, true])
    func actualDayLaneInkGradientKeepsEveryStrokePositionReadable(appearance: String, increased: Bool) throws {
        let lane: Lane = RustCore.invoke("sky.lane", Input(start: 1_782_000_000, end: 1_782_086_400,
            latitude: 51.51, longitude: -0.13, step: 2))
        let scheme: ColorScheme = appearance == "dark" ? .dark : .light
        let renderer = ImageRenderer(content: Rectangle().fill(SkyLaneForegroundStyle(stops: lane.stops))
            .frame(width: 1441, height: 4).environment(\.colorScheme, scheme)
            .environment(\.colorSchemeContrast, increased ? .increased : .standard))
        let raster = try Raster(#require(renderer.cgImage))
        let shade = scheme == .dark && !increased ? 0.22 : 0
        for minute in 0...1440 {
            let luminance = try #require(LightPalette.skyLuminance(stops: lane.stops, at: Double(minute) / 1440, shade: shade))
            let foreground = raster.pixel(x: minute, y: 2)
            let measured = (max(foreground.luminance, luminance) + 0.05) / (min(foreground.luminance, luminance) + 0.05)
            #expect(measured >= 3, "昼夜条真正描边 minute=\(minute), \(appearance), contrast=\(increased): \(measured)")
        }
    }

    @Test(arguments: ["light", "dark"], [false, true])
    func realLaneMarkerAndTableShapesUseTheFullRibbonCoordinates(appearance: String, increased: Bool) throws {
        let scheme: ColorScheme = appearance == "dark" ? .dark : .light
        let start = Date(timeIntervalSince1970: 1_790_985_600)
        let frame = DayLaneFrame(start: start, length: 86_400, timeZoneID: "Europe/London")
        let coordinate = Coordinate(latitude: 51.51, longitude: -0.13)
        let lane: Lane = RustCore.invoke("sky.lane", Input(start: start.timeIntervalSince1970,
            end: start.timeIntervalSince1970 + 86_400, latitude: 51.51, longitude: -0.13, step: 2))
        let ribbon = try #require(SkyStripMemo.ribbonImage(lane.stops, width: 720))
        for at in [0.1, 0.5] {
            let reference = start.addingTimeInterval(at * frame.length)
            // 真正的 DayLane 走 Rust 命令与生产 stroke，包含其实际衬边和深色压暗。
            let day = ImageRenderer(content: DayLane(frame: frame, coordinate: coordinate, reference: reference)
                .frame(width: 720, height: 12).environment(\.colorScheme, scheme)
                .environment(\.colorSchemeContrast, increased ? .increased : .standard))
            day.scale = 10
            let raster = try Raster(#require(day.cgImage))
            let x = Int(at * 7200)
            let background = raster.pixel(x: x + 40, y: 45)
            let foreground = raster.pixel(x: x, y: 45)
            #expect(ratio(foreground, background) >= 3, "真正昼夜条 reference=\(at), \(appearance), contrast=\(increased)")
            let paper = LightPalette.paperReads(on: background.luminance)
            #expect(foreground.distance(to: try pigment(SkyTextRole.laneGlyph.foreground(paper: paper))) < 0.025,
                    "细线不能把自己的零宽 path 当作渐变整条坐标")

            // 换算与排会使用的真实 MarkerLine、ColumnLines、BandTicks，均保留生产线宽与衬边。
            let shapes = ImageRenderer(content: ZStack {
                Image(decorative: ribbon, scale: 1).resizable().interpolation(.high)
                    .overlay { if scheme == .dark && !increased { Color.black.opacity(0.22) } }
                MarkerLine(at: at).stroke(SkyLaneForegroundStyle(stops: lane.stops, backing: true), lineWidth: 3.5)
                MarkerLine(at: at).stroke(SkyLaneForegroundStyle(stops: lane.stops), lineWidth: 1.5)
                ColumnLines(from: at + 0.05, to: at + 0.1)
                    .stroke(SkyLaneForegroundStyle(stops: lane.stops, backing: true), lineWidth: 3.5)
                ColumnLines(from: at + 0.05, to: at + 0.1)
                    .stroke(SkyLaneForegroundStyle(stops: lane.stops), lineWidth: 1.5)
                BandTicks(marks: [.init(at: at + 0.15, full: true)])
                    .stroke(SkyLaneForegroundStyle(stops: lane.stops, backing: true), lineWidth: 2.5)
                BandTicks(marks: [.init(at: at + 0.15, full: true)])
                    .stroke(SkyLaneForegroundStyle(stops: lane.stops), lineWidth: 1)
            }.frame(width: 720, height: 12).environment(\.colorScheme, scheme)
                .environment(\.colorSchemeContrast, increased ? .increased : .standard))
            shapes.scale = 10
            let table = try Raster(#require(shapes.cgImage))
            let base = ImageRenderer(content: Image(decorative: ribbon, scale: 1).resizable().interpolation(.high)
                .overlay { if scheme == .dark && !increased { Color.black.opacity(0.22) } }
                .frame(width: 720, height: 12).environment(\.colorScheme, scheme)
                .environment(\.colorSchemeContrast, increased ? .increased : .standard))
            base.scale = 10
            let baseSky = try Raster(#require(base.cgImage))
            #expect(baseSky.width == table.width && baseSky.height == table.height)
            let markers = [at, at + 0.05, at + 0.1, at + 0.15].map { Int(($0 * 7200).rounded()) }
            var comparisons = 0
            var maximumBackgroundDelta = 0.0
            var maximumBackgroundCodepointDelta = 0
            for controlX in stride(from: 40, to: table.width - 40, by: 36) where markers.allSatisfy({ abs($0 - controlX) > 25 }) {
                let actual = table.pixel(x: controlX, y: 45)
                let expected = baseSky.pixel(x: controlX, y: 45)
                let delta = actual.distance(to: expected)
                // 容差仍是一格，直接比较整数色阶，避免除以 255 后的边界误差。
                let redDelta = abs(Int((actual.r * 255).rounded()) - Int((expected.r * 255).rounded()))
                let greenDelta = abs(Int((actual.g * 255).rounded()) - Int((expected.g * 255).rounded()))
                let blueDelta = abs(Int((actual.b * 255).rounded()) - Int((expected.b * 255).rounded()))
                let codepointDelta = max(redDelta, max(greenDelta, blueDelta))
                maximumBackgroundDelta = max(maximumBackgroundDelta, delta)
                maximumBackgroundCodepointDelta = max(maximumBackgroundCodepointDelta, codepointDelta)
                comparisons += 1
                #expect(codepointDelta <= 1, "Independent base sky must equal actual same-x non-marker pixels within one codepoint")
            }
            #expect(comparisons >= 8)
            print("SKY_TABLE_BACKGROUND_CONTROL appearance=\(appearance) contrast=\(increased) at=\(at) comparisons=\(comparisons) maximumDelta=\(maximumBackgroundDelta) maximumCodepointDelta=\(maximumBackgroundCodepointDelta) requiredCodepoints=1")
            for marker in [at, at + 0.05, at + 0.1, at + 0.15] {
                let position = Int((marker * 7200).rounded())
                let ink = table.pixel(x: position, y: 45)
                let sky = baseSky.pixel(x: position, y: 45)
                #expect(ratio(ink, sky) >= 3, "真正表格 shape x=\(marker), \(appearance), contrast=\(increased)")
                let expected = try pigment(SkyTextRole.laneGlyph.foreground(on: sky.luminance))
                if ink.distance(to: expected) >= 0.025 {
                    try diagnostic(table, name: "table-shape-\(appearance)-\(increased)-\(at)-\(marker)", notes: ["marker": String(marker), "ink": rgb(ink), "sky": rgb(sky), "expected": rgb(expected), "skyLuminance": String(sky.luminance), "position": String(position)])
                }
                #expect(ink.distance(to: expected) < 0.025, "marker=\(marker), ink=\(rgb(ink)), sky=\(rgb(sky)), expected=\(rgb(expected))")
            }
        }

        let state = SkyStripState(stops: lane.stops, marker: 0.9, now: nil, beyond: false, dayHere: false, marks: [])
        let strip = ImageRenderer(content: SkyRibbon(state: state, ribbon: ribbon, scrubbing: false)
            .frame(width: 720, height: 16).environment(\.colorScheme, scheme)
            .environment(\.colorSchemeContrast, increased ? .increased : .standard))
        strip.scale = 20
        let actualStrip = try Raster(#require(strip.cgImage))
        // 带子在 16 点高区域正中；上边描边中心是 4 + lineWidth/2。
        let borderY = Int((4 + (increased ? 0.5 : 0.375)) * 20)
        for at in [0.1, 0.5] {
            let x = Int(at * 14_400)
            let ink = actualStrip.pixel(x: x, y: borderY)
            let sky = actualStrip.pixel(x: x, y: 8 * 20)
            #expect(ratio(ink, sky) >= 3, "真实工具天色带描边 \(appearance), contrast=\(increased), x=\(at)")
        }

        // 面板滑块的真实未压暗渐变与 Capsule 半点描边，深色外观也不压暗。
        let center = start.addingTimeInterval(36_000)
        let sliderState = SkyStripState.compute(now: center, instant: center, coordinate: coordinate, marks: false)
        #expect(!sliderState.stops.isEmpty)
        let sliderGradient = Gradient(stops: sliderState.stops.map {
            .init(color: LightPalette.color($0.color), location: $0.at)
        })
        let slider = ImageRenderer(content: Capsule()
            .fill(LinearGradient(gradient: sliderGradient, startPoint: .leading, endPoint: .trailing))
            .overlay(Capsule().strokeBorder(SkyLaneForegroundStyle(stops: sliderState.stops,
                shadeInDarkAppearance: false), lineWidth: 0.5))
            .frame(width: 720, height: 6).environment(\.colorScheme, scheme)
            .environment(\.colorSchemeContrast, increased ? .increased : .standard))
        slider.scale = 20
        let actualSlider = try Raster(#require(slider.cgImage))
        for at in [0.1, 0.5] {
            let x = Int(at * 14_400)
            let ink = actualSlider.pixel(x: x, y: 5)
            let sky = actualSlider.pixel(x: x, y: 60)
            #expect(ratio(ink, sky) >= 3, "真实滑块轨道描边 \(appearance), contrast=\(increased), x=\(at)")
            #expect(ink.distance(to: try pigment(SkyTextRole.laneGlyph.foreground(on: sky.luminance))) < 0.025)
        }
    }

    private func verifySunRing(_ actual: Raster, sky: Raster, center: CGPoint, radius: Double,
                               lineWidth: Double, scale: Double, context: String) throws {
        struct Point { let x, y: Int; let value, background: Pixel; let delta: Double }
        let reach = radius + lineWidth
        let left = Int(floor((Double(center.x) - reach) * scale))
        let right = Int(ceil((Double(center.x) + reach) * scale))
        let top = Int(floor((Double(center.y) - reach) * scale))
        let bottom = Int(ceil((Double(center.y) + reach) * scale))
        guard left >= 0, top >= 0, right < actual.width, bottom < actual.height,
              sky.width == actual.width, sky.height == actual.height else {
            throw OracleFailure.unresolved("Actual sun ring or independent map sky is clipped")
        }
        var candidates = [Point]()
        for y in top...bottom {
            for x in left...right {
                let dx = (Double(x) + 0.5) / scale - Double(center.x)
                let dy = (Double(y) + 0.5) / scale - Double(center.y)
                let radial = sqrt(dx * dx + dy * dy)
                if abs(radial - radius) > lineWidth * 0.2 { continue }
                let value = actual.pixel(x: x, y: y)
                let background = sky.pixel(x: x, y: y)
                let delta = value.distance(to: background)
                if delta >= 4.0 / 255 {
                    candidates.append(Point(x: x, y: y, value: value, background: background, delta: delta))
                }
            }
        }
        func key(_ value: Pixel) -> Int {
            let red = Int((value.r * 255).rounded())
            let green = Int((value.g * 255).rounded())
            let blue = Int((value.b * 255).rounded())
            return (red << 16) | (green << 8) | blue
        }
        let observed = Dictionary(grouping: candidates, by: { key($0.value) })
        var chosen = [Point]()
        var chosenCenter: Pixel?
        var chosenScore = -Double.infinity
        var chosenKey = -1
        for (centerKey, sameColor) in observed {
            guard let pigment = sameColor.first?.value else { continue }
            let red = centerKey >> 16
            let green = (centerKey >> 8) & 255
            let blue = centerKey & 255
            var core = [Point]()
            for r in max(0, red - 2)...min(255, red + 2) {
                for g in max(0, green - 2)...min(255, green + 2) {
                    for b in max(0, blue - 2)...min(255, blue + 2) {
                        if let points = observed[(r << 16) | (g << 8) | b] { core.append(contentsOf: points) }
                    }
                }
            }
            guard core.count >= 8, let score = core.map(\.delta).min() else { continue }
            let betterScore = score > chosenScore
            let sameScore = score == chosenScore
            let betterCount = core.count > chosen.count
            let sameCount = core.count == chosen.count
            if betterScore || (sameScore && betterCount) || (sameScore && sameCount && centerKey > chosenKey) {
                chosen = core; chosenCenter = pigment; chosenScore = score; chosenKey = centerKey
            }
        }
        let foreground = try #require(chosenCenter, "Actual sun ring must have eight repeated measured core pixels: \(context)")
        let measurements = chosen.map { (ratio($0.value, $0.background), $0) }
        let worst = try #require(measurements.min(by: { $0.0 < $1.0 }))
        let minimum = worst.0
        if minimum < 3 {
            try diagnostic(actual, name: "sun-ring-\(context)", notes: ["foreground": rgb(foreground), "background": rgb(worst.1.background), "minimum": String(minimum)])
        }
        #expect(chosen.count >= 8)
        #expect(minimum >= 3, "Actual sun ring must contrast its actual sky by3:1: \(context)")
        print("SKY_SUN_RING_CORE context=\(context) center=\(rgb(foreground)) background=\(rgb(worst.1.background)) pixels=\(chosen.count) score=\(chosenScore) minimum=\(minimum) radius=\(radius) lineWidth=\(lineWidth)")
    }

    private func verifySunRings(_ actual: Raster, sky: Raster, center: CGPoint, scale: Double,
                                large: Bool, handle: Bool, dragging: Bool, context: String) throws {
        let r = large ? 8.0 : 4.5
        try verifySunRing(actual, sky: sky, center: center, radius: r + 0.5,
            lineWidth: 1, scale: scale, context: context + "-inner-sky")
        try verifySunRing(actual, sky: sky, center: center, radius: r + 1.4,
            lineWidth: 0.8, scale: scale, context: context + "-outer-sky")
        if handle {
            try verifySunRing(actual, sky: sky, center: center, radius: r + 4,
                lineWidth: 1.2, scale: scale, context: context + "-handle-sky")
        }
        if dragging {
            try verifySunRing(actual, sky: sky, center: center, radius: 2.2 * r - 0.75,
                lineWidth: 1.5, scale: scale, context: context + "-drag-sky")
        }
    }

    @Test(arguments: ["light", "dark"], [false, true])
    func actualSunRingsReadOnRustPaletteAndRealMapCaller(appearance: String, increased: Bool) async throws {
        let scheme: ColorScheme = appearance == "dark" ? .dark : .light
        let contrast: ColorSchemeContrast = increased ? .increased : .standard
        let london = zones()[0]
        let polar = TimeZoneEntry(timezoneID: "Arctic/Longyearbyen", cityName: "Longyearbyen",
            coordinate: Coordinate(latitude: 78.22, longitude: 15.65), countryCode: "NO")
        var backgrounds = [(String, String)]()
        let summer = Date(timeIntervalSince1970: 1_782_000_000)
        for hour in 0..<24 {
            let instant = summer.addingTimeInterval(Double(hour) * 3600)
            let panel = SkyPanel.compute(instant: instant, now: instant, zones: [london], need: increased ? 7 : 5.5, locale: Locale(identifier: "en"))
            let row = try #require(panel.rows[london.id])
            backgrounds.append(("London-hour-\(hour)", row.colors.mid))
        }
        for (name, unix) in [("polar-day", 1_782_043_200.0), ("polar-night", 1_797_854_400.0)] {
            let instant = Date(timeIntervalSince1970: unix)
            let panel = SkyPanel.compute(instant: instant, now: instant, zones: [polar], need: increased ? 7 : 5.5, locale: Locale(identifier: "en"))
            let row = try #require(panel.rows[polar.id])
            #expect(row.sunrise == nil && row.sunset == nil)
            backgrounds.append((name, row.colors.mid))
        }
        let size = CGSize(width: 80, height: 80)
        let center = CGPoint(x: 40, y: 40)
        for (name, hex) in backgrounds {
            let skyColor = LightPalette.color(hex)
            let luminance = LightPalette.luminance(hex)
            let baseView = skyColor.frame(width: size.width, height: size.height)
            let baseRenderer = ImageRenderer(content: baseView)
            baseRenderer.scale = 10
            let base = try Raster(#require(baseRenderer.cgImage))
            for large in [false, true] {
                for handle in [false, true] {
                    for dragging in [false, true] {
                        let mark = MapSunMark(large: large, handle: handle, dragging: dragging,
                            point: center, luminance: { _ in luminance })
                        let painted = mark.frame(width: size.width, height: size.height).background(skyColor)
                            .environment(\.colorScheme, scheme).environment(\.colorSchemeContrast, contrast)
                        let renderer = ImageRenderer(content: painted)
                        renderer.scale = 10
                        let actual = try Raster(#require(renderer.cgImage))
                        let context = "\(name)-\(appearance)-\(increased)-large\(large)-handle\(handle)-drag\(dragging)"
                        try verifySunRings(actual, sky: base, center: center, scale: 10,
                            large: large, handle: handle, dragging: dragging, context: context)
                    }
                }
            }
            await Task.yield()
        }
        let instant = Date(timeIntervalSince1970: 1_791_021_600)
        let latitudeSpan: Double = WorldMapScene.standard.upperBound - WorldMapScene.standard.lowerBound
        let mapSize = CGSize(width: 360, height: CGFloat(latitudeSpan))
        let scene = WorldMapScene.scene(instant: instant, size: mapSize, places: [], latitudes: WorldMapScene.standard)
        #expect(scene.sun.count == 2)
        let sun = CGPoint(x: try #require(scene.sun.first), y: try #require(scene.sun.last))
        for large in [false, true] {
            let rawMap = try #require(MapRaster.render(instant: instant, size: mapSize, scale: 2,
                latitudes: WorldMapScene.standard, lights: 0, large: large))
            let independentSky = try Raster(rawMap.image)
            for handle in [false, true] {
                for dragging in [false, true] {
                    let map = WorldMapScene(instant: instant, places: [], large: large, lights: 0,
                        sunHandle: handle, sunDragging: dragging, showsMoon: false, rasterScale: 2, cornerRadius: 0)
                    let painted = map.frame(width: mapSize.width, height: mapSize.height)
                        .environment(\.colorScheme, scheme).environment(\.colorSchemeContrast, contrast)
                    let actual = try await hosted(painted, size: mapSize, scheme: scheme)
                    let scale = Double(actual.width) / Double(mapSize.width)
                    #expect(scale == 2, "Caller map and independent Rust raster must have the same actual pixel grid")
                    let context = "real-caller-\(appearance)-\(increased)-large\(large)-handle\(handle)-drag\(dragging)"
                    try verifySunRings(actual, sky: independentSky, center: sun, scale: scale,
                        large: large, handle: handle, dragging: dragging, context: context)
                }
            }
        }
    }

}
