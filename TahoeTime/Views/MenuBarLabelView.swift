// SPDX-License-Identifier: GPL-3.0-only
//
//  MenuBarLabelView.swift
//  TahoeTime
//
//  菜单栏标签——和系统时钟并排出现的地方,最关键的可见面。
//
//  实现注意:
//  ① MenuBarExtra 的 label 用多元素布局只会渲染第一段;整条必须拼成**单个 Text**。
//  ② **默认分支(系统字体设计 + 常规字重 + 不自定义色)逐字节 = 原 NSFont.menuBarFont,无 foregroundStyle**,
//     保证不动设置时与系统时钟一致;只有用户显式开了定制才偏离。
//  ③ 菜单栏整条对齐:**有意不做**——状态项是自动宽度(和系统时钟一样),左/中/右对齐无可见
//     效果;要生效得固定宽度,而固定宽度的菜单栏时钟不原生(系统时钟没有对齐选项)。
//

import SwiftUI
import AppKit

struct MenuBarLabelView: View {
    /// 只读时间核:菜单栏标签是纯读者,不依赖 AppModel 的写侧。
    @Environment(TimeCore.self) private var core

    var body: some View {
        let settings = core.settings
        // 读一次系统变更版本号:系统语言 / 时区 / 时钟一变,本地化城市名与时间都要立刻重算
        // (缓存本身能自愈,但没有它就没人通知 SwiftUI 重渲 ——)。
        let revision = core.systemRevision
        // prefix(...) 给的是零拷贝 ArraySlice;只取一次,传给占位判断与拼串,避免每次刷新两次 Array 堆分配。
        let count: Int = PresentationCore.call("menu_count", ["count": core.zones.count, "requested": settings.menuBarMaxZones])
        let shown = core.zones.prefix(count)
        return styled(base(shown, settings: settings, revision: revision), settings: settings)
    }

    @ViewBuilder
    private func base(_ shown: ArraySlice<TimeZoneEntry>, settings: AppSettings, revision: Int) -> some View {
        if shown.isEmpty {
            MenuBarLocalClockText(settings: settings, revision: revision)   // 首次启动也应直接显示本机时间
        } else {
            MenuBarClockText(items: shown.map {
                MenuBarClockItem(zone: $0, localizedCity: core.localizedCity($0))
            }, settings: settings, revision: revision)
        }
    }

    /// 套字体/字重。**默认分支保持原表达式**;显示秒时叠等宽数字。
    /// **不设 foregroundStyle**:经真机验证,菜单栏文字颜色由系统按浅/深色菜单栏托管,
    /// 自定义色在这里被系统覆盖(无效),这正是原生行为——自定义色只作用于面板(见 TimeZoneRowView)。
    @ViewBuilder
    private func styled(_ content: some View, settings s: AppSettings) -> some View {
        let menuFont = NSFont.menuBarFont(ofSize: 0)
        let font: Font = (s.fontDesign.design == nil && s.weight == .regular)
            ? Font(menuFont)   // ← 默认:精确的系统菜单栏字体,逐字节同今天
            : Font.system(size: menuFont.pointSize, design: s.fontDesign.design ?? .default)
                  .weight(s.weight.fontWeight)
        let sized = content.font(font)
        if s.showSeconds { sized.monospacedDigit() } else { sized }
    }
}

private struct MenuBarClockItem: Identifiable, Equatable {
    let zone: TimeZoneEntry
    let localizedCity: String

    var id: UUID { zone.id }
}

private struct MenuBarClockText: View {
    @Environment(\.featureHub) private var featureHub
    let items: [MenuBarClockItem]
    let settings: AppSettings
    let revision: Int
    @State private var date: Date = .now

    var body: some View {
        Text(labelString(at: date))
            .modifier(MenuBarTick(showSeconds: settings.showSeconds, revision: revision, date: $date))
    }

    /// 整条菜单栏文字。按 elementOrder 排列标识与时间,中间用 separator;zone 间固定 3 空格。
    /// 出口处过一道**宽度防线**(`MenuBarLabelFormatter`):超预算先去掉名称保住每个时区的完整
    /// 时间,仍超宽才截断。过宽时 macOS 不是截断而是**整项不绘制**,而面板是本 app 唯一入口。
    private func labelString(at date: Date) -> String {
        let sep = settings.separator.string
        var labelItems = items.map { item in
            let zone = item.zone
            let name = zone.label(mode: settings.displayMode, at: date,
                                  localizedCity: item.localizedCity)
            let time = TimeFormatting.string(for: date, in: zone.timeZone, format: settings.clockFormat)
            return MenuBarLabelFormatter.Item(name: name, time: time)
        }
        if let meeting = featureHub?.menuBarMeeting(now: date) {
            labelItems.insert(.init(name: "", time: menuBarMeetingText(meeting, locale: featureHub?.uiLocale ?? InterfaceLanguage.systemLocale())), at: 0)
        }
        return MenuBarLabelFormatter.compose(
            items: labelItems,
            separator: sep,
            nameFirst: settings.elementOrder == .nameThenTime,
            font: measurementFont
        )
    }

    /// SwiftUI 中用到的设计 / 字重也纳入宽度估算,避免定制粗体实际越过 180pt。
    private var measurementFont: NSFont {
        let menuFont = NSFont.menuBarFont(ofSize: 0)
        let styledFont: NSFont
        if settings.fontDesign == .system, settings.weight == .regular {
            styledFont = menuFont
        } else {
            let weight: NSFont.Weight = switch settings.weight {
            case .regular:  .regular
            case .medium:   .medium
            case .semibold: .semibold
            case .bold:     .bold
            }
            let base = NSFont.systemFont(ofSize: menuFont.pointSize, weight: weight)
            let descriptor: NSFontDescriptor? = switch settings.fontDesign {
            case .system:     base.fontDescriptor
            case .rounded:    base.fontDescriptor.withDesign(.rounded)
            case .serif:      base.fontDescriptor.withDesign(.serif)
            case .monospaced: base.fontDescriptor.withDesign(.monospaced)
            }
            styledFont = descriptor.flatMap {
                NSFont(descriptor: $0, size: menuFont.pointSize)
            } ?? base
        }
        return settings.showSeconds
            ? MenuBarLabelFormatter.withMonospacedDigits(styledFont)
            : styledFont
    }
}

private struct MenuBarLocalClockText: View {
    @Environment(\.featureHub) private var featureHub
    let settings: AppSettings
    let revision: Int
    @State private var date: Date = .now

    var body: some View {
        Text(label)
            .modifier(MenuBarTick(showSeconds: settings.showSeconds, revision: revision, date: $date))
    }
    private var label: String {
        let clock = TimeFormatting.string(for: date, in: .autoupdatingCurrent, format: settings.clockFormat)
        guard let meeting = featureHub?.menuBarMeeting(now: date) else { return clock }
        return MenuBarLabelFormatter.compose(items: [
            .init(name: "", time: menuBarMeetingText(meeting, locale: featureHub?.uiLocale ?? InterfaceLanguage.systemLocale())),
            .init(name: "", time: clock)
        ], separator: "", nameFirst: true, font: .menuBarFont(ofSize: 0))
    }
}

private func menuBarMeetingText(_ meeting: UpcomingMeeting, locale: Locale) -> String {
    if meeting.isOngoing { return "●" }
    return "◷ " + Duration.seconds(Int64(clamping: meeting.minutesUntilStart) * 60)
        .formatted(.units(allowed: [.minutes], width: .abbreviated).locale(locale))
}

/// 把 `date` 状态对齐到下一整秒(显秒)/整分驱动的共享菜单栏时钟。两个时钟视图共用一份 tick
/// 循环(原来各写一份相同的)。`.task(id:)` 在显示秒切换**或系统时钟 / 时区变更**时重启:前者让
/// 新节奏立即生效,后者让菜单栏时间当场跳到新值而不是等最多 60 秒的下一次 tick。
/// 视图消失时 SwiftUI 自动取消该 task(菜单栏关闭 → 停止唤醒)。对齐边界 → 数字恰好在整秒/整分翻动。
private struct MenuBarTick: ViewModifier {
    @Environment(\.featureHub) private var featureHub
    /// task 的重启键:任一分量变化都重建 tick 循环并立即刷新一次时间。
    private struct TickKey: Equatable { let showSeconds: Bool; let revision: Int }

    let showSeconds: Bool
    let revision: Int
    @Binding var date: Date

    func body(content: Content) -> some View {
        content.task(id: TickKey(showSeconds: showSeconds, revision: revision)) {
            date = .now
            featureHub?.clockDidTick(date)
            while !Task.isCancelled {
                try? await Task.sleep(for: ClockTick.nextBoundary(showSeconds: showSeconds))
                if Task.isCancelled { return }
                date = .now
                featureHub?.clockDidTick(date)
            }
        }
    }
}
