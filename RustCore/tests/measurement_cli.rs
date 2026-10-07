// SPDX-License-Identifier: GPL-3.0-only
//! End-to-end measurement tests launch only temporary shell fixtures, never an
//! installed app. vmmap is supplied by a deterministic per-command PATH fixture.
use std::{
    fs,
    os::unix::fs::PermissionsExt,
    path::PathBuf,
    process::{Child, Command, Stdio},
    thread,
    time::{Duration, Instant},
};
struct Fixture {
    dir: PathBuf,
    app: PathBuf,
    tools: PathBuf,
}
impl Fixture {
    fn new(bad_vmmap: bool) -> Self {
        let dir =
            std::env::temp_dir().join(format!("dayside-measure-fixture-{}", uuid::Uuid::new_v4()));
        let app = dir.join("Fake.app");
        let tools = dir.join("tools");
        fs::create_dir_all(app.join("Contents/MacOS")).unwrap();
        fs::create_dir(&tools).unwrap();
        fs::write(app.join("Contents/Info.plist"),r#"<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>fake</string><key>CFBundleShortVersionString</key><string>1.0</string><key>CFBundleVersion</key><string>1</string></dict></plist>"#).unwrap();
        Self::script(&app.join("Contents/MacOS/fake"),"#!/bin/sh\necho $$ > \"$MEASUREMENT_FIXTURE_PID\"\necho MEANTIME_RELEASE_GATE_READY\nsleep 30 &\necho $! > \"$MEASUREMENT_FIXTURE_CHILD\"\nwait\n");
        Self::script(
            &tools.join("vmmap"),
            if bad_vmmap {
                "#!/bin/sh\necho 'unreadable sample' >&2\nexit 1\n"
            } else {
                "#!/bin/sh\nif [ \"$1\" = --summary ]; then echo 'Physical footprint: 15.0M'; else printf 'Process: fixture [%s]\\nREGION TYPE\\nMALLOC 1M\\n' \"$1\"; fi\n"
            },
        );
        Self { dir, app, tools }
    }
    fn script(path: &PathBuf, text: &str) {
        fs::write(path, text).unwrap();
        fs::set_permissions(path, fs::Permissions::from_mode(0o700)).unwrap();
    }
    fn command(&self, bin: &str) -> Command {
        let mut c = Command::new(bin);
        c.env(
            "PATH",
            format!(
                "{}:{}",
                self.tools.display(),
                std::env::var("PATH").unwrap_or_default()
            ),
        )
        .env("MEASUREMENT_FIXTURE_PID", self.dir.join("pid"))
        .env("MEASUREMENT_FIXTURE_CHILD", self.dir.join("child"));
        c
    }
    fn diagnostics(&self) -> Stdio {
        Stdio::from(fs::File::create(self.dir.join("stderr")).unwrap())
    }
    fn pid(&self, name: &str) -> u32 {
        let until = Instant::now() + Duration::from_secs(30);
        loop {
            if let Ok(text) = fs::read_to_string(self.dir.join(name)) {
                if let Ok(pid) = text.trim().parse() {
                    return pid;
                }
            }
            assert!(
                Instant::now() < until,
                "fixture did not launch; CLI stderr: {}",
                fs::read_to_string(self.dir.join("stderr")).unwrap_or_default()
            );
            thread::sleep(Duration::from_millis(25));
        }
    }
    fn launched_pid(&self, run: &mut Running, name: &str) -> u32 {
        let until = Instant::now() + Duration::from_secs(30);
        loop {
            if let Ok(text) = fs::read_to_string(self.dir.join(name)) {
                if let Ok(pid) = text.trim().parse() {
                    return pid;
                }
            }
            if let Some(status) = run.0.try_wait().unwrap() {
                panic!(
                    "fixture CLI exited before {name}: {status}; {}",
                    fs::read_to_string(self.dir.join("stderr")).unwrap_or_default()
                );
            }
            assert!(
                Instant::now() < until,
                "fixture startup exceeded the product's 30-second READY deadline; {}",
                fs::read_to_string(self.dir.join("stderr")).unwrap_or_default()
            );
            thread::sleep(Duration::from_millis(25));
        }
    }
    fn assert_gone(pid: u32) {
        let until = Instant::now() + Duration::from_secs(3);
        while unsafe { libc::kill(pid as i32, 0) } == 0 {
            assert!(
                Instant::now() < until,
                "fixture child {pid} survived cleanup"
            );
            thread::sleep(Duration::from_millis(25));
        }
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.dir);
    }
}
struct Running(Child);
impl Drop for Running {
    fn drop(&mut self) {
        if self.0.try_wait().ok().flatten().is_none() {
            unsafe {
                libc::kill(self.0.id() as i32, libc::SIGTERM);
            }
            let until = Instant::now() + Duration::from_secs(3);
            while self.0.try_wait().ok().flatten().is_none() && Instant::now() < until {
                thread::sleep(Duration::from_millis(25));
            }
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }
}
#[test]
fn gate_reports_five_rows_from_valid_samples() {
    let f = Fixture::new(false);
    let output = f
        .command(env!("CARGO_BIN_EXE_release_gate"))
        .args(["--skip-build", "--settle", "0.2", "--app"])
        .arg(&f.app)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let text = String::from_utf8(output.stdout).unwrap();
    assert_eq!(text.lines().filter(|s| s.ends_with("通过 |")).count(), 5);
    assert!(text.contains("15.0 MB"));
    assert!(!text.contains("超标"));
    Fixture::assert_gone(f.pid("pid"));
    Fixture::assert_gone(f.pid("child"));
}
#[test]
fn failed_vmmap_never_produces_zero_or_a_passing_table() {
    let f = Fixture::new(true);
    let output = f
        .command(env!("CARGO_BIN_EXE_release_gate"))
        .args(["--skip-build", "--settle", "0.2", "--app"])
        .arg(&f.app)
        .output()
        .unwrap();
    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("vmmap 失败"));
    assert!(output.stdout.is_empty());
    Fixture::assert_gone(f.pid("pid"));
    Fixture::assert_gone(f.pid("child"));
}
#[test]
fn interruption_cleans_only_the_launched_tree() {
    let f = Fixture::new(false);
    let mut external = Command::new("sleep").arg("30").spawn().unwrap();
    let child = f
        .command(env!("CARGO_BIN_EXE_bench_app"))
        .arg(&f.app)
        .arg("0.2")
        .stdout(Stdio::null())
        .stderr(f.diagnostics())
        .spawn()
        .unwrap();
    let mut run = Running(child);
    let main = f.launched_pid(&mut run, "pid");
    let helper = f.launched_pid(&mut run, "child");
    unsafe {
        libc::kill(run.0.id() as i32, libc::SIGTERM);
    }
    let status = run.0.wait().unwrap();
    assert!(!status.success());
    Fixture::assert_gone(main);
    Fixture::assert_gone(helper);
    assert!(
        external.try_wait().unwrap().is_none(),
        "unrelated process was killed"
    );
    external.kill().unwrap();
    external.wait().unwrap();
}
#[test]
fn ready_then_exit_is_not_an_idle_result() {
    let f = Fixture::new(false);
    Fixture::script(
        &f.app.join("Contents/MacOS/fake"),
        "#!/bin/sh\necho MEANTIME_RELEASE_GATE_READY\nexit 1\n",
    );
    let output = f
        .command(env!("CARGO_BIN_EXE_release_gate"))
        .args(["--skip-build", "--settle", "0.2", "--app"])
        .arg(&f.app)
        .output()
        .unwrap();
    assert!(!output.status.success());
    assert!(output.stdout.is_empty());
}

#[test]
fn excess_footprint_is_nonzero_with_the_failed_metric_visible() {
    let f = Fixture::new(false);
    Fixture::script(&f.tools.join("vmmap"),"#!/bin/sh\nif [ \"$1\" = --summary ]; then echo 'Physical footprint: 25.0M'; else printf 'Process: fixture [%s]\\nREGION TYPE\\nMALLOC 1M\\n' \"$1\"; fi\n");
    let output = f
        .command(env!("CARGO_BIN_EXE_release_gate"))
        .args(["--skip-build", "--settle", "0.2", "--app"])
        .arg(&f.app)
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(1));
    let text = String::from_utf8(output.stdout).unwrap();
    assert!(text.contains("| Physical footprint | 25.0 MB | ≤ 20 | **超标** |"));
    Fixture::assert_gone(f.pid("pid"));
    Fixture::assert_gone(f.pid("child"));
}

#[test]
fn interruption_during_a_blocked_sampler_cleans_sampler_and_app() {
    let f = Fixture::new(false);
    Fixture::script(
        &f.tools.join("vmmap"),
        "#!/bin/sh\necho $$ > \"$MEASUREMENT_SAMPLER_PID\"\nexec sleep 30\n",
    );
    let child = f
        .command(env!("CARGO_BIN_EXE_release_gate"))
        .args(["--skip-build", "--settle", "0.2", "--app"])
        .arg(&f.app)
        .env("MEASUREMENT_SAMPLER_PID", f.dir.join("sampler"))
        .stdout(Stdio::null())
        .stderr(f.diagnostics())
        .spawn()
        .unwrap();
    let mut run = Running(child);
    let until = Instant::now() + Duration::from_secs(45);
    while !f.dir.join("sampler").exists() {
        assert!(
            run.0.try_wait().unwrap().is_none(),
            "CLI exited before sampling: {}",
            fs::read_to_string(f.dir.join("stderr")).unwrap_or_default()
        );
        assert!(Instant::now() < until);
        thread::sleep(Duration::from_millis(25));
    }
    let sampler = f.pid("sampler");
    unsafe {
        libc::kill(run.0.id() as i32, libc::SIGTERM);
    }
    let until = Instant::now() + Duration::from_secs(3);
    let status = loop {
        if let Some(s) = run.0.try_wait().unwrap() {
            break s;
        }
        assert!(Instant::now() < until, "signal was blocked by sampler");
        thread::sleep(Duration::from_millis(25));
    };
    assert!(!status.success());
    Fixture::assert_gone(sampler);
    Fixture::assert_gone(f.pid("pid"));
    Fixture::assert_gone(f.pid("child"));
}

#[test]
fn blocked_ps_cleanup_has_a_deadline_and_kills_only_its_child() {
    let f = Fixture::new(false);
    Fixture::script(&f.app.join("Contents/MacOS/fake"),"#!/bin/sh\necho $$ > \"$MEASUREMENT_FIXTURE_PID\"\necho MEANTIME_RELEASE_GATE_READY\nexec sleep 30\n");
    Fixture::script(
        &f.tools.join("ps"),
        "#!/bin/sh\necho $$ > \"$MEASUREMENT_SAMPLER_PID\"\nexec sleep 30\n",
    );
    let child = f
        .command(env!("CARGO_BIN_EXE_release_gate"))
        .args(["--skip-build", "--settle", "0.2", "--app"])
        .arg(&f.app)
        .env("MEASUREMENT_SAMPLER_PID", f.dir.join("sampler"))
        .stdout(Stdio::null())
        .stderr(f.diagnostics())
        .spawn()
        .unwrap();
    let mut run = Running(child);
    let main = f.launched_pid(&mut run, "pid");
    let first_ps = f.launched_pid(&mut run, "sampler");
    unsafe {
        libc::kill(run.0.id() as i32, libc::SIGTERM);
    }
    let until = Instant::now() + Duration::from_secs(4);
    let status = loop {
        if let Some(s) = run.0.try_wait().unwrap() {
            break s;
        }
        assert!(Instant::now() < until, "cleanup hung in ps");
        thread::sleep(Duration::from_millis(25));
    };
    assert!(!status.success());
    Fixture::assert_gone(main);
    Fixture::assert_gone(first_ps);
    Fixture::assert_gone(f.pid("sampler"));
}
