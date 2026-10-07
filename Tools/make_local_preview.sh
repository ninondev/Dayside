#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copies a completed candidate into a new isolated preview bundle. Never overwrites output.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CARGO_BIN=${CARGO:-cargo}
if ! command -v "$CARGO_BIN" >/dev/null 2>&1; then CARGO_BIN="$HOME/.cargo/bin/cargo"; fi
exec "$CARGO_BIN" run --locked --quiet --manifest-path "$ROOT/RustCore/Cargo.toml" --bin make_local_preview -- "$@"
