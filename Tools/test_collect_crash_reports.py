#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
from contextlib import redirect_stdout
import hashlib
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import collect_crash_reports

SINCE = 1_700_000_000.0


def write_file(path, data=b"crash body", mtime=SINCE + 100):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    os.utime(path, (mtime, mtime))
    return path


def ips_bytes(header):
    return json.dumps(header).encode() + b"\n" + b'{"usedBytes": 1}\n'


class CollectCrashReportsTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.reports = self.root / "DiagnosticReports"
        self.out = self.root / "out"

    def manifest(self):
        return json.loads((self.out / "manifest.json").read_text(encoding="utf-8"))

    def collect(self, dirs=None, processes=None):
        return collect_crash_reports.collect(
            SINCE, self.out, dirs or [self.reports],
            processes or collect_crash_reports.DEFAULT_PROCESSES,
        )

    def test_header_matched_ips_is_copied_with_bug_type_and_sha256(self):
        data = ips_bytes({"app_name": "Dayside", "bug_type": "309"})
        write_file(self.reports / "random-name.ips", data)

        reports = self.collect()

        self.assertEqual(len(reports), 1)
        entry = reports[0]
        self.assertEqual(entry["file"], "random-name.ips")
        self.assertEqual(entry["process"], "Dayside")
        self.assertEqual(entry["bug_type"], "309")
        self.assertEqual(entry["bytes"], len(data))
        self.assertEqual(entry["sha256"], hashlib.sha256(data).hexdigest())
        self.assertEqual((self.out / "random-name.ips").read_bytes(), data)
        self.assertEqual(self.manifest(), {"since": SINCE, "reports": reports})

    def test_header_keys_name_and_procname_also_match(self):
        write_file(self.reports / "a.ips", ips_bytes({"name": "xctest"}))
        write_file(self.reports / "b.ips", ips_bytes({"procName": "DaysideTests"}))

        reports = self.collect()

        self.assertEqual({r["file"]: r["process"] for r in reports},
                         {"a.ips": "xctest", "b.ips": "DaysideTests"})
        self.assertIsNone(reports[0]["bug_type"])

    def test_older_file_is_skipped_and_exact_since_is_kept(self):
        write_file(self.reports / "Dayside-old.ips", ips_bytes({"app_name": "Dayside"}), mtime=SINCE - 1)
        write_file(self.reports / "Dayside-edge.ips", ips_bytes({"app_name": "Dayside"}), mtime=SINCE)

        reports = self.collect()

        self.assertEqual([r["file"] for r in reports], ["Dayside-edge.ips"])
        self.assertFalse((self.out / "Dayside-old.ips").exists())

    def test_unrelated_process_and_wrong_suffix_are_skipped(self):
        write_file(self.reports / "Safari-1.ips", ips_bytes({"app_name": "Safari"}))
        write_file(self.reports / "Other-2.ips", ips_bytes({"app_name": "Other"}))
        write_file(self.reports / "Dayside-report.txt", b"not a report")
        write_file(self.reports / "Dayside-report.ips.bak", b"not a report")
        write_file(self.reports / "garbage.ips", b"\x00\xff not json\n")

        reports = self.collect()

        self.assertEqual(reports, [])
        self.assertEqual(self.manifest()["reports"], [])
        self.assertEqual(sorted(p.name for p in self.out.iterdir()), ["manifest.json"])

    def test_filename_prefix_matches_crash_files(self):
        write_file(self.reports / "xctest_2026-10-01-120000.crash")
        write_file(self.reports / "DaysideTests-2026-10-01.crash")
        write_file(self.reports / "Dayside.crash")  # exact name only counts for .ips

        reports = self.collect()

        self.assertEqual(
            {r["file"]: (r["process"], r["bug_type"]) for r in reports},
            {"xctest_2026-10-01-120000.crash": ("xctest", None),
             "DaysideTests-2026-10-01.crash": ("DaysideTests", None)},
        )

    def test_missing_reports_dir_gives_empty_manifest_and_exit_zero(self):
        missing = self.root / "does-not-exist"
        buffer = io.StringIO()

        with redirect_stdout(buffer):
            code = collect_crash_reports.main([
                "--since", str(SINCE), "--out", str(self.out), "--reports-dir", str(missing),
            ])

        self.assertEqual(code, 0)
        self.assertEqual(buffer.getvalue(), f"CRASH_REPORTS 0 {self.out}\n")
        self.assertEqual(self.manifest(), {"since": SINCE, "reports": []})

    def test_name_collision_between_reports_dirs_gets_index_prefix(self):
        first, second = self.root / "A", self.root / "B"
        write_file(first / "Dayside-1.ips", ips_bytes({"app_name": "Dayside", "run": "first"}))
        write_file(second / "Dayside-1.ips", ips_bytes({"app_name": "Dayside", "run": "second"}))

        reports = self.collect(dirs=[first, second])

        by_source = {r["source"]: r for r in reports}
        first_entry = by_source[os.path.abspath(first / "Dayside-1.ips")]
        second_entry = by_source[os.path.abspath(second / "Dayside-1.ips")]
        self.assertEqual(first_entry["file"], "Dayside-1.ips")
        self.assertEqual(second_entry["file"], "1-Dayside-1.ips")
        self.assertIn(b'"first"', (self.out / "Dayside-1.ips").read_bytes())
        self.assertIn(b'"second"', (self.out / "1-Dayside-1.ips").read_bytes())

    def test_rerun_keeps_earlier_copies_instead_of_overwriting(self):
        write_file(self.reports / "Dayside-1.ips", ips_bytes({"app_name": "Dayside", "run": "new"}))
        self.out.mkdir()
        (self.out / "Dayside-1.ips").write_bytes(b"from an earlier run")

        reports = self.collect()

        self.assertEqual([r["file"] for r in reports], ["0-Dayside-1.ips"])
        self.assertEqual((self.out / "Dayside-1.ips").read_bytes(), b"from an earlier run")

    def test_source_files_still_exist_after_collection(self):
        source = write_file(self.reports / "Dayside-keep.ips", ips_bytes({"app_name": "Dayside"}))
        before = source.read_bytes()

        self.collect()

        self.assertTrue(source.exists())
        self.assertEqual(source.read_bytes(), before)

    def test_strict_missing_primary_directory_fails_with_incomplete_receipt(self):
        code = collect_crash_reports.main([
            "--strict", "--since", str(SINCE), "--out", str(self.out),
            "--reports-dir", str(self.reports),
        ])
        self.assertEqual(code, 1)
        self.assertFalse(self.manifest()["scan"]["complete"])
        self.assertEqual(self.manifest()["reports"], [])

    def test_strict_missing_optional_retired_directory_is_recorded(self):
        self.reports.mkdir()
        code = collect_crash_reports.main([
            "--strict", "--since", str(SINCE), "--out", str(self.out),
            "--reports-dir", str(self.reports),
            "--reports-dir", str(self.reports / "Retired"),
        ])
        self.assertEqual(code, 0)
        self.assertTrue(self.manifest()["scan"]["complete"])
        self.assertEqual([d["status"] for d in self.manifest()["scan"]["directories"]],
                         ["scanned", "missing"])

    def test_strict_unreadable_directory_cannot_pass_as_zero_crashes(self):
        self.reports.mkdir()
        with patch.object(Path, "iterdir", side_effect=PermissionError("denied")):
            code = collect_crash_reports.main([
                "--strict", "--since", str(SINCE), "--out", str(self.out),
                "--reports-dir", str(self.reports),
            ])
        self.assertEqual(code, 1)
        self.assertFalse(self.manifest()["scan"]["complete"])
        self.assertEqual(self.manifest()["scan"]["directories"][0]["status"], "unreadable")

    def test_fail_on_reports_preserves_crash_and_returns_failure(self):
        source = write_file(self.reports / "Dayside-keep.ips", ips_bytes({"app_name": "Dayside"}))
        code = collect_crash_reports.main([
            "--strict", "--fail-on-reports", "--since", str(SINCE), "--out", str(self.out),
            "--reports-dir", str(self.reports),
        ])
        self.assertEqual(code, 1)
        self.assertTrue(self.manifest()["scan"]["complete"])
        self.assertEqual((self.out / "Dayside-keep.ips").read_bytes(), source.read_bytes())

    def test_strict_existing_manifest_is_never_overwritten(self):
        self.reports.mkdir()
        self.collect()
        before = (self.out / "manifest.json").read_bytes()
        with self.assertRaises(SystemExit) as result:
            collect_crash_reports.main([
                "--strict", "--since", str(SINCE), "--out", str(self.out),
                "--reports-dir", str(self.reports),
            ])
        self.assertEqual(result.exception.code, 2)
        self.assertEqual((self.out / "manifest.json").read_bytes(), before)

    def test_strict_unreadable_header_cannot_pass_as_zero_crashes(self):
        report = write_file(self.reports / "random.ips", ips_bytes({"app_name": "Dayside"}))
        original_open = Path.open
        def open_path(path, *args, **kwargs):
            if path == report:
                raise PermissionError("header denied")
            return original_open(path, *args, **kwargs)
        with patch.object(Path, "open", open_path):
            collect_crash_reports.collect(SINCE, self.out, [self.reports],
                                          collect_crash_reports.DEFAULT_PROCESSES, strict=True)
        self.assertFalse(self.manifest()["scan"]["complete"])
        self.assertIn("header denied", self.manifest()["scan"]["issues"][0])

    def test_strict_malformed_header_cannot_pass_as_zero_crashes(self):
        write_file(self.reports / "random.ips", b'{"app_name":\n')
        collect_crash_reports.collect(SINCE, self.out, [self.reports],
                                      collect_crash_reports.DEFAULT_PROCESSES, strict=True)
        self.assertFalse(self.manifest()["scan"]["complete"])
        self.assertEqual(self.manifest()["reports"], [])


if __name__ == "__main__":
    unittest.main()
