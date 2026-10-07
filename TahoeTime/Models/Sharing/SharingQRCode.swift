// SPDX-License-Identifier: GPL-3.0-only
import CoreGraphics
import Foundation

/// The time card as a QR code: two people in the same room exchange availability by pointing a
/// camera at a screen, no server, no account. The code carries the hosted link when one is
/// configured and the bare `mt1.` card otherwise; both decode with `TimeCard.person(from:)`.
nonisolated enum SharingQRCode {
    static func payload(for document: SharingDocument) -> String {
        document.shareURL ?? document.fragment
    }

    /// Pixels per module in the generated bitmap.
    static let modulePixels: CGFloat = 6

    /// On-screen size in points. A minimal card is ~51 modules and reads fine at 132 pt; a card with
    /// a fortnight of availability behind a hosted link is ~119 modules and needs about 3 pt per
    /// module to scan from a phone even on a non-Retina display (measured with Vision at 1× plus a
    /// 0.8 px blur; 2.6 was enough for CoreImage's masks, the Rust encoder's penalty-chosen mask on the
    /// 167-byte test card needed a little more).
    static func displaySide(for image: CGImage) -> CGFloat {
        let modules = CGFloat(image.width) / modulePixels
        return min(max(132, (modules * 3.0).rounded(.up)), 300)
    }

    /// 静区：规范建议四个模块，扫码端靠它找边；此前 CoreImage 的输出也带边。
    static let quietModules = 4

    /// Crisp pixels: one module = `scale` device pixels, medium error correction.
    ///
    /// 编码在 Rust（`qr.encode`：字节模式、纠错 M、版本按内容取最小），这里只把 0/1 矩阵用 CoreGraphics
    /// 画成位图。采用纯算法生成二维码，避免 CoreImage 的 `CIContext` 在软件渲染时仍把
    /// Metal 起起来，分享页首帧因此多出 ~17 MB 图形缓冲，主程序还链着整个 CoreImage。
    static func image(for text: String, scale: CGFloat = modulePixels) -> CGImage? {
        guard !text.isEmpty, text.utf8.count <= 2_000 else { return nil }
        struct Input: Encodable { let text: String }
        struct Output: Decodable { let error: String?; let size: Int; let rows: [String] }
        let code: Output = RustCore.invoke("qr.encode", Input(text: text))
        guard code.error == nil, code.size > 0, code.rows.count == code.size else { return nil }
        let modules = code.size + quietModules * 2
        let pixels = Int((CGFloat(modules) * scale).rounded())
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        context.setFillColor(gray: 0, alpha: 1)
        // CoreGraphics 的 y 轴朝上：第 0 行画在最上面。
        for (rowIndex, row) in code.rows.enumerated() {
            for (columnIndex, cell) in row.utf8.enumerated() where cell == UInt8(ascii: "1") {
                let x = CGFloat(columnIndex + quietModules) * scale
                let y = CGFloat(modules - 1 - (rowIndex + quietModules)) * scale
                context.fill(CGRect(x: x, y: y, width: scale, height: scale))
            }
        }
        return context.makeImage()
    }
}
