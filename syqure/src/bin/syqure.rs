use std::path::PathBuf;

use anyhow::Result;
use clap::{Parser, Subcommand};
use syqure::{analyze_file, analyze, CompileOptions, Syqure};

#[derive(Parser, Debug)]
#[command(name = "syqure", about = "Compile and run Codon/Sequre programs")]
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
    opts.program_args = args.program_args.clone();
    opts.run_after_build = !args.build_only;

    let syqure = Syqure::new(opts);
    if let Some(output) = syqure.compile_and_maybe_run(source)? {
        println!("Built executable at {}", output.display());
    }

    Ok(())
}
