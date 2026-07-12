//! KEY=VALUE config, sharing the file the shell-agent prototype used
//! (`/mnt/us/privatecloud/config`) so both can coexist during migration.

use std::collections::HashMap;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone)]
pub struct Config {
    pub server_url: String,
    pub api_token: String,
    pub document_dir: PathBuf,
    pub state_file: PathBuf,
    pub poll_interval_secs: u64,
    /// While the device is awake, probe the tiny queue-version endpoint
    /// this often and sync immediately on change. 0 disables the fast
    /// path (plain POLL_INTERVAL sleeps).
    pub fast_poll_secs: u64,
    pub auto_download: bool,
    /// The firmware's Library thumbnail cache.
    pub thumbnail_dir: PathBuf,
    /// Where the reader appends highlights/notes.
    pub clippings_path: PathBuf,
}

pub const DEFAULT_BASE_DIR: &str = "/mnt/us/privatecloud";
pub const DEFAULT_DOCUMENT_DIR: &str = "/mnt/us/documents/PrivateCloud";
pub const DEFAULT_THUMBNAIL_DIR: &str = "/mnt/us/system/thumbnails";
pub const DEFAULT_CLIPPINGS_PATH: &str = "/mnt/us/documents/My Clippings.txt";

impl Config {
    pub fn base_dir() -> PathBuf {
        std::env::var_os("PRIVATECLOUD_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from(DEFAULT_BASE_DIR))
    }

    pub fn path() -> PathBuf {
        Self::base_dir().join("config")
    }

    pub fn load() -> io::Result<Config> {
        Self::load_from(&Self::path())
    }

    pub fn load_from(path: &Path) -> io::Result<Config> {
        let text = fs::read_to_string(path)?;
        let values = parse_key_values(&text);
        let base = Self::base_dir();

        let server_url = values
            .get("SERVER_URL")
            .map(|s| s.trim_end_matches('/').to_string())
            .filter(|s| !s.is_empty())
            .ok_or_else(|| {
                io::Error::new(io::ErrorKind::InvalidData, "SERVER_URL missing from config")
            })?;

        Ok(Config {
            server_url,
            api_token: values.get("API_TOKEN").cloned().unwrap_or_default(),
            document_dir: values
                .get("DOCUMENT_DIR")
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from(DEFAULT_DOCUMENT_DIR)),
            state_file: base.join("state.json"),
            poll_interval_secs: values
                .get("POLL_INTERVAL")
                .and_then(|s| s.parse().ok())
                .unwrap_or(300),
            fast_poll_secs: values
                .get("FAST_POLL")
                .and_then(|s| s.parse().ok())
                .unwrap_or(30),
            auto_download: values
                .get("AUTO_DOWNLOAD")
                .map(|s| s != "0" && !s.eq_ignore_ascii_case("false"))
                .unwrap_or(true),
            thumbnail_dir: values
                .get("THUMBNAIL_DIR")
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from(DEFAULT_THUMBNAIL_DIR)),
            clippings_path: values
                .get("CLIPPINGS_PATH")
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from(DEFAULT_CLIPPINGS_PATH)),
        })
    }

    pub fn write_initial(server_url: &str, api_token: &str) -> io::Result<PathBuf> {
        let path = Self::path();
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        let body = format!(
            "SERVER_URL={}\nAPI_TOKEN={}\nDOCUMENT_DIR={}\nPOLL_INTERVAL=300\nAUTO_DOWNLOAD=1\n",
            server_url.trim_end_matches('/'),
            api_token,
            DEFAULT_DOCUMENT_DIR
        );
        fs::write(&path, body)?;
        Ok(path)
    }
}

fn parse_key_values(text: &str) -> HashMap<String, String> {
    let mut values = HashMap::new();
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if let Some((key, value)) = line.split_once('=') {
            let value = value.trim().trim_matches('"').trim_matches('\'');
            values.insert(key.trim().to_string(), value.to_string());
        }
    }
    values
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_key_values_with_comments_and_quotes() {
        let values = parse_key_values(
            "# comment\nSERVER_URL=\"http://h:1\"\n\nAPI_TOKEN=abc\nBAD LINE\nPOLL_INTERVAL=60\n",
        );
        assert_eq!(values.get("SERVER_URL").unwrap(), "http://h:1");
        assert_eq!(values.get("API_TOKEN").unwrap(), "abc");
        assert_eq!(values.get("POLL_INTERVAL").unwrap(), "60");
        assert!(!values.contains_key("BAD LINE"));
    }

    #[test]
    fn load_from_reads_full_config() {
        let dir = std::env::temp_dir().join(format!("kindled-test-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("config");
        fs::write(
            &path,
            "SERVER_URL=http://192.168.1.75:3000/\nAPI_TOKEN=tok\nAUTO_DOWNLOAD=0\n",
        )
        .unwrap();

        let config = Config::load_from(&path).unwrap();
        assert_eq!(config.server_url, "http://192.168.1.75:3000");
        assert_eq!(config.api_token, "tok");
        assert!(!config.auto_download);
        assert_eq!(config.poll_interval_secs, 300);

        fs::remove_dir_all(&dir).unwrap();
    }
}
