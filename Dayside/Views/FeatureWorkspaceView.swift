// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

enum FeatureSelection: String, CaseIterable, Identifiable {
    case planner, agenda, people, convert, timers, dstWatch, astronomy, markets, travel, sharing
    var id: Self { self }
    var title: LocalizedStringKey { LocalizedStringKey(titleKey) }
    var titleKey: String {
        switch self {
        case .planner: "找碰头时间"
        case .agenda: "日历"
        case .people: "人物时钟"
        case .convert: "时间换算"
        case .timers: "计时器"
        case .dstWatch: "夏令时提醒"
        case .travel: "旅行"
        case .astronomy: "太阳与月亮"
        case .markets: "市场时钟"
        case .sharing: "分享我的时间"
        }
    }
    /// 边栏分三组：安排 / 看时间 / 我的。
    enum Group: String, CaseIterable, Identifiable {
        case plan, look, mine
        var id: Self { self }
        var titleKey: String {
            switch self {
            case .plan: "安排"
            case .look: "看时间"
            case .mine: "我的"
            }
        }
        var title: LocalizedStringKey { LocalizedStringKey(titleKey) }
        var features: [FeatureSelection] {
            switch self {
            case .plan: [.planner, .agenda, .people]
            case .look: [.convert, .timers, .dstWatch, .astronomy, .markets]
            case .mine: [.travel, .sharing]
            }
        }
    }

    /// 边栏快捷键的序号：按 `allCases` 的顺序，与边栏三组里从上到下的顺序一致。
    /// 第十页按 macOS 惯例用 ⌘0（`keyEquivalent` 取个位；`Character("10")` 会直接崩，别写成那样）。
    var shortcutNumber: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }
    /// 显示与菜单用的那个字符（"1"…"9"、第十页是 "0"）。
    var shortcutKey: String { String(shortcutNumber % 10) }
    var keyEquivalent: KeyEquivalent { KeyEquivalent(Character(shortcutKey)) }

    var symbol: String {
        switch self {
        case .planner: "person.2.badge.gearshape"
        case .agenda: "calendar"
        case .people: "person.2"
        case .convert: "arrow.left.arrow.right"
        case .timers: "timer"
        case .dstWatch: "clock.badge.exclamationmark"
        case .travel: "airplane"
        case .astronomy: "sun.max"
        case .markets: "chart.line.uptrend.xyaxis"
        case .sharing: "square.and.arrow.up"
        }
    }
}

struct FeatureWorkspaceView: View {
    @Environment(AppModel.self) private var model
    @Bindable var hub: FeatureHub
    @State private var isVisible = false
    /// Sidebar width follows the longest page title in the current language: 190pt fits Chinese,
    /// English and Japanese, while Portuguese and Russian titles were truncated at that width.
    private var sidebarIdealWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let widest = FeatureSelection.allCases.filter(hub.isAvailable)
            .map { L10n.string($0.titleKey, locale: model.uiLocale).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        return min(300, max(190, ceil(widest) + 64))
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $hub.selection) {
                // 只列已登记的页；整组空了就不画组标题。
                ForEach(FeatureSelection.Group.allCases.filter { !$0.features.filter(hub.isAvailable).isEmpty }) { group in
                    Section(group.title) {
                        ForEach(group.features.filter(hub.isAvailable)) { feature in
                            Label(feature.title, systemImage: feature.symbol).tag(feature)
                                // 悬停提示写明快捷键（⌘1…⌘9 在 `DaysideApp` 的命令里定义）。
                                .help(Text(verbatim: "\(L10n.string(feature.titleKey, locale: model.uiLocale)) ⌘\(feature.shortcutKey)"))
                        }
                    }
                }
            }.navigationSplitViewColumnWidth(min: 170, ideal: sidebarIdealWidth, max: max(240, sidebarIdealWidth))
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                if hub.automationError != nil {
                    HStack {
                        Label("未能执行操作，请检查地点或计时器状态。", systemImage: "exclamationmark.triangle")
                        Spacer()
                        Button("关闭") { hub.clearAutomationError() }
                    }.appFont(.callout).padding([.horizontal, .top])
                }
                // 十页共用的出身：页首一条这里前后 12 小时的天，标着正在看的那一刻（`SkyStrip`）。
                // 它不随正文滚动：拖过时间之后，翻到哪一页、滚到哪一段，都看得见「看的是哪一刻」和「回到现在」。
                // 与正文同宽同边距（最大 720 居中），正文从它下面开始。
                Self.column {
                    SkyStrip()
                }
                .padding(.top, 10)
                .padding(.bottom, 2)
                if let feature = DaysideFeature(rawValue: hub.selection.rawValue), let module = hub.openModule(feature) {
                    if module.pageIsSelfScrolling { module.page(hub: hub) } else { page { module.page(hub: hub) } }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            #if DEBUG
            // 夹具挂在正文这一栏：分栏的每一栏是各自的宿主视图，反色这一项挂在窗口根上传不进来（实测）。
            .modifier(SkyA11yFixtures())
            #endif
            .navigationTitle(Text(verbatim: L10n.string(hub.selection.titleKey, locale: model.uiLocale)))
        }
        // 开关一律勾选框：macOS 26 的 switch 样式首帧要 ~35 MB 瞬时图形缓冲，勾选框没有。
        .background(ToolsPageMenu(hub: hub, locale: model.uiLocale).frame(width: 0, height: 0))
        .toggleStyle(.checkbox)
        .frame(minWidth: 660, minHeight: 460)
        #if DEBUG
        .task {
            // 截图夹具：`MEANTIME_UI_TEST_JUMP_HOURS=<小时>` 打开工具窗后跳到此刻前后那么多小时
            // （拍页首天色带拖过时间、超过 12 小时两种样子；只在测试宿主）；`MEANTIME_UI_TEST_JUMP_TO=<ISO 8601>` 跳到一个固定的时刻
            // （拍市场时钟的周末与休市日，换哪天拍都是同一个样子）。
            guard ApplicationSession.isTesting else { return }
            let environment = ProcessInfo.processInfo.environment
            let target = environment["MEANTIME_UI_TEST_JUMP_TO"].flatMap { ISO8601DateFormatter().date(from: $0) }
                ?? environment["MEANTIME_UI_TEST_JUMP_HOURS"].flatMap(Double.init).map { model.now.addingTimeInterval($0 * 3600) }
            guard let target else { return }
            try? await Task.sleep(for: .milliseconds(200))
            model.jump(to: target, animated: false)
        }
        #endif
        .onAppear { isVisible = true; hub.attach(to: model); hub.setVisible(true) }
        .onDisappear { isVisible = false; hub.setVisible(false); DiagnosticsLog.note("workspace", "tools window closed") }
        .onChange(of: hub.selection) { _, _ in hub.setVisible(isVisible) }
    }

    /// 十页共用的页面语法：标题只在工具栏，页首一条天色带，正文一层系统内边距、
    /// 一个最大宽度、左对齐、整页一个滚动区。人物页的列表与旅行页的分组表单是系统容器，
    /// 自带内边距与滚动，直接铺满，不再套一层。
    @ViewBuilder
    func page<Content: View>(@ViewBuilder _ content: @escaping () -> Content) -> some View {
        #if DEBUG
        if AccessibilityDump.requestedScrollFraction != nil {
            // 仅截图与转储夹具包一层代理，正常页面仍用原来的滚动区。
            let contentID = "dayside-ax-detail-content"
            ScrollViewReader { proxy in
                ScrollView {
                    Self.column { content().padding(.vertical) }.id(contentID)
                }
                .onAppear {
                    AccessibilityDump.scrollDetail = { fraction in
                        proxy.scrollTo(contentID, anchor: UnitPoint(x: 0, y: fraction))
                    }
                }
                .onDisappear { AccessibilityDump.scrollDetail = nil }
                .task {
                    guard !AccessibilityDump.isRequested, let fraction = AccessibilityDump.requestedScrollFraction else { return }
                    // 真实截图等夹具与窗口就位后再滚动。
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled else { return }
                    proxy.scrollTo(contentID, anchor: UnitPoint(x: 0, y: fraction))
                }
            }
        } else {
            ScrollView {
                Self.column { content().padding(.vertical) }
            }
        }
        #else
        ScrollView {
            Self.column { content().padding(.vertical) }
        }
        #endif
    }

    /// 正文那一栏：左右系统内边距、最大宽度 720，窗口更宽时居中（一轮：此前贴左、右边一大片空白，商店尺寸的截图尤其难看）。
    /// 天色带与正文用同一栏，左右边对齐。
    static func column<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .frame(maxWidth: contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    /// 正文最大宽度统一为 720 pt，正文居中。
    static let contentMaxWidth: CGFloat = 720
}
