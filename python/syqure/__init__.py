# Re-export everything from the Rust extension module
from .syqure import (
    Syqure,
    CompileOptions,
    compile,
    compile_and_run,
    version,
    info,
    __version__,
    __doc__,
)

__all__ = [
    "Syqure",
    "CompileOptions",
    "compile",
    "compile_and_run",
    "version",
    "info",
    "__version__",
]
