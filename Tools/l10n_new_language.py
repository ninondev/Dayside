#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""给界面加一种语言的翻译单：导出要翻的串、导回译文并逐条核对。

为什么是 Python：
它只在加语言时跑几次、不常驻；要与 `l10n_check.py`、`l10n_apple_style.py` 同一种写法读写目录（两空格缩进、键按原序、
非 ASCII 原样），换成 Rust 得给 serde_json 开 preserve_order，会改掉 RustCore 里所有 JSON 的键序。

四份目录：界面 `Dayside/Resources/Localizable.xcstrings`，
以及 `InfoPlist` / `AppShortcuts` / `ServicesMenu` 三份系统文案目录。

用法：
  Tools/l10n_new_language.py export <语言> <翻译单.json>   列出这种语言还缺的串（源语中文、英文、占位符、要的复数类别）
  Tools/l10n_new_language.py import <语言> <翻译单.json>   核对后写回目录（state = translated）；有一条不过就一条都不写
  Tools/l10n_new_language.py validate <语言> <翻译单.json> 只核对、不写（翻译的人自查用）
  Tools/l10n_new_language.py check <语言>                  各目录还缺几串

翻译单是一个数组，每项：{"catalog", "key", "zh", "en", "placeholders", "plural"（要复数时是类别列表，否则 null）,
"translation"（导回时填：普通串是字符串，要复数时是 {类别: 字符串}）}。

复数类别与现有十语同一口径：西法葡德只用 one / other，中日韩不分复数（写一个串）；新语言意、荷 one / other，
波兰语 one / few / many / other，土耳其、越南、印尼不分复数。
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOGS = {
    "interface": ROOT / "Dayside/Resources/Localizable.xcstrings",
    "infoplist": ROOT / "Dayside/Resources/InfoPlist.xcstrings",
    "shortcuts": ROOT / "Dayside/Resources/AppShortcuts.xcstrings",
    "services": ROOT / "Dayside/Resources/ServicesMenu.xcstrings",
}
PLURAL = {"it": ["one", "other"], "nl": ["one", "other"], "pl": ["one", "few", "many", "other"],
          "tr": None, "vi": None, "id": None}
# 占位符：%@、%lld、%d、%1$@、%2$lld、%.1f 这类（精度也算进种类，印尼语译者查出此前认不出 %.1f）；%% 是字面的百分号。
PLACEHOLDER = re.compile(r"%(?:\d+\$)?(?:@|(?:\.\d+)?l{0,2}[dfsu])|%%")


def load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def dump(path: Path, catalog: dict) -> None:
    # 顶层键按文件原来的顺序、结尾换行按原样写回（`AppShortcuts.xcstrings` 的 version 在 strings 前面、末尾没有换行），
    # 只让新语言成为差异。
    newline = "\n" if not path.exists() or path.read_bytes().endswith(b"\n") else ""
    path.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + newline, encoding="utf-8")


def placeholders(text: str) -> list[str]:
    """占位符的多重集（排好序，位置标记去掉后比较：译文可以换序，但种类与个数得一样）。"""
    found = [re.sub(r"\d+\$", "", p) for p in PLACEHOLDER.findall(text) if p != "%%"]
    return sorted(found)


def english(entry: dict) -> tuple[str | None, dict | None]:
    en = entry.get("localizations", {}).get("en", {})
    if "variations" in en:
        plural = en["variations"].get("plural", {})
        return plural.get("other", {}).get("stringUnit", {}).get("value"), {k: v["stringUnit"]["value"] for k, v in plural.items()}
    return en.get("stringUnit", {}).get("value"), None


def export(language: str, out: Path) -> None:
    jobs = []
    for name, path in CATALOGS.items():
        catalog = load(path)
        for key, entry in catalog["strings"].items():
            if entry.get("shouldTranslate") is False or language in entry.get("localizations", {}):
                continue
            en_text, en_plural = english(entry)
            needs_plural = en_plural is not None and PLURAL.get(language) is not None
            jobs.append({"catalog": name, "key": key, "zh": key, "en": en_text, "en_plural": en_plural,
                         "placeholders": placeholders(en_text or key), "plural": PLURAL[language] if needs_plural else None,
                         "translation": None})
    out.write_text(json.dumps(jobs, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"{language}：导出 {len(jobs)} 串 → {out}")


def validate(language: str, job: dict) -> str | None:
    t = job.get("translation")
    # 按英文（没有就按中文键）现算，不信翻译单里导出时存的那份（导出那天的规则可能认漏，见 PLACEHOLDER）。
    want = placeholders(job["en"] or job["key"])
    if job["plural"]:
        if not isinstance(t, dict) or sorted(t) != sorted(job["plural"]):
            return f"复数类别应为 {job['plural']}，实际 {sorted(t) if isinstance(t, dict) else type(t).__name__}"
        for category, text in t.items():
            if not isinstance(text, str) or not text.strip():
                return f"复数 {category} 为空"
            if placeholders(text) != want:
                return f"复数 {category} 的占位符 {placeholders(text)} ≠ {want}"
        return None
    if not isinstance(t, str) or (not t.strip() and job["en"]):
        return "译文为空"
    if placeholders(t) != want:
        return f"占位符 {placeholders(t)} ≠ {want}"
    return None


def problems_in(language: str, jobs: list) -> list:
    return [(j["catalog"], j["key"], p) for j in jobs if (p := validate(language, j))]


def validate_only(language: str, source: Path) -> None:
    jobs = json.loads(source.read_text(encoding="utf-8"))
    problems = problems_in(language, jobs)
    for catalog, key, problem in problems[:80]:
        print(f"✗ [{catalog}] {key!r}：{problem}")
    print(f"{language}：{len(jobs)} 串，{len(problems)} 串不过")
    sys.exit(1 if problems else 0)


def import_(language: str, source: Path) -> None:
    jobs = json.loads(source.read_text(encoding="utf-8"))
    problems = problems_in(language, jobs)
    if problems:
        for catalog, key, problem in problems[:40]:
            print(f"✗ [{catalog}] {key!r}：{problem}")
        sys.exit(f"{len(problems)} 串不过，一串都没写")
    loaded = {name: load(path) for name, path in CATALOGS.items()}
    written = 0
    for job in jobs:
        entry = loaded[job["catalog"]]["strings"].get(job["key"])
        if entry is None:
            continue   # 导出之后键被删了
        localizations = entry.setdefault("localizations", {})
        if job["plural"]:
            localizations[language] = {"variations": {"plural": {
                c: {"stringUnit": {"state": "translated", "value": job["translation"][c]}} for c in job["plural"]}}}
        else:
            localizations[language] = {"stringUnit": {"state": "translated", "value": job["translation"]}}
        written += 1
    for name, path in CATALOGS.items():
        dump(path, loaded[name])
    print(f"{language}：写回 {written} 串")


def check(language: str) -> None:
    total = 0
    for name, path in CATALOGS.items():
        catalog = load(path)
        missing = [k for k, e in catalog["strings"].items() if e.get("shouldTranslate") is not False and language not in e.get("localizations", {})]
        total += len(missing)
        print(f"{name:10s} 缺 {len(missing)} / {len(catalog['strings'])}")
    sys.exit(1 if total else 0)


if __name__ == "__main__":
    if len(sys.argv) < 3 or sys.argv[2] not in PLURAL:
        sys.exit(__doc__)
    command, language = sys.argv[1], sys.argv[2]
    if command == "export" and len(sys.argv) == 4:
        export(language, Path(sys.argv[3]))
    elif command == "import" and len(sys.argv) == 4:
        import_(language, Path(sys.argv[3]))
    elif command == "validate" and len(sys.argv) == 4:
        validate_only(language, Path(sys.argv[3]))
    elif command == "check":
        check(language)
    else:
        sys.exit(__doc__)
