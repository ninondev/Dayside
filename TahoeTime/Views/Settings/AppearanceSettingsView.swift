// SPDX-License-Identifier: GPL-3.0-only
//
//  AppearanceSettingsView.swift
//  TahoeTime
//
//  外观设置：菜单栏与面板的显示内容、布局和颜色。
//

import SwiftUI

struct AppearanceSettingsView: View {
    @Environment(AppModel.self) private var model

    /// ColorPicker 要 Binding<Color>,而我们存 CodableColor?。读时回退 .primary,写时桥回 CodableColor。
    /// 写入时给不透明度设下限(见 `CodableColor.minimumLegibleOpacity`):仍允许调淡,但不允许
    /// 调到看不见——取色器会当场回弹到下限,用户立刻看得出这是有意的边界而不是 bug。
    private var customColorBinding: Binding<Color> {
        Binding(
            get: { model.settings.customColor?.color ?? .primary },
            set: { newValue in
                guard var picked = CodableColor(newValue) else { return }
                picked.opacity = PresentationCore.scalar("clamp_opacity", ["opacity": picked.opacity, "minimum": CodableColor.minimumLegibleOpacity])
                model.settings.customColor = picked
            }
        )
    }

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Stepper("最多显示 \(model.settings.menuBarMaxZones) 个地点",
                        value: $model.settings.menuBarMaxZones, in: 1...6)
                Picker("分隔符", selection: $model.settings.separator) {
                    ForEach(SeparatorOption.allCases) { Text($0.localizedKey).tag($0) }
                }
            } header: { Text("菜单栏").modifier(SettingsScaledFont(style: .headline)) }
            Section {
                Picker("显示内容", selection: $model.settings.displayMode) {
                    ForEach(DisplayMode.allCases) { Text($0.localizedKey).tag($0) }
                }
                Picker("名称与时间顺序", selection: $model.settings.elementOrder) {
                    ForEach(ElementOrder.allCases) { Text($0.localizedKey).tag($0) }
                }
                Toggle("显示秒", isOn: $model.settings.showSeconds)
            } header: { Text("菜单栏和面板").modifier(SettingsScaledFont(style: .headline)) }
            Section {
                Picker("面板底色", selection: $model.settings.panelColors) {
                    ForEach(PanelColors.allCases) { Text($0.localizedKey).tag($0) }
                }
                if model.settings.panelColors == .system {
                    Toggle("使用自定义颜色", isOn: $model.settings.useCustomColor)
                    if model.settings.useCustomColor {
                        ColorPicker("文字颜色", selection: customColorBinding, supportsOpacity: true)
                    }
                }
                Picker("时间位置", selection: $model.settings.rowTimeAlignment) {
                    ForEach(RowTimeAlignment.allCases) { Text($0.localizedKey).tag($0) }
                }
                Toggle("显示昼夜地图", isOn: $model.settings.panelShowsMap)
                Toggle("显示日出日落", isOn: $model.settings.panelShowsSunTimes)
                Toggle("名称旁显示 UTC 偏移", isOn: $model.settings.showOffsetBesideName)
            } header: { Text("面板").modifier(SettingsScaledFont(style: .headline)) }
        }
        .formStyle(.grouped)
        // 按当前语言与展开状态量内容，窗口随之定高。
        .modifier(SettingsPageSizing(minimumContentHeight:
            model.settings.panelColors == .system && model.settings.useCustomColor
                ? Self.maximumExpandedHeight : Self.maximumDefaultHeight,
            layoutRevision: model.settings.panelColors == .system
                ? (model.settings.useCustomColor ? 2 : 1) : 0, page: .appearance))
    }

    /// 默认状态内容高的验收上限，由十六语量尺核对。
    static let maximumDefaultHeight: CGFloat = 559
    static let maximumExpandedHeight: CGFloat = 641
}
