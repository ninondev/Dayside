// SPDX-License-Identifier: GPL-3.0-only
import AppIntents
import Foundation

// 排会与计时器模块的快捷指令动作，系统按类型发现它们。

struct FindOverlapIntent: AppIntent {
    static let title: LocalizedStringResource = "查找共同空档"
    static let description = IntentDescription("按已保存地点的工作时段查找未来 7 天的共同空档。")
    static var parameterSummary: some ParameterSummary { Summary("查找 \(\.$minutes) 分钟的共同空档") }
    @Parameter(title: "时长（分钟）", default: 30) var minutes: Int

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard (15...480).contains(minutes) else { throw IntentFailure.needPlaces }
        let hub = FeatureHub.shared
        hub.attach(to: AppModel.shared)
        let core = AppModel.shared.core
        let prefs = core.settings.planner
        var participants: [OverlapPlanner.Participant] = core.zones
            .filter { !prefs.excludedZoneIDs.contains($0.id) }
            .map { zone in
                OverlapPlanner.Participant(id: zone.id, name: zone.displayName(localizedCity: core.cityName(for: zone)),
                                           timeZoneID: zone.timezoneID, availability: zone.effectiveAvailability,
                                           countryCode: zone.countryCode)
            }
        if prefs.includeLocal {
            participants.append(.init(id: UUID(), name: String(localized: "本机"), timeZoneID: TimeZone.current.identifier,
                                      availability: prefs.localAvailability, countryCode: Locale.current.region?.identifier))
        }
        participants += hub.savedPeople.map { $0.plannerParticipant(places: core.zones) }
        guard participants.count >= 2 else { throw IntentFailure.needPlaces }
        let plan = OverlapPlanner.plan(.init(participants: participants, from: .now, days: 7, durationMinutes: minutes,
                                             localTimeZoneID: TimeZone.current.identifier, toleranceMinutes: 0, limit: 3))
        let output = plan.everyone.map { window in
            participants.compactMap { person in
                TimeInput.timestamps(for: window.best, in: person.timeZone).map { "\(person.name): \($0.iso8601)" }
            }.joined(separator: "\n")
        }.joined(separator: "\n\n")
        return .result(value: output.isEmpty ? String(localized: "未来 7 天没有共同空档。") : output)
    }
}

struct StartTimerIntent: AppIntent {
    static let title: LocalizedStringResource = "开始倒计时"
    static let description = IntentDescription("在 Dayside 中开始倒计时。正在运行的计时器会保留。")
    static let supportedModes: IntentModes = .foreground
    @Parameter(title: "时长（分钟）", default: 5) var minutes: Int

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard (1...1440).contains(minutes) else { throw TimerIntentFailure.invalidDuration }
        let hub = FeatureHub.shared
        hub.attach(to: AppModel.shared)
        var spec = TimerSpec()
        spec.duration = Double(minutes * 60)
        guard hub.startTimer(spec) else {
            throw TimerIntentFailure.alreadyRunning
        }
        return .result(value: String(localized: "倒计时已开始。"))
    }
}

private enum TimerIntentFailure: Error, CustomLocalizedStringResourceConvertible {
    case invalidDuration, alreadyRunning
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .invalidDuration: "请输入 1 至 1440 分钟。"
        case .alreadyRunning: "已有计时器。请先在 Dayside 中结束它。"
        }
    }
}
