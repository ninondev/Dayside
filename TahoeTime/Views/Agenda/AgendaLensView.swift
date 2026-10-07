// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// 看的一天跟随时间核，选中的一场留在页面里。
struct AgendaLensView: View {
    @Environment(AppModel.self) private var model
    @Environment(TimeCore.self) private var core
    @Environment(\.featureHub) private var featureHub
    @Environment(\.accessibilityDifferentiateWithoutColor) private var noColor
    @Bindable var store: AgendaStore
    @State private var showingDate = false
    @State private var showingCalendars = false
    @State private var selection = AgendaPageSelection()
    @State private var skies = MomentLaneMemo()
    @State private var driftMemo = AgendaDriftMemo()
    @State private var loadingVisible = false
    @State private var copied = false
    @State private var actionsWidth: CGFloat = 0
    @State private var copyReceipt: Task<Void, Never>?

    var body: some View {
        let frame = DayLaneFrame.homeDay(containing: core.referenceDate)
        let day = store.day(dayStart: frame.start, dayEnd: frame.end, anchor: core.referenceDate, now: core.now)
        LazyVStack(alignment: .leading, spacing: 0) {
            if !store.isEnabled {
                invitation
            } else {
                switch store.state {
                case .permission(let access): permission(access)
                case .failed(let failure): failureContent(failure)
                case .disabled, .inactive: invitation
                case .loading, .ready: content(frame: frame, day: day)
                }
            }
        }
        .task(id: DriftContext(revision: store.snapshotRevision, calendars: store.preferences.selectedCalendarIDs)) { store.refreshDrift() }
        .onChange(of: frame.start, initial: true) { store.setViewedDay(frame.start) }
        .onChange(of: core.now) { store.clockDidChange(now: core.now) }
        .onChange(of: core.systemRevision) { store.setViewedDay(frame.start); store.refresh() }
        .onChange(of: SelectionContext(day: frame.start, offset: core.displayOffset, events: day?.timed.map(\.id) ?? []), initial: true) {
            selection.update(day: frame.start, offset: core.displayOffset, preferred: day?.selected, available: day?.timed.map(\.id) ?? [])
        }
        .task(id: day == nil && store.isEnabled) {
            loadingVisible = false
            guard day == nil, store.isEnabled else { return }
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            loadingVisible = true
        }
        .onDisappear { copyReceipt?.cancel() }
    }

    private struct DriftContext: Equatable { let revision: UUID; let calendars: [String]? }
    private struct SelectionContext: Equatable { let day: Date; let offset: TimeInterval; let events: [String] }

    @ViewBuilder private func content(frame: DayLaneFrame, day: AgendaDay?) -> some View {
        let places = AgendaTable.places(core: core, people: featureHub?.savedPeople ?? [])
        let _ = skies.update(frame: frame, coordinates: places.map(\.coordinate), marks: noColor)
        let participants = places.enumerated().map { index, place in
            AgendaDriftParticipant(id: place.id, name: index == 0 ? L10n.string("本机", locale: core.uiLocale) : place.name, timeZoneID: place.id)
        }
        let drift = driftMemo.value(events: store.driftSnapshot?.events ?? [], participants: participants)
        let shifted = Set(drift.map(\.identifier))
        let selected = day?.timed.first { $0.id == (selection.id ?? day?.selected) }
        subject(frame: frame)
        if let selected {
            header(selected, frame: frame, shifted: shifted).padding(.top, 14).padding(.bottom, 10)
        } else { Color.clear.frame(height: 14) }
        AgendaTable(places: places, frame: frame, events: day?.timed ?? [], selected: selected, skies: skies) { selection.select($0) }
        if let selected { actions(selected.item, places: places).padding(.top, 14) }
        Group {
            if store.calendars.isEmpty, store.state == .ready {
                VStack(alignment: .leading, spacing: 8) {
                    Text("没有可读取的日历。请先在系统日历 App 中添加日历。").appFont(.callout).foregroundStyle(.readableSecondary)
                    Button("打开“日历”") { store.openCalendarApp() }
                }
            } else if store.preferences.selectedCalendarIDs?.isEmpty == true {
                Button("显示全部日历") { store.selectAllCalendars() }
            } else if let day {
                if day.allDay.isEmpty && day.timed.isEmpty {
                    Text("这一天没有日程").appFont(.callout).foregroundStyle(.readableSecondary)
                } else {
                    AgendaDayList(day: day, frame: frame, selected: selected?.id, calendars: store.calendars,
                                  places: places, skies: skies, shifted: shifted) { selection.select($0) }
                }
            } else if loadingVisible {
                ProgressView().controlSize(.small).accessibilityLabel(Text("正在读取日历…"))
            }
        }.padding(.top, 24)
        if let next = day?.next {
            let description = "\(ClockText.day(next.startDate, in: frame.timeZone, locale: core.uiLocale, now: core.now, weekday: true)) \(ClockText.time(next.startDate, in: frame.timeZone, hourStyle: core.settings.hourStyle)) · \(AgendaDayList.title(next.title, locale: core.uiLocale))"
            Button { model.jump(to: next.startDate) } label: {
                Text(verbatim: String(format: L10n.string("下一场：%@", locale: core.uiLocale), description))
                    .fixedSize(horizontal: false, vertical: true)
            }.padding(.top, 8)
        }
        if let failure = store.joinFailure {
            ErrorLine(Text(errorKey(failure))).appFont(.callout).padding(.top, 8)
                .accessibilityIdentifier("agenda-join-error")
        }
        if !drift.isEmpty { driftSection(drift).padding(.top, 28) }
        Toggle("菜单栏显示下一日程", isOn: Binding(get: { store.preferences.showInMenuBar }, set: { store.setMenuBarEnabled($0) }))
            .toggleStyle(.checkbox).padding(.top, 28).accessibilityIdentifier("agenda-menu-bar")
    }

    private func subject(frame: DayLaneFrame) -> some View {
        HStack(alignment: .top, spacing: 8) {
            SubjectFlowLayout(spacing: 8, lineSpacing: 4) {
                dateChip(frame: frame)
                if store.calendars.count >= 2 { SubjectDot(); calendarsChip }
            }
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                step(-1, key: "前一天", symbol: "chevron.left", shortcut: .leftArrow)
                step(1, key: "后一天", symbol: "chevron.right", shortcut: .rightArrow)
            }
        }
    }
    private func dateChip(frame: DayLaneFrame) -> some View {
        let label = ClockText.day(frame.start, in: frame.timeZone, locale: core.uiLocale, now: core.now, weekday: true)
        return Button { showingDate = true } label: {
            PlannerMenuLabel(text: label).accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("日期")).accessibilityValue(Text(verbatim: label))
        }.buttonStyle(.plain).help(Text("日期"))
            .popover(isPresented: $showingDate, arrowEdge: .bottom) {
                DatePicker("日期", selection: Binding(get: { core.referenceDate }, set: { model.jump(to: Self.replacingDay(of: core.referenceDate, with: $0, zone: frame.timeZone)) }),
                           in: Date(timeIntervalSince1970: -5_364_576_000)...Date(timeIntervalSince1970: 4_133_894_400), displayedComponents: .date)
                    .datePickerStyle(.graphical).labelsHidden().padding()
                    .environment(\.timeZone, frame.timeZone).environment(\.locale, core.uiLocale)
            }
    }
    private func step(_ amount: Int, key: LocalizedStringKey, symbol: String, shortcut: KeyEquivalent) -> some View {
        Button { if let date = Calendar.gregorianUTC(.current).date(byAdding: .day, value: amount, to: core.referenceDate) { model.jump(to: date) } } label: {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(.readableSecondary)
                .frame(width: 26, height: 24).contentShape(Rectangle())
        }.buttonStyle(.plain).keyboardShortcut(shortcut, modifiers: .command).accessibilityLabel(Text(key)).help(Text(key))
    }
    private var calendarsLabel: String {
        let selected = store.calendars.filter { store.includesCalendar($0.id) }
        if selected.isEmpty { return L10n.string("未选日历", locale: core.uiLocale) }
        if selected.count == store.calendars.count { return L10n.string("全部日历", locale: core.uiLocale) }
        if selected.count == 1 { return selected[0].title }
        return String(format: L10n.string("%lld 个日历", locale: core.uiLocale), locale: core.uiLocale, Int64(selected.count))
    }
    private var calendarsChip: some View {
        Button { showingCalendars = true } label: {
            PlannerMenuLabel(text: calendarsLabel).accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("选择日历")).accessibilityValue(Text(verbatim: calendarsLabel))
        }.buttonStyle(.plain).help(Text("选择日历"))
            .popover(isPresented: $showingCalendars, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(store.calendars) { calendar in
                        Toggle(isOn: Binding(get: { store.includesCalendar(calendar.id) }, set: { store.setCalendar(calendar.id, included: $0) })) {
                            HStack(alignment: .top, spacing: 5) {
                                AgendaDayList.dot(calendar).padding(.top, 4)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: calendar.title).fixedSize(horizontal: false, vertical: true)
                                    Text(verbatim: calendar.sourceTitle).appFont(.caption).foregroundStyle(.readableSecondary)
                                }
                            }
                        }.toggleStyle(.checkbox)
                    }
                    HStack(spacing: 10) {
                        Button("全部日历") { store.selectAllCalendars() }
                        Button("清除选择") { store.selectNoCalendars() }
                    }.buttonStyle(.borderless).controlSize(.small)
                }.padding().environment(\.locale, core.uiLocale)
            }
    }

    private func header(_ event: AgendaDayItem, frame: DayLaneFrame, shifted: Set<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if store.calendars.count >= 2 { AgendaDayList.dot(store.calendars.first { $0.id == event.calendarID }) }
                Text(verbatim: AgendaDayList.title(event.title, locale: core.uiLocale)).appFont(.body, weight: .semibold)
                    .fixedSize(horizontal: false, vertical: true)
                if shifted.contains(event.identifier) { AgendaDayList.driftBadge() }
            }
            ChipFlowLayout(spacing: 5, lineSpacing: 3) {
                Text(verbatim: AgendaDayList.interval(event.item, frame: frame, core: core)).appFont(.caption)
                if let status = AgendaDayList.status(event.item, now: core.now, viewedDay: frame.start, locale: core.uiLocale, zone: frame.timeZone) {
                    Text(verbatim: "· \(status)").appFont(.caption)
                }
                if let location = event.location, !location.isEmpty {
                    Label { Text(verbatim: location).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) } icon: {
                        Image(systemName: "mappin.and.ellipse")
                    }.appFont(.caption).accessibilityLabel(Text("地点：\(location)"))
                }
            }.foregroundStyle(.readableSecondary)
        }
    }

    private func actions(_ event: AgendaItem, places: [AgendaTable.Place]) -> some View {
        TrailingWrapLayout(spacing: 10) {
            AgendaActionHead(maximumWidth: actionsWidth) {
                ChipFlowLayout(spacing: 10, lineSpacing: 8) {
                if let link = event.meetingLink, event.endDate > core.now {
                    if event.startDate.timeIntervalSince(core.now) <= 600 {
                        Button("加入会议") { store.joinMeeting(id: event.id, locale: core.uiLocale) }
                            .buttonStyle(.borderedProminent).disabled(store.isJoining).help(Text(verbatim: link.provider))
                    } else {
                        Button("加入会议") { store.joinMeeting(id: event.id, locale: core.uiLocale) }
                            .buttonStyle(.bordered).disabled(store.isJoining).help(Text(verbatim: link.provider))
                    }
                }
                Button(copied ? "已复制" : "复制全部各地时间") { copy(event, places: places) }
                    .buttonStyle(.bordered)
                }
            }
            Button("在面板里看这一刻") { model.jump(to: event.startDate) }
                .buttonStyle(.bordered).keyboardShortcut(.return, modifiers: .command)
                .help(Text("面板上各地的时间都跳到这一刻"))
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { actionsWidth = $0 }
    }
    private func copy(_ event: AgendaItem, places: [AgendaTable.Place]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AgendaDayList.copyText(event, places: places, hourStyle: core.settings.hourStyle, locale: core.uiLocale, now: core.now), forType: .string)
        copied = true
        NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
                             userInfo: [.announcement: L10n.string("已复制", locale: core.uiLocale), .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        copyReceipt?.cancel()
        copyReceipt = Task { do { try await Task.sleep(for: .seconds(2.5)) } catch { return }; copied = false }
    }

    private var invitation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("在本机显示所选日历的议程，不修改日程。").appFont(.callout).foregroundStyle(.readableSecondary)
            HStack(spacing: 8) {
                Button("允许读取日历") { if store.isEnabled { store.requestAccess() } else { store.setEnabled(true) } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(store.isRequestingAccess)
                    .accessibilityIdentifier("agenda-request-access")
                if store.isRequestingAccess { ProgressView().controlSize(.small) }
            }
        }
    }
    @ViewBuilder private func permission(_ access: AgendaAuthorization) -> some View {
        switch access {
        case .notDetermined, .writeOnly, .fullAccess: invitation
        case .denied, .restricted:
            VStack(alignment: .leading, spacing: 10) {
                Label { Text(access == .denied ? "日历读取权限未开启。请在系统设置的「隐私与安全性 › 日历」里允许 Dayside 访问。" : "此 Mac 限制了日历访问。请联系设备管理员，或关闭日历议程。")
                        .appFont(.callout).fixedSize(horizontal: false, vertical: true)
                } icon: { Image(systemName: "calendar.badge.exclamationmark").accessibilityHidden(true) }
                .foregroundStyle(.readableSecondary)
                ChipFlowLayout(spacing: 8, lineSpacing: 8) {
                    if access == .denied { Button("打开系统设置") { store.openCalendarPrivacySettings() } }
                    Button("重新检查权限") { store.refresh() }
                }
            }
        }
    }
    private func failureContent(_ failure: AgendaFailure) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ErrorLine(Text(errorKey(failure))).appFont(.callout)
            Button("重试") { if failure == .permission { store.requestAccess() } else { store.refresh() } }
        }
    }
    private func errorKey(_ failure: AgendaFailure) -> LocalizedStringKey {
        switch failure {
        case .permission: "无法请求日历权限。请重试，或在系统设置中检查日历权限。"
        case .read: "无法读取日历。请重试，并检查系统日历 App 是否能显示日程。"
        case .eventUnavailable: "此日程已结束、删除或不在所选日历中。议程已刷新。"
        case .meetingLinkUnavailable: "此日程没有可识别的 Zoom、Google Meet 或 Microsoft Teams 加入链接。"
        case .open: "无法打开会议链接。请检查默认浏览器后重试。"
        }
    }

    private func driftSection(_ meetings: [AgendaDriftMeeting]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("时钟调整会改变这些会议的当地时间").appFont(.headline, weight: .semibold).accessibilityAddTraits(.isHeader)
            ForEach(meetings) { meeting in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "clock.arrow.2.circlepath").accessibilityHidden(true)
                        Text(verbatim: AgendaDayList.title(meeting.title, locale: core.uiLocale)).appFont(.body, weight: .medium)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(meeting.places) { place in
                        ForEach(place.runs) { run in
                            let from = ClockText.minute(place.baseline, hourStyle: core.settings.hourStyle)
                            let to = ClockText.minute(run.minute, hourStyle: core.settings.hourStyle)
                            let when = driftWhen(run)
                            let change = String(format: L10n.string("由 %1$@ 变为 %2$@", locale: core.uiLocale), from, to)
                            let spoken = "\(place.participantName), \(change), \(when)"
                            ChipFlowLayout(spacing: 10, lineSpacing: 4) {
                                Text(verbatim: place.participantName).frame(minWidth: 64, alignment: .leading)
                                Text(verbatim: "\(from) → \(to)").monospacedDigit()
                                Text(verbatim: when).foregroundStyle(.readableSecondary)
                            }.appFont(.callout).padding(.leading, 22)
                                .accessibilityElement(children: .ignore).accessibilityAddTraits(.isStaticText)
                                .accessibilityLabel(Text(verbatim: spoken))
                        }
                    }
                }
            }
        }.accessibilityIdentifier("agenda-drift")
    }
    private func driftWhen(_ run: AgendaDriftRun) -> String {
        let first = Date(timeIntervalSince1970: run.first)
        if run.open { return String(format: L10n.string("%@起", locale: core.uiLocale), ClockText.day(first, in: .current, locale: core.uiLocale, now: core.now, weekday: true)) }
        if run.first == run.last { return String(format: L10n.string("只在%@", locale: core.uiLocale), ClockText.day(first, in: .current, locale: core.uiLocale, now: core.now, weekday: true)) }
        return ClockText.range(ClockText.day(first, in: .current, locale: core.uiLocale, now: core.now),
                               ClockText.day(Date(timeIntervalSince1970: run.last), in: .current, locale: core.uiLocale, now: core.now))
    }
    static func replacingDay(of reference: Date, with day: Date, zone: TimeZone) -> Date {
        let calendar = Calendar.gregorianUTC(zone)
        let time = calendar.dateComponents([.hour, .minute, .second], from: reference)
        return calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: time.second ?? 0, of: day) ?? reference
    }
}

@MainActor private final class AgendaDriftMemo {
    private var events: [AgendaEvent] = []
    private var participants: [AgendaDriftParticipant] = []
    private var meetings: [AgendaDriftMeeting] = []
    func value(events: [AgendaEvent], participants: [AgendaDriftParticipant]) -> [AgendaDriftMeeting] {
        if self.events != events || self.participants != participants {
            self.events = events; self.participants = participants
            meetings = AgendaDrift.meetings(events: events, participants: participants)
        }
        return meetings
    }
}

/// 尾部排版量理想宽度时，也让左侧按钮按页面宽度换行。
private struct AgendaActionHead: Layout {
    let maximumWidth: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let head = subviews.first else { return .zero }
        let ideal = head.sizeThatFits(.unspecified)
        let width = min(proposal.width ?? ideal.width, maximumWidth > 0 ? maximumWidth : ideal.width)
        return head.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}
