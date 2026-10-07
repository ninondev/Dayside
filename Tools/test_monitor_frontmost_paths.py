#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
import contextlib
import io
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

import monitor_frontmost


class FrontmostOwnershipTests(unittest.TestCase):
    root = Path("/tmp/owned-step")

    def record(self, path):
        return {"dayside": True, "info": '\"LSBundlePath\"=\"' + str(path) + '\"'}

    def test_owned_bundle_counts(self):
        self.assertEqual(monitor_frontmost.classify_frontmost(self.record(self.root / "dd/Dayside.app"), [self.root]), (True, False))

    def test_foreign_bundle_is_retained_as_foreign(self):
        self.assertEqual(monitor_frontmost.classify_frontmost(self.record("/tmp/fgfix/Dayside.app"), [self.root]), (False, True))

    def test_shared_string_prefix_does_not_imply_ownership(self):
        self.assertEqual(monitor_frontmost.classify_frontmost(self.record("/tmp/owned-step-other/Dayside.app"), [self.root]), (False, True))

    def test_empty_frontmost_is_neither_owned_nor_foreign(self):
        self.assertEqual(monitor_frontmost.classify_frontmost({"dayside": False}, [self.root]), (False, False))

    def test_unattributable_dayside_does_not_silently_pass(self):
        with self.assertRaises(ValueError):
            monitor_frontmost.classify_frontmost({"dayside": True, "info": ""}, [self.root])

    def test_default_preserves_existing_dayside_guard(self):
        self.assertEqual(monitor_frontmost.classify_frontmost(self.record("/tmp/elsewhere/Dayside.app"), []), (True, False))

    def run_monitor(self, record):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder) / "samples.jsonl"
            process = Mock(returncode=0)
            process.poll.return_value = 0
            with patch.object(sys, "argv", ["monitor", "--output", str(output), "--owned-app-root", str(self.root), "--", "test-command"]), patch.object(monitor_frontmost, "screen_free", return_value=True), patch.object(monitor_frontmost, "frontmost", return_value=record), patch.object(monitor_frontmost.subprocess, "Popen", return_value=process) as launch, contextlib.redirect_stdout(io.StringIO()):
                status = monitor_frontmost.main()
            return status, launch.call_count, output.read_text()

    def test_foreign_frontmost_does_not_block_command(self):
        status, launches, samples = self.run_monitor(self.record("/tmp/fgfix/Dayside.app"))
        self.assertEqual((status, launches), (0, 1))
        self.assertIn('"foreignDayside": true', samples)
        self.assertIn('"ownedDayside": false', samples)

    def test_owned_frontmost_prevents_command_launch(self):
        status, launches, samples = self.run_monitor(self.record(self.root / "Dayside.app"))
        self.assertEqual((status, launches), (1, 0))
        self.assertIn('"ownedDayside": true', samples)


if __name__ == "__main__":
    unittest.main()
