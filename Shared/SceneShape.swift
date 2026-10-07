// SPDX-License-Identifier: GPL-3.0-only
//
//  SceneShape.swift
//  Shared：主程序使用的绘图适配。
//
//  Rust 给的一批绘图命令（矩形 / 椭圆 / 线 / 二次曲线 / 折线 / 多边形 / 多环）与两种执行方式：
//  `SceneShape` 把一条命令画成纯形状（默认；静态图不启动 Canvas 的 Metal 缓冲），
//  `SceneCommand.draw(in:)` 留给必须逐帧重画的 Canvas 场合。颜色只有语义色名，跟随浅深色。
//  绘图命令的 SwiftUI 形状执行与 Canvas 执行共用同一份几何。
//  Rust 只说**角色**（day / available / terminator / home / sun），`DaysidePalette` 把角色配成
//  一套两色——昼的蓝与太阳的橙，其余全是系统中性色；地图、昼夜条、太阳弧、名片、图标同一对颜色。
//

import SwiftUI

/// Dayside 的两种彩色。都是系统色（`Color.blue` / `Color.orange`），跟浅深色与「增强对比度」走，不是自定义品牌色；
/// 只是不再跟用户挑的强调色走——地图上的白天不该因为强调色改成紫色而变紫，那是这张图的含义。
/// 图标（`Tools/make_app_icon.swift`）与网站的标记用同一对颜色的十六进制值。
nonisolated enum DaysidePalette {
    static let day = Color.blue
    static let sun = Color.orange
    /// Rust 会说的全部角色（封闭表；`PaletteTests` 拿 Rust 真实输出逐条核对，新角色两边一起加）。
    static let roles: Set<String> = ["day", "twilight", "available", "terminator", "home", "sun", "orange",
                                     "green", "yellow", "primary", "secondary", "tertiary", "quaternary", "dawn", "dusk",
                                     "sky", "background", "ink", "paper", "sunRim", "sunGlow"]
    /// 深色模式里被照亮的半球要「发亮」：同一份 Rust 命令，昼 / 曙暮 / 晨昏线的不透明度按这个倍数抬，
    /// 浅色不动（浅色底上蓝色 22% 已经够清楚，再重会压过陆地）。
    static func opacity(_ role: String, _ base: Double, dark: Bool) -> Double {
        guard dark else { return base }
        switch role {
        case "day", "twilight", "available": return min(1, base * 1.5)
        case "terminator": return min(1, base * 1.4)
        default: return base
        }
    }

    /// 角色 → 形状样式。`dark` 只影响昼 / 曙暮 / 晨昏线的不透明度。
    static func shading(_ role: String, opacity: Double, dark: Bool) -> AnyShapeStyle {
        let alpha = Self.opacity(role, opacity, dark: dark)
        switch role {
        // 曙暮：地图上与昼夜条同一套三档（昼 / 曙暮 / 夜），曙暮是昼色的淡一档。
        case "day", "twilight", "available", "terminator", "home": return AnyShapeStyle(day.opacity(alpha))
        case "orange": return AnyShapeStyle(sun.opacity(alpha))
        // 光的材料（Rust `sky.palette`，与地图、面板滑块同一批颜色）：太阳是金盘与深色外沿、光晕，字与细线是墨或纸。
        // 太阳一天图的金线、黄金时刻与地平线用它们；画在天色上，不跟浅深色走。
        case "sun": return AnyShapeStyle(LightPalette.sun.opacity(alpha))
        case "sunRim": return AnyShapeStyle(LightPalette.sunRim.opacity(alpha))
        case "sunGlow": return AnyShapeStyle(LightPalette.sunGlow.opacity(alpha))
        case "ink": return AnyShapeStyle(LightPalette.ink.opacity(alpha))
        case "paper": return AnyShapeStyle(LightPalette.paper.opacity(alpha))
        // 地图上的晨昏线分两段，破晓一侧偏玫瑰、黄昏一侧偏琥珀（颜色由 Rust `sky.palette` 给）；
        // 地图是天色，不跟浅深色走。
        case "dawn": return AnyShapeStyle(LightPalette.dawn.opacity(alpha))
        case "dusk": return AnyShapeStyle(LightPalette.dusk.opacity(alpha))
        // 天色昼夜条：天那一条的颜色在命令自己的色标里（`gradient`），这里只给个兜底；参考线的衬边用窗口底色。
        case "sky": return AnyShapeStyle(LightPalette.paper.opacity(alpha))
        case "background": return AnyShapeStyle(.background.opacity(alpha))
        case "green": return AnyShapeStyle(Color.green.opacity(alpha))
        case "yellow": return AnyShapeStyle(Color.yellow.opacity(alpha))
        case "primary": return AnyShapeStyle(.primary)
        case "secondary": return AnyShapeStyle(.secondary.opacity(alpha))
        case "tertiary": return AnyShapeStyle(.tertiary)
        case "quaternary": return AnyShapeStyle(.quaternary)
        default: preconditionFailure("Unknown Rust scene style: \(role)")
        }
    }
}

nonisolated struct SceneCommand: Decodable, Sendable {
    /// 渐变的色标（`gradient` 命令：横向渐变填满 geometry 的矩形；光，的天色昼夜条）。
    struct Stop: Decodable, Sendable {
        let at: Double
        let color: String
    }
    let kind: String
    let geometry: [Double]
    let style: String
    let opacity: Double
    let lineWidth: Double
    var stops: [Stop]? = nil

    /// 色标 → SwiftUI 渐变（颜色是 Rust 给的 sRGB 十六进制）。
    var gradient: Gradient {
        Gradient(stops: (stops ?? []).map { .init(color: LightPalette.color($0.color), location: $0.at) })
    }

    func draw(in context: GraphicsContext) {
        let p = geometry
        // Canvas 路读不到外观：按浅色配（现在没有页面走这条路；页面里的图一律用 `SceneShape`）。
        let shading: GraphicsContext.Shading = .style(DaysidePalette.shading(style, opacity: opacity, dark: false))
        switch kind {
        case "rect": context.fill(Path(CGRect(x: p[0], y: p[1], width: p[2], height: p[3])), with: shading)
        case "ellipse": context.fill(Path(ellipseIn: CGRect(x: p[0], y: p[1], width: p[2], height: p[3])), with: shading)
        case "line":
            var path = Path()
            path.move(to: CGPoint(x: p[0], y: p[1]))
            path.addLine(to: CGPoint(x: p[2], y: p[3]))
            context.stroke(path, with: shading, lineWidth: lineWidth)
        case "quadFill", "quadStroke":
            var path = Path()
            path.move(to: CGPoint(x: p[0], y: p[1]))
            path.addQuadCurve(to: CGPoint(x: p[2], y: p[3]), control: CGPoint(x: p[4], y: p[5]))
            if kind == "quadFill" { path.closeSubpath(); context.fill(path, with: shading) }
            else { context.stroke(path, with: shading, lineWidth: lineWidth) }
        case "polyline", "polygonFill":
            // 平铺的 [x0, y0, x1, y1, …]；折线描边、多边形闭合填充（太阳高度图的线与面）。
            guard p.count >= 4 else { return }
            var path = Path()
            path.move(to: CGPoint(x: p[0], y: p[1]))
            for i in stride(from: 2, to: p.count - 1, by: 2) { path.addLine(to: CGPoint(x: p[i], y: p[i + 1])) }
            if kind == "polygonFill" { path.closeSubpath(); context.fill(path, with: shading) }
            else { context.stroke(path, with: shading, style: StrokeStyle(lineWidth: lineWidth, lineJoin: .round)) }
        case "polygonsFill": context.fill(SceneShape.path(for: self), with: shading)
        case "polygonsFillEO": context.fill(SceneShape.path(for: self), with: shading, style: FillStyle(eoFill: true))
        case "dots": context.fill(SceneShape.path(for: self), with: shading)
        case "gradient":
            context.fill(Path(CGRect(x: p[0], y: p[1], width: p[2], height: p[3])),
                         with: .linearGradient(gradient, startPoint: CGPoint(x: p[0], y: 0), endPoint: CGPoint(x: p[0] + p[2], y: 0)))
        default: preconditionFailure("Unknown Rust canvas command: \(kind)")
        }
    }
}

/// 把一条 Rust 绘图命令画成 SwiftUI 形状（`Path` + fill / stroke），与 `DrawCommand.draw(in:)` 的 Canvas
/// 路是同一份命令的两种执行方式。`Canvas` 首帧会启动 Metal 图形缓冲，
/// 纯形状走 CoreGraphics 没有这一笔，页面里的静态图一律用这条路；每帧都要重画的（穿梭中的太阳弧）再考虑 Canvas。
struct SceneShape: View {
    let command: SceneCommand
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let path = Self.path(for: command)
        let shading = DaysidePalette.shading(command.style, opacity: command.opacity, dark: colorScheme == .dark)
        switch command.kind {
        case "gradient":
            // 天色昼夜条：矩形总是横贯整条（x 从 0 到宽），所以渐变的两端就是视图的左右两边。
            // 深色外观里压暗一档（「月光纸」）：纸色的白天段对深色窗口底原本 14:1，是整页最亮的一大块，比名字和钟点还抢眼；
            // 压暗后白天与夜仍分得清。面板行不走这里，行底就是那里真实的天。
            path.fill(LinearGradient(gradient: command.gradient, startPoint: .leading, endPoint: .trailing))
                .overlay { if colorScheme == .dark { path.fill(Color.black.opacity(0.22)) } }
        case "rect", "ellipse", "quadFill", "polygonFill", "polygonsFill", "dots":
            path.fill(shading)
        case "polygonsFillEO":
            // 昼 / 曙暮区 = 整幅矩形减去夜那一块（奇偶填充）：夜冠不跨极点时是个洞，跨极点时是连到极点的一片，
            // 两种情况一条规则画对（Rust `worldmap.scene`）。
            path.fill(shading, style: FillStyle(eoFill: true))
        case "polyline":
            // 折线（太阳一天图的线与黄金时刻的光）两头是圆的：粗的那道光不会在两端截成方块。
            path.stroke(shading, style: StrokeStyle(lineWidth: command.lineWidth, lineCap: .round, lineJoin: .round))
        default:
            path.stroke(shading, style: StrokeStyle(lineWidth: command.lineWidth, lineJoin: .round))
        }
    }

    nonisolated static func path(for command: SceneCommand) -> Path {
        let p = command.geometry
        var path = Path()
        switch command.kind {
        case "rect", "gradient": path.addRect(CGRect(x: p[0], y: p[1], width: p[2], height: p[3]))
        case "ellipse": path.addEllipse(in: CGRect(x: p[0], y: p[1], width: p[2], height: p[3]))
        case "line":
            path.move(to: CGPoint(x: p[0], y: p[1])); path.addLine(to: CGPoint(x: p[2], y: p[3]))
        case "quadFill", "quadStroke":
            path.move(to: CGPoint(x: p[0], y: p[1]))
            path.addQuadCurve(to: CGPoint(x: p[2], y: p[3]), control: CGPoint(x: p[4], y: p[5]))
            if command.kind == "quadFill" { path.closeSubpath() }
        case "polyline", "polygonFill":
            guard p.count >= 4 else { return path }
            path.move(to: CGPoint(x: p[0], y: p[1]))
            for i in stride(from: 2, to: p.count - 1, by: 2) { path.addLine(to: CGPoint(x: p[i], y: p[i + 1])) }
            if command.kind == "polygonFill" { path.closeSubpath() }
        case "polygonsFill", "polygonsFillEO":
            // 多个闭合多边形并成一个 Path（昼夜地图的 127 块陆地；昼 / 曙暮的「矩形 + 夜冠」）：[点数, x, y, …, 点数, x, y, …]。
            var i = 0
            while i < p.count {
                let count = Int(p[i]); i += 1
                guard count >= 3, i + 2 * count <= p.count else { break }
                path.move(to: CGPoint(x: p[i], y: p[i + 1]))
                for k in 1..<count { path.addLine(to: CGPoint(x: p[i + 2 * k], y: p[i + 2 * k + 1])) }
                path.closeSubpath()
                i += 2 * count
            }
        case "dots":
            // 一串小圆点并成一个 Path（地球窗的城市灯火）：[x, y, x, y, …]，半径放在 lineWidth 里。
            let r = command.lineWidth
            for i in stride(from: 0, to: p.count - 1, by: 2) {
                path.addEllipse(in: CGRect(x: p[i] - r, y: p[i + 1] - r, width: 2 * r, height: 2 * r))
            }
        default: preconditionFailure("Unknown Rust scene command: \(command.kind)")
        }
        return path
    }
}
