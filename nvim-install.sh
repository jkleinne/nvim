#!/bin/bash
# Exit immediately if a command exits with a non-zero status
set -e

NVIM_URL="https://github.com/neovim/neovim/releases/latest/download/nvim-linux-x86_64.tar.gz"
NVIM_ARCHIVE="nvim-linux-x86_64.tar.gz"
INSTALL_DIR="/opt/nvim-linux-x86_64"
BIN_DIR="$INSTALL_DIR/bin"

# Determine the directory where the script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Downloading Neovim from ${NVIM_URL}..."
curl -LO "$NVIM_URL"

echo
echo "WARNING: This script will remove any existing Neovim installations located at /opt/nvim and ${INSTALL_DIR}."
read -p "Do you wish to continue? [y/N] " confirmation
if [[ ! "$confirmation" =~ ^[Yy]$ ]]; then
  echo "Installation cancelled."
  exit 1
fi

echo "Removing existing Neovim installations..."
sudo rm -rf /opt/nvim
sudo rm -rf "$INSTALL_DIR"

echo "Extracting the downloaded archive to /opt..."
sudo tar -C /opt -xzf "$NVIM_ARCHIVE"

echo "Cleaning up the downloaded archive..."
rm "$NVIM_ARCHIVE"

# Add Neovim to the PATH in ~/.bashrc if it's not already there
if ! grep -q "$BIN_DIR" ~/.bashrc; then
    echo "export PATH=\"\$PATH:${BIN_DIR}\"" >> ~/.bashrc
    echo "Added Neovim to PATH in ~/.bashrc"
else
    echo "Neovim path already exists in ~/.bashrc"
fi

# Source ~/.bashrc to update the PATH for the current session
# (Note: This may not propagate to the parent shell.)
source ~/.bashrc

# Verify Neovim installation
if command -v nvim >/dev/null 2>&1; then
    echo "Neovim installed successfully. Version: $(nvim --version | head -n1)"
else
    echo "Neovim installation failed."
    exit 1
fi

# Move the 'nvim' directory from the script's directory to ~/.config if it exists
NVIM_CONFIG_SOURCE="$SCRIPT_DIR"
NVIM_CONFIG_DEST="$HOME/.config/nvim"

if [ -d "$NVIM_CONFIG_SOURCE" ]; then
    mkdir -p "$(dirname "$NVIM_CONFIG_DEST")"
    mv "$NVIM_CONFIG_SOURCE" "$NVIM_CONFIG_DEST"
    echo "Moved 'nvim' configuration to ~/.config/nvim"
else
    echo "Source directory '$NVIM_CONFIG_SOURCE' does not exist. Skipping move."
fi
