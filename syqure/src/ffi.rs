#[cxx::bridge]
mod bridge {
    #[derive(Debug)]
    struct SyCompileOpts {
        argv0: String,
        input: String,
        plugins: Vec<String>,
        disabled_opts: Vec<String>,
        libs: Vec<String>,
        linker_flags: String,
        release: bool,
        standalone: bool,
        shared_lib: bool,
        quiet: bool,
    }

    #[derive(Debug)]
    struct SyBuildResult {
        status: i32,
        output_path: String,
        error: String,
        /// Captured stdout from the program execution.
        stdout_output: String,
        /// Captured stderr from the program execution.
        stderr_output: String,
    }

    unsafe extern "C++" {
        include!("ffi/bridge.h");

        /// Codon version string.
        fn sy_codon_version() -> String;
        /// Compile and run a Codon program (standalone flag controls linking mode).
        fn sy_codon_run(opts: &SyCompileOpts, prog_args: &Vec<String>) -> SyBuildResult;
        /// Compile and emit an executable/shared lib (no run).
        fn sy_codon_build_exe(opts: &SyCompileOpts, output: &str) -> SyBuildResult;
    }
}

pub use bridge::{
    sy_codon_build_exe, sy_codon_run, sy_codon_version, SyBuildResult, SyCompileOpts,
};
