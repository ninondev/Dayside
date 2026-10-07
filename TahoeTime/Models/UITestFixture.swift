// SPDX-License-Identifier: GPL-3.0-only
#if DEBUG
import Foundation

/// Debug-only fixture behind `MEANTIME_TEST_HOST=1` + `MEANTIME_UI_TEST_FEATURE`: the real app on a
/// throwaway defaults suite, sample content on every tool page, and permission providers that never
/// prompt (calendar, contacts, notifications), so an automated audit runs without touching the user's
/// data or raising a system dialog.
@MainActor
enum UITestFixture {
    static var isActive: Bool {
        ApplicationSession.uiTestPage != nil || ApplicationSession.uiTestSurface != nil
            || (ApplicationSession.isTesting && ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_MEMORY_TOUR"] == "1")
            || (ApplicationSession.isTesting && ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_AGENDA_MENU_BAR"] == "1")
    }

    /// `MEANTIME_UI_TEST_FIXTURE=empty` audits the first-run state: no places, people or trips.
    static var isEmpty: Bool { ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_FIXTURE"] == "empty" }
    /// `MEANTIME_UI_TEST_FIXTURE=store`: the store screenshots want the planner to find something, so
    /// Tokyo sits out of the meeting (Los Angeles 9:00–10:00 is London 17:00–18:00); everything else is
    /// the default sample.
    static var isStore: Bool { ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_FIXTURE"] == "store" }
    /// `MEANTIME_UI_TEST_FIXTURE=errors`：错误态截图——地点数据里混一条认不得的时区（启动报「已备份并恢复可读部分」）、
    /// 日历权限被拒、通知权限被拒；换算页用 `MEANTIME_UI_TEST_CONVERT_TEXT` 灌一句读不出的话。
    static var isErrors: Bool { ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_FIXTURE"] == "errors" }

    static var hasLongUndo: Bool { panelFlag("MEANTIME_UI_TEST_PANEL_LONG_UNDO") }
    static var hasLongMeeting: Bool { panelFlag("MEANTIME_UI_TEST_PANEL_LONG_MEETING") }
    static var welcomeHasNoCoordinate: Bool { welcomeFlag("MEANTIME_UI_TEST_WELCOME_NO_COORDINATE") }
    static var welcomeDragged: Bool { welcomeFlag("MEANTIME_UI_TEST_WELCOME_DRAGGED") }

    private static func welcomeFlag(_ name: String) -> Bool {
        ApplicationSession.isTesting && ApplicationSession.uiTestSurface == "welcome"
            && ProcessInfo.processInfo.environment[name] == "1"
    }

    private static func panelFlag(_ name: String) -> Bool {
        ApplicationSession.isTesting && ApplicationSession.uiTestSurface == "panel"
            && ProcessInfo.processInfo.environment[name] == "1"
    }

    static func seed(_ defaults: UserDefaults) {
        var settings = Store.loadSettings(from: defaults)
        settings.hourStyle = ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_HOUR_STYLE"] == "12" ? .force12 : .force24
        if let raw = ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_HOUR_FORMAT"],
           let style = HourStyle(rawValue: raw) {
            settings.hourStyle = style
        }
        if ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_AGENDA_MENU_BAR"] == "1" {
            defaults.set(Data("{\"isEnabled\":true,\"showInMenuBar\":true,\"selectedCalendarIDs\":null,\"days\":7}".utf8), forKey: AgendaStore.preferencesKey)
        }
        // 默认展开规划区；`MEANTIME_UI_TEST_PANEL_EXPAND_AFTER=1` 时先收起，启动后再展开（拍「展开后滚进视野」）。
        settings.planner.isExpanded = ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_PANEL_EXPAND_AFTER"] != "1"
        // 截图脚本按语言拍：MEANTIME_UI_TEST_LANGUAGE=en / zhHans / ja …（InterfaceLanguage 的 rawValue），也认 BCP-47
        // 写法（zh-Hant / pt-BR）；认不出就写一行到 stdout，别静默落回系统语言（否则会把指定其他语言的截图拍成系统语言）。
        if let raw = ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_LANGUAGE"], !raw.isEmpty {
            if let language = requestedLanguage(raw) {
                settings.interfaceLanguage = language
                settings.cityLanguage = .followInterface
            } else {
                FileHandle.standardOutput.write(Data("MEANTIME_UI_TEST_LANGUAGE unknown: \(raw)\n".utf8))
            }
        }
        // 文字大小三档：`MEANTIME_UI_TEST_TEXT_SIZE=large|larger` 拍 / 审放大档。
        if let raw = ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_TEXT_SIZE"],
           let size = TextSize(rawValue: raw) {
            settings.textSize = size
        }
        // 旅行页的固定时刻：夹具给两条，转储与截图才看得到那一节的行。
        settings.fixedTimes = [
            TravelFixedTime(id: UUID(uuidString: "00000000-0000-4000-8000-00000000f001")!, label: "服药", minute: 480),
            TravelFixedTime(id: UUID(uuidString: "00000000-0000-4000-8000-00000000f002")!, label: "和家里通话", minute: 1260),
        ]
        // 面板排序：`MEANTIME_UI_TEST_PANEL_SORT=callable` 拍 / 审「现在能打给谁」那一档。
        if ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_PANEL_SORT"] == "callable" {
            settings.panelSort = .callable
        }
        // 面板底色：`MEANTIME_UI_TEST_PANEL_COLORS=system` 拍 / 审「跟着系统」那一档。
        if ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_PANEL_COLORS"] == "system" {
            settings.panelColors = .system
        }
        if ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_SETTINGS_EXPANDED"] == "1" {
            settings.panelColors = .system
            settings.useCustomColor = true
        }
        // 可选文字也进转储，避免只量默认收起的面板。
        let environment = ProcessInfo.processInfo.environment
        // 已拖动的面板夹具先落盘，再由正常打开流程决定是否显示提示。
        if ApplicationSession.isTesting, ApplicationSession.uiTestSurface == "panel",
           let raw = environment["MEANTIME_UI_TEST_PANEL_MAP_DRAGS"],
           let count = Int(raw), (0...99).contains(count) {
            settings.mapDrags = count
        }
        if let raw = environment["MEANTIME_UI_TEST_SUN_TIMES"] {
            settings.panelShowsSunTimes = raw == "1"
        }
        if let raw = environment["MEANTIME_UI_TEST_NAME_OFFSET"] {
            settings.showOffsetBesideName = raw == "1"
        }
        if let raw = environment["MEANTIME_UI_TEST_DISPLAY_MODE"], let mode = DisplayMode(rawValue: raw) {
            settings.displayMode = mode
        }
        var zones: [TimeZoneEntry] = [
            .init(timezoneID: "America/Los_Angeles", cityName: "Los Angeles", coordinate: .init(latitude: 34.05, longitude: -118.24), countryCode: "US"),
            .init(timezoneID: "Europe/London", cityName: "London", coordinate: .init(latitude: 51.51, longitude: -0.13), countryCode: "GB"),
            // 东京带 emoji 与色点：面板行与菜单栏标签都该显示「🗼 东京」，行首一个蓝点。
            .init(timezoneID: "Asia/Tokyo", cityName: "Tokyo", coordinate: .init(latitude: 35.68, longitude: 139.69), countryCode: "JP", emoji: "🗼", color: "blue")
        ]
        if hasLongUndo {
            zones[0].customName = "Los Angeles international project coordination office and overnight customer support team"
        }
        if isStore { settings.planner.excludedZoneIDs = zones.filter { $0.timezoneID == "Asia/Tokyo" }.map(\.id) }
        Store.saveSettings(settings, to: defaults)
        // 只往测试夹具的临时偏好域写坏数据，核对恢复提示。
        if isActive, ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_DST_RECOVERED"] == "1" {
            defaults.set(Data("{broken".utf8), forKey: DSTWatchStore.storageKey)
        }
        if isEmpty { return }
        if ApplicationSession.uiTestSurface == "welcome" {
            if welcomeHasNoCoordinate {
                let identifier = TimeZone.current.identifier
                let name = ZoneCatalog.shared.option(for: identifier)?.cityName ?? identifier
                Store.saveZones([TimeZoneEntry(timezoneID: identifier, cityName: name, coordinate: nil)], to: defaults)
            } else if ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_WELCOME_ADDED"] == "1" {
                let option = ZoneCatalog.shared.option(for: TimeZone.current.identifier)
                    ?? ZoneOption(identifier: TimeZone.current.identifier, coordinate: nil)
                Store.saveZones([TimeZoneEntry(timezoneID: option.identifier, cityName: option.cityName, coordinate: option.coordinate)], to: defaults)
            }
        } else {
            Store.saveZones(zones, to: defaults)
        }
        if isErrors {
            // 往已存好的 JSON 数组里塞一条 Foundation 认不得的时区：启动时整条丢弃、备份、置恢复标记（面板顶部那行提示）。
            if let data = defaults.data(forKey: "tahoetime.zones.v1"), var array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                array.append(["id": UUID().uuidString, "timezoneID": "Not/AZone", "cityName": "Nowhere"])
                if let broken = try? JSONSerialization.data(withJSONObject: array) { defaults.set(broken, forKey: "tahoetime.zones.v1") }
            }
        }
    }

    /// `zhHans` 这种 rawValue 或 `zh-Hans` / `pt-BR` 这种 BCP-47 都认。
    static func requestedLanguage(_ raw: String) -> InterfaceLanguage? {
        if let language = InterfaceLanguage(rawValue: raw) { return language }
        let folded = raw.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "").lowercased()
        return InterfaceLanguage.allCases.first { $0 != .system && $0.rawValue.lowercased() == folded }
    }

    /// Interface locale the shot asked for (`MEANTIME_UI_TEST_LANGUAGE`), else the system locale.
    static var uiLocale: Locale {
        guard let raw = ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_LANGUAGE"],
              let identifier = requestedLanguage(raw)?.localeIdentifier else { return .autoupdatingCurrent }
        return Locale(identifier: identifier)
    }

    static func makeHub(defaults: UserDefaults) -> FeatureHub {
        FeatureHub(defaults: defaults, integrateSystemSurfaces: false,
            agendaMenuBarReader: FeatureFixture.makeAgendaMenuBarReader(defaults: defaults))
    }
    /// 夹具用的通知客户端：计时器夹具也用它，所以不是 private。
    static func makeNotifications() -> LensNotificationClient { FixtureNotifications() }
}

@MainActor private final class FixtureNotifications: LensNotificationClient {
    func authorization() async -> LensNotificationAccess {
        let scenario = ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_COPY_NOTIFICATIONS"]
        return UITestFixture.isActive && (scenario == "failed" || scenario == "authorized") ? .authorized : .denied
    }
    func requestAuthorization() async throws -> Bool {
        await authorization() == .authorized
    }
    func pendingIdentifiers() async -> [String] { [] }
    func deliveredIdentifiers() async -> [String] { [] }
    func add(_ request: LensNotificationRequest) async throws {
        if UITestFixture.isActive, ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_COPY_NOTIFICATIONS"] == "failed" {
            throw FixtureNotificationFailure.scheduling
        }
    }
    func removePending(_ identifiers: [String]) {}
    func removeDelivered(_ identifiers: [String]) {}
}

private enum FixtureNotificationFailure: Error { case scheduling }

#endif
