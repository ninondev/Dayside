// SPDX-License-Identifier: GPL-3.0-only
//
//  SkyStrip.swift
//  TahoeTime
//
//  工具窗十页共用的出身：每页页首一行，行首一条「这里前后 12 小时的天」（与面板滑块的轨道同一批色标，Rust `sky.strip`，
//  216 点长（放不下最短 120），不与正文的昼夜条同宽，免得被当成它们的刻度），正在看的那一刻是带上的一颗太阳（那一刻这里是白天）
//  或一弯月亮（夜里）；带子后面一句说看的是哪一刻：没拖过时间写「现在」，拖过了写钟点与「3小时后」，
//  行尾给「回到现在」（点带子也回到现在），此刻在带上留一个小三角。
//  离此刻超过 12 小时，带改画那一刻前后 12 小时的天，此刻不在带上，那一句带日期。
//  只在打开、每分钟（`core.now` 走一格）与拖时间时算，不逐帧；工具窗关了它就不在。
//

import SwiftUI

/// Rust `sky.strip` 的输出：色标、正在看的那一刻与此刻在带上的位置（0…1）、那一刻这里是昼是夜、
/// 「不使用颜色区分」时的昼夜边界。
struct SkyStripState: Decodable, Equatable, Sendable {
    struct Stop: Decodable, Equatable, Sendable { let at: Double; let color: String }
    struct Mark: Decodable, Equatable, Sendable { let at: Double; let full: Bool }
    let stops: [Stop]
    let marker: Double
    let now: Double?
    let beyond: Bool
    let dayHere: Bool?
    let marks: [Mark]

    /// 没有本机坐标或时刻超出 1800–2100：中性的带，标记在正中。
    static let neutral = SkyStripState(stops: [], marker: 0.5, now: 0.5, beyond: false, dayHere: nil, marks: [])

    private struct Input: Encodable {
        let now: Double
        let instant: Double
        let latitude: Double?
        let longitude: Double?
        let marks: Bool
    }

    static func compute(now: Date, instant: Date, coordinate: Coordinate?, marks: Bool) -> SkyStripState {
        let input = Input(now: now.timeIntervalSince1970, instant: instant.timeIntervalSince1970,
                          latitude: coordinate?.latitude, longitude: coordinate?.longitude, marks: marks)
        return (try? RustCore.attempt("sky.strip", input, as: SkyStripState.self)) ?? .neutral
    }
}

/// 只在输入变了时才去 Rust 算一次：此刻按分钟、看的那一刻按秒、本机坐标、要不要刻度。
/// 视图因为别的原因重算 body（窗口改大小、旁边的字变了）时直接拿上一次的结果。
@MainActor
final class SkyStripMemo {
    private struct Key: Equatable {
        let minute: Int
        let instant: Int
        let latitude: Double?
        let longitude: Double?
        let marks: Bool
    }
    private var key: Key?
    private(set) var state = SkyStripState.neutral
    /// 这条天画成的一行像素（432 × 1，约 1.7 KB），显示时横向拉满带子。不用 SwiftUI 的 73 色标渐变填充：
    /// 带子跨页常驻，每次重画都重新铺渐变，走完十页工具窗的峰值多约 1.1 MiB（实测，内存巡回，见设计稿第五节）。
    private(set) var ribbon: CGImage?
    /// 真去 Rust 算过几次（测试用：同一分钟、同一刻不重算）。
    private(set) var computations = 0

    func update(now: Date, instant: Date, coordinate: Coordinate?, marks: Bool) {
        let next = Key(minute: Int((now.timeIntervalSince1970 / 60).rounded(.down)), instant: Int(instant.timeIntervalSince1970.rounded()),
                       latitude: coordinate?.latitude, longitude: coordinate?.longitude, marks: marks)
        guard next != key else { return }
        key = next
        computations += 1
        let stops = state.stops
        state = SkyStripState.compute(now: now, instant: instant, coordinate: coordinate, marks: marks)
        // 拖时间时带子不动（色标不变），不重画那行像素。
        if state.stops != stops || ribbon == nil { ribbon = Self.ribbonImage(state.stops) }
    }

    /// 色标 → 一行像素：Core Graphics 在 sRGB 里按色标线性插值（与 SwiftUI 渐变默认的插值同一种），默认宽 432 像素（216 点的 2 倍）；
    /// 换算页共同时间轴的天也走这里（宽 720）。
    static func ribbonImage(_ stops: [SkyStripState.Stop], width: Int = 432) -> CGImage? {
        guard stops.count > 1, width > 1, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let colors = stops.map { stop -> CGColor in
            let (r, g, b) = LightPalette.components(stop.color)
            return CGColor(colorSpace: space, components: [r, g, b, 1]) ?? CGColor(gray: 0.5, alpha: 1)
        }
        let locations = stops.map { CGFloat($0.at) }
        guard let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations),
              let context = CGContext(data: nil, width: width, height: 1, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: CGFloat(width), y: 0), options: [])
        return context.makeImage()
    }
}

struct SkyStrip: View {
    @Environment(AppModel.self) private var model
    @Environment(TimeCore.self) private var core
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @State private var memo = SkyStripMemo()

    /// 带子的长度（点）：一小时 9 点，与正文的昼夜条不同宽，不会被当成它们的刻度去对；放不下最短缩到 120。
    static let length: CGFloat = 216
    static let shortest: CGFloat = 120

    var body: some View {
        let _ = memo.update(now: core.now, instant: core.referenceDate,
                            coordinate: SkyPanel.homeCoordinate(zones: core.zones), marks: differentiateWithoutColor)
        let scrubbing = core.isScrubbing
        // 一行，只有一份带子（第一版把六种整行写法交给 `ViewThatFits` 挑，每种都带一份带子；冷启动太阳与月亮页，
        // 有它没它峰值差 1.57 MiB，改成一行之后差约 0.5 MiB，实测）。
        // 放不下时按优先级让：那一句先拿够（它自己在三种长短里挑），带子其次（216 点，最短 120），
        // 「回到现在」最后（全名放不下退成图标）。
        HStack(alignment: .center, spacing: 12) {
            SkyRibbon(state: memo.state, ribbon: memo.ribbon, scrubbing: scrubbing)
                .frame(minWidth: Self.shortest, idealWidth: Self.length, maxWidth: Self.length)
                .frame(height: 16)
                .contentShape(Rectangle())
                .onTapGesture { if scrubbing { model.resetToNow() } }
                .accessibilityHidden(true)
                .layoutPriority(1)
            SkyStripCaption()
                .layoutPriority(2)
            Spacer(minLength: 8)
            if scrubbing {
                ViewThatFits(in: .horizontal) {
                    backButton(iconOnly: false)
                    backButton(iconOnly: true)
                }
            }
        }
        .frame(minHeight: 24)
    }

    /// 与面板滑块下的「回到现在」同一个样子（无边框、半粗、带回头箭头），悬停与读屏都是全名。
    private func backButton(iconOnly: Bool) -> some View {
        Button { model.resetToNow() } label: {
            Group {
                if iconOnly {
                    Image(systemName: "arrow.uturn.backward")
                } else {
                    Label("回到现在", systemImage: "arrow.uturn.backward")
                }
            }
            .fontWeight(.semibold)
            .padding(.horizontal, 6)
            .frame(minWidth: 24, minHeight: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .appFont(.callout)
        .help(Text("回到现在"))
        .accessibilityLabel(Text("回到现在"))
        .fixedSize()
    }
}

/// 带子后面那一句：没拖过时间写「现在」；拖过了写看的那一刻（本机钟点，不是今天就带上日期）与离此刻多远。
/// 放不下依次：全句 → 「+17h24m」→ 去掉日期。三种都只是几段字，`ViewThatFits` 在它们之间挑。读屏照旧念全句。
private struct SkyStripCaption: View {
    @Environment(TimeCore.self) private var core

    var body: some View {
        Group {
            if core.isScrubbing {
                let parts = parts
                ViewThatFits(in: .horizontal) {
                    line(day: parts.day, time: parts.time, shift: parts.shift)
                    line(day: parts.day, time: parts.time, shift: parts.compact)
                    line(day: nil, time: parts.time, shift: parts.compact)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isStaticText)
                .accessibilityLabel(Text(verbatim: [parts.day, parts.shift, parts.time].compactMap { $0 }.joined(separator: ", ")))
            } else {
                Text("现在").fontWeight(.semibold)
            }
        }
        .appFont(.callout)
        .lineLimit(1)
    }

    private var parts: (day: String?, time: String, shift: String, compact: String) {
        let date = core.referenceDate
        let offset = core.displayOffset
        let time = TimeFormatting.string(for: date, in: .current, format: ClockFormat(hourStyle: core.settings.hourStyle, showSeconds: false))
        // 与面板滑块下那一句同一个出口：方向句的时长按各语言的变格与复数模板拼（「3小时后」「через 2 часа」）。
        let shift = SliderPosition.offsetLabel(seconds: offset, locale: core.uiLocale)
        let compact: String = PresentationCore.call("scroll_label", ["seconds": offset])
        var calendar = Calendar.current
        calendar.timeZone = .current
        // 与面板的日期片同一写法：月、日、星期简写，不是今年才写年份。
        let day: String? = calendar.isDate(date, inSameDayAs: core.now) ? nil : {
            var style = Date.FormatStyle(locale: core.uiLocale, calendar: calendar, timeZone: .current).month(.abbreviated).day().weekday(.abbreviated)
            if calendar.component(.year, from: date) != calendar.component(.year, from: core.now) { style = style.year() }
            return date.formatted(style)
        }()
        return (day, time, shift, compact)
    }

    private func line(day: String?, time: String, shift: String) -> some View {
        HStack(spacing: 5) {
            if let day {
                Text(verbatim: day)
                Text(verbatim: "·").foregroundStyle(.readableSecondary)
            }
            Text(verbatim: time).fontWeight(.semibold).monospacedDigit()
            Text(verbatim: "·").foregroundStyle(.readableSecondary)
            Text(verbatim: shift).monospacedDigit()
        }
        .fixedSize()
    }
}

/// 带子本身：8 点高的胶囊涂这里的天（`SkyStripMemo.ribbon` 那一行像素拉满），外面一道细描边（与昼夜条同一条规矩：浅色窗口里白天那截与窗口底几乎同色，
/// 没有边就丢了形状；深色外观里天色压暗 22%，白天那截不当整页最亮的一块；「提高对比度」时描边加重、不压暗）。
/// 正在看的那一刻画太阳或月亮（与面板滑块的圆点同一套，小一号、不带投影：它不是拿来拖的）；
/// 拖过时间且此刻还在带上，此刻那里留一个朝下的小三角。各样东西按「在带上的位置」由 `FractionLayout` 摆，不用 `GeometryReader`。
struct SkyRibbon: View {
    let state: SkyStripState
    let ribbon: CGImage?
    let scrubbing: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    private static let band: CGFloat = 8
    private static let disc: CGFloat = 11

    var body: some View {
        let increased = contrast == .increased
        FractionLayout {
            Group {
                if let ribbon {
                    Image(decorative: ribbon, scale: 1).resizable().interpolation(.high)
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
                .clipShape(Capsule())
                .overlay { if colorScheme == .dark && !increased { Capsule().fill(Color.black.opacity(0.22)) } }
                .overlay(Capsule().strokeBorder(SkyLaneForegroundStyle(stops: state.stops),
                                                lineWidth: increased ? 1 : 0.75))
                .frame(height: Self.band)
            ForEach(Array(state.marks.enumerated()), id: \.offset) { _, mark in
                let tick = mark.full ? Self.band : Self.band / 2
                Rectangle().fill(LightPalette.skyLuminance(stops: state.stops, at: mark.at, shade: colorScheme == .dark && !increased ? 0.22 : 0)
                    .map { AnyShapeStyle(SkyTextRole.stripGlyph.foreground(on: $0)) } ?? AnyShapeStyle(.primary))
                    .frame(width: 1, height: tick)
                    .fraction(mark.at, dy: (tick - Self.band) / 2)
            }
            if scrubbing, let now = state.now {
                NowNotch().fill(.primary).frame(width: 7, height: 4)
                    .fraction(now, dy: -Self.band / 2 - 3.5)
            }
            StripMarker(day: state.dayHere, luminance: LightPalette.skyLuminance(stops: state.stops, at: state.marker, shade: colorScheme == .dark && !increased ? 0.22 : 0))
                .frame(width: Self.disc, height: Self.disc)
                .fraction(state.marker)
        }
        // 反色开着：带子连同太阳月亮预反一次，屏幕上仍是原来的天色（与面板滑块、昼夜条同一套）。
        .modifier(SkyPreInvert())
    }
}

/// 一行里按「横向位置 0…1」摆东西：没标位置的铺满整宽、竖向居中（胶囊、图底）；标了位置的圆心落在「位置 × 宽」，
/// 两头各收半个自身宽（不出头），竖向居中再挪 `dy`。页首带子的标记与刻度、太阳与月亮主图的横轴钟点都用它，
/// 不用 `GeometryReader` 读了尺寸再 `.position`：一个小 `Layout` 一次摆完，没有为读几何多出来的一层视图。
struct FractionLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(width: proposal.width ?? 216, height: proposal.height ?? height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            guard let fraction = subview[FractionKey.self] else {
                subview.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center,
                              proposal: ProposedViewSize(width: bounds.width, height: nil))
                continue
            }
            let size = subview.sizeThatFits(.unspecified)
            let x = min(max(bounds.minX + CGFloat(fraction) * bounds.width, bounds.minX + size.width / 2), bounds.maxX - size.width / 2)
            subview.place(at: CGPoint(x: x, y: bounds.midY + subview[FractionOffsetKey.self]), anchor: .center, proposal: .unspecified)
        }
    }
}

private struct FractionKey: LayoutValueKey { static let defaultValue: Double? = nil }
private struct FractionOffsetKey: LayoutValueKey { static let defaultValue: CGFloat = 0 }

extension View {
    /// 在 `FractionLayout` 里的横向位置（0…1）与竖向偏移。
    func fraction(_ value: Double, dy: CGFloat = 0) -> some View {
        layoutValue(key: FractionKey.self, value: value).layoutValue(key: FractionOffsetKey.self, value: dy)
    }
}

/// 此刻的位置：一个朝下的小三角，压在带子上沿。
private struct NowNotch: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// 带上的太阳或月亮：白天一颗金盘，夜里一弯月（纸色的盘，左下压一块夜色），都有一道深色细边。
/// 与面板滑块的圆点同一套画法，小一号、不带光晕与投影：它只是指出那一刻，不是拿来拖的把手。
/// 不知道这里的天（没有本机坐标、年份越界）时是一枚纸色的圆，不猜昼夜。
private struct StripMarker: View {
    let day: Bool?
    let luminance: Double?

    var body: some View {
        ZStack {
            switch day {
            case true?:
                Circle().fill(LightPalette.sun)
            case false?:
                Circle().fill(LightPalette.paper)
                Circle().fill(LightPalette.moonDark)
                    .offset(x: -3.4, y: -0.6)
                    .mask(Circle())
            case nil:
                Circle().fill(LightPalette.paper)
            }
            Circle().strokeBorder(SkyGlyphRimStyle(luminance: luminance, role: .stripGlyph, radius: 5.5, halfBand: 4), lineWidth: 1.25)
        }
    }
}
