// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

struct TravelPlanMenus: View {
    @Environment(TimeCore.self) private var core
    let trip: TravelTrip
    let store: TravelStore
    let summary: TravelPlan.Summary
    @State private var editingSleep = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("安排").appFont(.headline).accessibilityAddTraits(.isHeader)
            SubjectFlowLayout {
                Button { editingSleep = true } label: {
                    TravelMenuLabel(text: format("平时 %@ 睡", ClockText.minuteRange(trip.sleepMinute, trip.wakeMinute, hourStyle: core.settings.hourStyle)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("平时的作息"))
                .accessibilityValue(Text(verbatim: ClockText.minuteRange(trip.sleepMinute, trip.wakeMinute, hourStyle: core.settings.hourStyle)))
                .popover(isPresented: $editingSleep) {
                    VStack(alignment: .leading, spacing: 10) {
                        DatePicker("入睡", selection: minuteBinding(\.sleepMinute), displayedComponents: .hourAndMinute)
                        DatePicker("起床", selection: minuteBinding(\.wakeMinute), displayedComponents: .hourAndMinute)
                        Text("到了那边也按这个钟点睡。").appFont(.caption).foregroundStyle(.readableSecondary)
                    }
                    .environment(\.timeZone, .gmt).environment(\.calendar, Calendar.gregorianUTC(.gmt))
                    .environment(\.locale, core.uiLocale).padding(12)
                }
                SubjectDot()
                Menu {
                    ForEach(0...7, id: \.self) { nights in
                        menuItem(preparation(nights), selected: trip.preparationDays == nights) { save(\.preparationDays, nights) }
                    }
                } label: { TravelMenuLabel(text: preparation(trip.preparationDays)) }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                    .accessibilityLabel(Text("出发前几晚开始挪"))
                    .accessibilityValue(Text(verbatim: preparation(trip.preparationDays)))
                SubjectDot()
                Menu {
                    ForEach([15, 30, 60, 90, 120], id: \.self) { minutes in
                        menuItem(duration(minutes), selected: trip.dailyShiftMinutes == minutes) { save(\.dailyShiftMinutes, minutes) }
                    }
                } label: { TravelMenuLabel(text: format("每晚 %@", duration(trip.dailyShiftMinutes))) }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                    .accessibilityLabel(Text("每晚挪多少"))
                    .accessibilityValue(Text(verbatim: duration(trip.dailyShiftMinutes)))
                    .help(Text("往前挪每晚最多 1小时；往后挪可到 2小时。"))
                    .accessibilityHint(Text("往前挪每晚最多 1小时；往后挪可到 2小时。"))
                if summary.targetShiftMinutes != 0 {
                    SubjectDot()
                    Menu {
                        ForEach(["automatic", "earlier", "later"], id: \.self) { value in
                            menuItem(direction(value), selected: trip.direction == value) { save(\.direction, value) }
                        }
                    } label: { TravelMenuLabel(text: directionLabel) }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                        .accessibilityLabel(Text("往哪边挪"))
                        .accessibilityValue(Text(verbatim: directionLabel))
                }
            }
            .disabled(store.storageReadOnly)
            .modifier(TravelStorageHelp(readOnly: store.storageReadOnly))
        }
    }
    private func format(_ key: String, _ args: CVarArg...) -> String {
        String(format: L10n.string(key, locale: core.uiLocale), locale: core.uiLocale, arguments: args)
    }
    private func duration(_ minutes: Int) -> String { ClockText.duration(seconds: Double(minutes) * 60, locale: core.uiLocale) }
    private func preparation(_ nights: Int) -> String {
        nights == 0 ? L10n.string("出发前不挪", locale: core.uiLocale) : format("出发前 %lld 晚", Int64(nights))
    }
    private func direction(_ value: String) -> String {
        L10n.string(value == "automatic" ? "自动" : value == "earlier" ? "往前挪" : "往后挪", locale: core.uiLocale)
    }
    private var directionLabel: String {
        trip.direction == "automatic" ? format("%@（自动）", direction(summary.targetShiftMinutes > 0 ? "later" : "earlier")) : direction(trip.direction)
    }
    private func menuItem(_ text: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { if selected { Label(text, systemImage: "checkmark") } else { Text(verbatim: text) } }
    }
    private func save<T>(_ key: WritableKeyPath<TravelTrip, T>, _ value: T) {
        var draft = trip
        draft[keyPath: key] = value
        store.save(draft)
    }
    private func minuteBinding(_ key: WritableKeyPath<TravelTrip, Int>) -> Binding<Date> {
        Binding(get: { Date(timeIntervalSince1970: Double(trip[keyPath: key]) * 60) }, set: {
            let parts = Calendar.gregorianUTC(.gmt).dateComponents([.hour, .minute], from: $0)
            save(key, (parts.hour ?? 0) * 60 + (parts.minute ?? 0))
        })
    }
}

struct TravelMenuLabel: View {
    let text: String
    var body: some View {
        HStack(spacing: 4) {
            Text(verbatim: text).appFont(.body).fixedSize(horizontal: false, vertical: true)
            Image(systemName: "chevron.down").font(.system(size: 9)).accessibilityHidden(true)
        }.frame(minHeight: 24).contentShape(Rectangle())
    }
}

private struct TravelStorageHelp: ViewModifier {
    let readOnly: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if readOnly {
            content.help(Text("请更新 Dayside 后再编辑这份存档。"))
        } else {
            content
        }
    }
}
