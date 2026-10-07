#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""往手写的 Xcode 工程里登记一个 Swift 源文件（或改一个已登记文件的路径）。

    Tools/register_source.py TahoeTime/Models/Foo.swift            # 主程序 target
    Tools/register_source.py TahoeTimeTests/FooTests.swift --test  # 单元测试 target
    Tools/register_source.py TahoeTime/Models/Foo.swift --ios      # 主程序 + iPhone 原型
    Tools/register_source.py --move 旧路径 新路径                    # 文件挪了目录，只改 path

文件引用一律 `sourceTree = SOURCE_ROOT` + 仓根相对路径（与 register_features.py 加的那批同一写法），
id 由路径哈希得出，重跑幂等。
"""
import hashlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "TahoeTime.xcodeproj/project.pbxproj"
APP_SOURCES = "AA000000000000000000000C"
TEST_SOURCES = "CC0000000000000000000023"
IOS_SOURCES = "I0500000000000000000005"
FEATURE_GROUP_NAME = "Feature files"


def uid(value: str) -> str:
    return hashlib.sha256(("dayside-source:" + value).encode()).hexdigest()[:24].upper()


def main() -> int:
    text = PROJECT.read_text()
    args = sys.argv[1:]
    if args[:1] == ["--move"]:
        old, new = args[1], args[2]
        pattern = re.compile(r'path = "?' + re.escape(old) + r'"?;')
        if not pattern.search(text):
            print(f"工程里没有 {old}", file=sys.stderr)
            return 1
        text = pattern.sub(f'path = "{new}";', text)
        PROJECT.write_text(text)
        print(f"{old} → {new}")
        return 0
    path = args[0]
    if not (ROOT / path).exists():
        print(f"没有这个文件：{path}", file=sys.stderr)
        return 1
    name = Path(path).name
    if re.search(r'path = (?:"' + re.escape(name) + r'"|' + re.escape(name) + r'|"' + re.escape(path) + r'");', text):
        file_ref = None
        match = re.search(r'\n\t\t([0-9A-Z]{22,24}) (?:/\*[^\n]*\*/ )?= \{isa = PBXFileReference;[^\n]*path = (?:"' + re.escape(path) + r'"|"?' + re.escape(name) + r'"?);', text)
        if match:
            file_ref = match.group(1)
        if file_ref is None:
            print(f"{path} 已有同名引用但找不到 id", file=sys.stderr)
            return 1
    else:
        file_ref = uid("file:" + path)
        node = f'\t\t{file_ref} /* {name} */ = {{isa = PBXFileReference; path = "{path}"; sourceTree = SOURCE_ROOT; lastKnownFileType = sourcecode.swift;}};\n'
        text = text.replace("/* End PBXFileReference section */", node + "/* End PBXFileReference section */", 1)
        # 挂进「Feature files」组，导航器里看得见。
        group = re.search(r'\n\t\t([0-9A-Z]{22,24}) = \{isa = PBXGroup; name = "' + FEATURE_GROUP_NAME + r'"; children = \(', text)
        if group:
            text = text[: group.end()] + f"\n\t\t\t\t{file_ref},\n\t\t\t" + text[group.end():]
    phases = [TEST_SOURCES] if "--test" in args else [APP_SOURCES] + ([IOS_SOURCES] if "--ios" in args else [])
    for phase in phases:
        build = uid("build:" + phase + ":" + path)
        if build in text:
            continue
        node = f"\t\t{build} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_ref};}};\n"
        text = text.replace("/* End PBXBuildFile section */", node + "/* End PBXBuildFile section */", 1)
        pattern = re.compile(r"(\n\t\t" + phase + r" (?:/\*[^\n]*\*/ )?= \{[^\n]*\n(?:[^\n]*\n)*?\t\t\tfiles = \(\n)")
        match = pattern.search(text)
        if not match:
            print(f"找不到 Sources 阶段 {phase}", file=sys.stderr)
            return 1
        text = text[: match.end()] + f"\t\t\t\t{build} /* {name} in Sources */,\n" + text[match.end():]
    PROJECT.write_text(text)
    print(f"登记 {path} → {'测试' if '--test' in args else '主程序'}{' + iOS' if '--ios' in args else ''}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
