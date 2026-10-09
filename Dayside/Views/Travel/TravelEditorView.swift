// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

struct TravelEditorView: View {
    @Environment(TimeCore.self) private var core
    @Environment(\.dismiss) private var dismiss
    let store: TravelStore
    let didSave: (UUID) -> Void
    var onRemove: (() -> Void)?
    @State private var trip: TravelTrip
    @State private var issues: [String] = []
    @State private var choosingOrigin = false
    @State private var choosingDestination = false

    init(store: TravelStore, trip: TravelTrip, didSave: @escaping (UUID) -> Void, onRemove: (() -> Void)? = nil) {
        self.store = store
        self.didSave = didSave
        self.onRemove = onRemove
        _trip = State(initialValue: trip)
    }
    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("旅行名称", text: $trip.name, prompt: Text(verbatim: destinationName))
                LabeledContent("出发地") {
                    HStack(spacing: 8) {
                        Text(verbatim: originName)
                        Button("更改…") { choosingOrigin = true }
                            .popover(isPresented: $choosingOrigin) { picker(origin: true) }
                    }
                }
                LabeledContent("目的地") {
                    HStack(spacing: 8) {
                        Text(verbatim: destinationName)
                        Button("更改…") { choosingDestination = true }
                            .popover(isPresented: $choosingDestination) { picker(origin: false) }
                    }
                }
                DatePicker(selection: $trip.departure, in: TravelTrip.supportedDates, displayedComponents: [.date, .hourAndMinute]) {
                    Text(verbatim: String(format: L10n.string("起飞（%@时间）", locale: core.uiLocale), originName))
                }
                .environment(\.timeZone, originZone).environment(\.calendar, Calendar.gregorianUTC(originZone))
                DatePicker(selection: $trip.arrival, in: TravelTrip.supportedDates, displayedComponents: [.date, .hourAndMinute]) {
                    Text(verbatim: String(format: L10n.string("落地（%@时间）", locale: core.uiLocale), destinationName))
                }
                .environment(\.timeZone, destinationZone).environment(\.calendar, Calendar.gregorianUTC(destinationZone))
                ForEach(issues, id: \.self) { ErrorLine(issueText($0)) }
            }
            .formStyle(.grouped).labeledContentStyle(.readable)
            HStack {
                if let onRemove, store.trips.contains(where: { $0.id == trip.id }) {
                    Button("移除这次旅行…", role: .destructive) { dismiss(); onRemove() }.disabled(store.storageReadOnly)
                }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    if trip.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { trip.name = destinationName }
                    issues = store.save(trip)
                    if issues.isEmpty { didSave(trip.id); dismiss() }
                }.keyboardShortcut(.defaultAction).disabled(store.storageReadOnly)
            }.padding()
        }
        .frame(minWidth: 500, idealWidth: 540, minHeight: 380, idealHeight: 420)
        .environment(\.locale, core.uiLocale)
    }
    private var originName: String { trip.placeName(origin: true, core: core) }
    private var destinationName: String { trip.placeName(origin: false, core: core) }
    private var originZone: TimeZone { TimeZone(identifier: trip.originTimeZoneID) ?? .gmt }
    private var destinationZone: TimeZone { TimeZone(identifier: trip.destinationTimeZoneID) ?? .gmt }
    private func picker(origin: Bool) -> some View {
        PlacePicker(selectedID: origin ? nil : trip.destinationPlaceID,
            timeZoneID: origin ? trip.originTimeZoneID : trip.destinationTimeZoneID, includesThisMac: origin,
            onSaved: { place in
                let snapshot = place.coordinate.map { TravelPlaceSnapshot(name: place.displayName(localizedCity: core.cityName(for: place)),
                    latitude: $0.latitude, longitude: $0.longitude, countryCode: place.countryCode) }
                if origin { trip.originTimeZoneID = place.timezoneID; trip.originPlace = snapshot; choosingOrigin = false }
                else { trip.destinationTimeZoneID = place.timezoneID; trip.destinationPlaceID = place.id; trip.destinationPlace = nil; choosingDestination = false }
            }, onSearch: { option in
                let snapshot = option.coordinate.map { TravelPlaceSnapshot(name: core.displayName(for: option),
                    latitude: $0.latitude, longitude: $0.longitude, countryCode: option.countryCode.isEmpty ? nil : option.countryCode) }
                if origin { trip.originTimeZoneID = option.identifier; trip.originPlace = snapshot; choosingOrigin = false }
                else { trip.destinationTimeZoneID = option.identifier; trip.destinationPlaceID = nil; trip.destinationPlace = snapshot; choosingDestination = false }
            }, onThisMac: {
                trip.originTimeZoneID = TimeZone.current.identifier
                trip.originPlace = nil
                choosingOrigin = false
            })
    }
    private func issueText(_ issue: String) -> Text {
        switch issue {
        case "name": Text("请选择目的地。")
        case "originTimeZone": Text("请选择出发地。")
        case "destinationTimeZone": Text("请选择目的地。")
        case "date": Text("请选择 1900 至 2199 年内的日期。")
        case "arrivalBeforeDeparture": Text("到达必须晚于或等于出发的实际时刻，请核对两地日期与时区。")
        case "sleepHours": Text("入睡和起床不能相同，请重新选择。")
        case "preparationDays", "dailyShift", "direction": Text("请重新选择行前安排。")
        case "readOnly": Text("请更新 Dayside 后再编辑这份存档。")
        default: Text("无法保存，请重新打开编辑。")
        }
    }
}
