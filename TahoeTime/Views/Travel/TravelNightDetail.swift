// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

@MainActor
struct TravelNightWords {
    struct Item { let start: Double; let icon: String; let text: String; var sunlight = false }
    let trip: TravelTrip
    let lane: TravelNights.Lane
    let core: TimeCore
    var zone: TimeZone { TimeZone(identifier: lane.kind == "prep" ? trip.originTimeZoneID : trip.destinationTimeZoneID) ?? .gmt }
    func format(_ key: String, _ args: CVarArg...) -> String {
        String(format: L10n.string(key, locale: core.uiLocale), locale: core.uiLocale, arguments: args)
    }
    func duration(_ minutes: Double) -> String { ClockText.duration(seconds: abs(minutes) * 60, locale: core.uiLocale) }
    func day(_ iso: String, weekday: Bool = true, in zone: TimeZone? = nil) -> String {
        let chosen = zone ?? self.zone
        guard let date = TravelNightFacts.date(iso, in: chosen) else { return iso }
        return ClockText.day(date, in: chosen, locale: core.uiLocale, now: core.now, weekday: weekday)
    }
    var dateText: String {
        let origin = TimeZone(identifier: trip.originTimeZoneID) ?? .gmt
        if lane.kind == "flight" { return day(lane.date, in: origin) }
        if let to = lane.dateTo { return ClockText.range(day(lane.date, weekday: false), day(to, weekday: false)) }
        return day(lane.date)
    }
    var label: String {
        switch lane.label.kind {
        case "shift":
            guard let minutes = lane.label.minutes, minutes != 0 else { return "" }
            return format(minutes > 0 ? "晚睡 %@" : "早睡 %@", duration(minutes))
        case "remaining": return format("身体还差 %@", duration(((lane.label.minutes ?? 0) / 60).rounded() * 60))
        case "aligned": return L10n.string("按当地作息", locale: core.uiLocale)
        case "flight": return format("飞 %@", duration(lane.label.minutes ?? 0))
        case "quiet": return format("这 %lld 晚按当地时间睡", Int64(lane.label.nights ?? 1))
        default: return ""
        }
    }
    var title: String {
        if lane.kind == "flight" { return dateText + " · " + format("飞往%@", trip.placeName(origin: false, core: core)) }
        let place = trip.placeName(origin: lane.kind == "prep", core: core)
        let date: String
        if lane.dateTo != nil { date = dateText }
        else {
            let noon = TravelNightFacts.date(lane.date, in: zone) ?? trip.arrival
            let next = Calendar.gregorianUTC(zone).date(byAdding: .day, value: 1, to: noon) ?? noon
            date = format("%1$@夜里", dateText, ClockText.day(next, in: zone, locale: core.uiLocale, now: core.now, weekday: true))
        }
        var parts = [date, format("%@时间", place)]
        if lane.kind == "after", lane.label.kind == "remaining" { parts.append(label) }
        return parts.joined(separator: " · ")
    }
    var clock: String {
        if lane.kind == "flight" {
            return ClockText.range(ClockText.time(trip.departure, in: TimeZone(identifier: trip.originTimeZoneID) ?? .gmt, hourStyle: core.settings.hourStyle),
                ClockText.time(trip.arrival, in: TimeZone(identifier: trip.destinationTimeZoneID) ?? .gmt, hourStyle: core.settings.hourStyle))
        }
        if lane.kind == "prep" {
            let shifted = Int(lane.label.minutes ?? 0)
            let sleep = ((trip.sleepMinute + shifted) % 1440 + 1440) % 1440
            let wake = ((trip.wakeMinute + shifted) % 1440 + 1440) % 1440
            return ClockText.minuteRange(sleep, wake, hourStyle: core.settings.hourStyle)
        }
        return ClockText.minuteRange(trip.sleepMinute, trip.wakeMinute, hourStyle: core.settings.hourStyle)
    }
    private func clockRange(_ span: [Double]) -> String {
        guard span.count == 2 else { return "" }
        return ClockText.range(ClockText.time(Date(timeIntervalSince1970: span[0]), in: zone, hourStyle: core.settings.hourStyle),
            ClockText.time(Date(timeIntervalSince1970: span[1]), in: zone, hourStyle: core.settings.hourStyle))
    }
    var items: [Item] {
        var result: [Item] = []
        if lane.kind == "flight" {
            let origin = TimeZone(identifier: trip.originTimeZoneID) ?? .gmt
            let destination = TimeZone(identifier: trip.destinationTimeZoneID) ?? .gmt
            result.append(.init(start: trip.departureUnix, icon: "airplane", text: format("%1$@ %2$@ 起飞，%3$@ %4$@ 落地，飞 %5$@",
                trip.placeName(origin: true, core: core), ClockText.time(trip.departure, in: origin, hourStyle: core.settings.hourStyle),
                trip.placeName(origin: false, core: core), ClockText.dateTime(trip.arrival, in: destination,
                    hourStyle: core.settings.hourStyle, locale: core.uiLocale, now: core.now, weekday: true), duration((trip.arrivalUnix - trip.departureUnix) / 60))))
        } else {
            let minutes = lane.kind == "prep" ? lane.label.minutes ?? 0 : 0
            let key = lane.kind == "after" ? "%@　按当地时间睡" : minutes == 0 ? "%@　睡觉" : minutes > 0 ? "%@　睡觉，比平时晚 %@" : "%@　睡觉，比平时早 %@"
            let start = lane.sleep?.first.map { (lane.range.first ?? 0) + $0 * ((lane.range.last ?? 0) - (lane.range.first ?? 0)) } ?? lane.range.first ?? 0
            result.append(.init(start: start, icon: "moon.zzz", text: format(key, clock, duration(minutes))))
        }
        if let span = lane.seekRange { result.append(.init(start: span[0], icon: "sun.max.fill", text: format("%@　晒光：户外或明亮的光", clockRange(span)), sunlight: true)) }
        if let span = lane.avoidRange {
            let dim = lane.avoidKind == "dim"
            result.append(.init(start: span[0], icon: dim ? "lightbulb.slash" : "sunglasses", text: format(dim ? "%@　调暗：室内光调暗，少看亮屏" : "%@　避光：戴深色墨镜，少看亮屏", clockRange(span))))
        }
        return result.sorted { $0.start < $1.start }
    }
    var warning: Bool {
        guard let checks = lane.checks else { return false }
        return checks.nonexistentTime || checks.repeatedTime || checks.overlapsDeparture || elapsedDiffers
    }
    var elapsedDiffers: Bool {
        guard let elapsed = lane.checks?.elapsedSleepMinutes else { return false }
        return abs(elapsed - Double((trip.wakeMinute - trip.sleepMinute + 1440) % 1440)) > 0.5
    }
    var spoken: String {
        var values = [title] + items.map(\.text)
        if lane.label.kind == "quiet" { values.append(format("身体还差 %@；这几晚没有要特别晒光或避光的时段。", duration(lane.label.minutes ?? 0))) }
        if let checks = lane.checks {
            if checks.nonexistentTime { values.append(L10n.string("当地没有这个时刻，请调整睡眠时间。", locale: core.uiLocale)) }
            if checks.overlapsDeparture { values.append(L10n.string("这段作息与出发时间重叠，请调整行程或作息。", locale: core.uiLocale)) }
            if checks.repeatedTime { values.append(L10n.string("当地时刻会重复，请核对夏令时切换。", locale: core.uiLocale)) }
            if elapsedDiffers { values.append(format("实际经过 %@", duration(checks.elapsedSleepMinutes ?? 0))) }
        }
        return values.joined(separator: core.uiLocale.language.languageCode?.identifier == "zh" ? "；" : "; ")
    }
}

struct TravelNightDetail: View {
    @Environment(TimeCore.self) private var core
    let trip: TravelTrip
    let lane: TravelNights.Lane
    var body: some View {
        let words = TravelNightWords(trip: trip, lane: lane, core: core)
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: words.title).appFont(.headline).accessibilityAddTraits(.isHeader)
            ForEach(Array(words.items.enumerated()), id: \.offset) { _, item in
                let iconStyle: AnyShapeStyle = if item.sunlight {
                    AnyShapeStyle(LightPalette.sun)
                } else if item.icon == "sunglasses" || item.icon == "lightbulb.slash" {
                    AnyShapeStyle(.primary)
                } else {
                    AnyShapeStyle(.readableSecondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: item.icon).foregroundStyle(iconStyle)
                        .frame(width: 16).accessibilityHidden(true)
                    Text(verbatim: item.text).appFont(.body).fixedSize(horizontal: false, vertical: true)
                }
            }
            if lane.label.kind == "quiet" {
                Label(words.format("身体还差 %@；这几晚没有要特别晒光或避光的时段。", words.duration(lane.label.minutes ?? 0)), systemImage: "exclamationmark.triangle")
                    .appFont(.caption).foregroundStyle(.readableSecondary)
            }
            if let checks = lane.checks {
                if checks.nonexistentTime { ErrorLine(Text("当地没有这个时刻，请调整睡眠时间。")) }
                if checks.overlapsDeparture { ErrorLine(Text("这段作息与出发时间重叠，请调整行程或作息。")) }
                if checks.repeatedTime {
                    Label("当地时刻会重复，请核对夏令时切换。", systemImage: "exclamationmark.triangle").appFont(.caption).foregroundStyle(.readableSecondary)
                }
                if words.elapsedDiffers {
                    Label(words.format("实际经过 %@", words.duration(checks.elapsedSleepMinutes ?? 0)), systemImage: "clock.arrow.circlepath")
                        .appFont(.caption).foregroundStyle(.readableSecondary)
                }
            }
        }
    }
}
