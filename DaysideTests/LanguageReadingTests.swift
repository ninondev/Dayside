// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import Dayside

@MainActor
struct LanguageReadingTests {
    private let reference = Date(timeIntervalSince1970: 1_789_000_000)

    /// 第一处读成的时刻按它自己的时区写成「2026-09-15 15:00 Asia/Tokyo」（固定偏移写 GMT+0800）；读不成是 nil。
    /// 直接输入原文，断言读出的时刻与时区，覆盖口语写法。
    private func reading(_ text: String, _ reference: Date, in zone: TimeZone) -> String? {
        let result = TimeInput.resolve(text, relativeTo: reference, now: reference, in: zone)
        guard result.error == nil, let date = result.dates.first else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = result.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "\(formatter.string(from: date)) \(result.timeZone.identifier)"
    }

    @Test func phrasesAreReadByTheDeterministicEngine() async {
        // Thursday 2026-09-10 12:00 UTC.
        let thursday = Date(timeIntervalSince1970: 1_789_041_600)
        #expect(reading("下周二东京下午三点", thursday, in: .gmt) == "2026-09-15 15:00 Asia/Tokyo")
        #expect(reading("next friday 9am london", thursday, in: .gmt) == "2026-09-18 09:00 Europe/London")
        #expect(reading("tomorrow 3pm", thursday, in: TimeZone(identifier: "Asia/Tokyo")!) == "2026-09-11 15:00 Asia/Tokyo")
        #expect(TimeInput.resolve("明天上午十点 UTC+8", relativeTo: thursday, in: .gmt).dates == [Date(timeIntervalSince1970: 1_789_092_000)])
        #expect(reading("tomorrow 3pm", thursday, in: TimeZone(secondsFromGMT: -12 * 3_600)!) == "2026-09-11 15:00 GMT-1200")
        #expect(reading("东京", thursday, in: .gmt) == nil)
        // 认不出的零散词不当地名，也不挡住钟点（整段里找时间，换心起）：按来源时区读。
        #expect(reading("下午三点 不存在的地方xyz", thursday, in: .gmt) == "2026-09-10 15:00 GMT")
    }

    @Test func explicitUTCReadsOneInstant() {
        #expect(TimeInput.resolve("14:00 UTC", relativeTo: reference, in: .gmt).dates.count == 1)
    }

    @Test func russianDeclinedPlacesReachTheirCity() async {
        // Thursday 2026-09-10 12:00 UTC.
        let thursday = Date(timeIntervalSince1970: 1_789_041_600)
        // 「в Москве」是 Москва 的方位格：引擎只收列出来的词尾，还原成原形后要是精确的键。
        #expect(reading("в Москве в 15:00", thursday, in: .gmt) == "2026-09-10 15:00 Europe/Moscow")
        // Бари 本身就是地名（也以列出的词尾之一结尾），不能被截成别的城市。
        #expect(TimeInput.resolve("в Бари в 15:00", relativeTo: thursday, in: .gmt).timeZone.identifier == "Europe/Rome")
    }

    /// 换算页示例行里的每个例子都必须真能换算：zh「可写 14:00、明天 9:00 东京、后天下午三点 伦敦、三小时后 纽约。」、
    /// zh-Hant「…後天下午三點 倫敦、三小時後 紐約」、en「Try 14:00, tomorrow 9:00 Tokyo, 9am Central, or in 3 hours New York.」
    /// 及其余七语的相对句例子。
    @Test func examplesShownInTheConverterHintAreReadable() {
        // Thursday 2026-09-10 12:00 UTC.
        let thursday = Date(timeIntervalSince1970: 1_789_041_600)
        #expect(TimeInput.resolve("14:00", relativeTo: thursday, in: .gmt).error == nil)
        #expect(reading("明天 9:00 东京", thursday, in: .gmt) == "2026-09-11 09:00 Asia/Tokyo")
        #expect(reading("后天下午三点 伦敦", thursday, in: .gmt) == "2026-09-12 15:00 Europe/London")
        #expect(reading("後天下午三點 倫敦", thursday, in: .gmt) == "2026-09-12 15:00 Europe/London")
        #expect(reading("tomorrow 9:00 Tokyo", thursday, in: .gmt) == "2026-09-11 09:00 Asia/Tokyo")
        #expect(TimeInput.resolve("9am Central", relativeTo: thursday, in: .gmt).error == nil)
        // 12:00 UTC + 3 h = 15:00 UTC = 11:00 纽约（九月是夏令时）。
        for example in ["三小时后 纽约", "三小時後 紐約", "in 3 hours New York", "in 3 Stunden New York", "en 3 horas Nueva York",
                        "dans 3 heures New York", "daqui a 3 horas Nova York", "через 3 часа Нью-Йорк", "3時間後 ニューヨーク", "3시간 후 뉴욕"] {
            #expect(reading(example, thursday, in: .gmt) == "2026-09-10 11:00 America/New_York", "\(example)")
        }
    }

    /// 时区词：「美东 / 北京时间 / 东八区 / Eastern Time / 한국시간 / hora del este」直接给时区；
    /// 「成都时间 / osaka time / hora de Quito」剥掉模板词后查城市索引。
    @Test func zoneWordsAndTimeTemplatesResolve() {
        // Thursday 2026-09-10 12:00 UTC.
        let thursday = Date(timeIntervalSince1970: 1_789_041_600)
        for (phrase, zone) in [("美东时间下午三点", "America/New_York"), ("北京时间晚上8点", "Asia/Shanghai"), ("东八区 15:00", "Asia/Shanghai"),
                               ("3pm eastern time", "America/New_York"), ("9am beijing time", "Asia/Shanghai"), ("3pm korea time", "Asia/Seoul"),
                               ("오후 3시 한국시간", "Asia/Seoul"), ("a las 15:00 hora del pacífico", "America/Los_Angeles"), ("15 Uhr Ostküste", "America/New_York"),
                               ("成都时间下午三点", "Asia/Shanghai"), ("3pm osaka time", "Asia/Tokyo"), ("a las 15:00 hora de Quito", "America/Guayaquil"),
                               ("9am 美东", "America/New_York"), ("9am ET", "America/New_York"), ("15:00 hora del este", "America/New_York"),
                               ("9am 明天 北京时间", "Asia/Shanghai")] {
            let result = TimeInput.resolve(phrase, relativeTo: thursday, in: .gmt)
            #expect(result.error == nil && result.timeZone.identifier == zone, "\(phrase) → \(result.timeZone.identifier) \(result.error ?? "")")
        }
    }

    /// 相对句：偏移从「现在」算，钟点按目标时区读；「之前」是负数；没有地点就用来源时区；跨日跨年都按真实时刻走。
    @Test func relativePhrasesOffsetTheReferenceInstant() {
        // Thursday 2026-09-10 12:00 UTC.
        let thursday = Date(timeIntervalSince1970: 1_789_041_600)
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        #expect(reading("in 45 minutes", thursday, in: tokyo) == "2026-09-10 21:45 Asia/Tokyo")
        #expect(reading("3小时后", thursday, in: tokyo) == "2026-09-11 00:00 Asia/Tokyo")
        #expect(reading("20 minutes ago london", thursday, in: tokyo) == "2026-09-10 12:40 Europe/London")
        #expect(reading("两小时后 UTC+8", thursday, in: .gmt) == "2026-09-10 22:00 GMT+0800")
        // 跨年：12-31 23:30 UTC + 1 小时
        let newYearsEve = Date(timeIntervalSince1970: 1_798_759_800)
        #expect(reading("in an hour", newYearsEve, in: .gmt) == "2027-01-01 00:30 GMT")
        #expect(TimeInput.resolve("2 hours from now paris", relativeTo: thursday, now: thursday, in: .gmt).dates == [thursday.addingTimeInterval(7_200)])
        // 「in 2 hours at 3pm」是两处（此前整句报错）：第一处是两小时后。
        #expect(reading("in 2 hours at 3pm", thursday, in: .gmt) == "2026-09-10 14:00 GMT")
        #expect(reading("三天后早上七点", thursday, in: .gmt) == "2026-09-13 07:00 GMT")
        #expect(reading("later", thursday, in: .gmt) == nil)
    }

}
