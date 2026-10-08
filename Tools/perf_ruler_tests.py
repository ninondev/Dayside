#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# 合成记录只验证量尺解析，不作性能证据。
import unittest
import perf_ruler as ruler


class RulerTests(unittest.TestCase):
    def samples(self):
        return [dict(uptime=i, fp=(10 + i) * ruler.MIB, rss=(30 + i) * ruler.MIB,
                     peak=999 * ruler.MIB, cpu_ns=i * 1000000, idlewake=i, wake=i * 2)
                for i in range(64)]

    def event(self, kind, phase='active', uptime=0, **fields):
        return dict(event=kind, phase=phase, uptime=uptime, scenario='idle', **fields)

    def test_phase_peak_does_not_inherit_lifetime_peak(self):
        result = ruler.phase_result(self.event('begin'), self.event('end', uptime=60), self.samples())
        self.assertEqual(result['peak_footprint_mib'], 70)
        self.assertEqual(result['cpu_seconds'], .06)
        self.assertEqual(result['idle_wakeups_per_minute'], 60)
        self.assertIsNone(result['gpu_kernel_units'])

    def test_boundary_kernel_counters_take_precedence(self):
        begin = self.event('begin', meter='fp=10485760 cpu_ns=15000000 idlewake=2 gpu=900 energy_nj=1000')
        end = self.event('end', uptime=60, meter='fp=10485760 cpu_ns=95000000 idlewake=7 gpu=920 energy_nj=1001000')
        result = ruler.phase_result(begin, end, self.samples())
        self.assertEqual(result['cpu_seconds'], .08)
        self.assertEqual(result['idle_wakeups_per_minute'], 5)
        self.assertEqual(result['gpu_kernel_units'], 20)
        self.assertEqual(result['energy_millijoules'], 1)

    def test_invalid_or_missing_readings_are_not_zero(self):
        for raw in ('cpu_ns=-1', 'gpu=nan'):
            # 字符串解析只接受内核的非负整数；格式坏时字段不可用。
            self.assertNotIn('cpu_ns' if raw.startswith('cpu') else 'gpu', ruler.meter_fields(dict(meter=raw)))
        with self.assertRaises(ValueError):
            ruler.meter_fields(dict(metrics={'fp': float('nan')}))
        with self.assertRaises(ValueError):
            ruler.phase_result(self.event('begin', metrics={'cpu_ns': 10}),
                               self.event('end', uptime=60, metrics={'cpu_ns': 9}), self.samples())
        with self.assertRaises(ValueError):
            ruler.phase_result(self.event('begin'), self.event('end', uptime=5), self.samples())

    def test_fixture_and_motion_acknowledgment_required(self):
        events = [self.event('ready', protocol=1, places=5, people=3, reduceMotion=False, fixtureHash='synthetic-test-only'),
                  self.event('begin'), self.event('end', uptime=60)]
        self.assertIn('active', ruler.parse_events(events, self.samples(), 'idle'))
        for key, value in [('places', 0), ('reduceMotion', True), ('protocol', 2)]:
            altered = [dict(events[0], **{key: value}), *events[1:]]
            with self.assertRaises(ValueError):
                ruler.parse_events(altered, self.samples(), 'idle')

    def test_missing_post_close_and_duplicate_phase_fail(self):
        events = [self.event('ready', protocol=1, places=5, people=3, reduceMotion=False, fixtureHash='synthetic-test-only'),
                  self.event('begin'), self.event('end', uptime=60)]
        with self.assertRaises(ValueError):
            ruler.parse_events(events, self.samples(), 'panel')
        with self.assertRaises(ValueError):
            ruler.parse_events(events + [self.event('begin')], self.samples(), 'idle')

    def test_fixture_identity_is_compared_within_each_scenario(self):
        idle = dict(places=5, people=3, fixtureHash='live-idle-policy')
        surfaces = dict(places=5, people=3, fixtureHash='closed-fixed-policy')
        runs = [dict(status='valid', scenario='idle', metadata=idle)]
        ruler.validate_fixture_consistency(runs, 'surfaces', surfaces)
        runs.append(dict(status='valid', scenario='surfaces', metadata=surfaces))
        ruler.validate_fixture_consistency(runs, 'surfaces', dict(surfaces))
        for field, value in [('places', 4), ('people', 0), ('fixtureHash', 'different-data')]:
            with self.assertRaises(ValueError):
                ruler.validate_fixture_consistency(runs, 'surfaces', dict(surfaces, **{field: value}))

    def test_medians_spread_and_partial_not_reported_as_complete(self):
        runs = [dict(build='old', scenario='idle', status='valid', phases={'active':
            dict(cpu_seconds=i, peak_footprint_mib=12)}) for i in (4, 1, 2)]
        summary = ruler.aggregate(runs, 3)['idle/active']['old']
        self.assertEqual(summary['metrics']['cpu_seconds']['median'], 2)
        self.assertEqual(summary['metrics']['cpu_seconds']['spread'], 3)
        self.assertTrue(summary['metrics']['cpu_seconds']['complete'])
        partial = ruler.aggregate(runs[:1], 3)['idle/active']['old']
        self.assertFalse(partial['metrics']['cpu_seconds']['complete'])
        invalid = dict(runs[0], status='invalid')
        self.assertEqual(ruler.aggregate([invalid], 3)['idle/active']['old']['valid_runs'], 0)

    def test_monotonic_nanosecond_event_clock(self):
        self.assertEqual(ruler.event_uptime(dict(monotonic_ns=1234567890)), 1.23456789)

    def test_unavailable_scenario_still_has_table_row(self):
        runs = [dict(build='old', scenario='understand', status='unavailable', phases={}, repeat=1)]
        summary = ruler.aggregate(runs, 3)
        self.assertIn('understand/active', summary)
        self.assertIn('N/A', ruler.markdown(summary, runs))

    def test_foreground_and_animation_evidence_are_required(self):
        events = [self.event('ready', protocol=1, places=5, people=3, reduceMotion=False, fixtureHash='synthetic-test-only'),
                  self.event('begin'), self.event('end', uptime=60)]
        for scenario in ('earth', 'cold-convert', 'tools-tour', 'panel'):
            with self.assertRaises(ValueError):
                ruler.parse_events(events, self.samples(), scenario)

    def test_only_documented_old_understand_absence_can_succeed(self):
        absence = dict(status='unavailable', build='old', scenario='understand', capability='engineAbsent')
        self.assertEqual(ruler.exit_code([absence]), 0)
        self.assertEqual(ruler.exit_code([dict(absence, build='new')]), 2)
        self.assertEqual(ruler.exit_code([dict(absence, scenario='converter')]), 2)
        self.assertEqual(ruler.exit_code([dict(absence, capability=None)]), 2)
        self.assertEqual(ruler.exit_code([dict(absence, status='invalid')]), 2)
        self.assertEqual(ruler.exit_code([dict(status='valid'), absence]), 0)

    def complete_window_events(self, scenario, checkpoints):
        events = [dict(self.event('ready', protocol=1, places=5, people=3, reduceMotion=False,
                                 fixtureHash='synthetic-test-only'), scenario=scenario),
                  dict(self.event('begin'), scenario=scenario),
                  *[dict(event='checkpoint', scenario=scenario, **c) for c in checkpoints],
                  dict(self.event('end', uptime=60), scenario=scenario),
                  dict(self.event('begin', phase='post-close', uptime=61), scenario=scenario),
                  dict(self.event('end', phase='post-close', uptime=121), scenario=scenario)]
        samples = [dict(uptime=i, fp=10 * ruler.MIB, rss=30 * ruler.MIB,
                        cpu_ns=i * 1000000, idlewake=i, wake=i) for i in range(122)]
        return events, samples

    def test_all_six_jumps_require_individual_intermediate_frames(self):
        checkpoint = dict(jumps=6, visible=True, front=True, animatedFrames=12, jumpFrames=[2] * 6)
        events, samples = self.complete_window_events('panel', [checkpoint])
        self.assertIn('active', ruler.parse_events(events, samples, 'panel'))
        for frames in ([12], [2] * 5, [2] * 5 + [1], [2] * 5 + [True]):
            altered, samples = self.complete_window_events('panel', [dict(checkpoint, jumpFrames=frames)])
            with self.assertRaises(ValueError):
                ruler.parse_events(altered, samples, 'panel')

    def test_earth_requires_uninterrupted_full_foreground_dwell(self):
        checkpoints = [dict(window='earth', visible=True, front=True),
                       dict(posterPNG=100, posterTIFF=200, visible=True, front=True),
                       dict(earthForegroundSeconds=30, foregroundInterrupted=False, visible=True, front=True)]
        events, samples = self.complete_window_events('earth', checkpoints)
        self.assertIn('active', ruler.parse_events(events, samples, 'earth'))
        for change in ({'earthForegroundSeconds': 29}, {'foregroundInterrupted': True}, {'front': False}):
            altered, samples = self.complete_window_events('earth', checkpoints[:2] + [dict(checkpoints[2], **change)])
            with self.assertRaises(ValueError):
                ruler.parse_events(altered, samples, 'earth')

    def test_spotlight_operation_wall_duration_separate_from_tail(self):
        begin = dict(self.event('begin'), scenario='spotlight')
        end = dict(self.event('end', uptime=60), scenario='spotlight', operation_ns=1000000000)
        values = ruler.phase_result(begin, end, self.samples())
        self.assertEqual(values['operation_seconds'], 1)
        self.assertEqual(values['duration_seconds'], 60)
        for raw in (None, -1, float('nan'), 61000000000, True):
            with self.assertRaises(ValueError):
                ruler.phase_result(begin, dict(end, operation_ns=raw), self.samples())
        runs = [dict(build='new', scenario='spotlight', status='valid',
                     phases={'active': dict(values, operation_seconds=n)}) for n in (3, 1, 2)]
        metric = ruler.aggregate(runs, 3)['spotlight/active']['new']['metrics']['operation_seconds']
        self.assertEqual(metric['median'], 2)
        self.assertEqual(metric['spread'], 2)

    def test_idle_cpu_normalization_preserves_raw_64_second_reading(self):
        samples = [dict(uptime=i, fp=10 * ruler.MIB, rss=30 * ruler.MIB,
                        cpu_ns=i * 1000000, idlewake=i, wake=i) for i in range(66)]
        result = ruler.phase_result(self.event('begin'), self.event('end', uptime=64), samples)
        self.assertEqual(result['duration_seconds'], 64)
        self.assertEqual(result['cpu_seconds'], .064)
        self.assertAlmostEqual(result['cpu_seconds_per_60s'], .060)
        active = ruler.phase_result(dict(self.event('begin'), scenario='converter'),
                                    dict(self.event('end', uptime=64), scenario='converter'), samples)
        self.assertIsNone(active['cpu_seconds_per_60s'])
        post = ruler.phase_result(dict(self.event('begin', phase='post-close'), scenario='panel'),
                                  dict(self.event('end', phase='post-close', uptime=64), scenario='panel'), samples)
        self.assertAlmostEqual(post['cpu_seconds_per_60s'], .060)

    def test_table_exposes_duration_and_derived_rate_medians_ranges(self):
        runs = [dict(build='old', scenario='idle', status='valid', repeat=i,
                     phases={'active': dict(duration_seconds=n, cpu_seconds=n / 1000,
                                            cpu_seconds_per_60s=.060)}) for i, n in enumerate((60, 64, 62), 1)]
        summary = ruler.aggregate(runs, 3)
        self.assertEqual(summary['idle/active']['old']['metrics']['duration_seconds']['median'], 62)
        self.assertEqual(summary['idle/active']['old']['metrics']['duration_seconds']['spread'], 4)
        table = ruler.markdown(summary, runs)
        self.assertIn('Actual duration s', table)
        self.assertIn('CPU / 60 s (idle)', table)
        self.assertIn('62.0000 [60.0000, 64.0000]', table)
        self.assertIn('0.0620 [0.0600, 0.0640]', table)

    def test_optional_receipts_are_discoverable_without_required_layout(self):
        import tempfile
        from pathlib import Path
        with tempfile.TemporaryDirectory() as folder:
            app = Path(folder) / 'Synthetic.app'
            missing = ruler.discover_provenance(app)
            self.assertTrue(all(v['status'] == 'missing' for v in missing.values()))
            (app.parent / 'source-commit.txt').write_text('synthetic-test-only\n')
            (app.parent / 'source-overlay.patch').write_text('synthetic patch\n')
            (app.parent / 'executable-sha256.txt').write_text('synthetic sha\n')
            (app.parent / 'build-flags.txt').write_text('SYNTHETIC_FLAGS\n')
            receipts = ruler.discover_provenance(app)
            self.assertTrue(all(v['status'] == 'present' for v in receipts.values()))
            self.assertEqual(receipts['source_commit']['value'], 'synthetic-test-only')
            self.assertIn('sha256', receipts['source_overlay'])
            self.assertNotIn('value', receipts['source_overlay'])
            self.assertEqual(receipts['build_flags']['value'], 'SYNTHETIC_FLAGS')

    def test_first_understand_snapshot_excludes_observation_tail_reclamation(self):
        begin = self.event('begin', metrics=dict(rss=30 * ruler.MIB, fp=10 * ruler.MIB))
        checkpoint = self.event('checkpoint', uptime=.01,
                                metrics=dict(rss=35 * ruler.MIB, fp=13 * ruler.MIB))
        first = ruler.first_call_result(begin, checkpoint)
        self.assertEqual(first['first_call_resident_delta_mib'], 5)
        self.assertEqual(first['first_call_footprint_delta_mib'], 3)
        self.assertEqual(first['first_call_capture_seconds'], .01)
        end = self.event('end', uptime=2, metrics=dict(rss=28 * ruler.MIB, fp=9 * ruler.MIB))
        tail = ruler.phase_result(dict(begin, scenario='understand'), dict(end, scenario='understand'), self.samples())
        self.assertEqual(tail['resident_delta_mib'], -2)
        self.assertEqual(tail['footprint_delta_mib'], -1)
        self.assertEqual(first['first_call_resident_delta_mib'], 5)

    def test_first_call_memory_boundaries_and_order_are_required(self):
        begin = self.event('begin', metrics=dict(rss=30 * ruler.MIB, fp=10 * ruler.MIB))
        with self.assertRaises(ValueError):
            ruler.first_call_result(begin, self.event('checkpoint', uptime=.01, metrics={'fp': ruler.MIB}))
        with self.assertRaises(ValueError):
            ruler.first_call_result(dict(begin, uptime=2), self.event('checkpoint', uptime=1,
                                    metrics=dict(rss=30 * ruler.MIB, fp=10 * ruler.MIB)))
        signed = ruler.first_call_result(begin, self.event('checkpoint', uptime=.01,
                                       metrics=dict(rss=29 * ruler.MIB, fp=9 * ruler.MIB)))
        self.assertEqual(signed['first_call_resident_delta_mib'], -1)
        self.assertEqual(signed['first_call_footprint_delta_mib'], -1)

    def test_understand_parser_aggregates_immediate_call_separately(self):
        metadata = self.event('ready', protocol=1, places=5, people=3, reduceMotion=False, fixtureHash='synthetic-test-only')
        begin = self.event('begin', metrics=dict(rss=30 * ruler.MIB, fp=10 * ruler.MIB))
        checkpoint = self.event('checkpoint', uptime=.01, input='9:00', mentions=1, cityIndexNeeded=False,
                                metrics=dict(rss=35 * ruler.MIB, fp=13 * ruler.MIB))
        end = self.event('end', uptime=2, metrics=dict(rss=28 * ruler.MIB, fp=9 * ruler.MIB))
        events = [dict(e, scenario='understand') for e in (metadata, begin, checkpoint, end)]
        phases = ruler.parse_events(events, self.samples(), 'understand')
        self.assertEqual(phases['active']['first_call_resident_delta_mib'], 5)
        self.assertEqual(phases['active']['resident_delta_mib'], -2)
        runs = [dict(build='new', scenario='understand', status='valid', repeat=i,
                     phases={'active': dict(phases['active'], first_call_resident_delta_mib=n)})
                for i, n in enumerate((5, 7, 6), 1)]
        summary = ruler.aggregate(runs, 3)
        metric = summary['understand/active']['new']['metrics']['first_call_resident_delta_mib']
        self.assertEqual(metric['median'], 6)
        self.assertEqual(metric['spread'], 2)
        table = ruler.markdown(summary, runs)
        self.assertIn('First-call capture s', table)
        self.assertIn('6.0000 [5.0000, 7.0000]', table)

    def test_converter_uses_shared_existing_fixture_transport_only(self):
        inherited = {'MEANTIME_UI_TEST_CONVERT_TEXT': 'inherited unrelated sample',
                     'MEANTIME_UI_TEST_FIXTURE': 'empty', 'MEANTIME_TEST_HOST': '0', 'PATH': '/synthetic-path'}
        converter = ruler.measurement_environment('converter', '/synthetic/events.jsonl', inherited=inherited)
        self.assertEqual(converter['MEANTIME_UI_TEST_CONVERT_TEXT'], '2026-10-04 09:00')
        self.assertEqual(converter['MEANTIME_UI_TEST_FIXTURE'], 'store')
        self.assertEqual(converter['MEANTIME_TEST_HOST'], '1')
        self.assertEqual(converter['MEANTIME_PERF_COUNTS'], '0')
        self.assertEqual(converter['PATH'], '/synthetic-path')
        for scenario in ruler.SCENARIOS:
            if scenario != 'converter':
                env = ruler.measurement_environment(scenario, '/synthetic/events.jsonl', inherited=inherited)
                self.assertNotIn('MEANTIME_UI_TEST_CONVERT_TEXT', env)
        diagnostics = ruler.measurement_environment('converter', '/synthetic/events.jsonl', True, inherited)
        self.assertEqual(diagnostics['MEANTIME_PERF_COUNTS'], '1')
        self.assertEqual(diagnostics['MEANTIME_UI_TEST_CONVERT_TEXT'], converter['MEANTIME_UI_TEST_CONVERT_TEXT'])

    def test_post_close_diagnostics_selection_and_environment_preserve_primary(self):
        ruler.validate_diagnostic_selection(True, 'post-close', ruler.POST_CLOSE_SCENARIOS)
        for scenario in ruler.POST_CLOSE_SCENARIOS:
            env = ruler.measurement_environment(scenario, '/synthetic/events', True,
                                               diagnostic_phase='post-close')
            self.assertEqual(env['MEANTIME_PERF_COUNTS'], '1')
            self.assertEqual(env['MEANTIME_PERF_DIAGNOSTICS'], '0')
        for diagnostics, phase, scenarios in [(False, 'post-close', ('panel',)),
                                              (True, 'post-close', ruler.SCENARIOS),
                                              (True, 'post-close', ('cold-convert',)),
                                              (True, 'post-close', ()), (True, 'unknown', ('panel',))]:
            with self.assertRaises(ValueError):
                ruler.validate_diagnostic_selection(diagnostics, phase, scenarios)
        for scenario in ruler.SCENARIOS:
            primary = ruler.measurement_environment(scenario, '/synthetic/events')
            active = ruler.measurement_environment(scenario, '/synthetic/events', True)
            self.assertEqual(primary['MEANTIME_PERF_COUNTS'], '0')
            self.assertEqual(primary['MEANTIME_PERF_DIAGNOSTICS'], '0')
            self.assertEqual(active['MEANTIME_PERF_COUNTS'], '1')
            self.assertEqual(active['MEANTIME_PERF_DIAGNOSTICS'], '1')

    def test_diagnostic_target_requires_exact_end_and_one_capture(self):
        target = ruler.DiagnosticTarget('post-close')
        for event in [dict(event='complete'), dict(event='end', phase='active'),
                      dict(event='begin', phase='post-close'), dict(event='checkpoint', diagnosticsReady=True)]:
            self.assertFalse(target.accept(event))
        with self.assertRaises(ValueError):
            target.require_complete()
        end = dict(event='end', phase='post-close')
        self.assertTrue(target.accept(end))
        target.require_complete()
        with self.assertRaises(ValueError):
            target.accept(end)
        active = ruler.DiagnosticTarget('active')
        self.assertFalse(active.accept(end))
        self.assertTrue(active.accept(dict(event='checkpoint', diagnosticsReady=True)))
        active.require_complete()

    def test_diagnostic_receipts_keep_end_anchor_times_and_one_region_attempt(self):
        import json
        from pathlib import Path
        import tempfile
        from unittest.mock import patch
        class Process:
            pid = 12345
            def poll(self):
                return None
        class Meter:
            def read(self, pid):
                return dict(uptime=100, fp=12 * ruler.MIB, rss=34 * ruler.MIB)
        calls = []
        def fake_bounded(program, arguments, timeout):
            calls.append((program, arguments, timeout))
            return dict(status=1 if program.endswith(('vmmap', 'heap')) else 0,
                        stdout='synthetic diagnostic receipt', stderr='synthetic failure')
        event = dict(event='end', phase='post-close', uptime=60, scenario='panel',
                     meter='fp=10485760 rss=31457280', rustCalls={'solar': 7})
        with tempfile.TemporaryDirectory() as temporary, patch.object(ruler, 'bounded', fake_bounded):
            folder = Path(temporary)
            attempted, capture = ruler.capture_diagnostics(Process(), folder, 'post-close', event,
                                                           Meter(), True, False)
            self.assertTrue(attempted)
            self.assertEqual(capture['target_event'], event)
            self.assertEqual(capture['target_uptime'], 60)
            self.assertEqual(capture['phase'], 'post-close')
            self.assertEqual(capture['before_capture']['counters']['fp'], 12 * ruler.MIB)
            self.assertEqual([call[2] for call in calls], [6, 6, 6, 2])
            self.assertEqual(calls[3][1][-2:], ['--pid', '12345'])
            for name in ('vmmap', 'heap', 'sample'):
                receipt = json.loads((folder / (name + '-post-close.json')).read_text())
                self.assertLessEqual(receipt['capture_start_uptime'], receipt['capture_end_uptime'])
                self.assertIn('before_meter', receipt)
                self.assertIn('after_meter', receipt)
            self.assertEqual(json.loads((folder / 'vmmap-post-close.json').read_text())['status'], 1)
            self.assertTrue((folder / 'regions-fallback-post-close.json').exists())
            self.assertFalse((folder / 'regions-fallback.json').exists())
            self.assertTrue((folder / 'diagnostic-capture.json').exists())
            ruler.capture_diagnostics(Process(), folder, 'active', dict(event, phase='active'), Meter(), True, attempted)
            self.assertEqual(sum(call[0] == '/usr/bin/env' for call in calls), 1)
            self.assertTrue((folder / 'vmmap-active.json').exists())

    def test_diagnostics_never_query_an_exited_owned_process(self):
        from pathlib import Path
        import tempfile
        from unittest.mock import patch
        class Process:
            pid = 12345
            def poll(self):
                return 0
        with tempfile.TemporaryDirectory() as temporary, patch.object(ruler, 'bounded') as command:
            with self.assertRaises(ValueError):
                ruler.capture_diagnostics(Process(), Path(temporary), 'post-close',
                    dict(event='end', phase='post-close', uptime=60), None, True, False)
            command.assert_not_called()

    def test_wrappers_keep_persistent_lock_and_reject_synthetic_flag_loss(self):
        from pathlib import Path
        import shlex
        prefix = ['/usr/bin/lockf', '-k', '-t', '3600', '$coordination_root/cpu-turn.lock', 'nice', '-n', '10']
        def check(source):
            lines = [line.strip().rstrip(' \\') for line in source.splitlines()
                     if line.strip().startswith('/usr/bin/lockf ')]
            self.assertEqual(len(lines), 1)
            self.assertEqual(shlex.split(lines[0]), prefix)
        for filename in ('perf_ruler.sh',):
            source = Path(__file__).with_name(filename).read_text()
            check(source)
            with self.assertRaises(AssertionError):
                check(source.replace('/usr/bin/lockf -k -t', '/usr/bin/lockf -t'))
            self.assertNotIn('SECONDS - start', source)

    def test_wrapper_queue_retries_only_before_payload_start_without_shared_access(self):
        from pathlib import Path
        import re
        import subprocess
        import tempfile
        for filename in ('perf_ruler.sh',):
            source = Path(__file__).with_name(filename).read_text()
            helper = re.search(r'^run_queued_under_cpu_lock\(\) \{\n.*?^\}', source, re.M | re.S).group()
            for mode, expected_status, expected_calls in [('unstarted-timeout', 0, 2),
                                                         ('started-timeout', 75, 1),
                                                         ('other-failure', 7, 1)]:
                with tempfile.TemporaryDirectory() as temporary:
                    script = helper + '''
cat() { printf 'FREE\\n'; }
dayside_measurement_state() { printf 'FREE\\n'; }
sleep() { echo 'Unexpected state wait' >&2; return 99; }
calls=0
payload() {
  calls=$((calls + 1))
  case "$mode" in
    unstarted-timeout) if (( calls == 1 )); then return 75; fi; printf 'started\\n' > "$marker"; return 0 ;;
    started-timeout) printf 'started\\n' > "$marker"; return 75 ;;
    other-failure) return 7 ;;
  esac
}
marker=$1; mode=$2
run_queued_under_cpu_lock "$marker" payload
status=$?
printf '%s %s\\n' "$status" "$calls"
exit "$status"
'''
                    result = subprocess.run(['/bin/bash', '-c', script, 'synthetic-queue-test',
                                             str(Path(temporary) / 'marker'), mode],
                                            capture_output=True, text=True, timeout=2)
                    self.assertEqual(result.returncode, expected_status)
                    self.assertEqual(result.stdout.strip(), f'{expected_status} {expected_calls}')

    def test_structure_matches_v4_sdk(self):
        self.assertEqual(len(ruler.RUSAGE_FIELDS), 35)
        self.assertEqual(ruler.ctypes.sizeof(ruler.Rusage), 16 + 35 * 8)

    def test_table_distinguishes_sampled_rss_from_footprint_boundaries(self):
        begin = self.event('begin', metrics=dict(rss=150 * ruler.MIB, fp=90 * ruler.MIB))
        end = self.event('end', uptime=60, metrics=dict(rss=160 * ruler.MIB, fp=100 * ruler.MIB))
        phase = ruler.phase_result(begin, end, self.samples())
        self.assertEqual(phase['peak_rss_mib'], 90)
        self.assertEqual(phase['end_rss_mib'], 160)
        self.assertEqual(phase['peak_footprint_mib'], 100)
        runs = [dict(build='new', scenario='idle', status='valid', repeat=i,
                     phases={'active': phase}) for i in range(1, 4)]
        table = ruler.markdown(ruler.aggregate(runs, 3), runs)
        self.assertIn('RSS sampled peak / end MiB', table)
        self.assertIn('Footprint sampled+boundary peak / end MiB', table)
        self.assertIn('can be lower than the end reading', table)
        self.assertIn('90.0000 [90.0000, 90.0000] / 160.0000 [160.0000, 160.0000]', table)

    def test_diagnostic_capture_stops_tool_queries_when_owned_preview_exits(self):
        from pathlib import Path
        import tempfile
        from unittest.mock import patch
        class Process:
            pid, alive = 12345, True
            def poll(self):
                return None if self.alive else 0
        class Meter:
            def read(self, pid):
                return dict(uptime=100, fp=12 * ruler.MIB, rss=34 * ruler.MIB)
        proc, calls = Process(), []
        def exits_during_vmmap(program, arguments, timeout):
            calls.append(program)
            proc.alive = False
            return dict(status=1, stdout='', stderr='synthetic process exit')
        with tempfile.TemporaryDirectory() as temporary, patch.object(ruler, 'bounded', exits_during_vmmap):
            folder = Path(temporary)
            with self.assertRaises(ValueError):
                ruler.capture_diagnostics(proc, folder, 'post-close',
                    dict(event='end', phase='post-close', uptime=60), Meter(), True, False)
            self.assertEqual(calls, ['/usr/bin/vmmap'])
            self.assertTrue((folder / 'heap-post-close.json').exists())
            self.assertTrue((folder / 'regions-fallback-post-close.json').exists())
            self.assertTrue((folder / 'diagnostic-capture.json').exists())

    def test_wrapper_queue_waits_through_timed_state_without_real_state_reads(self):
        from pathlib import Path
        import re
        import subprocess
        import tempfile
        for filename in ('perf_ruler.sh',):
            helper = re.search(r'^run_queued_under_cpu_lock\(\) \{\n.*?^\}',
                              Path(__file__).with_name(filename).read_text(), re.M | re.S).group()
            script = helper + '''
marker=$1; state_counter=$2; sleeps=0; calls=0
dayside_measurement_state() { printf 'FREE\\n'; }
cat() {
  local n=0
  if [[ -f "$state_counter" ]]; then read -r n < "$state_counter"; fi
  n=$((n + 1)); printf '%s\\n' "$n" > "$state_counter"
  if (( n <= 2 )); then printf 'TIMED\\n'; else printf 'FREE\\n'; fi
}
sleep() { [[ "$1" == 5 ]] || return 99; sleeps=$((sleeps + 1)); }
payload() { calls=$((calls + 1)); printf 'started\\n' > "$marker"; }
run_queued_under_cpu_lock "$marker" payload
status=$?; printf '%s %s %s\\n' "$status" "$calls" "$sleeps"; exit "$status"
'''
            with tempfile.TemporaryDirectory() as temporary:
                result = subprocess.run(['/bin/bash', '-c', script, 'synthetic-state-test',
                                         str(Path(temporary) / 'marker'), str(Path(temporary) / 'state')],
                                        capture_output=True, text=True, timeout=2)
                self.assertEqual(result.returncode, 0)
                self.assertEqual(result.stdout.strip(), '0 1 2')

    def test_builds_run_nicely_without_the_measurement_lock_or_state_wait(self):
        from pathlib import Path
        source = Path(__file__).with_name('perf_build.sh').read_text()
        self.assertNotIn('/usr/bin/lockf', source)
        self.assertNotIn('measure.state', source)
        self.assertIn('nice -n 10', source)
        self.assertIn('-jobs 3', source)

    def test_wrapper_waits_for_the_same_screen_pause_file_as_the_monitor(self):
        from pathlib import Path
        import re
        import subprocess
        import tempfile
        source = Path(__file__).with_name('perf_ruler.sh').read_text()
        self.assertIn('source "$root/Tools/test_screen_guard.sh"', source)
        helper = re.search(r'^run_queued_under_cpu_lock\(\) \{\n.*?^\}', source, re.M | re.S).group()
        script = helper + '''
marker=$1; state_counter=$2; sleeps=0; calls=0
dayside_measurement_state() {
  local n=0
  if [[ -f "$state_counter" ]]; then read -r n < "$state_counter"; fi
  n=$((n + 1)); printf '%s\\n' "$n" > "$state_counter"
  if (( n <= 2 )); then printf 'PAUSED\\n'; else printf 'FREE\\n'; fi
}
cat() { printf 'FREE\\n'; }
sleep() { [[ "$1" == 5 ]] || return 99; sleeps=$((sleeps + 1)); }
payload() { calls=$((calls + 1)); printf 'started\\n' > "$marker"; }
run_queued_under_cpu_lock "$marker" payload
status=$?; printf '%s %s %s\\n' "$status" "$calls" "$sleeps"; exit "$status"
'''
        with tempfile.TemporaryDirectory() as temporary:
            result = subprocess.run(['/bin/bash', '-c', script, 'synthetic-screen-state-test',
                                     str(Path(temporary) / 'marker'), str(Path(temporary) / 'state')],
                                    capture_output=True, text=True, timeout=2)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(result.stdout.strip(), '0 1 2')

    def test_ruler_command_marker_failure_prevents_payload_execution(self):
        from pathlib import Path
        import re
        import subprocess
        import tempfile
        source = Path(__file__).with_name('perf_ruler.sh').read_text()
        adapter = re.search(r"/bin/bash -c '([^']+)'", source).group(1)
        with tempfile.TemporaryDirectory() as temporary:
            result = subprocess.run(['/bin/bash', '-c', adapter, 'synthetic-start-test',
                                     str(Path(temporary) / 'missing' / 'marker'),
                                     '/bin/bash', '-c', "printf 'payload executed'"],
                                    capture_output=True, text=True, timeout=2)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('payload executed', result.stdout)

    def test_strict_idle_gate_ignores_present_flag_and_rejects_bad_readings(self):
        from pathlib import Path
        import os
        import subprocess
        import tempfile
        with tempfile.TemporaryDirectory() as temporary:
            flag = Path(temporary) / 'present'
            flag.touch()
            gate = Path(__file__).with_name('owner_away.sh')
            for idle, expected in [('300000000000', 0), ('299999999999', 75),
                                   ('bad', 75), ('READ_ERROR', 75),
                                   ('18446744073709551616', 75)]:
                environment = dict(os.environ, DAYSIDE_OWNER_AWAY_TEST_FLAG=str(flag),
                                   DAYSIDE_OWNER_AWAY_TEST_HID_IDLE_NS=idle)
                result = subprocess.run(['/bin/bash', str(gate), '--unit-test-strict-check'],
                                        env=environment, capture_output=True, timeout=2)
                self.assertEqual(result.returncode, expected, idle)
            result = subprocess.run(['/bin/bash', str(gate), '--unit-test-check'],
                                    env=environment, capture_output=True, timeout=2)
            self.assertEqual(result.returncode, 0)


    def test_native_completion_memory_math_preserves_units_and_signed_release(self):
        end = dict(event='end', scenario='earth', phase='post-close', uptime_ns=123000000000,
                   metrics=dict(fp=100 * ruler.MIB, rss=200 * ruler.MIB))
        complete = dict(event='complete', scenario='earth', phase=None, uptime_ns=123012500000,
                        meter=f'fp={83 * ruler.MIB} rss={180 * ruler.MIB}')
        result = ruler.native_completion_result(end, complete, 'earth')
        self.assertEqual(result['native_complete_footprint_mib'], 83)
        self.assertEqual(result['native_complete_rss_mib'], 180)
        self.assertEqual(result['native_complete_delay_seconds'], .0125)
        self.assertEqual(result['native_complete_footprint_release_mib'], 17)
        self.assertEqual(result['native_complete_rss_release_mib'], 20)
        self.assertEqual(result['native_completion_status'], 'valid')
        self.assertEqual(result['native_completion_source'], 'hook-native-end-and-complete')
        for fp, rss, release in [(100, 200, 0), (101, 201, -1)]:
            later = dict(complete, uptime_ns=end['uptime_ns'], meter=f'fp={fp * ruler.MIB} rss={rss * ruler.MIB}')
            signed = ruler.native_completion_result(end, later, 'earth')
            self.assertEqual(signed['native_complete_footprint_release_mib'], release)
            self.assertEqual(signed['native_complete_rss_release_mib'], release)
            self.assertEqual(signed['native_complete_delay_seconds'], 0)
        alias_end = {key: value for key, value in end.items() if key != 'uptime_ns'}
        alias_complete = {key: value for key, value in complete.items() if key != 'uptime_ns'}
        alias_end['monotonic_ns'], alias_complete['monotonic_ns'] = end['uptime_ns'], complete['uptime_ns']
        self.assertEqual(ruler.native_completion_result(alias_end, alias_complete, 'earth')['native_completion_clock'],
                         'monotonic_ns')

    def test_native_completion_rejects_identity_clock_and_byte_counter_errors(self):
        end = dict(event='end', scenario='panel', phase='post-close', uptime_ns=60000000000,
                   metrics=dict(fp=100 * ruler.MIB, rss=200 * ruler.MIB))
        complete = dict(event='complete', scenario='panel', uptime_ns=60001000000,
                        metrics=dict(fp=90 * ruler.MIB, rss=180 * ruler.MIB))
        cases = [(dict(end, event='begin'), complete, 'panel'),
                 (dict(end, phase='active'), complete, 'panel'),
                 (dict(end, scenario='earth'), complete, 'panel'),
                 (end, dict(complete, event='done'), 'panel'),
                 (end, dict(complete, phase='active'), 'panel'),
                 (end, dict(complete, scenario='earth'), 'panel'),
                 (end, complete, 'idle'),
                 (end, dict(complete, uptime_ns=59999999999), 'panel'),
                 (dict(end, monotonic_ns=end['uptime_ns']), complete, 'panel'),
                 (end, {key: value for key, value in complete.items() if key != 'uptime_ns'}, 'panel'),
                 (dict(end, metrics=dict(fp=1)), complete, 'panel')]
        for invalid in (True, -1, 1.5, float('nan'), float('inf'), '60001000000', 2 ** 64):
            cases.append((end, dict(complete, uptime_ns=invalid), 'panel'))
        for key in ('fp', 'rss'):
            for invalid in (True, -1, 1.5, float('nan'), float('inf'), None, '1.5', '1 MiB', 2 ** 64):
                cases.append((end, dict(complete, metrics=dict(complete['metrics'], **{key: invalid})), 'panel'))
        for raw in ('fp=1.5 rss=2', 'fp=1 rss=-2', 'fp=nan rss=2', 'fp=1 rss=2 fp=3', 'fp_mib=1 rss=2'):
            cases.append((end, {key: value for key, value in dict(complete, meter=raw).items() if key != 'metrics'}, 'panel'))
        mixed = {key: value for key, value in complete.items() if key != 'uptime_ns'}
        mixed['monotonic_ns'] = complete['uptime_ns']
        cases.append((end, mixed, 'panel'))
        for first, last, scenario in cases:
            with self.subTest(first=first, last=last, scenario=scenario), self.assertRaises(ValueError):
                ruler.native_completion_result(first, last, scenario)

    def test_native_completion_missing_duplicate_and_order_errors_are_optional(self):
        metadata = self.event('ready', protocol=1, places=5, people=3, reduceMotion=False,
                              fixtureHash='synthetic-test-only')
        checkpoint = self.event('checkpoint', jumps=6, visible=True, animatedFrames=12, jumpFrames=[2] * 6)
        post_end = self.event('end', phase='post-close', uptime=62, uptime_ns=62000000000,
                              metrics=dict(fp=100 * ruler.MIB, rss=200 * ruler.MIB))
        events = [dict(event, scenario='panel') for event in
                  (metadata, self.event('begin'), checkpoint, self.event('end', uptime=1),
                   self.event('begin', phase='post-close', uptime=2), post_end)]
        complete = dict(event='complete', scenario='panel', uptime_ns=62001000000,
                        metrics=dict(fp=90 * ruler.MIB, rss=180 * ruler.MIB))
        missing = ruler.parse_events(events, self.samples(), 'panel')
        valid = ruler.parse_events(events + [complete], self.samples(), 'panel')
        bad = ruler.parse_events(events + [dict(complete, metrics=dict(fp=-1, rss=1))], self.samples(), 'panel')
        old_fields = {key: value for key, value in missing['post-close'].items() if not key.startswith('native_')}
        for result in (valid, bad):
            self.assertEqual({key: value for key, value in result['post-close'].items() if not key.startswith('native_')},
                             old_fields)
        self.assertEqual(missing['post-close']['native_completion_status'], 'unavailable')
        self.assertEqual(bad['post-close']['native_completion_status'], 'unavailable')
        self.assertTrue(bad['post-close']['native_completion_error'])
        self.assertNotIn('native_complete_footprint_mib', bad['post-close'])
        self.assertEqual(valid['post-close']['native_completion_status'], 'valid')
        for malformed in (events, events + [complete, complete], [complete] + events,
                          events + [dict(events[-1]), complete]):
            result = ruler.native_completion_checkpoint(malformed, 'panel')
            self.assertEqual(result['native_completion_status'], 'unavailable')
            self.assertTrue(result['native_completion_error'])
            self.assertFalse(any(key.startswith('native_complete_') for key in result))

    def test_native_completion_aggregate_and_separate_table_keep_original_endpoints(self):
        end = dict(event='end', scenario='panel', phase='post-close', uptime_ns=60000000000,
                   metrics=dict(fp=100 * ruler.MIB, rss=200 * ruler.MIB))
        runs = []
        for repeat, fp in enumerate((80, 90, None), 1):
            complete = dict(event='complete', scenario='panel', uptime_ns=60001000000,
                            metrics=dict(fp=None if fp is None else fp * ruler.MIB, rss=180 * ruler.MIB))
            extra = ruler.native_completion_checkpoint([end, complete], 'panel')
            phase = dict(end_footprint_mib=100, peak_footprint_mib=110, end_rss_mib=200, peak_rss_mib=220,
                         cpu_seconds=.06, duration_seconds=60, **extra)
            runs.append(dict(build='old', repeat=repeat, scenario='panel', status='valid', phases={'post-close': phase}))
        summary = ruler.aggregate(runs, 3)
        original = summary['panel/post-close']['old']
        self.assertEqual(original['valid_runs'], 3)
        self.assertEqual(original['metrics']['end_footprint_mib']['median'], 100)
        memory = original['metrics']['native_complete_footprint_mib']
        self.assertEqual((memory['n'], memory['median'], memory['min'], memory['max'], memory['spread']), (2, 85, 80, 90, 10))
        self.assertFalse(memory['complete'])
        self.assertEqual(original['metrics']['native_complete_footprint_release_mib']['median'], 15)
        table = ruler.markdown(summary, runs)
        self.assertIn('## Native completion after post-close', table)
        self.assertIn('post-case, before the outer Task returns', table)
        self.assertIn('not a settled-idle endpoint', table)
        self.assertIn('| panel/post-close | old | 2 | 85.0000 [80.0000, 90.0000] (partial)', table)
        self.assertIn('Completion evidence unavailable:', table)
        self.assertIn('unsigned integer bytes: fp', table)
        self.assertIn('N/A', table)


if __name__ == '__main__':
    unittest.main()
