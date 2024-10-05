#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

NVIM_URL="https://github.com/neovim/neovim/releases/latest/download/nvim-linux64.tar.gz"
NVIM_ARCHIVE="nvim-linux64.tar.gz"
INSTALL_DIR="/opt/nvim-linux64"
BIN_DIR="$INSTALL_DIR/bin"

# Download the latest Neovim release
curl -LO "$NVIM_URL" 

# Remove any existing Neovim installation
sudo rm -rf /opt/nvim
sudo rm -rf "$INSTALL_DIR"

# Extract the downloaded archive to /opt
sudo tar -C /opt -xzf "$NVIM_ARCHIVE" 

# Remove the downloaded archive to clean up
rm "$NVIM_ARCHIVE"

# Add Neovim to the PATH in ~/.bashrc if it's not already there
if ! grep -q "$BIN_DIR" ~/.bashrc; then
    echo 'export PATH="$PATH:/opt/nvim-linux64/bin"' >> ~/.bashrc
    echo "Added Neovim to PATH in ~/.bashrc"
else
    echo "Neovim path already exists in ~/.bashrc"
fi

# Source the updated ~/.bashrc to apply changes immediately
source ~/.bashrc

# Verify Neovim installation
if command -v nvim >/dev/null 2>&1; then
    echo "Neovim installed successfully. Version: $(nvim --version | head -n1)"
else
    echo "Neovim installation failed."
    exit 1
fi
