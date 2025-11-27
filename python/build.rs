use std::env;
use std::path::PathBuf;

fn main() {
    // Link to Codon/Sequre libs (built by ../build.sh) and set rpaths so the
    // bundled wheel can load the copies shipped alongside the extension.
    if let Some(repo_root) = repo_root() {
        let codon_lib = repo_root.join("codon/install/lib/codon");
        if codon_lib.exists() {
            println!("cargo:rustc-link-search=native={}", codon_lib.display());
        }
    }

    // Relative rpaths for the packaged wheel: place libs at syqure/lib/codon.
    println!("cargo:rustc-link-arg=-Wl,-rpath,@loader_path/lib/codon");
    println!("cargo:rustc-link-arg=-Wl,-rpath,$ORIGIN/lib/codon");
}

fn repo_root() -> Option<PathBuf> {
    let manifest = env::var("CARGO_MANIFEST_DIR").ok()?;
    std::path::Path::new(&manifest)
        .parent()
        .map(|p| p.to_path_buf())
}
