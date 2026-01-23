use std::collections::hash_map::DefaultHasher;
use std::env;
use std::hash::{Hash, Hasher};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

fn main() {
    let runtime_bundle = env::var("CARGO_FEATURE_RUNTIME_BUNDLE").is_ok();
    let bundle_file = if !runtime_bundle {
        Some(set_bundle_env())
    } else {
        println!("cargo:rerun-if-env-changed=SYQURE_BUNDLE_FILE");
        None
    };
    let bundle_root = bundle_file.and_then(|f| bundle_root(&f));

    // Build the C++ bridge. We keep it minimal for now and allow downstream
    // overrides for include/library paths via env vars.
    let mut bridge = cxx_build::bridge("src/ffi.rs");

    // Allow callers to point at Codon/Sequre headers if needed later.
    if let Ok(include) = env::var("SYQURE_CPP_INCLUDE") {
        bridge.include(include);
    }

    // Add homebrew include paths for fmt and other dependencies (macOS).
    if cfg!(target_os = "macos") {
        for prefix in &["/opt/homebrew", "/usr/local"] {
            let inc = Path::new(prefix).join("include");
            if inc.exists() {
                bridge.include(&inc);
            }
        }
    }
    // Prefer headers from the prebuilt bundle if available.
    if let Some(root) = &bundle_root {
        let bundle_inc = root.join("include");
        if bundle_inc.exists() {
            bridge.include(&bundle_inc);
        }
    }
    // Fallback to repo-installed headers only when no bundle is available.
    if bundle_root.is_none() {
        if let Some(repo_root) = repo_root() {
            let codon_src = repo_root.join("codon");
            if codon_src.exists() {
                bridge.include(&codon_src);
            }
            let codon_install_inc = repo_root.join("codon/install/include");
            if codon_install_inc.exists() {
                bridge.include(&codon_install_inc);
            }
            let llvm_install_inc = repo_root.join("codon/llvm-project/install/include");
            if llvm_install_inc.exists() {
                bridge.include(&llvm_install_inc);
            }
        }
    }
    if let Ok(llvm_inc) = env::var("SYQURE_LLVM_INCLUDE") {
        bridge.include(llvm_inc);
    } else if let Some(llvm_inc) = detect_llvm_include() {
        bridge.include(llvm_inc);
    }
    // Local bridge headers
    bridge.include("src");
    bridge.include("src/ffi");

    // Emit any custom linker search paths (e.g., Codon/Sequre libs).
    if let Ok(lib_dirs) = env::var("SYQURE_CPP_LIB_DIRS") {
        for dir in lib_dirs.split(':').filter(|s| !s.is_empty()) {
            println!("cargo:rustc-link-search=native={}", dir);
            println!("cargo:rustc-link-arg=-Wl,-rpath,{}", dir);
        }
    } else {
        let mut linked = false;
        if let Some(root) = &bundle_root {
            let bundle_lib = root.join("lib/codon");
            if bundle_lib.exists() {
                let path = bundle_lib.display();
                println!("cargo:rustc-link-search=native={}", path);
                println!("cargo:rustc-link-arg=-Wl,-rpath,{}", path);
                linked = true;
            }
            // Only link against bundled LLVM when explicitly requested.
            let bundle_llvm = root.join("lib/llvm");
            if bundle_llvm.exists()
                && env::var("SYQURE_LINK_LLVM_SHARED")
                    .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
                    .unwrap_or(false)
            {
                let path = bundle_llvm.display();
                println!("cargo:rustc-link-search=native={}", path);
                println!("cargo:rustc-link-arg=-Wl,-rpath,{}", path);
                if let Some(llvm_lib) = find_llvm_lib(&bundle_llvm) {
                    println!("cargo:rustc-link-lib=dylib={}", llvm_lib);
                }
            }
        }
        if !linked {
            if let Some(repo_root) = repo_root() {
                let default_lib = repo_root.join("codon/install/lib/codon");
                if default_lib.exists() {
                    let path = default_lib.display();
                    println!("cargo:rustc-link-search=native={}", path);
                    println!("cargo:rustc-link-arg=-Wl,-rpath,{}", path);
                }
            }
        }
    }

    // Link against Codon runtime + compiler; expect the caller's search path to be set.
    println!("cargo:rustc-link-lib=dylib=codonrt");
    println!("cargo:rustc-link-lib=dylib=codonc");
    // Link LLVM only when explicitly requested to avoid duplicate LLVM copies.
    if env::var("SYQURE_LINK_LLVM_SHARED")
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false)
    {
        // Shared LLVM already linked above when requested.
    } else if env::var("SYQURE_LINK_LLVM_STATIC")
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false)
    {
        if let Some(llvm_config) = llvm_config_path(&bundle_root) {
            link_llvm_static(&llvm_config);
        }
    }

    bridge
        .file("src/ffi/bridge.cc")
        .flag_if_supported("-std=c++17")
        // Silence benign warnings from Codon/LLVM/fmt headers.
        .flag_if_supported("-Wno-unused-parameter")
        .flag_if_supported("-Wno-sign-compare")
        .flag_if_supported("-Wno-unused-command-line-argument")
        .flag_if_supported("-Wno-unknown-pragmas")
        .flag_if_supported("-Wno-comment")
        .flag_if_supported("-Wno-tautological-compare")
        .flag_if_supported("-Wno-redundant-move")
        .flag_if_supported("-Wno-dangling-reference")
        // Make rpaths relative so we can bundle Codon libs next to the binary.
        .flag_if_supported(if cfg!(target_os = "macos") {
            "-Wl,-rpath,@loader_path"
        } else {
            "-Wl,-rpath,$ORIGIN"
        })
        .flag_if_supported(if cfg!(target_os = "macos") {
            "-Wl,-rpath,@loader_path/lib/codon"
        } else {
            "-Wl,-rpath,$ORIGIN/lib/codon"
        });

    // For self-contained binaries: add rpath to the expected cache extraction path.
    // This allows the single binary to find libs after extracting its embedded bundle.
    if !runtime_bundle {
        if let Some(cache_rpath) = compute_cache_rpath() {
            bridge.flag_if_supported(&cache_rpath);
        }
    }

    bridge.compile("syqure-ffi");

    // Expose TARGET for runtime info
    if let Ok(target) = env::var("TARGET") {
        println!("cargo:rustc-env=TARGET={}", target);
    }

    // Re-run build script if any of these files change.
    println!("cargo:rerun-if-changed=src/ffi.rs");
    println!("cargo:rerun-if-changed=src/ffi/bridge.cc");
    println!("cargo:rerun-if-changed=src/ffi/bridge.h");
    println!("cargo:rerun-if-env-changed=SYQURE_CPP_INCLUDE");
    println!("cargo:rerun-if-env-changed=SYQURE_CPP_LIB_DIRS");
    println!("cargo:rerun-if-env-changed=SYQURE_BUNDLE_FILE");
    println!("cargo:rerun-if-env-changed=SYQURE_LINK_LLVM_SHARED");
    println!("cargo:rerun-if-env-changed=SYQURE_LINK_LLVM_STATIC");
    println!("cargo:rerun-if-env-changed=SYQURE_LLVM_CONFIG");
}

fn repo_root() -> Option<std::path::PathBuf> {
    let manifest = env::var("CARGO_MANIFEST_DIR").ok()?;
    std::path::Path::new(&manifest)
        .parent()
        .map(|p| p.to_path_buf())
}

fn bundle_root_from_bin(root: &Path, triple: &str) -> Option<PathBuf> {
    let platform = if triple.contains("apple-darwin") {
        if triple.starts_with("aarch64") {
            Some("macos-arm64")
        } else if triple.starts_with("x86_64") {
            Some("macos-x86_64")
        } else {
            None
        }
    } else if triple.contains("linux") {
        if triple.contains("x86_64") {
            Some("linux-x86")
        } else if triple.contains("aarch64") {
            Some("linux-arm64")
        } else {
            None
        }
    } else {
        None
    };

    platform.and_then(|p| {
        let candidate = root.join("bin").join(p).join("codon");
        if candidate.exists() {
            Some(candidate)
        } else {
            None
        }
    })
}

fn detect_llvm_include() -> Option<PathBuf> {
    let candidates = [
        "/opt/homebrew/opt/llvm@17/include",
        "/opt/homebrew/opt/llvm/include",
        "/usr/local/opt/llvm@17/include",
        "/usr/local/opt/llvm/include",
    ];
    for candidate in candidates {
        let path = Path::new(candidate);
        if path.join("llvm/Support/Error.h").exists() {
            return Some(path.to_path_buf());
        }
    }

    for bin in ["llvm-config-17", "llvm-config"] {
        if let Ok(out) = Command::new(bin).arg("--includedir").output() {
            if out.status.success() {
                let inc = String::from_utf8_lossy(&out.stdout).trim().to_string();
                if !inc.is_empty() {
                    let path = PathBuf::from(&inc);
                    if path.join("llvm/Support/Error.h").exists() {
                        return Some(path);
                    }
                }
            }
        }
    }
    None
}

fn set_bundle_env() -> PathBuf {
    if let Some(val) = env::var_os("SYQURE_BUNDLE_FILE") {
        let path = PathBuf::from(&val);
        println!(
            "cargo:rustc-env=SYQURE_BUNDLE_FILE={}",
            val.to_string_lossy()
        );
        println!("cargo:rerun-if-changed={}", val.to_string_lossy());
        return path;
    }
    if let Some(root) = repo_root() {
        if let Ok(triple) = env::var("TARGET") {
            let candidate = root
                .join("syqure/bundles")
                .join(format!("{}.tar.zst", triple));
            if candidate.exists() {
                println!("cargo:rustc-env=SYQURE_BUNDLE_FILE={}", candidate.display());
                println!("cargo:rerun-if-changed={}", candidate.display());
                return candidate;
            }
            if let Some(bundle_root) = bundle_root_from_bin(&root, &triple) {
                let out = Path::new(&env::var("OUT_DIR").unwrap())
                    .join(format!("bundle-bin-{}.tar.zst", triple));
                let _ = std::fs::remove_file(&out);
                let mut tar = Command::new("tar")
                    .arg("-C")
                    .arg(&bundle_root)
                    .arg("-ch")
                    .arg(".")
                    .stdout(Stdio::piped())
                    .spawn()
                    .expect("failed to spawn tar for bundle");
                let status = Command::new("zstd")
                    .arg("-19")
                    .arg("-o")
                    .arg(&out)
                    .stdin(Stdio::from(tar.stdout.take().expect("missing tar stdout pipe")))
                    .status()
                    .expect("failed to run zstd for bundle");
                let _ = tar.wait();
                if status.success() {
                    println!("cargo:rustc-env=SYQURE_BUNDLE_FILE={}", out.display());
                    return out;
                }
            }
            // Fallback: if we have a local codon install, package it into OUT_DIR.
            let codon_lib = root.join("codon/install/lib/codon");
            if codon_lib.exists() {
                let out = Path::new(&env::var("OUT_DIR").unwrap())
                    .join(format!("bundle-{}.tar.zst", triple));
                let _ = std::fs::remove_file(&out);
                let status = std::process::Command::new("tar")
                    .arg("-C")
                    .arg(&codon_lib)
                    .arg("-c")
                    .arg(".")
                    .stdout(std::fs::File::create(&out).unwrap())
                    .status()
                    .unwrap();
                if status.success() {
                    println!("cargo:rustc-env=SYQURE_BUNDLE_FILE={}", out.display());
                    return out;
                }
            }
        }
    }
    // Panic early so cargo install surfaces the missing bundle.
    panic!(
        "Missing Codon/Sequre bundle. Set SYQURE_BUNDLE_FILE to a tar.zst bundle for your target."
    );
}

fn bundle_root(bundle: &Path) -> Option<PathBuf> {
    let out_dir = env::var("OUT_DIR").ok()?;
    let extract_dir = Path::new(&out_dir).join("bundle");

    if extract_dir.exists() {
        let _ = std::fs::remove_dir_all(&extract_dir);
    }
    std::fs::create_dir_all(&extract_dir).ok()?;

    // Extract .tar.zst bundle using zstd | tar to avoid relying on tar -I support.
    let mut zstd = Command::new("zstd")
        .arg("-dc")
        .arg(bundle)
        .stdout(Stdio::piped())
        .spawn()
        .expect("failed to spawn zstd for bundle");
    let tar_status = Command::new("tar")
        .arg("-xf")
        .arg("-")
        .arg("-C")
        .arg(&extract_dir)
        .stdin(Stdio::from(
            zstd.stdout.take().expect("missing zstd stdout pipe"),
        ))
        .status()
        .expect("failed to run tar to extract bundle");
    let _ = zstd.wait();
    if !tar_status.success() {
        panic!(
            "failed to extract bundle {} into {}",
            bundle.display(),
            extract_dir.display()
        );
    }

    // Normalize dylib install names to use bundled LLVM runtimes.
    if let Err(e) = rewrite_install_names(&extract_dir) {
        eprintln!("warning: failed to rewrite install names: {}", e);
    }

    Some(extract_dir)
}

fn find_llvm_lib(dir: &Path) -> Option<String> {
    let mut entries = std::fs::read_dir(dir).ok()?;
    while let Some(Ok(entry)) = entries.next() {
        let path = entry.path();
        let name = path.file_name()?.to_string_lossy();
        if name == "libLLVM.so" || name == "libLLVM.dylib" {
            return Some("LLVM".to_string());
        }
        if let Some(rest) = name.strip_prefix("libLLVM-") {
            if let Some(lib) = rest.strip_suffix(".so") {
                return Some(format!("LLVM-{}", lib));
            }
        }
        if let Some(rest) = name.strip_prefix("libLLVM-") {
            if let Some(lib) = rest.strip_suffix(".dylib") {
                return Some(format!("LLVM-{}", lib));
            }
        }
    }
    None
}

fn rewrite_install_names(bundle_root: &Path) -> Result<(), String> {
    let codon_lib = bundle_root.join("lib/codon");
    let llvm_lib = bundle_root.join("lib/llvm");
    if !codon_lib.exists() || !llvm_lib.exists() {
        return Ok(());
    }
    let replacements = [
        (
            "/opt/homebrew/opt/llvm/lib/c++/libc++abi.1.dylib",
            "@loader_path/../llvm/libc++abi.1.dylib",
        ),
        (
            "/opt/homebrew/opt/llvm/lib/c++/libc++.1.dylib",
            "@loader_path/../llvm/libc++.1.dylib",
        ),
        (
            "/opt/homebrew/opt/llvm/lib/libunwind.1.dylib",
            "@loader_path/../llvm/libunwind.1.dylib",
        ),
        (
            "@rpath/libunwind.1.dylib",
            "@loader_path/../llvm/libunwind.1.dylib",
        ),
        (
            "/usr/lib/libunwind.1.dylib",
            "@loader_path/../llvm/libunwind.1.dylib",
        ),
        (
            "/usr/lib/libunwind.dylib",
            "@loader_path/../llvm/libunwind.1.dylib",
        ),
        (
            "/usr/lib/system/libunwind.dylib",
            "@loader_path/../llvm/libunwind.1.dylib",
        ),
    ];
    let targets = [
        codon_lib.join("libcodonrt.dylib"),
        codon_lib.join("libcodonc.dylib"),
        llvm_lib.join("libc++.1.0.dylib"),
        llvm_lib.join("libc++abi.1.0.dylib"),
    ];
    for path in targets {
        if !path.exists() {
            continue;
        }
        for (old, newv) in &replacements {
            let status = Command::new("install_name_tool")
                .arg("-change")
                .arg(old)
                .arg(newv)
                .arg(&path)
                .status()
                .map_err(|e| format!("install_name_tool failed: {}", e))?;
            if !status.success() {
                return Err(format!(
                    "install_name_tool returned {} while patching {}",
                    status,
                    path.display()
                ));
            }
        }
    }
    Ok(())
}

fn llvm_config_path(bundle_root: &Option<PathBuf>) -> Option<PathBuf> {
    if let Ok(path) = env::var("SYQURE_LLVM_CONFIG") {
        let path = PathBuf::from(path);
        if path.exists() {
            return Some(path);
        }
    }
    if let Some(root) = bundle_root {
        let candidate = root.join("bin/llvm-config");
        if candidate.exists() {
            return Some(candidate);
        }
    }
    if let Some(repo_root) = repo_root() {
        let candidate = repo_root.join("codon/llvm-project/install/bin/llvm-config");
        if candidate.exists() {
            return Some(candidate);
        }
    }
    if Command::new("llvm-config")
        .arg("--version")
        .output()
        .is_ok()
    {
        return Some(PathBuf::from("llvm-config"));
    }
    None
}

fn link_llvm_static(llvm_config: &Path) {
    let libdir = run_llvm_config_raw(llvm_config, &["--libdir"]).map(PathBuf::from);
    if let Some(dir) = &libdir {
        println!("cargo:rustc-link-search=native={}", dir.display());
    }
    for lib in run_llvm_config(llvm_config, &["--libs", "--link-static"]) {
        if let Some(dir) = &libdir {
            let candidate = dir.join(format!("lib{}.a", lib));
            if !candidate.exists() {
                continue;
            }
        }
        println!("cargo:rustc-link-lib=static={}", lib);
    }
    for lib in run_llvm_config(llvm_config, &["--system-libs", "--link-static"]) {
        println!("cargo:rustc-link-lib=dylib={}", lib);
    }
}

fn run_llvm_config(llvm_config: &Path, args: &[&str]) -> Vec<String> {
    let stdout = run_llvm_config_raw(llvm_config, args).unwrap_or_default();
    stdout
        .split_whitespace()
        .filter_map(|tok| {
            if let Some(rest) = tok.strip_prefix("-l") {
                return Some(rest.to_string());
            }
            if let Some(rest) = tok.strip_prefix("-L") {
                println!("cargo:rustc-link-search=native={}", rest);
                return None;
            }
            None
        })
        .collect()
}

fn run_llvm_config_raw(llvm_config: &Path, args: &[&str]) -> Option<String> {
    let output = Command::new(llvm_config)
        .args(args)
        .output()
        .expect("failed to run llvm-config");
    if !output.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

/// Compute and emit the expected cache extraction path for self-contained binaries.
/// This path is embedded as an env var for runtime use (e.g., setting LD_LIBRARY_PATH).
fn compute_cache_rpath() -> Option<String> {
    let bundle_path = env::var("SYQURE_BUNDLE_FILE").ok()?;
    let bundle_bytes = std::fs::read(&bundle_path).ok()?;

    // Compute hash (must match bundle.rs algorithm)
    let mut hasher = DefaultHasher::new();
    bundle_bytes.hash(&mut hasher);
    let hash = format!("{:x}-{}", hasher.finish(), bundle_bytes.len());

    // Get bundle name from path
    let bundle_name = Path::new(&bundle_path)
        .file_name()
        .and_then(|s| s.to_str())?
        .to_string();

    // Emit the cache lib path for runtime use
    // Note: rpath doesn't support $HOME expansion, so this is for informational/wrapper use
    println!(
        "cargo:rustc-env=SYQURE_CACHE_LIB_PATH={}/{}/lib/codon",
        bundle_name, hash
    );

    // Cannot add to rpath (no $HOME expansion), return None
    None
}
