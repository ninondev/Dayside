// SPDX-License-Identifier: GPL-3.0-only
//
//  TimeZoneRowView.swift
//  TahoeTime
//
//  列表里的一行。系统文本样式 + 语义色;时间用等宽数字。外观定制(字体设计/颜色/顺序/对齐)
//  都是可选层,**默认值 = 现有布局/样式**。副标题与昼夜带保持语义色不动。
//

import SwiftUI
import AppKit

struct TimeZoneRowView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.featureHub) private var featureHub
    @Environment(\.openWindow) private var openWindow
    @Environment(\.panelSky) private var panelSky
    @Environment(\.panelFollowsSky) private var followsSky
    @Environment(\.textScale) private var textScale
    @State private var measuredHeight: CGFloat = 0
    let zone: TimeZoneEntry
    /// 指针停在这一行上或键盘选中了它：左边一道竖线（行的字色），地图上写出它的名字。
    var highlighted = false
    var compactOffsets = false
    var availableWidth: CGFloat = 320
    var onRename: () -> Void

    var body: some View {
        @Bindable var model = model
        let settings = model.settings
        let localizedCity = model.localizedCity(zone)   // 城市语言=无 时为空
        let sky = panelSky?.rows[zone.id]
        let metrics = SkyRowMetrics(settings: settings, textScale: textScale)
        // 行是这个地方此刻的天。框跟着天色时字用墨或纸（对比度由 Rust 实算）；
        // 跟着系统时字是系统色，天色缩成左边一条色带。
        let ink: Color? = followsSky ? sky.map { SkyTextRole.panelName.foreground(in: $0.colors) } : nil
        HStack(alignment: .center, spacing: 10) {
            if !followsSky, let sky {
                // 跟着系统时天色缩成一条色带；正午的天几乎是纸色，白底上要一道细边才看得见。
                // 反色开着时这条色带（连同细边）预反一次；框跟着天色时没有这条带，由面板整块反。
                SkyRowBackground(row: sky)
                    .frame(width: 4)
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(SkyRowForegroundStyle(row: sky), lineWidth: 0.5))
                    .modifier(SkyPreInvert())
                    .padding(.vertical, 12)
                    .accessibilityHidden(true)
            }
            // 复制时间戳只在右键菜单与无障碍动作里提供；每行常驻一个图标是视觉噪音。
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 10) {
                    rowContent(settings: settings, localizedCity: localizedCity, sky: sky, metrics: metrics, ink: ink)
                }
                if settings.panelShowsSunTimes, let sky {
                    ClockDrivenRowSunTimes(zone: zone, sky: sky, metrics: metrics,
                                          clockFormat: settings.clockFormat, followsSky: followsSky,
                                          rowHeight: max(metrics.rowHeight, measuredHeight))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: metrics.rowHeight, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .coordinateSpace(name: zone.id)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { measuredHeight = $0 }
        .modifier(RowInk(ink: ink))
        .overlay(alignment: .leading) {
            if highlighted {
                Rectangle().fill(ink ?? Color.accentColor).frame(width: 3).accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        // 读屏顺序始终从地点开始，不跟视觉上的时间优先顺序走。
        .modifier(RowAccessibility(zone: zone, localizedCity: localizedCity, sky: sky))
        // 行里不再有按钮后,合并元素没有角色(VoiceOver 念「未知」);这行是内容,按静态文本报角色。
        .accessibilityAddTraits(.isStaticText)
        // 读屏动作是一列平的（没有子菜单），改名与删除排在最前：多数人对一行要做的就是这两样。
        .accessibilityActions {
            Button("重命名…") { onRename() }
            Button("删除") { model.removeZone(id: zone.id) }
            Button("复制全部各地时间") { model.copyAllPlaceTimes() }
            copyActions
        }
        // 右键菜单（`PlaceRowMenu`）：第一层最多 8 项，改名与删除不用滚就看得见。
        .contextMenu {
            PlaceRowMenu(model: model, hub: featureHub, zone: zone, onRename: onRename, open: open)
        }
    }

    private func open(_ page: FeatureSelection, prepare: (FeatureHub) -> Void) {
        guard let hub = featureHub else { return }
        prepare(hub)
        hub.selection = page
        openWindow(id: "tools")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// 读屏动作里的四种时间戳（一列平的，每项带动词）。
    @ViewBuilder
    private var copyActions: some View {
        Button { PlaceRowMenu.copy(\.iso8601, model: model, zone: zone) } label: {
            Text(verbatim: L10n.string("复制 ISO 8601", locale: model.uiLocale))
        }
        Button { PlaceRowMenu.copy(\.unix, model: model, zone: zone) } label: {
            Text(verbatim: L10n.string("复制 Unix 时间戳", locale: model.uiLocale))
        }
        // Discord / Slack 令牌：收方按各自时区显示。
        Button { PlaceRowMenu.copy(\.discord, model: model, zone: zone) } label: {
            Text(verbatim: L10n.string("复制 Discord 时间戳", locale: model.uiLocale))
        }
        Button { PlaceRowMenu.copy(\.slack, model: model, zone: zone) } label: {
            Text(verbatim: L10n.string("复制 Slack 日期令牌", locale: model.uiLocale))
        }
    }

    /// 标识块与时间按 顺序 × 对齐 排布;默认(名称在前 + 时间单独成列)。
    @ViewBuilder
    private func rowContent(settings: AppSettings, localizedCity: String, sky: SkyPanel.Row?, metrics: SkyRowMetrics, ink: Color?) -> some View {
        let style = RowPrimaryTextStyle(settings: settings, metrics: metrics, followsSky: followsSky, skyColors: sky?.colors)
        let label = RowLabelBlock(zone: zone, localizedCity: localizedCity,
                                  mode: settings.displayMode, style: style,
                                  withOffset: settings.showOffsetBesideName, sky: sky, metrics: metrics,
                                  compactOffsets: compactOffsets, availableWidth: availableWidth)
        // 名称模式 + 城市语言=无 + 无自定义名 → 行内不显示任何名称,时间就成了唯一内容。
        // 这种情况下给时间补一个从 identifier 拆出的名字做无障碍标签,行才有语境。
        let spokenName: String? = PresentationCore.call("spoken_name", PresentationCore.SpokenNameInput(
            customName: zone.customName, localizedCity: localizedCity, cityName: zone.cityName,
            nameMode: settings.displayMode == .name))
        let time = ClockDrivenRowTimeText(zone: zone, clockFormat: settings.clockFormat, style: style,
                                          spokenName: spokenName, metrics: metrics)

        switch (settings.elementOrder, settings.rowTimeAlignment) {
        case (.nameThenTime, .trailing): label.frame(maxWidth: .infinity, alignment: .leading); time.padding(.leading, 18)
        case (.nameThenTime, .leading):  label; time; Spacer(minLength: 0)
        case (.timeThenName, .trailing): time; label.frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 18)
        case (.timeThenName, .leading):  time; label; Spacer(minLength: 0)
        }
    }
}

/// 地点行的右键菜单（系统菜单，长得就该像系统菜单）。第一层最多 8 项：平时 7 项，「现在能打给谁」排序时多一项「能打给的时段」。
/// 次序：拷贝 · 去别的页 · 改名与删除 · 两个就地设置。拷贝只有一个入口「复制为」：同一刻的几种写法收在一起，
/// 最常用的「各地时间连成一行」排第一（与换算页「复制成一行 / 其他写法」同一套），四种时间戳在它下面
/// （此前四条排在菜单最上面，一级十一二项，改名与删除被挤到中下）。截图夹具也用它（`RowMenuFixture`）。
struct PlaceRowMenu: View {
    let model: AppModel
    let hub: FeatureHub?
    let zone: TimeZoneEntry
    let onRename: () -> Void
    let open: (FeatureSelection, (FeatureHub) -> Void) -> Void

    var body: some View {
        @Bindable var model = model
        Menu("复制为") {
            // 面板上所有地点的当前时间连成一行（调研 #11）：穿梭到别的时刻就复制那个时刻。
            Button("各地时间连成一行") { model.copyAllPlaceTimes() }
            Divider()
            // 父菜单已经说了「复制为」，这里只写名字（Apple 的子菜单不重复父项的动词）。
            // ISO 8601 带这个地方那一刻的偏移；Unix、Discord、Slack 与时区无关。
            Button { Self.copy(\.iso8601, model: model, zone: zone) } label: { Text(verbatim: "ISO 8601") }
            Button("Unix 时间戳") { Self.copy(\.unix, model: model, zone: zone) }
            Button("Discord 时间戳") { Self.copy(\.discord, model: model, zone: zone) }
            Button("Slack 日期令牌") { Self.copy(\.slack, model: model, zone: zone) }
        }
        Divider()
        // 从这一行去别处：带着这个地点打开那一页，不用到了那边再选一遍。
        Button("在「太阳与月亮」里查看") { open(.astronomy) { $0.astronomy.requestedZoneID = zone.id } }
        Button("从这里换算…") { open(.convert) { $0.conversionSourceID = zone.id.uuidString } }
        if hub?.isAvailable(.planner) == true {
            Button("在「找碰头时间」里包含") { model.setParticipates(id: zone.id, true); open(.planner) { _ in } }
        }
        Divider()
        Button("重命名…") { onRename() }
        Button("删除", role: .destructive) { model.removeZone(id: zone.id) }
        Divider()
        // 「现在能打给谁」的判定基准就地换（只在 callable 排序下才有意义）：上班 = 这行自己的可约时段，
        // 醒着 = 设置里的全局醒着窗口。当前项带勾，与下面的「面板底色」同一款 inline Picker。
        if model.settings.panelSort == .callable {
            Menu {
                Picker("能打给的时段", selection: Binding(get: { zone.callBasis }, set: { model.setCallBasis(id: zone.id, to: $0) })) {
                    ForEach(CallBasis.allCases, id: \.self) { Text($0.localizedKey).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Text("能打给的时段")
            }
        }
        // 面板底色就地换（与外观设置页同一个设置、同一组标签），当前项带勾（底栏排序菜单同款 inline Picker）。
        Menu {
            Picker("面板底色", selection: $model.settings.panelColors) {
                ForEach(PanelColors.allCases) { Text($0.localizedKey).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Text("面板底色")
        }
    }

    /// 这个地方此刻（拖过时间就是拖到的那一刻）的一种时间戳放进剪贴板。
    @MainActor static func copy(_ field: KeyPath<TimeInput.Timestamps, String>, model: AppModel, zone: TimeZoneEntry) {
        guard let stamps = TimeInput.timestamps(for: model.referenceDate, in: zone.timeZone) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(stamps[keyPath: field], forType: .string)
    }
}

#if DEBUG
/// 截图夹具（只在测试宿主）：`MEANTIME_UI_TEST_ROW_MENU=1` 面板出来后在第一行旁弹出它的右键菜单，`=copy` 弹「复制为」那一层。
/// 菜单内容就是右键用的那一份 `PlaceRowMenu`，经系统的 `NSHostingMenu` 变成菜单（不合成点击：右键菜单只能由真的右键打开，
/// 截图脚本又不许发点击）。同时把每一层的项写到 stdout（`MEANTIME_ROW_MENU`），数第一层几项不靠看图。
@MainActor
enum RowMenuFixture {
    static func runIfRequested(model: AppModel, hub: FeatureHub?) {
        guard ApplicationSession.isTesting, let mode = ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_ROW_MENU"],
              !mode.isEmpty else { return }
        guard ApplicationSession.uiTestForeground else {
            FileHandle.standardError.write(Data("DEFERRED: native row menu requires MEANTIME_UI_TEST_FOREGROUND=1\n".utf8))
            exit(75)
        }
        guard let zone = model.panelOrder.zones.first else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            guard let window = NSApp.windows.first(where: { ($0.identifier?.rawValue ?? "").hasPrefix("audit-panel") && $0.isVisible }),
                  let content = window.contentView else { return }
            let full = PlaceRowMenu(model: model, hub: hub, zone: zone, onRename: {}, open: { _, _ in })
            let menu = NSHostingMenu(rootView: full.environment(\.locale, model.uiLocale))
            menu.update()
            func dump(_ menu: NSMenu, depth: Int) {
                for item in menu.items {
                    let line = item.isSeparatorItem ? "—" : item.title
                    FileHandle.standardOutput.write(Data("MEANTIME_ROW_MENU \(String(repeating: "  ", count: depth))\(line)\n".utf8))
                    if let sub = item.submenu { sub.update(); dump(sub, depth: depth + 1) }
                }
            }
            dump(menu, depth: 0)
            let first = menu.items.filter { !$0.isSeparatorItem }.count
            FileHandle.standardOutput.write(Data("MEANTIME_ROW_MENU_TOP \(first)\n".utf8))
            let shown = mode == "copy" ? (menu.items.first?.submenu ?? menu) : menu
            // 弹在窗口上部（搜索栏下面、盖住地图）：测试窗口常常压着屏幕底边，弹在第一行旁菜单会被屏幕截短、出现滚动箭头；
            // 真的面板挂在菜单栏下，右键时下面有整屏的高度。
            let point = NSPoint(x: 150, y: content.isFlipped ? 70 : content.bounds.height - 70)
            shown.popUp(positioning: nil, at: point, in: content)
        }
    }
}
#endif

/// 行的字色：跟着天色时是墨或纸（整行，连同读屏以外的一切字）；跟着系统时不改（系统的主色）。
private struct RowInk: ViewModifier {
    let ink: Color?
    func body(content: Content) -> some View {
        if let ink { content.foregroundStyle(ink) } else { content }
    }
}

/// 一行的天色底：太阳贴着地平线时天顶到地平线的渐变，其余一种颜色；系统「提高对比度」时一律纯色（渐变两端的
/// 对比度 Rust 都算过，这里只是少一样花样）。没有坐标的地点是纸色。
struct SkyRowBackground: View {
    let row: SkyPanel.Row
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        if row.gradient && contrast != .increased {
            LinearGradient(colors: [row.colors.topColor, row.colors.horizonColor], startPoint: .top, endPoint: .bottom)
        } else {
            row.colors.midColor
        }
    }
}

/// 面板行的字号与行高：地名大一号（标题 2），钟点更大更细，第二行是说明文字的字号；
/// 字号给出最小行高；文字换行时按实际内容增高（面板只有一个滚动区，列表自己不滚）。
/// 都乘「文字大小」的倍数（macOS 没有 Dynamic Type）。
struct SkyRowMetrics: Equatable {
    let nameSize: CGFloat
    let timeSize: CGFloat
    let detailSize: CGFloat
    let rowHeight: CGFloat

    init(settings: AppSettings, textScale: Double) {
        let scale = CGFloat(textScale)
        nameSize = (AppFont.size(.title2) * scale).rounded()
        timeSize = ClockFace.largeSize(scale: textScale)
        detailSize = (AppFont.size(.callout) * scale).rounded()
        // 左列：名字一行、（非名称模式）友好名一行、词一行、（开着时）日出日落一行，行间 4 pt；
        // 右列：钟点一行 + 「次日」一行。上下各留 10 pt，至少 70 pt（原型的行高）。
        let lines = 1 + (settings.displayMode == .name ? 0 : 1) + (settings.panelShowsSunTimes ? 1 : 0)
        let left = nameSize * 1.28 + CGFloat(lines) * (detailSize * 1.35 + 4) + 4
        let right = timeSize * 1.2 + detailSize * 1.35 + 2
        rowHeight = max(70, (max(left, right) + 20).rounded(.up))
    }
}

private struct RowLabelBlock: View {
    let zone: TimeZoneEntry
    let localizedCity: String
    let mode: DisplayMode
    let style: RowPrimaryTextStyle
    /// 名称旁附 UTC 偏移（调研 #9）。开着时名称档也要跟着钟走（偏移会随夏令时变）。
    let withOffset: Bool
    let sky: SkyPanel.Row?
    let metrics: SkyRowMetrics
    let compactOffsets: Bool
    let availableWidth: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if zone.timezoneID == TimeZone.current.identifier {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        nameAndMarkers.fixedSize(horizontal: true, vertical: true)
                        localBadge.fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        nameAndMarkers
                        localBadge
                    }
                }
            } else {
                nameAndMarkers
            }
            // 主标识不是名字时,底下补一行友好名(为空[城市语言=无]则不显示)。
            if mode != .name {
                let friendly = zone.displayName(localizedCity: localizedCity)
                if !friendly.isEmpty {
                    Text(friendly)
                        .font(.system(size: metrics.detailSize))
                        .foregroundStyle(style.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ClockDrivenRowDetail(zone: zone, sky: sky, metrics: metrics, style: style,
                                 compactOffsets: compactOffsets, availableWidth: availableWidth)
        }
    }

    private var nameAndMarkers: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            // 色点与 emoji 只供肉眼扫行，读屏从地点名开始。
            if let color = zone.color { ZoneDot(name: color).accessibilityHidden(true) }
            if let emoji = zone.emoji {
                Text(emoji)
                    .font(.system(size: metrics.nameSize * 0.9))
                    .accessibilityHidden(true)
            }
            primaryLabel
        }
    }

    private var localBadge: some View {
        Text("本机")
            .font(.system(size: max(9, metrics.detailSize - 2), weight: .medium))
            .kerning(0.6)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var primaryLabel: some View {
        if mode == .name && !withOffset {
            let primary = zone.customName ?? localizedCity
            // name 模式 + 城市语言=无 + 无自定义名 → primary 为空,整段不渲染(只剩时间与第二行)。
            if !primary.isEmpty {
                style.primaryText(Text(primary).font(style.nameFont(for: primary)))
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            ClockDrivenRowLabelText(zone: zone, localizedCity: localizedCity, mode: mode, style: style,
                                    withOffset: withOffset)
        }
    }
}

private struct ClockDrivenRowLabelText: View {
    @Environment(TimeCore.self) private var core
    let zone: TimeZoneEntry
    let localizedCity: String
    let mode: DisplayMode
    let style: RowPrimaryTextStyle
    var withOffset: Bool = false

    @ViewBuilder
    var body: some View {
        // emoji 在这一行左边单画（见 RowLabelBlock），串里不再带一个。
        let primary = zone.label(mode: mode, at: core.referenceDate, localizedCity: localizedCity,
                                 withOffset: withOffset, includeEmoji: false)
        if !primary.isEmpty {
            // 缩写与偏移是代号，不用衬线（`nameFont` 只给名字）。
            style.primaryText(Text(primary).font(mode == .name ? style.nameFont(for: primary) : style.codeFont))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 第二行：小太阳弧 + 一天里的词（破晓 / 下午 / 深夜…）+ 比本机快慢几小时。
/// 跟着钟走（拖时间时词、太阳的位置、快慢一起变），所以单独读 `TimeCore`。
struct ClockDrivenRowDetail: View {
    @Environment(TimeCore.self) private var core
    @Environment(AppModel.self) private var model
    let zone: TimeZoneEntry
    let sky: SkyPanel.Row?
    let metrics: SkyRowMetrics
    let style: RowPrimaryTextStyle

    let compactOffsets: Bool
    let availableWidth: CGFloat

    var body: some View {
        let relative = PanelRowDetail.relative(zone: zone, at: core.referenceDate, locale: model.uiLocale)
        let resting = PanelRowDetail.isResting(zone: zone, core: core)
        // 深底浅字显得细，第二行加粗半级（只对跟着天色、写纸色字的行）。
        let font = RowOffsetLayout.detailFont(settings: core.settings, metrics: metrics, sky: sky, followsSky: style.followsSky)
        let offset = relative.map { compactOffsets ? $0.compact : $0.full }
        let layout = RowOffsetLayout.detailLayout(offset: offset, word: sky?.word, resting: resting,
            path: sky?.path != nil, locale: core.uiLocale, font: font,
            availableWidth: availableWidth - RowOffsetLayout.reservedWidth(zone: zone, core: core, sky: sky,
                followsSky: style.followsSky, metrics: metrics))
        let wrapParts: [String?] = [sky?.word, relative?.full,
                                    resting ? L10n.string("在休息时段", locale: core.uiLocale) : nil]
        let wrapText = wrapParts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    if layout.showsPath, let path = sky?.path {
                        SunPathGlyph(path: path, foreground: style.glyph)
                            .frame(width: 22, height: 14)
                            .accessibilityHidden(true)
                    }
                    // 天色词放不下时整词隐藏，读屏仍保留完整意思。
                    if layout.showsSkyWord, let word = sky?.word {
                        Text(verbatim: word).fixedSize(horizontal: true, vertical: false).layoutPriority(1)
                    }
                    if layout.showsSkyWord, relative != nil {
                        Text(verbatim: "·").accessibilityHidden(true)
                    }
                    if let relative {
                        // 整表由最宽的一行决定同一写法，读屏始终读完整意思。
                        Text(verbatim: compactOffsets ? relative.compact : relative.full)
                            .fixedSize(horizontal: true, vertical: false)
                            .layoutPriority(2)
                            .accessibilityLabel(Text(verbatim: relative.full))
                    }
                    if layout.showsResting {
                        // 醒着基准、又在醒着窗口外（那边在睡）：第二行末尾缀一句，样式随这一行（同一字号、同一次截断）。
                        if layout.showsSkyWord || relative != nil {
                            Text(verbatim: "·").accessibilityHidden(true)
                        }
                        Text(verbatim: L10n.string("在休息时段", locale: core.uiLocale))
                    }
                }
                .font(Font(font))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: true)
                // 词与快慢也跟着钟点走第二拍（交叉淡入），不在地图那一拍里先变。
                .contentTransition(.opacity)
                HStack(spacing: 6) {
                    if layout.showsPath, let path = sky?.path {
                        SunPathGlyph(path: path, foreground: style.glyph)
                            .frame(width: 22, height: 14)
                            .accessibilityHidden(true)
                    }
                    Text(verbatim: wrapText)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(Font(font))
                .contentTransition(.opacity)
            }
        }
    }
}

/// 日出日落用整行的宽度；放不下时换行，不挤掉钟点或地名。
private struct ClockDrivenRowSunTimes: View {
    @Environment(TimeCore.self) private var core
    let zone: TimeZoneEntry
    let sky: SkyPanel.Row
    let metrics: SkyRowMetrics
    let clockFormat: ClockFormat
    let followsSky: Bool
    let rowHeight: CGFloat

    var body: some View {
        sunTimes
            .font(.system(size: metrics.detailSize).monospacedDigit())
            .fixedSize(horizontal: false, vertical: true)
            .modifier(SkyRowLocalForeground(row: sky, rowID: zone.id, height: rowHeight, followsSky: followsSky))
            .contentTransition(.opacity)
    }

    @ViewBuilder
    private var sunTimes: some View {
        let format = { (unix: Double) in
            TimeFormatting.string(for: Date(timeIntervalSince1970: unix), in: zone.timeZone,
                                  format: ClockFormat(hourStyle: clockFormat.hourStyle, showSeconds: false))
        }
        let parts = [sky.sunrise.map { String(format: L10n.string("日出 %@", locale: core.uiLocale), format($0)) },
                     sky.sunset.map { String(format: L10n.string("日落 %@", locale: core.uiLocale), format($0)) }].compactMap { $0 }
        if !parts.isEmpty {
            Text(verbatim: parts.joined(separator: "  "))
        } else if sky.known, let path = sky.path {
            // 这一天没有日出也没有日落：极昼（太阳一直在地平线上）或极夜（旧面板行就这么写，光重做时漏了，同上补回）。
            Text(path.up ? "极昼" : "极夜")
        }
    }
}

/// 第二行的文字事实供显示、读屏与整表量宽共同取用。
@MainActor
enum PanelRowDetail {
    struct Relative: Equatable {
        let full: String
        let compact: String
    }

    static func relative(zone: TimeZoneEntry, at date: Date, locale: Locale) -> Relative? {
        relative(timeZone: zone.timeZone, at: date, locale: locale)
    }

    /// 与本机差多少的唯一写法（面板行、换算页的结果行都走这里）：「快 8小时 / 慢 3小时30分钟」，窄时「+8h」；同一时间不写。
    static func relative(timeZone: TimeZone, at date: Date, locale: Locale, home: TimeZone = .current) -> Relative? {
        guard let full = fullRelative(timeZone: timeZone, at: date, locale: locale, home: home) else { return nil }
        let difference = Double(timeZone.secondsFromGMT(for: date) - home.secondsFromGMT(for: date))
        return Relative(full: full, compact: PresentationCore.call("scroll_label", ["seconds": difference]))
    }

    /// 只要全写那一句时（换算页的结果行）：不去 Rust 要窄写，表跟着拖时间重画时不多一次往返。
    static func fullRelative(timeZone: TimeZone, at date: Date, locale: Locale, home: TimeZone = .current) -> String? {
        let difference = Double(timeZone.secondsFromGMT(for: date) - home.secondsFromGMT(for: date))
        guard difference != 0 else { return nil }
        let duration = ClockText.duration(seconds: abs(difference), locale: locale)
        return String(format: L10n.string(difference > 0 ? "快 %@" : "慢 %@", locale: locale), duration)
    }

    static func isResting(zone: TimeZoneEntry, core: TimeCore) -> Bool {
        guard core.settings.panelSort == .callable, zone.callBasis == .awake else { return false }
        return !PlaceCallability.compute(timeZone: zone.timeZone, now: core.now, countryCode: zone.countryCode,
                                         window: core.settings.awakeWindow).isCallable
    }
}

private struct RowAccessibility: ViewModifier {
    @Environment(TimeCore.self) private var core
    let zone: TimeZoneEntry
    let localizedCity: String
    let sky: SkyPanel.Row?

    func body(content: Content) -> some View {
        let name = zone.customName ?? (localizedCity.isEmpty ? zone.cityName : localizedCity)
        let label = zone.label(mode: core.settings.displayMode, at: core.referenceDate, localizedCity: localizedCity,
                               withOffset: core.settings.showOffsetBesideName, includeEmoji: false)
        let time = TimeFormatting.string(for: core.referenceDate, in: zone.timeZone, format: core.settings.clockFormat)
        let day = ClockText.dayOffset(of: core.referenceDate, in: zone.timeZone, from: .current)
        let shift = zone.timeZone.secondsFromGMT(for: core.referenceDate) - zone.timeZone.secondsFromGMT(for: core.now)
        var parts = [name]
        if !label.isEmpty && label != name { parts.append(label) }
        if zone.timeZone == TimeZone.current { parts.append(L10n.string("本机", locale: core.uiLocale)) }
        if let word = sky?.word { parts.append(word) }
        if let relative = PanelRowDetail.relative(zone: zone, at: core.referenceDate, locale: core.uiLocale) { parts.append(relative.full) }
        if PanelRowDetail.isResting(zone: zone, core: core) { parts.append(L10n.string("在休息时段", locale: core.uiLocale)) }
        if core.settings.panelShowsSunTimes, let sky {
            let clock = { (unix: Double) in
                TimeFormatting.string(for: Date(timeIntervalSince1970: unix), in: zone.timeZone,
                                      format: ClockFormat(hourStyle: core.settings.hourStyle, showSeconds: false))
            }
            if let sunrise = sky.sunrise { parts.append(String(format: L10n.string("日出 %@", locale: core.uiLocale), clock(sunrise))) }
            if let sunset = sky.sunset { parts.append(String(format: L10n.string("日落 %@", locale: core.uiLocale), clock(sunset))) }
            if sky.sunrise == nil && sky.sunset == nil, sky.known, let path = sky.path {
                parts.append(L10n.string(path.up ? "极昼" : "极夜", locale: core.uiLocale))
            }
        }
        if day != 0 { parts.append(L10n.string(day > 0 ? "次日" : "前一日", locale: core.uiLocale)) }
        parts.append(time)
        if shift != 0 {
            parts.append(clockChangeDescription(shift, locale: core.uiLocale))
        }
        return content.accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: parts.filter { !$0.isEmpty }.joined(separator: ", ")))
    }
}

/// 一枚小太阳弧（22 × 14 点）：一条地平线、一道虚线的弧；点永远是太阳——白天骑在弧上（从日出一端走到日落一端），
/// 夜里沉在地平线下，从落下的一端往升起的一端挪。静态图使用纯形状，避免 Canvas 的图形缓冲。
struct SunPathGlyph: View {
    let path: SkyPanel.SunPath
    var foreground: Color? = nil

    var body: some View {
        let (center, radius) = Self.sun(path)
        let ink = foreground.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.foreground)
        ZStack(alignment: .topLeading) {
            Path { p in p.move(to: CGPoint(x: 1, y: 9.5)); p.addLine(to: CGPoint(x: 21, y: 9.5)) }
                .stroke(ink, style: StrokeStyle(lineWidth: 1.2))
            Path { p in p.addArc(center: CGPoint(x: 11, y: 9.5), radius: 9, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false) }
                .applying(CGAffineTransform(translationX: 0, y: 9.5).scaledBy(x: 1, y: 7.5 / 9).translatedBy(x: 0, y: -9.5))
                .stroke(ink, style: StrokeStyle(lineWidth: 1.2, dash: [1.5, 1.5]))
            Circle().fill(ink)
                .frame(width: 2 * radius, height: 2 * radius)
                .position(center)
        }
        .frame(width: 22, height: 14, alignment: .topLeading)
    }

    /// 太阳的圆心与半径（22 × 14 的格子里）。
    static func sun(_ path: SkyPanel.SunPath) -> (CGPoint, CGFloat) {
        let f = min(1, max(0, path.fraction))
        if path.up {
            let theta = Double.pi * (1 - f)
            return (CGPoint(x: 11 + 9 * cos(theta), y: 9.5 - 7.5 * sin(theta)), 2.6)
        }
        return (CGPoint(x: 20 - 18 * f, y: 12.4), 2.2)
    }
}

private func clockChangeDescription(_ seconds: Int, locale: Locale) -> String {
    String(format: L10n.string(seconds > 0 ? "换钟，拨快%@" : "换钟，拨慢%@", locale: locale),
           ClockText.directionalDuration(seconds: Double(seconds), locale: locale))
}

private struct ClockDrivenRowTimeText: View {
    @Environment(TimeCore.self) private var core
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let zone: TimeZoneEntry
    let clockFormat: ClockFormat
    let style: RowPrimaryTextStyle
    /// 行内没有可见名称时,用它给时间补语境(见 rowContent)。nil = 行内已有名称,不重复。
    var spokenName: String? = nil
    let metrics: SkyRowMetrics

    var body: some View {
        let time = TimeFormatting.string(for: core.referenceDate, in: zone.timeZone,
                                         format: clockFormat)
        // 那边已是次日 / 还是前一日时在钟点下标一下（系统世界时钟同位置写「明天」）；同一天不写。
        let offset = ClockText.dayOffset(of: core.referenceDate, in: zone.timeZone, from: .current)
        let shift = daylightShift
        let signed: String? = shift == 0 ? nil : PresentationCore.call("signed_offset", ["seconds": shift])
        VStack(alignment: .trailing, spacing: 2) {
            // 钟点是一行里最大的字（二轮起「先看几点」）；跳到某一刻时数字滚过去（跳转的第二拍），
            // 「减弱动态效果」时不滚、交叉淡入。
            style.primaryText(Text(time).font(style.timeFont))
                .contentTransition(reduceMotion ? .opacity : .numericText())
                .lineLimit(1)
                .fixedSize()
            if offset != 0 || signed != nil {
                HStack(spacing: 6) {
                    if offset != 0 { Text(offset > 0 ? "次日" : "前一日") }
                    // 换钟徽标：图标 + 有符号的偏移（「+1」「−0:30」），挤不下「夏令时」三个字，意思交给读屏。
                    if let signed {
                        Label(signed, systemImage: "clock.arrow.2.circlepath")
                            .labelStyle(.titleAndIcon)
                            .imageScale(.small)
                    }
                }
                .font(.system(size: metrics.detailSize).monospacedDigit())
                .lineLimit(1)
                .fixedSize()
                // 「次日 / 前一日」与换钟徽标也是钟点的一部分：与上面的大钟点同一拍淡入。
                .contentTransition(.opacity)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel({
            var parts = [time]
            if offset != 0 { parts.insert(L10n.string(offset > 0 ? "次日" : "前一日", locale: core.uiLocale), at: 0) }
            if shift != 0 { parts.append(clockChangeDescription(shift, locale: core.uiLocale)) }
            if let spokenName { parts.insert(spokenName, at: 0) }
            return Text(verbatim: parts.joined(separator: ", "))
        }())
    }

    /// 拖到的那一刻与此刻，这个地方的时区偏移差（秒）。非零 = 中间跨过一次夏令时换钟：约会定在两周后、那两周里对方刚好换钟，
    /// 心算就整整差一小时（钟本身一直按系统时区数据走、是对的，只是这件事过去看不见）。不拖时间恒为 0，不出声。
    /// 地点的唤醒基准徽标与名称一起显示，保持与该地点的可约性判断一致。
    private var daylightShift: Int {
        zone.timeZone.secondsFromGMT(for: core.referenceDate) - zone.timeZone.secondsFromGMT(for: core.now)
    }
}

struct RowPrimaryTextStyle {
    let fontDesign: FontDesignOption
    let weight: WeightOption
    let useCustomColor: Bool
    let customColor: CodableColor?
    let metrics: SkyRowMetrics
    let followsSky: Bool
    let skyColors: SkyPanel.Colors?

    init(settings: AppSettings, metrics: SkyRowMetrics, followsSky: Bool, skyColors: SkyPanel.Colors?) {
        fontDesign = settings.fontDesign
        weight = settings.weight
        useCustomColor = settings.useCustomColor
        customColor = settings.customColor
        self.metrics = metrics
        self.followsSky = followsSky
        self.skyColors = skyColors
    }

    /// 地名：默认（`.system`）用衬线——拉丁字母 New York、汉字宋体；选了圆角 / 衬线 / 等宽就照选的来。
    /// 字重默认中等，选了别的字重就照选的来。
    func nameFont(for text: String) -> Font {
        let w = weight == .regular ? Font.Weight.medium : weight.fontWeight
        guard let design = fontDesign.design else { return SerifFace.font(text, size: metrics.nameSize, weight: w) }
        return .system(size: metrics.nameSize, weight: w, design: design)
    }

    /// 缩写（PST）与 UTC 偏移：代号，用系统字（或选的设计）。
    var codeFont: Font {
        let w = weight == .regular ? Font.Weight.medium : weight.fontWeight
        return .system(size: metrics.nameSize, weight: w, design: fontDesign.design ?? .default).monospacedDigit()
    }

    /// 钟点：大、细、等宽数字；选了设计与字重就照选的来（`ClockFace`，工具窗各页的主数字同一种）。
    var timeFont: Font {
        ClockFace.font(size: metrics.timeSize, design: fontDesign, weight: weight, light: true)
    }

    /// 第二行等次要文字：跟着天色时与主字同色（墨或纸，对比度才算得准）；跟着系统时用可读的次要色。
    var secondary: AnyShapeStyle {
        if followsSky, let skyColors {
            AnyShapeStyle(SkyTextRole.panelSecondary.foreground(in: skyColors))
        } else {
            AnyShapeStyle(.readableSecondary)
        }
    }

    var glyph: Color? {
        followsSky ? skyColors.map { SkyTextRole.panelGlyph.foreground(in: $0) } : nil
    }

    var sunTimes: AnyShapeStyle {
        if followsSky, let skyColors {
            AnyShapeStyle(SkyTextRole.panelSunTimes.foreground(in: skyColors))
        } else {
            AnyShapeStyle(.readableSecondary)
        }
    }

    /// 自定义色只给主文本，且只在「跟着系统」时用（天色底上的字色由对比度决定，不接受自定义）。
    @ViewBuilder
    func primaryText(_ text: Text) -> some View {
        if !followsSky, useCustomColor, let customColor {
            text.foregroundStyle(customColor.legibleColor)
        } else {
            text
        }
    }
}
