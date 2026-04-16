#!/usr/bin/env bash
# shellcheck disable=SC2034  # forward-declared constants; used in subsequent tasks
set -euo pipefail

readonly MIN_NVIM_VERSION="0.12.0"
readonly NVIM_REPO="https://github.com/jkleinne/nvim.git"
readonly NVIM_REPO_HTTPS="https://github.com/jkleinne/nvim"
readonly NVIM_CONFIG_DIR="$HOME/.config/nvim"
readonly NVIM_INSTALL_DIR="/opt/nvim"
readonly NVIM_RELEASE_BASE="https://github.com/neovim/neovim/releases/latest/download"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_TMPDIR=""
WARNINGS=()
NEED_PATH_SETUP=false
NVIM_INSTALL_METHOD=""
OS=""
ARCH=""
PKG_MGR=""
USER_SHELL=""

# ---------------------------------------------------------------------------
# Color / output helpers
# ---------------------------------------------------------------------------

setup_colors() {
  if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]] && [[ "${TERM:-}" != "dumb" ]]; then
    BOLD="$(tput bold 2>/dev/null || printf '')"
    RESET="$(tput sgr0 2>/dev/null || printf '')"
    RED="$(tput setaf 1 2>/dev/null || printf '')"
    GREEN="$(tput setaf 2 2>/dev/null || printf '')"
    YELLOW="$(tput setaf 3 2>/dev/null || printf '')"
    BLUE="$(tput setaf 4 2>/dev/null || printf '')"
  else
    BOLD="" RESET="" RED="" GREEN="" YELLOW="" BLUE=""
  fi
}

info()    { printf '%s\n' "${BLUE}${BOLD}==>${RESET} ${BOLD}$1${RESET}"; }
success() { printf '%s\n' "${GREEN}${BOLD} ok${RESET} $1"; }
warn()    { printf '%s\n' "${YELLOW}${BOLD}  !${RESET} $1"; WARNINGS+=("$1"); }
error()   { printf '%s\n' "${RED}${BOLD}  x${RESET} $1" >&2; }
section() {
  printf '\n%s\n' "${BOLD}${BLUE}--- $1 ---${RESET}"
}

# ---------------------------------------------------------------------------
# Temp directory management and cleanup
# ---------------------------------------------------------------------------

cleanup() {
  if [[ -n "${SCRIPT_TMPDIR:-}" ]] && [[ -d "$SCRIPT_TMPDIR" ]]; then
    rm -rf "$SCRIPT_TMPDIR"
  fi
}

create_tmpdir() {
  SCRIPT_TMPDIR="$(mktemp -d)"
}

trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Platform detection
# ---------------------------------------------------------------------------

detect_os() {
  local kernel
  kernel="$(uname -s)"
  case "$kernel" in
    Darwin) OS="darwin" ;;
    Linux)  OS="linux" ;;
    *)
      error "Unsupported operating system: $kernel"
      error "This script supports macOS and Linux."
      exit 1
      ;;
  esac
}

detect_arch() {
  local machine
  machine="$(uname -m)"

  if [[ "$OS" == "darwin" ]]; then
    if sysctl -n hw.optional.arm64 2>/dev/null | grep -q '1'; then
      ARCH="arm64"
      return
    fi
  fi

  case "$machine" in
    x86_64 | amd64) ARCH="x86_64" ;;
    arm64 | aarch64) ARCH="arm64" ;;
    *)
      error "Unsupported architecture: $machine"
      exit 1
      ;;
  esac
}

detect_pkg_manager() {
  if [[ "$OS" == "darwin" ]]; then
    if command -v brew >/dev/null 2>&1; then
      PKG_MGR="brew"
    else
      error "Homebrew is required on macOS but was not found."
      error "Install it from https://brew.sh and re-run this script."
      exit 1
    fi
    return
  fi

  local mgr
  for mgr in apt-get dnf pacman apk; do
    if command -v "$mgr" >/dev/null 2>&1; then
      PKG_MGR="$mgr"
      return
    fi
  done

  error "No supported package manager found."
  error "Supported: apt-get (Debian/Ubuntu), dnf (Fedora/RHEL), pacman (Arch), apk (Alpine)."
  exit 1
}

detect_shell() {
  local shell_name
  shell_name="$(basename "${SHELL:-/bin/sh}")"
  case "$shell_name" in
    bash) USER_SHELL="bash" ;;
    zsh)  USER_SHELL="zsh" ;;
    fish) USER_SHELL="fish" ;;
    *)    USER_SHELL="posix" ;;
  esac
}

version_gte() {
  local have="$1" need="$2"
  local have_major have_minor have_patch
  local need_major need_minor need_patch

  IFS='.' read -r have_major have_minor have_patch <<< "$have"
  IFS='.' read -r need_major need_minor need_patch <<< "$need"

  have_patch="${have_patch:-0}"
  need_patch="${need_patch:-0}"

  local have_num=$(( have_major * 1000000 + have_minor * 1000 + have_patch ))
  local need_num=$(( need_major * 1000000 + need_minor * 1000 + need_patch ))

  (( have_num >= need_num ))
}

get_nvim_version() {
  nvim --version 2>/dev/null | head -n1 | sed 's/^NVIM v//'
}

confirm_proceed() {
  section "Bootstrap Plan"
  printf '  %-18s %s\n' "OS:" "$OS"
  printf '  %-18s %s\n' "Architecture:" "$ARCH"
  printf '  %-18s %s\n' "Package manager:" "$PKG_MGR"
  printf '  %-18s %s\n' "Shell:" "$USER_SHELL"
  printf '\n'
  info "This script will:"
  printf '  %s\n' "1. Install Neovim 0.12+ (prefer $PKG_MGR, tarball fallback)"
  printf '  %s\n' "2. Install build tools, runtimes, formatters, linters, TUI tools"
  printf '  %s\n' "3. Clone config to $NVIM_CONFIG_DIR"
  printf '\n'

  local confirmation
  read -rp "Proceed? [y/N] " confirmation
  if [[ ! "$confirmation" =~ ^[Yy]$ ]]; then
    info "Cancelled."
    exit 0
  fi
}

# ---------------------------------------------------------------------------
# Neovim installation
# ---------------------------------------------------------------------------

pkg_install_neovim() {
  case "$PKG_MGR" in
    brew)    brew install neovim ;;
    apt-get) sudo apt-get update -qq && sudo apt-get install -y neovim ;;
    dnf)     sudo dnf install -y neovim ;;
    pacman)  sudo pacman -S --noconfirm neovim ;;
    apk)     sudo apk add neovim ;;
  esac
}

install_neovim_tarball() {
  local os_name="$OS"
  if [[ "$OS" == "darwin" ]]; then
    os_name="macos"
  fi
  local filename="nvim-${os_name}-${ARCH}.tar.gz"
  local url="${NVIM_RELEASE_BASE}/${filename}"

  create_tmpdir
  local tarball="${SCRIPT_TMPDIR}/${filename}"

  # Neovim releases do not publish SHA256 checksum files.
  # HTTPS from github.com is the trust anchor (same as Homebrew formulae downloads).
  info "Downloading Neovim from GitHub releases..."
  if ! curl -fSL --progress-bar -o "$tarball" "$url"; then
    error "Failed to download Neovim from $url"
    exit 1
  fi

  if [[ ! -s "$tarball" ]]; then
    error "Downloaded file is empty: $tarball"
    exit 1
  fi

  success "Downloaded $(du -h "$tarball" | cut -f1 | xargs)"

  if [[ -d "$NVIM_INSTALL_DIR" ]]; then
    warn "Existing installation at $NVIM_INSTALL_DIR will be replaced."
    local confirm_remove
    read -rp "  Remove $NVIM_INSTALL_DIR? [y/N] " confirm_remove
    if [[ ! "$confirm_remove" =~ ^[Yy]$ ]]; then
      error "Cannot install without removing existing directory."
      exit 1
    fi
    sudo rm -rf "$NVIM_INSTALL_DIR"
  fi

  info "Extracting to $NVIM_INSTALL_DIR (requires sudo)..."
  sudo mkdir -p "$NVIM_INSTALL_DIR"
  sudo tar -C "$NVIM_INSTALL_DIR" --strip-components=1 -xzf "$tarball"

  if [[ -w "/usr/local/bin" ]] || sudo test -w "/usr/local/bin"; then
    sudo ln -sf "${NVIM_INSTALL_DIR}/bin/nvim" /usr/local/bin/nvim
    success "Symlinked nvim to /usr/local/bin/nvim"
  else
    NEED_PATH_SETUP=true
  fi

  NVIM_INSTALL_METHOD="tarball"
}

install_neovim() {
  section "Neovim"

  if command -v nvim >/dev/null 2>&1; then
    local current_version
    current_version="$(get_nvim_version)"
    if version_gte "$current_version" "$MIN_NVIM_VERSION"; then
      success "Neovim $current_version already installed (>= $MIN_NVIM_VERSION)"
      NVIM_INSTALL_METHOD="existing"
      return
    fi
    warn "Neovim $current_version found, but $MIN_NVIM_VERSION+ is required."
  fi

  info "Installing Neovim via $PKG_MGR..."
  if pkg_install_neovim; then
    local pkg_version
    pkg_version="$(get_nvim_version)"
    if version_gte "$pkg_version" "$MIN_NVIM_VERSION"; then
      success "Neovim $pkg_version installed via $PKG_MGR"
      NVIM_INSTALL_METHOD="$PKG_MGR"
      return
    fi
    warn "Package manager installed Neovim $pkg_version, but $MIN_NVIM_VERSION+ is required."
  else
    warn "Package manager install failed. Falling back to GitHub release."
  fi

  install_neovim_tarball
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

usage() {
  cat <<'EOF'
Usage: nvim-install.sh [--help]

Cross-platform bootstrap script for Neovim 0.12+ with full dev environment.

Installs Neovim, build tools, runtimes (Node, Go), formatters, linters,
and TUI tools. Clones the Neovim configuration to ~/.config/nvim.

Supported platforms:
  macOS        (Homebrew)
  Debian/Ubuntu (apt)
  Fedora/RHEL  (dnf)
  Arch Linux   (pacman)
  Alpine       (apk)
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  setup_colors

  if [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
    usage
    exit 0
  fi

  info "Neovim bootstrap starting"

  detect_os
  detect_arch
  detect_pkg_manager
  detect_shell
  confirm_proceed
  install_neovim
}

main "$@"
