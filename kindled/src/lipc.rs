//! Stock-firmware integration through `lipc-set-prop`, the same calls the
//! capture research proved trigger local library ingestion:
//!   com.lab126.scanner reScanFile <path>
//!   com.lab126.ccat    triggerUpdate 1     (pre-5.19 firmware)
//!   com.lab126.scanner triggerUpdate 1     (5.19+: moved to the scanner)
//! On 5.19 the documents folder is also inotify-watched, so most changes
//! index with no trigger at all; the calls stay as best-effort accelerators
//! and are muted when a property doesn't exist on the running firmware.
//! Off-device (tests, dev host) the binary is absent and calls are no-ops.
//!
//! Caveat verified live on 5.19.2: `reScanFile` on an EXISTING catalog row
//! does NOT re-read the file's metadata — replacing a book in place keeps
//! stale catalog identity. The sync layer therefore deletes + rescans
//! before writing the new bytes.

use std::path::Path;
use std::process::{Command, Stdio};

pub fn refresh_file(path: &Path) {
    set_prop(&["com.lab126.scanner", "reScanFile", &path.to_string_lossy()]);
    trigger_catalog_update();
}

pub fn trigger_catalog_update() {
    set_prop(&["com.lab126.scanner", "triggerUpdate", "1"]);
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
