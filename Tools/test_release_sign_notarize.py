#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# 正式签名与公证脚本的流程检查：只跑 --dry-run，不需要 macOS、证书或钥匙串。
from pathlib import Path
import os
import plistlib
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parent / "release_sign_notarize.sh"
IDENTITY = "Developer ID Application: Example Person (AB12CD34EF)"


class ReleaseSignNotarizeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.app = self.root / "Dayside.app"
        (self.app / "Contents").mkdir(parents=True)
        self.write_version("1.0")

    def tearDown(self):
        self.temp.cleanup()

    def write_version(self, version):
        with (self.app / "Contents/Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleIdentifier": "com.dayside.Dayside", "CFBundleShortVersionString": version}, stream)

    def run_script(self, *args, identity=IDENTITY):
        env = {key: value for key, value in os.environ.items() if key != "MEANTIME_SIGN_IDENTITY"}
        if identity is not None:
            env["MEANTIME_SIGN_IDENTITY"] = identity
        return subprocess.run(["bash", str(SCRIPT), *args], capture_output=True, text=True, env=env, check=False)

    def test_dry_run_orders_every_release_step(self):
        result = self.run_script(str(self.app), "arm64", "--out", str(self.root), "--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        steps = [line for line in result.stdout.splitlines() if line.startswith("DRY-RUN:")]
        order = ["sign_bundle.sh", "codesign --verify --deep --strict", "check_release_identity.py", "make_dmg.sh",
                 "--timestamp " + str(self.root / "Dayside-1.0-arm64.dmg"), "notarytool submit", "stapler staple",
                 "stapler validate", "spctl --assess --type open"]
        positions = [next(i for i, line in enumerate(steps) if needle in line.replace("\\", "")) for needle in order]
        self.assertEqual(positions, sorted(positions), result.stdout)
        self.assertIn("--asset-name Dayside-1.0-arm64.dmg", result.stdout)
        self.assertIn("--keychain-profile dayside-notary", result.stdout)
        self.assertIn("MEANTIME_SIGN_IDENTITY=Developer", result.stdout)
        self.assertNotIn("password", result.stdout.lower())

    def test_rejects_identities_that_cannot_be_notarized(self):
        for identity in (None, "-", "Apple Development: Example Person (AB12CD34EF)", "Developer ID Application: Example Person"):
            with self.subTest(identity=identity):
                result = self.run_script(str(self.app), "arm64", "--dry-run", identity=identity)
                self.assertEqual(result.returncode, 1)
                self.assertIn("Developer ID Application", result.stderr)

    def test_rejects_unknown_architecture_and_unsafe_profile(self):
        self.assertEqual(self.run_script(str(self.app), "universal", "--dry-run").returncode, 2)
        self.assertEqual(self.run_script(str(self.app), "arm64", "--profile", "a b", "--dry-run").returncode, 2)

    def test_rejects_non_release_version_and_existing_assets(self):
        self.write_version("1.0 beta")
        self.assertEqual(self.run_script(str(self.app), "arm64", "--out", str(self.root), "--dry-run").returncode, 1)
        self.write_version("1.0")
        (self.root / "Dayside-1.0-x86_64.dmg").write_bytes(b"already here")
        result = self.run_script(str(self.app), "x86_64", "--out", str(self.root), "--dry-run")
        self.assertEqual(result.returncode, 1)
        self.assertIn("不覆盖", result.stderr)


if __name__ == "__main__":
    unittest.main()
