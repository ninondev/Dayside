// SPDX-License-Identifier: GPL-3.0-only
import CoreGraphics
import CoreImage
import Foundation
import Testing
import Vision
@testable import TahoeTime

struct SharingQRCodeTests {
    private func decode(_ image: CGImage) throws -> String? {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image).perform([request])
        return request.results?.first?.payloadStringValue
    }

    @Test func aScannedCodeIsTheSameCardAndImportsBack() throws {
        var draft = SharingDraft()
        draft.timeZoneID = "Asia/Tokyo"
        draft.displayName = "Mei"
        let now = Date(timeIntervalSince1970: 1_789_041_600)
        let built = SharingGenerator.build(draft: draft, hostURL: "", now: now)
        let document = try #require(built.document)
        let text = SharingQRCode.payload(for: document)
        #expect(text.hasPrefix("mt1."))
        let image = try #require(SharingQRCode.image(for: text))
        #expect(image.width >= 100 && image.width == image.height)
        let scanned = try #require(try decode(image))
        #expect(scanned == text)
        let imported = try TimeCard.person(from: scanned, now: now).get()
        #expect(imported.contact.timeZoneID == "Asia/Tokyo")
        #expect(imported.contact.name == "Mei")
    }

    /// On a non-Retina display a point is one pixel. A minimal card (~51 modules) at its 132 pt and
    /// the largest realistic card (name, a fortnight of availability, hosted link: ~119 modules) at
    /// its computed size must both scan at 1× and with the softness of a phone photo.
    @Test func theOnScreenSizeStillScansAtOnePixelPerPointAndSlightlyBlurred() throws {
        var full = SharingDraft()
        full.timeZoneID = "America/Argentina/Buenos_Aires"
        full.displayName = "Ana María Fernández"
        full.includesAvailability = true
        var minimal = SharingDraft()
        minimal.timeZoneID = "Asia/Tokyo"
        for (draft, host) in [(full, "https://example.com/when.html"), (minimal, "")] {
            let text = SharingQRCode.payload(for: try #require(SharingGenerator.build(draft: draft, hostURL: host, now: Date(timeIntervalSince1970: 1_789_041_600)).document))
            let image = try #require(SharingQRCode.image(for: text))
            let side = Int(SharingQRCode.displaySide(for: image))
            #expect(side >= 132 && side <= 300)
            let small = try #require(downscale(image, to: side))
            #expect(try decode(small) == text, "\(text.utf8.count) bytes at \(side) px")
            let blurred = try #require(blur(small, radius: 0.8))
            #expect(try decode(blurred) == text, "\(text.utf8.count) bytes at \(side) px blurred")
        }
        let minimalImage = try #require(SharingQRCode.image(for: "mt1.short"))
        #expect(SharingQRCode.displaySide(for: minimalImage) == 132)
    }

    private func downscale(_ image: CGImage, to side: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return context.makeImage()
    }

    private func blur(_ image: CGImage, radius: Double) -> CGImage? {
        let filter = CIFilter(name: "CIGaussianBlur")!
        filter.setValue(CIImage(cgImage: image), forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage else { return nil }
        return CIContext(options: [.useSoftwareRenderer: true]).createCGImage(output, from: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }

    @Test func aHostedCardEncodesTheLinkAndJunkIsRefused() throws {
        var draft = SharingDraft()
        draft.timeZoneID = "Europe/London"
        let built = SharingGenerator.build(draft: draft, hostURL: "https://example.com/when.html", now: Date(timeIntervalSince1970: 1_789_041_600))
        let document = try #require(built.document)
        let text = SharingQRCode.payload(for: document)
        #expect(text.hasPrefix("https://example.com/when.html#mt1."))
        let image = try #require(SharingQRCode.image(for: text))
        #expect(try decode(image) == text)
        #expect(SharingQRCode.image(for: "") == nil)
        #expect(SharingQRCode.image(for: String(repeating: "x", count: 2_001)) == nil)
    }

    /// Rust 编码器的每个版本都要能被 Vision 解回来（版本表抄错一格就在这里露馅）。
    /// 负载按各版本的容量刚好装满（`qr.capacities`），字节里混上 base64url 与 URL 常见字符。
    @Test func everyQRVersionDecodesWithVision() throws {
        let capacities: [Int] = RustCore.invoke("qr.capacities", CoreJSON.null)
        #expect(capacities.count == 40)
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_./:?=&".utf8)
        for (index, capacity) in capacities.enumerated() where capacity <= 2_000 {
            let bytes = (0..<capacity).map { alphabet[($0 * 7 + index) % alphabet.count] }
            let text = String(decoding: bytes, as: UTF8.self)
            let image = try #require(SharingQRCode.image(for: text), "版本 \(index + 1)")
            #expect(image.width == ((index + 1) * 4 + 17 + SharingQRCode.quietModules * 2) * Int(SharingQRCode.modulePixels), "版本 \(index + 1) 的尺寸")
            #expect(try decode(image) == text, "版本 \(index + 1)：\(capacity) 字节")
        }
    }
}
