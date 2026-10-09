// SPDX-License-Identifier: GPL-3.0-only
//
//  MarketLensView.swift
//  Dayside
//
//  市场时钟：别人的上班时间。每个交易所一行，那座城市今天的天，天下面一道蓝轨是它开着的那几段；一根竖线是 App 正在看的那一刻。
//  状态词说准：开盘中、未开盘、午休中、已收盘；「休市」只给当地今天根本不开的日子（周末、休市日），并写出缘由。
//  下一次开盘或收盘超过一天，写本机的星期与钟点（「本机 周一 6:30 开盘」）。外汇的四个时段收在一个展开里（多数人用不上）。
//  作息与休市日规则在 Rust `markets.*`，真实时刻与休市日表由 `MarketMemo` 在 Foundation 里算。不做行情、不联网。
//

import SwiftUI

struct MarketLensView: View {
    @Environment(TimeCore.self) private var core
    @Bindable var store: MarketStore
    @State private var memo = MarketMemo()
    @State private var peek: Date?
    @State private var showsForex = false

    private var format: ClockFormat { ClockFormat(hourStyle: core.settings.hourStyle, showSeconds: false) }

    var body: some View {
        let reference = core.referenceDate
        let shown = peek ?? reference
        let frame = DayLaneFrame.homeDay(containing: reference)
        let exchanges = MarketCatalog.all.filter { $0.kind == "exchange" }
        let forex = MarketCatalog.all.filter { $0.kind == "fx" }
        let markets = showsForex ? exchanges + forex : exchanges
        let snapshot = memo.rows(at: shown, markets: markets)
        let exchangeRows = snapshot.filter { $0.market.kind == "exchange" }
        VStack(alignment: .leading, spacing: 0) {
            MarketTable(rows: exchangeRows.map { row($0, frame: frame, at: shown) }, frame: frame, reference: reference,
                        spoken: spoken(exchangeRows, at: shown), peek: $peek)
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                MeetingLegend(sky: true, outside: false, rail: "交易时段")
                Spacer(minLength: 0)
                if peek != nil {
                    Button { peek = nil } label: {
                        Label("回到原来的时刻", systemImage: "arrow.uturn.backward").fontWeight(.semibold)
                            .foregroundStyle(Color.primary)
                            .frame(minHeight: 24).contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .appFont(.callout)
                }
            }
            .padding(.top, 10)
            closures(exchangeRows, at: shown)
            DisclosureGroup(isExpanded: $showsForex) {
                if showsForex {
                    VStack(alignment: .leading, spacing: 8) {
                        let forexRows = snapshot.filter { $0.market.kind == "fx" }
                        MarketTable(rows: forexRows.map { row($0, frame: frame, at: shown) }, frame: frame, reference: reference,
                                    spoken: spoken(forexRows, at: shown), peek: $peek)
                        Text("外汇时段按业界惯例的当地时间，不是交易所；没有休市日表，只跳过当地周末。")
                            .appFont(.caption).foregroundStyle(.readableSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 10)
                }
            } label: {
                Text("外汇时段").appFont(.headline)
            }
            .padding(.top, 28)
            footnotes(exchanges)
        }
        // 别处拖了时间，竖线回到 App 正在看的那一刻（点出来的那一刻作废）。
        .onChange(of: core.displayOffset) { peek = nil }
        #if DEBUG
        // 夹具等工具窗跳完时间（`MEANTIME_UI_TEST_JUMP_TO`，200 毫秒）再看别的时刻。
        .task { try? await Task.sleep(for: .milliseconds(600)); applyFixtures() }
        #endif
        .accessibilityIdentifier("markets")
    }

    // MARK: - 一行

    private func row(_ row: MarketStore.Row, frame: DayLaneFrame, at date: Date) -> MarketTable.Row {
        let locale = core.uiLocale
        let market = row.market
        let sessions = row.spans.compactMap { span -> ClosedRange<Double>? in
            let a = MomentTable.fraction(of: span.start, in: frame), b = MomentTable.fraction(of: span.end, in: frame)
            return b > a ? a...b : nil
        }
        return MarketTable.Row(id: market.id, name: L10n.string(market.nameKey, locale: locale), hours: hoursText(market),
                               status: L10n.string(Self.statusKey(row.status), locale: locale),
                               reason: reason(row), next: Self.nextText(row.status, from: date, format: format, locale: locale),
                               open: row.status.isOpen, coordinate: market.coordinate, sessions: sessions)
    }

    /// 状态词只按 Rust 给的那一种关来选，「休市」只给当地今天不开的日子。
    static func statusKey(_ status: MarketStatus) -> String {
        switch status.phase ?? (status.isOpen ? "open" : "closed") {
        case "open": "开盘中"
        case "beforeOpen": "未开盘"
        case "break": "午休中"
        case "noSession": "休市"
        default: "已收盘"
        }
    }

    /// 休市的缘由：休市日写名字，周末写「当地周末」（洛杉矶周五晚上东京已是周六，只写「休市」会让人以为那边放假）。
    private func reason(_ row: MarketStore.Row) -> String? {
        guard row.status.phase == "noSession" else { return nil }
        return L10n.string(row.todayHolidayKey ?? "当地周末", locale: core.uiLocale)
    }

    /// 下一次开盘或收盘。一天以内写还有多久与本机的钟点：「2小时5分钟后收盘（本机 13:00）」，开着且当天还有下一段时写午休；
    /// 超过一天（跨周末、长假）直接写本机的星期与钟点：「本机 周一 6:30 开盘」（此前写「57小时57分钟后开盘（本机17:00）」，
    /// 读起来像今天下午）。收盘与午休总在一天以内。
    static func nextText(_ status: MarketStatus, from date: Date, format: ClockFormat, locale: Locale) -> String? {
        guard let change = status.changeDate else { return nil }
        let seconds = change.timeIntervalSince(date)
        guard seconds > 0 else { return nil }
        let clock = { (moment: Date) in TimeFormatting.string(for: moment, in: .current, format: format) }
        if !status.isOpen, seconds > 86_400 {
            let when = "\(ClockText.weekday(change, in: .current, locale: locale)) \(clock(change))"
            return String(format: L10n.string("本机 %@ 开盘", locale: locale), locale: locale, when)
        }
        let resume = status.isOpen ? status.breakUntilDate.map(clock) : nil
        return changeLine(isOpen: status.isOpen, seconds: seconds, clock: clock(change), breakUntilClock: resume, locale: locale)
    }

    /// 开盘、收盘与午休句共用方向时长的变格，句式保留各语言自己的语序。
    nonisolated static func changeLine(isOpen: Bool, seconds: Double, clock: String,
                                       breakUntilClock: String? = nil, locale: Locale) -> String {
        let duration = ClockText.directionalDuration(seconds: seconds, locale: locale)
        if isOpen {
            if let breakUntilClock {
                return String(format: L10n.string("%1$@后午休，本机 %2$@ 恢复", locale: locale), locale: locale,
                              duration, breakUntilClock)
            }
            return String(format: L10n.string("%1$@后收盘（本机 %2$@）", locale: locale), locale: locale, duration, clock)
        }
        return String(format: L10n.string("%1$@后开盘（本机 %2$@）", locale: locale), locale: locale, duration, clock)
    }

    /// 「9:30–16:00 当地」或两段式的「9:00–11:30、12:30–15:30 当地」。
    private func hoursText(_ market: MarketDefinition) -> String {
        let parts = market.sessions.map { session in
            ClockText.range(wallTime(session.startMinute), wallTime(session.endMinute))
        }
        return String(format: L10n.string("%@ 当地", locale: core.uiLocale),
                      parts.joined(separator: L10n.string("、", locale: core.uiLocale)))
    }

    private func wallTime(_ minute: Int) -> String {
        TimeFormatting.string(for: Date(timeIntervalSince1970: Double(minute) * 60), in: .gmt, format: format)
    }

    /// 读屏念的值：竖线在本机几点，各市场那时开没开。
    private func spoken(_ rows: [MarketStore.Row], at date: Date) -> String {
        let locale = core.uiLocale
        var parts = [String(format: L10n.string("竖线在本机 %@", locale: locale), TimeFormatting.string(for: date, in: .current, format: format))]
        for row in rows {
            parts.append("\(L10n.string(row.market.nameKey, locale: locale)) \(L10n.string(Self.statusKey(row.status), locale: locale))")
        }
        return parts.joined(separator: ", ")
    }

    // MARK: - 接下来的休市日

    /// 每个有休市日表的交易所下一个休市日（今天就是的话就是今天），同一天同一个节日的几家并成一行，按日子排。
    @ViewBuilder private func closures(_ rows: [MarketStore.Row], at date: Date) -> some View {
        let items = Self.closureItems(rows, at: date)
        if !items.isEmpty {
            Text("接下来的休市日").appFont(.headline).accessibilityAddTraits(.isHeader).padding(.top, 28)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items, id: \.id) { item in
                    let day = closureDay(item)
                    let names = DSTWatchLensView.list(item.markets.map { L10n.string($0.nameKey, locale: core.uiLocale) }, locale: core.uiLocale)
                    Text("\(Text(verbatim: day).fontWeight(.semibold).monospacedDigit())\(Text(verbatim: " · \(L10n.string(item.nameKey, locale: core.uiLocale)) · \(names)"))")
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("按各市场当地的日期")
                    .appFont(.caption).foregroundStyle(.readableSecondary)
            }
            .padding(.top, 10)
        }
    }

    struct ClosureItem {
        let date: String
        let nameKey: String
        let markets: [MarketDefinition]
        var id: String { "\(date)/\(nameKey)" }
    }

    static func closureItems(_ rows: [MarketStore.Row], at date: Date) -> [ClosureItem] {
        var items: [ClosureItem] = []
        for row in rows where row.market.hasHolidays {
            guard let holiday = row.todayHolidayKey.map({ MarketHoliday(date: MarketStore.civilDate(date, in: row.market.timeZone), nameKey: $0) })
                    ?? row.nextHoliday else { continue }
            if let index = items.firstIndex(where: { $0.date == holiday.date && $0.nameKey == holiday.nameKey }) {
                items[index] = ClosureItem(date: holiday.date, nameKey: holiday.nameKey, markets: items[index].markets + [row.market])
            } else {
                items.append(ClosureItem(date: holiday.date, nameKey: holiday.nameKey, markets: [row.market]))
            }
        }
        return items.sorted { $0.date < $1.date }
    }

    /// 「2026-11-26」→ 按界面语言写日期与星期（那个市场当地的日子）。
    private func closureDay(_ item: ClosureItem) -> String {
        let zone = item.markets.first?.timeZone ?? .gmt
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = zone
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: item.date) else { return item.date }
        return ClockText.day(date.addingTimeInterval(12 * 3600), in: zone, locale: core.uiLocale, now: core.now, weekday: true)
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - 页脚

    @ViewBuilder private func footnotes(_ exchanges: [MarketDefinition]) -> some View {
        let locale = core.uiLocale
        let uncovered = exchanges.filter { !$0.hasHolidays }.map { L10n.string($0.nameKey, locale: locale) }
        VStack(alignment: .leading, spacing: 6) {
            if !uncovered.isEmpty {
                Text(verbatim: String(format: L10n.string("%@的休市日未收录，只跳过当地周末。", locale: locale),
                                      DSTWatchLensView.list(uncovered, locale: locale)))
                    .fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup("休市日怎么算") {
                Text("开收盘按各市场公布的常规交易时段算，不含盘前盘后与半日市；时刻按本机时间显示。休市日由规则算出（美英是「几月第几个星期几」加复活节，日本还有春分秋分与振替休日，中港的农历日子来自系统农历），没收录的市场只跳过当地周末。")
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
        .appFont(.caption).foregroundStyle(.readableSecondary)
        .padding(.top, 28)
    }

    #if DEBUG
    /// 截图与转储夹具（只在测试宿主）：`MEANTIME_UI_TEST_MARKETS_FX=1` 打开外汇时段；`MEANTIME_UI_TEST_MARKETS_PEEK_HOURS=<小时>`
    /// 在时间轴上看那么多小时以后。
    private func applyFixtures() {
        guard ApplicationSession.isTesting else { return }
        let environment = ProcessInfo.processInfo.environment
        if environment["MEANTIME_UI_TEST_MARKETS_FX"] == "1" { showsForex = true }
        if let hours = environment["MEANTIME_UI_TEST_MARKETS_PEEK_HOURS"].flatMap(Double.init) {
            peek = core.referenceDate.addingTimeInterval(hours * 3600)
        }
    }
    #endif
}
