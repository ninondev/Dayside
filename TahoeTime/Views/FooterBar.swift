// SPDX-License-Identifier: GPL-3.0-only
//
//  FooterBar.swift
//  TahoeTime
//
//  面板底栏:打开设置 + 退出。SettingsLink 直接打开 Settings 场景。
//

import SwiftUI
import AppKit

struct FooterBar: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(AppModel.self) private var model
    /// 两个地点以上才有排序可言。
    var showsSort = false
    var body: some View {
        // 长语言（ru「Настройки / Сортировка / Инструменты времени / Завершить」）一行放不下时退成只有图标的按钮，
        // 悬停与读屏仍给全名，避免俄语下四个按钮的文字全被省略号截断。
        ViewThatFits(in: .horizontal) {
            bar(labels: true)
            bar(labels: false)
        }
        .appFont(.callout)
        .foregroundStyle(.panelSecondary)
    }

    @ViewBuilder
    private func bar(labels: Bool) -> some View {
        @Bindable var model = model
        HStack {
            SettingsLink {
                item("设置", systemImage: "gearshape", labels: labels)
            }
            .buttonStyle(.plain)
            .help(Text("设置"))
            .accessibilityLabel(Text("设置"))
            if showsSort {
                Spacer()
                // 面板列表的排序开关放在底栏。
                Menu {
                    Picker(selection: $model.settings.panelSort) {
                        ForEach(PanelSort.allCases) { Text($0.localizedKey).tag($0) }
                    } label: {
                        Text("排序")
                    }
                    .pickerStyle(.inline)
                } label: {
                    item("排序", systemImage: model.settings.panelSort == .callable ? "phone.arrow.up.right" : "arrow.up.arrow.down", labels: labels)
                }
                .menuStyle(.button).buttonStyle(.plain).fixedSize()
                .help(Text("排序"))
                .accessibilityLabel(Text("排序"))
            }
            Spacer()
            Button { openWindow(id: "tools"); NSApplication.shared.activate(ignoringOtherApps: true) } label: {
                item("时间工具", systemImage: "square.grid.2x2", labels: labels)
            }
            .buttonStyle(.plain)
            .help(Text("时间工具"))
            .accessibilityLabel(Text("时间工具"))
            Spacer()
            Button { NSApplication.shared.terminate(nil) } label: {
                // 「退出」带文字时只有文字（与从前逐像素一致），退回图标时用电源符号。
                item("退出", systemImage: "power", labels: labels, textOnly: true)
            }
            .buttonStyle(.plain)
            .help(Text("退出"))
            .accessibilityLabel(Text("退出"))
        }
    }

    /// 底栏一项：带文字时是 Label，退回图标时只剩符号（命中区照旧 ≥ 20 pt）。
    @ViewBuilder
    private func item(_ title: LocalizedStringKey, systemImage: String, labels: Bool, textOnly: Bool = false) -> some View {
        if labels && textOnly {
            // 短词也要够点：土耳其语「Çık」文字只有 18 pt 宽，命中区向左补到 24 pt，文字仍贴右边。
            Text(title).frame(minWidth: 24, alignment: .trailing).padding(.vertical, 3).contentShape(Rectangle())
        } else if labels {
            Label(title, systemImage: systemImage).padding(.vertical, 3).contentShape(Rectangle())
        } else {
            Image(systemName: systemImage).frame(minWidth: 24, minHeight: 22).padding(.vertical, 3).contentShape(Rectangle())
        }
    }
}
