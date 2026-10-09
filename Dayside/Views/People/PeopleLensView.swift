// SPDX-License-Identifier: GPL-3.0-only
//
//  PeopleLensView.swift
//  Dayside
//
//  人物时钟：一个钟是一个人，不是一座城。每个人一条自己的天，上面一道自己的工作时段（`PeopleTable`）；
//  第一行是你自己（这台 Mac 的所在地与你的工作时段），两道轨上下一比就是重叠多少、她几点下班。
//  页面照工具窗外壳的语法：页首天色带（看的那一刻与「回到现在」都由它管）→ 那张表 → 图例 → 选中那个人的细节与动作 → 一句脚注。
//  页面自己不带滚动区（与外壳同一栏，最大 720），五个人在默认窗口里一屏放得下。
//

import SwiftUI

struct PeopleLensView: View {
    @Environment(TimeCore.self) private var core
    @Environment(AppModel.self) private var model
    @Environment(\.featureHub) private var featureHub
    @Environment(\.textScale) private var textScale
    @Bindable var store: PeopleStore
    /// 「对方上班时提醒我」设好后的一行回执，写在细节下面，换人或关页就不在了。
    @State private var reminderNote: String?
    @State private var reminderPersonID: UUID?
    @State private var editing: PersonProfile?
    @State private var importing = false
    @State private var pendingImport: PersonProfile?
    @State private var removing: PersonProfile?
    /// 编辑器里点了「移除人物…」的那个人，表单收起后转成 `removing`。
    @State private var pendingRemoval: PersonProfile?
    @State private var importingCard = false
    /// 表下面写谁的细节：默认第一个人。
    @State private var selection: UUID?
    /// 选中那个人的「共同时段 / 每工作日重叠 / 对方下班或上班 = 你的几点」：只算这一个人，按分钟与穿梭时刻刷新。
    @State private var details: Details?

    private struct Details: Equatable {
        let personID: UUID
        let shared: SharedWindow?
        let summary: OverlapSummary
        let nextStart: Date?
    }

    @ViewBuilder var body: some View {
        #if DEBUG
        // 直接呈现编辑器，避免模态表单妨碍安静宿主退出。
        if UITestFixture.isActive,
           ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_COPY_PEOPLE"] == "vacation-editor",
           let person = store.people.first {
            PeopleEditorView(store: store, original: person)
                .environment(\.locale, core.uiLocale)
        } else {
            page
        }
        #else
        page
        #endif
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.storageReadOnly {
                Label("人物存档版本较新，更新 Dayside 后再编辑。原始数据已保留。", systemImage: "lock")
                    .appFont(.callout).fixedSize(horizontal: false, vertical: true).padding(.bottom, 14)
            } else if store.storageNeedsRecovery {
                Label("部分人物数据无法读取。可用记录已恢复，原始数据会在编辑前另存备份。", systemImage: "exclamationmark.triangle")
                    .appFont(.callout).fixedSize(horizontal: false, vertical: true).padding(.bottom, 14)
            }
            if store.people.isEmpty {
                ContentUnavailableView {
                    Label("还没有人物", systemImage: "person.2")
                        .foregroundStyle(.primary)
                } description: {
                    Text("添加姓名、所在地和作息，查看当地时间与工作状态。无需通讯录权限。")
                        .foregroundStyle(.readableSecondary)
                } actions: {
                    Button("添加人物", systemImage: "plus", action: addPerson)
                        .disabled(store.storageReadOnly)
                    // 分享页的说明点名「导入时间名片」，工具栏里它只是个图标；空态给一个带字的入口。
                    Button("导入时间名片", systemImage: "tray.and.arrow.down") { importingCard = true }
                        .disabled(store.storageReadOnly)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 24)
            } else {
                let tableRows = rows
                // 存档只读时照样看、照样点时间轴，只是不能改人：编辑与移除在这里拦下（细节里的按钮另外置灰）。
                PeopleTable(rows: tableRows, selection: $selection, hereEditor: hereEditor,
                            onEdit: { id in if !store.storageReadOnly { editing = person(id) } },
                            onRemind: { id in if let person = person(id) { remindAtWorkStart(person) } },
                            onRemove: { id in if !store.storageReadOnly { removing = person(id) } })
                MeetingLegend(sky: tableRows.contains { $0.participant.coordinate != nil }, outside: false)
                    .padding(.top, 12)
                if let person = selectedPerson {
                    detailSection(person, workStatus: tableRows.first { $0.personID == person.id }?.workStatus)
                        .padding(.top, 24)
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button("从通讯录选择", systemImage: "person.crop.rectangle") {
                    importing = true
                    store.beginContactsImport()
                }
                .disabled(store.storageReadOnly)
                // `tray.and.arrow.down`：读作「导入」；`square.and.arrow.down` 读作「下载」。
                Button("导入时间名片", systemImage: "tray.and.arrow.down") { importingCard = true }
                    .disabled(store.storageReadOnly)
                Button("添加人物", systemImage: "plus", action: addPerson)
                    .disabled(store.storageReadOnly)
            }
        }
        .onAppear { alignSelection(); refreshDetails() }
        .onChange(of: store.people) { alignSelection(); refreshDetails() }
        .onChange(of: selection) {
            if selection != reminderPersonID { reminderNote = nil; reminderPersonID = nil }
            refreshDetails()
        }
        .onChange(of: core.zones) { refreshDetails() }
        .onChange(of: core.settings.planner.localAvailability) { refreshDetails() }
        .onChange(of: Int(core.referenceDate.timeIntervalSince1970 / 60)) { refreshDetails() }
        .sheet(item: $editing, onDismiss: {
            // 编辑器里点了「移除人物…」：等表单收起再弹确认框（叠在正在收起的 sheet 上会丢）。
            if let pendingRemoval { removing = pendingRemoval; self.pendingRemoval = nil }
        }) { person in
            PeopleEditorView(store: store, original: person, onRemove: { pendingRemoval = person })
                .environment(core).environment(model).environment(\.locale, core.uiLocale)
        }
        .sheet(isPresented: $importingCard) {
            TimeCardImportView(now: core.now) { person in
                importingCard = false
                editing = person
            }
            .environment(\.locale, core.uiLocale)
        }
        .sheet(isPresented: $importing, onDismiss: {
            store.deactivate()
            if let pendingImport { editing = pendingImport; self.pendingImport = nil }
        }) {
            PeopleContactsPicker(store: store) { contact in
                pendingImport = store.people.first(where: { $0.contactIdentifier == contact.id })
                    ?? PersonProfile(name: contact.name, timeZoneID: TimeZone.current.identifier,
                                     contactIdentifier: contact.id)
                importing = false
            }
            .environment(\.locale, core.uiLocale)
        }
        .onAppear {
            #if DEBUG
            if UITestFixture.isActive, ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_COPY_REMIND"] == "1", let first = store.people.first {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(600))
                    remindAtWorkStart(first)
                }
            }
            // 确认框截图：`MEANTIME_UI_TEST_PEOPLE_REMOVE_FIRST=1` 对第一位人物弹出移除确认（只在测试宿主生效）。
            if ProcessInfo.processInfo.environment["MEANTIME_TEST_HOST"] == "1",
               ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_PEOPLE_REMOVE_FIRST"] == "1", let first = store.people.first {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(600))
                    removing = first
                }
            }
            // 编辑器截图：`MEANTIME_UI_TEST_PEOPLE_EDIT_FIRST=1` 打开第一位人物的编辑表单（只在测试宿主生效）。
            if ProcessInfo.processInfo.environment["MEANTIME_TEST_HOST"] == "1",
               ["1", "2"].contains(ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_PEOPLE_EDIT_FIRST"] ?? ""), let first = store.people.first {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(600))
                    editing = first
                }
            }
            #endif
        }
        .confirmationDialog(Text("移除「\(removing?.name ?? "")」？"), isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("移除人物", role: .destructive) {
                if let removing { store.remove(id: removing.id) }
                removing = nil
            }
        } message: { Text("只移除 Dayside 中的记录，不会修改通讯录。") }
        .onDisappear { store.deactivate() }
    }

    // MARK: - 表上的行

    /// 第一行是这台 Mac 的所在地（名字下面写你的工作时段，点了改：与找碰头时间同一个设置），其余每人一行。
    private var rows: [PeopleTable.Row] {
        let availability = core.settings.planner.localAvailability
        var here = PeopleOverlap.localParticipant(availability: availability)
        here.coordinate = SkyPanel.homeCoordinate(zones: core.zones)
        let hours = availability.isWholeDay ? L10n.string("全天", locale: core.uiLocale)
            : ClockText.minuteRange(availability.startMinute, availability.endMinute, hourStyle: core.settings.hourStyle)
        let hereRow = PeopleTable.Row(kind: .here, participant: here, name: core.placeName(forTimeZoneID: TimeZone.current.identifier),
                                      status: nil, hours: hours)
        return [hereRow] + store.people.map { person in
            let work = person.workStatus(at: core.referenceDate, places: core.zones)
            return PeopleTable.Row(kind: .person(person.id), participant: person.plannerParticipant(places: core.zones), name: person.name,
                            status: PeopleStatus(person.callStatus(at: core.referenceDate, places: core.zones,
                                                                   awakeWindow: core.settings.awakeWindow, workStatus: work)),
                            hours: nil, workStatus: work, zoneKnown: TimeZone(identifier: person.resolvedTimeZoneID(places: core.zones)) != nil)
        }
    }

    /// 本机那一行点开的工作时段编辑器（找碰头时间的同一个编辑器、同一个设置）。
    private func hereEditor() -> AnyView {
        AnyView(AvailabilityEditor(title: core.placeName(forTimeZoneID: TimeZone.current.identifier), timeZone: .current,
                                   countryCode: Locale.autoupdatingCurrent.region?.identifier,
                                   availability: Binding(get: { core.settings.planner.localAvailability },
                                                         set: { model.settings.planner.localAvailability = $0 }))
            .environment(\.locale, core.uiLocale))
    }

    private func person(_ id: UUID) -> PersonProfile? { store.people.first { $0.id == id } }
    private var selectedPerson: PersonProfile? { selection.flatMap(person) }

    /// 没选或选的人被删了：选第一个人（细节一直有人可写，选中这件事也就看得见）。
    private func alignSelection() {
        if selection == nil || person(selection!) == nil { selection = store.people.first?.id }
    }

    private func addPerson() {
        editing = PersonProfile(name: "", timeZoneID: TimeZone.current.identifier)
    }

    // MARK: - 选中那个人的细节

    /// 「Ana · 伦敦 · 快 8小时」，下面一行一件事：共同时段、每工作日重叠与她几点下班（不在班时写几点上班，都按你的钟），
    /// 再下面两个动作。
    private func detailSection(_ person: PersonProfile, workStatus: PeopleWorkStatus?) -> some View {
        let identifier = person.resolvedTimeZoneID(places: core.zones)
        let zone = TimeZone(identifier: identifier)
        let place = [core.placeName(forTimeZoneID: identifier),
                     zone.flatMap { PanelRowDetail.fullRelative(timeZone: $0, at: core.referenceDate, locale: core.uiLocale) }]
            .compactMap { $0 }.joined(separator: " · ")
        let facts = details?.personID == person.id ? details : nil
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: person.name)
                    .font(SerifFace.font(person.name, size: (AppFont.size(.title2) * textScale).rounded(), weight: .medium, locale: core.uiLocale))
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: place).appFont(.callout).foregroundStyle(.readableSecondary)
                    .help(Text(verbatim: identifier))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            if let facts {
                sharedWindowLine(facts.shared)
                if let overlap = overlapLine(facts, working: workStatus == .working) { Text(verbatim: overlap) }
            }
            HStack(spacing: 10) {
                Button("编辑人物") { editing = person }
                Button("对方上班时提醒我") { remindAtWorkStart(person) }
            }
            .disabled(store.storageReadOnly)
            .padding(.top, 8)
            if let reminderNote {
                Label(reminderNote, systemImage: "alarm").appFont(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("people-reminder-note")
            }
        }
        .appFont(.callout)
        .monospacedDigit()
    }

    /// 「共同时段 今天 9:00–11:00」：两人都在工作时段内的第一段（本机时间）；7 天内没有就说没有。
    @ViewBuilder private func sharedWindowLine(_ window: SharedWindow?) -> some View {
        if let window {
            let local = TimeZone.current
            let range = TimeFormatting.string(for: window.start, in: local, format: core.settings.clockFormat)
                + "–" + TimeFormatting.string(for: window.end, in: local, format: core.settings.clockFormat)
            switch window.dayOffset {
            case 0: Text("共同时段 今天 \(range)")
            case 1: Text("共同时段 明天 \(range)")
            default: Text("共同时段 \(ClockText.day(window.start, in: local, locale: core.uiLocale)) \(range)")
            }
        } else {
            Text("7 天内没有共同工作时段")
        }
    }

    /// 「每工作日重叠 3小时 · 对方下班 = 你的 14:00」；不在班时后半句写「对方上班 = 你的 10月5日 周一 0:00」（不是今天才写日期）。
    /// 重叠是接下来 7 天里两边都上班的日子的中位数，日子之间不一样时写成范围；一天都没有就不写这一半。
    private func overlapLine(_ facts: Details, working: Bool) -> String? {
        let locale = core.uiLocale
        var parts: [String] = []
        if let typical = facts.summary.typicalMinutes, facts.summary.workdays > 0 {
            if facts.summary.isUniform {
                parts.append(String(format: L10n.string("每工作日重叠 %@", locale: locale),
                                    ClockText.duration(seconds: Double(typical) * 60, locale: locale)))
            } else if let low = facts.summary.minMinutes, let high = facts.summary.maxMinutes {
                let range = ClockText.durationRange(lowSeconds: Double(low) * 60, highSeconds: Double(high) * 60, locale: locale)
                parts.append(String(format: L10n.string("每工作日重叠 %@–%@", locale: locale), range.low, range.high))
            }
        }
        if working, let end = facts.summary.theirDayEnd {
            parts.append(String(format: L10n.string("对方下班 = 你的 %@", locale: locale), localMoment(end)))
        } else if !working, let start = facts.nextStart {
            parts.append(String(format: L10n.string("对方上班 = 你的 %@", locale: locale), localMoment(start)))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 本机钟面上的一刻：与看的那一刻同一天只写钟点，否则带日期与星期。
    private func localMoment(_ date: Date) -> String {
        let time = TimeFormatting.string(for: date, in: .current, format: ClockFormat(hourStyle: core.settings.hourStyle, showSeconds: false))
        let calendar = Calendar.gregorianUTC(.current)
        if calendar.isDate(date, inSameDayAs: core.referenceDate) { return time }
        return "\(ClockText.day(date, in: .current, locale: core.uiLocale, now: core.now, weekday: true)) \(time)"
    }

    private func refreshDetails() {
        guard let person = selectedPerson else { details = nil; return }
        let local = PeopleOverlap.localParticipant(availability: core.settings.planner.localAvailability)
        let participant = person.plannerParticipant(places: core.zones)
        let now = core.referenceDate
        let next = Details(personID: person.id,
                           shared: PeopleOverlap.nextSharedWindow(person: participant, local: local, now: now),
                           summary: PeopleOverlap.summary(person: participant, local: local, now: now),
                           nextStart: PeopleReminder.nextWorkStart(for: person, places: core.zones, now: now))
        if next != details { details = next }
    }

    private func remindAtWorkStart(_ person: PersonProfile) {
        guard let hub = featureHub else { return }
        reminderPersonID = person.id
        selection = person.id
        guard let start = PeopleReminder.nextWorkStart(for: person, places: core.zones, now: core.now) else {
            reminderNote = L10n.string("未来14天里对方都不上班，没有设闹钟。", locale: core.uiLocale)
            return
        }
        var spec = TimerSpec()
        spec.mode = "alarm"
        spec.label = String(format: L10n.string("%@ 上班", locale: core.uiLocale), person.name)
        spec.alarmAt = start.timeIntervalSince1970
        hub.timers.start(spec)
        let local = ClockText.dateTime(start, in: .current, hourStyle: core.settings.hourStyle, locale: core.uiLocale, now: core.now)
        reminderNote = String(format: L10n.string("已设闹钟：%1$@ 上班时（本机 %2$@）。在「计时器」页查看或取消。", locale: core.uiLocale),
                              person.name, local)
    }
}

private struct PeopleContactsPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: PeopleStore
    let select: (PeopleContactCandidate) -> Void
    @State private var query = ""

    private var filteredContacts: [PeopleContactCandidate] {
        struct Input: Encodable { let names: [String]; let query: String }
        let indices: [Int] = RustCore.invoke("people.filter_contacts", Input(names: store.contacts.map(\.name), query: query))
        return indices.compactMap { store.contacts.indices.contains($0) ? store.contacts[$0] : nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("从通讯录选择").appFont(.title2)
            Text("仅读取姓名用于选择。保存后，Dayside 保留所选姓名与通讯录标识；所在地和作息由你填写。")
                .appFont(.callout).foregroundStyle(.readableSecondary)
            switch store.contactsState {
            case .loading:
                ProgressView("正在读取姓名…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .denied:
                ContentUnavailableView("未获通讯录权限", systemImage: "person.crop.rectangle.badge.xmark",
                                       description: Text("你仍可手工添加人物。若要导入，可在系统设置中允许 Dayside 访问通讯录。"))
            case .failed:
                ContentUnavailableView("暂时无法读取通讯录", systemImage: "exclamationmark.triangle",
                                       description: Text("请稍后重试，或手工添加人物。"))
            case .ready:
                TextField("搜索姓名", text: $query).textFieldStyle(.roundedBorder)
                if filteredContacts.isEmpty {
                    ContentUnavailableView("没有匹配的姓名", systemImage: "magnifyingglass")
                } else {
                    List(filteredContacts) { contact in
                        Button { select(contact) } label: {
                            Text(contact.name).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                        }.buttonStyle(.plain)
                    }
                }
            case .idle: EmptyView()
            }
            HStack {
                if store.contactsState == .failed || store.contactsState == .denied {
                    Button("重试") { store.beginContactsImport() }
                }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24).frame(minWidth: 440, idealWidth: 500, minHeight: 380, idealHeight: 520)
    }
}

private struct TimeCardImportView: View {
    @Environment(TimeCore.self) private var core
    @Environment(\.dismiss) private var dismiss
    let now: Date
    let accept: (PersonProfile) -> Void
    @State private var text = ""
    @State private var failure: String?
    @State private var expiredNotice = false
    /// Sender's tzdata release when it is older than this Mac's: their windows may be an hour off.
    @State private var olderSenderRelease: (theirs: String, ours: String)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("导入时间名片").appFont(.title2)
            Text("粘贴对方用 Dayside 分享的链接或片段。地点和作息会变成一位人物，两台 Mac 各自算重叠，不经过任何服务器。")
                .appFont(.callout).foregroundStyle(.readableSecondary)
            TextEditor(text: $text)
                .font(.body.monospaced())
                .frame(minHeight: 90)
                .accessibilityLabel(Text("时间名片内容"))
                .onChange(of: text) { previewCard() }
            if let olderSenderRelease {
                Text("对方生成名片时的时区数据 \(olderSenderRelease.theirs) 比本机的 \(olderSenderRelease.ours) 旧，可约时段可能差 1 小时。")
                    .appFont(.caption)
            }
            if failure != nil {
                ErrorLine(Text("无法读取这张时间名片。")).appFont(.caption)
            } else if expiredNotice {
                Text("这张时间名片已过期，作息仍可导入。").appFont(.caption).foregroundStyle(.readableSecondary)
            }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("导入") { importCard() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 440)
    }

    /// 粘贴时先显示过期与时区数据提示。
    private func previewCard() {
        failure = nil
        expiredNotice = false
        olderSenderRelease = nil
        guard case .success(let imported) = TimeCard.person(from: text, now: now) else { return }
        expiredNotice = imported.expired
        guard let theirs = imported.senderTZData, let ours = TZDataCheck.installedVersion, theirs < ours else { return }
        olderSenderRelease = (theirs, ours)
    }

    private func importCard() {
        switch TimeCard.person(from: text, now: now) {
        case .success(let imported):
            var person = PersonProfile(imported.contact)
            if person.name.isEmpty { person.name = L10n.string("时间名片", locale: core.uiLocale) }
            failure = nil
            accept(person)
        case .failure(let error):
            failure = error.code
        }
    }
}
