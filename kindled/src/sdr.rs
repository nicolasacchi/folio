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

/// Restores a bundle into the sidecar directory, atomically. The bundle is
/// first validated (every entry must be a plain file/dir path that stays
/// inside the sidecar — see [`validate_bundle`]) and unpacked into a scratch
/// directory *beside* `dir` on the same filesystem; only once that fully
/// succeeds does the existing directory (if any) get moved to
/// `<dir>.bak-<unix-ts>` and the scratch directory get renamed into place.
/// A single `rename` is atomic on the same filesystem, so a reader (or a
/// process crash) never observes a half-unpacked sidecar, and any failure —
/// a corrupt/truncated bundle, a tar-slip entry, a mid-unpack I/O error —
/// leaves the existing sidecar completely untouched. The conflict policy is
/// latest-wins but never destroy local state without a backup.
pub fn unpack(bundle: &[u8], dir: &Path) -> io::Result<Option<PathBuf>> {
    validate_bundle(bundle).map_err(|error| {
        eprintln!("sdr unpack for {} rejected: {error}", dir.display());
        error
    })?;

    let parent = dir.parent().unwrap_or_else(|| Path::new("."));
    fs::create_dir_all(parent)?;
    let scratch = parent.join(format!(
        ".{}.unpack-{}-{}",
        dir.file_name().and_then(|n| n.to_str()).unwrap_or("sdr"),
        std::process::id(),
        SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_nanos(),
    ));
    // A stale scratch dir from a previous killed attempt would collide.
    let _ = fs::remove_dir_all(&scratch);
    fs::create_dir_all(&scratch)?;

    if let Err(error) = unpack_into(bundle, &scratch) {
        let _ = fs::remove_dir_all(&scratch);
        eprintln!(
            "sdr unpack for {} failed ({error}); leaving existing sidecar untouched",
            dir.display()
        );
        return Err(error);
    }

    let backup = if dir.exists() {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        let backup = dir.with_extension(format!("sdr.bak-{stamp}"));
        if let Err(error) = fs::rename(dir, &backup) {
            let _ = fs::remove_dir_all(&scratch);
            return Err(error);
        }
        Some(backup)
    } else {
        None
    };

    if let Err(error) = fs::rename(&scratch, dir) {
        // Put the original back so a failed swap doesn't lose it.
        if let Some(backup) = &backup {
            let _ = fs::rename(backup, dir);
        }
        let _ = fs::remove_dir_all(&scratch);
        return Err(error);
    }

    Ok(backup)
}

fn unpack_into(bundle: &[u8], scratch: &Path) -> io::Result<()> {
    let mut archive = tar::Archive::new(GzDecoder::new(bundle));
    archive.unpack(scratch)
}

/// Pre-scans every entry in the bundle before extraction: rejects absolute
/// paths, any `..` component (tar-slip), and any symlink/hardlink entry
/// (a `.sdr` sidecar is plain files and directories only — a link entry has
/// no legitimate use here and, if followed later, could point outside the
/// sidecar). `tar` itself already skips `..`/absolute entries on unpack
/// (see its crate-level `# Security` docs), but that's "silently drop the
/// bad entry and keep going" — this is a fail-closed check that rejects the
/// whole bundle instead, before anything is written to disk.
fn validate_bundle(bundle: &[u8]) -> io::Result<()> {
    let mut archive = tar::Archive::new(GzDecoder::new(bundle));
    let entries = archive.entries()?;
    for entry in entries {
        let entry = entry?;
        let path = entry.path()?;
        if !is_contained_relative_path(&path) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("bundle entry escapes the sidecar directory: {}", path.display()),
            ));
        }
        let kind = entry.header().entry_type();
        if kind.is_symlink() || kind.is_hard_link() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("bundle contains an unexpected link entry: {}", path.display()),
            ));
        }
    }
    Ok(())
}

/// A relative path with no `..`/root/prefix component — i.e. one that,
/// joined onto any base directory, cannot climb above it.
fn is_contained_relative_path(path: &Path) -> bool {
    if path.is_absolute() {
        return false;
    }
    path.components()
        .all(|c| matches!(c, std::path::Component::Normal(_) | std::path::Component::CurDir))
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

    /// Builds a tar.gz with entries at exactly the raw names given, bypassing
    /// `tar::Header::set_path`'s own `..`/absolute-path validation (which a
    /// real attacker's tool — not this crate — would not apply either) so
    /// the test can exercise `validate_bundle`'s guard.
    fn build_raw_tar_gz(entries: &[(&str, &[u8])]) -> Vec<u8> {
        let encoder = GzEncoder::new(Vec::new(), Compression::default());
        let mut builder = tar::Builder::new(encoder);
        for &(name, data) in entries {
            let mut header = tar::Header::new_gnu();
            header.set_size(data.len() as u64);
            header.set_mode(0o644);
            let raw = header.as_old_mut();
            let name_bytes = name.as_bytes();
            raw.name[..name_bytes.len()].copy_from_slice(name_bytes);
            header.set_cksum();
            builder.append(&header, data).unwrap();
        }
        builder.into_inner().unwrap().finish().unwrap()
    }

    #[test]
    fn tar_slip_parent_dir_entry_is_rejected_and_sidecar_untouched() {
        let root = temp_dir("tarslip-parent");
        let sdr = root.join("Book.sdr");
        fs::create_dir_all(&sdr).unwrap();
        fs::write(sdr.join("Book.mbp1"), b"original").unwrap();

        let malicious = build_raw_tar_gz(&[("../evil.txt", b"pwned")]);
        assert!(unpack(&malicious, &sdr).is_err());

        // Existing sidecar content is untouched, and nothing escaped into
        // the parent directory.
        assert_eq!(fs::read(sdr.join("Book.mbp1")).unwrap(), b"original");
        assert!(!root.join("evil.txt").exists());
        // No leftover scratch or backup directories.
        assert_eq!(fs::read_dir(&root).unwrap().count(), 1); // just Book.sdr

        fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn tar_slip_absolute_path_entry_is_rejected() {
        let root = temp_dir("tarslip-abs");
        let sdr = root.join("Book.sdr");

        let malicious = build_raw_tar_gz(&[("/etc/evil.txt", b"pwned")]);
        assert!(unpack(&malicious, &sdr).is_err());
        assert!(!sdr.exists()); // never created

        fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn truncated_bundle_is_rejected_and_existing_sidecar_untouched() {
        let root = temp_dir("truncated");
        let sdr = root.join("Book.sdr");
        fs::create_dir_all(&sdr).unwrap();
        fs::write(sdr.join("Book.mbp1"), b"original").unwrap();

        let good = pack(&sdr).unwrap();
        let truncated = &good[..good.len() / 2];
        assert!(unpack(truncated, &sdr).is_err());

        // A corrupt/partial bundle must never touch the existing sidecar.
        assert_eq!(fs::read(sdr.join("Book.mbp1")).unwrap(), b"original");
        assert_eq!(fs::read_dir(&root).unwrap().count(), 1); // just Book.sdr

        fs::remove_dir_all(&root).unwrap();
    }
}
