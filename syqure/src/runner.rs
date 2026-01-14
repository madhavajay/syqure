use std::path::{Path, PathBuf};

use anyhow::{anyhow, Result};

use crate::bundle::ensure_bundle;
use crate::ffi::{sy_codon_build_exe, sy_codon_run, SyCompileOpts};

/// Options that control how syqure invokes Codon/Sequre.
#[derive(Debug, Clone)]
pub struct CompileOptions {
    pub codon_path: PathBuf,
    pub plugin: String,
    pub disable_opts: Vec<String>,
    pub release: bool,
    /// If false, only build (no run).
    pub run_after_build: bool,
    /// Extra program arguments to pass after compilation.
    pub program_args: Vec<String>,
    /// Additional libraries to link (rare).
    pub libs: Vec<String>,
    /// Extra linker flags (rare).
    pub linker_flags: String,
}

impl Default for CompileOptions {
    fn default() -> Self {
        Self {
            codon_path: default_codon_path(),
            plugin: "sequre".to_string(),
            disable_opts: vec!["core-pythonic-list-addition-opt".to_string()],
            release: false,
            run_after_build: true,
            program_args: Vec::new(),
            libs: Vec::new(),
            linker_flags: String::new(),
        }
    }
}

/// High-level facade for compiling/running Codon sources with Sequre.
pub struct Syqure {
    opts: CompileOptions,
}

impl Syqure {
    pub fn new(opts: CompileOptions) -> Self {
        Self { opts }
    }

    /// Compile the provided Codon file and optionally run it.
    /// Returns Ok(Some(path)) when only building, Ok(None) when run completed.
    pub fn compile_and_maybe_run(&self, source: impl AsRef<Path>) -> Result<Option<PathBuf>> {
        let source = source.as_ref();
        if !source.exists() {
            return Err(anyhow!("source file not found: {}", source.display()));
        }

        // Ensure Codon finds its stdlib and plugins by exporting CODON_PATH when missing.
        // Point CODON_PATH directly at the bundled stdlib (what Codon expects), and bundle plugins.
        let codon_root = ensure_bundle()?;
        let stdlib = codon_root.join("stdlib");
        std::env::set_var("CODON_PATH", &stdlib);
        if std::env::var_os("CODON_PLUGIN_PATH").is_none() {
            std::env::set_var("CODON_PLUGIN_PATH", codon_root.join("plugins"));
        }

        // Sequre's gmp module does dlopen("libgmp.so") which looks in hardcoded build paths.
        // Create symlinks so the bundled libgmp.so can be found at the expected location.
        ensure_libgmp_available(&codon_root);

        clean_sockets()?;

        let plugin = resolve_plugin_path(&codon_root, &self.opts.plugin);

        if self.opts.run_after_build {
            let result = sy_codon_run(
                &self.make_opts(source, /*standalone=*/ false, plugin.clone()),
                &self.opts.program_args,
            );
            if result.status != 0 {
                return Err(anyhow!("codon run failed: {}", result.error));
            }
            return Ok(None);
        }

        // Build only.
        let output = default_output_path(source);
        let result = sy_codon_build_exe(
            &self.make_opts(source, /*standalone=*/ true, plugin),
            output.to_str().unwrap_or_default(),
        );
        if result.status != 0 {
            return Err(anyhow!("codon build failed: {}", result.error));
        }
        Ok(Some(output))
    }

    fn make_opts(&self, source: &Path, standalone: bool, plugin: String) -> SyCompileOpts {
        SyCompileOpts {
            argv0: self.codon_bin().to_string_lossy().into_owned(),
            input: source.to_string_lossy().into_owned(),
            plugins: vec![plugin],
            disabled_opts: self.opts.disable_opts.clone(),
            libs: self.opts.libs.clone(),
            linker_flags: self.opts.linker_flags.clone(),
            release: self.opts.release,
            standalone,
            shared_lib: false,
        }
    }

    fn codon_bin(&self) -> PathBuf {
        self.opts.codon_path.join("bin/codon")
    }
}

fn default_output_path(source: &Path) -> PathBuf {
    let mut path = source.to_path_buf();
    if let Some(ext) = path.extension() {
        // Strip common Codon extensions.
        if ext == "codon" || ext == "py" || ext == "seq" {
            path.set_extension("");
        }
    }
    path
}

fn default_codon_path() -> PathBuf {
    if let Some(env_path) = std::env::var_os("CODON_PATH") {
        return PathBuf::from(env_path);
    }
    // Try to locate a bundled codon lib next to the executable (set by package step).
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            let bundled = dir.join("lib/codon");
            if bundled.exists() {
                return bundled;
            }
        }
    }
    PathBuf::from("codon/install")
}

fn clean_sockets() -> Result<()> {
    let walker = walkdir::WalkDir::new(".").into_iter();
    for entry in walker.filter_map(Result::ok) {
        let name = entry.file_name().to_string_lossy();
        if name.starts_with("sock.") {
            let _ = std::fs::remove_file(entry.path());
        }
    }
    Ok(())
}

fn resolve_plugin_path(codon_root: &Path, plugin: &str) -> String {
    let candidate = codon_root.join("plugins").join(plugin);
    if candidate.join("plugin.toml").exists() {
        return candidate.to_string_lossy().into_owned();
    }
    plugin.to_string()
}

fn ensure_libgmp_available(codon_root: &Path) {
    // The sequre plugin's gmp.codon calls dlopen("libgmp.so") which searches:
    // 1. Relative path "libgmp.so"
    // 2. Hardcoded build-time path like "<repo>/codon/install/lib/codon/libgmp.so"
    //
    // Since DYLD_LIBRARY_PATH doesn't work reliably on macOS (SIP strips it),
    // we create a symlink at the expected location pointing to the bundled lib.

    let bundled_gmp = codon_root.join("libgmp.so");
    if !bundled_gmp.exists() {
        return;
    }

    // Find the syqure repo root by looking for codon/install relative to current exe or cwd
    let candidates = [
        std::env::current_exe()
            .ok()
            .and_then(|p| p.parent().map(|d| d.to_path_buf()))
            .map(|d| d.join("../../codon/install/lib/codon")),
        std::env::current_dir()
            .ok()
            .map(|d| d.join("codon/install/lib/codon")),
        std::env::var_os("SYQURE_CODON_INSTALL")
            .map(|p| PathBuf::from(p).join("lib/codon")),
    ];

    for candidate in candidates.into_iter().flatten() {
        let target_dir = candidate;
        let target_gmp = target_dir.join("libgmp.so");

        // If the directory exists but libgmp.so doesn't, create symlink
        if target_dir.exists() && !target_gmp.exists() {
            if let Err(_) = std::os::unix::fs::symlink(&bundled_gmp, &target_gmp) {
                // Symlink failed, try copy as fallback
                let _ = std::fs::copy(&bundled_gmp, &target_gmp);
            }
            // Also handle .dylib for macOS
            let bundled_dylib = codon_root.join("libgmp.dylib");
            let target_dylib = target_dir.join("libgmp.dylib");
            if bundled_dylib.exists() && !target_dylib.exists() {
                let _ = std::os::unix::fs::symlink(&bundled_dylib, &target_dylib);
            }
            break;
        }
    }
}
