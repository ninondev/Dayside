// SPDX-License-Identifier: GPL-3.0-only
//
//  MeetingTable.swift
//  TahoeTime
//
//  找碰头时间的共同时间轴：与换算页同一张表（`MomentTableLayout`：顶上一行本机刻度，每人一行「名字 | 钟点 | 那里的天」，
//  天按本机当天对齐、上下对齐），多两样东西：每条天下面一道细轨是那个人的工作时段（蓝），会议是两道竖线夹住的一段，
//  穿过所有人的天。会落在谁的工作时段外，谁的钟点前面一个小月亮；落在谁的夜里，那一段天就是墨色的，一眼看得见。
//  点任何一条天或刻度：试那个钟点（对齐整刻钟），各人的钟点与月亮跟着变，原来那一场在刻度下沿留一个小三角。
//
//  天由 Rust `sky.lanes` 一次给齐、画成一行像素（与换算页同一个 `MomentLaneMemo`）；工作时段由 `availability.intervals`、
//  各人处境由 `planner.fit` 给，都只在框、参与者或那一场变了时算，点一下、走一分钟、窗口改大小都不再去 Rust。工具窗关了它就不在。
//

import SwiftUI

/// 每人工作时段的区间（本机当天前后各多一天，够判断跨午夜的会）与那一场各人的处境；跟着视图走（`@State`）。
@MainActor
final class MeetingRailMemo {
    private struct Key: Equatable {
        let start: Double
        let length: Double
        let participants: [OverlapPlanner.Participant]
    }
    private struct FitKey: Equatable {
        let rails: Key
        let start: Double
        let duration: Int
    }
    private var key: Key?
    private var fitKey: FitKey?
    private(set) var intervals: [[DateInterval]] = []
    /// 框里的工作时段（0…1）。
    private(set) var spans: [[ClosedRange<Double>]] = []
    private(set) var fits: [OverlapPlanner.Fit] = []

    func update(frame: DayLaneFrame, participants: [OverlapPlanner.Participant]) {
        let next = Key(start: frame.start.timeIntervalSince1970, length: frame.length, participants: participants)
        guard next != key else { return }
        key = next
        fitKey = nil
        let from = frame.start.addingTimeInterval(-86_400), to = frame.end.addingTimeInterval(86_400)
        intervals = participants.map { OverlapPlanner.availabilityIntervals(for: $0, coveringFrom: from, to: to) }
        spans = intervals.map { list in
            list.compactMap { interval in
                let a = MomentTable.fraction(of: interval.start, in: frame), b = MomentTable.fraction(of: interval.end, in: frame)
                return b > a ? a...b : nil
            }
        }
    }

    /// 那一场（或试的那个钟点）各人的处境：同一场只算一次。
    func fits(start: Date, durationMinutes: Int, participants: [OverlapPlanner.Participant]) -> [OverlapPlanner.Fit] {
        guard let key else { return [] }
        let next = FitKey(rails: key, start: start.timeIntervalSince1970, duration: durationMinutes)
        if next != fitKey {
            fitKey = next
            fits = OverlapPlanner.fits(intervals: intervals, participants: participants, start: start, durationMinutes: durationMinutes).map(\.fit)
        }
        return fits
    }
}

struct MeetingTable: View {
    struct Row: Identifiable, Equatable {
        let id: String
        let participant: OverlapPlanner.Participant
        let name: String
        /// 「9:00–18:00」：那个人自己的钟面上的工作时段。
        let hours: String
        /// 时段后面那一句：「本机」或「重叠 1小时」。
        let note: String?
        /// 点时段怎么改：地点在旁边弹出工作时段，人物打开人物表单（由页面接住）。
        enum Editing: Equatable { case none, popover, sheet }
        let editing: Editing
    }

    let rows: [Row]
    /// 这一场的开始（还没在表上试别的钟点时，竖线就在这里）。
    let start: Date
    let durationMinutes: Int
    /// 同一个本机钟点也行的那几天（两天以上时，刻度左边那一格是「哪一天」菜单）。
    var days: [Date] = []
    var onDay: (Date) -> Void = { _ in }
    @Binding var peek: Date?
    /// 点时段改工作时段：地点的弹出框内容，与人物的编辑表单（页面接住）。
    var editor: (Row) -> AnyView = { _ in AnyView(EmptyView()) }
    var onEditSheet: (Row) -> Void = { _ in }

    @Environment(TimeCore.self) private var core
    @Environment(\.textScale) private var textScale
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @State private var skies = MomentLaneMemo()
    @State private var rails = MeetingRailMemo()
    @State private var editing: String?

    private var duration: TimeInterval { TimeInterval(max(1, durationMinutes) * 60) }

    var body: some View {
        let frame = DayLaneFrame.homeDay(containing: start)
        let participants = rows.map(\.participant)
        let _ = skies.update(frame: frame, coordinates: participants.map(\.coordinate), marks: differentiateWithoutColor)
        let _ = rails.update(frame: frame, participants: participants)
        let shown = peek ?? start
        let fits = rails.fits(start: shown, durationMinutes: durationMinutes, participants: participants)
        let from = MomentTable.fraction(of: shown, in: frame)
        let to = MomentTable.fraction(of: shown.addingTimeInterval(duration), in: frame)
        let read = MomentTable.fraction(of: start, in: frame)
        MomentTableLayout {
            VStack(alignment: .leading, spacing: 2) {
                LocalTimelineLabel()
                dayLabel(frame: frame)
            }
            .momentRole(.rulerLabel)
            DayLaneRuler(frame: frame)
                .momentRole(.ruler)
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                // 这一条与上一条（或刻度）之间那一截：两道竖线画在窗口底上，不跟天一起预反色。
                // 两道线之间在窗口底上铺一层极淡的底，几截连起来读成一根柱子：这一场穿过每个人的一天。
                ColumnBand(from: from, to: to).fill(.primary.opacity(0.07))
                    .overlay(ColumnLines(from: from, to: to).stroke(.primary, lineWidth: 1.5))
                    .accessibilityHidden(true).momentRole(.connector(index))
                leftCell(row).momentRole(.left(index))
                MeetingLane(art: index < skies.art.count ? skies.art[index] : .unknown,
                            ribbon: index < skies.ribbons.count ? skies.ribbons[index] : nil,
                            hours: index < rails.spans.count ? rails.spans[index] : [],
                            from: from, to: to)
                    .momentRole(.lane(index))
                rightCell(row, at: shown, fit: index < fits.count ? fits[index] : .inside).momentRole(.right(index))
            }
            if peek != nil {
                ReadNotch().fill(.primary).momentRole(.notch(read))
            }
            // 点与读屏都落在这一块上（刻度到最后一条天，天那一列）：点哪儿就试哪个钟点；读屏里它是一个元素，
            // 值说这一场在本机几点、各人那一刻是白天还是夜里，上下调 = 前后挪一小时（只是看，候选不变）。
            Color.clear
                .contentShape(Rectangle())
                .modifier(MeetingPeekTap(frame: frame, read: read, duration: duration, peek: $peek))
                .help(Text("点一下，试这个钟点"))
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isImage)
                .accessibilityLabel(Text("当天时间轴"))
                .accessibilityValue(Text(verbatim: spokenValue(frame: frame, shown: shown, from: from)))
                .accessibilityHint(Text(verbatim: [L10n.string("点一下，试这个钟点", locale: core.uiLocale), L10n.string("调整可看前后一小时各地几点", locale: core.uiLocale)].joined(separator: ". ")))
                .accessibilityAdjustableAction { direction in
                    let target = shown.addingTimeInterval(direction == .increment ? 3600 : -3600)
                    guard target >= frame.start, target < frame.end else { return }
                    peek = abs(target.timeIntervalSince(start)) < 1 ? nil : target
                }
                .accessibilitySortPriority(-1)
                .momentRole(.accessibility)
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - 刻度左边：这一天（几天都行时是「哪一天」菜单）

    @ViewBuilder
    private func dayLabel(frame: DayLaneFrame) -> some View {
        let label = ClockText.day(start, in: frame.timeZone, locale: core.uiLocale, now: core.now, weekday: true)
        if days.count > 1 {
            Menu {
                ForEach(days, id: \.self) { day in
                    let title = ClockText.day(day, in: frame.timeZone, locale: core.uiLocale, now: core.now, weekday: true)
                    Button { onDay(day) } label: {
                        if Calendar.gregorianUTC(frame.timeZone).isDate(day, inSameDayAs: start) {
                            Label(title, systemImage: "checkmark")
                        } else {
                            Text(verbatim: title)
                        }
                    }
                }
            } label: {
                PlannerMenuLabel(text: label, style: .caption)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("哪一天"))
                    .accessibilityValue(Text(verbatim: label))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        } else {
            Text(verbatim: label)
                .appFont(.caption).foregroundStyle(.readableSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 两边的字

    /// 左边：衬线名字，下面一行小字「9:00–18:00 · 重叠 1小时」；时段能点开改。
    private func leftCell(_ row: Row) -> some View {
        let size = (AppFont.size(.body) * 1.15 * textScale).rounded()
        return VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: row.name).font(SerifFace.font(row.name, size: size, weight: .regular, locale: core.uiLocale))
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if row.editing != .none {
                    Button { if row.editing == .popover { editing = row.id } else { onEditSheet(row) } } label: {
                        Text(verbatim: row.hours).monospacedDigit()
                            .underline(pattern: .dot, color: .secondary)
                            .frame(minHeight: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(Text("点按修改"))
                    .accessibilityLabel(Text("工作时段 \(row.hours)"))
                    .accessibilityHint(Text("点按修改"))
                    .popover(isPresented: Binding(get: { editing == row.id }, set: { if !$0, editing == row.id { editing = nil } }),
                             arrowEdge: .trailing) {
                        editor(row)
                    }
                } else {
                    Text(verbatim: row.hours).monospacedDigit()
                }
                if let note = row.note {
                    Text(verbatim: "·").accessibilityHidden(true)
                    Text(verbatim: note)
                }
            }
            .appFont(.caption).foregroundStyle(.readableSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 右边：那个人那一刻的钟点（钟点字中号）；会落在工作时段外时前面一个小月亮；与本机不是同一天时下面写「次日（周二）」。
    private func rightCell(_ row: Row, at date: Date, fit: OverlapPlanner.Fit) -> some View {
        let zone = row.participant.timeZone
        let clock = TimeFormatting.string(for: date, in: zone, format: ClockFormat(hourStyle: core.settings.hourStyle, showSeconds: false))
        let day = MomentTable.dayNote(date, in: zone, from: .current, locale: core.uiLocale)
        let outside: Bool = { if case .inside = fit { return false } else { return true } }()
        let spoken = [clock, day, outside ? L10n.string(Self.isOff(fit) ? "当天休息" : "在工作时间外", locale: core.uiLocale) : nil]
            .compactMap { $0 }.joined(separator: ", ")
        return VStack(alignment: .trailing, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if outside {
                    Image(systemName: "moon.zzz").foregroundStyle(.orange).imageScale(.small)
                }
                Text(verbatim: clock).font(ClockFace.medium(core.settings, scale: textScale))
            }
            if let day {
                Text(verbatim: day).appFont(.caption).foregroundStyle(.readableSecondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: spoken))
        .accessibilityAddTraits(.isStaticText)
    }

    static func isOff(_ fit: OverlapPlanner.Fit) -> Bool {
        if case .unavailable = fit { return true }
        return false
    }

    /// 读屏念的值：这一场在本机几点到几点（试过别的钟点时再说原来那一场），每个人那一刻是白天还是夜里。
    private func spokenValue(frame: DayLaneFrame, shown: Date, from: Double) -> String {
        let locale = core.uiLocale
        let format = ClockFormat(hourStyle: core.settings.hourStyle, showSeconds: false)
        let range = ClockText.range(TimeFormatting.string(for: shown, in: frame.timeZone, format: format),
                                    TimeFormatting.string(for: shown.addingTimeInterval(duration), in: frame.timeZone, format: format))
        var parts = [String(format: L10n.string("会议在本机 %@", locale: locale), range)]
        if peek != nil {
            parts.append(String(format: L10n.string("原来的时刻在本机 %@", locale: locale), TimeFormatting.string(for: start, in: frame.timeZone, format: format)))
        }
        for (index, row) in rows.enumerated() {
            guard index < skies.art.count, let day = skies.art[index].isDay(at: from) else { continue }
            parts.append("\(row.name) \(L10n.string(day ? "白天" : "夜晚", locale: locale))")
        }
        return parts.joined(separator: ", ")
    }
}

/// 刻度左边那一格与「其他写法」同一种菜单标签：文字加 9 点小箭头，整块一个读屏元素，命中区 24 点高。
struct PlannerMenuLabel: View {
    let text: String
    /// nil = 系统按钮的字（不跟「文字大小」走）：挨着系统按钮放的那一个，与按钮一样大。
    var style: Font.TextStyle? = .title3
    var serif = false
    @Environment(TimeCore.self) private var core
    @Environment(\.textScale) private var textScale

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if serif {
                Text(verbatim: text).font(SerifFace.font(text, size: (AppFont.size(.title2) * textScale).rounded(), weight: .medium, locale: core.uiLocale))
                    .fixedSize(horizontal: false, vertical: true)
            } else if let style {
                Text(verbatim: text).appFont(style)
                    .foregroundStyle(style == .caption ? AnyShapeStyle(.readableSecondary) : AnyShapeStyle(.primary))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(verbatim: text).fixedSize(horizontal: false, vertical: true)
            }
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.readableSecondary)
        }
        .frame(minHeight: 24)
        .contentShape(Rectangle())
    }
}

/// 点时间轴上的某处：试那个钟点（对齐整刻钟）开这一场；点回原来那一场附近（6 点以内）就回去。
private struct MeetingPeekTap: ViewModifier {
    let frame: DayLaneFrame
    let read: Double
    let duration: TimeInterval
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
                peek = min(max(snapped, frame.start), frame.end.addingTimeInterval(-900))
            }
    }
}

/// 一个人那一行的天：那里的天（一行像素拉满，圆角 3，细描边，深色压暗 22%，「不使用颜色区分」时画昼夜刻度），
/// 下面一道细轨是这个人的工作时段（蓝）；会议是两道竖线，穿过天与细轨（反色时与天一起预反）。
private struct MeetingLane: View {
    let art: MomentLaneArt
    let ribbon: CGImage?
    let hours: [ClosedRange<Double>]
    let from: Double
    let to: Double
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let increased = contrast == .increased
        let stops = art.stops.map { SkyStripState.Stop(at: $0.at, color: $0.color) }
        VStack(spacing: 2) {
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
            // 工作时段用不透明的昼的蓝：叠在灰轨上还有约 3.2:1（90% 时只有约 2.9:1，按色值算），白底上约 4:1。
            RailSpans(spans: hours).fill(DaysidePalette.day)
                .background(Capsule().fill(.quaternary))
                .frame(height: MeetingMetrics.rail)
        }
        .overlay {
            ColumnLines(from: from, to: to).stroke(SkyLaneForegroundStyle(stops: stops, backing: true), lineWidth: 3.5)
            ColumnLines(from: from, to: to).stroke(SkyLaneForegroundStyle(stops: stops), lineWidth: 1.5)
        }
        .modifier(SkyPreInvert())
        .accessibilityHidden(true)
    }
}

nonisolated enum MeetingMetrics {
    /// 工作时段那道细轨的高（天 12 点、空 2 点、轨 4 点）。
    static let rail: CGFloat = 4
}

/// 会议的起止两道竖线（上下各出头 2 点，与参考线同一个画法）；短会两道挨在一起。
struct ColumnLines: Shape {
    let from: Double
    let to: Double
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for at in [from, to] {
            let x = rect.minX + CGFloat(at) * rect.width
            path.move(to: CGPoint(x: x, y: rect.minY - 2))
            path.addLine(to: CGPoint(x: x, y: rect.maxY + 2))
        }
        return path
    }
}

/// 会议那一段在窗口底上的极淡的底（只铺在条与条之间，不盖天色）。
struct ColumnBand: Shape {
    let from: Double
    let to: Double
    func path(in rect: CGRect) -> Path {
        let x0 = rect.minX + CGFloat(from) * rect.width
        let x1 = max(rect.minX + CGFloat(to) * rect.width, x0)
        return Path(CGRect(x: x0, y: rect.minY, width: x1 - x0, height: rect.height))
    }
}

/// 细轨里的工作时段：一条路径画完所有段（不为每段各起一个视图）。
private struct RailSpans: Shape {
    let spans: [ClosedRange<Double>]
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for span in spans {
            let x0 = rect.minX + CGFloat(span.lowerBound) * rect.width
            let x1 = max(rect.minX + CGFloat(span.upperBound) * rect.width, x0 + 2)
            path.addRoundedRect(in: CGRect(x: x0, y: rect.minY, width: x1 - x0, height: rect.height),
                                cornerSize: CGSize(width: rect.height / 2, height: rect.height / 2))
        }
        return path
    }
}

/// 表下面一行图例：只列轴上真有的东西。夜 / 曙暮 / 白天三枚色样取昼夜条真实涂的颜色，每枚一道与天同样的细描边
/// （浅色窗口里白天那一枚靠它才看得见，毛病表 23）；工作时段一小段蓝轨；会落在工作时段外的人前面那个小月亮。
struct MeetingLegend: View {
    /// 有没有哪一行有天色（有坐标）；没有就不列夜 / 曙暮 / 白天。
    var sky = true
    /// 表上有没有人在工作时段外；没有就不列小月亮。
    var outside = true
    /// 那一道蓝轨叫什么：找碰头时间是各人的工作时段，市场时钟是交易时段。
    var rail: LocalizedStringKey = "工作时段"
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ChipFlowLayout(spacing: 12, lineSpacing: 4) {
            if sky {
                item(Self.nightSample, "夜")
                item(Self.twilightSample, "曙暮")
                item(Self.daySample, "白天")
            }
            HStack(spacing: 4) {
                Capsule().fill(DaysidePalette.day).frame(width: 12, height: MeetingMetrics.rail)
                Text(rail)
            }
            if outside {
                HStack(spacing: 4) {
                    Image(systemName: "moon.zzz").foregroundStyle(.orange).imageScale(.small).accessibilityHidden(true)
                    Text("在工作时间外")
                }
            }
        }
        .appFont(.caption2).foregroundStyle(.readableSecondary)
        .accessibilityElement(children: .combine)
    }

    private func item(_ sample: (color: Color, luminance: Double), _ label: LocalizedStringKey) -> some View {
        HStack(spacing: 4) {
            SkyLegendSwatch(color: sample.color, luminance: sample.luminance)
            Text(label)
        }
    }

    /// 色样的出处：赤道上 2026-03-20 的某一段天（Rust `sky.lane`，与昼夜条同一种颜色），取段中点那一枚。
    private static func skyPhaseSample(_ start: Double, _ end: Double) -> (color: Color, luminance: Double) {
        struct Input: Encodable { let start: Double; let end: Double; let latitude: Double; let longitude: Double; let step: Double }
        struct Output: Decodable { let stops: [SceneCommand.Stop] }
        guard let output = try? RustCore.attempt("sky.lane", Input(start: start, end: end, latitude: 0, longitude: 0, step: 30), as: Output.self)
        else { return (LightPalette.paper, LightPalette.paperLuminance) }
        let sorted = output.stops.sorted { $0.at < $1.at }
        guard !sorted.isEmpty else { return (LightPalette.paper, LightPalette.paperLuminance) }
        let hex = sorted[sorted.count / 2].color
        return (LightPalette.color(hex), LightPalette.luminance(hex))
    }

    // 三段各一小时：00:00 深夜、05:20–06:20 日出前后的晨昏、11:00 正午（2026-03-20 赤道，0° 经线）。
    static let nightSample = skyPhaseSample(1_773_964_800, 1_773_968_400)
    static let twilightSample = skyPhaseSample(1_773_984_000, 1_773_987_600)
    static let daySample = skyPhaseSample(1_774_004_400, 1_774_008_000)
}

/// 真正的天色图例色样：边线是色样自身的墨或纸，不跟窗口的主次文字色。
struct SkyLegendSwatch: View {
    let color: Color
    let luminance: Double
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        RoundedRectangle(cornerRadius: 2).fill(color)
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(SkyTextRole.laneGlyph.foreground(on: luminance),
                                                                   lineWidth: contrast == .increased ? 1 : 0.75))
            .frame(width: 10, height: 8)
            .modifier(SkyPreInvert())
    }
}
