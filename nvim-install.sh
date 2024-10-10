#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

NVIM_URL="https://github.com/neovim/neovim/releases/latest/download/nvim-linux64.tar.gz"
NVIM_ARCHIVE="nvim-linux64.tar.gz"
INSTALL_DIR="/opt/nvim-linux64"
BIN_DIR="$INSTALL_DIR/bin"

# Determine the directory where the script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# Because of how scripts are executed in a subshell, this will not propagate to
# the parent shell unless its explicitly specified to run the script in the current shell
# e.g. source <script.sh> or . <script.sh>
source ~/.bashrc

# Verify Neovim installation
if command -v nvim >/dev/null 2>&1; then
    echo "Neovim installed successfully. Version: $(nvim --version | head -n1)"
else
    echo "Neovim installation failed."
    exit 1
fi

# Move the 'nvim' directory from the script's directory to ~/.config
NVIM_CONFIG_SOURCE="$SCRIPT_DIR"
NVIM_CONFIG_DEST="$HOME/.config/nvim"

# Check if the source directory exists
if [ -d "$NVIM_CONFIG_SOURCE" ]; then
    # Create the destination directory if it doesn't exist
    mkdir -p "$(dirname "$NVIM_CONFIG_DEST")"
    
    # Move the nvim directory
    mv "$NVIM_CONFIG_SOURCE" "$NVIM_CONFIG_DEST"
    echo "Moved 'nvim' configuration to ~/.config/nvim"
else
    echo "Source directory '$NVIM_CONFIG_SOURCE' does not exist. Skipping move."
fi
