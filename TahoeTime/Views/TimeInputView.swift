// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import AppKit

/// 换算页（工具窗）。面板里输入时间只走顶上的搜索框（此前滑块旁还有一颗键盘图标开这一页的缩小版弹出框，2026-10-02 删）。
/// 换算页的魂：别人写下的那一刻，落在每个地方的天里。上面是那段话（像一封信，页首一行「洛杉矶 · 10月2日 周五」是它的落款：
/// 话里没写地点、没写日期的，按这里与这一天读），读懂的几段在字下面划线；中间「读到的时间」逐处说出读成了什么；
/// 下面是选中那一处在各地的时间：每个地方一行，中间一条那里当天的天，一根竖线穿过所有的天（`MomentTable`）。
/// 边输入边读（停 350 ms）；读的时候不跳，点一处也只是选中，按「在面板里看这一刻」（⌘↩）才让整个 App 跳到那一刻。
/// 有几种读法的（IST、10/3、九月的 PST）给候选菜单，选过的缩写在工具窗开着期间成为之后同一写法的默认；
/// 几天共用一个钟点的（「周二至周四 9–12 点」）引擎每天给一处，这里并成一行，选中时下面挑看哪一天。
/// Created only while the user opens the converter. No timers or observers; the city index opens only when the text has letters.
struct TimeInputView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.featureHub) private var hub
    @Environment(\.textScale) private var textScale
    @State private var text = ""
    @State private var sourceID = "local"
    /// 上一次读的结果，与读的那段文字（界面只拿配得上的一对）。
    @State private var output = TimeUnderstanding.Output()
    @State private var readText = ""
    /// 读了第几回：结果的记忆按它认（同一段字读两遍也算新的一回，选择要清掉）。
    @State private var readVersion = 0
    /// 选中的那一行（行里第一处在 `output.mentions` 里的下标）。
    @State private var selected: Int?
    /// 选中的是几天一组时，看的是第几天。
    @State private var seriesDay = 0
    @State private var choices: [Int: TimeUnderstanding.Choice] = [:]
    /// 打的字里「我这边」是这台 Mac；粘贴进来、从别的 App 送来的整段里是写信人。
    @State private var origin: TimeUnderstanding.Origin = .typed
    /// 夏令时结束那天重复的一小时：两个起点选第几个。
    @State private var candidate = 0
    /// 「今天」的锚：打开时 App 的时间偏移；自己跳过去之后不跟着变，否则再读「明天」就成了跳到的那天的明天（设计 10.4）。
    @State private var anchorOffset: TimeInterval = 0
    @State private var ownJumpOffset: TimeInterval?
    @State private var anchorTask: Task<Void, Never>?
    @State private var editorHeight: CGFloat = 76
    @State private var copied = false
    @State private var liveTask: Task<Void, Never>?
    /// 在共同时间轴上点出来的那一刻（只是看，读法不变）；nil = 看读出的那一刻。
    @State private var peek: Date?
    @State private var showingCalendar = false
    @State private var memo = ResolvedMemo()

    init(initialText: String = "", initialSourceID: String? = nil) {
        _text = State(initialValue: initialText)
        _sourceID = State(initialValue: initialSourceID ?? "local")
        // 从服务菜单、链接或快捷指令送来的整段：当作粘贴进来的。
        _origin = State(initialValue: initialText.isEmpty ? .typed : .pasted)
    }

    private var source: TimeZone {
        sourceEntry?.timeZone ?? .autoupdatingCurrent
    }

    private var sourceEntry: TimeZoneEntry? { model.zones.first { $0.id.uuidString == sourceID } }

    private var reference: Date { model.now.addingTimeInterval(anchorOffset) }

    private var context: TimeUnderstanding.Context {
        TimeUnderstanding.Context(reference: reference, now: model.now, fallback: source, home: .current,
                                  preferredZones: model.zones.map(\.timezoneID), origin: origin)
    }

    private var style: UnderstandingText.Style {
        let core = model.core
        let cityLocale = core.cityLocale
        return UnderstandingText.Style(locale: model.uiLocale, hourStyle: model.settings.hourStyle, now: model.now,
                                       name: { core.placeName(forTimeZoneID: $0.identifier) },
                                       cityName: { CityNameLanguage.name(from: CityIndex.shared.localizedNames(cityIndex: $0), locale: cityLocale) },
                                       reference: reference, home: .current)
    }

    /// 每一处的选择：点过的用点过的；没点过、这个写法在工具窗开着期间选过的，用那次的选择。
    private var effectiveChoices: [Int: TimeUnderstanding.Choice] {
        var result = choices
        for (index, mention) in output.mentions.enumerated() where result[index]?.zone == nil {
            if let written = UnderstandingText.zoneText(mention, in: readText)?.lowercased(),
               let remembered = hub?.zoneChoiceMemory[written] {
                result[index, default: .init()].zone = remembered
            }
        }
        return result
    }

    /// 落成的每一处。按「读了第几回、今天的锚、此刻的分钟、来源地点、选择」记住上一次：点时间轴、拷贝、窗口改大小都不再重算。
    private var resolved: [TimeUnderstanding.Resolved] {
        let choices = effectiveChoices
        let key = ResolvedMemo.Key(version: readVersion, reference: reference.timeIntervalSince1970,
                                   minute: Int((model.now.timeIntervalSince1970 / 60).rounded(.down)), source: source.identifier,
                                   pasted: origin == .pasted, preferred: model.zones.map(\.timezoneID), choices: choices)
        return memo.value(for: key) { TimeUnderstanding.resolveAll(output, context: context, choices: choices) }
    }

    /// 「读到的时间」的行：几天一组的并成一行（CONVENTIONS 第 12 条：同一组的几天相邻、带同一个号）。
    private var rows: [ReadingRow] { ReadingRow.group(output.mentions) }

    /// 选中的那一行与正在看的那一处（几天一组时是挑的那一天）；没选时是第一行读成了的。
    private func current(_ all: [TimeUnderstanding.Resolved]) -> (row: ReadingRow, index: Int, item: TimeUnderstanding.Resolved)? {
        let rows = rows
        let row = rows.first { $0.first == selected } ?? rows.first { row in row.indices.contains { all.indices.contains($0) && all[$0].problem == nil } }
        guard let row else { return nil }
        let readable = row.indices.filter { all.indices.contains($0) && all[$0].problem == nil }
        guard !readable.isEmpty else { return nil }
        let index = readable[min(max(seriesDay, 0), readable.count - 1)]
        return (row, index, all[index])
    }

    var body: some View {
        let all = resolved
        let chosen = current(all)
        page(all, chosen)
        .onAppear {
            anchorOffset = model.displayOffset
            #if DEBUG
            // 截图与转储夹具：灌一段文字（只在测试宿主生效）。
            if ProcessInfo.processInfo.environment["MEANTIME_TEST_HOST"] == "1",
               let sample = ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_CONVERT_TEXT"], !sample.isEmpty, text.isEmpty {
                text = sample
            }
            #endif
            read()
            #if DEBUG
            // 夹具：读完后在共同时间轴上「点」到读出的那一刻前后几小时（拍点过别处的样子；只在测试宿主生效）。
            if ProcessInfo.processInfo.environment["MEANTIME_TEST_HOST"] == "1",
               let raw = ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_CONVERT_PEEK_HOURS"], let hours = Double(raw) {
                // 夹具灌字会再触发一次「停 350 ms 再读」，读会清掉点出来的那一刻：等它读完再点。
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(700))
                    let base = current(resolved).flatMap { startDate($0.item) } ?? model.referenceDate
                    peek = base.addingTimeInterval(hours * 3600)
                }
            }
            #endif
        }
        .onChange(of: text) {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { origin = .typed }
            scheduleRead()
        }
        .onChange(of: sourceID) { read() }
        .onChange(of: model.displayOffset) { _, offset in
            // 用户在别处拖了时间（面板、地图）：「今天」跟过去，等拖停了再跟（拖的时候不逐帧重读）；自己刚跳的不算。
            guard offset != ownJumpOffset else { return }
            anchorTask?.cancel()
            anchorTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, model.displayOffset == offset else { return }
                anchorOffset = offset
            }
        }
        .onChange(of: model.systemRevision) { read() }
    }

    // MARK: - 读

    private func scheduleRead() {
        liveTask?.cancel()
        let snapshot = text
        liveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, text == snapshot else { return }
            read()
        }
    }

    private func read() {
        let snapshot = text
        output = TimeUnderstanding.read(snapshot, language: model.uiLocale.language.languageCode?.identifier)
        #if DEBUG
        // 夹具：用手写的引擎输出（JSON）代替这一回读到的，拍「几天一组」这类引擎还没给的样子（只在测试宿主生效）。
        if ProcessInfo.processInfo.environment["MEANTIME_TEST_HOST"] == "1",
           let json = ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_CONVERT_OUTPUT"], !json.isEmpty,
           let decoded = try? JSONDecoder().decode(TimeUnderstanding.Output.self, from: Data(json.utf8)) {
            output = decoded
        }
        #endif
        readText = snapshot
        readVersion += 1
        choices = [:]
        selected = nil
        seriesDay = 0
        candidate = 0
        copied = false
        peek = nil
    }

    // MARK: - 工具窗形态

    @ViewBuilder
    private func page(_ all: [TimeUnderstanding.Resolved], _ chosen: (row: ReadingRow, index: Int, item: TimeUnderstanding.Resolved)?) -> some View {
        let read = readText == text
        VStack(alignment: .leading, spacing: 0) {
            dateline
            editor
                .padding(.top, 8)
            // 读懂了就收起写法示例，让结果早一点出现；没读出东西时示例留着。
            if chosen == nil {
                // 读过了、一处都没读出来：说一声（灰字，不是错误：人可能还在打字）。
                if all.isEmpty, read, !readText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("没读出时间或地点。").appFont(.callout).foregroundStyle(.readableSecondary)
                        .padding(.top, 8)
                }
                examples.padding(.top, 8)
            }
            if let truncated = output.truncatedAt {
                note(String(format: L10n.string("只读了前 %lld 个字", locale: model.uiLocale), Int64(truncated)))
                    .padding(.top, 8)
            }
            if !all.isEmpty {
                understood(all, chosen: chosen)
                    .padding(.top, 16)
            }
            // 同一行里几个时区写同一刻，核对差出来的（多半有一处没按夏令时改）；还在打字时不算。
            if read {
                ForEach(UnderstandingText.crosscheckNotes(TimeUnderstanding.crosscheck(all), all, style: style, pasted: origin == .pasted),
                        id: \.self) { line in note(line).padding(.top, 6) }
            }
            if let chosen, let start = startDate(chosen.item) {
                let end = peek == nil ? endDate(chosen.item) : nil
                let zones = Self.resultZones(target: chosen.item.target, source: chosen.item.zone, local: .autoupdatingCurrent,
                                             saved: model.zones.map(\.timeZone))
                #if DEBUG
                let _ = PerformanceProbe.recordConversion(places: zones.count)
                #endif
                MomentTable(places: zones.map { place($0, item: chosen.item, at: start) }, start: start, end: endDate(chosen.item),
                            dayReference: chosen.item.zone, peek: $peek)
                    .padding(.top, 24)
                actions(zones: zones, item: chosen.item, start: peek ?? start, end: end, source: chosen.item.zone)
                    .padding(.top, 12)
                footnotes(zones: zones, at: peek ?? start)
            } else if all.isEmpty, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !model.zones.isEmpty {
                // 空着时：表上是各地此刻（看的那一刻）。点时间轴一样能看别的时刻，按「在面板里看这一刻」把整个 App 带过去。
                let now = model.referenceDate
                let zones = Self.resultZones(source: nil, local: .autoupdatingCurrent, saved: model.zones.map(\.timeZone))
                MomentTable(places: zones.map { place($0, item: nil, at: now) }, start: now, end: nil, dayReference: .current, peek: $peek)
                    .padding(.top, 10)
                actions(zones: zones, item: nil, start: peek ?? now, end: nil, source: .current)
                    .padding(.top, 12)
                footnotes(zones: zones, at: peek ?? now)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: selected) { peek = nil; copied = false }
        .onChange(of: seriesDay) { peek = nil; copied = false }
        .onChange(of: peek) { copied = false }
    }

    /// 落款：这段话没写地点、没写日期时按哪里、哪一天读。地点用面板行的衬线字，点开是本机与保存的地点；
    /// 日期点开是系统日历，换一天就是把整个 App 看的那一刻挪到那一天（钟点不变），与「太阳与月亮」的日期同一个做法。
    /// 行尾「粘贴并换算」；一行放不下时它挪到下一行。
    private var dateline: some View {
        TrailingWrapLayout(spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                sourceMenu
                Text(verbatim: "·").foregroundStyle(.readableSecondary).accessibilityHidden(true)
                dayChip
            }
            pasteButton
        }
    }

    private var sourceName: String {
        guard let sourceEntry else {
            return String(format: L10n.string("本机（%@）", locale: model.uiLocale), model.core.placeName(forTimeZoneID: TimeZone.current.identifier))
        }
        return sourceEntry.displayName(localizedCity: model.cityName(for: sourceEntry))
    }

    /// 来源地点：衬线地名加一个小箭头，点开是本机与保存的地点，选中的那一个前面一个勾。
    /// 标签由 SwiftUI 自己画（`.plain`），整块是一个读屏元素、命中区 24 点高：系统的菜单按钮按字号定高，拉丁字母的衬线字只有 18 点（ru 转储 R3）；
    /// 菜单里是一列按钮，不嵌 `Picker`：嵌进去的那一种在内存巡回里这一页多约 0.5 MiB（实测，三次对照）。字号同各页的主语行（17 点衬线中等）。
    private var sourceMenu: some View {
        let size = (AppFont.size(.title2) * textScale).rounded()
        let name = sourceName
        let local = String(format: L10n.string("本机（%@）", locale: model.uiLocale), model.core.placeName(forTimeZoneID: TimeZone.current.identifier))
        let options = [("local", local)] + model.zones.map { ($0.id.uuidString, $0.displayName(localizedCity: model.cityName(for: $0))) }
        return Menu {
            ForEach(options, id: \.0) { id, title in
                Button { sourceID = id } label: {
                    if id == sourceID { Label(title, systemImage: "checkmark") } else { Text(verbatim: title) }
                }
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(verbatim: name).font(SerifFace.font(name, size: size, weight: .medium, locale: model.uiLocale))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.readableSecondary)
            }
            .frame(minHeight: 24)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("来源地点"))
            .accessibilityValue(Text(verbatim: name))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text(verbatim: [L10n.string("话里没写地点的时间按这里算", locale: model.uiLocale),
                              model.core.zoneCaption(for: source, entry: sourceEntry, at: reference)].joined(separator: " · ")))
    }

    /// 来源日期：话里没写日期的按这一天（来源地点的当地日期，与面板日期片同一写法）。
    private var dayChip: some View {
        let label = ClockText.day(reference, in: source, locale: model.uiLocale, now: model.now, weekday: true)
        return Button { showingCalendar = true } label: {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(verbatim: label).appFont(.title3)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.readableSecondary)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(Text("话里没写日期的时间按这一天算"))
        .accessibilityLabel(Text("来源日期"))
        .accessibilityValue(Text(verbatim: label))
        .popover(isPresented: $showingCalendar, arrowEdge: .bottom) {
            DatePicker("来源日期", selection: Binding(get: { reference }, set: { moveAnchor(toDayOf: $0) }),
                       in: Self.supportedDays, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .padding()
                .environment(\.timeZone, source)
                .environment(\.locale, model.uiLocale)
        }
    }

    /// 能选的日子：与「太阳与月亮」同一个范围（1800–2100 年，两头各让一天）。
    private static let supportedDays = Date(timeIntervalSince1970: -5_364_576_000)...Date(timeIntervalSince1970: 4_133_894_400)

    /// 换一天：整个 App 看的那一刻挪过去（来源地点的钟点不变），「今天」的锚立刻跟上。
    private func moveAnchor(toDayOf picked: Date) {
        let calendar = Calendar.gregorianUTC(source)
        let from = calendar.dateComponents([.year, .month, .day], from: reference)
        let to = calendar.dateComponents([.year, .month, .day], from: picked)
        guard let a = calendar.date(from: from), let b = calendar.date(from: to),
              let days = calendar.dateComponents([.day], from: a, to: b).day, days != 0,
              let target = calendar.date(byAdding: .day, value: days, to: reference) else { return }
        model.jump(to: target)
        anchorTask?.cancel()
        anchorOffset = model.displayOffset
        ownJumpOffset = nil
    }

    private var editor: some View {
        UnderstandingEditor(text: $text, marks: marks(resolved, selected: current(resolved)?.row), placeholder: L10n.string("要换算的时间", locale: model.uiLocale),
                            accessibilityLabel: L10n.string("要换算的时间", locale: model.uiLocale),
                            onCaret: { caret in selectMention(at: caret) },
                            onPaste: { origin = .pasted },
                            onCommit: { commit() },
                            onHeight: { editorHeight = $0 },
                            focusOnAppear: true)
            .frame(height: editorHeight)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text("要换算的时间").foregroundStyle(.readableSecondary)
                        .padding(.leading, 9).padding(.top, 6).allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
    }

    /// 写法示例：每一条都能点，点了就填进框里读。一行放不下就折行。完整写法放悬停提示。
    private var examples: some View {
        let samples = Self.exampleKeys.map { L10n.string($0, locale: model.uiLocale) }
        return ChipFlowLayout(spacing: 6, lineSpacing: 6) {
            Text("例如").appFont(.callout).foregroundStyle(.readableSecondary)
            ForEach(samples, id: \.self) { sample in
                Button {
                    origin = .typed
                    text = sample
                    liveTask?.cancel()
                    read()
                } label: { Text(verbatim: sample).appFont(.callout) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(Text("填进框里读一遍"))
                .accessibilityHint(Text("填进框里读一遍"))
            }
        }
    }

    /// 四条示例（各语言各有自己的写法，十六语都在字符串目录里，`LanguageReadingTests` 逐语核过读得懂）。
    static let exampleKeys = ["14:00", "明天 9:00 东京", "后天下午三点 伦敦", "三小时后 纽约"]

    /// 「读到的时间」：每行一处（几天一组的并成一行）；能换算的有两行以上时是单选（只有一行时不画单选圈）；没写钟点的灰、不能选；
    /// 读不成的写出哪一段不对（红只上图标）。候选菜单与提醒贴在选中那一行下面（离开那一行放在列表下面，看不出是在说哪一处）。
    private func understood(_ all: [TimeUnderstanding.Resolved], chosen: (row: ReadingRow, index: Int, item: TimeUnderstanding.Resolved)?) -> some View {
        let rows = rows
        let readable = { (row: ReadingRow) in row.indices.contains { all.indices.contains($0) && all[$0].problem == nil } }
        let choosable = rows.filter(readable).count > 1
        return VStack(alignment: .leading, spacing: 2) {
            Text("读到的时间").appFont(.caption).foregroundStyle(.readableSecondary)
                .accessibilityAddTraits(.isHeader)
            ForEach(rows) { row in
                let items = row.indices.filter { all.indices.contains($0) }.map { all[$0] }
                let isChosen = chosen?.row.first == row.first
                let ok = readable(row)
                let first = items.first
                let line = items.count > 1 ? UnderstandingText.seriesSummary(items, in: readText, style: style, pasted: origin == .pasted)
                                           : first.map { UnderstandingText.summary($0, in: readText, style: style, pasted: origin == .pasted) } ?? ""
                let spoken = items.count > 1 ? UnderstandingText.accessibleSeriesSummary(items, in: readText, style: style, pasted: origin == .pasted)
                                             : first.map { UnderstandingText.accessibleSummary($0, in: readText, style: style, pasted: origin == .pasted) } ?? ""
                let failed = !ok && first?.problem != .dateOnly
                let rowView = HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if failed {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.red).frame(width: 16)
                    } else if !ok {
                        Image(systemName: "calendar").foregroundStyle(.readableSecondary).frame(width: 16)
                    } else if choosable {
                        Image(systemName: isChosen ? "largecircle.fill.circle" : "circle").foregroundStyle(.readableSecondary).frame(width: 16)
                    }
                    Text(verbatim: line)
                        .foregroundStyle(ok || failed ? AnyShapeStyle(.primary) : AnyShapeStyle(.readableSecondary))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 3)
                .frame(minHeight: 22)
                .help(Text(verbatim: UnderstandingText.snippet(row.span(all: output.mentions), in: readText)))
                if ok {
                    // 能换算的一行：点它只选中（下面换成它的候选与各地时间），跳要另按「在面板里看这一刻」。
                    Button {
                        selected = row.first
                        seriesDay = 0
                        candidate = 0
                    } label: { rowView.contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: spoken))
                    .accessibilityAddTraits(isChosen ? .isSelected : [])
                } else {
                    // 没写钟点的、读不成的：只是说出来，不能点（不用置灰的按钮：错误句要读得清）。
                    rowView.accessibilityElement(children: .combine)
                        .accessibilityLabel(Text(verbatim: spoken))
                }
                // 几天一组里有读不成的那几天：各写一句（红只上图标），读成了的几天照常换算。
                if items.count > 1, ok {
                    ForEach(Array(items.enumerated()).filter { $0.element.problem != nil && $0.element.problem != .dateOnly }, id: \.offset) { _, item in
                        if let problem = UnderstandingText.problem(item, in: readText, style: style) {
                            ErrorLine(Text(verbatim: problem)).appFont(.callout)
                                .padding(.leading, choosable ? 22 : 0)
                        }
                    }
                }
                if let first, let line = UnderstandingText.sentenceNote(first, style: style) {
                    note(line).accessibilityHidden(true)
                        .padding(.leading, choosable ? 22 : 0)
                }
                if let chosen, isChosen {
                    VStack(alignment: .leading, spacing: 6) { candidates(chosen, all: all) }
                        .padding(.leading, choosable ? 22 : 0)
                        .padding(.vertical, 4)
                }
            }
        }
    }

    /// 选中那一行的候选菜单与提醒行：几天一组时先挑看哪一天，再是按哪种理解、日期与钟点、夏令时重复的那一小时。
    @ViewBuilder
    private func candidates(_ chosen: (row: ReadingRow, index: Int, item: TimeUnderstanding.Resolved), all: [TimeUnderstanding.Resolved]) -> some View {
        let item = chosen.item
        let at = startDate(item) ?? reference
        let days = chosen.row.indices.filter { all.indices.contains($0) && all[$0].problem == nil }
        if days.count > 1 {
            Picker("哪一天", selection: $seriesDay) {
                ForEach(Array(days.enumerated()), id: \.offset) { offset, index in
                    Text(verbatim: UnderstandingText.dayLabel(all[index], style: style) ?? "").tag(offset)
                }
            }
            .fixedSize()
        }
        if item.zoneOptions.count > 1 {
            Picker("按哪种理解", selection: Binding(
                get: { item.zoneOption.id },
                set: { id in
                    // 几天一组共用一个写法：一起改。
                    for index in chosen.row.indices { choices[index, default: .init()].zone = id }
                    if let written = UnderstandingText.zoneText(item.mention, in: readText)?.lowercased() { hub?.zoneChoiceMemory[written] = id }
                    candidate = 0
                })) {
                ForEach(item.zoneOptions) { option in
                    Text(verbatim: UnderstandingText.zoneLabel(option, among: item.zoneOptions, at: at, style: style, pasted: origin == .pasted,
                                                               written: UnderstandingText.zoneText(item.mention, in: readText)))
                        .tag(option.id)
                }
            }
            .fixedSize()
        }
        if item.readings.count > 1 {
            Picker(item.zoneOptions.count > 1 ? "日期与钟点" : "按哪种理解", selection: Binding(
                get: { item.reading.id },
                set: { id in choices[chosen.index, default: .init()].reading = id; candidate = 0 })) {
                ForEach(item.readings) { reading in
                    Text(verbatim: UnderstandingText.readingLabel(reading, of: item, style: style)).tag(reading.id)
                }
            }
            .fixedSize()
        }
        if item.intervals.count > 1 {
            // 夏令时结束那天这个钟点走两遍：按人读的写法（钟点 + 缩写）标第一次 / 第二次，ISO 串进悬停提示。
            Text("夏令时结束时，这个时刻出现两次。请选择：").appFont(.callout)
            HStack {
                ForEach(Array(item.intervals.enumerated()), id: \.offset) { index, interval in
                    let abbreviation = UnderstandingText.abbreviation(item.zoneOption, at: interval.start,
                        offsetOnly: !item.zoneWritten && (sourceEntry?.offsetOnlyZoneName ?? false))
                    let clock = TimeFormatting.string(for: interval.start, in: item.zone,
                                                      format: ClockFormat(hourStyle: model.settings.hourStyle, showSeconds: false))
                    Button {
                        candidate = index
                        peek = nil
                    } label: {
                        Label { Text("\(clock) \(abbreviation)（\(index == 0 ? Text("第一次") : Text("第二次"))）").monospacedDigit() }
                            icon: { Image(systemName: candidate == index ? "largecircle.fill.circle" : "circle") }
                    }
                    .help(Text(verbatim: TimeInput.timestamps(for: interval.start, in: item.zone)?.iso8601 ?? ""))
                }
            }
        }
        ForEach(UnderstandingText.notes(item, in: readText, style: style), id: \.self) { line in note(line) }
    }

    /// 「已处理、只是告诉你」的提醒：灰三角，一句话。
    private func note(_ line: String) -> some View {
        Label { Text(verbatim: line) } icon: { Image(systemName: "exclamationmark.triangle") }
            .appFont(.caption).foregroundStyle(.readableSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - 共同时间轴下面：拷贝、回到原来的时刻、在面板里看这一刻

    /// 一种拷贝（此前有三套：每行一个按钮、右键菜单、「复制成一行」）：按一下拷贝「各地时间一行」（最常要的：贴进聊天回人）；旁边「其他写法」里是其余几种，
    /// 都按表上正在显示的那一刻：ISO 8601（每个地方的偏移各一条，外加 UTC）、Unix、Discord 两种、Slack。
    /// 点过时间轴上别处时多一个「回到原来的时刻」；「在面板里看这一刻」把整个 App 带到表上正在显示的那一刻（⌘↩）。
    @ViewBuilder
    private func actions(zones: [TimeZone], item: TimeUnderstanding.Resolved?, start: Date, end: Date?, source: TimeZone) -> some View {
        let named = zones.map { (name: rowName($0, source: item, at: start), zone: $0) }
        TrailingWrapLayout(spacing: 8) {
            HStack(spacing: 12) {
                copyMenu(named: named, start: start, end: end, source: source)
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
            jumpButton
        }
    }

    private func copyMenu(named: [(name: String, zone: TimeZone)], start: Date, end: Date?, source: TimeZone) -> some View {
        // 一个按钮加一个写着「其他写法」的菜单：按钮拷贝一行；菜单里是其余几种。菜单项只写名字与偏移，
        // 时间戳在点的时候才去 Rust 算（不在每次重画页面时为六七个写法各跑一次）。
        // 不用 `Menu(primaryAction:)`（箭头那一段读屏没有名字，实测转储 R1），也不用 `ControlGroup`（冷启动这一页多约 1.4 MiB，实测）。
        HStack(spacing: 10) {
            Button {
                copyLine(named: named, start: start, end: end, source: source)
            } label: {
                Text(copied ? LocalizedStringKey("已复制") : LocalizedStringKey("复制全部各地时间"))
            }
            .fixedSize()
            .help(Text("各地时间连成一行，能直接贴进聊天。"))
            Menu {
                Menu("复制 ISO 8601") {
                    ForEach(Array(named.enumerated()), id: \.offset) { _, entry in
                        Button { copyStamp(\.iso8601, at: start, in: entry.zone) } label: {
                            Text(verbatim: String(format: L10n.string("%1$@（%2$@）", locale: model.uiLocale), entry.name,
                                                  UnderstandingText.offset(entry.zone.secondsFromGMT(for: start))))
                        }
                    }
                    Divider()
                    Button { copyStamp(\.iso8601, at: start, in: TimeZone(identifier: "UTC") ?? .gmt) } label: { Text(verbatim: "UTC") }
                }
                Button("复制 Unix 时间戳") { copyStamp(\.unix, at: start, in: source) }
                Divider()
                Button("复制 Discord 时间戳") { copyStamp(\.discord, at: start, in: source) }
                Button("复制 Discord 相对时间") { copyStamp(\.discordRelative, at: start, in: source) }
                Button("复制 Slack 日期令牌") { copyStamp(\.slack, at: start, in: source) }
            } label: {
                // 标签由 SwiftUI 自己画（`.plain`）：上下留白让命中区过 20 点；有边框的下拉冷启动这一页多约 0.7 MiB，
                // 无边框的系统下拉只有 16 点高（都是实测）。
                HStack(spacing: 4) {
                    Text("其他写法")
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.readableSecondary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 4)
                .frame(minHeight: 24)
                .contentShape(Rectangle())
                .accessibilityElement(children: .ignore)
                .modifier(MenuAccessibleTitle(title: Text("其他写法")))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    /// 点了菜单项才算那一种写法（Rust `converter.timestamps`）。
    private func copyStamp(_ field: KeyPath<TimeInput.Timestamps, String>, at date: Date, in zone: TimeZone) {
        if let stamp = TimeInput.timestamps(for: date, in: zone) { copy(stamp[keyPath: field]) }
    }

    /// 「东京 9月17日 3:00 / 洛杉矶 11:00 / 伦敦 19:00」。
    private func copyLine(named: [(name: String, zone: TimeZone)], start: Date, end: Date?, source: TimeZone) {
        copy(TimeInput.pasteLine(start: start, end: end, zones: named, source: source,
                                 hourStyle: model.settings.hourStyle, locale: model.uiLocale, now: model.now))
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copied = true
        AccessibilityNotification.Announcement(L10n.string("已复制", locale: model.uiLocale)).post()
    }

    @ViewBuilder
    private func footnotes(zones: [TimeZone], at date: Date) -> some View {
        // 真太阳时的年份（1947 年前的利雅得这类）：ISO 串的偏移带秒，已四舍五入到分钟（调研 #35）。
        // 偏移带秒就是真太阳时（Rust `converter.timestamps` 的 offsetRounded 同一个判据），不必为每个地方各跑一次 Rust。
        if zones.contains(where: { $0.secondsFromGMT(for: date) % 60 != 0 }) {
            Text("这几个地点在这个日期用的是真太阳时，偏移带秒；复制的 ISO 8601 已四舍五入到整分钟。")
                .appFont(.caption).foregroundStyle(.readableSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
        }
    }

    // MARK: - 结果（选中的那一处，按各地列出来）

    private func startDate(_ item: TimeUnderstanding.Resolved) -> Date? {
        item.intervals.indices.contains(candidate) ? item.intervals[candidate].start : item.start
    }

    private func endDate(_ item: TimeUnderstanding.Resolved) -> Date? {
        item.intervals.indices.contains(candidate) ? item.intervals[candidate].end : item.end
    }

    /// 结果列出的时区：目标 → 来源 → 本机 → 已保存地点，按顺序去重；首启没有保存地点时仍能读懂结果。
    static func resultZones(target: TimeZone? = nil, source: TimeZone?, local: TimeZone, saved: [TimeZone]) -> [TimeZone] {
        var seen = Set<String>()
        var rows: [TimeZone] = []
        for zone in [target, source, local].compactMap({ $0 }) + saved where seen.insert(zone.identifier).inserted {
            rows.append(zone)
        }
        return rows
    }

    /// 本机那一行只在它不是已保存地点时才标「本机」（已保存的按用户起的名字显示）。
    private func isUnsavedLocal(_ zone: TimeZone) -> Bool {
        zone.identifier == TimeZone.autoupdatingCurrent.identifier && !model.zones.contains { $0.timezoneID == zone.identifier }
    }

    private func rowName(_ zone: TimeZone, source item: TimeUnderstanding.Resolved? = nil, at date: Date = .now) -> String {
        // 来源那一行：写的是城市就写那座城，写的是固定偏移就写「UTC+5:30」（此前写成「未知地点」）。
        if let item, zone.identifier == item.zone.identifier, item.zoneWritten, item.zoneOption.city != nil || zone.identifier.hasPrefix("GMT") {
            return UnderstandingText.zoneName(item.zoneOption, at: date, style: style, pasted: origin == .pasted)
        }
        if zone.identifier.hasPrefix("GMT") { return UnderstandingText.offset(zone.secondsFromGMT(for: date)) }
        return isUnsavedLocal(zone)
            ? String(format: L10n.string("本机（%@）", locale: model.uiLocale), model.core.placeName(forTimeZoneID: zone.identifier))
            : model.core.placeName(forTimeZoneID: zone.identifier)
    }

    /// 表里的一行：名字、地名下面那行小字的标记（「原文」：话里写的就是这个地方；「本机」：这台 Mac，名字里没写过时）、坐标。
    private func place(_ zone: TimeZone, item: TimeUnderstanding.Resolved?, at date: Date) -> MomentTable.Place {
        var tags: [String] = []
        if let item, zone.identifier == item.zone.identifier, item.zoneWritten { tags.append(L10n.string("原文", locale: model.uiLocale)) }
        if zone.identifier == TimeZone.autoupdatingCurrent.identifier, !isUnsavedLocal(zone) { tags.append(L10n.string("本机", locale: model.uiLocale)) }
        return MomentTable.Place(zone: zone, name: rowName(zone, source: item, at: date), tags: tags, coordinate: coordinate(for: zone))
    }

    /// 该时区的经纬度：已保存的地点用它自己存下的坐标；没保存的问系统时区目录（只查随包 tzcoords，不碰城市索引）。
    private func coordinate(for zone: TimeZone) -> Coordinate? {
        if let saved = model.zones.first(where: { $0.timeZone.identifier == zone.identifier }) { return saved.coordinate }
        return ZoneCatalog.shared.option(for: zone.identifier)?.coordinate
    }

    /// 该地的日历日期是否与来源地点不同（比较年月日，各按自己的时区）。
    nonisolated static func isDifferentDay(_ date: Date, in zone: TimeZone, from source: TimeZone) -> Bool {
        let components: Set<Calendar.Component> = [.year, .month, .day]
        return Calendar.gregorianUTC(zone).dateComponents(components, from: date)
            != Calendar.gregorianUTC(source).dateComponents(components, from: date)
    }

    // MARK: - 跳与选

    /// 让整个 App 跳到选中的那一处（按的是表上正在显示的那一刻，点过时间轴就是点的那一刻），并把面板亮出来。
    /// 快捷键 ⌘↩（↩ 在多行框里是换行）。
    private var jumpButton: some View {
        Button("在面板里看这一刻") { commit() }
            .fixedSize()
            .disabled(!canJump)
            .help(Text(verbatim: L10n.string("面板上各地的时间都跳到这一刻", locale: model.uiLocale) + "  ⌘↩"))
            .accessibilityHint(Text("面板上各地的时间都跳到这一刻"))
            .keyboardShortcut(.return, modifiers: .command)
    }

    /// 还有没读的字（停下不到 350 ms）时按了也行：先读再跳；读过了就看选中的那一处落不落得成一个时刻；
    /// 空着时只有点过时间轴才有别的时刻可去。
    private var canJump: Bool {
        if readText != text { return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return peek != nil }
        return current(resolved).flatMap { startDate($0.item) } != nil
    }

    private var pasteButton: some View {
        // 只在点击时读剪贴板；打开页面不读，免得触发系统的剪贴板提示。
        Button("粘贴并换算") {
            let pasted = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !pasted.isEmpty else { return }
            origin = .pasted
            text = pasted
            // 只读、不跳：有几种读法的（CST、10/3）先在这里看清选好，再按「在面板里看这一刻」。
            liveTask?.cancel()
            read()
        }
        .fixedSize()
    }

    /// 「在面板里看这一刻」与 ⌘↩ / ↩：字还没读就先读（读会清掉选中，读过了就不再读，免得选了第二处却跳到第一处）。
    private func commit() {
        if readText != text { read() }
        if let peek {
            jump(to: peek)
        } else if let chosen = current(resolved), let start = startDate(chosen.item) {
            jump(to: start)
        }
    }

    /// 让整个 App 跳到这一刻（面板、地图、昼夜条一起动）。面板没开就替用户点一下菜单栏项把它亮出来
    /// （按钮说的就是「在面板里看」），开着就不点（点了反而关上）。
    private func jump(to start: Date) {
        model.jump(to: start)
        ownJumpOffset = model.displayOffset
        anchorTask?.cancel()
        // 空着时表上就是看的那一刻：跳过去以后点出来的那一刻与它重合，不再留「回到原来的时刻」。
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { peek = nil }
        if !model.isPanelVisible {
            // 等这次按键 / 点按处理完再点：在处理当中点菜单栏项，面板不出来（进程内实测）。
            Task { @MainActor in _ = MenuBarPanel.toggle() }
        }
    }

    /// 光标落在哪一处的字上，就选中那一处所在的那一行（只选、不跳）。
    private func selectMention(at caret: Int) {
        guard readText == text,
              let index = output.mentions.firstIndex(where: { $0.span.count == 2 && $0.span[0] <= caret && caret <= $0.span[1] }),
              let row = rows.first(where: { $0.indices.contains(index) }),
              row.first != selected else { return }
        selected = row.first
        seriesDay = 0
        candidate = 0
    }

    /// 原文上的标记：每处读懂的几段划线，选中那一行线粗一点；不成立的段红点线，没认出的地名橙点线。
    /// 同一处里只隔着空格或「at / um / 的」这类短词的几段并成一道线（「tomorrow 9am PST」是一处，不是三截）。
    private func marks(_ all: [TimeUnderstanding.Resolved], selected row: ReadingRow?) -> [UnderstandingEditor.Mark] {
        guard readText == text else { return [] }
        var marks: [UnderstandingEditor.Mark] = []
        for (index, mention) in output.mentions.enumerated() {
            let kind: UnderstandingEditor.Mark.Kind = row?.indices.contains(index) == true ? .selected : .understood
            let spans = mention.parts.map(\.span).filter { $0.count == 2 && $0[0] < $0[1] }.sorted { $0[0] < $1[0] }
            var merged: [[Int]] = []
            for span in spans {
                if let last = merged.last, span[0] >= last[1], span[0] - last[1] <= 4 {
                    merged[merged.count - 1][1] = max(last[1], span[1])
                } else if let last = merged.last, span[0] < last[1] {
                    merged[merged.count - 1][1] = max(last[1], span[1])
                } else {
                    merged.append(span)
                }
            }
            for span in merged {
                marks.append(.init(range: NSRange(location: span[0], length: span[1] - span[0]), kind: kind))
            }
            for issue in mention.issues where issue.span.count == 2 {
                marks.append(.init(range: NSRange(location: issue.span[0], length: issue.span[1] - issue.span[0]), kind: .problem))
            }
            for unknown in mention.unresolved where unknown.span.count == 2 {
                marks.append(.init(range: NSRange(location: unknown.span[0], length: unknown.span[1] - unknown.span[0]), kind: .unresolved))
            }
        }
        // 几天一组的几处原文范围相同、钟点那几段也相同：同一段只画一次。
        var seen = Set<String>()
        return marks.filter { seen.insert("\($0.range.location):\($0.range.length):\($0.kind)").inserted }
    }
}

/// 「读到的时间」的一行：一处，或几天共用一个钟点的一组（引擎每天给一处，带同一个 `series` 号、相邻）。
struct ReadingRow: Identifiable, Equatable {
    /// 行里第一处在 `mentions` 里的下标（也是这一行的身份与选中时记的值）。
    let first: Int
    let indices: [Int]
    var id: Int { first }

    /// 相邻、`series` 相同的几处并成一行；没有 `series` 的一处一行。
    static func group(_ mentions: [TimeUnderstanding.Mention]) -> [ReadingRow] {
        var rows: [ReadingRow] = []
        var index = 0
        while index < mentions.count {
            var end = index + 1
            if let series = mentions[index].series {
                while end < mentions.count, mentions[end].series == series { end += 1 }
            }
            rows.append(ReadingRow(first: index, indices: Array(index..<end)))
            index = end
        }
        return rows
    }

    /// 这一行在原文里的范围（几天一组时是它们的并）。
    func span(all mentions: [TimeUnderstanding.Mention]) -> [Int] {
        let spans = indices.compactMap { mentions.indices.contains($0) ? mentions[$0].span : nil }.filter { $0.count == 2 }
        guard let low = spans.map({ $0[0] }).min(), let high = spans.map({ $0[1] }).max() else { return [] }
        return [low, high]
    }
}

/// 落成结果的记忆：同一回读、同一个锚、同一分钟、同样的选择，直接拿上一次的（点时间轴、拷贝都不再重算）。
@MainActor
final class ResolvedMemo {
    struct Key: Equatable {
        let version: Int
        let reference: Double
        let minute: Int
        let source: String
        let pasted: Bool
        let preferred: [String]
        let choices: [Int: TimeUnderstanding.Choice]
    }
    private var key: Key?
    private var value: [TimeUnderstanding.Resolved] = []

    func value(for next: Key, compute: () -> [TimeUnderstanding.Resolved]) -> [TimeUnderstanding.Resolved] {
        if next == key { return value }
        key = next
        value = compute()
        return value
    }
}

/// 一行里几样东西：放得下时最后一样靠右、其余靠左；放不下时最后一样折到下一行靠左。
/// 落款那一行（来源地点 · 日期 …… 粘贴并换算）与时间轴下面那一行（拷贝 …… 在面板里看这一刻）用它，不在两种整行写法之间挑。
struct TrailingWrapLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let total = sizes.map(\.width).reduce(0, +) + spacing * CGFloat(max(0, sizes.count - 1))
        if total <= width || sizes.count < 2 {
            return CGSize(width: proposal.width ?? total, height: sizes.map(\.height).max() ?? 0)
        }
        let head = sizes.dropLast()
        let first = head.map(\.height).max() ?? 0
        // 折行后按行宽重测，行高容下完整文字。
        let last = subviews.last?.sizeThatFits(ProposedViewSize(width: width, height: nil)) ?? .zero
        return CGSize(width: proposal.width ?? total, height: first + spacing + last.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let total = sizes.map(\.width).reduce(0, +) + spacing * CGFloat(max(0, sizes.count - 1))
        let fits = total <= bounds.width || sizes.count < 2
        let rowHeight = fits ? (sizes.map(\.height).max() ?? 0) : (sizes.dropLast().map(\.height).max() ?? 0)
        var x = bounds.minX
        for (index, subview) in subviews.enumerated() {
            let size = sizes[index]
            if index == subviews.count - 1, sizes.count > 1 {
                if fits {
                    subview.place(at: CGPoint(x: bounds.maxX - size.width, y: bounds.minY + (rowHeight - size.height) / 2), proposal: .unspecified)
                } else {
                    subview.place(at: CGPoint(x: bounds.minX, y: bounds.minY + rowHeight + spacing),
                                  proposal: ProposedViewSize(width: bounds.width, height: nil))
                }
            } else {
                subview.place(at: CGPoint(x: x, y: bounds.minY + (rowHeight - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
        }
    }
}

/// 一串小块依次排、一行放不下就折行（写法示例的那几个按钮）。各块按自己的理想宽，竖向按一行里最高的那块居中。
struct ChipFlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    private func lines(width: CGFloat, sizes: [CGSize]) -> [[Int]] {
        var lines: [[Int]] = [[]]
        var x: CGFloat = 0
        for (index, size) in sizes.enumerated() {
            if !lines[lines.count - 1].isEmpty, x + spacing + size.width > width {
                lines.append([])
                x = 0
            }
            x += (lines[lines.count - 1].isEmpty ? 0 : spacing) + size.width
            lines[lines.count - 1].append(index)
        }
        return lines
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let width = proposal.width ?? sizes.map(\.width).reduce(0, +)
        let rows = lines(width: width, sizes: sizes)
        let height = rows.map { row in row.map { sizes[$0].height }.max() ?? 0 }.reduce(0, +) + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        var y = bounds.minY
        for row in lines(width: bounds.width, sizes: sizes) {
            let height = row.map { sizes[$0].height }.max() ?? 0
            var x = bounds.minX
            for index in row {
                subviews[index].place(at: CGPoint(x: x, y: y + (height - sizes[index].height) / 2), proposal: .unspecified)
                x += sizes[index].width + spacing
            }
            y += height + lineSpacing
        }
    }
}
