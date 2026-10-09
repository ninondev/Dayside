#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Require one selected Swift test to have executed and passed in an xcresult."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def execution_errors(summary, tree, test_id):
    errors = []
    counts = {"totalTestCount": 1, "passedTests": 1, "failedTests": 0, "skippedTests": 0}
    for key, expected in counts.items():
        if summary.get(key) != expected:
            errors.append(f"{key}: expected {expected}, found {summary.get(key)}")
    nodes = []
    def walk(value):
        if isinstance(value, dict):
            if value.get("nodeType") == "Test Case":
                nodes.append(value)
            for child in value.values():
                walk(child)
        elif isinstance(value, list):
            for child in value:
                walk(child)
    walk(tree)
    matches = [n for n in nodes if n.get("nodeIdentifierURL", "").endswith("/" + test_id)]
    if len(nodes) != 1 or len(matches) != 1:
        errors.append("result must contain exactly the requested test case")
    elif matches[0].get("result") != "Passed" or matches[0].get("durationInSeconds", 0) <= 0:
        errors.append("requested test did not execute and pass")
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--result-bundle", required=True)
    parser.add_argument("--test-id", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=False)
    results = {}
    receipt = {"testIdentifier": args.test_id, "passed": False, "errors": [], "rawSha256": {}}
    for kind in ("summary", "tests"):
        command = ["xcrun", "xcresulttool", "get", "test-results", kind,
                   "--path", args.result_bundle, "--compact"]
        result = subprocess.run(command, capture_output=True, timeout=60)
        (out / f"{kind}.json").write_bytes(result.stdout)
        (out / f"{kind}.stderr").write_bytes(result.stderr)
        receipt["rawSha256"][kind] = hashlib.sha256(result.stdout).hexdigest()
        if result.returncode != 0:
            receipt["errors"].append(f"xcresulttool {kind} exit {result.returncode}")
            break
        try:
            results[kind] = json.loads(result.stdout)
        except (ValueError, UnicodeDecodeError) as exc:
            receipt["errors"].append(str(exc))
            break
    if not receipt["errors"]:
        receipt["errors"] = execution_errors(results["summary"], results["tests"], args.test_id)
        receipt["counts"] = {key: results["summary"].get(key) for key in
                             ("totalTestCount", "passedTests", "failedTests", "skippedTests")}
    receipt["passed"] = not receipt["errors"]
    (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt))
    return 0 if receipt["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
