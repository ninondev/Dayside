// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Foundation
import Testing
@testable import Dayside

struct SearchFieldTests {
    @MainActor @Test func nativeButtonsFollowTheInterfaceLanguageWhenItChanges() throws {
        let cell = NSSearchFieldCell(textCell: "Tokyo")
        for language in ["en", "ru", "zh-Hant"] {
            let locale = Locale(identifier: language)
            SearchField.localizeButtons(cell, locale: locale)
            let search = try #require(cell.searchButtonCell)
            let clear = try #require(cell.cancelButtonCell)
            #expect(search.accessibilityLabel() == L10n.string("搜索", locale: locale))
            #expect(clear.accessibilityLabel() == L10n.string("清除搜索", locale: locale))
        }
    }
}
