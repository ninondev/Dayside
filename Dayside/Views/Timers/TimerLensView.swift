// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// 闹钟只用第一处；没写日期且今天已经过去时，按地点的下一个民用日再读。
nonisolated struct AlarmReading {
    let item: TimeUnderstanding.Resolved?
    let count: Int
    let advanced: Bool
    let reference: Date

    static func resolve(_ text: String, now: Date, home: TimeZone = .current,
                        preferredZones: [String] = [], choice: TimeUnderstanding.Choice = .init()) -> Self {
        let output = TimeUnderstanding.read(text)
        let context = TimeUnderstanding.Context(reference: now, now: now, fallback: home, home: home,
                                                 preferredZones: preferredZones)
        guard let mention = output.mentions.first else {
            return Self(item: nil, count: 0, advanced: false, reference: now)
        }
        let first = output.mentions.count == 1
            ? TimeInput.resolve(output, relativeTo: now, now: now, in: home,
                                preferredZones: preferredZones, choice: choice).resolved
            : nil
        let item = rejectingUnknownSource(first ?? TimeUnderstanding.resolve(mention, context: context, choice: choice))
        guard mention.date == nil, mention.relativeMinutes == nil, mention.instant == nil,
              item.problem == nil, !item.intervals.isEmpty, item.intervals.allSatisfy({ $0.start <= now }),
              let tomorrow = Calendar.gregorianUTC(item.zone).date(byAdding: .day, value: 1, to: now) else {
            return Self(item: item, count: output.mentions.count, advanced: false, reference: now)
        }
        var next = context
        next.reference = tomorrow
        return Self(item: TimeUnderstanding.resolve(mention, context: next, choice: choice), count: output.mentions.count,
                    advanced: true, reference: tomorrow)
    }

    private static func rejectingUnknownSource(_ item: TimeUnderstanding.Resolved) -> TimeUnderstanding.Resolved {
        guard item.problem == nil, let place = item.notes.compactMap({ note -> String? in
            if case .unresolvedPlace(let place) = note { return place }
            return nil
        }).first else { return item }
        return TimeUnderstanding.Resolved(mention: item.mention, readings: item.readings, reading: item.reading,
                                          zoneOptions: item.zoneOptions, zoneOption: item.zoneOption, zoneWritten: item.zoneWritten,
                                          day: item.day, intervals: [], target: item.target, problem: .unresolvedPlace(place),
                                          notes: item.notes, anchoredToGroup: item.anchoredToGroup)
    }

}

struct TimerLensView: View {
    @Environment(TimeCore.self) private var core
    @Bindable var store: TimerStore
    @State private var mode = TimerLensView.initialMode
    @State private var label = ""
    @State private var minutes = 5
    @State private var focusMinutes = 25
    @State private var breakMinutes = 5
    @State private var longBreakMinutes = 15
    @State private var rounds = 4
    @Environment(\.textScale) private var textScale
    @State private var alarmText = ""
    @State private var alarmReading: AlarmReading?
    @State private var alarmChoice = TimeUnderstanding.Choice()
    @State private var alarmCandidate: Int?
    @State private var settingAlarm = false
    @State private var fixtureText: String?

    private var isCreatingAlarm: Bool {
        mode == "alarm" && store.state.session == nil
    }

    private var alarmParseText: String? {
        isCreatingAlarm && !alarmText.isEmpty ? alarmText : nil
    }

    private var selectedAlarm: Date? {
        guard let item = alarmReading?.item, item.problem == nil else { return nil }
        if item.intervals.count == 1 { return item.intervals.first?.start }
        guard let candidate = alarmCandidate, item.intervals.indices.contains(candidate) else { return nil }
        return item.intervals[candidate].start
    }

    private var alarmStyle: UnderstandingText.Style {
        let cityLocale = core.cityLocale
        return UnderstandingText.Style(locale: core.uiLocale, hourStyle: core.settings.hourStyle, now: core.now,
                                       name: { core.placeName(forTimeZoneID: $0.identifier) },
                                       cityName: { CityNameLanguage.name(from: CityIndex.shared.localizedNames(cityIndex: $0), locale: cityLocale) },
                                       reference: alarmReading?.reference ?? core.now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let session = store.state.session, let view = store.presentation {
                AnyView(sessionView(session, presentation: view))
            } else {
                AnyView(creationForm)
            }
            if let error = store.error { ErrorLine(Text(Self.errorKey(error))).appFont(.callout) }
            if store.recovered { Text("上次计时数据无法读取，已备份原始数据。").appFont(.caption).foregroundStyle(.readableSecondary) }
            Toggle("到期通知", isOn: Binding(get: { store.state.notifications }, set: { enabled in
                if enabled { Task { await store.requestNotificationPermission() } }
                else { store.setNotificationsEnabled(false) }
            })).padding(.top, 10)
                .modifier(LensNotificationValue(access: store.notifications.access))
            if store.state.notifications {
                LensNotificationStatusView(notifications: store.notifications,
                                           requestPermission: { await store.requestNotificationPermission() }, retry: store.refresh)
            }
            if store.showsCompletionHint {
                Text("关闭窗口后仍继续计时。通知可能受专注模式、睡眠和系统设置影响，无法保证准时显示。")
                    .appFont(.caption).foregroundStyle(.readableSecondary)
            }
        }
        .onAppear {
            configureStore()
            store.setVisible(true)
            applyAlarmFixture()
        }
        .onDisappear { store.setVisible(false) }
        .onChange(of: core.uiLocale.identifier) { configureStore() }
        .onChange(of: core.settings.hourStyle) { configureStore() }
        .onChange(of: core.zones) { checkAlarm() }
        .onChange(of: core.systemRevision) { checkAlarm(); store.refresh() }
        .onChange(of: alarmText) {
            guard alarmText != fixtureText else { return }
            alarmReading = nil; alarmChoice = .init(); alarmCandidate = nil
        }
        .task(id: alarmParseText) {
            guard let requestedText = alarmParseText else { return }
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard !Task.isCancelled, alarmParseText == requestedText else { return }
            checkAlarm()
        }
    }

    private var modePicker: some View {
        Picker("计时方式", selection: $mode) {
            Text("倒计时").tag("countdown")
            Text("番茄钟").tag("pomodoro")
            Text("秒表").tag("stopwatch")
            Text("跨时区闹钟").tag("alarm")
        }
    }

    private var creationForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 标签在左、分段控件在右（系统习惯）；四段放不下一行的语言（ru / pt-BR）才退成
            // 「标签在上 + 弹出菜单」。中文与英文都走第一个分支。
            ViewThatFits(in: .horizontal) {
                modePicker.pickerStyle(.segmented)
                    .accessibilityLabel(Text("计时方式"))
                VStack(alignment: .leading, spacing: 6) {
                    Text("计时方式").appFont(.caption).foregroundStyle(.readableSecondary)
                    modePicker.pickerStyle(.menu).labelsHidden()
                }
            }
            switch mode {
            case "countdown":
                // 数字框旁配系统步进器；上限与「倒计时最长 31 天」一致。
                LabeledContent("分钟") {
                    HStack(spacing: 4) {
                        TextField("分钟", value: $minutes, format: .number).frame(width: 100).accessibilityLabel(Text("分钟"))
                        Stepper("分钟", value: $minutes, in: 1...(31 * 24 * 60)).labelsHidden()
                    }
                }
                HStack(spacing: 6) {
                    Text("常用时长").appFont(.caption).foregroundStyle(.readableSecondary)
                    ForEach([5, 15, 25, 60], id: \.self) { preset in
                        Button { minutes = preset } label: { Text(verbatim: preset.formatted()) }
                            .buttonStyle(.bordered).controlSize(.small)
                            .accessibilityLabel(Text("\(preset) 分钟"))
                    }
                }
            case "pomodoro":
                Stepper("专注 \(focusMinutes) 分钟", value: $focusMinutes, in: 1...240)
                Stepper("短休息 \(breakMinutes) 分钟", value: $breakMinutes, in: 1...60)
                Stepper("长休息 \(longBreakMinutes) 分钟", value: $longBreakMinutes, in: 1...120)
                    .help(Text("每 4 轮后安排长休息，最后一轮结束后停止。"))
                    .accessibilityHint(Text("每 4 轮后安排长休息，最后一轮结束后停止。"))
                Stepper("共 \(rounds) 轮", value: $rounds, in: 1...12)
                ledgerLine
            case "alarm": AnyView(alarmForm)
            default:
                EmptyView()
            }
            // 标签排在时长之后：先填要几分钟，再给它起名——多数人不起名。
            TextField("标签（可选）", text: $label)
                .accessibilityLabel(Text("标签（可选）"))
            if mode == "alarm" {
                VStack(alignment: .leading, spacing: 8) {
                    Button("设闹钟") { Task { await setAlarm() } }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(selectedAlarm.map { $0 > core.now } != true || settingAlarm)
                        .help(Text("闹钟只响一次"))
                        .accessibilityHint(Text("闹钟只响一次"))
                }
            } else {
                Button("开始计时") { store.startFromTimersPage(makeSpec()) }.buttonStyle(.borderedProminent)
            }
        }
    }

    private var alarmForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(String(format: L10n.string("例如：%@", locale: core.uiLocale), alarmExample), text: $alarmText)
                .accessibilityLabel(Text("闹钟的时间与地点"))
                .onSubmit { Task { await setAlarm() } }
            if !alarmText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("读到的时间").appFont(.caption).foregroundStyle(.readableSecondary).accessibilityAddTraits(.isHeader)
                if let item = alarmReading?.item {
                    if let problem = UnderstandingText.problem(item, in: alarmText, style: alarmStyle) {
                        ErrorLine(Text(verbatim: problem)).appFont(.caption)
                    } else {
                        Text(verbatim: alarmSummary(item)).appFont(.body)
                            .foregroundStyle(item.problem == .dateOnly ? AnyShapeStyle(.readableSecondary) : AnyShapeStyle(.primary))
                            .fixedSize(horizontal: false, vertical: true)
                        alarmCandidates(item)
                        if let selectedAlarm, selectedAlarm <= core.now {
                            ErrorLine(Text("这个闹钟时刻已经过去，请重新选择。")).appFont(.caption)
                        }
                        if alarmReading?.advanced == true, let at = item.start {
                            note(String(format: L10n.string("没写日期，按下一个 %@", locale: core.uiLocale),
                                        ClockText.time(at, in: item.zone, hourStyle: core.settings.hourStyle,
                                                       system: core.settings.hourStyle == .followSystem ? .current : core.uiLocale)))
                        }
                        if (alarmReading?.count ?? 0) > 1 {
                            note(L10n.string("读到几处时间，按第一处设闹钟", locale: core.uiLocale))
                        }
                        ForEach(UnderstandingText.notes(item, in: alarmText, style: alarmStyle), id: \.self) { note($0) }
                    }
                } else {
                    Text(verbatim: String(format: L10n.string("还没读出时间。写一个地方和钟点，例如：%@", locale: core.uiLocale), alarmExample))
                        .appFont(.caption).foregroundStyle(.readableSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var alarmExample: String { L10n.string("明天 9:00 东京", locale: core.uiLocale) }

    private func alarmSummary(_ item: TimeUnderstanding.Resolved) -> String {
        var summary = UnderstandingText.summary(item, in: alarmText, style: alarmStyle, pasted: false)
        if let date = selectedAlarm, item.zone.identifier != TimeZone.current.identifier {
            summary += " → " + localAlarmTime(date)
        }
        return summary
    }

    private func localAlarmTime(_ date: Date) -> String {
        String(format: L10n.string("本机 %@", locale: core.uiLocale),
               ClockText.dateTime(date, in: .current, hourStyle: core.settings.hourStyle, locale: core.uiLocale,
                                  now: core.now, weekday: true))
    }

    @ViewBuilder private func alarmCandidates(_ item: TimeUnderstanding.Resolved) -> some View {
        let at = item.start ?? core.now
        if item.zoneOptions.count > 1 {
            Picker("按哪种理解", selection: Binding(get: { item.zoneOption.id }, set: {
                alarmChoice.zone = $0; alarmCandidate = nil; checkAlarm()
            })) {
                ForEach(item.zoneOptions) { option in
                    Text(verbatim: UnderstandingText.zoneLabel(option, among: item.zoneOptions, at: at, style: alarmStyle,
                                                               pasted: false, written: UnderstandingText.zoneText(item.mention, in: alarmText)))
                        .tag(option.id)
                }
            }.fixedSize()
        }
        if item.readings.count > 1 {
            Picker(item.zoneOptions.count > 1 ? "日期与钟点" : "按哪种理解", selection: Binding(get: { item.reading.id }, set: {
                alarmChoice.reading = $0; alarmCandidate = nil; checkAlarm()
            })) {
                ForEach(item.readings) { reading in
                    Text(verbatim: UnderstandingText.readingLabel(reading, of: item, style: alarmStyle)).tag(reading.id)
                }
            }.fixedSize()
        }
        if item.intervals.count > 1 {
            Text("夏令时结束时，这个时刻出现两次。请选择：").appFont(.callout)
            ViewThatFits(in: .horizontal) {
                HStack { repeatedChoices(item) }
                VStack(alignment: .leading) { repeatedChoices(item) }
            }
        }
    }

    private func repeatedChoices(_ item: TimeUnderstanding.Resolved) -> some View {
        ForEach(Array(item.intervals.enumerated()), id: \.offset) { index, interval in
            Button { alarmCandidate = index } label: {
                Label {
                    Text(verbatim: Self.repeatedLabel(item, index: index, hourStyle: core.settings.hourStyle, locale: core.uiLocale)).monospacedDigit()
                } icon: { Image(systemName: alarmCandidate == index ? "largecircle.fill.circle" : "circle") }
            }
            .accessibilityAddTraits(alarmCandidate == index ? .isSelected : [])
            .help(Text(verbatim: TimeInput.timestamps(for: interval.start, in: item.zone)?.iso8601 ?? ""))
        }
    }

    static func repeatedLabel(_ item: TimeUnderstanding.Resolved, index: Int, hourStyle: HourStyle, locale: Locale,
                              system: Locale = .current) -> String {
        guard item.intervals.indices.contains(index) else { return "" }
        let date = item.intervals[index].start
        let clock = ClockText.time(date, in: item.zone, hourStyle: hourStyle,
                                   system: hourStyle == .followSystem ? system : locale)
        let abbreviation = UnderstandingText.abbreviation(item.zoneOption, at: date)
        let occurrence = L10n.string(index == 0 ? "第一次" : "第二次", locale: locale)
        return String(format: L10n.string("%1$@（%2$@）", locale: locale), "\(clock) \(abbreviation)", occurrence)
    }

    private func note(_ line: String) -> some View {
        Label { Text(verbatim: line) } icon: { Image(systemName: "exclamationmark.triangle") }
            .appFont(.caption).foregroundStyle(.readableSecondary).fixedSize(horizontal: false, vertical: true)
    }

    private func checkAlarm(now: Date = .now) {
        guard isCreatingAlarm else { return }
        let result = AlarmReading.resolve(alarmText, now: now, preferredZones: core.zones.map(\.timezoneID), choice: alarmChoice)
        if result.item?.intervals != alarmReading?.item?.intervals { alarmCandidate = nil }
        alarmReading = result
    }

    private func configureStore() {
        store.configure(zones: core.zones, locale: core.uiLocale, hourStyle: core.settings.hourStyle)
    }

    private func makeSpec() -> TimerSpec {
        var spec = TimerSpec()
        spec.mode = mode; spec.label = label
        spec.duration = Double(minutes) * 60; spec.focus = Double(focusMinutes) * 60
        spec.shortBreak = Double(breakMinutes) * 60; spec.longBreak = Double(longBreakMinutes) * 60; spec.rounds = rounds
        spec.alarmAt = selectedAlarm?.timeIntervalSince1970
        if let item = alarmReading?.item, item.zoneWritten, let date = selectedAlarm {
            spec.alarmZone = item.zone.identifier
            spec.alarmPlace = UnderstandingText.zoneName(item.zoneOption, at: date, style: alarmStyle, pasted: false)
        }
        return spec
    }

    private func setAlarm() async {
        guard !settingAlarm, isCreatingAlarm else { return }
        checkAlarm()
        guard let date = selectedAlarm, date > Date.now else { return }
        let spec = makeSpec()
        settingAlarm = true
        defer { settingAlarm = false }
        if !store.state.notifications { await store.requestNotificationPermission() }
        guard store.state.session == nil else { return }
        store.startFromTimersPage(spec)
    }

    private func applyAlarmFixture() {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        guard env["MEANTIME_TEST_HOST"] == "1", let text = env["MEANTIME_UI_TEST_ALARM_TEXT"], !text.isEmpty else { return }
        let written: String
        switch text {
        case "example": written = alarmExample
        case "twice":
            let place = core.zones.first { $0.timezoneID == "America/Los_Angeles" }
            let name = place.map { core.cityName(for: $0) } ?? core.placeName(forTimeZoneID: "America/Los_Angeles")
            let calendar = Calendar.gregorianUTC(.gmt)
            let date = calendar.date(from: DateComponents(year: 2030, month: 11, day: 3, hour: 12))!
            let formatter = DateFormatter()
            formatter.locale = core.uiLocale
            formatter.calendar = calendar
            formatter.timeZone = .gmt
            formatter.dateStyle = .long
            formatter.timeStyle = .none
            let separator = ["zh", "ja"].contains(core.uiLocale.language.languageCode?.identifier ?? "") ? "" : " "
            written = "\(name)\(separator)\(formatter.string(from: date))\(separator)1:30"
        default: written = text
        }
        fixtureText = written
        mode = "alarm"; alarmText = written
        checkAlarm(now: core.now)
        if let value = env["MEANTIME_UI_TEST_ALARM_CHOICE"], let candidate = Int(value),
           alarmReading?.item?.intervals.indices.contains(candidate) == true { alarmCandidate = candidate }
        if env["MEANTIME_UI_TEST_ALARM_SET"] == "1", selectedAlarm != nil {
            var spec = makeSpec(); spec.mode = "alarm"
            store.startFromTimersPage(spec)
        }
        #endif
    }

    private func sessionView(_ session: TimerSession, presentation: TimerPresentation) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !session.spec.label.isEmpty { Text(verbatim: session.spec.label).appFont(.headline) }
            if session.spec.mode == "alarm", let target = session.spec.alarmAt {
                let date = Date(timeIntervalSince1970: target)
                let zone = session.spec.alarmZone.flatMap(TimeZone.init(identifier:)) ?? .current
                let place = Self.alarmSubjectPlace(session.spec, locale: core.uiLocale,
                                                  fallback: core.placeName(forTimeZoneID: zone.identifier))
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: place)
                        .font(SerifFace.font(place, size: 17 * textScale, weight: .medium, locale: core.uiLocale))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: "·").appFont(.title3).accessibilityHidden(true)
                    Text(verbatim: ClockText.day(date, in: zone, locale: core.uiLocale, now: core.now, weekday: true))
                        .appFont(.title3).fixedSize(horizontal: false, vertical: true)
                }.accessibilityElement(children: .combine)
                Text(verbatim: ClockText.time(date, in: zone, hourStyle: core.settings.hourStyle,
                                             system: core.settings.hourStyle == .followSystem ? .current : core.uiLocale))
                    .font(timerFont)
                    .accessibilityLabel(Text(verbatim: [place, ClockText.time(date, in: zone, hourStyle: core.settings.hourStyle,
                                                                            system: core.settings.hourStyle == .followSystem ? .current : core.uiLocale)]
                        .filter { !$0.isEmpty }.joined(separator: " ")))
                    .accessibilityIdentifier("timer-display")
                let remaining = ClockText.durationIn(seconds: floor(max(0, target - core.now.timeIntervalSince1970) / 60) * 60,
                                                     locale: core.uiLocale)
                Text(verbatim: session.spec.alarmZone == nil ? remaining : "\(localAlarmTime(date)) · \(remaining)")
                    .appFont(.callout).foregroundStyle(.readableSecondary).fixedSize(horizontal: false, vertical: true)
                if session.status == "paused" { Text("已暂停").foregroundStyle(.readableSecondary) }
            } else {
                Text(Self.phaseKey(presentation.phase)).appFont(.headline)
                Text(verbatim: presentation.display).font(timerFont).accessibilityIdentifier("timer-display")
                if session.status == "paused" { Text("已暂停").foregroundStyle(.readableSecondary) }
            }
            if session.spec.mode == "pomodoro", !presentation.isCompleted {
                Text("第 \(presentation.round) 轮，共 \(presentation.rounds) 轮").appFont(.callout)
            }
            if session.spec.mode == "pomodoro" { ledgerLine }
            HStack {
                if presentation.canPause {
                    if session.spec.mode == "alarm" {
                        Button("暂停", action: store.pause)
                            .help(Text("暂停会关闭提醒，但不会改变闹钟的目标时刻。"))
                            .accessibilityHint(Text("暂停会关闭提醒，但不会改变闹钟的目标时刻。"))
                    } else {
                        Button("暂停", action: store.pause)
                    }
                }
                if presentation.canResume { Button("继续", action: store.resume) }
                if session.spec.mode != "alarm" { Button("重新开始", action: store.restart) }
                if presentation.isCompleted { Button("新建计时器", action: store.cancel) }
                else if session.spec.mode == "alarm" { Button("取消闹钟", role: .destructive, action: store.cancel) }
                else { Button("取消计时", role: .destructive, action: store.cancel) }
            }.buttonStyle(.bordered)
            if presentation.isCompleted { Text("已到期。重新打开窗口不会补发旧提醒。").appFont(.caption).foregroundStyle(.readableSecondary) }
        }
    }

    static func cityCoordinate(place: String, in zone: TimeZone) -> Coordinate? {
        let name = place.searchFolded
        guard !name.isEmpty else { return nil }
        for hit in CityIndex.shared.search(folded: name, limit: 6) {
            guard let record = CityIndex.shared.city(at: hit.cityIndex), record.timezoneID == zone.identifier else { continue }
            let exact = record.name.searchFolded == name || CityIndex.shared.localizedNames(cityIndex: hit.cityIndex)
                .values.contains { $0.searchFolded == name }
            if exact { return Coordinate(latitude: record.latitude, longitude: record.longitude) }
        }
        return nil
    }

    static func alarmSubjectPlace(_ spec: TimerSpec, locale: Locale, fallback: String) -> String {
        guard spec.alarmZone != nil else { return L10n.string("本机", locale: locale) }
        return spec.alarmPlace.flatMap { $0.isEmpty ? nil : $0 } ?? fallback
    }

    private var timerFont: Font {
        ClockFace.font(size: 44 * textScale, design: core.settings.fontDesign, weight: core.settings.weight, light: true)
    }

    /// 番茄钟账本：「今天 3 次 · 专注 1 小时 15 分钟 · 最近 7 天 12 次」；只记做完的专注段，
    /// 中途取消的不算。一次都没有时说明这一行会记什么。
    @ViewBuilder private var ledgerLine: some View {
        Group {
            if let ledger = store.ledger, let today = ledger.today, ledger.recentCount > 0 {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        Text("今天 \(today.focusCount) 次")
                        Text(verbatim: "·")
                        Text("专注 \(ClockText.duration(seconds: today.focusSeconds, locale: core.uiLocale))")
                        Text(verbatim: "·")
                        Text("最近 7 天 \(ledger.recentCount) 次")
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("今天 \(today.focusCount) 次")
                        Text("专注 \(ClockText.duration(seconds: today.focusSeconds, locale: core.uiLocale))")
                        Text("最近 7 天 \(ledger.recentCount) 次")
                    }
                }
                .appFont(.caption).foregroundStyle(.readableSecondary)
                .accessibilityElement(children: .combine)
            } else {
                Text("做完一段专注后，这里记今天的次数与总时长；中途取消的不算。")
                    .appFont(.caption).foregroundStyle(.readableSecondary)
            }
        }
        .help(Text("只记完成的专注，中途取消的不算"))
        .accessibilityHint(Text("只记完成的专注，中途取消的不算"))
    }

    /// 转储与截图可以让页面直接停在番茄钟（`MEANTIME_UI_TEST_TIMER_MODE`，只在测试宿主生效）。
    private static var initialMode: String {
        #if DEBUG
        if ProcessInfo.processInfo.environment["MEANTIME_TEST_HOST"] == "1",
           let mode = ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_TIMER_MODE"],
           ["countdown", "pomodoro", "stopwatch", "alarm"].contains(mode) { return mode }
        #endif
        return "countdown"
    }

    private static func phaseKey(_ phase: String) -> LocalizedStringKey {
        switch phase {
        case "focus": "专注中"
        case "shortBreak": "短休息"
        case "longBreak": "长休息"
        case "stopwatch": "秒表"
        case "alarm": "闹钟"
        case "completed": "已完成"
        default: "倒计时"
        }
    }

    static func errorKey(_ error: String) -> LocalizedStringKey {
        switch error {
        case "activeSession": "请先取消当前计时，再新建。"
        case "invalidDuration": "请输入有效时长。倒计时最长 31 天。"
        case "invalidLabel": "标签最多 120 个字，不能包含换行。"
        case "alarmInPast": "这个闹钟时刻已经过去，请重新选择。"
        case "ambiguousZone": "这个时区缩写有歧义，请使用完整时区名称或 UTC 偏移。"
        case "unknownZone", "unknownPlace": "未识别这个时区，请使用已保存地点或完整时区名称。"
        case "nonexistentTime", "invalidDate": "该地点没有这个时刻，请调整日期或时间。"
        default: "无法识别时间，请输入明确日期、时刻和时区。"
        }
    }
}
