// SPDX-License-Identifier: GPL-3.0-only
//
//  PostcardView.swift
//  Dayside
//
//  分享我的时间：一张印着那边此刻的天的明信片。
//  上半像一行面板：底是那个地方此刻的天（面板行同一种颜色，字只有墨与纸），左边名字与地名（衬线），右边大钟点与日期。
//  下半是那个地方今天的天（昼夜条同一种画法：每 10 分钟一个色标、细描边、深色外观压暗），底下一道细轨是可约时段，
//  此刻一根竖线穿过；最后一行写可约时段与一枚小小的 Dayside。
//  App 里的预览、拷贝出去的图片与收方打开的网页（`site/when.html`，同一套颜色算法的 JavaScript 版，夹具钉住两边一致）
//  画的是同一张，数都从名片本身来。只在名片、这一分钟或系统外观变了时去 Rust 算一次（`PostcardMemo`），
//  天先画成一行像素再拉满（不用 SwiftUI 渐变填充）；工具窗关了它就不在。
//

import AppKit
import SwiftUI

/// 明信片要画的东西：都从名片本身（`SharingDocument.payload`）来，App 里看到的就是收方看到的。
struct Postcard: Equatable {
    let name: String?
    let place: String
    let city: String?
    let timeZoneID: String
    let coordinate: Coordinate?
    let windows: [DateInterval]
    /// 「可约：周一至周五 · 9:00–18:00 · 东京时间」；没分享可约时段就没有。
    let free: String?

    /// `fallbackPlace`：名片没写地名（旧草稿）时用的地名。
    init(document: SharingDocument, locale: Locale, hourStyle: HourStyle, fallbackPlace: String) {
        let payload = document.payload
        name = payload.displayName
        place = payload.place ?? fallbackPlace
        city = payload.place == nil ? nil : payload.city
        timeZoneID = payload.timeZoneID
        coordinate = payload.latitude.flatMap { latitude in payload.longitude.map { Coordinate(latitude: latitude, longitude: $0) } }
        windows = payload.windows.map { DateInterval(start: $0.startDate, end: $0.endDate) }
        let place = place
        free = payload.schedule.map { SharingGenerator.freeLine($0, placeName: place, locale: locale, hourStyle: hourStyle) }
    }

    var timeZone: TimeZone { TimeZone(identifier: timeZoneID) ?? .gmt }
    /// 标题是名字，没有名字就是地名；下面一行：有名字时「东京 · Tokyo」，没有名字时只写拉丁写法（与网页同一个规矩）。
    var title: String { name ?? place }
    var subtitle: String? {
        if name != nil { return [place, city].compactMap { $0 }.joined(separator: " · ") }
        return city
    }
}

/// 明信片上要算的几样：那边此刻的天（Rust `sky.panel`：底色、墨或纸、要不要渐变）、那边今天的天（`sky.lanes`，画成一行像素）、
/// 可约时段在今天里的位置、此刻那根竖线。按「名片、这一分钟、要不要刻度、提高对比度」记住上一次，跟着视图走（`@State`）。
@MainActor
final class PostcardMemo {
    struct Art {
        var sky: SkyPanel.Row?
        var ribbon: CGImage?
        var marks: [MomentLaneArt.Mark] = []
        var frame: DayLaneFrame
        var rail: [ClosedRange<Double>] = []
        var line: Double = 0
    }
    private struct Key: Equatable {
        let minute: Int
        let card: Postcard
        let marks: Bool
        let increased: Bool
        let language: String
    }
    private struct Place: Encodable { let latitude: Double?; let longitude: Double?; let utcOffset: Double }
    private struct PanelInput: Encodable {
        let instant: Double; let now: Double; let home: Place; let places: [Place]; let need: Double; let flat: Bool; let language: String
    }
    private struct PanelOutput: Decodable { let rows: [SkyPanel.Row] }
    private struct LanePlace: Encodable { let latitude: Double?; let longitude: Double? }
    private struct LanesInput: Encodable { let start: Double; let end: Double; let places: [LanePlace]; let marks: Bool }
    private struct LanesOutput: Decodable { let lanes: [MomentLaneArt] }

    private var key: Key?
    private var art: Art?

    func update(card: Postcard, now: Date, marks: Bool, increased: Bool, language: String) -> Art {
        let next = Key(minute: Int(now.timeIntervalSince1970 / 60), card: card, marks: marks, increased: increased, language: language)
        if next == key, let art { return art }
        let frame = DayLaneFrame.homeDay(containing: now, timeZone: card.timeZone)
        let previousFrame = art?.frame
        var result = Art(frame: frame)
        if let coordinate = card.coordinate {
            let place = Place(latitude: coordinate.latitude, longitude: coordinate.longitude,
                              utcOffset: Double(card.timeZone.secondsFromGMT(for: now)))
            let input = PanelInput(instant: now.timeIntervalSince1970, now: now.timeIntervalSince1970, home: place, places: [place],
                                   need: increased ? 7 : 5.5, flat: increased, language: language)
            result.sky = (try? RustCore.attempt("sky.panel", input, as: PanelOutput.self))?.rows.first
            // 今天的天只在换了一天、换了地方或刻度开关变了时重算：一分钟走一格只挪竖线。
            if let previous = art, previousFrame == frame, key?.card.coordinate == card.coordinate, key?.marks == marks {
                result.ribbon = previous.ribbon
                result.marks = previous.marks
            } else {
                let lanes = try? RustCore.attempt("sky.lanes", LanesInput(start: frame.start.timeIntervalSince1970, end: frame.end.timeIntervalSince1970,
                    places: [LanePlace(latitude: coordinate.latitude, longitude: coordinate.longitude)], marks: marks), as: LanesOutput.self)
                if let lane = lanes?.lanes.first {
                    result.ribbon = SkyStripMemo.ribbonImage(lane.stops.map { SkyStripState.Stop(at: $0.at, color: $0.color) },
                                                             width: MomentLaneMemo.ribbonWidth)
                    result.marks = lane.marks
                }
            }
        }
        result.rail = card.windows.compactMap { window in
            let a = MomentTable.fraction(of: window.start, in: frame), b = MomentTable.fraction(of: window.end, in: frame)
            return b > a ? a...b : nil
        }
        result.line = MomentTable.fraction(of: now, in: frame)
        key = next
        art = result
        return result
    }
}

/// 明信片本身。`now` 由页面给（每分钟走一格）；离屏出图时给出图那一刻。
struct PostcardView: View {
    let card: Postcard
    let now: Date

    @Environment(TimeCore.self) private var core
    @Environment(\.textScale) private var textScale
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @State private var memo = PostcardMemo()

    static let cornerRadius: CGFloat = 12

    var body: some View {
        let increased = contrast == .increased
        let art = memo.update(card: card, now: now, marks: differentiateWithoutColor, increased: increased,
                              language: SkyPanel.languageCode(core.uiLocale))
        VStack(alignment: .leading, spacing: 0) {
            skyBand(art.sky, increased: increased)
            dayPart(art)
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: Self.cornerRadius)
            .strokeBorder(increased ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary.opacity(0.9)), lineWidth: increased ? 1 : 0.75))
        // 读屏把整张当一个元素念：名字、地名、那边几点、哪天、可约时段。
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isImage)
        .accessibilityLabel(Text("分享预览"))
        .accessibilityValue(Text(verbatim: spoken))
    }

    private var scale: CGFloat { CGFloat(textScale) }
    private var clock: String {
        TimeFormatting.string(for: now, in: card.timeZone, format: ClockFormat(hourStyle: core.settings.hourStyle, showSeconds: false))
    }
    private var date: String { ClockText.day(now, in: card.timeZone, locale: core.uiLocale, now: now, weekday: true) }
    private var spoken: String {
        [card.title, card.subtitle, clock, date, card.free].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    // MARK: 上半：那边此刻的天

    private func skyBand(_ sky: SkyPanel.Row?, increased: Bool) -> some View {
        let ink = sky?.colors.ink ?? true
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(verbatim: card.title)
                    .font(SerifFace.font(card.title, size: (20 * scale).rounded(), weight: .medium, locale: core.uiLocale))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text(verbatim: clock)
                    .font(ClockFace.font(size: (34 * scale).rounded(), design: core.settings.fontDesign, weight: core.settings.weight, light: true))
                    .fixedSize()
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                if let subtitle = card.subtitle, !subtitle.isEmpty {
                    Text(verbatim: subtitle)
                        .font(SerifFace.font(subtitle, size: (13 * scale).rounded(), weight: .regular, locale: core.uiLocale))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Text(verbatim: date).appFont(.callout).fixedSize()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, minHeight: 74 * scale, alignment: .bottomLeading)
        .foregroundStyle(ink ? LightPalette.ink : LightPalette.paper)
        .background {
            // 面板行同一种底：太阳贴着地平线时天顶到地平线一道渐变，其余一种颜色；提高对比度时平涂；不知道在哪是纸色。
            if let sky, sky.gradient, !increased {
                LinearGradient(colors: [sky.colors.topColor, sky.colors.horizonColor], startPoint: .top, endPoint: .bottom)
            } else if let sky {
                sky.colors.midColor
            } else {
                LightPalette.paper
            }
        }
        .modifier(SkyPreInvert())
    }

    // MARK: 下半：那边今天的天与可约时段

    private func dayPart(_ art: PostcardMemo.Art) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            DayLaneRuler(frame: art.frame, every: 6).frame(height: 14)
            PostcardLane(ribbon: art.ribbon, marks: art.marks, rail: art.rail, line: art.line, showsRail: card.free != nil)
                .frame(height: card.free != nil ? MomentMetrics.lane + 2 + MeetingMetrics.rail : MomentMetrics.lane)
            HStack(alignment: .lastTextBaseline, spacing: 10) {
                if let free = card.free {
                    Text(verbatim: free).appFont(.caption).foregroundStyle(.readableSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                PostcardMark()
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }
}

/// 那边今天的天：一行像素拉满（圆角 3、细描边、深色外观压暗 22%、「不使用颜色区分」时画昼夜边界刻度），
/// 下面一道细轨是可约时段（昼的蓝，与人物页、找碰头时间的工作时段同一种），此刻一根竖线穿过两样（反色时与天一起预反）。
private struct PostcardLane: View {
    let ribbon: CGImage?
    let marks: [MomentLaneArt.Mark]
    let rail: [ClosedRange<Double>]
    let line: Double
    let showsRail: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let increased = contrast == .increased
        VStack(spacing: 2) {
            Group {
                if let ribbon {
                    Image(decorative: ribbon, scale: 1).resizable().interpolation(.high)
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .overlay { if colorScheme == .dark && !increased && ribbon != nil { Color.black.opacity(0.22) } }
            .overlay {
                if !marks.isEmpty {
                    BandTicks(marks: marks).stroke(.background, lineWidth: 2.5)
                    BandTicks(marks: marks).stroke(.primary, lineWidth: 1)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(increased ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary.opacity(0.9)),
                                                                   lineWidth: increased ? 1 : 0.75))
            .frame(height: MomentMetrics.lane)
            if showsRail {
                PostcardRail(spans: rail).fill(DaysidePalette.day)
                    .background(Capsule().fill(.quaternary))
                    .frame(height: MeetingMetrics.rail)
            }
        }
        .overlay {
            MarkerLine(at: line).stroke(.background, lineWidth: 3.5)
            MarkerLine(at: line).stroke(.primary, lineWidth: 1.5)
        }
        .modifier(SkyPreInvert())
        .accessibilityHidden(true)
    }
}

/// 细轨里的可约时段：一条路径画完所有段。
private struct PostcardRail: Shape {
    let spans: [ClosedRange<Double>]
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for span in spans {
            let x0 = rect.minX + CGFloat(span.lowerBound) * rect.width
            let x1 = max(rect.minX + CGFloat(span.upperBound) * rect.width, x0 + 2)
            path.addRoundedRect(in: CGRect(x: x0, y: rect.minY, width: x1 - x0, height: rect.height),
                                cornerSize: CGSize(width: rect.height / 2, height: rect.height / 2))
        }
        return path
    }
}

/// 右下角一枚小小的 Dayside（图标与字）：别人收到图片时知道它从哪来。
private struct PostcardMark: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 12, height: 12)
            Text(verbatim: "Dayside")
        }
        .font(.caption2)
        .foregroundStyle(.readableSecondary)
        .fixedSize()
        .accessibilityHidden(true)
    }
}

/// 明信片的 PNG：浅色、420 点宽、两倍像素，四周 16 点白边，`ImageRenderer` 离屏渲染；拷贝（PNG + TIFF）或经存储面板存成文件。
/// 与预览同一个视图、同一张名片，所以拷贝出去的就是看到的那一张。都不联网、不写别处。
@MainActor
enum PostcardImage {
    static let width: CGFloat = 420
    enum SaveResult { case saved, cancelled, failed }

    static func image(for card: Postcard, core: TimeCore) -> NSImage? {
        let view = PostcardView(card: card, now: core.now)
            .frame(width: width)
            .padding(16)
            .background(Color.white)
            .environment(core)
            .environment(\.locale, core.uiLocale)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return renderer.nsImage
    }

    @discardableResult
    static func copy(_ card: Postcard, core: TimeCore) -> Bool {
        guard let image = image(for: card, core: core), let png = TimeCardImage.pngData(image),
              let tiff = image.tiffRepresentation else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let copiedPNG = pasteboard.setData(png, forType: .png)
        let copiedTIFF = pasteboard.setData(tiff, forType: .tiff)
        return copiedPNG && copiedTIFF
    }

    @discardableResult
    static func save(_ card: Postcard, core: TimeCore, suggestedName: String) -> SaveResult {
        guard let image = image(for: card, core: core), let png = TimeCardImage.pngData(image) else { return .failed }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = suggestedName.hasSuffix(".png") ? suggestedName : suggestedName + ".png"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK else { return .cancelled }
        guard let url = panel.url else { return .failed }
        do { try png.write(to: url, options: .atomic); return .saved } catch { return .failed }
    }
}
