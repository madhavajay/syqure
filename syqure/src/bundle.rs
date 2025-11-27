use std::fs;
use std::path::PathBuf;

use anyhow::{anyhow, Result};
use tar::Archive;
use zstd::stream::read::Decoder;

// Bundle bytes are provided at compile time by build.rs via SYQURE_BUNDLE_FILE.
const BUNDLE_BYTES: &[u8] = include_bytes!(env!("SYQURE_BUNDLE_FILE"));

/// Ensure the bundled Codon/Sequre assets are unpacked locally and return their root path.
/// Extracts to ~/.cache/syqure/<bundle-name>/lib/codon (or temp dir fallback).
pub fn ensure_bundle() -> Result<PathBuf> {
    let cache_dir =
        default_cache_dir().ok_or_else(|| anyhow!("cannot determine cache directory"))?;
    let target_dir = cache_dir.join("lib/codon");

    if !target_dir.exists() {
        if target_dir.exists() {
            fs::remove_dir_all(&target_dir).ok();
        }
        fs::create_dir_all(&cache_dir)?;

        let cursor = std::io::Cursor::new(BUNDLE_BYTES);
        let mut decoder = Decoder::new(cursor)?;
        let mut archive = Archive::new(&mut decoder);
        archive.unpack(&cache_dir)?;
    }

    Ok(target_dir)
}

fn default_cache_dir() -> Option<PathBuf> {
    if let Some(dir) = std::env::var_os("SYQURE_BUNDLE_CACHE") {
        return Some(PathBuf::from(dir));
    }
    let bundle_name = std::path::Path::new(env!("SYQURE_BUNDLE_FILE"))
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("bundle");
    if let Some(home) = std::env::var_os("HOME") {
        return Some(
            PathBuf::from(home)
                .join(".cache")
                .join("syqure")
                .join(bundle_name),
        );
    }
    Some(std::env::temp_dir().join("syqure-cache").join(bundle_name))
}
