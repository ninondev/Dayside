#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Alternating, isolated process measurements; missing readings remain missing."""
import argparse
import ctypes
import hashlib
import json
import math
import os
from pathlib import Path
import plistlib
import re
import signal
import statistics
import subprocess
import sys
import threading
import time

PAGES = ('planner', 'agenda', 'people', 'convert', 'timers', 'dstWatch',
         'astronomy', 'markets', 'travel', 'sharing')
SCENARIOS = ('idle', 'panel', 'tools-tour') + tuple('cold-' + p for p in PAGES) + (
    'earth', 'converter', 'spotlight', 'add-place', 'understand', 'surfaces')
POST_CLOSE_SCENARIOS = ('panel', 'tools-tour', 'earth')
MIB = 1048576
METRICS = ('peak_footprint_mib', 'end_footprint_mib', 'peak_rss_mib', 'end_rss_mib',
           'cpu_seconds', 'idle_wakeups_per_minute', 'interrupt_wakeups_per_minute',
           'energy_millijoules', 'gpu_kernel_units', 'duration_seconds', 'resident_delta_mib', 'footprint_delta_mib', 'operation_seconds', 'cpu_seconds_per_60s',
           'first_call_resident_delta_mib', 'first_call_footprint_delta_mib', 'first_call_capture_seconds',
           'native_complete_footprint_mib', 'native_complete_rss_mib', 'native_complete_delay_seconds',
           'native_complete_footprint_release_mib', 'native_complete_rss_release_mib',
           'begin_footprint_mib', 'begin_rss_mib')
RUSAGE_FIELDS = ('user_time system_time pkg_idle_wkups interrupt_wkups pageins '
    'wired_size resident_size phys_footprint proc_start_abstime proc_exit_abstime '
    'child_user_time child_system_time child_pkg_idle_wkups child_interrupt_wkups '
    'child_pageins child_elapsed_abstime diskio_bytesread diskio_byteswritten '
    'cpu_time_qos_default cpu_time_qos_maintenance cpu_time_qos_background '
    'cpu_time_qos_utility cpu_time_qos_legacy cpu_time_qos_user_initiated '
    'cpu_time_qos_user_interactive billed_system_time serviced_system_time logical_writes '
    'lifetime_max_phys_footprint instructions cycles billed_energy serviced_energy '
    'interval_max_phys_footprint runnable_time').split()


class Rusage(ctypes.Structure):
    _fields_ = [('uuid', ctypes.c_uint8 * 16)] + [(n, ctypes.c_uint64) for n in RUSAGE_FIELDS]


class Timebase(ctypes.Structure):
    _fields_ = [('numer', ctypes.c_uint32), ('denom', ctypes.c_uint32)]


class Meter:
    def __init__(self):
        self.lib = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
        self.lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
        self.lib.proc_pid_rusage.restype = ctypes.c_int
        base = Timebase()
        if self.lib.mach_timebase_info(ctypes.byref(base)) != 0 or not base.denom:
            raise RuntimeError('mach_timebase_info unavailable')
        self.factor = base.numer / base.denom

    def read(self, pid):
        usage = Rusage()
        if self.lib.proc_pid_rusage(pid, 4, ctypes.byref(usage)) != 0:
            raise OSError(ctypes.get_errno(), 'proc_pid_rusage failed')
        return dict(uptime=time.monotonic(), fp=usage.phys_footprint,
                    rss=usage.resident_size, peak=usage.lifetime_max_phys_footprint,
                    cpu_ns=(usage.user_time + usage.system_time) * self.factor,
                    idlewake=usage.pkg_idle_wkups, wake=usage.interrupt_wkups)


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def bounded(program, args=(), timeout=15):
    try:
        proc = subprocess.run([program, *args], capture_output=True, text=True, timeout=timeout)
        return dict(status=proc.returncode, stdout=proc.stdout, stderr=proc.stderr)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return dict(status=None, stdout='', stderr=str(exc))


def discover_provenance(app):
    candidates = dict(source_commit=('source-commit.txt',),
                      source_overlay=('source-overlay.patch',),
                      executable_receipt=('executable-sha256.txt',),
                      build_flags=('build-flags.json', 'build-flags.txt', 'swift-flags.txt'))
    receipts = {}
    for name, filenames in candidates.items():
        path = next((app.parent / f for f in filenames if (app.parent / f).is_file()), None)
        if path is None:
            receipts[name] = dict(status='missing', searched_filenames=list(filenames))
            continue
        try:
            data = path.read_bytes()
            item = dict(status='present', path=str(path.resolve()), sha256=hashlib.sha256(data).hexdigest())
            if name in ('source_commit', 'executable_receipt', 'build_flags'):
                item['value'] = data.decode('utf-8').strip()
            receipts[name] = item
        except (OSError, UnicodeDecodeError) as exc:
            receipts[name] = dict(status='unreadable', path=str(path), error=str(exc))
    return receipts


def validate_app(path):
    app = Path(path).resolve(strict=True)
    if app == Path('/Applications/Dayside.app') or Path('/Applications') in app.parents:
        raise ValueError('Installed applications cannot be measured by this ruler')
    with (app / 'Contents/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    if info.get('CFBundleIdentifier') != 'com.dayside.Dayside.localpreview' or info.get('MTLocalPreview') is not True:
        raise ValueError(f'{app}: independent local preview identity required')
    executable = app / 'Contents/MacOS' / info['CFBundleExecutable']
    verified = bounded('/usr/bin/codesign', ['--verify', '--deep', '--strict', str(app)])
    if verified['status'] != 0:
        raise ValueError(f'{app}: signature verification failed: {verified["stderr"]}')
    return app, executable, dict(path=str(app), bundle_id=info['CFBundleIdentifier'],
        version=info.get('CFBundleShortVersionString'), build=info.get('CFBundleVersion'),
        executable_sha256=hashlib.sha256(executable.read_bytes()).hexdigest(),
        optional_provenance=discover_provenance(app))


def meter_fields(event):
    raw = event.get('metrics', event.get('meter', {}))
    if isinstance(raw, str):
        raw = dict(re.findall(r'([a-z_]+)=([0-9]+)', raw))
    if not isinstance(raw, dict):
        raise ValueError('Boundary meter must be an object or ProcessMeter line')
    result = {}
    for key, value in raw.items():
        try:
            number = float(value)
        except (TypeError, ValueError):
            continue
        if not math.isfinite(number) or number < 0:
            raise ValueError(f'Invalid metric {key}')
        result[key] = number
    return result


def event_uptime(event):
    value = event.get('uptime', event.get('_received_uptime'))
    if 'monotonic_ns' in event:
        value = event['monotonic_ns'] / 1e9
    elif 'uptime_ns' in event:
        value = event['uptime_ns'] / 1e9
    if not isinstance(value, (float, int)) or not math.isfinite(value):
        raise ValueError('Missing event uptime')
    return float(value)


def phase_result(begin, end, samples):
    a, b = meter_fields(begin), meter_fields(end)
    start, stop = event_uptime(begin), event_uptime(end)
    duration = stop - start
    if duration <= 0:
        raise ValueError('Non-positive phase duration')
    interval = [s for s in samples if start <= s['uptime'] <= stop]
    if len(interval) < 2:
        raise ValueError('Insufficient continuous samples')
    # 内核边界计数优先；外部采样是缺字段时的明确替代。
    sources = {}
    def delta(key, scale=1):
        if key in a and key in b:
            first, last = a[key], b[key]
            sources[key] = 'hook-kernel-boundaries'
        elif key in interval[0] and key in interval[-1]:
            first, last = interval[0][key], interval[-1][key]
            sources[key] = 'external-sample-boundaries'
        else:
            sources[key] = 'unavailable'
            return None
        if last < first:
            raise ValueError(f'Cumulative counter decreased: {key}')
        return (last - first) / scale
    result = dict(duration_seconds=duration, sample_count=len(interval),
        begin_footprint_mib=a.get('fp', interval[0]['fp']) / MIB,
        begin_rss_mib=a.get('rss', interval[0]['rss']) / MIB,
        peak_footprint_mib=max([s['fp'] for s in interval] + [a.get('fp', 0), b.get('fp', 0)]) / MIB,
        end_footprint_mib=b.get('fp', interval[-1]['fp']) / MIB,
        peak_rss_mib=max(s['rss'] for s in interval) / MIB,
        end_rss_mib=b.get('rss', interval[-1]['rss']) / MIB,
        resident_delta_mib=(b.get('rss', interval[-1]['rss']) - a.get('rss', interval[0]['rss'])) / MIB,
        footprint_delta_mib=(b.get('fp', interval[-1]['fp']) - a.get('fp', interval[0]['fp'])) / MIB,
        cpu_seconds=delta('cpu_ns', 1e9), idle_wakeups_per_minute=delta('idlewake', duration / 60),
        interrupt_wakeups_per_minute=delta('wake', duration / 60),
        energy_millijoules=delta('energy_nj', 1e6), gpu_kernel_units=delta('gpu'), sources=sources)
    is_idle = begin.get('scenario') == 'idle' or begin.get('phase') in ('post-close', 'idle', 'closed-idle')
    result['cpu_seconds_per_60s'] = (result['cpu_seconds'] * 60 / duration
                                     if is_idle and result['cpu_seconds'] is not None else None)
    operation_ns = end.get('operation_ns')
    result['operation_seconds'] = None
    if operation_ns is not None:
        if (not isinstance(operation_ns, (int, float)) or isinstance(operation_ns, bool)
                or not math.isfinite(operation_ns) or operation_ns <= 0
                or operation_ns / 1e9 > duration):
            raise ValueError('Invalid operation duration')
        result['operation_seconds'] = operation_ns / 1e9
    if begin.get('scenario') == 'spotlight' and result['operation_seconds'] is None:
        raise ValueError('Spotlight operation duration missing')
    if is_idle:
        if duration < 59.5:
            raise ValueError('Idle phase shorter than 60 seconds')
    if begin.get('scenario') == 'earth' and begin.get('phase') == 'active' and duration < 29.5:
        raise ValueError('Earth foreground phase shorter than 30 seconds')
    return result


def first_call_result(begin, checkpoint):
    first, captured = meter_fields(begin), meter_fields(checkpoint)
    if any(key not in first or key not in captured for key in ('rss', 'fp')):
        raise ValueError('Immediate first-call memory boundaries missing')
    duration = event_uptime(checkpoint) - event_uptime(begin)
    if duration < 0:
        raise ValueError('First-call checkpoint precedes active begin')
    return dict(first_call_resident_delta_mib=(captured['rss'] - first['rss']) / MIB,
                first_call_footprint_delta_mib=(captured['fp'] - first['fp']) / MIB,
                first_call_capture_seconds=duration)


def native_completion_result(end, complete, scenario):
    if scenario not in POST_CLOSE_SCENARIOS:
        raise ValueError('Native completion memory supports post-close scenarios only')
    if end.get('event') != 'end' or end.get('phase') != 'post-close':
        raise ValueError('Native completion requires end/post-close')
    if complete.get('event') != 'complete' or complete.get('phase') is not None:
        raise ValueError('Native completion event identity invalid')
    if end.get('scenario') != scenario or complete.get('scenario') != scenario:
        raise ValueError('Native completion scenario identity mismatch')
    clocks = tuple(key for key in ('uptime_ns', 'monotonic_ns') if key in end)
    if len(clocks) != 1 or tuple(key for key in ('uptime_ns', 'monotonic_ns') if key in complete) != clocks:
        raise ValueError('Native completion requires matching native nanosecond clocks')
    clock = clocks[0]
    ticks = [end[clock], complete[clock]]
    if any(not isinstance(value, int) or isinstance(value, bool) or not 0 <= value < 2 ** 64 for value in ticks):
        raise ValueError('Native completion nanosecond clock invalid')
    if ticks[1] < ticks[0]:
        raise ValueError('Native complete precedes post-close end')
    def memory(event):
        raw = event.get('metrics', event.get('meter', {}))
        if isinstance(raw, str):
            fields = re.findall(r'(?:^|\s)(fp|rss)=([^\s]+)', raw)
            if len({key for key, _ in fields}) != len(fields):
                raise ValueError('Duplicate native completion memory counter')
            raw = dict(fields)
        if not isinstance(raw, dict) or any(key not in raw for key in ('fp', 'rss')):
            raise ValueError('Native completion fp/rss counters missing')
        result = {}
        for key in ('fp', 'rss'):
            value = raw[key]
            if isinstance(value, str) and re.fullmatch(r'[0-9]+', value):
                value = int(value)
            if not isinstance(value, int) or isinstance(value, bool) or not 0 <= value < 2 ** 64:
                raise ValueError('Native completion memory counter must be unsigned integer bytes: ' + key)
            result[key] = value
        return result
    before, after = memory(end), memory(complete)
    return dict(native_complete_footprint_mib=after['fp'] / MIB,
                native_complete_rss_mib=after['rss'] / MIB,
                native_complete_delay_seconds=(ticks[1] - ticks[0]) / 1e9,
                native_complete_footprint_release_mib=(before['fp'] - after['fp']) / MIB,
                native_complete_rss_release_mib=(before['rss'] - after['rss']) / MIB,
                native_completion_status='valid', native_completion_clock=clock,
                native_completion_source='hook-native-end-and-complete')


def native_completion_checkpoint(events, scenario):
    try:
        ends = [(i, event) for i, event in enumerate(events)
                if event.get('event') == 'end' and event.get('phase') == 'post-close']
        completes = [(i, event) for i, event in enumerate(events) if event.get('event') == 'complete']
        if len(ends) != 1 or len(completes) != 1:
            raise ValueError('Exactly one post-close end and native complete required')
        if completes[0][0] <= ends[0][0]:
            raise ValueError('Native complete receipt precedes post-close end')
        return native_completion_result(ends[0][1], completes[0][1], scenario)
    except (ValueError, TypeError, OverflowError) as exc:
        return dict(native_completion_status='unavailable', native_completion_error=str(exc))


def aggregate(runs, repeats):
    result = {}
    for run in runs:
        if run['scenario'] != 'surfaces':
            result.setdefault(run['scenario'] + '/active', {})
        for phase, values in run.get('phases', {}).items():
            key = run['scenario'] + '/' + phase
            bucket = result.setdefault(key, {})
            build = bucket.setdefault(run['build'], dict(valid_runs=0, metrics={}))
            if run['status'] == 'valid':
                build['valid_runs'] += 1
                for metric in METRICS:
                    value = values.get(metric)
                    if value is not None:
                        build['metrics'].setdefault(metric, []).append(value)
    for bucket in result.values():
        for build in bucket.values():
            for metric, values in list(build['metrics'].items()):
                build['metrics'][metric] = dict(n=len(values), median=statistics.median(values),
                    min=min(values), max=max(values), spread=max(values) - min(values),
                    complete=len(values) == repeats)
    return result


def markdown(summary, runs):
    lines = ['# Performance ruler output', '',
        'All memory values are MiB (1,048,576 bytes). RSS sampled peak is the maximum of periodic 100 ms samples only and can be lower than the end reading. Footprint sampled+boundary peak includes periodic samples and hook begin/end readings. End readings prefer hook boundaries, with the last interval sample as fallback. Kernel lifetime peaks stay in raw samples and are never reused as interval peaks.',
        'First-call deltas compare the active begin and immediate understand checkpoint. First-call capture time includes hook bookkeeping; it is not pure parser latency.',
        'Actual duration is the kernel-event wall interval. CPU / 60 s is a derived rate shown only for idle and post-close; raw CPU seconds stay unchanged.',
        'GPU values use the kernel task GPU counter; its time/energy unit is unverified. Missing GPU/energy readings are N/A, never zero. App counters exclude WindowServer and system indexing services.', '',
        '| Scenario / phase | Build | Valid runs | Footprint sampled+boundary peak / end MiB | RSS sampled peak / end MiB | Actual duration s | CPU s | CPU / 60 s (idle) | Operation wall s | First-call RSS / footprint delta MiB | First-call capture s | Idle wakeups / min | GPU raw |',
        '|---|---|---:|---|---|---|---|---|---|---|---|---|---|']
    def cell(build, metric):
        val = build['metrics'].get(metric)
        if val is None:
            return 'N/A'
        suffix = '' if val['complete'] else ' (partial)'
        return f'{val["median"]:.4f} [{val["min"]:.4f}, {val["max"]:.4f}]' + suffix
    for key, builds in summary.items():
        for name in ('old', 'new'):
            build = builds.get(name, dict(valid_runs=0, metrics={}))
            lines.append('| ' + ' | '.join([key, name, str(build['valid_runs']),
                cell(build, 'peak_footprint_mib') + ' / ' + cell(build, 'end_footprint_mib'),
                cell(build, 'peak_rss_mib') + ' / ' + cell(build, 'end_rss_mib'),
                cell(build, 'duration_seconds'), cell(build, 'cpu_seconds'),
                cell(build, 'cpu_seconds_per_60s'), cell(build, 'operation_seconds'),
                cell(build, 'first_call_resident_delta_mib') + ' / ' + cell(build, 'first_call_footprint_delta_mib'),
                cell(build, 'first_call_capture_seconds'), cell(build, 'idle_wakeups_per_minute'),
                cell(build, 'gpu_kernel_units')]) + ' |')
    completion_rows = [(key, builds) for key, builds in summary.items() if key.endswith('/post-close')]
    if completion_rows:
        lines += ['', '## Native completion after post-close', '',
            'The native complete snapshot is post-case, before the outer Task returns. It is not a settled-idle endpoint. The original post-close endpoints above stay unchanged. Positive release means end minus complete is positive; negative values mean memory increased. Delay includes return/unwinding and emit bookkeeping. Values are median [min, max]; invalid or missing completion evidence is N/A.', '',
            '| Scenario / phase | Build | Validated captures | Complete footprint / RSS MiB | End-to-complete delay s | Footprint / RSS release MiB |',
            '|---|---|---:|---|---|---|']
        for key, builds in completion_rows:
            for name in ('old', 'new'):
                build = builds.get(name, dict(metrics={}))
                captures = build['metrics'].get('native_complete_footprint_mib', {}).get('n', 0)
                lines.append('| ' + ' | '.join([key, name, str(captures),
                    cell(build, 'native_complete_footprint_mib') + ' / ' + cell(build, 'native_complete_rss_mib'),
                    cell(build, 'native_complete_delay_seconds'),
                    cell(build, 'native_complete_footprint_release_mib') + ' / ' + cell(build, 'native_complete_rss_release_mib')]) + ' |')
        unavailable = [f'- {run["build"]} #{run["repeat"]} {run["scenario"]}: '
                       + run['phases']['post-close'].get('native_completion_error', 'Native completion evidence missing')
                       for run in runs if 'post-close' in run.get('phases', {})
                       and run['phases']['post-close'].get('native_completion_status') != 'valid']
        if unavailable:
            lines += ['', 'Completion evidence unavailable:', ''] + unavailable
    lines += ['', '## Invalid or unavailable runs', '']
    lines += [f'- {r["build"]} #{r["repeat"]} {r["scenario"]}: {r["status"]}: {r.get("error", "")}'
              for r in runs if r['status'] != 'valid'] or ['None.']
    return '\n'.join(lines) + '\n'


def validate_diagnostic_selection(diagnostics, phase, scenarios):
    if phase not in ('active', 'post-close'):
        raise ValueError('Unknown diagnostic phase')
    if phase == 'post-close':
        if not diagnostics:
            raise ValueError('--diagnostic-phase post-close requires --diagnostics')
        if not scenarios or any(s not in POST_CLOSE_SCENARIOS for s in scenarios):
            raise ValueError('Post-close diagnostics require explicit panel, tools-tour, or earth scenarios')


class DiagnosticTarget:
    def __init__(self, phase):
        if phase not in ('active', 'post-close'):
            raise ValueError('Unknown diagnostic phase')
        self.phase, self.captured = phase, False

    def accept(self, event):
        matches = (event.get('diagnosticsReady') is True if self.phase == 'active' else
                   event.get('event') == 'end' and event.get('phase') == 'post-close')
        if matches and self.captured:
            raise ValueError('Duplicate diagnostic target')
        if matches:
            self.captured = True
        return matches

    def require_complete(self):
        if not self.captured:
            raise ValueError('Requested diagnostic target missing')


def diagnostic_meter(proc, meter):
    result = dict(observed_uptime=time.monotonic(), process_alive=proc.poll() is None)
    if result['process_alive']:
        try:
            result['counters'] = meter.read(proc.pid)
        except OSError as exc:
            result['error'] = str(exc)
    else:
        result['error'] = 'Owned preview exited'
    return result


def capture_diagnostics(proc, folder, phase, event, meter, region_fallback, region_attempted):
    if proc.poll() is not None:
        raise ValueError('Owned preview exited before diagnostic capture')
    capture = dict(phase=phase, pid=proc.pid, target_event=dict(event),
                   target_uptime=event_uptime(event), capture_start_uptime=time.monotonic(),
                   before_capture=diagnostic_meter(proc, meter), tools=[])
    memory_tool_failed = False
    for tool, arguments in [('vmmap', ['--summary', str(proc.pid)]),
                            ('heap', [str(proc.pid), '--noContent']),
                            ('sample', [str(proc.pid), '3', '10'])]:
        before = diagnostic_meter(proc, meter)
        start = time.monotonic()
        receipt = (bounded('/usr/bin/' + tool, arguments, timeout=6) if before['process_alive'] else
                   dict(status=None, stdout='', stderr='Owned preview exited; tool not attempted'))
        receipt.update(capture_start_uptime=start, capture_end_uptime=time.monotonic(),
                       before_meter=before, after_meter=diagnostic_meter(proc, meter))
        name = tool + '-' + phase + '.json'
        write_json(folder / name, receipt)
        capture['tools'].append(dict(tool=tool, evidence=name, status=receipt['status'],
                                    start_uptime=receipt['capture_start_uptime'],
                                    end_uptime=receipt['capture_end_uptime']))
        if tool in ('vmmap', 'heap') and receipt['status'] != 0:
            memory_tool_failed = True
    if region_fallback and memory_tool_failed and not region_attempted:
        region_attempted = True
        worker = Path(__file__).with_name('perf_regions.py')
        before = diagnostic_meter(proc, meter)
        start = time.monotonic()
        receipt = (bounded('/usr/bin/env', ['DAYSIDE_PERF_REGION_DIAGNOSTIC=1', sys.executable,
                   str(worker), '--pid', str(proc.pid)], timeout=2) if before['process_alive'] else
                   dict(status=None, stdout='', stderr='Owned preview exited; no region query attempted'))
        receipt.update(capture_start_uptime=start, capture_end_uptime=time.monotonic(),
                       before_meter=before, after_meter=diagnostic_meter(proc, meter))
        name = 'regions-fallback.json' if phase == 'active' else 'regions-fallback-post-close.json'
        write_json(folder / name, receipt)
        capture['tools'].append(dict(tool='regions', evidence=name, status=receipt['status'],
                                    start_uptime=receipt['capture_start_uptime'],
                                    end_uptime=receipt['capture_end_uptime']))
    capture.update(capture_end_uptime=time.monotonic(), after_capture=diagnostic_meter(proc, meter),
                   region_attempted=region_attempted,
                   scope='Snapshots follow the target event; per-tool timings expose capture delay. '
                         'Region tags are not heap classes, subsystem ownership, or physical footprint.')
    write_json(folder / 'diagnostic-capture.json', capture)
    if not capture['after_capture']['process_alive']:
        raise ValueError('Owned preview exited during diagnostic capture')
    return region_attempted, capture


def capture_surface_diagnostics(proc, folder, event):
    write_json(folder / 'event.json', event)
    for tool, arguments in [('vmmap', ['--summary', str(proc.pid)]),
                            ('footprint', ['-p', str(proc.pid)])]:
        receipt = bounded('/usr/bin/' + tool, arguments, timeout=3)
        write_json(folder / (tool + '.json'), receipt)
    receipt = bounded('/usr/bin/env', ['DAYSIDE_PERF_REGION_DIAGNOSTIC=1', sys.executable,
                      str(Path(__file__).with_name('perf_regions.py')), '--pid', str(proc.pid)], timeout=2)
    write_json(folder / 'regions.json', receipt)


def measurement_environment(scenario, event_path, diagnostics=False, inherited=None, diagnostic_phase='active'):
    validate_diagnostic_selection(diagnostics, diagnostic_phase, (scenario,))
    env = dict(os.environ if inherited is None else inherited)
    for key in list(env):
        if key.startswith(('MEANTIME_', 'TEST_RUNNER_MEANTIME_', 'DAYSIDE_')):
            del env[key]
    env.update(MEANTIME_TEST_HOST='1', MEANTIME_UI_TEST_FIXTURE='store', MEANTIME_PERF_COUNTS='1' if diagnostics else '0',
        MEANTIME_PERF_SCENARIO=scenario, MEANTIME_PERF_OUTPUT=str(event_path),
        MEANTIME_PERF_DIAGNOSTICS='1' if diagnostics and diagnostic_phase == 'active' else '0')
    if scenario == 'converter':
        env['MEANTIME_UI_TEST_CONVERT_TEXT'] = '2026-10-04 09:00'
    return env


def run_one(app, executable, scenario, folder, timeout, meter, diagnostics=False, region_fallback=False,
            diagnostic_phase='active', surface_diagnostics=False):
    folder.mkdir()
    event_path = folder / 'events.jsonl'
    env = measurement_environment(scenario, event_path, diagnostics, diagnostic_phase=diagnostic_phase)
    if surface_diagnostics:
        env['MEANTIME_PERF_SURFACE_DIAGNOSTICS'] = '1'
    samples, errors, events = [], [], []
    stop_sampling = threading.Event()
    region_attempted = False
    diagnostic_target = DiagnosticTarget(diagnostic_phase) if diagnostics else None
    def sample_loop(pid):
        with (folder / 'samples.jsonl').open('w') as stream:
            while not stop_sampling.is_set():
                try:
                    item = meter.read(pid)
                    samples.append(item)
                    stream.write(json.dumps(item) + '\n')
                    stream.flush()
                except OSError as exc:
                    errors.append(str(exc))
                    break
                stop_sampling.wait(.1)
    output = dict(status='invalid', phases={})
    with (folder / 'stdout.log').open('w') as stdout, (folder / 'stderr.log').open('w') as stderr:
        proc = subprocess.Popen([str(executable)], env=env, stdout=stdout, stderr=stderr)
        sampler = threading.Thread(target=sample_loop, args=(proc.pid,), daemon=True)
        sampler.start()
        deadline, offset = time.monotonic() + timeout, 0
        handshake_deadline = time.monotonic() + 30
        pending = ''
        try:
            while time.monotonic() < deadline:
                source = folder / 'stdout.log'
                if source.exists():
                    with source.open() as stream:
                        stream.seek(offset)
                        pending += stream.read()
                        offset = stream.tell()
                    while '\n' in pending:
                        line, pending = pending.split('\n', 1)
                        if not line.startswith('MEANTIME_PERF '):
                            continue
                        event = json.loads(line[len('MEANTIME_PERF '):])
                        event['_received_uptime'] = time.monotonic()
                        if event.get('scenario') != scenario:
                            raise ValueError('Hook scenario does not match request')
                        events.append(event)
                        if event.get('event') == 'error':
                            raise ValueError(str(event.get('error', event)))
                        if event.get('event') == 'unavailable' or event.get('available') is False:
                            output.update(status='unavailable', capability=event.get('capability'),
                                          error=str(event.get('reason', event)),
                                          metadata=validate_ready_metadata(events))
                            return output
                        if surface_diagnostics and event.get('surfaceDiagnostics'):
                            phase_folder = folder / ('snapshot-' + event['surfaceDiagnostics'])
                            phase_folder.mkdir()
                            capture_surface_diagnostics(proc, phase_folder, event)
                        if diagnostic_target and diagnostic_target.accept(event):
                            if diagnostic_phase == 'post-close':
                                if errors:
                                    raise ValueError('Continuous sampler failed: ' + '; '.join(errors))
                                parse_events(events, samples, scenario)
                            region_attempted, capture = capture_diagnostics(proc, folder, diagnostic_phase,
                                event, meter, region_fallback, region_attempted)
                            output['diagnostic_capture'] = capture
                        if event.get('event') in ('complete', 'done'):
                            if errors:
                                raise ValueError('Continuous sampler failed: ' + '; '.join(errors))
                            if diagnostic_target:
                                diagnostic_target.require_complete()
                            output['phases'] = parse_events(events, samples, scenario)
                            output['status'] = 'valid'
                            output['metadata'] = next((e for e in events if e.get('event') == 'ready'), {})
                            return output
                if not events and time.monotonic() >= handshake_deadline:
                    raise ValueError('Missing hook protocol acknowledgment within 30 seconds')
                if proc.poll() is not None:
                    raise ValueError(f'App exited before complete (exit {proc.returncode})')
                time.sleep(.05)
            raise ValueError(f'No complete hook protocol within {timeout} seconds')
        except (ValueError, OSError) as exc:
            output['error'] = str(exc)
            return output
        finally:
            stop_sampling.set()
            sampler.join(timeout=2)
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=5)
            write_json(folder / 'events-observed.json', events)
            write_json(folder / 'sampling-errors.json', errors)
            ls = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
            write_json(folder / 'unregister.json', bounded(ls, ['-u', str(app)]))


def validate_ready_metadata(events):
    metadata = next((e for e in events if e.get('event') == 'ready'), None)
    if metadata is None:
        metadata = next((e for e in events if e.get('event') == 'begin'), {})
    if metadata.get('protocol') != 1:
        raise ValueError('Missing protocol=1 acknowledgment')
    if metadata.get('places', 0) < 5 or metadata.get('people', 0) < 1:
        raise ValueError('Store fixture places/people not confirmed')
    if metadata.get('reduceMotion') is not False:
        raise ValueError('Reduce Motion disabled not confirmed')
    if not isinstance(metadata.get('fixtureHash'), str) or not metadata['fixtureHash']:
        raise ValueError('Fixture content fingerprint missing')
    return metadata


def validate_fixture_consistency(runs, scenario, current):
    reference = next((r.get('metadata') for r in runs
                      if r['status'] == 'valid' and r.get('scenario') == scenario), None)
    if reference and any(reference.get(k) != current.get(k) for k in ('places', 'people', 'fixtureHash')):
        raise ValueError('Fixture metadata differs between launches')


def parse_events(events, samples, scenario):
    metadata = validate_ready_metadata(events)
    checkpoints = [e for e in events if e.get('event') == 'checkpoint']
    if scenario in ('earth', 'tools-tour', 'converter') or scenario.startswith('cold-'):
        window = 'earth' if scenario == 'earth' else 'tools'
        if not any(e.get('window') == window and e.get('visible') is True and e.get('front') is True for e in checkpoints):
            raise ValueError('Window foreground acknowledgment missing')
    if scenario == 'earth' and not any(e.get('posterPNG', 0) > 0 and e.get('posterTIFF', 0) > 0
            and e.get('visible') is True and e.get('front') is True for e in checkpoints):
        raise ValueError('Earth foreground poster copy acknowledgment missing')
    if scenario == 'earth' and not any(e.get('earthForegroundSeconds', 0) >= 30
            and e.get('foregroundInterrupted') is False and e.get('visible') is True
            and e.get('front') is True for e in checkpoints):
        raise ValueError('Earth uninterrupted 30-second foreground dwell not confirmed')
    if scenario == 'tools-tour':
        opened = {e.get('page') for e in checkpoints}
        if not set(metadata.get('pages', PAGES)).issubset(opened):
            raise ValueError('Tools tour omitted an available page')
    if scenario == 'panel':
        if not any(e.get('jumps') == 6 and e.get('visible') is True for e in checkpoints):
            raise ValueError('Six panel jumps not acknowledged')
        if not any(e.get('jumps') == 6 and e.get('visible') is True
                and isinstance(e.get('jumpFrames'), list) and len(e['jumpFrames']) == 6
                and all(isinstance(n, int) and not isinstance(n, bool) and n > 1 for n in e['jumpFrames'])
                and e.get('animatedFrames', 0) > 6 for e in checkpoints):
            raise ValueError('Each of six jumps must have intermediate animation frames')
    active, phases = {}, {}
    for event in events:
        phase = event.get('phase', 'active')
        if event.get('event') == 'begin':
            if scenario == 'surfaces' and active:
                raise ValueError('Overlapping surface phases')
            if phase in active or phase in phases:
                raise ValueError('Duplicate phase begin')
            active[phase] = event
        elif event.get('event') == 'end':
            if phase not in active:
                raise ValueError('End without matching begin')
            phases[phase] = phase_result(active.pop(phase), event, samples)
    if active or (scenario != 'surfaces' and 'active' not in phases):
        raise ValueError('Incomplete phase pairs')
    if scenario == 'surfaces':
        if metadata.get('surfaceProtocol') != 2:
            raise ValueError('Missing surface protocol=2 acknowledgment; old tours are not comparable')
        required = ['idle', 'panel', 'panel-closed'] + ['page-' + p for p in metadata.get('pages', PAGES)] + [
            'settings', 'welcome', 'earth-open', 'earth-scrub', 'earth-closed', 'closed', 'closed-idle']
        if list(phases) != required or not set(metadata.get('pages', PAGES)).issubset({e.get('page') for e in checkpoints}):
            raise ValueError('Surface tour omitted required boundaries or pages')
        start = next(i for i, e in enumerate(events) if e.get('event') == 'begin' and e.get('phase') == 'panel-closed')
        stop = next(i for i, e in enumerate(events) if e.get('event') == 'end' and e.get('phase') == 'panel-closed')
        if not any(e.get('event') == 'checkpoint' and e.get('closedPanelBaseline') is True
                   and e.get('panelVisible') is False and e.get('toolsVisible') is False for e in events[start + 1:stop]):
            raise ValueError('Closed-panel baseline was not witnessed before Time Tools opened')
        renderer = metadata.get('mapRenderer')
        if renderer not in ('iosurface', 'legacy-scene'):
            raise ValueError('Surface map renderer not acknowledged')
        for phase in ('panel', 'earth-open', 'earth-scrub'):
            start = next(i for i, e in enumerate(events) if e.get('event') == 'begin' and e.get('phase') == phase)
            stop = next(i for i, e in enumerate(events) if e.get('event') == 'end' and e.get('phase') == phase)
            witnesses = [e for e in events[start + 1:stop] if e.get('event') == 'checkpoint'
                         and e.get('phase') == phase and e.get('visible') is True
                         and e.get('occlusionVisible') is True and e.get('mapRenderer') == renderer]
            if renderer == 'iosurface':
                witnesses = [e for e in witnesses if type(e.get('mapViews')) is int and e['mapViews'] > 0
                             and type(e.get('mapSurfaces')) is int and e['mapSurfaces'] > 0]
            if not witnesses:
                raise ValueError('Visible rendered map not witnessed: ' + phase)
    if scenario in ('panel', 'tools-tour', 'earth') and 'post-close' not in phases:
        raise ValueError('Post-close phase missing')
    if scenario == 'understand':
        checkpoint = next((e for e in checkpoints if e.get('input') == '9:00'
                           and e.get('mentions', 0) > 0 and e.get('cityIndexNeeded') is False), None)
        if checkpoint is None:
            raise ValueError('Immediate first understand checkpoint missing')
        begin = next(e for e in events if e.get('event') == 'begin' and e.get('phase') == 'active')
        end = next(e for e in events if e.get('event') == 'end' and e.get('phase') == 'active')
        if event_uptime(checkpoint) > event_uptime(end):
            raise ValueError('First understand checkpoint follows active end')
        phases['active'].update(first_call_result(begin, checkpoint))
    if scenario in POST_CLOSE_SCENARIOS:
        phases['post-close'].update(native_completion_checkpoint(events, scenario))
    return phases


def exit_code(runs):
    for run in runs:
        if run['status'] == 'valid':
            continue
        expected_absence = (run['status'] == 'unavailable' and run.get('build') == 'old'
                            and run.get('scenario') == 'understand'
                            and run.get('capability') == 'engineAbsent')
        if not expected_absence:
            return 2
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--old-app', required=True)
    parser.add_argument('--new-app', required=True)
    parser.add_argument('--out', required=True, help='New evidence directory; existing paths are refused')
    parser.add_argument('--repeats', type=int, default=3)
    parser.add_argument('--diagnostics', action='store_true', help='Separate attribution run: collect vmmap/heap/sample at the active-window diagnostic checkpoint')
    parser.add_argument('--diagnostic-phase', choices=('active', 'post-close'), default='active',
                        help='Diagnostics capture target; post-close supports panel, tools-tour, and earth only')
    parser.add_argument('--region-fallback', action='store_true', help='Diagnostics only: one bounded public libproc region-tag capture if vmmap/heap fails')
    parser.add_argument('--surface-diagnostics', action='store_true')
    parser.add_argument('--scenario', action='append', choices=SCENARIOS)
    parser.add_argument('--timeout', type=float, default=240, help='Bound for each isolated scenario launch')
    args = parser.parse_args()
    scenarios = tuple(args.scenario or SCENARIOS)
    if args.surface_diagnostics and (scenarios != ('surfaces',) or args.diagnostics):
        parser.error('--surface-diagnostics requires only --scenario surfaces')
    try:
        validate_diagnostic_selection(args.diagnostics, args.diagnostic_phase, scenarios)
    except ValueError as exc:
        parser.error(str(exc))
    if args.region_fallback and not args.diagnostics:
        parser.error('--region-fallback requires --diagnostics')
    if args.repeats < 3 or args.repeats > 5:
        parser.error('repeats must be 3 to 5')
    if not math.isfinite(args.timeout) or args.timeout < 65 or args.timeout > 600:
        parser.error('timeout must be 65 to 600 seconds')
    if sys.platform != 'darwin' or os.environ.get('DAYSIDE_PERF_CPU_LOCK_HELD') != '1':
        parser.error('Use Tools/perf_ruler.sh on macOS under the shared CPU lock')
    apps = {name: validate_app(path) for name, path in [('old', args.old_app), ('new', args.new_app)]}
    out = Path(args.out).resolve()
    out.mkdir(parents=True, exist_ok=False)
    conditions = dict(protocol=1, repeats=args.repeats, scenarios=scenarios, sample_interval_seconds=.1, diagnostic_run=args.diagnostics, region_fallback_requested=args.region_fallback,
        diagnostic_phase=args.diagnostic_phase if args.diagnostics else None,
        native_diagnostic_hold=args.diagnostics and args.diagnostic_phase == 'active',
        rust_counts_enabled=args.diagnostics,
        builds={name: values[2] for name, values in apps.items()},
        system=bounded('/usr/bin/sw_vers'), hardware=bounded('/usr/sbin/sysctl', ['hw.model', 'hw.memsize']),
        swap_before=bounded('/usr/sbin/sysctl', ['vm.swapusage']), load_before=bounded('/usr/bin/uptime'),
        ruler_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest())
    write_json(out / 'conditions.json', conditions)
    meter = Meter()
    runs = []
    for scenario in scenarios:
        for repeat in range(1, args.repeats + 1):
            for name in (('old', 'new') if repeat % 2 else ('new', 'old')):
                app, executable, _ = apps[name]
                strict = bounded('/bin/bash', [str(Path(__file__).with_name('owner_away.sh')), '--strict-check'])
                environment = dict(load=bounded('/usr/bin/uptime'), swap=bounded('/usr/sbin/sysctl', ['vm.swapusage']), strict_away=strict)
                write_json(out / f'{scenario}-{repeat}-{name}-environment.json', environment)
                if strict['status'] != 0:
                    print('WAITING: strict idle check rejected the next launch', flush=True)
                    return 75
                numbers = re.search(r'total = ([0-9.]+)M\s+used = ([0-9.]+)M', environment['swap']['stdout'])
                if numbers and float(numbers[1]) > 0 and float(numbers[2]) / float(numbers[1]) >= .9:
                    print('VOID: swap is at least 90% used; measurement round cannot start', flush=True)
                    return 2
                gate = bounded('/usr/bin/env', ['DAYSIDE_OWNER_AWAY_LOCK_HELD=1', '/bin/bash',
                    str(Path(__file__).with_name('owner_away.sh')), '--wait'])
                if gate['status'] != 0:
                    write_json(out / 'launch-gate.json', gate)
                    print('WAITING: launch gate did not admit the next run', flush=True)
                    return 75
                print(f'{name} #{repeat} {scenario}', flush=True)
                folder = out / f'{scenario}-{repeat}-{name}'
                run = run_one(app, executable, scenario, folder, args.timeout, meter, args.diagnostics,
                              args.region_fallback, args.diagnostic_phase,
                              surface_diagnostics=args.surface_diagnostics and repeat == 1)
                if run['status'] == 'valid':
                    try:
                        validate_fixture_consistency(runs, scenario, run.get('metadata', {}))
                    except ValueError as exc:
                        run.update(status='invalid', error=str(exc))
                run.update(build=name, repeat=repeat, scenario=scenario, evidence=str(folder), environment=environment)
                if run['status'] == 'valid' and numbers and float(numbers[2]) > 0 and min(p['end_rss_mib'] for p in run['phases'].values()) < 60:
                    run.update(status='invalid', error='RSS below 60 MiB under swap pressure; possibly swapped-out process')
                runs.append(run)
                write_json(out / 'runs.json', runs)
                summary = aggregate(runs, args.repeats)
                write_json(out / 'summary.json', summary)
                (out / 'TABLE.md').write_text(markdown(summary, runs))
                print(f'  {run["status"]}: {run.get("error", "complete")}', flush=True)
                if run['status'] == 'invalid' and 'protocol' in run.get('error', '').lower():
                    print('Hook capability missing; stopping before repeating invalid launches.', file=sys.stderr)
                    return 1
    write_json(out / 'system-after.json', dict(swap=bounded('/usr/sbin/sysctl', ['vm.swapusage']),
        load=bounded('/usr/bin/uptime')))
    return exit_code(runs)


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyboardInterrupt) as exc:
        print(f'Performance ruler failed: {exc}', file=sys.stderr)
        raise SystemExit(1)
