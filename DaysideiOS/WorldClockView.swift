// SPDX-License-Identifier: GPL-3.0-only
//
//  WorldClockView.swift
//  DaysideiOS
//
//  地点列表（每分钟刷新的当地时间、与本机的偏移、跨日「次日 / 前一日」）+ 城市搜索（复用 ZoneCatalog / Rust 索引）。
//  持久化用本 App 自己的 UserDefaults 键，与 macOS 版的偏好域无关。
//

import SwiftUI

@MainActor
@Observable
final class WorldClockStore {
    private static let key = "dayside.ios.places.v1"
    private(set) var places: [TimeZoneEntry]

    init(defaults: UserDefaults = .standard) {
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([TimeZoneEntry].self, from: data) {
            places = decoded.filter { TimeZone(identifier: $0.timezoneID) != nil }
        } else {
            places = []
        }
    }

    func add(_ option: ZoneOption) {
        guard !places.contains(where: { $0.timezoneID == option.identifier && $0.cityName == option.cityName }) else { return }
        places.append(TimeZoneEntry(zone: option))
        save()
    }
    func remove(at offsets: IndexSet) { places.remove(atOffsets: offsets); save() }
    /// 从 Mac 导入后的整份清单（合并或替换都在 PlacesTransfer 里算好）。
    func replaceAll(with entries: [TimeZoneEntry]) {
        places = entries.filter { TimeZone(identifier: $0.timezoneID) != nil }
        save()
    }
    func move(from source: IndexSet, to destination: Int) { places.move(fromOffsets: source, toOffset: destination); save() }

    private func save() {
        if let data = try? JSONEncoder().encode(places) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

struct WorldClockView: View {
    @State private var store = WorldClockStore()
    @State private var adding = false
    /// 导入页；系统交来 `dayside://import#dp1.…` 时带着链接文本直接打开。
    @State private var importing: String?? = nil

    var body: some View {
        NavigationStack {
            Group {
                if store.places.isEmpty {
                    ContentUnavailableView {
                        Label("还没有地点", systemImage: "globe")
                    } description: {
                        Text("添加一座城市，这里会显示它的当地时间。")
                    } actions: {
                        Button("添加地点") { adding = true }
                    }
                } else {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        List {
                            ForEach(store.places) { place in
                                PlaceRow(place: place, now: context.date)
                            }
                            .onDelete { store.remove(at: $0) }
                            .onMove { store.move(from: $0, to: $1) }
                        }
                    }
                }
            }
            .navigationTitle("Dayside")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { adding = true } label: { Label("添加地点", systemImage: "plus") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { importing = .some(nil) } label: { Label("从 Mac 导入", systemImage: "square.and.arrow.down") }
                }
                if !store.places.isEmpty {
                    ToolbarItem(placement: .topBarLeading) { EditButton() }
                }
            }
            .sheet(isPresented: $adding) {
                CitySearchView { option in
                    store.add(option)
                    adding = false
                }
            }
            .sheet(isPresented: Binding(get: { importing != nil }, set: { if !$0 { importing = nil } })) {
                ImportPlacesView(existing: store.places, initialText: importing ?? nil) { store.replaceAll(with: $0) }
            }
            .onOpenURL { url in
                // dayside://import#dp1.… ；解码在导入页里做，失败也在那页说。
                guard url.scheme == "dayside", url.host == "import" || url.path.hasPrefix("/import") || url.absoluteString.contains("import") else { return }
                importing = .some(url.absoluteString)
            }
        }
    }
}

struct PlaceRow: View {
    let place: TimeZoneEntry
    let now: Date

    private var timeZone: TimeZone { TimeZone(identifier: place.timezoneID) ?? .current }
    private var clock: String {
        TimeFormatting.string(for: now, in: timeZone, format: ClockFormat(hourStyle: .followSystem, showSeconds: false))
    }
    /// 与本机的整小时 / 半小时差，真减号；同一天以外标「次日 / 前一日」。
    private var offsetText: String {
        let seconds = timeZone.secondsFromGMT(for: now) - TimeZone.current.secondsFromGMT(for: now)
        if seconds == 0 { return "与本机相同" }
        let hours = Double(seconds) / 3600
        let magnitude = hours.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(abs(hours))) : String(format: "%.1f", abs(hours))
        return (seconds > 0 ? "+" : "−") + magnitude + " 小时"
    }
    private var dayCaption: String? {
        var local = Calendar.current; local.timeZone = .current
        var remote = Calendar.current; remote.timeZone = timeZone
        let a = local.startOfDay(for: now)
        let b = remote.dateComponents([.year, .month, .day], from: now)
        let remoteDayInLocal = local.date(from: b) ?? a
        let days = local.dateComponents([.day], from: a, to: remoteDayInLocal).day ?? 0
        switch days {
        case 1...: return "次日"
        case ..<0: return "前一日"
        default: return nil
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(place.displayName(localizedCity: CityNameLanguage.name(from: place.localizedNames ?? [:], locale: .current) ?? place.cityName)).font(.headline)
                Text(offsetText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if let dayCaption { Text(dayCaption).font(.caption2).foregroundStyle(.secondary) }
                Text(clock).font(.title2.monospacedDigit())
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct CitySearchView: View {
    let onSelect: (ZoneOption) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [ZoneOption] = []

    var body: some View {
        NavigationStack {
            List(results) { option in
                Button {
                    onSelect(option)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        // 城市名按界面语言（索引里的本地化名，Rust 选、CFStringTransform 归一简繁），没有就用主名。
                        Text(option.cityIndex.flatMap { CityNameLanguage.name(from: CityIndex.shared.localizedNames(cityIndex: $0), locale: .current) } ?? option.cityName)
                        let subtitle = option.subtitle(locale: .current)
                        if !subtitle.isEmpty {
                            Text(subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .foregroundStyle(.primary)
            }
            .overlay {
                if query.isEmpty {
                    ContentUnavailableView("搜索城市或时区", systemImage: "magnifyingglass",
                                           description: Text("235,740 座城市与全部 IANA 时区，离线可搜。"))
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .navigationTitle("添加地点")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "城市或时区")
            .onChange(of: query) { _, text in
                results = text.isEmpty ? [] : ZoneCatalog.shared.search(text, locale: .current, limit: 12)
            }
        }
    }
}
