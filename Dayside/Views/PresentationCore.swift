// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

extension ShapeStyle where Self == AnyShapeStyle {
    /// The system secondary label is 3.95:1 on white, under WCAG AA for small text; this keeps the
    /// secondary look above 4.5:1 on white and on card backgrounds in both appearances
    /// (measured by Tools/ax_dump_pages.sh).
    static var readableSecondary: AnyShapeStyle { AnyShapeStyle(Color.primary.opacity(0.78)) }
}

/// 错误与校验信息的唯一写法：红色只上图标，文字保持正文色。
/// 白底上系统红只有约 4.0:1，达不到 AA 的普通文字对比度要求。
struct ErrorLine: View {
    let text: Text
    init(_ text: Text) { self.text = text }
    var body: some View {
        Label { text } icon: { Image(systemName: "exclamationmark.circle").foregroundStyle(.red) }
    }
}

/// Same row layout as the automatic macOS style, with the value in the readable secondary shade
/// instead of the system secondary label (3.1:1 on a grouped-form card).
struct ReadableLabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline) {
            configuration.label
            Spacer(minLength: 12)
            configuration.content
                .foregroundStyle(.readableSecondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

extension LabeledContentStyle where Self == ReadableLabeledContentStyle {
    static var readable: ReadableLabeledContentStyle { .init() }
}

/// Platform facts and DTO transport. Rust decides selection, boundaries and geometry.
nonisolated enum PresentationCore {
    static func call<Input: Encodable, Output: Decodable>(_ operation: String, _ input: Input,
                                                         as: Output.Type = Output.self) -> Output {
        RustCore.invoke("presentation.\(operation)", input, as: Output.self)
    }
    static func scalar(_ operation: String, _ input: [String: Double]) -> Double { call(operation, input) }

    struct CalendarFacts: Encodable {
        let fromDay: Double
        let todayStart: Double
        let now: Double
        let nextDay: Double
        init(fromDay: Date, now: Date, timeZone: TimeZone) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            self.fromDay = fromDay.timeIntervalSince1970
            todayStart = calendar.startOfDay(for: now).timeIntervalSince1970
            self.now = now.timeIntervalSince1970
            nextDay = calendar.dateInterval(of: .day, for: fromDay)!.end.timeIntervalSince1970
        }
    }

    /// 太阳与月亮页的主图「这一天的天」（Rust `presentation.sun_day`）：某地当地这一天的天色、太阳高度的线、地平线、
    /// 黄金时刻，以及看的那一刻太阳在哪。宿主只给民用日的起止、坐标、画布尺寸与看的那一刻。
    struct SunDayInput: Encodable, Equatable, Sendable {
        struct Span: Encodable, Equatable, Sendable { let start: Double; let end: Double }
        let dayStart: Double
        let dayEnd: Double
        let latitude: Double
        let longitude: Double
        let width: Double
        let height: Double
        let golden: [Span]
        let instant: Double
        /// 系统「不使用颜色区分」：昼 / 曙暮 / 夜的边界加刻度。
        let marks: Bool
    }
    struct SunDayScene: Decodable, Sendable {
        struct Sun: Decodable, Sendable { let x: Double; let y: Double; let up: Bool }
        let commands: [DrawCommand]
        let horizon: Double
        let sun: Sun?
    }
    /// 画布尺寸为零、年份越界时不画（不报错，不崩）。
    static func sunDay(_ input: SunDayInput) -> SunDayScene? {
        guard input.width > 0, input.height > 0 else { return nil }
        return try? RustCore.attempt("presentation.sun_day", input, as: SunDayScene.self)
    }

    /// 绘图命令与形状执行在 `Shared/SceneShape.swift`；这里留别名，让各调用处共用同一套类型。
    typealias DrawCommand = SceneCommand

    struct PlannerZoneFact: Encodable {
        let id: UUID
        let timeZoneId: String
        let customName: String?
        let cityName: String
        let localizedCity: String
    }
    struct PlannerRowsInput: Encodable {
        let zones: [PlannerZoneFact]
        let excluded: [UUID]
        let localTimeZoneId: String
        let localName: String
        let includeLocal: Bool
    }
    struct PlannerRowChoice: Decodable { let sourceIndex: Int; let name: String; let participates: Bool }
    struct ParticipantFact: Encodable { let id: UUID?; let participates: Bool }
    struct PlannerInputFacts: Encodable {
        let rows: [ParticipantFact]
        let fromDay: Double
        let todayStart: Double
        let now: Double
        let nextDay: Double
        init(rows: [ParticipantFact], calendar: CalendarFacts) {
            self.rows = rows
            fromDay = calendar.fromDay; todayStart = calendar.todayStart
            now = calendar.now; nextDay = calendar.nextDay
        }
    }
    struct PlannerInputChoice: Decodable {
        struct Participant: Decodable { let index: Int; let id: UUID }
        let participants: [Participant]
        let notBefore: Double
        let canPlan: Bool
    }
    struct IntervalEndpoint: Encodable { let time: String; let day: String; let abbreviation: String }
    struct IntervalTextInput: Encodable {
        let sameDay: Bool
        let startOffset: Int
        let endOffset: Int
        let start: IntervalEndpoint
        let end: IntervalEndpoint
    }
    struct BandWindow: Encodable { let start: Double; let end: Double; let tier: Int }
    struct BandInput: Encodable {
        let start: Double
        let length: Double
        let reference: Double
        let width: Double
        let height: Double
        let windows: [BandWindow]
        /// 本行的可约区间（Unix 秒）：折中窗口只涂在这些区间之外，黄色才只表示「这个人在时段外」。
        var available: [BandSpan] = []
    }
    struct BandSpan: Encodable, Equatable, Sendable { let start: Double; let end: Double }
    struct PanelInput: Encodable { let screenHeight: Double }
    struct PanelLayout: Decodable { let body: Double }
    struct ListInput: Encodable {
        let count: Int
        let nameMode: Bool
        let nameHeight: Double
        let twoLineHeight: Double
        let inset: Double
        let maxHeight: Double
    }
    struct SearchInput: Encodable { let ids: [String]; let selection: String?; let command: String; let query: String }
    struct SpokenNameInput: Encodable { let customName: String?; let localizedCity: String; let cityName: String; let nameMode: Bool }

    struct SearchState: Codable { var query: String; var selection: String?; var keyboardNavigating: Bool }
    struct SearchEvent: Encodable { let state: SearchState; let ids: [String]; let kind: String; var command: String? = nil }
    struct SearchTransition: Decodable { let state: SearchState; let commitIndex: Int?; let handled: Bool }

    struct PlannerMessage: Codable { let kind: String; var title: String? = nil }
    struct Place: Encodable {
        let name: String
        let time: String
        let fit: String
        /// 该地当地日期比行首日期晚几天（`ClockText.dayOffset`）；非零时 Rust 给钟点套「次日 / 前一日」模板。
        let dayOffset: Int
        init(name: String, time: String, fit: OverlapPlanner.Fit = .inside, dayOffset: Int = 0) {
            self.name = name; self.time = time; self.dayOffset = dayOffset
            switch fit {
            case .inside: self.fit = "inside"
            case .stretched: self.fit = "stretched"
            case .unavailable: self.fit = "unavailable"
            }
        }
        /// `date` 在 `timeZone` 的钟点，跨日偏移相对行首日期所在的 `reference` 时区算。
        init(name: String, date: Date, in timeZone: TimeZone, reference: TimeZone, format: ClockFormat,
             fit: OverlapPlanner.Fit = .inside) {
            self.init(name: name, time: TimeFormatting.string(for: date, in: timeZone, format: format), fit: fit,
                      dayOffset: ClockText.dayOffset(of: date, in: timeZone, from: reference))
        }
    }
    /// 三条文案都按界面语言取：「在工作时间外」、「次日 %@」、「前一日 %@」，后两条的 %@ 是钟点。
    struct PlacesInput: Encodable {
        let places: [Place]
        let outsidePhrase: String
        let nextDay: String
        let previousDay: String
        init(places: [Place], locale: Locale) {
            self.places = places
            outsidePhrase = L10n.string("在工作时间外", locale: locale)
            nextDay = L10n.string("次日 %@", locale: locale)
            previousDay = L10n.string("前一日 %@", locale: locale)
        }
    }
    struct Places: Decodable {
        struct Segment: Decodable { let text: String; let outside: Bool }
        let segments: [Segment]
        let accessibility: String

        /// 「洛杉矶 21:00 · 🌙伦敦 5:00 · 东京 13:00」：在时段外的人名前加一个 `moon.zzz` 小图标（图标可着橙色），
        /// 文字本身保持 `.readableSecondary`。此前整段文字着橙色，浅色底上系统橙只有约 2.3:1（
        /// 彩色只上图标，不上文字）。无障碍标签仍是 `accessibility`（带「在工作时间外」）。
        /// `Text + Text` 在 macOS 26 已废弃，拼接走插值（键「%@%@」「%@ %@」在字符串目录里，十语都是原样）。
        @MainActor var text: Text {
            var combined = Text(verbatim: "")
            for segment in segments {
                let piece: Text = segment.outside
                    ? Text("\(Text(Image(systemName: "moon.zzz")).foregroundStyle(.orange)) \(Text(verbatim: segment.text))")
                    : Text(verbatim: segment.text)
                combined = Text("\(combined)\(piece)")
            }
            return combined
        }
    }

}

extension View {
    /// 条件版 `labelsHidden`：面板里的紧凑控件隐藏标签、工具窗里保留。
    @ViewBuilder func labelsHidden(_ hidden: Bool) -> some View {
        if hidden { labelsHidden() } else { self }
    }
}

/// 新系统的菜单按钮把可读标题放在值属性里。
struct MenuAccessibleTitle: ViewModifier {
    let title: Text

    func body(content: Content) -> some View {
        if #available(macOS 27, *) {
            content.accessibilityLabel(title).accessibilityValue(title)
        } else {
            content.accessibilityLabel(title)
        }
    }
}
