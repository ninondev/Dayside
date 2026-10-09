// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI
import Testing
@testable import Dayside

@MainActor
struct HourRulerRegressionTests {
    nonisolated struct TickCase: Sendable {
        let every: Int
        let hour: Int
        let height: Int
        let twelve: Int
        let twentyFour: Int
    }

    nonisolated static let cases: [TickCase] = [3, 6].flatMap { every in
        [14, 20].flatMap { height in
            [(0, 12, 0), (12, 12, 12), (18, 6, 18)].map { hour, twelve, twentyFour in
                TickCase(every: every, hour: hour, height: height, twelve: twelve, twentyFour: twentyFour)
            }
        }
    }

    @Test(arguments: [HourStyle.force12, .force24], cases)
    func tickRendersTheSelectedHourFormat(style: HourStyle, tick: TickCase) throws {
        let (defaults, cleanup) = TestDefaults.make(prefix: "hour-ruler")
        defer { cleanup() }
        let model = AppModel(defaults: defaults, migrate: false, applySystemIntegration: false)
        model.settings.hourStyle = style
        model.settings.interfaceLanguage = .en
        let frame = DayLaneFrame(start: Date(timeIntervalSince1970: 1_767_225_600),
                                 length: 86_400, timeZoneID: "UTC")
        let actual = try render(DayLaneRuler(frame: frame, every: tick.every).environment(model.core), height: tick.height)
        let number = style == .force12 ? tick.twelve : tick.twentyFour
        let x = max(8, Double(tick.hour) / 24 * 720)
        let expected = try render(Text(verbatim: number.formatted(.number.locale(model.core.uiLocale)))
            .font(.caption2).foregroundStyle(.readableSecondary).fixedSize()
            .position(x: x, y: Double(tick.height - 3) / 2), height: tick.height)
        // 只比午夜、正午和傍晚的字形，底下的刻线不参与；两种间距和高度都核对。
        let crop = CGRect(x: max(0, (x - 25) * 2), y: 0, width: 100, height: Double(tick.height - 4) * 2)
        let actualLabel = try #require(actual.cropping(to: crop))
        let expectedLabel = try #require(expected.cropping(to: crop))
        #expect(try pixels(actualLabel) == pixels(expectedLabel),
                "\(tick.hour) 点刻度应显示 \(number)，小时制为 \(style.rawValue)，高度为 \(tick.height)")
    }

    @Test(arguments: [InterfaceLanguage.zhHans, .en])
    func exportedPostcardProvidesTwelveHourRenderEvidence(language: InterfaceLanguage) throws {
        let locale = Locale(identifier: try #require(language.localeIdentifier))
        let now = Date(timeIntervalSince1970: 1_789_041_600)
        var draft = SharingDraft()
        draft.timeZoneID = "Asia/Tokyo"
        draft.displayName = "Mei"
        draft.placeName = language == .zhHans ? "东京" : "Tokyo"
        draft.placeCity = language == .zhHans ? "Tokyo" : ""
        draft.latitude = 35.6895
        draft.longitude = 139.6917
        draft.includesAvailability = true
        let document = try #require(SharingGenerator.build(draft: draft, hostURL: "", now: now).document)
        let card = Postcard(document: document, locale: locale, hourStyle: .force12, fallbackPlace: draft.placeName)
        var settings = AppSettings()
        settings.interfaceLanguage = language
        settings.hourStyle = .force12
        let core = TimeCore(zones: [], settings: settings)
        core.now = now
        let image = try #require(PostcardImage.image(for: card, core: core))
        let png = try #require(TimeCardImage.pngData(image))
        _ = try #require(NSBitmapImageRep(data: png))
        // 测试宿主的临时目录保存真实导出，修复前后都能独立目视核对。
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ruler-export-\(locale.identifier)-\(UUID().uuidString).png")
        try png.write(to: url)
        print("RULER_EXPORT_RENDER locale=\(locale.identifier) path=\(url.path)")
    }

    private func render(_ view: some View, height: Int) throws -> CGImage {
        let renderer = ImageRenderer(content: view.frame(width: 720, height: CGFloat(height))
            .background(Color.white).environment(\.colorScheme, .light))
        renderer.scale = 2
        return try #require(renderer.cgImage)
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try #require(context.data)
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self),
                                        count: image.width * image.height * 4))
    }
}
