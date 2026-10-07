// SPDX-License-Identifier: GPL-3.0-only
// 把按窗口 ID 截出的商店截图（四角圆角处为透明像素）合成到一块纯色底上。
// App Store Connect 不收带 alpha 通道的截图，上传前须压掉透明度；本脚本只做这一件事，
// 不缩放、不裁切——输出像素尺寸与输入完全一致，只是把透明像素换成指定底色、其余像素原样合成。
//
// 用法：
//   swift Tools/flatten_png.swift <底色十六进制，如 1E1E1E> <输入目录> <输出目录>
//
// 递归处理输入目录下全部 .png（子目录结构照原样搬到输出目录），非 PNG 文件忽略不复制。
// 处理完逐张打印像素尺寸与写盘后的 hasAlpha 复核结果，任何一张仍带 alpha 即以非零退出。
import CoreGraphics
import Foundation
import ImageIO

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(2)
}

let args = CommandLine.arguments
guard args.count == 4 else {
    fail("用法：swift Tools/flatten_png.swift <底色十六进制，如 1E1E1E> <输入目录> <输出目录>")
}
let hexArg = args[1]
let inputRoot = URL(fileURLWithPath: args[2], isDirectory: true).standardizedFileURL
let outputRoot = URL(fileURLWithPath: args[3], isDirectory: true).standardizedFileURL

func parseHexColor(_ hex: String) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
    var s = hex
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6, let value = UInt32(s, radix: 16) else {
        fail("底色必须是形如 1E1E1E 的 6 位十六进制（不认识：\(hex)）")
    }
    let r = CGFloat((value >> 16) & 0xFF) / 255.0
    let g = CGFloat((value >> 8) & 0xFF) / 255.0
    let b = CGFloat(value & 0xFF) / 255.0
    return (r, g, b)
}
let bg = parseHexColor(hexArg)

let fm = FileManager.default
var isDir: ObjCBool = false
guard fm.fileExists(atPath: inputRoot.path, isDirectory: &isDir), isDir.boolValue else {
    fail("输入目录不存在或不是目录：\(inputRoot.path)")
}
guard inputRoot.path != outputRoot.path else {
    fail("输入输出目录不能相同（会边读边写）：\(inputRoot.path)")
}
guard !outputRoot.path.hasPrefix(inputRoot.path + "/") else {
    fail("输出目录不能嵌在输入目录内部，否则二次调用会把上一份产物当输入重新处理：\(outputRoot.path)")
}

// ---- 递归收集输入目录下的 .png，记录相对路径以便原样镜射子目录结构 ----
guard let enumerator = fm.enumerator(
    at: inputRoot,
    includingPropertiesForKeys: [.isRegularFileKey],
    options: [.skipsHiddenFiles]
) else {
    fail("无法遍历输入目录：\(inputRoot.path)")
}
let inputPrefix = inputRoot.path + "/"
var relPaths: [String] = []
for case let fileURL as URL in enumerator {
    guard fileURL.pathExtension.lowercased() == "png" else { continue }
    let full = fileURL.standardizedFileURL.path
    guard full.hasPrefix(inputPrefix) else { continue }
    relPaths.append(String(full.dropFirst(inputPrefix.count)))
}
relPaths.sort()

guard !relPaths.isEmpty else {
    fail("输入目录下没有找到 .png：\(inputRoot.path)")
}

// ---- 合成：新建一块 32bpp 位图 context，先铺底色，再把原图正常混合画上去 ----
// 用原图自带的色彩空间建 context（而不是固定塞一个 device RGB），避免不透明像素被隐式转色；
// alpha 信息用 .noneSkipLast 参与混合最省事，但实测 ImageIO 给任何 32bpp 图写 PNG 时一律按
// RGBA（color type 6）落盘，哪怕 alphaInfo 说「没有 alpha、末字节忽略」——sips 照样报
// hasAlpha=yes。真正让 PNG 落盘时不含 alpha 通道（color type 2），CGImage 自己必须是
// 紧凑的 24bpp（每像素 3 字节，无填充字节），所以合成完还要手动把第 4 字节剔掉再打包。
func flatten(pngAt inputURL: URL, to outputURL: URL) throws {
    guard let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw NSError(domain: "flatten_png", code: 1, userInfo: [NSLocalizedDescriptionKey: "读不出图"])
    }
    let width = image.width
    let height = image.height
    let space = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: space,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else {
        throw NSError(domain: "flatten_png", code: 2, userInfo: [NSLocalizedDescriptionKey: "建不出位图 context（\(width)x\(height)）"])
    }
    context.setFillColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1.0)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    // 32bpp RGBX（R,G,B,忽略字节，默认字节序即字面顺序）紧缩成 24bpp RGB。
    guard let srcBase = context.data else {
        throw NSError(domain: "flatten_png", code: 6, userInfo: [NSLocalizedDescriptionKey: "读不出合成缓冲区"])
    }
    let srcBytesPerRow = context.bytesPerRow
    let srcData = srcBase.assumingMemoryBound(to: UInt8.self)
    let dstBytesPerRow = width * 3
    var packed = [UInt8](repeating: 0, count: dstBytesPerRow * height)
    packed.withUnsafeMutableBufferPointer { dst in
        let dstBase = dst.baseAddress!
        for row in 0..<height {
            let srcRow = srcData + row * srcBytesPerRow
            let dstRow = dstBase + row * dstBytesPerRow
            for col in 0..<width {
                dstRow[col * 3 + 0] = srcRow[col * 4 + 0]
                dstRow[col * 3 + 1] = srcRow[col * 4 + 1]
                dstRow[col * 3 + 2] = srcRow[col * 4 + 2]
            }
        }
    }
    guard let provider = CGDataProvider(data: Data(packed) as CFData) else {
        throw NSError(domain: "flatten_png", code: 7, userInfo: [NSLocalizedDescriptionKey: "建不出打包后的 data provider"])
    }
    guard let flattened = CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 24,
        bytesPerRow: dstBytesPerRow,
        space: space,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    ) else {
        throw NSError(domain: "flatten_png", code: 3, userInfo: [NSLocalizedDescriptionKey: "取不出打包后的 24bpp 图像"])
    }

    try fm.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, "public.png" as CFString, 1, nil) else {
        throw NSError(domain: "flatten_png", code: 4, userInfo: [NSLocalizedDescriptionKey: "建不出输出文件"])
    }
    CGImageDestinationAddImage(destination, flattened, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "flatten_png", code: 5, userInfo: [NSLocalizedDescriptionKey: "写盘失败"])
    }
}

// ---- 写盘后原样读回来复核：像素尺寸不变、hasAlpha 变 no ----
// 实测 ImageIO 对无 alpha 的 PNG 根本不写 HasAlpha 这个键（不是写 false），
// 键缺失才是「没有 alpha」的正常表现；缺分母不能当「有 alpha」处理，否则永远误报。
func inspect(_ url: URL) -> (width: Int, height: Int, hasAlpha: Bool)? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
        return nil
    }
    let width = props[kCGImagePropertyPixelWidth] as? Int ?? -1
    let height = props[kCGImagePropertyPixelHeight] as? Int ?? -1
    let hasAlpha = (props[kCGImagePropertyHasAlpha] as? Bool) ?? false
    return (width, height, hasAlpha)
}

print("底色 #\(hexArg.uppercased())　输入 \(inputRoot.path)　输出 \(outputRoot.path)　共 \(relPaths.count) 张")
var failures: [String] = []
for rel in relPaths {
    let inputURL = inputRoot.appendingPathComponent(rel)
    let outputURL = outputRoot.appendingPathComponent(rel)
    do {
        try flatten(pngAt: inputURL, to: outputURL)
    } catch {
        print("!! \(rel)：\(error.localizedDescription)")
        failures.append(rel)
        continue
    }
    guard let info = inspect(outputURL) else {
        print("!! \(rel)：写出后读不回来复核")
        failures.append(rel)
        continue
    }
    let alphaMark = info.hasAlpha ? "hasAlpha=yes（!! 仍带 alpha）" : "hasAlpha=no"
    print("\(rel)\t\(info.width)x\(info.height)\t\(alphaMark)")
    if info.hasAlpha { failures.append(rel) }
}

print("完成：\(relPaths.count - failures.count)/\(relPaths.count) 张通过复核")
if !failures.isEmpty {
    print("未过：\(failures.joined(separator: ", "))")
    exit(1)
}
