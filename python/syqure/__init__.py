# Re-export everything from the Rust extension module
from .syqure import (
    CompileOptions,
    Syqure,
    __doc__,
    __version__,
    analyze,
    compile,
    compile_and_run,
    info,
    version,
)

__all__ = [
    "CompileOptions",
    "Syqure",
    "__doc__",
    "__version__",
    "analyze",
    "compile",
    "compile_and_run",
    "info",
    "version",
]
