// SPDX-License-Identifier: GPL-3.0-only
//
//  TimeUnderstanding.swift
//  TahoeTime
//
//  「听懂时间」：Rust `understand.parse` 在任意一段文字里找出每一次提到的时间
//  （日期、钟点、时间段、相对时间、精确时刻、时区或地点、「在哪儿是几点」的目标），这里用 Foundation 把它落成
//  具体时刻：星期几是哪天、没写年的月日取哪一年、夏令时的缺口与重复一小时（沿用 `TimeInput.resolveWallTime`）。
//
//  Rust 的结构用带标签的枚举解码，约定对不上时当作没读出、不崩；
//  日期拼回来要还是同一天（平年的 2 月 29 日、Apia 跳过的 2011-12-30 不存在）；时间段两端比较带秒，夏令时重复那一小时里
//  终点按每个起点各自推；时区选项与读法先全部建好、按意思的标识选（七月的 PST 两项都在表里，选哪项表都不变）；
//  一国几个时区里钟走法一样的只留一个；沿用的日期跟着来源那一处选的读法走。
//
//  写信人自述在哪里（「我在柏林」）：「我这边」先按那里算；没写时由同一行写明时区的那处推出固定偏移
//  （±14 小时内、归到一刻钟），推出来两处从此同一刻。
//
import Foundation

nonisolated enum TimeUnderstanding {
    // MARK: - Rust 给的结构

    struct Clock: Decodable, Hashable, Sendable {
        let hour: Int
        let minute: Int
        let second: Int
        /// 午夜 = 次日 0 点。
        let dayOffset: Int

        /// 一天里的第几秒。时间段两端比较用它，秒也算（「10:20:10–10:20:20」是 10 秒，不是跨夜）。
        var secondOfDay: Int { hour * 3_600 + minute * 60 + second }
        func later(days: Int) -> Clock { Clock(hour: hour, minute: minute, second: second, dayOffset: dayOffset + days) }
        var key: String { String(format: "%02d:%02d:%02d%+d", hour, minute, second, dayOffset) }
    }

    enum DateSpec: Decodable, Hashable, Sendable {
        case absolute(year: Int, month: Int, day: Int)
        /// 没写年：最近的将来那一年（今年这一天过去一个月以上就是明年）。
        case monthDay(month: Int, day: Int)
        case offset(days: Int)
        /// ISO 星期（1 = 星期一）；`week` 是 this / next / last，nil = 从今天起下一个（今天就是也算今天）。
        case weekday(Int, week: String?)

        private enum Key: String, CodingKey { case kind, year, month, day, days, weekday, week }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            switch try c.decode(String.self, forKey: .kind) {
            case "absolute":
                self = .absolute(year: try c.decode(Int.self, forKey: .year), month: try c.decode(Int.self, forKey: .month),
                                 day: try c.decode(Int.self, forKey: .day))
            case "monthDay": self = .monthDay(month: try c.decode(Int.self, forKey: .month), day: try c.decode(Int.self, forKey: .day))
            case "offset": self = .offset(days: try c.decode(Int.self, forKey: .days))
            case "weekday": self = .weekday(try c.decode(Int.self, forKey: .weekday), week: try c.decodeIfPresent(String.self, forKey: .week))
            case let kind: throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown date kind \(kind)")
            }
        }

        var key: String {
            switch self {
            case let .absolute(year, month, day): "\(year)-\(month)-\(day)"
            case let .monthDay(month, day): "\(month)-\(day)"
            case let .offset(days): "\(days)d"
            case let .weekday(weekday, week): "w\(weekday)\(week ?? "")"
            }
        }
    }

    indirect enum Zone: Decodable, Hashable, Sendable {
        /// 随夏令时走的地区时间（ET、Central、北京时间、Berlin time）。
        case region(String)
        /// 固定偏移（UTC+8、PST = UTC−8）；`region` 是缩写所指的地区。
        case fixed(minutes: Int, region: String?)
        /// 有歧义的候选：abbreviation（IST / CST / BST）、country（一国几个时区）、city（同名城市）。
        case options(reason: String, [Zone])
        case city(index: Int, name: String, iana: String, population: UInt64? = nil)
        /// 没有城市索引（快捷指令进程）时原样交回的地名。
        case place(String)
        /// 「本地时间 / my time / 我这边」。
        case local

        /// 界面上说「没认出 X」时的 X。
        var written: String {
            switch self {
            case .region(let identifier), .city(_, _, let identifier, _): identifier
            case .place(let query): query
            case .fixed(let minutes, _): String(format: "UTC%+d:%02d", minutes / 60, abs(minutes) % 60)
            case .options(_, let options): options.first?.written ?? ""
            case .local: ""
            }
        }

        private enum Key: String, CodingKey { case kind, iana, minutes, region, reason, options, cityIndex, name, query, population }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            switch try c.decode(String.self, forKey: .kind) {
            case "region": self = .region(try c.decode(String.self, forKey: .iana))
            case "fixed": self = .fixed(minutes: try c.decode(Int.self, forKey: .minutes), region: try c.decodeIfPresent(String.self, forKey: .region))
            case "options": self = .options(reason: try c.decodeIfPresent(String.self, forKey: .reason) ?? "", try c.decode([Zone].self, forKey: .options))
            case "city":
                self = .city(index: try c.decode(Int.self, forKey: .cityIndex), name: try c.decode(String.self, forKey: .name),
                             iana: try c.decode(String.self, forKey: .iana), population: try c.decodeIfPresent(UInt64.self, forKey: .population))
            case "place": self = .place(try c.decode(String.self, forKey: .query))
            case "local": self = .local
            case let kind: throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown zone kind \(kind)")
            }
        }
    }

    /// 同一段字的另一种读法。
    enum Alternative: Decodable, Hashable, Sendable {
        /// 「10/3」另一种顺序。
        case dateOrder(DateSpec)
        /// 读成了钟点（「15.03」），也可能是这个日期。
        case dotDate(DateSpec)
        /// 读成了日期，也可能是这个钟点。
        case dotClock(Clock)

        private enum Key: String, CodingKey { case kind, date, time }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            switch try c.decode(String.self, forKey: .kind) {
            case "dateOrder": self = .dateOrder(try c.decode(DateSpec.self, forKey: .date))
            case "dotDate": self = .dotDate(try c.decode(DateSpec.self, forKey: .date))
            case "dotClock": self = .dotClock(try c.decode(Clock.self, forKey: .time))
            case let kind: throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown alternative \(kind)")
            }
        }
    }

    /// 读到了、但写得不成立的一段（invalidDate / invalidTime / invalidOffset / conflictingPeriod / conflictingDeadline /
    /// conflictingDate）：这一处不算读成，界面说出哪一段不对。
    struct Issue: Decodable, Hashable, Sendable {
        let kind: String
        let text: String
        let span: [Int]
    }

    /// 有明确线索却查不到的地名；`role` 是 place 或 target。
    struct Unresolved: Decodable, Hashable, Sendable {
        let text: String
        let span: [Int]
        let role: String
    }

    struct Part: Decodable, Hashable, Sendable {
        /// date | time | end | duration | zone | target | instant。
        let kind: String
        let span: [Int]
    }

    /// 一次提到的时间。`span` 与各部分的位置是原文的 UTF-16 下标。
    struct Mention: Decodable, Hashable, Sendable {
        let span: [Int]
        let parts: [Part]
        /// 几天共用一个钟点（「周二至周四 9–12 点」「3 日和 19 日」）时引擎每天给一处，同一组的几天带同一个号
        /// （组里第一天在 `mentions` 里的下标，只比相等）；几天在 `mentions` 里相邻、按原文顺序，原文范围相同。
        /// 不在一组里的没有这一项。换算页把一组显示成一行（CONVENTIONS 第 12 条）。
        let series: Int?
        var date: DateSpec?
        /// 没写日期，沿用了同一段落里前面 `dateFrom` 那一处的。
        var dateInherited = false
        var dateFrom: Int?
        /// nil = 只有日期（列出、灰、不可选）。
        var time: Clock?
        /// 钟点不是写出来的：eod（下班前，默认 17:00）、aoe / dayend / midnight（23:59）。
        var timeImplied: String?
        var end: Clock?
        var durationMinutes: Int?
        var relativeMinutes: Int?
        var instant: Int?
        var source: Zone?
        /// 句中地点建议的国家身份；单时区国家也保留 ISO 码，说明文字不把国家叫成时区名。
        var sentencePlaceCountry: String? = nil
        var target: Zone?
        var alternatives: [Alternative] = []
        var unresolved: [Unresolved] = []
        var issues: [Issue] = []
        var language: String?
        /// 等价组：同一行里只隔着分隔符或连接词的几处同一个号。
        var group = 0

        private enum Key: String, CodingKey {
            case span, parts, series, date, dateInherited, dateFrom, time, timeImplied, end, durationMinutes, relativeMinutes, instant,
                 source, sentencePlaceCountry, target, alternatives, unresolved, issues, language, group
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            span = try c.decode([Int].self, forKey: .span)
            parts = try c.decode([Part].self, forKey: .parts)
            series = try c.decodeIfPresent(Int.self, forKey: .series)
            date = try c.decodeIfPresent(DateSpec.self, forKey: .date)
            dateInherited = try c.decodeIfPresent(Bool.self, forKey: .dateInherited) ?? false
            dateFrom = try c.decodeIfPresent(Int.self, forKey: .dateFrom)
            time = try c.decodeIfPresent(Clock.self, forKey: .time)
            timeImplied = try c.decodeIfPresent(String.self, forKey: .timeImplied)
            end = try c.decodeIfPresent(Clock.self, forKey: .end)
            durationMinutes = try c.decodeIfPresent(Int.self, forKey: .durationMinutes)
            relativeMinutes = try c.decodeIfPresent(Int.self, forKey: .relativeMinutes)
            instant = try c.decodeIfPresent(Int.self, forKey: .instant)
            source = try c.decodeIfPresent(Zone.self, forKey: .source)
            // 可选的显示身份不影响钟点解码；旧输出没有这项时仍沿用城市 / 时区的叫法。
            sentencePlaceCountry = try? c.decodeIfPresent(String.self, forKey: .sentencePlaceCountry)
            target = try c.decodeIfPresent(Zone.self, forKey: .target)
            alternatives = try c.decodeIfPresent([Alternative].self, forKey: .alternatives) ?? []
            unresolved = try c.decodeIfPresent([Unresolved].self, forKey: .unresolved) ?? []
            issues = try c.decodeIfPresent([Issue].self, forKey: .issues) ?? []
            language = try c.decodeIfPresent(String.self, forKey: .language)
            group = try c.decodeIfPresent(Int.self, forKey: .group) ?? 0
        }
    }

    /// 写信人自述在哪里（「我在柏林」，「我这边」说的那边）：`place` 与一处的 source 同一种写法，`span` 是那句话的位置。
    struct Writer: Decodable, Sendable {
        let place: Zone
        let span: [Int]
    }

    struct Output: Decodable, Sendable {
        var mentions: [Mention] = []
        /// 文字太长只读到这里（原文的 UTF-16 下标）；nil = 整段都读了。界面要说出来，不悄悄截。
        var truncatedAt: Int?
        /// 这段文字命中的语言（按命中次数从多到少）。
        var languages: [String] = []
        /// 写信人自述在哪里；没写、或这一句对不上约定时是 nil。
        var writer: Writer?
        /// Rust 与 Swift 的约定对不上（Rust 报错、解码失败）：当作什么都没读出，界面说「没读懂」，不让用户的输入把 App 弄崩。
        var failed = false

        init() {}

        private enum Key: String, CodingKey { case mentions, truncatedAt, languages, writer }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            mentions = try c.decode([Mention].self, forKey: .mentions)
            truncatedAt = try c.decodeIfPresent(Int.self, forKey: .truncatedAt)
            languages = try c.decodeIfPresent([String].self, forKey: .languages) ?? []
            // 这一句没给或对不上：当作没写，不让整段读失败。
            writer = try? c.decodeIfPresent(Writer.self, forKey: .writer)
        }
    }

    /// 读一段文字。`region` 决定英文或判不出语言时「10/3」按美国写法（10 月 3 日）还是其余地区（3 月 10 日）读，
    /// `language` 是界面语言（地区也没有时的回退）。没有字母的输入（「9:00」「1727000000」）用不上地名，不打开城市索引。
    static func read(_ text: String, region: String? = Locale.current.region?.identifier, language: String? = nil) -> Output {
        struct Input: Encodable { let text: String; let region: String?; let language: String?; let cityHandle: UInt64? }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return Output() }
        let needsPlaces = text.unicodeScalars.contains { CharacterSet.letters.contains($0) }
        let handle = needsPlaces ? CityIndex.shared.rustHandle : nil
        do {
            return try RustCore.attempt("understand.parse", Input(text: text, region: region, language: language, cityHandle: handle))
        } catch {
            var failed = Output()
            failed.failed = true
            return failed
        }
    }

    static func parse(_ text: String, region: String? = Locale.current.region?.identifier, language: String? = nil) -> [Mention] {
        read(text, region: region, language: language).mentions
    }

    // MARK: - 选项

    /// 一处的一种读法：主读法 + 每个备选各一种（「10/3」的另一种顺序、「15.03」是钟点还是日期）。
    /// `id` 按内容起名，界面记住用户选的是哪种意思，不记第几项。
    struct Reading: Identifiable, Hashable, Sendable {
        let id: String
        let date: DateSpec?
        let time: Clock?

        init(date: DateSpec?, time: Clock?) {
            self.date = date
            self.time = time
            id = "\(date?.key ?? "-")|\(time?.key ?? "-")"
        }
    }

    static func readings(of mention: Mention) -> [Reading] {
        var all = [Reading(date: mention.date, time: mention.time)]
        let ownDate = mention.date != nil && !mention.dateInherited
        for alternative in mention.alternatives {
            switch alternative {
            case .dateOrder(let date): all.append(Reading(date: date, time: mention.time))
            // 「15.03」若是 3 月 15 日，钟点就没了；这一处本来就另写了日期时这个读法说不通，不给。
            case .dotDate(let date) where !ownDate: all.append(Reading(date: date, time: nil))
            case .dotClock(let clock) where mention.time == nil: all.append(Reading(date: nil, time: clock))
            default: break
            }
        }
        // 下班前没写钟点：默认 17:00，也可以按 18:00 算；界面标明它是可修改的默认值。
        if mention.timeImplied == "eod", let time = mention.time, time.hour == 17, time.minute == 0 {
            all.append(Reading(date: mention.date, time: Clock(hour: 18, minute: 0, second: 0, dayOffset: time.dayOffset)))
        }
        var seen = Set<String>()
        return all.filter { seen.insert($0.id).inserted }
    }

    /// 一个来源时区的选项。`id` 按意思起名（`zone:Asia/Tokyo`、`offset:-480@America/Los_Angeles`、`local`），
    /// 界面记住用户选的是哪个意思；七月的 PST 两项都在表里，选哪项表都不变（此前只在选第一项时才插进
    /// 「按地区现在的钟」，选第二项时表就变了）。
    struct ZoneOption: Identifiable, Hashable, Sendable {
        enum Kind: Hashable, Sendable {
            /// 随夏令时走的地区时间（城市、国家的一个时区、ET、Berlin time）。
            case region
            /// 按字面的固定偏移（UTC+8、一月的 PST）。
            case literal
            /// 夏令时期间写了标准时间缩写：按那个地区现在的钟（七月的 PST → 洛杉矶现在的钟），`literal` 是字面偏移。
            case regionalClock(literal: TimeZone)
            /// 「我这边 / my time」。
            case local
            /// 句中地点建议的备选：读者自己的时区，粘贴时也明确称为本机。
            case readerLocal
            /// 原文写了写信人在哪儿（「我在柏林」）：「我这边」按那里算。
            case writer
            /// 写信人没写、由同一行写明时区的那处推出的固定偏移。
            case writerInferred
        }

        /// 城市索引认出的城（界面上写城市自己的名字，不写时区的代表城市：「Winston-Salem」不写成纽约）。
        struct CityRef: Hashable, Sendable {
            let index: Int
            let name: String
            var population: UInt64? = nil
        }

        let id: String
        let zone: TimeZone
        let kind: Kind
        /// 这个选项说的是哪个地区（固定偏移的缩写是它所指的地区）：按用户自己的地点排序用。
        let anchor: String?
        var city: CityRef? = nil
    }

    /// 「我这边」按哪里算：原文写了写信人在哪儿（`place` 是那句话里地名的叫法，说不出给空串、界面退回通用叫法），
    /// 或由同一行写明时区的那处推出固定偏移（`placeAndClock` 是那一处的地名与钟点）。
    enum WriterBasis: Sendable {
        case written(Zone, place: String)
        case inferred(offsetMinutes: Int, placeAndClock: String, other: Mention)
    }

    /// 文字从哪儿来：打的字里「我这边」是这台 Mac；粘贴进来的（邮件、服务菜单）里是写信人那边。
    enum Origin: Sendable { case typed, pasted }

    struct Context: Sendable {
        /// 「今天」：只有钟点时落在这一天（面板穿梭到别的时刻、计时器选了别的日子时是那一天）。
        var reference: Date
        /// 「现在」：「两小时后」从这一刻算（计时器闹钟框按提交那一刻，不按窗口打开那一刻）。
        var now: Date = .now
        /// 文字里没写时区时的来源地点。
        var fallback: TimeZone
        /// 这台 Mac 的时区。
        var home: TimeZone = .current
        /// 用户自己的地点（有歧义的缩写与国家的几个时区按它们排）。
        var preferredZones: [String] = []
        var origin: Origin = .typed
    }

    /// 用户对一处的选择（都按意思的标识记；nil = 默认，第一项）。
    struct Choice: Hashable, Sendable {
        var zone: String?
        var reading: String?
        init(zone: String? = nil, reading: String? = nil) {
            self.zone = zone
            self.reading = reading
        }
    }

    /// 文字里的时区 → 全部选项（第一项是默认）。`date` 用来判断七月的 PST 该不该先按地区现在的钟；
    /// `writer` 是「我这边」时写信人的地点（写了或推出了在哪里），先按那里算。
    static func zoneOptions(_ zone: Zone?, date: DateSpec?, context: Context, writer: WriterBasis? = nil) -> [ZoneOption] {
        guard let zone else { return [] }
        var result: [ZoneOption] = []
        func add(_ option: ZoneOption) {
            if !result.contains(where: { $0.id == option.id }) { result.append(option) }
        }
        func addRegion(_ identifier: String) {
            guard let tz = TimeZone(identifier: identifier) else { return }
            add(ZoneOption(id: "zone:\(identifier)", zone: tz, kind: .region, anchor: identifier))
        }
        func expand(_ zone: Zone) {
            switch zone {
            case .region(let identifier):
                addRegion(identifier)
            case let .city(index, name, identifier, population):
                guard let tz = TimeZone(identifier: identifier) else { return }
                add(ZoneOption(id: "zone:\(identifier)", zone: tz, kind: .region, anchor: identifier,
                               city: .init(index: index, name: name, population: population)))
            case let .fixed(minutes, regionID):
                guard let literal = TimeZone(secondsFromGMT: minutes * 60) else { return }
                if let regionID, let region = TimeZone(identifier: regionID) {
                    switch relation(literal: literal, region: region, date: date, context: context) {
                    case .same:
                        // 字面偏移就是那边那天的钟（一月的 PST、印度的 IST）：按地区算，名字与夏令时都对，不另给「按字面」。
                        addRegion(regionID)
                        return
                    case .daylight:
                        add(ZoneOption(id: "zone:\(regionID)", zone: region, kind: .regionalClock(literal: literal), anchor: regionID))
                    case .other:
                        break
                    }
                }
                add(ZoneOption(id: "offset:\(minutes)@\(regionID ?? "")", zone: literal, kind: .literal, anchor: regionID))
            case let .options(reason, options):
                if reason == "nearby" {
                    // 附近地点保持在前；本机选项不借写信人或用户收藏改排。
                    for option in options {
                        if option == .local {
                            add(ZoneOption(id: "local", zone: context.home, kind: .readerLocal, anchor: context.home.identifier))
                        } else {
                            expand(option)
                        }
                    }
                    return
                }
                let start = result.count
                options.forEach(expand)
                var expanded = Array(result[start...])
                result.removeSubrange(start...)
                if reason == "sentence" {
                    // 句中地点是建议，保持它在第一项；本机与粘贴时的用户地点让读者改选。
                    expanded.forEach(add)
                    add(ZoneOption(id: "local", zone: context.home, kind: .readerLocal, anchor: context.home.identifier))
                    if context.origin == .pasted {
                        context.preferredZones.forEach { identifier in
                            guard identifier != context.home.identifier,
                                  !expanded.contains(where: { $0.zone.identifier == identifier }),
                                  let tz = TimeZone(identifier: identifier) else { return }
                            add(ZoneOption(id: "zone:\(identifier)", zone: tz, kind: .region, anchor: identifier))
                        }
                    }
                    return
                }
                // 用户自己的地点里有的排前面（加了孟买的人写 IST 多半是印度时间；加了丹佛的人说「美国」先给山地时间）。
                let mine = expanded.filter { option in option.anchor.map { context.preferredZones.contains($0) } ?? false }
                expanded = mine + expanded.filter { !mine.contains($0) }
                if reason == "city" {
                    // 先按完整候选表求门槛，再保留原顺序取六项。
                    let largest = expanded.compactMap { $0.city?.population }.max() ?? 0
                    let minimum = largest / 10 + (largest % 10 == 0 ? 0 : 1)
                    expanded = Array(expanded.lazy.filter { option in
                        guard let population = option.city?.population else { return true }
                        return population >= minimum || option.anchor.map { context.preferredZones.contains($0) } == true
                    }.prefix(6))
                }
                if reason == "country" { expanded = distinctClocks(expanded, from: context.reference) }
                expanded.forEach(add)
            case .place(let query):
                addRegion(query)
            case .local:
                // 写信人写了或推出了在哪里就先按那里算；后面仍是今天的选项（本机、粘贴时的用户地点），同一时区不列两遍。
                var listed = Set<String>()
                func addOnce(_ option: ZoneOption) {
                    if listed.insert(option.zone.identifier).inserted { add(option) }
                }
                if case .written(let place, _)? = writer, place != .local,
                   let first = zoneOptions(place, date: date, context: context).first {
                    addOnce(ZoneOption(id: "writer:\(first.zone.identifier)", zone: first.zone, kind: .writer, anchor: first.anchor, city: first.city))
                }
                if case .inferred(let minutes, _, _)? = writer, let fixed = TimeZone(secondsFromGMT: minutes * 60) {
                    addOnce(ZoneOption(id: "writer:offset:\(minutes)", zone: fixed, kind: .writerInferred, anchor: nil))
                }
                addOnce(ZoneOption(id: "local", zone: context.home, kind: .local, anchor: context.home.identifier))
                // 粘贴进来的「我这边」是写信人那边：用户自己的地点都给出来让他改。
                if context.origin == .pasted {
                    context.preferredZones.forEach { identifier in
                        guard let tz = TimeZone(identifier: identifier) else { return }
                        addOnce(ZoneOption(id: "zone:\(identifier)", zone: tz, kind: .region, anchor: identifier))
                    }
                }
            }
        }
        expand(zone)
        return result
    }

    private enum Relation { case same, daylight, other }

    /// 字面偏移与缩写所指地区那天的钟：一样（一月的 PST）、地区在夏令时而写的是它的标准时间（七月的 PST）、别的。
    private static func relation(literal: TimeZone, region: TimeZone, date: DateSpec?, context: Context) -> Relation {
        let calendar = Calendar.gregorianUTC(region)
        guard let day = civilDay(date, reference: context.reference, in: region),
              let noon = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12)) else { return .other }
        let regional = region.secondsFromGMT(for: noon)
        if literal.secondsFromGMT() == regional { return .same }
        return region.isDaylightSavingTime(for: noon) && literal.secondsFromGMT() == regional - 3_600 ? .daylight : .other
    }

    /// 一国几个时区里钟走法一样的只留第一个（纽约、底特律、路易斯维尔都是美东；雅加达与坤甸都是西印尼）。
    /// 比参考时刻起一年里每半个月的偏移与之后两次换钟的时刻，都相同才算一样。
    private static func distinctClocks(_ options: [ZoneOption], from reference: Date) -> [ZoneOption] {
        func fingerprint(_ zone: TimeZone) -> [Double] {
            let samples = (0..<25).map { Double(zone.secondsFromGMT(for: reference.addingTimeInterval(Double($0) * 15 * 86_400))) }
            let first = zone.nextDaylightSavingTimeTransition(after: reference)
            let second = first.flatMap { zone.nextDaylightSavingTimeTransition(after: $0) }
            return samples + [first?.timeIntervalSince1970 ?? 0, second?.timeIntervalSince1970 ?? 0]
        }
        var seen: [[Double]] = []
        return options.filter { option in
            let print = fingerprint(option.zone)
            guard !seen.contains(print) else { return false }
            seen.append(print)
            return true
        }
    }

    // MARK: - 落成时刻

    struct Resolved: Hashable, Sendable {
        /// 一个起点与它的终点。夏令时重复那一小时里有两个起点，终点各自推。
        struct Interval: Hashable, Sendable {
            let start: Date
            let end: Date?
        }

        struct Gap: Hashable, Sendable {
            let at: Date
            let before: Int
            let after: Int
        }

        enum Problem: Hashable, Sendable {
            /// 只有日期（列出、灰、不可选）。
            case dateOnly
            /// 写得不成立的部分（Rust 报的）。
            case issues([Issue])
            /// 日期在这个时区不存在（平年的 2 月 29 日、Apia 跳过的 2011-12-30）。
            case invalidDate
            /// 钟点落在夏令时拨快的缺口里。
            case nonexistentTime(Gap?)
            /// 写了时区却一项都落不成（「America/Nowhere」这种系统没有的标识符）：不拿本地时区顶替。
            case unresolvedPlace(String)
        }

        enum Note: Hashable, Sendable {
            /// 七月写 PST：按地区现在的钟理解了，字面偏移是 `literal`。
            case standardAbbreviationDuringDaylightTime(literal: TimeZone, region: TimeZone)
            /// 钟点没明确写地点，先建议句中提到的地方；改选后仍保留这句说明。
            case sentenceSuggestion(ZoneOption)
            /// 钟点是按默认算的（下班前 17:00、AoE / 今天之内 23:59），界面标明、可改。
            case impliedTime(String)
            /// 粘贴的文字里「我这边」指写信人那边，没说在哪：先按你这里算，要用户确认。
            case localMeansTheWriter
            /// 原文写了写信人在哪儿（「我在柏林」）：「我这边」按那里算，`place` 是那句话里的地名。
            case localIsTheWriter(place: String)
            /// 「我这边」由同一行写明时区的那处推出（「3pm my time / 9am 纽约」→ UTC+2）。
            case localInferredFrom(offsetMinutes: Int, placeAndClock: String, other: Mention)
            /// 目标地名没认出来。
            case unresolvedTarget(String)
            /// 有线索的地名没认出来（「9am in Москвzz」「w celu udziału」）：照来源地点换算，标出来。
            case unresolvedPlace(String)
        }

        let mention: Mention
        let readings: [Reading]
        let reading: Reading
        let zoneOptions: [ZoneOption]
        let zoneOption: ZoneOption
        /// 文字里写了时区或地点。
        let zoneWritten: Bool
        /// 那一天（来源时区的民用日）；只有日期的一处也有。
        let day: DateComponents?
        let intervals: [Interval]
        let target: TimeZone?
        let problem: Problem?
        let notes: [Note]
        /// 没写日期、锚到了等价组里第一处那一天的一处。
        let anchoredToGroup: Bool

        var zone: TimeZone { zoneOption.zone }
        var start: Date? { intervals.first?.start }
        var end: Date? { intervals.first?.end }
    }

    /// 整段：每处按各自的选择落成时刻；沿用日期的那几处跟着来源那一处选的读法走；同一行里写同一刻、没写日期的几处
    /// 锚到组里第一处的那一天（`groupAnchor`）。`choices` 的键是 `Output.mentions` 的下标。
    /// 「我这边」：原文写了写信人在哪儿就按那里算；没写时由同组写明时区的那处推（推不出来照旧）。
    static func resolveAll(_ output: Output, context: Context, choices: [Int: Choice] = [:]) -> [Resolved] {
        func settle(_ writers: [Int: WriterBasis], pinning: [Int: DateSpec]) -> [Resolved] {
            var resolved: [Resolved] = []
            for (index, mention) in output.mentions.enumerated() {
                let choice = choices[index] ?? Choice()
                let inherited = mention.dateFrom.flatMap { $0 < resolved.count ? inheritedDay(from: resolved[$0]) : nil }
                let plain = resolve(mention, context: context, choice: choice, inheritedDate: inherited,
                                    anchorDay: pinning[index], writer: writers[index])
                // 推出偏移的那一处已锚在推算用的那天，不再按组里第一处另锚。
                let anchored = pinning[index] == nil
                    ? groupAnchor(plain, of: mention, choice: choice, inherited: inherited, context: context, previous: resolved, writer: writers[index])
                    : nil
                resolved.append(anchored ?? plain)
            }
            return resolved
        }

        if let writer = output.writer {
            // 写了就不推：每处「我这边」先按那里算，后面仍是今天的选项。
            var writers: [Int: WriterBasis] = [:]
            for (index, mention) in output.mentions.enumerated() where mention.source == .local {
                writers[index] = .written(writer.place, place: writerPlaceWord(writer.place))
            }
            return settle(writers, pinning: [:])
        }

        let plain = settle([:], pinning: [:])
        // 没写才推：「3pm my time / 9am 纽约」两处本是同一刻，这边墙钟与那处那刻的差就是写信人的偏移
        // （归到一刻钟，出 ±14 小时不推）。另一处照第一遍落成的时刻算，推出来再落第二遍（两处从此同一刻）。
        var writers: [Int: WriterBasis] = [:]
        var pinning: [Int: DateSpec] = [:]
        for (index, mention) in output.mentions.enumerated() {
            guard mention.source == .local, let clock = mention.time, plain[index].problem == nil, let day = plain[index].day,
                  let other = output.mentions.indices.first(where: { candidate in
                      candidate != index && output.mentions[candidate].group == mention.group
                          && output.mentions[candidate].source != .local
                          && plain[candidate].zoneWritten && plain[candidate].problem == nil && plain[candidate].start != nil
                  }),
                  let otherStart = plain[other].start,
                  let wall = wallClockAsUTC(clock, on: day) else { continue }
            let minutes = Int(((wall.timeIntervalSince1970 - otherStart.timeIntervalSince1970) / 900).rounded()) * 15
            guard abs(minutes) <= 14 * 60 else { continue }
            writers[index] = .inferred(offsetMinutes: minutes, placeAndClock: placeAndClock(of: plain[other]), other: output.mentions[other])
            if let year = day.year, let month = day.month, let number = day.day {
                pinning[index] = .absolute(year: year, month: month, day: number)
            }
        }
        guard !writers.isEmpty else { return plain }
        return settle(writers, pinning: pinning)
    }

    /// 写信人那句里地名的叫法：城市用城市名、写的地名照写；时区词、缩写说不出，给空串（界面退回那一处的通用叫法）。
    private static func writerPlaceWord(_ zone: Zone) -> String {
        switch zone {
        case let .city(_, name, _, _): return name
        case let .place(query): return query
        default: return ""
        }
    }

    /// 那一天的墙钟（「午夜 = 次日 0 点」也算）当作 UTC 读出的那一刻：与另一处那刻的差就是「我这边」的偏移。
    private static func wallClockAsUTC(_ clock: Clock, on day: DateComponents) -> Date? {
        let calendar = Calendar.gregorianUTC(TimeZone(secondsFromGMT: 0)!)
        guard let anchor = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12)),
              let target = calendar.date(byAdding: .day, value: clock.dayOffset, to: anchor) else { return nil }
        var components = calendar.dateComponents([.year, .month, .day], from: target)
        components.hour = clock.hour
        components.minute = clock.minute
        components.second = clock.second
        return calendar.date(from: components)
    }

    /// 推断的说明里另一处怎么称呼：城市用城市名（没有就用标识符），钟点照原文写「9:00」。
    private static func placeAndClock(of other: Resolved) -> String {
        let place = other.zoneOption.city?.name ?? other.zone.identifier
        guard let clock = other.mention.time else { return place }
        return String(format: "%@ %d:%02d", place, clock.hour, clock.minute)
    }

    /// 沿用的是来源那一处已经落定的那一天（界面写「同上」），不是把「明天」「星期五」按这一处的时区再算一遍：
    /// 傍晚在洛杉矶读「Kickoff tomorrow 9am PST, sync 18:00 Berlin」，柏林已是次日，再算一遍就晚了一天，
    /// 而两处本是同一刻（换算页实测）。来源落不成日子时（那一天在那里不存在）退回它写的日期。
    private static func inheritedDay(from source: Resolved) -> DateSpec? {
        guard let day = source.day, let year = day.year, let month = day.month, let date = day.day else { return source.reading.date }
        return .absolute(year: year, month: month, day: date)
    }

    /// 同一行里几个时区写同一刻（等价组，Rust 给同一个 `group`）：没写日期的后面几处不落在「那边的今天」：傍晚在洛杉矶读
    /// 「9:00 纽约 / 14:00 伦敦」，伦敦、新加坡已是次日，各落各的今天就差出 24 小时，核对也就提醒不出来。这里把它们落在
    /// 离组里第一处（更早、写明时区、读成了的）最近的那一天：先照常读一遍拿这一处的时区，再按第一处那天在那边的前一天、
    /// 当天、后一天各读一遍，取起点离第一处最近的（一样近取早的）。
    private static func groupAnchor(_ plain: Resolved, of mention: Mention, choice: Choice, inherited: DateSpec?,
                                    context: Context, previous: [Resolved], writer: WriterBasis? = nil) -> Resolved? {
        guard mention.date == nil, !mention.dateInherited, mention.relativeMinutes == nil, mention.instant == nil,
              plain.reading.date == nil, plain.reading.time != nil,
              let base = previous.first(where: { $0.mention.group == mention.group && $0.start != nil && $0.zoneWritten && $0.problem == nil }),
              let baseStart = base.start,
              let baseDay = civilDay(nil, reference: baseStart, in: plain.zone) else { return nil }
        var best: Resolved?
        for offset in [-1, 0, 1] {
            guard let day = shiftedDay(baseDay, by: offset, in: plain.zone) else { continue }
            let candidate = resolve(mention, context: context, choice: choice, inheritedDate: inherited, anchorDay: day, writer: writer)
            guard let start = candidate.start else { continue }
            // 候选按日子从早到晚来，一样近时留着先读到的（更早的那天）。
            if let current = best?.start, abs(start.timeIntervalSince(baseStart)) >= abs(current.timeIntervalSince(baseStart)) { continue }
            best = candidate
        }
        return best
    }

    /// `day` 在 `zone` 里挪 `days` 天后的年月日（等价组锚定要读前一天与后一天）。
    private static func shiftedDay(_ day: DateComponents, by days: Int, in zone: TimeZone) -> DateSpec? {
        let calendar = Calendar.gregorianUTC(zone)
        guard let noon = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12)),
              let moved = calendar.date(byAdding: .day, value: days, to: noon) else { return nil }
        let parts = calendar.dateComponents([.year, .month, .day], from: moved)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        return .absolute(year: year, month: month, day: day)
    }

    /// 把一次提到落成具体时刻。`inheritedDate` 是来源那一处现在选的日期（沿用日期时用它，不用 Rust 抄过来的那份）；
    /// `anchorDay` 是等价组锚定的那一天，只在没写日期、也没沿用日期时才轮到它；`writer` 是「我这边」时写信人的地点。
    static func resolve(_ mention: Mention, context: Context, choice: Choice = Choice(), inheritedDate: DateSpec? = nil,
                        anchorDay: DateSpec? = nil, writer: WriterBasis? = nil) -> Resolved {
        let readings = readings(of: mention)
        let reading = readings.first { $0.id == choice.reading } ?? readings[0]
        let date = (mention.dateInherited ? inheritedDate : nil) ?? reading.date ?? anchorDay
        // 这一天是等价组锚进来的，不是「那边的今天」：界面不再那样标。
        let anchored = !mention.dateInherited && reading.date == nil && anchorDay != nil

        var options = zoneOptions(mention.source, date: date, context: context, writer: writer)
        let written = !options.isEmpty
        if options.isEmpty {
            options = [ZoneOption(id: "zone:\(context.fallback.identifier)", zone: context.fallback, kind: .region,
                                  anchor: context.fallback.identifier)]
        }
        let chosen = options.first { $0.id == choice.zone } ?? options[0]
        let zone = chosen.zone
        let target: TimeZone? = mention.target.flatMap { target in
            if case .local = target { return context.home }
            return zoneOptions(target, date: date, context: context).first?.zone
        }

        var notes: [Resolved.Note] = []
        if case .options(reason: "sentence", _) = mention.source, let suggested = options.first {
            notes.append(.sentenceSuggestion(suggested))
        }
        if case let .regionalClock(literal) = chosen.kind { notes.append(.standardAbbreviationDuringDaylightTime(literal: literal, region: zone)) }
        // 写信人那里落实成选项了：不再说「没写在哪、先按你这里算」。
        let writerSettled = options.contains { option in
            switch option.kind { case .writer, .writerInferred: return true; default: return false }
        }
        if case .local = chosen.kind, context.origin == .pasted, !writerSettled { notes.append(.localMeansTheWriter) }
        if case .writer = chosen.kind, case .written(_, let place)? = writer { notes.append(.localIsTheWriter(place: place)) }
        if case .writerInferred = chosen.kind, case .inferred(let minutes, let placeAndClock, let other)? = writer {
            notes.append(.localInferredFrom(offsetMinutes: minutes, placeAndClock: placeAndClock, other: other))
        }
        if let implied = mention.timeImplied, reading.time != nil { notes.append(.impliedTime(implied)) }
        if let unknown = mention.unresolved.first(where: { $0.role == "target" }), mention.target == nil { notes.append(.unresolvedTarget(unknown.text)) }
        // 有线索却没认出的地名不挡换算：照来源地点算、标出来（192 条里 26 处是被当成地名的普通词，
        // 「讲座时间」「w celu udziału」，挡住换算的伤害比「9am in Москвzz」照本地算再提醒大得多）。
        if let place = mention.unresolved.first(where: { $0.role == "place" }), mention.source == nil { notes.append(.unresolvedPlace(place.text)) }

        let day = mention.instant == nil && mention.relativeMinutes == nil ? civilDay(date, reference: context.reference, in: zone) : nil
        func make(_ intervals: [Resolved.Interval], _ problem: Resolved.Problem? = nil) -> Resolved {
            Resolved(mention: mention, readings: readings, reading: reading, zoneOptions: options, zoneOption: chosen, zoneWritten: written,
                     day: day, intervals: intervals, target: target, problem: problem, notes: notes, anchoredToGroup: anchored)
        }
        func lasting(_ start: Date) -> Resolved.Interval {
            Resolved.Interval(start: start, end: mention.durationMinutes.map { start.addingTimeInterval(TimeInterval($0 * 60)) })
        }

        if !mention.issues.isEmpty { return make([], .issues(mention.issues)) }
        // 写了时区却一项都落不成（「America/Nowhere」这种系统没有的标识符）：说出来，不悄悄改用本地时区。
        if let source = mention.source, !written { return make([], .unresolvedPlace(source.written)) }
        if let instant = mention.instant { return make([lasting(Date(timeIntervalSince1970: TimeInterval(instant)))]) }
        if let minutes = mention.relativeMinutes { return make([lasting(context.now.addingTimeInterval(TimeInterval(minutes * 60)))]) }
        guard let clock = reading.time else { return make([], day == nil ? .invalidDate : .dateOnly) }
        guard let day else { return make([], .invalidDate) }

        let calendar = Calendar.gregorianUTC(zone)
        func wall(_ c: Clock) -> (DateComponents, Date)? {
            guard let anchor = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12)),
                  let target = calendar.date(byAdding: .day, value: c.dayOffset, to: anchor) else { return nil }
            var components = calendar.dateComponents([.year, .month, .day], from: target)
            components.hour = c.hour
            components.minute = c.minute
            components.second = c.second
            return (components, target)
        }
        guard let (components, targetDay) = wall(clock) else { return make([], .invalidDate) }
        let start = TimeInput.resolveWallTime(components, on: targetDay, in: zone)
        if start.error != nil || start.dates.isEmpty {
            return make([], .nonexistentTime(start.gap.map { Resolved.Gap(at: $0.at, before: $0.before, after: $0.after) }))
        }
        // 终点早于或等于起点（「22:00–01:00」）：在次日。比较带秒。
        var endCandidates: [Date]?
        if let end = mention.end {
            let endClock = end.dayOffset == clock.dayOffset && end.secondOfDay <= clock.secondOfDay ? end.later(days: 1) : end
            endCandidates = wall(endClock).map { TimeInput.resolveWallTime($0.0, on: $0.1, in: zone).dates } ?? []
        }
        let intervals = start.dates.map { begin -> Resolved.Interval in
            guard let endCandidates else { return lasting(begin) }
            return Resolved.Interval(start: begin, end: endCandidates.first { $0 > begin })
        }
        return make(intervals)
    }

    /// 日期说明 → 该时区里的民用日（年月日）。没写日期就是 `reference` 那天。那一天在这个时区不存在时（平年的 2 月 29 日、
    /// Apia 跳过的 2011-12-30）给 nil：拼回来要还是同一天，不让 Foundation 悄悄挪到下一天（旧 `TimeInput` 有这道检查，新路补上）。
    static func civilDay(_ spec: DateSpec?, reference: Date, in zone: TimeZone) -> DateComponents? {
        let calendar = Calendar.gregorianUTC(zone)
        let today = calendar.dateComponents([.year, .month, .day, .weekday], from: reference)
        func shifted(_ days: Int) -> DateComponents? {
            guard let anchor = calendar.date(from: DateComponents(year: today.year, month: today.month, day: today.day, hour: 12)),
                  let day = calendar.date(byAdding: .day, value: days, to: anchor) else { return nil }
            return calendar.dateComponents([.year, .month, .day], from: day)
        }
        func existing(_ year: Int, _ month: Int, _ day: Int) -> DateComponents? {
            let wanted = DateComponents(year: year, month: month, day: day)
            guard let noon = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)),
                  calendar.dateComponents([.year, .month, .day], from: noon) == wanted else { return nil }
            return wanted
        }
        guard let spec else { return DateComponents(year: today.year, month: today.month, day: today.day) }
        switch spec {
        case let .absolute(year, month, day):
            return existing(year, month, day)
        case let .monthDay(month, day):
            guard let year = today.year else { return nil }
            // 今年这一天已经过去一个月以上，就是明年的（「Oct 3」在 11 月说是明年十月）。
            if let thisYear = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)),
               let limit = calendar.date(byAdding: .day, value: -30, to: reference), thisYear < limit {
                return existing(year + 1, month, day)
            }
            return existing(year, month, day)
        case let .offset(days):
            return shifted(days)
        case let .weekday(target, week):
            guard let weekday = today.weekday else { return nil }
            let iso = (weekday + 5) % 7 + 1   // Foundation 的星期日 = 1 → ISO 的星期一 = 1
            let delta: Int
            switch week {
            case "next": delta = (8 - iso) + (target - 1)
            case "this": delta = target - iso
            case "last": delta = target - iso - 7
            default: delta = (target - iso + 7) % 7
            }
            return shifted(delta)
        }
    }

    // MARK: - 等价组核对

    /// 同一行里几个时区写同一刻（等价组）的核对结果（Rust `understand.crosscheck`）：真一样的几处归进 `same`，
    /// 差着的报进 `notes`（多半有一处没按夏令时改）。`a`、`b`、`same` 里的数都是 `resolveAll` 结果的下标。
    struct Crosscheck: Decodable, Hashable, Sendable {
        /// 差出来的两处：`kind` 是 dstSuspect（差 30 分钟到 2 小时，多半有一处没按夏令时改）或 different（差得更多或更少，不提醒）。
        struct Note: Decodable, Hashable, Sendable { let a: Int; let b: Int; let deltaMinutes: Int; let kind: String }

        var same: [[Int]] = []
        var notes: [Note] = []
        /// kind == "dstSuspect"
        var suspects: [Note] { notes.filter { $0.kind == "dstSuspect" } }

        init(same: [[Int]] = [], notes: [Note] = []) {
            self.same = same
            self.notes = notes
        }

        private enum Key: String, CodingKey { case same, notes }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            same = try c.decodeIfPresent([[Int]].self, forKey: .same) ?? []
            notes = try c.decodeIfPresent([Note].self, forKey: .notes) ?? []
        }
    }

    /// 把落成的几处交给 Rust 核对：只有落成起点又没有问题的那几处参与，各带上它在整段里的下标与等价组号。
    /// 不足两处、Rust 报错或约定对不上时当作没差出来，不挡换算。
    static func crosscheck(_ resolved: [Resolved]) -> Crosscheck {
        struct Item: Encodable { let index: Int; let group: Int; let instant: Int64; let zone: String; let zoned: Bool; let hasClock: Bool }
        struct Input: Encodable { let mentions: [Item] }
        var items: [Item] = []
        for (index, item) in resolved.enumerated() {
            guard let start = item.start, item.problem == nil else { continue }
            items.append(Item(index: index, group: item.mention.group, instant: Int64(start.timeIntervalSince1970.rounded(.down)),
                              zone: item.zone.identifier, zoned: item.zoneWritten, hasClock: item.reading.time != nil))
        }
        guard items.count >= 2 else { return Crosscheck() }
        do {
            return try RustCore.attempt("understand.crosscheck", Input(mentions: items))
        } catch {
            return Crosscheck()
        }
    }
}
