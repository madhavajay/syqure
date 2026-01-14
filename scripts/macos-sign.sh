#!/bin/bash
set -euo pipefail

# macOS Code Signing and Notarization Script
# Required environment variables:
#   APPLE_ID                    - Apple ID email
#   APPLE_PASSWORD              - App-specific password
#   APPLE_TEAM_ID               - Team ID (10 character string)
#   APPLE_SIGNING_IDENTITY      - "Developer ID Application: Name (TeamID)"
#   SIGNING_CERTIFICATE_P12_DATA - Base64 encoded .p12 certificate
#   SIGNING_CERTIFICATE_PASSWORD - Password for the .p12 file

BINARY="${1:-}"
if [[ -z "$BINARY" || ! -f "$BINARY" ]]; then
    echo "Usage: $0 <binary-path>" >&2
    exit 1
fi

# Load environment variables from .env if present
if [[ -f ".env" ]]; then
    echo "Loading environment from .env..."
    export $(grep -v '^#' .env | xargs)
fi

# Verify required variables
for var in APPLE_ID APPLE_PASSWORD APPLE_TEAM_ID APPLE_SIGNING_IDENTITY; do
    if [[ -z "${!var:-}" ]]; then
        echo "ERROR: $var is not set" >&2
        exit 1
    fi
done

KEYCHAIN_NAME="syqure-signing.keychain"
KEYCHAIN_PASSWORD="$(openssl rand -base64 32)"

cleanup() {
    echo "Cleaning up keychain..."
    security delete-keychain "$KEYCHAIN_NAME" 2>/dev/null || true
}
trap cleanup EXIT

echo "=== Step 1: Import Certificate ==="
if [[ -n "${SIGNING_CERTIFICATE_P12_DATA:-}" ]]; then
    # Decode and import certificate
    P12_FILE="$(mktemp).p12"
    echo "$SIGNING_CERTIFICATE_P12_DATA" | base64 -d > "$P12_FILE"

    # Create temporary keychain
    security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_NAME"
    security set-keychain-settings -lut 21600 "$KEYCHAIN_NAME"
    security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_NAME"

    # Import certificate
    security import "$P12_FILE" -k "$KEYCHAIN_NAME" \
        -P "${SIGNING_CERTIFICATE_PASSWORD:-}" \
        -T /usr/bin/codesign \
        -T /usr/bin/productbuild

    # Allow codesign to access keychain
    security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_NAME"

    # Add to keychain search list
    security list-keychains -d user -s "$KEYCHAIN_NAME" $(security list-keychains -d user | tr -d '"')

    rm -f "$P12_FILE"
    echo "Certificate imported successfully."
else
    echo "Using existing keychain certificates..."
fi

echo ""
echo "=== Step 2: Code Sign Binary ==="
echo "Binary: $BINARY"
echo "Identity: $APPLE_SIGNING_IDENTITY"

# Sign with hardened runtime (required for notarization)
codesign --force \
    --options runtime \
    --timestamp \
    --sign "$APPLE_SIGNING_IDENTITY" \
    "$BINARY"

echo "Verifying signature..."
codesign --verify --verbose=4 "$BINARY"

echo ""
echo "=== Step 3: Create ZIP for Notarization ==="
BINARY_NAME="$(basename "$BINARY")"
ZIP_FILE="${BINARY}.zip"
ditto -c -k --keepParent "$BINARY" "$ZIP_FILE"
echo "Created: $ZIP_FILE"

echo ""
echo "=== Step 4: Submit for Notarization ==="
xcrun notarytool submit "$ZIP_FILE" \
    --apple-id "$APPLE_ID" \
    --password "$APPLE_PASSWORD" \
    --team-id "$APPLE_TEAM_ID" \
    --wait

echo ""
echo "=== Step 5: Staple Notarization Ticket ==="
# Note: stapler only works on app bundles and disk images, not raw binaries
# For binaries distributed in a zip, the notarization is verified online
echo "Note: Raw binaries cannot be stapled. Notarization will be verified online."
echo "If distributing as a DMG or app bundle, use: xcrun stapler staple <path>"

echo ""
echo "=== Done ==="
echo "Signed and notarized: $BINARY"
