// SPDX-License-Identifier: GPL-3.0-only
//! Arbitrary-app sampling, sharing exactly the release gate's native parsers.
#[path = "support/measurement.rs"]
mod measurement;
use measurement::*;
use std::{env, path::PathBuf, process::ExitCode, time::Duration};
fn run(app: PathBuf, settle_raw: String) -> Result<()> {
    let settle = settle_seconds(&settle_raw)?;
    let app = app_path(&app)?;
    let name = app.file_stem().unwrap_or_default().to_string_lossy();
    let executable = info(&app, "CFBundleExecutable")?;
    let version = info(&app, "CFBundleShortVersionString").unwrap_or_else(|_| "-".into());
    let bundle = bundle_mb(&app)?;
    if processes()?.iter().any(|p| has_bundle_process(p, &app)) {
        return Err(format!("already running: {}", app.display()));
    }
    wait_owner_away()?;
    let mut process = OwnedApp::spawn(&app.join("Contents/MacOS").join(executable), false)?;
    process.wait(Duration::from_secs(10))?;
    let start = process.snapshot(&app, true)?;
    process.wait(Duration::from_secs_f64(settle))?;
    let end = process.snapshot(&app, true)?;
    let (cpu, rss) = aggregate(&start, &end, settle)?;
    let pid = process.pid().to_string();
    let foot = match command("vmmap", &["--summary", &pid]).and_then(|s| footprint(&s)) {
        Ok((_, raw)) => raw,
        Err(e) => {
            let reason = e.to_ascii_lowercase();
            if [
                "task port",
                "task for pid",
                "permission",
                "not permitted",
                "privilege",
            ]
            .iter()
            .any(|word| reason.contains(word))
            {
                eprintln!("Physical footprint 取不到: {e}");
                "取不到(无 task port)".into()
            } else {
                return Err(e);
            }
        }
    };
    process.check_alive()?;
    drop(process);
    let stamp = timestamp()?;
    println!("| {name} | {version} | {cpu:.2} s | {foot} | {rss:.1} MB({} 个进程合计) | {bundle:.1} MB | {stamp} |",end.len());
    Ok(())
}
fn main() -> ExitCode {
    install_signals();
    let mut args = env::args().skip(1);
    let Some(app) = args.next() else {
        eprintln!("用法:Tools/bench_app.sh /Applications/Foo.app [settle=60]");
        return ExitCode::from(2);
    };
    let settle = args.next().unwrap_or_else(|| "60".into());
    if args.next().is_some() || settle_seconds(&settle).is_err() {
        eprintln!(
            "用法:Tools/bench_app.sh /Applications/Foo.app [settle=60]，采样秒数必须为正数。"
        );
        return ExitCode::from(2);
    }
    if !PathBuf::from(&app).is_dir() {
        eprintln!("not found: {app}");
        return ExitCode::from(2);
    }
    match run(app.into(), settle) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            let code = if e.starts_with("already running:") {
                3
            } else {
                1
            };
            eprintln!("{e}");
            ExitCode::from(code)
        }
    }
}
