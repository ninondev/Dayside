#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# 只核版本库里的冻结原文和替换点，不写旧版工作树。
import subprocess
import unittest
import perf_overlay_old as overlay


class OverlayTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        available = subprocess.run(['git', 'cat-file', '-e', overlay.BASE + '^{commit}'],
                                   capture_output=True, check=False)
        if available.returncode != 0:
            raise unittest.SkipTest('Pinned historical source is unavailable in this clone: ' + overlay.BASE)
        cls.originals = {path: subprocess.check_output(['git', 'show', overlay.BASE + ':' + path], text=True)
                         for path in overlay.PATHS}

    def test_all_adapters_match_exact_0924c_originals(self):
        patched = overlay.patch_plan(self.originals)
        self.assertEqual(set(patched), set(overlay.PATHS))
        for path in overlay.PATHS:
            self.assertNotEqual(patched[path], self.originals[path])
        self.assertIn('model.jump(to: date)', patched['TahoeTime/Views/TimeInputView.swift'])
        self.assertIn('parts: "dynamic"', patched['TahoeTime/Views/WorldMapView.swift'])
        self.assertIn('PerformanceProbe.recordConversion(places: resultZones.count)',
                      patched['TahoeTime/Views/TimeInputView.swift'])

    def test_changed_original_or_duplicate_match_refused(self):
        with self.assertRaises(ValueError):
            overlay.replace_once('changed source', 'original source', 'replacement', 'test')
        with self.assertRaises(ValueError):
            overlay.replace_once('old old', 'old', 'replacement', 'test')
        altered = dict(self.originals)
        path = 'TahoeTime/Models/ApplicationSession.swift'
        altered[path] = altered[path].replace('if isLocalPreview { return .standard }', 'if isLocalPreview { return .custom }')
        with self.assertRaises(ValueError):
            overlay.patch_plan(altered)

    def test_old_motion_override_uses_only_existing_app_model_gate(self):
        patched = overlay.patch_plan(self.originals)
        self.assertNotIn('transformEnvironment', patched['TahoeTime/TahoeTimeApp.swift'])
        self.assertIn('guard animatesScrub, !reduced', patched['TahoeTime/Models/AppModel.swift'])
        self.assertNotIn('accessibilityReduceMotion', self.originals['TahoeTime/Views/WorldMapView.swift'])

    def test_panel_visibility_read_is_test_build_only(self):
        patched = overlay.patch_plan(self.originals)['TahoeTime/Models/AppModel.swift']
        self.assertIn('#if DEBUG\n    private(set) var isPanelVisible = false\n    #else\n    private var isPanelVisible = false\n    #endif', patched)
        self.assertEqual(patched.count('private(set) var isPanelVisible = false'), 1)

    def test_every_production_adapter_has_test_host_guard(self):
        patched = overlay.patch_plan(self.originals)
        self.assertIn('if isLocalPreview && !isTesting', patched['TahoeTime/Models/ApplicationSession.swift'])
        for path in ('TahoeTime/Models/AppModel.swift', 'TahoeTime/Models/RustCore.swift',
                     'TahoeTime/Views/WorldMapView.swift', 'TahoeTime/Views/TimeInputView.swift'):
            self.assertIn('#if DEBUG', patched[path])
        self.assertIn('PerformanceProbe.isRequested', patched['TahoeTime/Models/UITestFixture.swift'])


class PortableOverlayTests(unittest.TestCase):
    def test_scratch_boundary_rejects_live_paths_roots_and_lookalikes(self):
        from pathlib import Path
        import tempfile
        scratch = Path(tempfile.gettempdir()).resolve()
        self.assertTrue(overlay.is_scratch_checkout(scratch / 'old-source'))
        self.assertTrue(overlay.is_scratch_checkout(Path('/private/tmp/old-source')))
        for path in (scratch, Path('/private/tmp'), Path('/Applications/Dayside.app'),
                     Path('/work/Dayside'), Path(str(scratch) + '-lookalike') / 'old-source'):
            self.assertFalse(overlay.is_scratch_checkout(path), str(path))

    def test_changed_original_or_duplicate_match_always_refused(self):
        for source in ('changed source', 'old old'):
            with self.assertRaises(ValueError):
                overlay.replace_once(source, 'old', 'replacement', 'test')


if __name__ == '__main__':
    unittest.main()
