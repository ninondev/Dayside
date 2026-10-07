// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

struct TravelNightsView: View {
    @Environment(TimeCore.self) private var core
    @Environment(\.textScale) private var textScale
    let trip: TravelTrip
    let nights: TravelNights
    let art: [[TravelNightsMemo.Art]]
    @Binding var selected: Int
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TravelNightTableLayout {
                ForEach(Array(nights.lanes.enumerated()), id: \.offset) { index, lane in
                    if lane.kind == "prep" && index == 0 {
                        group(origin: true).travelRole(.group(index))
                        TravelNightRuler().travelRole(.ruler(index))
                    }
                    if lane.kind == "after", index == 0 || nights.lanes[index - 1].kind != "after" {
                        group(origin: false).travelRole(.group(index))
                        TravelNightRuler().travelRole(.ruler(index))
                    }
                    let words = TravelNightWords(trip: trip, lane: lane, core: core)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: words.dateText).appFont(.callout).fixedSize(horizontal: false, vertical: true)
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            if !words.label.isEmpty { Text(verbatim: words.label).appFont(.caption).foregroundStyle(.readableSecondary).fixedSize(horizontal: false, vertical: true) }
                            if words.warning { Image(systemName: "exclamationmark.triangle").font(.system(size: 10)).foregroundStyle(.readableSecondary) }
                        }
                    }
                    .padding(.leading, 8).accessibilityHidden(true).travelRole(.date(index))
                    Text(verbatim: words.clock).font(ClockFace.medium(core.settings, scale: textScale))
                        .foregroundStyle(.readableSecondary).fixedSize(horizontal: false, vertical: true)
                        .accessibilityHidden(true).travelRole(.clock(index))
                    TravelNightLane(lane: lane, art: index < art.count ? art[index] : [])
                        .travelRole(.lane(index))
                    Button { selected = index } label: {
                        Color.clear.contentShape(Rectangle())
                            .overlay(alignment: .leading) {
                                if selected == index { Rectangle().fill(.primary).frame(width: 2.5).padding(.vertical, 5) }
                            }
                    }
                    .buttonStyle(.plain).accessibilityLabel(Text(verbatim: words.spoken))
                    .accessibilityAddTraits(selected == index ? .isSelected : [])
                    .help(Text("点一下看这一晚"))
                    .accessibilityHint(Text("点一下看这一晚"))
                    .travelRole(.button(index))
                }
            }
            .focusable().focusEffectDisabled().focused($focused)
            .onMoveCommand { direction in
                if direction == .up { selected = max(0, selected - 1) }
                if direction == .down { selected = min(nights.lanes.count - 1, selected + 1) }
            }
            legend
        }
    }
    private func group(origin: Bool) -> some View {
        Text(verbatim: String(format: L10n.string(origin ? "出发前 · %@时间" : "到了以后 · %@时间", locale: core.uiLocale),
                             trip.placeName(origin: origin, core: core)))
            .appFont(.caption).foregroundStyle(.readableSecondary).accessibilityAddTraits(.isHeader)
            .fixedSize(horizontal: false, vertical: true)
    }
    private var legend: some View {
        SubjectFlowLayout(spacing: 8, lineSpacing: 4) {
            if nights.lanes.contains(where: { $0.parts.contains(where: { !$0.stops.isEmpty }) }) {
                legendItem("夜")
                SubjectDot()
                legendItem("白天")
                SubjectDot()
            }
            if nights.lanes.contains(where: { $0.sleep != nil }) { legendItem("睡觉"); SubjectDot() }
            if nights.lanes.contains(where: { !$0.seek.isEmpty }) { legendItem("晒光"); SubjectDot() }
            if nights.lanes.contains(where: { !$0.avoid.isEmpty }) { legendItem("避光"); SubjectDot() }
        }.accessibilityHidden(true)
    }
    private func legendItem(_ key: LocalizedStringKey) -> some View {
        Text(key).appFont(.caption).foregroundStyle(.readableSecondary)
    }
}

struct TravelNightLane: View {
    let lane: TravelNights.Lane
    let art: [TravelNightsMemo.Art]
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var width: CGFloat = 360
    var body: some View {
        let increased = contrast == .increased
        VStack(spacing: 2) {
            ZStack(alignment: .leading) {
                ForEach(Array(lane.parts.enumerated()), id: \.offset) { index, part in
                    let ribbon = index < art.count ? art[index].ribbon : nil
                    let line = index < art.count ? art[index].line : nil
                    Group {
                        if let ribbon { Image(decorative: ribbon, scale: 1).resizable().interpolation(.high) }
                        else { Rectangle().fill(.quaternary) }
                    }
                    .overlay { if scheme == .dark && !increased && ribbon != nil { Color.black.opacity(0.22) } }
                    .overlay {
                        TravelPartTicks(marks: part.marks).stroke(.background, lineWidth: 2.5)
                        TravelPartTicks(marks: part.marks).stroke(.primary, lineWidth: 1)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(increased ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary.opacity(0.9)), lineWidth: increased ? 1 : 0.75))
                    .overlay {
                        if let sleep = lane.sleep, sleep.count == 2 {
                            let lower = max(part.from, sleep[0]), upper = min(part.to, sleep[1])
                            if upper > lower {
                                let outline = TravelSleepOutline(lower: (lower - part.from) / (part.to - part.from),
                                    upper: (upper - part.from) / (part.to - part.from),
                                    left: lane.sleepClipStart != true && sleep[0] >= part.from,
                                    right: lane.sleepClipEnd != true && sleep[1] <= part.to)
                                if let line {
                                    Image(decorative: line, scale: 1).resizable().interpolation(.none)
                                        .mask(outline.stroke(lineWidth: increased ? 2 : 1.5))
                                } else { outline.stroke(.primary, lineWidth: increased ? 2 : 1.5) }
                            }
                        }
                    }
                    .frame(width: max(0, CGFloat(part.to - part.from) * width), height: 14)
                    .offset(x: CGFloat(part.from) * width)
                }
                ForEach(Array(lane.air.enumerated()), id: \.offset) { _, span in
                    if span.count == 2 {
                        TravelAirLine(lower: span[0], upper: span[1]).stroke(.readableSecondary.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, dash: [1.5, 3]))
                    }
                }
            }.frame(height: 14)
            ZStack(alignment: .leading) {
                ForEach(Array(lane.seek.enumerated()), id: \.offset) { _, span in
                    if span.count == 2 {
                        Capsule().fill(LightPalette.sun)
                            .overlay(Capsule().strokeBorder(increased ? AnyShapeStyle(.primary) : AnyShapeStyle(LightPalette.sunRim), lineWidth: increased ? 1 : scheme == .dark ? 0 : 0.75))
                            .frame(width: max(0, CGFloat(span[1] - span[0]) * width), height: 4).offset(x: CGFloat(span[0]) * width)
                    }
                }
                ForEach(Array(lane.avoid.enumerated()), id: \.offset) { _, span in
                    if span.count == 2 {
                        Capsule().strokeBorder(.primary.opacity(scheme == .dark ? 0.7 : 0.62), lineWidth: 0.75)
                            .overlay(TravelHatch().stroke(.primary.opacity(scheme == .dark ? 0.7 : 0.62), lineWidth: 1).clipShape(Capsule()))
                            .frame(width: max(0, CGFloat(span[1] - span[0]) * width), height: 4).offset(x: CGFloat(span[0]) * width)
                    }
                }
            }.frame(height: 4).frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .overlay(alignment: .top) {
            if let at = lane.reference {
                TravelReference(at: at).stroke(.background, lineWidth: 3.5)
                TravelReference(at: at).stroke(.primary, lineWidth: 1.5)
            }
        }
        .frame(height: 20).frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .modifier(SkyPreInvert()).accessibilityHidden(true)
    }

}

private struct TravelSleepOutline: Shape {
    let lower: Double
    let upper: Double
    let left: Bool
    let right: Bool
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let a = CGFloat(lower) * rect.width, b = CGFloat(upper) * rect.width
        path.move(to: CGPoint(x: a, y: 2)); path.addLine(to: CGPoint(x: b, y: 2))
        path.move(to: CGPoint(x: a, y: rect.height - 2)); path.addLine(to: CGPoint(x: b, y: rect.height - 2))
        if left { path.move(to: CGPoint(x: a, y: 2)); path.addLine(to: CGPoint(x: a, y: rect.height - 2)) }
        if right { path.move(to: CGPoint(x: b, y: 2)); path.addLine(to: CGPoint(x: b, y: rect.height - 2)) }
        return path
    }
}
private struct TravelPartTicks: Shape {
    let marks: [SkyStripState.Mark]
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for mark in marks {
            let x = CGFloat(mark.at) * rect.width
            path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: mark.full ? rect.height : rect.height / 2))
        }
        return path
    }
}
private struct TravelAirLine: Shape {
    let lower: Double
    let upper: Double
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: CGFloat(lower) * rect.width, y: rect.height / 2))
        path.addLine(to: CGPoint(x: CGFloat(upper) * rect.width, y: rect.height / 2))
        return path
    }
}
private struct TravelReference: Shape, Animatable {
    var at: Double
    var animatableData: Double { get { at } set { at = newValue } }
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: CGFloat(at) * rect.width, y: -3)); path.addLine(to: CGPoint(x: CGFloat(at) * rect.width, y: 17))
        return path
    }
}
private struct TravelHatch: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for x in stride(from: -rect.height, through: rect.width + rect.height, by: 3) {
            path.move(to: CGPoint(x: x, y: rect.height)); path.addLine(to: CGPoint(x: x + rect.height, y: 0))
        }
        return path
    }
}

private struct TravelNightRuler: View {
    @Environment(TimeCore.self) private var core
    @State private var width: CGFloat = 360
    var body: some View {
        let wide = width >= 240
        let twelve = [.oneToTwelve, .zeroToEleven].contains(ClockText.hourCycle(for: core.settings.hourStyle))
        HStack(spacing: 0) {
            ForEach(0..<8, id: \.self) { index in
                let hour = (12 + index * 3) % 24
                VStack(alignment: .leading, spacing: 0) {
                    if wide || index % 2 == 0 {
                        Text(verbatim: label(hour, twelve: twelve)).appFont(.caption2).foregroundStyle(.readableSecondary)
                    } else { Text(verbatim: " ").appFont(.caption2) }
                    Rectangle().fill(.tertiary).frame(width: 1, height: 3)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(height: 16).frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .accessibilityHidden(true)
    }
    private func label(_ hour: Int, twelve: Bool) -> String {
        guard twelve else { return String(hour) }
        if hour != 0 && hour != 12 { return String(hour % 12) }
        let formatter = DateFormatter()
        formatter.locale = ClockText.clockLocale(hourStyle: core.settings.hourStyle)
        return "12 " + (hour == 12 ? formatter.pmSymbol : formatter.amSymbol)
    }
}

private enum TravelRole: Equatable { case none, date(Int), clock(Int), lane(Int), button(Int), group(Int), ruler(Int) }
private struct TravelRoleKey: LayoutValueKey { static let defaultValue = TravelRole.none }
private extension View { func travelRole(_ role: TravelRole) -> some View { layoutValue(key: TravelRoleKey.self, value: role) } }

private struct TravelNightTableLayout: Layout {
    struct Plan { let width: CGFloat; let height: CGFloat; let frames: [Int: CGRect] }
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
        var dates: [Int: Int] = [:], clocks: [Int: Int] = [:], lanes: [Int: Int] = [:], buttons: [Int: Int] = [:], groups: [Int: Int] = [:], rulers: [Int: Int] = [:]
        for (index, view) in subviews.enumerated() {
            switch view[TravelRoleKey.self] {
            case .date(let row): dates[row] = index
            case .clock(let row): clocks[row] = index
            case .lane(let row): lanes[row] = index
            case .button(let row): buttons[row] = index
            case .group(let row): groups[row] = index
            case .ruler(let row): rulers[row] = index
            case .none: break
            }
        }
        let rows = dates.keys.sorted()
        let ideal = { (index: Int?) in index.map { subviews[$0].sizeThatFits(.unspecified).width } ?? 0 }
        let left = min(ceil(rows.map { ideal(dates[$0]) }.max() ?? 0), floor(width * 0.34))
        let clock = min(ceil(rows.map { ideal(clocks[$0]) }.max() ?? 0), floor(width * 0.26))
        let x = left + clock + 24
        let stacked = width - x < 160
        let laneWidth = stacked ? width : width - x
        let height = { (index: Int?, width: CGFloat) in index.map { subviews[$0].sizeThatFits(ProposedViewSize(width: width, height: nil)).height } ?? 0 }
        var frames: [Int: CGRect] = [:]
        var y: CGFloat = 0
        for row in rows {
            if let group = groups[row], let ruler = rulers[row] {
                if y > 0 { y += 8 }
                if stacked {
                    let h = max(16, height(group, width))
                    frames[group] = CGRect(x: 0, y: y, width: width, height: h)
                    y += h
                    frames[ruler] = CGRect(x: 0, y: y, width: width, height: 16)
                    y += 16
                } else {
                    let h = max(16, height(group, x - 12))
                    frames[group] = CGRect(x: 0, y: y, width: x - 12, height: h)
                    frames[ruler] = CGRect(x: x, y: y + h - 16, width: laneWidth, height: 16)
                    y += h
                }
            }
            let top = y
            y += 4
            if stacked {
                let clockWidth = min(ideal(clocks[row]), width * 0.45)
                let dateWidth = width - clockWidth - 12
                let h = max(height(dates[row], dateWidth), height(clocks[row], clockWidth))
                if let index = dates[row] { frames[index] = CGRect(x: 0, y: y, width: dateWidth, height: h) }
                if let index = clocks[row] { frames[index] = CGRect(x: width - clockWidth, y: y, width: clockWidth, height: h) }
                y += h + 3
                if let index = lanes[row] { frames[index] = CGRect(x: 0, y: y, width: width, height: 20) }
                y += 20
            } else {
                let h = max(26, height(dates[row], left), height(clocks[row], clock))
                if let index = dates[row] { frames[index] = CGRect(x: 0, y: y + (h - height(index, left)) / 2, width: left, height: height(index, left)) }
                if let index = clocks[row] { frames[index] = CGRect(x: left + 12, y: y + (h - height(index, clock)) / 2, width: clock, height: height(index, clock)) }
                if let index = lanes[row] { frames[index] = CGRect(x: x, y: y + (h - 20) / 2, width: laneWidth, height: 20) }
                y += h
            }
            y += 4
            if let index = buttons[row] { frames[index] = CGRect(x: 0, y: top, width: width, height: max(34, y - top)) }
        }
        return Plan(width: width, height: y, frames: frames)
    }
}
