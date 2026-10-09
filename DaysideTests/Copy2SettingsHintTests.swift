// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SwiftUI
import Testing
@testable import Dayside

/// Copy 2 设置与分享这组改动里可以离线钉住的两件事：版本行的读屏标签在编译进 app 的
/// 每种语言里都保得住真实版本号；城市语言选「不显示城市名」只藏显示名，存档与时钟不动。
/// 设置页与帮助页的读屏名字、被删可见句不再出现，由根目录的 AX 验证负责。
@MainActor
struct Copy2SettingsHintTests {

    /// 版本行的读屏键 `Dayside，版本%@` 拿可区分的样本 `1.2.3 (47)` 在每种语言里过一遍：
    /// 格式化后样本恰好出现一次（既不吞掉版本号、也不重复），且不残留未解析的 %@。
    /// 某种语言还没配上译文时回退到键本身，仍带一个 %@，同样成立；译文丢了占位符才会失败。
    @Test func versionHintPreservesActualVersionInEveryLanguage() {
        let sample = "1.2.3 (47)"
        let bundle = Bundle(for: AppModel.self)
        let languages = Self.compiledLanguages(in: bundle)
        #expect(Set(languages) == Set(["zh-Hans", "en", "zh-Hant", "ja", "ko", "de", "es", "fr", "pt-BR", "ru", "it", "nl", "pl", "tr", "vi", "id"]))
        for identifier in languages {
            let lproj = bundle.path(forResource: identifier, ofType: "lproj").flatMap(Bundle.init(path:))
            #expect(lproj != nil, "编译资源里找不到 \(identifier).lproj")
            guard let lproj else { continue }
            let spoken = String(format: NSLocalizedString("Dayside，版本%@", bundle: lproj, value: "Dayside，版本%@", comment: ""), sample)
            #expect(spoken.components(separatedBy: sample).count == 2, "\(identifier) 里版本样本不是恰好出现一次：\(spoken)")
            #expect(!spoken.contains("%@"), "\(identifier) 里残留未解析的 %@：\(spoken)")
        }
    }

    /// 城市语言切到 .none 只影响显示层：面板读的城市名为空（隐藏），但存档的地点
    /// （id、时区标识符、存的英文名）与时钟（now）原样不动；设置落盘，重开 AppModel 仍在。
    @Test func hideCityNamesKeepsStoredPlaceAndClock() throws {
        let (defaults, cleanup) = TestDefaults.make(prefix: "copy2settings")
        defer { cleanup() }
        Store.saveZones([TimeZoneEntry(timezoneID: "Asia/Tokyo", cityName: "Tokyo", countryCode: "JP")], to: defaults)
        let model = AppModel(defaults: defaults, migrate: false)
        let anchor = try #require(ISO8601DateFormatter().date(from: "2026-09-17T09:00:00Z"))
        model.now = anchor
        let entry = try #require(model.zones.first)
        #expect(!model.localizedCity(entry).isEmpty)
        model.settings.cityLanguage = .none
        #expect(model.localizedCity(entry).isEmpty)
        let after = try #require(model.zones.first)
        #expect(after.id == entry.id)
        #expect(after.timezoneID == entry.timezoneID)
        #expect(after.cityName == entry.cityName)
        #expect(model.now == anchor)
        let reloaded = AppModel(defaults: defaults, migrate: false)
        #expect(reloaded.zones.map(\.id) == [entry.id])
        #expect(reloaded.zones.map(\.timezoneID) == [entry.timezoneID])
        #expect(reloaded.settings.cityLanguage == .none)
    }

    /// 编译进 app 的语言目录：只数带 Localizable.strings 表的 .lproj（Base 之类不算）。
    private static func compiledLanguages(in bundle: Bundle) -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: bundle.resourcePath ?? bundle.bundlePath)) ?? []
        return entries
            .filter { $0.hasSuffix(".lproj") }
            .map { String($0.dropLast(".lproj".count)) }
            .filter { identifier in
                guard let lproj = bundle.path(forResource: identifier, ofType: "lproj").flatMap(Bundle.init(path:)) else {
                    return false
                }
                return lproj.url(forResource: "Localizable", withExtension: "strings") != nil
            }
            .sorted()
    }
}
