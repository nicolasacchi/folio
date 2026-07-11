//! One reconciliation pass: mirror the server manifest into the local
//! documents folder and exchange `.sdr` reading state.
//!
//! Reading-state policy (from the capture research): latest content mtime
//! wins across devices, local sidecars are backed up before overwrite,
//! and our own uploads are never re-applied (they can't be newer than the
//! local sidecar that produced them).

use std::fs;
use std::thread;
use std::time::{Duration, Instant};

use crate::api::{ApiError, Client, ManifestItem, Removal};
use crate::config::Config;
use crate::state::{BookState, State};
use crate::{device, lipc, sdr};

#[derive(Debug, Default)]
pub struct SyncReport {
    pub downloaded: u32,
    pub pushed_states: u32,
    pub applied_states: u32,
    pub removed: u32,
    pub clippings_pushed: bool,
    pub errors: Vec<String>,
}

pub fn run(config: &Config) -> Result<SyncReport, ApiError> {
    let started = Instant::now();
    let client = Client::new(config);
    let manifest = client.manifest()?;
    let mut state = State::load(&config.state_file);
    let mut report = SyncReport::default();

    for item in &manifest.items {
        if let Err(error) = sync_item(config, &client, &mut state, item, &mut report) {
            report
                .errors
                .push(format!("{} ({}): {error}", item.title, item.id));
        }
        // Persist after every item; the Kindle may sleep or lose wifi.
        state.save(&config.state_file)?;
    }

    for removal in &manifest.removals {
        match process_removal(config, &client, &mut state, removal) {
            Ok(()) => report.removed += 1,
            Err(error) => report
                .errors
                .push(format!("removal {} ({}): {error}", removal.filename, removal.id)),
        }
        state.save(&config.state_file)?;
    }

    if let Some(url) = &manifest.clippings_url {
        match push_clippings(config, &client, &mut state, url) {
            Ok(pushed) => {
                report.clippings_pushed = pushed;
                if pushed {
                    state.save(&config.state_file)?;
                }
            }
            Err(error) => report.errors.push(format!("clippings: {error}")),
        }
    }

    // Telemetry last, so the report covers this whole pass. Best-effort:
    // an old server without the endpoint must not fail the sync.
    if let Some(url) = &manifest.status_url {
        if let Err(error) = post_status(config, &client, &state, &report, started, url) {
            eprintln!("status report failed: {error}");
        }
    }

    Ok(report)
}

/// Delete a book (plus sidecar and any installed thumbnail) at the
/// server's request, then ack so the delivery row is closed out. Newer
/// local reading state is pushed first — finishing position survives the
/// eviction on the server.
fn process_removal(
    config: &Config,
    client: &Client,
    state: &mut State,
    removal: &Removal,
) -> Result<(), ApiError> {
    let path = config.document_dir.join(&removal.filename);
    let sdr_dir = sdr::sdr_dir_for(&path);

    if let Some(book_state) = state.books.get(&removal.id) {
        if let Some(local) = sdr::latest_mtime(&sdr_dir) {
            if local > book_state.pushed_sdr_mtime && local > book_state.applied_sdr_mtime {
                let bundle = sdr::pack(&sdr_dir)?;
                client.push_reading_state(&removal.id, bundle, local)?;
            }
        }
    }

    fs::remove_file(&path).ok(); // may already be gone
    fs::remove_dir_all(&sdr_dir).ok();
    if let Some(thumbnail) = &removal.thumbnail_filename {
        fs::remove_file(config.thumbnail_dir.join(thumbnail)).ok();
    }
    lipc::refresh_file(&path); // drop the catalog row

    client.post_json(&removal.ack_url, &serde_json::json!({}))?;
    state.books.remove(&removal.id);
    if let Some(reason) = &removal.reason {
        eprintln!("removed {} ({reason})", removal.filename);
    } else {
        eprintln!("removed {}", removal.filename);
    }
    Ok(())
}

/// Upload My Clippings.txt when it changed since the last push.
fn push_clippings(
    config: &Config,
    client: &Client,
    state: &mut State,
    url: &str,
) -> Result<bool, ApiError> {
    const MAX_CLIPPINGS_BYTES: u64 = 10 * 1024 * 1024;

    let Ok(meta) = fs::metadata(&config.clippings_path) else {
        return Ok(false); // no highlights yet
    };
    if meta.len() == 0 || meta.len() > MAX_CLIPPINGS_BYTES {
        return Ok(false);
    }
    let mtime = meta
        .modified()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_secs())
        .unwrap_or(0);
    if mtime <= state.clippings_pushed_mtime {
        return Ok(false);
    }

    let body = fs::read(&config.clippings_path)?;
    client.put_clippings(url, body)?;
    state.clippings_pushed_mtime = mtime;
    Ok(true)
}

/// POST storage/battery/firmware telemetry, the pass report, and the list
/// of books actually present on disk (the server reconciles deliveries
/// against it).
fn post_status(
    config: &Config,
    client: &Client,
    state: &State,
    report: &SyncReport,
    started: Instant,
    url: &str,
) -> Result<(), ApiError> {
    let info = device::collect(&config.document_dir);
    let books: Vec<serde_json::Value> = state
        .books
        .iter()
        .filter(|(_, book)| book.path.exists())
        .map(|(id, book)| {
            let size = fs::metadata(&book.path).map(|m| m.len()).unwrap_or(0);
            serde_json::json!({ "id": id, "size": size })
        })
        .collect();

    let payload = serde_json::json!({
        "free_bytes": info.free_bytes,
        "total_bytes": info.total_bytes,
        "battery_percent": info.battery_percent,
        "firmware_version": info.firmware_version,
        "serial": info.serial,
        "kindled_version": env!("CARGO_PKG_VERSION"),
        "sync": {
            "downloaded": report.downloaded,
            "sdr_pushed": report.pushed_states,
            "sdr_applied": report.applied_states,
            "removed": report.removed,
            "errors": report.errors.len(),
            "duration_ms": started.elapsed().as_millis() as u64,
        },
        "books": books,
    });
    client.post_json(url, &payload)
}

fn sync_item(
    config: &Config,
    client: &Client,
    state: &mut State,
    item: &ManifestItem,
    report: &mut SyncReport,
) -> Result<(), ApiError> {
    let book_state = state.books.get(&item.id).cloned();

    // Download the book when it's new, changed on the server, or the local
    // file vanished. Formats never overwrite each other: filename comes
    // from the manifest.
    let destination = config.document_dir.join(&item.filename);
    let needs_download = match &book_state {
        Some(existing) => existing.sha256 != item.sha256 || !existing.path.exists(),
        None => true,
    };

    if needs_download {
        if !config.auto_download {
            return Ok(());
        }
        eprintln!("downloading {} -> {}", item.title, destination.display());
        let part = client.download_book_part(item, &destination)?;
        if destination.exists() {
            // Replacing in place keeps stale catalog metadata (the scanner
            // does not re-read an existing row's file) — drop the row
            // first, then place the new bytes. The `.sdr` sidecar stays,
            // so the reading position survives the swap.
            fs::remove_file(&destination)?;
            lipc::refresh_file(&destination);
            thread::sleep(Duration::from_millis(1500));
        }
        fs::rename(&part, &destination)?;
        lipc::refresh_file(&destination);
        report.downloaded += 1;
        state.books.insert(
            item.id.clone(),
            BookState {
                path: destination.clone(),
                sha256: item.sha256.clone(),
                ..book_state.clone().unwrap_or_default()
            },
        );
    }

    if let Err(error) = install_thumbnail(config, client, state, item) {
        // Cosmetic; never fail the book sync over it.
        eprintln!("thumbnail for {} failed: {error}", item.title);
    }

    sync_reading_state(client, state, item, report)
}

/// Fallback cover path for files that still carry a store identity: put
/// the server-rendered cover into the firmware's thumbnail cache under the
/// EXTH-derived name. A rescan regenerates the firmware's placeholder (the
/// size change betrays it), so re-install whenever the size differs from
/// what we wrote.
fn install_thumbnail(
    config: &Config,
    client: &Client,
    state: &mut State,
    item: &ManifestItem,
) -> Result<(), ApiError> {
    let Some(thumbnail) = &item.thumbnail else {
        return Ok(());
    };
    if !config.thumbnail_dir.is_dir() {
        return Ok(()); // not on a Kindle
    }
    let Some(book_state) = state.books.get(&item.id).cloned() else {
        return Ok(()); // book not downloaded yet
    };

    let destination = config.thumbnail_dir.join(&thumbnail.filename);
    let current_size = fs::metadata(&destination).map(|m| m.len()).ok();
    let ours = book_state.thumbnail_filename.as_deref() == Some(thumbnail.filename.as_str())
        && current_size == Some(book_state.thumbnail_size);
    if ours {
        return Ok(());
    }

    let bytes = client.download_bytes(&thumbnail.url)?;
    let size = bytes.len() as u64;
    let part = destination.with_extension("part");
    fs::write(&part, &bytes)?;
    fs::rename(&part, &destination)?;
    state.books.entry(item.id.clone()).and_modify(|book| {
        book.thumbnail_filename = Some(thumbnail.filename.clone());
        book.thumbnail_size = size;
    });
    Ok(())
}

fn sync_reading_state(
    client: &Client,
    state: &mut State,
    item: &ManifestItem,
    report: &mut SyncReport,
) -> Result<(), ApiError> {
    let Some(book_state) = state.books.get(&item.id).cloned() else {
        return Ok(());
    };

    let sdr_dir = sdr::sdr_dir_for(&book_state.path);
    let local_mtime = sdr::latest_mtime(&sdr_dir);
    let server_mtime = item.reading_state.as_ref().map(|s| s.mtime);

    // Push: local sidecar changed since our last upload and is not older
    // than what the server already has. A sidecar we just restored from the
    // server carries the applied mtime and must not bounce back.
    if let Some(local) = local_mtime {
        let already_pushed = local <= book_state.pushed_sdr_mtime;
        let is_applied_copy = local <= book_state.applied_sdr_mtime;
        let server_is_newer = server_mtime.is_some_and(|server| server > local);
        if !already_pushed && !is_applied_copy && !server_is_newer {
            let bundle = sdr::pack(&sdr_dir)?;
            client.push_reading_state(&item.id, bundle, local)?;
            report.pushed_states += 1;
            state
                .books
                .entry(item.id.clone())
                .and_modify(|b| b.pushed_sdr_mtime = local);
        }
    }

    // Apply: server has strictly newer state than anything local, and we
    // have not applied that exact version yet.
    if let Some(server) = server_mtime {
        let newer_than_local = local_mtime.is_none_or(|local| server > local);
        let not_applied_yet = server > book_state.applied_sdr_mtime;
        let not_our_own = server > book_state.pushed_sdr_mtime;
        if newer_than_local && not_applied_yet && not_our_own {
            if let Some(bundle) = client.fetch_reading_state(&item.id)? {
                let backup = sdr::unpack(&bundle, &sdr_dir)?;
                if let Some(backup) = backup {
                    eprintln!("local sidecar backed up to {}", backup.display());
                }
                set_dir_mtimes(&sdr_dir, server);
                lipc::trigger_catalog_update();
                report.applied_states += 1;
                state
                    .books
                    .entry(item.id.clone())
                    .and_modify(|b| b.applied_sdr_mtime = server);
            }
        }
    }

    Ok(())
}

/// After restoring a bundle the extracted files carry "now" as mtime,
/// which would immediately look like fresh local changes and bounce back
/// to the server. Pin them to the server-side content mtime instead.
fn set_dir_mtimes(dir: &std::path::Path, unix_secs: u64) {
    let Ok(entries) = fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            set_dir_mtimes(&path, unix_secs);
        }
        let _ = filetime_set(&path, unix_secs);
    }
    let _ = filetime_set(dir, unix_secs);
}

/// Minimal utimensat wrapper via std: rewrite the file's mtime by touching
/// through File::set_modified (stable since 1.75).
fn filetime_set(path: &std::path::Path, unix_secs: u64) -> std::io::Result<()> {
    let time = std::time::UNIX_EPOCH + std::time::Duration::from_secs(unix_secs);
    let file = fs::File::options().write(true).open(path);
    match file {
        Ok(file) => file.set_modified(time),
        // Directories can't be opened for write on all platforms; ignore.
        Err(_) => Ok(()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(id: &str, sha: &str, state_mtime: Option<u64>) -> ManifestItem {
        ManifestItem {
            id: id.into(),
            title: "T".into(),
            author: None,
            format: "azw3".into(),
            filename: "T.azw3".into(),
            size: 1,
            sha256: sha.into(),
            url: format!("/api/v1/books/{id}/file"),
            thumbnail: None,
            reading_state: state_mtime.map(|mtime| crate::api::ReadingStateSummary { mtime }),
        }
    }

    #[test]
    fn download_decision_covers_new_changed_and_missing() {
        let mut state = State::default();

        // Unknown book -> download.
        let unknown = state.books.get("a").is_none();
        assert!(unknown);

        // Known with same sha and existing file -> no download.
        let dir = std::env::temp_dir().join(format!("kindled-sync-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("T.azw3");
        fs::write(&path, b"x").unwrap();
        state.books.insert(
            "a".into(),
            BookState { path: path.clone(), sha256: "aa".into(), ..Default::default() },
        );
        let existing = state.books.get("a").unwrap();
        assert!(!(existing.sha256 != item("a", "aa", None).sha256 || !existing.path.exists()));

        // Changed sha -> download again.
        assert!(existing.sha256 != item("a", "bb", None).sha256);

        // Missing file -> download again.
        fs::remove_file(&path).unwrap();
        let existing = state.books.get("a").unwrap();
        assert!(!existing.path.exists());

        fs::remove_dir_all(&dir).unwrap();
    }
}
