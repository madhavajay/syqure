#pragma once

#include "rust/cxx.h"
#include "syqure/src/ffi.rs.h" // cxxbridge-generated types

SyBuildResult sy_codon_run(const SyCompileOpts &opts,
                           const rust::Vec<rust::String> &prog_args);
SyBuildResult sy_codon_build_exe(const SyCompileOpts &opts, rust::Str output);
rust::String sy_codon_version();
