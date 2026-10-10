#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

import check_adhoc_identity


class AdHocIdentityTests(unittest.TestCase):
    def inspect(self, errors, metadata=b"Signature=adhoc\n", returncode=0):
        formal = {"ok": not errors, "errors": errors}
        signature = subprocess.CompletedProcess([], returncode, stdout=b"", stderr=metadata)
        with patch.object(check_adhoc_identity.check_release_identity, "inspect_bundle", return_value=formal), \
                patch.object(check_adhoc_identity.subprocess, "run", return_value=signature):
            return check_adhoc_identity.inspect_bundle(Path("Dayside.app"), "Dayside-1.0-arm64.dmg")

    def test_only_the_explicitly_deferred_signing_error_is_allowed(self):
        result = self.inspect(["release_signing_identity"])
        self.assertTrue(result["ok"])
        self.assertFalse(result["formalReleaseIdentityGate"]["ok"])
        self.assertEqual(result["formalReleaseIdentityGate"]["errors"], ["release_signing_identity"])

    def test_preview_and_other_identity_failures_still_block(self):
        for error in ("local_preview", "bundle_identifier", "app_intents_metadata", "container_migration",
                      "asset_architecture", "network_entitlement", "strict_signature", "test_bundle"):
            with self.subTest(error=error):
                self.assertFalse(self.inspect([error, "release_signing_identity"])["ok"])

    def test_unsigned_or_other_certificate_is_not_an_ad_hoc_signature(self):
        for metadata in (b"", b"Authority=Developer ID Application: Fixture\n", b"Signature=adhoc-extra\n"):
            self.assertFalse(self.inspect(["release_signing_identity"], metadata)["ok"])

    def test_inspection_failure_blocks(self):
        self.assertFalse(self.inspect(["release_signing_identity"], returncode=1)["ok"])

    def test_formal_success_is_not_mislabeled_ad_hoc(self):
        self.assertFalse(self.inspect([])["ok"])


if __name__ == "__main__":
    unittest.main()
