use pyo3::exceptions::PyRuntimeError;
use pyo3::prelude::*;
use pyo3::types::PyDict;

use std::path::Path;

use ::syqure as core;
use core::{analyze_file, bundle, CompileOptions, RunResult, Syqure};

/// Print captured output to Python's stdout/stderr so it appears in Jupyter cells
fn print_captured_output(py: Python<'_>, result: &RunResult) -> PyResult<()> {
    let builtins = py.import_bound("builtins")?;
    let print_fn = builtins.getattr("print")?;

    if !result.stdout.is_empty() {
        // Use print with end="" to avoid extra newline since output already has newlines
        print_fn.call1((&result.stdout,))?;
    }
    if !result.stderr.is_empty() {
        let sys = py.import_bound("sys")?;
        let stderr = sys.getattr("stderr")?;
        // Print to stderr using file= parameter
        let kwargs = PyDict::new_bound(py);
        kwargs.set_item("file", stderr)?;
        kwargs.set_item("end", "")?;
        print_fn.call((&result.stderr,), Some(&kwargs))?;
    }
    Ok(())
}

fn map_err(err: impl std::fmt::Display) -> PyErr {
    PyRuntimeError::new_err(err.to_string())
}

#[pyclass(name = "CompileOptions", module = "syqure")]
#[derive(Clone)]
struct PyCompileOptions {
    inner: CompileOptions,
}

#[pymethods]
impl PyCompileOptions {
    #[new]
    #[allow(clippy::too_many_arguments)]
    #[pyo3(signature = (
        codon_path=None,
        plugin=None,
        disable_opts=None,
        release=false,
        run_after_build=true,
        program_args=None,
        libs=None,
        linker_flags=None
    ))]
    fn new(
        codon_path: Option<String>,
        plugin: Option<String>,
        disable_opts: Option<Vec<String>>,
        release: bool,
        run_after_build: bool,
        program_args: Option<Vec<String>>,
        libs: Option<Vec<String>>,
        linker_flags: Option<String>,
    ) -> Self {
        let mut opts = CompileOptions::default();

        if let Some(path) = codon_path {
            opts.codon_path = path.into();
        }
        if let Some(p) = plugin {
            opts.plugin = p;
        }
        if let Some(d) = disable_opts {
            opts.disable_opts = d;
        }
        opts.release = release;
        opts.run_after_build = run_after_build;
        if let Some(args) = program_args {
            opts.program_args = args;
        }
        if let Some(l) = libs {
            opts.libs = l;
        }
        if let Some(flags) = linker_flags {
            opts.linker_flags = flags;
        }

        Self { inner: opts }
    }

    #[getter]
    fn codon_path(&self) -> String {
        self.inner.codon_path.to_string_lossy().into_owned()
    }

    #[setter]
    fn set_codon_path(&mut self, path: String) {
        self.inner.codon_path = path.into();
    }

    #[getter]
    fn plugin(&self) -> String {
        self.inner.plugin.clone()
    }

    #[setter]
    fn set_plugin(&mut self, plugin: String) {
        self.inner.plugin = plugin;
    }

    #[getter]
    fn disable_opts(&self) -> Vec<String> {
        self.inner.disable_opts.clone()
    }

    #[setter]
    fn set_disable_opts(&mut self, opts: Vec<String>) {
        self.inner.disable_opts = opts;
    }

    #[getter]
    fn release(&self) -> bool {
        self.inner.release
    }

    #[setter]
    fn set_release(&mut self, release: bool) {
        self.inner.release = release;
    }

    #[getter]
    fn run_after_build(&self) -> bool {
        self.inner.run_after_build
    }

    #[setter]
    fn set_run_after_build(&mut self, run: bool) {
        self.inner.run_after_build = run;
    }

    #[getter]
    fn program_args(&self) -> Vec<String> {
        self.inner.program_args.clone()
    }

    #[setter]
    fn set_program_args(&mut self, args: Vec<String>) {
        self.inner.program_args = args;
    }

    #[getter]
    fn libs(&self) -> Vec<String> {
        self.inner.libs.clone()
    }

    #[setter]
    fn set_libs(&mut self, libs: Vec<String>) {
        self.inner.libs = libs;
    }

    #[getter]
    fn linker_flags(&self) -> String {
        self.inner.linker_flags.clone()
    }

    #[setter]
    fn set_linker_flags(&mut self, flags: String) {
        self.inner.linker_flags = flags;
    }
}

#[pyclass(name = "Syqure", module = "syqure")]
struct PySyqure {
    inner: Syqure,
}

#[pymethods]
impl PySyqure {
    #[new]
    fn new(opts: PyCompileOptions) -> Self {
        Self {
            inner: Syqure::new(opts.inner),
        }
    }

    #[staticmethod]
    fn default() -> Self {
        Self {
            inner: Syqure::new(CompileOptions::default()),
        }
    }

    fn compile_and_run(&self, py: Python<'_>, source: String) -> PyResult<()> {
        let result = self.inner.compile_and_maybe_run(&source).map_err(map_err)?;
        print_captured_output(py, &result)?;
        Ok(())
    }

    fn compile(&self, py: Python<'_>, source: String) -> PyResult<Option<String>> {
        let result = self.inner.compile_and_maybe_run(&source).map_err(map_err)?;
        print_captured_output(py, &result)?;
        Ok(result.output_path.map(|p| p.to_string_lossy().into_owned()))
    }
}

#[pyfunction]
fn compile_and_run(py: Python<'_>, source: String, opts: Option<PyCompileOptions>) -> PyResult<()> {
    let options = opts.map(|o| o.inner).unwrap_or_default();
    let syqure = Syqure::new(options);
    let result = syqure.compile_and_maybe_run(&source).map_err(map_err)?;
    print_captured_output(py, &result)?;
    Ok(())
}

#[pyfunction]
fn compile(py: Python<'_>, source: String, opts: Option<PyCompileOptions>) -> PyResult<Option<String>> {
    let options = opts.map(|o| o.inner).unwrap_or_default();
    let syqure = Syqure::new(options);
    let result = syqure.compile_and_maybe_run(&source).map_err(map_err)?;
    print_captured_output(py, &result)?;
    Ok(result.output_path.map(|p| p.to_string_lossy().into_owned()))
}

/// Returns the version string
#[pyfunction]
fn version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

/// Returns detailed build and system information as a dictionary
#[pyfunction]
fn info(py: Python<'_>) -> PyResult<Py<PyDict>> {
    let dict = PyDict::new_bound(py);

    // Version info
    dict.set_item("version", env!("CARGO_PKG_VERSION"))?;
    dict.set_item("target", env!("TARGET"))?;
    dict.set_item(
        "profile",
        if cfg!(debug_assertions) {
            "debug"
        } else {
            "release"
        },
    )?;

    // System info
    dict.set_item("os", std::env::consts::OS)?;
    dict.set_item("arch", std::env::consts::ARCH)?;

    // Bundle/library info
    match bundle::ensure_bundle() {
        Ok(codon_path) => {
            dict.set_item("codon_path", codon_path.to_string_lossy().to_string())?;
            if let Some(parent) = codon_path.parent() {
                dict.set_item("cache_dir", parent.to_string_lossy().to_string())?;
            }

            // List libraries
            let mut libs = Vec::new();
            if codon_path.exists() {
                if let Ok(entries) = std::fs::read_dir(&codon_path) {
                    for entry in entries.flatten() {
                        let path = entry.path();
                        if let Some(name) = path.file_name() {
                            let name_str = name.to_string_lossy();
                            if name_str.ends_with(".dylib") || name_str.ends_with(".so") {
                                libs.push(name_str.to_string());
                            }
                        }
                    }
                }
            }
            dict.set_item("libraries", libs)?;

            // List plugins
            let mut plugins = Vec::new();
            let plugins_dir = codon_path.join("plugins");
            if plugins_dir.exists() {
                if let Ok(entries) = std::fs::read_dir(&plugins_dir) {
                    for entry in entries.flatten() {
                        if entry.path().is_dir() {
                            plugins.push(entry.file_name().to_string_lossy().to_string());
                        }
                    }
                }
            }
            dict.set_item("plugins", plugins)?;
        }
        Err(e) => {
            dict.set_item("bundle_error", e.to_string())?;
        }
    }

    // Environment variables
    let env_dict = PyDict::new_bound(py);
    for var in ["CODON_PATH", "SYQURE_BUNDLE_CACHE", "DYLD_LIBRARY_PATH", "LD_LIBRARY_PATH"] {
        if let Ok(val) = std::env::var(var) {
            env_dict.set_item(var, val)?;
        }
    }
    dict.set_item("environment", env_dict)?;

    Ok(dict.into())
}

/// Analyze a .codon file and return cost estimation as a dictionary
#[pyfunction]
fn analyze(py: Python<'_>, source: String) -> PyResult<Py<PyDict>> {
    let path = Path::new(&source);
    let analysis = analyze_file(path).map_err(map_err)?;

    let dict = PyDict::new_bound(py);
    dict.set_item("file", &analysis.file)?;
    dict.set_item("path", &analysis.path)?;

    // Types
    let types = PyDict::new_bound(py);
    types.set_item("sharetensor", analysis.types.sharetensor)?;
    types.set_item("ciphertensor", analysis.types.ciphertensor)?;
    types.set_item("mpu", analysis.types.mpu)?;
    types.set_item("mpp", analysis.types.mpp)?;
    types.set_item("mpa", analysis.types.mpa)?;
    dict.set_item("types", types)?;

    // Operations
    let ops = PyDict::new_bound(py);
    ops.set_item("matmul", analysis.operations.matmul)?;
    ops.set_item("encrypt", analysis.operations.encrypt)?;
    ops.set_item("decrypt", analysis.operations.decrypt)?;
    dict.set_item("operations", ops)?;

    // Runtime
    let runtime = PyDict::new_bound(py);
    runtime.set_item("needs_mhe", analysis.runtime.needs_mhe)?;
    runtime.set_item("can_skip_mhe", analysis.runtime.can_skip_mhe)?;
    runtime.set_item("uses_local", analysis.runtime.uses_local)?;
    dict.set_item("runtime", runtime)?;

    // Estimate
    let estimate = PyDict::new_bound(py);
    estimate.set_item("jit_seconds", analysis.estimate.jit_seconds)?;
    estimate.set_item("mhe_seconds", analysis.estimate.mhe_seconds)?;
    estimate.set_item("mpc_seconds", analysis.estimate.mpc_seconds)?;
    estimate.set_item("ops_seconds", analysis.estimate.ops_seconds)?;
    estimate.set_item("total_seconds", analysis.estimate.total_seconds)?;
    dict.set_item("estimate", estimate)?;

    Ok(dict.into())
}

#[pymodule]
fn syqure(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add_class::<PyCompileOptions>()?;
    m.add_class::<PySyqure>()?;

    m.add_function(wrap_pyfunction!(compile_and_run, m)?)?;
    m.add_function(wrap_pyfunction!(compile, m)?)?;
    m.add_function(wrap_pyfunction!(analyze, m)?)?;
    m.add_function(wrap_pyfunction!(version, m)?)?;
    m.add_function(wrap_pyfunction!(info, m)?)?;

    m.add("__version__", env!("CARGO_PKG_VERSION"))?;
    m.add(
        "__doc__",
        "Python bindings for the syqure Rust library - Codon/Sequre compiler wrapper using PyO3.",
    )?;

    Ok(())
}
