// SPDX-License-Identifier: GPL-3.0-only
//
//  AvailabilityEditor.swift
//  Dayside
//
//  某个地点的可约时段编辑器(popover):开始 / 结束时刻用系统 DatePicker 的 hourAndMinute,
//  「只算工作日」开关下面写明该地哪几天算周末(来自 ICU 的地区数据),一个「恢复默认」按钮。
//  编辑的是墙钟分钟,不是绝对时刻:DatePicker 只是输入控件,日期部分无意义,用固定的参照日。
//

import SwiftUI

struct AvailabilityEditor: View {
    @Environment(\.locale) private var locale
    let title: String
    let timeZone: TimeZone
    let countryCode: String?
    @Binding var availability: Availability

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: title).appFont(.headline)
            Grid(alignment: .leading, verticalSpacing: 8) {
                GridRow {
                    Text("开始")
                    DatePicker("开始", selection: minuteBinding(\.startMinute), displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .environment(\.timeZone, Self.editingZone)
                }
                GridRow {
                    Text("结束")
                    HStack {
                        DatePicker("结束", selection: minuteBinding(\.endMinute), displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .environment(\.timeZone, Self.editingZone)
                            .accessibilityLabel(endLabel)
                        if availability.crossesMidnight { Text("次日").accessibilityHidden(true) }
                        else if availability.isWholeDay { Text("全天").accessibilityHidden(true) }
                    }
                }
            }
            // popover 是另一个呈现根，勾选框样式要再指定一次。
            Toggle("只算工作日", isOn: $availability.weekdaysOnly).toggleStyle(.checkbox)
            Text("周末：\(weekendDescription)")
                .appFont(.caption)
                .foregroundStyle(.readableSecondary)
            HStack {
                Spacer()
                Button("恢复默认") { availability = .standard }
                    .disabled(availability == .standard)
            }
        }
        .padding()
        .frame(minWidth: 260)
    }

    /// 输入用的固定时区(UTC):DatePicker 的日期部分不参与语义,选 UTC 免掉夏令时空洞。
    private static let editingZone = TimeZone(identifier: "UTC")!

    private var endLabel: Text {
        let marker = availability.crossesMidnight ? "次日" : availability.isWholeDay ? "全天" : nil
        let words = [L10n.string("结束", locale: locale)] + (marker.map { [L10n.string($0, locale: locale)] } ?? [])
        return Text(verbatim: words.joined(separator: ", "))
    }

    private func minuteBinding(_ keyPath: WritableKeyPath<Availability, Int>) -> Binding<Date> {
        Binding(
            get: { Date(timeIntervalSince1970: PresentationCore.scalar("availability_date", ["minute": Double(availability[keyPath: keyPath])])) },
            set: { date in
                availability[keyPath: keyPath] = PresentationCore.call("availability_minute", ["date": date.timeIntervalSince1970])
            }
        )
    }

    /// 该地按 ICU 数据算作周末的星期,按当前界面语言写(「周五、周六」)。
    private var weekendDescription: String {
        Self.weekendDescription(timeZone: timeZone, countryCode: countryCode, locale: locale)
    }

    static func weekendDescription(timeZone: TimeZone, countryCode: String?, locale: Locale) -> String {
        let cal = OverlapPlanner.calendar(for: timeZone, countryCode: countryCode)
        // 在参与者所在地取完整一周的正午;判断和显示必须使用同一时区。
        let base = cal.date(from: DateComponents(year: 2026, month: 1, day: 5, hour: 12))!
        let days = (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: base) }
        let indices: [Int] = PresentationCore.call("weekend_indices", ["weekend": days.map(cal.isDateInWeekend)])
        // 句子里列举星期写全称；短写只用在日期标签上。
        let formatter = Date.FormatStyle(locale: locale, timeZone: timeZone).weekday(.wide)
        let names = indices.map { days[$0].formatted(formatter) }
        let list = ListFormatter()
        list.locale = locale
        return list.string(from: names) ?? names.joined(separator: ", ")
    }
}
