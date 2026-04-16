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

  have_patch="${have_patch:-0}"; have_patch="${have_patch%%[-+]*}"
  need_patch="${need_patch:-0}"; need_patch="${need_patch%%[-+]*}"

  local have_num=$(( have_major * 1000000 + have_minor * 1000 + have_patch ))
  local need_num=$(( need_major * 1000000 + need_minor * 1000 + need_patch ))

  [[ $have_num -ge $need_num ]]
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
# Dependency installation helpers
# ---------------------------------------------------------------------------

pkg_install() {
  case "$PKG_MGR" in
    brew)    brew install "$@" ;;
    apt-get) sudo apt-get install -y "$@" ;;
    dnf)     sudo dnf install -y "$@" ;;
    pacman)  sudo pacman -S --noconfirm "$@" ;;
    apk)     sudo apk add "$@" ;;
  esac
}

install_hard() {
  local label="$1"; shift
  info "Installing $label..."
  if ! pkg_install "$@"; then
    error "Failed to install $label. Cannot continue."
    exit 1
  fi
  success "$label"
}

install_soft() {
  local name="$1"; shift
  if command -v "$name" >/dev/null 2>&1; then
    success "$name (already installed)"
    return
  fi
  if "$@"; then
    success "$name"
  else
    warn "$name: install failed, skipping"
  fi
}

# ---------------------------------------------------------------------------
# Dependency categories
# ---------------------------------------------------------------------------

install_build_tools() {
  section "Build Tools"

  if [[ "$OS" == "darwin" ]]; then
    if xcode-select -p >/dev/null 2>&1; then
      success "Xcode Command Line Tools (already installed)"
    else
      info "Installing Xcode Command Line Tools..."
      xcode-select --install 2>/dev/null || true
      warn "Xcode CLT installer launched. Re-run this script after installation completes."
      exit 0
    fi
    return
  fi

  case "$PKG_MGR" in
    apt-get)
      install_hard "build tools" build-essential curl tar gzip
      ;;
    dnf)
      install_hard "build tools" gcc make curl tar gzip
      ;;
    pacman)
      install_hard "build tools" base-devel curl
      ;;
    apk)
      install_hard "build tools" build-base curl tar
      ;;
  esac
}

install_core_tools() {
  section "Core Tools"
  install_hard "core tools" ripgrep git
}

install_runtimes() {
  section "Runtimes"

  case "$PKG_MGR" in
    brew)
      install_hard "runtimes" node go
      ;;
    apt-get)
      install_hard "runtimes" nodejs npm golang
      ;;
    dnf)
      install_hard "runtimes" nodejs npm golang
      ;;
    pacman)
      install_hard "runtimes" nodejs npm go
      ;;
    apk)
      install_hard "runtimes" nodejs npm go
      ;;
  esac
}

install_formatters() {
  section "Formatters"

  case "$PKG_MGR" in
    brew)
      install_soft stylua brew install stylua
      install_soft shfmt brew install shfmt
      install_soft prettier brew install prettier
      install_soft black brew install black
      ;;
    pacman)
      install_soft stylua sudo pacman -S --noconfirm stylua
      install_soft shfmt sudo pacman -S --noconfirm shfmt
      install_soft prettier npm install -g prettier
      install_soft black pip install --user black
      ;;
    *)
      install_soft prettier npm install -g prettier
      install_soft black pip install --user black
      if command -v go >/dev/null 2>&1; then
        install_soft shfmt go install mvdan.cc/sh/v3/cmd/shfmt@latest
      else
        warn "shfmt: requires Go (skipping)"
      fi
      if command -v cargo >/dev/null 2>&1; then
        install_soft stylua cargo install stylua
      else
        warn "stylua: no cargo on PATH, install manually from https://github.com/JohnnyMorganz/StyLua/releases"
      fi
      ;;
  esac
}

install_linters() {
  section "Linters"

  case "$PKG_MGR" in
    brew)
      local linters=(selene hadolint shellcheck yamllint tflint golangci-lint ruff)
      for l in "${linters[@]}"; do
        install_soft "$l" brew install "$l"
      done
      ;;
    pacman)
      install_soft shellcheck sudo pacman -S --noconfirm shellcheck
      install_soft yamllint pip install --user yamllint
      install_soft ruff pip install --user ruff
      if command -v go >/dev/null 2>&1; then
        install_soft golangci-lint go install github.com/golangci/golangci-lint/cmd/golangci-lint@latest
      fi
      if command -v cargo >/dev/null 2>&1; then
        install_soft selene cargo install selene
      fi
      warn "hadolint, tflint: install manually (not in pacman repos)"
      ;;
    *)
      case "$PKG_MGR" in
        apt-get) install_soft shellcheck sudo apt-get install -y shellcheck ;;
        dnf)     install_soft shellcheck sudo dnf install -y shellcheck ;;
        apk)     install_soft shellcheck sudo apk add shellcheck ;;
      esac
      install_soft yamllint pip install --user yamllint
      install_soft ruff pip install --user ruff
      if command -v go >/dev/null 2>&1; then
        install_soft golangci-lint go install github.com/golangci/golangci-lint/cmd/golangci-lint@latest
      fi
      warn "selene, hadolint, tflint: install manually (not in distro repos)"
      ;;
  esac
}

install_tui_tools() {
  section "TUI Tools"

  case "$PKG_MGR" in
    brew)
      install_soft lazygit brew install lazygit
      install_soft lazydocker brew install lazydocker
      install_soft lazysql brew install lazysql
      install_soft fortune brew install fortune
      if command -v pipx >/dev/null 2>&1; then
        install_soft posting pipx install posting
      else
        install_soft posting pip install --user posting
      fi
      ;;
    pacman)
      install_soft lazygit sudo pacman -S --noconfirm lazygit
      if command -v go >/dev/null 2>&1; then
        install_soft lazydocker go install github.com/jesseduffield/lazydocker@latest
        install_soft lazysql go install github.com/jorgerojas26/lazysql@latest
      fi
      install_soft fortune sudo pacman -S --noconfirm fortune-mod
      if command -v pipx >/dev/null 2>&1; then
        install_soft posting pipx install posting
      else
        install_soft posting pip install --user posting
      fi
      ;;
    *)
      if command -v go >/dev/null 2>&1; then
        install_soft lazygit go install github.com/jesseduffield/lazygit@latest
        install_soft lazydocker go install github.com/jesseduffield/lazydocker@latest
        install_soft lazysql go install github.com/jorgerojas26/lazysql@latest
      else
        warn "lazygit, lazydocker, lazysql: requires Go (skipping)"
      fi
      case "$PKG_MGR" in
        apt-get) install_soft fortune sudo apt-get install -y fortune-mod ;;
        dnf)     install_soft fortune sudo dnf install -y fortune-mod ;;
        apk)     install_soft fortune sudo apk add fortune-mod ;;
      esac
      if command -v pipx >/dev/null 2>&1; then
        install_soft posting pipx install posting
      else
        install_soft posting pip install --user posting
      fi
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Dependency orchestrator
# ---------------------------------------------------------------------------

install_deps() {
  if [[ "$PKG_MGR" == "apt-get" ]]; then
    info "Updating package lists..."
    sudo apt-get update -qq
  fi

  install_build_tools
  install_core_tools
  install_runtimes
  install_formatters
  install_linters
  install_tui_tools
}

# ---------------------------------------------------------------------------
# Config setup
# ---------------------------------------------------------------------------

setup_config() {
  section "Configuration"

  if [[ -d "$NVIM_CONFIG_DIR" ]]; then
    local existing_remote
    existing_remote="$(git -C "$NVIM_CONFIG_DIR" remote get-url origin 2>/dev/null || echo "")"

    if [[ "$existing_remote" == "$NVIM_REPO" ]] || [[ "$existing_remote" == "$NVIM_REPO_HTTPS" ]]; then
      success "Config already present at $NVIM_CONFIG_DIR"
      return
    fi

    local backup
    backup="${NVIM_CONFIG_DIR}.bak.$(date +%s)"
    warn "Existing config at $NVIM_CONFIG_DIR is not this repo."
    info "Backing up to $backup"
    if ! mv "$NVIM_CONFIG_DIR" "$backup"; then
      error "Failed to back up existing config from $NVIM_CONFIG_DIR to $backup"
      exit 1
    fi
    success "Backed up existing config"
  fi

  local script_remote
  script_remote="$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null || echo "")"

  if [[ "$script_remote" == "$NVIM_REPO" ]] || [[ "$script_remote" == "$NVIM_REPO_HTTPS" ]]; then
    local resolved_script_dir
    resolved_script_dir="$(cd "$SCRIPT_DIR" && pwd -P)"
    local resolved_config_dir
    resolved_config_dir="$(cd "$NVIM_CONFIG_DIR" 2>/dev/null && pwd -P || echo "$NVIM_CONFIG_DIR")"

    if [[ "$resolved_script_dir" == "$resolved_config_dir" ]]; then
      success "Running from $NVIM_CONFIG_DIR, no clone needed"
      return
    fi

    info "This script is inside a clone of the config repo at $SCRIPT_DIR."
    info "Clone it to $NVIM_CONFIG_DIR or move it there manually."
    warn "Skipping automatic config setup to avoid the old self-move bug."
    return
  fi

  info "Cloning config to $NVIM_CONFIG_DIR..."
  if ! mkdir -p "$(dirname "$NVIM_CONFIG_DIR")"; then
    error "Cannot create parent directory for $NVIM_CONFIG_DIR"
    exit 1
  fi
  if ! git clone "$NVIM_REPO" "$NVIM_CONFIG_DIR"; then
    error "Failed to clone config repo to $NVIM_CONFIG_DIR"
    exit 1
  fi
  success "Config cloned to $NVIM_CONFIG_DIR"
}

# ---------------------------------------------------------------------------
# PATH setup (tarball installs only)
# ---------------------------------------------------------------------------

setup_path() {
  if [[ "$NEED_PATH_SETUP" != true ]]; then
    return
  fi

  section "PATH"

  local nvim_bin="${NVIM_INSTALL_DIR}/bin"
  local rc_file=""
  local path_line=""

  case "$USER_SHELL" in
    bash)
      if [[ "$OS" == "darwin" ]] && [[ -f "$HOME/.bash_profile" ]]; then
        rc_file="$HOME/.bash_profile"
      else
        rc_file="$HOME/.bashrc"
      fi
      path_line="export PATH=\"\$PATH:${nvim_bin}\""
      ;;
    zsh)
      rc_file="${ZDOTDIR:-$HOME}/.zshenv"
      path_line="export PATH=\"\$PATH:${nvim_bin}\""
      ;;
    fish)
      rc_file="${HOME}/.config/fish/config.fish"
      path_line="fish_add_path ${nvim_bin}"
      ;;
    posix)
      rc_file="$HOME/.profile"
      path_line="export PATH=\"\$PATH:${nvim_bin}\""
      ;;
  esac

  if [[ -z "$rc_file" ]]; then
    warn "Could not determine rc file for shell: $USER_SHELL"
    info "Add this to your shell config manually:"
    printf '  %s\n' "$path_line"
    return
  fi

  if [[ "$rc_file" != "$HOME/.profile" ]] && [[ ! -f "$rc_file" ]]; then
    warn "$rc_file does not exist."
    info "Add this to your shell config manually:"
    printf '  %s\n' "$path_line"
    return
  fi

  if grep -qF "$nvim_bin" "$rc_file" 2>/dev/null; then
    success "PATH entry already in $rc_file"
    return
  fi

  printf '\n# Neovim (added by nvim-install.sh)\n%s\n' "$path_line" >> "$rc_file"
  success "Added PATH entry to $rc_file"
  info "Run 'source $rc_file' or open a new terminal to apply."
}

# ---------------------------------------------------------------------------
# Verification and summary
# ---------------------------------------------------------------------------

verify_install() {
  section "Verification"

  if ! command -v nvim >/dev/null 2>&1; then
    error "nvim not found on PATH after installation."
    if [[ "$NEED_PATH_SETUP" == true ]]; then
      error "You may need to open a new terminal or source your shell config."
    fi
    exit 1
  fi

  local installed_version
  installed_version="$(get_nvim_version)"
  if ! version_gte "$installed_version" "$MIN_NVIM_VERSION"; then
    error "Neovim $installed_version is installed, but $MIN_NVIM_VERSION+ is required."
    exit 1
  fi
  success "Neovim $installed_version on PATH"

  if nvim --headless "+qa" 2>/dev/null; then
    success "Config loads cleanly"
  else
    warn "Config reported errors (expected on first run before plugins sync)"
    warn "Launch nvim interactively to complete plugin installation"
  fi
}

print_summary() {
  local installed_version
  installed_version="$(get_nvim_version 2>/dev/null || echo "unknown")"

  printf '\n'
  printf '%s\n' "${BOLD}${GREEN}====================================${RESET}"
  printf '%s\n' "${BOLD}${GREEN}  Neovim Bootstrap Complete${RESET}"
  printf '%s\n' "${BOLD}${GREEN}====================================${RESET}"
  printf '  %-18s %s\n' "Version:" "$installed_version"
  printf '  %-18s %s\n' "Install method:" "$NVIM_INSTALL_METHOD"
  printf '  %-18s %s\n' "Config:" "$NVIM_CONFIG_DIR"

  if [[ "$NEED_PATH_SETUP" == true ]]; then
    printf '  %-18s %s\n' "PATH updated:" "yes (restart shell to apply)"
  fi

  if [[ ${#WARNINGS[@]} -gt 0 ]]; then
    printf '\n  %s\n' "${YELLOW}${BOLD}Warnings:${RESET}"
    for w in "${WARNINGS[@]}"; do
      printf '    %s %s\n' "${YELLOW}!${RESET}" "$w"
    done
  fi

  printf '%s\n' "${BOLD}${GREEN}====================================${RESET}"
  printf '\n'
  info "Launch nvim to complete plugin installation."
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
  install_deps
  setup_config
  setup_path
  verify_install
  print_summary
}

main "$@"
