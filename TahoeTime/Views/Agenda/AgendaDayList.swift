// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// 一天的日程：全天静态展示，定时的一行只改变选中。
struct AgendaDayList: View {
    let day: AgendaDay
    let frame: DayLaneFrame
    let selected: String?
    let calendars: [AgendaCalendar]
    let places: [AgendaTable.Place]
    let skies: MomentLaneMemo
    let shifted: Set<String>
    let select: (String) -> Void
    @Environment(TimeCore.self) private var core
    @Environment(\.textScale) private var textScale

    var body: some View {
        let width = Self.timeWidth(day: day, settings: core.settings, scale: textScale, locale: core.uiLocale, zone: frame.timeZone)
        LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(day.allDay) { event in
                let spoken = L10n.string("全天", locale: core.uiLocale) + ", " + Self.title(event.title, locale: core.uiLocale)
                row(event, allDay: true, startsBefore: false, ended: event.end <= core.now.timeIntervalSince1970,
                    isSelected: false, drift: false, width: width)
                    .accessibilityElement(children: .ignore).accessibilityAddTraits(.isStaticText)
                    .accessibilityLabel(Text(verbatim: spoken))
            }
            ForEach(day.timed) { event in
                Button { select(event.id) } label: {
                    row(event.item, allDay: false, startsBefore: event.startsBefore, ended: event.ended,
                        isSelected: event.id == selected, drift: shifted.contains(event.identifier), width: width)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(Text(verbatim: "\(Self.interval(event.item, frame: frame, core: core)), \(Self.title(event.title, locale: core.uiLocale))"))
                .accessibilityValue(Text(verbatim: spoken(event)))
                .accessibilityAddTraits(event.id == selected ? .isSelected : [])
                .accessibilityIdentifier("agenda-event-\(event.id)")
            }
        }
    }

    private func row(_ event: AgendaItem, allDay: Bool, startsBefore: Bool, ended: Bool,
                     isSelected: Bool, drift: Bool, width: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Rectangle().fill(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.clear))
                .frame(width: 2.5).padding(.vertical, 4).frame(width: 10)
                .accessibilityHidden(true)
            VStack(alignment: .trailing, spacing: 1) {
                if allDay {
                    Text("全天").appFont(.callout).foregroundStyle(.readableSecondary)
                } else {
                    Text(verbatim: ClockText.time(event.startDate, in: frame.timeZone, hourStyle: core.settings.hourStyle))
                        .font(ClockFace.medium(core.settings, scale: textScale))
                    if startsBefore { Text("前一日").appFont(.caption).foregroundStyle(.readableSecondary) }
                }
            }.frame(width: width, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    if calendars.count >= 2 { Self.dot(calendars.first { $0.id == event.calendarID }) }
                    Text(verbatim: Self.title(event.title, locale: core.uiLocale))
                        .appFont(.body, weight: isSelected ? .semibold : .regular)
                        .fixedSize(horizontal: false, vertical: true)
                    if drift { Self.driftBadge() }
                }
                if allDay {
                    let last = event.endDate.addingTimeInterval(-1)
                    if !Calendar.gregorianUTC(frame.timeZone).isDate(event.startDate, inSameDayAs: last) {
                        Text(verbatim: ClockText.range(ClockText.day(event.startDate, in: frame.timeZone, locale: core.uiLocale, now: core.now),
                                                      ClockText.day(last, in: frame.timeZone, locale: core.uiLocale, now: core.now)))
                            .appFont(.caption).foregroundStyle(.readableSecondary)
                    }
                }
            }.padding(.leading, 10).frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(ended ? AnyShapeStyle(.readableSecondary) : AnyShapeStyle(.primary))
        .padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }

    private func spoken(_ event: AgendaDayItem) -> String {
        var parts: [String] = []
        if let status = Self.status(event.item, now: core.now, viewedDay: frame.start, locale: core.uiLocale, zone: frame.timeZone) { parts.append(status) }
        if let location = event.location, !location.isEmpty { parts.append(String(format: L10n.string("地点：%@", locale: core.uiLocale), location)) }
        if calendars.count >= 2, let calendar = calendars.first(where: { $0.id == event.calendarID }) {
            parts.append(String(format: L10n.string("日历：%@", locale: core.uiLocale), calendar.title))
        }
        let at = MomentTable.fraction(of: event.startDate, in: frame)
        for (index, place) in places.enumerated() {
            guard index < skies.art.count, skies.art[index].isDay(at: at) == false else { continue }
            let note = MomentTable.dayNote(event.startDate, in: place.zone, from: frame.timeZone, locale: core.uiLocale).map { " \($0)" } ?? ""
            let time = ClockText.time(event.startDate, in: place.zone, hourStyle: core.settings.hourStyle)
            let night = L10n.string("夜晚", locale: core.uiLocale)
            parts.append("\(place.name)\(note) \(time) \(night)")
        }
        if shifted.contains(event.identifier) { parts.append(L10n.string("换钟会挪动这场例会", locale: core.uiLocale)) }
        return parts.joined(separator: ", ")
    }

    static func title(_ title: String, locale: Locale) -> String { title.isEmpty ? L10n.string("未命名日程", locale: locale) : title }
    static func interval(_ event: AgendaItem, frame: DayLaneFrame, core: TimeCore) -> String {
        if event.startDate < frame.start || event.endDate > frame.end {
            return ClockText.interval(from: event.startDate, to: event.displayEndDate, in: frame.timeZone,
                                      hourStyle: core.settings.hourStyle, locale: core.uiLocale, now: core.now)
        }
        return ClockText.range(ClockText.time(event.startDate, in: frame.timeZone, hourStyle: core.settings.hourStyle),
                               ClockText.time(event.endDate, in: frame.timeZone, hourStyle: core.settings.hourStyle))
    }
    static func status(_ event: AgendaItem, now: Date, viewedDay: Date, locale: Locale, zone: TimeZone) -> String? {
        guard Calendar.gregorianUTC(zone).isDate(now, inSameDayAs: viewedDay) else { return nil }
        if event.endDate <= now { return L10n.string("已结束", locale: locale) }
        if event.startDate <= now { return L10n.string("正在进行", locale: locale) }
        return ClockText.durationIn(seconds: event.startDate.timeIntervalSince(now), locale: locale)
    }
    static func copyText(_ event: AgendaItem, places: [AgendaTable.Place], hourStyle: HourStyle, locale: Locale, now: Date, home: TimeZone = .current) -> String {
        title(event.title, locale: locale) + "\n" + TimeInput.pasteLine(start: event.startDate, end: event.endDate,
            zones: places.map { (name: $0.name, zone: $0.zone) }, source: home, hourStyle: hourStyle, locale: locale, now: now)
    }
    static func timeWidth(day: AgendaDay, settings: AppSettings, scale: Double, locale: Locale, zone: TimeZone) -> CGFloat {
        let font = ClockFace.nativeFont(size: ClockFace.mediumSize(scale: scale), design: settings.fontDesign, weight: settings.weight, light: false)
        var width: CGFloat = 0
        for event in day.timed {
            let text = ClockText.time(event.startDate, in: zone, hourStyle: settings.hourStyle)
            width = max(width, (text as NSString).size(withAttributes: [.font: font]).width)
        }
        if !day.allDay.isEmpty {
            let text = L10n.string("全天", locale: locale)
            width = max(width, (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: AppFont.size(.callout) * scale)]).width)
        }
        return ceil(width)
    }
    static func dot(_ calendar: AgendaCalendar?) -> some View {
        Circle().fill(calendar?.color.map { AnyShapeStyle($0.color) } ?? AnyShapeStyle(.tertiary))
            .frame(width: 8, height: 8).accessibilityHidden(true)
    }
    static func driftBadge() -> some View {
        Image(systemName: "clock.arrow.2.circlepath").appFont(.caption).foregroundStyle(.readableSecondary)
            .help(Text("换钟会挪动这场例会")).accessibilityLabel(Text("换钟会挪动这场例会"))
    }
}

/// 只有换天或穿梭改变时才重新选；钟走到下一分钟保留人的选择。
struct AgendaPageSelection: Equatable {
    private(set) var id: String?
    private var day: Date?
    private var offset: TimeInterval?
    mutating func update(day: Date, offset: TimeInterval, preferred: String?, available: [String]) {
        if self.day != day || self.offset != offset || id == nil || !available.contains(id ?? "") {
            id = preferred
            self.day = day
            self.offset = offset
        }
    }
    mutating func select(_ id: String) { self.id = id }
}
