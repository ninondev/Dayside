#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""检查单份界面文案、源码键、十六语译文与 Apple 排版规则。

--check 发现缺键、未用键、缺译文、排版问题或过期编译提取时失败。
--require-compiler-data 要求当前工作区的编译提取；--derived-data、
--configuration 与 --arch 可明确选择 xcodebuild 的构建目录与架构。
没有编译数据时只执行静态检查，并明确说明证据范围。
"""
from __future__ import annotations

import argparse
import collections
import copy
import json
import os
import re
import sys
from pathlib import Path

import l10n_apple_style as apple_style

ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "TahoeTime/Resources/Localizable.xcstrings"
SHORTCUT_CATALOG = ROOT / "TahoeTime/Resources/AppShortcuts.xcstrings"
SYSTEM_CATALOGS = [ROOT / "TahoeTime/Resources/InfoPlist.xcstrings",
                   ROOT / "TahoeTime/Resources/ServicesMenu.xcstrings"]
LANGUAGES = ["zh-Hans", "en", "zh-Hant", "ja", "ko", "de", "es", "fr", "ru", "pt-BR", "it", "nl", "pl", "tr", "vi", "id"]
SWIFT_ROOTS = ["TahoeTime", "Shared", "TahoeTimeTests", "DaysideiOS", "TahoeTimeUITests"]


def sources() -> dict[Path, str]:
    """按源码目录读取文件，导出的源码无需 Git 或其他工具脚本。"""
    out: dict[Path, str] = {}
    for rel in SWIFT_ROOTS:
        for p in sorted((ROOT / rel).rglob("*.swift")):
            if "Generated" not in p.relative_to(ROOT).parts:
                out[p] = p.read_text(encoding="utf-8")
    for p in sorted((ROOT / "RustCore/src").rglob("*.rs")):
        if RUST_DATA_DIRS & set(p.parts):
            continue   # 数据目录里的词（「从」「到」）与界面文案同形，不算引用
        out[p] = p.read_text(encoding="utf-8")
    return out


PLACEHOLDER = re.compile(r"%(?:\d+\$)?[@dfsl.0-9]+|\$\{[^}]*\}")


def key_pattern(key: str) -> re.Pattern[str]:
    """把目录键变成能在源码里认出它的正则：占位符处允许 Swift 插值 `\\(…)` 或同一占位符。"""
    literal = PLACEHOLDER.split(key)
    # 占位符的替代写法组成一个组，避免单个占位符匹配到不相关的键。
    pattern = r"(?:\\\((?:[^()]|\([^()]*\))*\)|%(?:\d+\$)?[@dfsl.0-9]+|\$\{[^}]*\})"
    escaped = [re.escape(p) for p in literal]
    return re.compile('"' + pattern.join(escaped) + '"')


def referenced_keys(catalog_keys: list[str], files: dict[Path, str]) -> set[str]:
    found: set[str] = set()
    patterns = {k: key_pattern(k) for k in catalog_keys}
    for text in files.values():
        for k in catalog_keys:
            if '"' + k + '"' in text or patterns[k].search(text):
                found.add(k)
    return found


def load(path: Path) -> dict:
    if not path.exists():
        return {"sourceLanguage": "zh-Hans", "strings": {}, "version": "1.0"}
    return json.loads(path.read_text(encoding="utf-8"))


# 源码里的键也要核对目录，防止缺键时界面直接显示源串。三条路一起核：
#   ① 编译器提取：Xcode 编 Debug 时给每个 Swift 文件写 `Objects-normal/<arch>/<文件>.stringsdata`（`SWIFT_EMIT_LOC_STRINGS`），
#      里面是编译器看到的每个可本地化字面量（`Text("…")` / `Label` / `Button` / `String(localized:)` / `LocalizedStringKey` …，
#      插值已归一成 `%@` / `%lld`），逐键核目录；stringsdata 比源文件旧就算「构建过期」，同样不过。
#   ② 运行时查表：`L10n.string("…")` 的字面量键，编译器不提取，正则找。
#   ③ Swift 与 Rust 里其余含中日韩文的字面量（`titleKey` 这类枚举返回的键、Rust 回给宿主再本地化的键）：
#      不在目录里就报，除非是数据模块（词表、地名表）、测试 / 夹具、错误信息（`Err(` / `panic!` / `assert`）或明确列在允许表里。
DERIVED_DATA = Path.home() / "Library/Developer/Xcode/DerivedData"
# 只认字母（汉字、假名、谚文），「、」这类标点不算。
CJK = re.compile(r"[\u3041-\u30ff\u3400-\u4dbf\u4e00-\u9fff\uac00-\ud7af]")
# Rust 里这些文件的中文是数据（地名与地区表、索引规则、模糊测试语料），不是文案。
RUST_DATA_MODULES = {"catalog.rs", "index_builder.rs", "index_builder_rules.rs", "fuzz_tests.rs",
                     "city_index.rs", "ttcity.rs", "fsst.rs", "tzdata.rs",
                     "day_words.rs"}   # 各语言自己的钟点表与太阳四词，原样显示，不进目录。
# 理解引擎的词表与读句子用的字面量用于比对，不是界面文案。
RUST_DATA_DIRS = {"understand"}
# 夹具与测试数据。
SWIFT_DATA_FILES = {"UITestFixture.swift"}
# 明确允许的非目录字面量（各自的理由）。
ALLOWED_LITERALS = {
    "简体中文", "繁體中文", "日本語", "한국어",   # settings.rs：界面语言的名字各用自己的文字显示，不翻译
    "Dayside Panel",                              # TahoeTimeApp.swift：Debug 转储专用的 audit-panel 窗口标题，用户看不到
    "天涯共此时", "天涯共此時",                   # 海报题记原文，只在中文界面出现，不翻译。
}
ERROR_LINE = re.compile(r"\bErr\(|panic!\(|assert(_eq|_ne)?!\(|\.expect\(|unreachable!\(|preconditionFailure\(|fatalError\(|assertionFailure\(")
LOCALIZED_CALL = re.compile(
    r'\b(?:Text|Label|Button|Toggle|Picker|GroupBox|LabeledContent|Section|'
    r'LocalizedStringKey|LocalizedStringResource|NSLocalizedString)\(\s*'
    r'|\bString\(\s*localized:\s*|\bL10n\.string\(\s*'
    r'|\.(?:navigationTitle|accessibilityLabel|accessibilityHint|help|confirmationDialog|alert)\(\s*'
)


def _strip_line_comment(line: str) -> str:
    # 只去掉不在字符串里的 // 注释（粗略：引号数为偶时才算注释开始）。
    out, quotes = [], 0
    i = 0
    while i < len(line):
        c = line[i]
        if c == '"' and (i == 0 or line[i - 1] != "\\"):
            quotes += 1
        if line.startswith("//", i) and quotes % 2 == 0:
            break
        out.append(c)
        i += 1
    return "".join(out)


def compiled_string_keys(files: dict[Path, str], derived_data: Path | None = None,
                         configuration: str = "Debug", arch: str | None = None) -> tuple[dict[str, str], list[str], str]:
    """只核对当前工作区的编译提取，返回键、问题与证据范围。"""
    pattern = f"Build/Intermediates.noindex/TahoeTime.build/{configuration}/TahoeTime.build/Objects-normal/{arch or '*'}/*.stringsdata"
    custom = derived_data or os.environ.get("DAYSIDE_DERIVED_DATA")
    candidates = sorted(Path(custom).glob(pattern) if custom else DERIVED_DATA.glob("TahoeTime-*/" + pattern))
    extracts: list[tuple[Path, Path, dict]] = []
    for path in candidates:
        data = json.loads(path.read_text(encoding="utf-8"))
        raw_source = data.get("source")
        if not raw_source:
            continue
        source = Path(raw_source)
        source = (source if source.is_absolute() else ROOT / source).resolve()
        if source in files and source_is_ui(source):
            extracts.append((path, source, data))
    if not extracts:
        return {}, [], "仅静态检查：没有当前工作区的编译器提取数据，未核对编译器键"
    # 多份 DerivedData、多个架构目录（Rosetta 那次的 x86_64 会留着旧文件）时，只看最新的那个目录。
    newest_dir = max({p.parent for p, _, _ in extracts}, key=lambda d: max(p.stat().st_mtime for p, _, _ in extracts if p.parent == d))
    keys: dict[str, str] = {}
    problems: list[str] = []
    # 「过期」的判据是源文件比这个目录里**最后一次构建**新：没被改过的文件 Xcode 不会重编，它的 .stringsdata
    # 保持旧时间戳是正常的（mtime 变了但内容没变的文件也不会重编）。
    last_build = max(p.stat().st_mtime for p, _, _ in extracts if p.parent == newest_dir)
    for source in files:
        if source.suffix == ".swift" and source_is_ui(source) and source.stat().st_mtime > last_build + 1:
            problems.append(f"编译提取过期：{source.relative_to(ROOT)} 在最后一次 {configuration} 构建之后改过，先 build 再核")
    for path, source, data in extracts:
        if path.parent != newest_dir:
            continue
        for entry in data.get("tables", {}).get("Localizable", []):
            key = entry.get("key")
            if key is not None and key not in keys:
                loc = entry.get("location", {})
                keys[key] = f"{source.name}:{loc.get('startingLine', '?')}"
    return keys, problems, f"静态 + 编译器检查：编译器提取 {len(keys)} 键（{newest_dir}）"


def source_is_ui(path: Path) -> bool:
    return not (path.name in SWIFT_DATA_FILES or "DaysideiOS" in path.parts
                or any(part.endswith("Tests") for part in path.parts))


def decode_literal(literal: str) -> str:
    escapes = {"n": "\n", "r": "\r", "t": "\t", '"': '"', "\\": "\\"}
    return re.sub(r'\\([nrt"\\])', lambda m: escapes[m.group(1)], literal)


def string_literals(body: str, swift: bool) -> list[tuple[int, int, str]]:
    """Swift 插值里可以有调用和字符串；按括号配对读取，保留内部字符串。"""
    found: list[tuple[int, int, str]] = []

    def interpolation(i: int) -> int:
        depth = 1
        while i < len(body) and depth:
            if body[i] == '"':
                i = quoted(i)
                continue
            if body[i] == "(":
                depth += 1
            elif body[i] == ")":
                depth -= 1
            i += 1
        return i

    def quoted(start: int) -> int:
        i = start + 1
        while i < len(body):
            if body[i] == "\\":
                if swift and body.startswith("\\(", i):
                    i = interpolation(i + 2)
                else:
                    i += 2
            elif body[i] == '"':
                found.append((start, i + 1, body[start + 1:i]))
                return i + 1
            else:
                i += 1
        return i

    i = 0
    while i < len(body):
        i = quoted(i) if body[i] == '"' else i + 1
    return sorted(found)


def literal_template(literal: str) -> str:
    """静态比对只把插值位置归一化；具体占位符类型另由编译器提取核对。"""
    out: list[str] = []
    i = 0
    while i < len(literal):
        if not literal.startswith("\\(", i):
            out.append(literal[i])
            i += 1
            continue
        i += 2
        depth, quoted = 1, False
        while i < len(literal) and depth:
            c = literal[i]
            if c == "\\" and quoted:
                i += 2
                continue
            if c == '"':
                quoted = not quoted
            elif not quoted and c == "(":
                depth += 1
            elif not quoted and c == ")":
                depth -= 1
            i += 1
        out.append("\x00")
    return "".join(out)


def source_only_keys(files: dict[Path, str], catalog_keys: set[str]) -> dict[str, str]:
    """②③：源码里的字面量键（编译器不提取的那些）→ 出处。"""
    found: dict[str, str] = {}
    templates: dict[str, list[str]] = {}
    for key in catalog_keys:
        templates.setdefault(PLACEHOLDER.sub("\x00", key), []).append(key)
    for path, text in files.items():
        is_rust = path.suffix == ".rs"
        if is_rust and (path.name in RUST_DATA_MODULES or "/bin/" in str(path) or RUST_DATA_DIRS & set(path.parts)):
            continue
        if not is_rust and not source_is_ui(path):
            continue   # 测试、夹具和独立 iPhone 原型不共用主程序的文案目录。
        body = text.split("#[cfg(test)]")[0] if is_rust else text
        body = "\n".join(_strip_line_comment(raw) for raw in body.split("\n"))
        explicit = set()
        if not is_rust:
            for call in LOCALIZED_CALL.finditer(body):
                if body[call.end():call.end() + 1] == '"':
                    explicit.add(call.end())
        for start, end, raw in string_literals(body, swift=not is_rust):
            number = body.count("\n", 0, start) + 1
            line_end = body.find("\n", end)
            line = body[body.rfind("\n", 0, start) + 1:line_end if line_end >= 0 else len(body)]
            if ERROR_LINE.search(line):
                continue
            literal = decode_literal(raw)
            if literal in ALLOWED_LITERALS or not (CJK.search(literal) or start in explicit):
                continue
            if not is_rust and "\\(.applicationName)" in literal:
                phrase = literal.replace("\\(.applicationName)", "${applicationName}")
                phrase = re.sub(r'\\\(\\\.\$([A-Za-z_]\w*)\)', lambda m: "${" + m.group(1) + "}", phrase)
                found.setdefault(phrase, f"{path.name}:{number}")
                continue
            if not is_rust and "\\(" in literal:
                matches = templates.get(literal_template(literal), [])
                if matches:
                    for key in matches:
                        found.setdefault(key, f"{path.name}:{number}")
                    continue
            found.setdefault(literal, f"{path.name}:{number}")
    return found


# 窗口场景的标题：`Window("地球", …)` 这类场景标题由系统按系统语言查表，
#    不经过 `LocalizedRoot` 注入的界面语言，目录里有这个键也没用，俄语界面下窗口标题仍是中文。
#    场景标题只许放品牌名（拉丁字母），要本地化的标题在内容里用 `.navigationTitle(L10n.string(…))`。
SCENE_TITLE = re.compile(r'\b(Window|WindowGroup|UtilityWindow|DocumentGroup|CommandMenu)\(\s*"((?:[^"\\]|\\.)*)"')


def scene_title_problems(files: dict[Path, str]) -> list[str]:
    problems: list[str] = []
    for path, text in files.items():
        if path.suffix != ".swift" or "DaysideiOS" in path.parts or any(part.endswith("Tests") for part in path.parts):
            continue
        body = "\n".join(_strip_line_comment(raw) for raw in text.split("\n"))
        for match in SCENE_TITLE.finditer(body):
            if CJK.search(match.group(2)):
                number = body.count("\n", 0, match.start()) + 1
                problems.append(f"场景标题不跟界面语言走：{match.group(1)}({match.group(2)!r}) ← {path.name}:{number}；"
                                "标题只放品牌名，本地化标题用内容里的 .navigationTitle(L10n.string(…))")
    return problems


def missing_key_problems(files: dict[Path, str], catalog_keys: set[str], require_compiler: bool = False,
                         derived_data: Path | None = None, configuration: str = "Debug", arch: str | None = None) -> tuple[list[str], str, set[str]]:
    compiled, problems, scope = compiled_string_keys(files, derived_data, configuration, arch)
    if require_compiler and scope.startswith("仅静态检查"):
        problems.append("缺少当前工作区的编译器提取数据：先 Debug build，使用自定构建目录时设置 DAYSIDE_DERIVED_DATA")
    problems += scene_title_problems(files)
    shortcut_keys = set(load(SHORTCUT_CATALOG)["strings"])
    plain = source_only_keys(files, catalog_keys | shortcut_keys)
    for key, where in sorted(compiled.items()):
        if key not in catalog_keys and key not in ALLOWED_LITERALS:
            problems.append(f"源码里有、目录里没有（编译器提取）：{key!r} ← {where}")
    for key, where in sorted(plain.items()):
        if key not in catalog_keys and key not in shortcut_keys and key not in compiled:
            problems.append(f"源码里有、目录里没有：{key!r} ← {where}")
    summary = f"{scope}；静态字面量 {len(plain)} 键"
    return problems, summary, set(compiled) | set(plain)


def translation_problems(key: str, language: str, localization: dict) -> list[str]:
    """每个单复数、设备变体与替换项都必须有已翻译的 stringUnit。"""
    problems: list[str] = []

    def walk(node: dict, where: str) -> None:
        if not isinstance(node, dict):
            problems.append(f"{key!r} 的 {language}{where} 译文结构无效")
            return
        has_content = False
        if "stringUnit" in node:
            has_content = True
            unit = node["stringUnit"]
            if not isinstance(unit, dict) or unit.get("state") != "translated":
                problems.append(f"{key!r} 的 {language}{where} 尚未标为 translated")
            if not isinstance(unit, dict) or not isinstance(unit.get("value"), str) or (key and not unit.get("value")):
                problems.append(f"{key!r} 的 {language}{where} 缺译文内容")
        for field in ("variations", "substitutions"):
            if field not in node:
                continue
            branches = node[field]
            if not isinstance(branches, dict) or not branches:
                problems.append(f"{key!r} 的 {language}{where}/{field} 缺变体")
                continue
            has_content = True
            if field == "variations":
                for kind, variants in branches.items():
                    if not isinstance(variants, dict) or not variants:
                        problems.append(f"{key!r} 的 {language}{where}/{kind} 缺变体")
                        continue
                    if kind == "plural" and "other" not in variants:
                        problems.append(f"{key!r} 的 {language}{where}/plural 缺 other")
                    for name, variant in variants.items():
                        walk(variant, f"{where}/{kind}/{name}")
            else:
                for name, substitution in branches.items():
                    walk(substitution, f"{where}/{name}")
        if not has_content:
            problems.append(f"{key!r} 缺 {language}{where} 译文")

    walk(localization, "")
    return problems


def style_problems(path: Path, catalog: dict) -> list[str]:
    """规则只在副本上运行，检查不写回目录。"""
    changes: list[dict] = []
    rules = [rule for rule in apple_style.RULES if rule["default"]]
    apple_style.apply_rules(str(path), copy.deepcopy(catalog), rules,
                            any(rule["id"] == "cjk-latin-space" for rule in rules),
                            changes, collections.Counter(), [])
    return [f"Apple 排版规则：{change['key']!r} 的 {change['lang']} "
            f"{change['variation']} 需修正（{', '.join(change['rules'])}）" for change in changes]


def report(check: bool, require_compiler: bool = False, derived_data: Path | None = None,
           configuration: str = "Debug", arch: str | None = None) -> int:
    files = sources()
    if not CATALOG.exists():
        print(f"缺少界面文案目录：{CATALOG}")
        return 1
    catalog = load(CATALOG)
    everything = catalog["strings"]
    referenced = referenced_keys(list(everything), files)
    missing, summary, used = missing_key_problems(files, set(everything), require_compiler,
                                                 derived_data, configuration, arch)
    referenced.update(used)
    problems: list[str] = []
    for key, entry in everything.items():
        if key not in referenced:
            problems.append(f"没有任何源文件引用：{key!r}")
        for lang in LANGUAGES:
            problems.extend(translation_problems(key, lang, entry.get("localizations", {}).get(lang, {})))
    problems.extend(style_problems(CATALOG, catalog))
    shortcuts = load(SHORTCUT_CATALOG)["strings"]
    system_keys = 0
    for path in [SHORTCUT_CATALOG, *SYSTEM_CATALOGS]:
        if not path.exists():
            problems.append(f"缺少系统文案目录：{path.name}")
            continue
        data = load(path)
        strings = data["strings"]
        if path != SHORTCUT_CATALOG:
            system_keys += len(strings)
        for key, entry in strings.items():
            for lang in LANGUAGES:
                problems.extend(f"{path.name}: {problem}" for problem in
                                translation_problems(key, lang, entry.get("localizations", {}).get(lang, {})))
        problems.extend(style_problems(path, data))
    problems.extend(missing)
    print(f"文案目录 {len(everything)} 键，{len(LANGUAGES)} 种语言；快捷指令 {len(shortcuts)} 键；系统文案 {system_keys} 键；{summary}")
    for line in problems:
        print("  " + line)
    return 1 if check and problems else 0


def main() -> int:
    parser = argparse.ArgumentParser(description="检查十六语文案、源码键与 Apple 排版规则")
    actions = parser.add_mutually_exclusive_group()
    actions.add_argument("--report", action="store_true", help="显示文案完整性与检查范围")
    actions.add_argument("--check", action="store_true", help="发现文案问题或过期提取时失败")
    parser.add_argument("--require-compiler-data", action="store_true", help="要求当前工作区的编译提取")
    parser.add_argument("--derived-data", type=Path, help="明确选择 xcodebuild 的 DerivedData 目录")
    parser.add_argument("--configuration", default="Debug", choices=("Debug", "Release"))
    parser.add_argument("--arch", choices=("arm64", "x86_64"), help="只检查指定架构的编译提取")
    args = parser.parse_args()
    if args.require_compiler_data and not args.check:
        parser.error("--require-compiler-data 需要配合 --check")
    return report(args.check, args.require_compiler_data, args.derived_data, args.configuration, args.arch)


if __name__ == "__main__":
    sys.exit(main())
