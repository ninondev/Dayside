// SPDX-License-Identifier: GPL-3.0-only
//
//  GeneralSettingsView.swift
//  TahoeTime
//
//  通用设置：语言、钟点、文字、醒着时段与后台运行。
//

import ServiceManagement
import SwiftUI

struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model

    private var loginIssue: LaunchAtLoginIssue? {
        #if DEBUG
        if ApplicationSession.isTesting {
            switch ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_LOGIN_ISSUE"] {
            case "approval": return .requiresApproval
            case "failed": return .updateFailed
            default: break
            }
        }
        #endif
        return model.launchAtLoginIssue
    }

    private var awakeStartMinute: Binding<Int> {
        Binding(get: { model.settings.awakeWindow.startMinute },
                set: { model.settings.awakeWindow = Availability(startMinute: $0,
                    endMinute: model.settings.awakeWindow.endMinute, weekdaysOnly: false) })
    }

    private var awakeEndMinute: Binding<Int> {
        Binding(get: { model.settings.awakeWindow.endMinute },
                set: { model.settings.awakeWindow = Availability(startMinute: model.settings.awakeWindow.startMinute,
                    endMinute: $0, weekdaysOnly: false) })
    }

    private static let awakeStartChoices = Array(stride(from: 0, through: 1425, by: 15))
    private static let awakeEndChoices = Array(stride(from: 15, through: 1440, by: 15))

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("界面语言", selection: $model.settings.interfaceLanguage) {
                    ForEach(InterfaceLanguage.allCases) { lang in
                        if lang == .system { Text("跟随系统").modifier(SettingsMenuValueFont()).tag(lang) }
                        else { Text(verbatim: lang.autonym).modifier(SettingsMenuValueFont()).tag(lang) }
                    }
                }
                Picker("城市显示语言", selection: $model.settings.cityLanguage) {
                    ForEach(CityLanguage.allCases) { lang in
                        switch lang {
                        case .followInterface: Text("跟随界面").modifier(SettingsMenuValueFont()).tag(lang)
                        case .system: Text("跟随系统").modifier(SettingsMenuValueFont()).tag(lang)
                        case .none: Text("不显示城市名").modifier(SettingsMenuValueFont()).tag(lang)
                        default: Text(verbatim: lang.autonym).modifier(SettingsMenuValueFont()).tag(lang)
                        }
                    }
                }
                Picker("小时制", selection: $model.settings.hourStyle) {
                    ForEach(HourStyle.allCases) { Text($0.localizedKey).modifier(SettingsMenuValueFont()).tag($0) }
                }
            } header: { Text("语言与钟点").modifier(SettingsScaledFont(style: .headline)) }
            Section {
                Picker("字体", selection: $model.settings.fontDesign) {
                    ForEach(FontDesignOption.allCases) { Text($0.localizedKey).modifier(SettingsMenuValueFont()).tag($0) }
                }
                Picker("字重", selection: $model.settings.weight) {
                    ForEach(WeightOption.allCases) { Text($0.localizedKey).modifier(SettingsMenuValueFont()).tag($0) }
                }
                Picker("文字大小", selection: $model.settings.textSize) {
                    ForEach(TextSize.allCases) { Text($0.localizedKey).modifier(SettingsMenuValueFont()).tag($0) }
                }
            } header: { Text("文字").modifier(SettingsScaledFont(style: .headline)) } footer: {
                Text("字体和字重用于所有钟点；文字大小用于面板和窗口，菜单栏的字号由系统决定。")
                    .modifier(SettingsScaledFont(style: .caption))
                    .foregroundStyle(.readableSecondary)
            }
            Section {
                LabeledContent("醒着时段") {
                    HStack(spacing: 4) {
                        Picker("醒着时段开始", selection: awakeStartMinute) {
                            ForEach(Self.awakeStartChoices, id: \.self) {
                                Text(verbatim: ClockText.minute($0, hourStyle: model.settings.hourStyle)).modifier(SettingsMenuValueFont()).tag($0)
                            }
                        }.labelsHidden()
                        Text(verbatim: "–")
                            .foregroundStyle(.readableSecondary)
                        Picker("醒着时段结束", selection: awakeEndMinute) {
                            ForEach(Self.awakeEndChoices, id: \.self) {
                                Text(verbatim: ClockText.minute($0, hourStyle: model.settings.hourStyle)).modifier(SettingsMenuValueFont()).tag($0)
                            }
                        }.labelsHidden()
                    }
                }
            } header: { Text("能打给谁").modifier(SettingsScaledFont(style: .headline)) } footer: {
                Text("面板按“现在能打给谁”排序时，每个地点按它自己的上班时段或这里的醒着时段算，都按当地时间；在面板里右键点地点可以换。")
                    .modifier(SettingsScaledFont(style: .caption))
                    .foregroundStyle(.readableSecondary)
            }
            Section {
                Toggle("开机自启", isOn: $model.settings.launchAtLogin)
                Toggle("在后台保持运行", isOn: $model.settings.keepAliveInBackground)
                if let issue = loginIssue {
                    VStack(alignment: .leading, spacing: 8) {
                        switch issue {
                        case .requiresApproval:
                            Label("macOS 需要在系统设置的登录项中允许 Dayside。", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.readableSecondary)
                        case .updateFailed:
                            ErrorLine(Text("无法更新开机自启。"))
                        }
                        Button("打开系统设置…") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
            } header: { Text("后台运行").modifier(SettingsScaledFont(style: .headline)) } footer: {
                Text("在后台保持运行时只用低优先级，不会阻止 Mac 睡眠。")
                    .modifier(SettingsScaledFont(style: .caption))
                    .foregroundStyle(.readableSecondary)
            }
        }
        .formStyle(.grouped)
        .modifier(SettingsPageSizing(minimumContentHeight: Self.maximumDefaultHeight, page: .general))
    }

    static let maximumDefaultHeight: CGFloat = 742
}

/// 新系统自行绘制菜单选中值，需要直接给选项文字设置字号。
private struct SettingsMenuValueFont: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 27, *) {
            content.appFont(.body)
        } else {
            content
        }
    }
}
