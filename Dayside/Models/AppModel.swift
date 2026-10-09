// SPDX-License-Identifier: GPL-3.0-only
//
//  AppModel.swift
//  Dayside
//
//  应用状态的**写侧**与协调器。@Observable @MainActor:Tahoe 原生写法,视图自动观察。
//  只读状态(now / 偏移 / 条目 / 设置 / 系统版本号 / 命名)住在 `TimeCore`。
//  面板各行、菜单栏标签与透镜只依赖 TimeCore;本类保留同名转发属性,
//  写操作(增删改、跳转、面板可见性、持久化、设置副作用分发)全在这里。
//  时钟用 async 循环(Task + Task.sleep)推进,**不用 Timer**(避开 Swift 6 strict
//  concurrency 下 Timer 回调的 Sendable 报错)。
//

import AppKit
import Observation
import Security
import ServiceManagement
import SwiftUI

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel(defaults: ApplicationSession.defaults, migrate: !ApplicationSession.isIsolated,
                                 applySystemIntegration: !ApplicationSession.isTesting)
    /// 只读时间核。视图经环境注入直接读它;本类是它唯一的写者。
    let core: TimeCore

    @ObservationIgnored var onDataChange: (() -> Void)?
    @ObservationIgnored var onSystemChange: (() -> Void)?
    @ObservationIgnored private var spotlightSession: SpotlightIndexSession?

    /// 生产从菜单栏就绪入口安装；测试可安装自己的假索引。
    func startSpotlightIndexing(session: SpotlightIndexSession? = nil,
                                startupDelay: Duration = SpotlightPlaceIndex.startupDelay) {
        guard spotlightSession == nil else { return }
        let session = session ?? SpotlightIndexSession(backend: CoreSpotlightBackend())
        spotlightSession = session
        session.start(seed: SpotlightPlaceIndex.seed(model: self), delay: startupDelay)
    }

    private func updateSpotlightPlaces() {
        spotlightSession?.savedPlacesChanged(seed: SpotlightPlaceIndex.seed(model: self))
    }

    /// 当前时刻(转发 TimeCore)。仅在面板打开时推进。
    var now: Date {
        get { core.now }
        set { core.now = newValue }
    }

    /// Time Scroller 滑块的偏移分量(秒),量程恒 ±24h,**滑块直接绑这个**(每帧平滑跟手)。
    /// 总偏移 = `jumpAnchor + scrollOffset`;0/0 = 实时。**不持久化**:scrub 是瞬态查看手势,
    /// 启动一律回到实时。
    var scrollOffset: TimeInterval = 0 {
        didSet { throttleDisplay() }
    }

    /// 日期选择器的"锚点"分量(秒):跳到任意日期时写这里,滑块只在锚点 ±24h 内微调。
    /// 旧实现让滑块直接改写整个偏移——跳到 +96h 后指尖一碰滑块,SwiftUI 立刻把绑定值
    /// 拉回滑块量程内,远日期被无声吞掉;分量分解后两个控件各管各的,互不覆盖。
    private(set) var jumpAnchor: TimeInterval = 0

    /// 面板行 / 太阳弧实际读的偏移(转发 TimeCore),**经节流(≤~30Hz)**。
    private(set) var displayOffset: TimeInterval {
        get { core.displayOffset }
        set { core.displayOffset = newValue }
    }

    // 节流句柄(@ObservationIgnored:非 UI 状态,免追踪)。
    @ObservationIgnored private var displayThrottleTask: Task<Void, Never>?

    /// 把 displayOffset 节流到 ~30Hz:已有挂起更新就合并,否则 33ms 后追上最新总偏移。
    private func throttleDisplay() {
        guard displayThrottleTask == nil else { return }
        displayThrottleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(33))
            if let self { self.applyScrub("flush") }
            self?.displayThrottleTask = nil
        }
    }

    /// 面板里所有时区行读这个;= now + 节流后的偏移。
    var referenceDate: Date { core.referenceDate }

    /// 是否处于穿梭(非实时)状态。
    var isScrubbing: Bool { core.isScrubbing }

    // MARK: - 语言与命名(转发 TimeCore)

    var uiLocale: Locale { core.uiLocale }
    var cityLocale: Locale { core.cityLocale }
    var citySearchLocale: Locale? { core.citySearchLocale }
    func cityName(for entry: TimeZoneEntry) -> String { core.cityName(for: entry) }
    func displayName(for option: ZoneOption) -> String { core.displayName(for: option) }
    func localizedCity(_ entry: TimeZoneEntry) -> String { core.localizedCity(entry) }

    /// 时区条目(转发 TimeCore)。对外只读;增删改一律走下面的方法,方法内**显式持久化**
    /// (显式 > 依赖 didSet 的隐式持久化,数据落盘点清晰可审计)。
    private(set) var zones: [TimeZoneEntry] {
        get { core.zones }
        set { core.zones = newValue }
    }

    /// 面板地点列表的显示顺序。手动就是用户自己拖出来的顺序；「现在能打给谁」
    /// 由宿主在各地时区里算准「还剩多久下班 / 还要多久上班」，再交 Rust `availability.callable_order` 排。
    /// 每分钟只算一次（显示秒时每秒都算会让整张表每秒重建）。
    struct PanelOrder {
        var zones: [TimeZoneEntry]
        var callableCount: Int
        var nextZone: TimeZoneEntry?
        var nextInMinutes: Int?
    }

    /// 面板「复制全部各地时间」（调研 #11）：按面板**此刻的顺序**与**此刻显示的时刻**
    /// （穿梭到别的时间就复制那个时间）拼成一行，与换算页的「复制成一行」同一个出口
    /// （`TimeInput.pasteLine`），所以跨日会带日期、小时制跟设置走。返回复制的文本，空表返回 nil。
    @discardableResult
    func copyAllPlaceTimes() -> String? {
        guard let line = panelTimesLine() else { return nil }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(line, forType: .string)
        return line
    }

    /// 上面那一行的文本（不碰剪贴板，供测试与将来的别处复用）。
    func panelTimesLine() -> String? {
        let ordered = panelOrder.zones
        guard !ordered.isEmpty else { return nil }
        let named = ordered.map { entry -> (name: String, zone: TimeZone) in
            // 名字用面板行上看到的那个：自定义名 → 本地化城市名 → 城市语言 = 无时退到时区的地名。
            let city = localizedCity(entry)
            let name = entry.customName ?? (city.isEmpty ? core.placeName(forTimeZoneID: entry.timezoneID) : city)
            return (name, entry.timeZone)
        }
        return TimeInput.pasteLine(start: referenceDate, end: nil, zones: named, source: .current,
                                   hourStyle: settings.hourStyle, locale: uiLocale, now: now)
    }

    var panelOrder: PanelOrder {
        guard settings.panelSort == .callable, zones.count > 1 else {
            return PanelOrder(zones: zones, callableCount: 0, nextZone: nil, nextInMinutes: nil)
        }
        let minute = Int(now.timeIntervalSince1970 / 60)
        // 基准与醒着窗口都进缓存键：右键菜单 / 设置页一改，下一帧就重排，不等分钟翻页。
        let key = PanelOrderKey(minute: minute, ids: zones.map(\.id), bases: zones.map(\.callBasis),
                                awakeWindow: settings.awakeWindow, homeTimeZoneID: TimeZone.current.identifier)
        if let cached = cachedPanelOrder, cachedPanelOrderKey == key { return cached }
        let states = zones.map { entry in
            // .awake 按全局醒着窗口（每天，不看周末）；.work 仍是这一行自己的可约时段。
            (id: entry.id, state: PlaceCallability.compute(timeZone: entry.timeZone, now: now,
                                                           countryCode: entry.countryCode,
                                                           window: entry.callBasis == .awake ? settings.awakeWindow : entry.effectiveAvailability))
        }
        let result = CallableOrder.compute(states)
        // 本机时区仍参与排序；等待提示只从别的时区里选。
        let next = CallableOrder.compute(states, zones: zones, excluding: TimeZone.current)
        let byID = Dictionary(uniqueKeysWithValues: zones.map { ($0.id, $0) })
        // Rust 只回 id；顺序里没出现的（理论上不会）补在后面，一个地点都不能丢。
        var sorted = result.order.compactMap { byID[$0] }
        for entry in zones where !result.order.contains(entry.id) { sorted.append(entry) }
        let order = PanelOrder(zones: sorted, callableCount: result.callableCount,
                               nextZone: next.nextID.flatMap { byID[$0] },
                               nextInMinutes: next.nextInMinutes)
        cachedPanelOrder = order
        cachedPanelOrderKey = key
        return order
    }

    private struct PanelOrderKey: Equatable {
        let minute: Int
        let ids: [UUID]
        let bases: [CallBasis]        // 某行的判定基准一改就要重排
        let awakeWindow: Availability // 醒着窗口一改同理
        let homeTimeZoneID: String
    }
    @ObservationIgnored private var cachedPanelOrder: PanelOrder?
    @ObservationIgnored private var cachedPanelOrderKey: PanelOrderKey?

    /// 全局设置(转发 TimeCore)。Settings 窗口用 @Bindable 直接绑定其子字段;
    /// setter 去重后把副作用分发给 `effects`(落盘、时钟节奏、系统集成)。
    var settings: AppSettings {
        get { core.settings }
        set {
            // 值未真正改变就别编码+写盘(Picker 复确认同一项、ColorPicker 重发同色、绑定回环都会触发)。
            let old = core.settings
            let change = SettingsChange(old: old, new: newValue)
            guard change.changed else { return }
            core.settings = newValue
            for effect in effects { effect.apply(change: change, new: newValue, on: self) }
            updateSpotlightPlaces()
            onDataChange?()
        }
    }

    @ObservationIgnored private let effects: [any SettingsEffect]

    /// 开机自启的系统同步提示。nil = 设置已应用或无需提示。
    private(set) var launchAtLoginIssue: LaunchAtLoginIssue?

    /// 启动时发现时区数据损坏(已备份原始字节、尽量抢救可读条目)→ 面板顶部提示一次。
    private(set) var zonesRecoveryNotice = false

    /// 面板里刚删掉的地点（带原来的位置），几秒内可撤销；过期或撤销后清空。
    /// 用行内提示而不是 `UndoManager`：面板是 MenuBarExtra 的窗口，App 又是 LSUIElement 没有可见的
    /// 「编辑」菜单，⌘Z 既不可发现也未必路由得到；一行「已删除 X · 撤销」看得见、点得到。
    private(set) var pendingRemoval: PendingRemoval?
    struct PendingRemoval: Equatable {
        struct Item: Equatable { let index: Int; let entry: TimeZoneEntry }
        let items: [Item]
        let token: UUID
        var names: [String] { items.map { $0.entry.customName ?? $0.entry.cityName } }
    }
    /// 面板窗口的撤销管理器（PopoverRootView 从环境里交进来）：删除地点登记进它，⌘Z / ⇧⌘Z 与「编辑」菜单就都通了（HIG undo，
    /// 撤销提示不再定时消失）。没有窗口（测试、扩展）时为 nil，撤销按钮直接放回。
    @ObservationIgnored weak var panelUndoManager: UndoManager?

    /// 系统环境变更版本号(转发 TimeCore)。
    var systemRevision: Int { core.systemRevision }

    /// 换算页的「在面板里看这一刻」要知道面板开没开：开着就不再替用户点菜单栏项（点一下反而关上）。
    private(set) var isPanelVisible = false
    private var isWorkspaceVisible = false
    /// 地球窗开着：与面板、工具窗一样要让时钟走；三者各记各的，关一个不停别人的钟。
    private var isEarthVisible = false

    /// 面板这次开着要不要亮「地图也能拖」：不落盘，拖一次地图就熄。
    private(set) var showsMapHint = false

    // 时钟句柄不是 UI 状态,@ObservationIgnored 免追踪;nonisolated(unsafe) 让 nonisolated
    // 的 deinit 能取消它(Task 是 Sendable、析构时已无其它引用,无数据竞争)。
    @ObservationIgnored
    private nonisolated(unsafe) var clockTask: Task<Void, Never>?

    @ObservationIgnored
    private nonisolated(unsafe) var backgroundActivity: NSObjectProtocol?

    @ObservationIgnored
    private nonisolated(unsafe) var systemObservers: [NSObjectProtocol] = []

    /// 偏好域。生产走 `.standard`;测试注入独立 suite,免得测试宿主(App 本体)把用户真实时区清掉。
    @ObservationIgnored
    private let defaults: UserDefaults

    /// `defaults` 默认是沙盒容器的标准域;`migrate` 为 true 时启动先做一次性迁移。
    init(defaults: UserDefaults = Store.appDefaults, migrate: Bool = true,
         applySystemIntegration: Bool = true) {
        self.defaults = defaults
        if migrate {
            // The reserved legacy source is distinct from the standard target domain.
            Store.migrateIfNeeded(into: defaults, from: Store.legacySources,
                                  sourceNames: ["com.dayside.Dayside.legacy"])
        }
        // 加载时不回写:TimeCore 直接用加载值构造,不走 settings setter。
        let loaded = Store.loadZones(from: defaults)
        core = TimeCore(zones: loaded.zones, settings: Store.loadSettings(from: defaults))
        zonesRecoveryNotice = loaded.recovered
        var configuredEffects: [any SettingsEffect] = [
            PersistSettingsEffect(defaults: defaults),
            ClockCadenceEffect(),
        ]
        if applySystemIntegration { configuredEffects.append(SystemIntegrationEffect()) }
        effects = configuredEffects
        // 冷启动:只应用系统集成状态(保活 / 开机自启 / 全局快捷键),落盘与时钟节奏不动。
        let initialChange = SettingsChange(old: nil, new: core.settings)
        for effect in effects { effect.apply(change: initialChange, new: core.settings, on: self) }
        updateClockRunningState()
        observeSystemChanges()
    }

    deinit {
        clockTask?.cancel()
        if let backgroundActivity {
            SystemIntegrationController.endBackgroundClockActivity(backgroundActivity)
        }
        systemObservers.forEach(NotificationCenter.default.removeObserver)
    }

    /// 订阅系统语言 / 时区 / 时钟变更。**事件驱动、不轮询**(与 MenuBarPresenceController 同教义)。
    private func observeSystemChanges() {
        let names: [Notification.Name] = [
            NSLocale.currentLocaleDidChangeNotification,   // 语言 / 地区 / 24 小时制开关
            .NSSystemTimeZoneDidChange,                    // 本机时区(影响「跟随系统」的本地时钟)
            .NSSystemClockDidChange,                       // 手动改时间 / 网络对时跳变
        ]
        systemObservers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // queue: .main 保证回调在主线程,可安全断言主执行器隔离。
                MainActor.assumeIsolated { self?.systemEnvironmentDidChange() }
            }
        }
    }

    private func systemEnvironmentDidChange() {
        now = .now                       // 面板行 / 太阳弧立即按新时区、新时钟重算
        core.systemRevision &+= 1        // 菜单栏标签(含本地化城市名与 tick)随之重建
        onSystemChange?()
    }

    /// 推进 now。**显示秒时每整秒、否则每整分**(对齐边界,像系统时钟):面板打开时唤醒/重渲从
    /// 60 次/分降到 1 次/分,性能开销骤降。在 @MainActor 类里创建的 Task 继承主线程隔离,无 Sendable 问题。
    private func startClock() {
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // 对齐到下一整秒 / 下一整分,数字恰好在边界翻动(不漂移)。
                let sleep = ClockTick.nextBoundary(showSeconds: self.settings.showSeconds)
                try? await Task.sleep(for: sleep)
                if Task.isCancelled { return }
                self.now = .now
            }
        }
    }

    /// 面板关闭或没有任何时区时,AppModel 不需要周期性唤醒;菜单栏由 TimelineView 局部刷新。
    private func updateClockRunningState() {
        let directive: String = RustCore.invoke("model.clock", ["empty": zones.isEmpty && !isWorkspaceVisible && !isEarthVisible,
            "visible": isPanelVisible || isWorkspaceVisible || isEarthVisible, "running": clockTask != nil])
        switch directive {
        case "stop": stopClock()
        case "start": now = .now; startClock()
        default: break
        }
    }

    private func stopClock() {
        clockTask?.cancel()
        clockTask = nil
    }

    /// 重启时钟(切换显示秒时由 ClockCadenceEffect 调用,让新节奏立刻生效)。取消旧 Task 后重建;
    /// 旧 Task 被 cancel 后 `Task.sleep` 抛 CancellationError(被 try? 吞掉)、`isCancelled` 守卫确保不写陈旧值。
    func restartClock() {
        stopClock()
        updateClockRunningState()
    }

    /// 后台保活(由 SystemIntegrationEffect 调用)。
    func applyBackgroundKeepAlivePreference() {
        if settings.keepAliveInBackground {
            guard backgroundActivity == nil else { return }
            backgroundActivity = SystemIntegrationController.beginBackgroundClockActivity()
        } else {
            endBackgroundActivity()
        }
    }

    private func endBackgroundActivity() {
        guard let backgroundActivity else { return }
        SystemIntegrationController.endBackgroundClockActivity(backgroundActivity)
        self.backgroundActivity = nil
    }

    /// 开机自启(由 SystemIntegrationEffect 调用)。
    func applyLaunchAtLoginPreference() {
        do {
            try SystemIntegrationController.setLaunchAtLogin(settings.launchAtLogin)
            launchAtLoginIssue = SystemIntegrationController.requiresLoginItemApproval ? .requiresApproval : nil
            DiagnosticsLog.note("loginItem", "launchAtLogin=\(settings.launchAtLogin) status=\(SystemIntegrationController.loginItemStatusName)")
        } catch {
            launchAtLoginIssue = .updateFailed
            DiagnosticsLog.note("loginItem", "launchAtLogin=\(settings.launchAtLogin) failed: \(error.localizedDescription)", level: .error)
        }
    }

    /// 按欢迎页的选择应用登录项，开始使用前不注册。
    func finishWelcome(openAtLogin: Bool) {
        var updated = settings
        updated.launchAtLogin = openAtLogin
        updated.didShowWelcome = true
        settings = updated
    }

    // MARK: - Time Scroller

    /// 跳到任意日期(日期选择器用),保留挑选的时间;总偏移可超出 ±24h。
    /// 只动锚点、不动滑块分量:跳完滑块位置不跳变,且此后拖滑块是在新日期附近 ±24h 微调。
    func jump(to date: Date) { applyScrub("jump", target: date) }
    /// 拖动地图上的太阳时逐帧跳（不动画，指针到哪时间到哪）；松手那一下再带动画对齐到整刻钟。
    func jump(to date: Date, animated: Bool) { applyScrub("jump", target: date, animated: animated) }
    func resetToNow() { applyScrub("reset") }

    /// 一次地图拖动结束：计数 +1（封顶 99），滑块提示立刻熄掉。
    func noteMapDrag() {
        showsMapHint = false
        if settings.mapDrags < 99 { settings.mapDrags += 1 }
    }

    /// 跳到某一刻时的动画（「有含义的运动」；按距离定长短、≥ 6 h 分两拍）：
    /// 地图（晨昏线、太阳）整段走 `JumpTiming.jumpDuration` 那么久；面板行的天色与钟点跟在后面
    /// （`scrubRowAnimation`，行上 `.animation(_:value:)` 取用），两拍与地图同刻到达。拖滑块 / 拖地图仍是逐帧直接赋值。
    /// 测试宿主可以关（`animatesScrub = false`，全都不动）。
    @ObservationIgnored var animatesScrub = true
    /// 行内容（天色与钟点）这一拍的动画；nil = 不动画（拖动、flush、`animatesScrub = false`）。
    @ObservationIgnored private(set) var scrubRowAnimation: Animation?
    /// 带动画跳转的序号：行上 `.animation(_:value:)` 的键。键不是时刻：分钟 tick 与逐帧拖动就不会带着残留动画走。
    private(set) var scrubSerial = 0

    private var performanceAllowsMotion: Bool {
        #if DEBUG
        PerformanceProbe.isRequested
        #else
        false
        #endif
    }

    private func applyScrub(_ kind: String, target: Date? = nil, animated: Bool = true) {
        struct Input: Encodable { let kind: String; let anchor: Double; let offset: Double; let now: Double; let target: Double? }
        struct Result: Decodable { let anchor: Double; let offset: Double; let display: Double }
        let result: Result = RustCore.invoke("model.scrub", Input(kind: kind, anchor: jumpAnchor, offset: scrollOffset,
            now: now.timeIntervalSince1970, target: target?.timeIntervalSince1970))
        jumpAnchor = result.anchor
        // 距离（这一跳 displayOffset 挪多远，赋值前读）定时长；系统「减弱动态效果」开着：地图一步到位，行交叉淡入。
        let beats = JumpTiming.beats(hours: abs(result.display - displayOffset) / 3600)
        let animatedJump = kind != "flush" && animated && animatesScrub
        var animation: Animation? = nil
        scrubRowAnimation = nil
        if animatedJump {
            scrubSerial += 1
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && !ApplicationSession.forceAnimation && !performanceAllowsMotion {
                scrubRowAnimation = .easeInOut(duration: JumpTiming.fadeDuration)
            } else {
                animation = .easeInOut(duration: beats.map)
                scrubRowAnimation = .easeInOut(duration: beats.row).delay(beats.delay)
            }
        }
        withAnimation(animation) {
            if scrollOffset != result.offset { scrollOffset = result.offset }
            // 只在真变时赋值：「现在」之后 33 ms 的节流 flush 会再算一次同样的值，同值再赋会打断正在跑的动画事务。
            if displayOffset != result.display { displayOffset = result.display }
        }
    }

    func setEarthVisible(_ visible: Bool) {
        guard isEarthVisible != visible else { return }
        isEarthVisible = visible
        if visible { now = .now }
        updatePresentationVisibility()
    }

    func setPanelVisible(_ visible: Bool) {
        guard isPanelVisible != visible else { return }
        isPanelVisible = visible
        if visible {
            now = .now
            refreshCityNames()
            // 学一次：还没拖过地图、提示也没亮满 5 次，这一开才亮并计数；拖过一次就永不再亮。
            showsMapHint = settings.mapDrags == 0 && settings.mapHintOpens < 5
            if showsMapHint { settings.mapHintOpens += 1 }
        }
        updatePresentationVisibility()
    }

    func setWorkspaceVisible(_ visible: Bool) {
        guard isWorkspaceVisible != visible else { return }
        isWorkspaceVisible = visible
        if visible { now = .now }
        updatePresentationVisibility()
    }

    private func updatePresentationVisibility() {
        updateClockRunningState()
    }

    /// 把已有条目的各语言显示名与当前城市索引对齐。
    ///
    /// 显示名是**添加时**存进条目的(见 TimeZoneEntry.localizedNames 的说明),所以索引一旦
    /// 修正,老条目还带着旧名字——真出过这事:成都曾被挑成雅称「天府」,修好索引之后
    /// 已经加过成都的用户仍然看到「天府」。
    ///
    /// 放在**面板打开时**做:那时城市索引本来就要映射,不会把它拖进启动路径
    /// (菜单栏标签在启动时映射 28MB 索引 = 毁掉"面板不开就不映射"这条性质)。
    /// 每条一次索引检索约 0.04ms,几条时区可忽略;名字没变就不落盘。
    private func refreshCityNames() {
        struct Request: Codable { let id: UUID; let cityName: String; let timezoneID: String }
        struct Candidate: Encodable { let identifier: String; let cityName: String; let cityIndex: Int? }
        struct Lookup: Encodable { let request: Request; let candidates: [Candidate] }
        struct Match: Decodable { let id: UUID; let cityIndex: Int }
        let requests: [Request] = RustCore.invoke("model.refresh_name_requests", zones)
        let lookups = requests.map { request in
            Lookup(request: request, candidates: ZoneCatalog.shared.search(request.cityName, locale: nil).map {
                Candidate(identifier: $0.identifier, cityName: $0.cityName, cityIndex: $0.cityIndex)
            })
        }
        let matches: [Match] = RustCore.invoke("model.refresh_name_matches", lookups)
        var updates: [String: CoreJSON] = [:]
        for match in matches {
            updates[match.id.uuidString] = CoreJSON(CityIndex.shared.localizedNames(cityIndex: match.cityIndex))
        }
        editZones(.object(["kind": .string("refreshNames"), "updates": .object(updates)]))
    }

    private func editZones(_ action: CoreJSON) {
        struct Input: Encodable { let zones: [TimeZoneEntry]; let action: CoreJSON }
        struct Result: Decodable { let zones: [TimeZoneEntry]; let persist: Bool; let resetScrub: Bool }
        let result: Result = RustCore.invoke("model.edit", Input(zones: zones, action: action))
        zones = result.zones
        if result.persist {
            Store.saveZones(zones, to: defaults)
            updateSpotlightPlaces()
        }
        if result.resetScrub { resetToNow() }
        if result.persist { onDataChange?() }
    }
    func addZone(_ zone: ZoneOption) {
        pendingRemoval = nil
        // 时区层的条目在这里才补坐标（按需解析，目录初始化不再扫索引）；城市层条目自带坐标，原样。
        let zone = ZoneCatalog.shared.resolvingCoordinate(zone)
        editZones(.object(["kind": .string("add"), "entry": CoreJSON(TimeZoneEntry(zone: zone))]))
        updateClockRunningState()
    }
    func removeZone(id: UUID) {
        removeZones(ids: [id])
    }
    /// 按 id 删（面板按「现在能打给谁」排序时，行的位次与 `zones` 的下标不一致，只能按 id 删）。
    func removeZones(ids: [UUID]) {
        let offsets = IndexSet(ids.compactMap { id in zones.firstIndex(where: { $0.id == id }) })
        guard !offsets.isEmpty else { return }
        removeZones(at: offsets)
    }
    /// 删掉几个地点：提示行留到下一次编辑（不再 3 秒消失），并登记进窗口的撤销管理器，⌘Z 放回、⇧⌘Z 再删；
    /// 连续删几次就能连续撤销几次。
    func removeZones(at offsets: IndexSet) {
        let removed = offsets.compactMap { zones.indices.contains($0) ? PendingRemoval.Item(index: $0, entry: zones[$0]) : nil }
        editZones(.object(["kind": .string("removeOffsets"), "offsets": CoreJSON(Array(offsets))]))
        updateClockRunningState()
        guard !removed.isEmpty else { return }
        pendingRemoval = PendingRemoval(items: removed, token: UUID())
        registerUndo(restoring: removed)
    }

    private func registerUndo(restoring items: [PendingRemoval.Item]) {
        guard let manager = panelUndoManager else { return }
        manager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.restore(items) }
        }
        manager.setActionName(L10n.string("删除地点", locale: uiLocale))
    }

    private func registerRedo(removing items: [PendingRemoval.Item]) {
        guard let manager = panelUndoManager else { return }
        manager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.removeEntries(items) }
        }
        manager.setActionName(L10n.string("删除地点", locale: uiLocale))
    }

    /// 放回一批删掉的地点（按原下标从小到大插回，多个也能复原顺序），并登记「再删」作为重做。
    private func restore(_ items: [PendingRemoval.Item]) {
        pendingRemoval = nil
        for item in items.sorted(by: { $0.index < $1.index }) {
            editZones(.object(["kind": .string("insert"), "index": CoreJSON(item.index), "entry": CoreJSON(item.entry)]))
        }
        updateClockRunningState()
        registerRedo(removing: items)
    }

    /// 重做：按 id 再删一遍（中间可能挪过位置，所以不按下标）。
    private func removeEntries(_ items: [PendingRemoval.Item]) {
        let ids = Set(items.map(\.entry.id))
        let offsets = IndexSet(zones.indices.filter { ids.contains(zones[$0].id) })
        removeZones(at: offsets)
    }

    /// 「撤销」按钮：有撤销管理器就走它（重做栈才对得上），没有就直接放回。
    func restoreRemovedZones() {
        guard let pending = pendingRemoval else { return }
        if let manager = panelUndoManager, manager.canUndo {
            manager.undo()
        } else {
            restore(pending.items)
        }
    }
    func moveZones(from source: IndexSet, to destination: Int) {
        pendingRemoval = nil
        editZones(.object(["kind": .string("move"), "offsets": CoreJSON(Array(source)), "destination": CoreJSON(destination)]))
    }
    func rename(id: UUID, to name: String) {
        pendingRemoval = nil
        editZones(.object(["kind": .string("rename"), "id": .string(id.uuidString), "name": .string(name)]))
    }
    /// emoji 与色点一起设：emoji 只取第一个字素簇，空即清；颜色名不在名单里 Rust 会当没有。
    func decorate(id: UUID, emoji: String?, color: String?) {
        pendingRemoval = nil
        let symbol = emoji?.trimmingCharacters(in: .whitespacesAndNewlines).first.map(String.init)
        editZones(.object(["kind": .string("decorate"), "id": .string(id.uuidString),
                           "emoji": symbol.map(CoreJSON.string) ?? .null, "color": color.map(CoreJSON.string) ?? .null]))
    }
    func setAvailability(id: UUID, _ availability: Availability?) {
        editZones(.object(["kind": .string("availability"), "id": .string(id.uuidString), "availability": CoreJSON(availability)]))
    }
    /// 「能打给的时段」基准就地换（面板右键菜单），与改名 / 上色同一条编辑路径。
    func setCallBasis(id: UUID, to basis: CallBasis) {
        pendingRemoval = nil
        editZones(.object(["kind": .string("callBasis"), "id": .string(id.uuidString), "callBasis": .string(basis.rawValue)]))
    }
    func setParticipates(id: UUID, _ participates: Bool) {
        struct Input: Encodable { let id: UUID; let participates: Bool; let excluded: [UUID] }
        settings.planner.excludedZoneIDs = RustCore.invoke("model.participation", Input(id: id, participates: participates, excluded: settings.planner.excludedZoneIDs))
    }

}

/// 跳转动画的节奏：距离越远走越久。纯函数，`JumpTimingTests` 直接钉住。
nonisolated enum JumpTiming {
    /// 「减弱动态效果」时行内容交叉淡入的时长。
    static let fadeDuration = 0.2
    /// 分两拍的距离门槛（小时）。
    static let twoBeatHours = 6.0

    /// 距离（小时，取绝对值）→ 地图那一段的时长：≤ 2 h 恒 0.25 s；2 … 6 h 线性升到 0.6；
    /// 之后 18 h 再线性加 0.3，24 h 起 0.9 封顶。
    static func jumpDuration(hours: Double) -> Double {
        let h = hours.isFinite ? abs(hours) : 0
        if h <= 2 { return 0.25 }
        if h <= 6 { return 0.25 + (h - 2) * 0.35 / 4 }
        return min(0.9, 0.6 + (h - 6) * 0.3 / 18)
    }

    /// 一次跳转的两拍：地图整段走 `map`；行内容等 `delay` 后走 `row`，`delay + row == map`（同刻到达）。
    /// 不足 `twoBeatHours` 一拍（行与地图同段）。
    struct Beats: Equatable, Sendable {
        let map: Double
        let delay: Double
        let row: Double
    }

    static func beats(hours: Double) -> Beats {
        let map = jumpDuration(hours: hours)
        let twoBeat = (hours.isFinite ? abs(hours) : 0) >= twoBeatHours
        // 行第二拍占 0.6 d、先等 0.4 d：地图先走，行跟上，两者同刻停。
        return Beats(map: map, delay: twoBeat ? 0.4 * map : 0, row: twoBeat ? 0.6 * map : map)
    }
}

enum LaunchAtLoginIssue: Equatable {
    case requiresApproval
    case updateFailed
}

enum SystemIntegrationController {
    /// 「注册了当前登录项的构建」身份存档。App 是 ad hoc 签名(无 Team ID),系统按代码哈希认 app:
    /// 换构建后 status 仍读 .enabled,登录项却认不得新二进制,下次登录静默失联。
    private static let buildIdentityKey = "dayside.loginItem.buildIdentity"

    static var requiresLoginItemApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    /// 诊断日志用的可读状态名。
    static var loginItemStatusName: String {
        switch SMAppService.mainApp.status {
        case .notRegistered: return "notRegistered"
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notFound: return "notFound"
        @unknown default: return "unknown"
        }
    }

    static func setLaunchAtLogin(_ enabled: Bool) throws {
        // 测试宿主绝不碰 SMAppService:宿主是 app 本体,不能被挂进登录项。
        guard ProcessInfo.processInfo.environment["MEANTIME_TEST_HOST"] != "1" else { return }
        let service = SMAppService.mainApp
        if enabled {
            if service.status == .requiresApproval { return }
            if service.status == .enabled {
                // .enabled 可能是旧构建的残留注册:身份一致才直接返回;不一致(或没记过)就
                // 注销再注册。注销失败也照试注册:宁可多注一次,绝不能让登录项缺着。
                guard UserDefaults.standard.string(forKey: buildIdentityKey) != currentBuildIdentity() else { return }
                try? service.unregister()
                try service.register()
                saveBuildIdentity()
                DiagnosticsLog.note("loginItem", "re-registered for a new build")
                return
            }
            // .notRegistered / .notFound(以及未来新增状态,同旧行为):直接注册并记下身份。
            try service.register()
            saveBuildIdentity()
        } else {
            guard service.status == .enabled || service.status == .requiresApproval else { return }
            try service.unregister()
            UserDefaults.standard.removeObject(forKey: buildIdentityKey)
        }
    }

    /// 当前身份读不出就清存档:身份误判最多让下次多重注一次,不会漏注册。
    private static func saveBuildIdentity() {
        if let identity = currentBuildIdentity() {
            UserDefaults.standard.set(identity, forKey: buildIdentityKey)
        } else {
            UserDefaults.standard.removeObject(forKey: buildIdentityKey)
        }
    }

    /// 当前构建身份:cdhash 的小写十六进制;读不出退回「CFBundleVersion + 主可执行文件修改秒 + 大小」。
    private static func currentBuildIdentity() -> String? {
        if let hash = codeDirectoryHash() {
            return hash.map { String(format: "%02x", $0) }.joined()
        }
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "0"
        guard let executable = Bundle.main.executableURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: executable.path),
              let modified = attributes[.modificationDate] as? Date else { return nil }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        return "\(version)-\(Int(modified.timeIntervalSince1970))-\(size)"
    }

    /// 运行中代码的 cdhash(kSecCodeInfoUnique)。任一步失败都交回上层走退路。
    private static func codeDirectoryHash() -> Data? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let information,
              let unique = (information as? [String: Any])?[kSecCodeInfoUnique as String] as? Data else { return nil }
        return unique
    }

    static func beginBackgroundClockActivity() -> NSObjectProtocol {
        // `.background` 抑制 App Nap(菜单栏钟的 Task.sleep tick 不被节流 → 时间保持准确),
        // 且**不含** IdleSystemSleepDisabled → 不阻止系统睡眠(与设置页脚承诺一致)。
        // 不用 `.automaticTerminationDisabled`:它只在 app 通过 Info.plist 的 NSSupportsAutomaticTermination
        // 或 automaticTerminationSupportEnabled=true 声明支持自动终止时才有意义;本 app 两者皆无、
        // 本就不会被自动终止,该 flag 是空操作(已移除)。
        ProcessInfo.processInfo.beginActivity(
            options: .background,
            reason: "Keep Dayside menu bar clock current"
        )
    }

    static func endBackgroundClockActivity(_ activity: NSObjectProtocol) {
        ProcessInfo.processInfo.endActivity(activity)
    }
}
