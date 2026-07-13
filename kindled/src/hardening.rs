//! Device-side reconciliation of the reader/experiment policy the manifest
//! carries (see docs/kindle-519-kpp-reader-routing.html).
//!
//! Two levers, both proven on firmware 5.19.2:
//!   * modern_reader — the firmware opens a book in the modern KPP reader
//!     (back/home buttons, page numbers) iff `/var/local/ENABLE_KPPREADER`
//!     exists; otherwise the legacy chrome-less reader. We create it and
//!     make it immutable (`chattr +i`) so a weblab re-sync can't delete it.
//!     `DISABLE_KPPREADER_WEBLAB` tells the switch manager to obey the
//!     marker, not Amazon's experiment.
//!   * freeze_experiments — Amazon fetches weblab assignments from
//!     `kwis-opf.amazon.com` into `/var/local/kindleforeink_weblabs.json`
//!     and re-evaluates device behaviour on boot. We freeze that cache
//!     immutable AND drop the fetch with an iptables SNI match, so the
//!     device stops running server-driven experiments.
//!
//! Everything is best-effort and idempotent: off-device (no /var/local,
//! no chattr/iptables) every step is a quiet no-op and the reported mode
//! is "unknown". `chattr`/`iptables` need root, which the daemon has on
//! the device.

use std::path::{Path, PathBuf};
use std::process::Command;

const DEFAULT_VAR_LOCAL: &str = "/var/local";
const ENABLE_MARKER: &str = "ENABLE_KPPREADER";
const WEBLAB_BYPASS_MARKER: &str = "DISABLE_KPPREADER_WEBLAB";
const WEBLAB_CACHE: &str = "kindleforeink_weblabs.json";
/// The weblab fetch host substring to match in the TLS SNI. Covers both
/// `kwis-opf.amazon.com` and its `-preprod` sibling.
const WEBLAB_HOST_MATCH: &str = "kwis-opf";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ReaderStatus {
    /// What a book actually opens in:
    ///   "kpp"         — modern reader active (marker on AND Amazon's
    ///                    LegacyFormatMigration weblab = true)
    ///   "kpp_pending" — marker pinned, but the format-migration weblab
    ///                    (KINDLE_FEATURE_1308000, MobileWeblab) is still
    ///                    off, so reflowable books stay in the legacy reader
    ///                    until Amazon rolls it out
    ///   "legacy"      — marker off
    ///   "unknown"     — off-device
    pub reader_mode: &'static str,
    pub experiments_frozen: bool,
}

impl Default for ReaderStatus {
    fn default() -> Self {
        ReaderStatus { reader_mode: "unknown", experiments_frozen: false }
    }
}

#[derive(Debug, Clone, Copy, Default)]
pub struct Policy {
    pub modern_reader: bool,
    pub freeze_experiments: bool,
}

fn var_local() -> PathBuf {
    std::env::var_os("VARLOCAL_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(DEFAULT_VAR_LOCAL))
}

/// Bring the device in line with `policy` and report what actually holds.
pub fn reconcile(policy: Policy) -> ReaderStatus {
    let base = var_local();
    // Not a Kindle (dev host / tests): nothing to touch, nothing to claim.
    if !base.is_dir() {
        return ReaderStatus::default();
    }

    let enable = base.join(ENABLE_MARKER);
    let bypass = base.join(WEBLAB_BYPASS_MARKER);
    if policy.modern_reader {
        ensure_present_immutable(&enable);
        ensure_present_immutable(&bypass);
    } else {
        ensure_absent(&enable);
    }

    let weblab = base.join(WEBLAB_CACHE);
    let experiments_frozen = if policy.freeze_experiments {
        set_immutable(&weblab, true);
        set_weblab_block(true);
        // Report the freeze as real only if both halves are actually in place.
        (!weblab.exists() || is_immutable(&weblab)) && weblab_block_present()
    } else {
        set_immutable(&weblab, false);
        set_weblab_block(false);
        false
    };

    // The marker only makes KPP *available*; a reflowable book actually
    // opens in KPP only when Amazon's LegacyFormatMigration weblab is also
    // on. Read that gate from the framework log so the UI tells the truth.
    let reader_mode = if !enable.exists() {
        "legacy"
    } else {
        match format_migration_enabled() {
            Some(true) => "kpp",
            _ => "kpp_pending",
        }
    };
    ReaderStatus { reader_mode, experiments_frozen }
}

/// The newest `isKPPLegacyFormatMigrationEnabled() ... = true|false` the
/// framework logged (weblab KINDLE_FEATURE_1308000). None if the device
/// hasn't logged a book-open decision yet (or off-device).
fn format_migration_enabled() -> Option<bool> {
    let output = Command::new("grep")
        .args(["-hoE", "LegacyFormatMigration = (true|false)", "/var/log/messages"])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    // grep preserves file order; the newest match is the last line.
    let text = String::from_utf8_lossy(&output.stdout);
    text.lines().last().map(|line| line.contains("true"))
}

/// Create the marker if missing, then make it immutable so nothing can
/// delete it. A marker that already exists is left untouched (touching an
/// immutable file would fail anyway).
fn ensure_present_immutable(path: &Path) {
    if !path.exists() {
        if std::fs::File::create(path).is_ok() {
            eprintln!("hardening: created {}", path.display());
        }
    }
    set_immutable(path, true);
}

/// Clear immutability (if any) and remove the marker.
fn ensure_absent(path: &Path) {
    if path.exists() {
        set_immutable(path, false);
        if std::fs::remove_file(path).is_ok() {
            eprintln!("hardening: removed {}", path.display());
        }
    }
}

/// Toggle the ext3 immutable attribute, only shelling out when it needs to
/// change (keeps the every-pass reconcile quiet).
fn set_immutable(path: &Path, want: bool) {
    if !path.exists() || is_immutable(path) == want {
        return;
    }
    let flag = if want { "+i" } else { "-i" };
    if run_ok("chattr", &[flag, &path.to_string_lossy()]) {
        eprintln!("hardening: chattr {flag} {}", path.display());
    }
}

fn is_immutable(path: &Path) -> bool {
    // `lsattr` prints e.g. "----i---------------- /var/local/ENABLE_KPPREADER".
    match Command::new("lsattr").arg(path).output() {
        Ok(out) if out.status.success() => String::from_utf8_lossy(&out.stdout)
            .split_whitespace()
            .next()
            .is_some_and(|flags| flags.contains('i')),
        _ => false,
    }
}

fn weblab_rule_spec() -> Vec<String> {
    [
        "OUTPUT", "-p", "tcp", "-m", "string", "--string", WEBLAB_HOST_MATCH,
        "--algo", "bm", "-j", "REJECT", "--reject-with", "tcp-reset",
    ]
    .iter()
    .map(|s| s.to_string())
    .collect()
}

fn weblab_block_present() -> bool {
    let mut args = vec!["-C".to_string()];
    args.extend(weblab_rule_spec());
    run_ok("iptables", &args.iter().map(String::as_str).collect::<Vec<_>>())
}

/// Insert (or delete) the SNI-match REJECT for the weblab host. iptables
/// rules live in memory only, so this re-asserts the block after every
/// reboot — the first sync pass restores it.
fn set_weblab_block(enable: bool) {
    let present = weblab_block_present();
    if enable == present {
        return;
    }
    let verb = if enable { "-I" } else { "-D" };
    let mut args = vec![verb.to_string()];
    args.extend(weblab_rule_spec());
    if run_ok("iptables", &args.iter().map(String::as_str).collect::<Vec<_>>()) {
        eprintln!("hardening: iptables {verb} weblab block");
    }
}

/// Run a command, returning true only on a clean exit. Missing binaries
/// (dev host) and non-zero exits both count as "did not happen".
fn run_ok(program: &str, args: &[&str]) -> bool {
    Command::new(program)
        .args(args)
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Mutex, MutexGuard};

    // VARLOCAL_DIR is process-global; serialise the tests that set it.
    static ENV_LOCK: Mutex<()> = Mutex::new(());

    struct Scratch {
        dir: PathBuf,
        _guard: MutexGuard<'static, ()>,
    }

    impl Scratch {
        fn new(tag: &str) -> Self {
            let guard = ENV_LOCK.lock().unwrap_or_else(|p| p.into_inner());
            let dir = std::env::temp_dir().join(format!("kindled-hard-{tag}-{}", std::process::id()));
            std::fs::create_dir_all(&dir).unwrap();
            std::env::set_var("VARLOCAL_DIR", &dir);
            Scratch { dir, _guard: guard }
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            std::env::remove_var("VARLOCAL_DIR");
            std::fs::remove_dir_all(&self.dir).ok();
        }
    }

    #[test]
    fn pins_reader_marker_when_enabled() {
        let s = Scratch::new("pin");
        let status = reconcile(Policy { modern_reader: true, freeze_experiments: false });
        assert!(s.dir.join(ENABLE_MARKER).exists());
        assert!(s.dir.join(WEBLAB_BYPASS_MARKER).exists());
        // Marker present but the format-migration gate is unknown off-device,
        // so we report "pinned but pending", never a false "active".
        assert_eq!(status.reader_mode, "kpp_pending");
    }

    #[test]
    fn removes_reader_marker_when_disabled() {
        let s = Scratch::new("unpin");
        std::fs::File::create(s.dir.join(ENABLE_MARKER)).unwrap();
        let status = reconcile(Policy { modern_reader: false, freeze_experiments: false });
        assert!(!s.dir.join(ENABLE_MARKER).exists());
        assert_eq!(status.reader_mode, "legacy");
    }

    #[test]
    fn reports_unknown_off_device() {
        let _lock = ENV_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        std::env::set_var("VARLOCAL_DIR", "/nonexistent-kindled-var-local");
        let status = reconcile(Policy { modern_reader: true, freeze_experiments: true });
        std::env::remove_var("VARLOCAL_DIR");
        assert_eq!(status.reader_mode, "unknown");
        assert!(!status.experiments_frozen);
    }
}
