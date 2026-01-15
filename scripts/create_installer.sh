#!/usr/bin/env bash
set -euo pipefail

# Create a self-extracting installer from a release tarball
# Usage: ./create_installer.sh <tarball> <output> <version>

TARBALL="$1"
OUTPUT="$2"
VERSION="${3:-unknown}"

if [[ ! -f "$TARBALL" ]]; then
    echo "Error: tarball not found: $TARBALL" >&2
    exit 1
fi

# Detect platform from tarball name
if [[ "$TARBALL" == *"darwin"* ]]; then
    PLATFORM="macos"
    LIB_PATH_VAR="DYLD_LIBRARY_PATH"
elif [[ "$TARBALL" == *"linux"* ]]; then
    PLATFORM="linux"
    LIB_PATH_VAR="LD_LIBRARY_PATH"
else
    echo "Error: cannot detect platform from tarball name" >&2
    exit 1
fi

# Create the self-extracting script
cat > "$OUTPUT" << 'INSTALLER_HEADER'
#!/usr/bin/env bash
set -euo pipefail

VERSION="__VERSION__"
INSTALL_DIR="${SYQURE_INSTALL_DIR:-$HOME/.local/syqure/$VERSION}"

extract_and_run() {
    if [[ ! -d "$INSTALL_DIR" ]] || [[ "$1" == "--reinstall" ]]; then
        echo "Installing syqure $VERSION to $INSTALL_DIR..." >&2
        rm -rf "$INSTALL_DIR"
        mkdir -p "$INSTALL_DIR"

        # Find where the archive starts (after __ARCHIVE_MARKER__)
        ARCHIVE_LINE=$(awk '/^__ARCHIVE_MARKER__$/{print NR + 1; exit 0;}' "$0")
        tail -n +$ARCHIVE_LINE "$0" | tar xzf - -C "$INSTALL_DIR"

        echo "Installation complete." >&2
    fi

    # Set library path and run
    export __LIB_PATH_VAR__="$INSTALL_DIR/lib/codon${__LIB_PATH_VAR__:+:$__LIB_PATH_VAR__}"

    # Handle special commands
    case "${1:-}" in
        --reinstall)
            shift
            if [[ $# -eq 0 ]]; then
                echo "Reinstalled syqure $VERSION to $INSTALL_DIR"
                exit 0
            fi
            exec "$INSTALL_DIR/syqure" "$@"
            ;;
        --install-path)
            echo "$INSTALL_DIR"
            exit 0
            ;;
        --add-to-path)
            SHELL_RC=""
            if [[ -n "${ZSH_VERSION:-}" ]] || [[ "$SHELL" == *"zsh"* ]]; then
                SHELL_RC="$HOME/.zshrc"
            elif [[ -n "${BASH_VERSION:-}" ]] || [[ "$SHELL" == *"bash"* ]]; then
                SHELL_RC="$HOME/.bashrc"
            fi
            if [[ -n "$SHELL_RC" ]]; then
                LINE="export PATH=\"$INSTALL_DIR:\$PATH\""
                if ! grep -qF "$LINE" "$SHELL_RC" 2>/dev/null; then
                    echo "$LINE" >> "$SHELL_RC"
                    echo "Added syqure to PATH in $SHELL_RC"
                    echo "Run 'source $SHELL_RC' or restart your shell"
                else
                    echo "syqure already in PATH"
                fi
            else
                echo "Add this to your shell rc file:"
                echo "  export PATH=\"$INSTALL_DIR:\$PATH\""
            fi
            exit 0
            ;;
        *)
            exec "$INSTALL_DIR/syqure" "$@"
            ;;
    esac
}

extract_and_run "$@"
exit 0

__ARCHIVE_MARKER__
INSTALLER_HEADER

# Replace placeholders
sed -i.bak "s/__VERSION__/$VERSION/g" "$OUTPUT"
sed -i.bak "s/__LIB_PATH_VAR__/$LIB_PATH_VAR/g" "$OUTPUT"
rm -f "$OUTPUT.bak"

# Append the tarball
cat "$TARBALL" >> "$OUTPUT"

# Make executable
chmod +x "$OUTPUT"

echo "Created self-extracting installer: $OUTPUT"
echo "Size: $(du -h "$OUTPUT" | cut -f1)"
