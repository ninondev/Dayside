#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import monitor_frontmost

ROOT = Path(__file__).resolve().parents[1]


class PauseFileTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.home = Path(directory.name)
        self.pause_file = self.home / ".config/dayside/measure.state"
        self.pause_file.parent.mkdir(parents=True)
        home_env = patch.dict(os.environ, {"HOME": str(self.home)})
        home_env.start()
        self.addCleanup(home_env.stop)

    def assert_window(self, free):
        self.assertEqual(monitor_frontmost.screen_free(False), free)
        self.assertEqual(monitor_frontmost.screen_free(True), free)

    def test_absent_is_free(self):
        self.assertEqual(monitor_frontmost.measurement_state(), "FREE")
        self.assert_window(True)

    def test_linked_free_is_free_and_target_is_reread(self):
        target = self.home / "state"
        target.write_text("FREE\n")
        self.pause_file.symlink_to(target)
        self.assert_window(True)
        target.write_text("TIMED test\n")
        self.assert_window(False)

    def test_linked_timed_blocks(self):
        target = self.home / "state"
        target.write_text("TIMED test\n")
        self.pause_file.symlink_to(target)
        self.assert_window(False)

    def test_dangling_link_blocks(self):
        self.pause_file.symlink_to(self.home / "missing")
        self.assert_window(False)

    def test_unreadable_and_unknown_values_block(self):
        for value in [b"", b"UNKNOWN\n", b"\xff"]:
            with self.subTest(value=value):
                self.pause_file.write_bytes(value)
                self.assert_window(False)

    def test_foreground_marker_still_blocks_only_foreground(self):
        (self.home / ".dayside-screen-busy").touch()
        self.assertTrue(monitor_frontmost.screen_free(False))
        self.assertFalse(monitor_frontmost.screen_free(True))

    def test_launcher_defers_before_build_or_launch(self):
        self.pause_file.write_text("TIMED test\n")
        commands = self.home / "bin"
        commands.mkdir()
        marker = self.home / "unexpected-command"
        for name in ["xcodebuild", "open", "Dayside"]:
            sentinel = commands / name
            sentinel.write_text('#!/bin/bash\nprintf "%s\\n" "$0" >> "$PAUSE_TEST_MARKER"\nexit 99\n')
            sentinel.chmod(0o700)
        output = self.home / "captures"
        env = os.environ.copy()
        env.pop("MEANTIME_DEBUG_APP", None)
        env.update({"PATH": str(commands) + ":" + env["PATH"],
                    "PAUSE_TEST_MARKER": str(marker),
                    "MEANTIME_SKIP_BUILD": "0",
                    "MEANTIME_DERIVED_DATA_PATH": str(self.home / "dd")})
        result = subprocess.run(
            ["/bin/bash", "-x", str(ROOT / "Tools/shoot_app_pages.sh"), str(output)],
            env=env, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 75, result.stderr)
        self.assertIn("DEFERRED: Page capture; measure.state=TIMED test", result.stderr)
        self.assertFalse(marker.exists(), result.stderr)
        self.assertFalse(output.exists(), result.stderr)
        self.assertNotIn("make_debug_copy.sh", result.stderr)
        self.assertNotIn("xcodebuild", result.stderr)
        self.assertNotIn("owner_away.sh", result.stderr)


if __name__ == "__main__":
    unittest.main()
