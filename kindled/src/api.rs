//! HTTP client for the Folio server's device API (plain HTTP on the LAN).

use std::fmt;
use std::fs;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::thread;
use std::time::Duration;

use serde::Deserialize;
use sha2::{Digest, Sha256};

use crate::config::Config;

#[derive(Debug)]
pub enum ApiError {
    Http(String),
    Status(i32, String),
    Io(std::io::Error),
    ChecksumMismatch { expected: String, actual: String },
    /// A server-supplied filename failed the path-containment check (see
    /// `sync::contained_join`) — absolute, empty, or escaping the intended
    /// base directory. Terminal: retrying the same manifest entry can't fix
    /// a bad filename.
    UnsafePath(String),
}

impl fmt::Display for ApiError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ApiError::Http(e) => write!(f, "http error: {e}"),
            ApiError::Status(code, url) => write!(f, "server returned {code} for {url}"),
            ApiError::Io(e) => write!(f, "io error: {e}"),
            ApiError::ChecksumMismatch { expected, actual } => {
                write!(f, "checksum mismatch (expected {expected}, got {actual})")
            }
            ApiError::UnsafePath(name) => {
                write!(f, "rejected unsafe server-supplied path: {name:?}")
            }
        }
    }
}

impl From<std::io::Error> for ApiError {
    fn from(error: std::io::Error) -> Self {
        ApiError::Io(error)
    }
}

/// Extra JSON fields (version, generated_at, per-item series/size details)
/// are intentionally ignored — only what the sync logic needs is kept.
/// The v3 fields (removals, status_url, clippings_url, thumbnails) default
/// to empty against older servers.
#[derive(Debug, Deserialize)]
pub struct Manifest {
    #[serde(default)]
    pub items: Vec<ManifestItem>,
    #[serde(default)]
    pub removals: Vec<Removal>,
    #[serde(default)]
    pub status_url: Option<String>,
    #[serde(default)]
    pub clippings_url: Option<String>,
    /// Reader/experiment policy the daemon enforces on-device. Absent on
    /// older servers → both false (leave the device alone).
    #[serde(default)]
    pub device_settings: DeviceSettings,
}

/// Per-device reader/experiment policy (see hardening.rs).
#[derive(Debug, Deserialize, Default, Clone, Copy)]
pub struct DeviceSettings {
    #[serde(default)]
    pub modern_reader: bool,
    #[serde(default)]
    pub freeze_experiments: bool,
}

#[derive(Debug, Deserialize)]
pub struct ManifestItem {
    pub id: String,
    pub title: String,
    #[serde(default)]
    pub author: Option<String>,
    pub format: String,
    pub filename: String,
    pub size: u64,
    pub sha256: String,
    pub url: String,
    #[serde(default)]
    pub thumbnail: Option<Thumbnail>,
    #[serde(default)]
    pub reading_state: Option<ReadingStateSummary>,
}

/// Library cover to install into the firmware's thumbnail cache
/// (fallback path for files that still carry a store identity).
#[derive(Debug, Deserialize)]
pub struct Thumbnail {
    pub url: String,
    pub filename: String,
}

/// A server-requested eviction: delete the file on-device, then ack.
#[derive(Debug, Deserialize)]
pub struct Removal {
    /// Book public id (the `items[].id` key and state map key).
    pub id: String,
    pub filename: String,
    #[serde(default)]
    pub thumbnail_filename: Option<String>,
    #[serde(default)]
    pub reason: Option<String>,
    pub ack_url: String,
}

#[derive(Debug, Deserialize)]
pub struct ReadingStateSummary {
    pub mtime: u64,
}

pub struct Client<'a> {
    config: &'a Config,
}

const CONNECT_TIMEOUT_SECS: u64 = 20;

impl<'a> Client<'a> {
    pub fn new(config: &'a Config) -> Self {
        Client { config }
    }

    fn url(&self, path: &str) -> String {
        format!("{}{}", self.config.server_url, path)
    }

    fn get(&self, path: &str) -> minreq::Request {
        minreq::get(self.url(path))
            .with_header("X-Api-Token", &self.config.api_token)
            .with_timeout(CONNECT_TIMEOUT_SECS)
    }

    pub fn healthz(&self) -> Result<(), ApiError> {
        let response = minreq::get(self.url("/healthz"))
            .with_timeout(CONNECT_TIMEOUT_SECS)
            .send()
            .map_err(|e| ApiError::Http(e.to_string()))?;
        expect_ok(response.status_code, "/healthz")?;
        Ok(())
    }

    pub fn manifest(&self) -> Result<Manifest, ApiError> {
        with_retry("manifest fetch", RETRY_ATTEMPTS, || {
            let response = self
                .get("/api/v1/manifest")
                .send()
                .map_err(|e| ApiError::Http(e.to_string()))?;
            expect_ok(response.status_code, "/api/v1/manifest")?;
            serde_json::from_slice(response.as_bytes())
                .map_err(|e| ApiError::Http(format!("manifest parse: {e}")))
        })
    }

    /// Streams and verifies into `destination.part` WITHOUT the final
    /// rename — the sync layer decides placement (replacing an indexed
    /// file needs a delete + rescan first or the catalog keeps stale
    /// metadata; verified on firmware 5.19.2).
    ///
    /// `send_lazy()` streams straight off the socket (see minreq's
    /// `ResponseLazy`, a byte iterator over a buffered `HttpStream`) rather
    /// than buffering the whole body in memory, so a `.part` left over from
    /// an interrupted download is worth resuming: we ask for `bytes=N-` and
    /// append if the server answers 206, and fall back to a clean restart
    /// otherwise. Either way the FULL file is rehashed from disk afterwards
    /// — there is no in-memory hasher state carried over from whatever
    /// process wrote the existing prefix, so a resumed hash can't be assumed
    /// correct.
    pub fn download_book_part(
        &self,
        item: &ManifestItem,
        destination: &Path,
    ) -> Result<PathBuf, ApiError> {
        if let Some(parent) = destination.parent() {
            fs::create_dir_all(parent)?;
        }
        let part = destination.with_extension("part");

        let resume_from = fs::metadata(&part).ok().map(|m| m.len()).filter(|&len| len > 0);

        let (response, append) = match resume_from {
            Some(existing_len) => {
                let response = self
                    .get(&item.url)
                    .with_timeout(3600) // big books over slow Kindle wifi
                    .with_header("Range", format!("bytes={existing_len}-"))
                    .send_lazy()
                    .map_err(|e| ApiError::Http(e.to_string()))?;
                if response.status_code == 206 {
                    (response, true)
                } else if (200..300).contains(&response.status_code) {
                    // Server ignored the Range request and is sending the
                    // whole file again — restart clean rather than append a
                    // full body onto the bytes we already have.
                    (response, false)
                } else {
                    // The `.part` we have doesn't correspond to what the
                    // server has any more (e.g. 416 for a stale/oversized
                    // partial from a since-changed file) — drop it and
                    // fetch the whole file fresh.
                    eprintln!(
                        "download resume for {} rejected ({}); restarting from scratch",
                        item.title, response.status_code
                    );
                    fs::remove_file(&part).ok();
                    let response = self
                        .get(&item.url)
                        .with_timeout(3600)
                        .send_lazy()
                        .map_err(|e| ApiError::Http(e.to_string()))?;
                    expect_ok(response.status_code, &item.url)?;
                    (response, false)
                }
            }
            None => {
                let response = self
                    .get(&item.url)
                    .with_timeout(3600)
                    .send_lazy()
                    .map_err(|e| ApiError::Http(e.to_string()))?;
                expect_ok(response.status_code, &item.url)?;
                (response, false)
            }
        };

        let mut file = std::io::BufWriter::new(
            fs::OpenOptions::new()
                .create(true)
                .write(true)
                .append(append)
                .truncate(!append)
                .open(&part)?,
        );
        let mut buffer = Vec::with_capacity(64 * 1024);
        for byte in response {
            let (byte, _) = byte.map_err(|e| ApiError::Http(e.to_string()))?;
            buffer.push(byte);
            if buffer.len() == buffer.capacity() {
                file.write_all(&buffer)?;
                buffer.clear();
            }
        }
        file.write_all(&buffer)?;
        file.flush()?;
        drop(file);

        // Always rehash the full file from disk (see doc comment above).
        let actual = hash_file(&part)?;
        if actual != item.sha256 {
            fs::remove_file(&part).ok();
            return Err(ApiError::ChecksumMismatch {
                expected: item.sha256.clone(),
                actual,
            });
        }

        Ok(part)
    }

    /// The tiny "did anything change?" probe backing the fast-poll loop.
    pub fn queue_version(&self) -> Result<u64, ApiError> {
        #[derive(Deserialize)]
        struct QueueVersion {
            version: u64,
        }
        let path = "/api/v1/queue_version";
        let response = self
            .get(path)
            .send()
            .map_err(|e| ApiError::Http(e.to_string()))?;
        expect_ok(response.status_code, path)?;
        let parsed: QueueVersion = serde_json::from_slice(response.as_bytes())
            .map_err(|e| ApiError::Http(format!("queue_version parse: {e}")))?;
        Ok(parsed.version)
    }

    /// Small binary fetch (thumbnails).
    pub fn download_bytes(&self, path: &str) -> Result<Vec<u8>, ApiError> {
        let response = self
            .get(path)
            .with_timeout(120)
            .send()
            .map_err(|e| ApiError::Http(e.to_string()))?;
        expect_ok(response.status_code, path)?;
        Ok(response.into_bytes())
    }

    /// POST a JSON body (device status, removal acks). Both callers are
    /// idempotent (posting status twice, or acking an already-acked removal,
    /// is harmless), so this is safe to retry.
    pub fn post_json(&self, path: &str, body: &serde_json::Value) -> Result<(), ApiError> {
        with_retry(path, RETRY_ATTEMPTS, || {
            let response = minreq::post(self.url(path))
                .with_header("X-Api-Token", &self.config.api_token)
                .with_header("Content-Type", "application/json")
                .with_timeout(60)
                .with_body(body.to_string())
                .send()
                .map_err(|e| ApiError::Http(e.to_string()))?;
            expect_ok(response.status_code, path)?;
            Ok(())
        })
    }

    /// Uploads the whole My Clippings.txt. Re-uploading the same bytes on
    /// retry is harmless (it's a full replace, not an append).
    pub fn put_clippings(&self, path: &str, body: Vec<u8>) -> Result<(), ApiError> {
        with_retry(path, RETRY_ATTEMPTS, || {
            let response = minreq::put(self.url(path))
                .with_header("X-Api-Token", &self.config.api_token)
                .with_header("Content-Type", "text/plain")
                .with_timeout(120)
                .with_body(body.clone())
                .send()
                .map_err(|e| ApiError::Http(e.to_string()))?;
            expect_ok(response.status_code, path)?;
            Ok(())
        })
    }

    pub fn fetch_reading_state(&self, book_id: &str) -> Result<Option<Vec<u8>>, ApiError> {
        let path = format!("/api/v1/books/{book_id}/reading_state");
        let response = self
            .get(&path)
            .send()
            .map_err(|e| ApiError::Http(e.to_string()))?;
        if response.status_code == 404 {
            return Ok(None);
        }
        expect_ok(response.status_code, &path)?;
        Ok(Some(response.into_bytes()))
    }

    /// Uploads the `.sdr` bundle, replacing whatever the server has for this
    /// book — safe to retry (same bytes, same mtime).
    pub fn push_reading_state(
        &self,
        book_id: &str,
        bundle: Vec<u8>,
        mtime: u64,
    ) -> Result<(), ApiError> {
        let path = format!("/api/v1/books/{book_id}/reading_state");
        with_retry(&path, RETRY_ATTEMPTS, || {
            let response = minreq::put(self.url(&path))
                .with_header("X-Api-Token", &self.config.api_token)
                .with_header("X-Sdr-Mtime", mtime.to_string())
                .with_header("Content-Type", "application/gzip")
                .with_timeout(120)
                .with_body(bundle.clone())
                .send()
                .map_err(|e| ApiError::Http(e.to_string()))?;
            expect_ok(response.status_code, &path)?;
            Ok(())
        })
    }
}

fn expect_ok(status: i32, url: &str) -> Result<(), ApiError> {
    if (200..300).contains(&status) {
        Ok(())
    } else {
        Err(ApiError::Status(status, url.to_string()))
    }
}

/// Number of attempts (not extra retries) `with_retry` makes for the small
/// set of idempotent calls it wraps. Kept low: a Kindle runs on battery and
/// flaky wifi, so we want to fail fast, not hammer a struggling server.
const RETRY_ATTEMPTS: u32 = 3;

/// Is `error` worth a retry? Reuses the classification `ApiError` already
/// encodes: `Http` is a transport-level failure (DNS, connect, timeout,
/// connection reset — minreq folds all of these into one variant, see
/// `minreq::Error`), which is exactly the kind of thing that can succeed a
/// moment later. `Status` is only retried for 429 (rate limited) and 5xx
/// (server trouble); any other 4xx (404, 400, ...) is the server telling us
/// plainly that retrying won't help. `Io` and `ChecksumMismatch` are local/
/// content problems a retry of the same request will not fix.
fn is_transient(error: &ApiError) -> bool {
    match error {
        ApiError::Http(_) => true,
        ApiError::Status(code, _) => *code == 429 || (500..600).contains(code),
        ApiError::Io(_) => false,
        ApiError::ChecksumMismatch { .. } => false,
        ApiError::UnsafePath(_) => false,
    }
}

/// Exponential backoff with a little jitter, capped low on purpose — total
/// extra wait across `RETRY_ATTEMPTS` attempts is a handful of seconds, not
/// minutes, because this can run on every sync pass on battery power.
fn backoff_delay(attempt: u32) -> Duration {
    const BASE: Duration = Duration::from_millis(750);
    const CAP: Duration = Duration::from_secs(3);
    let scaled = BASE.saturating_mul(1u32 << attempt.saturating_sub(1).min(4));
    scaled.min(CAP) + Duration::from_millis(jitter_ms(250))
}

/// A little std-only pseudo-randomness (no `rand` dependency) so retries
/// from a fresh process don't all sleep the exact same duration. Not
/// security-sensitive — this only spaces out backoff sleeps.
fn jitter_ms(cap: u64) -> u64 {
    use std::collections::hash_map::RandomState;
    use std::hash::{BuildHasher, Hasher};
    if cap == 0 {
        return 0;
    }
    let mut hasher = RandomState::new().build_hasher();
    hasher.write_u128(
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos(),
    );
    hasher.finish() % cap
}

/// Retries `f` with exponential backoff, but only for transient errors (see
/// [`is_transient`]) — a terminal error (404, malformed body, ...) returns
/// immediately on the first attempt. `label` is only used in the log line.
pub fn with_retry<T>(
    label: &str,
    max_attempts: u32,
    f: impl FnMut() -> Result<T, ApiError>,
) -> Result<T, ApiError> {
    with_retry_delayed(label, max_attempts, backoff_delay, f)
}

/// Same as [`with_retry`], but with the backoff function injected so tests
/// can exercise the retry/attempt-counting logic without actually sleeping.
fn with_retry_delayed<T>(
    label: &str,
    max_attempts: u32,
    delay_for: impl Fn(u32) -> Duration,
    mut f: impl FnMut() -> Result<T, ApiError>,
) -> Result<T, ApiError> {
    let mut attempt = 0;
    loop {
        attempt += 1;
        match f() {
            Ok(value) => return Ok(value),
            Err(error) if attempt < max_attempts && is_transient(&error) => {
                let delay = delay_for(attempt);
                eprintln!(
                    "{label}: attempt {attempt}/{max_attempts} failed ({error}), retrying in {delay:?}"
                );
                thread::sleep(delay);
            }
            Err(error) => return Err(error),
        }
    }
}

pub fn hex(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        out.push_str(&format!("{byte:02x}"));
    }
    out
}

/// SHA-256 of a file's full contents, read back from disk. Used to verify a
/// download regardless of whether it was written in one pass or resumed
/// across multiple process invocations.
fn hash_file(path: &Path) -> Result<String, ApiError> {
    let mut file = fs::File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buffer = [0u8; 64 * 1024];
    loop {
        let read = file.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    Ok(hex(&hasher.finalize()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_manifest_json() {
        let json = r#"{
            "version": 2,
            "generated_at": 1,
            "items": [{
                "id": "abc", "title": "T", "author": null, "series": null,
                "format": "azw3", "filename": "T.azw3", "size": 10,
                "sha256": "aa", "url": "/api/v1/books/abc/file?fmt=azw3",
                "reading_state": {"mtime": 5, "sha256": "bb", "size": 3,
                                   "device_id": 1, "url": "/api/v1/books/abc/reading_state"}
            }]
        }"#;
        let manifest: Manifest = serde_json::from_str(json).unwrap();
        assert_eq!(manifest.items.len(), 1);
        let item = &manifest.items[0];
        assert_eq!(item.id, "abc");
        assert_eq!(item.reading_state.as_ref().unwrap().mtime, 5);
        // v2 server: the v3 fields default to empty.
        assert!(manifest.removals.is_empty());
        assert!(manifest.status_url.is_none());
        assert!(item.thumbnail.is_none());
    }

    #[test]
    fn parses_v3_manifest_fields() {
        let json = r#"{
            "version": 3,
            "generated_at": 1,
            "items": [{
                "id": "abc", "title": "T", "author": null, "series": null,
                "format": "azw3", "filename": "T.azw3", "size": 10,
                "sha256": "aa", "url": "/api/v1/books/abc/file?fmt=azw3",
                "thumbnail": {"url": "/api/v1/books/abc/thumbnail",
                               "filename": "thumbnail_uuid_EBOK_portrait.jpg"},
                "reading_state": null
            }],
            "removals": [{
                "id": "gone", "delivery_id": 7, "filename": "Old.azw3",
                "thumbnail_filename": null, "reason": "finished",
                "ack_url": "/api/v1/removals/7/ack"
            }],
            "status_url": "/api/v1/device/status",
            "clippings_url": "/api/v1/clippings"
        }"#;
        let manifest: Manifest = serde_json::from_str(json).unwrap();
        let thumb = manifest.items[0].thumbnail.as_ref().unwrap();
        assert_eq!(thumb.filename, "thumbnail_uuid_EBOK_portrait.jpg");
        assert_eq!(manifest.removals.len(), 1);
        assert_eq!(manifest.removals[0].id, "gone");
        assert_eq!(manifest.removals[0].reason.as_deref(), Some("finished"));
        assert_eq!(manifest.removals[0].ack_url, "/api/v1/removals/7/ack");
        assert_eq!(manifest.status_url.as_deref(), Some("/api/v1/device/status"));
        assert_eq!(manifest.clippings_url.as_deref(), Some("/api/v1/clippings"));
    }

    #[test]
    fn hex_encodes() {
        assert_eq!(hex(&[0x00, 0xff, 0x0a]), "00ff0a");
    }

    use std::cell::Cell;

    #[test]
    fn is_transient_classifies_errors() {
        assert!(is_transient(&ApiError::Http("connection reset".into())));
        assert!(is_transient(&ApiError::Status(429, "u".into())));
        assert!(is_transient(&ApiError::Status(500, "u".into())));
        assert!(is_transient(&ApiError::Status(503, "u".into())));
        assert!(!is_transient(&ApiError::Status(404, "u".into())));
        assert!(!is_transient(&ApiError::Status(400, "u".into())));
        assert!(!is_transient(&ApiError::Io(std::io::Error::other("x"))));
        assert!(!is_transient(&ApiError::ChecksumMismatch {
            expected: "a".into(),
            actual: "b".into(),
        }));
        assert!(!is_transient(&ApiError::UnsafePath("../etc/passwd".into())));
    }

    #[test]
    fn with_retry_succeeds_after_transient_failures() {
        let calls = Cell::new(0);
        let result = with_retry_delayed("t", 3, |_| Duration::ZERO, || {
            let n = calls.get() + 1;
            calls.set(n);
            if n < 3 {
                Err(ApiError::Http("timeout".into()))
            } else {
                Ok(42)
            }
        });
        assert_eq!(result.unwrap(), 42);
        assert_eq!(calls.get(), 3);
    }

    #[test]
    fn with_retry_gives_up_after_max_attempts() {
        let calls = Cell::new(0);
        let result: Result<(), ApiError> = with_retry_delayed("t", 3, |_| Duration::ZERO, || {
            calls.set(calls.get() + 1);
            Err(ApiError::Http("still down".into()))
        });
        assert!(result.is_err());
        assert_eq!(calls.get(), 3); // exactly max_attempts, never more
    }

    #[test]
    fn with_retry_does_not_retry_terminal_errors() {
        let calls = Cell::new(0);
        let result: Result<(), ApiError> = with_retry_delayed("t", 3, |_| Duration::ZERO, || {
            calls.set(calls.get() + 1);
            Err(ApiError::Status(404, "not found".into()))
        });
        assert!(result.is_err());
        assert_eq!(calls.get(), 1); // fails fast, no retry
    }

    #[test]
    fn backoff_delay_grows_and_is_capped_in_the_seconds_range() {
        let first = backoff_delay(1);
        let second = backoff_delay(2);
        let capped = backoff_delay(10);
        assert!(first < second);
        assert!(capped <= Duration::from_secs(3) + Duration::from_millis(250));
        assert!(first <= Duration::from_secs(1));
    }
}
