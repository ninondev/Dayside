// SPDX-License-Identifier: GPL-3.0-only
//
//  TimeZoneListView.swift
//  Dayside
//
//  面板内的时区列表。用 List 拿到原生的删除 / 拖拽重排(onMove)/ 键盘选行。
//  每一行的底是那个地方此刻的天（`listRowBackground`，满幅、相邻天色接近时画细线），
//  系统的选中高亮关掉（蓝色的一整条会盖住天色），选中与指针所在的行改由行自己左边一道竖线表示。
//

import AppKit
import SwiftUI

struct TimeZoneListView: View {
    @Environment(AppModel.self) private var model
    @Environment(TimeCore.self) private var core
    @Environment(\.panelSky) private var panelSky
    @Environment(\.panelFollowsSky) private var followsSky
    @Environment(\.textScale) private var textScale
    /// 指针停在哪一行（面板把它交给地图：地图上写出那个地方的名字与时间）。
    @Binding var hovered: UUID?
    var onRename: (TimeZoneEntry) -> Void

    /// 选中态：↑↓ 选行、回车重命名、⌫ / Delete 删除（可撤销）。
    /// 放在面板上：键盘选中的那一行与指针所在的一行一样，地图上写出它的名字。
    @Binding var selection: UUID?
    @State private var measuredRowWidth: CGFloat?
    @State private var measuredRows: [UUID: RowMeasurement] = [:]

    /// List 在面板里不会按内容定高：按每行实测高度相加，未量到时先用字号给出的最小高度。
    /// 列表整行取高后自己不滚：滚动交给面板唯一的 ScrollView。
    private var listHeight: CGFloat {
        let minimum = SkyRowMetrics(settings: model.settings, textScale: textScale).rowHeight
        return model.zones.reduce(CGFloat(6)) { total, zone in
            let measurement = measuredRows[zone.id]
            let height = measurement?.context == rowContext(zone: zone, width: measuredRowWidth ?? 320)
                ? measurement?.size.height ?? minimum : minimum
            return total + max(minimum, height)
        }
    }

    private struct RowContext: Equatable {
        let zone: TimeZoneEntry
        let settings: AppSettings
        let width: CGFloat
        let textScale: Double
        let locale: String
        let followsSky: Bool
    }

    private struct RowMeasurement: Equatable {
        let context: RowContext
        let size: CGSize
    }

    private func rowContext(zone: TimeZoneEntry, width: CGFloat) -> RowContext {
        RowContext(zone: zone, settings: model.settings, width: width, textScale: textScale,
                   locale: model.uiLocale.identifier, followsSky: followsSky)
    }

    var body: some View {
        // 排序开关：手动就是 `model.zones` 本身；「现在能打给谁」由 `panelOrder` 给顺序。
        let displayed = model.panelOrder.zones
        let manual = model.settings.panelSort == .manual
        GeometryReader { geometry in
            let compactOffsets = RowOffsetLayout.usesCompact(
                requiredWidths: displayed.map { RowOffsetLayout.requiredWidth(zone: $0, core: core,
                    sky: panelSky?.rows[$0.id], followsSky: followsSky, textScale: textScale) },
                availableWidth: measuredRowWidth ?? geometry.size.width)
            List(selection: $selection) {
                ForEach(displayed) { zone in
                    let context = rowContext(zone: zone, width: measuredRowWidth ?? geometry.size.width)
                    TimeZoneRowView(zone: zone, highlighted: selection == zone.id || hovered == zone.id, compactOffsets: compactOffsets, availableWidth: measuredRowWidth ?? geometry.size.width, onRename: { onRename(zone) })
                        .modifier(RowSunGraph(zone: zone))  // 行的音频图：带经纬度的行，读屏用户也能「听」到这一天的昼夜。
                        .onHover { inside in
                            if inside { hovered = zone.id } else if hovered == zone.id { hovered = nil }
                        }
                        .onGeometryChange(for: RowMeasurement.self, of: {
                            RowMeasurement(context: context, size: $0.size)
                        }) { measurement in
                            guard measurement.size.width > 0, measurement.size.height > 0 else { return }
                            measuredRowWidth = measurement.size.width
                            measuredRows[zone.id] = measurement
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(rowBackground(zone: zone))
                        // 排过序的列表不能拖：拖出来的位次不是 `zones` 的位次。系统会自己收起拖拽手柄。
                        .moveDisabled(!manual)
                }
                // 删除按 id（排序后行的位次与 `zones` 的下标不一致）。
                .onDelete { offsets in model.removeZones(ids: offsets.compactMap { displayed.indices.contains($0) ? displayed[$0].id : nil }) }
                .onMove { from, to in
                    guard manual else { return }
                    model.moveZones(from: from, to: to)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .background(TableHighlightOff())
            // 整表同一拍，行内容与行底一起继承，不为每一行各包两层。
            .animation(model.scrubRowAnimation, value: model.scrubSerial)
        }
        .frame(height: listHeight)
        .onDeleteCommand {
            guard let id = selection else { return }
            selection = nil
            model.removeZone(id: id)
        }
        .onKeyPress(.return) {
            guard let zone = model.zones.first(where: { $0.id == selection }) else { return .ignored }
            onRename(zone)
            return .handled
        }
        .onChange(of: model.zones.map(\.id)) { _, ids in
            if let id = selection, !ids.contains(id) { selection = nil }
            measuredRows = measuredRows.filter { ids.contains($0.key) }
        }
        #if DEBUG
        .task {
            // 截图夹具：`MEANTIME_UI_TEST_PANEL_SELECT=<行号>` 选中那一行（看选中的样子；只在测试宿主）。
            guard ApplicationSession.isTesting, let raw = ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_PANEL_SELECT"],
                  let row = Int(raw), displayed.indices.contains(row) else { return }
            try? await Task.sleep(for: .milliseconds(300))
            selection = displayed[row].id
        }
        #endif
    }

    /// 跟着天色时，相邻颜色接近才画行顶细线；跟着系统时，每行保留细线。
    @ViewBuilder
    private func rowBackground(zone: TimeZoneEntry) -> some View {
        let sky = panelSky?.rows[zone.id]
        ZStack(alignment: .top) {
            if followsSky, let sky {
                SkyRowBackground(row: sky)
            }
            if !followsSky || sky == nil || panelSky?.dividers[zone.id] == true {
                Rectangle()
                    .fill((followsSky ? sky?.colors.foreground : nil).map { AnyShapeStyle($0.opacity(0.3)) } ?? AnyShapeStyle(.separator))
                    .frame(height: 0.5)
            }
        }
    }
}

/// 整表在每次布局里量一次最宽第二行，统一选择完整或短写。
@MainActor
enum RowOffsetLayout {
    static func usesCompact(requiredWidths: [CGFloat], availableWidth: CGFloat) -> Bool {
        (requiredWidths.max() ?? 0) > availableWidth
    }

    struct DetailLayout: Equatable {
        let showsSkyWord: Bool
        let showsResting: Bool
        let showsPath: Bool
        let width: CGFloat
    }

    static func detailFont(settings: AppSettings, metrics: SkyRowMetrics, sky: SkyPanel.Row?, followsSky: Bool) -> NSFont {
        AppFont.detailFont(size: metrics.detailSize, design: settings.fontDesign,
                           heavier: followsSky && sky?.colors.ink == false)
    }

    static func width(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    static func requiredWidth(zone: TimeZoneEntry, core: TimeCore, sky: SkyPanel.Row?,
                              followsSky: Bool, textScale: Double) -> CGFloat {
        guard let relative = PanelRowDetail.relative(zone: zone, at: core.referenceDate, locale: core.uiLocale) else { return 0 }
        let metrics = SkyRowMetrics(settings: core.settings, textScale: textScale)
        let font = detailFont(settings: core.settings, metrics: metrics, sky: sky, followsSky: followsSky)
        let detail = detailWidth(offset: relative.full, word: sky?.word,
                                 resting: PanelRowDetail.isResting(zone: zone, core: core),
                                 path: sky?.path != nil, locale: core.uiLocale, font: font)
        return detail + reservedWidth(zone: zone, core: core, sky: sky, followsSky: followsSky, metrics: metrics)
    }

    /// 天色词先让出位置，再让休息提示与太阳弧让位；偏移始终完整。
    static func detailLayout(offset: String?, word: String?, resting: Bool, path: Bool,
                             locale: Locale, font: NSFont, availableWidth: CGFloat) -> DetailLayout {
        var showsWord = word != nil
        var showsResting = resting
        var showsPath = path
        func measured() -> CGFloat {
            detailWidth(offset: offset, word: showsWord ? word : nil, resting: showsResting,
                        path: showsPath, locale: locale, font: font)
        }
        if offset != nil {
            if measured() > availableWidth { showsWord = false }
            if measured() > availableWidth { showsResting = false }
            if measured() > availableWidth { showsPath = false }
        }
        return DetailLayout(showsSkyWord: showsWord, showsResting: showsResting, showsPath: showsPath, width: measured())
    }

    static func detailWidth(offset: String?, word: String?, resting: Bool, path: Bool,
                            locale: Locale, font: NSFont) -> CGFloat {
        var pieces = [CGFloat]()
        if path { pieces.append(22) }
        if let word { pieces.append(width(word, font: font)) }
        if let offset {
            if word != nil { pieces.append(width("·", font: font)) }
            pieces.append(width(offset, font: font))
        }
        if resting {
            if word != nil || offset != nil { pieces.append(width("·", font: font)) }
            pieces.append(width(L10n.string("在休息时段", locale: locale), font: font))
        }
        return pieces.reduce(0, +) + CGFloat(max(0, pieces.count - 1)) * 6
    }

    static func reservedWidth(zone: TimeZoneEntry, core: TimeCore, sky: SkyPanel.Row?,
                              followsSky: Bool, metrics: SkyRowMetrics) -> CGFloat {
        let settings = core.settings
        let timeFont = ClockFace.nativeFont(size: metrics.timeSize, design: settings.fontDesign, weight: settings.weight, light: true)
        let detailFont = AppFont.detailFont(size: metrics.detailSize, design: .system, heavier: false)
        let time = TimeFormatting.string(for: core.referenceDate, in: zone.timeZone, format: settings.clockFormat)
        var clockWidth = width(time, font: timeFont)
        let day = ClockText.dayOffset(of: core.referenceDate, in: zone.timeZone, from: .current)
        let shift = zone.timeZone.secondsFromGMT(for: core.referenceDate) - zone.timeZone.secondsFromGMT(for: core.now)
        var lowerWidth: CGFloat = day == 0 ? 0 : width(L10n.string(day > 0 ? "次日" : "前一日", locale: core.uiLocale), font: detailFont)
        if shift != 0 {
            let signed: String = PresentationCore.call("signed_offset", ["seconds": shift])
            lowerWidth += width(signed, font: detailFont) + 20 + (day == 0 ? 0 : 6)
        }
        clockWidth = max(clockWidth, lowerWidth)
        let columnSpace: CGFloat = settings.rowTimeAlignment == .trailing ? 28 : 20
        return clockWidth + 32 + columnSpace + (!followsSky && sky != nil ? 14 : 0)
    }

}

/// 把面板列表的系统选中高亮关掉：选中照旧（键盘 ↑↓、⌫、回车都认），只是不画那一整条蓝色，
/// 行的天色不被盖住；选中的行由它自己画一道竖线。SwiftUI 没有这个开关，这里只找占据本列表区域的 `NSTableView`
/// 把 `selectionHighlightStyle` 设成 `.none`——找不到（系统换了实现）就什么也不做，退回系统高亮，不会出错。
struct TableHighlightOff: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) { (nsView as? Probe)?.apply() }

    final class Probe: NSView {
        private(set) weak var appliedTable: NSTableView?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            // 列表的原生子树可能晚一轮接上；只等这一轮，不设计时器。
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            apply()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            apply()
        }

        override func layout() {
            super.layout()
            apply()
        }

        func apply() {
            appliedTable = nil
            guard bounds.width > 0, bounds.height > 0 else { return }
            var ancestor = superview
            while let current = ancestor {
                if let table = table(in: current) {
                    if table.selectionHighlightStyle != .none { table.selectionHighlightStyle = .none }
                    appliedTable = table
                    return
                }
                ancestor = current.superview
            }
        }

        private func table(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView {
                // 搜索补全也用表格；它在别的区域，不能收掉它的系统选中高亮。
                let enclosure: NSView = table.enclosingScrollView ?? table
                let frame = convert(enclosure.bounds, from: enclosure)
                return frame.width > 0 && frame.height > 0 && bounds.insetBy(dx: -1, dy: -1).contains(frame) ? table : nil
            }
            for child in view.subviews {
                if let table = table(in: child) { return table }
            }
            return nil
        }
    }
}
