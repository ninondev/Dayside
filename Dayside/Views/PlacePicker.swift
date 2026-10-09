// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

struct PlacePicker: View {
    @Environment(TimeCore.self) private var core
    let selectedID: UUID?
    let timeZoneID: String
    var includesThisMac = false
    let onSaved: (TimeZoneEntry) -> Void
    let onSearch: (ZoneOption) -> Void
    var onThisMac: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if includesThisMac, let onThisMac {
                Button { onThisMac() } label: {
                    Text(verbatim: String(format: L10n.string("本机（%@）", locale: core.uiLocale),
                        core.placeName(forTimeZoneID: TimeZone.current.identifier)))
                }.buttonStyle(.plain).frame(minHeight: 24)
            }
            if !core.zones.isEmpty {
                Text("已添加的地点").appFont(.caption).foregroundStyle(.readableSecondary)
                ForEach(core.zones) { place in
                    Button { onSaved(place) } label: {
                        HStack {
                            Text(verbatim: place.displayName(localizedCity: core.cityName(for: place)))
                            Spacer()
                            if place.id == selectedID || (selectedID == nil && place.timezoneID == timeZoneID) {
                                Image(systemName: "checkmark")
                            }
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).frame(minHeight: 24)
                }
                Divider()
            }
            Text("或搜索城市").appFont(.caption).foregroundStyle(.readableSecondary)
            AddZoneField(onSelect: onSearch)
        }
        .padding(12).frame(width: 340)
        .environment(\.locale, core.uiLocale)
    }
}
