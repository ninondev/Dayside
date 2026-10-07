// SPDX-License-Identifier: GPL-3.0-only
//
//  AstronomyLensView.swift
//  TahoeTime
//
//  太阳与月亮：某地某天的光。魂是「一天的光，就是一条天」——主图是那个地方那一天真实的天（与昼夜条同一批色标），
//  太阳这一天的高度画在上面：金线越过地平线的地方，就是墨色的夜转成玫瑰色的晨；黄金时刻是金线贴着地平线发光的那两段。
//  看的是哪一天跟着工具窗页首那条天色带走：看的那一刻在所选地点是哪一天，这一页就是哪一天；改日期就是把看的那一刻挪到那一天
//  （当地钟点不变），点页首的带子回到今天。主数字（日出、日落）用面板行的钟点字；月亮与面板地图上的同一颗。
//

import SwiftUI

struct AstronomyLensView: View {
    @Environment(AppModel.self) private var model
    @Environment(TimeCore.self) private var core
    @Environment(\.textScale) private var textScale
    @Bindable var store: AstronomyStore
    @State private var zoneID: UUID?
    @State private var showingCalendar = false

    /// 没有保存任何地点时按本机所在地算（系统时区目录给坐标），页面不再空着。
    @State private var localFallback: TimeZoneEntry?
    private var selectedZone: TimeZoneEntry? { core.zones.first { $0.id == zoneID } ?? (core.zones.isEmpty ? localFallback : nil) }
    private var timeZone: TimeZone { selectedZone?.timeZone ?? .current }

    /// 看的那一刻在所选地点是哪一天（当地日期的序号）：它变了才重算这一页。
    private var localDay: Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: core.referenceDate)
        return (parts.year ?? 0) * 10_000 + (parts.month ?? 0) * 100 + (parts.day ?? 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if core.zones.isEmpty, localFallback == nil {
                Text("先在菜单栏面板添加地点，再查看当地的日照和月相。").foregroundStyle(.readableSecondary)
            } else {
                subject
                if let result = store.result, result.available, let solar = result.solar, let moon = result.moon,
                   let dayStart = result.dayStart, let dayEnd = result.dayEnd, let coordinate = selectedZone?.coordinate {
                    SunDayChart(dayStart: dayStart, dayEnd: dayEnd, coordinate: coordinate, golden: solar.golden,
                                instant: core.referenceDate, timeZone: timeZone, hourStyle: core.settings.hourStyle,
                                summary: sunSummary(solar))
                        .padding(.top, 16)
                    sunTimes(solar)
                        .padding(.top, 14)
                    sunNotes(solar)
                        .padding(.top, 10)
                    golden(solar)
                        .padding(.top, 28)
                    moonSection(moon)
                        .padding(.top, 28)
                } else if store.error == "missingCoordinates" {
                    ErrorLine(Text("这个地点没有经纬度。请添加具体城市后查看日照。")).padding(.top, 16)
                } else if store.error != nil {
                    ErrorLine(Text("暂时无法计算这个日期或地点。请选择 1800 至 2100 年之间的日期。")).padding(.top, 16)
                }
            }
        }
        .onAppear {
            if core.zones.isEmpty, localFallback == nil,
               let option = ZoneCatalog.shared.option(for: TimeZone.current.identifier) {
                localFallback = TimeZoneEntry(zone: option)
            }
            consumeRequest()
            if selectedZone == nil { zoneID = core.zones.first?.id }
            compute()
        }
        .onChange(of: store.requestedZoneID) { consumeRequest() }
        .onChange(of: zoneID) { compute() }
        .onChange(of: localDay) { compute() }
        .onChange(of: core.zones) {
            if selectedZone == nil { zoneID = core.zones.first?.id }
            compute()
        }
        .onChange(of: core.systemRevision) { compute() }
    }

    /// 页面的主语：「洛杉矶 · 10月2日 周四」，地名用面板行的衬线字，两样都能点开换。长地名 + 窄窗放不下就上下两行。
    private var subject: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                place
                Text(verbatim: "·").foregroundStyle(.readableSecondary).accessibilityHidden(true)
                dateChip
            }
            VStack(alignment: .leading, spacing: 4) {
                place
                dateChip
            }
        }
    }

    /// 地点：衬线地名 + 系统的小箭头，点开是已保存地点的菜单；没有地点时是本机所在地（不能点）。
    /// 箭头用系统的（`.menuIndicator(.visible)`）：藏起来自己画时，读屏框只剩箭头那 8 × 5 点（实测）。
    @ViewBuilder
    private var place: some View {
        let size = (AppFont.size(.title2) * textScale).rounded()
        if core.zones.isEmpty, let local = localFallback {
            let name = String(format: L10n.string("本机（%@）", locale: core.uiLocale), core.placeName(forTimeZoneID: local.timezoneID))
            Text(verbatim: name).font(SerifFace.font(name, size: size, weight: .medium, locale: core.uiLocale))
                .help(Text("在面板里添加地点后，可以在这里换"))
                .accessibilityHint(Text("在面板里添加地点后，可以在这里换"))
        } else {
            let name = selectedZone.map(placeName) ?? ""
            Menu {
                Picker("地点", selection: $zoneID) {
                    ForEach(core.zones) { zone in
                        Text(verbatim: placeName(zone)).tag(Optional(zone.id))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Text(verbatim: name).font(SerifFace.font(name, size: size, weight: .medium, locale: core.uiLocale))
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.visible)
            .fixedSize()
            .help(Text("在面板里添加地点后，可以在这里换"))
            .accessibilityHint(Text("在面板里添加地点后，可以在这里换"))
            .accessibilityLabel(Text("地点"))
            .accessibilityValue(Text(verbatim: name))
        }
    }

    /// 日期：所选地点那天的当地日期（与面板日期片同一写法），点开是系统日历；换一天 = 把看的那一刻挪到那一天的同一个当地钟点。
    private var dateChip: some View {
        let label = dayLabel(core.referenceDate)
        return Button { showingCalendar = true } label: {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(verbatim: label).appFont(.title3)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.readableSecondary)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(Text("当地日期"))
        .accessibilityLabel(Text("当地日期"))
        .accessibilityValue(Text(verbatim: label))
        .popover(isPresented: $showingCalendar, arrowEdge: .bottom) {
            DatePicker("当地日期", selection: Binding(get: { core.referenceDate }, set: { model.jump(to: $0) }),
                       in: Self.supportedDays, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .padding()
                .environment(\.timeZone, timeZone)
                .environment(\.locale, core.uiLocale)
        }
    }

    /// 能选的日子：天文与页首天色带都只算 1800–2100 年（两头各让出一天，前后 12 小时的天也在范围里）。
    private static let supportedDays = Date(timeIntervalSince1970: -5_364_576_000)...Date(timeIntervalSince1970: 4_133_894_400)

    private func dayLabel(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var style = Date.FormatStyle(locale: core.uiLocale, calendar: calendar, timeZone: timeZone).month(.abbreviated).day().weekday(.abbreviated)
        if calendar.component(.year, from: date) != calendar.component(.year, from: core.now) { style = style.year() }
        return date.formatted(style)
    }

    private func placeName(_ zone: TimeZoneEntry) -> String {
        zone.displayName(localizedCity: core.cityName(for: zone))
    }

    /// 面板带过来的地点：接过去就清掉，下次自己打开这一页不受影响。
    private func consumeRequest() {
        guard let requested = store.requestedZoneID else { return }
        store.requestedZoneID = nil
        if core.zones.contains(where: { $0.id == requested }) { zoneID = requested }
    }

    // MARK: - 太阳

    /// 主数字：日出、日落，用面板行的钟点字（大、细、等宽数字）；没有的（极昼极夜）写「今天无日出」。
    private func sunTimes(_ solar: AstronomySolar) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // 两个钟点最宽的写法（12 小时制「12:48 PM」）并排也只要 300 点左右，最窄的正文栏（约 330 点）放得下，不留竖排的第二份。
            HStack(alignment: .top, spacing: 40) { sunTime(solar, rise: true); sunTime(solar, rise: false) }
            if solar.kind == "polarDay" { Text("极昼：这一天太阳始终在地平线以上。") }
            if solar.kind == "polarNight" { Text("极夜：这一天没有日出。") }
        }
    }

    private func sunTime(_ solar: AstronomySolar, rise: Bool) -> some View {
        let instant = rise ? solar.sunrise : solar.sunset
        return VStack(alignment: .leading, spacing: 2) {
            Label(rise ? LocalizedStringKey("日出") : LocalizedStringKey("日落"), systemImage: rise ? "sunrise" : "sunset")
                .appFont(.callout).foregroundStyle(.readableSecondary)
            if let instant {
                Text(verbatim: time(instant)).font(ClockFace.large(core.settings, scale: textScale))
            } else {
                Text(rise ? LocalizedStringKey("今天无日出") : LocalizedStringKey("今天无日落")).appFont(.title3).foregroundStyle(.readableSecondary)
            }
        }
        .accessibilityElement(children: .combine)
        // 原页脚整句（含月相那半句）作为目录键搬进悬停与读屏提示；月相一节另有自己的提示。
        .help(Text("时间为天文估算，地形和天气会影响实际观测。月相按所选地点当天中午计算。"))
        .accessibilityHint(Text("时间为天文估算，地形和天气会影响实际观测。月相按所选地点当天中午计算。"))
    }

    /// 日照多长、比昨天怎样；太阳正午与「钟比太阳快」；离至日还有几天。
    private func sunNotes(_ solar: AstronomySolar) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("日照时长")
                Text(verbatim: duration(solar.daylightSeconds)).monospacedDigit().fontWeight(.medium).foregroundStyle(.primary)
            }
            .accessibilityElement(children: .combine)
            if let trend = store.trend {
                trendLine(trend)
            }
            if let noon = solar.solarNoon {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { noonParts(noon) }
                    VStack(alignment: .leading, spacing: 2) { noonParts(noon) }
                }
                .accessibilityElement(children: .combine)
            }
            if let trend = store.trend { solsticeLine(trend).fixedSize(horizontal: false, vertical: true) }
        }
        .appFont(.callout)
        .foregroundStyle(.readableSecondary)
    }

    @ViewBuilder
    private func noonParts(_ noon: Double) -> some View {
        HStack(spacing: 6) {
            Text("太阳正午")
            Text(verbatim: time(noon)).monospacedDigit()
        }
        if let line = clockVersusSun(noon) {
            Text(verbatim: "·").accessibilityHidden(true)
            Text(verbatim: line)
        }
    }

    /// 黄金时刻：两段时间（钟点字，中号），口径进标题的悬停与读屏提示。
    private func golden(_ solar: AstronomySolar) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // 标题前一小段金光，与主图上金线发光的那两段同一个样子：图上哪两段是黄金时刻，一眼对得上。
            Label {
                Text("黄金时刻")
            } icon: {
                Capsule().fill(LightPalette.sun.opacity(0.55)).frame(width: 16, height: 7)
                    .overlay(Capsule().fill(LightPalette.sun).frame(width: 16, height: 2))
            }
            .appFont(.headline)
            .accessibilityAddTraits(.isHeader)
            // 口径写明白：黄金时刻没有唯一定义，我们取 PhotoPills 的 −4°…+6°；
            // timeanddate 用的是 −6°…+6°，两家差十来分钟，所以点名是哪一种。
            .help(Text("黄金时刻按太阳高度 −4° 至 +6° 估算（PhotoPills 的口径；另有工具用 −6°），所有时刻均为所选地点的当地时间。"))
            .accessibilityHint(Text("黄金时刻按太阳高度 −4° 至 +6° 估算（PhotoPills 的口径；另有工具用 −6°），所有时刻均为所选地点的当地时间。"))
            if solar.golden.isEmpty {
                Text("这一天没有符合条件的黄金时刻。").foregroundStyle(.readableSecondary)
            } else {
                // 一般两段（晨、昏）；12 小时制 + 窄窗或极地的几段放不下就竖排。
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 28) { goldenRanges(solar) }
                    VStack(alignment: .leading, spacing: 4) { goldenRanges(solar) }
                }
            }
        }
    }

    private func goldenRanges(_ solar: AstronomySolar) -> some View {
        ForEach(solar.golden) { interval in
            Text(verbatim: ClockText.range(time(interval.start), time(interval.end))).font(ClockFace.medium(core.settings, scale: textScale))
        }
    }

    // MARK: - 月亮

    /// 月相：与面板地图上同一颗月亮（暗面一枚深色圆、亮面按月相画），旁边是名字与几样数。
    private func moonSection(_ moon: AstronomyMoon) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("月相").appFont(.headline).accessibilityAddTraits(.isHeader)
                .help(Text("月相按所选日期当地中午计算"))
                .accessibilityHint(Text("月相按所选日期当地中午计算"))
            HStack(alignment: .top, spacing: 18) {
                MoonTile(illumination: moon.illumination, waxing: moon.cycle < 0.5,
                         southern: (selectedZone?.coordinate?.latitude ?? 0) < 0)
                    .frame(width: 54, height: 54)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(LocalizedStringKey(WorldMapScene.moonPhaseKey(moon.phase))).font(ClockFace.medium(core.settings, scale: textScale))
                    // 名字一列、值一列：两个竖排并排，一行一个字号，行自然对齐。此前用 `Grid`，冷启动这一页峰值多约 1 MiB（实测），换成两列。
                    // 读屏一行念一件事（「月面照亮, 36%」）：名字那列隐藏，值那格带上名字。
                    HStack(alignment: .top, spacing: 14) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(moonFacts(moon)) { fact in Text(fact.label).foregroundStyle(.readableSecondary) }
                        }
                        .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(moonFacts(moon)) { fact in
                                fact.value.monospacedDigit()
                                    .accessibilityLabel(Text(fact.label))
                                    .accessibilityValue(fact.value)
                            }
                        }
                    }
                    .appFont(.callout)
                    .fixedSize()
                }
            }
        }
    }

    /// 月亮的几样数：照亮多少、距上次新月几天、下次新月与满月（先到的先列）。
    private struct MoonFact: Identifiable {
        let id: Int
        let label: LocalizedStringKey
        let value: Text
    }

    private func moonFacts(_ moon: AstronomyMoon) -> [MoonFact] {
        var facts = [MoonFact(id: 0, label: "月面照亮",
                              value: Text(verbatim: moon.illumination.formatted(.percent.precision(.fractionLength(0)).locale(core.uiLocale))))]
        if let age = moon.ageDays {
            facts.append(MoonFact(id: 1, label: "距上次新月", value: Text("约 \(age, specifier: "%.1f") 天")))
        }
        for (offset, event) in nextMoons(moon).enumerated() {
            facts.append(MoonFact(id: 2 + offset, label: event.label, value: Text(verbatim: time(event.instant, date: true))))
        }
        return facts
    }

    private struct MoonEvent: Identifiable {
        let id: Int
        let label: LocalizedStringKey
        let instant: Double
    }

    private func nextMoons(_ moon: AstronomyMoon) -> [MoonEvent] {
        var events: [MoonEvent] = []
        if let new = moon.nextNewMoon { events.append(MoonEvent(id: 0, label: "下次新月（约）", instant: new)) }
        if let full = moon.nextFullMoon { events.append(MoonEvent(id: 1, label: "下次满月（约）", instant: full)) }
        return events.sorted { $0.instant < $1.instant }
    }

    // MARK: - 文字

    /// 「比昨天短 4 分钟 · 日出晚 1 分钟 · 日落早 3 分钟」：三段各自一条键，用「·」相接（长语言放不下就竖排），零值写「不变 / 相同」。
    private func trendLine(_ trend: AstronomyTrend) -> some View {
        let parts = trendParts(trend)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                ForEach(parts.indices, id: \.self) { index in
                    parts[index]
                    if index < parts.count - 1 { Text(verbatim: "·").accessibilityHidden(true) }
                }
            }
            VStack(alignment: .leading, spacing: 2) { ForEach(parts.indices, id: \.self) { parts[$0] } }
        }
        .accessibilityElement(children: .combine)
    }

    private func trendParts(_ trend: AstronomyTrend) -> [Text] {
        let seconds = Int(trend.daylightChangeSeconds.rounded())
        let minutes = Int((trend.daylightChangeSeconds / 60).rounded())
        let change: Text = switch (minutes, seconds) {
        case (0, 0): Text("与昨天相同")
        case (0, let s) where s > 0: Text("比昨天长 \(s) 秒")
        case (0, let s): Text("比昨天短 \(-s) 秒")
        case (let m, _) where m > 0: Text("比昨天长 \(m) 分钟")
        case (let m, _): Text("比昨天短 \(-m) 分钟")
        }
        var parts = [change]
        if let shift = trend.sunriseShiftMinutes {
            parts.append(shift == 0 ? Text("日出不变") : shift > 0 ? Text("日出晚 \(shift) 分钟") : Text("日出早 \(-shift) 分钟"))
        }
        if let shift = trend.sunsetShiftMinutes {
            parts.append(shift == 0 ? Text("日落不变") : shift > 0 ? Text("日落晚 \(shift) 分钟") : Text("日落早 \(-shift) 分钟"))
        }
        return parts
    }

    /// 「距日照最长的一天（6月21日）还有 96 天，届时日照 14 小时 32 分钟。」；今天就是那天时只说这一句。
    private func solsticeLine(_ trend: AstronomyTrend) -> Text {
        if trend.solsticeDaysAway == 0 {
            return trend.solsticeIsLongest ? Text("今天是这里一年中日照最长的一天。") : Text("今天是这里一年中日照最短的一天。")
        }
        let day = ClockText.day(trend.solsticeDay, in: timeZone, locale: core.uiLocale, now: core.now)
        let daylight = duration(trend.solsticeDaylightSeconds)
        return trend.solsticeIsLongest
            ? Text("距日照最长的一天（\(day)）还有 \(trend.solsticeDaysAway) 天，届时日照 \(daylight)。")
            : Text("距日照最短的一天（\(day)）还有 \(trend.solsticeDaysAway) 天，届时日照 \(daylight)。")
    }

    /// 钟与太阳：当地钟面 12:00 与太阳正午差多少（马德里夏天差两个多小时，这是时区画在政治版图上的代价）。
    /// 钟比太阳快 = 太阳正午落在钟面 12:00 之后（钟先到了中午）。差不到 1 分钟就说一致。
    private func clockVersusSun(_ noon: Double) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let noonDate = Date(timeIntervalSince1970: noon)
        guard let clockNoon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: noonDate) else { return nil }
        let minutes = (noonDate.timeIntervalSince(clockNoon) / 60).rounded()
        guard abs(minutes) >= 1 else { return L10n.string("钟与太阳相差不到1分钟", locale: core.uiLocale) }
        let span = ClockText.duration(seconds: abs(minutes) * 60, locale: core.uiLocale)
        let key = minutes > 0 ? "钟比太阳快%@" : "钟比太阳慢%@"
        return String(format: L10n.string(key, locale: core.uiLocale), span)
    }

    /// 主图对读屏是一个元素：念日出、太阳正午、日落与日照时长（用与页面同一批本地化的词）。
    private func sunSummary(_ solar: AstronomySolar) -> String {
        // 没有日出 / 日落（极昼、极夜）时说系统「天气」同一句（「今天无日出」），各语言的性数一致；此前一律「无」，
        // 意大利语成了「Alba Nessuno」（阴性名词配了阳性词）。
        let parts: [(String, Double?, String)] = [
            (L10n.string("日出", locale: core.uiLocale), solar.sunrise, L10n.string("今天无日出", locale: core.uiLocale)),
            (L10n.string("太阳正午", locale: core.uiLocale), solar.solarNoon, L10n.string("无", locale: core.uiLocale)),
            (L10n.string("日落", locale: core.uiLocale), solar.sunset, L10n.string("今天无日落", locale: core.uiLocale)),
        ]
        // 标签照读：荷、波、法、印尼语那一句不带「日出」这个词（「Geen vandaag」「Brak dzisiaj」）。
        let spoken = parts.map { label, instant, missing in "\(label) \(instant.map { time($0) } ?? missing)" }
        return (spoken + ["\(L10n.string("日照时长", locale: core.uiLocale)) \(duration(solar.daylightSeconds))"]).joined(separator: ", ")
    }

    private func compute() {
        guard let selectedZone else { store.clear(); return }
        store.compute(zone: selectedZone, on: core.referenceDate)
    }

    /// 钟点走 ClockText：按设置里的小时制，前导零与面板、排会页一致。
    private func time(_ unix: Double, date: Bool = false) -> String {
        let instant = Date(timeIntervalSince1970: unix)
        if date {
            return ClockText.dateTime(instant, in: timeZone, hourStyle: core.settings.hourStyle, locale: core.uiLocale, now: core.now)
        }
        return ClockText.time(instant, in: timeZone, hourStyle: core.settings.hourStyle)
    }

    /// 「14小时3分钟」：走 `ClockText.duration`。
    private func duration(_ seconds: Double) -> String {
        ClockText.duration(seconds: seconds, locale: core.uiLocale)
    }
}

/// 主图「这一天的天」：几何全在 Rust `presentation.sun_day`（天色、地平线、黄金时刻、太阳高度的线），
/// 这里执行绘图命令、画看的那一刻的太阳（在地平线下就是一圈空心的）、按小时制排横轴刻度。
/// 整张图对读屏是一个元素，念日出、正午、日落与日照时长。只在这一天、地点、尺寸或看的那一刻变了时才去 Rust 算。
private struct SunDayChart: View {
    let dayStart: Double
    let dayEnd: Double
    let coordinate: Coordinate
    let golden: [AstronomyInterval]
    let instant: Date
    let timeZone: TimeZone
    let hourStyle: HourStyle
    let summary: String
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @State private var memo = SunDayMemo()

    static let height: CGFloat = 136

    var body: some View {
        let ticks = tickInstants
        VStack(spacing: 4) {
            GeometryReader { proxy in
                let scene = memo.scene(PresentationCore.SunDayInput(
                    dayStart: dayStart, dayEnd: dayEnd, latitude: coordinate.latitude, longitude: coordinate.longitude,
                    width: proxy.size.width, height: proxy.size.height,
                    golden: golden.map { .init(start: $0.start, end: $0.end) },
                    instant: instant.timeIntervalSince1970, marks: differentiateWithoutColor))
                let increased = contrast == .increased
                ZStack(alignment: .topLeading) {
                    ForEach(Array((scene?.commands ?? []).enumerated()), id: \.offset) { _, command in
                        SceneShape(command: command)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                // 外面一道细描边（与昼夜条同一条规矩）：浅色窗口里白天那截与窗口底几乎同色，没有边图就丢了形状。
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(increased ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary.opacity(0.9)),
                                                                       lineWidth: increased ? 1 : 0.75))
                .overlay(alignment: .topLeading) {
                    if let sun = scene?.sun {
                        SunMark(up: sun.up).frame(width: 14, height: 14).position(x: sun.x, y: sun.y)
                    }
                }
                .modifier(SkyPreInvert())
            }
            .frame(height: Self.height)
            SunDayAxis(tickInstants: ticks, dayStart: dayStart, dayEnd: dayEnd, timeZone: timeZone, hourStyle: hourStyle)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isImage)
        .accessibilityLabel(Text("当天太阳高度变化"))
        .accessibilityValue(Text(verbatim: summary))
    }

    /// 从当天当地午夜起每 6 小时一个刻度（日历事实：换钟那天的 6 小时不一定等于 21,600 秒）。
    private var tickInstants: [Double] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var out: [Double] = []
        var cursor = Date(timeIntervalSince1970: dayStart)
        let end = Date(timeIntervalSince1970: dayEnd)
        while cursor < end, out.count < 8 {
            out.append(cursor.timeIntervalSince1970)
            guard let next = calendar.date(byAdding: .hour, value: 6, to: cursor) else { break }
            cursor = next
        }
        return out
    }
}

struct SunDayAxis: View {
    let tickInstants: [Double]
    let dayStart: Double
    let dayEnd: Double
    let timeZone: TimeZone
    let hourStyle: HourStyle

    var body: some View {
        FractionLayout {
            ForEach(Array(tickInstants.enumerated()), id: \.offset) { _, tick in
                Text(verbatim: ClockText.time(Date(timeIntervalSince1970: tick), in: timeZone, hourStyle: hourStyle))
                    .appFont(.caption).foregroundStyle(.readableSecondary).monospacedDigit()
                    .fixedSize()
                    .fraction((tick - dayStart) / max(1, dayEnd - dayStart))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

@MainActor
private final class SunDayMemo {
    private var input: PresentationCore.SunDayInput?
    private var value: PresentationCore.SunDayScene?

    func scene(_ next: PresentationCore.SunDayInput) -> PresentationCore.SunDayScene? {
        if next == input { return value }
        input = next
        value = PresentationCore.sunDay(next)
        return value
    }
}

/// 看的那一刻的太阳：在天上是金盘与深色外沿（与地图、面板滑块同一颗；光晕在纸色的天上看不出，不画）；沉在地平线下是一圈空心的。
private struct SunMark: View {
    let up: Bool

    var body: some View {
        ZStack {
            if up {
                Circle().fill(LightPalette.sun)
                Circle().strokeBorder(LightPalette.sunRim, lineWidth: 1.5)
            } else {
                Circle().fill(LightPalette.ink.opacity(0.35))
                Circle().strokeBorder(LightPalette.paper.opacity(0.9), lineWidth: 1.5)
            }
        }
        .allowsHitTesting(false)
    }
}

/// 月亮挂在一小块夜空里：夜是主图里同一种墨，月亮与面板地图上的同一颗（暗面一枚深色圆、亮面按月相画）。
/// 地图上那圈月光这里不画：冷启动这一页时那一圈渐变与裁切多占堆（实测），小块夜空里也看不出。
/// 盈月亮面朝右、亏月朝左；南半球看过去左右反过来。外面一道细描边（与主图同一条规矩），反色开着时整块预反一次。
private struct MoonTile: View {
    let illumination: Double
    let waxing: Bool
    let southern: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let increased = contrast == .increased
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(LightPalette.ink)
            Circle().fill(LightPalette.moonDark).frame(width: 30, height: 30)
            MoonLitShape(illumination: illumination)
                .fill(LightPalette.moonLit)
                .frame(width: 30, height: 30)
                .rotationEffect(.degrees(waxing != southern ? 0 : 180))
        }
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(increased ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary.opacity(0.9)),
                                                               lineWidth: increased ? 1 : 0.75))
        .modifier(SkyPreInvert())
    }
}
