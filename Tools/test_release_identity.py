#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
import copy
from pathlib import Path
import plistlib
import tempfile
import unittest

import check_release_identity


class ReleaseIdentityTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.app = Path(self.scratch.name) / "Dayside.app"
        self.resources = self.app / "Contents/Resources"
        (self.resources / "Metadata.appintents").mkdir(parents=True)
        (self.resources / "Metadata.appintents/extract.actionsdata").write_bytes(b"actions")
        (self.resources / "container-migration.plist").write_bytes(plistlib.dumps({"Move": ["legacy.plist"]}))
        self.info = {
            "CFBundleIdentifier": "com.dayside.Dayside", "CFBundleName": "Dayside",
            "CFBundleDisplayName": "Dayside", "CFBundleShortVersionString": "1.0.1", "CFBundleVersion": "20",
            "CFBundleURLTypes": [{"CFBundleURLSchemes": ["dayside"]}],
            "NSServices": [{"NSMessage": "convertTime", "NSPortName": "Dayside",
                            "NSSendTypes": ["NSStringPboardType"], "NSMenuItem": {"default": "Convert Time with Dayside"}}],
        }
        self.entitlements = {"com.apple.security.app-sandbox": True}

    def errors(self, info=None, entitlements=None, asset_name="Dayside-1.0.1-arm64.dmg"):
        return check_release_identity.identity_errors(
            self.app, self.info if info is None else info,
            self.entitlements if entitlements is None else entitlements, asset_name,
        )

    def test_formal_identity_and_both_asset_architectures_are_accepted(self):
        self.assertEqual(self.errors(), [])
        self.assertEqual(self.errors(asset_name="Dayside-1.0.1-x86_64.dmg"), [])

    def test_published_preview_shape_is_rejected(self):
        info = copy.deepcopy(self.info)
        info.update(CFBundleIdentifier="com.dayside.Dayside.localpreview", CFBundleName="Dayside Local Preview",
                    CFBundleDisplayName="Dayside Local Preview", MTLocalPreview=True)
        info.pop("CFBundleURLTypes")
        info.pop("NSServices")
        entitlements = dict(self.entitlements)
        entitlements["com.apple.security.application-groups"] = ["group.com.dayside.Dayside"]
        for code in ["bundle_identifier", "bundle_name", "local_preview", "url_scheme",
                     "time_conversion_service", "application_group"]:
            self.assertIn(code, self.errors(info, entitlements))

    def test_formal_name_cannot_hide_preview_flag(self):
        self.assertIn("local_preview", self.errors({**self.info, "MTLocalPreview": True}))

    def test_asset_version_must_match_bundle_and_asset_name_must_be_valid(self):
        self.assertIn("asset_version", self.errors(asset_name="Dayside-1.0-arm64.dmg"))
        self.assertIn("asset_name", self.errors(asset_name="Dayside-1.0.1-universal.dmg"))

    def test_missing_or_empty_app_intents_metadata_is_rejected(self):
        actions = self.resources / "Metadata.appintents/extract.actionsdata"
        actions.write_bytes(b"")
        self.assertIn("app_intents_metadata", self.errors())
        actions.unlink()
        self.assertIn("app_intents_metadata", self.errors())

    def test_missing_or_invalid_migration_resource_is_rejected(self):
        migration = self.resources / "container-migration.plist"
        for value in [b"bad plist", plistlib.dumps({}), plistlib.dumps({"Move": []})]:
            migration.write_bytes(value)
            self.assertIn("container_migration", self.errors())
        migration.unlink()
        self.assertIn("container_migration", self.errors())

    def test_debug_and_temporary_exception_permissions_are_rejected(self):
        self.assertIn("debug_entitlement", self.errors(entitlements={**self.entitlements, "com.apple.security.get-task-allow": True}))
        self.assertIn("temporary_exception", self.errors(entitlements={**self.entitlements, "com.apple.security.temporary-exception.mach-lookup.global-name": ["testmanagerd"]}))

    def test_network_permission_and_test_payload_are_rejected(self):
        self.assertIn("network_entitlement", self.errors(entitlements={**self.entitlements, "com.apple.security.network.client": True}))
        (self.app / "Contents/PlugIns/Tests.xctest").mkdir(parents=True)
        self.assertIn("test_bundle", self.errors())

    def test_malformed_integration_arrays_fail_closed(self):
        for key, code in [("CFBundleURLTypes", "url_scheme"), ("NSServices", "time_conversion_service")]:
            self.assertIn(code, self.errors({**self.info, key: "unexpected"}))

    def test_any_app_group_entitlement_is_rejected(self):
        group = {**self.entitlements, "com.apple.security.application-groups": ["group.com.dayside.Dayside"]}
        self.assertEqual(self.errors(entitlements=group), ["application_group"])
        empty = {**self.entitlements, "com.apple.security.application-groups": []}
        self.assertEqual(self.errors(entitlements=empty), ["application_group"])

    def test_qualified_only_group_is_rejected(self):
        entitlements = {**self.entitlements, "com.apple.security.application-groups": ["ABCDE12345.group.com.dayside.Dayside"]}
        for team in [None, "ABCDE12345", "OTHER12345", "ABCDE"]:
            self.assertIn("application_group", check_release_identity.identity_errors(
                          self.app, self.info, entitlements, signing_team=team))

    def test_shipping_requires_a_real_developer_id_signing_identity(self):
        for metadata in [b"Signature=adhoc\nTeamIdentifier=not set\n", b"TeamIdentifier=ABCDE12345\n",
                         b"Authority=Apple Development: Fixture\nTeamIdentifier=ABCDE12345\n"]:
            self.assertIn("release_signing_identity", check_release_identity.signing_errors(self.app, metadata, self.entitlements))

    def test_developer_id_bundle_without_app_group_needs_no_profile(self):
        metadata = b"Authority=Developer ID Application: Fixture\nTeamIdentifier=ABCDE12345\n"
        self.assertEqual(check_release_identity.signing_errors(self.app, metadata, self.entitlements), [])
        self.assertNotIn("release_signing_identity", check_release_identity.signing_errors(self.app, metadata, self.entitlements))

    def test_service_must_declare_text_input_and_menu_item(self):
        for key in ["NSSendTypes", "NSMenuItem"]:
            info = copy.deepcopy(self.info)
            info["NSServices"][0].pop(key)
            self.assertIn("time_conversion_service", self.errors(info))


if __name__ == "__main__":
    unittest.main()
