#!/bin/bash
set -e

cd "$(dirname "$0")"

echo "🔨 Building syqure Python package..."
./build_python.sh

echo ""
echo "📦 Installing syqure..."

# Check if uv is available
if command -v uv &> /dev/null; then
    echo "Using uv for installation..."
    uv pip install --force-reinstall target/wheels/syqure-*.whl
else
    echo "Using pip for installation..."
    pip install --force-reinstall target/wheels/syqure-*.whl
fi

echo ""
echo "✅ Installation complete!"
echo ""
echo "Test with:"
echo "  python -c 'import syqure; print(syqure.__version__)'"
