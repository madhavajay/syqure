use std::env;
use std::fs;
use std::path::PathBuf;
use std::process::Command;

fn main() {
    // Detect and unpack the bundle for the Python wheel
    set_bundle_and_unpack();

    // Link to Codon/Sequre libs (built by ../build.sh) and set rpaths so the
    // bundled wheel can load the copies shipped alongside the extension.
    if let Some(repo_root) = repo_root() {
        let codon_lib = repo_root.join("codon/install/lib/codon");
        if codon_lib.exists() {
            println!("cargo:rustc-link-search=native={}", codon_lib.display());
        }
    }

    // Relative rpaths for the packaged wheel: place libs at syqure/lib/codon.
    match env::var("CARGO_CFG_TARGET_OS").as_deref() {
        Ok("macos") => {
            println!("cargo:rustc-link-arg=-Wl,-rpath,@loader_path/lib/codon");
        }
        _ => {
            println!("cargo:rustc-link-arg=-Wl,-rpath,$ORIGIN/lib/codon");
        }
    }

    // Re-run if bundle changes
    println!("cargo:rerun-if-env-changed=SYQURE_BUNDLE_FILE");
}

fn repo_root() -> Option<PathBuf> {
    let manifest = env::var("CARGO_MANIFEST_DIR").ok()?;
    std::path::Path::new(&manifest)
        .parent()
        .map(|p| p.to_path_buf())
}

fn set_bundle_and_unpack() {
    if let Ok(val) = env::var("SYQURE_SKIP_BUNDLE_UNPACK") {
        if val == "1" || val.eq_ignore_ascii_case("true") {
            println!("cargo:warning=Skipping bundle unpack (SYQURE_SKIP_BUNDLE_UNPACK=1)");
            return;
        }
    }

    let bundle_file = if let Some(val) = env::var_os("SYQURE_BUNDLE_FILE") {
        PathBuf::from(val)
    } else if let Some(root) = repo_root() {
        if let Ok(triple) = env::var("TARGET") {
            let candidate = root
                .join("syqure/bundles")
                .join(format!("{}.tar.zst", triple));
            if candidate.exists() {
                candidate
            } else {
                eprintln!(
                    "Warning: No bundle found at {}. Run build_libs.sh first.",
                    candidate.display()
                );
                return;
            }
        } else {
            return;
        }
    } else {
        return;
    };

    // Unpack the bundle into python/syqure/lib/ so maturin includes it in the wheel
    if let Some(manifest_dir) = env::var_os("CARGO_MANIFEST_DIR") {
        let python_dir = PathBuf::from(manifest_dir);
        let lib_dir = python_dir.join("syqure").join("lib");

        // Create lib directory
        if let Err(e) = fs::create_dir_all(&lib_dir) {
            eprintln!("Warning: Failed to create {}: {}", lib_dir.display(), e);
            return;
        }

        // Unpack bundle using tar + zstd
        println!(
            "cargo:warning=Unpacking bundle {} to {}",
            bundle_file.display(),
            lib_dir.display()
        );

        let status = Command::new("sh")
            .arg("-c")
            .arg(format!(
                "zstd -d -c '{}' | tar -x -C '{}'",
                bundle_file.display(),
                lib_dir.display()
            ))
            .status();

        match status {
            Ok(s) if s.success() => {
                println!(
                    "cargo:warning=Successfully unpacked bundle to {}",
                    lib_dir.display()
                );
            }
            Ok(s) => {
                eprintln!(
                    "Warning: Failed to unpack bundle (exit code: {:?})",
                    s.code()
                );
            }
            Err(e) => {
                eprintln!("Warning: Failed to run tar/zstd: {}", e);
            }
        }
    }
}
