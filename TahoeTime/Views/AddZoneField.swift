// SPDX-License-Identifier: GPL-3.0-only
//
//  AddZoneField.swift
//  TahoeTime
//
//  添加时区:系统搜索框(NSSearchField)+ 系统 List 补全。结果用 List 的系统选中高亮
//  (正确的选中几何全由系统给)。**鼠标点选即添加**;键盘走搜索框转交的 ↑ / ↓ 高亮 +
//  回车确认(见 SearchField.onKeyCommand)——两条路都能完成核心操作。Esc 清空搜索词。
//  不自绘控件、无魔法圆角。
//

import SwiftUI

struct AddZoneField: View {
    @Environment(AppModel.self) private var model
    /// 选中一项时的去处：默认加进地点列表；人物编辑器借它选所在地时传自己的回调。
    var onSelect: ((ZoneOption) -> Void)? = nil
    @State private var query = ""
    @State private var selection: ZoneOption.ID? = nil
    /// 键盘 ↑ / ↓ 移动高亮也会改 `selection`,但只是预览、不提交;用这面旗子让
    /// `onChange(of: selection)` 区分"键盘高亮"(跳过)与"鼠标点选"(立即添加)。
    @State private var keyboardNavigating = false
    /// 「跳到」行第二行选的读法（换了搜索词就回到默认）。
    @State private var jumpChoice = TimeUnderstanding.Choice()
    @State private var jumpOrigin: TimeUnderstanding.Origin = .typed
    // 行高随 Dynamic Type 缩放(不写死 point)。
    @ScaledMetric(relativeTo: .body) private var resultRowHeight: CGFloat = 40

    private var coordinatesUnavailable: Bool {
        #if DEBUG
        if ApplicationSession.isTesting, ApplicationSession.uiTestSurface == "panel",
           ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_MISSING_COORDINATES"] == "1" {
            return true
        }
        #endif
        return ZoneCatalog.shared.coordinatesUnavailable
    }

    /// 搜索框认时间句：「明天 9:00 东京」「9am」「三小时后 纽约」经口语理解解析成一个时刻，
    /// 回车或点它，整个面板穿梭到那一刻——各地的时间、昼夜条的参考线、地图的晨昏线一起动，「现在」回来。
    /// 只在面板自己的搜索框认（人物编辑器借这个视图选所在地时 `onSelect` 非空，不认）。读不懂就当城市名搜，不猜。
    private var jumpCandidate: (date: Date, zone: TimeZone)? {
        jumpResolution.flatMap { resolution in resolution.dates.first.map { ($0, resolution.timeZone) } }
    }

    /// 读成的那一处（带全部候选）。`jumpChoice` 是「跳到」行第二行里切换的读法。
    private var jumpResolution: TimeInput.Resolution? {
        guard onSelect == nil, !query.isEmpty else { return nil }
        let resolution = TimeInput.resolve(query, relativeTo: model.now, now: model.now, in: .current,
                                           preferredZones: model.zones.map(\.timezoneID), origin: jumpOrigin, choice: jumpChoice)
        guard resolution.error == nil, !resolution.dates.isEmpty else { return nil }
        return resolution
    }

    private var understandingStyle: UnderstandingText.Style {
        let core = model.core
        let cityLocale = core.cityLocale
        return UnderstandingText.Style(locale: model.uiLocale, hourStyle: model.settings.hourStyle, now: model.now,
                                       name: { core.placeName(forTimeZoneID: $0.identifier) },
                                       cityName: { CityNameLanguage.name(from: CityIndex.shared.localizedNames(cityIndex: $0), locale: cityLocale) })
    }

    /// 有几种读法时（IST、10/3、九月的 PST）「跳到」行下面多一行小字：现在按哪种读，点开换。
    private func readingSwitch(_ resolved: TimeUnderstanding.Resolved, at date: Date) -> some View {
        let style = understandingStyle
        let current = resolved.zoneOptions.count > 1
            ? UnderstandingText.zoneLabel(resolved.zoneOption, among: resolved.zoneOptions, at: date, style: style, pasted: jumpOrigin == .pasted)
            : UnderstandingText.readingLabel(resolved.reading, of: resolved, style: style)
        return HStack(spacing: 6) {
            Text("读成").appFont(.caption).foregroundStyle(.panelSecondary)
                .fixedSize(horizontal: true, vertical: false)
            // 有边框的弹出菜单：无边框的命中区只有 16 点（项目第四次踩这个坑），读屏念「按哪种理解」与当前读法。
            if resolved.zoneOptions.count > 1 {
                Picker("按哪种理解", selection: Binding(get: { resolved.zoneOption.id }, set: { jumpChoice.zone = $0 })) {
                    ForEach(resolved.zoneOptions) { option in
                        Text(verbatim: UnderstandingText.zoneLabel(option, among: resolved.zoneOptions, at: date, style: style, pasted: jumpOrigin == .pasted))
                            .tag(option.id)
                    }
                }
                .labelsHidden().fixedSize()
            } else {
                Picker("按哪种理解", selection: Binding(get: { resolved.reading.id }, set: { jumpChoice.reading = $0 })) {
                    ForEach(resolved.readings) { reading in
                        Text(verbatim: UnderstandingText.readingLabel(reading, of: resolved, style: style)).tag(reading.id)
                    }
                }
                .labelsHidden().fixedSize()
            }
            Spacer()
        }
        .padding(.leading, 28)
        .accessibilityValue(Text(verbatim: current))
    }

    private func jumpText(_ jump: (date: Date, zone: TimeZone)) -> String {
        let place = model.core.placeName(forTimeZoneID: jump.zone.identifier)
        let moment = ClockText.dateTime(jump.date, in: jump.zone, hourStyle: model.settings.hourStyle, locale: model.uiLocale, now: model.now)
        return "\(place) \(moment)"
    }

    private func perform(_ jump: (date: Date, zone: TimeZone)) {
        model.jump(to: jump.date)
        query = ""
        selection = nil
    }

    /// 框里的提示：读得懂时间的框（面板、找碰头时间页的「添加地点…」）直说「搜索城市或输入时间」：
    /// 能读时间是 Dayside 最好的本事之一，此前的「搜索城市或时区…」没提，新人发现不了。不轮换例句：
    /// 面板一天开几十次，框里的字自己动会抢眼，读屏也会一遍遍念新的；例句放在悬停提示与读屏说明里，一句、不动。
    /// 借这个框选所在地的人物编辑器（`onSelect`）不读时间，照旧「搜索城市或时区…」。
    private var placeholder: String {
        L10n.string(onSelect == nil ? "搜索城市或输入时间" : "搜索城市或时区…", locale: model.uiLocale)
    }

    /// 悬停提示与读屏说明：例句就是换算页的那一条（十六语各自的写法，`LanguageReadingTests` 逐语核过引擎读得懂）。
    private var fieldHelp: String {
        guard onSelect == nil else { return "" }
        return String(format: L10n.string("也能输入时间，例如「%@」", locale: model.uiLocale),
                      L10n.string("明天 9:00 东京", locale: model.uiLocale))
    }

    var body: some View {
        let results = searchResults
        let placeholder = placeholder
        VStack(spacing: 8) {
            // NSSearchField 的 placeholder 是 String,拿不到环境 locale,按界面语言取串。
            SearchField(text: $query,
                        placeholder: placeholder,
                        help: fieldHelp,
                        onKeyCommand: { handleKeyCommand($0, results: results) },
                        onPaste: { jumpOrigin = .pasted })
                .accessibilityLabel(Text(verbatim: placeholder))
                .frame(maxWidth: .infinity)
                .onAppear {
                    #if DEBUG
                    // 截图夹具：`MEANTIME_UI_TEST_PANEL_QUERY` 预填搜索词（拍「跳到…」那一行）。
                    if ApplicationSession.isTesting, query.isEmpty,
                       let preset = ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_PANEL_QUERY"] { query = preset }
                    #endif
                }
                .onChange(of: query) {
                    jumpChoice = .init()
                    if query.isEmpty { jumpOrigin = .typed }
                }

            if let jump = jumpCandidate {
                let sentenceNote = jumpResolution?.resolved.flatMap { UnderstandingText.sentenceNote($0, style: understandingStyle) }
                Button { perform(jump) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.turn.down.right")
                        VStack(alignment: .leading, spacing: 1) {
                            Text("跳到 \(jumpText(jump))")
                            Text(verbatim: String(format: L10n.string("本机：%@", locale: model.uiLocale),
                                                  ClockText.dateTime(jump.date, in: .current, hourStyle: model.settings.hourStyle,
                                                                     locale: model.uiLocale, now: model.now)))
                                .appFont(.caption).foregroundStyle(.panelSecondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4).padding(.horizontal, 6)
                    .frame(minHeight: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: [String(format: L10n.string("跳到 %@", locale: model.uiLocale), jumpText(jump)), sentenceNote]
                    .compactMap { $0 }.joined(separator: "。")))
                .accessibilityHint(Text("面板上各地的时间都跳到这一刻"))
                .accessibilityIdentifier("panel-jump")
                if let sentenceNote {
                    Text(verbatim: sentenceNote)
                        .appFont(.caption).foregroundStyle(.panelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 28)
                        .accessibilityHidden(true)
                }
                if let resolved = jumpResolution?.resolved, resolved.zoneOptions.count > 1 || resolved.readings.count > 1 {
                    readingSwitch(resolved, at: jump.date)
                }
            }

            // 坐标表没打进包 / 损坏 → 目录为空、搜什么都没有结果。说明原因,而不是让用户对着一个
            // 永远搜不到东西的框反复试（Release 下 assertionFailure 被优化掉）。
            if coordinatesUnavailable {
                ErrorLine(Text("时区数据未随应用一起安装，搜索不可用。"))
                    .appFont(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if !results.isEmpty {
                List(results, selection: $selection) { zone in
                    resultRow(zone)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(height: PresentationCore.scalar("search_height", ["count": Double(results.count), "rowHeight": resultRowHeight]))
                .onChange(of: selection) { _, newValue in
                    let action: PresentationCore.SearchTransition = PresentationCore.call("search_event",
                        PresentationCore.SearchEvent(state: .init(query: query, selection: newValue,
                            keyboardNavigating: keyboardNavigating), ids: results.map(\.id), kind: "selectionChanged"))
                    apply(action, results: results)
                }
            }
        }
    }

    /// 搜索框转交的键盘命令:↑ / ↓ 在结果里移动高亮,回车添加高亮项(未高亮取第一项),
    /// Esc 清空搜索词;返回 false 让 AppKit 走默认(如空搜索词时 Esc 关面板)。
    private func handleKeyCommand(_ command: SearchField.KeyCommand, results: [ZoneOption]) -> Bool {
        // 时间句：回车直接穿梭，不进城市结果的状态机。
        if case .commit = command, let jump = jumpCandidate {
            perform(jump)
            return true
        }
        let code: String
        switch command {
        case .moveDown: code = "down"
        case .moveUp: code = "up"
        case .commit: code = "commit"
        case .cancel: code = "cancel"
        }
        let action: PresentationCore.SearchTransition = PresentationCore.call("search_event",
            PresentationCore.SearchEvent(state: .init(query: query, selection: selection,
                keyboardNavigating: keyboardNavigating), ids: results.map(\.id), kind: "key", command: code))
        apply(action, results: results)
        return action.handled
    }

    private func apply(_ action: PresentationCore.SearchTransition, results: [ZoneOption]) {
        if let index = action.commitIndex {
            if let onSelect { onSelect(results[index]) } else { model.addZone(results[index]) }
        }
        query = action.state.query
        keyboardNavigating = action.state.keyboardNavigating
        selection = action.state.selection
    }

    private var searchResults: [ZoneOption] {
        guard PresentationCore.call("search_active", ["query": query], as: Bool.self) else { return [] }
        return ZoneCatalog.shared.search(query, locale: model.citySearchLocale)
    }

    private func resultRow(_ zone: ZoneOption) -> some View {
        // 副标题给的是「行政区, 国家」(国家名按界面语言),同名城市靠它区分:
        // 23 万座城市里 San Jose 有好几座,只显示时区标识分不清哪座。
        let name = model.displayName(for: zone)
        let subtitle = zone.subtitle(locale: model.uiLocale, displayName: name)
        return HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .appFont(.caption)
                        .foregroundStyle(.panelSecondary)
                }
            }
            Spacer()
        }
        .help(zone.identifier)
    }
}
