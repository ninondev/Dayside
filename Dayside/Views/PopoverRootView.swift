// SPDX-License-Identifier: GPL-3.0-only
//
//  PopoverRootView.swift
//  Dayside
//
//  菜单栏下拉面板根视图(window 风格)。
//  从上到下是搜索栏、此刻的昼夜地图（满幅）、时间穿梭（轨道是这里前后 12 小时的天）、各地的行
//  （每行涂那里此刻的天）、找碰头时间那一行结论、底栏。框（搜索栏、穿梭、底栏与它们之间的底）按设置「面板底色」涂这里此刻的天顶
//  （字用墨或纸，系统控件跟着换浅深），或者跟系统（系统的玻璃与浅深色，此前的样子）。
//  一个地点都没有时照样画这张地图（太阳、晨昏线、城市灯火都在，只是还没有地点的圈），下面一句话与建议按钮：
//  第一眼看到的就是 Dayside 的天，不是一页系统样式的「还没有地点」。
//

import SwiftUI
import AppKit

struct PopoverRootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.featureHub) private var featureHub
    @Environment(\.openWindow) private var openWindow
    @Environment(\.undoManager) private var undoManager
    @State private var renaming: TimeZoneEntry? = {
        #if DEBUG
        if ApplicationSession.isTesting, ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_COPY_CLOCK_SHIFT"] == "1",
           !AppModel.shared.zones.contains(where: { $0.timezoneID == "Australia/Sydney" }),
           let zone = ZoneCatalog.shared.option(for: "Australia/Sydney") {
            AppModel.shared.addZone(zone)
        }
        if ApplicationSession.isTesting, ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_COPY_RENAME"] == "1" {
            return AppModel.shared.zones.first
        }
        #endif
        return nil
    }()
    /// 单一滚动区的内容实高：ScrollView 自己不会按内容定高，量出来再取 min(内容, 预算)。
    @State private var bodyHeight: CGFloat = 0
    @MainActor private static var loggedUndoManager = false
    /// 空态的建议地点：通讯录要在主线程外枚举，所以异步装填，先显示本机那一颗。
    @State private var suggestions: [ZoneOption] = []
    /// 指针停在哪一行、键盘选中了哪一行：地图上写出那个地方的名字与时间。
    @State private var hoveredZone: UUID?
    @State private var selectedZone: UUID?

    private var layout: PresentationCore.PanelLayout {
        PresentationCore.call("panel_layout", PresentationCore.PanelInput(screenHeight: Double(NSScreen.main?.visibleFrame.height ?? 800)))
    }

    /// 「东京和马德里」：名字与列表行同一出口（自定义名 / 界面语言的城市名），多个按界面语言连接（ListFormatter）。
    private func removedNames(_ pending: AppModel.PendingRemoval) -> String {
        let names = pending.items.map { $0.entry.displayName(localizedCity: model.cityName(for: $0.entry)) }
        let formatter = ListFormatter()
        formatter.locale = model.uiLocale
        return formatter.string(from: names) ?? names.joined(separator: ", ")
    }


    /// 空态的建议按钮；异步结果还没到时先给本机那一颗。
    @ViewBuilder private var suggestionButtons: some View {
        let shown = suggestions.isEmpty ? [SuggestedPlaces.option(identifier: TimeZone.current.identifier)] : suggestions
        ForEach(shown, id: \.id) { option in
            Button {
                model.addZone(option)
            } label: {
                Text("添加 \(model.displayName(for: option))")
            }
        }
    }

    /// 滚动区里的内容：地点列表（或空态）、撤销行、穿梭控件、找碰头时间那一行。
    @ViewBuilder private var scrollingBody: some View {
        if model.zones.isEmpty {
            // 空态：同一张满幅地图（此刻的太阳、晨昏线、城市灯火，还没有地点的圈），只看不拖：
            // 这里没有滑块与「回到现在」，拖动挪了时间却没处看、也没处回来。地图开关关着也画（第一眼要看到的就是它）。
            WorldMapView(interactive: false, cornerRadius: 0)
            VStack(alignment: .leading, spacing: 10) {
                // 一句话指向上面的搜索框与这张图；建议按钮直接写地名（「添加洛杉矶」），最多三颗，
                // 本机之外再建议已保存人物的所在地、系统「地区」所在国家的最大城市、日历里出现过的时区与通讯录地址里最常见的城市
                // （后两者已授权才读，不弹授权框）；从系统时区目录或城市索引取项、带坐标。三颗并排放不下就上下排。
                Text("在上方搜索城市，它会出现在这张图上")
                    .appFont(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                ViewThatFits(in: .horizontal) {
                    HStack { suggestionButtons }
                    VStack(alignment: .leading) { suggestionButtons }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 14, leading: 16, bottom: 16, trailing: 16))
            .task(id: featureHub?.peoplePlaces.count ?? 0) {
                suggestions = await SuggestedPlaces.load(people: featureHub?.peoplePlaces ?? [], now: model.now)
            }
        } else {
            // 昼夜地图：Dayside 名字的本义——地球被太阳照亮的那半边，此刻在哪。
            // 满幅贴边（地图本身就是天色，不再装在一个圆角框里）；指针停在某一行时地图上写出那个地方。
            if model.settings.panelShowsMap {
                // 地图可以拖（太阳跟着指针、时间跟着太阳），连按两次放大成地球窗。
                WorldMapView(interactive: true, opensEarth: true, highlightZone: hoveredZone ?? selectedZone, cornerRadius: 0)
            }
            // 时间穿梭放在地图与各行之间：先看世界，再挑时刻，再读各地。
            TimeScrollerView()
                .padding(EdgeInsets(top: 10, leading: 16, bottom: 12, trailing: 16))
            TimeZoneListView(hovered: $hoveredZone, onRename: { renaming = $0 }, selection: $selectedZone)
            // 「现在能打给谁」模式下的一行提示：谁是下一个进入工作时段的、还要多久。
            // 全都能打时没有这一行（没什么可等的）。
            if model.settings.panelSort == .callable {
                let order = model.panelOrder
                if let next = order.nextZone, let minutes = order.nextInMinutes {
                    // 全表同一个判定基准时，提示行前面带上它（按上班时段 / 按醒着时段）；两种混用就不缀，免得说错。
                    let bases = Set(order.zones.map(\.callBasis))
                    let basisPrefix = bases.count == 1
                        ? L10n.string(bases.first == .work ? "按上班时段" : "按醒着时段", locale: model.uiLocale) + " · "
                        : ""
                    let hint = String(format: L10n.string("下一个能打：%1$@（%2$@）", locale: model.uiLocale),
                                      next.displayName(localizedCity: model.cityName(for: next)),
                                      ClockText.durationIn(seconds: Double(minutes) * 60, locale: model.uiLocale))
                    Text(verbatim: basisPrefix + hint)
                        .appFont(.caption)
                        .foregroundStyle(.panelSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.bottom, 6)
                }
            }
        }

        // 刚删掉的地点可撤销：一行系统样式的提示（文字 + 小按钮），不自绘；
        // 留到下一次编辑而不是 3 秒消失，⌘Z / ⇧⌘Z 走窗口的撤销管理器。
        // 删光后空态在上面，这一行仍在，所以放在 if / else 之外。
        if let pending = model.pendingRemoval {
            HStack {
                Text("已删除「\(removedNames(pending))」").appFont(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                Spacer()
                Button("撤销") { model.restoreRemovedZones() }.controlSize(.small)
                    .fixedSize(horizontal: true, vertical: false)
                    .help(Text("也可以按 ⌘Z；⇧⌘Z 再删"))
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .accessibilityIdentifier("panel-undo-removal")
        }

        if !model.zones.isEmpty {
            PanelHairline()

            // 模块登记的面板节：找碰头时间那一行结论（`PanelMeetingLine`），点了开工具窗那一页。
            if let hub = featureHub {
                ForEach(hub.panelSections, id: \.0) { _, section in
                    section.panelSection()
                }
            }
        }
    }

    var body: some View {
        let layout = layout
        PanelSkyHost(followsSky: model.settings.panelColors == .sky) {
            VStack(spacing: 0) {
                // 排序开关放在底栏：面板顶上只剩搜索框，一眼就是「找城市」。
                AddZoneField()
                .padding()                  // 系统默认内边距,不写死数值

                // 启动时发现持久化数据损坏 → 提示一次(原始字节已备份、可读条目已抢救)。
                if model.zonesRecoveryNotice {
                    ErrorLine(Text("时区数据曾损坏：已备份原始数据，并恢复了可读的部分。"))
                        .appFont(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                }

                PanelHairline()

                // 面板只有一个滚动区：地点列表整行取高、穿梭控件与找碰头时间那一行按内容长高，一起滚；
                // 高度 = min(内容, 屏幕预算)。此前列表与规划区各自一个限高滚动区，长语言的规划区把东京那行时间轴
                // 与图例整个挤出可见区，英文空态末行也被裁过。
                ScrollView {
                    VStack(spacing: 0) {
                        scrollingBody
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bodyHeight = $0 }
                }
                .frame(height: min(max(bodyHeight, 1), layout.body))

                PanelHairline()

                if let hub = featureHub, let meeting = hub.nextMeeting(now: model.now) {
                    Button {
                        hub.selection = .agenda
                        openWindow(id: "tools")
                    } label: {
                        HStack {
                            Image(systemName: "calendar")
                            Text(meeting.title)
                                .fixedSize(horizontal: false, vertical: true)
                                .layoutPriority(1)
                            Spacer()
                            // 跟设置里的小时制走（`style: .time` 只跟系统）。
                            Text(verbatim: TimeFormatting.string(for: meeting.start, in: .current,
                                                                 format: ClockFormat(hourStyle: model.settings.hourStyle, showSeconds: false)))
                                .monospacedDigit()
                                .fixedSize(horizontal: true, vertical: false)
                        }.appFont(.caption).padding(.vertical, 3).frame(minHeight: 24).contentShape(Rectangle())
                    }.buttonStyle(.plain).padding(8)
                        .fixedSize(horizontal: false, vertical: true)
                    PanelHairline()
                }

                FooterBar(showsSort: model.zones.count > 1)
                    .padding(8)
            }
        }
        // 开关一律勾选框：macOS 26 的 switch 样式首帧要 ~35 MB 瞬时图形缓冲，勾选框没有。
        .toggleStyle(.checkbox)
        .frame(width: 320)
        #if DEBUG
        .modifier(SkyA11yFixtures())
        #endif
        .onAppear {
            model.setPanelVisible(true)
            model.panelUndoManager = undoManager
            // 诊断包里留一行证据：真实 MenuBarExtra 面板有没有拿到窗口的撤销管理器（⌘Z 路径），只记第一次。
            if !Self.loggedUndoManager {
                Self.loggedUndoManager = true
                DiagnosticsLog.note("panel", "undo manager \(undoManager == nil ? "missing" : "available")")
            }
        }
        .onChange(of: undoManager == nil) { model.panelUndoManager = undoManager }
        #if DEBUG
        .task {
            if ApplicationSession.isTesting, ApplicationSession.uiTestSurface == "panel",
               ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_PANEL_RENAME"] == "1" {
                try? await Task.sleep(for: .milliseconds(200))
                renaming = model.zones.first
            }
            // 截图夹具：`MEANTIME_UI_TEST_ROW_MENU=1|copy` 弹出第一行的右键菜单（只在测试宿主）。
            RowMenuFixture.runIfRequested(model: model, hub: featureHub)
            // 截图夹具：`MEANTIME_UI_TEST_JUMP_HOURS=<小时>` 打开面板后跳到此刻前后那么多小时（拍白天、晨昏与夜里的框；只在测试宿主）。
            guard ApplicationSession.isTesting, let raw = ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_JUMP_HOURS"],
                  let hours = Double(raw) else { return }
            try? await Task.sleep(for: .milliseconds(200))
            model.jump(to: model.now.addingTimeInterval(hours * 3600), animated: false)
        }
        #endif
        .onDisappear { model.setPanelVisible(false) }
        // sheet / popover 是另一个呈现根，不继承根视图注入的 `\.locale`（界面语言与系统语言不同时会露出系统语言，
        // 所以每处呈现根都要再注入一次界面语言。
        .sheet(item: $renaming) { zone in
            RenameSheet(zone: zone).environment(model).environment(\.locale, model.uiLocale)
        }
    }
}

/// 面板里找碰头时间那一行：320 点宽的面板不再塞一个缩小版的排会器（参与者、两个菜单、
/// 结果、时间轴、图例，把面板拉到约 865 点高），只说结论：最早一段所有人都合适的时段（「明天 7:00–8:00，所有人都合适」），
/// 或者这段范围里没有；点了开工具窗那一页。参与者与那一页同一组（面板里勾着的地点与本机，时长、范围、理想时段同一份偏好），
/// 所以那一页一打开就是同一群人。这一行之外不构造任何排会的视图；结论在后台算，只在这一行出现、看的那一天、每一刻钟
/// （最早能开始的时刻往后挪）或参与者与偏好变了时算一次。面板关了它就没了。
struct PanelMeetingLine: View {
    @Environment(TimeCore.self) private var core

    var body: some View {
        // 外层读看的那一刻（拖时间时逐帧），只把「看的那一天」与此刻（每分钟走一格）传进去：里层只在它们变了时才重画，
        // 候选只在参与者、偏好、看的那一天或最早能开始的那一刻钟变了时才重算（`.task(id:)`）。
        PanelMeetingLineBody(day: Self.localDay(core.referenceDate), now: core.now)
    }

    /// 那一刻在本机是哪一天（0 点）。
    private static func localDay(_ date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        return calendar.startOfDay(for: date)
    }
}

private struct PanelMeetingLineBody: View {
    let day: Date
    let now: Date
    @Environment(TimeCore.self) private var core
    @Environment(\.featureHub) private var featureHub
    @Environment(\.openWindow) private var openWindow
    @Environment(\.textScale) private var textScale
    @State private var computed: PanelMeetingSummary.Conclusion?

    var body: some View {
        let inputs = PanelMeetingSummary.inputs(core: core, day: day, now: now)
        // 重算的那几毫秒里先留着上一次的结论（每一刻钟、改了参与者时不闪成页名）；第一次打开时还没有，写页名。
        let conclusion = computed
        Button { open() } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "calendar.badge.clock").accessibilityHidden(true)
                Text(sentence(conclusion, inputs: inputs))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .imageScale(.small)
                    .foregroundStyle(.panelSecondary)
                    .accessibilityHidden(true)
            }
            .appFont(.callout)
            .padding(EdgeInsets(top: 9, leading: 16, bottom: 9, trailing: 16))
            .frame(minHeight: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text("在「找碰头时间」里查看"))
        .accessibilityHint(Text("在「找碰头时间」里查看"))
        .accessibilityIdentifier("panel-meeting")
        .task(id: inputs) {
            guard let request = inputs.request else {
                computed = .needsTwo
                return
            }
            let result = await Task.detached(priority: .userInitiated) { OverlapPlanner.plan(request) }.value
            guard !Task.isCancelled else { return }
            computed = PanelMeetingSummary.conclusion(result)
        }
    }

    /// 还没算出来、或参与者不到两个时只写页名（这一行就是去那一页的门）；算出来是一句结论。
    private func sentence(_ conclusion: PanelMeetingSummary.Conclusion?, inputs: PanelMeetingSummary.Inputs) -> AttributedString {
        let locale = core.uiLocale
        switch conclusion {
        case .slot(let start, let end)?:
            // 结论在前：先说哪段时间（今天、明天按句首写法），再说「所有人都合适」。
            let when = ClockText.relativeInterval(from: start, to: end, in: .autoupdatingCurrent, hourStyle: core.settings.hourStyle,
                                                  locale: locale, now: now, sentenceStart: true)
            let formatted = String(format: L10n.string("%@，所有人都合适", locale: locale), locale: locale, when)
            var text = AttributedString(formatted)
            if !when.isEmpty, let range = text.range(of: when) {
                let font: Font = textScale == 1 ? .system(.callout) : .system(size: AppFont.size(.callout) * textScale)
                text[range].font = font.weight(.semibold).monospacedDigit()
            }
            return text
        case .noSlot?:
            if !inputs.fromToday {
                return AttributedString(L10n.string("没有所有人都合适的时段", locale: locale))
            } else if inputs.days == 1 {
                return AttributedString(L10n.string("今天没有所有人都合适的时段", locale: locale))
            } else {
                return AttributedString(String(format: L10n.string("未来 %lld 天没有所有人都合适的时段", locale: locale),
                                               locale: locale, Int64(inputs.days)))
            }
        case .needsTwo?, nil:
            return AttributedString(L10n.string("找碰头时间", locale: locale))
        }
    }

    private func open() {
        guard let hub = featureHub else { return }
        hub.showPlannerFromPanel()
        openWindow(id: "tools")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

/// 那一行的输入与结论（纯逻辑，测试直接调）。参与者的取法与工具窗那一页的地点那一半同一套 Rust 规则
/// （`presentation.planner_rows` 定哪几行、`planner_inputs` 定谁参加与最早能开始的时刻）；人物不进来：那一页的人物勾选不存盘，
/// 每次打开都是空的，这一行与它一致。
enum PanelMeetingSummary {
    struct Inputs: Hashable {
        /// nil = 参加的不到两个，算不了。
        let request: OverlapPlanner.Request?
        /// 看的那一天就是今天（「今天没有」「未来 7 天没有」只在这时候说得准）。
        let fromToday: Bool
        let days: Int
    }

    enum Conclusion: Equatable {
        case needsTwo
        /// 最早一段所有人都合适的时段：最早能开始到最晚结束。
        case slot(start: Date, end: Date)
        case noSlot
    }

    @MainActor static func inputs(core: TimeCore, day: Date, now: Date, local: TimeZone = .autoupdatingCurrent) -> Inputs {
        let prefs = core.settings.planner
        let facts = core.zones.map {
            PresentationCore.PlannerZoneFact(id: $0.id, timeZoneId: $0.timezoneID, customName: $0.customName,
                                             cityName: $0.cityName, localizedCity: core.localizedCity($0))
        }
        let rows: [PresentationCore.PlannerRowChoice] = PresentationCore.call("planner_rows", PresentationCore.PlannerRowsInput(
            zones: facts, excluded: prefs.excludedZoneIDs, localTimeZoneId: local.identifier,
            localName: String(format: L10n.string("本机（%@）", locale: core.uiLocale), core.placeName(forTimeZoneID: local.identifier)),
            includeLocal: prefs.includeLocal))
        let ids: [UUID?] = rows.map { $0.sourceIndex < 0 ? nil : core.zones[$0.sourceIndex].id }
        let calendarFacts = PresentationCore.CalendarFacts(fromDay: day, now: now, timeZone: local)
        let selected: PresentationCore.PlannerInputChoice = PresentationCore.call("planner_inputs", PresentationCore.PlannerInputFacts(
            rows: zip(ids, rows).map { .init(id: $0.0, participates: $0.1.participates) }, calendar: calendarFacts))
        let fromToday = calendarFacts.fromDay == calendarFacts.todayStart
        guard selected.canPlan else { return Inputs(request: nil, fromToday: fromToday, days: prefs.daysAhead) }
        let participants = selected.participants.map { choice -> OverlapPlanner.Participant in
            let row = rows[choice.index]
            if row.sourceIndex < 0 {
                // 本机的坐标：列表里有本机所在地就用它的，否则用随包 tzcoords 的代表城市（不碰城市索引）。
                return OverlapPlanner.Participant(id: choice.id, name: row.name, timeZoneID: local.identifier,
                    availability: prefs.localAvailability, countryCode: Locale.autoupdatingCurrent.region?.identifier,
                    coordinate: core.zones.first { $0.timezoneID == local.identifier }?.coordinate
                        ?? ZoneCatalog.shared.knownCoordinate(for: local.identifier))
            }
            let zone = core.zones[row.sourceIndex]
            return OverlapPlanner.Participant(id: choice.id, name: row.name, timeZoneID: zone.timezoneID,
                availability: zone.effectiveAvailability, countryCode: zone.countryCode,
                coordinate: zone.coordinate, offsetOnlyZoneName: zone.offsetOnlyZoneName)
        }
        // 结果按舒适度排、默认只留 8 段；要的是「最早」那一段，所以多要一些（范围最多 31 天，一天一两段）。
        let request = OverlapPlanner.Request(participants: participants, from: Date(timeIntervalSince1970: selected.notBefore),
                                             days: prefs.daysAhead, durationMinutes: prefs.durationMinutes,
                                             localTimeZoneID: local.identifier, limit: 64, idealWindow: prefs.idealWindow)
        return Inputs(request: request, fromToday: fromToday, days: prefs.daysAhead)
    }

    static func conclusion(_ result: OverlapPlanner.Result) -> Conclusion {
        guard let first = result.everyone.min(by: { $0.start < $1.start }) else { return .noSlot }
        return .slot(start: first.start, end: first.end)
    }
}

/// 面板的天色：按看的那一刻算一次（Rust `sky.panel`），往下传给地图以外的各块；框跟着天色时在这里涂框的底、
/// 定字色（墨或纸）与系统控件的浅深。只有它读时刻：拖时间时 ~30 Hz 重算的是它，面板其余部分只按读没读天色重渲。
private struct PanelSkyHost<Content: View>: View {
    @Environment(AppModel.self) private var model
    @Environment(TimeCore.self) private var core
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityInvertColors) private var invertColors
    let followsSky: Bool
    @ViewBuilder let content: Content

    var body: some View {
        let sky = SkyPanel.compute(instant: core.referenceDate, now: core.now, zones: model.panelOrder.zones,
                                   need: contrast == .increased ? 7 : 5.5, locale: core.uiLocale, flat: contrast == .increased)
        content
            .environment(\.panelSky, sky)
            .environment(\.panelFollowsSky, followsSky)
            .modifier(ChromePaint(chrome: followsSky ? sky.chrome : nil))
            // 反色开着：整块面板（框、行、滑块、地图的覆盖层）预反一次，并让子里的天色件不再各自反；
            // `.colorInvert` 连地图的 AppKit 图层一起反（实测），地图不另反。不跟天色时不反，各天色件自己反。
            .modifier(PanelPreInvert(enabled: followsSky && invertColors))
    }
}

/// 面板跟着天色且反色开着：内容整块 `.colorInvert` 一次（系统再反一次，看到的就是原来的天色），
/// 同时置 `skyPreInverted`，拦住子视图的第二遍反色。
private struct PanelPreInvert: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.colorInvert().environment(\.skyPreInverted, true)
        } else {
            content
        }
    }
}

/// 框跟着天色：底涂这里此刻的天顶，字是墨或纸，系统控件（搜索框、按钮、勾选框）按底的浅深换外观。
/// 外观要落到窗口上（`preferredColorScheme`），只改 SwiftUI 的 `colorScheme` 环境不够：面板开着时底的浅深一变
/// （拖时间跨过黎明、系统切深浅色），系统勾选框仍按窗口原来的外观画字，可能出现浅底白字；
/// 深色外观、洛杉矶清晨；启动时就定好外观的截图里是对的，所以只有「开着时变」才露出来）。
private struct ChromePaint: ViewModifier {
    let chrome: SkyPanel.Colors?

    func body(content: Content) -> some View {
        if let chrome {
            #if DEBUG
            let scheme = AXCaptureAppearance.isForced ? (AXCaptureAppearance.shared.scheme ?? chrome.scheme) : chrome.scheme
            #else
            let scheme = chrome.scheme
            #endif
            content
                .foregroundStyle(chrome.foreground)
                .background(chrome.topColor)
                .environment(\.colorScheme, scheme)
                .preferredColorScheme(scheme)
        } else {
            content.preferredColorScheme(nil)
        }
    }
}

/// 框里各块之间的一道细线：跟着天色时是字色的 20%，跟着系统时是系统分隔线。
private struct PanelHairline: View {
    @Environment(\.panelSky) private var sky
    @Environment(\.panelFollowsSky) private var followsSky

    var body: some View {
        Rectangle()
            .fill(followsSky ? AnyShapeStyle((sky?.chrome.foreground ?? .primary).opacity(0.2)) : AnyShapeStyle(.separator))
            .frame(height: 0.5)
            .accessibilityHidden(true)
    }
}

#if DEBUG
/// 截图夹具（与其它 `MEANTIME_UI_TEST_*` 同一套读法，只在测试宿主）：
/// `MEANTIME_UI_TEST_INVERT=1` 把反色、`MEANTIME_UI_TEST_NO_COLOR=1` 把「不使用颜色区分」、
/// `MEANTIME_UI_TEST_CONTRAST=increased` 把「提高对比度」在所在根视图设为开；
/// 面板根、地球窗根与工具窗根各挂一次。没设的那个不动，仍跟系统真实设置。
struct SkyA11yFixtures: ViewModifier {
    /// 进程里只读一次环境变量：它挂在面板根与工具窗正文那一栏上，每次重画都整份读一遍环境会白白多出临时分配
    /// （Debug 量内存时会算进去）。
    private static let on: (invert: Bool, noColor: Bool, contrast: Bool) = {
        guard ApplicationSession.isTesting else { return (false, false, false) }
        let environment = ProcessInfo.processInfo.environment
        return (environment["MEANTIME_UI_TEST_INVERT"] == "1", environment["MEANTIME_UI_TEST_NO_COLOR"] == "1",
                environment["MEANTIME_UI_TEST_CONTRAST"] == "increased")
    }()

    func body(content: Content) -> some View {
        content
            .modifier(InvertColorsFixture(on: Self.on.invert))
            .modifier(DifferentiateWithoutColorFixture(on: Self.on.noColor))
            .modifier(IncreasedContrastFixture(on: Self.on.contrast))
    }
}

private struct IncreasedContrastFixture: ViewModifier {
    let on: Bool

    func body(content: Content) -> some View {
        if on {
            content.environment(\._colorSchemeContrast, .increased)
        } else {
            content
        }
    }
}

/// 只在夹具开了才写环境值：无条件写会把系统真实的设置盖成关。
private struct InvertColorsFixture: ViewModifier {
    let on: Bool

    func body(content: Content) -> some View {
        if on {
            content.environment(\._accessibilityInvertColors, true)
        } else {
            content
        }
    }
}

private struct DifferentiateWithoutColorFixture: ViewModifier {
    let on: Bool

    func body(content: Content) -> some View {
        if on {
            content.environment(\._accessibilityDifferentiateWithoutColor, true)
        } else {
            content
        }
    }
}
#endif
