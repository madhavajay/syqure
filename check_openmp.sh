#!/usr/bin/env bash
set -euo pipefail

# Platform detection
OS="$(uname -s)"

# OpenMP regex per platform
if [[ "$OS" == "Darwin" ]]; then
  openmp_regex='libomp\.(dylib|tbd)'
  binary_check='Mach-O'
  file_pattern='-name *.dylib -o -name *.so -o -perm -111'
else
  openmp_regex='lib(omp|gomp|iomp5)\.so'
  binary_check='ELF'
  file_pattern='-name *.so -o -perm -111'
fi

default_paths=(
  "./bin/codon"
  "./codon/build/lib"
  "./codon/build"
)

paths=()
if [[ $# -gt 0 ]]; then
  paths=("$@")
else
  for p in "${default_paths[@]}"; do
    if [[ -e "$p" ]]; then
      paths+=("$p")
    fi
  done
fi

if [[ ${#paths[@]} -eq 0 ]]; then
  echo "No existing paths to scan. Pass paths as args."
  exit 1
fi

# Tool detection
have_otool=0
have_readelf=0
have_ldd=0

if command -v otool >/dev/null 2>&1; then
  have_otool=1
fi
if command -v readelf >/dev/null 2>&1; then
  have_readelf=1
fi
if command -v ldd >/dev/null 2>&1; then
  have_ldd=1
fi

if [[ "$OS" == "Darwin" && $have_otool -eq 0 ]]; then
  echo "otool not available. Install Xcode command line tools: xcode-select --install"
  exit 1
elif [[ "$OS" != "Darwin" && $have_readelf -eq 0 && $have_ldd -eq 0 ]]; then
  echo "Neither readelf nor ldd is available."
  exit 1
fi

total=0
with_openmp=0

scan_file() {
  local f="$1"
  local deps=""

  if [[ "$OS" == "Darwin" ]]; then
    # macOS: use otool -L to list linked libraries
    deps=$(otool -L "$f" 2>/dev/null | tail -n +2 | awk '{print $1}')
  elif [[ $have_readelf -eq 1 ]]; then
    deps=$(readelf -d "$f" 2>/dev/null | awk '/NEEDED/ {print $NF}' | tr -d '[]')
  elif [[ $have_ldd -eq 1 ]]; then
    deps=$(ldd "$f" 2>/dev/null | awk '{print $1}')
  fi

  if echo "$deps" | grep -qE "$openmp_regex"; then
    printf "OPENMP  %s\n" "$f"
    with_openmp=$((with_openmp + 1))
  else
    printf "NOOMP   %s\n" "$f"
  fi
}

for root in "${paths[@]}"; do
  if [[ ! -e "$root" ]]; then
    continue
  fi
  while IFS= read -r -d '' f; do
    if file -L "$f" 2>/dev/null | grep -q "$binary_check"; then
      total=$((total + 1))
      scan_file "$f"
    fi
  done < <(
    find "$root" -type f \( -name '*.so' -o -name '*.dylib' -o -perm -111 \) \
      ! -path '*/CMakeFiles/*' \
      ! -path '*/_deps/*' \
      ! -path '*/llvm-project/*' \
      ! -path '*/bin/llvm-*' \
      ! -path '*/bin/opt' \
      ! -path '*/bin/lli' \
      ! -path '*/bin/llc' \
      ! -path '*/bin/bugpoint' \
      ! -path '*/bin/sanstats' \
      ! -path '*/bin/sancov' \
      -print0 2>/dev/null
  )
done

echo "---"
echo "Platform: $OS"
echo "Scanned: $total"
echo "OpenMP-linked: $with_openmp"
