// SPDX-License-Identifier: GPL-3.0-only
//
//  SplitSessionsView.swift
//  Dayside
//
//  找碰头时间的第三种解法：把一场会**拆成 N 场**。三大洲的全员会没有一个时刻能让所有人都在工作时段内，
//  轮换是让大家轮流熬，拆场是每人只来自己方便的那一场。命名按 GitLab 的规矩只标「第 1 / 2 / 3 场」——
//  「对一个人的 early 是另一个人的 late」，所以不出现 APAC friendly / early / late 这种说法。
//  挑哪几场在 Rust `planner.split`；这里与「一次」同一种排法：一列场次（后面写谁在自己的工作时段内），
//  选中那一场画在共同时间轴上（在时段外的人钟点前面一个小月亮：他多半不来这一场）。要定的只有一件事：两场还是三场。
//

import AppKit
import SwiftUI

struct SplitSessionsView: View {
    @Environment(AppModel.self) private var model
    @Environment(TimeCore.self) private var core
    @Environment(\.locale) private var locale

    let context: PlannerContext

    @State private var sessionCount = 2
    @State private var split: OverlapPlanner.Split?
    @State private var selection: Int?
    @State private var peek: Date?
    @State private var feedback: PresentationCore.PlannerMessage?
    @State private var isExporting = false

    private var localZone: TimeZone { context.localZone }

    private struct Inputs: Hashable {
        let participants: [OverlapPlanner.Participant]
        let from: Date
        let days: Int
        let duration: Int
        let localTZ: String
        let sessions: Int
    }

    private var inputs: Inputs {
        Inputs(participants: context.participants, from: context.notBefore, days: context.days, duration: context.duration,
               localTZ: context.localTZ, sessions: sessionCount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("场次", selection: $sessionCount) {
                Text("两场").tag(2)
                Text("三场").tag(3)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Text("每人只来自己方便的那一场：挑出让尽可能多的人都在工作时段内的几个时刻。场次只按先后编号。")
                .appFont(.caption).foregroundStyle(.readableSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            if let split {
                results(split).padding(.top, 14)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 14)
            }
        }
        .accessibilityIdentifier("planner-split")
        .task(id: inputs) {
            feedback = nil
            peek = nil
            let current = inputs
            let request = OverlapPlanner.SplitRequest(participants: current.participants, from: current.from, days: current.days,
                                                      durationMinutes: current.duration, sessions: current.sessions,
                                                      localTimeZoneID: current.localTZ)
            let computed = await Task.detached(priority: .userInitiated) { OverlapPlanner.split(request) }.value
            guard !Task.isCancelled else { return }
            split = computed
        }
        .onChange(of: selection) { peek = nil; feedback = nil }
    }

    @ViewBuilder private func results(_ split: OverlapPlanner.Split) -> some View {
        if !split.needed {
            Text("有让所有人都在工作时段内的时刻，不用拆场。")
                .appFont(.callout).foregroundStyle(.readableSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if split.sessions.isEmpty {
            Text("这段时间里排不出场次：有人休息，或范围太短。可以放宽范围。")
                .appFont(.callout).foregroundStyle(.readableSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            let selected = split.sessions.first { $0.index == selection } ?? split.sessions.first
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(split.sessions) { session in
                        PlannerSlotRow(glyph: .none,
                                       prefix: String(format: L10n.string("第 %lld 场", locale: locale), session.index),
                                       start: session.start, end: session.end,
                                       trailing: .text(session.inside.isEmpty
                                           ? L10n.string("没有人在工作时段内。", locale: locale)
                                           : String(format: L10n.string("在工作时段内：%@", locale: locale),
                                                    PlannerPage.nameList(session.inside.map(\.name), locale: locale))),
                                       selected: session.index == selected?.index, choosable: split.sessions.count > 1) {
                            selection = session.index
                        }
                    }
                }
                .accessibilityIdentifier("planner-split-list")
                coverage(split).padding(.top, 8)
                if let selected {
                    MeetingTable(rows: context.rows, start: selected.start, durationMinutes: context.duration,
                                 peek: $peek, editor: context.editor, onEditSheet: context.onEditSheet)
                        .padding(.top, 24)
                    MeetingLegend(sky: context.participants.contains { $0.coordinate != nil },
                                  outside: selected.inside.count < context.participants.count || peek != nil)
                        .padding(.top, 10)
                }
                HStack(spacing: 10) {
                    Button {
                        Task { await addAll(split) }
                    } label: {
                        Text("加入日历（\(split.sessions.count) 场）")
                    }
                    .disabled(isExporting)
                    .fixedSize()
                    Button("复制场次说明") { copyAll(split) }
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

    @ViewBuilder private func coverage(_ split: OverlapPlanner.Split) -> some View {
        Group {
            if split.uncovered.isEmpty {
                Text("每个人都至少有一场在自己的工作时段内。")
            } else {
                Text(verbatim: String(format: L10n.string(sessionCount < 3 ? "这几场都不在工作时段内的人：%@。可以改成三场或放宽范围。" : "这几场都不在工作时段内的人：%@。可以放宽范围。", locale: locale),
                                      PlannerPage.nameList(split.uncovered.map(\.name), locale: locale)))
            }
        }
        .appFont(.callout).foregroundStyle(.readableSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("planner-split-coverage")
    }

    @ViewBuilder private func feedbackText(_ feedback: PresentationCore.PlannerMessage) -> some View {
        switch feedback.kind {
        case "added": Label("已加入日历「\(feedback.title ?? "")」", systemImage: "checkmark.circle")
        case "openedICS": Label("已交给日历 app 打开", systemImage: "arrow.up.forward.app")
        case "copied": Label("已复制", systemImage: "checkmark.circle")
        case "failed": ErrorLine(Text("加入日历失败。可以改用「复制」把各地时间贴进日历，或在系统设置的「隐私与安全性 › 日历」里检查权限。"))
        default: EmptyView()
        }
    }

    // MARK: - 动作

    private func events(_ split: OverlapPlanner.Split) -> [MeetingEvent] {
        split.sessions.map { session in
            MeetingEvent.make(start: session.start, end: session.end,
                              names: context.participants.map(\.name), timeZones: context.participants.map(\.timeZone),
                              offsetOnlyZoneNames: context.participants.map(\.offsetOnlyZoneName),
                              title: String(format: L10n.string("第 %lld 场", locale: locale), session.index),
                              footer: L10n.string("用 Dayside 规划", locale: locale),
                              locale: locale, hourStyle: core.settings.hourStyle)
        }
    }

    private func addAll(_ split: OverlapPlanner.Split) async {
        guard !isExporting else { return }
        isExporting = true
        defer { isExporting = false }
        switch await CalendarExporter.export(series: events(split)) {
        case let .added(title): feedback = .init(kind: "added", title: title)
        case .openedICS: feedback = .init(kind: "openedICS")
        case .failed: feedback = .init(kind: "failed")
        }
    }

    private func copyAll(_ split: OverlapPlanner.Split) {
        let body = events(split).map { event in
            "\(event.title)\n\(ClockText.day(event.start, in: localZone, locale: locale, now: core.now, weekday: true))\n\(event.notes)"
        }
        let text = ([L10n.string("拆成几场", locale: locale)] + body).joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        feedback = .init(kind: "copied")
        AccessibilityNotification.Announcement(L10n.string("已复制", locale: locale)).post()
    }
}
