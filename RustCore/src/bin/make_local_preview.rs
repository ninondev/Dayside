// SPDX-License-Identifier: GPL-3.0-only
//! Produce a separately identified local preview without touching the production candidate or data.
use std::{
    env,
    ffi::{CString, OsStr},
    fs,
    os::unix::ffi::OsStrExt,
    path::{Path, PathBuf},
    process::{Command, ExitCode},
    time::{SystemTime, UNIX_EPOCH},
};

type Result<T> = std::result::Result<T, String>;

fn run(program: &str, args: &[&OsStr]) -> Result<String> {
    let output = Command::new(program)
        .args(args)
        .output()
        .map_err(|e| e.to_string())?;
    if !output.status.success() {
        return Err(format!(
            "{program}: {}",
            String::from_utf8_lossy(&output.stderr)
        ));
    }
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_owned())
}

fn plist(path: &Path, command: &str) -> Result<String> {
    run(
        "/usr/libexec/PlistBuddy",
        &["-c".as_ref(), command.as_ref(), path.as_os_str()],
    )
}

struct Scratch(PathBuf);
impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn create(source: &Path, requested_output: &Path) -> Result<()> {
    let source = source.canonicalize().map_err(|e| e.to_string())?;
    let output = if requested_output.is_absolute() {
        requested_output.to_owned()
    } else {
        env::current_dir()
            .map_err(|e| e.to_string())?
            .join(requested_output)
    };
    if fs::symlink_metadata(&output).is_ok() || output.extension().is_none_or(|e| e != "app") {
        return Err("Choose a new .app path; existing output will never be replaced.".into());
    }
    let parent = output.parent().ok_or("Missing output parent")?;
    let parent = parent
        .canonicalize()
        .map_err(|e| format!("Choose an existing output parent directory: {e}"))?;
    if parent.starts_with(&source) {
        return Err("Output must be outside the candidate bundle.".into());
    }
    let output = parent.join(output.file_name().ok_or("Missing app name")?);
    run(
        "/usr/bin/codesign",
        &[
            "--verify".as_ref(),
            "--deep".as_ref(),
            "--strict".as_ref(),
            source.as_os_str(),
        ],
    )?;
    if plist(
        &source.join("Contents/Info.plist"),
        "Print :CFBundleIdentifier",
    )? != "com.dayside.Dayside"
    {
        return Err("The source must be the completed production Dayside candidate.".into());
    }
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|e| e.to_string())?
        .as_nanos();
    let scratch = Scratch(parent.join(format!(".dayside-preview-{}-{nonce}", std::process::id())));
    fs::create_dir(&scratch.0).map_err(|e| e.to_string())?;
    let staging = scratch
        .0
        .join(output.file_name().ok_or("Missing app name")?);
    run("/usr/bin/ditto", &[source.as_os_str(), staging.as_os_str()])?;
    let contents = staging.join("Contents");
    // These removals apply only to our new copy, never an installed app or user data.
    for relative in [
        "Extensions",
        "PlugIns",
        "Resources/Metadata.appintents",
        "Resources/container-migration.plist",
    ] {
        let target = contents.join(relative);
        if target.is_dir() {
            fs::remove_dir_all(target).map_err(|e| e.to_string())?;
        } else if target.exists() {
            fs::remove_file(target).map_err(|e| e.to_string())?;
        }
    }
    let info = contents.join("Info.plist");
    for command in [
        "Set :CFBundleIdentifier com.dayside.Dayside.localpreview",
        "Set :CFBundleName Dayside Local Preview",
        "Set :CFBundleDisplayName Dayside Local Preview",
        "Add :MTLocalPreview bool true",
    ] {
        plist(&info, command)?;
    }
    for key in ["CFBundleURLTypes", "NSServices"] {
        if plist(&info, &format!("Print :{key}")).is_ok() {
            plist(&info, &format!("Delete :{key}"))?;
        }
    }
    let root = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .ok_or("Missing repository root")?;
    let entitlements = scratch.0.join("preview.entitlements");
    fs::copy(
        root.join("TahoeTime/TahoeTime-signing-Release.entitlements"),
        &entitlements,
    )
    .map_err(|e| e.to_string())?;
    plist(
        &entitlements,
        "Delete :com.apple.security.application-groups",
    )?;
    // `--options runtime`: the preview derives from a Release candidate, and notarization needs the
    // hardened runtime on every code object; the preview must not lose it while being re-signed.
    run(
        "/usr/bin/codesign",
        &[
            "--force".as_ref(),
            "--sign".as_ref(),
            "-".as_ref(),
            "--options".as_ref(),
            "runtime".as_ref(),
            "--timestamp=none".as_ref(),
            "--entitlements".as_ref(),
            entitlements.as_os_str(),
            staging.as_os_str(),
        ],
    )?;
    run(
        "/usr/bin/codesign",
        &[
            "--verify".as_ref(),
            "--deep".as_ref(),
            "--strict".as_ref(),
            staging.as_os_str(),
        ],
    )?;
    let from = CString::new(staging.as_os_str().as_bytes()).map_err(|e| e.to_string())?;
    let to = CString::new(output.as_os_str().as_bytes()).map_err(|e| e.to_string())?;
    // SAFETY: both strings are live, NUL-terminated paths. RENAME_EXCL makes the
    // final operation atomic and refuses even a concurrently created symlink.
    if unsafe { libc::renamex_np(from.as_ptr(), to.as_ptr(), libc::RENAME_EXCL) } != 0 {
        return Err(format!("Preview output was not replaced: {}", std::io::Error::last_os_error()));
    }
    println!(
        "{}",
        serde_json::json!({"candidate":source,"preview":output,
        "bundleIdentifier":"com.dayside.Dayside.localpreview","migratesProductionData":false,
        "sharedSystemSurfacesIncluded":false})
    );
    Ok(())
}

fn main() -> ExitCode {
    let args: Vec<_> = env::args_os().skip(1).collect();
    if args.len() != 2 {
        eprintln!("Usage: make_local_preview <completed Release.app> <new preview.app>");
        return ExitCode::from(2);
    }
    match create(Path::new(&args[0]), Path::new(&args[1])) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("Local preview was not created: {error}");
            ExitCode::FAILURE
        }
    }
}
