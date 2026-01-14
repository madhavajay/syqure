use std::path::Path;
use anyhow::Result;
use regex::Regex;
use serde::Serialize;

#[derive(Debug, Serialize)]
pub struct TypeUsage {
    pub sharetensor: bool,
    pub ciphertensor: bool,
    pub mpu: bool,
    pub mpp: bool,
    pub mpa: bool,
}

#[derive(Debug, Serialize)]
pub struct Operations {
    pub matmul: usize,
    pub encrypt: usize,
    pub decrypt: usize,
}

#[derive(Debug, Serialize)]
pub struct RuntimeInfo {
    pub needs_mhe: bool,
    pub can_skip_mhe: bool,
    pub uses_local: bool,
}

#[derive(Debug, Serialize)]
pub struct Estimate {
    pub jit_seconds: f64,
    pub mhe_seconds: f64,
    pub mpc_seconds: f64,
    pub ops_seconds: f64,
    pub total_seconds: f64,
}

#[derive(Debug, Serialize)]
pub struct Analysis {
    pub file: String,
    pub path: String,
    pub types: TypeUsage,
    pub operations: Operations,
    pub runtime: RuntimeInfo,
    pub estimate: Estimate,
}

pub fn analyze_file(path: &Path) -> Result<Analysis> {
    let source = std::fs::read_to_string(path)?;
    analyze_source(path, &source)
}

pub fn analyze_source(path: &Path, source: &str) -> Result<Analysis> {
    // Type detection patterns
    let has_sharetensor = Regex::new(r"\bSharetensor\b")?.is_match(source);
    let has_ciphertensor = Regex::new(r"\bCiphertensor\b")?.is_match(source);
    let has_mpu = Regex::new(r"\bMPU\b")?.is_match(source);
    let has_mpp = Regex::new(r"\bMPP\b")?.is_match(source);
    let has_mpa = Regex::new(r"\bMPA\b")?.is_match(source);
    let uses_mhe = Regex::new(r"mpc\.mhe\b")?.is_match(source);
    let uses_local = Regex::new(r"@local\b")?.is_match(source);

    // Operation counting
    let matmul_count = Regex::new(r"@")?.find_iter(source).count();
    let encrypt_count = Regex::new(r"\.encrypt\s*\(")?.find_iter(source).count();
    let decrypt_count = Regex::new(r"\.decrypt\s*\(|\.reveal\s*\(")?.find_iter(source).count();

    // Compute estimates
    let needs_mhe = has_ciphertensor || has_mpu || has_mpp || has_mpa || uses_mhe;
    let can_skip_mhe = !needs_mhe;

    let jit_seconds = 20.0;
    let mhe_seconds = if needs_mhe { 15.0 } else { 0.0 };
    let mpc_seconds = 3.0;

    // Rough operation cost estimates
    let mut ops_seconds = 0.0;
    if has_sharetensor && matmul_count > 0 {
        ops_seconds += matmul_count as f64 * 1000.0 * 0.00003;
    }
    if has_ciphertensor && matmul_count > 0 {
        ops_seconds += matmul_count as f64 * 100.0 * 0.033;
    }
    ops_seconds = (ops_seconds * 1000.0).round() / 1000.0;

    let total_seconds = ((jit_seconds + mhe_seconds + mpc_seconds + ops_seconds) * 10.0).round() / 10.0;

    Ok(Analysis {
        file: path.file_name()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_default(),
        path: path.canonicalize()
            .map(|p| p.to_string_lossy().to_string())
            .unwrap_or_else(|_| path.to_string_lossy().to_string()),
        types: TypeUsage {
            sharetensor: has_sharetensor,
            ciphertensor: has_ciphertensor,
            mpu: has_mpu,
            mpp: has_mpp,
            mpa: has_mpa,
        },
        operations: Operations {
            matmul: matmul_count,
            encrypt: encrypt_count,
            decrypt: decrypt_count,
        },
        runtime: RuntimeInfo {
            needs_mhe,
            can_skip_mhe,
            uses_local,
        },
        estimate: Estimate {
            jit_seconds,
            mhe_seconds,
            mpc_seconds,
            ops_seconds,
            total_seconds,
        },
    })
}

pub fn print_analysis(analysis: &Analysis) {
    println!("============================================================");
    println!("STATIC ANALYSIS: {}", analysis.file);
    println!("============================================================");

    println!("\n--- Type Usage ---");
    println!("  Sharetensor (MPC):   {}", if analysis.types.sharetensor { "Yes" } else { "No" });
    println!("  Ciphertensor (HE):   {}", if analysis.types.ciphertensor { "Yes" } else { "No" });
    println!("  MPU (Union):         {}", if analysis.types.mpu { "Yes" } else { "No" });
    println!("  MPP (Partition):     {}", if analysis.types.mpp { "Yes" } else { "No" });
    println!("  MPA (Aggregate):     {}", if analysis.types.mpa { "Yes" } else { "No" });

    println!("\n--- Operation Patterns ---");
    println!("  Matrix multiplications (@): {}", analysis.operations.matmul);
    println!("  Encrypt calls:              {}", analysis.operations.encrypt);
    println!("  Decrypt/reveal calls:       {}", analysis.operations.decrypt);

    println!("\n--- Runtime Requirements ---");
    println!("  Requires MHE setup:  {}", if analysis.runtime.needs_mhe { "Yes" } else { "No (MPC only)" });
    println!("  Can use --skip-mhe:  {}", if analysis.runtime.can_skip_mhe { "Yes" } else { "No" });
    println!("  Uses @local:         {}", if analysis.runtime.uses_local { "Yes" } else { "No" });

    println!("\n--- Estimated Runtime ---");
    println!("  JIT Compilation:     {:>6.1}s", analysis.estimate.jit_seconds);
    if analysis.runtime.needs_mhe {
        println!("  MHE Key Setup:       {:>6.1}s", analysis.estimate.mhe_seconds);
    }
    println!("  MPC Network:         {:>6.1}s", analysis.estimate.mpc_seconds);
    println!("  Operations (rough):  {:>6.1}s", analysis.estimate.ops_seconds);
    println!("  --------------------------");
    println!("  TOTAL:               {:>6.1}s", analysis.estimate.total_seconds);
    println!("============================================================");
}

pub fn print_json(analysis: &Analysis) -> Result<()> {
    println!("{}", serde_json::to_string_pretty(analysis)?);
    Ok(())
}
