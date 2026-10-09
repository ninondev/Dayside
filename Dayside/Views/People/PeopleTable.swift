// SPDX-License-Identifier: GPL-3.0-only
//
//  PeopleTable.swift
//  Dayside
//
//  人物页的那张表：一个钟是一个人，每个人一条自己的天。与换算页、找碰头时间同一张表（`MomentTableLayout`：顶上一行本机刻度，
//  每行「名字 | 钟点 | 那里的天」，天按本机当天对齐、上下对齐），第一行是这台 Mac 的所在地与你的工作时段（点了改），其余每人一行。
//  天下面一道细轨是那个人的工作时段（蓝，与找碰头时间同一种：一种颜色只有一个意思），看的那一刻是一根竖线穿过所有的天，
//  你的那道轨与他的那道轨上下一比，就是「重叠几小时」「她下班 = 你的几点」。名字下面一行只说一件事：那一刻他的状态
//  （图标加字，不靠颜色；能找他时图标是绿勾）。钟点下面写「次日 / 前一日」，与面板行同一个位置、同一种说法。
//  点名字或钟点选中那个人（表下面写他的细节与动作），点天或刻度，整个 App 跳到那一刻（页首天色带给「回到现在」）。
//
//  天由 Rust `sky.lanes` 一次给齐、画成一行像素（与换算页同一个 `MomentLaneMemo`），工作时段由 `availability.intervals` 给
//  （与找碰头时间同一个 `MeetingRailMemo`），都只在框或人变了时算；走一分钟、点一下、窗口改大小都不再去 Rust。工具窗关了它就不在。
//

import SwiftUI

/// 那一刻一个人的状态，只说一件事（此前「工作时段外 · 在休息时段」说两遍）：不在醒着时段（多半在睡）压过休息日与下班；
/// 休息日那天的细轨本来就是空的，图上看得见。图标与字一起说，能找他时图标是绿勾，其余一律可读次要色。
enum PeopleStatus: Equatable {
    case working, awake, outsideHours, resting, dayOff, vacation, unknown

    init(_ status: PersonCallStatus) {
        switch status {
        case .working: self = .working
        case .awake: self = .awake
        case .resting: self = .resting
        case .outsideHours(let resting): self = resting ? .resting : .outsideHours
        case .dayOff(let resting): self = resting ? .resting : .dayOff
        case .vacation: self = .vacation
        case .unknown: self = .unknown
        }
    }

    var key: String {
        switch self {
        case .working: "上班中"
        case .awake: "在醒着时段"
        case .outsideHours: "工作时段外"
        case .resting: "在休息时段"
        case .dayOff: "休息日"
        case .vacation: "休假中"
        case .unknown: "作息未知"
        }
    }

    var symbol: String {
        switch self {
        case .working, .awake: "checkmark.circle.fill"
        case .outsideHours: "moon.zzz"
        case .resting: "bed.double"
        case .dayOff: "cup.and.saucer"
        case .vacation: "beach.umbrella"
        case .unknown: "questionmark.circle"
        }
    }

    /// 现在能找他（上班中、在醒着时段）：图标用在班的绿（只上图标）。
    var reachable: Bool { self == .working || self == .awake }
}

struct PeopleTable: View {
    struct Row: Identifiable, Equatable {
        /// 这台 Mac 的那一行，或一个人。
        enum Kind: Equatable { case here, person(UUID) }
        let kind: Kind
        let participant: OverlapPlanner.Participant
        let name: String
        /// 人：那一刻的状态。本机那一行没有（写工作时段）。
        let status: PeopleStatus?
        /// 本机那一行名字下面的工作时段「9:00–18:00」。
        let hours: String?
        /// 原始工作状态供细节复用，不受联系基准影响。
        var workStatus: PeopleWorkStatus? = nil
        /// 存档里的时区读不出（坏数据）：钟点那一格写「时区不可用」，不拿 GMT 冒充。
        var zoneKnown = true

        var id: String {
            switch kind {
            case .here: "here"
            case .person(let id): id.uuidString
            }
        }
        var personID: UUID? { if case .person(let id) = kind { id } else { nil } }
    }

    let rows: [Row]
    @Binding var selection: UUID?
    /// 本机那一行的工作时段点开的编辑器（页面给）。
    var hereEditor: () -> AnyView = { AnyView(EmptyView()) }
    var onEdit: (UUID) -> Void = { _ in }
    var onRemind: (UUID) -> Void = { _ in }
    var onRemove: (UUID) -> Void = { _ in }

    @Environment(TimeCore.self) private var core
    @Environment(AppModel.self) private var model
    @Environment(\.textScale) private var textScale
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @State private var skies = MomentLaneMemo()
    @State private var rails = MeetingRailMemo()
    @State private var editingHere = false

    var body: some View {
        let shown = core.referenceDate
        let frame = DayLaneFrame.homeDay(containing: shown)
        let participants = rows.map(\.participant)
        let _ = skies.update(frame: frame, coordinates: participants.map(\.coordinate), marks: differentiateWithoutColor)
        let _ = rails.update(frame: frame, participants: participants)
        let line = MomentTable.fraction(of: shown, in: frame)
        // 拖过时间而此刻还在这一天里：刻度下沿一个小三角标着此刻（与页首天色带标「此刻」的那个同一个样子）。
        let nowMark: Double? = core.isScrubbing && core.now >= frame.start && core.now < frame.end ? MomentTable.fraction(of: core.now, in: frame) : nil
        MomentTableLayout(rowGap: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: ClockText.day(shown, in: frame.timeZone, locale: core.uiLocale, now: core.now, weekday: true))
                    .appFont(.caption).foregroundStyle(.readableSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                LocalTimelineLabel()
            }
                .momentRole(.rulerLabel)
            DayLaneRuler(frame: frame)
                .momentRole(.ruler)
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                // 这一条与上一条（或刻度）之间那一截竖线：画在窗口底上，不跟天一起预反色。
                MarkerLine(at: line).stroke(.primary, lineWidth: 1.5).accessibilityHidden(true).momentRole(.connector(index))
                leftCell(row).momentRole(.left(index))
                PersonLane(art: index < skies.art.count ? skies.art[index] : .unknown,
                           ribbon: index < skies.ribbons.count ? skies.ribbons[index] : nil,
                           hours: index < rails.spans.count ? rails.spans[index] : [], marker: line)
                    .momentRole(.lane(index))
                rightCell(row, at: shown).momentRole(.right(index))
            }
            if let nowMark {
                ReadNotch().fill(.primary).momentRole(.notch(nowMark))
            }
            // 点与读屏都落在这一块上（刻度到最后一条天，天那一列）：点哪儿整个 App 就跳到哪一刻（对齐整刻钟），点回此刻附近就回到现在；
            // 读屏里它是一个可调的图像元素，值说竖线在本机几点、每个人那一刻是白天还是夜里，上下调 = 前后一小时。
            Color.clear
                .contentShape(Rectangle())
                .modifier(PeopleJumpTap(frame: frame, now: nowMark))
                .help(Text("点一下跳到那一刻"))
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isImage)
                .accessibilityLabel(Text("当天时间轴"))
                .accessibilityValue(Text(verbatim: spokenValue(frame: frame, shown: shown, line: line)))
                .accessibilityHint(Text(verbatim: [L10n.string("点一下跳到那一刻", locale: core.uiLocale),
                                                  L10n.string("调整可看前后一小时各地几点", locale: core.uiLocale)].joined(separator: ", ")))
                .accessibilityAdjustableAction { direction in
                    let target = shown.addingTimeInterval(direction == .increment ? 3600 : -3600)
                    if abs(target.timeIntervalSince(core.now)) < 60 { model.resetToNow() } else { model.jump(to: target, animated: false) }
                }
                .accessibilitySortPriority(-1)
                .momentRole(.accessibility)
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - 左边：名字与那一刻的状态（本机那一行是工作时段）

    @ViewBuilder
    private func leftCell(_ row: Row) -> some View {
        let size = (AppFont.size(.body) * 1.15 * textScale).rounded()
        let selected = row.personID != nil && row.personID == selection
        let content = HStack(alignment: .top, spacing: 7) {
            // 选中的那个人左边一道竖线（与找碰头时间的候选同一个样子）；本机那一行也留出这一格，名字才对得齐。
            Capsule().fill(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.clear)).frame(width: 2.5)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: row.name).font(SerifFace.font(row.name, size: size, weight: .regular, locale: core.uiLocale))
                    .fixedSize(horizontal: false, vertical: true)
                if let status = row.status {
                    Label {
                        Text(LocalizedStringKey(status.key))
                    } icon: {
                        Image(systemName: status.symbol)
                            .foregroundStyle(status.reachable ? AnyShapeStyle(.green) : AnyShapeStyle(.readableSecondary))
                    }
                    .appFont(.caption).foregroundStyle(.readableSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                } else if let hours = row.hours {
                    hereHours(hours)
                }
            }
        }
        if let id = row.personID {
            content
                .contentShape(Rectangle())
                .onTapGesture { selection = id }
                .contextMenu { personMenu(id) }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                .accessibilityAction { selection = id }
                .accessibilityActions { personMenu(id) }
        } else {
            content
        }
    }

    /// 本机那一行名字下面：「9:00–18:00 · 本机」，时段带点状下划线，点了改（与找碰头时间同一个做法与同一个设置）。
    private func hereHours(_ hours: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Button { editingHere = true } label: {
                Text(verbatim: hours).monospacedDigit()
                    .underline(pattern: .dot, color: .secondary)
                    .frame(minHeight: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text("点按修改"))
            .accessibilityLabel(Text("工作时段 \(hours)"))
            .accessibilityHint(Text("点按修改"))
            .popover(isPresented: $editingHere, arrowEdge: .trailing) { hereEditor() }
            Text(verbatim: "·").accessibilityHidden(true)
            Text("本机")
        }
        .appFont(.caption).foregroundStyle(.readableSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func personMenu(_ id: UUID) -> some View {
        Button("编辑") { onEdit(id) }
        Button("对方上班时提醒我") { onRemind(id) }
        Button("移除人物") { onRemove(id) }
    }

    // MARK: - 右边：那一刻他那里几点，跨日时下面写「次日」

    @ViewBuilder
    private func rightCell(_ row: Row, at date: Date) -> some View {
        let zone = row.participant.timeZone
        let clock = TimeFormatting.string(for: date, in: zone, format: ClockFormat(hourStyle: core.settings.hourStyle, showSeconds: false))
        let offset = ClockText.dayOffset(of: date, in: zone, from: .current)
        let day: String? = offset == 0 ? nil : L10n.string(offset > 0 ? "次日" : "前一日", locale: core.uiLocale)
        let content = VStack(alignment: .trailing, spacing: 1) {
            if row.zoneKnown {
                Text(verbatim: clock).font(ClockFace.medium(core.settings, scale: textScale))
                    .contentTransition(.numericText())
                if let day {
                    Text(verbatim: day).appFont(.caption).foregroundStyle(.readableSecondary)
                }
            } else {
                Text("时区不可用").appFont(.caption).foregroundStyle(.readableSecondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.zoneKnown ? Text(verbatim: [clock, day].compactMap { $0 }.joined(separator: ", ")) : Text("时区不可用"))
        .accessibilityAddTraits(.isStaticText)
        if let id = row.personID {
            content.contentShape(Rectangle()).onTapGesture { selection = id }.contextMenu { personMenu(id) }
        } else {
            content
        }
    }

    /// 读屏念的值：竖线在本机几点，每个人那一刻是白天还是夜里。钟点与状态由各行自己念，这里不重复。
    private func spokenValue(frame: DayLaneFrame, shown: Date, line: Double) -> String {
        let locale = core.uiLocale
        let format = ClockFormat(hourStyle: core.settings.hourStyle, showSeconds: false)
        var parts = [String(format: L10n.string("竖线在本机 %@", locale: locale), TimeFormatting.string(for: shown, in: frame.timeZone, format: format))]
        for (index, row) in rows.enumerated() {
            guard index < skies.art.count, let day = skies.art[index].isDay(at: line) else { continue }
            parts.append("\(row.name) \(L10n.string(day ? "白天" : "夜晚", locale: locale))")
        }
        return parts.joined(separator: ", ")
    }
}

/// 点时间轴上的某处：整个 App 跳到那一刻（对齐整刻钟，带跳转动画）；点回此刻附近（6 点以内）就回到现在。
private struct PeopleJumpTap: ViewModifier {
    let frame: DayLaneFrame
    let now: Double?
    @Environment(AppModel.self) private var model
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .onTapGesture { location in
                guard width > 0 else { return }
                let at = min(max(Double(location.x / width), 0), 1)
                if let now, abs(at - now) * Double(width) <= 6 { model.resetToNow(); return }
                let raw = frame.start.timeIntervalSince1970 + at * frame.length
                let snapped = Date(timeIntervalSince1970: (raw / 900).rounded() * 900)
                model.jump(to: min(max(snapped, frame.start), frame.end.addingTimeInterval(-900)), animated: true)
            }
    }
}

/// 一个人那一行的天：那里的天（一行像素拉满，圆角 3，细描边，深色压暗 22%，「不使用颜色区分」时画昼夜刻度），
/// 下面一道细轨是这个人的工作时段（蓝）；看的那一刻一根竖线穿过天与细轨（反色时与天一起预反）。
private struct PersonLane: View {
    let art: MomentLaneArt
    let ribbon: CGImage?
    let hours: [ClosedRange<Double>]
    let marker: Double
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let increased = contrast == .increased
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
                    BandTicks(marks: art.marks).stroke(.background, lineWidth: 2.5)
                    BandTicks(marks: art.marks).stroke(.primary, lineWidth: 1)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(increased ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary.opacity(0.9)),
                                                                   lineWidth: increased ? 1 : 0.75))
            .frame(height: MomentMetrics.lane)
            // 工作时段用不透明的昼的蓝（与找碰头时间同一种：叠在灰轨上约 3.2:1，白底上约 4:1）。
            WorkRail(spans: hours).fill(DaysidePalette.day)
                .background(Capsule().fill(.quaternary))
                .frame(height: MeetingMetrics.rail)
        }
        .overlay {
            MarkerLine(at: marker).stroke(.background, lineWidth: 3.5)
            MarkerLine(at: marker).stroke(.primary, lineWidth: 1.5)
        }
        .modifier(SkyPreInvert())
        .accessibilityHidden(true)
    }
}

/// 细轨里的工作时段：一条路径画完所有段（不为每段各起一个视图）。
private struct WorkRail: Shape {
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
