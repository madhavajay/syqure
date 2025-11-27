use std::env;
use std::path::{Path, PathBuf};
use std::process::Command;

fn main() {
    set_bundle_env();
    let bundle_root = bundle_root();

    // Build the C++ bridge. We keep it minimal for now and allow downstream
    // overrides for include/library paths via env vars.
    let mut bridge = cxx_build::bridge("src/ffi.rs");

    // Allow callers to point at Codon/Sequre headers if needed later.
    if let Ok(include) = env::var("SYQURE_CPP_INCLUDE") {
        bridge.include(include);
    } else if let Some(repo_root) = repo_root() {
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
    // If we only have a prebuilt bundle, use its headers.
    if let Some(root) = &bundle_root {
        let bundle_inc = root.join("include");
        if bundle_inc.exists() {
            bridge.include(&bundle_inc);
        }
    }
    if let Ok(llvm_inc) = env::var("SYQURE_LLVM_INCLUDE") {
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
    } else if let Some(repo_root) = repo_root() {
        let default_lib = repo_root.join("codon/install/lib/codon");
        if default_lib.exists() {
            let path = default_lib.display();
            println!("cargo:rustc-link-search=native={}", path);
            println!("cargo:rustc-link-arg=-Wl,-rpath,{}", path);
        }
    } else if let Some(root) = &bundle_root {
        let bundle_lib = root.join("lib/codon");
        if bundle_lib.exists() {
            let path = bundle_lib.display();
            println!("cargo:rustc-link-search=native={}", path);
            println!("cargo:rustc-link-arg=-Wl,-rpath,{}", path);
        }
    }

    // Link against Codon runtime + compiler; expect the caller's search path to be set.
    println!("cargo:rustc-link-lib=dylib=codonrt");
    println!("cargo:rustc-link-lib=dylib=codonc");

    bridge
        .file("src/ffi/bridge.cc")
        .flag_if_supported("-std=c++17")
        // Silence benign unused-parameter warnings coming from Codon's headers.
        .flag_if_supported("-Wno-unused-parameter")
        // Codon headers also trip -Wsign-compare; suppress for cleaner logs.
        .flag_if_supported("-Wno-sign-compare")
        .flag_if_supported("-Wno-unused-command-line-argument")
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
        })
        .compile("syqure-ffi");

    // Re-run build script if any of these files change.
    println!("cargo:rerun-if-changed=src/ffi.rs");
    println!("cargo:rerun-if-changed=src/ffi/bridge.cc");
    println!("cargo:rerun-if-changed=src/ffi/bridge.h");
    println!("cargo:rerun-if-env-changed=SYQURE_CPP_INCLUDE");
    println!("cargo:rerun-if-env-changed=SYQURE_CPP_LIB_DIRS");
    println!("cargo:rerun-if-env-changed=SYQURE_BUNDLE_FILE");
}

fn repo_root() -> Option<std::path::PathBuf> {
    let manifest = env::var("CARGO_MANIFEST_DIR").ok()?;
    std::path::Path::new(&manifest)
        .parent()
        .map(|p| p.to_path_buf())
}

fn set_bundle_env() {
    if let Some(val) = env::var_os("SYQURE_BUNDLE_FILE") {
        println!(
            "cargo:rustc-env=SYQURE_BUNDLE_FILE={}",
            val.to_string_lossy()
        );
        return;
    }
    if let Some(root) = repo_root() {
        if let Ok(triple) = env::var("TARGET") {
            let candidate = root
                .join("syqure/bundles")
                .join(format!("{}.tar.zst", triple));
            if candidate.exists() {
                println!("cargo:rustc-env=SYQURE_BUNDLE_FILE={}", candidate.display());
                return;
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
                    return;
                }
            }
        }
    }
    // Panic early so cargo install surfaces the missing bundle.
    panic!(
        "Missing Codon/Sequre bundle. Set SYQURE_BUNDLE_FILE to a tar.zst bundle for your target."
    );
}

fn bundle_root() -> Option<PathBuf> {
    let bundle = env::var("SYQURE_BUNDLE_FILE").ok()?;
    let out_dir = env::var("OUT_DIR").ok()?;
    let extract_dir = Path::new(&out_dir).join("bundle");

    if extract_dir.exists() {
        let _ = std::fs::remove_dir_all(&extract_dir);
    }
    std::fs::create_dir_all(&extract_dir).ok()?;

    let status = Command::new("tar")
        .arg("-xf")
        .arg(&bundle)
        .arg("-C")
        .arg(&extract_dir)
        .status()
        .expect("failed to run tar to extract SYQURE_BUNDLE_FILE");
    if !status.success() {
        panic!(
            "failed to extract bundle {} into {}",
            bundle,
            extract_dir.display()
        );
    }

    Some(extract_dir)
}
