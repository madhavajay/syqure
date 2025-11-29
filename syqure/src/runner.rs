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
        if std::env::var_os("CODON_PATH").is_none() {
            // Point CODON_PATH at the bundled Codon root so stdlib/plugins resolve correctly.
            let codon_root = ensure_bundle()?;
            std::env::set_var("CODON_PATH", &codon_root);
            std::env::set_var("CODON_STDLIB", codon_root.join("stdlib"));
            if std::env::var_os("CODON_PLUGIN_PATH").is_none() {
                std::env::set_var("CODON_PLUGIN_PATH", codon_root.join("plugins"));
            }
        }

        clean_sockets()?;

        if self.opts.run_after_build {
            let result = sy_codon_run(
                &self.make_opts(source, /*standalone=*/ false),
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
            &self.make_opts(source, /*standalone=*/ true),
            output.to_str().unwrap_or_default(),
        );
        if result.status != 0 {
            return Err(anyhow!("codon build failed: {}", result.error));
        }
        Ok(Some(output))
    }

    fn make_opts(&self, source: &Path, standalone: bool) -> SyCompileOpts {
        SyCompileOpts {
            argv0: self.codon_bin().to_string_lossy().into_owned(),
            input: source.to_string_lossy().into_owned(),
            plugins: vec![self.opts.plugin.clone()],
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
