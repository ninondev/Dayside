// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// 一个功能模块：一页工具窗、它的 store 生命周期、它要接的宿主事件。宿主通过协议按需转发。
@MainActor
protocol FeatureModule: AnyObject {
    var feature: DaysideFeature { get }
    var activeResourceCount: Int { get }
    func activate()
    /// 宿主装好后调一次（拿 `AppModel`、装回调）。
    func attach(hub: FeatureHub, model: AppModel)
    /// 地点、语言或设置变了（`FeatureHub.refreshSnapshot`）。
    func placesDidChange(model: AppModel)
    /// 系统时区换了。
    func systemTimeZoneDidChange(to identifier: String, model: AppModel)
    /// 宿主时钟到了下一分钟（或系统时钟 / 时区变了）。
    func clockDidChange(now: Date)
    /// 工具窗开关、选中页变了。
    func setVisible(_ visible: Bool, selected: Bool)
    /// 自动化命令（URL / 快捷指令）：归它管就处理并回结果，不归它管回 nil。
    func handle(_ command: AutomationCommand, hub: FeatureHub, model: AppModel) -> Bool?
    /// 工具窗里这一页。
    func page(hub: FeatureHub) -> AnyView
    /// 页面自带滚动容器（人物页的列表、旅行页的分组表单）就不套 `FeatureWorkspaceView.page`。
    var pageIsSelfScrolling: Bool { get }
}

extension FeatureModule {
    var activeResourceCount: Int { 0 }
    func activate() {}
    func attach(hub: FeatureHub, model: AppModel) {}
    func placesDidChange(model: AppModel) {}
    func systemTimeZoneDidChange(to identifier: String, model: AppModel) {}
    func clockDidChange(now: Date) {}
    func setVisible(_ visible: Bool, selected: Bool) {}
    func handle(_ command: AutomationCommand, hub: FeatureHub, model: AppModel) -> Bool? { nil }
    var pageIsSelfScrolling: Bool { false }
}

/// 模块按需提供面板与菜单栏的内容。

/// 下一场会议（日历模块）：面板底栏那一行与菜单栏的「◷ 12 min」。
struct UpcomingMeeting: Equatable, Sendable {
    let title: String
    let start: Date
    let isOngoing: Bool
    let minutesUntilStart: UInt64
}
@MainActor
protocol NextMeetingProviding: AnyObject {
    func nextMeeting(now: Date) -> UpcomingMeeting?
    func menuBarMeeting(now: Date) -> UpcomingMeeting?
}

/// 已保存人物的所在地（人物模块）：分享页与首启建议地点用。
struct PersonPlace: Equatable, Sendable {
    let name: String
    let timeZoneID: String
    let countryCode: String?
}
@MainActor
protocol PeoplePlacesProviding: AnyObject {
    var peoplePlaces: [PersonPlace] { get }
}

/// 面板里的一节（排会模块的「找碰头时间」折叠区）。
@MainActor
protocol PanelSectionProviding: AnyObject {
    func panelSection() -> AnyView
}

