// SPDX-License-Identifier: GPL-3.0-only
// 仅补现有国家名的语言归属，不添加名字或更改原表。
import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let data = root.appendingPathComponent("RustCore/data")
let rows = try String(contentsOf: data.appendingPathComponent("country_names.tsv"), encoding: .utf8).split(separator: "\n").filter { !$0.hasPrefix("#") }
let languages = ["zh-Hans", "zh-Hant", "en", "ja", "ko", "de", "es", "fr", "pt-BR", "ru", "it", "nl", "pl", "tr", "vi", "id"]
var output = ["# SPDX-License-Identifier: GPL-3.0-only", "# 国家码、语言、现有 country_names.tsv 中从零起算的名字列号"]
for row in rows {
    let fields = row.split(separator: "\t").map(String.init)
    for language in languages {
        if let name = Locale(identifier: language).localizedString(forRegionCode: fields[0]), let index = fields.dropFirst().firstIndex(of: name) {
            output.append("\(fields[0])\t\(language)\t\(index - 1)")
        }
    }
}
try (output.joined(separator: "\n") + "\n").write(to: data.appendingPathComponent("nearby_country_languages.tsv"), atomically: true, encoding: .utf8)
