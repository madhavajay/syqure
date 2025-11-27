use std::path::PathBuf;

use anyhow::Result;
use clap::Parser;
use syqure::{CompileOptions, Syqure};

#[derive(Parser, Debug)]
#[command(name = "syqure", about = "Compile and run Codon/Sequre programs")]
struct Args {
    /// Path to the .codon source file
    source: PathBuf,
    /// Compile in release mode
    #[arg(long)]
    release: bool,
    /// Only build; do not run the resulting binary
    #[arg(long)]
    build_only: bool,
    /// Path to Codon installation (defaults to CODON_PATH or ./codon/install)
    #[arg(long, env = "CODON_PATH")]
    codon_path: Option<PathBuf>,
    /// Program arguments passed to the compiled Codon binary
    #[arg(last = true)]
    program_args: Vec<String>,
}

fn main() -> Result<()> {
    let args = Args::parse();

    let mut opts = CompileOptions::default();
    if let Some(path) = args.codon_path {
        opts.codon_path = path;
    }
    opts.release = args.release;
    opts.program_args = args.program_args;
    opts.run_after_build = !args.build_only;

    let syqure = Syqure::new(opts);
    if let Some(output) = syqure.compile_and_maybe_run(&args.source)? {
        println!("Built executable at {}", output.display());
    }

    Ok(())
}
