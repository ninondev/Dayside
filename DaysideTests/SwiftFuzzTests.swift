// SPDX-License-Identifier: GPL-3.0-only
//
//  SwiftFuzzTests.swift
//  DaysideTests
//
//  Swift 侧的敌意输入扫描。Rust 的 fuzz_tests.rs 已经给每个核心操作喂过随机 JSON，
//  这里补的是 Swift 入口：外部字符串先过 Foundation（Calendar / TimeZone / UserDefaults / Bundle），
//  再进 Rust 的那几条路。`RustCore.invoke` 遇到 Rust 返回 Err 或 panic 会 preconditionFailure，
//  所以这里任何一次崩溃都是真 bug，不是「测试太严」。
//
//  伪随机固定种子（SplitMix64，不用 SystemRandomNumberGenerator），失败信息带样本序号，可复现。
//  每个入口至少 2,000 个样本（FuzzBudget.samples）；不变量违反先攒着，末尾一次汇报前几条，
//  免得一条真 bug 刷出上千条同样的 issue。
//

import Foundation
import Testing
@testable import Dayside

// MARK: - 确定性伪随机与记账

/// SplitMix64：十来行、固定种子、跨机器同序列。
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func below(_ n: Int) -> Int { Int(next() % UInt64(max(n, 1))) }
    mutating func chance(_ percent: Int) -> Bool { below(100) < percent }
    mutating func pick<T>(_ items: [T]) -> T { items[below(items.count)] }
    mutating func int(_ range: ClosedRange<Int>) -> Int { range.lowerBound + below(range.upperBound - range.lowerBound + 1) }
    mutating func double(_ range: ClosedRange<Double>) -> Double {
        range.lowerBound + (range.upperBound - range.lowerBound) * (Double(next() >> 11) / Double(1 << 53))
    }
}

enum FuzzBudget {
    /// 默认每入口 2,000 个样本；一次性的长扫用 `MEANTIME_FUZZ_SAMPLES=<n>` 加大（只影响本进程，不进 verify_all 的口径）。
    static let samples: Int = {
        if let raw = ProcessInfo.processInfo.environment["MEANTIME_FUZZ_SAMPLES"], let n = Int(raw), n > 0 { return n }
        return 2_000
    }()
    /// 种子偏移：`MEANTIME_FUZZ_SEED=<n>` 让五个入口各自的固定种子都加上 n，换一条序列再扫一遍；默认 0 即原序列。
    static let seedOffset: UInt64 = {
        if let raw = ProcessInfo.processInfo.environment["MEANTIME_FUZZ_SEED"], let n = UInt64(raw) { return n }
        return 0
    }()
}

/// 不变量失败先攒着，`finish` 时打印样本数与耗时、记录前几条失败，再用一条 #expect 收口。
struct FuzzLedger {
    let name: String
    private(set) var failures: [String] = []
    private(set) var samples = 0
    private let started = ContinuousClock.now
    init(_ name: String) { self.name = name }
    mutating func sample() { samples += 1 }
    mutating func check(_ condition: Bool, _ message: @autoclosure () -> String) {
        if !condition { failures.append(message()) }
    }
    func finish(sourceLocation: SourceLocation = #_sourceLocation) {
        let elapsed = started.duration(to: .now)
        print("[fuzz] \(name)：\(samples) 个样本，\(failures.count) 条失败，耗时 \(elapsed)")
        for line in failures.prefix(6) { Issue.record(Comment(rawValue: line), sourceLocation: sourceLocation) }
        #expect(failures.isEmpty, "\(name)：\(samples) 个样本里 \(failures.count) 条不变量失败", sourceLocation: sourceLocation)
    }
}

/// 失败信息里的样本：截短并转义，控制符与双向控制符不会把日志本身弄乱。
private func shown(_ text: String) -> String {
    let head = String(text.prefix(100))
    return head.debugDescription + (text.count > 100 ? "…(\(text.count) 字符)" : "")
}

/// 字节级包含。`String.contains` 按字位簇与规范等价比较：拼接处一个组合符就能把前一个字符「吃」进
/// 同一簇，Rust 明明原样拼了字节也会判成不含；排版函数的合同是字节原样，就按字节查。
private func bytesContain(_ haystack: String, _ needle: String) -> Bool {
    let h = Array(haystack.utf8), n = Array(needle.utf8)
    if n.isEmpty { return true }
    guard h.count >= n.count else { return false }
    return (0...(h.count - n.count)).contains { h[$0..<$0 + n.count].elementsEqual(n) }
}

// MARK: - 语料

enum FuzzCorpus {
    /// 片段：零宽字符、双向控制符、控制符、emoji、全角数字、日韩文、西里尔、阿拉伯文、各语口语时间、
    /// 显式时间语法的合法与非法写法、时区词、名片前缀、格式串与注入句、超长串。
    static let pieces: [String] = [
        "", " ", "  ", "\t", "\n", "\r\n", "\u{0}", "\u{7}", "\u{1B}[31m", "\u{7F}", "\u{85}",
        "\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}", "\u{2060}", "\u{00AD}", "\u{034F}",
        "\u{202A}", "\u{202B}", "\u{202D}", "\u{202E}", "\u{2066}", "\u{2067}", "\u{2069}", "\u{061C}",
        "😀", "🌍", "👨‍👩‍👧‍👦", "🇯🇵", "🏳️‍🌈", "🧑🏽‍💻", "\u{FE0F}",
        "１４：００", "９", "３０", "２０２６-０９-１０", "٣", "۳", "१५", "⑨", "Ⅸ",
        "東京", "下周二东京下午三点", "明天下午三点", "今天", "昨天", "明晚八点", "中午前", "下班前",
        "午後3時", "東京で明日15時", "오후 3시", "서울", "내일 오후 3시",
        "москва", "в Москве", "завтра в 15:00", "Ростов-на-Дону", "в следующий вторник в 15:00 в Москве", "в Бари",
        "القاهرة", "غداً الساعة 3", "İstanbul", "München", "São Paulo", "ñ", "e\u{301}", "\u{0301}", "ß", "ﬁ", "ǅ",
        "9am", "9 am", "3:30 PM", "14:00", "24:00", "12:60", "9", "9:5", "am", "pm", "noon", "midnight",
        "tomorrow", "yesterday", "today", "next tuesday 3pm tokyo", "next tuesday", "3pm", "by noon", "EOD", "end of week",
        "nächsten Dienstag um 15 Uhr in Berlin", "mañana a las 3 de la tarde en Madrid",
        "mardi prochain à 15 h à Paris", "terça que vem às 15h em São Paulo",
        "Asia/Tokyo", "Europe/London", "America/New_York", "Australia/Lord_Howe", "Pacific/Apia", "Pacific/Kiritimati",
        "Etc/GMT+9", "asia/tokyo", "Asia/Tokyo/", "Not/AZone", "Mars/Olympus_Mons",
        "UTC", "GMT", "Z", "UTC+05:45", "UTC+9", "GMT-12", "UTC+18", "UTC+19", "UTC-0", "GMT+0900", "PST", "CST", "IST",
        "Central", "Pacific", "Eastern",
        "2026-09-10", "2026-02-30", "1899-12-31", "2100-12-31", "0000-00-00", "2026-9-1", "2026-09-10T12:00:00Z",
        "mt1.", "mt1.AAAA", "mt1.!!!", "https://example.test/#mt1.x", "#mt1.", "mt1.mt1.mt1.", "MT1.AAAA",
        "%s%s%n", "../../etc/passwd", "{\"a\":1}", "null", "[]", "{}", "<script>", "'; DROP TABLE zones;--", "\\u0000", "%00",
        "york", "san", "sf", "la", "nyc", "hk", "北京", "新", "shanghai shi", "Chengxian Chengguanzhen", "Frankfurt", "빈",
        String(repeating: "x", count: 600), String(repeating: "9", count: 40), String(repeating: "東", count: 300),
        String(repeating: "🌍", count: 200), String(repeating: "a ", count: 300), String(repeating: "/", count: 100),
        String(repeating: "\u{202E}", count: 50), String(repeating: "\u{0301}", count: 120),
    ]
    static let separators = ["", " ", "  ", "\t", "\n", ":", "-", "/", "_", "+", ".", ",", "，", "\u{200B}", "\u{202E}"]

    /// 随机码位段：ASCII、控制符、拉丁扩展、组合符、西里尔、阿拉伯、天城文、通用标点（含零宽与双向）、
    /// CJK 标点、假名、汉字、谚文、私用区、变体选择符、全角、特殊区（含非字符）、emoji、标签、末尾两个非字符。
    static let scalarRanges: [ClosedRange<UInt32>] = [
        0x20...0x7E, 0x00...0x1F, 0x7F...0x9F, 0xA0...0x24F, 0x300...0x36F, 0x400...0x4FF, 0x600...0x6FF,
        0x900...0x97F, 0x2000...0x206F, 0x3000...0x303F, 0x3040...0x30FF, 0x4E00...0x9FFF, 0xAC00...0xD7A3,
        0xE000...0xF8FF, 0xFE00...0xFE0F, 0xFF00...0xFFEF, 0xFFF0...0xFFFF, 0x1F300...0x1F6FF, 0x1F900...0x1F9FF,
        0xE0000...0xE007F, 0x10FFF0...0x10FFFF,
    ]
    static func scalars(_ rng: inout SplitMix64, count: Int) -> String {
        var out = String.UnicodeScalarView()
        for _ in 0..<count {
            let range = rng.pick(scalarRanges)
            let value = range.lowerBound + UInt32(rng.below(Int(range.upperBound - range.lowerBound) + 1))
            if let scalar = Unicode.Scalar(value) { out.append(scalar) }
        }
        return String(out)
    }

    /// 一条敌意文本：单个片段、随机码位串、片段重复成超长串，或若干片段用随机分隔符拼起来。
    static func text(_ rng: inout SplitMix64) -> String {
        switch rng.below(10) {
        case 0: return rng.pick(pieces)
        case 1: return scalars(&rng, count: rng.below(48))
        case 2: return String(repeating: rng.pick(pieces), count: rng.below(120))
        default:
            let count = 1 + rng.below(7)
            var parts: [String] = []
            for _ in 0..<count {
                parts.append(rng.chance(20) ? scalars(&rng, count: 1 + rng.below(6)) : rng.pick(pieces))
            }
            return parts.joined(separator: rng.pick(separators))
        }
    }

    /// 显式语法的零件：合法与差一点合法的钟点、日期（含跳过的与重复的那天）、相对日与时区词。
    static let clockWords = [
        "9am", "9 am", "3:30 PM", "14:00", "24:00", "12:60", "9", "00:00", "23:59:59", "12am", "12pm", "０９：００",
        "9:00:00", "13pm", "7:05", "02:30", "01:30", "1:45", "9:5", "009:00",
    ]
    static let dateWords = [
        "2026-09-10", "2026-02-30", "1899-12-31", "2100-12-31", "2026-03-08", "2026-11-01", "2028-02-29", "2026-04-05",
        "2011-12-30", "1900-01-01", "2026-9-1", "2026-10-04",
    ]
    static let dayWords = ["today", "tomorrow", "yesterday", "今天", "明天", "昨天", "Tomorrow"]
    static let zoneWords = [
        "UTC", "GMT", "Z", "UTC+05:45", "UTC+9", "GMT-12", "UTC+18", "UTC+18:30", "PST", "CST", "IST", "JST", "CET", "Central",
        "Pacific", "Asia/Tokyo", "Australia/Lord_Howe", "Pacific/Apia", "America/New_York", "Not/AZone", "asia/tokyo",
        "Etc/GMT+9", "GMT+0900", "UTC-0", "utc+1",
    ]
    /// 一条「像显式语法」的输入：零件按语法顺序拼，偶尔打乱。
    static func grammarish(_ rng: inout SplitMix64) -> String {
        var parts: [String] = []
        if rng.chance(40) { parts.append(rng.pick(dateWords)) }
        parts.append(rng.pick(clockWords))
        if rng.chance(20) { parts.append(rng.chance(50) ? "am" : "pm") }
        if rng.chance(30) { parts.append(rng.pick(dayWords)) }
        if rng.chance(60) { parts.append(rng.pick(zoneWords)) }
        if rng.chance(10) { parts.shuffle(using: &rng) }
        return parts.joined(separator: rng.chance(90) ? " " : rng.pick(separators))
    }
    /// 口语句子加地点词：七种语言的日常说法，地点有城市、显式时区词、变格形与不存在的地方。
    static let colloquialPhrases = [
        "tomorrow 3pm", "next tuesday 3pm", "下周二下午三点", "明天上午十点", "by noon", "EOD Friday", "morgen um 15 Uhr",
        "mañana a las 3 de la tarde", "demain à 15 h", "amanhã às 15h", "завтра в 15:00", "3 in the afternoon", "tonight at 8",
        "8", "next friday 9am", "下班前", "中午前", "明晚八点", "end of week", "3pm tomorrow", "14:00",
    ]
    static let placeWords = [
        "tokyo", "东京", "in London", "à Paris", "в Москве", "UTC+9", "PST", "New York", "san", "york", "Nowhere xyz",
        "Asia/Tokyo", "GMT-12", "em São Paulo", "in Berlin", "서울", "", "🌍",
    ]
    static func colloquialish(_ rng: inout SplitMix64) -> String {
        let phrase = rng.pick(colloquialPhrases), place = rng.pick(placeWords)
        return rng.chance(50) ? "\(phrase) \(place)" : "\(place) \(phrase)"
    }
    /// 城市搜索的「像样」查询：真城市名的前缀、一到四个小写字母（命中面很大）。
    static let cityNames = [
        "New York", "San Francisco", "北京", "東京", "москва", "München", "São Paulo", "القاهرة", "서울", "Frankfurt am Main",
        "Ростов-на-Дону", "Saint Petersburg", "Kuala Lumpur", "Chengxian Chengguanzhen", "Baden-Baden", "N'Djamena",
        "İstanbul", "Αθήνα", "Shanghai Shi", "Los Angeles", "Belo Horizonte", "Bangalore", "台北", "香港", "Zürich",
    ]
    static func cityish(_ rng: inout SplitMix64) -> String {
        if rng.chance(50) { return String(rng.pick(cityNames).prefix(1 + rng.below(8))) }
        var out = ""
        for _ in 0..<(1 + rng.below(4)) { out.append(Character(Unicode.Scalar(UInt8(0x61 + rng.below(26))))) }
        return out
    }

    /// 真时区：含半小时/四十五分偏移、日界线两侧、南北半球夏令时、半小时回拨（Lord Howe）、
    /// 跳过一整天的 Apia、UTC+14，再加两个固定偏移时区。
    static let zoneIDs = [
        "UTC", "Asia/Tokyo", "Europe/London", "America/New_York", "Australia/Lord_Howe", "Pacific/Apia",
        "Pacific/Kiritimati", "Asia/Kathmandu", "America/St_Johns", "Pacific/Chatham", "Africa/Casablanca",
        "America/Santiago", "Asia/Tehran", "Europe/Kyiv", "Antarctica/Troll", "Pacific/Honolulu", "Asia/Kolkata",
        "America/Sao_Paulo", "Etc/GMT+12", "Etc/GMT-14", "Asia/Shanghai", "Europe/Berlin", "America/Los_Angeles",
    ]
    static let zones: [TimeZone] = zoneIDs.compactMap { TimeZone(identifier: $0) }
        + [TimeZone(secondsFromGMT: 20_700), TimeZone(secondsFromGMT: -12 * 3_600)].compactMap { $0 }

    /// 参考时刻：1901-01-01 … 2099-12-31，覆盖显式语法允许的整个年份区间的两侧。
    static func reference(_ rng: inout SplitMix64) -> Date {
        Date(timeIntervalSince1970: rng.double(-2_177_452_800...4_102_358_400).rounded())
    }

    /// 界面语言与地区：十种支持的语言、POSIX 变体、带扩展键的、空的、乱的、超长的。
    static let localeIDs = [
        "en", "en_US", "en-GB", "zh-Hans", "zh-Hant", "zh_CN", "zh-Hant_TW", "zh-Hans-CN", "ja", "ja_JP", "ko", "es", "es-419",
        "fr", "fr_CA", "de", "de_DE", "ru", "pt-BR", "pt_BR", "pt", "", "und", "root", "xx", "i-klingon", "en_US_POSIX",
        "de_DE.UTF-8", "en_US@calendar=japanese", "ar", "he", "th_TH@numbers=thai", "sr-Latn", "zh-Hans-CN-u-ca-chinese",
        "EN", "En_us", "-", "_", "@", "zh-", "-Hans", "en-US-x-private", "ja-JP-u-hc-h11", "en-u-hc-h23",
        String(repeating: "en-", count: 200), "\u{202E}en", "en\u{0}US",
    ]
    /// 目录里真有的键（各语 .lproj 都有译文）与几条不存在的。
    static let stringKeys = [
        "分享时间", "全天", "在工作时间外", "时区：%@", "跟随系统", "名称", "缩写 (PST/JST)", "UTC 偏移", "%@–次日 %@",
        "以下时段使用 %@", "可约时段不会查询日历或预订会议。", "no such key", "%@%@%@%@%@%@", "%1$@ %2$@", "%lld 天",
    ]
}

// MARK: - 1. 时间输入：「听懂时间」引擎（换心：旧的显式语法与口语理解已删）

struct SwiftFuzzTests {
    /// `TimeInput.resolve` 只会给出这些错误码；Rust 报的问题只有这些类型。别的字样说明有一侧改了却没同步。
    private static let resolveErrors: Set<String> = ["unrecognized", "nonexistentTime", "invalidDate", "unknownPlace", "invalid"]
    private static let issueKinds: Set<String> = ["invalidDate", "invalidTime", "invalidOffset", "conflictingPeriod", "conflictingDeadline",
                                                  "conflictingDate"]

    /// 不变量：约定不断；每个位置在界内且落在字符边界上；同一段读两遍结果相同；后面追加一句无关的话，前面几处读法不变；
    /// 读成的钟点就是落成的时刻在那个时区的钟点（写了年月日的，日期也相同）；终点晚于起点；时刻都能导出时间戳。
    @Test(.timeLimit(.minutes(2)))
    func understandingNeverCrashesAndOnlyYieldsTheWallTimeItRead() {
        var rng = SplitMix64(seed: 0x5EED_0000_0001 &+ FuzzBudget.seedOffset)
        var ledger = FuzzLedger("TimeUnderstanding.read / resolveAll")
        var mentions = 0, resolved = 0
        for sample in 0..<FuzzBudget.samples {
            ledger.sample()
            // 一半纯敌意，四分之一像显式语法，四分之一像口语：成功路径也要走到。
            let text: String
            switch rng.below(4) {
            case 0: text = FuzzCorpus.grammarish(&rng)
            case 1: text = FuzzCorpus.colloquialish(&rng)
            default: text = FuzzCorpus.text(&rng)
            }
            let zone = rng.pick(FuzzCorpus.zones)
            let reference = FuzzCorpus.reference(&rng)
            let tag = "#\(sample) \(shown(text)) @\(zone.identifier)"

            let output = TimeUnderstanding.read(text, region: "US")
            ledger.check(!output.failed, "\(tag)：约定对不上（Rust 报错或解码失败）")
            let units = Array(text.utf16)
            func onBoundary(_ span: [Int]) -> Bool {
                guard span.count == 2, 0 <= span[0], span[0] <= span[1], span[1] <= units.count else { return false }
                return span.allSatisfy { $0 == 0 || $0 == units.count || !UTF16.isTrailSurrogate(units[$0]) }
            }
            for mention in output.mentions {
                let spans = [mention.span] + mention.parts.map(\.span) + mention.issues.map(\.span) + mention.unresolved.map(\.span)
                ledger.check(spans.allSatisfy(onBoundary), "\(tag)：位置越界或切在字符中间 \(spans)")
                for issue in mention.issues {
                    ledger.check(Self.issueKinds.contains(issue.kind), "\(tag)：未知问题类型 \(issue.kind)")
                }
            }
            if let truncated = output.truncatedAt { ledger.check(truncated <= units.count, "\(tag)：截断位置 \(truncated) 越界") }
            ledger.check(TimeUnderstanding.read(text, region: "US").mentions == output.mentions, "\(tag)：同一段读两遍结果不同")
            if text.utf8.count < 3_000 {
                let longer = TimeUnderstanding.read(text + "\n\nThanks!", region: "US")
                ledger.check(Array(longer.mentions.prefix(output.mentions.count)) == output.mentions,
                             "\(tag)：追加一句无关的话改了前面的读法")
            }

            let context = TimeUnderstanding.Context(reference: reference, now: reference, fallback: zone)
            for item in TimeUnderstanding.resolveAll(output, context: context) {
                mentions += 1
                guard item.problem == nil else {
                    ledger.check(item.intervals.isEmpty, "\(tag)：有问题 \(String(describing: item.problem)) 却给了时刻")
                    continue
                }
                resolved += 1
                ledger.check(!item.intervals.isEmpty, "\(tag)：没问题也没给时刻")
                let calendar = Calendar.gregorianUTC(item.zone)
                for interval in item.intervals {
                    ledger.check(interval.start.timeIntervalSince1970.isFinite, "\(tag)：非有限时刻")
                    if let end = interval.end { ledger.check(end > interval.start, "\(tag)：终点不晚于起点") }
                    ledger.check(TimeInput.timestamps(for: interval.start, in: item.zone) != nil, "\(tag)：时刻无法导出时间戳")
                    guard let clock = item.reading.time, item.mention.instant == nil, item.mention.relativeMinutes == nil else { continue }
                    let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: interval.start)
                    ledger.check(parts.hour == clock.hour && parts.minute == clock.minute && parts.second == clock.second,
                                 "\(tag)：钟点 \(parts.hour ?? -1):\(parts.minute ?? -1):\(parts.second ?? -1) ≠ 读到的 \(clock.key)")
                    if case let .absolute(year, month, day)? = item.reading.date, clock.dayOffset == 0 {
                        ledger.check(parts.year == year && parts.month == month && parts.day == day,
                                     "\(tag)：日期 \(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0) ≠ 读到的 \(year)-\(month)-\(day)")
                    }
                }
            }
            let resolution = TimeInput.resolve(text, relativeTo: reference, now: reference, in: zone)
            if let error = resolution.error {
                ledger.check(resolution.dates.isEmpty, "\(tag)：报错 \(error) 却还给了时刻")
                ledger.check(Self.resolveErrors.contains(error), "\(tag)：未知错误码 \(error)")
            }
            let source = TimeInput.sourceTimeZone(for: text, in: zone)
            ledger.check(TimeZone(identifier: source.identifier) != nil, "\(tag)：来源时区标识符不合法 \(source.identifier)")
        }
        print("[fuzz] 听懂时间：\(mentions) 处，\(resolved) 处落成时刻")
        ledger.finish()
    }

    // MARK: - 2. 城市搜索

    @Test(.timeLimit(.minutes(2)))
    func citySearchReturnsWithinLimitAndEveryHitHasARealTimeZone() throws {
        let index = CityIndex.shared
        try #require(index.isAvailable, "测试宿主随包索引不可用")
        var rng = SplitMix64(seed: 0x5EED_0000_0002 &+ FuzzBudget.seedOffset)
        var ledger = FuzzLedger("CityIndex.search")
        // Int.max 只占 1/40：单字母查询配无上限会回来两万多条，Rust 侧按名次插入是 O(n²)，一次 100 多毫秒
        // （App 自己只用个位数上限，不是产品路径），留着做敌意样本但别让它吃掉整个预算。
        let limits = [0, 1, 2, 3, 4, 8, 8, 8, 8, 16, 16, 64, 1_000] + Array(repeating: 8, count: 26) + [Int.max]
        var nonEmpty = 0, hitsSeen = 0
        for sample in 0..<FuzzBudget.samples {
            ledger.sample()
            let raw = rng.chance(30) ? FuzzCorpus.cityish(&rng) : FuzzCorpus.text(&rng)
            // 生产路径先折叠再搜；这里一半按生产路径、一半把未折叠的原文直接当折叠串塞进去。
            let query = rng.chance(50) ? raw.searchFolded : raw
            let limit = rng.pick(limits)
            let tag = "#\(sample) \(shown(query)) limit=\(limit)"
            let hits = index.search(folded: query, limit: limit)
            ledger.check(hits.count <= limit, "\(tag)：返回 \(hits.count) 条超过上限")
            ledger.check(Set(hits.map(\.cityIndex)).count == hits.count, "\(tag)：同一城市出现两次")
            if !hits.isEmpty { nonEmpty += 1 }
            // 上限开到 Int.max 时单字母查询能回来两万多条；逐条回查时区只看头尾各 32 条，越界与重复仍看全部。
            let inspected = hits.count <= 64 ? hits : Array(hits.prefix(32)) + Array(hits.suffix(32))
            for hit in inspected {
                hitsSeen += 1
                ledger.check((0..<index.cityCount).contains(hit.cityIndex), "\(tag)：城市下标 \(hit.cityIndex) 越界")
                ledger.check((0...3).contains(hit.tier), "\(tag)：档位 \(hit.tier) 不在 0…3")
                let zoneID = index.timezoneID(at: hit.cityIndex)
                ledger.check(TimeZone(identifier: zoneID) != nil, "\(tag)：城市 \(hit.cityIndex) 的时区 \(shown(zoneID)) 不是这台 Mac 认得的标识符")
            }
            if let first = hits.first {
                let record = index.city(at: first.cityIndex)
                ledger.check(record != nil && record?.timezoneID == index.timezoneID(at: first.cityIndex),
                             "\(tag)：city(at:) 与 timezoneID(at:) 对不上")
            }
        }
        print("[fuzz] CityIndex：\(nonEmpty) 条查询有结果，逐条核过 \(hitsSeen) 个命中")
        ledger.finish()
    }

    // MARK: - 3. 时间名片导入

    /// Rust 解码器与 Swift 导入层一共只会给出这些失败码。
    private static let cardFailures: Set<String> = ["notACard", "corrupt", "invalid", "unsupportedVersion", "unknownZone", "tooLong"]
    private static let base64URLAlphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
    private static let hostileNumbers = [
        "0", "-0", "-1", "1", "2", "7", "8", "540", "1080", "1439", "1440", "1441", "-540", "1e309", "-1e309", "1e-400",
        "9223372036854775807", "9223372036854775808", "-9223372036854775809", "1.5", "4.0", "1e18", "1e300",
        "99999999999999999999999999", "64800", "64801", "-64800", "129", "0.0", "1e5",
    ]

    /// 几张真名片：有无可约时段、跨午夜、整天、非 ASCII 名字、80 字名字、有无托管链接、固定偏移地点。
    private static func realCards(now: Date) -> [String] {
        func make(_ zone: String, _ name: String, availability: (Int, Int, [Int])?, host: String) -> [String] {
            var draft = SharingDraft()
            draft.timeZoneID = zone
            draft.displayName = name
            if let (start, end, weekdays) = availability {
                draft.includesAvailability = true
                draft.startMinute = start
                draft.endMinute = end
                draft.workingWeekdays = weekdays
            }
            guard let document = SharingGenerator.build(draft: draft, hostURL: host, now: now).document else { return [] }
            return [document.fragment] + (document.shareURL.map { [$0] } ?? [])
        }
        return make("Asia/Tokyo", "Mei", availability: (540, 1080, [2, 3, 4, 5, 6]), host: "https://example.test/when.html")
            + make("Europe/London", "", availability: nil, host: "")
            + make("America/St_Johns", "Ана 東京 🌍", availability: (1_320, 360, [1, 7]), host: "")
            + make("Australia/Lord_Howe", String(repeating: "名", count: 80), availability: (0, 1_440, [1, 2, 3, 4, 5, 6, 7]),
                   host: "https://share.example.com/when.html")
            + make("UTC", "\u{200B}", availability: (600, 600, [3]), host: "")
            + make("GMT+0545", "Fixed", availability: (480, 1_020, [2, 4]), host: "")
    }

    private static func base64URLDecode(_ text: String) -> Data? {
        var standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while standard.count % 4 != 0 { standard.append("=") }
        return Data(base64Encoded: standard)
    }
    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// 打坏一张真名片：改片段的字符（翻转、截断、插入、加前后缀、换前缀），或解开 base64 改里面的 JSON
    /// （换数字、换字符串值、翻字节、删段、插段）再编回去。
    private static func damaged(_ card: String, _ rng: inout SplitMix64) -> String {
        guard let at = card.range(of: "mt1.") else { return card }
        let prefix = String(card[..<at.upperBound])
        var body = Array(card[at.upperBound...])
        if rng.chance(50) {
            switch rng.below(6) {
            case 0:
                for _ in 0..<(1 + rng.below(4)) where !body.isEmpty { body[rng.below(body.count)] = rng.pick(base64URLAlphabet) }
            case 1: body = Array(body.prefix(rng.below(body.count + 1)))
            case 2: body.insert(contentsOf: FuzzCorpus.text(&rng), at: rng.below(body.count + 1))
            case 3: return FuzzCorpus.text(&rng) + prefix + String(body) + FuzzCorpus.text(&rng)
            case 4: return rng.pick(["mt2.", "mt1", "MT1.", "mt1..", "mt1.=", " mt1. "]) + String(body)
            default: body.append(contentsOf: body)
            }
            return prefix + String(body)
        }
        let encoded = String(body.prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        guard let data = base64URLDecode(encoded), var json = String(data: data, encoding: .utf8) else { return card }
        switch rng.below(5) {
        case 0:
            if let match = json.range(of: #"-?\d+(\.\d+)?([eE][+-]?\d+)?"#, options: .regularExpression,
                                      range: json.index(json.startIndex, offsetBy: rng.below(json.count))..<json.endIndex) {
                json.replaceSubrange(match, with: rng.pick(hostileNumbers))
            }
        case 1:
            if let match = json.range(of: #""[^"\\]*""#, options: .regularExpression,
                                      range: json.index(json.startIndex, offsetBy: rng.below(json.count))..<json.endIndex) {
                json.replaceSubrange(match, with: HostileJSON.string(rng.chance(50) ? FuzzCorpus.text(&rng) : rng.pick(FuzzCorpus.pieces)))
            }
        case 2:
            var bytes = Array(json.utf8)
            for _ in 0..<(1 + rng.below(3)) where !bytes.isEmpty { bytes[rng.below(bytes.count)] = UInt8(rng.below(256)) }
            return prefix + base64URLEncode(Data(bytes))
        case 3:
            let start = rng.below(json.count), length = rng.below(json.count - start + 1)
            let from = json.index(json.startIndex, offsetBy: start)
            json.removeSubrange(from..<json.index(from, offsetBy: length))
        default:
            let generated = HostileJSON.value(&rng, depth: 2, keys: ["timeZoneID", "windows", "schedule", "version"])
            let insertion = rng.pick(["{", "}", "[", "]", ",", "\"", "\\", "\u{0}", "\"windows\":[", generated])
            json.insert(contentsOf: insertion, at: json.index(json.startIndex, offsetBy: rng.below(json.count + 1)))
        }
        return prefix + base64URLEncode(Data(json.utf8))
    }

    @Test(.timeLimit(.minutes(2)))
    func timeCardImportEitherFailsByNameOrRoundTrips() {
        let now = Date(timeIntervalSince1970: 1_789_041_600)
        let cards = Self.realCards(now: now)
        #expect(cards.count == 8, "真名片应有 6 张、其中 2 张带托管链接")
        var rng = SplitMix64(seed: 0x5EED_0000_0003 &+ FuzzBudget.seedOffset)
        var ledger = FuzzLedger("TimeCard.person(from:)")
        var imported = 0, failed: [String: Int] = [:]
        for sample in 0..<FuzzBudget.samples {
            ledger.sample()
            let text: String
            switch rng.below(10) {
            case 0, 1: text = FuzzCorpus.text(&rng)
            case 2: text = rng.pick(cards)
            default: text = Self.damaged(rng.pick(cards), &rng)
            }
            let tag = "#\(sample) \(shown(text))"
            switch TimeCard.person(from: text, now: rng.chance(80) ? now : FuzzCorpus.reference(&rng)) {
            case .failure(let failure):
                failed[failure.code, default: 0] += 1
                ledger.check(Self.cardFailures.contains(failure.code), "\(tag)：未知失败码 \(failure.code)")
            case .success(let result):
                imported += 1
                let person = result.contact
                ledger.check(TimeZone(identifier: person.timeZoneID) != nil, "\(tag)：导入的时区 \(shown(person.timeZoneID)) 不合法")
                ledger.check(person.name.count <= 80 && !person.name.unicodeScalars.contains { $0.properties.generalCategory == .control },
                             "\(tag)：名字 \(shown(person.name)) 超长或含控制符")
                ledger.check((person.startMinute == nil) == !result.hadSchedule, "\(tag)：hadSchedule 与作息字段不一致")
                if let start = person.startMinute, let end = person.endMinute, let weekdays = person.workingWeekdays {
                    ledger.check((0..<1_440).contains(start) && (0..<1_440).contains(end),
                                 "\(tag)：日程 \(start)–\(end) 超出人物模型的合法域")
                    ledger.check(!weekdays.isEmpty && weekdays.allSatisfy { (1...7).contains($0) }
                                 && weekdays == Array(Set(weekdays)).sorted(),
                                 "\(tag)：工作日 \(weekdays) 不合法")
                }
                if let sender = result.senderTZData {
                    ledger.check(!sender.isEmpty && sender.count <= 12 && sender.allSatisfy(\.isASCII), "\(tag)：发方 tzdata 发行号 \(shown(sender)) 不合法")
                }
                // 再编码、再解码：导入出来的人物做成一张新名片，必须能再导入成同一个人。
                var draft = SharingDraft()
                draft.timeZoneID = person.timeZoneID
                draft.displayName = person.name
                draft.includesAvailability = result.hadSchedule
                if result.hadSchedule, let start = person.startMinute, let end = person.endMinute, let weekdays = person.workingWeekdays {
                    draft.startMinute = start
                    draft.endMinute = end == 0 ? 1_440 : end
                    draft.workingWeekdays = weekdays
                }
                let rebuilt = SharingGenerator.build(draft: draft, hostURL: "", now: now)
                ledger.check(rebuilt.document != nil, "\(tag)：导入的人物再做名片失败：\(rebuilt.errors)")
                if let document = rebuilt.document {
                    switch TimeCard.person(from: document.fragment, now: now) {
                    case .failure(let failure): ledger.check(false, "\(tag)：再编码的名片解不开：\(failure.code)")
                    case .success(let again):
                        ledger.check(again.contact == person && again.hadSchedule == result.hadSchedule,
                                     "\(tag)：往返后人物变了：原 \(person) hadSchedule=\(result.hadSchedule) → 再 \(again.contact) hadSchedule=\(again.hadSchedule)；原文 \(text.debugDescription)")
                    }
                }
            }
        }
        print("[fuzz] TimeCard：\(imported) 张导入成功，失败分布 \(failed.sorted { $0.key < $1.key })")
        ledger.finish()
    }

    // MARK: - 4. 偏好读取

    @Test(.timeLimit(.minutes(2)))
    func preferencesLoadFromAnyBytesIntoLegalValues() throws {
        let suite = "swift-fuzz-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let zonesKey = "dayside.zones.v1", settingsKey = "dayside.settings.v1"
        let allKeys = [zonesKey, settingsKey, zonesKey + ".last-nonempty", zonesKey + ".corrupt-backup", settingsKey + ".corrupt-backup"]
        var rng = SplitMix64(seed: 0x5EED_0000_0004 &+ FuzzBudget.seedOffset)
        var zonesLedger = FuzzLedger("Store.loadZones"), settingsLedger = FuzzLedger("Store.loadSettings")
        var kept = 0, recoveries = 0, defaultSettings = 0
        let clean = AppSettings()
        for sample in 0..<FuzzBudget.samples {
            zonesLedger.sample()
            settingsLedger.sample()
            for key in allKeys { defaults.removeObject(forKey: key) }

            // 地点表：主键随机字节 / 敌意 JSON / 缺席，快照键有时也塞一份。
            let archive = HostileJSON.zonesArchive(&rng)
            let primary: Data? = rng.chance(8) ? nil : (rng.chance(5) ? HostileJSON.bytes(&rng) : Data(archive.utf8))
            if let primary { defaults.set(primary, forKey: zonesKey) }
            if rng.chance(25) { defaults.set(Data(HostileJSON.zonesArchive(&rng).utf8), forKey: zonesKey + ".last-nonempty") }
            let tag = "#\(sample) \(shown(primary.map { String(decoding: $0, as: UTF8.self) } ?? "<nil>"))"
            let loaded = Store.loadZones(from: defaults)
            if loaded.recovered { recoveries += 1 }
            kept += loaded.zones.count
            zonesLedger.check(Set(loaded.zones.map(\.id)).count == loaded.zones.count, "\(tag)：条目 id 重复")
            for zone in loaded.zones {
                zonesLedger.check(TimeZone(identifier: zone.timezoneID) != nil, "\(tag)：读出的时区标识符 \(shown(zone.timezoneID)) 不合法")
                if let coordinate = zone.coordinate {
                    zonesLedger.check(coordinate.latitude.isFinite && coordinate.longitude.isFinite, "\(tag)：坐标非有限")
                }
                if let availability = zone.availability {
                    zonesLedger.check((0..<1_440).contains(availability.startMinute) && (0...1_440).contains(availability.endMinute),
                                      "\(tag)：可约时段 \(availability.startMinute)–\(availability.endMinute) 越界")
                }
            }
            // 读出来的再存一遍再读：规范化必须是不动点，且干净数据不再报恢复。
            Store.saveZones(loaded.zones, to: defaults)
            let again = Store.loadZones(from: defaults)
            zonesLedger.check(again.zones == loaded.zones && !again.recovered, "\(tag)：地点表存后再读变了（或误报恢复）")

            // 设置：同样三种来源；每个字段都得落在合法域内，存后再读是不动点。
            let settingsArchive = HostileJSON.settingsArchive(&rng)
            let settingsData: Data? = rng.chance(8) ? nil : (rng.chance(5) ? HostileJSON.bytes(&rng) : Data(settingsArchive.utf8))
            if let settingsData { defaults.set(settingsData, forKey: settingsKey) }
            let settingsTag = "#\(sample) \(shown(settingsData.map { String(decoding: $0, as: UTF8.self) } ?? "<nil>"))"
            let settings = Store.loadSettings(from: defaults)
            if settings == clean { defaultSettings += 1 }
            settingsLedger.check((1...6).contains(settings.menuBarMaxZones), "\(settingsTag)：menuBarMaxZones=\(settings.menuBarMaxZones)")
            if let color = settings.customColor {
                settingsLedger.check([color.red, color.green, color.blue, color.opacity].allSatisfy(\.isFinite), "\(settingsTag)：颜色分量非有限")
            }
            let planner = settings.planner
            settingsLedger.check((5...480).contains(planner.durationMinutes), "\(settingsTag)：durationMinutes=\(planner.durationMinutes)")
            settingsLedger.check((1...31).contains(planner.daysAhead), "\(settingsTag)：daysAhead=\(planner.daysAhead)")
            settingsLedger.check((0..<1_440).contains(planner.localAvailability.startMinute) && (0...1_440).contains(planner.localAvailability.endMinute),
                                 "\(settingsTag)：本机可约时段 \(planner.localAvailability.startMinute)–\(planner.localAvailability.endMinute)")
            let rotation = planner.rotation
            settingsLedger.check(RotationPreferences.countChoices.contains(rotation.count), "\(settingsTag)：rotation.count=\(rotation.count)")
            settingsLedger.check([1, 2].contains(rotation.intervalWeeks), "\(settingsTag)：intervalWeeks=\(rotation.intervalWeeks)")
            settingsLedger.check(RotationPreferences.stretchChoices.contains(rotation.maxStretchMinutes), "\(settingsTag)：maxStretchMinutes=\(rotation.maxStretchMinutes)")
            settingsLedger.check(rotation.weekday.map { (1...7).contains($0) } ?? true, "\(settingsTag)：weekday=\(rotation.weekday ?? -1)")
            Store.saveSettings(settings, to: defaults)
            settingsLedger.check(Store.loadSettings(from: defaults) == settings, "\(settingsTag)：设置存后再读变了")
        }
        print("[fuzz] Store：地点表共读出 \(kept) 条、\(recoveries) 次置恢复标记；设置 \(defaultSettings) 次整份回默认")
        zonesLedger.finish()
        settingsLedger.finish()
    }

    // MARK: - 5. 本地化查表与纯排版函数

    @Test(.timeLimit(.minutes(2)))
    func localizationAndPresentationHelpersAcceptAnyText() {
        var rng = SplitMix64(seed: 0x5EED_0000_0005 &+ FuzzBudget.seedOffset)
        var ledger = FuzzLedger("L10n.string / PresentationCore.call")
        var localized = 0
        for sample in 0..<FuzzBudget.samples {
            ledger.sample()
            let key = rng.chance(40) ? rng.pick(FuzzCorpus.stringKeys) : FuzzCorpus.text(&rng)
            let localeID = rng.chance(70) ? rng.pick(FuzzCorpus.localeIDs) : FuzzCorpus.text(&rng)
            let locale = Locale(identifier: localeID)
            let tag = "#\(sample) key=\(shown(key)) locale=\(shown(localeID))"
            let value = L10n.string(key, locale: locale)
            ledger.check(!value.isEmpty || key.isEmpty, "\(tag)：本地化串为空")
            if value != key { localized += 1 }

            let start = PresentationCore.IntervalEndpoint(time: FuzzCorpus.text(&rng), day: FuzzCorpus.text(&rng), abbreviation: FuzzCorpus.text(&rng))
            let end = PresentationCore.IntervalEndpoint(time: FuzzCorpus.text(&rng), day: FuzzCorpus.text(&rng), abbreviation: FuzzCorpus.text(&rng))
            let sameDay = rng.chance(50)
            let interval: String = PresentationCore.call("interval_text", PresentationCore.IntervalTextInput(
                sameDay: sameDay, startOffset: rng.int(-100_000...100_000), endOffset: rng.int(-100_000...100_000), start: start, end: end))
            ledger.check(bytesContain(interval, "–") && bytesContain(interval, start.time) && bytesContain(interval, end.time),
                         "\(tag)：区间文本 \(shown(interval)) 丢了端点")

            let customName: String? = rng.chance(50) ? FuzzCorpus.text(&rng) : nil
            let localizedCity = FuzzCorpus.text(&rng), cityName = FuzzCorpus.text(&rng), nameMode = rng.chance(60)
            let spoken: String? = PresentationCore.call("spoken_name", PresentationCore.SpokenNameInput(
                customName: customName, localizedCity: localizedCity, cityName: cityName, nameMode: nameMode))
            let expected: String? = nameMode && (customName ?? localizedCity).isEmpty ? cityName : nil
            ledger.check(spoken == expected, "\(tag)：无障碍名 \(shown(spoken ?? "<nil>")) ≠ 预期 \(shown(expected ?? "<nil>"))")

            let seconds = rng.chance(10) ? rng.pick([Int.min, Int.max, 0, -1, 1, 86_399, -86_400]) : rng.int(-200_000...200_000)
            let signed: String = PresentationCore.call("signed_offset", ["seconds": seconds])
            ledger.check(signed.hasPrefix(seconds < 0 ? "−" : "+"), "\(tag)：带符号偏移 \(shown(signed)) 的符号不对")
            let scrollSeconds = rng.chance(10) ? rng.pick([1e300, -1e300, 0, -0.0, 0.4, 59.6]) : rng.double(-100_000...100_000)
            let scroll: String = PresentationCore.call("scroll_label", ["seconds": scrollSeconds])
            ledger.check(scroll.hasSuffix("h") || scroll.hasSuffix("m") || scroll.hasSuffix("d"), "\(tag)：穿梭标签 \(shown(scroll)) 形状不对")
        }
        print("[fuzz] L10n：\(localized) 次查到译文")
        ledger.finish()
    }
}

// MARK: - 敌意 JSON 文本生成

/// 直接生成 JSON *文本*而不是走 JSONSerialization：这样才塞得进 1e309、-0、超出 Int64 的整数、
/// 截断与尾巴垃圾这些真正会出现在坏文件里的东西。
enum HostileJSON {
    static let numbers = [
        "0", "-0", "-0.0", "-1", "1", "2", "3", "4", "6", "7", "8", "12", "31", "32", "60", "120", "480", "481", "540", "1080",
        "1439", "1440", "1441", "-540", "1e309", "-1e309", "1e-400", "1E5", "9223372036854775807", "9223372036854775808",
        "-9223372036854775809", "1.5", "4.0", "0.5", "1e18", "99999999999999999999999999", "2.5e-3", "35.68", "139.69",
        "91", "-91", "181", "-181", "1e300", "0.25", "1.0", "-1.0",
    ]
    static let enumWords = [
        "name", "abbreviation", "offset", "followSystem", "force12", "force24", "regular", "medium", "semibold", "bold",
        "space", "middleDot", "pipe", "enDash", "comma", "system", "rounded", "serif", "monospaced", "nameThenTime",
        "timeThenName", "trailing", "leading", "en", "zhHans", "zhHant", "ja", "ko", "es", "fr", "de", "ru", "ptBR",
        "followInterface", "none", "hologram", "BOLD", "Name", "", " name",
    ]
    static let zoneKeys = [
        "id", "timezoneID", "customName", "cityName", "coordinate", "latitude", "longitude", "usesExemplarName",
        "localizedNames", "countryCode", "availability", "startMinute", "endMinute", "weekdaysOnly", "zh-Hans", "ja",
    ]
    static let settingsKeys = [
        "displayMode", "hourStyle", "showSeconds", "weight", "menuBarMaxZones", "separator", "fontDesign", "useCustomColor",
        "customColor", "red", "green", "blue", "opacity", "elementOrder", "rowTimeAlignment", "interfaceLanguage",
        "cityLanguage", "keepAliveInBackground", "launchAtLogin", "didAskLaunchAtLogin", "didShowWelcome", "planner", "durationMinutes",
        "daysAhead", "localAvailability", "startMinute", "endMinute", "weekdaysOnly", "includeLocal", "excludedZoneIDs",
        "isExpanded", "rotation", "weekday", "count", "intervalWeeks", "maxStretchMinutes",
    ]

    /// 一个 JSON 字符串字面量（带引号、已转义）。
    static func string(_ value: String) -> String {
        let data = (try? JSONEncoder().encode([value])) ?? Data("[\"\"]".utf8)
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }
    static func uuid(_ rng: inout SplitMix64) -> String {
        let a = rng.next(), b = rng.next()
        return String(format: "%08llX-%04llX-%04llX-%04llX-%012llX", a >> 32, (a >> 16) & 0xFFFF, a & 0xFFFF, b >> 48, b & 0xFFFF_FFFF_FFFF)
    }
    static func scalar(_ rng: inout SplitMix64) -> String {
        switch rng.below(9) {
        case 0: return "null"
        case 1: return rng.chance(50) ? "true" : "false"
        case 2, 3: return rng.pick(numbers)
        case 4: return string(rng.pick(FuzzCorpus.zoneIDs + ["Not/AZone", "GMT+9", "", " Asia/Tokyo", "asia/tokyo", "PST"]))
        case 5: return string(rng.pick(enumWords))
        case 6: return string(uuid(&rng))
        case 7: return string(rng.chance(50) ? uuid(&rng).lowercased() : String(uuid(&rng).dropLast()))
        default: return string(FuzzCorpus.text(&rng))
        }
    }
    static func value(_ rng: inout SplitMix64, depth: Int, keys: [String]) -> String {
        if depth == 0 || rng.chance(45) { return scalar(&rng) }
        if rng.chance(35) {
            var items: [String] = []
            for _ in 0..<rng.below(6) { items.append(value(&rng, depth: depth - 1, keys: keys)) }
            return "[" + items.joined(separator: ",") + "]"
        }
        var fields: [String] = []
        for _ in 0..<rng.below(9) {
            let key = rng.chance(85) ? rng.pick(keys) : FuzzCorpus.text(&rng)
            fields.append(string(key) + ":" + value(&rng, depth: depth - 1, keys: keys))
        }
        return "{" + fields.joined(separator: ",") + "}"
    }
    /// 字段：一定概率缺席、一定概率换成随机值，其余按给定的合法写法；偶尔多一个陌生键或重复键。
    static func fields(_ rng: inout SplitMix64, _ legal: [(String, String)], keys: [String]) -> String {
        var out: [String] = []
        for (key, value) in legal {
            if rng.chance(8) { continue }
            out.append(string(key) + ":" + (rng.chance(72) ? value : self.value(&rng, depth: 2, keys: keys)))
        }
        if rng.chance(10) { out.append(string(rng.pick(keys)) + ":" + value(&rng, depth: 1, keys: keys)) }
        if rng.chance(5), let duplicate = out.first { out.append(duplicate) }
        return "{" + out.joined(separator: ",") + "}"
    }
    /// 整份存档的破坏：不是 JSON、随机 JSON 值、截断、尾巴垃圾、三百层数组包裹。
    static func wrapped(_ body: String, _ rng: inout SplitMix64, keys: [String]) -> String {
        switch rng.below(12) {
        case 0: return FuzzCorpus.text(&rng)
        case 1: return value(&rng, depth: 3, keys: keys)
        case 2: return String(body.prefix(rng.below(body.count + 1)))
        case 3: return body + FuzzCorpus.text(&rng)
        case 4: return String(repeating: "[", count: 300) + body + String(repeating: "]", count: 300)
        default: return body
        }
    }
    static func bytes(_ rng: inout SplitMix64) -> Data {
        var out = [UInt8]()
        for _ in 0..<rng.below(64) { out.append(UInt8(rng.below(256))) }
        return Data(out)
    }

    static func zoneEntry(_ rng: inout SplitMix64) -> String {
        let zone = rng.pick(FuzzCorpus.zoneIDs + ["Not/AZone", "GMT+9", "", "asia/tokyo", "Asia/Tokyo ", "PST", "\u{0}"])
        return fields(&rng, [
            ("id", string(uuid(&rng))),
            ("timezoneID", string(zone)),
            ("customName", rng.chance(50) ? "null" : string(FuzzCorpus.text(&rng))),
            ("cityName", string(rng.pick(["Tokyo", "東京", "", " ", FuzzCorpus.text(&rng)]))),
            ("coordinate", "{\"latitude\":\(rng.pick(numbers)),\"longitude\":\(rng.pick(numbers))}"),
            ("usesExemplarName", rng.chance(50) ? "true" : "false"),
            ("localizedNames", "{\"zh-Hans\":\(string(FuzzCorpus.text(&rng))),\"ja\":\(string(rng.pick(["東京", ""])))}"),
            ("countryCode", string(rng.pick(["JP", "jp", "J", "JPN", "", "🇯🇵"]))),
            ("availability", "{\"startMinute\":\(rng.pick(numbers)),\"endMinute\":\(rng.pick(numbers)),\"weekdaysOnly\":\(rng.chance(50) ? "true" : "false")}"),
        ], keys: zoneKeys)
    }
    static func zonesArchive(_ rng: inout SplitMix64) -> String {
        var entries: [String] = []
        for _ in 0..<rng.below(5) { entries.append(rng.chance(80) ? zoneEntry(&rng) : value(&rng, depth: 2, keys: zoneKeys)) }
        return wrapped("[" + entries.joined(separator: ",") + "]", &rng, keys: zoneKeys)
    }

    static func settingsArchive(_ rng: inout SplitMix64) -> String {
        func boolean(_ rng: inout SplitMix64) -> String { rng.chance(50) ? "true" : "false" }
        var excluded: [String] = []
        for _ in 0..<rng.below(4) { excluded.append(string(rng.chance(80) ? uuid(&rng) : FuzzCorpus.text(&rng))) }
        let rotation = fields(&rng, [
            ("weekday", rng.chance(30) ? "null" : rng.pick(numbers)),
            ("count", rng.pick(["4", "6", "8", "12", "5", "0", "-6", "6.0", "1e309"])),
            ("intervalWeeks", rng.pick(["1", "2", "3", "0", "2.0"])),
            ("maxStretchMinutes", rng.pick(["120", "240", "360", "480", "121", "-480", "480.0"])),
        ], keys: settingsKeys)
        let availability = fields(&rng, [
            ("startMinute", rng.pick(numbers)), ("endMinute", rng.pick(numbers)), ("weekdaysOnly", boolean(&rng)),
        ], keys: settingsKeys)
        let planner = fields(&rng, [
            ("durationMinutes", rng.pick(numbers)), ("daysAhead", rng.pick(numbers)), ("localAvailability", availability),
            ("includeLocal", boolean(&rng)), ("excludedZoneIDs", "[" + excluded.joined(separator: ",") + "]"),
            ("isExpanded", boolean(&rng)), ("rotation", rotation),
        ], keys: settingsKeys)
        let color = fields(&rng, [
            ("red", rng.pick(numbers)), ("green", rng.pick(numbers)), ("blue", rng.pick(numbers)), ("opacity", rng.pick(numbers)),
        ], keys: settingsKeys)
        let body = fields(&rng, [
            ("displayMode", string(rng.pick(enumWords))), ("hourStyle", string(rng.pick(enumWords))),
            ("showSeconds", boolean(&rng)), ("weight", string(rng.pick(enumWords))),
            ("menuBarMaxZones", rng.pick(numbers)), ("separator", string(rng.pick(enumWords))),
            ("fontDesign", string(rng.pick(enumWords))), ("useCustomColor", boolean(&rng)),
            ("customColor", rng.chance(30) ? "null" : color), ("elementOrder", string(rng.pick(enumWords))),
            ("rowTimeAlignment", string(rng.pick(enumWords))), ("interfaceLanguage", string(rng.pick(enumWords))),
            ("cityLanguage", string(rng.pick(enumWords))), ("keepAliveInBackground", boolean(&rng)),
            ("launchAtLogin", boolean(&rng)), ("didAskLaunchAtLogin", boolean(&rng)), ("planner", planner),
        ], keys: settingsKeys)
        return wrapped(body, &rng, keys: settingsKeys)
    }
}
