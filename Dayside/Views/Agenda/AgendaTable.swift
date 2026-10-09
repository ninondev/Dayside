// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// 同一场日程穿过各地的天；细轨只落在本机那一行。
struct AgendaTable: View {
    struct Place: Identifiable, Equatable {
        var id: String { zone.identifier }
        let zone: TimeZone
        let name: String
        let note: String
        let coordinate: Coordinate?
    }
    let places: [Place]
    let frame: DayLaneFrame
    let events: [AgendaDayItem]
    let selected: AgendaDayItem?
    let skies: MomentLaneMemo
    let select: (String) -> Void
    @Environment(TimeCore.self) private var core
    @Environment(\.textScale) private var textScale

    var body: some View {
        let shown = selected?.startDate ?? core.referenceDate
        let marker = MomentTable.fraction(of: shown, in: frame)
        let span = selected.map { MomentTable.fraction(of: $0.startDate, in: frame)...MomentTable.fraction(of: $0.endDate, in: frame) }
        let spans = events.map { MomentTable.fraction(of: $0.startDate, in: frame)...MomentTable.fraction(of: $0.endDate, in: frame) }
        MomentTableLayout(rowGap: 6) {
            DayLaneRuler(frame: frame).momentRole(.ruler)
            ForEach(Array(places.enumerated()), id: \.element.id) { index, place in
                connector(span: span, marker: marker).momentRole(.connector(index))
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: place.name)
                        .font(SerifFace.font(place.name, size: (15 * textScale).rounded(), weight: .regular, locale: core.uiLocale))
                        .fixedSize(horizontal: false, vertical: true)
                    if !place.note.isEmpty {
                        Text(verbatim: place.note).appFont(.caption).foregroundStyle(.readableSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine).momentRole(.left(index))
                rightCell(place, shown: shown).momentRole(.right(index))
                AgendaSkyLane(art: index < skies.art.count ? skies.art[index] : .unknown,
                              ribbon: index < skies.ribbons.count ? skies.ribbons[index] : nil,
                              marker: marker, span: span, spans: index == 0 ? spans : [])
                    .modifier(AgendaTimelineTap(events: events, frame: frame, select: select))
                    .momentRole(.lane(index))
            }
            if core.now >= frame.start, core.now < frame.end, selected != nil || core.displayOffset != 0 {
                ReadNotch().fill(.primary).momentRole(.notch(MomentTable.fraction(of: core.now, in: frame)))
            }
            Color.clear.contentShape(Rectangle())
                .modifier(AgendaTimelineTap(events: events, frame: frame, select: select))
                .help(Text("点一下选中那一场"))
                .accessibilityElement(children: .ignore).accessibilityAddTraits(.isImage)
                .accessibilityLabel(Text("当天时间轴"))
                .accessibilityValue(Text(verbatim: spoken(shown: shown, marker: marker)))
                .accessibilityHint(Text("调整可切换前后一场日程"))
                .accessibilityAdjustableAction { direction in
                    guard !events.isEmpty else { return }
                    let index = events.firstIndex { $0.id == selected?.id } ?? 0
                    let target = direction == .increment ? index + 1 : index - 1
                    if events.indices.contains(target) { select(events[target].id) }
                }
                .focusable()
                .accessibilitySortPriority(-1).momentRole(.accessibility)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func connector(span: ClosedRange<Double>?, marker: Double) -> some View {
        if let span {
            ZStack {
                ColumnBand(from: span.lowerBound, to: span.upperBound).fill(.primary.opacity(0.07))
                ColumnLines(from: span.lowerBound, to: span.upperBound).stroke(.primary, lineWidth: 1.5)
            }.accessibilityHidden(true)
        } else {
            MarkerLine(at: marker).stroke(.primary, lineWidth: 1.5).accessibilityHidden(true)
        }
    }

    private func rightCell(_ place: Place, shown: Date) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(verbatim: ClockText.time(shown, in: place.zone, hourStyle: core.settings.hourStyle))
                .font(ClockFace.medium(core.settings, scale: textScale)).multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
            if let note = MomentTable.dayNote(shown, in: place.zone, from: frame.timeZone, locale: core.uiLocale) {
                Text(verbatim: note).appFont(.caption).foregroundStyle(.readableSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.accessibilityElement(children: .combine)
    }

    private func spoken(shown: Date, marker: Double) -> String {
        var parts: [String] = []
        if let selected {
            parts.append(AgendaDayList.title(selected.title, locale: core.uiLocale))
            let range = ClockText.range(ClockText.time(selected.startDate, in: frame.timeZone, hourStyle: core.settings.hourStyle),
                                        ClockText.time(selected.endDate, in: frame.timeZone, hourStyle: core.settings.hourStyle))
            parts.append(String(format: L10n.string("日程在本机 %@", locale: core.uiLocale), range))
        } else {
            parts.append(String(format: L10n.string("竖线在本机 %@", locale: core.uiLocale),
                                ClockText.time(shown, in: frame.timeZone, hourStyle: core.settings.hourStyle)))
        }
        for (index, place) in places.enumerated() {
            guard index < skies.art.count, let day = skies.art[index].isDay(at: marker) else { continue }
            parts.append("\(place.name) \(L10n.string(day ? "白天" : "夜晚", locale: core.uiLocale))")
        }
        return parts.joined(separator: ", ")
    }

    static func places(core: TimeCore, people: [PersonProfile], home: TimeZone = .current) -> [Place] {
        var zones = [home]
        var seen = Set([home.identifier])
        for id in core.zones.map(\.timezoneID) + people.map({ $0.resolvedTimeZoneID(places: core.zones) }) {
            if let zone = TimeZone(identifier: id), seen.insert(zone.identifier).inserted { zones.append(zone) }
        }
        return zones.map { zone in
            let saved = core.zones.first { $0.timezoneID == zone.identifier }
            let names = people.filter { $0.resolvedTimeZoneID(places: core.zones) == zone.identifier }.map(\.name)
            var note = Array(names.prefix(3)).formatted(.list(type: .and, width: .narrow).locale(core.uiLocale))
            if names.count > 3 { note += " +\(names.count - 3)" }
            if zone == home { note = L10n.string("本机", locale: core.uiLocale) }
            let city = saved.map { core.cityName(for: $0) } ?? core.placeName(forTimeZoneID: zone.identifier)
            let name = zone == home && saved == nil ? String(format: L10n.string("本机（%@）", locale: core.uiLocale), city) : city
            return Place(zone: zone, name: name, note: note,
                         coordinate: saved?.coordinate ?? ZoneCatalog.shared.knownCoordinate(for: zone.identifier))
        }
    }

    static func hit(at fraction: Double, width: CGFloat, events: [AgendaDayItem], frame: DayLaneFrame) -> String? {
        guard width > 0 else { return nil }
        let time = frame.start.timeIntervalSince1970 + fraction * frame.length
        if let event = events.last(where: { $0.start <= time && time < $0.end }) { return event.id }
        let nearest = events.min { distance(time, $0) < distance(time, $1) }
        guard let nearest, distance(time, nearest) / frame.length * Double(width) <= 8 else { return nil }
        return nearest.id
    }
    private static func distance(_ at: Double, _ event: AgendaDayItem) -> Double { max(event.start - at, at - event.end, 0) }
}

private struct AgendaTimelineTap: ViewModifier {
    let events: [AgendaDayItem]
    let frame: DayLaneFrame
    let select: (String) -> Void
    @State private var width: CGFloat = 0
    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .onTapGesture { location in
                if let id = AgendaTable.hit(at: Double(location.x / max(width, 1)), width: width, events: events, frame: frame) { select(id) }
            }
    }
}

private struct AgendaSkyLane: View {
    let art: MomentLaneArt
    let ribbon: CGImage?
    let marker: Double
    let span: ClosedRange<Double>?
    let spans: [ClosedRange<Double>]
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        VStack(spacing: 2) {
            Group {
                if let ribbon { Image(decorative: ribbon, scale: 1).resizable().interpolation(.high) }
                else { Rectangle().fill(.quaternary) }
            }
            .modifier(SkyPreInvert())
            .overlay { if scheme == .dark && contrast != .increased && ribbon != nil { Color.black.opacity(0.22) } }
            .overlay {
                if !art.marks.isEmpty {
                    BandTicks(marks: art.marks).stroke(.background, lineWidth: 2.5)
                    BandTicks(marks: art.marks).stroke(.primary, lineWidth: 1)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(contrast == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary.opacity(0.9)), lineWidth: contrast == .increased ? 1 : 0.75))
            .frame(height: 12)
            if !spans.isEmpty {
                AgendaInkSpans(spans: spans).fill(.primary.opacity(contrast == .increased ? 0.75 : 0.55))
                    .background(Capsule().fill(.quaternary))
                    .overlay { if let span { AgendaInkSpans(spans: [span]).fill(.primary) } }
                    .frame(height: 5)
            }
        }
        .overlay {
            if let span {
                ColumnLines(from: span.lowerBound, to: span.upperBound).stroke(.background, lineWidth: 3.5)
                ColumnLines(from: span.lowerBound, to: span.upperBound).stroke(.primary, lineWidth: 1.5)
            } else {
                MarkerLine(at: marker).stroke(.background, lineWidth: 3.5)
                MarkerLine(at: marker).stroke(.primary, lineWidth: 1.5)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct AgendaInkSpans: Shape {
    let spans: [ClosedRange<Double>]
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for span in spans {
            let x = rect.minX + CGFloat(span.lowerBound) * rect.width
            let end = min(rect.maxX, max(rect.minX + CGFloat(span.upperBound) * rect.width, x + 3))
            path.addRoundedRect(in: CGRect(x: min(x, rect.maxX - 3), y: rect.minY, width: max(3, end - x), height: rect.height), cornerSize: CGSize(width: 1.5, height: 1.5))
        }
        return path
    }
}
