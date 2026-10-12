#!/usr/bin/env bash
set -euo pipefail

readonly MIN_NVIM_VERSION="0.12.0"
readonly NVIM_REPO_SLUG="jkleinne/nvim"
readonly NVIM_REPO="https://github.com/${NVIM_REPO_SLUG}.git"
readonly NVIM_CONFIG_DIR="$HOME/.config/nvim"
readonly NVIM_INSTALL_DIR="/opt/nvim"
readonly NVIM_RELEASE_BASE="https://github.com/neovim/neovim/releases/latest/download"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_TMPDIR=""
CLONE_STAGING=""
WARNINGS=()
PATH_WARNED_DIRS=()
NEED_PATH_SETUP=false
NVIM_INSTALL_METHOD=""
OS=""
ARCH=""
PKG_MGR=""
PKG_TIER=""
PKG_READY=false
SUDO_USED=false
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

# Ask a y/N question; anything but y/Y, including end of input, counts as no
confirm() {
  local reply
  read -rp "$1 [y/N] " reply || return 1
  [[ "$reply" =~ ^[Yy]$ ]]
}

# ---------------------------------------------------------------------------
# Temp directory management and cleanup
# ---------------------------------------------------------------------------

cleanup() {
  if [[ -n "${SCRIPT_TMPDIR:-}" ]] && [[ -d "$SCRIPT_TMPDIR" ]]; then
    rm -rf "$SCRIPT_TMPDIR"
  fi
  if [[ -n "${CLONE_STAGING:-}" ]] && [[ -d "$CLONE_STAGING" ]]; then
    rm -rf "$CLONE_STAGING"
  fi
  # Runs on every exit, errors and signals included, so a sudo ticket this script took never outlives it
  if [[ "${SUDO_USED:-}" == true ]]; then
    sudo -k 2>/dev/null || true
  fi
}

create_tmpdir() {
  SCRIPT_TMPDIR="$(mktemp -d)"
}

# ---------------------------------------------------------------------------
# Platform detection
# ---------------------------------------------------------------------------

require_non_root() {
  if [[ "$EUID" -eq 0 ]]; then
    error "Do not run this script as root or with sudo."
    error "It calls sudo itself for system packages, and user-level tools must install into your home directory."
    exit 1
  fi
}

require_sudo() {
  if ! command -v sudo >/dev/null 2>&1; then
    error "sudo is required to install system packages, but it is not on PATH."
    exit 1
  fi
}

detect_os() {
  local kernel
  kernel="$(uname -s)"
  if [[ "$kernel" != "Linux" ]]; then
    error "Unsupported operating system: $kernel"
    error "This script supports Linux only (Arch Linux first-class, other distros best-effort)."
    exit 1
  fi
  OS="linux"
}

detect_arch() {
  local machine
  machine="$(uname -m)"

  case "$machine" in
    x86_64 | amd64) ARCH="x86_64" ;;
    arm64 | aarch64) ARCH="arm64" ;;
    *)
      error "Unsupported architecture: $machine"
      exit 1
      ;;
  esac
}

# Print the package manager for the distro named by os-release ID and ID_LIKE, or nothing.
# $1 is the os-release file (default /etc/os-release).
os_release_pkg_mgr() {
  local file="${1:-/etc/os-release}"
  local ids
  if [[ ! -r "$file" ]]; then
    return 0
  fi
  # Root-owned system data; sourced in a subshell (as get.docker.com does) so nothing leaks
  # shellcheck source=/dev/null  # os-release is data, not a script to lint
  ids="$(. "$file" && printf ' %s %s ' "${ID:-}" "${ID_LIKE:-}")" || return 0
  case "$ids" in
    *" arch "*) printf '%s\n' pacman ;;
    *" debian "* | *" ubuntu "*) printf '%s\n' apt-get ;;
    *" fedora "* | *" rhel "* | *" centos "*) printf '%s\n' dnf ;;
    *" alpine "*) printf '%s\n' apk ;;
  esac
}

detect_pkg_manager() {
  local mgr
  # os-release first: binaries alone mislead, since Debian and Fedora can ship a pacman
  # binary and Arch's repos ship apt, dnf and apk-tools. Probe only when os-release names
  # no supported distro or its manager is missing (pacman first: Arch is first-class).
  mgr="$(os_release_pkg_mgr)"
  if [[ -n "$mgr" ]] && command -v "$mgr" >/dev/null 2>&1; then
    PKG_MGR="$mgr"
  else
    for mgr in pacman apt-get dnf apk; do
      if command -v "$mgr" >/dev/null 2>&1; then
        PKG_MGR="$mgr"
        break
      fi
    done
  fi

  if [[ -z "$PKG_MGR" ]]; then
    error "No supported package manager found."
    error "Supported: pacman (Arch Linux, first-class); apt-get, dnf, apk (best-effort)."
    exit 1
  fi

  if [[ "$PKG_MGR" == "pacman" ]]; then
    PKG_TIER="first-class"
  else
    PKG_TIER="best-effort"
  fi
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
  printf '  %-18s %s\n' "Support tier:" "$PKG_TIER"
  printf '  %-18s %s\n' "Shell:" "$USER_SHELL"
  printf '\n'
  if [[ "$PKG_TIER" == "best-effort" ]]; then
    info "$PKG_MGR is best-effort: tools missing from its repos are installed with go install or uv tool install when available (latest upstream), otherwise listed as manual steps at the end."
    printf '\n'
  fi
  info "This script will:"
  if [[ "$PKG_MGR" == "pacman" ]]; then
    printf '  %s\n' "0. Upgrade the system first (pacman -Syu, with pacman's own prompt) if anything needs installing"
  fi
  printf '  %s\n' "1. Install Neovim 0.12+ (prefer $PKG_MGR, tarball fallback)"
  printf '  %s\n' "2. Install build tools, clipboard, runtimes, language servers, formatters, linters, TUI tools"
  printf '  %s\n' "3. Clone config to $NVIM_CONFIG_DIR"
  printf '\n'

  if ! confirm "Proceed?"; then
    info "Cancelled."
    exit 0
  fi
}

# ---------------------------------------------------------------------------
# Neovim installation
# ---------------------------------------------------------------------------

install_neovim_tarball() {
  local filename="nvim-${OS}-${ARCH}.tar.gz"
  local url="${NVIM_RELEASE_BASE}/${filename}"

  create_tmpdir
  local tarball="${SCRIPT_TMPDIR}/${filename}"

  # Neovim releases do not publish SHA256 checksum files.
  # HTTPS from github.com is the trust anchor.
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
    if ! confirm "  Remove $NVIM_INSTALL_DIR?"; then
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
  if pkg_install neovim; then
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

# Runs once, right before the first package install: checks that sudo exists and its credentials (fails
# fast on a wrong password, and caches them), then refreshes package metadata. On Arch that is a full
# system upgrade, because installing new packages against a freshly synced database without upgrading
# is a partial upgrade, which Arch does not support. pacman shows its own list and asks before changing
# anything. A machine with everything installed never gets here, so it needs no sudo at all.
pkg_ready_once() {
  if [[ "$PKG_READY" == true ]]; then
    return
  fi
  require_sudo
  if ! sudo -v; then
    error "sudo authentication failed."
    exit 1
  fi
  SUDO_USED=true
  case "$PKG_MGR" in
    pacman)
      info "Upgrading the system first (pacman -Syu)..."
      if ! sudo pacman -Syu; then
        error "System upgrade declined or failed; installing packages now would be a partial upgrade."
        error "Run 'sudo pacman -Syu' yourself, then run this script again."
        exit 1
      fi
      ;;
    # The refresh is best effort on these distros; the warning reaches the summary
    apt-get)
      info "Updating package lists..."
      sudo apt-get update -qq || warn "apt-get update failed; installing from the existing package lists"
      ;;
    apk)
      info "Updating package index..."
      sudo apk update || warn "apk update failed; installing from the existing package index"
      ;;
    dnf) ;;
  esac
  PKG_READY=true
}

pkg_is_installed() {
  case "$PKG_MGR" in
    apt-get) dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed' ;;
    dnf)     rpm -q "$1" &>/dev/null ;;
    pacman)  pacman -Q "$1" &>/dev/null ;;
    apk)     apk info -e "$1" &>/dev/null ;;
  esac
}

pkg_install() {
  pkg_ready_once
  case "$PKG_MGR" in
    apt-get) sudo apt-get install -y "$@" ;;
    dnf)     sudo dnf install -y "$@" ;;
    pacman)  sudo pacman -S --noconfirm "$@" ;;
    apk)     sudo apk add "$@" ;;
  esac
}

# Install packages by package name, skipping installed ones.
# "required" exits on failure; "optional" retries one by one and warns.
install_pkgs() {
  local mode="$1" label="$2"
  shift 2

  case "$mode" in
    required | optional) ;;
    *)
      error "install_pkgs: unknown mode '$mode' (expected required or optional)"
      exit 1
      ;;
  esac

  local missing=() pkg
  for pkg in "$@"; do
    if ! pkg_is_installed "$pkg"; then
      missing+=("$pkg")
    fi
  done

  if [[ ${#missing[@]} -eq 0 ]]; then
    for pkg in "$@"; do
      success "$pkg (already installed)"
    done
    return
  fi

  info "Installing $label..."
  if pkg_install "${missing[@]}"; then
    success "$label"
    return
  fi

  if [[ "$mode" == "required" ]]; then
    error "Failed to install $label. Cannot continue."
    exit 1
  fi

  if [[ ${#missing[@]} -eq 1 ]]; then
    warn "${missing[0]}: install failed, skipping"
    return
  fi

  # One bad package aborts the whole transaction, so retry individually
  for pkg in "${missing[@]}"; do
    if pkg_install "$pkg"; then
      success "$pkg"
    else
      warn "$pkg: install failed, skipping"
    fi
  done
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

# GOBIN, else the first GOPATH entry's bin dir (go install writes there). Fails when go env does.
go_bin_dir() {
  local dir
  dir="$(go env GOBIN)" || return 1
  if [[ -z "$dir" ]]; then
    dir="$(go env GOPATH)" || return 1
    if [[ -z "$dir" ]]; then
      return 1
    fi
    dir="${dir%%:*}/bin"
  fi
  printf '%s\n' "$dir"
}

# The line that appends $1 to PATH in the user's shell config. Appending keeps user dirs from
# shadowing system binaries; fish needs --path, or fish_add_path puts the dir ahead of the system paths.
path_append_line() {
  if [[ "$USER_SHELL" == fish ]]; then
    printf 'fish_add_path --append --path %s\n' "$1"
  else
    # shellcheck disable=SC2016  # $PATH is literal on purpose: the line goes into the user's shell config
    printf 'export PATH="$PATH:%s"\n' "$1"
  fi
}

warn_if_not_on_path() {
  local dir="$1" seen
  if [[ -z "$dir" ]]; then
    return
  fi
  case ":$PATH:" in
    *":$dir:"*) return ;;
  esac
  for seen in "${PATH_WARNED_DIRS[@]}"; do
    if [[ "$seen" == "$dir" ]]; then
      return
    fi
  done
  PATH_WARNED_DIRS+=("$dir")
  warn "$dir is not on PATH; add this to your shell config: $(path_append_line "$dir")"
}

# Forget the sudo ticket this script took for package installs, once they are done, so the go install
# and uv tool install runs that follow never inherit it
drop_sudo_ticket() {
  if [[ "$SUDO_USED" == true ]]; then
    sudo -k
    SUDO_USED=false
  fi
}

# The next steps clone the config and launch Neovim, which installs plugins and runs their build steps,
# so drop any cached sudo credentials, including ones from before this run (for example the README's
# own 'sudo pacman -S' step); sudo -k never prompts. This is stricter than installers that drop only
# the tickets they created, because this script itself starts third-party build code.
forget_sudo_credentials() {
  if command -v sudo >/dev/null 2>&1; then
    sudo -k
  fi
}

# For go install / uv tool install: the binary lands in a user bin dir that may
# not be on PATH, so check that dir too and warn when the binary there is unreachable.
install_user_tool() {
  local name="$1" bin_dir="$2"
  shift 2
  if [[ -x "$bin_dir/$name" ]]; then
    success "$name (already installed in $bin_dir)"
  else
    install_soft "$name" "$@"
  fi
  if [[ -x "$bin_dir/$name" ]]; then
    warn_if_not_on_path "$bin_dir"
  fi
}

# Best-effort distros: Python CLI tools go into isolated uv environments
# (PEP 668 blocks user-site installs on most distros).
install_python_tool() {
  local name="$1" bin_dir
  if ! command -v uv >/dev/null 2>&1; then
    warn "$name: install uv, then run: uv tool install $name"
    return
  fi
  if ! bin_dir="$(uv tool dir --bin)" || [[ -z "$bin_dir" ]]; then
    warn "$name: could not resolve uv's tool bin dir; run: uv tool install $name"
    return
  fi
  install_user_tool "$name" "$bin_dir" uv tool install "$name"
}

# Best-effort distros: Go CLI tools go into Go's user bin dir.
install_go_tool() {
  local name="$1" module="$2" bin_dir
  if ! command -v go >/dev/null 2>&1; then
    warn "$name: install Go, then run: go install $module"
    return
  fi
  if ! bin_dir="$(go_bin_dir)"; then
    warn "$name: could not resolve Go's bin dir; run: go install $module"
    return
  fi
  install_user_tool "$name" "$bin_dir" go install "$module"
}

# Warn once, listing the tools that are not on PATH and need a manual install.
warn_manual() {
  local missing=() tool list
  for tool in "$@"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      missing+=("$tool")
    fi
  done
  if [[ ${#missing[@]} -eq 0 ]]; then
    return
  fi
  printf -v list '%s, ' "${missing[@]}"
  warn "${list%, }: install manually"
}

# ---------------------------------------------------------------------------
# Dependency categories
# ---------------------------------------------------------------------------

install_build_tools() {
  section "Build Tools"

  case "$PKG_MGR" in
    apt-get) install_pkgs required "build tools" build-essential curl tar gzip unzip ;;
    dnf)     install_pkgs required "build tools" gcc make curl tar gzip unzip ;;
    pacman)  install_pkgs required "build tools" base-devel curl unzip ;;
    apk)     install_pkgs required "build tools" build-base curl tar unzip ;;
  esac
}

install_core_tools() {
  section "Core Tools"
  install_pkgs required "core tools" ripgrep git
}

install_clipboard() {
  section "Clipboard"

  if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
    install_pkgs optional "clipboard (Wayland)" wl-clipboard
  elif [[ -n "${DISPLAY:-}" ]]; then
    install_pkgs optional "clipboard (X11)" xclip
  else
    warn "No graphical session detected: install wl-clipboard (Wayland) or xclip (X11) for system clipboard support"
  fi
}

install_runtimes() {
  section "Runtimes"

  case "$PKG_MGR" in
    apt-get | dnf) install_pkgs required "runtimes" nodejs golang ;;
    pacman | apk)  install_pkgs required "runtimes" nodejs go ;;
  esac
}

install_language_servers() {
  section "Language Servers"

  # Node-based servers come from the system; Mason installs the native ones on first launch
  case "$PKG_MGR" in
    pacman)
      # Keep in sync with system_servers in lua/plugins/lsp.lua
      install_pkgs optional "language servers" \
        bash-language-server dockerfile-language-server vscode-json-languageserver pyright \
        typescript-language-server yaml-language-server
      ;;
    *)
      warn_manual bash-language-server docker-langserver vscode-json-language-server pyright-langserver \
        typescript-language-server yaml-language-server
      ;;
  esac
}

install_formatters() {
  section "Formatters"

  case "$PKG_MGR" in
    pacman)
      install_pkgs optional "formatters" stylua shfmt prettier python-black go-tools terraform
      ;;
    *)
      warn_manual stylua prettier terraform
      ;;
  esac
}

install_linters() {
  section "Linters"

  case "$PKG_MGR" in
    pacman)
      install_pkgs optional "linters" selene shellcheck yamllint tflint golangci-lint ruff
      ;;
    dnf)
      install_pkgs optional "shellcheck" ShellCheck
      warn_manual selene tflint
      ;;
    *)
      install_pkgs optional "shellcheck" shellcheck
      warn_manual selene tflint
      ;;
  esac

  if command -v hadolint >/dev/null 2>&1; then
    return
  fi
  if [[ "$PKG_TIER" == first-class ]]; then
    warn "hadolint: not in the official repos; review the PKGBUILD and run 'yay -S hadolint-bin', or run ':MasonInstall hadolint' in Neovim"
  else
    warn "hadolint: install manually, or run ':MasonInstall hadolint' in Neovim"
  fi
}

install_tui_tools() {
  section "TUI Tools"

  case "$PKG_MGR" in
    pacman)
      install_pkgs optional "TUI tools" lazygit lazydocker fortune-mod
      ;;
    apk)
      install_pkgs optional "fortune" fortune
      ;;
    *)
      install_pkgs optional "fortune" fortune-mod
      ;;
  esac
}

# Best-effort distros: the formatters, linters, and TUI tools their repos lack, from uv tool install
# and go install (latest upstream). They fetch and build code from the network, so install_deps runs
# them last, after dropping the sudo ticket.
install_user_tools() {
  if [[ "$PKG_TIER" == first-class ]]; then
    return
  fi

  section "User Tools"
  install_python_tool black
  install_python_tool yamllint
  install_python_tool ruff
  install_go_tool shfmt mvdan.cc/sh/v3/cmd/shfmt@latest
  install_go_tool goimports golang.org/x/tools/cmd/goimports@latest
  install_go_tool golangci-lint github.com/golangci/golangci-lint/v2/cmd/golangci-lint@latest
  install_go_tool lazygit github.com/jesseduffield/lazygit@latest
  install_go_tool lazydocker github.com/jesseduffield/lazydocker@latest
}

# ---------------------------------------------------------------------------
# Dependency orchestrator
# ---------------------------------------------------------------------------

# Two phases, so sudo is asked for once and dropped once, before any go or uv code runs: every system
# package first, then the user-level tools
install_deps() {
  install_build_tools
  install_core_tools
  install_clipboard
  install_runtimes
  install_language_servers
  install_formatters
  install_linters
  install_tui_tools
  drop_sudo_ticket
  install_user_tools
}

# ---------------------------------------------------------------------------
# Config setup
# ---------------------------------------------------------------------------

# True for this repo's HTTPS, SCP-style SSH, or ssh:// URL, with or without .git or a trailing slash.
is_config_repo_url() {
  local url="${1%/}"
  url="${url%.git}"
  case "$url" in
    "https://github.com/$NVIM_REPO_SLUG" | "git@github.com:$NVIM_REPO_SLUG" | "ssh://git@github.com/$NVIM_REPO_SLUG")
      return 0
      ;;
    *) return 1 ;;
  esac
}

# Remove the clone staging dir (cleanup() does the same when the run is interrupted)
discard_clone_staging() {
  rm -rf "$CLONE_STAGING"
  CLONE_STAGING=""
}

# Clone the config into a sibling staging dir, then move a foreign config to $1 (when given) and
# the clone into place. Nothing is moved unless the clone succeeded, and a failed final move puts
# the foreign config back.
clone_config() {
  local backup="$1"
  info "Cloning config to $NVIM_CONFIG_DIR..."
  if ! mkdir -p "$(dirname "$NVIM_CONFIG_DIR")"; then
    error "Cannot create parent directory for $NVIM_CONFIG_DIR"
    exit 1
  fi
  # A sibling of the config dir, so the final mv is a rename on the same filesystem; cleanup()
  # removes it if the run is interrupted
  if ! CLONE_STAGING="$(mktemp -d "$(dirname "$NVIM_CONFIG_DIR")/.nvim-clone.XXXXXX")"; then
    error "Cannot create a staging directory next to $NVIM_CONFIG_DIR"
    CLONE_STAGING=""
    exit 1
  fi
  if ! git clone "$NVIM_REPO" "$CLONE_STAGING/nvim"; then
    discard_clone_staging
    error "Failed to clone config repo; $NVIM_CONFIG_DIR was not changed"
    exit 1
  fi

  if [[ -n "$backup" ]]; then
    info "Backing up to $backup"
    if ! mv -T "$NVIM_CONFIG_DIR" "$backup"; then
      discard_clone_staging
      error "Failed to back up existing config from $NVIM_CONFIG_DIR to $backup"
      exit 1
    fi
  fi

  if ! mv -T "$CLONE_STAGING/nvim" "$NVIM_CONFIG_DIR"; then
    discard_clone_staging
    if [[ -z "$backup" ]]; then
      error "Failed to move the clone into $NVIM_CONFIG_DIR; nothing else was changed"
    elif mv -T "$backup" "$NVIM_CONFIG_DIR"; then
      error "Failed to move the clone into $NVIM_CONFIG_DIR; your existing config is back in place there"
    else
      error "Failed to move the clone into $NVIM_CONFIG_DIR; your existing config is at $backup"
    fi
    exit 1
  fi
  discard_clone_staging

  if [[ -n "$backup" ]]; then
    success "Backed up existing config"
  fi
  success "Config cloned to $NVIM_CONFIG_DIR"
}

setup_config() {
  section "Configuration"

  if [[ -d "$NVIM_CONFIG_DIR" ]]; then
    local existing_remote
    existing_remote="$(git -C "$NVIM_CONFIG_DIR" remote get-url origin 2>/dev/null || echo "")"

    if is_config_repo_url "$existing_remote"; then
      success "Config already present at $NVIM_CONFIG_DIR"
      return
    fi

    # Never move the checkout this script is running from
    if [[ "$(cd "$NVIM_CONFIG_DIR" 2>/dev/null && pwd -P)" == "$(cd "$SCRIPT_DIR" && pwd -P)" ]]; then
      success "Running from $NVIM_CONFIG_DIR, no clone needed"
      return
    fi
  fi

  # Run from a clone elsewhere, the script never clones, so it must not move the config aside either
  local script_remote
  script_remote="$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null || echo "")"

  if is_config_repo_url "$script_remote"; then
    info "This script is inside a clone of the config repo at $SCRIPT_DIR."
    info "Clone it to $NVIM_CONFIG_DIR or move it there manually."
    warn "Skipping automatic config setup (running from $SCRIPT_DIR)"
    return
  fi

  # Not run from a clone: ask before touching a foreign config, then clone first and move the foreign
  # config aside only once the clone succeeded, so a failed clone leaves everything as it was
  local backup=""
  if [[ -d "$NVIM_CONFIG_DIR" ]]; then
    backup="${NVIM_CONFIG_DIR}.bak.$(date +%s)"
    warn "Existing config at $NVIM_CONFIG_DIR is not this repo."
    if ! confirm "  Move it to $backup and clone this repo?"; then
      warn "Left $NVIM_CONFIG_DIR in place; move it aside yourself and run this script again to clone the config."
      return
    fi
  fi

  clone_config "$backup"
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
    bash)  rc_file="$HOME/.bashrc" ;;
    zsh)   rc_file="${ZDOTDIR:-$HOME}/.zshenv" ;;
    fish)  rc_file="${HOME}/.config/fish/config.fish" ;;
    posix) rc_file="$HOME/.profile" ;;
  esac
  path_line="$(path_append_line "$nvim_bin")"

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

Bootstrap script for Neovim 0.12+ with a full dev environment on Linux.

Installs Neovim, build tools, a clipboard tool, runtimes (Node, Go), the
Node-based language servers, formatters, linters, and TUI tools, then clones
the Neovim configuration to ~/.config/nvim. Mason installs the remaining
language servers on first launch.

Supported platforms:
  Arch Linux     (pacman)  first-class
  Debian/Ubuntu  (apt)     best-effort
  Fedora/RHEL    (dnf)     best-effort
  Alpine         (apk)     best-effort

Run it as your normal user; it calls sudo when it needs to.
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  setup_colors
  # On INT or TERM, run the EXIT cleanup and die by the same signal, so a calling shell or loop sees
  # the interrupt (exit 130/143 would look like an ordinary failure and let a loop carry on)
  trap cleanup EXIT
  trap 'trap - INT; kill -s INT "$BASHPID"' INT
  trap 'trap - TERM; kill -s TERM "$BASHPID"' TERM

  if [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
    usage
    exit 0
  fi

  require_non_root

  info "Neovim bootstrap starting"

  detect_os
  detect_arch
  detect_pkg_manager
  detect_shell
  confirm_proceed
  install_neovim
  install_deps
  forget_sudo_credentials
  setup_config
  setup_path
  verify_install
  print_summary
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
