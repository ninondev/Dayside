#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Copy recent macOS crash reports for test-run processes into a folder.

Sources are never moved or deleted. A manifest.json describing the copies is
written next to them so the evidence can be matched to a test run later.
"""
import argparse
import hashlib
import json
import os
import shutil
import sys
import time
from pathlib import Path
from typing import Optional

DEFAULT_REPORTS_DIRS = [
    "~/Library/Logs/DiagnosticReports",
    "~/Library/Logs/DiagnosticReports/Retired",
]
DEFAULT_PROCESSES = ["Dayside", "xctest", "DaysideTests", "xcodebuild"]
SUFFIXES = (".ips", ".crash")
HEADER_LIMIT = 64 * 1024
HEADER_PROCESS_KEYS = ("app_name", "name", "procName")


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _read_header(path: Path, *, strict: bool = False) -> Optional[dict]:
    """Return the first line of an .ips file parsed as a JSON object, else None."""
    try:
        with path.open("rb") as fh:
            head = fh.read(HEADER_LIMIT)
    except OSError:
        if strict:
            raise
        return None
    first_line = head.split(b"\n", 1)[0]
    try:
        obj = json.loads(first_line.decode("utf-8"))
    except ValueError:  # includes UnicodeDecodeError and JSONDecodeError
        if strict:
            raise
        return None
    if strict and not isinstance(obj, dict):
        raise ValueError("crash report header is not a JSON object")
    return obj if isinstance(obj, dict) else None


def _matching_process(filename: str, header: Optional[dict], processes) -> Optional[str]:
    for name in processes:
        if filename.startswith((f"{name}-", f"{name}_")) or filename == f"{name}.ips":
            return name
    if header is not None:
        for name in processes:
            if any(header.get(key) == name for key in HEADER_PROCESS_KEYS):
                return name
    return None


def collect(since: float, out, reports_dirs, processes, *, strict: bool = False) -> list:
    """Copy matching reports newer than `since` into `out` and write manifest.json.

    Returns the manifest's "reports" list, sorted by source path.
    """
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    reports = []
    seen = set()
    scans = []
    issues = []
    for index, directory in enumerate(reports_dirs):
        directory = Path(directory)
        scan = {"directory": os.path.abspath(directory), "required": index == 0, "status": "pending"}
        scans.append(scan)
        if not directory.is_dir():
            scan["status"] = "missing"
            if strict and index == 0:
                issues.append(f"required report directory is unavailable: {directory}")
            continue
        try:
            candidates = sorted(directory.iterdir())
        except OSError as exc:
            print(f"warning: cannot read {directory}: {exc}", file=sys.stderr)
            scan["status"] = "unreadable"
            issues.append(str(exc))
            continue
        scan["status"] = "scanned"
        scan["entries"] = len(candidates)
        for path in candidates:
            if path.suffix not in SUFFIXES or not path.is_file():
                continue
            try:
                mtime = path.stat().st_mtime
            except OSError as exc:
                issues.append(str(exc))
                continue
            if mtime < since:
                continue
            key = path.resolve()
            if key in seen:
                continue
            try:
                header = _read_header(path, strict=strict) if path.suffix == ".ips" else None
            except (OSError, ValueError) as exc:
                issues.append(f"cannot identify crash report {path}: {exc}")
                continue
            process = _matching_process(path.name, header, processes)
            if process is None:
                continue
            seen.add(key)

            dest_name = path.name
            if (out / dest_name).exists():
                dest_name = f"{index}-{path.name}"
                counter = 2
                while (out / dest_name).exists():
                    dest_name = f"{index}-{counter}-{path.name}"
                    counter += 1
            dest = out / dest_name
            try:
                shutil.copy2(path, dest)
            except OSError as exc:
                if not strict:
                    raise
                issues.append(str(exc))
                continue

            bug_type = header.get("bug_type") if header is not None else None
            reports.append({
                "source": os.path.abspath(path),
                "file": dest_name,
                "bytes": dest.stat().st_size,
                "sha256": _sha256(dest),
                "bug_type": None if bug_type is None else str(bug_type),
                "process": process,
            })

    reports.sort(key=lambda report: report["source"])
    manifest = {"since": float(since), "reports": reports}
    if strict:
        manifest["scan"] = {"completedAt": time.time(), "directories": scans,
                            "complete": not issues, "issues": issues}
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return reports


def _process_name(value: str) -> str:
    if not value:
        raise argparse.ArgumentTypeError("process name must not be empty")
    return value


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Copy recent macOS crash reports for test-run processes.")
    parser.add_argument("--since", type=float, required=True,
                        help="only reports whose mtime is >= this epoch time (seconds)")
    parser.add_argument("--out", required=True, help="destination directory (created if missing)")
    parser.add_argument("--strict", action="store_true",
                        help="require a readable primary report directory and record scan completeness")
    parser.add_argument("--fail-on-reports", action="store_true",
                        help="return a failure if any matching crash report is found")
    parser.add_argument("--reports-dir", action="append", dest="reports_dirs", metavar="DIR",
                        help="directory to scan (repeatable); default: the DiagnosticReports folders")
    parser.add_argument("--process", action="append", dest="processes", metavar="NAME", type=_process_name,
                        help="process name to match (repeatable); default: %s" % ", ".join(DEFAULT_PROCESSES))
    args = parser.parse_args(argv)
    if args.strict and (Path(args.out).expanduser() / "manifest.json").exists():
        parser.error("refusing to overwrite an existing crash-evidence manifest")

    reports_dirs = args.reports_dirs or DEFAULT_REPORTS_DIRS
    processes = args.processes or DEFAULT_PROCESSES
    reports = collect(
        args.since,
        Path(args.out).expanduser(),
        [Path(d).expanduser() for d in reports_dirs],
        processes,
        strict=args.strict,
    )
    print(f"CRASH_REPORTS {len(reports)} {args.out}")
    if args.strict:
        manifest = json.loads((Path(args.out).expanduser() / "manifest.json").read_text())
        if not manifest["scan"]["complete"]:
            print("Crash report scan incomplete; see manifest.json", file=sys.stderr)
            return 1
    if args.fail_on_reports and reports:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
