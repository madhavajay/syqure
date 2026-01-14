#!/usr/bin/env bash
set -euo pipefail

if ! command -v pacman >/dev/null 2>&1; then
  echo "This script assumes Arch (pacman). Install Python manually for your distro." >&2
  exit 1
fi

sudo pacman -S --needed python

LIBPY_PATH=""
for candidate in /usr/lib/libpython3*.so*; do
  if [[ -f "$candidate" ]]; then
    LIBPY_PATH="$candidate"
    break
  fi
done

if [[ -z "$LIBPY_PATH" ]]; then
  echo "Could not find libpython in /usr/lib after install." >&2
  exit 1
fi

LOCAL_LIB_DIR="$HOME/.local/lib"
mkdir -p "$LOCAL_LIB_DIR"
ln -sf "$LIBPY_PATH" "$LOCAL_LIB_DIR/libpython.so"

echo "Linked $LIBPY_PATH -> $LOCAL_LIB_DIR/libpython.so"

ZSHRC="$HOME/.zshrc"
LINE="export LD_LIBRARY_PATH=\"$LOCAL_LIB_DIR:\$LD_LIBRARY_PATH\""
if [[ -f "$ZSHRC" ]] && ! rg -q "LD_LIBRARY_PATH=.*\\.local/lib" "$ZSHRC"; then
  printf "\n%s\n" "$LINE" >> "$ZSHRC"
  echo "Added LD_LIBRARY_PATH to $ZSHRC"
else
  echo "Add this to your shell if needed:"
  echo "  $LINE"
fi
