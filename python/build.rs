use std::env;
use std::path::PathBuf;

fn main() {
    // Add rpath to Codon libraries for the Python extension
    if let Some(repo_root) = repo_root() {
        let codon_lib = repo_root.join("codon/install/lib/codon");
        if codon_lib.exists() {
            println!("cargo:rustc-link-arg=-Wl,-rpath,{}", codon_lib.display());

            // Also add @loader_path relative rpath for macOS
            println!(
                "cargo:rustc-link-arg=-Wl,-rpath,@loader_path/../../../codon/install/lib/codon"
            );
        }
    }
}

fn repo_root() -> Option<PathBuf> {
    let manifest = env::var("CARGO_MANIFEST_DIR").ok()?;
    std::path::Path::new(&manifest)
        .parent()
        .map(|p| p.to_path_buf())
}
