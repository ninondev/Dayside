// SPDX-License-Identifier: GPL-3.0-only
//
//  InterfaceLanguageTests.swift
//  「跟随系统」只落在有译文的语言上：瑞典语、丹麦语这类还没有译文的系统此前整个界面中英混排
//  （SwiftUI 找不到意大利语就退回键本身，键是中文原文）。判据是真实的查表结果：同一个键在解析出的 locale 下
//  由 `L10n.string` 取出来的是哪种语言的译文，不是只看标识符。
//

import Foundation
import Testing
@testable import Dayside

struct InterfaceLanguageTests {
    private let available = ["zh-Hans", "en", "zh-Hant", "ja", "ko", "es", "fr", "de", "ru", "pt-BR",
                             "it", "nl", "pl", "tr", "vi", "id", "Base"]

    private func resolve(_ preferred: [String], _ current: String) -> Locale {
        InterfaceLanguage.systemLocale(preferred: preferred, current: Locale(identifier: current), available: available)
    }

    @Test func languagesWithoutTranslationsFallBackToEnglishNotToChineseKeys() {
        for (preferred, current, region) in [(["sv-SE"], "sv_SE", "SE"), (["da-DK"], "da_DK", "DK"), (["fi-FI"], "fi_FI", "FI"),
                                             (["ar-SA"], "ar_SA", "SA"), (["th-TH"], "th_TH", "TH")] {
            let locale = resolve(preferred, current)
            #expect(locale.language.languageCode?.identifier == "en", "\(preferred) → \(locale.identifier)")
            #expect(locale.region?.identifier == region, "地区照旧跟系统：\(locale.identifier)")
            #expect(L10n.string("白天", locale: locale) == "Day", "\(preferred) 查表得到 \(L10n.string("白天", locale: locale))")
        }
    }

    @Test func aLaterSupportedPreferenceWinsOverEnglish() {
        // 首选瑞典语、其次德语：界面用德语，日期写法仍按瑞典。
        let locale = resolve(["sv-SE", "de-DE"], "sv_SE")
        #expect(locale.language.languageCode?.identifier == "de")
        #expect(locale.region?.identifier == "SE")
        #expect(L10n.string("白天", locale: locale) == "Tag")
    }

    @Test func supportedSystemLanguagesKeepTheSystemLocaleUnchanged() {
        for (preferred, current) in [(["de-CH"], "de_CH"), (["zh-Hant-TW"], "zh_TW"), (["zh-Hans-CN"], "zh_CN"), (["en-GB"], "en_GB"),
                                     (["ja-JP"], "ja_JP"), (["fr-CA"], "fr_CA")] {
            #expect(resolve(preferred, current).identifier == current, "\(preferred) 应原样返回系统 locale")
        }
        #expect(L10n.string("白天", locale: resolve(["zh-Hant-TW"], "zh_TW")) == "白天")
    }

    /// 新增的六种语言：意、荷、波、土、越、印尼的系统原样用自己的译文，不再退回英文。
    @Test func theSixNewLanguagesUseTheirOwnTranslations() {
        for (preferred, current, day) in [(["it-IT"], "it_IT", "Giorno"), (["nl-NL"], "nl_NL", "Dag"), (["pl-PL"], "pl_PL", "Dzień"),
                                          (["tr-TR"], "tr_TR", "Gündüz"), (["vi-VN"], "vi_VN", "Ban ngày"), (["id-ID"], "id_ID", "Siang")] {
            let locale = resolve(preferred, current)
            #expect(locale.identifier == current, "\(preferred) 应原样返回系统 locale")
            let text = L10n.string("白天", locale: locale)
            #expect(text == day, "\(preferred) 查表得到 \(text)")
        }
    }

    @Test func portugueseFromPortugalUsesTheBrazilianTranslationWithPortugueseFormats() {
        let locale = resolve(["pt-PT"], "pt_PT")
        #expect(locale.language.languageCode?.identifier == "pt")
        #expect(locale.region?.identifier == "PT")
        #expect(L10n.string("白天", locale: locale) == L10n.string("白天", locale: Locale(identifier: "pt-BR")))
    }
}
