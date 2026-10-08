// SPDX-License-Identifier: GPL-3.0-only
//
//  PlannerPage.swift
//  TahoeTime
//
//  找碰头时间（工具窗那一页）。魂是公平：谁在为这场会熬夜，要被看见。
//  页面像一句话：「洛杉矶、伦敦和东京 · 1小时 · 10月2日 周五起 · 7天」，下面是答案。
//  每一个候选旁边只写在工作时段外的人和他那边的钟点（「☾东京 22:00」）；没有大家都在的时刻时，
//  首屏就是最接近的三种分法（Rust `planner.options`：每种是另一批人各让一点），不用先打开轮换。
//  一次只开一种解法：一次 / 例会轮换 / 拆成几场，用一个分段控件切；三种都是「一列候选 + 选中那一个画在共同时间轴上」。
//  常用组合收进参与者的弹出框，理想时段收进范围菜单。
//
//  资源：工具窗关着时这些都不存在；候选在参与者、时长、范围、偏好变了时在后台算一次（Rust），
//  表上的天与工作时段只在框或参与者变了时算（`MeetingTable`）。页面里没有 Canvas、Grid、阴影、材质。
//

import AppKit
import SwiftUI

struct PlannerPage: View {
    enum Mode: String, CaseIterable, Identifiable, Hashable {
        case once, rotate, split
        var id: Self { self }
        /// 分段控件上的字要短（「例会轮换」「拆成几场」在别处的长译名放不进三段），所以另有三个键。
        var title: LocalizedStringKey {
            switch self {
            case .once: "安排方式：一次"
            case .rotate: "安排方式：例会轮换"
            case .split: "安排方式：拆成几场"
            }
        }
    }

    /// 参与者行（本机或某个地点、某个人物）。`zoneID == nil` 且 `personID == nil` 是本机。
    struct Participant: Identifiable, Hashable {
        let zoneID: UUID?
        let name: String
        let timeZoneID: String
        let countryCode: String?
        let availability: Availability
        let participates: Bool
        var personID: UUID? = nil
        var workingWeekdays: [Int]? = nil
        var vacations: [OverlapPlanner.Vacation] = []
        var coordinate: Coordinate? = nil
        var offsetOnlyZoneName = false
        var id: String { personID?.uuidString ?? zoneID?.uuidString ?? "local" }
        var timeZone: TimeZone { TimeZone(identifier: timeZoneID) ?? .current }
    }

    /// 候选只在这些变了时重算。
    struct Inputs: Hashable {
        let participants: [OverlapPlanner.Participant]
        let fromDay: Date
        let notBefore: Date
        let days: Int
        let duration: Int
        let localTZ: String
        let canPlan: Bool
        var idealWindow: IdealWindow? = nil
        var clockWeight = "gentle"
    }

    private struct Computed: Equatable {
        let inputs: Inputs
        let value: OverlapPlanner.Options
    }

    private struct Feedback: Equatable {
        let start: Date
        let kind: String
        var title: String? = nil
    }

    @Environment(AppModel.self) private var model
    @Environment(TimeCore.self) private var core
    @Environment(\.locale) private var locale
    @Environment(\.featureHub) private var featureHub
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool {
        #if DEBUG
        PerformanceProbe.isRequested ? false : systemReduceMotion
        #else
        systemReduceMotion
        #endif
    }

    @State private var mode: Mode = .once
    @State private var selectedPeople: Set<UUID> = []
    @State private var overlaps: [String: OverlapSummary] = [:]
    @State private var staleZones: Set<String> = []
    @State private var computed: Computed?
    @State private var selection: Date?
    @State private var chosenDay: Date?
    @State private var peek: Date?
    @State private var isExporting = false
    @State private var feedback: Feedback?
    @State private var editingPerson: PersonProfile?
    @State private var showingParticipants = false
    @State private var showingCalendar = false
    @State private var namingGroup = false
    @State private var newGroupName = ""
    @State private var addingPlace = false
    #if DEBUG
    @State private var fixtureSelect: Int?
    @State private var fixturePeek: Double?
    #endif

    private var localTimeZone: TimeZone { .autoupdatingCurrent }
    private var format: ClockFormat { ClockFormat(hourStyle: core.settings.hourStyle, showSeconds: false) }

    var body: some View {
        let rows = participantRows
        let inputs = inputs(from: rows)
        VStack(alignment: .leading, spacing: 0) {
            subject(rows: rows, inputs: inputs)
            Picker("安排方式", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.top, 14)
            staleWarning(inputs)
            if inputs.canPlan {
                let context = context(rows: rows, inputs: inputs)
                switch mode {
                case .once:
                    once(inputs: inputs, rows: rows).padding(.top, 22)
                case .rotate:
                    RotationView(context: context).padding(.top, 18)
                case .split:
                    SplitSessionsView(context: context).padding(.top, 18)
                }
            } else {
                emptyState(rows).padding(.top, 22)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            staleZones = Set(TZDataCheck.currentReport().stale.map(\.zone))
            #if DEBUG
            // 截图与转储夹具（只在测试宿主）：`MEANTIME_UI_TEST_PLANNER_MODE=rotate|split` 打开时就是那一种解法。
            if ApplicationSession.isTesting {
                let environment = ProcessInfo.processInfo.environment
                if let raw = environment["MEANTIME_UI_TEST_PLANNER_MODE"], let fixture = Mode(rawValue: raw) { mode = fixture }
                // `MEANTIME_UI_TEST_PLANNER_SELECT=<序号>` 选中第几项；`MEANTIME_UI_TEST_PLANNER_PEEK_HOURS=<小时>` 在表上试那一场前后那么多小时。
                fixtureSelect = environment["MEANTIME_UI_TEST_PLANNER_SELECT"].flatMap(Int.init)
                fixturePeek = environment["MEANTIME_UI_TEST_PLANNER_PEEK_HOURS"].flatMap(Double.init)
            }
            #endif
        }
        .task(id: overlapKey) { refreshOverlaps(participantRows) }
        .task(id: mode == .once ? inputs : nil) {
            guard mode == .once, inputs.canPlan else { return }
            let request = OverlapPlanner.Request(participants: inputs.participants, from: inputs.notBefore,
                                                 days: inputs.days, durationMinutes: inputs.duration,
                                                 localTimeZoneID: inputs.localTZ, idealWindow: inputs.idealWindow)
            let weight = inputs.clockWeight
            let value = await Task.detached(priority: .userInitiated) { OverlapPlanner.options(request, clockWeight: weight) }.value
            guard !Task.isCancelled else { return }
            computed = Computed(inputs: inputs, value: value)
            #if DEBUG
            if let index = fixtureSelect, value.options.indices.contains(index) { selection = value.options[index].id; fixtureSelect = nil }
            if let hours = fixturePeek, let first = (value.options.first { $0.id == selection } ?? value.options.first) {
                try? await Task.sleep(for: .milliseconds(50))
                peek = first.best.addingTimeInterval(hours * 3600)
                fixturePeek = nil
            }
            #endif
        }
        .onChange(of: featureHub?.panelPlannerRequest, initial: true) { _, request in
            guard let request, request != 0 else { return }
            selectedPeople.removeAll()
            mode = .once
        }
        .onChange(of: selection) { chosenDay = nil; peek = nil; feedback = nil }
        .onChange(of: chosenDay) { peek = nil; feedback = nil }
        .onChange(of: peek) { feedback = nil }
        .onChange(of: mode) { peek = nil; feedback = nil }
        .sheet(item: $editingPerson) { person in
            if let store = featureHub?.people {
                PeopleEditorView(store: store, original: person).environment(core).environment(model)
                    .environment(\.locale, core.uiLocale)
            }
        }
        .sheet(isPresented: $namingGroup) { groupNamingSheet(rows) }
    }

    // MARK: - 输入

    /// 重叠只在这些变化时重算（小时粒度够了：工作时段是墙钟）。
    private var overlapKey: String {
        let rows = participantRows.map { "\($0.id)|\($0.timeZoneID)|\($0.availability)|\($0.workingWeekdays ?? [])|\($0.vacations.count)" }
        return (rows + ["\(core.settings.planner.localAvailability)", "\(Int(core.referenceDate.timeIntervalSince1970 / 3600))",
                        localTimeZone.identifier]).joined(separator: "#")
    }

    private var participantRows: [Participant] {
        let prefs = core.settings.planner
        let facts = core.zones.map {
            PresentationCore.PlannerZoneFact(id: $0.id, timeZoneId: $0.timezoneID, customName: $0.customName,
                                             cityName: $0.cityName, localizedCity: core.localizedCity($0))
        }
        let choices: [PresentationCore.PlannerRowChoice] = PresentationCore.call("planner_rows",
            PresentationCore.PlannerRowsInput(zones: facts, excluded: prefs.excludedZoneIDs,
                localTimeZoneId: localTimeZone.identifier,
                localName: String(format: L10n.string("本机（%@）", locale: locale), core.placeName(forTimeZoneID: localTimeZone.identifier)),
                includeLocal: prefs.includeLocal))
        let places = choices.map { choice in
            if choice.sourceIndex < 0 {
                // 本机的坐标：列表里有本机所在地就用它的，否则用随包 tzcoords 的代表城市（不碰城市索引）。
                let localCoordinate = core.zones.first { $0.timezoneID == localTimeZone.identifier }?.coordinate
                    ?? ZoneCatalog.shared.knownCoordinate(for: localTimeZone.identifier)
                return Participant(zoneID: nil, name: choice.name, timeZoneID: localTimeZone.identifier,
                                   countryCode: Locale.autoupdatingCurrent.region?.identifier,
                                   availability: prefs.localAvailability, participates: choice.participates, coordinate: localCoordinate)
            }
            let zone = core.zones[choice.sourceIndex]
            return Participant(zoneID: zone.id, name: choice.name, timeZoneID: zone.timezoneID,
                               countryCode: zone.countryCode, availability: zone.effectiveAvailability, participates: choice.participates,
                               coordinate: zone.coordinate, offsetOnlyZoneName: zone.offsetOnlyZoneName)
        }
        let people = (featureHub?.savedPeople ?? []).map { person in
            let participant = person.plannerParticipant(places: core.zones)
            return Participant(zoneID: person.id, name: person.name, timeZoneID: participant.timeZoneID,
                               countryCode: participant.countryCode, availability: participant.availability,
                               participates: selectedPeople.contains(person.id), personID: person.id,
                               workingWeekdays: participant.workingWeekdays, vacations: participant.vacations,
                               coordinate: participant.coordinate, offsetOnlyZoneName: participant.offsetOnlyZoneName)
        }
        return places + people
    }

    private func inputs(from rows: [Participant]) -> Inputs {
        let prefs = core.settings.planner
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = localTimeZone
        let fromDay = calendar.startOfDay(for: core.referenceDate)
        let selected: PresentationCore.PlannerInputChoice = PresentationCore.call("planner_inputs",
            PresentationCore.PlannerInputFacts(rows: rows.map { .init(id: $0.zoneID, participates: $0.participates) },
                calendar: .init(fromDay: fromDay, now: core.now, timeZone: localTimeZone)))
        let participants = selected.participants.map { choice in
            let row = rows[choice.index]
            return OverlapPlanner.Participant(id: choice.id, name: row.name, timeZoneID: row.timeZoneID,
                                              availability: row.availability, countryCode: row.countryCode,
                                              workingWeekdays: row.workingWeekdays, vacations: row.vacations,
                                              coordinate: row.coordinate, offsetOnlyZoneName: row.offsetOnlyZoneName)
        }
        return Inputs(participants: participants, fromDay: fromDay,
                      notBefore: Date(timeIntervalSince1970: selected.notBefore), days: prefs.daysAhead,
                      duration: prefs.durationMinutes, localTZ: localTimeZone.identifier, canPlan: selected.canPlan,
                      idealWindow: prefs.idealWindow, clockWeight: prefs.rotation.clockWeight)
    }

    /// 三种解法共用的东西：参与者、表上的每一行、看哪几天、多长。
    private func context(rows: [Participant], inputs: Inputs) -> PlannerContext {
        PlannerContext(participants: inputs.participants, rows: tableRows(rows: rows, participants: inputs.participants),
                       fromDay: inputs.fromDay, notBefore: inputs.notBefore, days: inputs.days, duration: inputs.duration,
                       localTZ: inputs.localTZ, editor: editor(rows), onEditSheet: editSheet)
    }

    /// 表上每人一行：名字、自己钟面上的工作时段、后面一句（本机那一行写「本机」，别的地点写每工作日与你重叠多久，人物也写）。
    private func tableRows(rows: [Participant], participants: [OverlapPlanner.Participant]) -> [MeetingTable.Row] {
        // 「本机」只写在代表这台 Mac 的那一行：没有本机所在地时是「本机（洛杉矶）」那一行，有时是列表里第一个在本机时区的地点。
        let here = rows.first { $0.personID == nil && $0.timeZoneID == localTimeZone.identifier }?.id
        return participants.map { participant in
            let row = rows.first { ($0.personID ?? $0.zoneID) == participant.id } ?? rows.first { $0.zoneID == nil && $0.personID == nil && participant.timeZoneID == $0.timeZoneID }
            let note: String? = row?.id == here ? L10n.string("本机", locale: locale) : row.flatMap { overlapText($0) }
            return MeetingTable.Row(id: row?.id ?? participant.id.uuidString, participant: participant, name: participant.name,
                                    hours: hoursText(participant.availability), note: note,
                                    editing: row == nil ? .none : (row?.personID != nil ? .sheet : .popover))
        }
    }

    private func editor(_ rows: [Participant]) -> (MeetingTable.Row) -> AnyView {
        { tableRow in
            guard let row = rows.first(where: { $0.id == tableRow.id }) else { return AnyView(EmptyView()) }
            return AnyView(AvailabilityEditor(title: row.name, timeZone: row.timeZone, countryCode: row.countryCode,
                                              availability: availabilityBinding(row))
                .environment(\.locale, core.uiLocale))
        }
    }

    private func editSheet(_ row: MeetingTable.Row) {
        editingPerson = featureHub?.savedPeople.first { $0.id.uuidString == row.id }
    }

    // MARK: - 主语行：谁 · 多长 · 从哪天起 · 几天

    private func subject(rows: [Participant], inputs: Inputs) -> some View {
        SubjectFlowLayout(spacing: 8, lineSpacing: 4) {
            participantsButton(rows)
            SubjectDot()
            durationMenu
            // 轮换也从这一天起排（第一次落在它之后的那个星期几）；看几天只对一次与拆场有意义。
            SubjectDot()
            dayChip(inputs)
            if mode != .rotate {
                SubjectDot()
                rangeMenu
            }
        }
    }

    private func participantsButton(_ rows: [Participant]) -> some View {
        let names = rows.filter(\.participates).map(\.name)
        let label = names.isEmpty ? L10n.string("选择参与者", locale: locale) : Self.nameList(names, locale: locale)
        return Button { showingParticipants = true } label: {
            PlannerMenuLabel(text: label, serif: true)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("参与者"))
                .accessibilityValue(Text(verbatim: label))
        }
        .buttonStyle(.plain)
        .help(Text("参与者"))
        .popover(isPresented: $showingParticipants, arrowEdge: .bottom) {
            participantsPopover(rows)
        }
    }

    /// 弹出框：勾选谁参加（地点在上、人物在下），底下是常用组合。
    private func participantsPopover(_ rows: [Participant]) -> some View {
        let places = rows.filter { $0.personID == nil }
        let people = rows.filter { $0.personID != nil }
        return VStack(alignment: .leading, spacing: 8) {
            Text("参与者").appFont(.headline).accessibilityAddTraits(.isHeader)
            ForEach(places) { row in
                Toggle(isOn: participationBinding(row)) { Text(verbatim: row.name) }
            }
            if !people.isEmpty {
                Divider().padding(.vertical, 2)
                ForEach(people) { row in
                    Toggle(isOn: participationBinding(row)) { Text(verbatim: row.name) }
                }
            }
            Divider().padding(.vertical, 2)
            groupsMenu(rows)
        }
        .toggleStyle(.checkbox)
        .padding(14)
        .frame(minWidth: 220, alignment: .leading)
        .environment(\.locale, core.uiLocale)
    }

    private var durationMenu: some View {
        let current = core.settings.planner.durationMinutes
        let label = Self.durationText(current, locale: locale)
        return Menu {
            ForEach(PlannerPreferences.durationChoices, id: \.self) { minutes in
                Button { model.settings.planner.durationMinutes = minutes } label: {
                    checked(Self.durationText(minutes, locale: locale), minutes == current)
                }
            }
        } label: {
            PlannerMenuLabel(text: label)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("时长"))
                .accessibilityValue(Text(verbatim: label))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help(Text("时长"))
    }

    /// 从哪天起：看的那一刻在本机是哪一天，点开是系统日历；换一天 = 把整个 App 看的那一刻挪过去（本机钟点不变），
    /// 与太阳与月亮、换算页的日期同一个做法。
    private func dayChip(_ inputs: Inputs) -> some View {
        let day = ClockText.day(inputs.fromDay, in: localTimeZone, locale: locale, now: core.now, weekday: true)
        let label = String(format: L10n.string("%@起", locale: locale), day)
        return Button { showingCalendar = true } label: {
            PlannerMenuLabel(text: label)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("从哪天起"))
                .accessibilityValue(Text(verbatim: day))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(Text("从哪天起"))
        .popover(isPresented: $showingCalendar, arrowEdge: .bottom) {
            DatePicker("从哪天起", selection: Binding(get: { core.referenceDate }, set: { model.jump(to: $0) }),
                       in: Self.supportedDays, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .padding()
                .environment(\.timeZone, localTimeZone)
                .environment(\.locale, core.uiLocale)
        }
    }

    /// 与太阳与月亮、换算页同一个范围（1800–2100 年，两头各让一天）。
    private static let supportedDays = Date(timeIntervalSince1970: -5_364_576_000)...Date(timeIntervalSince1970: 4_133_894_400)

    /// 几天，理想时段也在这个菜单里（偏好「几点开」与「看几天」是同一件事：什么时候）。设了理想时段，标签后面写出来。
    private var rangeMenu: some View {
        let prefs = core.settings.planner
        var label = String(format: L10n.string("%lld 天", locale: locale), locale: locale, Int64(prefs.daysAhead))
        if let ideal = prefs.idealWindow {
            label += " · " + String(format: L10n.string("优先 %@", locale: locale), idealText(ideal))
        }
        return Menu {
            Section("范围") {
                ForEach(PlannerPreferences.daysChoices, id: \.self) { days in
                    Button { model.settings.planner.daysAhead = days } label: {
                        checked(String(format: L10n.string("%lld 天", locale: locale), locale: locale, Int64(days)), days == prefs.daysAhead)
                    }
                }
            }
            Section("理想时段") {
                Button { model.settings.planner.idealWindow = nil } label: {
                    checked(L10n.string("不限", locale: locale), prefs.idealWindow == nil)
                }
                ForEach(IdealWindow.presets, id: \.self) { window in
                    Button { model.settings.planner.idealWindow = window } label: {
                        checked(idealText(window), prefs.idealWindow == window)
                    }
                }
            }
        } label: {
            PlannerMenuLabel(text: label)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("范围"))
                .accessibilityValue(Text(verbatim: label))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help(Text("落在这段本机时间里的候选排前面；不改变哪些时段可约。"))
    }

    private func checked(_ title: String, _ on: Bool) -> some View {
        Group {
            if on { Label(title, systemImage: "checkmark") } else { Text(verbatim: title) }
        }
    }

    private func idealText(_ window: IdealWindow) -> String {
        ClockText.range(Self.minuteText(window.startMinute, style: core.settings.hourStyle),
                        Self.minuteText(window.endMinute, style: core.settings.hourStyle))
    }

    // MARK: - 常用组合（在参与者的弹出框里）

    /// 组合 = 当前参与的地点与人物 + 当前理想时段。最多 20 组（Rust `settings.planner_groups` 封顶）。
    @ViewBuilder private func groupsMenu(_ rows: [Participant]) -> some View {
        let groups = core.settings.planner.groups
        Menu {
            ForEach(groups) { group in
                Button(group.name) { apply(group, rows: rows) }
            }
            if !groups.isEmpty { Divider() }
            Button("保存当前为组合…") { newGroupName = ""; showingParticipants = false; namingGroup = true }
                .disabled(groups.count >= 20)
            if !groups.isEmpty {
                Menu("删除组合") {
                    ForEach(groups) { group in
                        Button(group.name, role: .destructive) { model.settings.planner.groups.removeAll { $0.id == group.id } }
                    }
                }
            }
        } label: {
            Label("组合", systemImage: "person.2.square.stack")
        }
        .menuStyle(.button)
        .fixedSize()
        .help(Text("保存常用的参与者组合，一键切换"))
    }

    private func groupNamingSheet(_ rows: [Participant]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("保存当前组合").appFont(.headline)
            TextField("组合名称", text: $newGroupName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { saveGroup(rows: rows) }
            Text("记下现在勾选的地点与人物，以及理想时段。")
                .appFont(.caption).foregroundStyle(.readableSecondary)
            HStack {
                Spacer()
                Button("取消") { namingGroup = false }.keyboardShortcut(.cancelAction)
                Button("保存") { saveGroup(rows: rows) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newGroupName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
        .environment(\.locale, core.uiLocale)
    }

    private func saveGroup(rows: [Participant]) {
        let name = newGroupName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let zoneIDs = rows.filter { $0.participates && $0.personID == nil }.compactMap(\.zoneID)
        let personIDs = rows.filter { $0.participates }.compactMap(\.personID)
        model.settings.planner.groups.append(PlannerGroup(id: UUID(), name: String(name.prefix(60)), zoneIDs: zoneIDs, personIDs: personIDs,
                                                          idealWindow: core.settings.planner.idealWindow))
        namingGroup = false
    }

    private func apply(_ group: PlannerGroup, rows: [Participant]) {
        let zones = Set(group.zoneIDs)
        for row in rows where row.personID == nil {
            if let id = row.zoneID { model.setParticipates(id: id, zones.contains(id)) }
        }
        selectedPeople = Set(group.personIDs)
        model.settings.planner.idealWindow = group.idealWindow
    }

    // MARK: - 一次：结论、候选、共同时间轴、动作

    @ViewBuilder
    private func once(inputs: Inputs, rows: [Participant]) -> some View {
        if let computed {
            let stale = computed.inputs != inputs
            let value = computed.value
            let selected = value.options.first { $0.id == selection } ?? value.options.first
            VStack(alignment: .leading, spacing: 0) {
                verdict(value)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(value.options) { option in
                        // 小字（可以开始的范围、同一时间也行的日子）只写在选中的那一行：几行写同一句只是噪音。
                        PlannerSlotRow(glyph: option.tier == .everyone ? .everyone : .closest,
                                       start: option.best, end: option.bestEnd,
                                       trailing: .payers(option.fits),
                                       caption: option.id == selected?.id ? caption(option) : nil,
                                       selected: option.id == selected?.id,
                                       choosable: value.options.count > 1) {
                            selection = option.id
                        }
                    }
                }
                // 候选变了顺序（换了人、时长、范围）时短短地挪过去；减弱动态效果时直接换。
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: value.options.map(\.id))
                .padding(.top, 8)
                if let selected {
                    let day = shownDay(selected)
                    let tableRows = tableRows(rows: rows, participants: computed.inputs.participants)
                    MeetingTable(rows: tableRows, start: day, durationMinutes: selected.durationMinutes, days: selected.days,
                                 onDay: { chosenDay = $0 }, peek: $peek, editor: editor(rows), onEditSheet: editSheet)
                        .padding(.top, 24)
                    MeetingLegend(sky: computed.inputs.participants.contains { $0.coordinate != nil },
                                  outside: selected.tier != .everyone || peek != nil)
                        .padding(.top, 10)
                    actions(option: selected, day: day, participants: computed.inputs.participants, stale: stale)
                        .padding(.top, 14)
                }
            }
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity)
        }
    }

    /// 一句结论：大家都在的有几项，或者没有、以下是最接近的（谁在付写在每一项后面），或者这几天排不出（有人休息）。
    @ViewBuilder
    private func verdict(_ value: OverlapPlanner.Options) -> some View {
        Group {
            if value.options.isEmpty {
                Text("这几天排不出：有人休息。可以多看几天，或换一天开始。")
            } else if value.everyone {
                Text("所有人都合适")
            } else {
                Text("没有所有人都在工作时段内的时刻。以下最接近，但有人在时段外：")
            }
        }
        .appFont(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
    }

    /// 候选下面那一行小字：可以开始的范围（比会长时）与同一个钟点也行的其余日子。
    private func caption(_ option: OverlapPlanner.Option) -> String? {
        var parts: [String] = []
        if option.end.timeIntervalSince(option.start) > TimeInterval(option.durationMinutes * 60) + 1 {
            parts.append(String(format: L10n.string("可选范围 %@", locale: locale), PlannerText.interval(option.start, option.end, format: format, locale: locale)))
        }
        if let others = PlannerText.otherDays(option.days, first: option.best, locale: locale, now: core.now) {
            parts.append(others)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 选中那一项看哪一天：表上「哪一天」挑过就按挑的，否则是它最早的那天。
    private func shownDay(_ option: OverlapPlanner.Option) -> Date {
        if let chosenDay, option.days.contains(chosenDay) { return chosenDay }
        return option.best
    }

    // MARK: 动作：加入日历、复制、图片、在面板里看这一刻

    /// 都按表上正在显示的那一场：试过别的钟点就是试的那一个。
    private func actions(option: OverlapPlanner.Option, day: Date, participants: [OverlapPlanner.Participant],
                         stale: Bool) -> some View {
        let start = peek ?? day
        let window = peek.map { peekWindow(start: $0, option: option, participants: participants) } ?? option.window(startingAt: day)
        return VStack(alignment: .leading, spacing: 6) {
            PlannerActionButtons(stale: stale, isExporting: isExporting,
                                 onReturnToOriginal: peek == nil ? nil : { peek = nil },
                                 onAddToCalendar: { Task { await addToCalendar(window) } },
                                 onCopyTimes: { copy(window) },
                                 onImage: { image(window, save: $0) },
                                 onJump: { model.jump(to: start) })
            if let feedback, feedback.start == start {
                feedbackText(feedback).appFont(.callout)
            }
        }
    }

    /// 试的那个钟点也能加进日历、复制：处境按表上算的（`planner.fit`）。
    private func peekWindow(start: Date, option: OverlapPlanner.Option, participants: [OverlapPlanner.Participant]) -> OverlapPlanner.Window {
        let from = start.addingTimeInterval(-86_400 * 2), to = start.addingTimeInterval(86_400 * 2)
        let intervals = participants.map { OverlapPlanner.availabilityIntervals(for: $0, coveringFrom: from, to: to) }
        let fits = OverlapPlanner.fits(intervals: intervals, participants: participants, start: start, durationMinutes: option.durationMinutes)
        let everyone = fits.allSatisfy { if case .inside = $0.fit { return true } else { return false } }
        return OverlapPlanner.Window(tier: everyone ? .everyone : .compromise, start: start,
                                     end: start.addingTimeInterval(TimeInterval(option.durationMinutes * 60)),
                                     best: start, durationMinutes: option.durationMinutes, score: 0, fits: fits)
    }

    private func event(for window: OverlapPlanner.Window) -> MeetingEvent {
        MeetingEvent.make(window: window,
                          names: window.fits.map(\.participant.name),
                          timeZones: window.fits.map(\.participant.timeZone),
                          offsetOnlyZoneNames: window.fits.map(\.participant.offsetOnlyZoneName),
                          title: L10n.string("会议", locale: locale),
                          footer: L10n.string("用 Dayside 规划", locale: locale),
                          locale: locale, hourStyle: core.settings.hourStyle)
    }

    private func addToCalendar(_ window: OverlapPlanner.Window) async {
        guard !isExporting else { return }
        isExporting = true
        defer { isExporting = false }
        switch await CalendarExporter.export(event(for: window)) {
        case let .added(title): feedback = Feedback(start: window.best, kind: "added", title: title)
        case .openedICS: feedback = Feedback(start: window.best, kind: "openedICS")
        case .failed: feedback = Feedback(start: window.best, kind: "failed")
        }
    }

    private func copy(_ window: OverlapPlanner.Window) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(event(for: window).notes, forType: .string)
        feedback = Feedback(start: window.best, kind: "copied")
        AccessibilityNotification.Announcement(L10n.string("已复制", locale: locale)).post()
    }

    /// 一张 PNG 卡片：标题「会议」、本机日期与时段、各地时间行、署名，顶上是会议开始那一刻的昼夜地图。
    private func image(_ window: OverlapPlanner.Window, save: Bool) {
        let e = event(for: window)
        let places = window.fits.compactMap { fit -> WorldMapPlace? in
            guard let c = fit.participant.coordinate else { return nil }
            return WorldMapPlace(latitude: c.latitude, longitude: c.longitude, home: fit.participant.timeZone.identifier == localTimeZone.identifier)
        }
        let card = TimeCardImage.Card(
            title: e.title,
            subtitle: ClockText.dateTime(e.start, in: .autoupdatingCurrent, hourStyle: core.settings.hourStyle, locale: locale)
                + "–" + ClockText.time(e.end, in: .autoupdatingCurrent, hourStyle: core.settings.hourStyle),
            lines: e.lines.map { TimeCardImage.Line(name: $0.name, text: $0.text) },
            footer: e.footer,
            map: places.isEmpty ? nil : TimeCardImage.Map(instant: e.start, places: places))
        let done = save
            ? TimeCardImage.save(card, suggestedName: L10n.string("会议", locale: locale) + "-" + ClockText.day(e.start, in: .autoupdatingCurrent, locale: locale), locale: locale)
            : TimeCardImage.copy(card, locale: locale)
        if done, !save { feedback = Feedback(start: window.best, kind: "copiedImage") }
    }

    @ViewBuilder
    private func feedbackText(_ feedback: Feedback) -> some View {
        switch feedback.kind {
        case "added": Label("已加入日历「\(feedback.title ?? "")」", systemImage: "checkmark.circle")
        case "openedICS": Label("已交给日历 app 打开", systemImage: "arrow.up.forward.app")
        case "copied": Label("已复制", systemImage: "checkmark.circle")
        case "copiedImage": Label("已复制图片", systemImage: "checkmark.circle")
        case "failed": ErrorLine(Text("加入日历失败。可以改用「复制」把各地时间贴进日历，或在系统设置的「隐私与安全性 › 日历」里检查权限。"))
        default: EmptyView()
        }
    }

    // MARK: - 其余：时区数据、空态、参与者的开关与时段

    @ViewBuilder
    private func staleWarning(_ inputs: Inputs) -> some View {
        let affected = inputs.participants.filter { staleZones.contains($0.timeZoneID) }
        if !affected.isEmpty {
            // 本机的时区数据比某处的规则变更旧（见夏令时页）：这几处的每个时段都可能差一小时。
            Label {
                Text("本机时区数据可能过期，\(Self.nameList(affected.map(\.name), locale: locale)) 的时段可能差 1 小时；更新 macOS 后再核。")
            } icon: { Image(systemName: "exclamationmark.triangle") }
            .appFont(.callout)
            .foregroundStyle(.readableSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("planner-tzdata-warning")
            .padding(.top, 12)
        }
    }

    /// 空态指出去处：至少两个参与者；一个地点都没有时给一个能点的「添加地点…」，弹出面板同款搜索框。
    /// 已经有两个以上可选的人时，只差勾选：指向上面的名字；不够两个时才给「添加地点…」。
    @ViewBuilder
    private func emptyState(_ rows: [Participant]) -> some View {
        if rows.count >= 2 {
            Text("至少选择两个参与者：点上面的名字勾选。")
                .appFont(.callout).foregroundStyle(.readableSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("至少选择两个地点或人物。在菜单栏面板添加地点，或在「人物时钟」添加人物。")
                    .appFont(.callout).foregroundStyle(.readableSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("添加地点…") { addingPlace = true }
                    .popover(isPresented: $addingPlace, arrowEdge: .bottom) {
                        AddZoneField()
                            .environment(model)
                            .environment(\.locale, core.uiLocale)
                            .frame(width: 320)
                            .padding(12)
                    }
            }
        }
    }

    /// 「重叠 3 小时」：这一位与本机每工作日重叠多久（调研 #6，人物页写的是同一个数字）。本机那一行不写（毛病表 22）。
    private func overlapText(_ row: Participant) -> String? {
        guard let summary = overlaps[row.id], let typical = summary.typicalMinutes, summary.workdays > 0 else { return nil }
        if summary.isUniform {
            return String(format: L10n.string("重叠 %@", locale: locale), ClockText.duration(seconds: Double(typical) * 60, locale: locale))
        }
        guard let low = summary.minMinutes, let high = summary.maxMinutes else { return nil }
        let range = ClockText.durationRange(lowSeconds: Double(low) * 60, highSeconds: Double(high) * 60, locale: locale)
        return String(format: L10n.string("重叠 %@–%@", locale: locale), range.low, range.high)
    }

    /// 重算重叠：参与者的时区与作息、本机作息、以及小时（不必每分钟重算）任一变化就重来。
    /// 地点在本机时区里的那几行不算（那是与自己重叠，毛病表 22）；人物照算（同一个时区，作息可以不同）。
    private func refreshOverlaps(_ rows: [Participant]) {
        let local = PeopleOverlap.localParticipant(availability: core.settings.planner.localAvailability,
                                                   timeZoneID: localTimeZone.identifier)
        var result: [String: OverlapSummary] = [:]
        for row in rows where row.personID != nil || (row.zoneID != nil && row.timeZoneID != localTimeZone.identifier) {
            let participant = OverlapPlanner.Participant(id: row.personID ?? row.zoneID ?? UUID(), name: row.name,
                                                         timeZoneID: row.timeZoneID, availability: row.availability,
                                                         countryCode: row.countryCode,
                                                         workingWeekdays: row.workingWeekdays,
                                                         vacations: row.vacations)
            result[row.id] = PeopleOverlap.summary(person: participant, local: local, now: core.referenceDate)
        }
        overlaps = result
    }

    private func hoursText(_ availability: Availability) -> String {
        if availability.isWholeDay { return L10n.string("全天", locale: locale) }
        return ClockText.range(Self.minuteText(availability.startMinute, style: core.settings.hourStyle),
                               Self.minuteText(availability.endMinute, style: core.settings.hourStyle))
    }

    private func participationBinding(_ row: Participant) -> Binding<Bool> {
        Binding(
            get: { row.participates },
            set: { on in
                if let id = row.personID {
                    if on { selectedPeople.insert(id) } else { selectedPeople.remove(id) }
                } else if let id = row.zoneID { model.setParticipates(id: id, on) }
                else { model.settings.planner.includeLocal = on }
            }
        )
    }

    private func availabilityBinding(_ row: Participant) -> Binding<Availability> {
        Binding(
            get: {
                if let id = row.zoneID {
                    return core.zones.first { $0.id == id }?.effectiveAvailability ?? .standard
                }
                return core.settings.planner.localAvailability
            },
            set: { value in
                if let id = row.zoneID { model.setAvailability(id: id, value) }
                else { model.settings.planner.localAvailability = value }
            }
        )
    }

    static func durationText(_ minutes: Int, locale: Locale) -> String {
        ClockText.duration(seconds: Double(minutes * 60), locale: locale)
    }

    /// 墙钟分钟按用户的小时制显示，全天结束点读作午夜。
    static func minuteText(_ minute: Int, style: HourStyle) -> String {
        let date = Date(timeIntervalSince1970: PresentationCore.scalar("availability_label_date", ["minute": Double(minute)]))
        return TimeFormatting.string(for: date, in: TimeZone(identifier: "UTC")!,
                                     format: ClockFormat(hourStyle: style, showSeconds: false))
    }

    /// 从所选日期起算，今天不能早于此刻。
    static func planningStart(fromDay: Date, now: Date, timeZone: TimeZone) -> Date {
        let timestamp: Double = PresentationCore.call("planning_start",
            PresentationCore.CalendarFacts(fromDay: fromDay, now: now, timeZone: timeZone))
        return Date(timeIntervalSince1970: timestamp)
    }

    /// 几个名字按界面语言连成一串（「东京、马德里和纽约」「Tokyo, Madrid and New York」）。
    nonisolated static func nameList(_ names: [String], locale: Locale) -> String {
        let formatter = ListFormatter()
        formatter.locale = locale
        return formatter.string(from: names) ?? names.joined(separator: ", ")
    }
}


struct PlannerActionButtons: View {
    let stale: Bool
    let isExporting: Bool
    let onReturnToOriginal: (() -> Void)?
    let onAddToCalendar: () -> Void
    let onCopyTimes: () -> Void
    let onImage: (_ save: Bool) -> Void
    let onJump: () -> Void

    @Environment(\.locale) private var locale

    var body: some View {
        PlannerActionLayout() {
            Button("加入日历") { onAddToCalendar() }
                .disabled(isExporting || stale)
                .fixedSize()
            Button("复制各地时间") { onCopyTimes() }
                .disabled(stale)
                .fixedSize()
            Menu {
                Button("复制图片") { onImage(false) }
                Button("存储图片…") { onImage(true) }
            } label: {
                PlannerMenuLabel(text: L10n.string("图片", locale: locale), style: nil)
                    .padding(.horizontal, 4)
                    .accessibilityElement(children: .ignore)
                    .modifier(MenuAccessibleTitle(title: Text("图片")))
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .disabled(stale)
            if let onReturnToOriginal {
                Button(action: onReturnToOriginal) {
                    Label("回到原来的时刻", systemImage: "arrow.uturn.backward").fontWeight(.semibold)
                        .padding(.horizontal, 6).frame(minHeight: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .appFont(.callout)
                .fixedSize()
            }
            Button("在面板里看这一刻") { onJump() }
                .fixedSize()
                .keyboardShortcut(.return, modifiers: .command)
                .help(Text(verbatim: L10n.string("面板上各地的时间都跳到这一刻", locale: locale) + "  ⌘↩"))
                .accessibilityHint(Text("面板上各地的时间都跳到这一刻"))
        }
    }
}

// 动作逐个换行；量与摆共用同一份行划分。
struct PlannerActionLayout: Layout {
    var headSpacing: CGFloat = 10
    var finalSpacing: CGFloat = 8
    var rowSpacing: CGFloat = 8

    private struct Item { let index: Int; let size: CGSize }

    private func spacing(before index: Int, count: Int) -> CGFloat {
        index == count - 1 ? finalSpacing : headSpacing
    }

    private func intrinsicWidth(_ sizes: [CGSize]) -> CGFloat {
        var width: CGFloat = 0
        for (index, size) in sizes.enumerated() {
            width += (index == 0 ? 0 : spacing(before: index, count: sizes.count)) + size.width
        }
        return width
    }

    private func arrangement(width: CGFloat, sizes: [CGSize]) -> (rows: [[Item]], singleRow: Bool) {
        guard !sizes.isEmpty else { return ([], false) }
        if intrinsicWidth(sizes) <= width {
            return ([sizes.enumerated().map { Item(index: $0.offset, size: $0.element) }], sizes.count > 1)
        }
        var rows: [[Item]] = [[]]
        var x: CGFloat = 0
        for (index, size) in sizes.enumerated() {
            var gap = rows[rows.count - 1].isEmpty ? 0 : spacing(before: index, count: sizes.count)
            if !rows[rows.count - 1].isEmpty, x + gap + size.width > width {
                rows.append([])
                x = 0
                gap = 0
            }
            x += gap + size.width
            rows[rows.count - 1].append(Item(index: index, size: size))
        }
        return (rows, false)
    }

    private func height(of rows: [[Item]]) -> CGFloat {
        rows.map { row in row.map(\.size.height).max() ?? 0 }.reduce(0, +) + rowSpacing * CGFloat(max(0, rows.count - 1))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let width = proposal.width ?? intrinsicWidth(sizes)
        let rows = arrangement(width: width, sizes: sizes).rows
        return CGSize(width: width, height: height(of: rows))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let (rows, singleRow) = arrangement(width: bounds.width, sizes: sizes)
        var y = bounds.minY
        for row in rows {
            let rowHeight = row.map(\.size.height).max() ?? 0
            var x = bounds.minX
            for (position, item) in row.enumerated() {
                let placeX = singleRow && item.index == subviews.count - 1 ? bounds.maxX - item.size.width : x
                subviews[item.index].place(at: CGPoint(x: placeX, y: y + (rowHeight - item.size.height) / 2),
                                           proposal: ProposedViewSize(width: item.size.width, height: item.size.height))
                if position + 1 < row.count {
                    x = placeX + item.size.width + spacing(before: row[position + 1].index, count: subviews.count)
                }
            }
            y += rowHeight + rowSpacing
        }
    }
}

/// 三种解法共用的东西：谁参加、表上每人一行、从哪天起看几天、多长、本机时区，以及改工作时段的入口。
struct PlannerContext {
    let participants: [OverlapPlanner.Participant]
    let rows: [MeetingTable.Row]
    let fromDay: Date
    let notBefore: Date
    let days: Int
    let duration: Int
    let localTZ: String
    let editor: (MeetingTable.Row) -> AnyView
    let onEditSheet: (MeetingTable.Row) -> Void

    var localZone: TimeZone { TimeZone(identifier: localTZ) ?? .current }
}

// MARK: - 一行候选（三种解法共用）

/// 一行：形状（● 大家都在 / ◐ 有人在时段外）、本机的钟点（钟点字中号）与日期，后面写谁在付（只写在时段外的人和他那边的钟点），
/// 下面一行小字。能选时点一下只选中（表上画它），选中那一行左边一道竖线。
struct PlannerSlotRow: View {
    enum Glyph { case everyone, closest, none }
    enum Trailing {
        case payers([OverlapPlanner.ParticipantFit])
        case text(String)
        case none
    }

    let glyph: Glyph
    var prefix: String? = nil
    let start: Date
    let end: Date
    let trailing: Trailing
    var caption: String? = nil
    let selected: Bool
    let choosable: Bool
    let action: () -> Void

    @Environment(TimeCore.self) private var core
    @Environment(\.locale) private var locale
    @Environment(\.textScale) private var textScale

    private var localZone: TimeZone { .autoupdatingCurrent }
    private var format: ClockFormat { ClockFormat(hourStyle: core.settings.hourStyle, showSeconds: false) }

    var body: some View {
        // 那一次没开（例会轮换里有人休息）：只写日期。
        let slot: String? = end > start ? PlannerText.interval(start, end, format: format, locale: locale) : nil
        let day = ClockText.day(start, in: localZone, locale: locale, now: core.now, weekday: true)
        let row = HStack(alignment: .firstTextBaseline, spacing: 8) {
            glyphView.frame(width: 12)
            VStack(alignment: .leading, spacing: 2) {
                TrailingWrapLayout(spacing: 14) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if let prefix { Text(verbatim: prefix).appFont(.callout) }
                        if let slot { Text(verbatim: slot).font(ClockFace.medium(core.settings, scale: textScale)) }
                        Text(verbatim: day).appFont(.callout).foregroundStyle(slot == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.readableSecondary))
                    }
                    trailingView
                }
                if let caption {
                    Text(verbatim: caption).appFont(.caption).foregroundStyle(.readableSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 5)
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            if selected && choosable {
                Capsule().fill(.primary).frame(width: 2.5).padding(.vertical, 4)
            }
        }
        .contentShape(Rectangle())
        let spoken = [prefix, slot, day, spokenTrailing].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        if choosable {
            Button(action: action) { row }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: spoken))
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityHint(Text("在下面的时间轴上看这一场"))
        } else {
            row.accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: spoken))
                .accessibilityAddTraits(.isStaticText)
        }
    }

    @ViewBuilder private var glyphView: some View {
        switch glyph {
        case .everyone: Image(systemName: "circle.fill").imageScale(.small).foregroundStyle(.primary).accessibilityHidden(true)
        case .closest: Image(systemName: "circle.lefthalf.filled").imageScale(.small).foregroundStyle(.primary).accessibilityHidden(true)
        case .none: Color.clear.frame(width: 1, height: 1)
        }
    }

    @ViewBuilder private var trailingView: some View {
        switch trailing {
        case .payers(let fits):
            let text = PlannerText.payers(fits, start: start, format: format, locale: locale)
            if let text { text.appFont(.body).fixedSize(horizontal: false, vertical: true) }
        case .text(let value):
            Text(verbatim: value).appFont(.body).foregroundStyle(.readableSecondary).fixedSize(horizontal: false, vertical: true)
        case .none:
            EmptyView()
        }
    }

    private var spokenTrailing: String? {
        switch trailing {
        case .payers(let fits): PlannerText.spokenPayers(fits, start: start, format: format, locale: locale)
        case .text(let value): value
        case .none: nil
        }
    }
}

// MARK: - 文字

enum PlannerText {
    /// 本机的「6:00–7:00」（跨日或换钟时由 Rust 补日期与缩写，与排会旧版同一个出口）。
    static func interval(_ start: Date, _ end: Date, format: ClockFormat, locale: Locale) -> String {
        let zone = TimeZone.autoupdatingCurrent
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let entry = TimeZoneEntry(timezoneID: zone.identifier, cityName: "")
        func endpoint(_ date: Date) -> PresentationCore.IntervalEndpoint {
            PresentationCore.IntervalEndpoint(
                time: TimeFormatting.string(for: date, in: zone, format: format),
                day: date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale, timeZone: zone)),
                abbreviation: entry.abbreviation(at: date))
        }
        return PresentationCore.call("interval_text", PresentationCore.IntervalTextInput(
            sameDay: calendar.isDate(start, inSameDayAs: end), startOffset: zone.secondsFromGMT(for: start),
            endOffset: zone.secondsFromGMT(for: end), start: endpoint(start), end: endpoint(end)))
    }

    /// 在时段外的那一位那边的钟点：「22:00」，与本机不是同一天时「次日（周二）6:00」（星期是那边那一天的）。
    static func clock(_ date: Date, in zone: TimeZone, from reference: TimeZone = .autoupdatingCurrent,
                      format: ClockFormat, locale: Locale) -> String {
        let time = TimeFormatting.string(for: date, in: zone, format: format)
        let offset = ClockText.dayOffset(of: date, in: zone, from: reference)
        guard offset != 0 else { return time }
        return String(format: L10n.string(offset > 0 ? "次日（%1$@）%2$@" : "前一日（%1$@）%2$@", locale: locale), locale: locale,
                      ClockText.weekday(date, in: zone, locale: locale), time)
    }

    private static func outside(_ fit: OverlapPlanner.Fit) -> Bool {
        if case .inside = fit { return false }
        return true
    }

    /// 「☾洛杉矶 6:00 · ☾东京 22:00」：只写在时段外的人；大家都在时没有字（形状已经说了）。
    @MainActor
    static func payers(_ fits: [OverlapPlanner.ParticipantFit], start: Date, format: ClockFormat, locale: Locale) -> Text? {
        let paying = fits.filter { outside($0.fit) }
        guard !paying.isEmpty else { return nil }
        var combined = Text(verbatim: "")
        for (index, fit) in paying.enumerated() {
            let label = "\(fit.participant.name) \(clock(start, in: fit.participant.timeZone, format: format, locale: locale))"
            // `Text + Text` 在 macOS 26 已废弃，拼接走插值（键「%@ %@」「%@%@」在字符串目录里，十六语都是原样）。
            let piece = Text("\(Text(Image(systemName: "moon.zzz")).foregroundStyle(.orange)) \(Text(verbatim: label))")
            combined = index == 0 ? piece : Text("\(combined)\(Text("\(Text(verbatim: " · "))\(piece)"))")
        }
        return combined
    }

    static func spokenPayers(_ fits: [OverlapPlanner.ParticipantFit], start: Date, format: ClockFormat, locale: Locale) -> String? {
        let paying = fits.filter { outside($0.fit) }
        guard !paying.isEmpty else { return nil }
        let outsidePhrase = L10n.string("在工作时间外", locale: locale)
        return paying.map { "\($0.participant.name) \(clock(start, in: $0.participant.timeZone, format: format, locale: locale)) \(outsidePhrase)" }
            .joined(separator: ", ")
    }

    /// 同一个钟点也行的其余日子：都在一周之内写星期（「同一时间也行：周二、周三和周四」），再多只写几天。
    static func otherDays(_ days: [Date], first: Date, in zone: TimeZone = .autoupdatingCurrent, locale: Locale, now: Date) -> String? {
        let others = days.filter { $0 != first }
        guard !others.isEmpty else { return nil }
        if let last = others.last, last.timeIntervalSince(first) < 6.5 * 86_400 {
            let names = others.map { ClockText.weekday($0, in: zone, locale: locale) }
            return String(format: L10n.string("同一时间也行：%@", locale: locale), PlannerPage.nameList(names, locale: locale))
        }
        return String(format: L10n.string("同一时间还有 %lld 天也行", locale: locale), locale: locale, Int64(others.count))
    }
}

// MARK: - 主语行的排法

/// 主语行里各样之间的「·」：折行时落在行首或行尾的那一个不画（`SubjectFlowLayout` 把它挪到看不见的地方）。
struct SubjectDot: View {
    var body: some View {
        Text(verbatim: "·").foregroundStyle(.readableSecondary).accessibilityHidden(true)
            .layoutValue(key: SubjectDotKey.self, value: true)
    }
}

private struct SubjectDotKey: LayoutValueKey { static let defaultValue = false }

/// 一串东西依次排、放不下就折行；「·」只画在同一行的两样之间。比一行还宽的那一样（参与者很多时的名字）按行宽折字。
struct SubjectFlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 4

    private struct Item { let index: Int; let size: CGSize }

    private func lines(width: CGFloat, subviews: Subviews) -> [[Item]] {
        var lines: [[Item]] = [[]]
        var x: CGFloat = 0
        var pendingDot: Item?
        for (index, subview) in subviews.enumerated() {
            var size = subview.sizeThatFits(.unspecified)
            if subview[SubjectDotKey.self] {
                pendingDot = Item(index: index, size: size)
                continue
            }
            if size.width > width {
                size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            }
            let dotWidth = pendingDot.map { spacing + $0.size.width } ?? 0
            if !lines[lines.count - 1].isEmpty, x + dotWidth + spacing + size.width > width {
                lines.append([])
                x = 0
                pendingDot = nil
            }
            if let dot = pendingDot, !lines[lines.count - 1].isEmpty {
                lines[lines.count - 1].append(dot)
                x += spacing + dot.size.width
            }
            pendingDot = nil
            x += (lines[lines.count - 1].isEmpty ? 0 : spacing) + size.width
            lines[lines.count - 1].append(Item(index: index, size: size))
        }
        return lines
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width + spacing }.reduce(0, +)
        let rows = lines(width: width, subviews: subviews)
        let height = rows.map { row in row.map(\.size.height).max() ?? 0 }.reduce(0, +) + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = lines(width: bounds.width, subviews: subviews)
        var placed = Set<Int>()
        var y = bounds.minY
        for row in rows {
            let height = row.map(\.size.height).max() ?? 0
            var x = bounds.minX
            for item in row {
                subviews[item.index].place(at: CGPoint(x: x, y: y + (height - item.size.height) / 2),
                                           proposal: ProposedViewSize(width: item.size.width, height: item.size.height))
                placed.insert(item.index)
                x += item.size.width + spacing
            }
            y += height + lineSpacing
        }
        // 没排上的「·」（折行处）放到看不见的地方，不占位、读屏本来就跳过它。
        for index in subviews.indices where !placed.contains(index) {
            subviews[index].place(at: CGPoint(x: -10_000, y: -10_000), proposal: .zero)
        }
    }
}
