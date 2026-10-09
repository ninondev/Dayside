// SPDX-License-Identifier: GPL-3.0-only
use std::{env, fs, path::PathBuf};

fn main() {
    let manifest = PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").expect("Cargo manifest directory"));
    let source = manifest.join("../Dayside/Resources/relief.png");
    println!("cargo:rerun-if-changed={}", source.display());
    let bytes = fs::read(source).expect("bundled relief image");
    let checksum = bytes.iter().fold(0xcbf2_9ce4_8422_2325_u64, |hash, byte| {
        (hash ^ u64::from(*byte)).wrapping_mul(0x100_0000_01b3)
    });
    // 只把长度与校验写进库，不再带一份图片。
    let constants = format!("const RELIEF_LENGTH: u64 = {};\nconst RELIEF_CHECKSUM: u64 = {checksum};\n", bytes.len());
    let output = PathBuf::from(env::var_os("OUT_DIR").expect("Cargo output directory"));
    fs::write(output.join("terrain_source.rs"), constants).expect("terrain identity constants");
}
