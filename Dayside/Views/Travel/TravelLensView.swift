// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

struct TravelLensView: View {
    @Environment(TimeCore.self) private var core
    @Bindable var store: TravelStore
    @State private var selectedID: UUID?
    @State private var editing: TravelTrip?
    @State private var removing: TravelTrip?
    @State private var pendingRemoval: TravelTrip?
    @State private var selectionMemo = TravelSelectionMemo()

    private var selected: TravelTrip? {
        selectionMemo.prune(store.trips)
        return store.trips.first { $0.id == selectedID } ?? selectionMemo.choose(store.trips, at: core.referenceDate)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.storageReadOnly {
                Label("旅行存档版本较新，更新 Dayside 后再编辑。原始数据已保留。", systemImage: "lock")
                    .appFont(.callout).foregroundStyle(.readableSecondary).padding(.bottom, 10)
            } else if store.storageNeedsRecovery {
                Label("部分旅行数据无法读取。可用记录已恢复，原始数据会在编辑前另存备份。", systemImage: "exclamationmark.triangle")
                    .appFont(.callout).foregroundStyle(.readableSecondary).padding(.bottom, 10)
            }
            if let trip = selected {
                TravelPlanView(trip: trip, knownPlan: selectionMemo.plan(trip), store: store, selectedID: $selectedID, edit: { editing = trip }, add: addTrip)
                    .id(trip.id)
            } else {
                ContentUnavailableView {
                    Label("还没有旅行", systemImage: "airplane")
                } description: {
                    Text("添加一次旅行，这里会一晚一行画出几点睡、几点晒光。")
                        .foregroundStyle(.readableSecondary)
                } actions: {
                    Button("添加旅行", systemImage: "plus", action: addTrip).disabled(store.storageReadOnly)
                }
                autoSwitch.padding(.top, 28)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .toolbar { ToolbarItem { Button("添加旅行", systemImage: "plus", action: addTrip).disabled(store.storageReadOnly) } }
        .sheet(item: $editing, onDismiss: {
            if let pendingRemoval { removing = pendingRemoval; self.pendingRemoval = nil }
        }) { trip in
            TravelEditorView(store: store, trip: trip, didSave: { selectedID = $0 }, onRemove: { pendingRemoval = trip })
                .environment(core).environment(\.locale, core.uiLocale)
        }
        .confirmationDialog("移除这次旅行？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("移除旅行", role: .destructive) {
                if let removing { store.remove(id: removing.id) }
                removing = nil
            }
        }
        .onDisappear { store.deactivate() }
    }
    private var autoSwitch: some View { TravelAutoSwitch(store: store) }
    private func addTrip() {
        let destination = core.zones.first(where: { $0.timezoneID != TimeZone.current.identifier })
        let calendar = Calendar.gregorianUTC(.current)
        let day = calendar.date(byAdding: .day, value: 7, to: core.referenceDate) ?? core.referenceDate
        let departure = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: day) ?? day
        editing = TravelTrip(name: "", originTimeZoneID: TimeZone.current.identifier,
            destinationTimeZoneID: destination?.timezoneID ?? TimeZone.current.identifier,
            destinationPlaceID: destination?.id, departureUnix: departure.timeIntervalSince1970,
            arrivalUnix: departure.addingTimeInterval(3_600).timeIntervalSince1970)
    }
}

@MainActor
private final class TravelSelectionMemo {
    private var ranges: [TravelTrip: ClosedRange<Double>] = [:]
    private var plans: [TravelTrip: TravelPlan] = [:]
    func plan(_ trip: TravelTrip) -> TravelPlan {
        plans = plans.filter { $0.key.id != trip.id || $0.key == trip }
        ranges = ranges.filter { $0.key.id != trip.id || $0.key == trip }
        if let cached = plans[trip] { return cached }
        let computed = trip.plan()
        plans[trip] = computed
        return computed
    }
    func prune(_ trips: [TravelTrip]) {
        let present = Set(trips)
        ranges = ranges.filter { present.contains($0.key) }
        plans = plans.filter { present.contains($0.key) }
    }
    func choose(_ trips: [TravelTrip], at reference: Date) -> TravelTrip? {
        prune(trips)
        for trip in trips where ranges[trip] == nil {
            let origin = TimeZone(identifier: trip.originTimeZoneID) ?? .gmt
            let destination = TimeZone(identifier: trip.destinationTimeZoneID) ?? .gmt
            let home = Calendar.gregorianUTC(origin), there = Calendar.gregorianUTC(destination)
            let summary = plan(trip).summary
            let first: Double
            if summary?.targetShiftMinutes != 0, let relative = summary?.rows.first?.relativeDay {
                let firstDay = home.date(byAdding: .day, value: relative, to: trip.departure) ?? trip.departure
                first = TravelNightFacts.frame(on: firstDay, in: origin).start
            } else { first = TravelNightFacts.frame(containing: trip.departure, in: origin).start }
            let lastOffset = summary?.arrivalRows.last?.dayAfterArrival ?? 0
            let lastDay = there.date(byAdding: .day, value: lastOffset, to: trip.arrival) ?? trip.arrival
            let last = TravelNightFacts.frame(on: lastDay, in: destination).end
            if first <= last { ranges[trip] = first...last }
        }
        if let active = trips.sorted(by: { $0.departure < $1.departure }).first(where: { ranges[$0]?.contains(reference.timeIntervalSince1970) == true }) { return active }
        return trips.filter { $0.departure >= reference }.min(by: { $0.departure < $1.departure })
            ?? trips.max(by: { $0.arrival < $1.arrival })
    }
}

private struct TravelPlanView: View {
    @Environment(TimeCore.self) private var core
    @Environment(AppModel.self) private var model
    @Environment(\.textScale) private var textScale
    @Environment(\.accessibilityDifferentiateWithoutColor) private var marks
    let trip: TravelTrip
    let knownPlan: TravelPlan
    let store: TravelStore
    @Binding var selectedID: UUID?
    let edit: () -> Void
    let add: () -> Void
    @State private var memo = TravelNightsMemo()
    @State private var selectedNight = 0
    /// 新增固定时刻的表单（名字 + 家里的时刻）。
    @State private var addingFixedTime = {
        #if DEBUG
        return ApplicationSession.isTesting && ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_COPY_FIXED_TIME"] == "1"
        #else
        return false
        #endif
    }()
    @State private var newLabel = {
        #if DEBUG
        if ApplicationSession.isTesting && ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_COPY_FIXED_LIMIT"] == "1" {
            return String(repeating: "x", count: 41)
        }
        #endif
        return ""
    }()
    @State private var newTime = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: .now) ?? .now
    @State private var copiedStatus = false
    @State private var isAddingToCalendar = false
    @State private var calendarFeedback: PresentationCore.PlannerMessage?

    var body: some View {
        let _ = memo.update(trip: trip, origin: trip.coordinate(origin: true, places: core.zones),
                            destination: trip.coordinate(origin: false, places: core.zones), reference: core.referenceDate, marks: marks, knownPlan: knownPlan)
        VStack(alignment: .leading, spacing: 0) {
            subject
            if let summary = memo.plan?.summary {
                Text(verbatim: summaryText(summary)).appFont(.callout).padding(.top, 6)
                if showsLongEastwardNote(summary) {
                    Label("往东跨 8 小时以上，按往后挪安排：身体常常是这样调过来的。", systemImage: "exclamationmark.triangle")
                        .appFont(.caption).foregroundStyle(.readableSecondary).padding(.top, 4)
                }
                if summary.offsetChangesDuringTravel {
                    Label("行程期间有时区偏移变化，已按到达时刻计算。", systemImage: "exclamationmark.triangle")
                        .appFont(.caption).foregroundStyle(.readableSecondary).padding(.top, 4)
                }
                if !memo.nights.lanes.isEmpty {
                    TravelNightsView(trip: trip, nights: memo.nights, art: memo.art, selected: $selectedNight).padding(.top, 18)
                    TravelNightDetail(trip: trip, lane: memo.nights.lanes[min(max(selectedNight, 0), memo.nights.lanes.count - 1)]).padding(.top, 18)
                } else { ErrorLine(Text("无法生成这次旅行的作息表，请检查时区、日期和睡眠时间。")).padding(.top, 18) }
                TravelPlanMenus(trip: trip, store: store, summary: summary).padding(.top, 28)
                fixedTimeSection.padding(.top, 28)
                statusSection(summary).padding(.top, 28)
                TravelAutoSwitch(store: store).padding(.top, 28)
                if TravelFooterAdvice.showsAdvice(lanes: memo.nights.lanes) {
                    TravelFooter(direction: summary.direction).padding(.top, 28)
                }
            } else {
                ErrorLine(Text("无法生成这次旅行的作息表，请检查时区、日期和睡眠时间。")).padding(.top, 18)
                TravelAutoSwitch(store: store).padding(.top, 28)
            }
        }
        .onAppear { selectedNight = memo.nights.selected }
        .onChange(of: memo.revision) { selectedNight = memo.nights.selected }
    }
    private var subject: some View {
        TrailingWrapLayout(spacing: 8) {
            SubjectFlowLayout {
                Menu {
                    ForEach(store.trips.sorted(by: { $0.departure < $1.departure })) { option in
                        Button { selectedID = option.id } label: {
                            let text = option.name + " · " + option.placeName(origin: true, core: core) + " → " + option.placeName(origin: false, core: core) + " · " + departureDay(option, weekday: false)
                            if option.id == trip.id { Label(text, systemImage: "checkmark") }
                            else { Text(verbatim: text) }
                        }
                    }
                    Divider()
                    Button("添加旅行…", action: add).disabled(store.storageReadOnly)
                } label: {
                    HStack(spacing: 4) {
                        let text = trip.placeName(origin: true, core: core) + " → " + trip.placeName(origin: false, core: core)
                        Text(verbatim: text).font(SerifFace.font(text, size: 17 * textScale, weight: .medium, locale: core.uiLocale))
                        Image(systemName: "chevron.down").font(.system(size: 9)).accessibilityHidden(true)
                    }.frame(minHeight: 24)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                .accessibilityLabel(Text("行程"))
                .accessibilityValue(Text(verbatim: String(format: L10n.string("%1$@到%2$@", locale: core.uiLocale), trip.placeName(origin: true, core: core), trip.placeName(origin: false, core: core)) + ", " + departureDay(trip)))
                SubjectDot()
                Text(verbatim: departureDay(trip)).appFont(.title3)
            }
            Button("编辑…", action: edit).disabled(store.storageReadOnly)
        }
    }
    private func departureDay(_ trip: TravelTrip, weekday: Bool = true) -> String {
        ClockText.day(trip.departure, in: TimeZone(identifier: trip.originTimeZoneID) ?? .gmt,
                      locale: core.uiLocale, now: core.now, weekday: weekday)
    }
    private func summaryText(_ summary: TravelPlan.Summary) -> String {
        if summary.targetShiftMinutes == 0 { return L10n.string("两地钟面一致，不需要按光照调整。", locale: core.uiLocale) }
        let relative = PanelRowDetail.fullRelative(timeZone: TimeZone(identifier: trip.destinationTimeZoneID) ?? .gmt,
            at: trip.arrival, locale: core.uiLocale, home: TimeZone(identifier: trip.originTimeZoneID) ?? .gmt) ?? ""
        let shift = String(format: L10n.string(summary.targetShiftMinutes > 0 ? "作息往后挪 %@" : "作息往前挪 %@", locale: core.uiLocale),
                           duration(Double(abs(summary.targetShiftMinutes))))
        return [trip.placeName(origin: false, core: core), relative, shift].filter { !$0.isEmpty }.joined(separator: " · ")
    }
    private func showsLongEastwardNote(_ summary: TravelPlan.Summary) -> Bool {
        let east = ((summary.offsetDifferenceSeconds / 60) % 1440 + 1440) % 1440
        return trip.direction == "automatic" && east >= 480 && east < 720
    }
    // MARK: - 固定时刻

    @ViewBuilder private var fixedTimeSection: some View {
        let times = model.settings.fixedTimes
        let converted = TravelFixedTimeConverter.rows(times: times, trip: trip)
        VStack(alignment: .leading, spacing: 6) {
            Text("固定时刻").appFont(.headline).accessibilityAddTraits(.isHeader)
            if times.isEmpty {
                Text("写下每天固定要做的事（吃药、和家里通话、打卡…），这里按行程把它们换算成目的地当地时间。")
                    .appFont(.callout).foregroundStyle(.readableSecondary)
            } else {
                ForEach(converted.rows) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        LabeledContent {
                            HStack(spacing: 4) {
                                if row.segments.first?.night == true { Image(systemName: "moon.zzz").font(.caption).foregroundStyle(.orange).accessibilityHidden(true) }
                                Text(verbatim: trip.placeName(origin: false, core: core)).font(SerifFace.font(trip.placeName(origin: false, core: core), size: 13 * textScale, weight: .regular, locale: core.uiLocale))
                                Text(verbatim: segmentText(row.segments.first))
                            }
                                .monospacedDigit()
                        } label: {
                            Text(verbatim: row.label)
                            Text(verbatim: String(format: L10n.string("家里 %@", locale: core.uiLocale),
                                                  wallTime(row.homeMinute)))
                                .appFont(.caption).foregroundStyle(.readableSecondary)
                        }
                        // 目的地在这一周里换钟的话，后面几天是另一个钟点。
                        ForEach(row.segments.dropFirst(), id: \.self) { segment in
                            Text(verbatim: String(format: L10n.string("%1$@ 起 %2$@", locale: core.uiLocale),
                                                  localizedDay(segment.fromDate), segmentText(segment)))
                                .appFont(.caption).foregroundStyle(.readableSecondary)
                        }
                    }
                    .contextMenu {
                        Button("移除固定时刻", systemImage: "trash") { removeFixedTime(row.id) }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: fixedTimeAccessibility(row)))
                    .accessibilityAddTraits(.isStaticText)
                }
            }
            Button("添加固定时刻…", systemImage: "plus") { addingFixedTime = true }
                .disabled(times.count >= 8)
            Text("只换算，不建议改时间；表中是到达日起一周内的目的地当地时间。")
                .appFont(.caption).foregroundStyle(.readableSecondary)
        }
        .sheet(isPresented: $addingFixedTime) {
            fixedTimeSheet
                .environment(model).environment(core).environment(\.locale, core.uiLocale)
        }
    }

    @ViewBuilder private var fixedTimeSheet: some View {
        let exceedsLimits = newLabel.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count > 40
            || model.settings.fixedTimes.count >= 8
        Form {
            TextField("名称", text: $newLabel, prompt: Text("服药"))
                .accessibilityLabel(Text("名称"))
                .help(Text("最多40个字符，最多8条"))
                .accessibilityHint(Text("最多40个字符，最多8条"))
            DatePicker("家里的时刻", selection: $newTime, displayedComponents: .hourAndMinute)
            if exceedsLimits { ErrorLine(Text("最多40个字符，最多8条")) }
        }
        .formStyle(.grouped)
        .frame(width: 320)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("取消") { addingFixedTime = false }
                Spacer()
                Button("添加") { addFixedTime() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(exceedsLimits || newLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
    }

    private func addFixedTime() {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: newTime)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        var times = model.settings.fixedTimes
        times.append(TravelFixedTime(id: UUID(), label: newLabel.trimmingCharacters(in: .whitespacesAndNewlines),
                                     minute: minute))
        model.settings.fixedTimes = times
        newLabel = ""
        addingFixedTime = false
    }

    private func removeFixedTime(_ id: UUID) {
        model.settings.fixedTimes = model.settings.fixedTimes.filter { $0.id != id }
    }

    private func fixedTimeAccessibility(_ row: TravelFixedTimeRows.Row) -> String {
        var words = [row.label, String(format: L10n.string("家里 %@", locale: core.uiLocale), wallTime(row.homeMinute)), trip.placeName(origin: false, core: core)]
        for (index, segment) in row.segments.enumerated() {
            words.append(index == 0 ? segmentText(segment) : String(format: L10n.string("%1$@ 起 %2$@", locale: core.uiLocale), localizedDay(segment.fromDate), segmentText(segment)))
            if segment.night { words.append(L10n.string("在夜里", locale: core.uiLocale)) }
        }
        return words.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// 一段的当地钟点：跨日的写「次日 / 前一日」。
    private func segmentText(_ segment: TravelFixedTimeRows.Segment?) -> String {
        guard let segment else { return "" }
        let clock = wallTime(segment.minute)
        switch segment.dayOffset {
        case 1: return String(format: L10n.string("次日 %@", locale: core.uiLocale), clock)
        case -1: return String(format: L10n.string("前一日 %@", locale: core.uiLocale), clock)
        default: return clock
        }
    }

    /// 「2026-10-25」→ 按界面语言的日期写法。
    private func localizedDay(_ iso: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: trip.originTimeZoneID) ?? .current
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: iso) else { return iso }
        return ClockText.day(date, in: parser.timeZone, locale: core.uiLocale, now: core.now)
    }

    // MARK: - 一行状态文本 + 「不工作」阻塞事件

    @ViewBuilder private func statusSection(_ summary: TravelPlan.Summary) -> some View {
        let availability = core.settings.planner.localAvailability
        let line = statusLine(summary, availability: availability)
        VStack(alignment: .leading, spacing: 6) {
            Text("告诉别人我在哪").appFont(.headline).accessibilityAddTraits(.isHeader)
            if !line.text.isEmpty {
                Text(verbatim: line.text).appFont(.callout).textSelection(.enabled)
                HStack {
                    Button(copiedStatus ? "已复制" : "复制这一行", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(line.text, forType: .string)
                        copiedStatus = true
                        AccessibilityNotification.Announcement(L10n.string("已复制", locale: core.uiLocale)).post()
                    }
                    Spacer()
                }
                .frame(minHeight: 24)
            }
            Button(isAddingToCalendar ? "正在加入…" : "把不工作的时段加进日历", systemImage: "calendar.badge.plus") {
                Task { await addAwayBlocks(availability: availability) }
            }
            .disabled(isAddingToCalendar)
            .frame(minHeight: 24)
            .help(Text("按你在「找碰头时间」里设的工作时段算：到达日起一周，工作时段之外都做成日历事件，当地休息日整天。"))
            .accessibilityHint(Text("按你在「找碰头时间」里设的工作时段算：到达日起一周，工作时段之外都做成日历事件，当地休息日整天。"))
            if let calendarFeedback {
                calendarFeedbackText(calendarFeedback).appFont(.caption)
            }
        }
        .accessibilityIdentifier("travel-status")
        .task(id: copiedStatus) {
            guard copiedStatus else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            copiedStatus = false
        }
    }

    private func statusLine(_ summary: TravelPlan.Summary, availability: Availability) -> TravelStatusLine {
        let destination = TimeZone(identifier: trip.destinationTimeZoneID) ?? .current
        let origin = TimeZone(identifier: trip.originTimeZoneID) ?? .current
        let difference = destination.secondsFromGMT(for: trip.arrival) - origin.secondsFromGMT(for: trip.arrival)
        let homeStart = availability.startMinute - difference / 60
        let homeEnd = availability.endMinute - difference / 60
        return TravelStatusLine.make(
            place: trip.placeName(origin: false, core: core),
            // macOS 26 会把没有缩写的时区回成「GMT+9」：那种就不写缩写，只留偏移。
            zoneAbbreviation: {
                let raw = ZoneNameDisplay.abbreviation(destination, at: trip.arrival,
                    offsetOnly: trip.destinationOffsetOnly(places: core.zones))
                return raw.hasPrefix("GMT") || raw.hasPrefix("UTC") ? "" : raw
            }(),
            offsetText: UnderstandingText.offset(destination.secondsFromGMT(for: trip.arrival)),
            localWindowText: "\(wallTime(availability.startMinute))–\(wallTime(availability.endMinute))",
            // 家里那一段跨了午夜就给终点标「次日」（「9:00–18:00 = 17:00–次日 2:00」）。
            counterpartWindowText: {
                let start = wrapped(homeStart)
                let end = wrapped(homeEnd)
                let endText = end <= start
                    ? String(format: L10n.string("次日 %@", locale: core.uiLocale), wallTime(end))
                    : wallTime(end)
                return trip.placeName(origin: true, core: core) + " " + ClockText.range(wallTime(start), endText)
            }(), locale: core.uiLocale)
    }

    /// 把可能越界的墙钟分钟折回 0 ..< 1440（家里那边的同一段可能落在前一天或次日）。
    private func wrapped(_ minute: Int) -> Int { ((minute % 1440) + 1440) % 1440 }

    /// 目的地所在国家 / 地区：从已保存的地点里找同一时区的那一条（用来判当地周末）。
    private var destinationCountryCode: String? {
        trip.countryCode(places: core.zones)
    }

    @ViewBuilder private func calendarFeedbackText(_ feedback: PresentationCore.PlannerMessage) -> some View {
        switch feedback.kind {
        case "added": Label("已加入日历「\(feedback.title ?? "")」", systemImage: "checkmark.circle")
        case "openedICS": Label("已交给日历 app 打开", systemImage: "arrow.up.forward.app")
        case "failed": ErrorLine(Text("加入日历失败。请在系统设置的「隐私与安全性 › 日历」里检查权限后再试。"))
        default: EmptyView()
        }
    }

    private func addAwayBlocks(availability: Availability) async {
        guard !isAddingToCalendar else { return }
        isAddingToCalendar = true
        defer { isAddingToCalendar = false }
        let place = trip.placeName(origin: false, core: core)
        let events = TravelAwayBlocks.events(trip: trip, availability: availability, placeName: place,
                                             countryCode: destinationCountryCode,
                                             locale: core.uiLocale,
                                             footer: L10n.string("用 Dayside 生成", locale: core.uiLocale))
        guard !events.isEmpty else {
            calendarFeedback = .init(kind: "failed")
            return
        }
        switch await CalendarExporter.export(series: events) {
        case let .added(title): calendarFeedback = .init(kind: "added", title: title)
        case .openedICS: calendarFeedback = .init(kind: "openedICS")
        case .failed: calendarFeedback = .init(kind: "failed")
        }
    }

    private func wallTime(_ minute: Int) -> String { ClockText.minute(minute, hourStyle: core.settings.hourStyle) }
    private func duration(_ minutes: Double) -> String { ClockText.duration(seconds: minutes * 60, locale: core.uiLocale) }
}

private struct TravelAutoSwitch: View {
    let store: TravelStore
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("系统时区变化时置顶对应地点", isOn: Binding(get: { store.autoSwitchEnabled }, set: { store.setAutoSwitchEnabled($0) }))
                .disabled(store.storageReadOnly)
                .help(Text("没有对应的地点时，顺序不变"))
                .accessibilityHint(Text("没有对应的地点时，顺序不变"))
        }
    }
}

/// 医疗说明脚注只在页面真的画出睡觉或光照建议（睡觉/晒光/避光任一）时出现；
/// 同钟之旅、画不出作息表的行程没有建议，就不出现。
enum TravelFooterAdvice {
    static func showsAdvice(lanes: [TravelNights.Lane]) -> Bool {
        lanes.contains { $0.sleep != nil || !$0.seek.isEmpty || !$0.avoid.isEmpty }
    }
}

private struct TravelFooter: View {
    let direction: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("光照时段按公开的昼夜节律研究估算（体温最低点取起床前约 3 小时），是参考，不是医疗建议；身体反应因人而异。")
            Text("本页不提供褪黑素、安眠药或咖啡因建议。有睡眠障碍、双相情感障碍、光敏感或眼部疾病者，调整作息与强光暴露前请咨询医生。")
            DisclosureGroup("说明与依据") {
                VStack(alignment: .leading, spacing: 6) {
                    if direction == "delay" {
                        Text("目标是把身体的钟拨晚：体温最低点之前的光拨晚，之后的光拨早，所以晚上晒光、早上避光。出发前几晚在出发地照着做，到了以后按当地时间接着做。")
                    } else if direction == "advance" {
                        Text("目标是把身体的钟拨早：体温最低点之后的光拨早，之前的光拨晚，所以要等过了最低点再晒早上的光、晚上调暗。出发前几晚在出发地照着做，到了以后按当地时间接着做。")
                    }
                    Text("每晚按你选的量把估计的体温最低点往目标挪，剩下不到 1 小时就不再画；时段整段落在睡觉里的就不画。这里不预测要几天才能适应。")
                    Link("参考：Eastman & Burgess 2009，时差与光照时机", destination: URL(string: "https://pmc.ncbi.nlm.nih.gov/articles/PMC2829880/")!)
                        .foregroundStyle(.primary)
                    Link("参考：CDC 旅行与时差", destination: URL(string: "https://www.cdc.gov/yellow-book/hcp/travel-air-sea/jet-lag-disorder.html")!)
                        .foregroundStyle(.primary)
                }
            }
        }.appFont(.caption).foregroundStyle(.readableSecondary)
    }
}
