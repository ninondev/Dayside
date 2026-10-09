// SPDX-License-Identifier: GPL-3.0-only
// 补充记录真实像素，原有测试与生产绘制保持原样。
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Dayside

@Suite(.serialized)
@MainActor
struct SkyRasterOracleDiagnosticsTests {
    private struct RGB {
        let r: Double
        let g: Double
        let b: Double
        var components: [Double] { [r, g, b] }
        var luminance: Double { MapRaster.luminance(r: r, g: g, b: b) }
    }

    /// 与原有像素助手采用同一种位图坐标，不另加翻转或插值。
    private struct Raster {
        let width: Int
        let height: Int
        let bytes: [UInt8]
        init(_ image: CGImage) throws {
            let w = image.width, h = image.height
            var storage = [UInt8](repeating: 0, count: w * h * 4)
            try storage.withUnsafeMutableBytes { buffer in
                let context = try #require(CGContext(data: buffer.baseAddress, width: w, height: h,
                    bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            width = w
            height = h
            bytes = storage
        }
        func pixel(x: Int, row: Int) throws -> RGB {
            try #require(x >= 0 && x < width && row >= 0 && row < height,
                         "Diagnostic pixel must be inside the actual image")
            let offset = (row * width + x) * 4
            return RGB(r: Double(bytes[offset]) / 255,
                       g: Double(bytes[offset + 1]) / 255,
                       b: Double(bytes[offset + 2]) / 255)
        }
    }

    private struct Sample {
        let id: String
        let colors: SkyPanel.Colors
    }

    private func rgb(_ color: Color) throws -> RGB {
        let value = try #require(NSColor(color).usingColorSpace(.sRGB))
        return RGB(r: value.redComponent, g: value.greenComponent, b: value.blueComponent)
    }

    private func ratio(_ a: RGB, _ b: RGB) -> Double {
        (max(a.luminance, b.luminance) + 0.05) / (min(a.luminance, b.luminance) + 0.05)
    }

    private func emit(_ value: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        print("SKY_RASTER_ORACLE " + String(decoding: data, as: UTF8.self))
    }

    private func imageMetadata(_ image: CGImage) -> [String: Any] {
        ["width": image.width, "height": image.height,
         "bitsPerComponent": image.bitsPerComponent, "bitsPerPixel": image.bitsPerPixel,
         "bytesPerRow": image.bytesPerRow, "alphaInfo": image.alphaInfo.rawValue,
         "bitmapInfo": image.bitmapInfo.rawValue,
         "colorSpace": image.colorSpace?.name.map { String(describing: $0) } ?? "unknown"]
    }

    /// 调用方明确给出新目录时，保留原始截图。
    @discardableResult
    private func retain(_ image: CGImage, name: String) throws -> String? {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["DAYSIDE_SKY_TEST_ARTIFACT_DIR"] ?? environment["TEST_RUNNER_DAYSIDE_SKY_TEST_ARTIFACT_DIR"],
              !directory.isEmpty else { return nil }
        // 诊断任务名只选容器内的临时子目录，不改变沙盒。
        let job = URL(fileURLWithPath: directory, isDirectory: true).lastPathComponent
        try #require(job.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil,
                     "诊断任务名必须是单个有效目录名")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(job, isDirectory: true)
        let path = folder.appendingPathComponent("sky-raster-oracle-" + name + ".png")
        var receipt: [String: Any] = ["source": "SkyRasterOracleDiagnosticsTests", "stage": "before-write",
            "requested": directory, "jobBasename": job, "directory": folder.path, "png": path.path]
        try artifactReceipt(receipt)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #require(!FileManager.default.fileExists(atPath: path.path), "Retain diagnostics in a fresh directory")
        let representation = NSBitmapImageRep(cgImage: image)
        let png = try #require(representation.representation(using: .png, properties: [:]))
        try png.write(to: path, options: .atomic)
        receipt["stage"] = "written"
        receipt["pngBytes"] = png.count
        try artifactReceipt(receipt)
        return path.path
    }

    private func artifactReceipt(_ receipt: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
        print("SKY_TEST_ARTIFACT " + String(decoding: data, as: UTF8.self))
    }

    private func nativeCalibrationImage<V: View>(_ content: V, size: CGSize) async throws -> (CGImage, [String: Any]) {
        let hosting = NSHostingView(rootView: content.frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10000, y: -10000), size: size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.frame = CGRect(origin: .zero, size: size)
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        // 等宿主版面稳定，不改全局外观与应用偏好。
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        var prior = CGRect.null
        var stable = 0
        var iterations = 0
        repeat {
            hosting.layoutSubtreeIfNeeded()
            hosting.needsDisplay = true
            window.displayIfNeeded()
            iterations += 1
            if hosting.bounds == prior { stable += 1 } else { prior = hosting.bounds; stable = 0 }
            try await Task.sleep(for: .milliseconds(50))
        } while (stable < 3 || iterations < 4) && clock.now < deadline
        try #require(hosting.bounds.width == size.width && hosting.bounds.height == size.height && stable >= 3,
                     "Native calibration layout did not settle within its deadline")
        let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let image = try #require(rep.cgImage)
        return (image, ["hostingIsFlipped": hosting.isFlipped, "settleIterations": iterations,
                        "contentEffectiveAppearance": hosting.effectiveAppearance.name.rawValue,
                        "windowEffectiveAppearance": window.effectiveAppearance.name.rawValue,
                        "windowWasVisible": window.isVisible])
    }

    @Test func asymmetricCalibrationDocumentsBothRasterConventions() async throws {
        let content = VStack(spacing: 0) {
            Color(.sRGB, red: 1, green: 0, blue: 0)
            Color(.sRGB, red: 0, green: 0, blue: 1)
        }.frame(width: 80, height: 40)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        let generated = try #require(renderer.cgImage)
        let native = try await nativeCalibrationImage(content, size: CGSize(width: 80, height: 40))
        for (source, image, host) in [("ImageRenderer", generated, [String: Any]()),
                                      ("NSHostingView", native.0, native.1)] {
            let raster = try Raster(image)
            let first = try raster.pixel(x: raster.width / 2, row: 0)
            let last = try raster.pixel(x: raster.width / 2, row: raster.height - 1)
            // 上下两色必须实际画出，日志记录位图行对应的方向。
            #expect(abs(first.r - last.r) > 0.8 && abs(first.b - last.b) > 0.8)
            let path = try retain(image, name: "calibration-" + source)
            try emit(["kind": "asymmetric-calibration", "source": source,
                      "visualTop": "red", "visualBottom": "blue", "contextRow0": first.components,
                      "contextRowHeightMinus1": last.components, "image": imageMetadata(image),
                      "host": host, "png": path ?? "not requested"])
        }
    }

    private func opposedRustSamples() throws -> [Sample] {
        let london = TimeZoneEntry(timezoneID: "Europe/London", cityName: "London",
            coordinate: .init(latitude: 51.51, longitude: -0.13), countryCode: "GB")
        let summer = Date(timeIntervalSince1970: 1_782_000_000)
        var result = [Sample]()
        for hour in 0..<24 {
            let instant = summer.addingTimeInterval(Double(hour) * 3600)
            let panel = SkyPanel.compute(instant: instant, now: instant, zones: [london],
                                        need: 5.5, locale: Locale(identifier: "en"))
            let colors = try #require(panel.rows[london.id]).colors
            if !result.contains(where: { $0.colors.ink == colors.ink }) {
                result.append(Sample(id: "London-hour-\(hour)", colors: colors))
            }
            if result.count == 2 { break }
        }
        try #require(result.count == 2, "Real Rust fixtures must include opposed sky roles")
        return result
    }

    @Test func exactFrozenGlyphFixtureLogsDirectAndMirroredSamples() throws {
        for sample in try opposedRustSamples() {
            let background = try rgb(sample.colors.midColor)
            let foreground = SkyTextRole.panelGlyph.foreground(in: sample.colors)
            for up in [false, true] {
                let path = SkyPanel.SunPath(up: up, fraction: 0.5)
                let renderer = ImageRenderer(content: SunPathGlyph(path: path, foreground: foreground)
                    .foregroundStyle(sample.colors.ink ? LightPalette.paper : LightPalette.ink)
                    .background(sample.colors.midColor))
                renderer.scale = 10
                let image = try #require(renderer.cgImage)
                let raster = try Raster(image)
                let png = try retain(image, name: "glyph-\(sample.id)-up-\(up)")
                let (center, _) = SunPathGlyph.sun(path)
                for (landmark, point) in [("sun-center", center), ("horizon", CGPoint(x: 6, y: 9.5))] {
                    let x = Int(point.x * 10)
                    let directRow = Int(point.y * 10)
                    let mirroredRow = image.height - 1 - directRow
                    let direct = try raster.pixel(x: x, row: directRow)
                    let mirrored = try raster.pixel(x: x, row: mirroredRow)
                    try emit(["kind": "frozen-glyph", "sample": sample.id, "up": up,
                              "skyInk": sample.colors.ink, "landmark": landmark,
                              "point": [Double(point.x), Double(point.y)], "pixelX": x,
                              "directRow": directRow, "mirroredRow": mirroredRow,
                              "directRGB": direct.components, "mirroredRGB": mirrored.components,
                              "backgroundRGB": background.components, "expectedRGB": try rgb(foreground).components,
                              "directContrast": ratio(direct, background), "mirroredContrast": ratio(mirrored, background),
                              "requiredContrast": 3, "image": imageMetadata(image), "png": png ?? "not requested"])
                }
            }
        }
    }

    @Test func exactFrozenRimFixtureLogsBoundaryPixelsAndNeighbors() throws {
        let samples = try opposedRustSamples()
        let light = try #require(samples.first { $0.colors.ink })
        let dark = try #require(samples.first { !$0.colors.ink })
        for (sample, chrome) in [(light, dark.colors), (dark, light.colors)] {
            let panel = SkyPanel(rows: [:], dividers: [:], chrome: chrome, dayHere: nil)
            for (role, radius, lineWidth, points) in [
                (SkyTextRole.sliderGlyph, 10.0, 1.5, [CGPoint(x: 1.2, y: 5.9), CGPoint(x: 2.2, y: 6.2)]),
                (.stripGlyph, 5.5, 1.25, [CGPoint(x: 2.5, y: 1.4), CGPoint(x: 2.9, y: 1.6)])
            ] {
                let diameter = radius * 2
                let content = Circle().strokeBorder(SkyGlyphRimStyle(luminance: LightPalette.luminance(sample.colors.mid),
                    role: role, radius: radius, halfBand: 4), lineWidth: lineWidth)
                    .frame(width: diameter, height: diameter)
                    .background {
                        ZStack { chrome.midColor; Rectangle().fill(sample.colors.midColor).frame(height: 8) }
                    }
                    .environment(\.colorScheme, chrome.scheme).environment(\.panelSky, panel)
                    .environment(\.panelFollowsSky, true)
                let renderer = ImageRenderer(content: content)
                renderer.scale = 20
                let image = try #require(renderer.cgImage)
                let raster = try Raster(image)
                let png = try retain(image, name: "rim-\(sample.id)-\(role.rawValue)")
                for point in points + points.map({ CGPoint(x: $0.x, y: diameter - $0.y) }) {
                    let inside = abs(point.y - radius) < 4
                    let background = try rgb(inside ? sample.colors.midColor : chrome.midColor)
                    let expected = try rgb(inside ? role.foreground(in: sample.colors) : role.foreground(in: chrome))
                    let opposite = try rgb(inside ? role.foreground(in: chrome) : role.foreground(in: sample.colors))
                    let x = Int(point.x * 20), row = Int(point.y * 20)
                    for (dx, dy) in [(0, 0), (0, -2), (0, -1), (0, 1), (0, 2), (-1, 0), (1, 0)] {
                        let drawn = try raster.pixel(x: x + dx, row: row + dy)
                        let delta = [abs(drawn.r - expected.r), abs(drawn.g - expected.g), abs(drawn.b - expected.b)]
                        let neighborPointY = (Double(row + dy) + 0.5) / 20
                        try emit(["kind": "frozen-rim", "sample": sample.id, "role": role.rawValue,
                                  "skyInk": sample.colors.ink, "radius": radius, "lineWidth": lineWidth,
                                  "point": [Double(point.x), Double(point.y)], "insideOriginalPoint": inside,
                                  "originalPixel": [x, row], "pixel": [x + dx, row + dy], "offset": [dx, dy],
                                  "pixelCenterY": neighborPointY, "pixelCenterInside": abs(neighborPointY - radius) < 4,
                                  "drawnRGB": drawn.components, "expectedRGB": expected.components,
                                  "oppositeRGB": opposite.components, "backgroundRGB": background.components,
                                  "channelDelta": delta, "frozenEqualityTolerance": 1.0 / 255,
                                  "frozenEqualityPass": delta.allSatisfy { $0 <= 1.0 / 255 },
                                  "contrast": ratio(drawn, background), "requiredContrast": 3,
                                  "image": imageMetadata(image), "png": png ?? "not requested"])
                    }
                }
            }
        }
    }
}
