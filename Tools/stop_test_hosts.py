#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# 只结束指定构建目录的测试宿主，逐次核对可执行文件路径。
import argparse
import ctypes
import errno
import os
from pathlib import Path
import signal
import sys
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--derived-data", required=True)
    args = parser.parse_args()
    target = os.path.realpath(Path(args.derived_data) / "Build/Products/Debug/Dayside.app/Contents/MacOS/Dayside")
    libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    libproc.proc_listpids.argtypes = [ctypes.c_uint, ctypes.c_uint, ctypes.c_void_p, ctypes.c_int]
    libproc.proc_listpids.restype = ctypes.c_int
    libproc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    libproc.proc_pidpath.restype = ctypes.c_int

    def executable(pid):
        buffer = ctypes.create_string_buffer(4096)
        length = libproc.proc_pidpath(pid, buffer, len(buffer))
        return os.path.realpath(os.fsdecode(buffer.value)) if length > 0 else None

    def matching_pids():
        length = libproc.proc_listpids(1, 0, None, 0)
        if length <= 0:
            raise OSError(ctypes.get_errno(), "proc_listpids could not enumerate processes")
        capacity = length // ctypes.sizeof(ctypes.c_int) + 1024
        pids = (ctypes.c_int * capacity)()
        length = libproc.proc_listpids(1, 0, pids, ctypes.sizeof(pids))
        if length <= 0:
            raise OSError(ctypes.get_errno(), "proc_listpids could not read processes")
        return [pid for pid in pids[:length // ctypes.sizeof(ctypes.c_int)]
                if pid > 0 and executable(pid) == target]

    signaled = set()
    errors = []
    for requested_signal, seconds in ((signal.SIGTERM, 5), (signal.SIGKILL, 3)):
        deadline = time.monotonic() + seconds
        quiet_since = None
        while time.monotonic() < deadline:
            live = matching_pids()
            if not live:
                if quiet_since is None:
                    quiet_since = time.monotonic()
                if time.monotonic() - quiet_since >= 0.5:
                    if errors:
                        print("Test host cleanup failed: " + "; ".join(errors), file=sys.stderr)
                        return 1
                    return 0
            else:
                quiet_since = None
            for pid in live:
                key = (pid, requested_signal)
                if key in signaled or executable(pid) != target:
                    continue
                try:
                    os.kill(pid, requested_signal)
                    signaled.add(key)
                except OSError as error:
                    if error.errno != errno.ESRCH:
                        errors.append(f"pid {pid}: {error}")
                        signaled.add(key)
            time.sleep(0.1)
    remaining = matching_pids()
    if remaining or errors:
        print(f"Test host cleanup failed; owned path: {target}; remaining pids: {remaining}; errors: {errors}",
              file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError) as error:
        print(f"Test host cleanup failed: {error}", file=sys.stderr)
        sys.exit(1)
