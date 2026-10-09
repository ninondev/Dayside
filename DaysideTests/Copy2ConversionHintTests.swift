// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SwiftUI
import Testing
@testable import Dayside

/// Copy2：换算页的文案改名与真太阳时的证据（悬停、读屏提示的检查在根上的 AX 一套里）。
@MainActor
struct Copy2ConversionHintTests {
    /// 「读懂了」改名「读到的时间」：字符串目录里各语言都得有译文（中文的键就是值，不算退回）。
    @Test func renamedResultHeaderIsLocalizedInEveryLanguage() {
        let key = "读到的时间"
        for code in ["zh-Hans", "en", "zh-Hant", "ja", "ko", "de", "es", "fr", "pt-BR", "ru", "it", "nl", "pl", "tr", "vi", "id"] {
            #expect(Bundle.main.path(forResource: code, ofType: "lproj") != nil)
            let locale = Locale(identifier: code)
            guard locale.language.languageCode?.identifier != "zh" else { continue }
            #expect(L10n.string(key, locale: locale) != key, "「\(key)」在 \(code) 退回了键名：目录里还没有这个词的译文")
        }
    }

    /// 真太阳时的证据还在（换算页脚注靠它说话）：1947 年前的利雅得偏移带秒，
    /// 复制的 ISO 8601 仍把真偏移四舍五入到整分钟（+03:06:52 → +03:07）。
    @Test func localMeanTimeKeepsRoundedTimestampEvidence() throws {
        let zone = try #require(TimeZone(identifier: "Asia/Riyadh"))
        var components = DateComponents()
        components.year = 1940
        components.month = 6
        components.day = 1
        components.hour = 12
        let date = try #require(Calendar.gregorianUTC(TimeZone(identifier: "UTC") ?? .gmt).date(from: components))
        let seconds = zone.secondsFromGMT(for: date)
        #expect(seconds % 60 != 0, "前提不成立：1940 年的利雅得偏移不带秒，系统时区库与调研时不一样了")
        let stamps = try #require(TimeInput.timestamps(for: date, in: zone))
        let minutes = Int((Double(seconds) / 60).rounded())
        let expected = String(format: "%@%02d:%02d", minutes < 0 ? "-" : "+",
                              Int32(abs(minutes) / 60), Int32(abs(minutes) % 60))
        #expect(stamps.iso8601.hasSuffix(expected),
                "ISO 8601 的偏移没有按真偏移四舍五入到整分钟：\(stamps.iso8601) 应以 \(expected) 结尾")
    }
}
