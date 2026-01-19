use std::path::PathBuf;

use anyhow::Result;
use clap::{Parser, Subcommand};
use syqure::{analyze_file, analyze, bundle, CompileOptions, Syqure};

const VERSION: &str = env!("CARGO_PKG_VERSION");

#[derive(Parser, Debug)]
#[command(name = "syqure", version = VERSION, about = "Compile and run Codon/Sequre programs")]
struct Args {
    #[command(subcommand)]
    command: Option<Command>,

    /// Path to the .codon source file (shorthand for `syqure run <source>`)
    #[arg(global = true)]
    source: Option<PathBuf>,

    /// Compile in release mode
    #[arg(long, global = true)]
    release: bool,

    /// Only build; do not run the resulting binary
    #[arg(long, global = true)]
    build_only: bool,

    /// Skip MHE (homomorphic encryption) setup for MPC-only programs
    #[arg(long, global = true)]
    skip_mhe_setup: bool,

    /// Show compiler warnings (hidden by default)
    #[arg(long, global = true)]
    show_warnings: bool,

    /// Path to Codon installation (defaults to CODON_PATH or ./codon/install)
    #[arg(long, env = "CODON_PATH", global = true)]
    codon_path: Option<PathBuf>,

    /// Program arguments passed to the compiled Codon binary
    #[arg(last = true, global = true)]
    program_args: Vec<String>,
}

#[derive(Subcommand, Debug)]
enum Command {
    /// Compile and run a .codon source file
    Run {
        /// Path to the .codon source file
        source: PathBuf,
    },
    /// Analyze a .codon file for cost estimation
    Analyze {
        /// Path to the .codon source file
        source: PathBuf,
        /// Output as JSON
        #[arg(long)]
        json: bool,
    },
    /// Show build and system information for debugging
    Info,
}

fn main() -> Result<()> {
    let args = Args::parse();

    match &args.command {
        Some(Command::Analyze { source, json }) => {
            let analysis = analyze_file(source)?;
            if *json {
                analyze::print_json(&analysis)?;
            } else {
                analyze::print_analysis(&analysis);
            }
        }
        Some(Command::Run { source }) => {
            run_source(&args, source)?;
        }
        Some(Command::Info) => {
            print_info();
        }
        None => {
            // Default behavior: if source is provided without subcommand, run it
            if let Some(ref source) = args.source {
                run_source(&args, source)?;
            } else {
                // No source provided, show help
                use clap::CommandFactory;
                Args::command().print_help()?;
            }
        }
    }

    Ok(())
}

fn run_source(args: &Args, source: &PathBuf) -> Result<()> {
    let mut opts = CompileOptions::default();
    if let Some(ref path) = args.codon_path {
        opts.codon_path = path.clone();
    }
    opts.release = args.release;
    opts.run_after_build = !args.build_only;
    opts.quiet = !args.show_warnings;

    // Build program args, prepending --skip-mhe-setup if requested
    let mut program_args = Vec::new();
    if args.skip_mhe_setup {
        program_args.push("--skip-mhe-setup".to_string());
    }
    program_args.extend(args.program_args.clone());
    opts.program_args = program_args;

    let syqure = Syqure::new(opts);
    let result = syqure.compile_and_maybe_run(source)?;

    // Print captured output
    if !result.stdout.is_empty() {
        print!("{}", result.stdout);
    }
    if !result.stderr.is_empty() {
        eprint!("{}", result.stderr);
    }

    if let Some(output) = result.output_path {
        println!("Built executable at {}", output.display());
    }

    Ok(())
}

fn print_info() {
    println!("syqure {}", VERSION);
    println!();

    // Build info
    println!("Build Information:");
    println!("  Version:      {}", VERSION);
    println!("  Target:       {}", env!("TARGET"));
    println!("  Profile:      {}", if cfg!(debug_assertions) { "debug" } else { "release" });

    // Compile-time info from build.rs (if available)
    if let Some(cache_path) = option_env!("SYQURE_CACHE_LIB_PATH") {
        println!("  Cache path:   ~/.cache/syqure/{}", cache_path);
    }
    println!();

    // System info
    println!("System Information:");
    println!("  OS:           {}", std::env::consts::OS);
    println!("  Arch:         {}", std::env::consts::ARCH);
    if let Ok(exe) = std::env::current_exe() {
        println!("  Executable:   {}", exe.display());
    }
    println!();

    // Bundle/library info
    println!("Library Information:");
    match bundle::ensure_bundle() {
        Ok(codon_path) => {
            println!("  Codon path:   {}", codon_path.display());
            if let Some(parent) = codon_path.parent() {
                println!("  Cache dir:    {}", parent.display());
            }

            // List libraries
            if codon_path.exists() {
                println!("  Libraries:");
                if let Ok(entries) = std::fs::read_dir(&codon_path) {
                    for entry in entries.flatten() {
                        let path = entry.path();
                        if let Some(name) = path.file_name() {
                            let name_str = name.to_string_lossy();
                            if name_str.ends_with(".dylib") || name_str.ends_with(".so") {
                                if let Ok(meta) = std::fs::metadata(&path) {
                                    let size_kb = meta.len() / 1024;
                                    println!("    {} ({} KB)", name_str, size_kb);
                                } else {
                                    println!("    {}", name_str);
                                }
                            }
                        }
                    }
                }

                // Check plugins
                let plugins_dir = codon_path.join("plugins");
                if plugins_dir.exists() {
                    println!("  Plugins:");
                    if let Ok(entries) = std::fs::read_dir(&plugins_dir) {
                        for entry in entries.flatten() {
                            if entry.path().is_dir() {
                                println!("    {}", entry.file_name().to_string_lossy());
                            }
                        }
                    }
                }
            }
        }
        Err(e) => {
            println!("  Error: {}", e);
        }
    }
    println!();

    // Environment variables
    println!("Environment:");
    for var in ["CODON_PATH", "SYQURE_BUNDLE_CACHE", "DYLD_LIBRARY_PATH", "LD_LIBRARY_PATH"] {
        if let Ok(val) = std::env::var(var) {
            println!("  {}={}", var, val);
        }
    }
}
