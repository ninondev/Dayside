// SPDX-License-Identifier: GPL-3.0-only
//
//  make_app_icon.swift（现行样式 `limb`，夜半球边缘上太阳刚露头的那一道光，见 `renderLimb`）：
//  planet / split 样式按昼夜地图的几何画被照亮的半球、晨昏线与太阳，
//  颜色由 `DaysidePalette` 的系统蓝与系统橙构成；limb 样式绘制暗色行星边缘的日出。
//  1024 满幅不透明（macOS 26 自己裁 squircle；自绘圆角会出现灰框）。
//
//  现行：swift Tools/make_app_icon.swift TahoeTime/Assets.xcassets/AppIcon.appiconset --style limb --svg <网站标记.svg>
//  用法：swift Tools/make_app_icon.swift <输出目录> [--window <lon0> <latMax> <span>] [--sun <lat> <lon>] [--preview <px>]
//    默认输出十个 icon_*.png 到 <输出目录>；--preview 只出一张预览；--svg <文件> 另写网站用的标记（同一几何，无陆地）。
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct Options {
    var out = ""
    /// limb：夜半球的边缘上，太阳刚露头的那一道光；
    /// planet：一颗行星，被照亮的那一面朝着角上的太阳；
    /// split：全幅昼 / 夜分割 + 太阳。
    var style = "limb"
    var sunScale = 1.0
    var phase = 62.0        // planet：相位角（度），0 = 满、90 = 半；62 ≈ 三分之二被照亮
    var tilt = 40.0         // planet：太阳方向（度；40 = 左上）
    var twilight = true
    var planetRadius = 0.36
    var planetOffset = 0.06
    var sunGap = 0.06       // planet：太阳与行星边缘的间距（占边长；负数 = 压在行星上）
    var ring = false        // planet：太阳外一圈底色的「刀口」（海报的分色法），代替白晕
    var nightHex: UInt32 = 0x102446
    var lon0 = -126.0      // 窗口左缘经度
    var latMax = 78.0      // 窗口上缘纬度
    var span = 146.0       // 窗口跨度（度，经纬相同，正方形）
    var sunLat = 18.0
    var sunLon = -52.0
    var preview: Int? = nil
    var svg: String? = nil
}

var options = Options()
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--window": options.lon0 = Double(args.removeFirst())!; options.latMax = Double(args.removeFirst())!; options.span = Double(args.removeFirst())!
    case "--sun": options.sunLat = Double(args.removeFirst())!; options.sunLon = Double(args.removeFirst())!
    case "--preview": options.preview = Int(args.removeFirst())!
    case "--style": options.style = args.removeFirst()
    case "--sun-scale": options.sunScale = Double(args.removeFirst())!
    case "--phase": options.phase = Double(args.removeFirst())!
    case "--tilt": options.tilt = Double(args.removeFirst())!
    case "--no-twilight": options.twilight = false
    case "--planet": options.planetRadius = Double(args.removeFirst())!; options.planetOffset = Double(args.removeFirst())!
    case "--sun-gap": options.sunGap = Double(args.removeFirst())!
    case "--ring": options.ring = true
    case "--night": options.nightHex = UInt32(args.removeFirst().replacingOccurrences(of: "#", with: ""), radix: 16)!
    case "--svg": options.svg = args.removeFirst()
    default: options.out = a
    }
}
guard !options.out.isEmpty || options.svg != nil else { fputs("需要输出目录\n", stderr); exit(2) }

func terminatorLatitude(_ lon: Double, sun: (Double, Double)) -> Double {
    var dec = sun.0 * .pi / 180
    if abs(dec) < 1e-5 { dec = 1e-5 }
    let h = (lon - sun.1) * .pi / 180
    return atan(-cos(h) / tan(dec)) * 180 / .pi
}
func dayPolygon(sun: (Double, Double)) -> [(Double, Double)] {
    var pts = (0...180).map { i -> (Double, Double) in let lon = -180.0 + Double(i) * 2; return (lon, terminatorLatitude(lon, sun: sun)) }
    let pole = sun.0 >= 0 ? 90.0 : -90.0
    pts.append((180, pole)); pts.append((-180, pole))
    return pts
}

// 颜色：昼 = 系统蓝 #0A84FF（深色变体，饱和度够）；昼的陆地淡一档；夜是深海军蓝；夜的陆地略亮；太阳 = 系统橙 #FF9F0A。
func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}
let daySea = rgb(0x0A84FF), dayLand = rgb(0x8EC5FF), nightSea = rgb(0x0B1730), nightLand = rgb(0x2B3F66)
let terminator = rgb(0xFFFFFF, 0.62), sunColor = rgb(0xFF9F0A), sunHalo = rgb(0xFFFFFF, 0.55)
let twilightBlue = rgb(0x2E5C9E), deepNight = rgb(0x070F22), planetNight = rgb(0x102446)

func makeContext(_ size: Int) -> CGContext {
    let s = Double(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true); ctx.setShouldAntialias(true)
    ctx.translateBy(x: 0, y: s); ctx.scaleBy(x: 1, y: -1)
    return ctx
}

/// 行星：深夜色底，一颗行星占满中间，被照亮的那一面（正投影下的凸月形：半圆 + 半椭圆）朝着角上那颗
/// 大太阳；晨昏线外一圈曙暮的蓝。没有陆地——16 px 下只剩「一颗蓝 / 深蓝的球和一角橙」，这就是要的。
func renderPlanet(size: Int, options o: Options) -> CGImage {
    let s = Double(size)
    let ctx = makeContext(size)
    ctx.setFillColor(deepNight); ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
    let center = CGPoint(x: s * (0.5 + o.planetOffset), y: s * (0.5 + o.planetOffset))
    let r = s * o.planetRadius
    let tilt = o.tilt * .pi / 180
    // 太阳方向（单位向量，屏幕坐标 y 向下）：tilt = 45 → 左上。
    let dir = CGPoint(x: -cos(tilt), y: -sin(tilt))
    // 太阳：沿太阳方向放在行星外（或压在行星边上），允许被图标边裁掉一部分。太阳画在行星之后（见下）。
    let sunR = s * 0.19 * o.sunScale
    let sunC = CGPoint(x: center.x + dir.x * (r + sunR + s * o.sunGap), y: center.y + dir.y * (r + sunR + s * o.sunGap))
    // 行星本体：夜色。
    ctx.setFillColor(rgb(o.nightHex)); ctx.fillEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
    // 被照亮的部分：在「太阳在 −x 方向」的坐标系里画半圆 + 半椭圆，再整体旋转。
    func litPath(radius: Double, phaseDeg: Double) -> CGPath {
        let k = cos(phaseDeg * .pi / 180)                       // 椭圆短半轴 / 长半轴
        let m = CGMutablePath()
        // 朝太阳的半圆（x ≤ 0）。
        m.move(to: CGPoint(x: 0, y: -radius))
        m.addArc(center: .zero, radius: radius, startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: true)
        // 背太阳一侧的半椭圆（x ≥ 0，k > 0 时是凸月）。
        var t = CGAffineTransform(scaleX: max(k, 0.0001), y: 1)
        let ellipse = CGMutablePath()
        ellipse.addArc(center: .zero, radius: radius, startAngle: .pi / 2, endAngle: -.pi / 2, clockwise: true)
        m.addPath(ellipse, transform: t)
        m.closeSubpath()
        t = .identity
        return m
    }
    // 半圆朝 −x；把 −x 转到 dir = (−cos tilt, −sin tilt) 就是旋转 tilt。
    let xf = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: tilt)
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)); ctx.clip()
    if o.twilight {
        ctx.setFillColor(twilightBlue)
        let m = CGMutablePath(); m.addPath(litPath(radius: r, phaseDeg: o.phase - 9), transform: xf)
        ctx.addPath(m); ctx.fillPath()
    }
    ctx.setFillColor(daySea)
    let lit = CGMutablePath(); lit.addPath(litPath(radius: r, phaseDeg: o.phase), transform: xf)
    ctx.addPath(lit); ctx.fillPath()
    ctx.restoreGState()
    if o.ring {
        let w = sunR * 0.16
        ctx.setFillColor(deepNight); ctx.fillEllipse(in: CGRect(x: sunC.x - sunR - w, y: sunC.y - sunR - w, width: 2 * (sunR + w), height: 2 * (sunR + w)))
    } else {
        ctx.setFillColor(sunHalo); ctx.fillEllipse(in: CGRect(x: sunC.x - sunR * 1.16, y: sunC.y - sunR * 1.16, width: sunR * 2.32, height: sunR * 2.32))
    }
    ctx.setFillColor(sunColor); ctx.fillEllipse(in: CGRect(x: sunC.x - sunR, y: sunC.y - sunR, width: sunR * 2, height: sunR * 2))
    return ctx.makeImage()!
}

/// 全幅分割：整块图标就是昼 / 夜，一条从左下扫到右上的晨昏线，太阳在昼的一角。
func renderSplit(size: Int, options o: Options) -> CGImage {
    let s = Double(size)
    let ctx = makeContext(size)
    ctx.setFillColor(deepNight); ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
    // 晨昏线：同一条 atan 曲线，取陡的那一段横穿正方形。
    func curve(_ shift: Double) -> [CGPoint] {
        (0...40).map { i in
            let t = Double(i) / 40
            let x = t * s
            // 归一化的晨昏线：y 从下到上，中段陡。
            let h = (t - 0.5) * 180 + 90 + shift
            let lat = atan(-cos(h * .pi / 180) / tan(23.4 * .pi / 180)) * 180 / .pi   // −66.6 … 66.6
            return CGPoint(x: x, y: s * (0.5 - lat / 150))
        }
    }
    func dayPath(_ shift: Double) -> CGPath {
        let pts = curve(shift)
        let m = CGMutablePath()
        m.move(to: CGPoint(x: 0, y: 0))
        m.addLine(to: pts[0])
        for p in pts.dropFirst() { m.addLine(to: p) }
        m.addLine(to: CGPoint(x: s, y: 0))
        m.closeSubpath()
        return m
    }
    if o.twilight { ctx.setFillColor(twilightBlue); ctx.addPath(dayPath(-6)); ctx.fillPath() }
    ctx.setFillColor(daySea); ctx.addPath(dayPath(0)); ctx.fillPath()
    let sunR = s * 0.17 * o.sunScale
    let sunC = CGPoint(x: s * 0.30, y: s * 0.30)
    ctx.setFillColor(sunHalo); ctx.fillEllipse(in: CGRect(x: sunC.x - sunR * 1.16, y: sunC.y - sunR * 1.16, width: sunR * 2.32, height: sunR * 2.32))
    ctx.setFillColor(sunColor); ctx.fillEllipse(in: CGRect(x: sunC.x - sunR, y: sunC.y - sunR, width: sunR * 2, height: sunR * 2))
    return ctx.makeImage()!
}

// ---------------------------------------------------------------- limb

/// OKLCH → sRGB（与 Rust `sky.rs`、原型同一套公式），超出色域的分量钳到 0…1。
func oklch(_ l: Double, _ c: Double, _ h: Double, _ alpha: Double = 1) -> CGColor {
    let (a, b) = (c * cos(h * .pi / 180), c * sin(h * .pi / 180))
    let l_ = l + 0.3963377774 * a + 0.2158037573 * b
    let m_ = l - 0.1055613458 * a - 0.0638541728 * b
    let s_ = l - 0.0894841775 * a - 1.2914855480 * b
    let (L, M, S) = (l_ * l_ * l_, m_ * m_ * m_, s_ * s_ * s_)
    let linear = [4.0767416621 * L - 3.3077115913 * M + 0.2309699292 * S,
                  -1.2684380046 * L + 2.6097574011 * M - 0.3413193965 * S,
                  -0.0041960863 * L - 0.7034186147 * M + 1.7076147010 * S]
    let encode = { (x: Double) -> CGFloat in
        let v = max(0, min(1, x))
        return CGFloat(v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055)
    }
    return CGColor(srgbRed: encode(linear[0]), green: encode(linear[1]), blue: encode(linear[2]), alpha: CGFloat(alpha))
}

/// 在 OKLab 里混两种 OKLCH（原型 `mix`）。
func mixLch(_ p: (Double, Double, Double), _ q: (Double, Double, Double), _ t: Double) -> (Double, Double, Double) {
    let lab = { (c: (Double, Double, Double)) in (c.0, c.1 * cos(c.2 * .pi / 180), c.1 * sin(c.2 * .pi / 180)) }
    let (a, b) = (lab(p), lab(q))
    let m = (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
    var h = atan2(m.2, m.1) * 180 / .pi
    if h < 0 { h += 360 }
    return (m.0, (m.1 * m.1 + m.2 * m.2).squareRoot(), h)
}

/// 夜半球的边缘上，太阳刚露头：深夜的底（上黑下偏紫），画面下方一颗几乎撑满的暗色行星，地平线向左上略倾（−8°），
/// 行星边缘上沿着一道光——越靠日出点越亮、越暖（玫瑰 → 琥珀 → 金 → 近白），日出点上一团光晕与一道压扁的光芒。
/// 整张逐像素算：底 → 三层光晕加性叠加 → 行星盘 → 边缘的光 → 日出光晕与光芒，
/// 渐变在 sRGB 编码值上插值、不加抖动：CoreGraphics 的随机抖动会降低 PNG 压缩率。
/// 光晕沿半径是「一段宽度 × 高斯模糊」的解析式（两个误差函数之差），沿圆周按离日出点的角度衰减，没有分段接缝。
/// 小尺寸时光晕按 1 + 24 / 边长加宽，16 px 也看得见那一道光。
func renderLimb(size: Int, options o: Options) -> CGImage {
    let s = Double(size)
    let S = s
    typealias RGB = (Double, Double, Double)
    func rgbOf(_ l: Double, _ c: Double, _ h: Double) -> RGB {
        let k = oklch(l, c, h).components ?? [0, 0, 0, 1]
        return (Double(k[0]), Double(k[1]), Double(k[2]))
    }
    /// 按位置在色标之间插值（位置在两端之外取端点）。
    func lerp(_ stops: [(Double, RGB, Double)], _ t: Double) -> (RGB, Double) {
        guard let first = stops.first, let last = stops.last else { return ((0, 0, 0), 0) }
        if t <= first.0 { return (first.1, first.2) }
        if t >= last.0 { return (last.1, last.2) }
        for k in 0..<(stops.count - 1) where t <= stops[k + 1].0 {
            let (a, b) = (stops[k], stops[k + 1])
            let u = (t - a.0) / max(b.0 - a.0, 1e-9)
            // 画布渐变在预乘过的颜色上插值：颜色按不透明度加权。
            let alpha = a.2 + (b.2 - a.2) * u
            let w = alpha > 1e-9 ? (a.2 * (1 - u)) / alpha : 1 - u
            let color = (a.1.0 * w + b.1.0 * (1 - w), a.1.1 * w + b.1.1 * (1 - w), a.1.2 * w + b.1.2 * (1 - w))
            return (color, alpha)
        }
        return (last.1, last.2)
    }
    let cx = S * 0.5, cy = S * 1.52, R = S * 0.98, rise = -Double.pi / 2 + 0.22
    let boost = 1 + 24 / s
    let tilt = -8 * Double.pi / 180
    func falloff(_ t0: Double, _ spread: Double) -> Double {
        let d = abs((t0 - rise + .pi * 3).truncatingRemainder(dividingBy: .pi * 2) - .pi)
        return max(0, 1 - d / spread)
    }
    func tone(_ q: Double) -> (Double, Double, Double) {
        if q > 0.85 { return (0.98, 0.03, 90) }
        if q > 0.6 { return mixLch((0.86, 0.13, 68), (0.98, 0.03, 90), (q - 0.6) / 0.25) }
        if q > 0.3 { return mixLch((0.64, 0.14, 24), (0.86, 0.13, 68), (q - 0.3) / 0.3) }
        return mixLch((0.34, 0.1, 300), (0.64, 0.14, 24), q / 0.3)
    }
    // 沿半径：宽 w 的一段（中心在 r0）经标准差 σ 的高斯模糊后的强度（两个误差函数之差）。
    func band(_ d: Double, _ r0: Double, _ w: Double, _ sigma: Double) -> Double {
        let k = 1 / (max(sigma, 0.35) * 2.squareRoot())
        return 0.5 * (erf((d - (r0 - w / 2)) * k) - erf((d - (r0 + w / 2)) * k))
    }
    /// 两个圆之间的径向渐变（画布 `createRadialGradient` 的定义）：点落在哪个插值圆上，取最大的那个参数。
    func radial(_ p: (Double, Double), _ c0: (Double, Double), _ r0: Double, _ c1: (Double, Double), _ r1: Double) -> Double {
        let (qx, qy) = (p.0 - c0.0, p.1 - c0.1)
        let (dx, dy, dr) = (c1.0 - c0.0, c1.1 - c0.1, r1 - r0)
        let a = dx * dx + dy * dy - dr * dr
        let b = -2 * (qx * dx + qy * dy + r0 * dr)
        let c = qx * qx + qy * qy - r0 * r0
        if abs(a) < 1e-12 { return b == 0 ? 0 : -c / b }
        let disc = b * b - 4 * a * c
        guard disc >= 0 else { return 0 }
        let roots = [(-b + disc.squareRoot()) / (2 * a), (-b - disc.squareRoot()) / (2 * a)].filter { r0 + $0 * dr >= 0 }
        return roots.max() ?? 0
    }
    let bgStops: [(Double, RGB, Double)] = [(0, rgbOf(0.10, 0.02, 272), 1), (0.6, rgbOf(0.17, 0.045, 288), 1), (1, rgbOf(0.12, 0.03, 280), 1)]
    let planetStops: [(Double, RGB, Double)] = [(0, rgbOf(0.21, 0.035, 265), 1), (1, rgbOf(0.09, 0.018, 262), 1)]
    let bloomStops: [(Double, RGB, Double)] = [(0, rgbOf(0.99, 0.02, 90), 0.95), (0.08, rgbOf(0.95, 0.06, 85), 0.7), (0.35, rgbOf(0.8, 0.12, 65), 0.18), (1, rgbOf(0.7, 0.1, 40), 0)]
    let flareStops: [(Double, RGB, Double)] = [(0, rgbOf(0.98, 0.04, 88), 0.75), (1, rgbOf(0.85, 0.1, 70), 0)]
    // 光晕三层与边缘那道颜色按 q 取 256 档。
    struct Light { let r0: Double; let w: Double; let sigma: Double; let spread: Double; let alpha: (Double) -> Double; let colors: [RGB] }
    let glows = [(S * 0.30 * boost, 0.20, S * 0.09, 1.25), (S * 0.12 * boost, 0.42, S * 0.035, 1.05), (S * 0.045 * boost, 0.85, S * 0.01, 0.9)].map { w, a, blur, spread in
        Light(r0: R + w * 0.12, w: w, sigma: blur, spread: spread, alpha: { q in a * pow(q, 1.2) },
              colors: (0...255).map { i in let c = tone(Double(i) / 255); return rgbOf(c.0, c.1, c.2) })
    }
    let rimWidth = max(1.2, S * 0.012)
    let rim = Light(r0: R - rimWidth / 2, w: rimWidth, sigma: 0.45, spread: 0.8, alpha: { q in s < 48 ? min(1, 1.6 * q) : 0.95 * q },
                    colors: (0...255).map { i in let c = tone(0.6 + Double(i) / 255 * 0.4); return rgbOf(c.0, c.1, c.2) })
    func light(_ l: Light, d: Double, t: Double) -> RGB {
        let q = falloff(t, l.spread)
        guard q > 0 else { return (0, 0, 0) }
        let strength = l.alpha(q) * band(d, l.r0, l.w, l.sigma)
        let c = l.colors[min(255, Int(q * 255))]
        return (c.0 * strength, c.1 * strength, c.2 * strength)
    }
    let sun = (cx + R * cos(rise), cy + R * sin(rise) - S * 0.012)
    let flareAngle = rise + .pi / 2
    let (fsin, fcos) = (sin(-flareAngle), cos(-flareAngle))
    var pixels = [UInt8](repeating: 255, count: size * size * 4)
    let (sinT, cosT) = (sin(-tilt), cos(-tilt))
    for py in 0..<size {
        let bg = lerp(bgStops, (Double(py) + 0.5) / s).0
        for px in 0..<size {
            // 倾斜前的坐标：像素中心绕图中心转回 +8°。
            let (X, Y) = (Double(px) + 0.5 - s / 2, Double(py) + 0.5 - s / 2)
            let (x, y) = (X * cosT - Y * sinT + s / 2, X * sinT + Y * cosT + s / 2)
            let (dx, dy) = (x - cx, y - cy)
            let d = (dx * dx + dy * dy).squareRoot()
            let t = atan2(dy, dx)
            var c = bg
            if t <= 0.05 {
                for g in glows { let a = light(g, d: d, t: t); c = (c.0 + a.0, c.1 + a.1, c.2 + a.2) }
            }
            // 行星盘（边缘 1 像素抗锯齿）。
            let cover = min(1, max(0, R - d + 0.5))
            if cover > 0 {
                let p = lerp(planetStops, radial((x, y), (cx, cy - R * 0.92), R * 0.04, (cx, cy), R)).0
                c = (c.0 + (p.0 - c.0) * cover, c.1 + (p.1 - c.1) * cover, c.2 + (p.2 - c.2) * cover)
            }
            if t <= 0.05 { let a = light(rim, d: d, t: t); c = (c.0 + a.0, c.1 + a.1, c.2 + a.2) }
            // 日出光晕（圆）与光芒（沿地平线压扁的椭圆），都是加性。
            let (sx, sy) = (x - sun.0, y - sun.1)
            let bloomT = (sx * sx + sy * sy).squareRoot() / (S * 0.3 * boost)
            if bloomT < 1 { let (bc, ba) = lerp(bloomStops, bloomT); c = (c.0 + bc.0 * ba, c.1 + bc.1 * ba, c.2 + bc.2 * ba) }
            let (fx, fy) = (sx * fcos - sy * fsin, (sx * fsin + sy * fcos) / 0.12)
            let flareT = (fx * fx + fy * fy).squareRoot() / (S * 0.42)
            if flareT < 1 { let (fc, fa) = lerp(flareStops, flareT); c = (c.0 + fc.0 * fa, c.1 + fc.1 * fa, c.2 + fc.2 * fa) }
            let o = (py * size + px) * 4
            pixels[o] = UInt8((min(1, max(0, c.0)) * 255).rounded())
            pixels[o + 1] = UInt8((min(1, max(0, c.1)) * 255).rounded())
            pixels[o + 2] = UInt8((min(1, max(0, c.2)) * 255).rounded())
        }
    }
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil, shouldInterpolate: true,
                   intent: .defaultIntent)!
}

func render(size: Int, options o: Options) -> CGImage {
    switch o.style {
    case "limb": return renderLimb(size: size, options: o)
    case "planet": return renderPlanet(size: size, options: o)
    case "split": return renderSplit(size: size, options: o)
    default: fputs("没有这个样式：\(o.style)（limb / planet / split）\n", stderr); exit(2)
    }
}

func write(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

/// "#rrggbb"（OKLCH → sRGB）。
func hexColor(_ l: Double, _ c: Double, _ h: Double) -> String {
    let k = oklch(l, c, h).components ?? [0, 0, 0, 1]
    return String(format: "#%02X%02X%02X", Int((k[0] * 255).rounded()), Int((k[1] * 255).rounded()), Int((k[2] * 255).rounded()))
}

if let svgPath = options.svg, options.style == "limb" {
    // 网站的标记：与图标同一几何——深夜的底、画面下方的暗色行星、边缘一道越近日出点越亮越暖的光、
    // 日出点一团光晕。24 px 显示，64 单位视口；边缘那道光的颜色沿横向取 9 个色标（上半圆在方块里近乎横贯）。
    let S = 64.0, cx = S * 0.5, cy = S * 1.52, R = S * 0.98, rise = -Double.pi / 2 + 0.22
    func f(_ v: Double) -> String { String(format: "%.2f", v) }
    func falloff(_ t0: Double, _ spread: Double) -> Double {
        let d = abs((t0 - rise + .pi * 3).truncatingRemainder(dividingBy: .pi * 2) - .pi)
        return max(0, 1 - d / spread)
    }
    func tone(_ q: Double) -> (Double, Double, Double) {
        if q > 0.85 { return (0.98, 0.03, 90) }
        if q > 0.6 { return mixLch((0.86, 0.13, 68), (0.98, 0.03, 90), (q - 0.6) / 0.25) }
        if q > 0.3 { return mixLch((0.64, 0.14, 24), (0.86, 0.13, 68), (q - 0.3) / 0.3) }
        return mixLch((0.34, 0.1, 300), (0.64, 0.14, 24), q / 0.3)
    }
    // 横坐标 x 处（未倾斜）圆上那一点的角度。
    let rimStops = (0...8).map { i -> String in
        let x = Double(i) / 8 * S
        let t = -Double.pi / 2 + asin(max(-1, min(1, (x - cx) / R)))
        let q = falloff(t, 0.8)
        let c = tone(0.6 + q * 0.4)
        return "<stop offset=\"\(f(Double(i) / 8))\" stop-color=\"\(hexColor(c.0, c.1, c.2))\" stop-opacity=\"\(f(min(1, 1.6 * q)))\"/>"
    }.joined()
    let sun = (x: cx + R * cos(rise), y: cy + R * sin(rise) - S * 0.012)
    let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="24" height="24" aria-hidden="true"><defs>\
    <linearGradient id="dsbg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="\(hexColor(0.10, 0.02, 272))"/><stop offset=".6" stop-color="\(hexColor(0.17, 0.045, 288))"/><stop offset="1" stop-color="\(hexColor(0.12, 0.03, 280))"/></linearGradient>\
    <radialGradient id="dsglow" cx="\(f(sun.x))" cy="\(f(sun.y))" r="\(f(S * 0.42))" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="\(hexColor(0.99, 0.02, 90))" stop-opacity=".95"/><stop offset=".12" stop-color="\(hexColor(0.95, 0.06, 85))" stop-opacity=".8"/><stop offset=".45" stop-color="\(hexColor(0.8, 0.12, 65))" stop-opacity=".35"/><stop offset="1" stop-color="\(hexColor(0.34, 0.1, 300))" stop-opacity="0"/></radialGradient>\
    <radialGradient id="dsplanet" cx="\(f(cx))" cy="\(f(cy - R * 0.92))" r="\(f(R))" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="\(hexColor(0.21, 0.035, 265))"/><stop offset="1" stop-color="\(hexColor(0.09, 0.018, 262))"/></radialGradient>\
    <linearGradient id="dsrim" x1="0" y1="0" x2="64" y2="0" gradientUnits="userSpaceOnUse">\(rimStops)</linearGradient>\
    <clipPath id="dsm"><rect width="64" height="64" rx="14"/></clipPath></defs>\
    <g clip-path="url(#dsm)"><rect width="64" height="64" fill="url(#dsbg)"/><g transform="rotate(-8 32 32)">\
    <ellipse cx="\(f(sun.x))" cy="\(f(sun.y))" rx="\(f(S * 0.42))" ry="\(f(S * 0.2))" fill="url(#dsglow)"/>\
    <circle cx="\(f(cx))" cy="\(f(cy))" r="\(f(R))" fill="url(#dsplanet)"/>\
    <circle cx="\(f(cx))" cy="\(f(cy))" r="\(f(R - 1.2))" fill="none" stroke="url(#dsrim)" stroke-width="2.4"/>\
    <circle cx="\(f(sun.x))" cy="\(f(sun.y))" r="\(f(S * 0.07))" fill="url(#dsglow)"/></g></g></svg>
    """
    try! svg.write(toFile: svgPath, atomically: true, encoding: .utf8)
    print("svg → \(svgPath) (\(svg.utf8.count) 字节)")
} else if let svgPath = options.svg, options.style == "planet" {
    // 网站的标记：与图标同一几何（行星的凸月形被照亮面 + 压边的太阳），64 单位视口、24 px 显示。
    let o = options
    let s = 64.0
    let c = s * (0.5 + o.planetOffset), r = s * o.planetRadius
    let tilt = o.tilt * .pi / 180
    let dir = (x: -cos(tilt), y: -sin(tilt))
    let sunR = s * 0.19 * o.sunScale
    let sun = (x: c + dir.x * (r + sunR + s * o.sunGap), y: c + dir.y * (r + sunR + s * o.sunGap))
    let k = cos(o.phase * .pi / 180), kt = cos((o.phase - 9) * .pi / 180)
    func f(_ v: Double) -> String { String(format: "%.1f", v) }
    // 半圆（−x 侧）+ 半椭圆（+x 侧），旋转 tilt 度让 −x 指向太阳。
    func lit(_ k: Double) -> String { "M0,\(f(-r)) A\(f(r)),\(f(r)) 0 0 0 0,\(f(r)) A\(f(k * r)),\(f(r)) 0 0 0 0,\(f(-r)) Z" }
    let night = String(format: "#%06X", o.nightHex)
    let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="24" height="24" aria-hidden="true"><clipPath id="m"><rect width="64" height="64" rx="14"/></clipPath><g clip-path="url(#m)"><rect width="64" height="64" fill="#070F22"/><circle cx="\(f(c))" cy="\(f(c))" r="\(f(r))" fill="\(night)"/><g transform="translate(\(f(c)) \(f(c))) rotate(\(f(o.tilt)))"><path d="\(lit(kt))" fill="#2E5C9E"/><path d="\(lit(k))" fill="#0A84FF"/></g><circle cx="\(f(sun.x))" cy="\(f(sun.y))" r="\(f(sunR * 1.16))" fill="#070F22"/><circle cx="\(f(sun.x))" cy="\(f(sun.y))" r="\(f(sunR))" fill="#FF9F0A"/></g></svg>
    """
    try! svg.write(toFile: svgPath, atomically: true, encoding: .utf8)
    print("svg → \(svgPath) (\(svg.utf8.count) 字节)")
} else if let svgPath = options.svg {
    // 地图式的标记（第一版）：同一几何，24 px 视口，无陆地；圆角方 + 昼 / 夜 + 晨昏线 + 太阳。
    let o = options
    let s = 64.0
    func p(_ pt: (Double, Double)) -> String { String(format: "%.0f %.0f", (pt.0 - o.lon0) / o.span * s, (o.latMax - pt.1) / o.span * s) }
    let day = dayPolygon(sun: (o.sunLat, o.sunLon))
    // 24 px 的标记不需要 2° 采样：每 8° 一个点（晨昏线 23 点），文件 1 KB 出头。
    let sparse = day.prefix(day.count - 2).enumerated().filter { $0.offset % 4 == 0 || $0.offset == day.count - 3 }.map(\.element)
    let dayPath = "M" + (sparse + day.suffix(2)).map(p).joined(separator: " L") + " Z"
    let termPath = "M" + sparse.map(p).joined(separator: " L")
    let c = p((o.sunLon, o.sunLat)).split(separator: " ")
    let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="24" height="24" aria-hidden="true"><clipPath id="m"><rect width="64" height="64" rx="14"/></clipPath><g clip-path="url(#m)"><rect width="64" height="64" fill="#0B1730"/><path d="\(dayPath)" fill="#0A84FF"/><path d="\(termPath)" fill="none" stroke="#fff" stroke-opacity=".62" stroke-width="1.5" stroke-linejoin="round"/><circle cx="\(c[0])" cy="\(c[1])" r="5.8" fill="#fff" fill-opacity=".55"/><circle cx="\(c[0])" cy="\(c[1])" r="4.6" fill="#FF9F0A"/></g></svg>
    """
    try! svg.write(toFile: svgPath, atomically: true, encoding: .utf8)
    print("svg → \(svgPath) (\(svg.utf8.count) 字节)")
}

if !options.out.isEmpty {
    let outDir = URL(fileURLWithPath: options.out)
    try! FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    if let px = options.preview {
        write(render(size: px, options: options), to: outDir.appendingPathComponent("preview-\(px).png"))
        print("preview → \(outDir.path)/preview-\(px).png")
    } else {
        let slots: [(String, Int)] = [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
                                      ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
                                      ("icon_512x512", 512), ("icon_512x512@2x", 1024)]
        var cache: [Int: CGImage] = [:]
        for (name, px) in slots {
            let image = cache[px] ?? render(size: px, options: options)
            cache[px] = image
            write(image, to: outDir.appendingPathComponent("\(name).png"))
        }
        print("10 张 → \(outDir.path)")
    }
}
