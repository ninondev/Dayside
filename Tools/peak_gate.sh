#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# 峰值量尺：Tools/peak_gate.sh --app <隔离预览.app> [--dwell 6] [--scenario launch …]
# 每个场景重新启动一次 App，靠 dayside://tools?feature=… 打开各页，采就绪耗时、场景内 CPU、footprint 与峰值、索引映射段。
# 与发布门共用同一套采样器（RustCore/src/bin/support/measurement.rs）；只在隔离预览上跑（完整候选会弹 TCC 框）。
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CARGO_BIN=${CARGO:-cargo}
if ! command -v "$CARGO_BIN" >/dev/null 2>&1; then CARGO_BIN="$HOME/.cargo/bin/cargo"; fi
"$CARGO_BIN" run --locked --quiet --manifest-path "$ROOT/RustCore/Cargo.toml" --bin peak_gate -- "$@"
status=$?
"$ROOT/Tools/ls_unregister_copies.sh" >/dev/null 2>&1 || true
exit $status
