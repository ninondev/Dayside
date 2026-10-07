// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SwiftUI
import Testing
@testable import TahoeTime

/// 地球窗底栏读屏的全句与删掉方向提示后的换钟日步进（`EarthView.scrubCaption` / `MapScrub.step`）。
@MainActor struct Copy2EarthHintTests {
    /// 「本机%1$@ %2$@，%3$@」：整天、钟点、完整偏移（带方向）三份互不相同的样例，每种语言都恰好各出现一遍；
    /// 窄的可见版省了日期、偏移用了紧凑写法，念出来的仍是同一句全句。
    @Test func fullEarthCaptionHasDateClockAndDirectionInEveryLanguage() {
        let key = "本机%1$@ %2$@，%3$@"
        let languages = ["zh-Hans", "en", "zh-Hant", "ja", "ko", "de", "es", "fr", "pt-BR", "ru", "it", "nl", "pl", "tr", "vi", "id"].map { Locale(identifier: $0) }
        let samples: [(day: String, clock: String, offset: String)] = [
            ("10月7日 星期三", "09:41", "早 2 小时 15 分"),
            ("October 8, 2026", "23:59", "晚 1 小时"),
            ("1月1日 星期四", "00:00", "晚 45 分"),
        ]
        for locale in languages {
            for sample in samples {
                let formatted = String(format: L10n.string(key, locale: locale), sample.day, sample.clock, sample.offset)
                for part in [sample.day, sample.clock, sample.offset] {
                    #expect(occurrences(of: part, in: formatted) == 1,
                            "\(locale.identifier)：\(part) 应在 \(formatted) 里恰好出现一次")
                }
                let font = Font.system(size: 13, weight: .semibold).monospacedDigit()
                // 宽的可见版：读屏与整句一致。
                #expect(EarthView.scrubCaption(day: sample.day, clock: sample.clock, fullShift: sample.offset,
                                               compactShift: nil, date: true, clockFont: font, locale: locale).spoken == formatted)
                // 窄的可见版（省日期、偏移用紧凑写法）只改眼睛看的；耳朵听的仍是全句，不含紧凑偏移。
                let narrow = EarthView.scrubCaption(day: sample.day, clock: sample.clock, fullShift: sample.offset,
                                                    compactShift: "紧凑", date: false, clockFont: font, locale: locale)
                #expect(narrow.spoken == formatted)
                #expect(!narrow.spoken.contains("紧凑"))
            }
        }
    }

    /// 删掉方向提示不拖累键盘与读屏的一步：换钟日也按真实时间往前 / 往后，整点与整刻钟都对齐、不走回头路。
    @Test func dragHintRemovalPreservesHourAndQuarterHourSteps() throws {
        let newYork = try #require(TimeZone(identifier: "America/New_York"))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        func instant(month: Int, day: Int, hour: Int, minute: Int) -> Date {
            utc.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
        }
        var wall = Calendar(identifier: .gregorian)
        wall.timeZone = newYork

        // 春令时（2026-03-08）：钟面 2 点不存在，02:00 EST 一跳变 03:00 EDT。
        let beforeGap = instant(month: 3, day: 8, hour: 6, minute: 30)                 // 01:30 EST
        let hourForward = MapScrub.step(from: beforeGap, minutes: 60, forward: true, in: newYork)
        #expect(hourForward == instant(month: 3, day: 8, hour: 7, minute: 0))         // 03:00 EDT
        #expect(hourForward > beforeGap)
        let wallClock = wall.dateComponents([.hour, .minute], from: hourForward)
        #expect(wallClock.hour == 3 && wallClock.minute == 0)
        let hourBack = MapScrub.step(from: beforeGap, minutes: 60, forward: false, in: newYork)
        #expect(hourBack == instant(month: 3, day: 8, hour: 6, minute: 0))            // 01:00 EST
        #expect(hourBack < beforeGap)
        let quarterForward = MapScrub.step(from: instant(month: 3, day: 8, hour: 6, minute: 45), minutes: 15, forward: true, in: newYork)
        #expect(quarterForward == instant(month: 3, day: 8, hour: 7, minute: 0))      // 01:45 EST 一刻钟跨过空洞到 03:00 EDT
        #expect(quarterForward > instant(month: 3, day: 8, hour: 6, minute: 45))

        // 秋令时（2026-11-01）：钟面 1 点出现两次，方向仍按真实时间走。
        let earlyOneThirty = instant(month: 11, day: 1, hour: 5, minute: 30)          // 第一个 01:30（EDT）
        let fallForward = MapScrub.step(from: earlyOneThirty, minutes: 60, forward: true, in: newYork)
        #expect(fallForward == instant(month: 11, day: 1, hour: 6, minute: 0))        // 01:00 EST：钟面看似回头，真实时间向前
        #expect(fallForward > earlyOneThirty)
        let fallWallClock = wall.dateComponents([.hour, .minute], from: fallForward)
        #expect(fallWallClock.hour == 1 && fallWallClock.minute == 0)
        let lateOneThirty = instant(month: 11, day: 1, hour: 6, minute: 30)           // 第二个 01:30（EST）
        let back = MapScrub.step(from: lateOneThirty, minutes: 60, forward: false, in: newYork)
        #expect(back == instant(month: 11, day: 1, hour: 6, minute: 0))               // 01:00 EST
        #expect(back < lateOneThirty)
        let quarterBack = MapScrub.step(from: instant(month: 11, day: 1, hour: 6, minute: 15), minutes: 15, forward: false, in: newYork)
        #expect(quarterBack == instant(month: 11, day: 1, hour: 6, minute: 0))
        #expect(quarterBack < instant(month: 11, day: 1, hour: 6, minute: 15))
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }
}
