// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

struct PeopleEditorView: View {
    @Environment(TimeCore.self) private var core
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let store: PeopleStore
    @State private var draft: PersonProfile
    @State private var issues: [String] = []
    @State private var choosingPlace = false
    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

    /// 已保存的人物才有：编辑器左下「移除人物…」，让只用键盘的人也能走到移除（此前只在行的右键菜单里，
    /// 方便键盘操作）。由调用方在表单关掉后弹确认框。
    var onRemove: (() -> Void)? = nil

    init(store: PeopleStore, original: PersonProfile, onRemove: (() -> Void)? = nil) {
        self.store = store
        self.onRemove = onRemove
        _draft = State(initialValue: original)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("姓名", text: $draft.name)
                        .accessibilityLabel(Text("姓名"))
                        .help(draft.contactIdentifier != nil ? Text("姓名来自通讯录，在这里改不影响通讯录") : Text(verbatim: ""))
                        .accessibilityHint(draft.contactIdentifier != nil ? Text("姓名来自通讯录，在这里改不影响通讯录") : Text(verbatim: ""))
                    // 所在地：写地名，改用面板同款城市搜索选（此前是一格手写 IANA 标识符，
                    // 首启没有地点时还是唯一入口）。已保存的地点在搜索结果之上直接列出；标识符只进悬停提示。
                    LabeledContent("所在地") {
                        HStack(spacing: 8) {
                            Text(verbatim: placeLabel)
                                .help(Text(verbatim: draft.timeZoneID))
                            Button("更改…") { choosingPlace = true }
                                .popover(isPresented: $choosingPlace, arrowEdge: .bottom) { placePicker.environment(\.locale, core.uiLocale) }
                        }
                    }
                    .labeledContentStyle(.readable)
                }
                Section("当地作息") {
                    VStack(alignment: .leading, spacing: 8) {
                        DatePicker("开始", selection: minuteBinding(\.startMinute), displayedComponents: .hourAndMinute)
                            .accessibilityHint(Text("结束早于开始就是跨夜，算在开始那天；起止相同就是全天"))
                        HStack {
                            DatePicker("结束", selection: minuteBinding(\.endMinute), displayedComponents: .hourAndMinute)
                                .accessibilityLabel(Text(verbatim: [L10n.string("结束", locale: core.uiLocale), endMarker]
                                    .compactMap { $0 }.joined(separator: ", ")))
                                .accessibilityHint(Text("结束早于开始就是跨夜，算在开始那天；起止相同就是全天"))
                            if let endMarker {
                                Text(verbatim: endMarker).appFont(.caption).foregroundStyle(.readableSecondary)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .environment(\.timeZone, .gmt)
                    .help(Text("结束早于开始就是跨夜，算在开始那天；起止相同就是全天"))
                    .accessibilityElement(children: .contain)
                    .accessibilityHint(Text("结束早于开始就是跨夜，算在开始那天；起止相同就是全天"))
                    VStack(alignment: .leading, spacing: 8) {
                        Text("工作日")
                        HStack(spacing: 6) {
                            ForEach(1...7, id: \.self) { day in
                                Toggle(isOn: weekdayBinding(day)) {
                                    Text(weekdayName(day)).frame(minWidth: 22)
                                }
                                .toggleStyle(.button)
                                .accessibilityHint(Text("全部不选就是整周休息"))
                            }
                        }
                        if draft.schedule.workingWeekdays.isEmpty {
                            Text("整周休息").appFont(.caption).foregroundStyle(.readableSecondary)
                        }
                    }
                    .help(Text("全部不选就是整周休息"))
                    .accessibilityElement(children: .contain)
                    .accessibilityHint(Text("全部不选就是整周休息"))
                    // 与地点右键菜单的「能打给谁」同一套基准：只改人物行的状态显示，作息本身不动。
                    Picker("能打给的时段", selection: $draft.callBasis) {
                        ForEach(CallBasis.allCases, id: \.self) { basis in
                            Text(basis.localizedKey).tag(basis)
                        }
                    }
                }
                Section("假期") {
                    ForEach($draft.vacations) { $vacation in
                        HStack {
                            DatePicker("从", selection: dateBinding($vacation.startDate), displayedComponents: .date)
                                .help(Text("按人物所在地的日期计算，包含开始和结束两天。"))
                                .accessibilityHint(Text("按人物所在地的日期计算，包含开始和结束两天。"))
                            DatePicker("至", selection: dateBinding($vacation.endDate), displayedComponents: .date)
                                .help(Text("按人物所在地的日期计算，包含开始和结束两天。"))
                                .accessibilityHint(Text("按人物所在地的日期计算，包含开始和结束两天。"))
                            Button(role: .destructive) { draft.vacations.removeAll { $0.id == vacation.id } } label: {
                                Image(systemName: "minus.circle")
                                    .foregroundStyle(.primary)
                                    .frame(minWidth: 24, minHeight: 24)
                                    .contentShape(Rectangle())
                            }.buttonStyle(.borderless).accessibilityLabel(Text("移除假期"))
                        }
                        .environment(\.timeZone, .gmt)
                        .environment(\.calendar, Self.utcCalendar)
                    }
                    Button("添加假期", systemImage: "plus") {
                        var calendar = Calendar(identifier: .gregorian)
                        calendar.timeZone = TimeZone(identifier: draft.timeZoneID) ?? .current
                        let date = PersonProfile.civilDate(core.referenceDate, calendar: calendar)
                        draft.vacations.append(PeopleVacation(startDate: date, endDate: date))
                    }
                }
                if !issues.isEmpty {
                    Section {
                        ForEach(issues, id: \.self) { issue in ErrorLine(issueMessage(issue)) }
                    }
                }
            }
            .formStyle(.grouped)
            // sheet 是另一个呈现根，勾选框样式要再指定一次。
            .toggleStyle(.checkbox)
            HStack {
                if let onRemove, store.people.contains(where: { $0.id == draft.id }) {
                    Button("移除人物…", role: .destructive) { dismiss(); onRemove() }
                        .disabled(store.storageReadOnly)
                }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    if let place = core.zones.first(where: { $0.id == draft.placeID }) { bind(place) }
                    issues = store.save(draft)
                    if issues.isEmpty { dismiss() }
                }.keyboardShortcut(.defaultAction).disabled(store.storageReadOnly)
            }.padding()
        }
        // 比默认 540 pt 的工具窗矮：表单自己滚，sheet 不伸出窗底。
        .frame(minWidth: 530, idealWidth: 570, minHeight: 440, idealHeight: 480)
        .onAppear {
            // 绑定的地点已被删掉：保留时区标识符，改按地名显示。
            if draft.placeID != nil && !core.zones.contains(where: { $0.id == draft.placeID }) {
                draft.placeID = nil
            }
            #if DEBUG
            // 截图：`MEANTIME_UI_TEST_PEOPLE_EDIT_FIRST=2` 连所在地选择器一起弹开（只在测试宿主生效）。
            if ProcessInfo.processInfo.environment["MEANTIME_TEST_HOST"] == "1",
               ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_PEOPLE_EDIT_FIRST"] == "2" {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(700))
                    choosingPlace = true
                }
            }
            #endif
        }
    }

    private var endMarker: String? {
        let schedule = draft.schedule
        if schedule.endMinute == schedule.startMinute { return L10n.string("全天", locale: core.uiLocale) }
        if schedule.endMinute < schedule.startMinute { return L10n.string("次日", locale: core.uiLocale) }
        return nil
    }

    /// 「伦敦」或「伦敦（已保存的地点名）」：地名走 TimeCore 的统一出口，标识符不进主路径。
    private var placeLabel: String {
        if let place = core.zones.first(where: { $0.id == draft.placeID }) {
            return place.displayName(localizedCity: core.cityName(for: place))
        }
        let name = core.placeName(forTimeZoneID: draft.timeZoneID)
        return name.isEmpty ? draft.timeZoneID : name
    }

    private var placePicker: some View {
        PlacePicker(selectedID: draft.placeID, timeZoneID: draft.timeZoneID,
            onSaved: { bind($0); choosingPlace = false },
            onSearch: { draft.choose($0); choosingPlace = false })
            .environment(model)
    }

    private func bind(_ place: TimeZoneEntry) {
        draft.bind(to: place)
    }
    private func weekdayName(_ weekday: Int) -> String {
        ClockText.weekday(weekday, locale: core.uiLocale)
    }
    private func weekdayBinding(_ day: Int) -> Binding<Bool> {
        Binding(get: { draft.schedule.workingWeekdays.contains(day) }, set: { enabled in
            if enabled { draft.schedule.workingWeekdays.append(day) }
            else { draft.schedule.workingWeekdays.removeAll { $0 == day } }
        })
    }
    private func minuteBinding(_ keyPath: WritableKeyPath<PeopleWorkSchedule, Int>) -> Binding<Date> {
        Binding(get: {
            Date(timeIntervalSince1970: Double(draft.schedule[keyPath: keyPath] % 1440) * 60)
        }, set: { date in
            let parts = Self.utcCalendar.dateComponents([.hour, .minute], from: date)
            draft.schedule[keyPath: keyPath] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        })
    }
    private func dateBinding(_ text: Binding<String>) -> Binding<Date> {
        Binding(get: {
            let values = text.wrappedValue.split(separator: "-").compactMap { Int($0) }
            guard values.count == 3 else { return .now }
            return Self.utcCalendar.date(from: DateComponents(year: values[0], month: values[1], day: values[2])) ?? .now
        }, set: { text.wrappedValue = PersonProfile.civilDate($0, calendar: Self.utcCalendar) })
    }
    private func issueMessage(_ issue: String) -> Text {
        switch issue {
        case "name": Text("请填写姓名。")
        case "timeZone": Text("请选择所在地。")
        case "hours": Text("工作时刻无效，请重新选择。")
        case "weekdays": Text("工作日无效，请重新选择。")
        case "vacation": Text("请检查假期日期，结束日期不能早于开始日期。")
        case "readOnly": Text("请更新 Dayside 后再编辑这份存档。")
        default: Text("无法保存，请重新打开编辑。")
        }
    }
}
