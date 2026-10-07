// SPDX-License-Identifier: GPL-3.0-only
// 十六种界面语言的国家名（「听懂时间」认「9am in Brazil / 巴西 9 点 / в Бразилии」用）：取系统自带的地区名
// （Locale.localizedString(forRegionCode:)，即 CLDR），只收 RustCore/data/country_zones.tsv 里有时区的国家。
// 每个国家一行：`国家码 \t 名字 \t 名字 …`（去重、排序），写到 RustCore/data/country_names.tsv。
// 用法：swift Tools/make_country_names.swift
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let zonesURL = root.appendingPathComponent("RustCore/data/country_zones.tsv")
let outURL = root.appendingPathComponent("RustCore/data/country_names.tsv")
let languages = ["zh-Hans", "zh-Hant", "en", "ja", "ko", "de", "es", "fr", "pt-BR", "ru", "it", "nl", "pl", "tr", "vi", "id"]
let codes = try String(contentsOf: zonesURL, encoding: .utf8)
    .split(separator: "\n")
    .filter { !$0.hasPrefix("#") }
    .compactMap { $0.split(separator: "\t").first.map(String.init) }
var lines = ["# 由 Tools/make_country_names.swift 从系统自带的地区名（CLDR，macOS \(ProcessInfo.processInfo.operatingSystemVersionString)）生成，不要手改"]
var total = 0
for code in codes {
    var names = Set<String>()
    for language in languages {
        if let name = Locale(identifier: language).localizedString(forRegionCode: code), name != code {
            names.insert(name)
        }
    }
    total += names.count
    lines.append(([code] + names.sorted()).joined(separator: "\t"))
}
try (lines.joined(separator: "\n") + "\n").write(to: outURL, atomically: true, encoding: .utf8)
print("RustCore/data/country_names.tsv：\(codes.count) 个国家，\(total) 个名字")
