// SPDX-License-Identifier: GPL-3.0-only
//
//  MarketTable.swift
//  Dayside
//
//  市场时钟的共同时间轴：别人的上班时间。与换算页、找碰头时间同一张表（`MomentTableLayout`：顶上一行本机刻度，
//  每个市场一行「名字 | 那一刻的状态 | 那里的天」，天按本机当天对齐、上下对齐），天下面一道细轨是那个市场的交易时段（蓝，
//  与找碰头时间里各人的工作时段同一种画法：市场就是一个上班时间写在牌子上的人）。一根竖线穿过所有的天：App 正在看的那一刻；
//  点任何一条天或刻度看那一刻各市场开没开（对齐整刻钟），原来那一刻在刻度下沿留一个小三角。
//
//  天由 Rust `sky.lanes` 一次给齐、画成一行像素（与换算页同一个 `MomentLaneMemo`），交易所的天按它所在的城市画；
//  时段与状态由页面给（`MarketMemo`）。点一下、走一分钟、窗口改大小都不再去 Rust 算天。工具窗关了它就不在。
//

import SwiftUI

struct MarketTable: View {
    struct Row: Identifiable, Equatable {
        let id: String
        let name: String
        /// 名字下面一行：当地的交易时段「9:30–16:00 当地」。
        let hours: String
        /// 状态词：开盘中 / 未开盘 / 午休中 / 已收盘 / 休市。
        let status: String
        /// 休市的缘由（「感恩节」「当地周六」），只跟着「休市」。
        let reason: String?
        /// 下一次开盘或收盘：「2小时后收盘（本机 13:00）」，超过一天写到星期。
        let next: String?
        let open: Bool
        let coordinate: Coordinate?
        /// 框里的交易时段（0…1）。
        let sessions: [ClosedRange<Double>]
    }

    let rows: [Row]
    let frame: DayLaneFrame
    /// App 正在看的那一刻（竖线原来的位置）。
    let reference: Date
    /// 读屏念的值，由页面按表上正在显示的那一刻给。
    let spoken: String
    @Binding var peek: Date?
    /// 交易所与外汇时段两张表左右两列同宽，轴一样长。
    static let shares: (left: CGFloat, right: CGFloat) = (0.3, 0.28)

    @Environment(TimeCore.self) private var core
    @Environment(\.textScale) private var textScale
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @State private var skies = MomentLaneMemo()

    var body: some View {
        let _ = skies.update(frame: frame, coordinates: rows.map(\.coordinate), marks: differentiateWithoutColor)
        let shown = peek ?? reference
        let line = MomentTable.fraction(of: shown, in: frame)
        let read = MomentTable.fraction(of: reference, in: frame)
        MomentTableLayout(fixedShares: Self.shares) {
            Text(verbatim: ClockText.day(frame.start.addingTimeInterval(frame.length / 2), in: frame.timeZone, locale: core.uiLocale,
                                         now: core.now, weekday: true))
                .appFont(.caption).foregroundStyle(.readableSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .momentRole(.rulerLabel)
            DayLaneRuler(frame: frame)
                .momentRole(.ruler)
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                MarkerLine(at: line).stroke(.primary, lineWidth: 1.5).accessibilityHidden(true).momentRole(.connector(index))
                leftCell(row).momentRole(.left(index))
                MarketLane(art: index < skies.art.count ? skies.art[index] : .unknown,
                           ribbon: index < skies.ribbons.count ? skies.ribbons[index] : nil,
                           sessions: row.sessions, marker: line)
                    .momentRole(.lane(index))
                rightCell(row).momentRole(.right(index))
            }
            if peek != nil {
                ReadNotch().fill(.primary).momentRole(.notch(read))
            }
            Color.clear
                .contentShape(Rectangle())
                .modifier(MarketPeekTap(frame: frame, read: read, peek: $peek))
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isImage)
                .accessibilityLabel(Text("当天时间轴"))
                .accessibilityValue(Text(verbatim: spoken))
                .accessibilityHint(Text("调整可看前后一小时各市场开没开"))
                .accessibilityAdjustableAction { direction in
                    let target = shown.addingTimeInterval(direction == .increment ? 3600 : -3600)
                    guard target >= frame.start, target < frame.end else { return }
                    peek = abs(target.timeIntervalSince(reference)) < 1 ? nil : target
                }
                .accessibilitySortPriority(-1)
                .momentRole(.accessibility)
        }
        .accessibilityElement(children: .contain)
    }

    /// 左边：衬线名字，下面一行当地的交易时段。读屏一句念完。
    private func leftCell(_ row: Row) -> some View {
        let size = (AppFont.size(.body) * 1.15 * textScale).rounded()
        return VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: row.name).font(SerifFace.font(row.name, size: size, weight: .regular, locale: core.uiLocale))
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: row.hours).appFont(.caption).foregroundStyle(.readableSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    /// 右边：那一刻的状态（开着前面一颗绿点：在班），休市写缘由；下面一行下一次开盘或收盘。
    private func rightCell(_ row: Row) -> some View {
        let word = Text(verbatim: row.status).fontWeight(.semibold)
            .foregroundStyle(row.open ? AnyShapeStyle(.primary) : AnyShapeStyle(.readableSecondary))
        // `Text + Text` 在 macOS 26 已废弃，拼接走插值（键「%@%@」在字符串目录里）。
        let status = row.reason.map { Text("\(word)\(Text(verbatim: " · \($0)").foregroundStyle(.readableSecondary))") } ?? word
        return VStack(alignment: .trailing, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if row.open {
                    Circle().fill(.green).frame(width: 7, height: 7).accessibilityHidden(true)
                }
                status.appFont(.callout)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let next = row.next {
                Text(verbatim: next).appFont(.caption).foregroundStyle(.readableSecondary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }
}

/// 点时间轴上的某处：看那一刻各市场开没开（对齐整刻钟）；点回原来那一刻附近（6 点以内）就回去。只看，不挪 App。
private struct MarketPeekTap: ViewModifier {
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

/// 一个市场那一行的天：所在城市的天（一行像素拉满，圆角 3，细描边，深色压暗 22%，「不使用颜色区分」时画昼夜刻度），
/// 下面一道细轨是交易时段（不透明的昼的蓝，与工作时段同一种），竖线穿过天与细轨（反色时与天一起预反）。
private struct MarketLane: View {
    let art: MomentLaneArt
    let ribbon: CGImage?
    let sessions: [ClosedRange<Double>]
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
            SessionSpans(spans: sessions).fill(DaysidePalette.day)
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

/// 细轨里的交易时段：一条路径画完所有段。
private struct SessionSpans: Shape {
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
