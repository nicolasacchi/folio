//! Device telemetry for the status report: storage, battery, firmware,
//! serial. Everything is best-effort — off-device (tests, dev host) the
//! Kindle-specific sources are simply absent and fields come back None.

use std::ffi::CString;
use std::fs;
use std::path::Path;
use std::process::Command;

#[derive(Debug, Default)]
pub struct DeviceInfo {
    pub free_bytes: Option<u64>,
    pub total_bytes: Option<u64>,
    pub battery_percent: Option<i64>,
    pub firmware_version: Option<String>,
    pub serial: Option<String>,
}

pub fn collect(document_dir: &Path) -> DeviceInfo {
    let (free_bytes, total_bytes) = match statvfs(document_dir) {
        Some(pair) => (Some(pair.0), Some(pair.1)),
        None => (None, None),
    };
    DeviceInfo {
        free_bytes,
        total_bytes,
        battery_percent: battery_percent(),
        firmware_version: firmware_version(),
        serial: serial(),
    }
}

/// (free, total) in bytes for the filesystem holding `path`.
fn statvfs(path: &Path) -> Option<(u64, u64)> {
    let c_path = CString::new(path.as_os_str().as_encoded_bytes()).ok()?;
    let mut stats: libc::statvfs = unsafe { std::mem::zeroed() };
    let rc = unsafe { libc::statvfs(c_path.as_ptr(), &mut stats) };
    if rc != 0 {
        return None;
    }
    let block = if stats.f_frsize > 0 { stats.f_frsize } else { stats.f_bsize } as u64;
    Some((stats.f_bavail as u64 * block, stats.f_blocks as u64 * block))
}

/// The powerd LIPC property is authoritative on every firmware we have
/// seen (verified on 5.19.2); /sys is the fallback.
fn battery_percent() -> Option<i64> {
    if let Some(output) = run_capture("lipc-get-prop", &["com.lab126.powerd", "battLevel"]) {
        if let Ok(level) = output.trim().parse::<i64>() {
            return Some(level);
        }
    }
    for entry in fs::read_dir("/sys/class/power_supply").ok()?.flatten() {
        if let Ok(text) = fs::read_to_string(entry.path().join("capacity")) {
            if let Ok(level) = text.trim().parse::<i64>() {
                return Some(level);
            }
        }
    }
    None
}

fn firmware_version() -> Option<String> {
    for path in ["/etc/prettyversion.txt", "/etc/version.txt"] {
        if let Ok(text) = fs::read_to_string(path) {
            let line = text.lines().next().unwrap_or("").trim();
            if !line.is_empty() {
                return Some(line.chars().take(100).collect());
            }
        }
    }
    None
}

fn serial() -> Option<String> {
    let text = fs::read_to_string("/proc/usid").ok()?;
    let trimmed = text.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

fn run_capture(program: &str, args: &[&str]) -> Option<String> {
    let output = Command::new(program).args(args).output().ok()?;
    if !output.status.success() {
        return None;
    }
    String::from_utf8(output.stdout).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn statvfs_reports_plausible_numbers_for_tmp() {
        let (free, total) = statvfs(Path::new("/tmp")).expect("statvfs on /tmp");
        assert!(total > 0);
        assert!(free <= total);
    }

    #[test]
    fn collect_never_panics_off_device() {
        let info = collect(Path::new("/tmp"));
        assert!(info.total_bytes.is_some());
    }
}
