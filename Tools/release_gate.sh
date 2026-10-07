#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# 用法:Tools/release_gate.sh [--settle 60] [--skip-build] [--app /path/to/Dayside.app]
# 采样、就绪检查、进程清理与预算判定由 Rust CLI 执行。
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CARGO_BIN=${CARGO:-cargo}
if ! command -v "$CARGO_BIN" >/dev/null 2>&1; then CARGO_BIN="$HOME/.cargo/bin/cargo"; fi
"$CARGO_BIN" run --locked --quiet --manifest-path "$ROOT/RustCore/Cargo.toml" --bin release_gate -- "$@"
status=$?
# 门启动过的产物会留在 LaunchServices 里，注销掉（只留 /Applications 的安装版）。
"$ROOT/Tools/ls_unregister_copies.sh" >/dev/null 2>&1 || true
exit $status
