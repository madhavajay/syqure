#include "bridge.h"

#include <cstdio>
#include <fcntl.h>
#include <memory>
#include <sstream>
#include <string>
#include <unistd.h>
#include <utility>
#include <vector>

#include "codon/compiler/compiler.h"
#include "codon/compiler/error.h"
#include "codon/config/config.h"
#include "llvm/Support/Error.h"
#include "llvm/Support/raw_ostream.h"

// RAII helper to suppress stderr when quiet mode is enabled
class StderrSuppressor {
public:
  explicit StderrSuppressor(bool suppress) : suppress_(suppress), saved_fd_(-1), restored_(false) {
    if (suppress_) {
      fflush(stderr);
      saved_fd_ = dup(STDERR_FILENO);
      int devnull = open("/dev/null", O_WRONLY);
      if (devnull >= 0) {
        dup2(devnull, STDERR_FILENO);
        close(devnull);
      }
    }
  }
  ~StderrSuppressor() { restore(); }
  // Manually restore stderr (e.g., before running compiled program)
  void restore() {
    if (suppress_ && saved_fd_ >= 0 && !restored_) {
      fflush(stderr);
      dup2(saved_fd_, STDERR_FILENO);
      close(saved_fd_);
      saved_fd_ = -1;
      restored_ = true;
    }
  }
private:
  bool suppress_;
  int saved_fd_;
  bool restored_;
};

namespace {
std::string errorToString(llvm::Error err) {
  std::string output;
  llvm::handleAllErrors(
      std::move(err),
      [&](const codon::error::ParserErrorInfo &e) {
        std::string buf;
        llvm::raw_string_ostream os(buf);
        e.log(os);
        os.flush();
        output = buf;
      },
      [&](const codon::error::PluginErrorInfo &e) { output = e.getMessage(); },
      [&](const codon::error::RuntimeErrorInfo &e) {
        std::string buf;
        llvm::raw_string_ostream os(buf);
        e.log(os);
        os.flush();
        output = buf;
      },
      [&](const codon::error::IOErrorInfo &e) { output = e.getMessage(); },
      [&](const llvm::ErrorInfoBase &e) {
        std::string buf;
        llvm::raw_string_ostream os(buf);
        e.log(os);
        os.flush();
        output = buf;
      });
  if (output.empty()) {
    output = "unknown compilation error";
  }
  return output;
}

codon::Compiler::Mode toMode(bool release) {
  return release ? codon::Compiler::Mode::RELEASE : codon::Compiler::Mode::DEBUG;
}

SyBuildResult makeError(const std::string &msg) {
  SyBuildResult res{};
  res.status = 1;
  res.error = msg;
  return res;
}
} // namespace

SyBuildResult sy_codon_run(const SyCompileOpts &opts,
                           const rust::Vec<rust::String> &prog_args) {
  StderrSuppressor suppressor(opts.quiet);
  SyBuildResult res{};
  std::vector<std::string> disabled_opts;
  for (const auto &s : opts.disabled_opts)
    disabled_opts.emplace_back(std::string(s.data(), s.size()));

  auto compiler = std::make_unique<codon::Compiler>(std::string(opts.argv0.data(), opts.argv0.size()),
                                                    toMode(opts.release), disabled_opts,
                                                    /*isTest=*/false,
                                                    /*pyNumerics=*/false,
                                                    /*pyExtension=*/false);
  compiler->getLLVMVisitor()->setStandalone(opts.standalone);

  for (const auto &plugin : opts.plugins) {
    if (auto err = compiler->load(std::string(plugin.data(), plugin.size()))) {
      return makeError(errorToString(std::move(err)));
    }
  }

  if (auto err =
          compiler->parseFile(std::string(opts.input.data(), opts.input.size()), /*testFlags=*/0,
                              /*defines=*/{})) {
    return makeError(errorToString(std::move(err)));
  }

  if (auto err = compiler->compile()) {
    return makeError(errorToString(std::move(err)));
  }

  std::vector<std::string> args;
  args.reserve(prog_args.size() + 1);
  args.push_back(compiler->getInput());
  for (const auto &arg : prog_args)
    args.emplace_back(std::string(arg.data(), arg.size()));

  std::vector<std::string> libs;
  for (const auto &lib : opts.libs)
    libs.emplace_back(std::string(lib.data(), lib.size()));

  // Restore stderr before running so program output is visible
  suppressor.restore();
  compiler->getLLVMVisitor()->run(args, libs);
  res.status = 0;
  return res;
}

SyBuildResult sy_codon_build_exe(const SyCompileOpts &opts, rust::Str output) {
  StderrSuppressor suppressor(opts.quiet);
  SyBuildResult res{};
  std::vector<std::string> disabled_opts;
  for (const auto &s : opts.disabled_opts)
    disabled_opts.emplace_back(std::string(s.data(), s.size()));

  auto compiler = std::make_unique<codon::Compiler>(std::string(opts.argv0.data(), opts.argv0.size()),
                                                    toMode(opts.release), disabled_opts,
                                                    /*isTest=*/false,
                                                    /*pyNumerics=*/false,
                                                    /*pyExtension=*/false);
  compiler->getLLVMVisitor()->setStandalone(opts.standalone);

  for (const auto &plugin : opts.plugins) {
    if (auto err = compiler->load(std::string(plugin.data(), plugin.size()))) {
      return makeError(errorToString(std::move(err)));
    }
  }

  if (auto err =
          compiler->parseFile(std::string(opts.input.data(), opts.input.size()), /*testFlags=*/0,
                              /*defines=*/{})) {
    return makeError(errorToString(std::move(err)));
  }

  if (auto err = compiler->compile()) {
    return makeError(errorToString(std::move(err)));
  }

  std::vector<std::string> libs;
  for (const auto &lib : opts.libs)
    libs.emplace_back(std::string(lib.data(), lib.size()));
  compiler->getLLVMVisitor()->writeToExecutable(
      std::string(output.data(), output.size()),
      std::string(opts.argv0.data(), opts.argv0.size()), opts.shared_lib, libs,
      std::string(opts.linker_flags.data(), opts.linker_flags.size()));
  res.status = 0;
  res.output_path = std::string(output.data(), output.size());
  return res;
}

rust::String sy_codon_version() { return rust::String(CODON_VERSION); }
