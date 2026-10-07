// SPDX-License-Identifier: GPL-3.0-only
//
//  RotationView.swift
//  TahoeTime
//
//  例会轮换：三大洲的团队没有大家都在工作时间的时段，固定一个钟点就是同一群人每周熬夜。
//  这里让接下来几次例会轮着开（Rust `planner.rotate`：每次挑一个时刻，让各人「在时段外的分钟」按当地钟点折合后尽量均摊）。
//  第一次用的人只要定一件事：哪天开（「周二⌄ · 每周，6 次⌄」）；分法、钟点加权、单次上限有默认值，收在「调整轮换」里。
//  与「一次」同一种排法：一列（每次一行，后面写谁在付），选中那一次画在共同时间轴上；下面每人一行「这几次你付出的」，
//  前面一排小格子标出哪几次轮到他（● 在时段外，○ 在时段内），轮没轮开一眼看得出。
//  控件的值住在 `settings.planner.rotation`（默认值与校验在 Rust `settings.rotation`）：只有用户改了才写。
//

import AppKit
import SwiftUI

struct RotationView: View {
    @Environment(AppModel.self) private var model
    @Environment(TimeCore.self) private var core
    @Environment(\.locale) private var locale

    let context: PlannerContext

    @State private var rotation: OverlapPlanner.Rotation?
    @State private var resultClockWeight = "off"
    @State private var selection: Int?
    @State private var peek: Date?
    @State private var feedback: PresentationCore.PlannerMessage?
    @State private var isExporting = false

    private var localZone: TimeZone { context.localZone }
    private var preferences: RotationPreferences { core.settings.planner.rotation }
    /// 例会的星期：默认参考日起第一个对每个人都整天是工作日的日子；用户选过就以用户为准（存的是 Calendar 编号）。
    private var weekday: Int {
        preferences.weekday ?? OverlapPlanner.defaultRotationWeekday(onOrAfter: context.fromDay, in: localZone,
                                                                    countryCode: Locale.autoupdatingCurrent.region?.identifier,
                                                                    participants: context.participants)
    }
    private var firstDay: Date { OverlapPlanner.firstDate(weekday: weekday, onOrAfter: context.fromDay, in: localZone) }
    private var format: ClockFormat { ClockFormat(hourStyle: core.settings.hourStyle, showSeconds: false) }

    /// 只在这些变了才重算。
    private struct Inputs: Hashable {
        let participants: [OverlapPlanner.Participant]
        let fromDay: Date
        let notBefore: Date
        let duration: Int
        let localTZ: String
        let weekday: Int
        let count: Int
        let intervalWeeks: Int
        let maxStretch: Int
        let split: String
        let clockWeight: String
    }

    private var inputs: Inputs {
        Inputs(participants: context.participants, fromDay: context.fromDay, notBefore: context.notBefore, duration: context.duration,
               localTZ: context.localTZ, weekday: weekday, count: preferences.count,
               intervalWeeks: preferences.intervalWeeks, maxStretch: preferences.maxStretchMinutes,
               split: preferences.split, clockWeight: preferences.clockWeight)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            controls
            if let rotation {
                results(rotation).padding(.top, 14)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 14)
            }
            adjust.padding(.top, 22)
        }
        .accessibilityIdentifier("planner-rotation")
        .task(id: inputs) {
            feedback = nil
            peek = nil
            let current = inputs
            let request = OverlapPlanner.RotationRequest(
                participants: current.participants, fromDay: firstDay, notBefore: current.notBefore,
                count: current.count, intervalWeeks: current.intervalWeeks,
                durationMinutes: current.duration, localTimeZoneID: current.localTZ,
                maxStretchMinutes: current.maxStretch, split: current.split, clockWeight: current.clockWeight)
            let computed = await Task.detached(priority: .userInitiated) { OverlapPlanner.rotate(request) }.value
            guard !Task.isCancelled else { return }
            resultClockWeight = current.clockWeight
            rotation = computed
        }
        .onChange(of: selection) { peek = nil; feedback = nil }
    }

    // MARK: - 第一次用要定的：哪天开、开几次

    /// 「周二⌄ · 每周，6 次⌄」：星期是一列按钮，次数与周期在同一个菜单里（周期只有每周 / 每两周两档）。
    private var controls: some View {
        SubjectFlowLayout(spacing: 8, lineSpacing: 4) {
            weekdayMenu
            SubjectDot()
            cadenceMenu
        }
    }

    /// 星期按界面语言，从该地区的一周第一天排起。没选过时显示算出来的默认工作日，但不写回设置（那会把「跟着参考日走」固化）。
    private var weekdayMenu: some View {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        let options = (0..<7).map { offset -> (Int, String) in
            let index = (calendar.firstWeekday - 1 + offset) % 7
            return (index + 1, ClockText.weekday(index + 1, locale: locale))
        }
        let label = ClockText.weekday(weekday, locale: locale)
        return Menu {
            ForEach(options, id: \.0) { option in
                Button { model.settings.planner.rotation.weekday = option.0 } label: {
                    if option.0 == weekday { Label(option.1, systemImage: "checkmark") } else { Text(verbatim: option.1) }
                }
            }
        } label: {
            PlannerMenuLabel(text: label)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("星期"))
                .accessibilityValue(Text(verbatim: label))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help(Text("星期"))
    }

    private var cadenceMenu: some View {
        let label = String(format: L10n.string(preferences.intervalWeeks == 2 ? "每两周，%lld 次" : "每周，%lld 次", locale: locale),
                           locale: locale, Int64(preferences.count))
        return Menu {
            Section("次数") {
                ForEach(RotationPreferences.countChoices, id: \.self) { n in
                    Button { model.settings.planner.rotation.count = n } label: {
                        let title = String(format: L10n.string("%lld 次", locale: locale), locale: locale, Int64(n))
                        if n == preferences.count { Label(title, systemImage: "checkmark") } else { Text(verbatim: title) }
                    }
                }
            }
            Section("周期") {
                ForEach([1, 2], id: \.self) { weeks in
                    Button { model.settings.planner.rotation.intervalWeeks = weeks } label: {
                        let title = L10n.string(weeks == 1 ? "每周" : "每两周", locale: locale)
                        if weeks == preferences.intervalWeeks { Label(title, systemImage: "checkmark") } else { Text(verbatim: title) }
                    }
                }
            }
        } label: {
            PlannerMenuLabel(text: label)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("次数"))
                .accessibilityValue(Text(verbatim: label))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }

    // MARK: - 结果：每次一行、共同时间轴、各人的账、动作

    @ViewBuilder
    private func results(_ rotation: OverlapPlanner.Rotation) -> some View {
        if rotation.held.isEmpty {
            Text("这几次都排不出时刻：有人休息，或没有时刻能让所有人在上限内。可以提高上限。")
                .appFont(.callout).foregroundStyle(.readableSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            let held = rotation.held
            let selected = held.first { $0.index == selection } ?? held.first
            VStack(alignment: .leading, spacing: 0) {
                if !rotation.needed {
                    Text("每次都有所有人在工作时段内的时刻，不需要轮换。下面是每次最合适的时刻。")
                        .appFont(.callout).foregroundStyle(.readableSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 8)
                }
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(rotation.occurrences) { occurrence in
                        if let window = occurrence.window {
                            PlannerSlotRow(glyph: window.tier == .everyone ? .everyone : .closest,
                                           start: window.best, end: window.bestEnd, trailing: .payers(window.fits),
                                           selected: occurrence.index == selected?.index, choosable: held.count > 1) {
                                selection = occurrence.index
                            }
                        } else {
                            PlannerSlotRow(glyph: .none, start: occurrence.day, end: occurrence.day, trailing: .none,
                                           caption: L10n.string("这天排不出时刻：有人休息，或超出上限。", locale: locale),
                                           selected: false, choosable: false) {}
                        }
                    }
                }
                .accessibilityIdentifier("planner-rotation-list")
                if let window = selected?.window {
                    MeetingTable(rows: context.rows, start: window.best, durationMinutes: window.durationMinutes,
                                 peek: $peek, editor: context.editor, onEditSheet: context.onEditSheet)
                        .padding(.top, 24)
                    MeetingLegend(sky: context.participants.contains { $0.coordinate != nil },
                                  outside: window.tier != .everyone || peek != nil)
                        .padding(.top, 10)
                }
                ledger(rotation).padding(.top, 24)
                HStack(spacing: 10) {
                    Button {
                        Task { await addAll(rotation) }
                    } label: {
                        Text("加入日历（\(rotation.held.count) 场）")
                    }
                    .disabled(isExporting)
                    .fixedSize()
                    Button("复制轮换说明") { copyAll(rotation) }
                        .fixedSize()
                    if peek != nil {
                        Button { peek = nil } label: {
                            Label("回到原来的时刻", systemImage: "arrow.uturn.backward").fontWeight(.semibold)
                                .padding(.horizontal, 6).frame(minHeight: 24).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .appFont(.callout)
                        .fixedSize()
                    }
                }
                .padding(.top, 14)
                if let feedback {
                    feedbackText(feedback).appFont(.callout).padding(.top, 6)
                }
            }
        }
    }

    /// 各人的账：每人一行，前面一排小格子（每次一格：● 这次在时段外、○ 在时段内、空格 = 那次没开），后面一句「几次，共多久（其中凌晨多久）」，
    /// 加权时再写折合多少；最后一句最重与最轻差多少。
    private func ledger(_ rotation: OverlapPlanner.Rotation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("这几次各人付出的：").appFont(.headline).accessibilityAddTraits(.isHeader)
                .padding(.bottom, 2)
            ForEach(Array(rotation.totals.enumerated()), id: \.offset) { index, total in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    TurnCells(cells: rotation.occurrences.map { occurrence in
                        guard occurrence.window != nil, index < occurrence.stretch.count else { return .skipped }
                        return occurrence.stretch[index] > 0 ? .paid : .free
                    })
                    totalText(total)
                        .appFont(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
            Group {
                if resultClockWeight != "off" {
                    Text("最重与最轻相差 \(durationText(rotation.weightedSpread))（按钟点折合）")
                } else if rotation.spreadMinutes == 0 {
                    Text("完全均摊。")
                } else {
                    Text("最重与最轻相差 \(durationText(rotation.spreadMinutes))。")
                }
            }
            .appFont(.callout).foregroundStyle(.readableSecondary)
            .padding(.top, 2)
        }
        .accessibilityIdentifier("planner-rotation-summary")
    }

    private func totalText(_ total: OverlapPlanner.Rotation.Total) -> Text {
        if total.outsideCount == 0 {
            return Text(verbatim: String(format: L10n.string("%@：这几次都在工作时段内", locale: locale), total.participant.name))
        }
        var text = String(format: L10n.string("%@：%lld 次，共 %@", locale: locale), locale: locale,
                          total.participant.name, total.outsideCount, durationText(total.outsideMinutes))
        if total.nightMinutes > 0 {
            text += String(format: L10n.string("（其中凌晨 %@）", locale: locale), locale: locale, durationText(total.nightMinutes))
        }
        if resultClockWeight != "off", total.weightedMinutes != total.outsideMinutes {
            text += String(format: L10n.string("，按钟点折合 %@", locale: locale), locale: locale, durationText(total.weightedMinutes))
        }
        return Text(verbatim: text)
    }

    // MARK: - 调整：分法、钟点加权、单次上限（有默认值，第一次用不必动）

    private var adjust: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                SubjectFlowLayout(spacing: 14, lineSpacing: 6) {
                    labeledMenu("分法", value: L10n.string(preferences.split == "share" ? "每次大家都让一点" : "轮流吃亏", locale: locale)) {
                        choice("轮流吃亏", preferences.split == "rotate") { model.settings.planner.rotation.split = "rotate" }
                        choice("每次大家都让一点", preferences.split == "share") { model.settings.planner.rotation.split = "share" }
                    }
                    labeledMenu("钟点加权", value: L10n.string(Self.weightKey(preferences.clockWeight), locale: locale)) {
                        ForEach(["off", "gentle", "strong"], id: \.self) { weight in
                            choice(Self.weightKey(weight), preferences.clockWeight == weight) { model.settings.planner.rotation.clockWeight = weight }
                        }
                    }
                    labeledMenu("最多在时段外", value: durationText(preferences.maxStretchMinutes)) {
                        ForEach(RotationPreferences.stretchChoices, id: \.self) { minutes in
                            Button { model.settings.planner.rotation.maxStretchMinutes = minutes } label: {
                                if minutes == preferences.maxStretchMinutes { Label(durationText(minutes), systemImage: "checkmark") }
                                else { Text(verbatim: durationText(minutes)) }
                            }
                        }
                    }
                }
                Group {
                    if preferences.clockWeight == "gentle" {
                        Text("凌晨 1 小时按 2 小时算，深夜 1.5、清晨 1.25")
                    } else if preferences.clockWeight == "strong" {
                        Text("凌晨 1 小时按 3 小时算，深夜 2、清晨 1.5")
                    }
                }
                .appFont(.caption).foregroundStyle(.readableSecondary)
                Text("按各人的工作时段安排：每次会议另选一个时刻，让工作时段外的负担尽量均摊；有人休息的那次跳过。")
                    .appFont(.caption).foregroundStyle(.readableSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 8)
        } label: {
            Text("调整轮换").appFont(.callout)
        }
        .accessibilityIdentifier("planner-rotation-adjust")
    }

    private static func weightKey(_ weight: String) -> String {
        switch weight {
        case "gentle": "保守"
        case "strong": "加重"
        default: "不加权"
        }
    }

    private func choice(_ key: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            let title = L10n.string(key, locale: locale)
            if on { Label(title, systemImage: "checkmark") } else { Text(verbatim: title) }
        }
    }

    /// 「分法：轮流吃亏⌄」：名字在前（可读次要色），值是菜单（与主语行同一种标签，24 点高）。
    private func labeledMenu<Content: View>(_ name: LocalizedStringKey, value: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(name).appFont(.callout).foregroundStyle(.readableSecondary)
            Menu { content() } label: {
                PlannerMenuLabel(text: value, style: .callout)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(name))
                    .accessibilityValue(Text(verbatim: value))
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        }
    }

    // MARK: - 文字与动作

    private func durationText(_ minutes: Int) -> String {
        ClockText.duration(seconds: Double(minutes * 60), locale: locale)
    }

    @ViewBuilder
    private func feedbackText(_ feedback: PresentationCore.PlannerMessage) -> some View {
        switch feedback.kind {
        case "added": Label("已加入日历「\(feedback.title ?? "")」", systemImage: "checkmark.circle")
        case "openedICS": Label("已交给日历 app 打开", systemImage: "arrow.up.forward.app")
        case "copied": Label("已复制", systemImage: "checkmark.circle")
        case "failed": ErrorLine(Text("加入日历失败。可以改用「复制」把各地时间贴进日历，或在系统设置的「隐私与安全性 › 日历」里检查权限。"))
        default: EmptyView()
        }
    }

    private func events(_ rotation: OverlapPlanner.Rotation) -> [MeetingEvent] {
        rotation.held.compactMap { occurrence in
            occurrence.window.map { window in
                MeetingEvent.make(window: window,
                                  names: window.fits.map(\.participant.name),
                                  timeZones: window.fits.map(\.participant.timeZone),
                                  offsetOnlyZoneNames: window.fits.map(\.participant.offsetOnlyZoneName),
                                  title: L10n.string("会议", locale: locale),
                                  footer: L10n.string("用 Dayside 规划", locale: locale),
                                  locale: locale, hourStyle: core.settings.hourStyle)
            }
        }
    }

    private func addAll(_ rotation: OverlapPlanner.Rotation) async {
        guard !isExporting else { return }
        isExporting = true
        defer { isExporting = false }
        switch await CalendarExporter.export(series: events(rotation)) {
        case let .added(title): feedback = .init(kind: "added", title: title)
        case .openedICS: feedback = .init(kind: "openedICS")
        case .failed: feedback = .init(kind: "failed")
        }
    }

    /// 复制的是模型层文本：标题走 `L10n.string`，每场的各地时间行由 Rust 排好。
    private func copyAll(_ rotation: OverlapPlanner.Rotation) {
        let body = events(rotation).map { event in
            "\(ClockText.day(event.start, in: localZone, locale: locale, now: core.now, weekday: true))\n\(event.notes)"
        }
        let text = ([L10n.string("例会轮换", locale: locale)] + body).joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        feedback = .init(kind: "copied")
        AccessibilityNotification.Announcement(L10n.string("已复制", locale: locale)).post()
    }
}

/// 一排小格子：每次例会一格。● 这次在工作时段外，○ 在时段内，空 = 那次没开。形状本身就是意思（不靠颜色）。
private struct TurnCells: View {
    enum Cell { case paid, free, skipped }
    let cells: [Cell]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                Group {
                    switch cell {
                    case .paid: Circle().fill(.primary)
                    case .free: Circle().strokeBorder(.primary.opacity(0.78), lineWidth: 1)
                    case .skipped: Circle().strokeBorder(.secondary.opacity(0.9), style: StrokeStyle(lineWidth: 1, dash: [1.5, 1.5]))
                    }
                }
                .frame(width: 8, height: 8)
            }
        }
        .accessibilityHidden(true)
    }
}
