// SPDX-License-Identifier: GPL-3.0-only
use super::measurement_state;
use std::{fs, os::unix::fs::symlink, path::PathBuf};

struct TemporaryHome(PathBuf);

impl TemporaryHome {
    fn new() -> Self {
        let home = std::env::temp_dir().join(format!("dayside-home-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(home.join(".config/dayside")).unwrap();
        Self(home)
    }

    fn pause_file(&self) -> PathBuf {
        self.0.join(".config/dayside/measure.state")
    }
}

impl Drop for TemporaryHome {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).unwrap();
    }
}

#[test]
fn absent_pause_file_is_free() {
    let home = TemporaryHome::new();
    assert_eq!(measurement_state(&home.0).unwrap().trim(), "FREE");
}

#[test]
fn linked_free_pause_file_is_free() {
    let home = TemporaryHome::new();
    let target = home.0.join("state");
    fs::write(&target, "FREE\n").unwrap();
    symlink(target, home.pause_file()).unwrap();
    assert_eq!(measurement_state(&home.0).unwrap().trim(), "FREE");
}

#[test]
fn linked_timed_pause_file_blocks() {
    let home = TemporaryHome::new();
    let target = home.0.join("state");
    fs::write(&target, "TIMED test\n").unwrap();
    symlink(target, home.pause_file()).unwrap();
    assert_ne!(measurement_state(&home.0).unwrap().trim(), "FREE");
}

#[test]
fn dangling_pause_link_blocks() {
    let home = TemporaryHome::new();
    symlink(home.0.join("missing"), home.pause_file()).unwrap();
    assert!(measurement_state(&home.0).is_err());
}

#[test]
fn unreadable_pause_value_blocks() {
    let home = TemporaryHome::new();
    fs::write(home.pause_file(), [0xff]).unwrap();
    assert!(measurement_state(&home.0).is_err());
}
