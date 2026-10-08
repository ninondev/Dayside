#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
from __future__ import annotations

import argparse
import json
from pathlib import Path
import plistlib
import re
import subprocess


def identity_errors(app: Path, info: dict, entitlements: dict, asset_name: str | None = None,
                    signing_team: str | None = None) -> list[str]:
    errors = []
    if info.get("CFBundleIdentifier") != "com.dayside.Dayside":
        errors.append("bundle_identifier")
    if any(info.get(key) != "Dayside" for key in ("CFBundleName", "CFBundleDisplayName")):
        errors.append("bundle_name")
    if "MTLocalPreview" in info and info["MTLocalPreview"] is not False:
        errors.append("local_preview")
    for key in ("CFBundleShortVersionString", "CFBundleVersion"):
        if not isinstance(info.get(key), str) or not info[key].strip():
            errors.append(key)
    if asset_name is not None:
        asset = re.fullmatch(r"Dayside-(\d+\.\d+(?:\.\d+)?)-(arm64|x86_64)\.dmg", asset_name)
        if asset is None:
            errors.append("asset_name")
        elif asset.group(1) != info.get("CFBundleShortVersionString"):
            errors.append("asset_version")
    url_types = info.get("CFBundleURLTypes", [])
    if not isinstance(url_types, list) or not any(
        isinstance(item, dict) and isinstance(item.get("CFBundleURLSchemes"), list)
        and "dayside" in item["CFBundleURLSchemes"] for item in url_types
    ):
        errors.append("url_scheme")
    services = info.get("NSServices", [])
    if not isinstance(services, list) or not any(
        isinstance(item, dict) and item.get("NSMessage") == "convertTime"
        and item.get("NSPortName") == "Dayside"
        and isinstance(item.get("NSSendTypes"), list) and "NSStringPboardType" in item["NSSendTypes"]
        and isinstance(item.get("NSMenuItem"), dict) and isinstance(item["NSMenuItem"].get("default"), str)
        and bool(item["NSMenuItem"]["default"].strip()) for item in services
    ):
        errors.append("time_conversion_service")
    resources = app / "Contents/Resources"
    actions = resources / "Metadata.appintents/extract.actionsdata"
    if not actions.is_file() or actions.stat().st_size == 0:
        errors.append("app_intents_metadata")
    try:
        migration = plistlib.loads((resources / "container-migration.plist").read_bytes())
        if not isinstance(migration, dict) or not isinstance(migration.get("Move"), list) or not migration["Move"]:
            errors.append("container_migration")
    except (OSError, ValueError, plistlib.InvalidFileException):
        errors.append("container_migration")
    groups = entitlements.get("com.apple.security.application-groups", [])
    expected_groups = {"group.com.dayside.Dayside"}
    if not isinstance(groups, list) or not any(group in groups for group in expected_groups):
        errors.append("application_group")
    if entitlements.get("com.apple.security.app-sandbox") is not True:
        errors.append("sandbox")
    if entitlements.get("com.apple.security.get-task-allow") is not None and entitlements["com.apple.security.get-task-allow"] is not False:
        errors.append("debug_entitlement")
    if any(key.startswith("com.apple.security.temporary-exception.") for key in entitlements):
        errors.append("temporary_exception")
    if any(key.startswith("com.apple.security.network.") and value for key, value in entitlements.items()):
        errors.append("network_entitlement")
    if (app / "Contents/PlugIns").exists() and any((app / "Contents/PlugIns").glob("*.xctest")):
        errors.append("test_bundle")
    return errors


def signing_errors(app: Path, metadata: bytes, entitlements: dict) -> list[str]:
    errors = []
    team = re.search(rb"^TeamIdentifier=([A-Z0-9]{10})$", metadata, re.MULTILINE)
    authority = re.search(rb"^Authority=Developer ID Application: .+$", metadata, re.MULTILINE)
    if team is None or authority is None or b"Signature=adhoc" in metadata:
        errors.append("release_signing_identity")
    groups = entitlements.get("com.apple.security.application-groups", [])
    if isinstance(groups, list) and any(isinstance(group, str) and group.startswith("group.") for group in groups):
        if not (app / "Contents/embedded.provisionprofile").is_file():
            errors.append("provisioning_profile_required")
    return errors


def inspect_bundle(app: Path, asset_name: str | None = None) -> dict:
    record = {"app": str(app.resolve()), "ok": False, "errors": []}
    try:
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        if not isinstance(info, dict):
            raise ValueError("info_plist")
        entitlement_result = subprocess.run(
            ["/usr/bin/codesign", "-d", "--verbose=4", "--entitlements", ":-", str(app)],
            capture_output=True, check=False, timeout=30,
        )
        entitlements = plistlib.loads(entitlement_result.stdout)
        if entitlement_result.returncode != 0 or not isinstance(entitlements, dict):
            raise ValueError("signature_entitlements")
        team_match = re.search(rb"^TeamIdentifier=([A-Z0-9]{10})$", entitlement_result.stderr, re.MULTILINE)
        signing_team = team_match.group(1).decode("ascii") if team_match is not None else None
        record["errors"] = identity_errors(app, info, entitlements, asset_name, signing_team)
        record["errors"].extend(signing_errors(app, entitlement_result.stderr, entitlements))
        record["signingTeam"] = signing_team
        record.update(bundleIdentifier=info.get("CFBundleIdentifier"), version=info.get("CFBundleShortVersionString"))
        signature = subprocess.run(
            ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)],
            capture_output=True, check=False, timeout=30,
        )
        if signature.returncode != 0:
            record["errors"].append("strict_signature")
        if asset_name is not None and "asset_name" not in record["errors"]:
            executable = info.get("CFBundleExecutable")
            if not isinstance(executable, str) or Path(executable).name != executable:
                record["errors"].append("executable_name")
            else:
                arch = subprocess.run(
                    ["/usr/bin/lipo", "-archs", str(app / "Contents/MacOS" / executable)],
                    capture_output=True, text=True, check=False, timeout=30,
                )
                expected = asset_name.removesuffix(".dmg").rsplit("-", 1)[-1]
                if arch.returncode != 0 or arch.stdout.split() != [expected]:
                    record["errors"].append("asset_architecture")
    except (OSError, ValueError, plistlib.InvalidFileException, subprocess.TimeoutExpired):
        record["errors"].append("bundle_inspection")
    record["ok"] = not record["errors"]
    return record


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path)
    parser.add_argument("--asset-name")
    args = parser.parse_args()
    record = inspect_bundle(args.app, args.asset_name)
    print(json.dumps(record, ensure_ascii=False))
    return 0 if record["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
