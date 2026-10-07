// SPDX-License-Identifier: GPL-3.0-only
//
//  make_epigraph.swift
//  题记「天涯共此时」的书法竖幅：中文五个字竖排，用毛笔字而不是印刷体。
//  字形取自流江毛草（Liu Jian Mao Cao，刘正江等，SIL OFL 1.1，无保留字体名），按书法的行气排成一列：
//  每个字自己的大小、左右摆动与上下间距（天大、共小、時收尾放大，中轴左右轻摆），轮廓写成矢量 PDF，
//  进素材目录当模板图用（颜色由宿主给：墨或纸）。App 里不带字体文件，只带这一列字的轮廓。
//  这款字的「时」本身写成「時」的草法，简繁界面共用这一幅（读屏按界面简繁念）。
//
//  字体下载（Google Fonts 仓库，约 5 MB）：
//    curl -sSL -o LiuJianMaoCao-Regular.ttf https://github.com/google/fonts/raw/main/ofl/liujianmaocao/LiuJianMaoCao-Regular.ttf
//  用法：swift Tools/make_epigraph.swift <LiuJianMaoCao-Regular.ttf> TahoeTime/Assets.xcassets/EpigraphZh.imageset [预览.png]
//

import AppKit
import CoreText
import Foundation

/// 一个字：放大倍数（相对 em）、左右摆动（em）、与上一个字之间多留（负数是收紧）的空（em）。
struct Stroke { let character: String; let scale: CGFloat; let sway: CGFloat; let gap: CGFloat }

let column = [
    Stroke(character: "天", scale: 1.08, sway: 0.02, gap: 0),
    Stroke(character: "涯", scale: 1.0, sway: -0.05, gap: -0.06),
    Stroke(character: "共", scale: 0.86, sway: 0.03, gap: -0.02),
    Stroke(character: "此", scale: 0.92, sway: -0.03, gap: -0.04),
    Stroke(character: "时", scale: 1.12, sway: 0.02, gap: -0.02),
]
/// 字与字之间的基本空（em）。
let leading: CGFloat = 0.08
let em: CGFloat = 100

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write(Data("用法：swift Tools/make_epigraph.swift <字体.ttf> <imageset 目录> [预览.png]\n".utf8))
    exit(2)
}
guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(URL(fileURLWithPath: arguments[1]) as CFURL) as? [CTFontDescriptor],
      let descriptor = descriptors.first else {
    FileHandle.standardError.write(Data("读不了字体：\(arguments[1])\n".utf8))
    exit(1)
}

// 一列字的轮廓（y 向下为正，原点在第一字顶上的中轴）。
let path = CGMutablePath()
var top: CGFloat = 0
for stroke in column {
    let font = CTFontCreateWithFontDescriptor(descriptor, em * stroke.scale, nil)
    var unit = Array(stroke.character.utf16)
    var glyph = CGGlyph(0)
    guard CTFontGetGlyphsForCharacters(font, &unit, &glyph, 1), glyph != 0, let outline = CTFontCreatePathForGlyph(font, glyph, nil) else {
        FileHandle.standardError.write(Data("字体里没有「\(stroke.character)」\n".utf8))
        exit(1)
    }
    let bounds = outline.boundingBoxOfPath
    top += stroke.gap * em
    // 字形坐标 y 向上；翻成 y 向下，字的顶贴着 `top`，水平居中再按摆动挪。
    var transform = CGAffineTransform(translationX: -bounds.midX + stroke.sway * em, y: top + bounds.maxY).scaledBy(x: 1, y: -1)
    if let placed = outline.copy(using: &transform) { path.addPath(placed) }
    top += bounds.height + leading * em
}

// 紧贴轮廓再留一点边（墨迹的飞白不被裁掉），翻回 PDF 的 y 向上。
let box = path.boundingBoxOfPath.insetBy(dx: -2, dy: -2)
var flip = CGAffineTransform(translationX: -box.minX, y: box.maxY).scaledBy(x: 1, y: -1)
guard let final = path.copy(using: &flip) else { exit(1) }
var media = CGRect(origin: .zero, size: box.size)

let directory = URL(fileURLWithPath: arguments[2])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let pdf = directory.appendingPathComponent("Epigraph.pdf")
guard let consumer = CGDataConsumer(url: pdf as CFURL), let context = CGContext(consumer: consumer, mediaBox: &media, nil) else { exit(1) }
context.beginPDFPage(nil)
context.addPath(final)
context.setFillColor(CGColor(gray: 0, alpha: 1))
context.fillPath()
context.endPDFPage()
context.closePDF()

let contents = """
{
  "images" : [
    {
      "filename" : "Epigraph.pdf",
      "idiom" : "universal"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  },
  "properties" : {
    "preserves-vector-representation" : true,
    "template-rendering-intent" : "template"
  }
}

"""
try contents.write(to: directory.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("竖幅 \(Int(box.width)) × \(Int(box.height))（em = \(Int(em))）→ \(pdf.path)")

// 预览：夜色底上纸色的字，四倍大。
if arguments.count >= 4 {
    let scale: CGFloat = 4, pad: CGFloat = 40
    let width = Int((box.width + 2 * pad) * scale), height = Int((box.height + 2 * pad) * scale)
    guard let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
    bitmap.setFillColor(CGColor(srgbRed: 0.047, green: 0.055, blue: 0.09, alpha: 1))
    bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
    bitmap.scaleBy(x: scale, y: scale)
    bitmap.translateBy(x: pad, y: pad)
    bitmap.addPath(final)
    bitmap.setFillColor(CGColor(srgbRed: 0.95, green: 0.93, blue: 0.87, alpha: 1))
    bitmap.fillPath()
    if let image = bitmap.makeImage(), let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: arguments[3]) as CFURL, "public.png" as CFString, 1, nil) {
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
