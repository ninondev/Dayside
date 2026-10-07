#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""AX 转储报告的最终校验：Tools/ax_dump_pages.sh 以 --validate 调用这里的可调用实现，
stdlib unittest 用临时目录里的夹具报告检验两种模式（保存/不保存图片）的判定。
MEANTIME_AX_SAVE_IMAGES=0 的无图模式只免 images 路径与 PNG 文件；捕获状态、请求/实测
外观与对比度结果仍然必须真实存在。"""
import json
import sys
import tempfile
import unittest
import ax_check
from pathlib import Path


def validate_ax_reports(folder, policy, pages, save_images=True):
    """校验各页的 AX 转储报告，返回错误列表（空列表即通过）。

    save_images=False 对应 MEANTIME_AX_SAVE_IMAGES=0：不要求 images 路径与 PNG 文件，
    但仍校验每页每种外观的捕获状态（validLayout）、请求/实测外观记录与对比度结果；
    此时报告里若仍带 images 路径则报错。forced-native 策略两种模式都完整校验。
    """
    folder = Path(folder)
    errors = []
    for page in pages:
        path = folder / (page + ".json")
        if not path.exists():
            errors.append(f"{page}: missing AX dump")
            continue
        data = json.loads(path.read_text())
        images = data.get("images", {})
        if not save_images and images:
            errors.append(f"{page}: image paths saved despite MEANTIME_AX_SAVE_IMAGES=0")
        for name in ("light", "dark"):
            if save_images and (name not in images or not (folder / f"{page}-{name}.png").is_file()):
                errors.append(f"{page}/{name}: missing valid capture")
            capture = data.get("captureByAppearance", {}).get(name)
            if not isinstance(capture, dict) or capture.get("validLayout") is not True:
                errors.append(f"{page}/{name}: missing valid capture status")
            if not data.get("requestedAppearance_" + name) or not data.get("effectiveAppearance_" + name):
                errors.append(f"{page}/{name}: missing requested/effective appearance")
            if not any("contrast_" + name in node for node in data.get("nodesByAppearance", {}).get(name, [])):
                errors.append(f"{page}/{name}: no contrast measurements")
        if policy == "forced-native":
            if data.get("appearancePolicy") != policy:
                errors.append(f"{page}: diagnostic appearance policy not active")
            for name in ("light", "dark"):
                if data.get("appearanceMatched_" + name) is not True:
                    errors.append(f"{page}/{name}: actual native appearance did not match request")
                if data.get("renderBackgroundAppearance_" + name) != data.get("effectiveAppearance_" + name):
                    errors.append(f"{page}/{name}: material compositing appearance differs from actual content")
    return errors


def _report_fixture(images=("light", "dark"), captures=("light", "dark"), valid_layouts=("light", "dark"),
                    contrasts=("light", "dark"), appearance_policy="production",
                    appearance_matched=True, material_matches=True):
    """一份贴近真实转储的夹具报告：捕获状态、外观记录与对比度结果齐全；
    images/captures/valid_layouts/contrasts 控制各自缺什么。"""
    captures_by_appearance = {}
    nodes_by_appearance = {}
    for name in ("light", "dark"):
        if name in captures:
            status = {"attempts": 1, "layoutBefore": [0.0, 0.0, 480.0, 640.0],
                      "layoutAfter": [0.0, 0.0, 480.0, 640.0]}
            if name in valid_layouts:
                status["validLayout"] = True
            else:
                status["validLayout"] = False
                status["reason"] = "layout did not settle"
            captures_by_appearance[name] = status
        line = {"depth": 3, "class": "SwiftUI.AccessibilityNode", "childCount": 0,
                "role": "AXStaticText", "label": "Tokyo 明天 09:00",
                "help": "Tokyo local time", "hint": "Opens the city detail",
                "frame": {"x": 16.0, "y": 44.0, "w": 180.0, "h": 20.0}}
        if name in contrasts:
            line["contrast_" + name] = 13.5
            line["ink_" + name] = "#1D1D1F"
            line["background_" + name] = "#FFFFFF"
        nodes_by_appearance[name] = [line]
    return {
        "page": "planner",
        "appearancePolicy": appearance_policy,
        "captureMethod": "cachedView",
        "requestedAppearance_dark": "NSAppearanceNameDarkAqua",
        "requestedAppearance_light": "NSAppearanceNameAqua",
        "effectiveAppearance_dark": "NSAppearanceNameDarkAqua",
        "effectiveAppearance_light": "NSAppearanceNameAqua",
        "windowEffectiveAppearance_dark": "NSAppearanceNameDarkAqua",
        "windowEffectiveAppearance_light": "NSAppearanceNameAqua",
        "appearanceMatched_dark": appearance_matched,
        "appearanceMatched_light": appearance_matched,
        "renderBackgroundAppearance_dark": "NSAppearanceNameDarkAqua" if material_matches else "NSAppearanceNameAqua",
        "renderBackgroundAppearance_light": "NSAppearanceNameAqua",
        "captureByAppearance": captures_by_appearance,
        "nodesByAppearance": nodes_by_appearance,
        "images": {name: f"/tmp/dayside-ax-planner-501-{name}.png" for name in images},
        "layoutRewalks": 0,
        "settledAfterSeconds": 3.2,
        "nodeCount": len(nodes_by_appearance.get("light", [])),
        "nodes": nodes_by_appearance.get("light", []),
        "probe": {"class": "SwiftUI.HostingView", "modern": 12, "subviews": 31},
    }


class AXReportValidationTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.folder = Path(tmp.name)

    def write_report(self, **kwargs):
        report = _report_fixture(**kwargs)
        (self.folder / "planner.json").write_text(json.dumps(report, ensure_ascii=False), encoding="utf-8")
        return report

    def validate(self, *, save_images, policy="production"):
        return validate_ax_reports(self.folder, policy, ["planner"], save_images=save_images)

    def test_report_without_images_passes_in_no_image_mode(self):
        self.write_report(images=())
        self.assertEqual(self.validate(save_images=False), [])

    def test_missing_capture_status_fails_in_no_image_mode(self):
        self.write_report(images=(), captures=("light",))
        errors = self.validate(save_images=False)
        self.assertTrue(any("missing valid capture status" in error for error in errors))

    def test_invalid_capture_status_fails_in_no_image_mode(self):
        self.write_report(images=(), valid_layouts=())
        errors = self.validate(save_images=False)
        self.assertTrue(any("missing valid capture status" in error for error in errors))

    def test_missing_contrast_fails_in_no_image_mode(self):
        self.write_report(images=(), contrasts=())
        errors = self.validate(save_images=False)
        self.assertTrue(any("no contrast measurements" in error for error in errors))

    def test_saved_image_paths_fail_in_no_image_mode(self):
        self.write_report(images=("light", "dark"))
        errors = self.validate(save_images=False)
        self.assertTrue(any("MEANTIME_AX_SAVE_IMAGES=0" in error for error in errors))

    def test_absent_images_fail_in_default_mode(self):
        self.write_report(images=())
        errors = self.validate(save_images=True)
        self.assertTrue(any("missing valid capture" in error for error in errors))

    def test_report_with_images_passes_in_default_mode(self):
        self.write_report(images=("light", "dark"))
        for name in ("light", "dark"):
            (self.folder / f"planner-{name}.png").write_bytes(b"\x89PNG\r\n\x1a\n")
        self.assertEqual(self.validate(save_images=True), [])

    def test_missing_report_fails(self):
        errors = self.validate(save_images=False)
        self.assertTrue(any("missing AX dump" in error for error in errors))

    def test_forced_native_matching_report_passes_in_no_image_mode(self):
        self.write_report(images=(), appearance_policy="forced-native")
        self.assertEqual(self.validate(save_images=False, policy="forced-native"), [])

    def test_forced_native_appearance_mismatch_fails(self):
        self.write_report(images=(), appearance_policy="forced-native", appearance_matched=False)
        errors = self.validate(save_images=False, policy="forced-native")
        self.assertTrue(any("appearance did not match request" in error for error in errors))

    def test_forced_native_material_mismatch_fails(self):
        self.write_report(images=(), appearance_policy="forced-native", material_matches=False)
        errors = self.validate(save_images=False, policy="forced-native")
        self.assertTrue(any("material compositing appearance differs" in error for error in errors))


class AXCheckerNoImageTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.path = Path(tmp.name) / "planner.json"
        self.data = _report_fixture(images=())
        for shade in ("light", "dark"):
            self.data["renderBackground_" + shade] = "#FFFFFF" if shade == "light" else "#000000"
            self.data["captureByAppearance"][shade]["contentRect"] = [0, 0, 480, 640]
            self.data["nodesByAppearance"][shade] *= 5

    def findings(self, save_images=False):
        self.path.write_text(json.dumps(self.data), encoding="utf-8")
        return ax_check.check(self.path, save_images=save_images)[2]

    def test_actual_checker_accepts_valid_no_image_capture(self):
        self.assertEqual(self.findings(), [])
        self.assertTrue(self.findings(save_images=True))

    def test_actual_checker_rejects_invalid_capture(self):
        self.data["captureByAppearance"]["dark"]["validLayout"] = False
        self.assertTrue(self.findings())

    def test_actual_checker_rejects_missing_coordinates(self):
        del self.data["captureByAppearance"]["light"]["contentRect"]
        self.assertTrue(self.findings())

    def test_actual_checker_rejects_missing_contrast(self):
        for node in self.data["nodesByAppearance"]["light"]:
            node.pop("contrast_light", None)
        self.assertTrue(self.findings())

    def test_actual_checker_rejects_low_contrast(self):
        for node in self.data["nodesByAppearance"]["dark"]:
            node["contrast_dark"] = 1.0
        self.assertTrue(self.findings())

    def test_actual_checker_rejects_unmatched_forced_appearance(self):
        self.data["appearancePolicy"] = "forced-native"
        self.data["appearanceMatched_dark"] = False
        self.assertTrue(self.findings())


def main(argv):
    if len(argv) > 1 and argv[1] == "--validate":
        if len(argv) < 5:
            print("usage: test_copy2_ax_output.py --validate <folder> <policy> <0|1> <page>...", file=sys.stderr)
            return 2
        errors = validate_ax_reports(argv[2], argv[3], argv[5:], save_images=argv[4] == "1")
        if errors:
            print("\n".join(errors), file=sys.stderr)
            return 1
        return 0
    unittest.main(argv=argv)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
