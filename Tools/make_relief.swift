// SPDX-License-Identifier: GPL-3.0-only
//
//  make_relief.swift
//  把 Natural Earth「Gray Earth with Shaded Relief, Hypsography, and Ocean Bottom」（1:50m，公有领域）
//  裁成地图要的纬度、缩成随包的灰度 PNG。地图逐像素上色时拿它分海陆、压地形（Rust `sky.rs`）。
//
//  取原图：
//    curl -L -o GRAY_50M_SR_OB.zip https://naciscdn.org/naturalearth/50m/raster/GRAY_50M_SR_OB.zip
//    unzip GRAY_50M_SR_OB.zip GRAY_50M_SR_OB.tif     # 10800 × 5400，8 位灰度，覆盖 90°N … 90°S
//  生成：
//    swift Tools/make_relief.swift GRAY_50M_SR_OB.tif TahoeTime/Resources/relief.png [宽，默认 1800]
//  纬度范围写死在这里与 `WorldMapScene.latitudes` 同一组：80°N … 58°S（两极只有冰与空海）。
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let north = 80.0, south = -58.0
let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write("usage: swift make_relief.swift <GRAY_50M_SR_OB.tif> <out.png> [width]\n".data(using: .utf8)!)
    exit(64)
}
let width = arguments.count > 3 ? Int(arguments[3]) ?? 1800 : 1800
let height = Int((Double(width) * (north - south) / 360).rounded())

guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: arguments[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    FileHandle.standardError.write("cannot read \(arguments[1])\n".data(using: .utf8)!)
    exit(66)
}
// 原图覆盖 90°N … 90°S：按纬度裁出需要的那几行。
let top = Int(((90 - north) / 180 * Double(image.height)).rounded())
let bottom = Int(((90 - south) / 180 * Double(image.height)).rounded())
guard let cropped = image.cropping(to: CGRect(x: 0, y: top, width: image.width, height: bottom - top)) else { exit(65) }

guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { exit(70) }
context.interpolationQuality = .high
context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
guard let output = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: arguments[2]) as CFURL, UTType.png.identifier as CFString, 1, nil) else { exit(73) }
CGImageDestinationAddImage(destination, output, nil)
guard CGImageDestinationFinalize(destination) else { exit(74) }
let bytes = (try? FileManager.default.attributesOfItem(atPath: arguments[2])[.size] as? Int) ?? 0
print("\(width) × \(height), \(bytes) bytes → \(arguments[2])")
