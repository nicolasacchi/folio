//! `.sdr` sidecar handling: the Kindle stores reading position and
//! annotations in `<book>.sdr/` next to the book file. Bundles are tar.gz
//! archives of that directory, exchanged with the server.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use flate2::read::GzDecoder;
use flate2::write::GzEncoder;
use flate2::Compression;

/// `/x/Foo.azw3` -> `/x/Foo.sdr`
pub fn sdr_dir_for(book_path: &Path) -> PathBuf {
    book_path.with_extension("sdr")
}

/// Newest content mtime (unix seconds) of any file inside the sidecar,
/// or None when the directory is missing or empty.
pub fn latest_mtime(dir: &Path) -> Option<u64> {
    let mut newest = None;
    let entries = fs::read_dir(dir).ok()?;
    for entry in entries.flatten() {
        let path = entry.path();
        let mtime = if path.is_dir() {
            latest_mtime(&path)
        } else {
            entry
                .metadata()
                .ok()
                .and_then(|m| m.modified().ok())
                .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                .map(|d| d.as_secs())
        };
        if let Some(mtime) = mtime {
            newest = Some(newest.map_or(mtime, |n: u64| n.max(mtime)));
        }
    }
    newest
}

/// Tars and gzips the sidecar directory. Entry paths are relative to the
/// directory itself, so bundles restore cleanly next to any book file.
pub fn pack(dir: &Path) -> io::Result<Vec<u8>> {
    let encoder = GzEncoder::new(Vec::new(), Compression::default());
    let mut archive = tar::Builder::new(encoder);
    archive.append_dir_all(".", dir)?;
    archive.into_inner()?.finish()
}

/// Restores a bundle into the sidecar directory. The existing directory,
/// if any, is first moved to `<dir>.bak-<unix-ts>` — the conflict policy is
/// latest-wins but never destroy local state without a backup.
pub fn unpack(bundle: &[u8], dir: &Path) -> io::Result<Option<PathBuf>> {
    let backup = if dir.exists() {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        let backup = dir.with_extension(format!("sdr.bak-{stamp}"));
        fs::rename(dir, &backup)?;
        Some(backup)
    } else {
        None
    };

    fs::create_dir_all(dir)?;
    let mut archive = tar::Archive::new(GzDecoder::new(bundle));
    archive.unpack(dir)?;
    Ok(backup)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("kindled-sdr-{tag}-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn maps_book_path_to_sdr_dir() {
        assert_eq!(
            sdr_dir_for(Path::new("/mnt/us/documents/PrivateCloud/Foo.azw3")),
            Path::new("/mnt/us/documents/PrivateCloud/Foo.sdr")
        );
    }

    #[test]
    fn packs_and_unpacks_a_sidecar_roundtrip() {
        let root = temp_dir("roundtrip");
        let sdr = root.join("Book.sdr");
        fs::create_dir_all(&sdr).unwrap();
        fs::write(sdr.join("Book.mbp1"), b"progress-bytes").unwrap();
        fs::write(sdr.join("Book.mbs"), b"more-state").unwrap();

        let bundle = pack(&sdr).unwrap();
        assert!(!bundle.is_empty());

        // Restore into a fresh location.
        let restored = root.join("Restored.sdr");
        let backup = unpack(&bundle, &restored).unwrap();
        assert!(backup.is_none());
        assert_eq!(fs::read(restored.join("Book.mbp1")).unwrap(), b"progress-bytes");
        assert_eq!(fs::read(restored.join("Book.mbs")).unwrap(), b"more-state");

        // Restoring over an existing dir backs it up first.
        fs::write(restored.join("local-only.txt"), b"x").unwrap();
        let backup = unpack(&bundle, &restored).unwrap().expect("backup created");
        assert!(backup.exists());
        assert!(fs::read(backup.join("local-only.txt")).is_ok());
        assert!(!restored.join("local-only.txt").exists());

        fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn latest_mtime_none_for_missing_dir() {
        assert_eq!(latest_mtime(Path::new("/nonexistent-sdr-dir")), None);
    }

    #[test]
    fn latest_mtime_sees_nested_files() {
        let root = temp_dir("mtime");
        let nested = root.join("inner");
        fs::create_dir_all(&nested).unwrap();
        fs::write(nested.join("file.mbs"), b"x").unwrap();
        assert!(latest_mtime(&root).unwrap() > 0);
        fs::remove_dir_all(&root).unwrap();
    }
}
