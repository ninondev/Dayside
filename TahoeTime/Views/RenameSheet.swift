// SPDX-License-Identifier: GPL-3.0-only
//
//  RenameSheet.swift
//  TahoeTime
//
//  重命名 sheet。标准控件 + 系统文本样式;尺寸让内容自适应,不写死宽度。
//

import SwiftUI

struct RenameSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let zone: TimeZoneEntry
    @State private var name = ""
    @State private var emoji = ""
    @State private var color: ZoneColor?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("重命名").appFont(.headline)
            TextField("显示名称", text: $name)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(Text("显示名称"))
            // emoji 与色点：一个符号进菜单栏与面板标识前面；色点只在面板行画。
            HStack(spacing: 12) {
                TextField("emoji", text: $emoji)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 64)
                    .accessibilityLabel(Text("emoji"))
                    .help(Text("显示在名称前，菜单栏里也显示"))
                    .accessibilityHint(Text("显示在名称前，菜单栏里也显示"))
                    .onChange(of: emoji) { _, value in
                        if let first = value.trimmingCharacters(in: .whitespacesAndNewlines).first, String(first) != value { emoji = String(first) }
                    }
                Picker("颜色", selection: $color) {
                    Text("无").tag(Optional<ZoneColor>.none)
                    ForEach(ZoneColor.allCases) { choice in
                        Label { Text(LocalizedStringKey(choice.localizedKey)) } icon: { Image(systemName: "circle.fill").foregroundStyle(ZoneDot.color(choice)) }
                            .tag(Optional(choice))
                    }
                }
                .fixedSize()
                .help(Text("只在面板里显示为小圆点"))
                .accessibilityHint(Text("只在面板里显示为小圆点"))
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    model.rename(id: zone.id, to: name)
                    model.decorate(id: zone.id, emoji: emoji.isEmpty ? nil : emoji, color: color?.rawValue)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 300)
        .onAppear {
            name = zone.customName ?? model.cityName(for: zone)
            emoji = zone.emoji ?? ""
            color = zone.color.flatMap(ZoneColor.init(rawValue:))
        }
    }
}


/// 面板行的色点：6 pt 系统色圆点，名字给读屏。
struct ZoneDot: View {
    let name: String
    var body: some View {
        if let choice = ZoneColor(rawValue: name) {
            Circle().fill(Self.color(choice)).frame(width: 7, height: 7)
                .accessibilityLabel(Text(LocalizedStringKey(choice.localizedKey)))
        }
    }
    static func color(_ choice: ZoneColor) -> Color {
        switch choice {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        case .gray: .gray
        }
    }
}
