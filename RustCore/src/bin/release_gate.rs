// SPDX-License-Identifier: GPL-3.0-only
//! Release resource gate. The shell entry point only locates Cargo.
#[path = "support/measurement.rs"]
mod measurement;
use measurement::*;
use serde::Deserialize;
use std::{
    env, fs,
    path::PathBuf,
    process::{Command, ExitCode},
    time::Duration,
};
#[derive(Deserialize)]
struct Budget {
    idle_cpu_seconds_per_60s_max: f64,
    footprint_mb_max: f64,
    rss_mb_max: f64,
    bundle_mb_max: f64,
    index_mappings_while_idle_max: usize,
}
impl Budget {
    fn validate(&self) -> Result<()> {
        if [
            self.idle_cpu_seconds_per_60s_max,
            self.footprint_mb_max,
            self.rss_mb_max,
            self.bundle_mb_max,
        ]
        .into_iter()
        .all(|n| n.is_finite() && n >= 0.)
        {
            Ok(())
        } else {
            Err("Tools/budget.json 包含无效预算。".into())
        }
    }
}
struct Options {
    settle: String,
    skip_build: bool,
    app: Option<PathBuf>,
}
fn options(args: impl Iterator<Item = String>) -> Result<Options> {
    let mut args = args;
    let mut o = Options {
        settle: "60".into(),
        skip_build: false,
        app: None,
    };
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--settle" => o.settle = args.next().ok_or("--settle 缺少秒数")?,
            "--skip-build" => o.skip_build = true,
            "--app" => o.app = Some(args.next().ok_or("--app 缺少路径")?.into()),
            _ => return Err(format!("unknown arg: {arg}")),
        }
    }
    settle_seconds(&o.settle)?;
    Ok(o)
}
fn run(o: Options) -> Result<bool> {
    let root = repo_root();
    env::set_current_dir(&root).map_err(|e| e.to_string())?;
    let settle = settle_seconds(&o.settle)?;
    let budget: Budget = serde_json::from_slice(
        &fs::read(root.join("Tools/budget.json")).map_err(|e| e.to_string())?,
    )
    .map_err(|e| format!("Tools/budget.json: {e}"))?;
    budget.validate()?;
    let path = if let Some(path) = o.app {
        path
    } else {
        let dd = env::var_os("DERIVED_DATA")
            .map(PathBuf::from)
            .unwrap_or_else(|| env::temp_dir().join("dayside-release-gate"));
        if !o.skip_build {
            eprintln!("▶ Release 构建(derivedData={})…", dd.display());
            let mut build = Command::new("xcodebuild");
            build
                .args([
                    "-project",
                    "Dayside.xcodeproj",
                    "-scheme",
                    "Dayside",
                    "-configuration",
                    "Release",
                    "-derivedDataPath",
                ])
                .arg(&dd)
                .args(["build", "-quiet"]);
            OwnedApp::build(&mut build)?;
        }
        let products = dd.join("Build/Products/Release");
        let mut apps: Vec<_> = fs::read_dir(&products)
            .map_err(|e| format!("{}: {e}", products.display()))?
            .filter_map(|v| v.ok().map(|e| e.path()))
            .filter(|p| p.extension().is_some_and(|e| e == "app") && p.is_dir())
            .collect();
        apps.sort();
        apps.into_iter()
            .next()
            .ok_or_else(|| format!("找不到 app: {}", products.display()))?
    };
    let app = app_path(&path)?;
    let executable = info(&app, "CFBundleExecutable")?;
    let version = info(&app, "CFBundleShortVersionString")?;
    let build = info(&app, "CFBundleVersion")?;
    let bundle = bundle_mb(&app)?;
    wait_owner_away()?;
    let mut process = OwnedApp::spawn(&app.join("Contents/MacOS").join(executable), true)?;
    process.wait_ready(Duration::from_secs(30))?;
    process.wait(Duration::from_secs(10))?;
    let start = process.snapshot(&app, false)?;
    process.wait(Duration::from_secs_f64(settle))?;
    let end = process.snapshot(&app, false)?;
    let (cpu, rss) = aggregate(&start, &end, settle)?;
    let pid = process.pid().to_string();
    let (foot, _) = footprint(&command("vmmap", &["--summary", &pid])?)?;
    let mapped = mappings(&command("vmmap", &[&pid])?)?;
    process.check_alive()?;
    drop(process);
    let stamp = timestamp()?;
    let mut commit = command("git", &["rev-parse", "--short", "HEAD"])
        .map(|s| s.trim().to_owned())
        .unwrap_or_else(|_| "-".into());
    if command("git", &["status", "--porcelain"]).is_ok_and(|s| !s.trim().is_empty()) {
        commit.push_str("+dirty");
    }
    let cpu_name = nonempty_command("sysctl", &["-n", "machdep.cpu.brand_string"])?;
    let memory = nonempty_command("sysctl", &["-n", "hw.memsize"])?
        .parse::<u64>()
        .map_err(|_| "sysctl hw.memsize 无效")?
        / 1024
        / 1024
        / 1024;
    let system = nonempty_command("sw_vers", &["-productVersion"])?;
    let rows = vec![
        (
            "空闲 CPU(累计差值,折算每 60s)",
            format!("{cpu:.2} s"),
            budget.idle_cpu_seconds_per_60s_max,
            cpu <= budget.idle_cpu_seconds_per_60s_max,
        ),
        (
            "Physical footprint",
            format!("{foot:.1} MB"),
            budget.footprint_mb_max,
            foot <= budget.footprint_mb_max,
        ),
        (
            "RSS",
            format!("{rss:.1} MB"),
            budget.rss_mb_max,
            rss <= budget.rss_mb_max,
        ),
        (
            "包体",
            format!("{bundle:.1} MB"),
            budget.bundle_mb_max,
            bundle <= budget.bundle_mb_max,
        ),
        (
            "空闲时索引映射段",
            mapped.to_string(),
            budget.index_mappings_while_idle_max as f64,
            mapped <= budget.index_mappings_while_idle_max,
        ),
    ];
    println!("### 发布门 · {stamp} · {version} ({build}) · commit {commit} · {cpu_name}/{memory}GB/macOS {system} · 静置 {}s\n",o.settle);
    println!("| 指标 | 实测 | 预算 | 结果 |\n|---|---|---|---|");
    for (name, value, limit, passed) in &rows {
        println!(
            "| {name} | {value} | ≤ {limit} | {} |",
            if *passed { "通过" } else { "**超标**" }
        );
    }
    println!("\n口径:CPU=`ps -o time=` 累计差值;footprint=`vmmap --summary`;映射段=`vmmap | grep -c cities.ttcity`;包体=`du -sk`。");
    Ok(rows.iter().all(|r| r.3))
}
fn main() -> ExitCode {
    install_signals();
    let o = match options(env::args().skip(1)) {
        Ok(o) => o,
        Err(e) => {
            eprintln!("{e}");
            return ExitCode::from(2);
        }
    };
    match run(o) {
        Ok(true) => ExitCode::SUCCESS,
        Ok(false) => ExitCode::from(1),
        Err(e) => {
            eprintln!("发布门失败: {e}");
            ExitCode::from(1)
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_missing_or_invalid_duration() {
        for args in [
            vec!["--settle"],
            vec!["--settle", "0"],
            vec!["--settle", "NaN"],
            vec!["--app"],
            vec!["--bogus"],
        ] {
            assert!(options(args.into_iter().map(str::to_owned)).is_err());
        }
    }
    #[test]
    fn real_budget_parses_without_relaxation() {
        let b: Budget = serde_json::from_str(include_str!("../../../Tools/budget.json")).unwrap();
        b.validate().unwrap();
        assert_eq!(b.idle_cpu_seconds_per_60s_max, 0.1);
        assert_eq!(b.footprint_mb_max, 20.);
        assert_eq!(b.rss_mb_max, 95.);
        assert_eq!(b.bundle_mb_max, 40.);
        assert_eq!(b.index_mappings_while_idle_max, 0);
    }
}
