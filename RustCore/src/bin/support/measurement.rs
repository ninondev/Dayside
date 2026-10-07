// SPDX-License-Identifier: GPL-3.0-only
//! Native macOS sampling services and ownership-aware process lifetime.
//! A failed sample stays an error; it is never converted into zero usage.
#![allow(dead_code)]
use std::{
    collections::{HashMap, HashSet},
    fs::{self, File, OpenOptions},
    io::Read,
    os::{
        fd::AsRawFd,
        unix::{fs::OpenOptionsExt, process::CommandExt},
    },
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::atomic::{AtomicI32, Ordering},
    thread,
    time::{Duration, Instant},
};

pub type Result<T> = std::result::Result<T, String>;
static SIGNAL: AtomicI32 = AtomicI32::new(0);
extern "C" fn interrupted(signal: i32) {
    SIGNAL.store(signal, Ordering::Relaxed);
}
pub fn install_signals() {
    for signal in [libc::SIGINT, libc::SIGTERM, libc::SIGHUP] {
        // SAFETY: the handler only writes a lock-free atomic and does not call
        // allocation, I/O or other non-async-signal-safe operations.
        unsafe {
            let mut action: libc::sigaction = std::mem::zeroed();
            action.sa_sigaction = interrupted as *const () as usize;
            libc::sigemptyset(&mut action.sa_mask);
            libc::sigaction(signal, &action, std::ptr::null_mut());
        }
    }
}
pub fn check_signal() -> Result<()> {
    let signal = SIGNAL.load(Ordering::Relaxed);
    if signal == 0 {
        Ok(())
    } else {
        Err(format!("采样已被信号 {signal} 中断。"))
    }
}
pub fn command(program: &str, args: &[&str]) -> Result<String> {
    command_bounded(program, args, false, Duration::from_secs(30))
}
fn command_bounded(
    program: &str,
    args: &[&str],
    ignore_signal: bool,
    timeout: Duration,
) -> Result<String> {
    if !ignore_signal {
        check_signal()?;
    }
    let mut child = Command::new(program)
        .args(args)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("无法执行 {program}: {e}"))?;
    let mut stdout = child.stdout.take().expect("piped stdout");
    let mut stderr = child.stderr.take().expect("piped stderr");
    fn nonblocking(pipe: &impl AsRawFd) -> Result<()> {
        // SAFETY: each fd is an owned pipe kept alive throughout this command.
        let flags = unsafe { libc::fcntl(pipe.as_raw_fd(), libc::F_GETFL) };
        if flags < 0
            || unsafe { libc::fcntl(pipe.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0
        {
            return Err(std::io::Error::last_os_error().to_string());
        }
        Ok(())
    }
    if let Err(e) = nonblocking(&stdout).and_then(|_| nonblocking(&stderr)) {
        let _ = child.kill();
        let _ = child.wait();
        return Err(format!("无法设置 {program} 输出管道: {e}"));
    }
    fn drain(reader: &mut impl Read, output: &mut Vec<u8>) -> Result<bool> {
        let mut buffer = [0; 65536];
        for _ in 0..16 {
            match reader.read(&mut buffer) {
                Ok(0) => return Ok(true),
                Ok(n) => output.extend_from_slice(&buffer[..n]),
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => return Ok(true),
                Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                Err(e) => return Err(e.to_string()),
            }
        }
        Ok(false)
    }
    let mut output = vec![];
    let mut errors = vec![];
    let mut exited = None;
    let until = Instant::now() + timeout;
    let status = loop {
        if !ignore_signal {
            if let Err(e) = check_signal() {
                break Err(e);
            }
        }
        if Instant::now() >= until {
            break Err(format!(
                "{program} 采样命令超过 {} 秒;本次样本无效。",
                timeout.as_secs_f64()
            ));
        }
        let drained = match drain(&mut stdout, &mut output)
            .and_then(|a| drain(&mut stderr, &mut errors).map(|b| a && b))
        {
            Ok(done) => done,
            Err(e) => break Err(format!("无法读取 {program} 输出: {e}")),
        };
        if let Some(status) = exited {
            if drained {
                break Ok(status);
            }
        } else {
            match child.try_wait() {
                Ok(Some(status)) => {
                    exited = Some(status);
                    continue;
                }
                Ok(None) => {}
                Err(e) => break Err(format!("无法核对 {program} 状态: {e}")),
            }
        }
        thread::sleep(Duration::from_millis(10));
    };
    if status.is_err() {
        let _ = child.kill();
        let _ = child.wait();
    }
    let status = status?;
    if !status.success() {
        return Err(format!(
            "{program} 失败({status}): {}",
            String::from_utf8_lossy(&errors).trim()
        ));
    }
    String::from_utf8(output).map_err(|e| format!("{program} 输出不是 UTF-8: {e}"))
}
pub fn nonempty_command(program: &str, args: &[&str]) -> Result<String> {
    let s = command(program, args)?;
    let s = s.trim();
    if s.is_empty() {
        Err(format!("{program} 没有返回采样值。"))
    } else {
        Ok(s.to_owned())
    }
}
pub fn settle_seconds(raw: &str) -> Result<f64> {
    let n = raw
        .parse::<f64>()
        .map_err(|_| format!("无效采样时长: {raw}"))?;
    if n.is_finite() && n > 0. && Duration::try_from_secs_f64(n).is_ok() {
        Ok(n)
    } else {
        Err(format!("采样时长必须是可计时的正数: {raw}"))
    }
}
/// Parse decimal ps timestamps before subtraction, avoiding a floating-point
/// 0.10-second sample becoming 0.10000000000000009 at a hard budget boundary.
fn cpu_nanoseconds(raw: &str) -> Result<u128> {
    let raw = raw.trim();
    let invalid = || format!("无效 CPU 累计时间: {raw}");
    let integer = |s: &str| s.parse::<u128>().map_err(|_| invalid());
    let (days, clock) = if let Some((d, t)) = raw.split_once('-') {
        (integer(d)?, t)
    } else {
        (0, raw)
    };
    let fields: Vec<_> = clock.split(':').collect();
    if fields.len() != 2 && fields.len() != 3 {
        return Err(invalid());
    }
    let last = fields.last().unwrap();
    let (seconds, fraction) = last.split_once('.').unwrap_or((last, ""));
    let seconds = integer(seconds)?;
    if seconds >= 60 || fraction.len() > 9 || !fraction.bytes().all(|b| b.is_ascii_digit()) {
        return Err(invalid());
    }
    let nanos = if fraction.is_empty() {
        0
    } else {
        integer(fraction)? * 10u128.pow(9 - fraction.len() as u32)
    };
    let minutes = integer(fields[fields.len() - 2])?;
    if fields.len() == 3 && minutes >= 60 {
        return Err(invalid());
    }
    let hours = if fields.len() == 3 {
        integer(fields[0])?
    } else {
        0
    };
    days.checked_mul(86400)
        .and_then(|n| hours.checked_mul(3600).and_then(|h| n.checked_add(h)))
        .and_then(|n| minutes.checked_mul(60).and_then(|m| n.checked_add(m)))
        .and_then(|n| n.checked_add(seconds))
        .and_then(|n| n.checked_mul(1_000_000_000))
        .and_then(|n| n.checked_add(nanos))
        .ok_or_else(invalid)
}
pub fn cpu_seconds(raw: &str) -> Result<f64> {
    Ok(cpu_nanoseconds(raw)? as f64 / 1_000_000_000.)
}
pub fn size_mb(raw: &str) -> Result<f64> {
    let raw = raw.trim();
    let (number, multiple) = match raw.chars().last() {
        Some('K') => (&raw[..raw.len() - 1], 1. / 1024.),
        Some('M') => (&raw[..raw.len() - 1], 1.),
        Some('G') => (&raw[..raw.len() - 1], 1024.),
        Some('B') => (&raw[..raw.len() - 1], 1. / 1048576.),
        _ => return Err(format!("缺少可识别的内存单位(K/M/G/B): {raw}")),
    };
    let n = number
        .parse::<f64>()
        .map_err(|_| format!("无效内存值: {raw}"))?
        * multiple;
    if n.is_finite() && n >= 0. {
        Ok(n)
    } else {
        Err(format!("无效内存值: {raw}"))
    }
}
pub fn footprint(raw: &str) -> Result<(f64, String)> {
    for line in raw.lines() {
        if let Some(value) = line.trim().strip_prefix("Physical footprint:") {
            let token = value
                .split_whitespace()
                .next()
                .ok_or("Physical footprint 为空")?;
            return Ok((size_mb(token)?, token.to_owned()));
        }
    }
    Err("vmmap 未返回 Physical footprint。".into())
}
pub fn mappings(raw: &str) -> Result<usize> {
    if !raw.contains("Process:")
        || !(raw.contains("REGION TYPE") || raw.contains("Virtual Memory Map"))
    {
        return Err("vmmap 未返回有效内存映射报告。".into());
    }
    Ok(raw
        .lines()
        .filter(|line| line.contains("cities.ttcity"))
        .count())
}
#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub struct Identity {
    pub pid: u32,
    pub started: String,
}
#[derive(Clone, Debug)]
pub struct Process {
    pub identity: Identity,
    pub parent: u32,
    pub group: u32,
    pub cpu: u128,
    pub rss_kb: u64,
    pub command: String,
}
fn token<'a>(remaining: &mut &'a str) -> Option<&'a str> {
    *remaining = remaining.trim_start();
    let end = remaining
        .find(char::is_whitespace)
        .unwrap_or(remaining.len());
    if end == 0 {
        return None;
    }
    let found = &remaining[..end];
    *remaining = &remaining[end..];
    Some(found)
}
pub fn parse_processes(raw: &str) -> Result<Vec<Process>> {
    let mut out = vec![];
    for line in raw.lines().filter(|s| !s.trim().is_empty()) {
        let mut rest = line;
        let mut fields = vec![];
        for _ in 0..10 {
            fields.push(token(&mut rest).ok_or_else(|| format!("不完整的 ps 行: {line}"))?);
        }
        let number = |i: usize| {
            fields[i]
                .parse::<u32>()
                .map_err(|_| format!("无效 ps 进程字段: {line}"))
        };
        let rss_kb = fields[9]
            .parse::<u64>()
            .map_err(|_| format!("无效 RSS: {line}"))?;
        out.push(Process {
            identity: Identity {
                pid: number(0)?,
                started: fields[3..8].join(" "),
            },
            parent: number(1)?,
            group: number(2)?,
            cpu: cpu_nanoseconds(fields[8])?,
            rss_kb,
            command: rest.trim_start().to_owned(),
        });
    }
    if out.is_empty() {
        Err("ps 返回空进程表;本次不采样。".into())
    } else {
        Ok(out)
    }
}
pub fn processes() -> Result<Vec<Process>> {
    parse_processes(&command(
        "ps",
        &[
            "-axo",
            "pid=,ppid=,pgid=,lstart=,time=,rss=,command=",
            "-ww",
        ],
    )?)
}
pub fn info(app: &Path, key: &str) -> Result<String> {
    let plist = app.join("Contents/Info.plist");
    if !plist.is_file() {
        return Err(format!("找不到 Info.plist: {}", plist.display()));
    }
    // PlistBuddy reads the specified XML/binary file directly. `defaults`
    // would make bundle metadata depend on the user's CFPreferences service.
    nonempty_command(
        "/usr/libexec/PlistBuddy",
        &["-c", &format!("Print :{key}"), &plist.to_string_lossy()],
    )
    .map_err(|e| format!("读取 {} 的 {key} 失败: {e}", plist.display()))
}
pub fn bundle_mb(app: &Path) -> Result<f64> {
    let out = command("du", &["-sk", &app.to_string_lossy()])?;
    let kb = out
        .split_whitespace()
        .next()
        .ok_or("du 没有返回包体大小")?
        .parse::<u64>()
        .map_err(|_| "du 返回无效包体大小")?;
    Ok(kb as f64 / 1024.)
}
pub fn timestamp() -> Result<String> {
    nonempty_command("date", &["+%Y-%m-%d %H:%M %Z"])
}
pub fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .to_owned()
}
pub fn measurement_state(home: &Path) -> Result<String> {
    let pause_file = home.join(".config/dayside/measure.state");
    match fs::symlink_metadata(&pause_file) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok("FREE".into()),
        Err(e) => return Err(format!("measurement window: {e}")),
        Ok(_) => {}
    }
    fs::read_to_string(pause_file).map_err(|e| format!("measurement window: {e}"))
}

// 每次实际启动前重读键鼠空闲时间，构建与命令行测试不走此门。
pub fn wait_owner_away() -> Result<()> {
    let status = Command::new("/bin/bash")
        .arg(repo_root().join("Tools/owner_away.sh"))
        .arg("--wait")
        .status()
        .map_err(|e| format!("launch idle gate: {e}"))?;
    if !status.success() {
        return Err(format!("launch idle gate exited {status}"));
    }
    let home = std::env::var_os("HOME").ok_or("measurement window: HOME unavailable")?;
    // 等候期间可能开始别的测量，放行前再读 measure.state。
    let state = measurement_state(Path::new(&home))?;
    if state.trim() != "FREE" {
        return Err("measurement window unavailable".into());
    }
    Ok(())
}
pub fn app_path(raw: &Path) -> Result<PathBuf> {
    let p = fs::canonicalize(raw).map_err(|e| format!("找不到 app {}: {e}", raw.display()))?;
    if !p.is_dir() {
        return Err(format!("不是 app 目录: {}", p.display()));
    }
    Ok(p)
}
pub fn has_bundle_process(process: &Process, app: &Path) -> bool {
    process.command.contains(&format!("{}/", app.display()))
}

struct ReadyLog {
    path: PathBuf,
}
impl ReadyLog {
    fn create() -> Result<(Self, File)> {
        let path = std::env::temp_dir().join(format!(
            "dayside-gate-ready-{}-{}.log",
            std::process::id(),
            uuid::Uuid::new_v4()
        ));
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&path)
            .map_err(|e| format!("无法建立启动日志 {}: {e}", path.display()))?;
        Ok((Self { path }, file))
    }
    fn contents(&self) -> Result<String> {
        fs::read_to_string(&self.path)
            .map_err(|e| format!("无法读取启动日志 {}: {e}", self.path.display()))
    }
}
impl Drop for ReadyLog {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
    }
}
/// A private process group plus exact PID/start-time identities keep cleanup
/// scoped to this launch. It never sends pkill to a bundle-name pattern.
pub struct OwnedApp {
    child: Child,
    main: Identity,
    known: HashSet<Identity>,
    log: Option<ReadyLog>,
}
impl OwnedApp {
    pub fn spawn(executable: &Path, ready: bool) -> Result<Self> {
        let mut command = Command::new(executable);
        command.process_group(0).stdin(Stdio::null());
        let log = if ready {
            let (log, file) = ReadyLog::create()?;
            command
                .env("MEANTIME_RELEASE_GATE", "1")
                .stdout(file.try_clone().map_err(|e| e.to_string())?)
                .stderr(file);
            Some(log)
        } else {
            command.stdout(Stdio::null()).stderr(Stdio::null());
            None
        };
        let child = command
            .spawn()
            .map_err(|e| format!("无法启动 {}: {e}", executable.display()))?;
        Self::from_child(child, log)
    }
    fn from_child(child: Child, log: Option<ReadyLog>) -> Result<Self> {
        let pid = child.id();
        let mut app = Self {
            child,
            main: Identity {
                pid,
                started: String::new(),
            },
            known: HashSet::new(),
            log,
        };
        let snapshot = processes()?;
        let main = snapshot
            .iter()
            .find(|p| p.identity.pid == pid)
            .ok_or("app 在建立采样身份前退出。")?;
        app.main = main.identity.clone();
        app.known.insert(app.main.clone());
        app.discover(&snapshot);
        Ok(app)
    }
    /// Build processes receive the same signal-aware ownership guard. Their
    /// inherited terminal output stays visible and no build child is detached.
    pub fn build(command: &mut Command) -> Result<()> {
        command.process_group(0);
        let child = command.spawn().map_err(|e| format!("无法执行构建: {e}"))?;
        let mut build = Self::from_child(child, None)?;
        loop {
            check_signal()?;
            match build
                .child
                .try_wait()
                .map_err(|e| format!("无法核对构建进程: {e}"))?
            {
                Some(status) if status.success() => return Ok(()),
                Some(status) => return Err(format!("Release 构建失败: {status}")),
                None => thread::sleep(Duration::from_millis(100)),
            }
        }
    }
    pub fn pid(&self) -> u32 {
        self.main.pid
    }
    pub fn check_alive(&mut self) -> Result<()> {
        check_signal()?;
        match self.child.try_wait() {
            Ok(None) => Ok(()),
            Ok(Some(s)) => Err(format!(
                "app 在采样完成前退出({s});本次没有有效资源结果。{}",
                self.log
                    .as_ref()
                    .and_then(|l| l.contents().ok())
                    .map(|s| format!("\n启动日志:\n{s}"))
                    .unwrap_or_default()
            )),
            Err(e) => Err(format!("无法核对 app 进程状态: {e}")),
        }
    }
    fn discover(&mut self, snapshot: &[Process]) {
        let live_main = snapshot.iter().any(|p| p.identity == self.main);
        loop {
            let before = self.known.len();
            let parent_ids: HashSet<_> = snapshot
                .iter()
                .filter(|p| self.known.contains(&p.identity))
                .map(|p| p.identity.pid)
                .collect();
            for p in snapshot {
                if (live_main && p.group == self.main.pid) || parent_ids.contains(&p.parent) {
                    self.known.insert(p.identity.clone());
                }
            }
            if before == self.known.len() {
                break;
            }
        }
    }
    pub fn snapshot(&mut self, app: &Path, multiple: bool) -> Result<Vec<Process>> {
        self.check_alive()?;
        let rows = processes()?;
        self.discover(&rows);
        if !rows.iter().any(|p| p.identity == self.main) {
            return Err("采样时找不到本次启动的 app 身份。".into());
        }
        if multiple {
            if let Some(p) = rows
                .iter()
                .find(|p| has_bundle_process(p, app) && !self.known.contains(&p.identity))
            {
                return Err(format!(
                    "同一 app 目录出现无法归属本次启动的进程 {}: {};本次停止采样。",
                    p.identity.pid, p.command
                ));
            }
        }
        let selected: Vec<_> = rows
            .into_iter()
            .filter(|p| {
                p.identity == self.main
                    || (multiple && self.known.contains(&p.identity) && has_bundle_process(p, app))
            })
            .collect();
        if selected.iter().any(|p| p.rss_kb == 0) {
            return Err("存活 app 的 RSS 采样为 0;本次不作有效结果。".into());
        }
        self.check_alive()?;
        Ok(selected)
    }
    pub fn wait(&mut self, duration: Duration) -> Result<()> {
        let until = Instant::now()
            .checked_add(duration)
            .ok_or("采样时长超出时钟范围")?;
        loop {
            self.check_alive()?;
            let now = Instant::now();
            if now >= until {
                return Ok(());
            }
            thread::sleep((until - now).min(Duration::from_millis(100)));
        }
    }
    /// 就绪日志的全文（峰值量尺从里面读 `MEANTIME_RELEASE_GATE_INIT` / `_READY_AT` 两段耗时）。
    pub fn ready_log(&self) -> Result<String> {
        self.log.as_ref().ok_or("就绪采样缺少日志")?.contents()
    }
    pub fn wait_ready(&mut self, timeout: Duration) -> Result<()> {
        let until = Instant::now() + timeout;
        loop {
            self.check_alive()?;
            let log = self.log.as_ref().ok_or("就绪采样缺少日志")?;
            let text = log.contents()?;
            if text
                .lines()
                .any(|line| line == "MEANTIME_RELEASE_GATE_READY")
            {
                return self.check_alive();
            }
            if Instant::now() >= until {
                return Err(format!(
                    "发布门失败:{} 秒内未收到菜单栏就绪信号;本次不采样。\n{text}",
                    timeout.as_secs_f64()
                ));
            }
            thread::sleep(Duration::from_millis(100));
        }
    }
    fn cleanup(&mut self) {
        // Signal handling has already transferred control to normal Rust code;
        // cleanup itself must not be cancelled by the remembered signal.
        let cleanup_snapshot = || {
            command_bounded(
                "ps",
                &[
                    "-axo",
                    "pid=,ppid=,pgid=,lstart=,time=,rss=,command=",
                    "-ww",
                ],
                true,
                Duration::from_secs(1),
            )
            .ok()
            .and_then(|s| parse_processes(&s).ok())
        };
        let snapshot = cleanup_snapshot();
        if let Some(rows) = snapshot {
            self.discover(&rows);
            for p in rows.iter().filter(|p| self.known.contains(&p.identity)) {
                // SAFETY: this PID and creation time were revalidated above,
                // and ownership comes from the private group/descendant tree.
                unsafe {
                    libc::kill(p.identity.pid as i32, libc::SIGTERM);
                }
            }
            let until = Instant::now() + Duration::from_secs(1);
            while Instant::now() < until {
                if self.child.try_wait().ok().flatten().is_some() {
                    break;
                }
                thread::sleep(Duration::from_millis(25));
            }
            if let Some(rows) = cleanup_snapshot() {
                for p in rows.iter().filter(|p| self.known.contains(&p.identity)) {
                    // SAFETY: same exact identity and ownership check as above.
                    unsafe {
                        libc::kill(p.identity.pid as i32, libc::SIGKILL);
                    }
                }
            }
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
impl Drop for OwnedApp {
    fn drop(&mut self) {
        self.cleanup();
    }
}
pub fn aggregate(start: &[Process], end: &[Process], settle: f64) -> Result<(f64, f64)> {
    if start.is_empty() || end.is_empty() {
        return Err("进程采样为空。".into());
    }
    let previous: HashMap<_, _> = start.iter().map(|p| (p.identity.clone(), p.cpu)).collect();
    let current: HashSet<_> = end.iter().map(|p| p.identity.clone()).collect();
    if start.iter().any(|p| !current.contains(&p.identity)) {
        return Err("采样窗口内有进程退出或被替换;无法完整累计 CPU。".into());
    }
    let mut delta = 0u128;
    let mut rss = 0u64;
    for p in end {
        let diff = p
            .cpu
            .checked_sub(previous.get(&p.identity).copied().unwrap_or(0))
            .ok_or("CPU 累计时间倒退;本次样本无效。")?;
        delta = delta.checked_add(diff).ok_or("CPU 累计时间合计溢出")?;
        rss = rss.checked_add(p.rss_kb).ok_or("RSS 合计溢出")?;
    }
    let per60 = (delta as f64 / 1_000_000_000.) * 60. / settle;
    if !per60.is_finite() {
        return Err("CPU 折算结果无效。".into());
    }
    Ok((per60, rss as f64 / 1024.))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn cpu_formats_and_invalid_samples() {
        assert_eq!(cpu_seconds("01:02.50").unwrap(), 62.5);
        assert_eq!(cpu_seconds("1:02:03.25").unwrap(), 3723.25);
        assert_eq!(cpu_seconds("2-01:02:03").unwrap(), 176523.);
        for s in ["", "0", "bad", "0:NaN", "-1:00", "0:60", "1:99:00"] {
            assert!(cpu_seconds(s).is_err(), "{s}");
        }
    }
    #[test]
    fn memory_units_and_missing_footprint() {
        assert_eq!(size_mb("512K").unwrap(), 0.5);
        assert_eq!(size_mb("1.25G").unwrap(), 1280.);
        assert_eq!(size_mb("17.7M").unwrap(), 17.7);
        for s in ["", "12", "NaNM", "-5M"] {
            assert!(size_mb(s).is_err());
        }
        assert!(footprint("permission denied").is_err());
        assert!(mappings("").is_err());
        assert_eq!(
            mappings("Process: app [10]\nREGION TYPE\nMAPPED_FILE cities.ttcity\n").unwrap(),
            1
        );
    }
    fn process(pid: u32, cpu: f64) -> Process {
        Process {
            identity: Identity {
                pid,
                started: "Tue Sep 8 10:00:00 2026".into(),
            },
            parent: 1,
            group: pid,
            cpu: (cpu * 1_000_000_000.).round() as u128,
            rss_kb: 1024,
            command: "/app/Contents/MacOS/app".into(),
        }
    }
    #[test]
    fn no_missing_or_reset_cpu_is_zero() {
        assert!(aggregate(&[process(1, 1.)], &[], 60.).is_err());
        assert!(aggregate(&[process(1, 1.)], &[process(2, 1.)], 60.).is_err());
        assert!(aggregate(&[process(1, 2.)], &[process(1, 1.)], 60.).is_err());
        assert_eq!(
            aggregate(&[process(1, 1.)], &[process(1, 1.1), process(2, 0.2)], 60.).unwrap(),
            (0.3, 2.)
        );
    }
    #[test]
    fn decimal_cpu_sample_respects_the_exact_budget_boundary() {
        let baseline =
            parse_processes("10 1 10 Tue Sep 8 10:00:00 2026 00:01.00 2048 app").unwrap();
        let end = parse_processes("10 1 10 Tue Sep 8 10:00:00 2026 00:01.10 2048 app").unwrap();
        let (cpu, _) = aggregate(&baseline, &end, 60.).unwrap();
        assert_eq!(cpu, 0.1);
        assert!(cpu <= 0.1);
    }
    #[test]
    fn process_parser_preserves_space_in_path() {
        let p=parse_processes(" 10 1 10 Tue Sep  8 10:00:00 2026 01:02.50 2048 /Applications/A  B.app/Contents/MacOS/A  B\n").unwrap();
        assert_eq!(p[0].cpu, 62_500_000_000);
        assert_eq!(p[0].rss_kb, 2048);
        assert!(p[0].command.contains("A  B.app"));
        assert!(parse_processes("").is_err());
        assert!(parse_processes("10 1 10 Tue Sep 8 10:00:00 2026 bad 1 app").is_err());
    }

    #[test]
    fn plist_metadata_reads_the_file_and_missing_keys_fail() {
        let root = std::env::temp_dir().join(format!("dayside-plist-{}", uuid::Uuid::new_v4()));
        let app = root.join("A B.app");
        fs::create_dir_all(app.join("Contents")).unwrap();
        fs::write(app.join("Contents/Info.plist"),r#"<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>试验</string><key>CFBundleVersion</key><string>17</string></dict></plist>"#).unwrap();
        assert_eq!(info(&app, "CFBundleExecutable").unwrap(), "试验");
        assert_eq!(info(&app, "CFBundleVersion").unwrap(), "17");
        let missing = info(&app, "CFBundleShortVersionString").unwrap_err();
        assert!(missing.contains("CFBundleShortVersionString"));
        fs::remove_file(app.join("Contents/Info.plist")).unwrap();
        assert!(info(&app, "CFBundleExecutable").is_err());
        assert!(!app.join("Contents/Info.plist").exists());
        fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn fake_child_must_report_ready_and_is_reaped() {
        let temp = std::env::temp_dir().join(format!("dayside-fake-{}", uuid::Uuid::new_v4()));
        fs::create_dir(&temp).unwrap();
        let script = temp.join("app");
        use std::os::unix::fs::PermissionsExt;
        fs::write(
            &script,
            "#!/bin/sh\necho MEANTIME_RELEASE_GATE_READY\nexec sleep 30\n",
        )
        .unwrap();
        fs::set_permissions(&script, fs::Permissions::from_mode(0o700)).unwrap();
        let mut app = OwnedApp::spawn(&script, true).unwrap();
        let pid = app.pid();
        app.wait_ready(Duration::from_secs(30)).unwrap();
        drop(app);
        assert!(!processes().unwrap().iter().any(|p| p.identity.pid == pid));
        fs::write(&script, "#!/bin/sh\nexec sleep 30\n").unwrap();
        let mut app = OwnedApp::spawn(&script, true).unwrap();
        assert!(app.wait_ready(Duration::from_millis(150)).is_err());
        drop(app);
        fs::remove_dir_all(temp).unwrap();
    }
}

#[cfg(test)]
#[path = "measurement_pause_tests.rs"]
mod pause_tests;
