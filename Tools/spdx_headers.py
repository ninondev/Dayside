#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""SPDX license headers for source files.

The whole project is licensed under GPL-3.0-only (full text in `COPYING`). Every `.swift`, `.rs`,
`.py`, `.sh` and `.mjs` file starts with `SPDX-License-Identifier: GPL-3.0-only` on its first line
(second line when the file has a shebang), as recommended in the "How to Apply" section of the GPL.

Usage:
  python3 Tools/spdx_headers.py            # report files with a missing or different header
  python3 Tools/spdx_headers.py --check    # same, exit non-zero if any file needs a fix (used by verify_all)
  python3 Tools/spdx_headers.py --apply    # add missing headers and replace different ones
"""
from __future__ import annotations

import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
LICENSE_ID = "GPL-3.0-only"
TAG = "SPDX-License-Identifier:"
# Only a header line counts (`// SPDX-...` or `# SPDX-...`), not a mention inside prose.
HEADER_LINE = re.compile(r"^(?://|#)\s*SPDX-License-Identifier:\s*(\S+)\s*$")
SKIP_DIRS = {".git", "backup", "DerivedData", "build", "rust-target", "target", "node_modules", "Generated"}
COMMENT = {".swift": "//", ".rs": "//", ".mjs": "//", ".py": "#", ".sh": "#"}


def sources():
    for path in sorted(ROOT.rglob("*")):
        if path.is_dir() or path.suffix not in COMMENT:
            continue
        if any(part in SKIP_DIRS for part in path.relative_to(ROOT).parts):
            continue
        yield path


def current_id(text: str) -> str | None:
    # The header must be on the first line, or the second one after a shebang.
    lines = text.split("\n", 3)
    at = 1 if lines and lines[0].startswith("#!") else 0
    if len(lines) > at and (match := HEADER_LINE.match(lines[at])):
        return match.group(1)
    return None


def with_header(text: str, comment: str) -> str:
    lines = [line for line in text.split("\n") if not HEADER_LINE.match(line)]
    insert = 1 if lines and lines[0].startswith("#!") else 0
    lines.insert(insert, f"{comment} {TAG} {LICENSE_ID}")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--apply", action="store_true", help="add missing headers and replace different ones")
    parser.add_argument("--check", action="store_true", help="exit non-zero if any file needs a fix")
    args = parser.parse_args()

    good = 0
    missing: list[pathlib.Path] = []
    wrong: list[tuple[pathlib.Path, str]] = []
    for path in sources():
        found = current_id(path.read_text(encoding="utf-8"))
        if found == LICENSE_ID:
            good += 1
        elif found is None:
            missing.append(path)
        else:
            wrong.append((path, found))

    if args.apply:
        for path in missing + [p for p, _ in wrong]:
            text = path.read_text(encoding="utf-8")
            path.write_text(with_header(text, COMMENT[path.suffix]), encoding="utf-8")
        print(f"Added {len(missing)} headers, replaced {len(wrong)}.")
        return 0

    print(f"{LICENSE_ID}: {good} files carry the header; missing {len(missing)}, different {len(wrong)}.")
    for path in missing[:20]:
        print(f"  missing: {path.relative_to(ROOT).as_posix()}")
    for path, found in wrong[:20]:
        print(f"  different ({found}): {path.relative_to(ROOT).as_posix()}")
    if args.check:
        ok = not (missing or wrong)
        print("SPDX header check passed" if ok else "SPDX header check failed")
        return 0 if ok else 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
