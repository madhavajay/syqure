use std::fs;
use std::path::PathBuf;

use anyhow::{anyhow, Result};
use tar::Archive;
use zstd::stream::read::Decoder;

#[cfg(not(feature = "runtime-bundle"))]
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

        let bundle_bytes = load_bundle_bytes()?;
        let cursor = std::io::Cursor::new(bundle_bytes);
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
    let bundle_name = bundle_name();
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

fn bundle_name() -> String {
    #[cfg(feature = "runtime-bundle")]
    {
        return std::env::var("SYQURE_BUNDLE_FILE")
            .ok()
            .and_then(|p| {
                std::path::Path::new(&p)
                    .file_name()
                    .and_then(|s| s.to_str())
                    .map(|s| s.to_string())
            })
            .unwrap_or_else(|| "bundle".to_string());
    }
    #[cfg(not(feature = "runtime-bundle"))]
    {
        return std::path::Path::new(env!("SYQURE_BUNDLE_FILE"))
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or("bundle")
            .to_string();
    }
}

fn load_bundle_bytes() -> Result<Vec<u8>> {
    #[cfg(feature = "runtime-bundle")]
    {
        let path = std::env::var("SYQURE_BUNDLE_FILE")
            .map_err(|_| anyhow!("SYQURE_BUNDLE_FILE must be set when runtime-bundle is enabled"))?;
        return fs::read(&path)
            .map_err(|e| anyhow!("failed to read bundle {}: {}", path, e));
    }
    #[cfg(not(feature = "runtime-bundle"))]
    {
        return Ok(BUNDLE_BYTES.to_vec());
    }
}
