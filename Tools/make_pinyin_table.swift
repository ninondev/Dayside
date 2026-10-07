// SPDX-License-Identifier: GPL-3.0-only
//
//  make_pinyin_table.swift
//  Dayside 工具（一次性生成，产物入库）
//
//  把「前 N 座城市的中文名」转成拼音与首字母，写成 `RustCore/data/pinyin_keys.tsv`
//  （前 1,000 城的封闭表）。拼音来自系统 ICU 的中文转写
//  （`kCFStringTransformMandarinLatin` 再去声调），与 App 里用的是同一套系统数据。
//
//  用法：
//    cd RustCore && cargo test --lib export_top_cities_for_pinyin -- --ignored --nocapture > /tmp/cities.tsv
//    swift Tools/make_pinyin_table.swift /tmp/cities.tsv RustCore/data/pinyin_keys.tsv
//

import Foundation

/// 「北京」→ ["bei", "jing"]。ICU 给的是带声调的音节，用空格分开；去掉声调与非字母。
func syllables(_ chinese: String) -> [String] {
    let mutable = NSMutableString(string: chinese) as CFMutableString
    guard CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false),
          CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
    else { return [] }
    return (mutable as String)
        .lowercased()
        .split(whereSeparator: { !$0.isLetter })
        .map(String.init)
        .filter { !$0.isEmpty }
}

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write(Data("用法：swift Tools/make_pinyin_table.swift <cities.tsv> <out.tsv>\n".utf8))
    exit(2)
}
let input = try String(contentsOfFile: arguments[1], encoding: .utf8)
var rows: [String] = []
var skipped = 0
for line in input.split(separator: "\n") {
    if line.hasPrefix("#") { continue }
    let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    guard parts.count >= 4 else { continue }
    let (name, country, chinese) = (parts[1], parts[2], parts[3])
    // 只收真的有汉字的名字（有些「中文名」其实是拉丁拼写）。
    guard chinese.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains(Int($0.value)) }) else {
        skipped += 1
        continue
    }
    let parts2 = syllables(chinese)
    guard parts2.count >= 2 else { skipped += 1; continue }
    let full = parts2.joined()
    let initials = parts2.compactMap { $0.first.map(String.init) }.joined()
    // 首字母至少两个字母才有检索价值（单字母会撞上一切）。
    guard initials.count >= 2 else { skipped += 1; continue }
    rows.append([full, initials, name, country, chinese].joined(separator: "\t"))
}
rows.sort()
let header = """
# 拼音检索表。由 Tools/make_pinyin_table.swift 从前 1,000 座城市的中文名生成：
# 拼音（无声调、无空格）\t首字母\t城市主名\t国家码\t中文名
# 拼音来自系统 ICU 的中文转写（kCFStringTransformMandarinLatin + StripDiacritics），与 App 用的是同一套数据。
# 这是查询侧的封闭表：只决定「输入 bj 或 beijing 时该找哪座城」，不改索引、不改显示名。
"""
try (header + "\n" + rows.joined(separator: "\n") + "\n").write(toFile: arguments[2], atomically: true, encoding: .utf8)
FileHandle.standardError.write(Data("写出 \(rows.count) 行，跳过 \(skipped) 行 → \(arguments[2])\n".utf8))
