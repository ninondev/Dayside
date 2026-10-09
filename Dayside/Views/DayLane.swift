// SPDX-License-Identifier: GPL-3.0-only
//
//  DayLane.swift
//  Dayside
//
//  昼夜条：Dayside 的招牌——一条按**绝对时间**铺开的 24 小时带。所有行对齐同一个
//  时间框（本机当天），同一根参考线穿过所有行；时区差就成了各行昼夜段的错位，不用读数字也看得见
//  「那边是白天还是深夜」。面板、人物页、排会页三处同一份，用户学一次就够。
//
//  几何全部由 Rust `presentation.day_lane` 给；天色画成一行像素拉满，其余命令画成纯形状。
//  不用 `Canvas`，不启动它的 Metal 缓冲。
//  是天色版：上面一条是那个地方那一天真实的天（Rust `sky::lane_stops`，与面板行、滑块轨道同一种颜色），
//  可约 / 工作段与排会窗口挪到底下一道细轨里（不再半透明地盖在天色上），参考线带一道底色衬边。
//

import SwiftUI

/// 昼夜条共用的横轴：从某个钟的当天零点起、长一整个民用日（23 / 24 / 25 小时，换钟日也对）。
struct DayLaneFrame: Hashable, Sendable {
    let start: Date
    let length: TimeInterval
    /// 刻度按哪个钟画（本机）。
    let timeZoneID: String

    var timeZone: TimeZone { TimeZone(identifier: timeZoneID) ?? .current }
    var end: Date { start.addingTimeInterval(length) }

    /// 包含 `reference` 的本机当天。穿梭过午夜时整个框跳到下一天（各行的昼夜段随之重算，参考线从右缘回到左缘）。
    static func homeDay(containing reference: Date, timeZone: TimeZone = .current) -> DayLaneFrame {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = calendar.startOfDay(for: reference)
        let length = calendar.dateInterval(of: .day, for: start)?.duration ?? 86_400
        return DayLaneFrame(start: start, length: length, timeZoneID: timeZone.identifier)
    }

    /// 某一刻在框里的横向位置（0…width），框外钉在边上。
    func x(of date: Date, width: CGFloat) -> CGFloat {
        CGFloat(((date.timeIntervalSince1970 - start.timeIntervalSince1970) / length).clamp01) * width
    }
}

private extension Double {
    var clamp01: Double { Swift.min(1, Swift.max(0, self)) }
}

/// 反色开着时，面板跟着天色会整块预反一次：这个环境值告诉子视图别再各自反第二遍。`.colorInvert` 连地图那层
/// AppKit 图层（`MapSurface`）也一起反（截图实测：图层上再挂 CIColorInvert 就反了两遍），所以地图不另反。
private struct SkyPreInvertedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var skyPreInverted: Bool {
        get { self[SkyPreInvertedKey.self] }
        set { self[SkyPreInvertedKey.self] = newValue }
    }
}

/// 反色开着时的预反色：这块天色先反一次，系统再把整屏反一次，屏幕上看到的就是原来的样子
/// （夜仍是墨、昼仍是纸）。外层已整块反过（`skyPreInverted`，面板跟着天色时）就不再反第二遍。
struct SkyPreInvert: ViewModifier {
    @Environment(\.accessibilityInvertColors) private var invertColors
    @Environment(\.skyPreInverted) private var preInverted

    func body(content: Content) -> some View {
        if invertColors && !preInverted {
            content.colorInvert()
        } else {
            content
        }
    }
}

/// 一条昼夜带。`available` 是这一行的可约 / 工作区间（画在昼夜之上、上下各收 `inset`），`windows` 是排会的
/// 重叠窗口（与排会时间轴同一画法：黄 = 有人在时段外、绿 = 所有人都合适），`reference` 是参考线。
nonisolated struct DayLane: View {
    enum AvailableStyle: String, Sendable { case accent, green }
    struct Window: Encodable, Hashable, Sendable {
        let start: Double
        let end: Double
        /// 0 = 所有人都合适，1 = 有人在时段外（`OverlapPlanner.Window.Tier` 的原始值）。
        let tier: Int
    }

    let frame: DayLaneFrame
    let coordinate: Coordinate?
    var reference: Date
    var available: [DateInterval] = []
    var availableStyle: AvailableStyle = .accent
    var windows: [Window] = []
    var inset: CGFloat = 2
    /// 点到某一刻（排会时间轴用来穿梭）。nil = 不响应点击。
    var onTap: ((Date) -> Void)? = nil

    /// 保留时间戳接口；实际动画由参考线子视图承担。
    var animatableData: Double {
        get { reference.timeIntervalSince1970 }
        set { reference = Date(timeIntervalSince1970: newValue) }
    }

    struct Input: Encodable, Equatable, Sendable {
        let start: Double
        let length: Double
        let reference: Double
        let width: Double
        let height: Double
        let latitude: Double?
        let longitude: Double?
        let available: [PresentationCore.BandSpan]
        let availableStyle: String
        let windows: [Window]
        let inset: Double
        /// 天色版（上面是那里真实的天，可约段与窗口在底下的细轨里）。
        let sky = true
        /// 「不使用颜色区分」开着：让 Rust 在昼 / 曙暮 / 夜的边界画刻度（色弱或单色输出上也读得出）。
        let marks: Bool
    }

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let input = Input(
                start: frame.start.timeIntervalSince1970, length: frame.length,
                reference: reference.timeIntervalSince1970, width: size.width, height: size.height,
                latitude: coordinate?.latitude, longitude: coordinate?.longitude,
                available: available.map { .init(start: $0.start.timeIntervalSince1970, end: $0.end.timeIntervalSince1970) },
                availableStyle: availableStyle.rawValue, windows: windows, inset: inset, marks: differentiateWithoutColor)
            DayLaneScene(input: input, size: size, frame: frame)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            // 反色开着时整条预反一次（含刻度与参考线）；面板整块已反过时由 `skyPreInverted` 拦下，不反第二遍。
            .modifier(SkyPreInvert())
            .contentShape(Rectangle())
            .onTapGesture { location in
                guard let onTap, size.width > 0 else { return }
                let timestamp = PresentationCore.scalar("overlap_tap", ["start": frame.start.timeIntervalSince1970,
                    "length": frame.length, "x": location.x, "width": size.width])
                onTap(Date(timeIntervalSince1970: timestamp))
            }
        }
        .accessibilityHidden(true)
    }
}

/// 昼夜条上方的小时刻度：按 `frame.timeZone` 当天的实际时刻算（换钟日也对得上），每 `every` 小时一个标签。
/// 刻度数字用固定 `.font`（轴的几何是固定的，跟着「文字大小」放大会撞在一起）。
struct DayLaneRuler: View {
    @Environment(TimeCore.self) private var core
    let frame: DayLaneFrame
    var every: Int = 3

    /// 框里的整点刻度：框可以从任何时刻起（旅行页从中午到次日中午），所以看框起点那天与下一天两天的整点，
    /// 只留落在框内的；换钟日按当地真实时刻算。
    private var ticks: [(hour: Int, x: Double)] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = frame.timeZone
        let step = max(1, every)
        let firstDay = calendar.startOfDay(for: frame.start)
        var out: [(Int, Double)] = []
        for dayOffset in 0...1 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: firstDay) else { continue }
            for hour in stride(from: 0, through: 23, by: step) {
                guard let at = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) else { continue }
                let fraction = (at.timeIntervalSince1970 - frame.start.timeIntervalSince1970) / frame.length
                // 框的末端不标（整天框的右端是次日 0 点，与左端的 0 重复；中午到中午的框右端是 12，左端已有）。
                if fraction >= -0.0001, fraction < 0.999 { out.append((hour, min(max(fraction, 0), 1))) }
            }
        }
        return out
    }

    var body: some View {
        let locale = core.uiLocale
        let hourCycle = ClockText.hourCycle(for: core.settings.hourStyle)
        let ticks = ticks
        return GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                ForEach(Array(ticks.enumerated()), id: \.offset) { _, tick in
                    let x = CGFloat(tick.x) * size.width
                    Path { path in
                        path.move(to: CGPoint(x: x, y: size.height - 3))
                        path.addLine(to: CGPoint(x: x, y: size.height))
                    }
                    .stroke(.tertiary, lineWidth: 1)
                    let hour = switch hourCycle {
                    case .zeroToEleven: tick.hour % 12
                    case .oneToTwelve: (tick.hour + 11) % 12 + 1
                    case .zeroToTwentyThree: tick.hour
                    case .oneToTwentyFour: tick.hour == 0 ? 24 : tick.hour
                    @unknown default: tick.hour
                    }
                    Text(verbatim: hour.formatted(.number.locale(locale))).font(.caption2).foregroundStyle(.readableSecondary)
                        .fixedSize()
                        // 两位数字约 14 pt 宽，贴边的刻度往里收一点，别被裁掉。
                        .position(x: min(max(x, 8), size.width - 8), y: (size.height - 3) / 2)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// 只缓存完全相同的输入；参考时刻也逐值比较。
@MainActor
final class DayLaneSceneMemo {
    private var input: DayLane.Input?
    private(set) var commands: [SceneCommand] = []
    private(set) var computations = 0

    nonisolated init() {}

    func update(_ next: DayLane.Input) {
        if input == next {
            input = next
            return
        }
        input = next
        computations += 1
        commands = PresentationCore.call("day_lane", next)
    }
}

@MainActor
private struct DayLaneScene: View {
    let input: DayLane.Input
    let size: CGSize
    let frame: DayLaneFrame
    @State private var memo = DayLaneSceneMemo()

    nonisolated init(input: DayLane.Input, size: CGSize, frame: DayLaneFrame) {
        self.input = input
        self.size = size
        self.frame = frame
    }

    var body: some View {
        let _ = memo.update(input)
        let stops = memo.commands.first { $0.kind == "gradient" }?.stops?.map { SkyStripState.Stop(at: $0.at, color: $0.color) } ?? []
        ZStack(alignment: .topLeading) {
            ForEach(Array(memo.commands.dropLast(2).enumerated()), id: \.offset) { _, command in
                if command.kind == "gradient" {
                    DayLaneGradient(command: command, size: size)
                } else if command.kind == "line", command.style == "primary" || command.style == "background" {
                    SceneShape.path(for: command).stroke(SkyLaneForegroundStyle(stops: stops,
                        backing: command.style == "background", shadeWhenContrastIncreased: true), lineWidth: command.lineWidth)
                } else {
                    SceneShape(command: command)
                }
            }
            DayLaneReferenceLines(commands: Array(memo.commands.suffix(2)), frame: frame,
                                  reference: Date(timeIntervalSince1970: input.reference), width: size.width, stops: stops)
        }
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(SkyLaneForegroundStyle(stops: stops, shadeWhenContrastIncreased: true), lineWidth: 0.75))
    }
}

/// 只让参考线按时间戳插值；越界时沿原时间框钳住。
nonisolated struct DayLaneReferenceLines: View, Animatable {
    let commands: [SceneCommand]
    let frame: DayLaneFrame
    var reference: Date
    let targetReference: Date
    let width: CGFloat
    let stops: [SkyStripState.Stop]

    nonisolated init(commands: [SceneCommand], frame: DayLaneFrame, reference: Date, width: CGFloat, stops: [SkyStripState.Stop] = []) {
        self.commands = commands
        self.frame = frame
        self.reference = reference
        self.targetReference = reference
        self.width = width
        self.stops = stops
    }

    var animatableData: Double {
        get { reference.timeIntervalSince1970 }
        set { reference = Date(timeIntervalSince1970: newValue) }
    }

    var animatedOffset: CGFloat {
        frame.x(of: reference, width: width) - frame.x(of: targetReference, width: width)
    }

    private var animatedCommands: [SceneCommand] {
        let shift = Double(animatedOffset)
        return commands.map { command in
            guard command.kind == "line", command.geometry.count == 4 else { return command }
            var geometry = command.geometry
            // 先移动几何，再描边；避免平移已取样的像素改变线条覆盖率。
            geometry[0] += shift
            geometry[2] += shift
            return SceneCommand(kind: command.kind, geometry: geometry, style: command.style,
                                opacity: command.opacity, lineWidth: command.lineWidth, stops: command.stops)
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(animatedCommands.enumerated()), id: \.offset) { _, command in
                if command.kind == "line", command.style == "primary" || command.style == "background" {
                    SceneShape.path(for: command).stroke(SkyLaneForegroundStyle(stops: stops,
                        backing: command.style == "background", shadeWhenContrastIncreased: true), lineWidth: command.lineWidth)
                } else {
                    SceneShape(command: command)
                }
            }
        }
        .transaction { $0.animation = nil }
    }
}

/// 色标不变时复用一行像素；只保留当前结果。
@MainActor
final class DayLaneRibbonMemo {
    private var stops: [SceneCommand.Stop]?
    private var rasterWidth: Int?
    private var rasterSpan: Double?
    private(set) var ribbon: CGImage?
    static let width = 720

    nonisolated init() {}

    private static func binary16(_ value: Double) -> Double {
        guard value.isFinite else { return value }
        let quantum = Double(sign: .plus, exponent: max(value.exponent, -14) - 10, significand: 1)
        return (value / quantum).rounded(.toNearestOrEven) * quantum
    }

    func update(_ next: [SceneCommand.Stop], width: Int = 720, span: Double? = nil) {
        let physicalSpan = span ?? Double(width)
        if let stops, rasterWidth == width, rasterSpan == physicalSpan, stops.count == next.count,
           zip(stops, next).allSatisfy({ pair in pair.0.at == pair.1.at && pair.0.color == pair.1.color }) {
            self.stops = next
            return
        }
        stops = next
        rasterWidth = width
        rasterSpan = physicalSpan
        guard next.count > 1, width > 1, physicalSpan.isFinite, physicalSpan > 0 else { ribbon = nil; return }
        guard next.allSatisfy({ $0.at.isFinite }),
              zip(next, next.dropFirst()).allSatisfy({ pair in pair.0.at <= pair.1.at }),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: 1, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let data = context.data else { ribbon = nil; return }
        let samples = next.map { stop -> (at: Double, r: Double, g: Double, b: Double) in
            let (r, g, b) = LightPalette.components(stop.color)
            return (stop.at, r, g, b)
        }
        let coefficients = zip(samples, samples.dropFirst()).map { pair -> (inverse: Double, offset: Double) in
            let span = pair.1.at - pair.0.at
            let inverse = span > 0 ? Self.binary16(1 / span) : 0
            return (inverse, Self.binary16(-pair.0.at * inverse))
        }
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        var segment = 0
        // 像素中心的位置统一按二进制 16 位精度取样，再沿色标插值。
        for x in 0..<width {
            let center = (Double(x) + 0.5) / Double(width)
            let position = Self.binary16(center)
            while segment + 1 < samples.count - 1 && samples[segment + 1].at <= position { segment += 1 }
            let first = samples[segment]
            let last = samples[segment + 1]
            let span = last.at - first.at
            let coefficient = coefficients[segment]
            let fraction: Double
            if span > 0, coefficient.inverse.isFinite, coefficient.offset.isFinite {
                let product = Self.binary16(position * coefficient.inverse)
                fraction = min(1, max(0, Self.binary16(product + coefficient.offset)))
            } else {
                fraction = span > 0 ? min(1, max(0, (position - first.at) / span)) : 1
            }
            for channel in 0..<3 {
                let components: (Double, Double)
                switch channel {
                case 0: components = (first.r, last.r)
                case 1: components = (first.g, last.g)
                default: components = (first.b, last.b)
                }
                let value = components.0 + (components.1 - components.0) * fraction
                pixels[x * 4 + channel] = UInt8(min(255, max(0, Int((value * 255).rounded()))))
            }
            pixels[x * 4 + 3] = 255
        }
        ribbon = context.makeImage()
    }
}

/// 只接 DayLane 的渐变；其他绘图命令仍走原执行器。
@MainActor
struct DayLaneGradient: View {
    let command: SceneCommand
    let size: CGSize
    let onRibbonUse: (@MainActor () -> Void)?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @State private var memo = DayLaneRibbonMemo()

    nonisolated init(command: SceneCommand, size: CGSize, onRibbonUse: (@MainActor () -> Void)? = nil) {
        self.command = command
        self.size = size
        self.onRibbonUse = onRibbonUse
    }

    var body: some View {
        let physicalSpan = CGFloat(command.geometry[2]) * displayScale
        let _ = memo.update(command.stops ?? [], width: max(2, Int(physicalSpan.rounded(.up))), span: physicalSpan)
        let path = SceneShape.path(for: command)
        Group {
            if let ribbon = memo.ribbon {
                let _ = onRibbonUse?()
                Image(decorative: ribbon, scale: 1)
                    .resizable()
                    .interpolation(.low)
                    .frame(width: CGFloat(ribbon.width) / displayScale, height: size.height)
                    .offset(x: CGFloat(command.geometry[0]), y: CGFloat(command.geometry[1]))
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
                    .clipShape(path, style: FillStyle(eoFill: false, antialiased: true))
                    .overlay {
                        if colorScheme == .dark { path.fill(Color.black.opacity(0.22)) }
                    }
            } else {
                SceneShape(command: command)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}
