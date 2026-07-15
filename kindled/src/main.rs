//! kindled — private-cloud sync for a jailbroken Kindle.
//!
//! One static binary, no runtime. Subcommands map onto KUAL menu entries
//! and cron-ish usage:
//!
//!   kindled init <server-url> <api-token>   write the config file
//!   kindled sync                            one reconciliation pass
//!   kindled daemon                          sync in a loop (POLL_INTERVAL)
//!   kindled list                            print the server manifest
//!   kindled status                          config + local state overview

mod api;
mod config;
mod device;
mod hardening;
mod lipc;
mod sdr;
mod state;
mod sync;

use std::process::ExitCode;
use std::thread;
use std::time::Duration;

use api::Client;
use config::Config;
use state::State;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let command = args.first().map(String::as_str).unwrap_or("help");

    let result = match command {
        "init" => cmd_init(&args[1..]),
        "sync" => cmd_sync(),
        "daemon" => cmd_daemon(),
        "list" => cmd_list(),
        "status" => cmd_status(),
        "help" | "--help" | "-h" => {
            print_usage();
            Ok(())
        }
        other => Err(format!("unknown command: {other}")),
    };

    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("kindled: {message}");
            ExitCode::FAILURE
        }
    }
}

fn print_usage() {
    println!(
        "usage:\n  \
         kindled init <server-url> <api-token>\n  \
         kindled sync\n  \
         kindled daemon\n  \
         kindled list\n  \
         kindled status"
    );
}

fn load_config() -> Result<Config, String> {
    Config::load()
        .map_err(|e| format!("cannot read {} ({e}); run kindled init", Config::path().display()))
}

fn cmd_init(args: &[String]) -> Result<(), String> {
    let [server_url, api_token] = args else {
        return Err("usage: kindled init <server-url> <api-token>".into());
    };
    let path = Config::write_initial(server_url, api_token).map_err(|e| e.to_string())?;
    println!("wrote {}", path.display());

    let config = Config::load().map_err(|e| e.to_string())?;
    Client::new(&config)
        .healthz()
        .map_err(|e| format!("server unreachable: {e}"))?;
    println!("server ok: {}", config.server_url);
    Ok(())
}

fn cmd_sync() -> Result<(), String> {
    let config = load_config()?;
    let report = sync::run(&config).map_err(|e| e.to_string())?;
    println!(
        "sync done: {} downloaded, {} removed, {} states pushed, {} states applied, {} errors{}",
        report.downloaded,
        report.removed,
        report.pushed_states,
        report.applied_states,
        report.errors.len(),
        if report.clippings_pushed { ", clippings uploaded" } else { "" }
    );
    for error in &report.errors {
        eprintln!("  error: {error}");
    }
    if report.errors.is_empty() {
        Ok(())
    } else {
        Err("sync finished with errors".into())
    }
}

fn cmd_daemon() -> Result<(), String> {
    let config = load_config()?;
    eprintln!(
        "kindled daemon: polling {} every {}s (fast probe {}s while awake)",
        config.server_url, config.poll_interval_secs, config.fast_poll_secs
    );
    let mut last_version: Option<u64> = None;
    loop {
        match sync::run(&config) {
            Ok(report) => {
                if report.downloaded + report.removed + report.pushed_states + report.applied_states > 0 {
                    eprintln!(
                        "sync: {} downloaded, {} removed, {} pushed, {} applied",
                        report.downloaded, report.removed, report.pushed_states, report.applied_states
                    );
                }
                for error in &report.errors {
                    eprintln!("sync error: {error}");
                }
                // Snapshot after a successful pass: "unchanged" now means
                // "a sync would do nothing".
                last_version = Client::new(&config).queue_version().ok();
            }
            // Wifi drops are normal Kindle life; keep polling.
            Err(error) => eprintln!("sync failed: {error}"),
        }
        wait_for_work(&config, last_version);
    }
}

/// Why `wait_for_work` cut the sleep short — purely for the log line, the
/// caller does the same thing either way (sync now).
#[derive(Debug, Clone, Copy)]
enum WakeReason {
    ServerVersion,
    LocalSidecar,
}

/// Sleep until the next full sync is due — but while the device is awake,
/// every FAST_POLL seconds both probe the tiny queue-version endpoint AND
/// stat the tracked books' `.sdr` sidecars, cutting the wait short as soon
/// as either the server has something new or the firmware has written a
/// fresh reading position locally (outbound near-realtime: the device's own
/// position updates no longer wait for the full POLL_INTERVAL). ~1 KB per
/// server probe, a handful of `stat`s for the local check, and zero extra
/// wakeups: a suspended Kindle freezes this process, so probes only ever
/// run when the radio/CPU is already up.
fn wait_for_work(config: &Config, last_version: Option<u64>) {
    let interval = config.poll_interval_secs.max(30);
    let tick = config.fast_poll_secs;
    if tick == 0 || tick >= interval {
        thread::sleep(Duration::from_secs(interval));
        return;
    }

    // Loaded once: nothing else touches state.json while the daemon sleeps,
    // so the tracked-book list and watermarks can't move until the sync
    // pass that follows this wait.
    let state = State::load(&config.state_file);
    let has_books = !state.books.is_empty();

    let mut waited = 0;
    while waited < interval {
        thread::sleep(Duration::from_secs(tick));
        waited += tick;
        if !device::awake() {
            continue;
        }

        // Local check first: it's free (no network) and if it already says
        // "sync now" there's no point spending a probe on the server too.
        let reason = if has_books && local_state_changed(&state) {
            Some(WakeReason::LocalSidecar)
        } else {
            Client::new(config)
                .queue_version()
                .ok()
                .filter(|version| last_version != Some(*version))
                .map(|_| WakeReason::ServerVersion)
        };

        if let Some(reason) = reason {
            match reason {
                WakeReason::ServerVersion => {
                    eprintln!("fast-poll: server version changed — syncing early")
                }
                WakeReason::LocalSidecar => {
                    eprintln!("fast-poll: local reading state changed — syncing early")
                }
            }
            return;
        }
    }
}

/// True when any tracked book's `.sdr` sidecar has content newer than both
/// watermarks we hold for it (`pushed_sdr_mtime`, `applied_sdr_mtime`) —
/// i.e. the firmware wrote a fresh reading position since the last sync
/// pass, worth waking up early for. `sync_reading_state` (sync.rs) is what
/// actually pushes and advances `pushed_sdr_mtime`; once it does, that same
/// mtime is no longer ">" the watermark, so this cannot re-trigger on its
/// own output — a book left open with the firmware continuously touching
/// the sidecar causes at most one early sync per FAST_POLL tick, not a
/// tight loop.
fn local_state_changed(state: &State) -> bool {
    state.books.values().any(|book| {
        let sdr_dir = sdr::sdr_dir_for(&book.path);
        sdr::latest_mtime(&sdr_dir)
            .is_some_and(|mtime| mtime > book.pushed_sdr_mtime.max(book.applied_sdr_mtime))
    })
}

fn cmd_list() -> Result<(), String> {
    let config = load_config()?;
    let manifest = Client::new(&config).manifest().map_err(|e| e.to_string())?;
    for item in &manifest.items {
        let author = item.author.as_deref().unwrap_or("-");
        println!(
            "{}  {} — {} [{}] {} bytes",
            item.id, item.title, author, item.format, item.size
        );
    }
    println!("{} items", manifest.items.len());
    Ok(())
}

fn cmd_status() -> Result<(), String> {
    let config = load_config()?;
    println!("server:        {}", config.server_url);
    println!("documents:     {}", config.document_dir.display());
    println!("poll:          {}s", config.poll_interval_secs);
    println!("auto-download: {}", config.auto_download);

    let info = device::collect(&config.document_dir);
    if let (Some(free), Some(total)) = (info.free_bytes, info.total_bytes) {
        println!(
            "storage:       {:.1} GB free of {:.1} GB",
            free as f64 / 1e9,
            total as f64 / 1e9
        );
    }
    if let Some(battery) = info.battery_percent {
        println!("battery:       {battery}%");
    }
    if let Some(firmware) = &info.firmware_version {
        println!("firmware:      {firmware}");
    }

    let state = State::load(&config.state_file);
    println!("tracked books: {}", state.books.len());
    for (id, book) in &state.books {
        let exists = if book.path.exists() { "ok" } else { "MISSING" };
        println!("  {id}  {}  [{exists}]", book.path.display());
    }

    match Client::new(&config).healthz() {
        Ok(()) => println!("server health: ok"),
        Err(error) => println!("server health: unreachable ({error})"),
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use state::BookState;
    use std::fs;
    use std::path::PathBuf;

    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("kindled-main-{tag}-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn local_state_changed_false_with_no_tracked_books() {
        assert!(!local_state_changed(&State::default()));
    }

    #[test]
    fn local_state_changed_true_when_sidecar_outpaces_watermarks() {
        let root = temp_dir("outpaces");
        let book_path = root.join("Book.azw3");
        let sdr_dir = sdr::sdr_dir_for(&book_path);
        fs::create_dir_all(&sdr_dir).unwrap();
        fs::write(sdr_dir.join("Book.mbp1"), b"progress").unwrap();

        let mut state = State::default();
        state.books.insert(
            "id".into(),
            BookState {
                path: book_path,
                pushed_sdr_mtime: 0,
                applied_sdr_mtime: 0,
                ..Default::default()
            },
        );

        assert!(local_state_changed(&state));
        fs::remove_dir_all(&root).unwrap();
    }

    /// Mirrors the invariant `sync_reading_state` relies on: once a push
    /// advances `pushed_sdr_mtime` to the sidecar's current mtime, the same
    /// content no longer looks "changed" — no self-retrigger.
    #[test]
    fn local_state_changed_false_once_watermark_catches_up() {
        let root = temp_dir("caught-up");
        let book_path = root.join("Book.azw3");
        let sdr_dir = sdr::sdr_dir_for(&book_path);
        fs::create_dir_all(&sdr_dir).unwrap();
        fs::write(sdr_dir.join("Book.mbp1"), b"progress").unwrap();
        let mtime = sdr::latest_mtime(&sdr_dir).unwrap();

        let mut state = State::default();
        state.books.insert(
            "id".into(),
            BookState {
                path: book_path,
                pushed_sdr_mtime: mtime,
                applied_sdr_mtime: 0,
                ..Default::default()
            },
        );

        assert!(!local_state_changed(&state));
        fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn local_state_changed_false_when_only_applied_watermark_covers_it() {
        // A bundle we just restored from the server: applied_sdr_mtime is
        // set, pushed_sdr_mtime is not. Must not look like a local change.
        let root = temp_dir("applied-only");
        let book_path = root.join("Book.azw3");
        let sdr_dir = sdr::sdr_dir_for(&book_path);
        fs::create_dir_all(&sdr_dir).unwrap();
        fs::write(sdr_dir.join("Book.mbp1"), b"progress").unwrap();
        let mtime = sdr::latest_mtime(&sdr_dir).unwrap();

        let mut state = State::default();
        state.books.insert(
            "id".into(),
            BookState {
                path: book_path,
                pushed_sdr_mtime: 0,
                applied_sdr_mtime: mtime,
                ..Default::default()
            },
        );

        assert!(!local_state_changed(&state));
        fs::remove_dir_all(&root).unwrap();
    }
}
