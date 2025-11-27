use std::env;
fn main() {
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
        .compile("syqure-ffi");

    // Re-run build script if any of these files change.
    println!("cargo:rerun-if-changed=src/ffi.rs");
    println!("cargo:rerun-if-changed=src/ffi/bridge.cc");
    println!("cargo:rerun-if-changed=src/ffi/bridge.h");
    println!("cargo:rerun-if-env-changed=SYQURE_CPP_INCLUDE");
    println!("cargo:rerun-if-env-changed=SYQURE_CPP_LIB_DIRS");
}

fn repo_root() -> Option<std::path::PathBuf> {
    let manifest = env::var("CARGO_MANIFEST_DIR").ok()?;
    std::path::Path::new(&manifest)
        .parent()
        .map(|p| p.to_path_buf())
}
