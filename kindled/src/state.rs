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
    /// Loads sync state, falling back through primary -> backup -> default
    /// so a corrupt or truncated `state.json` (e.g. power loss mid-write on
    /// an older kindled that didn't keep a `.bak`, or filesystem
    /// corruption) doesn't silently forget every downloaded book and
    /// un-acked removal. Any fallback below the primary file is loud on
    /// stderr, since it means the daemon is about to re-check/re-download
    /// books it thinks it already has, or retry removals it may have
    /// already applied.
    pub fn load(path: &Path) -> State {
        match Self::try_load(path) {
            Ok(state) => return state,
            Err(error) => {
                eprintln!(
                    "WARNING: state file {} is missing or corrupt ({error}); trying backup",
                    path.display()
                );
            }
        }

        let backup = backup_path(path);
        match Self::try_load(&backup) {
            Ok(state) => {
                eprintln!("WARNING: recovered sync state from backup {}", backup.display());
                state
            }
            Err(error) => {
                eprintln!(
                    "WARNING: backup state file {} is also missing or corrupt ({error}); \
                     starting from a blank state (books will be re-checked and any \
                     un-acked removals retried)",
                    backup.display()
                );
                State::default()
            }
        }
    }

    fn try_load(path: &Path) -> Result<State, String> {
        let bytes = fs::read(path).map_err(|e| e.to_string())?;
        serde_json::from_slice(&bytes).map_err(|e| e.to_string())
    }

    /// Writes the new state via a temp file + atomic rename (unchanged from
    /// before — the Kindle can lose power mid-write). Before that swap, the
    /// file that's about to be replaced is copied to `state.json.bak`, so a
    /// save that lands a corrupt/truncated `state.json` (or one that parses
    /// but is semantically wrong) still leaves the previous, known-good
    /// generation on disk for `load` to fall back to.
    pub fn save(&self, path: &Path) -> io::Result<()> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }

        if path.exists() {
            let backup = backup_path(path);
            if let Err(error) = fs::copy(path, &backup) {
                eprintln!(
                    "WARNING: could not refresh state backup {}: {error}",
                    backup.display()
                );
            }
        }

        let tmp = path.with_extension("json.tmp");
        fs::write(&tmp, serde_json::to_vec_pretty(self)?)?;
        fs::rename(&tmp, path)
    }
}

fn backup_path(path: &Path) -> PathBuf {
    path.with_extension("json.bak")
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

    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("kindled-state-{tag}-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn corrupt_primary_falls_back_to_backup() {
        let dir = temp_dir("corrupt-primary");
        let path = dir.join("state.json");
        let backup = backup_path(&path);

        let good = State { clippings_pushed_mtime: 7, ..Default::default() };
        fs::write(&backup, serde_json::to_vec_pretty(&good).unwrap()).unwrap();
        fs::write(&path, b"{ not valid json at all").unwrap();

        let loaded = State::load(&path);
        assert_eq!(loaded.clippings_pushed_mtime, 7);

        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn both_primary_and_backup_corrupt_yields_default() {
        let dir = temp_dir("both-corrupt");
        let path = dir.join("state.json");
        let backup = backup_path(&path);

        fs::write(&path, b"not json").unwrap();
        fs::write(&backup, b"also not json").unwrap();

        let loaded = State::load(&path);
        assert!(loaded.books.is_empty());
        assert_eq!(loaded.clippings_pushed_mtime, 0);

        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn normal_save_keeps_a_backup_of_the_previous_generation() {
        let dir = temp_dir("keeps-backup");
        let path = dir.join("state.json");
        let backup = backup_path(&path);

        let mut state = State { clippings_pushed_mtime: 1, ..Default::default() };
        state.save(&path).unwrap();
        assert!(!backup.exists()); // nothing to back up yet on the first save

        state.clippings_pushed_mtime = 2;
        state.save(&path).unwrap();
        assert!(backup.exists());

        // The backup holds the *previous* generation, the primary the new one.
        assert_eq!(State::load(&path).clippings_pushed_mtime, 2);
        assert_eq!(State::try_load(&backup).unwrap().clippings_pushed_mtime, 1);

        fs::remove_dir_all(&dir).unwrap();
    }
}
