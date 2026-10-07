#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""每秒记录前台应用，后台验证若占据前台则失败；调用方持有 CPU 锁。"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time


class RunInterrupted(Exception):
    def __init__(self, number: int):
        self.number = number


def measurement_state() -> str:
    pause_file = Path.home() / ".config/dayside/measure.state"
    try:
        pause_file.lstat()
    except FileNotFoundError:
        return "FREE"
    return pause_file.read_text().strip()


def screen_free(foreground: bool) -> bool:
    try:
        state = measurement_state()
    except (OSError, UnicodeError):
        return False
    return state == "FREE" and (not foreground or not (Path.home() / ".dayside-screen-busy").exists())


def frontmost() -> dict:
    front = subprocess.check_output(["/usr/bin/lsappinfo", "front"], text=True, timeout=0.4).strip()
    if front == "[ NULL ]":
        return {"front": None, "info": None, "dayside": False}
    info = subprocess.check_output(
        ["/usr/bin/lsappinfo", "info", "-only", "name,bundleid,pid,bundlepath", front], text=True, timeout=0.4
    ).strip()
    if not re.fullmatch(r"ASN:0x[0-9a-fA-F]+-0x[0-9a-fA-F]+:", front):
        raise ValueError("Missing frontmost application identity")
    if not re.search(r'"pid"=\d+', info) or not re.search(r'"LSDisplayName"="[^"]+"', info):
        raise ValueError("Incomplete frontmost application metadata")
    return {"front": front, "info": info,
            "dayside": bool(re.search(r'"Dayside"|com\.dayside\.Dayside', info))}


def classify_frontmost(record: dict, owned_roots: list[Path]) -> tuple[bool, bool]:
    if not record["dayside"]:
        return False, False
    if not owned_roots:
        return True, False
    match = re.search(r'"LSBundlePath"="([^"]+)"', record["info"] or "")
    if match is None:
        raise ValueError("Missing Dayside bundle path")
    bundle = Path(match.group(1)).resolve()
    owned = any(bundle.is_relative_to(root.resolve()) for root in owned_roots)
    return owned, not owned


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--foreground", action="store_true")
    parser.add_argument("--owned-app-root", type=Path, action="append", default=[])
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("missing command after --")
    if args.foreground and os.environ.get("MEANTIME_UI_TEST_FOREGROUND") != "1":
        print("DEFERRED: foreground monitoring requires MEANTIME_UI_TEST_FOREGROUND=1", file=sys.stderr)
        return 75
    if not screen_free(args.foreground):
        print("DEFERRED: measurement screen is unavailable", file=sys.stderr)
        return 75
    args.output.parent.mkdir(parents=True, exist_ok=True)
    owned_roots = [root.resolve() for root in args.owned_app_root]
    samples = sightings = foreign_sightings = failures = 0
    last_sample = None
    max_sampling_gap = 0.0
    started = time.monotonic()
    process = None
    deferred = False
    violated = False
    interrupted = None
    def interrupt(number: int, _frame) -> None:
        raise RunInterrupted(number)
    handlers = {number: signal.signal(number, interrupt)
                for number in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM)}
    try:
        with args.output.open("x", encoding="utf-8") as log:
            def sample() -> None:
                nonlocal samples, sightings, foreign_sightings, failures, last_sample, max_sampling_gap
                elapsed = time.monotonic() - started
                record = {"utc": datetime.now(timezone.utc).isoformat(),
                          "elapsed": elapsed,
                          "foregroundAllowed": args.foreground}
                if last_sample is not None:
                    gap = elapsed - last_sample
                    max_sampling_gap = max(max_sampling_gap, gap)
                    if gap > 2:
                        record["samplingGapFailure"] = gap
                        failures += 1
                last_sample = elapsed
                try:
                    record.update(frontmost())
                    owned, foreign = classify_frontmost(record, owned_roots)
                    record.update(ownedDayside=owned, foreignDayside=foreign)
                    sightings += int(owned)
                    foreign_sightings += int(foreign)
                except (OSError, subprocess.SubprocessError, ValueError) as error:
                    record["error"] = str(error)
                    failures += 1
                log.write(json.dumps(record, ensure_ascii=False) + "\n")
                log.flush()
                samples += 1
            sample()
            if failures or (sightings and not args.foreground):
                print("Frontmost verification failed before launch", file=sys.stderr)
                return 1
            if not screen_free(args.foreground):
                print("DEFERRED: screen became unavailable before launch", file=sys.stderr)
                return 75
            process = subprocess.Popen(command, start_new_session=True)
            next_sample = time.monotonic() + 1
            while process.poll() is None:
                if not screen_free(args.foreground):
                    deferred = True
                    print("DEFERRED: screen became unavailable during verification", file=sys.stderr)
                    break
                time.sleep(min(0.1, max(0, next_sample - time.monotonic())))
                if time.monotonic() >= next_sample:
                    sample()
                    next_sample += 1
                    if failures or (sightings and not args.foreground):
                        violated = True
                        print("Frontmost verification failed; stopping the owned run", file=sys.stderr)
                        break
            sample()
    except RunInterrupted as error:
        interrupted = error.number
    finally:
        # 清理期间再收到信号也先等本轮子进程退出，CPU 锁仍由调用方持有。
        for number in handlers:
            signal.signal(number, signal.SIG_IGN)
        if process is not None and process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()
        for number, previous in handlers.items():
            signal.signal(number, previous)
    result = {"samples": samples, "daysideFrontmost": sightings, "samplingFailures": failures,
              "foreignDaysideFrontmost": foreign_sightings,
              "foregroundAllowed": args.foreground, "deferred": deferred, "violated": violated,
              "commandExit": process.returncode if process is not None else None,
              "interruptedBy": interrupted, "maxSamplingGapSeconds": max_sampling_gap}
    print("FRONTMOST_MONITOR " + json.dumps(result, sort_keys=True), flush=True)
    if deferred:
        return 75
    if interrupted is not None:
        return 128 + interrupted
    if failures or (sightings and not args.foreground):
        return 1
    return process.returncode if process is not None else 1


if __name__ == "__main__":
    sys.exit(main())
