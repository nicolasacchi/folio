//! Stock-firmware integration through `lipc-set-prop`, the same calls the
//! capture research proved trigger local library ingestion:
//!   com.lab126.scanner reScanFile <path>
//!   com.lab126.ccat    triggerUpdate 1
//! KPP-era firmware (5.19+) dropped both properties and instead watches
//! /mnt/us/documents by itself — verified live: downloads get indexed
//! with no trigger at all. The calls stay for older firmware, muted, as
//! pure best-effort.
//! Off-device (tests, dev host) the binary is absent and calls are no-ops.

use std::path::Path;
use std::process::{Command, Stdio};

pub fn refresh_file(path: &Path) {
    set_prop(&["com.lab126.scanner", "reScanFile", &path.to_string_lossy()]);
    set_prop(&["com.lab126.ccat", "triggerUpdate", "1"]);
}

pub fn trigger_catalog_update() {
    set_prop(&["com.lab126.ccat", "triggerUpdate", "1"]);
}

fn set_prop(args: &[&str]) {
    let _ = Command::new("lipc-set-prop")
        .args(args)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map_err(|_| ()); // not on a Kindle — fine
}
