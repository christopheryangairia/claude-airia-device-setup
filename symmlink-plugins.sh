#!/bin/bash

# =============================================================================
# CONFIGURATION — Edit these paths to match your OneDrive location
# =============================================================================

# macOS: Path to your OneDrive plugins folder
MACOS_FROM="$HOME/Library/CloudStorage/OneDrive-Personal/claude-plugins"
MACOS_TO="/Library/Application Support/Claude/org-plugins"

# Windows (WSL or Git Bash): Path to your OneDrive plugins folder
# Use Unix-style paths even on Windows (WSL handles the conversion)
WINDOWS_FROM="/mnt/c/Users/$USER/OneDrive/claude-plugins"
WINDOWS_TO="/Program Files/Claude/org-plugins"

# =============================================================================
# SCRIPT LOGIC — No need to edit below this line
# =============================================================================

set -e

# Detect OS
detect_os() {
  case "$(uname -s)" in
    Darwin)
      echo "macos"
      ;;
    Linux)
      # Check if running inside WSL
      if grep -qEi "(microsoft|wsl)" /proc/version 2>/dev/null; then
        echo "windows"
      else
        echo "linux"
      fi
      ;;
    MINGW*|MSYS*|CYGWIN*)
      echo "windows"
      ;;
    *)
      echo "unknown"
      ;;
  esac
}

OS=$(detect_os)

echo "🔍 Detected OS: $OS"

case "$OS" in
  macos)
    FROM="$MACOS_FROM"
    TO="$MACOS_TO"
    ;;
  windows)
    FROM="$WINDOWS_FROM"
    TO="$WINDOWS_TO"
    ;;
  *)
    echo "❌ Unsupported OS: $OS"
    echo "   This script supports macOS and Windows (WSL / Git Bash) only."
    exit 1
    ;;
esac

echo "📂 From : $FROM"
echo "📁 To   : $TO"

# Validate source exists
if [ ! -d "$FROM" ]; then
  echo ""
  echo "❌ Source directory not found:"
  echo "   $FROM"
  echo ""
  echo "   Please update the FROM path at the top of this script."
  exit 1
fi

# If the target already exists and is NOT a symlink, back it up
if [ -e "$TO" ] && [ ! -L "$TO" ]; then
  BACKUP="${TO}.backup_$(date +%Y%m%d_%H%M%S)"
  echo "⚠️  Target exists and is not a symlink. Backing up to:"
  echo "   $BACKUP"
  mv "$TO" "$BACKUP"
fi

# Remove existing symlink if present (to re-point it)
if [ -L "$TO" ]; then
  echo "🔗 Removing existing symlink at: $TO"
  rm "$TO"
fi

# Ensure the parent directory of the target exists
PARENT_DIR=$(dirname "$TO")
if [ ! -d "$PARENT_DIR" ]; then
  echo "📁 Creating parent directory: $PARENT_DIR"
  mkdir -p "$PARENT_DIR"
fi

# Create the symlink
ln -s "$FROM" "$TO"

echo ""
echo "✅ Symlink created successfully!"
echo "   $TO → $FROM"
