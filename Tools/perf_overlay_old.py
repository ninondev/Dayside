#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Apply only test-host ruler adapters to an untouched 0924c scratch checkout."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

BASE = '72c423826313ce8b2399fd35eff9ea6f8d61b3f9'
PROBE = 'TahoeTime/Models/Diagnostics/PerformanceProbe.swift'


def git(root, *args):
    return subprocess.check_output(['git', '-C', str(root), *args], text=True)


def replace_once(source, old, new, label):
    count = source.count(old)
    if count != 1:
        raise ValueError(f'{label}: expected one original snippet, found {count}')
    return source.replace(old, new, 1)


def is_scratch_checkout(root):
    root = root.resolve()
    roots = {Path('/private/tmp').resolve(), Path(tempfile.gettempdir()).resolve()}
    return any(root != scratch and root.is_relative_to(scratch) for scratch in roots)


def patch_plan(originals):
    result = dict(originals)
    def patch(path, old, new):
        result[path] = replace_once(result[path], old, new, path)

    path = 'TahoeTime/Models/ApplicationSession.swift'
    patch(path, 'if isLocalPreview { return .standard }', 'if isLocalPreview && !isTesting { return .standard }')
    path = 'TahoeTime/Models/UITestFixture.swift'
    patch(path, 'ApplicationSession.uiTestPage != nil || ApplicationSession.uiTestSurface != nil',
          'ApplicationSession.uiTestPage != nil || ApplicationSession.uiTestSurface != nil || PerformanceProbe.isRequested')
    patch(path, '        Store.saveZones(zones, to: defaults)\n',
          '        Store.saveZones(zones, to: defaults)\n        if PerformanceProbe.isRequested { PerformanceProbe.seed(defaults) }\n')
    path = 'TahoeTime/Pro/ProFixture.swift'
    patch(path, '        if !isEmpty {\n            _ = people.save(PersonProfile(name: "Ana",',
          '        if !isEmpty && !PerformanceProbe.isRequested {\n            _ = people.save(PersonProfile(name: "Ana",')
    path = 'TahoeTime/Models/AppModel.swift'
    patch(path, '    private var isPanelVisible = false\n',
          '    #if DEBUG\n    private(set) var isPanelVisible = false\n    #else\n    private var isPanelVisible = false\n    #endif\n')
    patch(path, '        guard animatesScrub, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return nil }\n',
          '        #if DEBUG\n        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && !PerformanceProbe.isRequested\n        #else\n        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion\n        #endif\n        guard animatesScrub, !reduced else { return nil }\n')
    path = 'TahoeTime/TahoeTimeApp.swift'
    patch(path, '                    DiagnosticsReport.runProbeIfRequested(model: model, hub: features)\n',
          '                    PerformanceProbe.runIfRequested(model: model, hub: features, open: { openWindow(id: $0) }, settings: { openSettings() })\n                    DiagnosticsReport.runProbeIfRequested(model: model, hub: features)\n')
    path = 'TahoeTime/Models/RustCore.swift'
    patch(path, '    ) -> Output {\n        do {\n',
          '    ) -> Output {\n        #if DEBUG\n        let performanceStart = PerformanceRustCalls.begin()\n        defer { PerformanceRustCalls.end(operation, started: performanceStart) }\n        #endif\n        do {\n')
    path = 'TahoeTime/Views/WorldMapView.swift'
    patch(path, '            set { seconds = newValue }\n',
          '            set {\n                #if DEBUG\n                if seconds != newValue { PerformanceRustCalls.animationFrame() }\n                #endif\n                seconds = newValue\n            }\n')
    path = 'TahoeTime/Views/TimeInputView.swift'
    patch(path, '            if !dismissAfterConversion, let appliedDate {\n                Divider()\n',
          '            if !dismissAfterConversion, let appliedDate {\n                #if DEBUG\n                let _ = PerformanceProbe.recordConversion(places: resultZones.count)\n                #endif\n                Divider()\n')
    path = 'TahoeTime.xcodeproj/project.pbxproj'
    patch(path, '\t\tAB700000000000000000000A /* WindowCloseProbe.swift in Sources */ =',
          '\t\tACF000000000000000000002 /* PerformanceProbe.swift in Sources */ = {isa = PBXBuildFile; fileRef = ACF000000000000000000001 /* PerformanceProbe.swift */; };\n\t\tAB700000000000000000000A /* WindowCloseProbe.swift in Sources */ =')
    patch(path, '\t\tAB7000000000000000000009 /* WindowCloseProbe.swift */ =',
          '\t\tACF000000000000000000001 /* PerformanceProbe.swift */ = {isa = PBXFileReference; path = "TahoeTime/Models/Diagnostics/PerformanceProbe.swift"; sourceTree = SOURCE_ROOT; lastKnownFileType = sourcecode.swift;};\n\t\tAB7000000000000000000009 /* WindowCloseProbe.swift */ =')
    patch(path, '\t\t\t\tAB700000000000000000000A /* WindowCloseProbe.swift in Sources */,\n',
          '\t\t\t\tAB700000000000000000000A /* WindowCloseProbe.swift in Sources */,\n\t\t\t\tACF000000000000000000002 /* PerformanceProbe.swift in Sources */,\n')
    return result


PATHS = ('TahoeTime/Models/ApplicationSession.swift', 'TahoeTime/Models/UITestFixture.swift',
         'TahoeTime/Pro/ProFixture.swift', 'TahoeTime/Models/AppModel.swift',
         'TahoeTime/TahoeTimeApp.swift', 'TahoeTime/Models/RustCore.swift',
         'TahoeTime/Views/WorldMapView.swift', 'TahoeTime/Views/TimeInputView.swift',
         'TahoeTime.xcodeproj/project.pbxproj')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', required=True, help='Untouched scratch worktree at exactly 0924c')
    parser.add_argument('--hook-source', default=str(Path(__file__).resolve().parents[1]),
                        help='Checkout providing the same PerformanceProbe.swift as the new build')
    parser.add_argument('--check', action='store_true', help='Validate and describe planned patch without writing')
    args = parser.parse_args()
    root = Path(args.source).resolve(strict=True)
    if not is_scratch_checkout(root):
        parser.error('The baseline checkout must live in temporary scratch storage')
    if git(root, 'rev-parse', 'HEAD').strip() != BASE:
        parser.error('Baseline HEAD does not match pinned 0924c commit')
    if git(root, 'status', '--porcelain').strip():
        parser.error('Baseline worktree must be untouched before applying instrumentation')
    if (root / PROBE).exists():
        parser.error('Probe already exists; refusing a second overlay')
    originals = {}
    for path in PATHS:
        expected = git(root, 'show', BASE + ':' + path)
        actual = (root / path).read_text()
        if actual != expected:
            parser.error('Original source differs from pinned commit: ' + path)
        originals[path] = actual
    patched = patch_plan(originals)
    source = Path(args.hook_source).resolve(strict=True)
    probe = (source / PROBE).read_text()
    if not probe.startswith('// SPDX-License-Identifier: GPL-3.0-only\n#if DEBUG\n'):
        parser.error('Shared probe is missing the required test-only guards')
    if '#if DAYSIDE_PERF_LEGACY' not in probe:
        parser.error('Shared probe does not support the baseline parser capability')
    manifest = dict(base_commit=BASE, shared_probe_sha256=hashlib.sha256(probe.encode()).hexdigest(),
        patched_files={path: dict(before_sha256=hashlib.sha256(originals[path].encode()).hexdigest(),
                                after_sha256=hashlib.sha256(patched[path].encode()).hexdigest()) for path in PATHS},
        new_files=[PROBE], required_swift_flags=['DEBUG', 'MEANTIME_MAIN_APP', 'DAYSIDE_PRO', 'DAYSIDE_PERF_LEGACY'],
        limitations=['understand absent in 0924c and reported N/A',
                     'Release optimization with DEBUG test-host guards, not stock Release',
                     '0924c motion gate exists only in AppModel; no SwiftUI environment override needed',
                     'existing old converter automatically jumps after parsing; production behavior preserved',
                     'CoreSpotlight named disposable index; existing index untouched',
                     'poster copied to private pasteboard; system clipboard untouched'])
    if not args.check:
        # 所有原文和替换点先核完，再只写测试宿主接线。
        for path in PATHS:
            (root / path).write_text(patched[path])
        (root / PROBE).write_text(probe)
        (root / '.perf-overlay.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps(dict(applied=not args.check, **manifest), indent=2))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        raise SystemExit('Baseline overlay refused: ' + str(exc))
