#!/usr/bin/env bash
set -euo pipefail

readonly MIN_NVIM_VERSION="0.12.0"
readonly NVIM_REPO_SLUG="jkleinne/nvim"
readonly NVIM_REPO="https://github.com/${NVIM_REPO_SLUG}.git"
readonly NVIM_CONFIG_DIR="$HOME/.config/nvim"
readonly NVIM_INSTALL_DIR="/opt/nvim"
# Where install_neovim_tarball links the tarball's nvim, so it is on PATH without a shell config entry
readonly NVIM_LINK_DIR="/usr/local/bin"
readonly NVIM_RELEASE_BASE="https://github.com/neovim/neovim/releases/latest/download"
# Arch's TypeScript (a dependency of typescript-language-server), the first place the editor's ts_ls
# gate looks; has_system_typescript makes the same check
readonly ARCH_TSSERVER="/usr/lib/node_modules/typescript/lib/tsserver.js"
# Go tools the distro repos lack (install_user_tools), pinned to exact releases: an update is a
# deliberate change here, and Go's checksum database (GOSUMDB, sum.golang.org by default) verifies the
# exact module. The releases current on 2026-10-28 (proxy.golang.org). A test checks the form.
readonly GO_TOOL_SHFMT="mvdan.cc/sh/v3/cmd/shfmt@v3.14.1"
readonly GO_TOOL_GOIMPORTS="golang.org/x/tools/cmd/goimports@v0.52.0"
readonly GO_TOOL_GOLANGCI_LINT="github.com/golangci/golangci-lint/v2/cmd/golangci-lint@v2.15.0"
readonly GO_TOOL_LAZYGIT="github.com/jesseduffield/lazygit@v0.66.2"
readonly GO_TOOL_LAZYDOCKER="github.com/jesseduffield/lazydocker@v0.25.2"

# The directory this script is in, resolved without CDPATH. Empty when the script has no file (run as
# bash -c "$(curl ...)", or through a pipe); setup_config then skips its checks for running from a
# checkout. Run as bash <(curl ...), it is /proc/self/fd, which matches no checkout, so that is harmless.
SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
  SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
fi
SCRIPT_TMPDIR=""
CLONE_STAGING=""
WARNINGS=()
PATH_WARNED_DIRS=()
# true when this run's nvim is in $NVIM_INSTALL_DIR/bin and PATH did not reach it first. install_neovim
# only records it; put_install_dir_first_on_path then puts that dir first on this run's PATH, after the
# privileged phase, and setup_path adds it to the shell config.
NEED_PATH_SETUP=false
# Where this run's nvim came from: existing (a new enough nvim on PATH), reused (a new enough one in
# $NVIM_INSTALL_DIR/bin that PATH did not reach first), the package manager's name, or tarball (installed
# now). The PATH messages read it for the cause.
NVIM_INSTALL_METHOD=""
OS=""
ARCH=""
PKG_MGR=""
PKG_TIER=""
PKG_DB_SYNCED=false
SUDO_TICKET_HELD=false
PRIVILEGE_CLOSED=false
USER_SHELL=""
# --packages-only: stop after the system packages (no user tools, clone, PATH setup, or config check)
PACKAGES_ONLY=false

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

# Ask a y/N question: returns 0 for y or Y, 1 for any other answer, and 2 at end of input (no one to
# answer, as when stdin is closed or the script comes through a pipe). Callers that only need yes or no
# treat 1 and 2 alike.
confirm() {
  local reply
  read -rp "$1 [y/N] " reply || return 2
  [[ "$reply" =~ ^[Yy]$ ]]
}

# ---------------------------------------------------------------------------
# Privilege
# ---------------------------------------------------------------------------

# Every root command goes through as_root, which holds a sudo ticket first. main forgets every cached
# credential once (forget_sudo_credentials), right after the last step that runs root commands, which
# closes the privileged phase: a root command after it stops the run. cleanup drops a ticket the script
# still holds on any exit. sudo usually asks for a password once; it asks again if one step, such as
# the upgrade, outlasts its timestamp_timeout (sudo's timestamp is per terminal, 5 minutes by default).

require_sudo() {
  if ! command -v sudo >/dev/null 2>&1; then
    error "sudo is required to install system packages, but it is not on PATH."
    exit 1
  fi
}

# Called before each root command, with that command as its arguments (for the error message). Once
# forget_sudo_credentials has closed the privileged phase, it stops the run. The first time, it checks
# that sudo exists and its credentials (fails fast on a wrong password, and caches them), after marking
# the ticket as held, so cleanup drops it even when an interrupt lands while sudo -v caches it. Later,
# it checks the ticket with sudo -n -v, which never prompts, and validates the credentials again when the
# ticket lapsed (sudo -n -v also succeeds without a ticket when every sudoers entry is NOPASSWD). A
# machine with everything installed never gets here, so it is never asked for a password.
ensure_sudo_ticket() {
  if [[ "$PRIVILEGE_CLOSED" == true ]]; then
    error "root command after the privileged phase: $*"
    exit 1
  fi
  if [[ "$SUDO_TICKET_HELD" == true ]] && sudo -n -v 2>/dev/null; then
    return
  fi
  require_sudo
  SUDO_TICKET_HELD=true
  if ! sudo -v; then
    error "sudo authentication failed."
    exit 1
  fi
}

# Runs "$@" as root
as_root() {
  ensure_sudo_ticket "$@"
  sudo "$@"
}

# Closes the privileged phase (any root command after this stops the run) and drops any cached sudo
# credentials, including ones from before this run (for example the README's own 'sudo pacman -S'
# step), so the code this script starts next never inherits them: main calls it once, after the last
# root command and before go install and uv tool install fetch and build code, the config clone, and
# Neovim's first launch, which installs plugins and runs their build steps. sudo -k never prompts. This
# is stricter than installers that drop only the tickets they created, because this script itself
# starts third-party build code. With passwordless (NOPASSWD) sudo there is no ticket to drop, so this
# protects nothing. sudo -k can fail where sudo is not setuid (some containers, nosuid mounts); such a
# host has no ticket to drop, and the run goes on, unless sudo -n -v (which never prompts, and succeeds
# with a live ticket, or with NOPASSWD sudoers entries) succeeds: then the run stops, and a ticket this
# script took stays marked as held, so cleanup tries sudo -k again.
forget_sudo_credentials() {
  local k_error
  PRIVILEGE_CLOSED=true
  if ! command -v sudo >/dev/null 2>&1; then
    SUDO_TICKET_HELD=false
    return
  fi
  if k_error="$(sudo -k 2>&1 >/dev/null)"; then
    SUDO_TICKET_HELD=false
    return
  fi
  if sudo -n -v 2>/dev/null; then
    error "sudo -k failed (${k_error:-no message}), and a cached sudo ticket is still valid."
    error "Wait for it to expire (sudo's timestamp_timeout, 5 minutes by default), then run this script again."
    exit 1
  fi
  SUDO_TICKET_HELD=false
}

# For cleanup, which runs on every exit: drops the ticket the script still holds, and never fails
release_held_ticket() {
  if [[ "${SUDO_TICKET_HELD:-}" == true ]]; then
    sudo -k 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# Temp directory management and cleanup
# ---------------------------------------------------------------------------

cleanup() {
  # Runs on every exit, errors and signals included, so a sudo ticket this script took never outlives
  # it; first, so an interrupt during the removals below cannot skip it
  release_held_ticket
  if [[ -n "${SCRIPT_TMPDIR:-}" ]] && [[ -d "$SCRIPT_TMPDIR" ]]; then
    rm -rf "$SCRIPT_TMPDIR"
  fi
  if [[ -n "${CLONE_STAGING:-}" ]] && [[ -d "$CLONE_STAGING" ]]; then
    rm -rf "$CLONE_STAGING"
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

detect_os() {
  local kernel
  kernel="$(uname -s)"
  if [[ "$kernel" != "Linux" ]]; then
    error "Unsupported operating system: $kernel"
    error "This script supports Linux only (Arch Linux first-class; Fedora supported; other distros best-effort)."
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

# Sets the package manager ($1) and its support tier together: pacman is first-class, dnf is supported
# (Fedora's repos cover the core tools, runtimes, and many formatters and linters; the script installs or
# lists the rest), apt-get and apk are best-effort. Behavior keys on PKG_MGR; PKG_TIER is for display.
# Any other manager stops the run: the install functions' case statements know only these four.
set_pkg_manager() {
  case "$1" in
    pacman) PKG_TIER="first-class" ;;
    dnf) PKG_TIER="supported" ;;
    apt-get | apk) PKG_TIER="best-effort" ;;
    *)
      error "set_pkg_manager: unknown package manager '$1' (expected pacman, apt-get, dnf, or apk)"
      exit 1
      ;;
  esac
  PKG_MGR="$1"
}

detect_pkg_manager() {
  local mgr found=""
  # os-release first: binaries alone mislead, since Debian and Fedora can ship a pacman
  # binary and Arch's repos ship apt, dnf and apk-tools. Probe only when os-release names
  # no supported distro or its manager is missing (pacman first: Arch is first-class).
  mgr="$(os_release_pkg_mgr)"
  if [[ -n "$mgr" ]] && command -v "$mgr" >/dev/null 2>&1; then
    found="$mgr"
  else
    for mgr in pacman apt-get dnf apk; do
      if command -v "$mgr" >/dev/null 2>&1; then
        found="$mgr"
        break
      fi
    done
  fi

  if [[ -z "$found" ]]; then
    error "No supported package manager found."
    error "Supported: pacman (Arch Linux, first-class); dnf (Fedora, supported); apt-get, apk (best-effort)."
    exit 1
  fi

  set_pkg_manager "$found"
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

# Prints the version of the nvim on PATH, or of the nvim binary $1 when given (install_neovim checks
# the one in $NVIM_INSTALL_DIR, which may not be on PATH)
get_nvim_version() {
  local nvim_binary="${1:-nvim}"
  "$nvim_binary" --version 2>/dev/null | head -n1 | sed 's/^NVIM v//'
}

confirm_proceed() {
  local mode="full"
  if [[ "$PACKAGES_ONLY" == true ]]; then
    mode="packages only"
  fi
  section "Bootstrap Plan"
  printf '  %-18s %s\n' "OS:" "$OS"
  printf '  %-18s %s\n' "Architecture:" "$ARCH"
  printf '  %-18s %s\n' "Package manager:" "$PKG_MGR"
  printf '  %-18s %s\n' "Support tier:" "$PKG_TIER"
  printf '  %-18s %s\n' "Shell:" "$USER_SHELL"
  printf '  %-18s %s\n' "Mode:" "$mode"
  printf '\n'
  case "$PKG_TIER" in
    first-class) ;;
    supported)
      info "$PKG_MGR is supported: packages come from the distro's repos; Neovim comes from the release tarball when the repo's is missing or older than $MIN_NVIM_VERSION; lazygit and lazydocker come from go install at pinned versions in the full run; tools the repos lack are listed at the end."
      printf '\n'
      ;;
    best-effort)
      info "$PKG_MGR is best-effort: tools missing from its repos are installed with go install (pinned versions) or uv tool install (latest upstream) in the full run when available, otherwise listed as manual steps at the end."
      printf '\n'
      ;;
  esac
  info "This script will:"
  if [[ "$PKG_MGR" == "pacman" ]]; then
    printf '  %s\n' "0. Upgrade the system first (pacman -Syu, with pacman's own prompt) if anything needs installing"
  fi
  printf '  %s\n' "1. Install Neovim 0.12+ (prefer $PKG_MGR, tarball fallback)"
  case "$PKG_MGR" in
    pacman | dnf)
      printf '  %s\n' "2. Install build tools, clipboard, runtimes, language servers, formatters, linters, TUI tools"
      ;;
    *)
      printf '  %s\n' "2. Install build tools, clipboard, runtimes, formatters, linters, TUI tools (language servers: manual steps)"
      ;;
  esac
  if [[ "$PACKAGES_ONLY" != true ]]; then
    printf '  %s\n' "3. Clone config to $NVIM_CONFIG_DIR"
  fi
  printf '\n'

  local answer=0
  confirm "Proceed?" || answer=$?
  case "$answer" in
    0) ;;
    2)
      error "No answer (stdin is closed or not a terminal); run the script from a terminal"
      exit 1
      ;;
    *)
      info "Cancelled."
      exit 0
      ;;
  esac
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
    as_root rm -rf "$NVIM_INSTALL_DIR"
  fi

  info "Extracting to $NVIM_INSTALL_DIR (requires sudo)..."
  as_root mkdir -p "$NVIM_INSTALL_DIR"
  as_root tar -C "$NVIM_INSTALL_DIR" --strip-components=1 -xzf "$tarball"
  # tar run as root keeps the owners the archive records, and the dir's bin may go first on PATH
  # (put_install_dir_first_on_path), so root owns the tree and only root can write to it
  as_root chown -R 0:0 "$NVIM_INSTALL_DIR"
  as_root chmod -R go-w "$NVIM_INSTALL_DIR"

  if [[ -w "$NVIM_LINK_DIR" ]] || as_root test -w "$NVIM_LINK_DIR"; then
    as_root ln -sf "${NVIM_INSTALL_DIR}/bin/nvim" "${NVIM_LINK_DIR}/nvim"
    success "Symlinked nvim to $NVIM_LINK_DIR/nvim"
  else
    NEED_PATH_SETUP=true
  fi

  NVIM_INSTALL_METHOD="tarball"
}

# Succeeds when each dir given (one or more absolute paths with no symlink in them, as readlink -f prints
# them) is owned by uid 0 with no group or other write bit, so only root can rename, remove, or replace
# what it holds. Fails on a find error, and with no dir given, since find would check the current dir
# instead. A sticky dir (such as /tmp, mode 1777) gets no exception, though unlink(2) and rename(2) do
# not let another account remove or replace a root-owned entry there: OpenSSH's check of the dirs above
# a file (safe_path) makes none either, and neither /opt nor / is sticky on a standard layout, so
# refusing costs no more than a fresh install.
are_root_only_dirs() {
  local first_offender
  if [[ $# -eq 0 ]]; then
    return 1
  fi
  first_offender="$(find "$@" -maxdepth 0 \( ! -user 0 -o -perm /go=w \) -print -quit)" || return 1
  [[ -z "$first_offender" ]]
}

# Succeeds when only root can change the tree at $1, as the tarball install leaves it, or the dirs above
# it. That tree's bin may go first on PATH, where a file another account could write or put in place
# could shadow commands such as sudo. $1 is resolved first, as the nvim lookup and PATH resolve it, with
# readlink -f (GNU coreutils and BusyBox both take it with --, which BusyBox's realpath does not). Each
# dir above the resolved path, up to /, must pass are_root_only_dirs, and every entry of the tree must be
# owned by uid 0 with no group or other write bit. find -L checks each symlink in the tree through to its
# target and descends a linked dir, so no link can lead to a file or dir another account can write. A
# broken link (the only kind find -L reports as -type l) fails, since its target, which may lie outside
# the tree, could later appear with anyone's contents. Any readlink or find error (a link loop, an
# unreadable entry, or no tree) counts as not root-owned. Not checked: the dirs above a link's target
# outside the tree, and a dir that holds a symlink on the way to the tree unless it is also above the
# resolved path (/opt, when /opt/nvim is itself a link). GNU find and BusyBox's find (with the features
# Alpine builds in) both take every option used here, -L and -maxdepth included.
is_root_owned_tree() {
  local tree dir first_offender
  local parent_dirs=()
  tree="$(readlink -f -- "$1")" || return 1
  dir="${tree%/*}"
  while [[ -n "$dir" ]]; do
    parent_dirs+=("$dir")
    dir="${dir%/*}"
  done
  parent_dirs+=(/)
  are_root_only_dirs "${parent_dirs[@]}" || return 1
  first_offender="$(find -L "$tree" \( -type l -o ! -user 0 -o -perm /go=w \) -print -quit)" || return 1
  [[ -z "$first_offender" ]]
}

# An earlier tarball install can leave its nvim only in $NVIM_INSTALL_DIR/bin: the $NVIM_LINK_DIR link
# failed, or neither the link nor setup_path's shell config entry is in effect for this run. Succeeds,
# after recording the reuse (the install method, and NEED_PATH_SETUP), when a new enough nvim is there
# and only root can change the tree or the dirs above it (is_root_owned_tree), which is checked before
# that nvim runs; fails otherwise (with a warning when the check fails), so install_neovim installs. The
# version is read inside the condition, where errexit does not apply, so a binary there that fails
# --version falls through to the install instead of ending the run.
reuse_install_dir_nvim() {
  local install_dir_nvim="$NVIM_INSTALL_DIR/bin/nvim" install_dir_version
  if [[ ! -x "$install_dir_nvim" ]]; then
    return 1
  fi
  if ! is_root_owned_tree "$NVIM_INSTALL_DIR"; then
    warn "Not reusing the nvim in $NVIM_INSTALL_DIR: something in it, or a directory above it, is not owned by root, is writable by group or others, or is a broken link; installing Neovim instead"
    return 1
  fi
  if ! install_dir_version="$(get_nvim_version "$install_dir_nvim")" \
    || ! version_gte "$install_dir_version" "$MIN_NVIM_VERSION"; then
    return 1
  fi
  success "Neovim $install_dir_version already installed in $NVIM_INSTALL_DIR (>= $MIN_NVIM_VERSION)"
  NVIM_INSTALL_METHOD="reused"
  NEED_PATH_SETUP=true
}

# Tries, in order: a new enough nvim on PATH, the one an earlier tarball install left in
# $NVIM_INSTALL_DIR, the package manager's, and the release tarball
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

  if reuse_install_dir_nvim; then
    return
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

# Runs once, right before the first package install: syncs the package database. On Arch that is the
# full system upgrade (pacman -Syu), because installing new packages against a freshly synced
# database without upgrading is a partial upgrade, which Arch does not support. pacman shows its own
# list and asks before changing anything.
sync_pkg_db_once() {
  if [[ "$PKG_DB_SYNCED" == true ]]; then
    return
  fi
  case "$PKG_MGR" in
    pacman)
      info "Upgrading the system first (pacman -Syu)..."
      if ! as_root pacman -Syu; then
        error "System upgrade declined or failed; installing packages now would be a partial upgrade."
        error "Run 'sudo pacman -Syu' yourself, then run this script again."
        exit 1
      fi
      ;;
    # The sync is best effort on these distros; the warning reaches the summary
    apt-get)
      info "Updating package lists..."
      as_root apt-get update -qq || warn "apt-get update failed; installing from the existing package lists"
      ;;
    apk)
      info "Updating package index..."
      as_root apk update || warn "apk update failed; installing from the existing package index"
      ;;
    # dnf refreshes expired metadata itself before an install, and Fedora supports installing against a
    # newer database without a full upgrade, so there is no upfront step
    dnf) ;;
  esac
  PKG_DB_SYNCED=true
}

pkg_is_installed() {
  case "$PKG_MGR" in
    apt-get) dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed' ;;
    # dnf install matches a name against package names and then Provides (on Fedora 44, nodejs is a
    # Provides of nodejs22), but rpm -q matches package names only; every package also provides its own
    # name, so --whatprovides finds both
    dnf)     rpm -q --whatprovides "$1" &>/dev/null ;;
    pacman)  pacman -Q "$1" &>/dev/null ;;
    apk)     apk info -e "$1" &>/dev/null ;;
  esac
}

pkg_install() {
  sync_pkg_db_once
  case "$PKG_MGR" in
    apt-get) as_root apt-get install -y "$@" ;;
    # dnf installs Recommends by default, and Fedora's nodejs recommends its package manager, which this
    # config never uses; with weak dependencies off, only the listed packages and their hard
    # dependencies land
    dnf)     as_root dnf install -y --setopt=install_weak_deps=False "$@" ;;
    pacman)  as_root pacman -S --noconfirm "$@" ;;
    apk)     as_root apk add "$@" ;;
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

# Unless tool $1 is already on PATH, installs it by running "$@", and warns when that fails
install_unless_on_path() {
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

# The line for the user's shell config that puts dir $2 on PATH, after the dirs already there ($1
# append) or ahead of them ($1 prepend). The user-tool hints append, so user dirs never shadow system
# binaries. fish gets --path either way, or fish_add_path puts the dir in fish_user_paths, which fish
# places ahead of the system paths even with --append. Any other mode is an error (status 1).
path_line() {
  # shellcheck disable=SC2016  # $PATH is literal on purpose: the line goes into the user's shell config
  case "$USER_SHELL:$1" in
    fish:append)  printf 'fish_add_path --append --path %s\n' "$2" ;;
    fish:prepend) printf 'fish_add_path --path %s\n' "$2" ;;
    *:append)     printf 'export PATH="$PATH:%s"\n' "$2" ;;
    *:prepend)    printf 'export PATH="%s:$PATH"\n' "$2" ;;
    *)
      error "path_line: unknown mode '$1' (expected append or prepend)"
      return 1
      ;;
  esac
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
  warn "$dir is not on PATH; add this to your shell config: $(path_line append "$dir")"
}

# For go install / uv tool install: the binary lands in a user bin dir that may
# not be on PATH, so check that dir too and warn when the binary there is unreachable.
install_user_tool() {
  local name="$1" bin_dir="$2"
  shift 2
  if [[ -x "$bin_dir/$name" ]]; then
    success "$name (already installed in $bin_dir)"
  else
    install_unless_on_path "$name" "$@"
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

# Go CLI tools go into Go's user bin dir, at the exact version the module string ($2) pins.
# GOTOOLCHAIN=local holds for every go call here (go env through go_bin_dir, and go install): Go's
# default, auto, downloads a newer toolchain when a module asks for one; with local that is a failure,
# reported as a skip. local -x scopes the export to this function, so the config clone and Neovim's
# first launch never inherit it.
install_go_tool() {
  local name="$1" module="$2" bin_dir
  local -x GOTOOLCHAIN=local
  if ! command -v go >/dev/null 2>&1; then
    warn "$name: install Go, then run: GOTOOLCHAIN=local go install $module"
    return
  fi
  if ! bin_dir="$(go_bin_dir)"; then
    warn "$name: could not resolve Go's bin dir; run: GOTOOLCHAIN=local go install $module"
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

# Succeeds when $1, with symlinks resolved, is a file whose package.json two levels up names
# typescript and has a non-empty string version: the test the editor's ts_ls gate applies to a
# tsserver.js (package_tsserver in lua/lsp_gates/typescript.lua). The fields are matched as text,
# which is enough for a hint.
typescript_package_tsserver() {
  local js pkg_json meta
  local name_re='"name"[[:space:]]*:[[:space:]]*"typescript"'
  local version_re='"version"[[:space:]]*:[[:space:]]*"[^"]+"'
  [[ -f "$1" ]] || return 1
  js="$(readlink -f -- "$1")" || return 1
  pkg_json="${js%/*}"
  pkg_json="${pkg_json%/*}/package.json"
  [[ -f "$pkg_json" && -r "$pkg_json" ]] || return 1
  meta="$(<"$pkg_json")"
  [[ $meta =~ $name_re && $meta =~ $version_re ]]
}

# Whether the editor's ts_ls gate finds a system TypeScript (system_tsserver in
# lua/lsp_gates/typescript.lua): Arch's ($ARCH_TSSERVER), else the TypeScript package that the
# tsserver on PATH, with symlinks resolved, belongs to (the nearest dir above it with a package.json,
# whose lib/tsserver.js must pass typescript_package_tsserver). A version manager's shim or a wrapper
# script belongs to no such package.
has_system_typescript() {
  local bin dir
  if typescript_package_tsserver "$ARCH_TSSERVER"; then
    return 0
  fi
  bin="$(command -v tsserver)" || return 1
  bin="$(readlink -f -- "$bin")" || return 1
  dir="$bin"
  while [[ "$dir" == */* ]]; do
    dir="${dir%/*}"
    if [[ -e "$dir/package.json" ]]; then
      typescript_package_tsserver "$dir/lib/tsserver.js"
      return
    fi
  done
  return 1
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

  # The system servers in lua/lsp_gates/servers.lua come from the system package manager where it
  # packages them and are listed as manual steps where it does not; a fallback is installed only where a
  # distro packages one in place of its server. Mason installs the native ones the first time nvim
  # opens a file
  case "$PKG_MGR" in
    pacman)
      # Keep in sync with the system table in lua/lsp_gates/servers.lua
      install_pkgs optional "language servers" \
        bash-language-server dockerfile-language-server vscode-json-languageserver pyright \
        typescript-language-server yaml-language-server
      ;;
    dnf)
      # Keep in sync with the system and fallbacks tables in lua/lsp_gates/servers.lua (a test checks)
      install_pkgs optional "language servers" nodejs-bash-language-server python3-lsp-server
      warn "Fedora packages no server for dockerls, jsonls, ts_ls or yamlls: they stay off unless their commands are on PATH (ts_ls also needs a system TypeScript); python-lsp-server (pylsp) stands in for pyright"
      ;;
    *)
      warn_manual bash-language-server docker-langserver vscode-json-language-server pyright-langserver \
        typescript-language-server yaml-language-server
      if ! has_system_typescript; then
        warn "ts_ls also needs a system TypeScript: install your distribution's TypeScript package, which provides tsserver"
      fi
      ;;
  esac
}

install_formatters() {
  section "Formatters"

  case "$PKG_MGR" in
    pacman)
      install_pkgs optional "formatters" stylua shfmt prettier python-black go-tools terraform
      ;;
    dnf)
      install_pkgs optional "formatters" shfmt black golang-x-tools-goimports
      warn_manual stylua prettier terraform
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
      install_pkgs optional "linters" ShellCheck yamllint ruff golangci-lint hadolint
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
  if [[ "$PKG_MGR" == pacman ]]; then
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
    dnf)
      install_pkgs optional "fortune" fortune-mod
      ;;
    apk)
      install_pkgs optional "fortune" fortune
      ;;
    *)
      install_pkgs optional "fortune" fortune-mod
      ;;
  esac
}

# The tools a distro's repos lack, installed as the user into Go's and uv's bin directories: on dnf,
# lazygit and lazydocker from go install; on apt-get and apk, also the formatters and linters, from go
# install and uv tool install. Each Go module is pinned by its GO_TOOL_* constant. They fetch and build
# code from the network, so main runs this only after forget_sudo_credentials, and it runs no root
# command. pacman installs all of them.
install_user_tools() {
  if [[ "$PKG_MGR" == pacman ]]; then
    return
  fi

  section "User Tools"
  case "$PKG_MGR" in
    dnf)
      install_go_tool lazygit "$GO_TOOL_LAZYGIT"
      install_go_tool lazydocker "$GO_TOOL_LAZYDOCKER"
      ;;
    *)
      install_python_tool black
      install_python_tool yamllint
      install_python_tool ruff
      install_go_tool shfmt "$GO_TOOL_SHFMT"
      install_go_tool goimports "$GO_TOOL_GOIMPORTS"
      install_go_tool golangci-lint "$GO_TOOL_GOLANGCI_LINT"
      install_go_tool lazygit "$GO_TOOL_LAZYGIT"
      install_go_tool lazydocker "$GO_TOOL_LAZYDOCKER"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Dependency orchestrator
# ---------------------------------------------------------------------------

# System packages only, all under one sudo ticket, so sudo usually asks for a password once; it asks
# again if one step, such as the upgrade, outlasts its timestamp_timeout. The user-level tools
# (install_user_tools) run later, after main forgets the ticket.
install_deps() {
  install_build_tools
  install_core_tools
  install_clipboard
  install_runtimes
  install_language_servers
  install_formatters
  install_linters
  install_tui_tools
}

# ---------------------------------------------------------------------------
# Config setup
# ---------------------------------------------------------------------------

# True for this repo's HTTPS, SCP-style SSH, or ssh:// URL, with or without .git or a trailing slash.
is_config_repo_url() {
  local url="${1%/}"
  url="${url%.git}"
  # A user name or token before the host (https://user:token@github.com/...) names the same repo
  if [[ $url =~ ^https://[^/?#@]+@(.+)$ ]]; then
    url="https://${BASH_REMATCH[1]}"
  fi
  case "$url" in
    "https://github.com/$NVIM_REPO_SLUG" | "git@github.com:$NVIM_REPO_SLUG" | "ssh://git@github.com/$NVIM_REPO_SLUG")
      return 0
      ;;
    *) return 1 ;;
  esac
}

# True when the git checkout at $1 has this repo among its origin URLs: every URL stored for origin
# (git fetches from the first; `git remote set-url --add` adds more), both as stored and as
# url.<base>.insteadOf rules rewrite them (a rule can add a token or expand a short alias). --local
# keeps a directory outside any repository from matching through the global git config.
is_config_checkout() {
  local url urls
  [[ -n "$1" ]] || return 1
  # errexit holds inside the substitution, so a read that finds nothing must not end it early
  mapfile -t urls < <(
    git -C "$1" config --local --get-all remote.origin.url 2>/dev/null || true
    git -C "$1" remote get-url --all origin 2>/dev/null || true
  )
  for url in "${urls[@]}"; do
    if is_config_repo_url "$url"; then
      return 0
    fi
  done
  return 1
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
    if is_config_checkout "$NVIM_CONFIG_DIR"; then
      success "Config already present at $NVIM_CONFIG_DIR"
      return
    fi

    # Never move the checkout this script is running from (with no script file, there is none)
    if [[ -n "$SCRIPT_DIR" ]] \
      && [[ "$(cd "$NVIM_CONFIG_DIR" 2>/dev/null && pwd -P)" == "$(cd "$SCRIPT_DIR" && pwd -P)" ]]; then
      success "Running from $NVIM_CONFIG_DIR, no clone needed"
      return
    fi
  fi

  # Run from a clone elsewhere, the script never clones, so it must not move the config aside either
  if is_config_checkout "$SCRIPT_DIR"; then
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
# PATH setup (an nvim in NVIM_INSTALL_DIR that PATH did not reach first)
# ---------------------------------------------------------------------------

# When install_neovim left this run's nvim only in $NVIM_INSTALL_DIR/bin (NEED_PATH_SETUP), puts that dir
# first on this run's PATH and exports it, so verify_nvim, verify_config, and what they start run that
# nvim now; setup_path adds the same entry to the shell config for new shells. Only root can write the
# tree (the tarball install chowns it, and reuse requires is_root_owned_tree), so the commands this run
# starts afterwards cannot find one another account planted there. main runs this after
# forget_sudo_credentials has closed the privileged phase, because as_root runs plain sudo, which
# searches the caller's PATH unless sudoers sets secure_path: past the drop, as_root stops the run, and
# cleanup's sudo -k runs only for a ticket still held, which the drop clears, so no root command and no
# lookup of sudo ever searches this dir.
put_install_dir_first_on_path() {
  if [[ "$NEED_PATH_SETUP" != true ]]; then
    return
  fi
  PATH="$NVIM_INSTALL_DIR/bin:$PATH"
  export PATH
}

setup_path() {
  if [[ "$NEED_PATH_SETUP" != true ]]; then
    return
  fi

  section "PATH"

  local nvim_bin="${NVIM_INSTALL_DIR}/bin"
  local rc_file=""
  local line=""

  case "$USER_SHELL" in
    bash)  rc_file="$HOME/.bashrc" ;;
    zsh)   rc_file="${ZDOTDIR:-$HOME}/.zshenv" ;;
    fish)  rc_file="${HOME}/.config/fish/config.fish" ;;
    posix) rc_file="$HOME/.profile" ;;
  esac
  # Prepended, unlike the user-tool dirs: the tarball's nvim is installed or reused only when the nvim on
  # PATH is missing or too old, so it must win over an older one in /usr/bin, as it does in this run
  # (put_install_dir_first_on_path)
  line="$(path_line prepend "$nvim_bin")"

  if [[ -z "$rc_file" ]]; then
    warn "Could not determine rc file for shell: $USER_SHELL"
    info "Add this to your shell config manually:"
    printf '  %s\n' "$line"
    return
  fi

  if [[ "$rc_file" != "$HOME/.profile" ]] && [[ ! -f "$rc_file" ]]; then
    warn "$rc_file does not exist."
    info "Add this to your shell config manually:"
    printf '  %s\n' "$line"
    return
  fi

  if grep -qF "$nvim_bin" "$rc_file" 2>/dev/null; then
    success "PATH entry already in $rc_file"
    return
  fi

  printf '\n# Neovim (added by nvim-install.sh)\n%s\n' "$line" >> "$rc_file"
  success "Added PATH entry to $rc_file"
  info "Run 'source $rc_file' or open a new terminal to apply."
}

# ---------------------------------------------------------------------------
# Verification and summary
# ---------------------------------------------------------------------------

# Both modes: nvim is on PATH and new enough; otherwise the run stops
verify_nvim() {
  section "Verification"

  if ! command -v nvim >/dev/null 2>&1; then
    error "nvim not found on PATH after installation."
    exit 1
  fi

  local installed_version
  installed_version="$(get_nvim_version)"
  if ! version_gte "$installed_version" "$MIN_NVIM_VERSION"; then
    error "Neovim $installed_version is installed, but $MIN_NVIM_VERSION+ is required."
    exit 1
  fi
  success "Neovim $installed_version on PATH"
}

# Full run only: the config loads (Neovim's first launch, which installs plugins and runs their build
# steps, so main runs this after forget_sudo_credentials). Neovim exits 0 even when the config errors at
# startup, so the launch reads v:errmsg before +qa and, when it is set, echoes it and quits with an
# error status. Some plugins, lazy.nvim among them, report errors through vim.schedule, so the launch
# first runs the callbacks startup queued (a 0 ms vim.wait, which a deferred-error test checks). That
# catches errors raised while init.lua, lazy's setup, and the start plugins run, and errors they queue,
# but not a failed plugin build: in headless mode lazy prints build output to stdout and does not record
# a failed make as an error (lazy.nvim 306a055: lua/lazy/manage/task/init.lua:153 and :197-224,
# task/plugin.lua:31-40). Errors from a timer (vim.defer_fn) not yet due when that wait runs, or from
# anything during +qa, go unchecked. An error hidden with :silent! (in init.lua or a plugin) still sets
# v:errmsg, so it makes this warn. Headless Neovim writes its messages to stderr, which goes to a log in
# Neovim's state dir, overwritten each run. On an error the warning names the log and shows its last
# lines, which end with the echoed message, so later messages cannot push it out of view (a test
# checks a long report). When the log cannot be written, the check is skipped with a warning.
verify_config() {
  local log_dir="${XDG_STATE_HOME:-$HOME/.local/state}/nvim"
  local log_file="$log_dir/nvim-install-config-check.log"
  # Covers lazy.nvim's 15-line report of a failed plugin config, with a few lines before it
  local shown_line_count=20
  local run_scheduled_callbacks="+lua vim.wait(0)"
  local report_startup_error="+if v:errmsg != '' | echo 'Last error message:' v:errmsg | cquit | endif"
  local shown_lines

  if ! mkdir -p -- "$log_dir" || ! : >"$log_file"; then
    warn "Skipped the config check: could not write its log $log_file"
    return
  fi
  if nvim --headless "$run_scheduled_callbacks" "$report_startup_error" "+qa" 2>"$log_file"; then
    success "Config loads cleanly"
    return
  fi

  warn "Config reported errors at startup (full log: $log_file)"
  mapfile -t shown_lines < <(tail -n "$shown_line_count" -- "$log_file")
  if [[ ${#shown_lines[@]} -gt 0 ]]; then
    printf '      %s\n' "${shown_lines[@]}"
  fi
  warn "Launch nvim to see them"
}

print_summary() {
  local installed_version title="Neovim Bootstrap Complete" config="$NVIM_CONFIG_DIR"
  installed_version="$(get_nvim_version 2>/dev/null || echo "unknown")"
  if [[ "$PACKAGES_ONLY" == true ]]; then
    title="Neovim Packages Installed"
    config="not cloned (packages-only)"
  fi

  printf '\n'
  printf '%s\n' "${BOLD}${GREEN}====================================${RESET}"
  printf '%s\n' "${BOLD}${GREEN}  $title${RESET}"
  printf '%s\n' "${BOLD}${GREEN}====================================${RESET}"
  printf '  %-18s %s\n' "Version:" "$installed_version"
  printf '  %-18s %s\n' "Install method:" "$NVIM_INSTALL_METHOD"
  printf '  %-18s %s\n' "Config:" "$config"

  if [[ "$NEED_PATH_SETUP" == true ]]; then
    # Only these two methods set NEED_PATH_SETUP (reuse_install_dir_nvim, install_neovim_tarball)
    local path_cause
    case "$NVIM_INSTALL_METHOD" in
      reused) path_cause="the reused nvim was not first on PATH" ;;
      tarball) path_cause="nvim could not be linked into $NVIM_LINK_DIR" ;;
      *)
        error "print_summary: NEED_PATH_SETUP is true for install method '$NVIM_INSTALL_METHOD' (expected reused or tarball)"
        exit 1
        ;;
    esac
    if [[ "$PACKAGES_ONLY" == true ]]; then
      # setup_path did not run
      printf '  %-18s %s\n' "PATH:" "$path_cause; the full run adds $NVIM_INSTALL_DIR/bin to your shell config"
    else
      printf '  %-18s %s\n' "PATH updated:" "yes, $NVIM_INSTALL_DIR/bin first, as $path_cause (restart shell to apply)"
    fi
  fi

  if [[ ${#WARNINGS[@]} -gt 0 ]]; then
    printf '\n  %s\n' "${YELLOW}${BOLD}Warnings:${RESET}"
    for w in "${WARNINGS[@]}"; do
      printf '    %s %s\n' "${YELLOW}!${RESET}" "$w"
    done
  fi

  printf '%s\n' "${BOLD}${GREEN}====================================${RESET}"
  printf '\n'
  if [[ "$PACKAGES_ONLY" == true ]]; then
    info "Run this script again without --packages-only where Neovim will run, to install the user tools and clone the config."
  else
    info "Open a file in nvim once so Mason installs its language servers."
  fi
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

usage() {
  cat <<'EOF'
Usage: nvim-install.sh [--packages-only | --help]

Bootstrap script for Neovim 0.12+ with a full dev environment on Linux.

Installs Neovim, build tools, a clipboard tool, runtimes (Node, Go),
formatters, linters, and TUI tools, and the language servers the distro
packages (Arch: the Node-based ones; Fedora: bash-language-server and
python-lsp-server; elsewhere: manual steps), then clones the Neovim
configuration to ~/.config/nvim. Mason installs the native language
servers the first time nvim opens a file; the others stay off until
installed.
On Fedora, python-lsp-server stands in for pyright.

Options:
  --packages-only  install the system packages and stop; run again
                   without it where Neovim will run
  --help, -h       show this help

Supported platforms:
  Arch Linux     (pacman)  first-class
  Fedora         (dnf)     supported
  RHEL/CentOS    (dnf)     same path, fewer packages
  Debian/Ubuntu  (apt)     best-effort
  Alpine         (apk)     best-effort

Run it as your normal user; it calls sudo when it needs to.
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# Turns the command line into the run mode, or stops. No arguments: the full run. One argument: --help
# or -h prints usage and exits 0, --packages-only sets the mode, and anything else (including the empty
# argument) is an error. More than one argument is an error too. Errors print the arguments as given
# (shell-quoted, so an empty one and a space inside one stay visible) and usage to stderr and exit 1,
# before anything runs
parse_args() {
  if [[ $# -eq 0 ]]; then
    return
  fi
  local shown
  printf -v shown '%q ' "$@"
  shown="${shown% }"
  if [[ $# -gt 1 ]]; then
    error "too many arguments: $shown (at most one: --packages-only, --help, or -h)"
    usage >&2
    exit 1
  fi
  case "$1" in
    --help | -h)
      usage
      exit 0
      ;;
    --packages-only) PACKAGES_ONLY=true ;;
    *)
      error "unknown argument: $shown"
      usage >&2
      exit 1
      ;;
  esac
}

main() {
  setup_colors
  # On INT or TERM, run the EXIT cleanup and die by the same signal, so a calling shell or loop sees
  # the interrupt (exit 130/143 would look like an ordinary failure and let a loop carry on)
  trap cleanup EXIT
  trap 'trap - INT; kill -s INT "$BASHPID"' INT
  trap 'trap - TERM; kill -s TERM "$BASHPID"' TERM

  parse_args "$@"
  require_non_root

  info "Neovim bootstrap starting"

  detect_os
  detect_arch
  detect_pkg_manager
  detect_shell
  confirm_proceed
  install_neovim
  install_deps
  # The one privilege boundary: every root command runs above, none below, and no cached credentials
  # reach the go and uv builds, the config clone, or Neovim's first launch
  forget_sudo_credentials
  # Past the boundary, so no root command and no lookup of sudo searches the dir it puts on PATH
  put_install_dir_first_on_path
  if [[ "$PACKAGES_ONLY" == true ]]; then
    verify_nvim
    print_summary
    return
  fi
  install_user_tools
  setup_config
  setup_path
  verify_nvim
  verify_config
  print_summary
}

# Runs main when the script is executed, directly or as bash -c "$(curl ...)" or through a pipe, and
# not when it is sourced (the tests source it). Through a pipe, confirm reads the end of input (or the
# script's own text), so the run stops at the first prompt: it needs a terminal to answer from.
if ! (return 0 2>/dev/null); then
  main "$@"
fi
