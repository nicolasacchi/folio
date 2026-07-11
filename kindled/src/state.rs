//! Local sync state, persisted as JSON next to the config. Writes are
//! atomic (tmp + rename) because the Kindle can lose power mid-write.

use std::collections::HashMap;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

#[derive(Debug, Default, Serialize, Deserialize)]
pub struct State {
    /// Keyed by the server's book public id.
    #[serde(default)]
    pub books: HashMap<String, BookState>,
    /// Unix mtime of the My Clippings.txt we last uploaded.
    #[serde(default)]
    pub clippings_pushed_mtime: u64,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
pub struct BookState {
    /// Absolute path of the downloaded book file.
    pub path: PathBuf,
    pub sha256: String,
    /// Unix mtime of the newest local `.sdr` content we pushed.
    #[serde(default)]
    pub pushed_sdr_mtime: u64,
    /// Server bundle mtime we last applied locally.
    #[serde(default)]
    pub applied_sdr_mtime: u64,
    /// Thumbnail we installed into the firmware cache (name + size, so a
    /// scanner-regenerated placeholder is detected by the size change).
    #[serde(default)]
    pub thumbnail_filename: Option<String>,
    #[serde(default)]
    pub thumbnail_size: u64,
}

impl State {
    pub fn load(path: &Path) -> State {
        match fs::read(path) {
            Ok(bytes) => serde_json::from_slice(&bytes).unwrap_or_default(),
            Err(_) => State::default(),
        }
    }

    pub fn save(&self, path: &Path) -> io::Result<()> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        let tmp = path.with_extension("json.tmp");
        fs::write(&tmp, serde_json::to_vec_pretty(self)?)?;
        fs::rename(&tmp, path)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrips_through_disk() {
        let dir = std::env::temp_dir().join(format!("kindled-state-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("state.json");

        let mut state = State::default();
        state.books.insert(
            "abc".into(),
            BookState {
                path: PathBuf::from("/mnt/us/documents/PrivateCloud/x.azw3"),
                sha256: "ff".into(),
                pushed_sdr_mtime: 5,
                applied_sdr_mtime: 0,
                ..Default::default()
            },
        );
        state.save(&path).unwrap();

        let loaded = State::load(&path);
        assert_eq!(loaded.books["abc"].pushed_sdr_mtime, 5);
        assert_eq!(loaded.books["abc"].sha256, "ff");

        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn missing_or_corrupt_file_yields_default() {
        assert!(State::load(Path::new("/nonexistent/state.json")).books.is_empty());
    }
}
