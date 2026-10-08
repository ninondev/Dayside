#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Diagnostic region tags only; no task port, mapped paths or memory-content reads."""
import argparse
import ctypes
import errno
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

LIMIT = 4096
MAX_ADDRESS = 2 ** 64 - 1
PROC_PIDREGIONINFO = 7
REGION_FIELDS_32 = ('behavior user_wired_count user_tag pages_resident pages_shared_now_private '
                   'pages_swapped_out pages_dirtied ref_count shadow_depth share_mode '
                   'private_pages_resident shared_pages_resident obj_id depth').split()


class RegionInfo(ctypes.Structure):
    _fields_ = [(n, ctypes.c_uint32) for n in ('protection', 'max_protection', 'inheritance', 'flags')] + [
        ('offset', ctypes.c_uint64)] + [(n, ctypes.c_uint32) for n in REGION_FIELDS_32] + [
        ('address', ctypes.c_uint64), ('size', ctypes.c_uint64)]


def sdk_tags(raw):
    tokens = dict(re.findall(r'^#define\s+(VM_MEMORY_[A-Z0-9_]+)\s+([A-Z0-9_]+)', raw, re.M))
    names = {}
    for key, value in tokens.items():
        if value.isdecimal():
            number = int(value)
            if number <= 255:
                names.setdefault(number, key)
    return names


def region_next(record, cursor):
    address, size = record['address'], record['size']
    if not isinstance(address, int) or not isinstance(size, int) or address < cursor or size <= 0:
        raise ValueError('Region address must advance and region size must be positive')
    end = address + size
    if end > MAX_ADDRESS or end <= cursor:
        raise ValueError('Region address overflow or non-progress')
    return end


def walk_regions(reader, limit=LIMIT, clock=time.monotonic, seconds=1.5):
    if not isinstance(limit, int) or not 1 <= limit <= LIMIT:
        raise ValueError('Region count bound must be 1..4096')
    records, cursor = [], 0
    deadline = clock() + seconds
    for _ in range(limit):
        if clock() >= deadline:
            return dict(status='partial', error='Region deadline reached', records=records)
        try:
            record = reader(cursor)
            if record is None:
                return dict(status='complete', records=records)
            cursor = region_next(record, cursor)
            records.append(record)
        except (OSError, ValueError) as exc:
            return dict(status='error', error=str(exc), records=records)
    return dict(status='partial', error='4096-region hard limit reached', records=records)


def group_regions(records, names, page_size):
    if not isinstance(page_size, int) or page_size <= 0:
        raise ValueError('Invalid page size')
    groups = {}
    for record in records:
        tag = record['user_tag']
        group = groups.setdefault(tag, dict(tag=tag, name=names.get(tag, f'unknown-tag-{tag}'),
            regions=0, virtual_bytes=0, resident_pages=0, private_resident_pages=0,
            shared_resident_pages=0, shared_now_private_pages=0, dirty_pages=0, swapped_pages=0))
        mapping = dict(virtual_bytes='size', resident_pages='pages_resident',
            private_resident_pages='private_pages_resident', shared_resident_pages='shared_pages_resident',
            shared_now_private_pages='pages_shared_now_private', dirty_pages='pages_dirtied',
            swapped_pages='pages_swapped_out')
        for output, source in mapping.items():
            value = record[source]
            if not isinstance(value, int) or isinstance(value, bool) or value < 0:
                raise ValueError('Invalid region counter: ' + source)
            group[output] += value
        group['regions'] += 1
    return dict(page_size_bytes=page_size, groups=list(groups.values()),
        scope='Virtual-memory region tags, not allocation classes or subsystem ownership proof; sums may alias shared regions and are not physical footprint.')


def capture(pid):
    lib = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
    lib.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
    lib.proc_pidinfo.restype = ctypes.c_int
    size = ctypes.sizeof(RegionInfo)
    termination = {}
    def reader(cursor):
        info = RegionInfo()
        ctypes.set_errno(0)
        returned = lib.proc_pidinfo(pid, PROC_PIDREGIONINFO, cursor, ctypes.byref(info), size)
        if returned == 0:
            code = ctypes.get_errno()
            if code in (errno.ENOENT, errno.EINVAL) and cursor > 0:
                termination.update(errno=code, address=cursor)
                return None
            raise OSError(code, 'PROC_PIDREGIONINFO unavailable; no retry or permission workaround')
        if returned != size:
            raise ValueError(f'PROC_PIDREGIONINFO returned {returned} bytes, expected {size}')
        return {field: getattr(info, field) for field, _ in RegionInfo._fields_}
    snapshot = walk_regions(reader)
    if termination:
        snapshot.update(status='partial', error='Enumeration stopped at an address error; snapshot completeness unverified',
                        terminal_error=termination)
    try:
        sdk = subprocess.check_output(['/usr/bin/xcrun', '--show-sdk-path'], text=True, timeout=1).strip()
        header = Path(sdk) / 'usr/include/mach/vm_statistics.h'
        names = sdk_tags(header.read_text())
        snapshot['tag_source'] = str(header)
    except (OSError, subprocess.SubprocessError) as exc:
        names = {}
        snapshot['tag_error'] = str(exc)
    records = snapshot.pop('records')
    grouped = group_regions(records, names, os.sysconf('SC_PAGE_SIZE'))
    snapshot['captured_region_count'] = len(records)
    return dict(pid=pid, capture_uptime=time.monotonic(), api='proc_pidinfo/PROC_PIDREGIONINFO',
                max_regions=LIMIT, **snapshot, **grouped)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pid', required=True, type=int)
    args = parser.parse_args()
    if sys.platform != 'darwin' or os.environ.get('DAYSIDE_PERF_REGION_DIAGNOSTIC') != '1' or args.pid <= 0:
        parser.error('Only the diagnostics ruler may capture its owned preview PID')
    try:
        print(json.dumps(capture(args.pid)))
    except (OSError, ValueError) as exc:
        print(json.dumps(dict(status='error', error=str(exc))))
