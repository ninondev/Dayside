// SPDX-License-Identifier: GPL-3.0-only
//! 峰值量尺。
//!
//! 发布门（`release_gate`）量的是**静置 60 秒**：菜单栏就绪后什么都不做。这里量的是**用起来**的那几下：
//! 启动到就绪花了多少、打开每一片工具页各花多少 CPU、footprint 涨到多少、峰值到过多少、
//! 城市索引有没有被映射进来。每个场景都**重新启动一次** App，峰值才不会互相累加。
//!
//! 页面靠 `dayside://tools?feature=<页>` 与 `dayside://convert?text=<句>` 打开（Release 里本来就有的自动化面）；
//! 隔离预览允许这两种纯导航命令，所以不必碰完整候选、不弹 TCC 框。
//!
//! 采样器、就绪信号、进程归属与清理与发布门共用同一份 `support/measurement.rs`。
//! 口径：CPU = `ps -o time=` 累计差值（场景内增量）；footprint 与峰值 = `vmmap --summary`；
//! 映射段 = `vmmap | grep -c cities.ttcity`。
#[path = "support/measurement.rs"]
mod measurement;
use measurement::*;
use std::{
    env,
    path::{Path, PathBuf},
    process::{Command, ExitCode, Stdio},
    time::{Duration, Instant},
};

/// 场景表：名字、要发的 URL（`None` = 只启动）、说明。
const SCENARIOS: &[(&str, Option<&str>, &str)] = &[
    ("launch", None, "启动到菜单栏就绪，再静 3 秒"),
    ("tools", Some("dayside://tools"), "打开工具窗（默认页）"),
    ("planner", Some("dayside://tools?feature=planner"), "找碰头时间"),
    ("agenda", Some("dayside://tools?feature=agenda"), "日历"),
    ("people", Some("dayside://tools?feature=people"), "人物时钟"),
    ("convert", Some("dayside://convert?text=9am%20Tokyo"), "换算一句话（要查城市索引）"),
    ("timers", Some("dayside://tools?feature=timers"), "计时器"),
    ("dstWatch", Some("dayside://tools?feature=dstWatch"), "夏令时提醒（39 条规则自检）"),
    ("astronomy", Some("dayside://tools?feature=astronomy"), "太阳与月亮"),
    ("markets", Some("dayside://tools?feature=markets"), "市场时钟（休市日按规则算）"),
    ("travel", Some("dayside://tools?feature=travel"), "旅行"),
    ("sharing", Some("dayside://tools?feature=sharing"), "分享（预览 + 二维码）"),
];

struct Options {
    app: PathBuf,
    dwell: f64,
    only: Vec<String>,
}

fn parse(args: env::Args) -> Result<Options> {
    let mut o = Options { app: PathBuf::new(), dwell: 6.0, only: vec![] };
    let mut args = args.skip(1);
    while let Some(a) = args.next() {
        match a.as_str() {
            "--app" => o.app = args.next().ok_or("--app 缺少路径")?.into(),
            "--dwell" => o.dwell = settle_seconds(&args.next().ok_or("--dwell 缺少秒数")?)?,
            "--scenario" => o.only.push(args.next().ok_or("--scenario 缺少名字")?),
            other => return Err(format!("不认识的参数：{other}")),
        }
    }
    if o.app.as_os_str().is_empty() {
        return Err("用法：Tools/peak_gate.sh --app <隔离预览.app> [--dwell 6] [--scenario launch …]".into());
    }
    for name in &o.only {
        if !SCENARIOS.iter().any(|(n, _, _)| n == name) {
            return Err(format!("没有这个场景：{name}（可选：{}）", SCENARIOS.iter().map(|s| s.0).collect::<Vec<_>>().join(" ")));
        }
    }
    Ok(o)
}

/// `vmmap --summary` 里的「Physical footprint (peak)」。
fn footprint_peak(raw: &str) -> Result<f64> {
    for line in raw.lines() {
        if let Some(value) = line.trim().strip_prefix("Physical footprint (peak):") {
            let token = value.split_whitespace().next().ok_or("峰值为空")?;
            return size_mb(token);
        }
    }
    Err("vmmap 未返回 Physical footprint (peak)。".into())
}

struct Sample {
    name: &'static str,
    ready_secs: f64,
    /// exec → App.init（dyld 与静态初始化）、App.init → 就绪（我们自己的代码），App 自己报的。
    init_secs: Option<f64>,
    ours_secs: Option<f64>,
    cpu_secs: f64,
    footprint: f64,
    peak: f64,
    rss: f64,
    mapped: usize,
}

fn run_scenario(app: &Path, executable: &Path, name: &'static str, url: Option<&str>, dwell: f64) -> Result<Sample> {
    if processes()?.iter().any(|p| has_bundle_process(p, app)) {
        return Err(format!("already running: {}", app.display()));
    }
    wait_owner_away()?;
    let started = Instant::now();
    let mut process = OwnedApp::spawn(executable, true)?;
    process.wait_ready(Duration::from_secs(30))?;
    let ready_secs = started.elapsed().as_secs_f64();
    let (init_secs, ours_secs) = launch_phases(&process.ready_log().unwrap_or_default());
    // 就绪后再静一小会儿，让启动尾巴（Spotlight 索引、登录项登记）落定，场景内的 CPU 才只算场景自己的。
    process.wait(Duration::from_secs(3))?;
    let before = process.snapshot(app, true)?;
    if let Some(url) = url {
        wait_owner_away()?;
        let status = Command::new("/usr/bin/open")
            .arg("-a").arg(app).arg(url)
            .stdout(Stdio::null()).stderr(Stdio::null())
            .status()
            .map_err(|e| format!("open 失败：{e}"))?;
        if !status.success() {
            return Err(format!("open 退出码 {status}：{url}"));
        }
    }
    process.wait(Duration::from_secs_f64(dwell))?;
    let after = process.snapshot(app, true)?;
    let (cpu_per60, rss) = aggregate(&before, &after, dwell)?;
    let cpu_secs = cpu_per60 * dwell / 60.0;
    let pid = process.pid().to_string();
    let summary = command("vmmap", &["--summary", &pid])?;
    let (footprint, _) = footprint(&summary)?;
    let peak = footprint_peak(&summary)?;
    let mapped = mappings(&command("vmmap", &[&pid])?)?;
    process.check_alive()?;
    drop(process);
    Ok(Sample { name, ready_secs, init_secs, ours_secs, cpu_secs, footprint, peak, rss, mapped })
}

/// 从 App 的就绪日志里读两段：`MEANTIME_RELEASE_GATE_INIT <exec 起秒数>` 与 `…READY_AT <exec 起秒数>`。
fn launch_phases(log: &str) -> (Option<f64>, Option<f64>) {
    let value = |prefix: &str| {
        log.lines()
            .find_map(|l| l.strip_prefix(prefix))
            .and_then(|v| v.trim().parse::<f64>().ok())
            .filter(|v| v.is_finite())
    };
    let init = value("MEANTIME_RELEASE_GATE_INIT ");
    let ready = value("MEANTIME_RELEASE_GATE_READY_AT ");
    (init, match (init, ready) { (Some(i), Some(r)) if r >= i => Some(r - i), _ => None })
}

fn run(o: Options) -> Result<()> {
    let app = app_path(&o.app)?;
    let executable = app.join("Contents/MacOS").join(info(&app, "CFBundleExecutable")?);
    let version = info(&app, "CFBundleShortVersionString").unwrap_or_else(|_| "-".into());
    let stamp = timestamp()?;
    println!("### 峰值量尺 · {stamp} · {version} · {} · 每场景重新启动，页打开后停 {:.0} 秒\n", app.display(), o.dwell);
    println!("| 场景 | 说明 | 就绪耗时（dyld + 我们） | 场景内 CPU | footprint | footprint 峰值 | RSS | 索引映射段 |");
    println!("|---|---|---|---|---|---|---|---|");
    let mut failures = 0;
    for (name, url, note) in SCENARIOS {
        if !o.only.is_empty() && !o.only.iter().any(|n| n == name) {
            continue;
        }
        match run_scenario(&app, &executable, name, *url, o.dwell) {
            Ok(s) => {
                let phases = match (s.init_secs, s.ours_secs) {
                    (Some(i), Some(o)) => format!("{:.2} s（{i:.2} + {o:.2}）", s.ready_secs),
                    _ => format!("{:.2} s", s.ready_secs),
                };
                println!(
                    "| {} | {} | {} | {:.2} s | {:.1} MB | {:.1} MB | {:.1} MB | {} |",
                    s.name, note, phases, s.cpu_secs, s.footprint, s.peak, s.rss, s.mapped
                )
            }
            Err(e) => {
                failures += 1;
                println!("| {name} | {note} | 失败 | | | | | {e} |");
            }
        }
        // 两个场景之间留一口气，让 LaunchServices 与窗口服务收尾。
        std::thread::sleep(Duration::from_millis(800));
    }
    println!("\n口径：就绪耗时 = 从 exec 到菜单栏就绪信号，括号里是 App 自报的两段（exec → App.init 的 dyld 与静态初始化，App.init → 就绪的我们自己的代码；刚换签名后的首次启动前一段会因系统验签虚高，看第二次）；场景内 CPU = 就绪后静 3 秒起、发 URL 后停 dwell 秒内的 `ps -o time=` 增量；footprint 与峰值 = `vmmap --summary`（峰值是进程生命周期内的最高点）；映射段 = `vmmap | grep -c cities.ttcity`。");
    if failures > 0 {
        return Err(format!("{failures} 个场景失败"));
    }
    Ok(())
}

fn main() -> ExitCode {
    install_signals();
    let options = match parse(env::args()) {
        Ok(o) => o,
        Err(e) => {
            eprintln!("{e}");
            return ExitCode::from(2);
        }
    };
    match run(options) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("{e}");
            ExitCode::from(if e.starts_with("already running:") { 3 } else { 1 })
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn peak_line_is_parsed_and_missing_peak_is_an_error() {
        let raw = "Physical footprint:         16.7M\nPhysical footprint (peak):  124.0M\n";
        assert_eq!(footprint_peak(raw).unwrap(), 124.0);
        assert!(footprint_peak("Physical footprint: 16.7M\n").is_err());
    }

    #[test]
    fn launch_phases_come_from_the_two_log_lines() {
        let log = "noise\nMEANTIME_RELEASE_GATE_INIT 0.02\nMEANTIME_RELEASE_GATE_READY_AT 0.16\nMEANTIME_RELEASE_GATE_READY\n";
        let (init, ours) = launch_phases(log);
        assert_eq!(init, Some(0.02));
        assert!((ours.unwrap() - 0.14).abs() < 1e-9);
        assert_eq!(launch_phases("MEANTIME_RELEASE_GATE_READY\n"), (None, None));
        // 就绪早于 init（不可能，但坏日志不许算出负数）。
        assert_eq!(launch_phases("MEANTIME_RELEASE_GATE_INIT 1.0\nMEANTIME_RELEASE_GATE_READY_AT 0.5\n"), (Some(1.0), None));
    }

    #[test]
    fn every_scenario_name_is_unique_and_urls_are_navigation_only() {
        let mut names: Vec<_> = SCENARIOS.iter().map(|s| s.0).collect();
        names.sort_unstable();
        names.dedup();
        assert_eq!(names.len(), SCENARIOS.len());
        for (_, url, _) in SCENARIOS {
            if let Some(url) = url {
                assert!(url.starts_with("dayside://tools") || url.starts_with("dayside://convert"), "{url}");
            }
        }
    }
}
