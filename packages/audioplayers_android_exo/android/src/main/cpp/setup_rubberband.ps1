# Setup script to download Rubberband library source code
# Run this script once before building the Android project

$RUBBERBAND_VERSION = "3.3.0"
$RUBBERBAND_URL = "https://breakfastquay.com/files/releases/rubberband-$RUBBERBAND_VERSION.tar.bz2"
$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
$RUBBERBAND_DIR = Join-Path $SCRIPT_DIR "rubberband"

Write-Host "Setting up Rubberband $RUBBERBAND_VERSION..."

# Check if already exists
if (Test-Path $RUBBERBAND_DIR) {
    Write-Host "Rubberband directory already exists. Skipping download."
    exit 0
}

# Create temp directory
$TEMP_DIR = Join-Path $env:TEMP "rubberband_download"
New-Item -ItemType Directory -Force -Path $TEMP_DIR | Out-Null

# Download
$TAR_FILE = Join-Path $TEMP_DIR "rubberband.tar.bz2"
Write-Host "Downloading from $RUBBERBAND_URL..."
Invoke-WebRequest -Uri $RUBBERBAND_URL -OutFile $TAR_FILE

# Extract (requires 7-Zip or tar)
Write-Host "Extracting..."
Set-Location $TEMP_DIR

# Try using tar (available in Windows 10+)
tar -xjf $TAR_FILE

# Move to destination
$EXTRACTED_DIR = Get-ChildItem -Directory -Filter "rubberband-*" | Select-Object -First 1
Move-Item $EXTRACTED_DIR.FullName $RUBBERBAND_DIR

# Cleanup
Remove-Item -Recurse -Force $TEMP_DIR

Write-Host "Rubberband setup complete at $RUBBERBAND_DIR"

