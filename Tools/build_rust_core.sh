#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Xcode's host layer links a static Rust library for every requested architecture.
set -euo pipefail
root="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cargo_bin="${CARGO:-${HOME}/.cargo/bin/cargo}"
[[ -x "$cargo_bin" ]] || cargo_bin="$(command -v cargo)"
profile=app-debug
profile_args=(--profile app-debug)
if [[ "${CONFIGURATION:-Release}" == Release ]]; then
  profile=release
  profile_args=(--release)
fi
target_dir="${DERIVED_FILE_DIR:-$root/RustCore/target/xcode}/rust-target"
output_dir="${BUILT_PRODUCTS_DIR:-$root/RustCore/target/xcode}"
mkdir -p "$output_dir"
libraries=()
# iOS 原型：Xcode 给 iphonesimulator / iphoneos 时换 Rust 三元组；macOS 路径不变。
platform="${PLATFORM_NAME:-macosx}"
for arch in ${ARCHS:-arm64 x86_64}; do
  case "$platform/$arch" in
    macosx/arm64) triple=aarch64-apple-darwin ;;
    macosx/x86_64) triple=x86_64-apple-darwin ;;
    iphonesimulator/arm64) triple=aarch64-apple-ios-sim ;;
    iphonesimulator/x86_64) triple=x86_64-apple-ios ;;
    iphoneos/arm64) triple=aarch64-apple-ios ;;
    *) echo "Unsupported Rust platform/architecture: $platform/$arch" >&2; exit 1 ;;
  esac
  # rustc 按这个环境变量定 iOS 最低版本；聚合 target 的配置里没有它，不设就按 SDK（27.0）编出来、链接 26.0 的 app 时整库告警。
  case "$triple" in *apple-ios*) export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-26.0}";; esac  # 聚合 target DaysideCore 的配置里现在写着 26.0
  CARGO_TARGET_DIR="$target_dir" "$cargo_bin" build --manifest-path "$root/RustCore/Cargo.toml" \
    --locked --lib --target "$triple" "${profile_args[@]}"
  cp "$target_dir/$triple/$profile/libdayside_core.a" "$output_dir/libdayside_core-$arch.a"
  libraries+=("$output_dir/libdayside_core-$arch.a")
done
/usr/bin/lipo -create "${libraries[@]}" -output "$output_dir/libdayside_core.a"
