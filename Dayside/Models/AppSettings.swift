// SPDX-License-Identifier: GPL-3.0-only
//
//  AppSettings.swift
//  Dayside
//
//  全局设置 + 相关枚举。原生黄金法则:**所有定制都是叠在系统默认上的可选层,默认值必须让
//  成品和系统原生逐像素一致**——用户不动设置时一眼仍像系统自带。
//

import SwiftUI

/// displayMode 设成**全局**(跟 menubartime 的 UI 一致,一个开关切全部),更克制、UI 更干净。
enum DisplayMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case name, abbreviation, offset
    var id: String { rawValue }
    var localizedKey: LocalizedStringKey {
        switch self {
        case .name:         return "名称"
        case .abbreviation: return "缩写（PST/JST）"
        case .offset:       return "UTC 偏移"
        }
    }
}

/// Font.Weight 不是 Codable,用这个枚举做持久化桥接。
enum WeightOption: String, Codable, CaseIterable, Identifiable, Sendable {
    case regular, medium, semibold, bold
    var id: String { rawValue }
    var localizedKey: LocalizedStringKey {
        switch self {
        case .regular:  return "常规"
        case .medium:   return "中等"
        case .semibold: return "半粗"
        case .bold:     return "粗体"
        }
    }
    var fontWeight: Font.Weight {
        switch self {
        case .regular:  return .regular
        case .medium:   return .medium
        case .semibold: return .semibold
        case .bold:     return .bold
        }
    }
}

/// 小时制。默认跟随系统(.current locale 已反映系统"24 小时制"开关,和菜单栏时钟一致)。
enum HourStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case followSystem, force12, force24
    var id: String { rawValue }
    var localizedKey: LocalizedStringKey {
        switch self {
        case .followSystem: return "跟随系统"
        case .force12:      return "12 小时"
        case .force24:      return "24 小时"
        }
    }
}

// MARK: - Phase 3 外观定制(默认值都保持系统原生态)

/// 标识与时间之间的分隔符。默认空格 → 和现在完全一致。
enum SeparatorOption: String, Codable, CaseIterable, Identifiable, Sendable {
    case space, middleDot, pipe, enDash, comma
    var id: String { rawValue }
    /// 实际插入的字符串。
    var string: String { RustCore.invoke("settings.separator", rawValue) }
    var localizedKey: LocalizedStringKey {
        switch self {
        case .space:     return "空格"
        case .middleDot: return "间隔点 ·"
        case .pipe:      return "竖线 |"
        case .enDash:    return "短横 –"
        case .comma:     return "逗号 ,"
        }
    }
}

/// 字体设计变体(都在苹果 SF 字体家族内,改了也仍是系统字体)。`.system` 返回 nil →
/// 让视图走"不碰字体设计"的默认分支(菜单栏仍用精确的 NSFont.menuBarFont)。
enum FontDesignOption: String, Codable, CaseIterable, Identifiable, Sendable {
    case system, rounded, serif, monospaced
    var id: String { rawValue }
    var design: Font.Design? {
        switch self {
        case .system:     return nil
        case .rounded:    return .rounded
        case .serif:      return .serif
        case .monospaced: return .monospaced
        }
    }
    var localizedKey: LocalizedStringKey {
        switch self {
        // 默认的面板字是「衬线地名 + 系统字钟点」，不再是纯系统字，所以这一档叫「默认」。
        case .system:     return "默认"
        case .rounded:    return "圆角"
        case .serif:      return "衬线"
        case .monospaced: return "等宽"
        }
    }
}

/// 标识与时间的先后顺序。
enum ElementOrder: String, Codable, CaseIterable, Identifiable, Sendable {
    case nameThenTime, timeThenName
    var id: String { rawValue }
    var localizedKey: LocalizedStringKey {
        switch self {
        case .nameThenTime: return "名称在前"
        case .timeThenName: return "时间在前"
        }
    }
}

/// 面板每行里时间的对齐:右对齐成独立列(默认)/ 紧跟名称。
enum RowTimeAlignment: String, Codable, CaseIterable, Identifiable, Sendable {
    case trailing, leading
    var id: String { rawValue }
    var localizedKey: LocalizedStringKey {
        switch self {
        case .trailing: return "时间单独成列"
        case .leading:  return "紧跟名称"
        }
    }
}

// MARK: - 语言(界面语言 / 城市显示语言,两者各自独立可选)

/// 界面(操作 UI)语言。默认 `.system` = 跟随系统;其余各语言用「以语言自身名字显示」(autonym)。
/// 这只决定 UI 文案的本地化,城市名另由 CityLanguage 决定。
enum InterfaceLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    // 选单顺序按各语言的自称排：拉丁字母、西里尔字母、再日中韩。
    // 印尼语的 case 不能叫 `id`（与 `Identifiable.id` 撞名），存盘的 rawValue 仍是 "id"。
    case system, indonesian = "id", de, en, es, fr, it, nl, pl, ptBR, vi, tr, ru, ja, zhHans, zhHant, ko
    var id: String { rawValue }

    /// 对应 .lproj / Locale 的 BCP-47 标识;.system 返回 nil(跟随系统)。
    var localeIdentifier: String? { RustCore.invoke("settings.locale", ["language": rawValue]) }

    /// 选单里每种语言用它自己的名字显示(原生惯例);.system 由调用方用本地化的「跟随系统」。
    var autonym: String { RustCore.invoke("settings.autonym", ["language": rawValue]) }

    /// 「跟随系统」时实际用的界面语言：系统首选语言里第一个我们有译文的那种；一个都没有
    /// （意大利语、荷兰语……）就用英文。地区与其他格式偏好照旧跟系统（日期写法、周首日不变），只换查表用的语言。
    /// 此前直接拿系统 locale 查表：SwiftUI 找不到意大利语就退回键本身，而键是中文原文，于是整个界面中英混排。
    /// 与系统语言一致时原样返回 `current`（德语、瑞士德语、繁体中文用户的行为与从前逐字相同）。
    static func systemLocale(preferred: [String] = Locale.preferredLanguages, current: Locale = .autoupdatingCurrent,
                             available: [String] = Bundle.main.localizations) -> Locale {
        let key = "\(current.identifier)|\(preferred.joined(separator: ","))|\(available.count)"
        if let hit = SystemLocaleCache.lookup(key) { return hit }
        let resolved = resolveSystemLocale(preferred: preferred, current: current, available: available)
        SystemLocaleCache.store(key, resolved)
        return resolved
    }

    private static func resolveSystemLocale(preferred: [String], current: Locale, available: [String]) -> Locale {
        let supported = available.filter { $0 != "Base" }
        let script = { (language: Locale.Language) in Locale.Language(identifier: language.maximalIdentifier).script }
        for identifier in preferred {
            guard let match = Bundle.preferredLocalizations(from: supported, forPreferences: [identifier]).first else { continue }
            let wanted = Locale.Language(identifier: identifier), got = Locale.Language(identifier: match)
            // 真是这种语言（葡萄牙的 pt-PT 配到 pt-BR 算；Foundation 找不到时塞回来的别的语言不算）。
            guard wanted.languageCode == got.languageCode else { continue }
            let sameAsCurrent = current.language.languageCode == got.languageCode && script(current.language) == script(got)
                && (got.region == nil || got.region == current.language.region)
            return sameAsCurrent ? current : Self.locale(language: match, keepingFormatsOf: current)
        }
        let english = Locale.Language(identifier: "en")
        return current.language.languageCode == english.languageCode ? current : Self.locale(language: "en", keepingFormatsOf: current)
    }

    private static func locale(language: String, keepingFormatsOf current: Locale) -> Locale {
        var components = Locale.Components(locale: current)
        components.languageComponents = Locale.Language.Components(identifier: language)
        if components.region == nil, let region = current.region { components.region = region }
        return Locale(components: components)
    }
}

/// `InterfaceLanguage.systemLocale` 的结果缓存：界面每帧都读 `uiLocale`，匹配只在系统语言或地区变了时重算。
private enum SystemLocaleCache {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var entry: (key: String, locale: Locale)?
    static func lookup(_ key: String) -> Locale? {
        lock.lock(); defer { lock.unlock() }
        return entry?.key == key ? entry?.locale : nil
    }
    static func store(_ key: String, _ locale: Locale) {
        lock.lock(); entry = (key, locale); lock.unlock()
    }
}

/// 城市显示语言。默认 `.followInterface` = 和界面语言一致(开箱两者统一,但可各自改)。
/// `.system` = 跟随系统;其余为指定语言。城市名取自系统 ICU(见 LocalizedZoneNames)。
enum CityLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    /// `.none` = 不本地化,显示原始英文 / IANA 名(如 "Tokyo"),区别于走 ICU 英文的 `.en`。
    case followInterface, system, none, indonesian = "id", de, en, es, fr, it, nl, pl, ptBR, vi, tr, ru, ja, zhHans, zhHant, ko
    var id: String { rawValue }

    /// 指定语言的 BCP-47 标识;`.followInterface` / `.system` / `.none` 返回 nil(由 AppModel 解析)。
    var localeIdentifier: String? { RustCore.invoke("settings.locale", ["language": rawValue]) }

    var autonym: String { RustCore.invoke("settings.autonym", ["language": rawValue]) }
}

/// 文字大小。
/// macOS 不支持 Dynamic Type（Apple HIG 明写「macOS doesn't support Dynamic Type」，`.dynamicTypeSize`
/// 在 macOS 的 SwiftUI 上实测无效），所以这里自己按倍数换字号。这是默认使用语义字号的
/// 唯一例外，只作用在我们自己的窗口与面板上，菜单栏标签仍由系统托管。
enum TextSize: String, Codable, CaseIterable, Identifiable, Sendable {
    case standard, large, larger
    var id: String { rawValue }
    /// 1.0 时走系统的语义字号（`.appFont(.caption)` 那一套），逐像素与从前相同。
    var scale: Double {
        switch self {
        case .standard: return 1.0
        case .large:    return 1.15
        case .larger:   return 1.3
        }
    }
    var localizedKey: LocalizedStringKey {
        switch self {
        case .standard: return "标准"
        case .large:    return "大"
        case .larger:   return "更大"
        }
    }
}

/// 面板地点列表的排序。
enum PanelSort: String, Codable, CaseIterable, Identifiable, Sendable {
    /// 用户自己拖出来的顺序。
    case manual
    /// 现在能打电话的排前面（当地工作时段内），按还剩多久从少到多；其余按还要多久能打排。
    case callable
    var id: String { rawValue }
    var localizedKey: LocalizedStringKey {
        switch self {
        case .manual:   return "手动顺序"
        case .callable: return "现在能打给谁"
        }
    }
}

/// CallBasis 本体在 TimeZoneEntry.swift；选单文案放这边，与 PanelSort 等枚举同一做法（LocalizedStringKey 要 SwiftUI）。
extension CallBasis {
    var localizedKey: LocalizedStringKey {
        switch self {
        case .work:  "上班时段"
        case .awake: "醒着时段"
        }
    }
}

/// 例会轮换偏好逐字段校验，坏字段独立恢复默认。
struct RotationPreferences: Codable, Equatable, Sendable {
    /// Calendar 编号 1–7(1 = 周日);nil = 参考日起第一个工作日,由视图按本机日历现算,所以不存默认星期。
    var weekday: Int?
    var count: Int
    var intervalWeeks: Int
    /// 单次最多让一个人在时段外多少分钟。
    var maxStretchMinutes: Int
    var split: String
    var clockWeight: String
    static let countChoices: [Int] = CoreConstants.value["rotationCountChoices"].decode()
    static let stretchChoices: [Int] = CoreConstants.value["rotationStretchChoices"].decode()
    enum CodingKeys: String, CodingKey { case weekday, count, intervalWeeks, maxStretchMinutes, split, clockWeight }
    init() { self.init(normalized: RustCore.invoke("settings.rotation", CoreJSON.object([:]))) }
    init(from decoder: Decoder) throws {
        _ = try decoder.container(keyedBy: CodingKeys.self)
        self.init(normalized: RustCore.invoke("settings.rotation", try CoreJSON(from: decoder)))
    }
    private init(normalized: CoreJSON) {
        weekday = normalized["weekday"].decode()
        count = normalized["count"].decode()
        intervalWeeks = normalized["intervalWeeks"].decode()
        maxStretchMinutes = normalized["maxStretchMinutes"].decode()
        split = normalized["split"].decode()
        clockWeight = normalized["clockWeight"].decode()
    }
}

/// 理想时段：本机墙钟 [startMinute, endMinute)，可跨午夜；规则在 Rust `settings.ideal_window`。
struct IdealWindow: Codable, Hashable, Sendable {
    var startMinute: Int
    var endMinute: Int
    /// 封闭的预设（分钟）：早上 8–11、上午 9–12、下午 13–16、傍晚 16–19；自定义走两个时间选择器。
    static let presets: [IdealWindow] = [.init(startMinute: 480, endMinute: 660), .init(startMinute: 540, endMinute: 720),
                                          .init(startMinute: 780, endMinute: 960), .init(startMinute: 960, endMinute: 1140)]
}

/// 排会「常用组合」：一组参与者（地点 id + 人物 id）加该组的理想时段；规则在 Rust `settings.planner_groups`。
struct PlannerGroup: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var zoneIDs: [UUID]
    var personIDs: [UUID]
    var idealWindow: IdealWindow?
}

/// 重叠规划器的偏好。整体是 AppSettings 的一个子结构,宽容解码同教义。
struct PlannerPreferences: Codable, Equatable, Sendable {
    var durationMinutes: Int
    var daysAhead: Int
    var localAvailability: Availability
    var includeLocal: Bool
    var excludedZoneIDs: [UUID]
    var isExpanded: Bool
    var rotation: RotationPreferences
    var idealWindow: IdealWindow?
    var groups: [PlannerGroup]
    static let durationChoices: [Int] = CoreConstants.value["durationChoices"].decode()
    static let daysChoices: [Int] = CoreConstants.value["daysChoices"].decode()
    enum CodingKeys: String, CodingKey { case durationMinutes, daysAhead, localAvailability, includeLocal, excludedZoneIDs, isExpanded, rotation, idealWindow, groups }
    init() { self.init(normalized: RustCore.invoke("settings.planner", CoreJSON.object([:]))) }
    init(from decoder: Decoder) throws {
        _ = try decoder.container(keyedBy: CodingKeys.self)
        self.init(normalized: RustCore.invoke("settings.planner", try CoreJSON(from: decoder)))
    }
    private init(normalized: CoreJSON) {
        durationMinutes = normalized["durationMinutes"].decode()
        daysAhead = normalized["daysAhead"].decode()
        localAvailability = normalized["localAvailability"].decode()
        includeLocal = normalized["includeLocal"].decode()
        excludedZoneIDs = normalized["excludedZoneIDs"].decode()
        isExpanded = normalized["isExpanded"].decode()
        rotation = normalized["rotation"].decode()
        idealWindow = normalized["idealWindow"] == .null ? nil : normalized["idealWindow"].decode()
        groups = normalized["groups"].decode()
    }
}

nonisolated enum CoreConstants {
    static let value: CoreJSON = RustCore.invoke("settings.constants", CoreJSON.object([:]))
}

/// 喂给时间格式化的最小配置。和 AppSettings 解耦,方便复用。
struct ClockFormat: Equatable, Sendable {
    var hourStyle: HourStyle
    var showSeconds: Bool
}

/// 全局设置,整体序列化。
/// 全局快捷键。`keyCode` 是 macOS 的虚拟键码（与键盘布局无关），
/// `modifiers` 是我们自己的位掩码（1 ⌘ / 2 ⌥ / 4 ⌃ / 8 ⇧，Rust `hotkey` 模块定），
/// 合法性与写法都由 Rust 决定，Swift 只负责注册与录制。
struct HotkeySetting: Codable, Hashable, Sendable {
    var enabled: Bool
    var keyCode: Int
    var modifiers: Int
    /// 组合的写法，例如 ⌥⌘T。
    var label: String {
        struct Input: Encodable { let keyCode: Int; let modifiers: Int }
        return RustCore.invoke("hotkey.label", Input(keyCode: keyCode, modifiers: modifiers))
    }
}

/// 面板的框（搜索栏、说明行、滑块、底栏）的颜色。
/// 每行涂的是那个地方此刻的天，两种都一样；这里只管外面那一圈。
enum PanelColors: String, Codable, CaseIterable, Identifiable, Sendable {
    /// 框涂这里此刻的天顶：白天是纸、夜里是墨、晨昏时有颜色；字用墨或纸，系统控件跟着换浅深。
    case sky
    /// 框跟系统的浅色 / 深色与面板的玻璃材质；行里的天色缩成一条色带。
    case system
    var id: String { rawValue }
    var localizedKey: LocalizedStringKey {
        switch self {
        case .sky:    return "跟着天色"
        case .system: return "跟着系统"
        }
    }
}

struct AppSettings: Codable, Sendable, Equatable {
    var displayMode: DisplayMode
    var hourStyle: HourStyle
    var showSeconds: Bool
    /// 面板行的名称旁附一个 UTC 偏移（调研 #9）。与「显示内容」三选一互补：选名称时也能看见偏移。
    /// 默认关（默认外观逐像素不变）；菜单栏标签不受它影响（那里有宽度预算）。
    var showOffsetBesideName: Bool
    var weight: WeightOption
    var menuBarMaxZones: Int
    var separator: SeparatorOption
    var fontDesign: FontDesignOption
    var useCustomColor: Bool
    var customColor: CodableColor?
    var elementOrder: ElementOrder
    var rowTimeAlignment: RowTimeAlignment
    var panelSort: PanelSort
    /// 醒着时段（判定基准 .awake 的那些行用的全局窗口，每天生效）。默认 08:00–22:00 与逐字段校验在 Rust `settings::awake_window`。
    var awakeWindow: Availability
    /// 面板的框跟着天色还是跟着系统。
    var panelColors: PanelColors
    /// 面板顶上的昼夜地图。
    var panelShowsMap: Bool
    /// 面板行的日出日落时间（默认关：昼夜条已经画出昼夜）。太阳弧模式不受它管。
    var panelShowsSunTimes: Bool
    var textSize: TextSize
    var interfaceLanguage: InterfaceLanguage
    var cityLanguage: CityLanguage
    var keepAliveInBackground: Bool
    var launchAtLogin: Bool
    var didAskLaunchAtLogin: Bool
    /// 首次启动的欢迎页只出一次。
    var didShowWelcome: Bool
    /// 拖完过的地图拖动次数：到 3 次后拖动中不再带方向提示。校验在 Rust，0…99。
    var mapDrags: Int
    /// 亮过「地图也能拖」的面板打开次数：前 5 次里还没拖过才亮。校验在 Rust，0…99。
    var mapHintOpens: Int
    var planner: PlannerPreferences
    var hotkey: HotkeySetting
    /// 旅行页的「固定时刻」：每天固定要做的事，只做换算、不给建议。
    var fixedTimes: [TravelFixedTime]
    var clockFormat: ClockFormat { ClockFormat(hourStyle: hourStyle, showSeconds: showSeconds) }
    enum CodingKeys: String, CodingKey {
        case displayMode, hourStyle, showSeconds, showOffsetBesideName, weight, menuBarMaxZones, separator, fontDesign, useCustomColor, customColor, elementOrder, rowTimeAlignment, panelSort, awakeWindow, panelColors, panelShowsMap, panelShowsSunTimes, textSize, interfaceLanguage, cityLanguage, keepAliveInBackground, launchAtLogin, didAskLaunchAtLogin, didShowWelcome, mapDrags, mapHintOpens, planner, hotkey, fixedTimes
    }
    init() { self.init(normalized: RustCore.invoke("settings.normalize", CoreJSON.object([:]))) }
    init(from decoder: Decoder) throws {
        _ = try decoder.container(keyedBy: CodingKeys.self)
        self.init(normalized: RustCore.invoke("settings.normalize", try CoreJSON(from: decoder)))
    }
    private init(normalized: CoreJSON) {
        displayMode = normalized["displayMode"].decode()
        hourStyle = normalized["hourStyle"].decode()
        showSeconds = normalized["showSeconds"].decode()
        showOffsetBesideName = normalized["showOffsetBesideName"].decode()
        weight = normalized["weight"].decode()
        menuBarMaxZones = normalized["menuBarMaxZones"].decode()
        separator = normalized["separator"].decode()
        fontDesign = normalized["fontDesign"].decode()
        useCustomColor = normalized["useCustomColor"].decode()
        customColor = normalized["customColor"].decode()
        elementOrder = normalized["elementOrder"].decode()
        rowTimeAlignment = normalized["rowTimeAlignment"].decode()
        panelSort = normalized["panelSort"].decode()
        awakeWindow = normalized["awakeWindow"].decode()
        panelColors = normalized["panelColors"].decode()
        panelShowsMap = normalized["panelShowsMap"].decode()
        panelShowsSunTimes = normalized["panelShowsSunTimes"].decode()
        textSize = normalized["textSize"].decode()
        interfaceLanguage = normalized["interfaceLanguage"].decode()
        cityLanguage = normalized["cityLanguage"].decode()
        keepAliveInBackground = normalized["keepAliveInBackground"].decode()
        launchAtLogin = normalized["launchAtLogin"].decode()
        didAskLaunchAtLogin = normalized["didAskLaunchAtLogin"].decode()
        didShowWelcome = normalized["didShowWelcome"].decode()
        mapDrags = normalized["mapDrags"].decode()
        mapHintOpens = normalized["mapHintOpens"].decode()
        planner = normalized["planner"].decode()
        hotkey = normalized["hotkey"].decode()
        fixedTimes = normalized["fixedTimes"].decode()
    }
}
