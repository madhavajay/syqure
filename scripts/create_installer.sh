#!/usr/bin/env bash
set -euo pipefail

# Create a self-extracting syqure wrapper
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
    LIB_PATH_VAR="DYLD_LIBRARY_PATH"
elif [[ "$TARBALL" == *"linux"* ]]; then
    LIB_PATH_VAR="LD_LIBRARY_PATH"
else
    echo "Error: cannot detect platform from tarball name" >&2
    exit 1
fi

# Create the wrapper script
cat > "$OUTPUT" << 'WRAPPER_EOF'
#!/usr/bin/env bash
set -euo pipefail

VERSION="__VERSION__"
CACHE_DIR="${HOME}/.cache/syqure/${VERSION}"

# Extract on first run (silent)
if [[ ! -x "${CACHE_DIR}/syqure" ]]; then
    mkdir -p "$CACHE_DIR"
    SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
    ARCHIVE_LINE=$(awk '/^__ARCHIVE__$/{print NR + 1; exit 0;}' "$SELF")
    tail -n +"$ARCHIVE_LINE" "$SELF" | tar xzf - -C "$CACHE_DIR" 2>/dev/null
fi

# Run with library path
export __LIB_PATH_VAR__="${CACHE_DIR}/lib/codon${__LIB_PATH_VAR__:+:$__LIB_PATH_VAR__}"
exec "${CACHE_DIR}/syqure" "$@"

__ARCHIVE__
WRAPPER_EOF

# Replace placeholders
sed -i.bak "s/__VERSION__/$VERSION/g" "$OUTPUT"
sed -i.bak "s/__LIB_PATH_VAR__/$LIB_PATH_VAR/g" "$OUTPUT"
rm -f "$OUTPUT.bak"

# Append the tarball
cat "$TARBALL" >> "$OUTPUT"
chmod +x "$OUTPUT"

echo "Created: $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
