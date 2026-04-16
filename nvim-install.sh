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
}

main "$@"
