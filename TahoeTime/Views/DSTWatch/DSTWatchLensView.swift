// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

struct DSTWatchLensView: View {
    @Environment(TimeCore.self) private var core
    @Environment(\.featureHub) private var featureHub
    @Bindable var store: DSTWatchStore
    @State private var dataReport: TZDataCheck.Report?
    @State private var clockChanges: [DSTClockChange] = []
    @State private var calendarFeedback: PresentationCore.PlannerMessage?
    @State private var isAddingToCalendar = false
    /// 各地与本机的时差变化窗口：只列未来 12 个月里时差会变的地点。
    @State private var offsetReports: [OffsetPlaceReport] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 内容在前、开关在后：这一页是来看「各地什么时候换钟」的，提醒是附带的选项；
            // 此前第一行是开关，列表排在开关与它的说明之后。
            Text("各地下一次时钟调整").appFont(.headline).accessibilityAddTraits(.isHeader)
            if store.state.enabled {
                if core.zones.isEmpty {
                    Text("还没有地点").foregroundStyle(.readableSecondary)
                } else if store.upcoming.isEmpty {
                    Text("暂未查到这些地点的下一次时钟调整。").foregroundStyle(.readableSecondary)
                } else {
                    ForEach(store.upcoming) { event in
                        // 卡片只用 GroupBox（不自定义圆角）。
                        GroupBox {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(verbatim: store.displayName(for: event)).appFont(.headline)
                                Text("当地时间 \(localDate(event))").appFont(.callout)
                                Text(verbatim: "\(event.beforeLabel) → \(event.afterLabel)").monospacedDigit()
                                shiftText(event.shift).appFont(.caption)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if store.upcoming.count > store.noticeLimit {
                        Text("系统提醒只安排最近 \(store.noticeLimit) 次变化。").appFont(.caption).foregroundStyle(.readableSecondary)
                    }
                }
            } else {
                let preview = upcomingPreview
                if core.zones.isEmpty {
                    // 没有保存地点时保留本机预览行与简短空态。
                    Text("还没有地点").appFont(.caption).foregroundStyle(.readableSecondary)
                }
                if !preview.isEmpty {
                    ForEach(preview, id: \.zone) { row in
                        HStack(alignment: .firstTextBaseline) {
                            // 没有地点时列出的本机那一行写「本机（洛杉矶）」，与排会页同一拼法。
                            Text(verbatim: core.zones.isEmpty && row.zone == TimeZone.current.identifier
                                 ? String(format: L10n.string("本机（%@）", locale: core.uiLocale), core.placeName(forTimeZoneID: row.zone))
                                 : core.placeName(forTimeZoneID: row.zone))
                            Spacer()
                            if let fact = row.fact {
                                Text(verbatim: previewDate(fact)).appFont(.callout).monospacedDigit().foregroundStyle(.readableSecondary)
                                shiftText(fact.after - fact.before).appFont(.caption)
                            } else {
                                // 不换钟的地点也列出来，免得用户以为少了一个。
                                Text("不调整").appFont(.callout).foregroundStyle(.readableSecondary)
                            }
                        }
                    }
                }
            }
            // 提醒开关与它的设置：列表之后、其余各节之前。
            Divider()
            Toggle("已保存地点的时钟调整提醒", isOn: Binding(get: { store.state.enabled }, set: { store.setEnabled($0) }))
                .help(Text("开着时每天检查一次，Mac唤醒或改时间时也会更新"))
                .accessibilityHint(Text("开着时每天检查一次，Mac唤醒或改时间时也会更新"))
                .modifier(LensNotificationValue(access: store.notifications.access))
            if store.state.enabled {
                Picker("提前提醒", selection: Binding(get: { store.state.leadSeconds }, set: { store.setLeadSeconds($0) })) {
                    Text("1 小时").tag(3600)
                    Text("1 天").tag(86400)
                    Text("1 周").tag(604800)
                }
                LensNotificationStatusView(notifications: store.notifications,
                                           requestPermission: { await store.requestNotificationPermission() }, retry: store.refresh)
                Button("刷新时钟调整", action: store.refresh)
            }
            if !clockChanges.isEmpty { calendarSection }
            if !core.zones.isEmpty { offsetSection }
            if store.recovered {
                Label("提醒设置无法读取，已备份原始数据并保持关闭。", systemImage: "exclamationmark.triangle")
                    .appFont(.caption).foregroundStyle(.readableSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let dataReport { tzdataSection(dataReport) }
        }
        .onAppear(perform: configure)
        .onChange(of: core.zones) { configure() }
        .onChange(of: core.uiLocale.identifier) { configure() }
        .onChange(of: core.systemRevision) { configure() }
        .onChange(of: calendarZones) { clockChanges = DSTCalendarPlan.changes(zones: calendarZones, from: core.now) }
        .onChange(of: core.zones.map(\.timezoneID)) { refreshOffsets() }
        .onAppear(perform: refreshOffsets)
        .onChange(of: core.systemRevision) { refreshOffsets() }
    }

    // MARK: - 与本机的时差变化

    private func refreshOffsets() {
        offsetReports = OffsetWindows.reports(places: core.zones.map(\.timezoneID), now: core.now)
    }

    /// 两地不在同一天换钟时，中间那几天的时差是另一个数，排跨时区例会最容易在这里踩空。
    @ViewBuilder private var offsetSection: some View {
        let changing = offsetReports.filter { !$0.changes.isEmpty }
        Divider()
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("与本机的时差变化").appFont(.headline).accessibilityAddTraits(.isHeader)
            }
            if changing.isEmpty {
                Text("未来 12 个月各地与本机的时差都不变。").foregroundStyle(.readableSecondary)
            } else {
                ForEach(changing) { report in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: core.placeName(forTimeZoneID: report.zone)).appFont(.callout, weight: .semibold)
                        ForEach(report.changes) { change in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(verbatim: offsetDate(change.date, zone: report.zone)).monospacedDigit()
                                Text(verbatim: "\(offsetDifference(change.from)) → \(offsetDifference(change.to))").monospacedDigit()
                                causeText(change.cause, zone: report.zone).appFont(.caption).foregroundStyle(.readableSecondary)
                            }
                        }
                    }
                }
            }
        }
    }

    /// 「快 8 小时」「慢 3 小时 30 分钟」「同一时间」，时差按对方减本机。
    private func offsetDifference(_ seconds: Int) -> String {
        Self.difference(seconds, locale: core.uiLocale)
    }

    static func difference(_ seconds: Int, locale: Locale) -> String {
        guard seconds != 0 else { return L10n.string("同一时间", locale: locale) }
        let amount = ClockText.duration(seconds: Double(abs(seconds)), locale: locale)
        return String(format: L10n.string(seconds > 0 ? "快 %@" : "慢 %@", locale: locale), amount)
    }

    /// 放不下整句时的短写：面板行放不下时那一种「+8h」「−3h30m」（Rust `presentation.scroll_label`）；同一时间没有短写。
    static func compactDifference(_ seconds: Int) -> String? {
        seconds == 0 ? nil : PresentationCore.call("scroll_label", ["seconds": Double(seconds)])
    }

    static func list(_ items: [String], locale: Locale) -> String {
        let formatter = ListFormatter()
        formatter.locale = locale
        return formatter.string(from: items) ?? items.joined(separator: ", ")
    }


    @ViewBuilder private func causeText(_ cause: String, zone: String) -> some View {
        switch cause {
        case "local": Text("本机换钟")
        case "both": Text("两边同时换钟")
        default: Text("\(core.placeName(forTimeZoneID: zone))换钟")
        }
    }

    /// 拨钟量使用方向时长，介词与变格按界面语言。
    @ViewBuilder private func shiftText(_ seconds: Int) -> some View {
        let amount = Text(verbatim: ClockText.directionalDuration(seconds: Double(abs(seconds)), locale: core.uiLocale))
        if seconds > 0 { Text("拨快 \(amount)") } else { Text("拨慢 \(amount)") }
    }

    // MARK: - 把换钟加进日历

    /// 要算换钟的地点:时钟列表 + 人物,按 IANA 标识符去重(同一座城市的两个人只算一次)。
    private var calendarZones: [String] {
        var seen: Set<String> = []
        return (core.zones.map(\.timezoneID) + (featureHub?.peoplePlaces.map(\.timeZoneID) ?? []))
            .filter { seen.insert($0).inserted }
    }

    /// 未来 12 个月的每一次时钟调整做成日历事件。一次全写进日历,写不进就交一份含多场的 .ics。
    @ViewBuilder private var calendarSection: some View {
        Divider()
        VStack(alignment: .leading, spacing: 8) {
            // 保留旧分区结构，日历事件的时长细节放在按钮的悬停提示。
            VStack(alignment: .leading, spacing: 2) {
                Text("未来 12 个月的时钟调整").appFont(.headline).accessibilityAddTraits(.isHeader)
            }
            Button {
                Task { await addChangesToCalendar() }
            } label: {
                Label("把时钟调整加进日历（\(clockChanges.count) 次）", systemImage: "calendar.badge.plus")
                    .frame(minHeight: 20)   // 命中区域不小于 16 pt(无障碍规则 R3)
                    .contentShape(Rectangle())
            }
            .disabled(isAddingToCalendar)
            .help(Text("每次调整添加为 1 小时的日历事件，备注写明当地时间的变化。"))
            if let calendarFeedback { calendarFeedbackText(calendarFeedback).appFont(.caption) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("dst-calendar")
    }

    @ViewBuilder private func calendarFeedbackText(_ feedback: PresentationCore.PlannerMessage) -> some View {
        switch feedback.kind {
        case "added": Label("已加入日历「\(feedback.title ?? "")」", systemImage: "checkmark.circle")
        case "openedICS": Label("已交给日历 app 打开", systemImage: "arrow.up.forward.app")
        // 这一页没有「复制」按钮，失败句只指权限。
        case "failed": ErrorLine(Text("加入日历失败。请在系统设置的「隐私与安全性 › 日历」里检查权限后再试。"))
        default: EmptyView()
        }
    }

    private func addChangesToCalendar() async {
        guard !isAddingToCalendar, !clockChanges.isEmpty else { return }
        isAddingToCalendar = true
        defer { isAddingToCalendar = false }
        // 地名走 `TimeCore.placeName` 这个统一出口,界面与事件标题用同一个名字。
        let names = Dictionary(clockChanges.map { ($0.zone, core.placeName(forTimeZoneID: $0.zone)) },
                               uniquingKeysWith: { first, _ in first })
        let events = DSTCalendarPlan.events(changes: clockChanges, names: names,
                                            locale: core.uiLocale, hourStyle: core.settings.hourStyle)
        switch await CalendarExporter.export(series: events) {
        case let .added(title): calendarFeedback = .init(kind: "added", title: title)
        case .openedICS: calendarFeedback = .init(kind: "openedICS")
        case .failed: calendarFeedback = .init(kind: "failed")
        }
    }

    /// 本机时区数据是否落后于已知的规则变更:Rust 出题(变更后的一个时刻与应有偏移),Foundation 答题。
    /// 只是一段说明,不改任何钟;用户保存的地点若在过期名单里排在前面。
    /// 一切正常时只在页面末尾留一行「时区数据是最新的（2026c）。」，版本与条数进悬停提示；
    /// 落后时才展开成带标题的分区并逐条点名。快捷指令「检查时区数据」仍返回完整两句。
    @ViewBuilder private func tzdataSection(_ report: TZDataCheck.Report) -> some View {
        Divider()
        let version = report.version ?? L10n.string("版本未知", locale: core.uiLocale)
        if Self.showsCurrentDataStatus(report) {
            Text("时区数据与已知规则变更一致")
                .appFont(.caption).foregroundStyle(.readableSecondary)
                .help(Text("本机时区数据 \(version)，与截至 \(report.coverage) 的 \(report.checked) 条已知规则变更一致。数据由 macOS 提供，随系统更新。"))
                .accessibilityHint(Text("本机时区数据 \(version)，与截至 \(report.coverage) 的 \(report.checked) 条已知规则变更一致。数据由 macOS 提供，随系统更新。"))
        } else if !report.stale.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("时区数据检查").appFont(.headline).accessibilityAddTraits(.isHeader)
                Label("本机时区数据 \(version) 可能过期：\(report.stale.count) 条已知规则变更未反映。", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.readableSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let mine = Set(core.zones.map(\.timezoneID))
            let ordered = report.stale.sorted { (mine.contains($1.zone) ? 1 : 0, $0.zone) < (mine.contains($0.zone) ? 1 : 0, $1.zone) }
            ForEach(ordered) { item in
                Text("\(core.placeName(forTimeZoneID: item.zone))：自 \(item.since) 起应为 \(TZDataCheck.offsetLabel(item.expectedMinutes))，本机数据给出 \(TZDataCheck.offsetLabel(item.observedMinutes))。")
                    .appFont(.callout)
            }
            Text("时区数据由 macOS 提供，随系统更新。已知规则变更收录至 \(report.coverage)。")
                .appFont(.caption).foregroundStyle(.readableSecondary)
        }
    }

    static func showsCurrentDataStatus(_ report: TZDataCheck.Report) -> Bool {
        report.stale.isEmpty && report.unknown.isEmpty
    }

    /// 关闭状态下的只读快照里的一行：有下一次调整的地点带事实，不换钟的地点 `fact == nil`。
    private struct PreviewRow {
        let zone: String
        let fact: DSTTransitionFact?
    }

    /// 关闭状态下的一次性只读快照:每个地点未来 400 天内的第一次调整，按时刻排序；
    /// 没有调整的地点排在后面（也列出来，用户才知道它不是漏了）。不安排任何提醒或周期任务。
    private var upcomingPreview: [PreviewRow] {
        var seen: Set<String> = []
        // 只读列表与「把时钟调整加进日历（N 次）」同一口径：地点加人物所在地（按钮说 6 次、列表只有 2 行）；
        // 没有地点也没有人物时列本机那一次（只读预览；开关打开后的提醒仍只按保存的地点）。
        let identifiers = calendarZones.isEmpty ? [TimeZone.current.identifier] : calendarZones
        let facts = DSTTransitionFact.systemFacts(zones: identifiers, now: core.now)
            .filter { seen.insert($0.zone).inserted }
            .sorted { $0.transitionAt < $1.transitionAt }
        var zones: Set<String> = []
        let unchanged = identifiers.filter { zones.insert($0).inserted && !seen.contains($0) }
        return facts.map { PreviewRow(zone: $0.zone, fact: $0) } + unchanged.map { PreviewRow(zone: $0, fact: nil) }
    }

    /// 「10月25日 2:00 → 1:00」：换钟前后两种读法（ClockText.clockChange），日期按界面语言、钟点按设置里的小时制。
    private func previewDate(_ fact: DSTTransitionFact) -> String {
        let date = Date(timeIntervalSince1970: fact.transitionAt)
        let written = ClockText.clockChange(at: date, before: fact.before, after: fact.after,
                                           hourStyle: core.settings.hourStyle, locale: core.uiLocale, now: core.now)
        return hasDifferentDay(date, offset: fact.before)
            ? String(format: L10n.string("当地时间 %@", locale: core.uiLocale), written) : written
    }

    private func offsetDate(_ date: Date, zone identifier: String) -> String {
        let written = ClockText.day(date, in: .current, locale: core.uiLocale)
        guard let zone = TimeZone(identifier: identifier),
              hasDifferentDay(date, offset: zone.secondsFromGMT(for: date)) else { return written }
        return String(format: L10n.string("本机 %@", locale: core.uiLocale), written)
    }

    private func hasDifferentDay(_ date: Date, offset: Int) -> Bool {
        let epoch = date.timeIntervalSince1970.rounded(.down)
        let local = TimeZone.current.secondsFromGMT(for: date)
        return ((epoch + Double(offset)) / 86_400).rounded(.down)
            != ((epoch + Double(local)) / 86_400).rounded(.down)
    }

    private func configure() {
        let names = Dictionary(core.zones.map { ($0.timeZone.identifier, $0.displayName(localizedCity: core.cityName(for: $0))) },
                               uniquingKeysWith: { first, _ in first })
        store.configure(zones: core.zones, locale: core.uiLocale, displayNames: names, hourStyle: core.settings.hourStyle)
        dataReport = TZDataCheck.currentReport()
        clockChanges = DSTCalendarPlan.changes(zones: calendarZones, from: core.now)
        #if DEBUG
        // 测试宿主可直接看提醒开启态，通知客户端仍用无权限夹具。
        if UITestFixture.isActive, ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_DST_ALERTS"] == "1",
           !store.state.enabled { store.setEnabled(true) }
        #endif
    }

    /// 「10月25日 星期日 2:00 → 1:00」：带星期（换钟都在周末夜里），换钟前后两种读法，年份只在不是今年时写。
    private func localDate(_ event: DSTWatchEvent) -> String {
        ClockText.clockChange(at: Date(timeIntervalSince1970: event.transitionAt), before: event.before, after: event.after,
                              hourStyle: core.settings.hourStyle, locale: core.uiLocale, now: core.now, weekday: true)
    }
}
