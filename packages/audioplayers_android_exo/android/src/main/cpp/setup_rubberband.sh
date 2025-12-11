#!/bin/bash
# Setup script to download Rubberband library source code
# Run this script once before building the Android project

RUBBERBAND_VERSION="3.3.0"
RUBBERBAND_URL="https://breakfastquay.com/files/releases/rubberband-${RUBBERBAND_VERSION}.tar.bz2"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUBBERBAND_DIR="${SCRIPT_DIR}/rubberband"

echo "Setting up Rubberband ${RUBBERBAND_VERSION}..."

# Check if already exists
if [ -d "${RUBBERBAND_DIR}" ]; then
    echo "Rubberband directory already exists. Skipping download."
    exit 0
fi

# Create temp directory
TEMP_DIR=$(mktemp -d)
cd "${TEMP_DIR}"

# Download
echo "Downloading from ${RUBBERBAND_URL}..."
curl -L -o rubberband.tar.bz2 "${RUBBERBAND_URL}"

# Extract
echo "Extracting..."
tar -xjf rubberband.tar.bz2

# Move to destination
mv rubberband-* "${RUBBERBAND_DIR}"

# Cleanup
rm -rf "${TEMP_DIR}"

echo "Rubberband setup complete at ${RUBBERBAND_DIR}"

