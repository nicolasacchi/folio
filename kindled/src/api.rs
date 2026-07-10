//! HTTP client for the Folio server's device API (plain HTTP on the LAN).

use std::fmt;
use std::fs;
use std::io::Write;
use std::path::Path;

use serde::Deserialize;
use sha2::{Digest, Sha256};

use crate::config::Config;

#[derive(Debug)]
pub enum ApiError {
    Http(String),
    Status(i32, String),
    Io(std::io::Error),
    ChecksumMismatch { expected: String, actual: String },
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
#[derive(Debug, Deserialize)]
pub struct Manifest {
    #[serde(default)]
    pub items: Vec<ManifestItem>,
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
    pub reading_state: Option<ReadingStateSummary>,
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
        let response = self
            .get("/api/v1/manifest")
            .send()
            .map_err(|e| ApiError::Http(e.to_string()))?;
        expect_ok(response.status_code, "/api/v1/manifest")?;
        serde_json::from_slice(response.as_bytes())
            .map_err(|e| ApiError::Http(format!("manifest parse: {e}")))
    }

    /// Streams a book to `destination.part`, verifies the sha256, then
    /// renames into place so readers never see a half-written file.
    pub fn download_book(
        &self,
        item: &ManifestItem,
        destination: &Path,
    ) -> Result<(), ApiError> {
        if let Some(parent) = destination.parent() {
            fs::create_dir_all(parent)?;
        }
        let part = destination.with_extension("part");

        let response = self
            .get(&item.url)
            .with_timeout(3600) // big books over slow Kindle wifi
            .send_lazy()
            .map_err(|e| ApiError::Http(e.to_string()))?;
        expect_ok(response.status_code, &item.url)?;

        let mut file = std::io::BufWriter::new(fs::File::create(&part)?);
        let mut hasher = Sha256::new();
        let mut buffer = Vec::with_capacity(64 * 1024);
        for byte in response {
            let (byte, _) = byte.map_err(|e| ApiError::Http(e.to_string()))?;
            buffer.push(byte);
            if buffer.len() == buffer.capacity() {
                hasher.update(&buffer);
                file.write_all(&buffer)?;
                buffer.clear();
            }
        }
        hasher.update(&buffer);
        file.write_all(&buffer)?;
        file.flush()?;
        drop(file);

        let actual = hex(&hasher.finalize());
        if actual != item.sha256 {
            fs::remove_file(&part).ok();
            return Err(ApiError::ChecksumMismatch {
                expected: item.sha256.clone(),
                actual,
            });
        }

        fs::rename(&part, destination)?;
        Ok(())
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

    pub fn push_reading_state(
        &self,
        book_id: &str,
        bundle: Vec<u8>,
        mtime: u64,
    ) -> Result<(), ApiError> {
        let path = format!("/api/v1/books/{book_id}/reading_state");
        let response = minreq::put(self.url(&path))
            .with_header("X-Api-Token", &self.config.api_token)
            .with_header("X-Sdr-Mtime", mtime.to_string())
            .with_header("Content-Type", "application/gzip")
            .with_timeout(120)
            .with_body(bundle)
            .send()
            .map_err(|e| ApiError::Http(e.to_string()))?;
        expect_ok(response.status_code, &path)?;
        Ok(())
    }
}

fn expect_ok(status: i32, url: &str) -> Result<(), ApiError> {
    if (200..300).contains(&status) {
        Ok(())
    } else {
        Err(ApiError::Status(status, url.to_string()))
    }
}

pub fn hex(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        out.push_str(&format!("{byte:02x}"));
    }
    out
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
    }

    #[test]
    fn hex_encodes() {
        assert_eq!(hex(&[0x00, 0xff, 0x0a]), "00ff0a");
    }
}
