// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI
import Testing
@testable import TahoeTime

@MainActor
struct AppFontWeightTests {
    @Test(arguments: TextSize.allCases)
    func headingsKeepTheirWeightAtEveryTextSize(size: TextSize) throws {
        let heading = Text(verbatim: "Heading 0123456789")
            .appFont(.headline)
            .environment(\.textScale, size.scale)
        let regular = Text(verbatim: "Heading 0123456789")
            .font(.system(size: AppFont.size(.headline) * size.scale, weight: .regular))
        let bold = Text(verbatim: "Heading 0123456789")
            .font(.system(size: AppFont.size(.headline) * size.scale, weight: .bold))
        let headingInk = try ink(heading)
        let regularInk = try ink(regular)
        #expect(headingInk > regularInk * 1.1)
        #expect(abs(headingInk - (try ink(bold))) < 1)
    }

    @Test(arguments: TextSize.allCases)
    func explicitlyRequestedWeightOverridesTheHeadingStyle(size: TextSize) throws {
        let heading = Text(verbatim: "Heading 0123456789")
            .appFont(.headline, weight: .regular)
            .environment(\.textScale, size.scale)
        let regular = Text(verbatim: "Heading 0123456789")
            .font(.system(size: AppFont.size(.headline) * size.scale, weight: .regular))
        #expect(abs(try ink(heading) - ink(regular)) < 1)
    }

    // 累计真实文字位图的覆盖量；常规体与粗体用同一句话、同一字号。
    private func ink(_ content: some View) throws -> Double {
        let renderer = ImageRenderer(content: content.foregroundStyle(.black).fixedSize()
            .environment(\.colorScheme, .light))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        var total = 0.0
        for offset in stride(from: 3, to: image.width * image.height * 4, by: 4) {
            total += Double(bytes[offset]) / 255
        }
        return total
    }
}
