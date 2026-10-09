// SPDX-License-Identifier: GPL-3.0-only
//
//  MomentTable.swift
//  Dayside
//
//  换算页的共同时间轴：读出的那一刻，在每个地方的天里。
//  每个地方一行：衬线地名与一行小字（原文 / 本机 / 快 8小时），挨着是那里的钟点（钟点字中号）与「次日（周日）」，
//  右边是那里的天（本机当天 0–24 时，各行同一个框、上下对齐）；顶上一行本机的小时刻度，读出的那一刻是一根竖线，穿过所有的天。
//  点任何一条天（或刻度）上的某处：竖线挪到那里，各地钟点跟着变，读法不变，刻度下沿留一个小三角标着原来的那一刻；
//  「在面板里看这一刻」才把整个 App 带过去（由页面给）。不能拖：拖动会让页面同时说两个时刻（字上的下划线标的是原文那一刻，表上却是另一刻）。
//
//  天的颜色由 Rust `sky.lanes` 一次给齐（每条与同一框、同一地方的昼夜条逐个色标相同），先画成一行像素（720 × 1）再拉满，
//  不用 SwiftUI 渐变填充（反复重画的渐变多占堆，实测）。只在框或地点变了时去 Rust（读到、换一处、跨过午夜）；
//  竖线与点出来的那一刻只是框里的位置，点一下、走一分钟都不再去 Rust，不逐帧算。工具窗关了它就不在。
//

import SwiftUI

/// Rust `sky.lanes` 给的一条：天的色标、昼 / 曙暮 / 夜三段（位置 0…1）、「不使用颜色区分」时的边界刻度。
struct MomentLaneArt: Decodable, Equatable, Sendable {
    struct Stop: Decodable, Equatable, Sendable { let at: Double; let color: String }
    struct Band: Decodable, Equatable, Sendable { let from: Double; let to: Double; let kind: Int }
    struct Mark: Decodable, Equatable, Sendable { let at: Double; let full: Bool }
    let stops: [Stop]
    let bands: [Band]
    let marks: [Mark]

    static let unknown = MomentLaneArt(stops: [], bands: [], marks: [])

    /// 框里某个位置是白天（太阳在地平线上）还是夜里；没有坐标时不知道。
    func isDay(at fraction: Double) -> Bool? {
        guard !bands.isEmpty else { return nil }
        let at = min(max(fraction, 0), 1)
        let band = bands.first { $0.from <= at && at < $0.to } ?? bands.last
        return band.map { $0.kind == 2 }
    }
}

/// 只在框、地点或「要不要刻度」变了时去 Rust 算一次，并把每条的天画成一行像素；别的原因重算 body（点了一下、钟走了一分钟、
/// 窗口改大小）直接拿上一次的。跟着视图走（`@State`），工具窗关了就没了。
@MainActor
final class MomentLaneMemo {
    private struct Key: Equatable {
        let start: Double
        let length: Double
        let coordinates: [Coordinate?]
        let marks: Bool
    }
    private struct Output: Decodable { let lanes: [MomentLaneArt] }
    private struct Place: Encodable { let latitude: Double?; let longitude: Double? }
    private struct Input: Encodable { let start: Double; let end: Double; let places: [Place]; let marks: Bool }

    private var key: Key?
    private(set) var art: [MomentLaneArt] = []
    private(set) var ribbons: [CGImage?] = []
    /// 真去 Rust 算过几次（测试用）。
    private(set) var computations = 0

    /// 每条天画成的一行像素的宽：最宽的正文栏里天那一列约 380 点，两倍再富余一点；天色是平缓的渐变，拉宽看不出。
    static let ribbonWidth = 720

    func update(frame: DayLaneFrame, coordinates: [Coordinate?], marks: Bool) {
        let next = Key(start: frame.start.timeIntervalSince1970, length: frame.length, coordinates: coordinates, marks: marks)
        guard next != key else { return }
        key = next
        computations += 1
        let input = Input(start: next.start, end: next.start + next.length,
                          places: coordinates.map { Place(latitude: $0?.latitude, longitude: $0?.longitude) }, marks: marks)
        let lanes = (try? RustCore.attempt("sky.lanes", input, as: Output.self))?.lanes ?? []
        art = coordinates.indices.map { $0 < lanes.count ? lanes[$0] : .unknown }
        ribbons = art.map { lane in
            SkyStripMemo.ribbonImage(lane.stops.map { SkyStripState.Stop(at: $0.at, color: $0.color) }, width: Self.ribbonWidth)
        }
    }
}

/// 本机时间轴的地点标识。
struct LocalTimelineLabel: View {
    @Environment(TimeCore.self) private var core

    var body: some View {
        Text(verbatim: String(format: L10n.string("本机（%@）", locale: core.uiLocale),
                              core.placeName(forTimeZoneID: TimeZone.current.identifier)))
            .appFont(.caption).foregroundStyle(.readableSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 共同时间轴这一块。页面给地点、读出的那一刻（与时间段的终点）、「次日」按哪个钟的那一天算，以及点出来的那一刻（绑定，页面也要用：
/// 拷贝与「在面板里看这一刻」都按表上正在显示的那一刻）。
struct MomentTable: View {
    struct Place: Identifiable, Equatable {
        /// 时区标识符（表里不重复）。
        var id: String { zone.identifier }
        let zone: TimeZone
        let name: String
        /// 地名下面那行小字的前半：「原文」「本机」。
        let tags: [String]
        let coordinate: Coordinate?
    }

    let places: [Place]
    let start: Date
    let end: Date?
    let dayReference: TimeZone
    @Binding var peek: Date?
    var interactive = true

    @Environment(TimeCore.self) private var core
    @Environment(\.textScale) private var textScale
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @State private var memo = MomentLaneMemo()

    var body: some View {
        let frame = DayLaneFrame.homeDay(containing: start)
        let _ = memo.update(frame: frame, coordinates: places.map(\.coordinate), marks: differentiateWithoutColor)
        let shown = interactive ? peek ?? start : start
        let line = Self.fraction(of: shown, in: frame)
        let read = Self.fraction(of: start, in: frame)
        // 时间段（没点别处时）在每条天的下沿一道细轨里标出来，与昼夜条的可约段同一个画法。
        let range: ClosedRange<Double>? = peek == nil ? end.map { Self.fraction(of: start, in: frame)...max(Self.fraction(of: $0, in: frame), read) } : nil
        MomentTableLayout {
            Text(verbatim: ClockText.day(frame.start.addingTimeInterval(frame.length / 2), in: frame.timeZone, locale: core.uiLocale,
                                         now: core.now, weekday: true))
                .appFont(.caption).foregroundStyle(.readableSecondary)
                .fixedSize(horizontal: false, vertical: true)
                    .momentRole(.rulerLabel)
            DayLaneRuler(frame: frame)
                .momentRole(.ruler)
            ForEach(Array(places.enumerated()), id: \.element.id) { index, place in
                // 这一条与上一条（或刻度）之间那一截竖线：画在窗口底上，不跟天一起预反色。
                MarkerLine(at: line).stroke(.primary, lineWidth: 1.5).accessibilityHidden(true).momentRole(.connector(index))
                leftCell(place, at: shown).momentRole(.left(index))
                MomentLane(art: index < memo.art.count ? memo.art[index] : .unknown,
                           ribbon: index < memo.ribbons.count ? memo.ribbons[index] : nil,
                           marker: line, range: range)
                    .momentRole(.lane(index))
                rightCell(place, at: shown).momentRole(.right(index))
            }
            if interactive && peek != nil {
                ReadNotch().fill(.primary).momentRole(.notch(read))
            }
            // 点与读屏都落在这一块上（刻度到最后一条天，天那一列）：点哪儿就看哪一刻；读屏里它是一个元素，值说竖线在本机几点、
            // 每个地方那一刻是白天还是夜里，上下调 = 竖线前后挪一小时（只是看，读法不变）。一块接住所有的点，不给每条天各挂一个手势与几何回调。
            if interactive {
                Color.clear
                    .contentShape(Rectangle())
                    .modifier(PeekTap(frame: frame, read: read, peek: $peek))
                    // 悬停先说点一下能干什么；读屏的提示里这一句在前，上下调整那句在后（丢不得：这一块挂着可调操作）。
                    .help(Text(verbatim: L10n.string("点一下，看那一刻各地几点", locale: core.uiLocale)))
                    .accessibilityElement(children: .ignore)
                    .accessibilityAddTraits(.isImage)
                    .accessibilityLabel(Text("当天时间轴"))
                    .accessibilityValue(Text(verbatim: spokenValue(frame: frame, shown: shown, line: line)))
                    .accessibilityHint(Text(verbatim: [L10n.string("点一下，看那一刻各地几点", locale: core.uiLocale),
                                                       L10n.string("调整可看前后一小时各地几点", locale: core.uiLocale)].joined(separator: " · ")))
                    .accessibilityAdjustableAction { direction in
                        let step: TimeInterval = direction == .increment ? 3600 : -3600
                        let target = shown.addingTimeInterval(step)
                        guard target >= frame.start, target < frame.end else { return }
                        peek = abs(target.timeIntervalSince(start)) < 1 ? nil : target
                    }
                    .accessibilitySortPriority(-1)
                    .momentRole(.accessibility)
            } else {
                Color.clear
                    .accessibilityElement(children: .ignore)
                    .accessibilityAddTraits(.isImage)
                    .accessibilityLabel(Text("当天时间轴"))
                    .accessibilityValue(Text(verbatim: spokenValue(frame: frame, shown: shown, line: line)))
                    .accessibilitySortPriority(-1)
                    .momentRole(.accessibility)
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// 某一刻在框里的位置（0…1，框外钉在边上）。
    static func fraction(of date: Date, in frame: DayLaneFrame) -> Double {
        min(max((date.timeIntervalSince1970 - frame.start.timeIntervalSince1970) / frame.length, 0), 1)
    }

    // MARK: - 两边的字

    /// 左边：衬线地名，下面一行小字「原文 · 快 8小时」（与面板行同一种说法；同一时间不写）。读屏一句念完。
    private func leftCell(_ place: Place, at date: Date) -> some View {
        let size = (AppFont.size(.body) * 1.15 * textScale).rounded()
        let note = Self.note(for: place, at: date, locale: core.uiLocale)
        return VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: place.name).font(SerifFace.font(place.name, size: size, weight: .regular, locale: core.uiLocale))
                .fixedSize(horizontal: false, vertical: true)
            if !note.isEmpty {
                Text(verbatim: note).appFont(.caption).foregroundStyle(.readableSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// 地名下面那行小字：标记在前（原文、本机），与本机差多少在后（面板行的写法，`PanelRowDetail.fullRelative`）。
    static func note(for place: Place, at date: Date, locale: Locale, home: TimeZone = .current) -> String {
        var parts = place.tags
        if let relative = PanelRowDetail.fullRelative(timeZone: place.zone, at: date, locale: locale, home: home) { parts.append(relative) }
        return parts.joined(separator: " · ")
    }

    /// 右边：那里的钟点（钟点字中号；时间段写「9:00–10:00」），与原文那天不是同一天时下面写「次日（周日）」。
    private func rightCell(_ place: Place, at date: Date) -> some View {
        let clock = Self.clock(start: date, end: peek == nil ? end : nil, in: place.zone, hourStyle: core.settings.hourStyle,
                               locale: core.uiLocale, now: core.now)
        let day = Self.dayNote(date, in: place.zone, from: dayReference, locale: core.uiLocale)
        return VStack(alignment: .trailing, spacing: 1) {
            Text(verbatim: clock).font(ClockFace.medium(core.settings, scale: textScale))
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
            if let day {
                Text(verbatim: day).appFont(.caption).foregroundStyle(.readableSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// 钟点或时间段：终点在同一天只写钟点，跨了日子连日期一起写（「23:00–10月4日 1:00」）。
    static func clock(start: Date, end: Date?, in zone: TimeZone, hourStyle: HourStyle, locale: Locale, now: Date) -> String {
        let format = ClockFormat(hourStyle: hourStyle, showSeconds: false)
        let from = TimeFormatting.string(for: start, in: zone, format: format)
        guard let end else { return from }
        let to = TimeFormatting.string(for: end, in: zone, format: format)
        let sameDay = Calendar.gregorianUTC(zone).isDate(start, inSameDayAs: end)
        return ClockText.range(from, sameDay ? to : "\(ClockText.day(end, in: zone, locale: locale, now: now)) \(to)")
    }

    /// 「次日（周日）」「前一日（周四）」：与 `reference` 那个钟的那一天比；同一天给 nil。星期是那边那一天的：只写「次日」时还要再算一遍是星期几。
    static func dayNote(_ date: Date, in zone: TimeZone, from reference: TimeZone, locale: Locale) -> String? {
        let offset = ClockText.dayOffset(of: date, in: zone, from: reference)
        guard offset != 0 else { return nil }
        return String(format: L10n.string("%1$@（%2$@）", locale: locale), locale: locale,
                      L10n.string(offset > 0 ? "次日" : "前一日", locale: locale), ClockText.weekday(date, in: zone, locale: locale))
    }

    /// 读屏念的值：竖线在本机几点（点过别处时再说原来那一刻），每个地方那一刻是白天还是夜晚。钟点由各行自己念，这里不重复。
    private func spokenValue(frame: DayLaneFrame, shown: Date, line: Double) -> String {
        let locale = core.uiLocale
        let format = ClockFormat(hourStyle: core.settings.hourStyle, showSeconds: false)
        var parts = [String(format: L10n.string("竖线在本机 %@", locale: locale), TimeFormatting.string(for: shown, in: frame.timeZone, format: format))]
        if peek != nil {
            parts.append(String(format: L10n.string("原来的时刻在本机 %@", locale: locale), TimeFormatting.string(for: start, in: frame.timeZone, format: format)))
        }
        for (index, place) in places.enumerated() {
            guard index < memo.art.count, let day = memo.art[index].isDay(at: line) else { continue }
            parts.append("\(place.name) \(L10n.string(day ? "白天" : "夜晚", locale: locale))")
        }
        return parts.joined(separator: ", ")
    }
}

/// 点时间轴上的某处（刻度或任何一条天）：看那一刻各地几点（对齐到整刻钟）；点回原来那一刻附近（6 点以内）就回去。只改看的那一刻，不改读法。
private struct PeekTap: ViewModifier {
    let frame: DayLaneFrame
    let read: Double
    @Binding var peek: Date?
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .onTapGesture { location in
                guard width > 0 else { return }
                let at = min(max(Double(location.x / width), 0), 1)
                if abs(at - read) * Double(width) <= 6 { peek = nil; return }
                let raw = frame.start.timeIntervalSince1970 + at * frame.length
                let snapped = Date(timeIntervalSince1970: (raw / 900).rounded() * 900)
                peek = min(max(snapped, frame.start), frame.end.addingTimeInterval(-60))
            }
    }
}

/// 一条天：那里的天（一行像素拉满，圆角 3），外面一道细描边（与昼夜条同一条规矩），深色外观压暗 22%（「月光纸」），
/// 「不使用颜色区分」时画昼夜边界刻度，时间段在下沿一道细轨里；竖线在这条上的那一段由它自己画（反色时与天一起预反）。
private struct MomentLane: View {
    let art: MomentLaneArt
    let ribbon: CGImage?
    let marker: Double
    let range: ClosedRange<Double>?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let increased = contrast == .increased
        let stops = art.stops.map { SkyStripState.Stop(at: $0.at, color: $0.color) }
        VStack(spacing: 1) {
            Group {
                if let ribbon {
                    Image(decorative: ribbon, scale: 1).resizable().interpolation(.high)
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .overlay { if colorScheme == .dark && !increased && ribbon != nil { Color.black.opacity(0.22) } }
            .overlay {
                if !art.marks.isEmpty {
                    BandTicks(marks: art.marks).stroke(SkyLaneForegroundStyle(stops: stops, backing: true), lineWidth: 2.5)
                    BandTicks(marks: art.marks).stroke(SkyLaneForegroundStyle(stops: stops), lineWidth: 1)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(SkyLaneForegroundStyle(stops: stops),
                                                                   lineWidth: increased ? 1 : 0.75))
            .frame(height: MomentMetrics.lane)
            if let range {
                RangeTrack(range: range).fill(DaysidePalette.day.opacity(0.9))
                    .background(Capsule().fill(.quaternary))
                    .frame(height: 3)
            }
        }
        .overlay {
            MarkerLine(at: marker).stroke(SkyLaneForegroundStyle(stops: stops, backing: true), lineWidth: 3.5)
            MarkerLine(at: marker).stroke(SkyLaneForegroundStyle(stops: stops), lineWidth: 1.5)
        }
        .modifier(SkyPreInvert())
        .accessibilityHidden(true)
    }
}

/// 竖线在一条天上的那一段（上下各出头 2 点，与昼夜条的参考线同一个画法）。找碰头时间的表也用它。
struct MarkerLine: Shape {
    let at: Double
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let x = rect.minX + CGFloat(at) * rect.width
        path.move(to: CGPoint(x: x, y: rect.minY - 2))
        path.addLine(to: CGPoint(x: x, y: rect.maxY + 2))
        return path
    }
}

/// 昼 / 曙暮 / 夜的边界刻度：日出日落整条高，晨光始昏影终半条高。找碰头时间的表也用它。
struct BandTicks: Shape {
    let marks: [MomentLaneArt.Mark]
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for mark in marks {
            let x = rect.minX + CGFloat(mark.at) * rect.width
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: mark.full ? rect.maxY : rect.midY))
        }
        return path
    }
}

/// 时间段在细轨里的那一截。
private struct RangeTrack: Shape {
    let range: ClosedRange<Double>
    func path(in rect: CGRect) -> Path {
        let x0 = rect.minX + CGFloat(range.lowerBound) * rect.width
        let x1 = max(rect.minX + CGFloat(range.upperBound) * rect.width, x0 + 2)
        return Path(roundedRect: CGRect(x: x0, y: rect.minY, width: x1 - x0, height: rect.height), cornerRadius: rect.height / 2)
    }
}

/// 点过别处时，原来那一刻在刻度下沿的小三角（与页首天色带标「此刻」的那个同一个样子）。找碰头时间的表也用它。
struct ReadNotch: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - 摆法

/// 天那一条的高、刻度那一行的高（摆法与视图共用，不隔离在主线程）。
nonisolated enum MomentMetrics {
    static let lane: CGFloat = 12
    static let ruler: CGFloat = 14
}

/// 表里每样东西是谁。
enum MomentRole: Equatable {
    case none
    case rulerLabel
    case ruler
    case connector(Int)
    case left(Int)
    case lane(Int)
    case right(Int)
    case notch(Double)
    case accessibility
}

private struct MomentRoleKey: LayoutValueKey { static let defaultValue = MomentRole.none }

extension View {
    func momentRole(_ role: MomentRole) -> some View { layoutValue(key: MomentRoleKey.self, value: role) }
}

/// 一个小 `Layout` 一次摆完（不用 `Grid`：冷启动一页多约 1 MiB，实测；不用 `GeometryReader`）。
/// 宽时三列：地名 | 钟点 | 天。地名与钟点挨着（先读到「伦敦 17:00」），天在右边铺开；地名一列最多占三成四、钟点一列最多两成六，
/// 由最宽的那一格定，天那一列拿剩下的，所以每条天左右对齐、共用顶上那一行刻度，竖线一根穿过所有的天（条与条之间那几截由 `connector` 补上）。
/// 窄到天那一列不足 140 点时上下排：每行先地名与钟点、下面一整条天，刻度也整宽，竖线各段仍在同一个 x 上。
struct MomentTableLayout: Layout {
    var columnGap: CGFloat = 12
    var rowGap: CGFloat = 6
    var minimumLane: CGFloat = 140
    /// 给了就按宽度的这两份定左右两列（不按内容）：同一页上下两张表（市场时钟的交易所与外汇时段）左右对齐、轴一样长。
    var fixedShares: (left: CGFloat, right: CGFloat)? = nil

    struct Plan {
        var stacked = false
        var width: CGFloat = 0
        var leftWidth: CGFloat = 0
        var rightWidth: CGFloat = 0
        var laneX: CGFloat = 0
        var laneWidth: CGFloat = 0
        var height: CGFloat = 0
        var frames: [Int: CGRect] = [:]
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let plan = plan(width: proposal.width ?? 560, subviews: subviews)
        return CGSize(width: plan.width, height: plan.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let plan = plan(width: bounds.width, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            let frame = plan.frames[index] ?? .zero
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }

    func plan(width: CGFloat, subviews: Subviews) -> Plan {
        var plan = Plan()
        plan.width = width
        var lefts: [Int: Int] = [:], rights: [Int: Int] = [:], lanes: [Int: Int] = [:], connectors: [Int: Int] = [:]
        var rulerLabel: Int?, ruler: Int?, notch: (Int, Double)?, access: Int?
        for (index, subview) in subviews.enumerated() {
            switch subview[MomentRoleKey.self] {
            case .left(let row): lefts[row] = index
            case .right(let row): rights[row] = index
            case .lane(let row): lanes[row] = index
            case .connector(let row): connectors[row] = index
            case .rulerLabel: rulerLabel = index
            case .ruler: ruler = index
            case .notch(let at): notch = (index, at)
            case .accessibility: access = index
            case .none: break
            }
        }
        let rows = lefts.keys.sorted()
        let ideal = { (index: Int?) -> CGFloat in index.map { subviews[$0].sizeThatFits(.unspecified).width } ?? 0 }
        let leftIdeal = max(rows.map { ideal(lefts[$0]) }.max() ?? 0, ideal(rulerLabel))
        let rightIdeal = rows.map { ideal(rights[$0]) }.max() ?? 0
        if let fixedShares {
            plan.leftWidth = floor(width * fixedShares.left)
            plan.rightWidth = floor(width * fixedShares.right)
        } else {
            plan.leftWidth = min(ceil(leftIdeal), floor(width * 0.34))
            plan.rightWidth = min(ceil(rightIdeal), floor(width * 0.26))
        }
        plan.laneWidth = width - plan.leftWidth - plan.rightWidth - 2 * columnGap
        plan.stacked = plan.laneWidth < minimumLane
        let laneHeight = { (index: Int?) -> CGFloat in
            index.map { subviews[$0].sizeThatFits(ProposedViewSize(width: plan.laneWidth, height: nil)).height } ?? MomentMetrics.lane
        }
        let height = { (index: Int?, width: CGFloat) -> CGFloat in
            index.map { subviews[$0].sizeThatFits(ProposedViewSize(width: width, height: nil)).height } ?? 0
        }

        var y: CGFloat = 0
        var rulerBottom: CGFloat = 0
        if plan.stacked {
            plan.laneX = 0
            plan.laneWidth = width
            let labelHeight = height(rulerLabel, width)
            if let rulerLabel { plan.frames[rulerLabel] = CGRect(x: 0, y: y, width: width, height: labelHeight) }
            y += labelHeight + 4
            if let ruler { plan.frames[ruler] = CGRect(x: 0, y: y, width: width, height: MomentMetrics.ruler) }
            y += MomentMetrics.ruler
            rulerBottom = y
            y += 4
            for row in rows {
                let rightWidth = min(ceil(ideal(rights[row])), floor(width * 0.45))
                let leftWidth = width - rightWidth - columnGap
                let top = max(height(lefts[row], leftWidth), height(rights[row], rightWidth))
                if let left = lefts[row] { plan.frames[left] = CGRect(x: 0, y: y, width: leftWidth, height: height(left, leftWidth)) }
                if let right = rights[row] { plan.frames[right] = CGRect(x: width - rightWidth, y: y, width: rightWidth, height: height(right, rightWidth)) }
                y += top + 3
                let lane = laneHeight(lanes[row])
                if let laneIndex = lanes[row] { plan.frames[laneIndex] = CGRect(x: 0, y: y, width: width, height: lane) }
                if let connector = connectors[row] { plan.frames[connector] = .zero }
                y += lane + rowGap + 4
            }
            y -= rowGap + 4
        } else {
            let clockX = plan.leftWidth + columnGap
            plan.laneX = clockX + plan.rightWidth + columnGap
            let labelWidth = plan.laneX - columnGap
            let labelHeight = height(rulerLabel, labelWidth)
            let rulerRow = max(labelHeight, MomentMetrics.ruler)
            if let rulerLabel { plan.frames[rulerLabel] = CGRect(x: 0, y: rulerRow - labelHeight, width: labelWidth, height: labelHeight) }
            if let ruler { plan.frames[ruler] = CGRect(x: plan.laneX, y: rulerRow - MomentMetrics.ruler, width: plan.laneWidth, height: MomentMetrics.ruler) }
            y = rulerRow
            rulerBottom = y
            y += rowGap
            var previousBottom = rulerBottom
            for row in rows {
                let lane = laneHeight(lanes[row])
                let leftHeight = height(lefts[row], plan.leftWidth)
                let rightHeight = height(rights[row], plan.rightWidth)
                let rowHeight = max(leftHeight, rightHeight, lane + 8)
                if let left = lefts[row] { plan.frames[left] = CGRect(x: 0, y: y, width: plan.leftWidth, height: leftHeight) }
                if let right = rights[row] {
                    plan.frames[right] = CGRect(x: clockX, y: y, width: plan.rightWidth, height: rightHeight)
                }
                let laneTop = y + (rowHeight - lane) / 2
                if let laneIndex = lanes[row] { plan.frames[laneIndex] = CGRect(x: plan.laneX, y: laneTop, width: plan.laneWidth, height: lane) }
                if let connector = connectors[row] {
                    // 这一条与上一条（或刻度）之间那一截竖线：与天同宽，竖线自己按位置画在里面（`MarkerLine`）。
                    plan.frames[connector] = CGRect(x: plan.laneX, y: previousBottom, width: plan.laneWidth, height: max(0, laneTop - previousBottom))
                }
                previousBottom = laneTop + lane
                y += rowHeight + rowGap
            }
            y -= rowGap
        }
        plan.height = max(y, rulerBottom)
        if let (index, at) = notch {
            plan.frames[index] = CGRect(x: plan.laneX + CGFloat(at) * plan.laneWidth - 3.5, y: rulerBottom - 4, width: 7, height: 4)
        }
        if let access {
            // 宽时：天那一列，从刻度顶到最后一条天的底。上下排时天与字交错，只接刻度那一行（点字不该挪竖线）。
            let firstLane = rows.first.flatMap { lanes[$0] }.flatMap { plan.frames[$0] }
            let lastLane = rows.last.flatMap { lanes[$0] }.flatMap { plan.frames[$0] }
            let rulerFrame = ruler.flatMap { plan.frames[$0] }
            let top = rulerFrame?.minY ?? firstLane?.minY ?? 0
            let bottom = plan.stacked ? (rulerFrame?.maxY ?? top + 1) : (lastLane?.maxY ?? top + 1)
            plan.frames[access] = CGRect(x: plan.laneX, y: top, width: plan.laneWidth, height: max(1, bottom - top))
        }
        return plan
    }
}
