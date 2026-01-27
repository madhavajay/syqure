use std::collections::hash_map::DefaultHasher;
use std::fs;
use std::hash::{Hash, Hasher};
use std::path::PathBuf;

use anyhow::{anyhow, Result};
use tar::Archive;
use zstd::stream::read::Decoder;

#[cfg(not(feature = "runtime-bundle"))]
const BUNDLE_BYTES: &[u8] = include_bytes!(env!("SYQURE_BUNDLE_FILE"));

/// Ensure the bundled Codon/Sequre assets are unpacked locally and return their root path.
/// Extracts to ~/.cache/syqure/<bundle-name>/<hash>/lib/codon (or temp dir fallback).
/// The hash-based subdirectory allows multiple versions to coexist.
pub fn ensure_bundle() -> Result<PathBuf> {
    let bundle_bytes = load_bundle_bytes()?;
    let sig = bundle_signature(&bundle_bytes);

    let cache_dir =
        versioned_cache_dir(&sig).ok_or_else(|| anyhow!("cannot determine cache directory"))?;
    let target_dir = cache_dir.join("lib/codon");

    if !target_dir.exists() {
        fs::create_dir_all(&cache_dir)?;

        let cursor = std::io::Cursor::new(bundle_bytes);
        let mut decoder = Decoder::new(cursor)?;
        let mut archive = Archive::new(&mut decoder);
        archive.unpack(&cache_dir)?;
    }

    Ok(target_dir)
}

/// Returns the versioned cache directory: ~/.cache/syqure/<bundle-name>/<hash>/
fn versioned_cache_dir(hash: &str) -> Option<PathBuf> {
    if let Some(dir) = std::env::var_os("SYQURE_BUNDLE_CACHE") {
        // If user overrides, use their path directly (they manage versioning)
        return Some(PathBuf::from(dir));
    }
    let bundle_name = bundle_name();
    if let Some(home) = std::env::var_os("HOME") {
        return Some(
            PathBuf::from(home)
                .join(".cache")
                .join("syqure")
                .join(&bundle_name)
                .join(hash),
        );
    }
    Some(
        std::env::temp_dir()
            .join("syqure-cache")
            .join(&bundle_name)
            .join(hash),
    )
}

/// Returns the base cache directory (without hash) for rpath purposes.
pub fn base_cache_dir() -> Option<PathBuf> {
    let bundle_name = bundle_name();
    if let Some(home) = std::env::var_os("HOME") {
        return Some(
            PathBuf::from(home)
                .join(".cache")
                .join("syqure")
                .join(&bundle_name),
        );
    }
    Some(std::env::temp_dir().join("syqure-cache").join(&bundle_name))
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
        std::path::Path::new(env!("SYQURE_BUNDLE_FILE"))
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or("bundle")
            .to_string()
    }
}

fn load_bundle_bytes() -> Result<Vec<u8>> {
    #[cfg(feature = "runtime-bundle")]
    {
        let path = std::env::var("SYQURE_BUNDLE_FILE").map_err(|_| {
            anyhow!("SYQURE_BUNDLE_FILE must be set when runtime-bundle is enabled")
        })?;
        return fs::read(&path).map_err(|e| anyhow!("failed to read bundle {}: {}", path, e));
    }
    #[cfg(not(feature = "runtime-bundle"))]
    {
        Ok(BUNDLE_BYTES.to_vec())
    }
}

fn bundle_signature(bytes: &[u8]) -> String {
    let mut hasher = DefaultHasher::new();
    bytes.hash(&mut hasher);
    format!("{:x}-{}", hasher.finish(), bytes.len())
}
