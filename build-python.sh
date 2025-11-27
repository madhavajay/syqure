#!/bin/bash
set -e

cd "$(dirname "$0")"

echo "🔨 Building syqure Python package..."

# Check if maturin is installed
if ! command -v maturin &> /dev/null; then
    echo "❌ maturin not found. Installing..."
    pip install maturin
fi

# Build the wheel
echo "📦 Building wheel..."
maturin build --manifest-path python/Cargo.toml --release

echo "✅ Build complete!"
echo ""
echo "📦 Wheel location: target/wheels/"
ls -lh target/wheels/*.whl
echo ""
echo "To install locally:"
echo "  pip install target/wheels/syqure-*.whl"
