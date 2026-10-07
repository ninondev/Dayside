// SPDX-License-Identifier: GPL-3.0-only
import AppIntents
import Foundation

// App Intents live in Dayside itself: Shortcuts and Spotlight launch the app (in the background
// when needed) and the intents read the live model. No extension process, no shared container.
// Every intent carries a parameter summary: Spotlight on macOS 26 lists an action only when its
// summary covers each required parameter without a default (WWDC25 session 260); `OpenPlaceIntent`
// (Spotlight results for the time-zone catalog) lives in SpotlightPlaceIndex.swift.

struct ConvertTimeIntent: AppIntent {
    static let title: LocalizedStringResource = "换算时间"
    static let description = IntentDescription("把包含时区的时刻换算到已保存的地点。")
    static var parameterSummary: some ParameterSummary { Summary("把 \(\.$expression) 从 \(\.$sourceTimeZone) 换算到已保存的地点") }
    @Parameter(title: "时间表达式") var expression: String
    @Parameter(title: "来源时区", default: "UTC") var sourceTimeZone: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let source = TimeZone(identifier: sourceTimeZone), expression.utf8.count <= 2048 else {
            throw IntentFailure.invalidTime
        }
        // 「听懂时间」引擎读整段，取第一处读成的（快捷指令只换算一个时刻；七月的 PST 按洛杉矶现在的钟，与换算页第一项相同）。
        let result = TimeInput.resolve(expression, relativeTo: .now, in: source)
        guard result.error == nil, !result.dates.isEmpty else { throw IntentFailure.invalidTime }
        let core = AppModel.shared.core
        let places = core.zones.map { ($0.displayName(localizedCity: core.cityName(for: $0)), $0.timeZone) }
        let targets = places.isEmpty ? [("UTC", TimeZone(identifier: "UTC")!)] : places
        let output = result.dates.map { date in
            targets.compactMap { name, zone in
                TimeInput.timestamps(for: date, in: zone).map { "\(name): \($0.iso8601)" }
            }.joined(separator: "\n")
        }.joined(separator: "\n\n")
        return .result(value: output)
    }
}

struct AddPlaceIntent: AppIntent {
    static let title: LocalizedStringResource = "添加时区地点"
    static let description = IntentDescription("把地点加入 Dayside 的时钟列表。")
    static var parameterSummary: some ParameterSummary {
        Summary("添加地点 \(\.$timeZoneID)") { \.$name }
    }
    @Parameter(title: "时区标识") var timeZoneID: String
    @Parameter(title: "名称", default: "") var name: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard TimeZone(identifier: timeZoneID) != nil, name.utf8.count <= 160,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw IntentFailure.invalidTime }
        let hub = FeatureHub.shared
        hub.attach(to: AppModel.shared)
        guard hub.handle(.init(action: "addPlace", arguments: ["timeZoneID": timeZoneID, "name": name])) else {
            throw IntentFailure.invalidTime
        }
        return .result(value: String(localized: "已添加到 Dayside。"))
    }
}

/// The tzdata self-check as a Shortcuts action, so a weekly automation can ask "is this Mac's
/// time zone data behind?" and read the same sentence the DST page shows.
struct CheckTimeZoneDataIntent: AppIntent {
    static let title: LocalizedStringResource = "检查时区数据"
    static let description = IntentDescription("核对本机时区数据是否落后于已知的时区规则变更。")
    static var parameterSummary: some ParameterSummary { Summary("检查时区数据") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let report = TZDataCheck.run()
        let version = report.version ?? String(localized: "版本未知")
        var lines: [String] = []
        if report.stale.isEmpty {
            // 与夏令时页同一对句子（结论 + 版本号与条数），合成一行：自动化里一条结果就是一行。
            lines.append([String(localized: "时区数据是最新的。"),
                          String(localized: "本机时区数据 \(version)，与截至 \(report.coverage) 的 \(report.checked) 条已知规则变更一致。数据由 macOS 提供，随系统更新。")]
                .joined(separator: " "))
        } else {
            lines.append(String(localized: "本机时区数据 \(version) 可能过期：\(report.stale.count) 条已知规则变更未反映。"))
            let core = AppModel.shared.core
            for item in report.stale {
                lines.append(String(localized: "\(core.placeName(forTimeZoneID: item.zone))：自 \(item.since) 起应为 \(TZDataCheck.offsetLabel(item.expectedMinutes))，本机数据给出 \(TZDataCheck.offsetLabel(item.observedMinutes))。"))
            }
        }
        return .result(value: lines.joined(separator: "\n"))
    }
}

struct DaysideShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ConvertTimeIntent(), phrases: ["用\(.applicationName)换算时间"], shortTitle: "换算时间", systemImageName: "arrow.left.arrow.right")
        AppShortcut(intent: FindOverlapIntent(), phrases: ["用\(.applicationName)查找共同工作时段", "用\(.applicationName)查找共同空档"], shortTitle: "共同空档", systemImageName: "person.2")
        AppShortcut(intent: AddPlaceIntent(), phrases: ["在\(.applicationName)添加地点"], shortTitle: "添加地点", systemImageName: "globe")
        AppShortcut(intent: CheckTimeZoneDataIntent(), phrases: ["用\(.applicationName)检查时区数据"], shortTitle: "检查时区数据", systemImageName: "checkmark.shield")
        AppShortcut(intent: OpenPlaceIntent(), phrases: ["在\(.applicationName)打开地点", "用\(.applicationName)打开\(\.$target)"], shortTitle: "打开地点", systemImageName: "mappin.and.ellipse")
    }
}

enum IntentFailure: Error, CustomLocalizedStringResourceConvertible {
    case invalidTime, needPlaces
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .invalidTime: "请使用明确的时间和 IANA 时区标识，例如 14:00 Europe/Paris。"
        case .needPlaces: "请先保存至少两个地点，并输入 15 至 480 分钟的时长。"
        }
    }
}
