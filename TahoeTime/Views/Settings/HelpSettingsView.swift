// SPDX-License-Identifier: GPL-3.0-only
//
//  HelpSettingsView.swift
//  TahoeTime
//
//  设置的「帮助」页：扉页、诊断、小技巧与数据来源。
//

import SwiftUI

/// 支持页地址。定了公开地址只改这一处；`grep -rn SUPPORT-URL-PLACEHOLDER` 能把所有要填的地方一起找出来。
enum SupportLinks {
    static let placeholderHost = "SUPPORT-URL-PLACEHOLDER"
    static let supportURL = URL(string: "https://\(placeholderHost)/support.html")!
    static var isPlaceholder: Bool { supportURL.host() == placeholderHost }
    /// 帮助页真正显示的地址：占位时为 nil，链接行与脚注里「见支持页面」一起不出现（
    /// 不可点的淡蓝字把人引向一个不存在的域名）。地址一到，这里非 nil，两处自动恢复。判断只写在这一处。
    static var published: URL? { isPlaceholder ? nil : supportURL }
}

struct HelpSettingsView: View {
    @Environment(\.locale) private var locale
    @Environment(\.textScale) private var textScale
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Form {
            DiagnosticsSettingsSection {
                VStack(spacing: 0) {
                    WorldMapView(latitudes: WorldMapScene.helpHeader, cornerRadius: 6)
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(contrast == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary.opacity(0.9)),
                                              lineWidth: contrast == .increased ? 1 : 0.75)
                        }
                        .accessibilityRemoveTraits(.isHeader)
                    Text("时差不差")
                        .font(.system(size: 20 * textScale, weight: .medium))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 12)
                    Text(verbatim: "Dayside \(Self.versionText)")
                        .appFont(.caption)
                        .foregroundStyle(.readableSecondary)
                        .textSelection(.enabled)
                        .accessibilityLabel(Text(verbatim: String(format: L10n.string("Dayside，版本%@", locale: locale), Self.versionText)))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                    Text("反馈与诊断")
                        .appFont(.headline, weight: .semibold)
                        .accessibilityAddTraits(.isHeader)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 22)
                }
            }
            GuideSettingsSection()
            FAQSettingsSection()
        }
        .formStyle(.grouped)
        .modifier(SettingsPageSizing(minimumContentHeight: Self.maximumDefaultHeight, page: .help))
    }

    static let maximumDefaultHeight: CGFloat = 769

    static var versionText: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\((info["CFBundleShortVersionString"] as? String) ?? "?") (\((info["CFBundleVersion"] as? String) ?? "?"))"
    }
}

/// 反馈与诊断:零遥测。导出的是纯文本诊断包(状态、时区数据自检、脱敏后的设置、App 自己的日志),用户看过再发。
struct DiagnosticsSettingsSection<Header: View>: View {
    @ViewBuilder let header: () -> Header
    @Environment(AppModel.self) private var model
    @Environment(\.textScale) private var textScale
    @State private var busy = false
    @State private var notice: Notice?

    private enum Notice { case saved, copied }

    @ViewBuilder private var diagnosticsButtons: some View {
        Button { Task { await export() } } label: {
            Text("导出诊断包…").modifier(SettingsScaledFont(style: .body))
        }.fixedSize()
        Button { Task { await copySummary() } } label: {
            Text("复制诊断摘要").modifier(SettingsScaledFont(style: .body))
        }.fixedSize()
    }

    var body: some View {
        Section {
            // 两个按钮并排放不下时改成上下两个，文字完整显示。
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { diagnosticsButtons }
                VStack(alignment: .leading, spacing: 8) { diagnosticsButtons }
            }
            .controlSize(textScale == 1 ? .regular : textScale < 1.3 ? .large : .extraLarge)
            .disabled(busy)
            if let notice {
                switch notice {
                case .saved: Label("已保存诊断包。", systemImage: "checkmark.circle").foregroundStyle(.readableSecondary)
                case .copied: Label("已复制", systemImage: "checkmark.circle").foregroundStyle(.readableSecondary)
                }
            }
            // 联系方式在支持页；地址定下来之前这一行不出现（`SupportLinks.published`）。
            if let url = SupportLinks.published {
                Link("支持页面", destination: url)
                    .accessibilityIdentifier("settings-support-link")
            }
        } header: {
            header()
        } footer: {
            Text("诊断包是纯文本，只有本机与 Dayside 的状态和日志，不含日历与联系人；Dayside 不会自动上传任何内容。")
                .modifier(SettingsScaledFont(style: .caption)).foregroundStyle(.readableSecondary)
        }
        .accessibilityIdentifier("settings-diagnostics")
    }

    private func export() async {
        busy = true
        defer { busy = false }
        let text = await DiagnosticsReport.text(model: model, hub: FeatureHub.shared, summary: false)
        notice = DiagnosticsReport.save(text) ? .saved : nil
    }

    private func copySummary() async {
        busy = true
        defer { busy = false }
        DiagnosticsReport.copy(await DiagnosticsReport.text(model: model, hub: FeatureHub.shared, summary: true))
        notice = .copied
    }
}

/// 不常见的入口收在最后一组。
struct FAQSettingsSection: View {
    @State private var showsMissing = false
    @State private var showsSources = false

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: $showsMissing) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("1. 打开「系统设置 › 菜单栏」，在「允许在菜单栏显示」里找到 Dayside，把它打开。macOS 26 允许逐个 App 关掉菜单栏项，关掉后 App 仍在运行。")
                    Text("2. 如果装了 Bartender、Ice 这类菜单栏管理工具，它可能把 Dayside 收进了隐藏区：在那个工具里把 Dayside 移回可见区。")
                    Text("3. 菜单栏太挤时，Dayside 会先只显示时间、再从尾部省略；挤到没有位置时由 macOS 决定隐藏哪个图标。关掉几个别的菜单栏项，或在“外观”里少显示几个地点。")
                    Text("三步都试过还是不见，用上面的「导出诊断包…」，里面有菜单栏驻留的事件记录。")
                        .appFont(.caption).foregroundStyle(.readableSecondary)
                }.appFont(.callout)
            } label: { Text("菜单栏里的 Dayside 不见了").frame(minHeight: 22) }
            .accessibilityIdentifier("settings-faq-menu-bar")
            DisclosureGroup(isExpanded: $showsSources) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("城市数据来自 GeoNames（geonames.org），按 CC BY 4.0 许可使用；各语言的地名写法部分来自 Wikidata（CC0）。")
                    Text("昼夜地图的海陆与地形来自 Natural Earth（公有领域）。")
                    Text("题记「天涯共此时」出自张九龄《望月怀远》，「It is always sunrise somewhere.」出自 John Muir《John of the Mountains》（1938）。")
                }.appFont(.caption).foregroundStyle(.readableSecondary).padding(.top, 4)
            } label: { Text("数据来源").frame(minHeight: 22) }
        }
        #if DEBUG
        .onAppear {
            guard ApplicationSession.isTesting,
                  ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_HELP_EXPANDED"] == "1" else { return }
            showsMissing = true
            showsSources = true
        }
        #endif
    }
}

struct GuideSettingsSection: View {
    var body: some View {
        Section {
            tip("右键点面板里的地点，直达太阳与月亮、换算和找碰头时间。", symbol: "contextualmenu.and.cursorarrow")
            tip("连按两次面板里的地图打开地球窗；全屏后可以放在副屏上当桌钟。", symbol: "arrow.up.left.and.arrow.down.right")
            tip("右键点地图，把这一刻拷贝成一张图发给别人。", symbol: "photo.on.rectangle")
        } header: { Text("小技巧").modifier(SettingsScaledFont(style: .headline)) }
    }

    private func tip(_ text: LocalizedStringKey, symbol: String) -> some View {
        Label { Text(text) } icon: {
            Image(systemName: symbol).foregroundStyle(.tint).frame(width: 20)
        }
    }
}
