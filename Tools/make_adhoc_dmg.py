#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Package a canonical Dayside bundle for the owner's ad-hoc release."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import uuid

import check_adhoc_identity


def run(*args: str) -> None:
    subprocess.run(args, check=True)


def digests(root: Path) -> dict[str, str]:
    result = {}
    for directory, _, files in os.walk(root):
        for name in files:
            path = Path(directory) / name
            result[str(path.relative_to(root))] = (
                "symlink:" + os.readlink(path) if path.is_symlink()
                else hashlib.sha256(path.read_bytes()).hexdigest()
            )
    return result


def package(app: Path, output: Path, readme: Path) -> dict:
    root = Path(__file__).resolve().parents[1]
    if output.exists() or app.name != "Dayside.app" or not readme.is_file():
        raise ValueError("Require Dayside.app, a ReadMe file, and a new output path")
    identity = check_adhoc_identity.inspect_bundle(app, output.name)
    if not identity["ok"]:
        raise ValueError(json.dumps(identity))
    output.parent.mkdir(parents=True, exist_ok=True)
    stage = output.parent / (output.stem + ".stage-" + uuid.uuid4().hex[:8])
    mount = output.parent / (output.stem + ".mount-" + uuid.uuid4().hex[:8])
    stage.mkdir()
    mount.mkdir()
    run("/usr/bin/ditto", str(app), str(stage / app.name))
    for name in ("LICENSE", "COPYING", "THIRD_PARTY_NOTICES.md"):
        shutil.copy2(root / name, stage / name)
    shutil.copy2(app / "Contents/Resources/ThirdPartyNotices.txt", stage / "ThirdPartyNotices.txt")
    shutil.copy2(readme, stage / "ReadMe.txt")
    (stage / "Applications").symlink_to("/Applications")
    run("/usr/bin/hdiutil", "create", "-volname", "Dayside", "-srcfolder", str(stage),
        "-fs", "APFS", "-format", "ULMO", str(output))
    run("/usr/bin/hdiutil", "verify", str(output))
    mounted = False
    try:
        run("/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", str(mount), str(output))
        mounted = True
        mounted_app = mount / app.name
        run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(mounted_app))
        source_files, mounted_files = digests(app), digests(mounted_app)
        if source_files != mounted_files or not (mount / "Applications").is_symlink():
            raise ValueError("Mounted application differs from the source or lacks Applications link")
        mounted_identity = check_adhoc_identity.inspect_bundle(mounted_app, output.name)
        if not mounted_identity["ok"]:
            raise ValueError(json.dumps(mounted_identity))
        sha = hashlib.sha256(output.read_bytes()).hexdigest()
        record = {
            "path": str(output.resolve()), "bytes": output.stat().st_size, "sha256": sha,
            "format": "ULMO (LZMA), APFS", "distribution": "ad-hoc, not notarized",
            "mountedFilesCompared": len(source_files), "mountedFilesEqualSourceBundle": True,
            "strictSignature": True, "applicationsLink": True,
            "identity": identity, "mountedIdentity": mounted_identity,
            "retainedStagePath": str(stage),
        }
        output.with_name(output.name + ".validation.json").write_text(json.dumps(record, indent=2) + "\n")
        output.with_name(output.name + ".sha256").write_text(f"{sha}  {output.name}\n")
        return record
    finally:
        if mounted:
            run("/usr/bin/hdiutil", "detach", str(mount))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("readme", type=Path)
    args = parser.parse_args()
    print(json.dumps(package(args.app.resolve(), args.output.resolve(), args.readme.resolve())))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
