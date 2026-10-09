// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

nonisolated struct SharingDraft: Codable, Equatable, Sendable {
    var timeZoneID = ""
    var displayName = ""
    var includesAvailability = false
    var startMinute = 540
    var endMinute = 1020
    /// Foundation weekday numbers: Sunday 1, Monday 2, … Saturday 7.
    var workingWeekdays = [2, 3, 4, 5, 6]
    /// 预约回执邮箱（可选）：对方在分享页选了时段，页面替他起一封给这个地址的邮件；
    /// 空着就只给他日历文件和可复制的文字。旧草稿没有这个键，解码按空处理。
    var contactEmail = ""
    /// 名片上的地名（发方地点表里那座城的名字，按城市语言；不带自定义名与 emoji）、它的拉丁写法与那座城的经纬度：
    /// 收方的页面按经纬度画那边此刻的天。都由所选的地点给，用户不手填；Rust 进名片前把坐标四舍五入到 0.1°。
    var placeName = ""
    var placeCity = ""
    var latitude: Double?
    var longitude: Double?

    enum CodingKeys: String, CodingKey {
        case timeZoneID, displayName, includesAvailability, startMinute, endMinute, workingWeekdays, contactEmail, placeName, placeCity, latitude, longitude
    }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        timeZoneID = try c.decodeIfPresent(String.self, forKey: .timeZoneID) ?? ""
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        includesAvailability = try c.decodeIfPresent(Bool.self, forKey: .includesAvailability) ?? false
        startMinute = try c.decodeIfPresent(Int.self, forKey: .startMinute) ?? 540
        endMinute = try c.decodeIfPresent(Int.self, forKey: .endMinute) ?? 1020
        workingWeekdays = try c.decodeIfPresent([Int].self, forKey: .workingWeekdays) ?? [2, 3, 4, 5, 6]
        contactEmail = try c.decodeIfPresent(String.self, forKey: .contactEmail) ?? ""
        placeName = try c.decodeIfPresent(String.self, forKey: .placeName) ?? ""
        placeCity = try c.decodeIfPresent(String.self, forKey: .placeCity) ?? ""
        latitude = try c.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try c.decodeIfPresent(Double.self, forKey: .longitude)
    }
}

/// 名片上那个地方：所选地点（或本机）的城市名、拉丁写法与经纬度。视图按 `TimeCore` 的城市语言算好交给 store。
nonisolated struct SharingPlaceFacts: Equatable, Sendable {
    var name: String
    var city: String
    var coordinate: Coordinate?

    static let none = SharingPlaceFacts(name: "", city: "", coordinate: nil)
}

/// 分享页「分享哪个地点」的选项。进名片的始终是 `draft.timeZoneID`（IANA 标识符，格式不变）；
/// 这里只记住它从哪来：已保存地点按条目 id 记（两个地点可能共用一个时区，按标识符记会分不清），
/// 「本机」跟随这台 Mac。只能从自己的地点里挑，不再手填时区标识符（诚实评估 C-8）。
nonisolated enum SharingZoneChoice: Hashable, Sendable {
    case place(UUID)
    case local
}

nonisolated struct SharingWindow: Codable, Equatable, Identifiable, Sendable {
    let start: Double
    let end: Double
    var id: Double { start }
    var startDate: Date { Date(timeIntervalSince1970: start) }
    var endDate: Date { Date(timeIntervalSince1970: end) }
}

nonisolated struct SharingSchedule: Codable, Equatable, Sendable {
    let startMinute: Int
    let endMinute: Int
    let workingWeekdays: [Int]
    let isWholeDay: Bool
    let endDayOffset: Int
}

nonisolated struct SharingPayload: Codable, Equatable, Sendable {
    let version: Int
    let timeZoneID: String
    let fixedOffsetSeconds: Int?
    let displayName: String?
    let schedule: SharingSchedule?
    let generatedAt: Double
    let validUntil: Double
    let windows: [SharingWindow]
    /// 预约回执邮箱（可选）；老名片没有这个键。
    var contactEmail: String? = nil
    /// 明信片上的地名、拉丁写法与那座城的坐标（四舍五入到 0.1°）；老名片没有。
    var place: String? = nil
    var city: String? = nil
    var latitude: Double? = nil
    var longitude: Double? = nil
}

nonisolated struct SharingDocument: Decodable, Equatable, Sendable {
    let payload: SharingPayload
    let fragment: String
    let shareURL: String?
    let html: String
}

nonisolated struct SharingResult: Decodable, Sendable {
    let document: SharingDocument?
    let errors: [String]
}

/// Foundation validates timezone identifiers and supplies calendar facts to the
/// existing Rust planner. The sharing core decides what enters the artifact.
nonisolated enum SharingGenerator {
    private struct ValidationInput: Encodable { let draft: SharingDraft; let timeZoneValid: Bool }
    private struct Validation: Decodable { let draft: SharingDraft?; let errors: [String] }
    private struct HostFacts: Encodable {
        let scheme: String
        let host: String
        let port: Int?
        let encodedPath: String
        let hasUserInfo: Bool
        let hasQuery: Bool
        let hasFragment: Bool

        init(_ raw: String) {
            let parsed = URLComponents(string: raw)
            scheme = parsed?.scheme ?? ""
            host = parsed?.host ?? ""
            port = parsed?.port
            encodedPath = parsed?.percentEncodedPath ?? ""
            hasUserInfo = parsed?.user != nil || parsed?.password != nil
            hasQuery = parsed?.query != nil
            hasFragment = parsed?.fragment != nil
        }
    }
    private struct BuildInput: Encodable {
        let draft: SharingDraft
        let timeZoneValid: Bool
        let nativeTimeZoneID: String
        let nativeOffsetSeconds: Int
        let now: Double
        let validUntil: Double
        let intervals: [SharingWindow]
        let hostFacts: HostFacts?
        let tzdata: String?
    }

    static func build(draft: SharingDraft, hostURL: String, now: Date) -> SharingResult {
        let zone = TimeZone(identifier: draft.timeZoneID.trimmingCharacters(in: .whitespacesAndNewlines))
        let validation: Validation = RustCore.invoke("sharing.validate", ValidationInput(draft: draft, timeZoneValid: zone != nil))
        guard let normalized = validation.draft, let zone else {
            return SharingResult(document: nil, errors: validation.errors)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        guard let until = calendar.date(byAdding: .day, value: 14, to: now),
              let previous = calendar.date(byAdding: .day, value: -1, to: now) else {
            return SharingResult(document: nil, errors: ["dates"])
        }
        let intervals: [SharingWindow]
        if normalized.includesAvailability {
            let participant = OverlapPlanner.Participant(id: UUID(), name: "", timeZoneID: normalized.timeZoneID,
                availability: Availability(startMinute: normalized.startMinute, endMinute: normalized.endMinute, weekdaysOnly: false),
                countryCode: nil, workingWeekdays: normalized.workingWeekdays)
            intervals = OverlapPlanner.availabilityIntervals(for: participant, coveringFrom: previous, to: until)
                .map { SharingWindow(start: $0.start.timeIntervalSince1970, end: $0.end.timeIntervalSince1970) }
        } else { intervals = [] }
        let host = hostURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return RustCore.invoke("sharing.build", BuildInput(draft: normalized, timeZoneValid: true,
            nativeTimeZoneID: zone.identifier, nativeOffsetSeconds: zone.secondsFromGMT(for: now),
            now: now.timeIntervalSince1970, validUntil: until.timeIntervalSince1970, intervals: intervals,
            hostFacts: host.isEmpty ? nil : HostFacts(host), tzdata: TZDataCheck.installedVersion))
    }

    /// 拷贝出去的文字：明信片的文字版，贴进聊天也读得懂。第一行「Mei · 东京（UTC+9）」（地名后面写那里的偏移，
    /// 读的人自己换算），有可约时段时再一行「可约：周一至周五 · 9:00–18:00 · 东京时间」与快照截止、不查日历两句，
    /// 有公开链接时最后是链接。钟点全走 `ClockText`（跟 `hourStyle`）。此前把每一段可约时段按发方这台 Mac 的时区逐行列出，
    /// 收方读到的是别人那边的钟点，又与作息那一行重复，去掉了。
    static func text(_ document: SharingDocument, locale: Locale, placeName: String, hourStyle: HourStyle = .followSystem,
                     now: Date = .now) -> String {
        let payload = document.payload
        let sourceZone = TimeZone(identifier: payload.timeZoneID) ?? .gmt
        let offset = TimeZoneEntry(timezoneID: payload.timeZoneID, cityName: placeName).offsetString(at: now)
        let place = t("%1$@（%2$@）", locale, placeName, offset)
        var lines = [[payload.displayName, place].compactMap { $0 }.joined(separator: " · ")]
        if let schedule = payload.schedule {
            lines.append(freeLine(schedule, placeName: placeName, locale: locale, hourStyle: hourStyle))
            let until = ClockText.dateTime(Date(timeIntervalSince1970: payload.validUntil), in: sourceZone,
                                           hourStyle: hourStyle, locale: locale, now: now)
            lines.append(t("时段快照截至 %@", locale, until))
            lines.append(t("可约时段不会查询日历或预订会议。", locale))
        }
        if let url = document.shareURL { lines.append(url) }
        return lines.joined(separator: "\n")
    }

    /// 明信片上那一行可约时段：「可约：周一至周五 · 9:00–18:00 · 东京时间」。收方网页（`site/when.html`）同一个写法。
    static func freeLine(_ schedule: SharingSchedule, placeName: String, locale: Locale, hourStyle: HourStyle = .followSystem) -> String {
        let parts = [weekdaysText(schedule.workingWeekdays, locale: locale), hoursText(schedule, locale: locale, hourStyle: hourStyle),
                     t("%@时间", locale, placeName)]
        return t("可约：%@", locale, parts.joined(separator: " · "))
    }

    /// 钟点：全天、跨午夜「21:00–次日 2:00」、或「9:00–18:00」。
    static func hoursText(_ schedule: SharingSchedule, locale: Locale, hourStyle: HourStyle = .followSystem) -> String {
        let start = ClockText.minute(schedule.startMinute, hourStyle: hourStyle)
        let end = ClockText.minute(schedule.endMinute % 1440, hourStyle: hourStyle)
        if schedule.isWholeDay { return t("全天", locale) }
        if schedule.endDayOffset == 1 { return t("%@–次日 %@", locale, start, end) }
        return ClockText.range(start, end)
    }

    /// 星期：连着三天以上写一段（「周一至周五」「Mon–Fri」「月〜金」），其余按语言的连词列出来；一周七天写「每天」。
    /// 一周按圈算：周日到周四也是一段。收方网页同一个规矩。
    static func weekdaysText(_ weekdays: [Int], locale: Locale) -> String {
        let days = Set(weekdays.filter { (1...7).contains($0) })
        if days.count == 7 { return t("每天", locale) }
        let first = (1...7).first { !days.contains($0) }.map { $0 % 7 + 1 } ?? 1
        var runs: [[Int]] = [], run: [Int] = []
        for offset in 0..<7 {
            let day = (first - 1 + offset) % 7 + 1
            if days.contains(day) { run.append(day) } else if !run.isEmpty { runs.append(run); run = [] }
        }
        if !run.isEmpty { runs.append(run) }
        let through: String = switch locale.language.languageCode?.identifier {
        case "zh": "至"
        case "ja": "〜"
        case "ko": "~"
        default: "–"
        }
        let name = { (day: Int) in ClockText.weekday(day, locale: locale) }
        let parts = runs.flatMap { run in run.count >= 3 ? [name(run[0]) + through + name(run[run.count - 1])] : run.map(name) }
        let list = ListFormatter()
        list.locale = locale
        return list.string(from: parts) ?? parts.joined(separator: ", ")
    }

    /// `String(localized:locale:)` only formats in `locale`; the lookup still follows the process
    /// language, so an English interface on a Chinese Mac copied Chinese labels. `L10n` reads the
    /// `.lproj` for the interface language instead.
    static func plainText(_ key: String, _ locale: Locale, _ args: CVarArg...) -> String {
        String(format: L10n.string(key, locale: locale), locale: locale, arguments: args)
    }

    private static func t(_ key: String, _ locale: Locale, _ args: CVarArg...) -> String {
        let pattern = L10n.string(key, locale: locale)
        return args.isEmpty ? pattern : String(format: pattern, locale: locale, arguments: args)
    }

}

@MainActor
@Observable
final class SharingStore {
    enum Status: Equatable { case idle, copied, saved, copyFailed, saveFailed }
    /// 分享页地址确定后，名片与二维码使用链接，手机扫描后在浏览器里打开。
    /// 未设置地址时，名片提供 HTML 文件、文字与图片，二维码携带可供 Dayside 导入的名片。
    static let publicPageURL: String? = nil
    /// 名片超过这个年龄后，页面再次出现时重新生成（可约时段覆盖的 14 天和「截至」时刻跟着现在走）。
    static let maxDocumentAge: TimeInterval = 3600
    // Only a real change discards the preview: SwiftUI text fields write the unchanged value back on
    // focus, and that must not make a generated card (and its QR code) disappear under the cursor.
    var draft = SharingDraft() { didSet { if draft != oldValue { invalidate() } } }
    /// 设置里的小时制（视图从 `core.settings` 同步进来）：预览与复制的文字里的钟点都跟它走。
    var hourStyle: HourStyle = .followSystem
    /// 当前分享的是哪一个地点；nil 表示页面还没按地点表对齐过（见 `alignZoneChoice`）。
    private(set) var zoneChoice: SharingZoneChoice?
    private(set) var document: SharingDocument?
    private(set) var previewText = ""
    private(set) var errors: [String] = []
    private(set) var status = Status.idle
    private(set) var isActive = false
    /// 名片的二维码，与 `document` 同生同灭；只在生成名片时画，不在视图里每次重绘时算。
    private(set) var qrCode: CGImage?
    private var pendingPanels: [UUID: NSSavePanel] = [:]
    @ObservationIgnored private var settledWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var generation = UUID()
    /// 上一次生成（成功或失败）用的草稿：自动预览每次输入停下都来问一遍，输入没变就不重算。
    @ObservationIgnored private var builtDraft: SharingDraft?
    @ObservationIgnored private var qrPayload = ""

    /// `defaults` 只为与其它页的 store 同一种构造；分享页不再往偏好里存任何东西（以前存过自己填的托管地址）。
    init(defaults: UserDefaults = Store.appDefaults) {}

    var activeResourceCount: Int { pendingPanels.count }
    func activate() { isActive = true }
    func deactivate() {
        isActive = false
        generation = UUID()
        for panel in Array(pendingPanels.values) { panel.cancel(nil) }
        document = nil
        previewText = ""
        status = .idle
        qrCode = nil
        qrPayload = ""
        builtDraft = nil
    }
    func waitUntilSettled() async {
        if pendingPanels.isEmpty { return }
        await withCheckedContinuation { settledWaiters.append($0) }
    }
    func deactivateAndWait() async {
        deactivate()
        await waitUntilSettled()
    }
    func invalidate() {
        document = nil
        previewText = ""
        errors = []
        status = .idle
        qrCode = nil
        qrPayload = ""
        builtDraft = nil
    }
    /// 页面出现或地点表变化时对齐：草稿里已有标识符就沿用能对上的项（已保存地点 → 本机），
    /// 对不上（地点删了）或空草稿就默认第一个已保存地点，没有地点时默认本机。
    func alignZoneChoice(places: [TimeZoneEntry], localTimeZoneID: String) {
        if case .place(let id)? = zoneChoice, !places.contains(where: { $0.id == id }) {
            zoneChoice = nil
        }
        guard zoneChoice == nil else { return }
        let current = draft.timeZoneID.trimmingCharacters(in: .whitespacesAndNewlines)
        if let place = places.first(where: { $0.timezoneID == current }) {
            zoneChoice = .place(place.id)
            draft.timeZoneID = place.timezoneID
        } else if current == localTimeZoneID {
            zoneChoice = .local
        } else if let first = places.first {
            zoneChoice = .place(first.id)
            draft.timeZoneID = first.timezoneID
        } else {
            zoneChoice = .local
            draft.timeZoneID = localTimeZoneID
        }
    }

    /// 用户选了一个地点：把它的标识符写进草稿（地名与坐标由视图随后 `applyPlace` 写）。
    func chooseZone(_ choice: SharingZoneChoice, places: [TimeZoneEntry], localTimeZoneID: String) {
        guard choice != zoneChoice else { return }
        switch choice {
        case .place(let id):
            guard let place = places.first(where: { $0.id == id }) else { return }
            draft.timeZoneID = place.timezoneID
        case .local:
            draft.timeZoneID = localTimeZoneID
        }
        zoneChoice = choice
    }

    /// 名片上的地名、拉丁写法与坐标：视图按所选地点与城市语言算好写进来；没变就什么都不做（草稿只认真变化）。
    func applyPlace(_ facts: SharingPlaceFacts) {
        var next = draft
        next.placeName = facts.name
        next.placeCity = facts.city == facts.name ? "" : facts.city
        next.latitude = facts.coordinate?.latitude
        next.longitude = facts.coordinate?.longitude
        draft = next
    }

    /// 这台 Mac 的时区变了（系统事件）而分享的是「本机」：草稿跟着走。
    func syncLocalTimeZone(_ localTimeZoneID: String) {
        guard zoneChoice == .local, draft.timeZoneID != localTimeZoneID else { return }
        draft.timeZoneID = localTimeZoneID
    }

    func setWeekday(_ weekday: Int, enabled: Bool) {
        var days = draft.workingWeekdays
        days.removeAll { $0 == weekday }
        if enabled { days.append(weekday) }
        draft.workingWeekdays = days.sorted()
    }

    /// 生成名片（片段、HTML、文字与二维码）。输入不合法时不生成，原因列在 `errors`。
    /// `placeName` 只在名片没写地名（旧草稿）时给文字一个地名（视图传 `TimeCore.placeName`）。
    func prepare(now: Date, locale: Locale, placeName: (String) -> String = { $0 }) {
        let result = SharingGenerator.build(draft: draft, hostURL: Self.publicPageURL ?? "", now: now)
        document = result.document
        errors = result.errors
        status = .idle
        builtDraft = draft
        previewText = result.document.map { text(for: $0, locale: locale, now: now, placeName: placeName) } ?? ""
        // 二维码只在名片内容真的变了才重画（同一份名片重排文字不算）。
        if let document = result.document {
            let payload = SharingQRCode.payload(for: document)
            if payload != qrPayload || qrCode == nil {
                qrCode = SharingQRCode.image(for: payload)
                qrPayload = payload
            }
        } else {
            qrCode = nil
            qrPayload = ""
        }
    }

    private func text(for document: SharingDocument, locale: Locale, now: Date, placeName: (String) -> String) -> String {
        SharingGenerator.text(document, locale: locale, placeName: document.payload.place ?? placeName(document.payload.timeZoneID),
                              hourStyle: hourStyle, now: now)
    }

    /// 自动预览的入口：页面出现与每次输入停下时调用。草稿与上次生成时不同才重新生成；上次生成失败而输入没变，
    /// 错误照旧显示、不重算；名片还在且不到 `maxDocumentAge`，什么都不做。
    func refreshIfNeeded(now: Date, locale: Locale, placeName: (String) -> String = { $0 }) {
        if builtDraft == draft {
            guard let document, now.timeIntervalSince1970 - document.payload.generatedAt > Self.maxDocumentAge else { return }
        }
        prepare(now: now, locale: locale, placeName: placeName)
    }

    /// 预览生成后界面语言或小时制变了：只重排文字，不重建名片，片段、链接与二维码保持刚才显示的那一份。
    func relocalize(locale: Locale, now: Date = .now, placeName: (String) -> String = { $0 }) {
        guard let document else { return }
        previewText = text(for: document, locale: locale, now: now, placeName: placeName)
    }

    func copyText() { copy(previewText) }
    func copyLink() { if let url = document?.shareURL { copy(url) } }

    /// 名片的明信片：App 里的预览、拷贝出去的图片与收方网页画的是同一张（数都从名片本身来）。
    func postcard(locale: Locale, placeName: (String) -> String = { $0 }) -> Postcard? {
        guard let document else { return nil }
        return Postcard(document: document, locale: locale, hourStyle: hourStyle, fallbackPlace: placeName(document.payload.timeZoneID))
    }

    func copyImage(locale: Locale, core: TimeCore, placeName: (String) -> String = { $0 }) {
        guard let card = postcard(locale: locale, placeName: placeName) else { return }
        status = PostcardImage.copy(card, core: core) ? .copied : .copyFailed
    }

    func saveImage(locale: Locale, core: TimeCore, placeName: (String) -> String = { $0 }) {
        guard let card = postcard(locale: locale, placeName: placeName), pendingPanels.isEmpty else { return }
        switch PostcardImage.save(card, core: core, suggestedName: SharingGenerator.plainText("时间名片", locale)) {
        case .failed: status = .saveFailed
        case .saved: status = .idle
        case .cancelled: break
        }
    }
    private func copy(_ text: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        status = NSPasteboard.general.setString(text, forType: .string) ? .copied : .copyFailed
    }

    func saveHTML() {
        guard let document, pendingPanels.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.allowsOtherFileTypes = false
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Dayside.html"
        let panelID = UUID()
        pendingPanels[panelID] = panel
        let token = generation
        panel.begin { [weak self, weak panel] response in
            guard let self else { return }
            defer {
                self.pendingPanels.removeValue(forKey: panelID)
                if self.pendingPanels.isEmpty {
                    let waiters = self.settledWaiters
                    self.settledWaiters.removeAll()
                    for waiter in waiters { waiter.resume() }
                }
            }
            guard self.generation == token else { return }
            guard response == .OK, let url = panel?.url else { return }
            do {
                try Data(document.html.utf8).write(to: url, options: .atomic)
                self.status = .saved
            } catch { self.status = .saveFailed }
        }
    }

    isolated deinit {
        for panel in pendingPanels.values { panel.cancel(nil) }
        for waiter in settledWaiters { waiter.resume() }
    }
}


// MARK: - Importing someone else's card (serverless two-party planning)

/// A pasted Dayside share link or fragment becomes a person with a place and working hours, so two
/// people can find overlap by exchanging cards: no server, no account, nothing uploaded.
nonisolated enum TimeCard {
    struct Decoded: Decodable, Sendable {
        struct Card: Decodable, Sendable {
            let timeZoneID: String
            let fixedOffsetSeconds: Int?
            let displayName: String?
            let tzdata: String?
            let startMinute: Int?
            let endMinute: Int?
            let workingWeekdays: [Int]?
            let validUntil: Double
            let windows: Int
        }
        let card: Card?
        let expired: Bool?
        let error: String?
    }
    /// 名片里的那个人：名字、地点、可选的作息。人物模块把它变成自己的人物记录。
    struct Contact: Equatable, Sendable {
        var name: String
        var timeZoneID: String
        var startMinute: Int?
        var endMinute: Int?
        var workingWeekdays: [Int]?
    }
    struct Imported: Sendable {
        var contact: Contact
        let expired: Bool
        let hadSchedule: Bool
        /// tzdata release on the sender's Mac when the card was made, when the card says.
        let senderTZData: String?
    }
    struct Failure: Error, Equatable, Sendable, ExpressibleByStringLiteral {
        let code: String
        init(stringLiteral value: String) { code = value }
        init(_ code: String) { self.code = code }
    }

    /// Failure names why: notACard / corrupt / invalid / unsupportedVersion / unknownZone / tooLong.
    static func person(from text: String, now: Date) -> Result<Imported, Failure> {
        struct Input: Encodable { let text: String; let now: Double }
        let decoded: Decoded = RustCore.invoke("sharing.decode", Input(text: text, now: now.timeIntervalSince1970))
        guard let card = decoded.card, decoded.error == nil else { return .failure(Failure(decoded.error ?? "corrupt")) }
        let zoneID: String
        if TimeZone(identifier: card.timeZoneID) != nil {
            zoneID = card.timeZoneID
        } else if let offset = card.fixedOffsetSeconds, let zone = TimeZone(secondsFromGMT: offset) {
            zoneID = zone.identifier
        } else {
            return .failure("unknownZone")
        }
        var contact = Contact(name: card.displayName ?? "", timeZoneID: zoneID)
        if let start = card.startMinute, let end = card.endMinute, let weekdays = card.workingWeekdays {
            contact.startMinute = start
            contact.endMinute = end == 1440 ? 0 : end
            contact.workingWeekdays = weekdays
        }
        return .success(Imported(contact: contact, expired: decoded.expired ?? false, hadSchedule: card.startMinute != nil,
                                 senderTZData: card.tzdata))
    }
}
