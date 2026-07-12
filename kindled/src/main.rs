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

/// Sleep until the next full sync is due — but while the device is awake,
/// probe the tiny queue-version endpoint every FAST_POLL seconds and cut
/// the wait short as soon as the server has something new. Near-realtime
/// deliveries at ~1 KB per probe, and zero extra wakeups: a suspended
/// Kindle freezes this process, so probes only ever run when the radio
/// is already up.
fn wait_for_work(config: &Config, last_version: Option<u64>) {
    let interval = config.poll_interval_secs.max(30);
    let tick = config.fast_poll_secs;
    if tick == 0 || tick >= interval {
        thread::sleep(Duration::from_secs(interval));
        return;
    }

    let mut waited = 0;
    while waited < interval {
        thread::sleep(Duration::from_secs(tick));
        waited += tick;
        if !device::awake() {
            continue;
        }
        if let Ok(version) = Client::new(config).queue_version() {
            if last_version != Some(version) {
                return; // something changed — sync now
            }
        }
    }
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
