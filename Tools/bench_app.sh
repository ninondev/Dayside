#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# 用法:Tools/bench_app.sh /Applications/Foo.app [settle=60]
# 采样与本次启动的子进程清理由 Rust CLI 执行。
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CARGO_BIN=${CARGO:-cargo}
if ! command -v "$CARGO_BIN" >/dev/null 2>&1; then CARGO_BIN="$HOME/.cargo/bin/cargo"; fi
exec "$CARGO_BIN" run --locked --quiet --manifest-path "$ROOT/RustCore/Cargo.toml" --bin bench_app -- "$@"
