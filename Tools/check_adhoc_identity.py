#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Validate an explicitly requested ad-hoc distribution without changing the formal gate."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import subprocess

import check_release_identity


def inspect_bundle(app: Path, asset_name: str) -> dict:
    formal = check_release_identity.inspect_bundle(app, asset_name)
    signature = subprocess.run(
        ["/usr/bin/codesign", "-d", "--verbose=4", str(app)],
        capture_output=True, check=False, timeout=30,
    )
    adhoc = signature.returncode == 0 and re.search(
        rb"^Signature=adhoc$", signature.stderr, re.MULTILINE,
    ) is not None
    structural = formal["errors"] == ["release_signing_identity"]
    return {
        "ok": structural and adhoc,
        "distribution": "ad-hoc, not notarized",
        "structuralIdentityPassed": structural,
        "adHocSignatureConfirmed": adhoc,
        "formalReleaseIdentityGate": formal,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--asset-name", required=True)
    args = parser.parse_args()
    record = inspect_bundle(args.app, args.asset_name)
    print(json.dumps(record, ensure_ascii=False))
    return 0 if record["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
