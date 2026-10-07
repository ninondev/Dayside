// SPDX-License-Identifier: GPL-3.0-only
//
//  TimeScrollerView.swift
//  TahoeTime
//
//  时间穿梭：一行说明（日期片、「现在」或拖到了哪儿）、一根滑块、一行刻度。
//  滑块的轨道是一段 24 小时的天（与工具窗页首天色带同一个 Rust `sky.strip`、同一批 73 个色标）：平时是这里此刻前后 12 小时；
//  看的那一刻离此刻超过 12 小时，轨道改画那一刻前后 12 小时的天，圆点回到正中，圆点、轨道与上面那一句说的是同一刻。
//  圆点在看的那一刻这里是白天就是太阳、夜里是月亮；刻度「12小时前 · 现在 · 12小时后」，三样各占自己的宽，任何语言都不叠。
//  拖动与地图同一套：拖到哪儿时间就到哪儿（整分钟跳），松手对齐整刻钟（`MapScrub`），键盘 ← → 走整点、⌥ 走整刻钟，读屏可调同一步。
//  日期片照旧点开系统日历（跳到任意一天）。输入一个时间只走面板顶上的搜索框（此前这里还有一颗键盘图标开一个小换算框，2026-10-02 删）。
//

import SwiftUI

struct TimeScrollerView: View {
    @Environment(\.panelSky) private var sky
    @Environment(\.panelFollowsSky) private var followsSky

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 6) {
                DateChip()
                ScrubCaption()
            }
            .appFont(.callout)
            .foregroundStyle(followsSky ? sky.map { AnyShapeStyle(SkyTextRole.sliderCaption.foreground(in: $0.chrome)) } ?? AnyShapeStyle(.primary) : AnyShapeStyle(.primary))
            // 行高与从前带键盘图标时一样（22 点），去掉图标后下面的滑块不上移。
            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
            SkySlider()
            SliderScale()
        }
    }
}

/// 日期片后面那一句：实时是「现在」；拖过时间是本机那一刻的钟点与「往后 / 往前 多久」。只有它读时刻，父层不跟着重渲。
private struct ScrubCaption: View {
    @Environment(TimeCore.self) private var core
    @Environment(AppModel.self) private var model
    @Environment(\.textScale) private var textScale

    var body: some View {
        if core.isScrubbing {
            let time = TimeFormatting.string(for: core.referenceDate, in: .current,
                                             format: ClockFormat(hourStyle: model.settings.hourStyle, showSeconds: false))
            let offset = core.displayOffset
            let shift = SliderPosition.offsetLabel(seconds: offset, locale: model.uiLocale)
            // 放得下就写完整方向与时长（一天以上写「2天3小时后」），长语言放不下时退成「+17h24m」「+2d3h」，不截成省略号。
            ViewThatFits(in: .horizontal) {
                caption(time: time, shift: shift)
                caption(time: time, shift: PresentationCore.call("scroll_label", ["seconds": offset]))
            }
            .monospacedDigit()
            .contentTransition(.numericText())
        } else {
            Text("现在")
        }
    }

    private func caption(time: String, shift: String) -> some View {
        var sentence = AttributedString(time + " · " + shift)
        if let range = sentence.range(of: time) {
            let font: Font = textScale == 1 ? .system(.callout) : .system(size: AppFont.size(.callout) * textScale)
            sentence[range].font = font.weight(.semibold).monospacedDigit()
        }
        return Text(sentence).lineLimit(1).fixedSize()
    }
}

/// 滑块那一段 24 小时放在哪：平时以此刻为中心；看的那一刻离此刻超过 12 小时，以那一刻为中心
/// （与工具窗页首天色带同一个判据，Rust `sky.strip` 的 `beyond`）。方向句也从这里出。
enum SliderPosition {
    /// 每一边多少分钟。
    static let span: Double = 720

    /// 看的那一刻离此刻超过 12 小时（`seconds` = 看的那一刻 − 此刻）。
    static func isBeyond(_ seconds: Double) -> Bool { abs(seconds) > span * 60 }

    /// 轨道正中是哪一刻。
    static func center(now: Date, instant: Date) -> Date {
        isBeyond(instant.timeIntervalSince(now)) ? instant : now
    }

    /// 某一刻落在以 `center` 为中心的那 24 小时的哪儿（0…1，出了两头钉在端点）。
    static func fraction(of instant: Date, center: Date) -> Double {
        min(1, max(0, instant.timeIntervalSince(center) / (2 * span * 60) + 0.5))
    }

    /// 「3小时后」「2天3小时后」「17 hours 24 minutes ago」。
    static func offsetLabel(seconds: Double, locale: Locale) -> String {
        seconds >= 0 ? ClockText.durationIn(seconds: abs(seconds), locale: locale)
                     : ClockText.durationAgo(seconds: abs(seconds), locale: locale)
    }
}

/// 滑块下的刻度：两端「12小时前」「12小时后」，正中「现在」（拖过时间时换成「回到现在」按钮，轨道正中就是此刻）。
/// 三样各有各的宽：正中那样按自己的宽居中；两端平分剩下的宽，全名放不下退成「−12h」，再放不下就不写（此前三样叠在一个
/// `ZStack` 里没有宽度预算，跳到 +17 小时 24 分钟时右端那句在 16 种语言里有 11 种压在「回到现在」上）。
/// 看的那一刻超过 12 小时：轨道画的是那一刻前后的天，两端不再是「12小时前 / 后」，不写字，只留「回到现在」。
private struct SliderScale: View {
    @Environment(TimeCore.self) private var core
    @Environment(AppModel.self) private var model
    @Environment(\.textScale) private var textScale
    @Environment(\.panelSky) private var sky
    @Environment(\.panelFollowsSky) private var followsSky

    var body: some View {
        let ends = !SliderPosition.isBeyond(core.displayOffset)
        HStack(spacing: 6) {
            end(forward: false, shown: ends)
            Group {
                if core.isScrubbing {
                    Button { model.resetToNow() } label: {
                        Label("回到现在", systemImage: "arrow.uturn.backward")
                            .fontWeight(.semibold)
                            .padding(.horizontal, 6)
                            .frame(minHeight: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("现在").accessibilityHidden(true)
                }
            }
            .lineLimit(1)
            .fixedSize()
            end(forward: true, shown: ends)
        }
        .appFont(.caption)
        .foregroundStyle(followsSky ? sky.map { AnyShapeStyle(SkyTextRole.sliderScale.foreground(in: $0.chrome)) } ?? AnyShapeStyle(.primary) : AnyShapeStyle(.primary))
        .padding(.horizontal, 2)
        .accessibilityHidden(true)
    }

    private func end(forward: Bool, shown: Bool) -> some View {
        let full = L10n.string(forward ? "12小时后" : "12小时前", locale: model.uiLocale)
        let short = forward ? "+12h" : "\u{2212}12h"
        let font = textScale == 1
            ? NSFont.preferredFont(forTextStyle: .caption1)
            : NSFont.systemFont(ofSize: AppFont.size(.caption) * textScale)
        let fullWidth = ceil((full as NSString).size(withAttributes: [.font: font]).width)
        let shortWidth = ceil((short as NSString).size(withAttributes: [.font: font]).width)
        let height = ceil(font.ascender - font.descender + font.leading)
        return GeometryReader { geometry in
            let label = !shown ? "" : fullWidth <= geometry.size.width ? full
                : shortWidth <= geometry.size.width ? short : ""
            Text(verbatim: label)
                .lineLimit(1)
                .fixedSize()
                .frame(width: geometry.size.width, height: geometry.size.height,
                       alignment: forward ? .trailing : .leading)
        }
        .frame(height: height)
        .frame(maxWidth: .infinity, alignment: forward ? .trailing : .leading)
        .accessibilityHidden(true)
    }
}

/// 穿梭滑块。轨道是一段 24 小时的天（`SliderPosition`：平时此刻前后 12 小时，超过 12 小时以看的那一刻为中心），
/// 用 SwiftUI 的渐变填充画（与此前同一种画法，面板里没量过另一种画法更省）。色标只在打开、每分钟与轨道换了中心时去 Rust 算
/// （`SliderTrackMemo`），拖动与逐帧的地图拖动都不重算：此前轨道算在面板的天色里，拖时间时 ~30 Hz 每次都把 73 个色标重算一遍。
struct SkySlider: View {
    @Environment(AppModel.self) private var model
    @Environment(TimeCore.self) private var core
    @Environment(\.panelSky) private var sky
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lastMinute: Date?
    @State private var memo = SliderTrackMemo()
    /// 在「超过 12 小时」时按下：轨道钉在按下那一刻的中心，拖动只挪圆点；松手后才按新的那一刻重新定中心。
    /// 在此刻前后 12 小时里拖动：轨道本来就以此刻为中心，拖不出这一段，不用钉。
    @State private var pinnedCenter: Date?

    private static let span = SliderPosition.span
    private static let thumb: CGFloat = 20

    var body: some View {
        let beyond = SliderPosition.isBeyond(core.displayOffset)
        let center = pinnedCenter ?? SliderPosition.center(now: core.now, instant: core.referenceDate)
        let _ = memo.update(now: core.now, center: center, coordinate: SkyPanel.homeCoordinate(zones: core.zones))
        GeometryReader { proxy in
            let inset = Self.thumb / 2
            let usable = max(1, proxy.size.width - 2 * inset)
            let x = inset + CGFloat(SliderPosition.fraction(of: core.referenceDate, center: center)) * usable
            ZStack(alignment: .topLeading) {
                track
                    .frame(width: usable, height: 8)
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                SliderThumb(day: sky?.dayHere ?? true, luminance: LightPalette.skyLuminance(stops: memo.stops, at: SliderPosition.fraction(of: core.referenceDate, center: center)))
                    .frame(width: Self.thumb, height: Self.thumb)
                    .position(x: x, y: proxy.size.height / 2)
            }
            // 反色开着：轨道（这里的天）连同圆点一起预反一次，太阳仍是金盘、月仍是纸色；面板整块反过时由 `skyPreInverted` 拦下。
            .modifier(SkyPreInvert())
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if pinnedCenter == nil, beyond { pinnedCenter = center }
                        let target = MapScrub.wholeMinute(date(at: value.location.x, inset: inset, usable: usable, center: center))
                        guard target != lastMinute else { return }
                        lastMinute = target
                        model.jump(to: target, animated: false)
                    }
                    .onEnded { value in
                        let target = MapScrub.snapped(date(at: value.location.x, inset: inset, usable: usable, center: center))
                        lastMinute = nil
                        // 松手后轨道按落下的那一刻重新定中心：圆点滑过去，不是一闪。
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { pinnedCenter = nil }
                        model.jump(to: target, animated: true)
                    }
            )
        }
        .frame(height: 24)
        // 跨过 12 小时那一下（地图拖过去、← → 走过去、日期片跳过去）：圆点从端点滑回正中（或从正中滑到它在此刻前后的位置），
        // 不是一闪；拖动中、减弱动态效果时不动画。
        .animation(reduceMotion || pinnedCenter != nil ? nil : .easeInOut(duration: 0.25), value: beyond)
        // 键盘：焦点在滑块上时 ← → 走整点、⌥ 走整刻钟（与地球窗、读屏同一步，`MapScrub.step`）。
        .focusable(interactions: .edit)
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            let minutes = press.modifiers.contains(.option) ? 15 : 60
            model.jump(to: MapScrub.step(from: core.referenceDate, minutes: minutes, forward: press.key == .rightArrow, in: .current),
                       animated: press.phase == .down)
            return .handled
        }
        // 读屏看到的是一个系统滑块（角色、名字、值、上下调整都齐）：念人话（「往后 3小时」/「现在」），
        // 量程就是轨道那 24 小时（以分钟计、相对此刻），上下调整走整点（连续滑块默认一步是量程的 10%，细调不可用）。
        .accessibilityRepresentation {
            let middle = center.timeIntervalSince(core.now) / 60
            Slider(value: Binding(get: { min(middle + Self.span, max(middle - Self.span, core.displayOffset / 60)) },
                                  set: { model.jump(to: core.now.addingTimeInterval($0 * 60)) }),
                   in: (middle - Self.span)...(middle + Self.span)) {
                Text("时间偏移")
            }
            .accessibilityValue(Text(verbatim: spokenValue))
            .accessibilityAdjustableAction { direction in
                let forward: Bool
                switch direction {
                case .increment: forward = true
                case .decrement: forward = false
                @unknown default: return
                }
                model.jump(to: MapScrub.step(from: core.referenceDate, minutes: 60, forward: forward, in: .current))
            }
        }
        // 提示气泡：键盘的两步写在滑块上。
        .help(Text("← → 走一小时 · ⌥ 走一刻钟"))
    }

    /// 轨道：那 24 小时的天；没有本机坐标时是一条中性的灰。
    private var track: some View {
        Capsule()
            .fill(memo.gradient.map { AnyShapeStyle(LinearGradient(gradient: $0, startPoint: .leading, endPoint: .trailing)) }
                  ?? AnyShapeStyle(.quaternary))
            .overlay(Capsule().strokeBorder(SkyLaneForegroundStyle(stops: memo.stops, shadeInDarkAppearance: false), lineWidth: 0.5))
    }

    /// 横坐标 → 时刻：轨道两端是 `center` 前后 12 小时（拖动中轨道不动、圆点动）。
    private func date(at x: CGFloat, inset: CGFloat, usable: CGFloat, center: Date) -> Date {
        let fraction = Double(min(max(0, (x - inset) / usable), 1))
        return center.addingTimeInterval((fraction * 2 - 1) * Self.span * 60)
    }

    private var spokenValue: String {
        guard core.isScrubbing else { return L10n.string("现在", locale: model.uiLocale) }
        let offset = core.displayOffset
        let shift = SliderPosition.offsetLabel(seconds: offset, locale: model.uiLocale)
        let time = TimeFormatting.string(for: core.referenceDate, in: .current,
                                         format: ClockFormat(hourStyle: model.settings.hourStyle, showSeconds: false))
        return "\(shift), \(time)"
    }
}

/// 滑块轨道的色标：Rust `sky.strip`（工具窗页首天色带同一个操作，同一个中心就是同一批 73 个色标），
/// 只在此刻的分钟、轨道中心（秒）或本机坐标变了时才去算，换成 SwiftUI 的渐变色标记住。面板关了它就随视图一起没了，没有全局缓存。
@MainActor
final class SliderTrackMemo {
    private struct Key: Equatable {
        let minute: Int
        let center: Int
        let latitude: Double?
        let longitude: Double?
    }
    private var key: Key?
    private(set) var stops: [SkyStripState.Stop] = []
    /// 没有本机坐标（或年份越界）时为 nil：轨道画中性的灰。
    private(set) var gradient: Gradient?
    /// 真去 Rust 算过几次（测试用）。
    private(set) var computations = 0

    func update(now: Date, center: Date, coordinate: Coordinate?) {
        let next = Key(minute: Int((now.timeIntervalSince1970 / 60).rounded(.down)), center: Int(center.timeIntervalSince1970.rounded()),
                       latitude: coordinate?.latitude, longitude: coordinate?.longitude)
        guard next != key else { return }
        key = next
        computations += 1
        // 以 `center` 当「看的那一刻」问 Rust：中心就是此刻时是此刻前后 12 小时，离此刻超过 12 小时时是它前后 12 小时。
        let state = SkyStripState.compute(now: now, instant: center, coordinate: coordinate, marks: false)
        guard state.stops != stops else { return }
        stops = state.stops
        gradient = stops.count > 1 ? Gradient(stops: stops.map { .init(color: LightPalette.color($0.color), location: $0.at) }) : nil
    }
}

/// 滑块的圆点：白天是一颗太阳（金盘、深色细边、一圈淡金的光），夜里是一弯月（纸色的盘，左下压一块夜色）。
private struct SliderThumb: View {
    let day: Bool
    let luminance: Double?

    var body: some View {
        ZStack {
            if day {
                Circle().fill(LightPalette.sun.opacity(0.22)).frame(width: 30, height: 30)
                Circle().fill(LightPalette.sun)
            } else {
                Circle().fill(LightPalette.paper)
                Circle().fill(LightPalette.moonDark)
                    .offset(x: -6, y: -1)
                    .mask(Circle())
            }
            Circle().strokeBorder(SkyGlyphRimStyle(luminance: luminance, role: .sliderGlyph, radius: 10, halfBand: 4), lineWidth: 1.5)
        }
        .shadow(color: .black.opacity(0.3), radius: 3, y: 1.5)
        .accessibilityHidden(true)
    }
}

/// 日期片：看的那一刻本机的日期（不是本年才写年份）做成按钮，点开弹系统 .graphical 日历改日期。
/// **单独子视图**——只有它读 `referenceDate`,时钟每分钟 tick 时父层 TimeScrollerView 不重渲。
private struct DateChip: View {
    @Environment(AppModel.self) private var model
    @State private var showingCalendar = false

    private var referenceBinding: Binding<Date> {
        Binding(get: { model.referenceDate }, set: { model.jump(to: $0) })
    }

    var body: some View {
        let date = model.referenceDate
        let thisYear = Calendar.current.isDate(date, equalTo: model.now, toGranularity: .year)
        Button {
            showingCalendar = true
        } label: {
            HStack(spacing: 3) {
                Text(date, format: thisYear ? .dateTime.month(.abbreviated).day().weekday(.abbreviated)
                                            : .dateTime.year().month(.abbreviated).day().weekday(.abbreviated))
                    .contentTransition(.numericText())
                    // 日期片不许被省略号截断（ru「Сейчас」按钮宽时也不行，避免出现「19.09.2…」）。
                    .fixedSize()
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).accessibilityHidden(true)
            }
            .fontWeight(.medium)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text("跳到某一天"))
        .popover(isPresented: $showingCalendar, arrowEdge: .bottom) {
            DatePicker("", selection: referenceBinding, displayedComponents: [.date])
                .datePickerStyle(.graphical)
                .labelsHidden()
                .padding()
                .environment(\.locale, model.uiLocale)
        }
    }
}
