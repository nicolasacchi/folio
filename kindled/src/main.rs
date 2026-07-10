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
        "sync done: {} downloaded, {} states pushed, {} states applied, {} errors",
        report.downloaded,
        report.pushed_states,
        report.applied_states,
        report.errors.len()
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
        "kindled daemon: polling {} every {}s",
        config.server_url, config.poll_interval_secs
    );
    loop {
        match sync::run(&config) {
            Ok(report) => {
                if report.downloaded + report.pushed_states + report.applied_states > 0 {
                    eprintln!(
                        "sync: {} downloaded, {} pushed, {} applied",
                        report.downloaded, report.pushed_states, report.applied_states
                    );
                }
                for error in &report.errors {
                    eprintln!("sync error: {error}");
                }
            }
            // Wifi drops are normal Kindle life; keep polling.
            Err(error) => eprintln!("sync failed: {error}"),
        }
        thread::sleep(Duration::from_secs(config.poll_interval_secs.max(30)));
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
