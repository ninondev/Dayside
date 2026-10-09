// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SwiftUI
import Testing
@testable import Dayside

/// Copy 2 把可见文字搬进悬停与读屏提示后，这里只做两件可以离线验证的事：
/// DST 页「时区数据与已知规则变更一致」一行的显隐条件仍然正确，以及天文页
/// 搬进提示的两条完整键在 16 种语言的编译资源里仍解析得出译文。
/// 这是字符串查表，不是运行时无障碍测试：日出/日落与黄金时刻的提示、两个
/// 假期日期选择器与被删可见句的读屏由根目录的 AX 验证负责。
@MainActor
struct Copy2SurfaceHintTests {
    /// 用真机当下的 TZDataCheck 报告：数据全新时「一致」那一行可见（返回真）；
    /// 报告过期（stale/unknown 非空）时必须为假，把位置让给过期分区。两个方向
    /// 都断言，测试在数据全新与过期的机器上都成立。
    @Test func daylightSavingAllClearStillVisible() {
        let report = TZDataCheck.currentReport()
        let stale = TZDataCheck.Report(version: report.version, coverage: report.coverage, checked: report.checked, stale: [], unknown: ["unknown-zone"])
        #expect(!DSTWatchLensView.showsCurrentDataStatus(stale))
        let allClear = report.stale.isEmpty && report.unknown.isEmpty
        #expect(DSTWatchLensView.showsCurrentDataStatus(report) == allClear)
        if allClear {
            #expect(DSTWatchLensView.showsCurrentDataStatus(report))
        } else {
            #expect(!DSTWatchLensView.showsCurrentDataStatus(report))
        }
    }

    /// 天文页的两条完整键（原可见句原文，一字不差）在编译进 app 的每种语言里
    /// 都要有译文：非中文语言查表回退到键本身（= 缺译文）即失败。
    @Test func astronomyHintsResolveForEveryLanguage() {
        let keys = [
            "时间为天文估算，地形和天气会影响实际观测。月相按所选地点当天中午计算。",
            "黄金时刻按太阳高度 −4° 至 +6° 估算（PhotoPills 的口径；另有工具用 −6°），所有时刻均为所选地点的当地时间。",
        ]
        let bundle = Bundle(for: AppModel.self)
        let languages = Self.compiledLanguages(in: bundle)
        #expect(Set(languages) == Set(["zh-Hans", "en", "zh-Hant", "ja", "ko", "de", "es", "fr", "pt-BR", "ru", "it", "nl", "pl", "tr", "vi", "id"]))
        for identifier in languages {
            let lproj = bundle.path(forResource: identifier, ofType: "lproj").flatMap(Bundle.init(path:))
            #expect(lproj != nil, "编译资源里找不到 \(identifier).lproj")
            guard let lproj else { continue }
            for key in keys {
                let resolved = NSLocalizedString(key, bundle: lproj, value: key, comment: "")
                // 中文是源语言，值就是键本身不算缺译文；其余语言回退到键即失败。
                if identifier.hasPrefix("zh") { continue }
                #expect(resolved != key, "\(identifier) 里这条键回退到了原文：\(key)")
            }
        }
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
