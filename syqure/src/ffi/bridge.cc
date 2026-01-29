#include "bridge.h"

#include <cstdio>
#include <fcntl.h>
#include <atomic>
#include <chrono>
#include <memory>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
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

// RAII helper to capture stdout/stderr to strings
class OutputCapture {
public:
  OutputCapture() : stdout_pipe_{-1, -1}, stderr_pipe_{-1, -1},
                    saved_stdout_(-1), saved_stderr_(-1), capturing_(false),
                    stop_(false) {}

  ~OutputCapture() { stop(); }

  bool start() {
    if (capturing_) return true;

    // Create pipes for stdout and stderr
    if (pipe(stdout_pipe_) < 0) return false;
    if (pipe(stderr_pipe_) < 0) {
      close(stdout_pipe_[0]);
      close(stdout_pipe_[1]);
      return false;
    }

    // Save original fds
    fflush(stdout);
    fflush(stderr);
    saved_stdout_ = dup(STDOUT_FILENO);
    saved_stderr_ = dup(STDERR_FILENO);

    // Redirect stdout/stderr to pipes
    dup2(stdout_pipe_[1], STDOUT_FILENO);
    dup2(stderr_pipe_[1], STDERR_FILENO);

    capturing_ = true;
    stop_.store(false);
    stdout_thread_ = std::thread([this]() { readLoop(stdout_pipe_[0], stdout_output_, stdout_mu_); });
    stderr_thread_ = std::thread([this]() { readLoop(stderr_pipe_[0], stderr_output_, stderr_mu_); });
    return true;
  }

  void stop() {
    if (!capturing_) return;
    stop_.store(true);

    // Flush before restoring
    fflush(stdout);
    fflush(stderr);

    // Restore original fds
    if (saved_stdout_ >= 0) {
      dup2(saved_stdout_, STDOUT_FILENO);
      close(saved_stdout_);
      saved_stdout_ = -1;
    }
    if (saved_stderr_ >= 0) {
      dup2(saved_stderr_, STDERR_FILENO);
      close(saved_stderr_);
      saved_stderr_ = -1;
    }

    // Close write ends
    if (stdout_pipe_[1] >= 0) {
      close(stdout_pipe_[1]);
      stdout_pipe_[1] = -1;
    }
    if (stderr_pipe_[1] >= 0) {
      close(stderr_pipe_[1]);
      stderr_pipe_[1] = -1;
    }

    // Join reader threads after closing write ends to signal EOF
    if (stdout_thread_.joinable()) stdout_thread_.join();
    if (stderr_thread_.joinable()) stderr_thread_.join();

    // Close read ends
    if (stdout_pipe_[0] >= 0) {
      close(stdout_pipe_[0]);
      stdout_pipe_[0] = -1;
    }
    if (stderr_pipe_[0] >= 0) {
      close(stderr_pipe_[0]);
      stderr_pipe_[0] = -1;
    }

    capturing_ = false;
  }

  const std::string& getStdout() const { return stdout_output_; }
  const std::string& getStderr() const { return stderr_output_; }

private:
  void readLoop(int fd, std::string &out, std::mutex &mu) {
    if (fd < 0) return;
    char buf[4096];
    while (true) {
      ssize_t n = read(fd, buf, sizeof(buf));
      if (n > 0) {
        std::lock_guard<std::mutex> lock(mu);
        out.append(buf, n);
        continue;
      }
      if (n == 0) {
        break;
      }
      if (errno == EAGAIN || errno == EWOULDBLOCK) {
        if (stop_.load()) {
          std::this_thread::sleep_for(std::chrono::milliseconds(5));
        } else {
          std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
        continue;
      }
      break;
    }
  }

  int stdout_pipe_[2];
  int stderr_pipe_[2];
  int saved_stdout_;
  int saved_stderr_;
  bool capturing_;
  std::string stdout_output_;
  std::string stderr_output_;
  std::thread stdout_thread_;
  std::thread stderr_thread_;
  std::mutex stdout_mu_;
  std::mutex stderr_mu_;
  std::atomic<bool> stop_;
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

SyBuildResult makeError(const std::string &msg, const std::string &stdout_out = "",
                        const std::string &stderr_out = "") {
  SyBuildResult res{};
  res.status = 1;
  res.error = msg;
  res.stdout_output = stdout_out;
  res.stderr_output = stderr_out;
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

  // Restore stderr before running so compiler warnings are visible if not quiet
  suppressor.restore();

  // Capture stdout/stderr from the JIT-executed program
  OutputCapture capture;
  capture.start();

  compiler->getLLVMVisitor()->run(args, libs);

  capture.stop();

  res.status = 0;
  res.stdout_output = capture.getStdout();
  res.stderr_output = capture.getStderr();
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
  res.stdout_output = "";
  res.stderr_output = "";
  return res;
}

rust::String sy_codon_version() { return rust::String(CODON_VERSION); }
