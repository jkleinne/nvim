#!/usr/bin/env bash
# Tests for nvim-install.sh: bash tests/install-script.test.sh
#
# Hermetic by default: every stub, fake HOME, and scratch file lives under one temp dir that is removed
# on exit. The suite first drops every shell function and alias it inherited (an exported function, or
# one a BASH_ENV file defined, would shadow the stubs on PATH) and refuses a temp dir whose path has a
# ':' (it would split the stub dirs on PATH). The stubs are files in tests/lib/stubs, copied into bin
# dirs under the temp dir, and before any test the suite checks that each one wins on PATH: it refuses
# to run when one does not, as on a noexec temp dir, where bash's PATH search skips the stubs and finds
# the real commands. Sourced tests and direct script runs start with sandbox: a fake HOME, which also
# becomes the working directory (git never finds the caller's repository from there), then
# hermetic_env, so inherited GIT_*, ZDOTDIR, XDG_*, BASH_ENV, ENV, CDPATH, and GOTOOLCHAIN variables
# are dropped (no shell a test starts reads a startup file that could put other commands ahead of the
# stubs on PATH, and T17's go stub logs the toolchain mode the script sets, never an inherited one) and
# git ignores the system and global config, refuses every protocol but file (no clone reaches the
# network, however git is invoked), and never looks above $TMP for a repository. DENY_BIN, which sandbox
# puts on PATH, refuses sudo, curl, wget, go, uv, and the language package managers and AUR helpers T5
# forbids, and logs each call to $TMP/refused.log; a test that needs one puts its stub ahead (a
# recording sudo that never runs its arguments, a curl that copies a tiny local tarball, go and uv stubs
# that only log), and T21 fails when any test reached a refusing stub. The tests that run install
# functions through their real code (T12's deps cases, T17, T20's collection) set PATH to stub dirs and
# at most a dir of the few real tools that code needs, so nothing else on the caller's PATH can run.
# Every command a recording sudo logs must be on the allowlist (sudo_allowlist_problems): sudo -v, -n
# -v, and -k, each package manager's refresh and install, and the tarball install's steps. So, apart
# from T4 under RUN_FULL=1 (the plugins, into scratch dirs) and T33 under RUN_FEDORA=1, no test can
# install, upgrade, or download anything, and load_script, run_script, run_script_args, and the main
# drivers (tests/lib/driver-*.sh, which share tests/lib/driver-lib.sh) run the script only under a fake
# HOME, so NVIM_CONFIG_DIR never points at a real config. The suite and driver-lib.sh share the helpers in
# tests/lib/common.sh. T20 reads the server list with nvim --clean --headless -l
# tests/lib/system-servers.lua, with scratch XDG dirs and TMPDIR, and T35 runs verify_config's headless
# nvim on a config it writes under a sandbox HOME, with a scratch TMPDIR. Each test sets up what it needs
# itself, from the stubs and host facts the setup sections below provide, so the tests do not depend
# on each other's order (T21, which reads what every test left, runs last). RUN_FULL=1 adds T4, an
# end-to-end run on this machine (see T4), which also reads the real ~/.config/nvim and runs the real
# sudo -k (it never prompts or elevates) to drop this terminal's cached ticket. The only real package
# manager queries are read-only: pacman -Q (T4's run and T20 (d)), pacman -Qlq (T20 (d)), and pacman
# -Si (T20 (b0)). REQUIRE_ALL=1 turns the skips of T3 and T26b's fake-root cases (no way to fake root
# here) into failures.
# RUN_FEDORA=1 adds T33 (see T33), which pulls the fedora:44 image into the user's podman storage (it
# stays after the run) and installs packages only inside a throwaway container.
# shellcheck source-path=SCRIPTDIR/..
set -uo pipefail

# Inherited functions (exported ones, or ones a BASH_ENV file defined) would shadow every stub on PATH,
# and aliases would rewrite commands, so none survive into the tests or the shells they start
while read -r _ _ fn; do unset -f "$fn"; done < <(declare -F)
unalias -a 2>/dev/null
shopt -u expand_aliases

ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/nvim-install.sh"
# Signal dispositions this suite inherited (one ignored at entry shows as trap -- '' SIGINT); see INT_RC
INHERITED_TRAPS="$(trap -p INT TERM)"
TMP="$(mktemp -d)" || exit 1
trap 'rm -rf -- "${TMP:?}"' EXIT
# Every stub dir sits under $TMP and goes on PATH, where a ':' would split it in two and let the real
# commands (sudo among them) resolve
if [[ "$TMP" == *:* ]]; then
  echo "FAIL setup: the temp dir $TMP has a ':' in its path, which would split the stub dirs on PATH;" \
    "set TMPDIR to a directory without one"
  exit 1
fi
# The stubs and the helpers in tests/lib/common.sh find the suite's files here, and the driver library
# refuses to run outside a sandbox home under it
SUITE_TMP="$TMP"
export SUITE_TMP
LIB="$ROOT/tests/lib"
# shellcheck source=tests/lib/common.sh
source "$LIB/common.sh"
fail=0

FOREIGN_ORIGIN="https://github.com/someone/else"
REPO_URL_HTTPS="https://github.com/jkleinne/nvim.git"

result() {
  if [[ "$2" == 0 ]]; then
    echo "PASS $1"
  else
    echo "FAIL $1${3:+: $3}"
    fail=1
  fi
}

# PASS when the collected problems string is empty
expect_none() {
  if [[ -z "$2" ]]; then
    result "$1" 0
  else
    result "$1" 1 "$2"
  fi
}

# Sourced test bodies run in a subshell with stdin on /dev/null and print DONE as their last line,
# so an early exit (even with status 0) fails the test.
done_ok() { [[ $1 -eq 0 && "$(tail -n1 <<<"$2")" == DONE ]]; }

# Drops the variables that point git or the shell at real config or repos, or make a shell read a
# startup file (BASH_ENV, ENV) or resolve cd elsewhere (CDPATH), or could stand in for what the script
# sets itself (GOTOOLCHAIN: T17's go stub records the toolchain mode the script sets, so an inherited
# value must not satisfy T17), and makes git ignore the system and global config, refuse every protocol
# but file, and never look above $TMP for a repo
hermetic_env() {
  unset "${!GIT_@}" ZDOTDIR XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME BASH_ENV ENV CDPATH GOTOOLCHAIN
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_ALLOW_PROTOCOL=file GIT_CEILING_DIRECTORIES="$TMP"
}

# Call first in each test's subshell, sourced or running the script: a fresh fake HOME, which becomes
# the working directory, hermetic_env, and PATH with the given stub dirs ($2, colon-separated, may be
# empty) first, then DENY_BIN
sandbox() {
  hermetic_env
  HOME="$(sandbox_home "$1")"
  export HOME
  mkdir -p "$HOME"
  cd "$HOME" || exit 1
  PATH="${2:+$2:}$DENY_BIN:$PATH"
}

# sandbox for a test that uses the recording sudo: RECORD_BIN goes on PATH after the stub dirs $2
# (optional, colon-separated); SUDO_LOG and EVENT_LOG point at new empty files (sudo_log $1, event_log
# $1), and SUDO_FAIL_ON is $3 (default empty), all exported; SUDO_INT_ON and SUDO_MARKER are unset
recording_sandbox() {
  sandbox "$1" "${2:+$2:}$RECORD_BIN"
  SUDO_LOG="$(sudo_log "$1")" EVENT_LOG="$(event_log "$1")" SUDO_FAIL_ON="${3:-}"
  export SUDO_LOG EVENT_LOG SUDO_FAIL_ON
  unset SUDO_INT_ON SUDO_MARKER
  : >"$SUDO_LOG"
  : >"$EVENT_LOG"
}

# Source the script under test (default $SCRIPT) into the calling subshell; sourcing never runs main.
# Fails the test instead when HOME is not a sandbox home.
load_script() {
  require_sandbox_home "$TMP" load_script
  # shellcheck source=nvim-install.sh
  source "${1:-$SCRIPT}"
  setup_colors
}

# Runs the script under test as a command, after the wrapper command given as arguments (none, or
# fakeroot, for example). Fails the test instead when HOME is not a sandbox home.
run_script() {
  require_sandbox_home "$TMP" run_script
  "$@" "$SCRIPT"
}

# Runs the script under test with the given arguments (no wrapper). Fails the test instead when HOME is
# not a sandbox home.
run_script_args() {
  require_sandbox_home "$TMP" run_script_args
  "$SCRIPT" "$@"
}

# Copies the script under test to file $1 with the one line that starts with $2 replaced by $3; fails
# the test unless exactly one line starts with $2
copy_script_with_line() {
  local copy="$1" prefix="$2" replacement="$3" line replaced=0
  mkdir -p "${copy%/*}"
  while IFS= read -r line; do
    if [[ "$line" == "$prefix"* ]]; then
      printf '%s\n' "$replacement"
      replaced=$((replaced + 1))
    else
      printf '%s\n' "$line"
    fi
  done <"$SCRIPT" >"$copy"
  if [[ $replaced -ne 1 ]]; then
    echo "copy_script_with_line: nvim-install.sh has $replaced lines starting with '$prefix', want 1"
    exit 1
  fi
}

# Copies the script under test to file $1 with the line that sets the readonly constant $2 replaced by
# one that sets it to $3, then sources the copy; fails the test unless exactly one line was replaced
load_script_with() {
  copy_script_with_line "$1" "readonly $2=" "$(printf 'readonly %s=%q' "$2" "$3")"
  load_script "$1"
}

# Copies the script under test into directory $1 (created when missing) and sources the copy, so
# SCRIPT_DIR is $1; fails the test unless it is, with NVIM_CONFIG_DIR under $TMP
load_script_copy() {
  mkdir -p "$1"
  cp "$SCRIPT" "$1/nvim-install.sh"
  load_script "$1/nvim-install.sh"
  if [[ $NVIM_CONFIG_DIR != "$TMP"/* || "$SCRIPT_DIR" != "$1" ]]; then
    echo "NVIM_CONFIG_DIR=$NVIM_CONFIG_DIR SCRIPT_DIR=$SCRIPT_DIR"
    exit 1
  fi
}

# Prints the value of the script's variable $1 (a constant such as GO_TOOL_LAZYGIT), read by sourcing
# the script in a sandbox, so nothing runs; fails (status 1, no output) when the script sets no such
# variable, and the caller reports it
script_constant() {
  (
    sandbox "constant-$1" ""
    load_script
    [[ -v "$1" ]] || exit 1
    printf '%s\n' "${!1}"
  ) </dev/null
}

# Prints the number of the first line of file $2 that matches the extended regex $1, or nothing
first_line() {
  grep -nE -m1 -- "$1" "$2" | cut -d: -f1
}

# Prints $1 with every extended regex special character escaped
# shellcheck disable=SC2001  # one sed bracket expression escapes every special character
ere_escape() { sed 's/[][\.*^$+?(){}|]/\\&/g' <<<"$1"; }

# Prints a problem when the sudo log $1 is missing or unreadable, or has a line that is not one of the
# only commands the script may run under sudo, as a recording sudo logs them (its arguments joined by
# spaces): sudo -v, -n -v (the checks for a live ticket), and -k, each package manager's refresh and
# install of plain package names (dnf's only with weak dependencies off), and the tarball install's
# exact steps, as as_root runs them, for the install dir $2 (default /opt/nvim); nothing otherwise
sudo_pkgs='( [A-Za-z0-9][A-Za-z0-9@._+-]*)+'
sudo_allowlist_problems() {
  local log="$1" dir outside allowlist
  dir="$(ere_escape "${2:-/opt/nvim}")"
  allowlist=(
    -e '-v' -e '-n -v' -e '-k'
    -e 'pacman -Syu' -e "pacman -S --noconfirm$sudo_pkgs"
    -e 'apt-get update -qq' -e "apt-get install -y$sudo_pkgs"
    -e "dnf install -y --setopt=install_weak_deps=False$sudo_pkgs"
    -e 'apk update' -e "apk add$sudo_pkgs"
    -e "rm -rf $dir" -e "mkdir -p $dir" -e "tar -C $dir --strip-components=1 -xzf /[^ ]+\\.tar\\.gz"
    -e "chown -R 0:0 $dir" -e "chmod -R go-w $dir"
    -e 'test -w /usr/local/bin' -e "ln -sf $dir/bin/nvim /usr/local/bin/nvim"
  )
  if [[ ! -f "$log" || ! -r "$log" ]]; then
    echo "[sudo log $log is missing or unreadable] "
    return
  fi
  outside="$(grep -vxE "${allowlist[@]}" "$log")"
  case $? in
    0) echo "[sudo commands outside the allowlist: $(tr '\n' ';' <<<"$outside")] " ;;
    1) ;;
    *) echo "[grep could not check $log against the allowlist] " ;;
  esac
}

# Prints a problem when the event log $1 has no sudo -k, or a sudo call after its first sudo -k other
# than another -k or forget_sudo_credentials's own sudo -n -v check: the forget in main is the final
# one, and nothing after it may take or use a ticket
no_sudo_after_final_forget() {
  local log="$1" k_line after
  k_line="$(first_line '^sudo -k$' "$log")"
  if [[ -z "$k_line" ]]; then
    echo "[no sudo -k in the event log] "
    return
  fi
  after="$(tail -n +"$((k_line + 1))" "$log" | grep -E '^sudo ' | grep -vxE 'sudo -k|sudo -n -v')"
  [[ -z "$after" ]] || echo "[sudo after the forget (sudo -k, line $k_line): $(tr '\n' ';' <<<"$after")] "
}

# Prints a problem unless each of the remaining arguments is a line of the event log $1 and their first
# occurrences come in the order given
order_problems() {
  local log="$1" entry line prev=0 ok=1 report=""
  shift
  for entry in "$@"; do
    line="$(first_line "^$(ere_escape "$entry")\$" "$log")"
    report+="$entry=${line:-none} "
    if [[ -z "$line" ]] || ((line <= prev)); then
      ok=0
    else
      prev="$line"
    fi
  done
  ((ok)) || echo "[order (first line of each): ${report% }] "
}

# Prints how PATH differs from $1, a PATH saved earlier: "unchanged", "install dir first" ($2/bin, the
# bin dir of install dir $2, then $1), or "other: <PATH>" (T25, T26)
path_change() {
  case "$PATH" in
    "$1") echo "unchanged" ;;
    "$2/bin:$1") echo "install dir first" ;;
    *) echo "other: $PATH" ;;
  esac
}

# Prints its input with the credentials in URLs (anything between :// and @) replaced by ***
redact_urls() { sed -E 's#(://)[^/@]*@#\1***@#g'; }

# Runs "$@" in a subshell with errexit on, as main runs it, and stores its exit status in RC. Call it
# as a plain statement: inside an if, ||, or && list, bash ignores errexit, even after set -e.
run_errexit() {
  local errexit_was=+e
  if [[ $- == *e* ]]; then
    errexit_was=-e
  fi
  set +e
  (
    set -e
    "$@"
  )
  RC=$?
  set "$errexit_was"
}

# Runs "$@" with stdin on /dev/null and prints "rc=<its status>" last. With python3, INT and TERM start
# at their defaults (a shell started with a signal ignored, as a background job of a script is, can
# neither trap nor reset it, and lists it as a trap), and death by signal N shows as rc=-N; without it,
# "$@" inherits this suite's dispositions, and death by INT or TERM shows as 130 or 143 (an exit status
# that would look the same).
signal_launcher='import signal, subprocess, sys
def default_signals():
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    signal.signal(signal.SIGTERM, signal.SIG_DFL)
r = subprocess.run(sys.argv[1:], stdin=subprocess.DEVNULL, preexec_fn=default_signals)
sys.stdout.write("rc=%d\n" % r.returncode)'
run_with_default_signals() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -I -c "$signal_launcher" "$@"
  else
    "$@" </dev/null
    echo "rc=$?"
  fi
}

# ---------------------------------------------------------------------------
# Stubs and fixtures
# ---------------------------------------------------------------------------

# Every stub the suite puts on PATH, as <dir>/<command>; the preflight below checks that each one wins
STUBS=()
# Copies the stub tests/lib/stubs/$3 into dir $1 (created when missing) as command $2, executable
add_stub() {
  mkdir -p "$1"
  cp "$LIB/stubs/$3" "$1/$2"
  chmod +x "$1/$2"
  STUBS+=("$1/$2")
}
# Links command $2 in dir $1 (created when missing) to the file $3
add_link() {
  mkdir -p "$1"
  ln -s "$3" "$1/$2"
  STUBS+=("$1/$2")
}

# Language package managers and AUR helpers: the script must never invoke one (T5 matches each name,
# with any version suffix), and DENY_BIN refuses them
FORBIDDEN_INSTALLERS=(npm npx pnpm yarn bun corepack pip pip3 pipx easy_install yay paru pikaur trizen aura makepkg)

# Commands no test may run for real: each stub (tests/lib/stubs/deny) logs "<name> <args>" to
# $TMP/refused.log (T21 fails when that log exists) and exits 1
DENY_BIN="$TMP/bin-deny"
for cmd in sudo curl wget go uv "${FORBIDDEN_INSTALLERS[@]}"; do
  add_stub "$DENY_BIN" "$cmd" deny
done

# sudo that appends its arguments to $SUDO_LOG and never runs them (tests/lib/stubs/recording-sudo, set
# up by recording_sandbox)
RECORD_BIN="$TMP/bin-record"
add_stub "$RECORD_BIN" sudo recording-sudo

# An empty dir, for a PATH on which no command resolves
EMPTY_BIN="$TMP/bin-empty"
mkdir -p "$EMPTY_BIN"

# The real tools a stub-only PATH may need: readlink (has_system_typescript)
TOOLS_BIN="$TMP/bin-tools"
add_link "$TOOLS_BIN" readlink "$(type -P readlink)"

# git stubs: NOCLONE_GIT_BIN's refuses to clone (no network); CLONE_GIT_BIN's clones offline, creating
# a repo whose origin is this repo with a marker file "cloned", and logs its arguments to $CLONE_LOG
# when set; APPEAR_GIT_BIN's clones the same way and then creates $HOME/.config/nvim with a file "stray"
# in it, standing in for a config dir that appears while the clone runs. Everything else goes to the
# real git. (No variable of the suite starts with GIT_: hermetic_env unsets those.) type -P searches
# PATH only, never a function.
REAL_GIT="$(type -P git)"
if [[ -z "$REAL_GIT" ]]; then
  echo "FAIL setup: git is not on PATH"
  exit 1
fi
NOCLONE_GIT_BIN="$TMP/bin-git"
CLONE_GIT_BIN="$TMP/bin-git-clone"
APPEAR_GIT_BIN="$TMP/bin-git-appear"
CLONE_GIT="$CLONE_GIT_BIN/git" CLONE_ORIGIN="$REPO_URL_HTTPS"
export REAL_GIT CLONE_GIT CLONE_ORIGIN
add_stub "$NOCLONE_GIT_BIN" git git-noclone
add_stub "$CLONE_GIT_BIN" git git-clone
add_stub "$APPEAR_GIT_BIN" git git-appear

# Package manager binaries for detection tests, which only look them up; they refuse and log like
# DENY_BIN's stubs
PKG_BIN="$TMP/bin-pkgmgr"
for mgr in pacman apt-get; do
  add_stub "$PKG_BIN" "$mgr" deny
done

# T17's go and uv: they log each call to $EVENT_LOG and install nothing
T17_BIN="$TMP/bin-T17"
add_stub "$T17_BIN" go t17-go
add_stub "$T17_BIN" uv t17-uv

# The Go tools install_user_tools installs, one GO_TOOL_<TOOL> constant each (T17 and T32 use it)
GO_TOOLS="shfmt goimports golangci-lint lazygit lazydocker"

# T19's go: it answers go env from T19_* variables
T19_BIN="$TMP/bin-T19"
add_stub "$T19_BIN" go t19-go

# T24's tsserver dirs: the tsserver of a fake TypeScript package, and of one whose version is empty, each
# linked into a dir of its own (as a bin dir links it), and a shim (a wrapper script in no package, as a
# version manager installs)
T24_PKGS="$TMP/T24-pkgs"
# $1 = package dir, $2 = its package.json
t24_package() {
  mkdir -p "$1/lib" "$1/bin"
  printf '%s\n' "$2" >"$1/package.json"
  printf '// tsserver\n' >"$1/lib/tsserver.js"
  printf '#!/bin/sh\nexit 0\n' >"$1/bin/tsserver"
  chmod +x "$1/bin/tsserver"
}
t24_package "$T24_PKGS/typescript" '{ "name": "typescript", "version": "5.9.3" }'
t24_package "$T24_PKGS/empty-version" '{ "name": "typescript", "version": "" }'
add_link "$TMP/bin-T24-package" tsserver "$T24_PKGS/typescript/bin/tsserver"
add_link "$TMP/bin-T24-empty-version" tsserver "$T24_PKGS/empty-version/bin/tsserver"
add_stub "$TMP/bin-T24-shim" tsserver t24-tsserver-shim

# T25's curl, which logs to $EVENT_LOG and copies this tiny local tarball
T25_BIN="$TMP/bin-T25"
add_stub "$T25_BIN" curl t25-curl
mkdir -p "$TMP/T25-src/nvim-linux/bin"
printf '#!/bin/sh\n' >"$TMP/T25-src/nvim-linux/bin/nvim"
tar -C "$TMP/T25-src" -czf "$TMP/T25-nvim.tar.gz" nvim-linux

# T26's nvim (T22 runs it too): it prints version $T26_VERSION
T26_BIN="$TMP/bin-T26"
add_stub "$T26_BIN" nvim t26-nvim
# T26's PATH dir for the cases with no nvim on PATH: the real tools those cases need, head and sed
# (get_nvim_version), cat (the install dir's nvim stub), and find (the install dir's ownership check)
T26_NO_NVIM_BIN="$TMP/bin-T26-no-nvim"
for tool in head sed cat find; do
  add_link "$T26_NO_NVIM_BIN" "$tool" "$(type -P "$tool")"
done

# T36's rpm: it answers rpm -q and rpm -q --whatprovides, as Fedora's rpm does, for the packages in
# $T36_INSTALLED
T36_BIN="$TMP/bin-T36"
add_stub "$T36_BIN" rpm t36-rpm

# The main drivers (T9, T17, T22, T23, T30) are committed scripts in tests/lib, each run as its own
# process inside a sandbox with the script under test as $1; they share tests/lib/driver-lib.sh, whose
# run_main_stubbed runs main itself (so main's real traps run) with each step main calls stubbed to log
# its name, except the ones the driver handles and the ones that run as they are, and stops on a step
# it does not know.

# A foreign config at $1: a git checkout whose origin is not this repo, with uncommitted work in it
foreign_config_fixture() {
  git init -q -b main "$1"
  git -C "$1" remote add origin "$FOREIGN_ORIGIN"
  printf 'local work\n' >"$1/untracked.lua"
}

# Prints what is wrong with the foreign config at $1 (made by foreign_config_fixture); nothing when
# it is intact
foreign_config_intact() (
  hermetic_env
  [[ -f "$1/untracked.lua" ]] || echo "[no untracked.lua in $1] "
  [[ "$(git -C "$1" remote get-url origin 2>/dev/null)" == "$FOREIGN_ORIGIN" ]] \
    || echo "[origin of $1 is not $FOREIGN_ORIGIN] "
)

# Preflight: each test puts its stub dirs first on PATH, so every stub must win there. Where one does not
# (a temp dir on a noexec mount: bash's PATH search skips files it cannot execute), the real command
# would run in its place, so the suite stops here, before any test.
for stub in "${STUBS[@]}"; do
  found="$(PATH="${stub%/*}:$PATH" type -P "${stub##*/}")"
  if [[ "$found" != "$stub" ]]; then
    echo "FAIL setup: the stub $stub does not win on PATH (${stub##*/} resolves to '${found:-nothing}');" \
      "is $TMP on a noexec mount? Set TMPDIR to a directory on a mount that allows running programs"
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# Host facts
# ---------------------------------------------------------------------------

# The package manager the script detects here (T2, T4, and T20 (b0) and (d) need pacman)
host_mgr="$( (
  sandbox host-mgr ""
  load_script
  detect_pkg_manager
  printf '%s\n' "$PKG_MGR"
) </dev/null 2>/dev/null)"

# How a run killed by INT or TERM ends, as run_with_default_signals reports it (T9, T30); empty when
# this suite cannot test signal handling (python3 missing, and this suite inherited signal dispositions)
INT_RC="" TERM_RC="" SIGNAL_NOTE=""
if command -v python3 >/dev/null 2>&1; then
  INT_RC=-2 TERM_RC=-15
elif [[ -z "$INHERITED_TRAPS" ]]; then
  INT_RC=130 TERM_RC=143 SIGNAL_NOTE=" (signal death not checked: python3 missing)"
fi

# The wrappers that report EUID 0 here without real root (T3, T26b), each a command line to split with
# read -ra: fakeroot, and unshare -r when this kernel lets an unprivileged user map itself to root in a
# user namespace. With none, those tests report it through report_no_fake_root.
FAKE_ROOT_WRAPPERS=()
if command -v fakeroot >/dev/null 2>&1; then
  FAKE_ROOT_WRAPPERS+=(fakeroot)
fi
if command -v unshare >/dev/null 2>&1 && unshare -r true >/dev/null 2>&1; then
  FAKE_ROOT_WRAPPERS+=("unshare -r")
fi
# Reports test $1, which needs a wrapper in FAKE_ROOT_WRAPPERS when there is none: a skip, or a failure
# under REQUIRE_ALL=1
report_no_fake_root() {
  local no_wrapper="neither fakeroot nor unshare -r works here"
  if [[ "${REQUIRE_ALL:-0}" == 1 ]]; then
    result "$1" 1 "$no_wrapper, and REQUIRE_ALL=1 forbids skipping"
  else
    echo "SKIP $1 ($no_wrapper)"
  fi
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

# T1: syntax, and shellcheck on the script, on this file, on the helpers, driver library, and drivers
# in tests/lib (following their source of the script and of each other), and on the stubs in
# tests/lib/stubs
if ! bash -n "$SCRIPT"; then
  result T1-static 1 "bash -n"
elif ! command -v shellcheck >/dev/null 2>&1; then
  echo "SKIP T1-static (shellcheck not installed; bash -n passed)"
else
  shellcheck "$SCRIPT" && shellcheck -x "${BASH_SOURCE[0]}" "$LIB"/*.sh && shellcheck "$LIB"/stubs/*
  result T1-static $?
fi

# T2: the plan screen names the platform and, on pacman, the upfront system upgrade; "n" cancels
# cleanly (exit 0), and end of input (no terminal to answer from, as in a piped run) stops the run with
# exit 1 and says why
if [[ "$host_mgr" != pacman ]]; then
  echo "SKIP T2-plan-screen (the script detects '${host_mgr:-nothing}' here, not pacman)"
else
  out="$( (
    sandbox T2 ""
    printf 'n\n' | run_script
  ) 2>&1)"
  rc=$?
  eof_out="$( (
    sandbox T2-eof ""
    run_script
  ) </dev/null 2>&1)"
  eof_rc=$?
  absent=""
  for want in 'OS: +linux' 'Architecture: +(x86_64|arm64)' 'Package manager: +pacman' 'Support tier: +first-class' \
    '0\. Upgrade the system first \(pacman -Syu' '1\. Install Neovim 0\.12\+' 'Cancelled\.'; do
    grep -qE "$want" <<<"$out" || absent+="[$want] "
  done
  [[ $rc -eq 0 && -z "$absent" && $eof_rc -eq 1 ]] \
    && grep -qF 'No answer (stdin is closed or not a terminal); run the script from a terminal' <<<"$eof_out" \
    && ! grep -qF 'Cancelled.' <<<"$eof_out" && ! grep -qE 'STUB .* BLOCKED' <<<"$out$eof_out"
  result T2-plan-screen $? "rc=$rc eof_rc=$eof_rc absent=$absent; EOF run: $(tail -n2 <<<"$eof_out" | tr '\n' ' ')"
fi

# Runs confirm_proceed, sourced so any host can run it, for package manager $2 and mode $3, answering "n",
# and prints its output (stdout and stderr) followed by NOT REACHED when it did not exit. OS, ARCH and
# USER_SHELL are set by hand, as detection would set them.
# $1 = case id, $2 = package manager, $3 = PACKAGES_ONLY (true or false)
t2_plan() {
  (
    sandbox "T2-$1" ""
    load_script
    # shellcheck disable=SC2030,SC2034  # confirm_proceed, in the script sourced into this subshell, reads them
    OS=linux ARCH=x86_64 USER_SHELL=bash PACKAGES_ONLY="$3"
    set_pkg_manager "$2"
    confirm_proceed <<<"n"
    echo "NOT REACHED"
  ) 2>&1
}
# T2b: the plan screen for dnf names the supported tier and its notice (which names no distro, since RHEL
# and CentOS reach this tier too, and gives the tarball fallback for a repo Neovim that is missing or
# older than the script's MIN_NVIM_VERSION), lists the language servers in step 2, has no upfront
# upgrade and no best-effort text, shows Mode: full with the clone step, and "n" cancels with exit 0.
t2_fail=""
out="$(t2_plan dnf dnf false)"
rc=$?
t2_min_version="$(script_constant MIN_NVIM_VERSION)" || t2_fail+="[the script sets no MIN_NVIM_VERSION] "
for want in 'Support tier: +supported' 'Mode: +full$' 'dnf is supported' \
  "Neovim comes from the release tarball when the repo's is missing or older than $(ere_escape "$t2_min_version")" \
  'lazygit and lazydocker come from go install at pinned versions in the full run' \
  '1\. Install Neovim 0\.12\+ \(prefer dnf' \
  '2\. Install build tools, clipboard, runtimes, language servers, formatters, linters, TUI tools$' \
  '3\. Clone config' 'Cancelled\.'; do
  grep -qE "$want" <<<"$out" || t2_fail+="[dnf: missing $want] "
done
[[ $rc -eq 0 ]] || t2_fail+="[dnf: rc=$rc $(tail -n2 <<<"$out" | tr '\n' ' ')] "
for unwanted in 'pacman -Syu' 'best-effort' 'manual steps\)' 'Fedora' 'NOT REACHED'; do
  ! grep -qE "$unwanted" <<<"$out" || t2_fail+="[dnf: shows $unwanted] "
done
expect_none T2b-dnf-plan-screen "$t2_fail"

# T2c: in packages-only mode the plan screen says so and ends with the packages (no clone step)
t2_fail=""
out="$(t2_plan dnf-packages-only dnf true)"
rc=$?
for want in 'Support tier: +supported' 'Mode: +packages only$' '2\. Install build tools' 'Cancelled\.'; do
  grep -qE "$want" <<<"$out" || t2_fail+="[packages-only: missing $want] "
done
[[ $rc -eq 0 ]] && ! grep -qE 'Clone config|NOT REACHED' <<<"$out" \
  || t2_fail+="[packages-only: rc=$rc $(tail -n2 <<<"$out" | tr '\n' ' ')] "
expect_none T2c-packages-only-plan-screen "$t2_fail"

# T2d: the plan screen for apt-get names the best-effort tier and its notice, which says the go install and
# uv tool install fallbacks happen in the full run (packages-only stops before them), and shows no dnf text
t2_fail=""
out="$(t2_plan apt-get-best-effort apt-get false)"
rc=$?
for want in 'Support tier: +best-effort' 'Mode: +full$' \
  'apt-get is best-effort: tools missing from its repos are installed with go install \(pinned versions\) or uv tool install \(latest upstream\) in the full run when available, otherwise listed as manual steps at the end\.' \
  'Cancelled\.'; do
  grep -qE "$want" <<<"$out" || t2_fail+="[apt-get: missing $want] "
done
[[ $rc -eq 0 ]] || t2_fail+="[apt-get: rc=$rc $(tail -n2 <<<"$out" | tr '\n' ' ')] "
for unwanted in 'dnf' 'pacman -Syu' 'NOT REACHED'; do
  ! grep -qE "$unwanted" <<<"$out" || t2_fail+="[apt-get: shows $unwanted] "
done
expect_none T2d-best-effort-plan-screen "$t2_fail"

# T3: root guard, under every wrapper that reports EUID 0 here (FAKE_ROOT_WRAPPERS: fakeroot, and
# unshare -r when the kernel allows it). With REQUIRE_ALL=1, having neither fails instead of skipping.
if [[ ${#FAKE_ROOT_WRAPPERS[@]} -gt 0 ]]; then
  t3_fail=""
  for wrapper in "${FAKE_ROOT_WRAPPERS[@]}"; do
    read -ra wrapper_cmd <<<"$wrapper"
    out="$( (
      sandbox T3 ""
      run_script "${wrapper_cmd[@]}"
    ) </dev/null 2>&1)"
    rc=$?
    [[ $rc -eq 1 ]] && grep -qF "Do not run this script as root" <<<"$out" \
      || t3_fail+="[$wrapper: rc=$rc $(tail -n2 <<<"$out" | tr '\n' ' ')] "
  done
  t3_ran="$(printf '%s, ' "${FAKE_ROOT_WRAPPERS[@]}")"
  expect_none "T3-root-guard (${t3_ran%, })" "$t3_fail"
else
  report_no_fake_root T3-root-guard
fi

# T4 (RUN_FULL=1, Arch only): runs the real script end to end on this machine. First the suite runs
# the real sudo -k, which drops this terminal's cached ticket and never prompts or elevates, so the
# verification launch's plugin builds never inherit one. On a fully provisioned machine nothing is
# installed: the script's sudo is a stub that allows only "sudo -k" (forget_sudo_credentials) and
# refuses and logs everything else, so any install, or the upfront upgrade, fails the test, and T4
# fails unless the log holds the script's own sudo -k. HOME stays real, because the run must find the
# real checkout, so T4 runs only when ~/.config/nvim is a clone of this repo (setup_config then leaves
# it in place). The verification launch needs network: lazy.nvim bootstraps itself and installs every
# plugin, running their build steps, into scratch XDG dirs whose config is a copy of this checkout, so
# the real checkout, its plugins, and lazy-lock.json are never written. That is why T4 skips
# hermetic_env: it keeps the real PATH and git config, and the suite never sets GIT_ALLOW_PROTOCOL for
# it, since lazy.nvim clones over https (a value the caller set, to fence a run offline, passes
# through). It drops only the other inherited GIT_* variables (a hook's GIT_DIR, for example),
# ZDOTDIR, and the shell startup variables BASH_ENV, ENV, and CDPATH. URLs it prints (the origin, and
# the run's last lines) have any credentials in them replaced by ***.
if [[ "${RUN_FULL:-0}" != 1 ]]; then
  echo "SKIP T4 (set RUN_FULL=1 on a fully provisioned Arch machine)"
elif [[ "$host_mgr" != pacman ]]; then
  echo "SKIP T4 (not an Arch host)"
else
  t4_env() {
    local var
    for var in "${!GIT_@}"; do
      if [[ "$var" != GIT_ALLOW_PROTOCOL ]]; then
        unset "$var"
      fi
    done
    unset ZDOTDIR BASH_ENV ENV CDPATH
  }
  live_config="$HOME/.config/nvim"
  t4_git() { (
    t4_env
    GIT_OPTIONAL_LOCKS=0 git -C "$live_config" "$@"
  ); }
  # The stored origin URLs, for the message; the guard asks setup_config's own check
  live_remote="$(t4_git config --local --get-all remote.origin.url 2>/dev/null | tr '\n' ' ' || true)"
  if ! (
    sandbox T4-guard ""
    load_script
    t4_env
    export GIT_OPTIONAL_LOCKS=0
    is_config_checkout "$live_config"
  ) </dev/null >/dev/null 2>&1; then
    result T4-idempotent-run 1 \
      "stored origin URLs of $live_config are '$(redact_urls <<<"$live_remote")', not this repo; refusing a full run"
  else
    xdg="$TMP/T4-xdg"
    mkdir -p "$xdg/config/nvim" "$xdg/data" "$xdg/state" "$xdg/cache" "$TMP/T4-tmp" "$TMP/bin-T4"
    tar -C "$ROOT" --exclude=./.git -cf - . | tar -C "$xdg/config/nvim" -xf -
    cat >"$TMP/bin-T4/sudo" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$TMP/T4-sudo.log"
if [ "\$*" = -k ]; then
  exit 0
fi
echo "STUB SUDO BLOCKED: \$*" >&2
exit 1
EOF
    chmod +x "$TMP/bin-T4/sudo"
    status_before="$(t4_git status --porcelain --untracked-files=all)"
    # Drops this terminal's cached sudo ticket, so the verification launch's plugin builds never
    # inherit it; sudo -k never prompts or elevates
    command sudo -k 2>/dev/null || true
    out="$( (
      t4_env
      printf 'y\n' | PATH="$TMP/bin-T4:$PATH" TMPDIR="$TMP/T4-tmp" XDG_CONFIG_HOME="$xdg/config" \
        XDG_DATA_HOME="$xdg/data" XDG_STATE_HOME="$xdg/state" XDG_CACHE_HOME="$xdg/cache" "$SCRIPT"
    ) 2>&1)"
    rc=$?
    status_after="$(t4_git status --porcelain --untracked-files=all)"
    t4_sudo="$(grep -vxF -- -k "$TMP/T4-sudo.log" 2>/dev/null)"
    problems=""
    [[ $rc -eq 0 ]] || problems+="[rc=$rc] "
    [[ -z "$t4_sudo" ]] || problems+="[sudo called other than -k: $(tr '\n' ';' <<<"$t4_sudo")] "
    grep -qxF -- -k "$TMP/T4-sudo.log" 2>/dev/null || problems+="[the script never ran sudo -k] "
    ! grep -qE '==> .*(Installing|Upgrading)' <<<"$out" || problems+="[installed or upgraded something] "
    grep -qF "Config already present at $live_config" <<<"$out" || problems+="[config not found in place] "
    grep -qF "Neovim Bootstrap Complete" <<<"$out" || problems+="[no summary] "
    if ! command -v hadolint >/dev/null 2>&1; then
      grep -qF "hadolint: not in the official repos" <<<"$out" || problems+="[no hadolint hint] "
    fi
    [[ "$status_before" == "$status_after" ]] || problems+="[the run changed $live_config] "
    [[ -z "$problems" ]] || problems+="; last lines: $(tail -n8 <<<"$out" | redact_urls | tr '\n' ' ')"
    expect_none T4-idempotent-run "$problems"
  fi
fi

# T5: no invocation of a language package manager or an AUR helper (FORBIDDEN_INSTALLERS, with any
# version suffix, such as pip3.12), and no AUR URL; the only match is the hadolint warn line, which names
# an AUR helper as a manual step
forbidden_re="$(IFS='|'; printf '%s' "${FORBIDDEN_INSTALLERS[*]}")"
matches="$(grep -nE "\\b($forbidden_re)[0-9.]*\\b|aur\\.archlinux\\.org" "$SCRIPT")"
[[ "$(wc -l <<<"$matches")" -eq 1 ]] && grep -q 'warn "hadolint' <<<"$matches"
result T5-no-forbidden-installers $? "$matches"

# T6: no leftovers from removed tools
leftovers="$(grep -nE 'lazysql|posting|brew|darwin|Darwin|xcode' "$SCRIPT")"
case $? in
  1) result T6-no-leftovers 0 ;;
  *) result T6-no-leftovers 1 "$leftovers" ;;
esac

# T7: install_pkgs modes, the optional retry, and no retry for a single package (package manager stubbed)
out="$( (
  sandbox T7 ""
  load_script
  set_pkg_manager pacman
  CALLS=0
  must_override pkg_is_installed
  must_override pkg_install
  pkg_is_installed() { return 1; }
  pkg_install() {
    local p
    CALLS=$((CALLS + 1))
    for p in "$@"; do
      if [[ "$p" == bad ]]; then return 1; fi
    done
    return 0
  }
  install_pkgs optional grp good bad >/dev/null
  [[ ${#WARNINGS[@]} -eq 1 && "${WARNINGS[0]}" == "bad: install failed, skipping" ]] \
    || { echo "optional warnings (${#WARNINGS[@]}): ${WARNINGS[*]}"; exit 1; }
  CALLS=0
  install_pkgs optional grp bad >/dev/null
  [[ $CALLS -eq 1 ]] || { echo "single missing package: $CALLS pkg_install calls"; exit 1; }
  run_errexit install_pkgs required grp bad >/dev/null 2>&1
  [[ $RC -eq 1 ]] || { echo "required rc=$RC"; exit 1; }
  run_errexit install_pkgs typo grp good >/dev/null 2>&1
  [[ $RC -eq 1 ]] || { echo "typo mode rc=$RC"; exit 1; }
  echo DONE
) </dev/null 2>&1)"
done_ok $? "$out"
result T7-install-pkgs $? "$(tail -n3 <<<"$out")"

# T8: os_release_pkg_mgr maps the os-release file it is given (default /etc/os-release) to a package
# manager; detect_pkg_manager trusts that over binaries on PATH and probes binaries (pacman first)
# only when os-release names nothing usable. There is no environment hook for the os-release path.
osr="$TMP/os-release"
mkdir -p "$osr"
printf 'ID=debian\n' >"$osr/debian"
printf 'ID=linuxmint\nID_LIKE="ubuntu debian"\n' >"$osr/mint"
printf 'ID=endeavouros\nID_LIKE=arch\n' >"$osr/endeavouros"
printf 'ID=fedora\n' >"$osr/fedora"
printf 'ID="rocky"\nID_LIKE="rhel centos fedora"\n' >"$osr/rocky"
printf 'ID=alpine\n' >"$osr/alpine"
printf 'ID=void\n' >"$osr/void"
out="$( (
  sandbox T8 ""
  load_script
  for tc in debian:apt-get mint:apt-get endeavouros:pacman fedora:dnf rocky:dnf alpine:apk void: absent:; do
    got="$(os_release_pkg_mgr "$osr/${tc%%:*}")"
    [[ "$got" == "${tc#*:}" ]] || { echo "os_release_pkg_mgr ${tc%%:*}: want '${tc#*:}', got '$got'"; exit 1; }
  done
  [[ "$(os_release_pkg_mgr)" == "$(os_release_pkg_mgr /etc/os-release)" ]] \
    || { echo "no argument does not read /etc/os-release"; exit 1; }
  # Detection sees only the stub pacman and apt-get; os_release_pkg_mgr stands in for the file
  must_override os_release_pkg_mgr
  for tc in "apt-get:apt-get best-effort" "pacman:pacman first-class" ":pacman first-class" \
    "dnf:pacman first-class"; do
    OSR_MGR="${tc%%:*}"
    os_release_pkg_mgr() { printf '%s\n' "$OSR_MGR"; }
    # shellcheck disable=SC2030  # os-release detection, in the script sourced into this subshell, sets both
    PKG_MGR="" PKG_TIER=""
    PATH="$PKG_BIN" detect_pkg_manager
    [[ "$PKG_MGR $PKG_TIER" == "${tc#*:}" ]] \
      || { echo "os-release '$OSR_MGR': want '${tc#*:}', got '$PKG_MGR $PKG_TIER'"; exit 1; }
  done
  echo DONE
) </dev/null 2>&1)"
done_ok $? "$out" && ! grep -nE 'OS_RELEASE_FILE|NVIM_INSTALL_OS_RELEASE' "$SCRIPT"
result T8-detection $? "$(tail -n3 <<<"$out")"

# T8b: set_pkg_manager takes only the four supported managers and sets each one's tier (pacman
# first-class, dnf supported, apt-get and apk best-effort); anything else stops the run, so no install
# function runs with a manager its case statements do not know (pkg_install would do nothing and succeed)
out="$( (
  sandbox T8b ""
  load_script
  for tc in pacman:first-class dnf:supported apt-get:best-effort apk:best-effort; do
    set_pkg_manager "${tc%%:*}"
    # shellcheck disable=SC2031  # set_pkg_manager, in the script sourced into this subshell, sets both
    [[ "$PKG_MGR" == "${tc%%:*}" && "$PKG_TIER" == "${tc#*:}" ]] \
      || { echo "${tc%%:*}: PKG_MGR=$PKG_MGR PKG_TIER=$PKG_TIER, want tier ${tc#*:}"; exit 1; }
  done
  run_errexit set_pkg_manager bogus
  echo "bogus rc=$RC"
  echo DONE
) </dev/null 2>&1)"
done_ok $? "$out" && grep -qxF "bogus rc=1" <<<"$out" \
  && grep -qF "set_pkg_manager: unknown package manager 'bogus'" <<<"$out"
result T8b-unknown-manager $? "$(tail -n3 <<<"$out" | tr '\n' ' ')"

# T9: sourcing sets no traps; main sets them, and INT or TERM then runs the EXIT cleanup (removing the
# temp dir and the clone staging dir, and dropping the sudo ticket the script took) and kills the
# script with the same signal instead of resuming, so a calling shell or loop sees the interrupt. A
# driver (tests/lib/driver-T9.sh) runs main as its own process with a real signal: its install_neovim
# takes a ticket through ensure_sudo_ticket against the recording sudo, creates the scratch dirs, and
# signals the shell. run_with_default_signals starts it with INT and TERM at their defaults and reports
# how it ended (with python3, death by signal N is return code -N; exit 130 or 143 would look like an
# ordinary failure), so this checks the behavior (no resume, scratch dirs removed, the ticket dropped,
# signal death), not just the trap text. Without python3 the driver inherits this suite's dispositions,
# so T9 is skipped when the suite started with INT or TERM ignored or trapped.
t9_signal() {
  local sig="$1"
  (
    recording_sandbox "T9-$sig"
    TMPDIR="$TMP/T9-$sig-tmp" T9_SIG="$sig"
    export TMPDIR T9_SIG
    mkdir -p "$TMPDIR"
    run_with_default_signals bash "$LIB/driver-T9.sh" "$SCRIPT"
  ) </dev/null 2>&1
}
if [[ -z "$INT_RC" ]]; then
  echo "SKIP T9-signal-traps (python3 missing, and this suite inherited signal dispositions: $INHERITED_TRAPS)"
else
  t9_fail=""
  for tc in "INT:$INT_RC" "TERM:$TERM_RC"; do
    sig="${tc%%:*}"
    out="$(t9_signal "$sig")"
    got="$(sed -n 's/^rc=//p' <<<"$out" | tail -n1)"
    created="$(sed -n 's/^TMPDIR_CREATED //p' <<<"$out")"
    staging="$(sed -n 's/^STAGING_CREATED //p' <<<"$out")"
    t9_log="$(sudo_log "T9-$sig")"
    problems=""
    [[ "$got" == "${tc#*:}" && -n "$created" && ! -e "$created" && -n "$staging" && ! -e "$staging" ]] \
      && ! grep -qxF RESUMED <<<"$out" \
      || problems+="[rc=${got:-none} created='$created' staging='$staging' $(tail -n2 <<<"$out" | tr '\n' ' ')] "
    # The ticket taken, then cleanup's sudo -k after the signal, and nothing else
    [[ "$(tr '\n' ' ' <"$t9_log")" == "-v -k " ]] || problems+="[sudo log: $(tr '\n' ';' <"$t9_log")] "
    problems+="$(sudo_allowlist_problems "$t9_log")"
    ! grep -qxF install_deps "$(event_log "T9-$sig")" || problems+="[main went on to install_deps] "
    [[ -z "$problems" ]] || t9_fail+="[$sig: $problems] "
  done
  expect_none "T9-signal-traps$SIGNAL_NOTE" "$t9_fail"
fi

# T10: is_config_repo_url accepts this repo's HTTPS URL (with or without .git, with a trailing slash),
# SCP-style SSH, and ssh:// forms (an HTTPS URL may name a user or token before the host), and nothing
# else (the URL spellings stay literal on purpose)
out="$( (
  sandbox T10-urls ""
  load_script
  # The clone URL is one this check accepts, spelled out here, so the script cannot clone one repo
  # and then call the clone foreign
  [[ $NVIM_REPO == "$REPO_URL_HTTPS" ]] && is_config_repo_url "$NVIM_REPO" || echo "BAD NVIM_REPO '$NVIM_REPO'"
  for url in https://github.com/jkleinne/nvim https://github.com/jkleinne/nvim.git \
    https://github.com/jkleinne/nvim/ https://github.com/jkleinne/nvim.git/ \
    https://x-access-token:SECRET@github.com/jkleinne/nvim.git \
    https://jkleinne@github.com/jkleinne/nvim \
    git@github.com:jkleinne/nvim git@github.com:jkleinne/nvim.git \
    ssh://git@github.com/jkleinne/nvim ssh://git@github.com/jkleinne/nvim.git; do
    is_config_repo_url "$url" || echo "BAD rejected '$url'"
  done
  for url in https://github.com/jkleinne/nvim-fork https://github.com/someone/nvim \
    http://github.com/jkleinne/nvim.git git@github.com:jkleinne/nvim/extra \
    https://u@github.com/someone/nvim https://jkleinne@github.com/jkleinne/nvim-fork \
    https://x-access-token:SECRET@evil.example/jkleinne/nvim \
    https://evil.example/x@github.com/jkleinne/nvim \
    'https://evil.example?x@github.com/jkleinne/nvim' \
    'https://evil.example#x@github.com/jkleinne/nvim.git' ""; do
    ! is_config_repo_url "$url" || echo "BAD accepted '$url'"
  done
  echo DONE
) </dev/null 2>&1)"
done_ok $? "$out" && ! grep -q '^BAD' <<<"$out"
result T10-repo-url-forms $? "$(grep '^BAD' <<<"$out" | tr '\n' ' ')$(tail -n1 <<<"$out")"

MIRROR_URL="https://example.invalid/mirror.git"
MIRROR2_URL="https://example.invalid/mirror2.git"

# Makes a checkout at $1 whose origin has the URLs in $2 (space-separated, fetch URL first; none for
# no origin), then runs the command "${@:3}" (when given) inside it
checkout_fixture() {
  local dir="$1" url urls
  read -ra urls <<<"$2"
  shift 2
  git init -q -b main "$dir"
  if ((${#urls[@]})); then
    git -C "$dir" remote add origin "${urls[0]}"
  fi
  for url in "${urls[@]:1}"; do
    git -C "$dir" remote set-url --add origin "$url"
  done
  if (($#)); then
    (cd "$dir" && "$@")
  fi
}

# Defines origin as URL $1 in a file the checkout's git config includes, not in the config itself
# shellcheck disable=SC2329  # checkout_fixture runs it, by name, through t10_present_case
origin_in_include() {
  git config -f .git/origin.inc remote.origin.url "$1"
  git config include.path origin.inc
}

# Runs setup_config with ~/.config/nvim a checkout_fixture of origin URLs $2 and command "${@:3}",
# and reports result $1: the checkout counts as this repo, so it stays in place
t10_present_case() {
  local id="$1" origins="$2" out rc config backups
  shift 2
  out="$( (
    sandbox "$id" "$NOCLONE_GIT_BIN"
    checkout_fixture "$HOME/.config/nvim" "$origins" "$@"
    printf 'local work\n' >"$HOME/.config/nvim/untracked.lua"
    load_script
    [[ $NVIM_CONFIG_DIR == "$TMP"/* ]] || { echo "NVIM_CONFIG_DIR=$NVIM_CONFIG_DIR"; exit 1; }
    setup_config
    echo DONE
  ) </dev/null 2>&1)"
  rc=$?
  config="$(sandbox_home "$id")/.config/nvim"
  backups="$(compgen -G "$config.bak.*" || true)"
  done_ok $rc "$out" && grep -qF "Config already present" <<<"$out" \
    && [[ -f "$config/untracked.lua" && -z "$backups" ]] && ! grep -qF "token@" <<<"$out"
  result "$id" $? "rc=$rc backups=[$backups]; $(tail -n3 <<<"$out" | tr '\n' ' ')"
}
# An SSH origin counts as this repo
t10_present_case T10-ssh-remote git@github.com:jkleinne/nvim.git
# Every URL of origin counts, as stored and as url.<base>.insteadOf rewrites it: URLs added for
# pushing (this repo's first, last, or in the middle), a rule that adds a token, a short alias, a rule
# that rewrites to a form this check rejects (an SSH host alias; only the stored URL matches), and an
# origin defined in an included file (only the rewritten read sees it, since --local skips includes)
t10_present_case T10-mirror-after "$REPO_URL_HTTPS $MIRROR_URL"
t10_present_case T10-mirror-before "$MIRROR_URL $REPO_URL_HTTPS"
t10_present_case T10-mirror-middle "$MIRROR_URL $REPO_URL_HTTPS $MIRROR2_URL"
t10_present_case T10-insteadof-remote "$REPO_URL_HTTPS" \
  git config url."https://token@github.com/".insteadOf "https://github.com/"
t10_present_case T10-alias-remote gh:jkleinne/nvim git config url."https://github.com/".insteadOf gh:
t10_present_case T10-insteadof-unrecognized "$REPO_URL_HTTPS" \
  git config url."git@github-personal:".insteadOf "https://github.com/"
t10_present_case T10-include-origin "" origin_in_include "$REPO_URL_HTTPS"

# A directory outside any repository never counts as this repo, not even with an origin in the
# global git config: neither the config dir nor the directory the script runs from (a plain copy)
out="$( (
  sandbox T10-global-origin "$NOCLONE_GIT_BIN"
  mkdir -p "$HOME/.config/nvim"
  export GIT_CONFIG_GLOBAL="$HOME/global-gitconfig"
  git config --global remote.origin.url "$REPO_URL_HTTPS"
  load_script_copy "$HOME/plain"
  setup_config
  echo DONE
) </dev/null 2>&1)"
done_ok $? "$out" && grep -qF "is not this repo" <<<"$out" && ! grep -qF "Config already present" <<<"$out"
result T10-global-origin-ignored $? "$(tail -n3 <<<"$out" | tr '\n' ' ')"

# T11: run from a clone of the repo elsewhere, setup_config skips before any prompt or move, even when told y.
# A copy of the script in a scratch clone makes SCRIPT_DIR that clone; the git stub refuses clone.
# t11_case <result> <origin URLs> [command]: the clone is a checkout_fixture of those arguments.
t11_case() {
  local id="$1" origins="$2" out rc config backups problems
  shift 2
  out="$( (
    sandbox "$id" "$NOCLONE_GIT_BIN"
    foreign_config_fixture "$HOME/.config/nvim"
    checkout_fixture "$HOME/src/nvim" "$origins" "$@"
    load_script_copy "$HOME/src/nvim"
    printf 'y\n' | setup_config
    echo DONE
  ) </dev/null 2>&1)"
  rc=$?
  config="$(sandbox_home "$id")/.config/nvim"
  backups="$(compgen -G "$config.bak.*" || true)"
  problems="$(foreign_config_intact "$config")"
  done_ok $rc "$out" && grep -qF "Skipping automatic config setup" <<<"$out" && [[ -z "$problems" && -z "$backups" ]]
  result "$id" $? "rc=$rc backups=[$backups] $problems; $(tail -n4 <<<"$out" | tr '\n' ' ')"
}
t11_case T11-no-move-from-foreign-clone "$REPO_URL_HTTPS"
# The same for a clone with a second URL, before or after this repo's
t11_case T11-mirror-after "$REPO_URL_HTTPS $MIRROR_URL"
t11_case T11-mirror-before "$MIRROR_URL $REPO_URL_HTTPS"

# T11b: run with no script file (bash -c, or a pipe), SCRIPT_DIR is empty, and setup_config skips its
# checks for running from a checkout: with no config yet, it clones. The working directory is a clone
# of this repo, which an empty path given to git -C or cd would stand for.
out="$( (
  sandbox T11b "$CLONE_GIT_BIN"
  git init -q -b main "$HOME/src/nvim"
  git -C "$HOME/src/nvim" remote add origin "$REPO_URL_HTTPS"
  load_script
  SCRIPT_DIR=""
  cd "$HOME/src/nvim" || exit 1
  run_errexit setup_config
  echo "setup_config rc=$RC"
  echo DONE
) </dev/null 2>&1)"
done_ok $? "$out" && grep -qxF "setup_config rc=0" <<<"$out" && [[ -f "$(sandbox_home T11b)/.config/nvim/cloned" ]]
result T11b-no-script-dir-clones $? "$(tail -n3 <<<"$out" | tr '\n' ' ')"

# T12: the first real install checks sudo once and runs pacman -Syu once, before any pacman -S;
# installing Neovim goes through the same path, apt-get and apk refresh once (also across a whole
# install_deps), dnf never refreshes (its first install follows the ticket check directly) and installs
# with weak dependencies off, nothing missing means no sudo, and a missing sudo binary stops the first
# install. A whole install_deps runs on a PATH of the recording sudo, DENY_BIN, and TOOLS_BIN only.
# $1 = case id, $2 = package manager, $3 = steps: pkgs, neovim, or deps with every package missing,
# or installed-pkgs (pkgs with every package already installed)
t12_case() {
  (
    recording_sandbox "T12-$1"
    load_script
    set_pkg_manager "$2"
    must_override pkg_is_installed
    if [[ "$3" == installed-pkgs ]]; then
      pkg_is_installed() { return 0; }
    else
      pkg_is_installed() { return 1; }
    fi
    case "$3" in
      pkgs | installed-pkgs) install_pkgs optional "group one" a b && install_pkgs optional "group two" c ;;
      neovim) pkg_install neovim && install_pkgs optional "group" d ;;
      deps) PATH="$RECORD_BIN:$DENY_BIN:$TOOLS_BIN" install_deps ;;
    esac >/dev/null
    echo DONE
  ) </dev/null 2>&1
}
# Prints the problems with a sudo log: $1 = log, $2 = refresh command, or empty for a manager with no
# upfront refresh (the first install then follows -v directly, and no manager's refresh appears), $3 =
# install command prefix
t12_check_log() {
  local log="$1" refresh="$2" install="$3" first_refresh first_install
  first_install="$(first_line "^$install" "$log")"
  [[ "$(head -n1 "$log")" == "-v" ]] || echo "[first sudo call is not -v]"
  [[ "$(grep -cxF -- "-v" "$log")" -eq 1 ]] || echo "[-v count $(grep -cxF -- "-v" "$log")]"
  if [[ -z "$refresh" ]]; then
    [[ "$first_install" == 2 ]] || echo "[$install (line ${first_install:-none}) does not follow -v directly]"
    ! grep -qxE 'pacman -Syu|apt-get update -qq|apk update' "$log" \
      || echo "[a refresh ran: $(grep -xE 'pacman -Syu|apt-get update -qq|apk update' "$log" | tr '\n' ';')]"
  else
    first_refresh="$(first_line "^$refresh\$" "$log")"
    [[ "$(grep -cxF -- "$refresh" "$log")" -eq 1 ]] || echo "[$refresh count $(grep -cxF -- "$refresh" "$log")]"
    [[ -n "$first_refresh" && -n "$first_install" && $first_refresh -lt $first_install ]] \
      || echo "[$refresh (line ${first_refresh:-none}) not before $install (line ${first_install:-none})]"
  fi
  sudo_allowlist_problems "$log"
}
t12_fail=""
for tc in "pacman-pkgs:pacman:pkgs:pacman -Syu:pacman -S --noconfirm" \
  "pacman-neovim:pacman:neovim:pacman -Syu:pacman -S --noconfirm neovim" \
  "apt-neovim:apt-get:neovim:apt-get update -qq:apt-get install -y neovim" \
  "apt-deps:apt-get:deps:apt-get update -qq:apt-get install -y" "apk-deps:apk:deps:apk update:apk add" \
  "dnf-neovim:dnf:neovim::dnf install -y --setopt=install_weak_deps=False neovim" \
  "dnf-deps:dnf:deps::dnf install -y --setopt=install_weak_deps=False"; do
  IFS=: read -r id mgr steps refresh install <<<"$tc"
  out="$(t12_case "$id" "$mgr" "$steps")"
  rc=$?
  log="$(sudo_log "T12-$id")"
  problems="$(t12_check_log "$log" "$refresh" "$install" | tr '\n' ' ')"
  done_ok $rc "$out" && [[ -z "$problems" ]] \
    || t12_fail+="[$id: rc=$rc $problems log: $(tr '\n' ';' <"$log")] "
done
out="$(t12_case all-installed pacman installed-pkgs)"
rc=$?
log="$(sudo_log T12-all-installed)"
done_ok $rc "$out" && [[ ! -s "$log" ]] || t12_fail+="[all-installed: rc=$rc sudo log: $(tr '\n' ';' <"$log")] "
# No sudo binary: the first install stops with a clear error. PATH is an empty dir; the guard,
# require_sudo, and error use only builtins.
out="$( (
  sandbox T12-no-sudo ""
  load_script
  set_pkg_manager pacman
  PATH="$EMPTY_BIN" run_errexit ensure_sudo_ticket
  echo "inner rc=$RC"
  echo DONE
) </dev/null 2>&1)"
rc=$?
done_ok $rc "$out" && grep -qxF "inner rc=1" <<<"$out" && grep -qF "sudo is required" <<<"$out" \
  || t12_fail+="[no-sudo: rc=$rc $(tail -n3 <<<"$out" | tr '\n' ' ')] "
expect_none T12-refresh-once "$t12_fail"

# The T13 family runs install_pkgs optional grp pkg (pkg missing) under errexit, as main runs it, with
# a recording sudo that fails on the given sudo arguments. $1 = test name (also the sandbox's and the
# sudo log's), $2 = package manager, $3 = the sudo arguments to fail on. Prints the output, then
# "WARNINGS: <the summary's warnings>" when install_pkgs returned, "inner rc=<its status>", and DONE.
failing_sudo_run() {
  (
    recording_sandbox "$1" "" "$3"
    load_script
    set_pkg_manager "$2"
    must_override pkg_is_installed
    # shellcheck disable=SC2329  # install_pkgs calls it, through run_errexit
    pkg_is_installed() { return 1; }
    # shellcheck disable=SC2329  # run_errexit calls it
    install_and_report() {
      install_pkgs optional grp pkg
      printf 'WARNINGS: %s\n' "${WARNINGS[*]}"
    }
    run_errexit install_and_report
    echo "inner rc=$RC"
    echo DONE
  ) </dev/null 2>&1
}

# T13 and T13c: a failed sudo command stops the run before any install. T13: a declined or failed
# pacman -Syu (no partial upgrade). T13c: a failed sudo -v (wrong password, or no sudo rights), before
# any package command. $1 = test name, $2 = the sudo arguments the recording sudo fails on, $3 = the
# message the run must print, $4 = text no logged sudo command may contain
sudo_failure_case() {
  local name="$1" fail_on="$2" message="$3" forbidden="$4" log out rc problems=""
  log="$(sudo_log "$name")"
  out="$(failing_sudo_run "$name" pacman "$fail_on")"
  rc=$?
  done_ok $rc "$out" && grep -qxF "inner rc=1" <<<"$out" || problems+="[rc=$rc, want inner rc=1] "
  grep -qF -- "$message" <<<"$out" || problems+="[no '$message' message] "
  ! grep -qF -- "$forbidden" "$log" || problems+="[a sudo command contains '$forbidden'] "
  problems+="$(sudo_allowlist_problems "$log")"
  [[ -z "$problems" ]] || problems+="; sudo log: $(tr '\n' ';' <"$log"); $(tail -n3 <<<"$out" | tr '\n' ' ')"
  expect_none "$name" "$problems"
}
sudo_failure_case T13-upgrade-declined "pacman -Syu" "partial upgrade" "-S --noconfirm"

# T13b: a failed apt-get update or apk update is best effort: it warns (the warning reaches the
# summary) and the install still runs, from the existing package lists or index
for tc in "apt-get:apt-get update -qq:apt-get install -y pkg:apt-get update failed" \
  "apk:apk update:apk add pkg:apk update failed"; do
  IFS=: read -r mgr refresh install warning <<<"$tc"
  out="$(failing_sudo_run "T13b-$mgr" "$mgr" "$refresh")"
  rc=$?
  log="$(sudo_log "T13b-$mgr")"
  t13b_update="$(first_line "^$refresh\$" "$log")"
  t13b_install="$(first_line "^$install\$" "$log")"
  problems=""
  done_ok $rc "$out" && grep -qxF "inner rc=0" <<<"$out" || problems+="[rc=$rc, want inner rc=0] "
  grep -qF -- "$warning" <<<"$(grep '^WARNINGS: ' <<<"$out")" || problems+="[no '$warning' among the warnings] "
  [[ -n "$t13b_update" && -n "$t13b_install" ]] && ((t13b_update < t13b_install)) \
    || problems+="[update line ${t13b_update:-none}, install line ${t13b_install:-none}] "
  problems+="$(sudo_allowlist_problems "$log")"
  [[ -z "$problems" ]] || problems+="; sudo log: $(tr '\n' ';' <"$log" 2>/dev/null); $(tail -n3 <<<"$out" | tr '\n' ' ')"
  expect_none "T13b-refresh-warns $mgr" "$problems"
done

sudo_failure_case T13c-sudo-v-fails "-v" "sudo authentication failed" "pacman"

# T14: confirm treats only y or Y as yes (status 0); an empty answer, n, and anything else are no
# (status 1), and so is end of input, with a status of its own (2), so confirm_proceed can tell that no
# one could answer. Every prompt in the script goes through it.
out="$( (
  sandbox T14 ""
  load_script
  status=0
  confirm "q" </dev/null || status=$?
  [[ $status -eq 2 ]] || { echo "end of input: status $status, want 2"; exit 1; }
  printf 'y\n' | confirm "q" || { echo "y counted as no"; exit 1; }
  printf 'Y\n' | confirm "q" || { echo "Y counted as no"; exit 1; }
  for answer in n '' yes; do
    status=0
    printf '%s\n' "$answer" | confirm "q" || status=$?
    [[ $status -eq 1 ]] || { echo "'$answer': status $status, want 1"; exit 1; }
  done
  echo DONE
) </dev/null 2>&1)"
rc=$?
# Every read, mapfile, or readarray builtin call on a non-comment line sits inside confirm(), and there
# is exactly one. A call that reads a here-string (version_gte) or a process substitution
# (is_config_checkout) parses a string or a command's output, not the terminal, so it does not count.
reads="$(awk '
  /^confirm\(\) \{/ { inside = 1 }
  !/^[[:space:]]*#/ && /(^|[;&|({[:space:]])(read|mapfile|readarray)([[:space:]]|$)/ && !/<<</ && !/< <\(/ {
    print (inside ? "inside" : "outside") " confirm, line " NR ": " $0
  }
  inside && /^\}/ { inside = 0 }
' "$SCRIPT")"
done_ok $rc "$out" && [[ "$(wc -l <<<"$reads")" -eq 1 && "$reads" == "inside confirm"* ]]
result T14-confirm-eof $? "rc=$rc reads: $(tr '\n' ';' <<<"$reads"); $(tail -n2 <<<"$out" | tr '\n' ' ')"

# T15: the PATH hint for a user tool's bin dir appends, so user dirs never shadow system binaries; fish
# gets its own line, which needs --path to append
for tc in "bash:export PATH=\"\$PATH:/nonexistent/bin\"" "fish:fish_add_path --append --path /nonexistent/bin"; do
  out="$( (
    sandbox "T15-${tc%%:*}" ""
    load_script
    USER_SHELL="${tc%%:*}"
    warn_if_not_on_path /nonexistent/bin
    echo DONE
  ) </dev/null 2>&1)"
  done_ok $? "$out" && grep -qF -- "${tc#*:}" <<<"$out"
  result "T15-path-hint-appends ${tc%%:*}" $? "$(head -n1 <<<"$out")"
done

# setup_path (tarball installs) prepends /opt/nvim/bin instead, so the tarball's nvim comes before an
# older packaged one, and writes its line into the shell's config file once (fish: config.fish, with
# --path; bash: .bashrc)
for tc in "fish:.config/fish/config.fish:fish_add_path --path /opt/nvim/bin" \
  "bash:.bashrc:export PATH=\"/opt/nvim/bin:\$PATH\""; do
  IFS=: read -r t15_shell t15_rc t15_line <<<"$tc"
  out="$( (
    sandbox "T15-setup-path-$t15_shell" ""
    load_script
    # shellcheck disable=SC2030,SC2034  # setup_path, in the script sourced into this subshell, reads both
    NEED_PATH_SETUP=true USER_SHELL="$t15_shell"
    rc_file="$HOME/$t15_rc"
    mkdir -p "${rc_file%/*}"
    printf '# existing\n' >"$rc_file"
    for run in 1 2; do
      setup_path >/dev/null
      count="$(grep -cxF -- "$t15_line" "$rc_file" || true)"
      [[ $count -eq 1 ]] || { echo "run $run: $count matching lines; $t15_rc: $(tr '\n' ';' <"$rc_file")"; exit 1; }
    done
    echo DONE
  ) </dev/null 2>&1)"
  done_ok $? "$out"
  result "T15-setup-path-prepends $t15_shell" $? "$(tail -n2 <<<"$out" | tr '\n' ' ')"
done

# T15b: path_line rejects a mode other than append or prepend (status 1, with an error) instead of
# printing nothing, so a typo cannot drop a PATH line silently
out="$( (
  sandbox T15b ""
  load_script
  USER_SHELL=bash
  run_errexit path_line sideways /nonexistent/bin
  echo "path_line rc=$RC"
  echo DONE
) </dev/null 2>&1)"
done_ok $? "$out" && grep -qxF "path_line rc=1" <<<"$out" \
  && grep -qF "path_line: unknown mode 'sideways' (expected append or prepend)" <<<"$out"
result T15b-path-line-bad-mode $? "$(tail -n3 <<<"$out" | tr '\n' ' ')"

# T16: declining the config move (n, or end of input) leaves the foreign config untouched and
# returns, so the run goes on to the summary with the warning in it. The script runs from a plain
# directory, not a clone of this repo, so setup_config reaches the prompt; the git stub refuses clone.
t16_case() {
  local answer="$1"
  (
    sandbox "T16-$answer" "$NOCLONE_GIT_BIN"
    foreign_config_fixture "$HOME/.config/nvim"
    load_script_copy "$HOME/plain"
    if [[ "$answer" == eof ]]; then
      setup_config </dev/null
    else
      setup_config <<<"$answer"
    fi
    [[ "${WARNINGS[*]}" == *"Left $HOME/.config/nvim in place"* ]] || { echo "WARNINGS: ${WARNINGS[*]}"; exit 1; }
    echo DONE
  ) </dev/null 2>&1
}
t16_fail=""
for answer in n eof; do
  out="$(t16_case "$answer")"
  rc=$?
  t16_config="$(sandbox_home "T16-$answer")/.config/nvim"
  backups="$(compgen -G "$t16_config.bak.*" || true)"
  problems="$(foreign_config_intact "$t16_config")"
  done_ok $rc "$out" && grep -qF "Left $t16_config in place; move it aside yourself" <<<"$out" \
    && [[ -z "$problems" && -z "$backups" ]] \
    && ! grep -qF "STUB GIT CLONE BLOCKED" <<<"$out" \
    || t16_fail+="[$answer: rc=$rc backups=[$backups] $problems $(tail -n3 <<<"$out" | tr '\n' ' ')] "
done
expect_none T16-decline-move-continues "$t16_fail"

# The sandbox and log name of a T17 case: $1 = package manager, $2 = packages, $3 = the GOTOOLCHAIN
# value the caller exports (optional)
t17_case_name() {
  printf 'T17-%s-%s%s\n' "$1" "$2" "${3:+-inherited-$3}"
}

# T17: main runs every package install first (install_deps), then forgets cached sudo credentials
# once (sudo -k), then the go install and uv tool install user tools (install_user_tools), none of them
# under sudo, and no sudo runs after the forget. A driver (tests/lib/driver-T17.sh) runs main with
# install_deps and install_user_tools as they are and every other step stubbed. The forget runs also
# when every package is already installed (all-installed), so no sudo -v ran: a ticket from before the
# run may still be live. One event log records the sudo, go, and uv calls and the stubbed steps in
# order; go and uv are stubs (T17_BIN) whose installs only log, so nothing real is installed, and the go
# stub also logs GOTOOLCHAIN after each call: every go call must run with GOTOOLCHAIN=local, even when
# the caller exports another value (the inherited-auto case exports auto), every go install must name
# the pinned module of the script's GO_TOOL_<TOOL> constant, and setup_config (which the driver stubs to
# log the GOTOOLCHAIN it sees) must see what the caller had, unset or auto, so the setting never
# outlives install_go_tool. While main runs, PATH is three stub dirs and nothing else (T17_BIN: go and
# uv; RECORD_BIN: sudo; DENY_BIN: curl and wget, and refusals the others shadow), so no user tool name
# resolves and install_unless_on_path skips none of them; the driver stubs the TypeScript check (T24
# covers it), and nothing else on that code path runs an external command. Run for every non-pacman
# package manager: dnf installs only lazygit and lazydocker, with Go and no uv; apt-get and apk install
# the whole list.
# $1 = package manager, $2 = missing (every package missing) or all-installed, $3 = the GOTOOLCHAIN
# value the caller exports (optional; unset when empty)
t17_case() {
  local mgr="$1" pkgs="$2" inherited="${3:-}"
  (
    recording_sandbox "$(t17_case_name "$mgr" "$pkgs" "$inherited")" "$T17_BIN"
    [[ -z "$inherited" ]] || export GOTOOLCHAIN="$inherited"
    T17_MGR="$mgr" T17_PKGS="$pkgs" T17_PATH="$T17_BIN:$RECORD_BIN:$DENY_BIN"
    export T17_MGR T17_PKGS T17_PATH
    bash "$LIB/driver-T17.sh" "$SCRIPT"
    echo "driver rc=$?"
  ) </dev/null 2>&1
}
# Prints the problems with a T17 event log: $1 = log, $2 = the sudo -v calls expected, $3 = the uv tools
# expected (space-separated; when empty, no uv call of any kind), $4 = the Go tools expected
# (space-separated; each one's module comes from the script's GO_TOOL_<TOOL> constant, with - read as _),
# $5 = the GOTOOLCHAIN value the caller exported (optional; unset when empty). Each tool is installed
# once and nothing else is, the module's path ends in the tool's name (or its name and a /vN major
# version), every go call runs with GOTOOLCHAIN=local whatever the caller exported, and setup_config sees
# the caller's value again.
t17_check_events() {
  local log="$1" want_v="$2" uv_tools="$3" go_tools="$4" k_line first_tool tool var module go_calls setup_config_lines
  local want_setup_config="${5:-unset}"
  [[ "$(grep -cxF 'sudo -v' "$log")" -eq "$want_v" ]] || echo "[sudo -v count $(grep -cxF 'sudo -v' "$log"), want $want_v]"
  [[ "$(grep -cxF 'sudo -k' "$log")" -eq 1 ]] || echo "[sudo -k count $(grep -cxF 'sudo -k' "$log"), want 1]"
  k_line="$(first_line '^sudo -k$' "$log")"
  first_tool="$(first_line '^(go|uv) ' "$log")"
  [[ -n "$k_line" && -n "$first_tool" ]] && ((k_line < first_tool)) \
    || echo "[first sudo -k (line ${k_line:-none}) not before the first go or uv call (line ${first_tool:-none})]"
  no_sudo_after_final_forget "$log"
  ! grep -qE '^sudo (go|uv)( |$)' "$log" || echo "[go or uv ran under sudo]"
  for tool in $uv_tools; do
    [[ "$(grep -cxF "uv tool install $tool" "$log")" -eq 1 ]] || echo "[want one 'uv tool install $tool']"
  done
  [[ "$(grep -c '^uv tool install ' "$log")" -eq "$(wc -w <<<"$uv_tools")" ]] \
    || echo "[uv tool install count $(grep -c '^uv tool install ' "$log"), want $(wc -w <<<"$uv_tools")]"
  if [[ -z "$uv_tools" ]] && grep -q '^uv ' "$log"; then
    echo "[uv ran although no uv tool is expected: $(grep '^uv ' "$log" | tr '\n' ';')]"
  fi
  for tool in $go_tools; do
    var="GO_TOOL_${tool^^}"
    module="$(script_constant "${var//-/_}")" || { echo "[no constant ${var//-/_} in the script]"; continue; }
    [[ "${module%@*}" =~ /"$tool"(/v[0-9]+)?$ ]] \
      || echo "[${var//-/_} is $module, whose path does not end in /$tool or /$tool/vN]"
    [[ "$(grep -cxF "go install $module" "$log")" -eq 1 ]] || echo "[want one 'go install $module']"
  done
  [[ "$(grep -c '^go install ' "$log")" -eq "$(wc -w <<<"$go_tools")" ]] \
    || echo "[go install count $(grep -c '^go install ' "$log"), want $(wc -w <<<"$go_tools")]"
  go_calls="$(grep -c '^go ' "$log")"
  [[ "$(grep -cxF 'go-env GOTOOLCHAIN=local' "$log")" -eq "$go_calls" && "$(grep -c '^go-env ' "$log")" -eq "$go_calls" ]] \
    || echo "[GOTOOLCHAIN=local not recorded for every go call: $(grep '^go-env ' "$log" | sort | uniq -c | tr -s ' \n' ' ')]"
  setup_config_lines="$(grep '^setup_config' "$log" | tr '\n' ';')"
  [[ "$setup_config_lines" == "setup_config GOTOOLCHAIN=$want_setup_config;" ]] \
    || echo "[setup_config saw: ${setup_config_lines:-none}, want GOTOOLCHAIN=$want_setup_config]"
}
# Each case is packages:sudo -v calls expected:GOTOOLCHAIN the caller exports (empty for none)
for mgr in apt-get dnf apk; do
  case "$mgr" in
    dnf) t17_uv="" t17_go="lazygit lazydocker" ;;
    *) t17_uv="black yamllint ruff" t17_go="$GO_TOOLS" ;;
  esac
  for tc in missing:1: all-installed:0: missing:1:auto; do
    IFS=: read -r pkgs want_v inherited <<<"$tc"
    case_name="$(t17_case_name "$mgr" "$pkgs" "$inherited")"
    out="$(t17_case "$mgr" "$pkgs" "$inherited")"
    events="$(event_log "$case_name")"
    problems=""
    grep -qxF "driver rc=0" <<<"$out" || problems+="[$(tail -n2 <<<"$out" | tr '\n' ' ')] "
    problems+="$(t17_check_events "$events" "$want_v" "$t17_uv" "$t17_go" "$inherited" | tr '\n' ' ')"
    problems+="$(sudo_allowlist_problems "$(sudo_log "$case_name")")"
    [[ -z "$problems" ]] || problems+="events: $(tr '\n' ';' <"$events")"
    expect_none "T17-sudo-dropped $mgr $pkgs${inherited:+ inherited-$inherited}" "$problems"
  done
done

# T18: answering y moves a foreign config aside only after the clone succeeds. The script runs from a
# plain directory, as in T16, so setup_config reaches the prompt, and setup_config runs under errexit,
# as in main. The clone stub logs its arguments: the URL must be the script's $NVIM_REPO. Cases:
#   success: the clone replaces the config, and the old one sits in one backup
#   fresh: no ~/.config at all; the clone lands without a prompt or a backup
#   clone-failure: nothing moves
#   mktemp-fails: ~/.config is not writable (mode 555), so the staging dir cannot be made; the run
#     stops before the clone with the foreign config in place and no backup (skipped for a user who
#     can write there anyway, as root can)
#   target-appears: fresh, but ~/.config/nvim appears, not empty, while the clone runs; the real mv
#     refuses to replace it or move the clone inside it, so the run stops and leaves it as it was
#   backup-move-fails, final-move-fails: the run stops with the foreign config in place and no backup
#   restore-fails: the clone's move and the move back both fail; the run stops and names the backup,
#     which holds the foreign config
# No case leaves anything in ~/.config but nvim and at most one nvim.bak.* (no staging dir).
T18_CASES=(success fresh clone-failure mktemp-fails target-appears backup-move-fails final-move-fails restore-fails)
# Sets the setup and expectations of T18 case $1 in the caller's variables, which the caller declares
# local. Setup: git_bin (the git stub dir), foreign (yes: a foreign config at ~/.config/nvim),
# read_only (yes: ~/.config is mode 555), and fail_mv (the moves to fail, space-separated: backup, the
# config's move aside; final, the clone's move into place; restore, the backup's move back).
# Expectations, over these defaults: setup_config exits 1 (want_rc), the clone ran with the script's
# URL (clone: yes, no, or any), the output has no particular message (message; {backup} stands for the
# backup's path), ~/.config/nvim holds the foreign config (config: foreign, clone, stray, or any), and
# no backup exists (backup: none, or foreign for one backup holding it).
t18_spec() {
  git_bin="$CLONE_GIT_BIN" foreign=yes read_only=no fail_mv=""
  want_rc=1 clone=yes message="" config=foreign backup=none
  case "$1" in
    success)           want_rc=0 config=clone backup=foreign ;;
    fresh)             foreign=no want_rc=0 config=clone ;;
    clone-failure)     git_bin="$NOCLONE_GIT_BIN" clone=any message="was not changed" ;;
    mktemp-fails)      read_only=yes clone=no message="Cannot create a staging directory" ;;
    target-appears)    git_bin="$APPEAR_GIT_BIN" foreign=no message="Failed to move the clone" config=stray ;;
    backup-move-fails) fail_mv=backup message="Failed to back up" ;;
    final-move-fails)  fail_mv=final message="back in place" ;;
    restore-fails)     fail_mv="final restore" message="your existing config is at {backup}" config=any backup=foreign ;;
    *) echo "[t18_spec: unknown case $1]"; return 1 ;;
  esac
}
# Runs T18 case $1
t18_case() {
  local id="$1" git_bin foreign read_only fail_mv want_rc clone message config backup
  t18_spec "$id" || return 1
  (
    sandbox "T18-$id" "$git_bin"
    CLONE_LOG="$TMP/T18-$id-clone.log"
    export CLONE_LOG
    if [[ "$foreign" == yes ]]; then
      foreign_config_fixture "$HOME/.config/nvim"
    fi
    if [[ "$read_only" == yes ]]; then
      mkdir -p "$HOME/.config"
      chmod 555 "$HOME/.config"
      if [[ -w "$HOME/.config" ]]; then
        echo "WRITABLE ANYWAY"
        exit 0
      fi
    fi
    load_script_copy "$HOME/plain"
    echo "NVIM_REPO=$NVIM_REPO"
    # In the move-failure cases, mv fails for the chosen sources (the path after a leading -T) and
    # runs the real mv for anything else
    if [[ -n "$fail_mv" ]]; then
      # shellcheck disable=SC2329  # clone_config calls it, through run_errexit and setup_config
      mv() {
        local src="$1"
        if [[ "$1" == -T ]]; then
          src="$2"
        fi
        if [[ " $fail_mv " == *" backup "* && "$src" == "$NVIM_CONFIG_DIR" ]] \
          || [[ " $fail_mv " == *" final "* && "$src" == */.nvim-clone.*/nvim ]] \
          || [[ " $fail_mv " == *" restore "* && "$src" == "$NVIM_CONFIG_DIR".bak.* ]]; then
          echo "STUB MV: failing $*" >&2
          return 1
        fi
        command mv "$@"
      }
    fi
    run_errexit setup_config <<<y
    echo "setup_config rc=$RC"
    echo DONE
  ) </dev/null 2>&1
}
# Prints the problems with T18 case $1, given its output ($2) and exit status ($3)
t18_check() {
  local id="$1" out="$2" rc="$3" dir
  dir="$(sandbox_home "T18-$id")/.config"
  local git_bin foreign read_only fail_mv want_rc clone message config backup
  local backups others want_url clone_argv=()
  t18_spec "$id" || return
  backups="$(compgen -G "$dir/nvim.bak.*" || true)"
  others="$(find "$dir" -mindepth 1 -maxdepth 1 ! -name nvim ! -name 'nvim.bak.*' 2>/dev/null)"
  done_ok "$rc" "$out" || echo "[rc=$rc]"
  [[ -z "$others" ]] || echo "[left in $dir: $(tr '\n' ' ' <<<"$others")]"
  [[ -z "$backups" || "$(wc -l <<<"$backups")" -eq 1 ]] || echo "[several backups: $(tr '\n' ' ' <<<"$backups")]"
  grep -qxF "setup_config rc=$want_rc" <<<"$out" || echo "[setup_config did not exit $want_rc]"
  message="${message//"{backup}"/$backups}"
  [[ -z "$message" ]] || grep -qF -- "$message" <<<"$out" || echo "[no '$message' message]"
  case "$clone" in
    no)
      [[ ! -e "$TMP/T18-$id-clone.log" ]] || echo "[clone ran: $(tr '\n' ' ' <"$TMP/T18-$id-clone.log")]"
      ;;
    yes)
      want_url="$(sed -n 's/^NVIM_REPO=//p' <<<"$out")"
      if [[ -f "$TMP/T18-$id-clone.log" ]]; then
        mapfile -t clone_argv <"$TMP/T18-$id-clone.log"
      fi
      [[ -n "$want_url" && ${#clone_argv[@]} -eq 3 && "${clone_argv[1]}" == "$want_url" ]] \
        || echo "[clone arguments '${clone_argv[*]}', want 'clone $want_url <dir>']"
      ;;
  esac
  case "$config" in
    clone) [[ -f "$dir/nvim/cloned" ]] || echo "[no clone at $dir/nvim]" ;;
    foreign) foreign_config_intact "$dir/nvim" ;;
    stray)
      [[ -f "$dir/nvim/stray" ]] || echo "[$dir/nvim/stray is gone]"
      [[ ! -e "$dir/nvim/nvim" ]] || echo "[the clone landed inside, at $dir/nvim/nvim]"
      ;;
  esac
  case "$backup" in
    none) [[ -z "$backups" ]] || echo "[backup made: $backups]" ;;
    foreign) if [[ -n "$backups" ]]; then foreign_config_intact "$backups"; else echo "[no backup]"; fi ;;
  esac
}
for id in "${T18_CASES[@]}"; do
  out="$(t18_case "$id")"
  rc=$?
  # Writable again (a read-only case left it mode 555), so the checks and the suite's cleanup can read
  # and remove it
  t18_dir="$(sandbox_home "T18-$id")/.config"
  [[ ! -d "$t18_dir" ]] || chmod 755 "$t18_dir"
  if grep -qxF "WRITABLE ANYWAY" <<<"$out"; then
    echo "SKIP T18-config-move-yes $id (this user can write to a mode 555 directory, as root can)"
    continue
  fi
  problems="$(t18_check "$id" "$out" "$rc" | tr '\n' ' ')"
  [[ -z "$problems" ]] || problems+="; $(tail -n4 <<<"$out" | tr '\n' ' ')"
  expect_none "T18-config-move-yes $id" "$problems"
done

# T19: go_bin_dir prints GOBIN, else the first GOPATH entry's bin dir, and fails when both are empty
# or go env fails. go is a stub (T19_BIN) answering go env from T19_* variables.
out="$( (
  sandbox T19 "$T19_BIN"
  load_script
  export T19_GOBIN T19_GOPATH T19_GO_FAILS
  # $1 = expected output, or "fail" for a nonzero return; $2 = case name
  t19_check() {
    local got rc=0
    got="$(go_bin_dir)" || rc=$?
    if [[ "$1" == fail ]]; then
      [[ $rc -ne 0 ]] || { echo "$2: want failure, got '$got'"; exit 1; }
    else
      [[ $rc -eq 0 && "$got" == "$1" ]] || { echo "$2: want '$1', got '$got' (rc=$rc)"; exit 1; }
    fi
  }
  T19_GOBIN=/x/bin T19_GOPATH=/a:/b T19_GO_FAILS=""
  t19_check /x/bin "GOBIN set"
  T19_GOBIN="" T19_GOPATH=/a:/b
  t19_check /a/bin "GOPATH list"
  T19_GOBIN="" T19_GOPATH=""
  t19_check fail "both empty"
  T19_GOBIN=/x/bin T19_GOPATH=/a:/b T19_GO_FAILS=1
  t19_check fail "go env fails"
  echo DONE
) </dev/null 2>&1)"
done_ok $? "$out"
result T19-go-bin-dir $? "$(tail -n2 <<<"$out" | tr '\n' ' ')"

# T20: the system servers in lua/lsp_gates/servers.lua (first string of each `system` entry), the
# installer, and the README agree: (a) the best-effort warn_manual list names the same binaries,
# (b) the pacman list has one package per server, (c) the README's pacman command under Requirements
# names exactly the packages the script installs on pacman, except the documented ones: the Nerd Font
# ttf-jetbrains-mono-nerd (README only) and xclip (script only, the X11 alternative to wl-clipboard),
# and on an Arch host (b0) every package the script installs on pacman exists in the sync databases
# (pacman -Si), and (d) the server packages installed here ship /usr/bin/<binary> for every server
# (pacman -Qlq), except binaries that no installed package ships, which are listed as skipped, as long
# as no more of them than packages are missing (one package per server). Both pacman queries are
# read-only and need no root. The server list comes from Neovim itself: tests/lib/system-servers.lua,
# run with --clean (no config or plugins), points package.path at the repo's lua/ and requires the
# module; t20_inventory gives each run scratch XDG dirs and TMPDIR, so it writes nothing outside $TMP.
# The script's lists come from running it, not from parsing its source, on a PATH of DENY_BIN only,
# with each installing function stubbed to print what it was given: install_language_servers for pacman
# (install_pkgs stubbed) gives (b)'s packages, and for apt-get (warn_manual stubbed, and the TypeScript
# check, which T24 covers) (a)'s binaries; install_deps (a Wayland display), install_clipboard again (an
# X11 display only), and install_neovim (pkg_install stubbed to fail, and the tarball fallback stubbed)
# give (c)'s packages. The collection runs a copy of the script whose NVIM_INSTALL_DIR is a scratch
# path with no nvim, so a host's /opt/nvim/bin/nvim never stands in for the neovim package (T26). (a)
# compares in byte order, as Lua's table.sort sorts.
t20_xdg="$TMP/T20-xdg"
mkdir -p "$t20_xdg/config" "$t20_xdg/data" "$t20_xdg/state" "$t20_xdg/cache" "$t20_xdg/tmp"
# Prints system-servers.lua's lines for its arguments (none, or $1 = table and optional $2 = keys) and
# returns nvim's status; each run gets its own sandbox and appends its stderr to $TMP/T20-nvim.err
t20_inventory() {
  (
    sandbox "T20-inventory${1:+-$1}${2:+-$2}" ""
    XDG_CONFIG_HOME="$t20_xdg/config" XDG_DATA_HOME="$t20_xdg/data" XDG_STATE_HOME="$t20_xdg/state" \
      XDG_CACHE_HOME="$t20_xdg/cache" TMPDIR="$t20_xdg/tmp"
    export XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME TMPDIR
    nvim --clean --headless -l "$LIB/system-servers.lua" "$@"
  ) </dev/null 2>>"$TMP/T20-nvim.err"
}
t20_servers="$(t20_inventory)"
t20_nvim_rc=$?
lsp_bins=()
if [[ $t20_nvim_rc -eq 0 ]]; then
  mapfile -t lsp_bins < <(sed '/^$/d' <<<"$t20_servers")
fi
# Prints each argument after the first $2 + 2 as "$1 <argument>", for the stubs in T20's collections
t20_print_tagged() {
  local tag="$1" skip="$2" item
  shift 2
  shift "$skip"
  for item in "$@"; do
    printf '%s %s\n' "$tag" "$item"
  done
}
out="$( (
  sandbox T20-collect ""
  load_script_with "$TMP/T20-collect/script/nvim-install.sh" NVIM_INSTALL_DIR "$TMP/T20-collect/opt-nvim"
  must_override install_pkgs
  must_override warn_manual
  must_override has_system_typescript
  must_override pkg_install
  must_override install_neovim_tarball
  install_pkgs() { t20_print_tagged "$T20_TAG" 2 "$@"; }
  warn_manual() { t20_print_tagged "$T20_TAG" 0 "$@"; }
  pkg_install() {
    t20_print_tagged "$T20_TAG" 0 "$@"
    return 1
  }
  has_system_typescript() { return 0; }
  install_neovim_tarball() { :; }
  PATH="$DENY_BIN"
  set_pkg_manager pacman
  T20_TAG=SERVER_PKG install_language_servers
  T20_TAG=PKG
  WAYLAND_DISPLAY=wayland-0 install_deps
  unset WAYLAND_DISPLAY
  DISPLAY=:0 install_clipboard
  install_neovim
  set_pkg_manager apt-get
  T20_TAG=MANUAL_BIN install_language_servers
  echo DONE
) </dev/null 2>&1)"
rc=$?
mapfile -t manual_bins < <(sed -n 's/^MANUAL_BIN //p' <<<"$out" | LC_ALL=C sort)
mapfile -t pacman_pkgs < <(sed -n 's/^SERVER_PKG //p' <<<"$out")
mapfile -t t20_all_pkgs < <(sed -n 's/^PKG //p' <<<"$out" | sort -u)
# The packages of the README's pacman command, one per line, sorted
mapfile -t readme_pkgs < <(sed -n '/^## Requirements/,/^## Installation/p' "$ROOT/README.md" \
  | awk '/^sudo pacman -S --needed / { on = 1; sub(/^sudo pacman -S --needed /, "") }
      on { cont = sub(/\\$/, ""); printf "%s ", $0; if (!cont) exit }' \
  | tr -s '[:space:]' '\n' | sed '/^$/d' | sort -u)
problems=""
[[ $t20_nvim_rc -eq 0 ]] \
  || problems+="[nvim could not read lua/lsp_gates/servers.lua: rc=$t20_nvim_rc $(tail -n2 "$TMP/T20-nvim.err" | tr '\n' ' ')] "
[[ ${#lsp_bins[@]} -gt 0 ]] || problems+="[no system servers found in lua/lsp_gates/servers.lua] "
done_ok $rc "$out" || problems+="[collecting the names failed: rc=$rc $(tail -n2 <<<"$out" | tr '\n' ' ')] "
[[ "${manual_bins[*]}" == "${lsp_bins[*]}" ]] \
  || problems+="[(a) warn_manual: ${manual_bins[*]}; system servers: ${lsp_bins[*]}] "
[[ ${#pacman_pkgs[@]} -eq ${#lsp_bins[@]} ]] \
  || problems+="[(b) ${#pacman_pkgs[@]} pacman packages (${pacman_pkgs[*]}) for ${#lsp_bins[@]} servers] "
# A collection that missed a branch (the server list, either display, or install_neovim) fails here
for pkg in "${pacman_pkgs[@]}" wl-clipboard xclip neovim; do
  [[ " ${t20_all_pkgs[*]} " == *" $pkg "* ]] || problems+="[(c) $pkg not among the collected names] "
done
if [[ ${#readme_pkgs[@]} -eq 0 ]]; then
  problems+="[(c) no 'sudo pacman -S --needed' command under Requirements in README.md] "
else
  t20_script_only="$(comm -23 <(printf '%s\n' "${t20_all_pkgs[@]}") <(printf '%s\n' "${readme_pkgs[@]}") \
    | grep -vxF xclip)"
  t20_readme_only="$(comm -13 <(printf '%s\n' "${t20_all_pkgs[@]}") <(printf '%s\n' "${readme_pkgs[@]}") \
    | grep -vxF ttf-jetbrains-mono-nerd)"
  [[ -z "$t20_script_only" ]] || problems+="[(c) the script installs, the README does not: $(tr '\n' ' ' <<<"$t20_script_only")] "
  [[ -z "$t20_readme_only" ]] || problems+="[(c) the README lists, the script does not install: $(tr '\n' ' ' <<<"$t20_readme_only")] "
fi
expect_none T20-server-list-sync "$problems"
if [[ "$host_mgr" != pacman ]] || ! command -v pacman >/dev/null 2>&1; then
  echo "SKIP T20-server-list-sync (b0) and (d) (not an Arch host)"
else
  problems=""
  for pkg in "${t20_all_pkgs[@]}"; do
    pacman -Si "$pkg" >/dev/null 2>&1 || problems+="[pacman -Si $pkg: not in the sync databases] "
  done
  expect_none "T20-server-list-sync (b0)" "$problems"
  t20_installed=() t20_missing=() t20_unshipped=() t20_files=""
  for pkg in "${pacman_pkgs[@]}"; do
    if pacman -Q "$pkg" >/dev/null 2>&1; then
      t20_installed+=("$pkg")
    else
      t20_missing+=("$pkg")
    fi
  done
  if [[ ${#t20_installed[@]} -gt 0 ]]; then
    t20_files="$(pacman -Qlq "${t20_installed[@]}")"
  fi
  for bin in "${lsp_bins[@]}"; do
    grep -qxF "/usr/bin/$bin" <<<"$t20_files" || t20_unshipped+=("$bin")
  done
  t20_shipped=$((${#lsp_bins[@]} - ${#t20_unshipped[@]}))
  if [[ ${#t20_unshipped[@]} -gt ${#t20_missing[@]} ]]; then
    result "T20-server-list-sync (d)" 1 \
      "no installed package ships /usr/bin/ for ${t20_unshipped[*]}, more binaries than the packages not installed here (${t20_missing[*]:-none})"
  else
    if [[ $t20_shipped -gt 0 ]]; then
      result "T20-server-list-sync (d) ($t20_shipped of ${#lsp_bins[@]} binaries)" 0
    fi
    if [[ ${#t20_unshipped[@]} -gt 0 ]]; then
      echo "SKIP T20-server-list-sync (d) for ${t20_unshipped[*]} (no installed package ships it; not installed here: ${t20_missing[*]})"
    fi
  fi
fi

# T20 (e), the same for dnf: the Fedora language-server packages are one for bash-language-server and one
# per fallback (python-lsp-server); the warning that lists the servers Fedora cannot run names every
# system server but bash-language-server's and the replaced ones before its ";", and each fallback as the
# stand-in for the server it replaces after it; and the README's dnf command under Requirements starts
# with the option that turns weak dependencies off (the script's dnf installs do the same) and names
# exactly the packages the script installs on dnf (collected as for pacman: install_deps with a Wayland
# display, install_clipboard with X11, and install_neovim, on a copy of the script with a scratch
# NVIM_INSTALL_DIR), except xclip. The dnf collection runs in its own subshell with fixed tags:
# install_pkgs prints DNF_SERVER_PKG during install_language_servers and DNF_PKG afterwards,
# warn_manual prints DNF_MANUAL, and warn prints DNF_WARN, so manual steps and warnings never land in a
# package list; the TypeScript check is stubbed as in the pacman collection (T24 covers it). The
# server names come from t20_inventory: `system keys` (the names) and `fallbacks` (name, replaced
# server, command).
mapfile -t t20_system_keys < <(t20_inventory system keys | sed '/^$/d')
mapfile -t t20_fallbacks < <(t20_inventory fallbacks | sed '/^$/d')
out="$( (
  sandbox T20-dnf-collect ""
  load_script_with "$TMP/T20-dnf-collect/script/nvim-install.sh" NVIM_INSTALL_DIR "$TMP/T20-dnf-collect/opt-nvim"
  must_override install_pkgs
  must_override warn_manual
  must_override warn
  must_override has_system_typescript
  must_override pkg_install
  must_override install_neovim_tarball
  install_pkgs() { t20_print_tagged "$T20_DNF_TAG" 2 "$@"; }
  warn_manual() { t20_print_tagged DNF_MANUAL 0 "$@"; }
  warn() { printf 'DNF_WARN %s\n' "$1"; }
  has_system_typescript() { return 0; }
  pkg_install() {
    t20_print_tagged "$T20_DNF_TAG" 0 "$@"
    return 1
  }
  install_neovim_tarball() { :; }
  # shellcheck disable=SC2030  # the functions of the script sourced into this subshell run on it
  PATH="$DENY_BIN"
  set_pkg_manager dnf
  T20_DNF_TAG=DNF_SERVER_PKG install_language_servers
  T20_DNF_TAG=DNF_PKG
  WAYLAND_DISPLAY=wayland-0 install_deps
  unset WAYLAND_DISPLAY
  DISPLAY=:0 install_clipboard
  install_neovim
  echo DONE
) </dev/null 2>&1)"
rc=$?
mapfile -t dnf_server_pkgs < <(sed -n 's/^DNF_SERVER_PKG //p' <<<"$out")
mapfile -t dnf_all_pkgs < <(sed -n 's/^DNF_PKG //p' <<<"$out" | sort -u)
# install_language_servers runs twice (once directly, once inside install_deps), so the warning is
# collected once per distinct text
mapfile -t dnf_off_warn < <(sed -n 's/^DNF_WARN \(Fedora packages no .*\)$/\1/p' <<<"$out" | sort -u)
t20_weak_deps_option="--setopt=install_weak_deps=False"
# The words of the README's dnf command after `sudo dnf install`, one per line, in order
mapfile -t readme_dnf_words < <(sed -n '/^## Requirements/,/^## Installation/p' "$ROOT/README.md" \
  | awk '/^sudo dnf install / { on = 1; sub(/^sudo dnf install /, "") }
      on { cont = sub(/\\$/, ""); printf "%s ", $0; if (!cont) exit }' \
  | tr -s '[:space:]' '\n' | sed '/^$/d')
# Its packages: the words but that option, sorted
mapfile -t readme_dnf_pkgs < <(printf '%s\n' "${readme_dnf_words[@]}" | grep -vxF -- "$t20_weak_deps_option" \
  | sed '/^$/d' | sort -u)
problems=""
done_ok $rc "$out" || problems+="[collecting the dnf names failed: rc=$rc $(tail -n2 <<<"$out" | tr '\n' ' ')] "
[[ ${#t20_system_keys[@]} -gt 0 && ${#t20_fallbacks[@]} -gt 0 ]] \
  || problems+="[system-servers.lua gave ${#t20_system_keys[@]} system keys and ${#t20_fallbacks[@]} fallbacks: $(grep -m1 E5113 "$TMP/T20-nvim.err" || tail -n1 "$TMP/T20-nvim.err")] "
[[ "${dnf_server_pkgs[*]}" == "nodejs-bash-language-server python3-lsp-server" ]] \
  || problems+="[(e) dnf language-server packages: ${dnf_server_pkgs[*]}] "
if [[ ${#dnf_off_warn[@]} -ne 1 ]]; then
  problems+="[(e) ${#dnf_off_warn[@]} 'Fedora packages no' warnings, want 1] "
else
  t20_warning="${dnf_off_warn[0]}"
  t20_stay_off="${t20_warning%%;*}"
  t20_stand_ins="${t20_warning#*;}"
  [[ "$t20_warning" == *\;* ]] \
    || problems+="[(e) the warning has no ';' between the servers that stay off and the stand-ins: $t20_warning] "
  t20_replaced=" "
  for entry in "${t20_fallbacks[@]}"; do
    read -r _ replaces _ <<<"$entry"
    t20_replaced+="$replaces "
  done
  for key in "${t20_system_keys[@]}"; do
    if [[ "$key" == bashls || "$t20_replaced" == *" $key "* ]]; then
      ! grep -qwF "$key" <<<"$t20_stay_off" \
        || problems+="[(e) the warning names $key, which has a Fedora package or a stand-in, as off: $t20_stay_off] "
    else
      grep -qwF "$key" <<<"$t20_stay_off" || problems+="[(e) the warning does not name $key as off: $t20_stay_off] "
    fi
  done
  for entry in "${t20_fallbacks[@]}"; do
    read -r name replaces _ <<<"$entry"
    grep -qF "($name) stands in for $replaces" <<<"$t20_stand_ins" \
      || problems+="[(e) the warning does not name $name as the stand-in for $replaces: $t20_stand_ins] "
  done
fi
for pkg in "${dnf_server_pkgs[@]}" wl-clipboard xclip neovim; do
  [[ " ${dnf_all_pkgs[*]} " == *" $pkg "* ]] || problems+="[(e) $pkg not among the collected dnf names] "
done
if [[ ${#readme_dnf_words[@]} -eq 0 ]]; then
  problems+="[(e) no 'sudo dnf install' command under Requirements in README.md] "
else
  [[ "${readme_dnf_words[0]}" == "$t20_weak_deps_option" ]] \
    || problems+="[(e) the README's dnf command does not turn weak dependencies off] "
  t20_dnf_script_only="$(comm -23 <(printf '%s\n' "${dnf_all_pkgs[@]}") <(printf '%s\n' "${readme_dnf_pkgs[@]}") \
    | grep -vxF xclip)"
  t20_dnf_readme_only="$(comm -13 <(printf '%s\n' "${dnf_all_pkgs[@]}") <(printf '%s\n' "${readme_dnf_pkgs[@]}"))"
  [[ -z "$t20_dnf_script_only" ]] \
    || problems+="[(e) the script installs on dnf, the README does not: $(tr '\n' ' ' <<<"$t20_dnf_script_only")] "
  [[ -z "$t20_dnf_readme_only" ]] \
    || problems+="[(e) the README lists for Fedora, the script does not install: $(tr '\n' ' ' <<<"$t20_dnf_readme_only")] "
fi
expect_none "T20-server-list-sync (e) dnf" "$problems"


# T22: main's single privilege boundary: install_neovim and install_deps, the steps that run root
# commands, come first; then main forgets cached sudo credentials; then put_install_dir_first_on_path
# (only after the forget, so no root command and no lookup of sudo ever searches NVIM_INSTALL_DIR/bin),
# install_user_tools (go and uv builds), setup_config, which clones the config, setup_path,
# verify_nvim, verify_config, which launches Neovim for the first time, and print_summary, and no sudo
# runs after the forget. In packages-only mode the forget is followed by put_install_dir_first_on_path,
# verify_nvim, and print_summary only, and the summary says so. A driver (tests/lib/driver-T22.sh) runs
# main with install_neovim taking a ticket through ensure_sudo_ticket (so moved after the forget, it
# stops the run), install_deps and the steps before it stubbed to log their names, and
# put_install_dir_first_on_path, setup_path, verify_nvim, verify_config, and print_summary logging their
# names and then running for real, with T26's stub nvim (version 0.12.0) first on PATH, so a root
# command in them reaches the recording sudo, which logs to the same event log; the real
# forget_sudo_credentials and cleanup run against it, and main gets the words of T22_ARGS as its
# arguments. Cases: main-order, where install_neovim takes a ticket; T22b, the same where sudo is not
# setuid (sudo -k and sudo -n -v both fail, so no ticket can be live), which still goes on to the end
# and exits 0, under the errexit main runs with; T22c, where no step takes a ticket, as on a re-run with
# nothing to install, but one from before the run may be live, so main still forgets it; T22d, the
# same, but sudo -k fails while sudo -n -v shows that ticket is still live, so the run stops with exit 1
# before put_install_dir_first_on_path, with sudo's message and the advice to wait for the ticket to
# expire; and T22e, main-order with --packages-only. Test name, whether install_neovim takes a ticket (1
# or 0), the sudo arguments the recording sudo fails on (';'-separated), the exit status main must end
# with, and main's arguments
for tc in "T22-main-order:1::0:" "T22b-forget-tolerates-failure:1:-k;-n -v:0:" \
  "T22c-forget-preexisting-ticket:0::0:" "T22d-forget-refuses-live-ticket:0:-k:1:" \
  "T22e-packages-only:1::0:--packages-only"; do
  IFS=: read -r t22_name t22_ticket t22_fail_on t22_want_rc t22_args <<<"$tc"
  t22_events="$(event_log "$t22_name")"
  t22_log="$(sudo_log "$t22_name")"
  out="$( (
    recording_sandbox "$t22_name" "$T26_BIN" "$t22_fail_on"
    T22_TICKET="$t22_ticket" T26_VERSION=0.12.0 T22_ARGS="$t22_args"
    export T22_TICKET T26_VERSION T22_ARGS
    bash "$LIB/driver-T22.sh" "$SCRIPT"
    echo "driver rc=$?"
  ) </dev/null 2>&1)"
  problems=""
  grep -qxF "driver rc=$t22_want_rc" <<<"$out" || problems+="[want exit $t22_want_rc: $(tail -n2 <<<"$out" | tr '\n' ' ')] "
  case "$t22_want_rc:$t22_args" in
    0:)
      problems+="$(order_problems "$t22_events" install_neovim install_deps "sudo -k" put_install_dir_first_on_path \
        install_user_tools setup_config setup_path verify_nvim verify_config print_summary)"
      grep -qF 'Neovim Bootstrap Complete' <<<"$out" \
        && ! grep -qE 'Packages Installed|not cloned \(packages-only\)|without --packages-only' <<<"$out" \
        || problems+="[no full-run summary, or it is the packages-only one] "
      ;;
    0:--packages-only)
      problems+="$(order_problems "$t22_events" install_neovim install_deps "sudo -k" put_install_dir_first_on_path \
        verify_nvim print_summary)"
      ! grep -qxE 'install_user_tools|setup_config|setup_path|verify_config' "$t22_events" \
        || problems+="[a full-run step ran in packages-only mode] "
      grep -qF 'Neovim Packages Installed' <<<"$out" && grep -qF 'not cloned (packages-only)' <<<"$out" \
        && grep -qF 'Run this script again without --packages-only' <<<"$out" \
        || problems+="[no packages-only summary] "
      ;;
    *)
      problems+="$(order_problems "$t22_events" install_neovim install_deps "sudo -k")"
      grep -qF "sudo -k failed (STUB SUDO: failing -k)" <<<"$out" && grep -qF "timestamp_timeout" <<<"$out" \
        || problems+="[no live-ticket error with sudo's message and the advice to wait] "
      ! grep -qxE 'put_install_dir_first_on_path|install_user_tools|setup_config' "$t22_events" \
        || problems+="[main went on after the forget failed] "
      ;;
  esac
  problems+="$(no_sudo_after_final_forget "$t22_events")"
  [[ "$(grep -cxF -- -v "$t22_log")" -eq "$t22_ticket" ]] \
    || problems+="[sudo -v count $(grep -cxF -- -v "$t22_log"), want $t22_ticket] "
  problems+="$(sudo_allowlist_problems "$t22_log")"
  [[ -z "$problems" ]] || problems+="events: $(tr '\n' ';' <"$t22_events")"
  expect_none "$t22_name" "$problems"
done

# T22f: print_summary says what the mode skipped, and why NVIM_INSTALL_DIR/bin goes on PATH. A sourced
# case per mode and install method, with T26's stub nvim (version 0.12.0) first on PATH and
# NEED_PATH_SETUP true, as after a tarball install that could not link nvim into /usr/local/bin
# (tarball) or a reuse of the install dir's nvim, which PATH did not reach first (reused): packages-only
# shows the title, the config line, the PATH note with that cause (setup_path did not run, so nothing
# was added yet), and the closing line that asks for the full run; the full run shows its own title,
# PATH updated with that cause, and the Mason line, and none of the packages-only texts (the bare word
# is not checked: the config path in the output sits under the suite's temp dir, whose name could
# contain it). Neither shows the other method's cause.
t22f_cause_tarball='nvim could not be linked into /usr/local/bin'
t22f_cause_reused='the reused nvim was not first on PATH'
t22f_fail=""
for mode in true false; do
  for method in tarball reused; do
    out="$( (
      sandbox "T22f-$mode-$method" "$T26_BIN"
      T26_VERSION=0.12.0
      export T26_VERSION
      load_script
      # shellcheck disable=SC2030  # print_summary, in the script sourced into this subshell, reads them
      PACKAGES_ONLY="$mode" NEED_PATH_SETUP=true NVIM_INSTALL_METHOD="$method"
      print_summary
      echo DONE
    ) </dev/null 2>&1)"
    rc=$?
    if [[ "$method" == tarball ]]; then
      t22f_cause="$t22f_cause_tarball" t22f_other_cause="$t22f_cause_reused"
    else
      t22f_cause="$t22f_cause_reused" t22f_other_cause="$t22f_cause_tarball"
    fi
    if [[ "$mode" == true ]]; then
      t22f_wanted=('Neovim Packages Installed' 'Config: +not cloned \(packages-only\)'
        "PATH: +$t22f_cause; the full run adds /opt/nvim/bin to your shell config"
        'Run this script again without --packages-only where Neovim will run, to install the user tools and clone the config\.')
      t22f_unwanted=('Bootstrap Complete' 'PATH updated' 'Mason installs' "$t22f_other_cause")
    else
      t22f_wanted=('Neovim Bootstrap Complete'
        "PATH updated: +yes, /opt/nvim/bin first, as $t22f_cause \\(restart shell to apply\\)"
        'Open a file in nvim once so Mason installs its language servers\.')
      t22f_unwanted=('Packages Installed' 'not cloned \(packages-only\)' 'without --packages-only' 'PATH: '
        "$t22f_other_cause")
    fi
    done_ok $rc "$out" || t22f_fail+="[packages_only=$mode $method: rc=$rc $(tail -n2 <<<"$out" | tr '\n' ' ')] "
    for want in "${t22f_wanted[@]}"; do
      grep -qE -- "$want" <<<"$out" || t22f_fail+="[packages_only=$mode $method: missing $want] "
    done
    for want in "${t22f_unwanted[@]}"; do
      ! grep -qE -- "$want" <<<"$out" || t22f_fail+="[packages_only=$mode $method: shows $want] "
    done
  done
done
expect_none T22f-summary-modes "$t22f_fail"

# T22h: NEED_PATH_SETUP comes only with the reused or tarball method, so print_summary, given it with
# any other method (existing here), has no cause to name: it stops with exit 1 and an error naming the
# method, in both modes, instead of printing an empty cause
t22h_fail=""
for mode in true false; do
  out="$( (
    sandbox "T22h-$mode" "$T26_BIN"
    T26_VERSION=0.12.0
    export T26_VERSION
    load_script
    # shellcheck disable=SC2030  # print_summary, in the script sourced into this subshell, reads them
    PACKAGES_ONLY="$mode" NEED_PATH_SETUP=true NVIM_INSTALL_METHOD=existing
    run_errexit print_summary
    echo "inner rc=$RC"
    echo DONE
  ) </dev/null 2>&1)"
  rc=$?
  done_ok $rc "$out" && grep -qxF "inner rc=1" <<<"$out" \
    && grep -qxF "  x print_summary: NEED_PATH_SETUP is true for install method 'existing' (expected reused or tarball)" <<<"$out" \
    || t22h_fail+="[packages_only=$mode: rc=$rc $(tail -n3 <<<"$out" | tr '\n' ' ')] "
  ! grep -qE 'PATH( updated)?: ' <<<"$out" || t22h_fail+="[packages_only=$mode: printed a PATH line] "
done
expect_none T22h-summary-path-cause-invariant "$t22h_fail"

# T22g: verify_nvim, with nvim missing from PATH (an empty dir; it uses only builtins), exits 1 with one
# error line, "nvim not found on PATH after installation.", in both modes and whatever NEED_PATH_SETUP
# says: an install that leaves its nvim only in NVIM_INSTALL_DIR/bin puts that dir first on this run's
# PATH (T25, T26), so a missing nvim here has no cause that state could name. Cases: PACKAGES_ONLY,
# NEED_PATH_SETUP
t22g_fail=""
for tc in "true:true" "false:true" "true:false" "false:false"; do
  IFS=: read -r t22g_mode t22g_need <<<"$tc"
  out="$( (
    sandbox "T22g-$t22g_mode-$t22g_need" ""
    load_script
    # shellcheck disable=SC2030  # verify_nvim, in the script sourced into this subshell, reads both
    PACKAGES_ONLY="$t22g_mode" NEED_PATH_SETUP="$t22g_need"
    PATH="$EMPTY_BIN" run_errexit verify_nvim
    echo "inner rc=$RC"
    echo DONE
  ) </dev/null 2>&1)"
  rc=$?
  done_ok $rc "$out" && grep -qxF "inner rc=1" <<<"$out" \
    && grep -qxF '  x nvim not found on PATH after installation.' <<<"$out" \
    || t22g_fail+="[$tc: rc=$rc $(tail -n3 <<<"$out" | tr '\n' ' ')] "
  t22g_errors="$(grep -c '^  x ' <<<"$out")"
  [[ "$t22g_errors" -eq 1 ]] || t22g_fail+="[$tc: $t22g_errors error lines, want 1: $(grep '^  x ' <<<"$out" | tr '\n' ';')] "
done
expect_none T22g-verify-nvim-not-found "$t22g_fail"

# T23: a run that stops on an error after the script took a sudo ticket still drops it. A driver
# (tests/lib/driver-T23.sh) runs main, so main's own EXIT trap is the one under test, with install_deps
# taking a ticket through ensure_sudo_ticket and then running a required install that fails against
# the recording sudo: the run exits 1, and cleanup's sudo -k is the last sudo call
t23_log="$(sudo_log T23)"
t23_events="$(event_log T23)"
out="$( (
  recording_sandbox T23 "" "apt-get install -y pkg"
  bash "$LIB/driver-T23.sh" "$SCRIPT"
  echo "driver rc=$?"
) </dev/null 2>&1)"
problems=""
grep -qxF "driver rc=1" <<<"$out" && grep -qF "Cannot continue" <<<"$out" && ! grep -qxF "NOT REACHED" <<<"$out" \
  || problems+="[$(tail -n3 <<<"$out" | tr '\n' ' ')] "
[[ "$(head -n1 "$t23_log")" == "-v" && "$(tail -n1 "$t23_log")" == "-k" && "$(grep -cxF -- -k "$t23_log")" -eq 1 ]] \
  || problems+="[want -v first and one -k, last; sudo log: $(tr '\n' ';' <"$t23_log")] "
problems+="$(sudo_allowlist_problems "$t23_log")"
! grep -qxF setup_config "$t23_events" || problems+="[main went on to setup_config] "
expect_none T23-cleanup-drops-ticket "$problems"

# T24: on a best-effort distro, install_language_servers says that ts_ls needs a system TypeScript
# unless the editor's gate (lua/lsp_gates/typescript.lua) would find one: Arch's package
# (ARCH_TSSERVER), else the TypeScript package the tsserver on PATH resolves into, whose package.json
# names typescript with a non-empty version and sits next to lib/tsserver.js. Each case sources a copy
# of the script with ARCH_TSSERVER rewritten to a scratch path (the host's own TypeScript never
# counts) and runs install_language_servers with PATH set to one case dir and TOOLS_BIN (readlink).
# Hint: no tsserver at all; a shim (a wrapper script in no package, as a version manager installs); a
# package whose version is empty. No hint: a fake TypeScript package's tsserver on PATH (through a
# symlink, as a bin dir links it), or at ARCH_TSSERVER with nothing on PATH. The dirs and packages are
# set up with the stubs (T24_PKGS).
# Case id, the dir on PATH, where ARCH_TSSERVER points (missing, or package: the fake package's
# lib/tsserver.js), and whether the hint shows
for tc in "no-tsserver:$EMPTY_BIN:missing:hint" "shim:$TMP/bin-T24-shim:missing:hint" \
  "empty-version:$TMP/bin-T24-empty-version:missing:hint" "package-on-path:$TMP/bin-T24-package:missing:none" \
  "arch-package:$EMPTY_BIN:package:none"; do
  IFS=: read -r id t24_bin t24_arch want <<<"$tc"
  if [[ "$t24_arch" == package ]]; then
    t24_arch="$T24_PKGS/typescript/lib/tsserver.js"
  else
    t24_arch="$TMP/T24-no-typescript/lib/tsserver.js"
  fi
  out="$( (
    sandbox "T24-$id" ""
    load_script_with "$TMP/T24-$id/nvim-install.sh" ARCH_TSSERVER "$t24_arch"
    [[ "$ARCH_TSSERVER" == "$t24_arch" ]] || { echo "ARCH_TSSERVER=$ARCH_TSSERVER"; exit 1; }
    set_pkg_manager apt-get
    PATH="$t24_bin:$TOOLS_BIN" install_language_servers >/dev/null
    printf 'WARNINGS: %s\n' "${WARNINGS[*]}"
    echo DONE
  ) </dev/null 2>&1)"
  rc=$?
  t24_warnings="$(grep '^WARNINGS: ' <<<"$out")"
  if [[ "$want" == hint ]]; then
    done_ok $rc "$out" && [[ "$t24_warnings" == *"ts_ls also needs a system TypeScript"* ]]
  else
    done_ok $rc "$out" && [[ -n "$t24_warnings" && "$t24_warnings" != *"ts_ls"* ]]
  fi
  result "T24-ts-ls-typescript-hint $id" $? "want $want; $(tail -n2 <<<"$out" | tr '\n' ' ')"
done


# T25: the tarball fallback, run on a copy of the script whose NVIM_INSTALL_DIR is a scratch path, with
# T25_BIN's curl (it logs "curl -o <file> <url>" to the event log and copies a tiny local tar.gz to that
# file) and the recording sudo, which never runs what it is given (nothing is removed, created,
# extracted, or changed for real). Cases: fresh, no existing dir: the ticket, then mkdir, tar of the
# downloaded file, chown -R 0:0 and chmod -R go-w of the dir (tar run as root keeps the owners the
# archive records, and the dir's bin may go first on PATH), the /usr/local/bin check (only when this
# user cannot write there), and the symlink, all through as_root, each root command after the first
# preceded by the ticket check (sudo -n -v); keep, an existing dir and answer n: exit 1 with "Cannot
# install without removing" and no root command; replace, answer y: the same as fresh with rm -rf of
# the dir first; no-symlink: the /usr/local/bin check fails, so the same as fresh without the symlink,
# and NEED_PATH_SETUP is set (skipped for a user who can write /usr/local/bin, where the check never
# runs). The install method is tarball, and the install leaves PATH as it was: only
# put_install_dir_first_on_path, which main runs after the privileged phase and each case runs next,
# changes it. In no-symlink it puts the dir's bin first, where verify_nvim then finds its nvim (T26's
# install dir stub, standing in for the one the recording sudo never extracted); the cases that link
# leave PATH as it was.
# $1 = case id (fresh, keep, replace, or no-symlink)
t25_case() {
  local id="$1" fail_on=""
  if [[ "$id" == no-symlink ]]; then
    fail_on="test -w /usr/local/bin"
  fi
  (
    recording_sandbox "T25-$id" "$T25_BIN" "$fail_on"
    TMPDIR="$TMP/T25-$id-tmp"
    export TMPDIR
    mkdir -p "$TMPDIR"
    dir="$TMP/T25-$id/opt-nvim"
    if [[ "$id" == keep || "$id" == replace ]]; then
      mkdir -p "$dir"
    fi
    load_script_with "$TMP/T25-$id/script/nvim-install.sh" NVIM_INSTALL_DIR "$dir"
    [[ "$NVIM_INSTALL_DIR" == "$dir" ]] || { echo "NVIM_INSTALL_DIR=$NVIM_INSTALL_DIR"; exit 1; }
    detect_os
    detect_arch
    # shellcheck disable=SC2031  # detect_arch, in the script sourced into this subshell, sets it
    echo "ARCH=$ARCH"
    # shellcheck disable=SC2329  # run_errexit calls it
    tarball_and_report() {
      # shellcheck disable=SC2031  # this subshell's PATH, before install_neovim_tarball runs
      local path_before="$PATH"
      install_neovim_tarball
      # shellcheck disable=SC2031  # install_neovim_tarball, in the script sourced into this subshell, sets it
      echo "NEED_PATH_SETUP=$NEED_PATH_SETUP"
      # shellcheck disable=SC2031  # install_neovim_tarball, in the script sourced into this subshell, sets it
      echo "METHOD=$NVIM_INSTALL_METHOD"
      echo "PATH after the tarball: $(path_change "$path_before" "$dir")"
      # As main runs it, after the privileged phase
      put_install_dir_first_on_path
      echo "PATH after the step: $(path_change "$path_before" "$dir")"
      if [[ "$id" == no-symlink ]]; then
        add_stub "$dir/bin" nvim t26-install-dir-nvim
        # A version no real nvim later on PATH has, so only the install dir's stub passes the check
        T26_INSTALL_DIR_VERSION=0.98.7
        export T26_INSTALL_DIR_VERSION
        echo "NVIM_FOUND=$(type -P nvim)"
        verify_nvim
      fi
    }
    case "$id" in
      keep) run_errexit tarball_and_report <<<n ;;
      replace) run_errexit tarball_and_report <<<y ;;
      *) run_errexit tarball_and_report </dev/null ;;
    esac
    echo "tarball rc=$RC"
    echo DONE
  ) </dev/null 2>&1
}
# Prints the sudo log T25 case $1 must leave, given the install dir $2 and the downloaded file $3: the
# root commands, -v before the first and -n -v before each later one
t25_want_log() {
  local cmds=() cmd check=-v
  case "$1" in
    keep) return ;;
    replace) cmds+=("rm -rf $2") ;;
  esac
  cmds+=("mkdir -p $2" "tar -C $2 --strip-components=1 -xzf $3" "chown -R 0:0 $2" "chmod -R go-w $2")
  if [[ ! -w /usr/local/bin ]]; then
    cmds+=("test -w /usr/local/bin")
  fi
  if [[ "$1" != no-symlink ]]; then
    cmds+=("ln -sf $2/bin/nvim /usr/local/bin/nvim")
  fi
  for cmd in "${cmds[@]}"; do
    printf '%s\n' "$check" "$cmd"
    check="-n -v"
  done
}
for id in fresh keep replace no-symlink; do
  if [[ "$id" == no-symlink && -w /usr/local/bin ]]; then
    echo "SKIP T25-tarball no-symlink (this user can write /usr/local/bin, so the symlink needs no root check)"
    continue
  fi
  out="$(t25_case "$id")"
  rc=$?
  t25_dir="$TMP/T25-$id/opt-nvim"
  t25_log="$(sudo_log "T25-$id")"
  t25_curl="$(grep '^curl ' "$(event_log "T25-$id")" 2>/dev/null)"
  t25_file="$(sed -n 's/^curl -o \([^ ]*\) .*/\1/p' <<<"$t25_curl")"
  t25_arch="$(sed -n 's/^ARCH=//p' <<<"$out")"
  problems=""
  done_ok $rc "$out" || problems+="[rc=$rc] "
  [[ "$t25_curl" == "curl -o $TMP/T25-$id-tmp/"*" https://github.com/neovim/neovim/releases/latest/download/nvim-linux-$t25_arch.tar.gz" ]] \
    || problems+="[download: '$t25_curl'] "
  if [[ "$id" == keep ]]; then
    grep -qxF "tarball rc=1" <<<"$out" || problems+="[want exit 1] "
    grep -qF "Cannot install without removing" <<<"$out" || problems+="[no 'Cannot install without removing' message] "
    t25_root="$(grep -vxF -- -v "$t25_log")"
    [[ -z "$t25_root" ]] || problems+="[root commands ran: $(tr '\n' ';' <<<"$t25_root")] "
  else
    grep -qxF "tarball rc=0" <<<"$out" || problems+="[want exit 0] "
    [[ "$(<"$t25_log")" == "$(t25_want_log "$id" "$t25_dir" "$t25_file")" ]] \
      || problems+="[want sudo log: $(t25_want_log "$id" "$t25_dir" "$t25_file" | tr '\n' ';')] "
    grep -qxF "METHOD=tarball" <<<"$out" || problems+="[want install method tarball] "
    grep -qxF "PATH after the tarball: unchanged" <<<"$out" || problems+="[install_neovim_tarball changed PATH] "
    if [[ "$id" == no-symlink ]]; then
      grep -qxF "NEED_PATH_SETUP=true" <<<"$out" || problems+="[NEED_PATH_SETUP not set] "
      grep -qxF "PATH after the step: install dir first" <<<"$out" \
        || problems+="[put_install_dir_first_on_path did not put the install dir's bin first] "
      grep -qxF "NVIM_FOUND=$t25_dir/bin/nvim" <<<"$out" || problems+="[nvim on PATH is not the install dir's] "
      grep -qF 'Neovim 0.98.7 on PATH' <<<"$out" || problems+="[verify_nvim did not pass on the install dir's nvim] "
    else
      grep -qxF "NEED_PATH_SETUP=false" <<<"$out" || problems+="[NEED_PATH_SETUP set although the symlink was made] "
      grep -qxF "PATH after the step: unchanged" <<<"$out" || problems+="[PATH changed although the symlink was made] "
    fi
  fi
  problems+="$(sudo_allowlist_problems "$t25_log" "$t25_dir")"
  [[ -z "$problems" ]] || problems+="sudo log: $(tr '\n' ';' <"$t25_log"); $(tail -n3 <<<"$out" | tr '\n' ' ')"
  expect_none "T25-tarball $id" "$problems"
done

# T26: install_neovim keeps a new enough nvim; otherwise it installs the neovim package and checks the
# version again: new enough is done, still too old falls back to the tarball, and so does a failed
# package install. When PATH has no nvim, or only one older than MIN_NVIM_VERSION, a new enough nvim in
# NVIM_INSTALL_DIR/bin is reused, when only root can write that tree: an earlier tarball install can
# leave its nvim only there (the /usr/local/bin link failed, or neither it nor setup_path's shell config
# entry is in effect for this run). Then nothing is installed, the install method is reused, and
# NEED_PATH_SETUP is set. An older nvim there, a broken one (it fails --version), a tree that is not
# root-owned (with a warning that says so), or none leaves the flow as it was, and a new enough nvim on
# PATH wins over the install dir. install_neovim never changes PATH: each case then runs
# put_install_dir_first_on_path, as main does after the privileged phase, which puts the dir's bin first
# on PATH after a reuse and leaves PATH as it was otherwise, and setup_path's shell config entry (not run
# here) does the same in new shells. Whenever the tarball does not run (here it is overridden, and
# installs nothing), verify_nvim then passes in the same process. Each case runs a
# copy of the script whose NVIM_INSTALL_DIR is a scratch dir, so a host's /opt/nvim never counts. The
# cases that need a root-owned tree override is_root_owned_tree to succeed, so the flow cases run on
# every host, with or without a fake-root wrapper; T26b checks the real function, on root-owned trees
# under one. The not-root-owned case runs the real check on the sandbox tree, which the user owns, and
# the install dir's nvim must not run there: the ownership check comes before its version is read. The
# PATH nvim is a stub (T26_BIN), first on PATH, that prints version $T26_VERSION, or PATH has none
# (T26_NO_NVIM_BIN, then DENY_BIN); the install dir's nvim is a stub that prints version
# $T26_INSTALL_DIR_VERSION and creates the file $T26_INSTALL_DIR_RAN whenever it runs. pkg_install
# (which prints its arguments, then fails or sets the version the package left) and
# install_neovim_tarball (which prints TARBALL) are overridden. No case may hit a missing command.
#
# Sets up T26 case $1 in the calling subshell: a sandbox, and a sourced copy of the script whose
# NVIM_INSTALL_DIR is $t26_install_dir (set here, with $t26_ran_marker), with the PATH nvim, the install
# dir's nvim, its ownership check, and the overrides as $2 to $5 say. $2 = the PATH nvim's version, or
# none; $3 = the install dir nvim's version, none, or broken; $4 = root (is_root_owned_tree overridden
# to succeed), user (the real check), or "-" (no install dir nvim, so no check runs); $5 = the version
# after the package install, or fail
t26_load() {
  sandbox "T26-$1" "$T26_BIN"
  t26_install_dir="$TMP/T26-$1/opt-nvim" t26_ran_marker="$TMP/T26-$1/install-dir-nvim-ran"
  load_script_with "$TMP/T26-$1/script/nvim-install.sh" NVIM_INSTALL_DIR "$t26_install_dir"
  set_pkg_manager pacman
  if [[ "$4" == root ]]; then
    must_override is_root_owned_tree
    # shellcheck disable=SC2329  # install_neovim calls it
    is_root_owned_tree() { return 0; }
  fi
  if [[ "$3" != none ]]; then
    add_stub "$t26_install_dir/bin" nvim t26-install-dir-nvim
    T26_INSTALL_DIR_VERSION="$3" T26_INSTALL_DIR_RAN="$t26_ran_marker"
    export T26_INSTALL_DIR_VERSION T26_INSTALL_DIR_RAN
  fi
  if [[ "$2" == none ]]; then
    PATH="$T26_NO_NVIM_BIN:$DENY_BIN"
  fi
  T26_VERSION="$2" T26_AFTER="$5"
  export T26_VERSION
  must_override pkg_install
  must_override install_neovim_tarball
  pkg_install() {
    echo "PKG_INSTALL $*"
    if [[ "$T26_AFTER" == fail ]]; then
      return 1
    fi
    T26_VERSION="$T26_AFTER"
  }
  install_neovim_tarball() { echo TARBALL; }
}
# Runs install_neovim, put_install_dir_first_on_path, and verify_nvim, in main's order, for T26 case $1
# ($2 to $5 as t26_load takes them)
t26_case() {
  (
    t26_load "$@"
    t26_path_before="$PATH"
    install_neovim
    # shellcheck disable=SC2031  # install_neovim, in the script sourced into this subshell, sets it
    echo "METHOD=$NVIM_INSTALL_METHOD"
    # shellcheck disable=SC2031  # install_neovim, in the script sourced into this subshell, sets it
    echo "NEED_PATH_SETUP=$NEED_PATH_SETUP"
    echo "PATH after install_neovim: $(path_change "$t26_path_before" "$t26_install_dir")"
    if [[ -e "$t26_ran_marker" ]]; then
      echo "INSTALL_DIR_NVIM_RAN=yes"
    else
      echo "INSTALL_DIR_NVIM_RAN=no"
    fi
    put_install_dir_first_on_path
    echo "PATH after the step: $(path_change "$t26_path_before" "$t26_install_dir")"
    run_errexit verify_nvim
    echo "VERIFY rc=$RC"
    echo DONE
  ) </dev/null 2>&1
}
# Case id, the PATH nvim's version (or none), the install dir nvim's version (or none, or broken), the
# install dir's ownership check (root, user, or "-"), the version after the package install (or fail,
# or "-" when it never runs), whether pkg_install neovim runs, whether the tarball runs, the install
# method when it does not (or "-"), NEED_PATH_SETUP afterwards, and PATH after
# put_install_dir_first_on_path (unchanged, or install-dir: the install dir's bin first, then PATH as it
# was)
t26_not_reused="Not reusing the nvim in"
t26_not_reused_why="something in it is not owned by root, or is writable by group or others; installing Neovim instead"
for tc in "current:0.12.0:none:-:-:no:no:existing:false:unchanged" \
  "old-package-new:0.11.4:none:-:0.12.6:yes:no:pacman:false:unchanged" \
  "old-package-old:0.11.4:none:-:0.11.5:yes:yes:-:false:unchanged" \
  "package-fails:0.11.4:none:-:fail:yes:yes:-:false:unchanged" \
  "no-nvim:none:none:-:fail:yes:yes:-:false:unchanged" \
  "install-dir-only:none:0.12.6:root:fail:no:no:reused:true:install-dir" \
  "old-path-install-dir-new:0.11.4:0.12.6:root:fail:no:no:reused:true:install-dir" \
  "old-path-install-dir-old:0.11.4:0.11.6:root:0.11.5:yes:yes:-:false:unchanged" \
  "install-dir-broken:none:broken:root:fail:yes:yes:-:false:unchanged" \
  "install-dir-not-root-owned:none:0.12.6:user:fail:yes:yes:-:false:unchanged" \
  "new-path-install-dir-new:0.12.0:0.12.6:root:-:no:no:existing:false:unchanged"; do
  IFS=: read -r id before install_dir tree after want_pkg want_tarball want_method want_path_setup want_path <<<"$tc"
  out="$(t26_case "$id" "$before" "$install_dir" "$tree" "$after")"
  rc=$?
  problems=""
  done_ok $rc "$out" || problems+="[rc=$rc] "
  ! grep -qF 'command not found' <<<"$out" || problems+="[a command was not found] "
  if [[ "$tree" == user ]]; then
    grep -qF "$t26_not_reused $TMP/T26-$id/opt-nvim: $t26_not_reused_why" <<<"$out" \
      || problems+="[no warning that the install dir is not reused] "
    grep -qxF "INSTALL_DIR_NVIM_RAN=no" <<<"$out" || problems+="[the install dir's nvim ran before the ownership check] "
  else
    ! grep -qF "$t26_not_reused" <<<"$out" || problems+="[warned that the install dir is not reused] "
  fi
  if [[ "$want_pkg" == yes ]]; then
    [[ "$(grep -c '^PKG_INSTALL' <<<"$out")" -eq 1 ]] && grep -qxF "PKG_INSTALL neovim" <<<"$out" \
      || problems+="[want one pkg_install neovim] "
  else
    ! grep -q '^PKG_INSTALL' <<<"$out" || problems+="[pkg_install ran] "
  fi
  if [[ "$want_tarball" == yes ]]; then
    grep -qxF TARBALL <<<"$out" || problems+="[no tarball fallback] "
  else
    ! grep -qxF TARBALL <<<"$out" || problems+="[tarball fallback ran] "
    grep -qxF "METHOD=$want_method" <<<"$out" || problems+="[want install method $want_method] "
    grep -qxF "VERIFY rc=0" <<<"$out" || problems+="[verify_nvim failed after install_neovim] "
  fi
  grep -qxF "NEED_PATH_SETUP=$want_path_setup" <<<"$out" || problems+="[want NEED_PATH_SETUP=$want_path_setup] "
  grep -qxF "PATH after install_neovim: unchanged" <<<"$out" || problems+="[install_neovim changed PATH] "
  if [[ "$want_path" == install-dir ]]; then
    grep -qxF "PATH after the step: install dir first" <<<"$out" \
      || problems+="[want the install dir's bin first on PATH after put_install_dir_first_on_path] "
  else
    grep -qxF "PATH after the step: unchanged" <<<"$out" || problems+="[want PATH unchanged after put_install_dir_first_on_path] "
  fi
  [[ -z "$problems" ]] || problems+="; $(tail -n7 <<<"$out" | tr '\n' ' ')"
  expect_none "T26-install-neovim $id" "$problems"
done

# T26c: a packages-only run that reuses NVIM_INSTALL_DIR ends as main ends it in that mode
# (install_neovim, then, past the privileged phase, put_install_dir_first_on_path, verify_nvim, and
# print_summary, under errexit), as on Fedora 43 when an earlier run left the tarball there and dnf's
# older nvim comes first on PATH: it exits 0, names reused as the install method, and its PATH line
# gives that cause, not a failed link. The setup is T26's (t26_load).
out="$( (
  t26_load packages-only-reuse 0.11.6 0.12.6 root fail
  PACKAGES_ONLY=true
  # shellcheck disable=SC2329  # run_errexit calls it
  packages_only_end() {
    install_neovim
    put_install_dir_first_on_path
    verify_nvim
    print_summary
  }
  run_errexit packages_only_end
  echo "end rc=$RC"
  echo DONE
) </dev/null 2>&1)"
rc=$?
problems=""
done_ok $rc "$out" && grep -qxF "end rc=0" <<<"$out" || problems+="[want exit 0: rc=$rc $(tail -n3 <<<"$out" | tr '\n' ' ')] "
grep -qF 'Neovim 0.12.6 on PATH' <<<"$out" || problems+="[verify_nvim did not find the install dir's nvim] "
grep -qE 'Install method: +reused$' <<<"$out" || problems+="[want install method reused] "
grep -qE "PATH: +the reused nvim was not first on PATH; the full run adds $(ere_escape "$TMP")/T26-packages-only-reuse/opt-nvim/bin to your shell config" <<<"$out" \
  || problems+="[no PATH line naming the reuse] "
! grep -qF 'linked' <<<"$out" || problems+="[names a failed link] "
! grep -qE '^PKG_INSTALL|^TARBALL$' <<<"$out" || problems+="[installed Neovim] "
expect_none T26c-packages-only-reuse "$problems"

# T26d: put_install_dir_first_on_path, on a copy of the script whose NVIM_INSTALL_DIR is a scratch
# path: with NEED_PATH_SETUP false it leaves PATH as it was; with it true it puts NVIM_INSTALL_DIR/bin
# first and exports PATH, so the commands this run starts (Neovim, and the plugin builds it runs) see
# it too: a child's environment has the new PATH even when PATH was not exported before
t26d_fail=""
for t26d_need in false true; do
  out="$( (
    sandbox "T26d-$t26d_need" ""
    t26d_dir="$TMP/T26d-$t26d_need/opt-nvim"
    load_script_with "$TMP/T26d-$t26d_need/script/nvim-install.sh" NVIM_INSTALL_DIR "$t26d_dir"
    t26d_before="$PATH"
    export -n PATH
    NEED_PATH_SETUP="$t26d_need"
    put_install_dir_first_on_path
    echo "PATH after the step: $(path_change "$t26d_before" "$t26d_dir")"
    if [[ "$(env | sed -n 's/^PATH=//p')" == "$PATH" ]]; then
      echo "CHILD_PATH=same"
    else
      echo "CHILD_PATH=differs"
    fi
    echo DONE
  ) </dev/null 2>&1)"
  rc=$?
  if [[ "$t26d_need" == true ]]; then
    t26d_want="install dir first"
  else
    t26d_want="unchanged"
  fi
  done_ok $rc "$out" && grep -qxF "PATH after the step: $t26d_want" <<<"$out" \
    || t26d_fail+="[NEED_PATH_SETUP=$t26d_need: want PATH $t26d_want; $(tail -n3 <<<"$out" | tr '\n' ' ')] "
  if [[ "$t26d_need" == true ]]; then
    grep -qxF "CHILD_PATH=same" <<<"$out" || t26d_fail+="[PATH not exported to child processes] "
  fi
done
expect_none T26d-install-dir-path-step "$t26d_fail"

# T26b: is_root_owned_tree, which install_neovim asks before it reuses NVIM_INSTALL_DIR, fails on a tree
# the user owns, on a symlink to one (the check follows it, as the nvim lookup and PATH do, instead of
# skipping it as a symlink), and on a path find cannot read (a missing one): find's error, with nothing
# printed, must not pass for a clean tree. Under each wrapper in FAKE_ROOT_WRAPPERS, a bash that sources
# the script makes a tree root-owned with no group or other write, as the tarball install leaves it (a
# chown that fakeroot fakes, or that unshare -r's mapping already makes true), with a symlink inside:
# the check passes on that clean tree, and fails once one file is group writable or one dir is other
# writable. Without a wrapper, those cases skip, or fail under REQUIRE_ALL=1 (report_no_fake_root).
t26b_fail=""
for id in user-owned symlinked missing; do
  out="$( (
    sandbox "T26b-$id" ""
    load_script
    t26b_tree="$TMP/T26b-$id/tree"
    case "$id" in
      user-owned)
        mkdir -p "$t26b_tree/bin"
        printf '#!/bin/sh\n' >"$t26b_tree/bin/nvim"
        ;;
      symlinked)
        mkdir -p "$TMP/T26b-$id/target/bin"
        printf '#!/bin/sh\n' >"$TMP/T26b-$id/target/bin/nvim"
        ln -s target "$t26b_tree"
        ;;
    esac
    if is_root_owned_tree "$t26b_tree"; then
      echo "found root-owned"
    else
      echo "found not root-owned"
    fi
    echo DONE
  ) </dev/null 2>&1)"
  done_ok $? "$out" && grep -qxF "found not root-owned" <<<"$out" && ! grep -qF 'command not found' <<<"$out" \
    || t26b_fail+="[$id: want not root-owned, got: $(tail -n3 <<<"$out" | tr '\n' ' ')] "
done
expect_none T26b-root-owned-tree "$t26b_fail"
# Run by bash under a fake-root wrapper, with the script under test as $1, the tree as $2, and the case
# as $3: makes the tree root-owned with no group or other write, opens the write bit the case names, and
# prints what is_root_owned_tree finds. The sourced script's errexit stops it, with no DONE, when a step
# fails.
# shellcheck disable=SC2016  # expanded by the bash that runs it, not here
t26b_fake_root_check='source "$1"
chown -R 0:0 "$2"
chmod -R go-w "$2"
case "$3" in
  group-writable-file) chmod g+w "$2/bin/nvim" ;;
  other-writable-dir) chmod o+w "$2/share" ;;
esac
if is_root_owned_tree "$2"; then
  echo "found root-owned"
else
  echo "found not root-owned"
fi
echo DONE'
if [[ ${#FAKE_ROOT_WRAPPERS[@]} -gt 0 ]]; then
  t26b_fail=""
  for wrapper in "${FAKE_ROOT_WRAPPERS[@]}"; do
    read -ra wrapper_cmd <<<"$wrapper"
    for id in clean group-writable-file other-writable-dir; do
      case "$id" in
        clean) want="root-owned" ;;
        *) want="not root-owned" ;;
      esac
      out="$( (
        sandbox "T26b-${wrapper_cmd[0]}-$id" ""
        require_sandbox_home "$TMP" T26b
        t26b_tree="$TMP/T26b-${wrapper_cmd[0]}-$id/tree"
        mkdir -p "$t26b_tree/bin" "$t26b_tree/share"
        printf '#!/bin/sh\n' >"$t26b_tree/bin/nvim"
        printf 'runtime\n' >"$t26b_tree/share/runtime.txt"
        ln -s nvim "$t26b_tree/bin/vi"
        "${wrapper_cmd[@]}" bash -c "$t26b_fake_root_check" bash "$SCRIPT" "$t26b_tree" "$id"
      ) </dev/null 2>&1)"
      done_ok $? "$out" && grep -qxF "found $want" <<<"$out" \
        || t26b_fail+="[$wrapper $id: want $want, got: $(tail -n3 <<<"$out" | tr '\n' ' ')] "
    done
  done
  t26b_ran="$(printf '%s, ' "${FAKE_ROOT_WRAPPERS[@]}")"
  expect_none "T26b-root-owned-tree-fake-root (${t26b_ran%, })" "$t26b_fail"
else
  report_no_fake_root T26b-root-owned-tree-fake-root
fi

# T27: main runs whenever the script is executed rather than sourced: from a string, as
# bash -c "$(curl ...)" runs it, and from standard input, as curl ... | bash does (here bash -s with
# the script on standard input, which takes --help as an argument). Both print the usage text and exit
# 0. (Sourcing never runs main: every test that sources the script relies on that.) And SCRIPT_DIR is
# empty when the script has no file (bash -c and bash -s), and is the script's own dir when it runs by
# a relative path while CDPATH names a dir with a subdir of the same name, which a cd that honored
# CDPATH would go to. Those cases run a copy whose main guard line prints SCRIPT_DIR instead.
t27_fail=""
for form in bash-c bash-s; do
  out="$( (
    sandbox "T27-$form" ""
    require_sandbox_home "$TMP" T27
    if [[ "$form" == bash-c ]]; then
      bash -c "$(cat "$SCRIPT")" bash --help
    else
      bash -s -- --help <"$SCRIPT"
    fi
    echo "rc=$?"
  ) </dev/null 2>&1)"
  grep -qF 'Usage: nvim-install.sh' <<<"$out" && grep -qxF 'rc=0' <<<"$out" \
    || t27_fail+="[$form: $(tail -n3 <<<"$out" | tr '\n' ' ')] "
done
t27_dir="$(sandbox_home T27-script-dir)/work/rel"
out="$( (
  sandbox T27-script-dir ""
  copy_script_with_line "$t27_dir/nvim-install.sh" 'if ! (return 0 2>/dev/null); then' \
    "printf 'SCRIPT_DIR=[%s]\\n' \"\$SCRIPT_DIR\"; if false; then"
  mkdir -p "$HOME/decoy/rel"
  printf 'bash-c %s\n' "$(bash -c "$(cat "$t27_dir/nvim-install.sh")" bash)"
  printf 'bash-s %s\n' "$(bash -s <"$t27_dir/nvim-install.sh")"
  cd "$HOME/work" || exit 1
  printf 'cdpath %s\n' "$(CDPATH="$HOME/decoy" bash rel/nvim-install.sh)"
  echo DONE
) </dev/null 2>&1)"
done_ok $? "$out" || t27_fail+="[script-dir: $(tail -n3 <<<"$out" | tr '\n' ' ')] "
for want in "bash-c SCRIPT_DIR=[]" "bash-s SCRIPT_DIR=[]" "cdpath SCRIPT_DIR=[$t27_dir]"; do
  grep -qxF -- "$want" <<<"$out" || t27_fail+="[want '$want'; got: $(grep -E '^(bash-c|bash-s|cdpath) ' <<<"$out" | tr '\n' ';')] "
done
expect_none T27-main-guard "$t27_fail"

# T28: every sudo invocation in the script sits in its Privilege section (from that header to the next
# section header), so every root command goes through as_root and the boundary it enforces. A static
# check over the non-comment lines, for sudo in command position: at the start of a line or after ; & |
# ! ( ) { } ` $( or a keyword such as if, then, do, or exec, after variable assignments, quoted, or with
# a path in front.
# shellcheck disable=SC2016  # an awk program: $0 and \$\( are awk's, not the shell's
t28_awk='
  /^# Privilege$/ { inside = 1; found = 1; next }
  inside && /^# [A-Z]/ && prev ~ /^# -+$/ { inside = 0 }
  { prev = $0 }
  !/^[[:space:]]*#/ && /(^|[;&|!(){}`]|\$\(|(^|[^[:alnum:]_])(if|elif|while|until|then|do|else|exec|command|env|time|nohup|xargs))[[:space:]]*([[:alpha:]_][[:alnum:]_]*=[^[:space:]]*[[:space:]]+)*["\047]?([^[:space:];&|()"\047]*\/)?sudo["\047]?([[:space:];&|)]|$)/ {
    print (inside ? "inside" : "OUTSIDE") " line " NR ": " $0
  }
  END { if (!found) print "no Privilege section" }
'
t28="$(awk "$t28_awk" "$SCRIPT")"
t28_outside="$(grep -v '^inside ' <<<"$t28")"
[[ -z "$t28_outside" ]] && grep -q '^inside ' <<<"$t28"
result T28-sudo-only-in-privilege $? "$(tr '\n' ';' <<<"${t28_outside:-no sudo found inside the Privilege section}")"

# T29: forget_sudo_credentials closes the privileged phase: a root command after it stops the run with
# exit 1 and an error that names the command, instead of taking a new ticket, so the boundary in main
# holds even if a later step calls as_root
out="$( (
  recording_sandbox T29
  load_script
  # shellcheck disable=SC2329  # run_errexit calls it
  across_the_boundary() {
    ensure_sudo_ticket
    forget_sudo_credentials
    as_root true
    echo "NOT REACHED"
  }
  run_errexit across_the_boundary
  echo "inner rc=$RC"
  echo DONE
) </dev/null 2>&1)"
rc=$?
t29_log="$(sudo_log T29)"
problems=""
done_ok $rc "$out" && grep -qxF "inner rc=1" <<<"$out" || problems+="[rc=$rc, want inner rc=1] "
grep -qF "root command after the privileged phase: true" <<<"$out" || problems+="[no 'after the privileged phase' error] "
! grep -qxF "NOT REACHED" <<<"$out" || problems+="[as_root returned] "
[[ "$(tr '\n' ' ' <"$t29_log")" == "-v -k " ]] || problems+="[sudo log: $(tr '\n' ';' <"$t29_log"), want -v;-k] "
[[ -z "$problems" ]] || problems+="; $(tail -n3 <<<"$out" | tr '\n' ' ')"
expect_none T29-boundary-enforced "$problems"

# T30: the windows around the ticket, through main's real traps (tests/lib/driver-T30.sh). (a) int: the
# flag that makes cleanup drop the ticket is set before sudo -v runs, so an interrupt that lands while
# sudo -v caches the ticket still has it dropped: the recording sudo sends INT to the shell right after
# logging -v, and the run must die by INT without resuming, with cleanup's -k logged after the -v. (b)
# order: cleanup drops the ticket before it removes the scratch dirs, so an interrupt during the removal
# cannot skip the drop: the temp dir holds a marker file that the recording sudo checks on each call,
# and it must still be there at cleanup's -k (the run fails after taking the ticket, and the temp dir is
# gone at the end). (a) is skipped where T9 is.
# $1 = case (int or order)
t30_run() {
  (
    recording_sandbox "T30-$1"
    TMPDIR="$TMP/T30-$1-tmp" T30_CASE="$1"
    export TMPDIR T30_CASE
    mkdir -p "$TMPDIR"
    if [[ "$1" == int ]]; then
      SUDO_INT_ON="-v"
      export SUDO_INT_ON
    fi
    run_with_default_signals bash "$LIB/driver-T30.sh" "$SCRIPT"
  ) </dev/null 2>&1
}
if [[ -z "$INT_RC" ]]; then
  echo "SKIP T30-ticket-windows int (python3 missing, and this suite inherited signal dispositions: $INHERITED_TRAPS)"
else
  out="$(t30_run int)"
  t30_log="$(sudo_log T30-int)"
  problems=""
  got="$(sed -n 's/^rc=//p' <<<"$out" | tail -n1)"
  [[ "$got" == "$INT_RC" ]] && ! grep -qxF RESUMED <<<"$out" \
    || problems+="[rc=${got:-none}, want $INT_RC without resuming: $(tail -n2 <<<"$out" | tr '\n' ' ')] "
  [[ "$(tr '\n' ' ' <"$t30_log")" == "-v -k " ]] || problems+="[sudo log: $(tr '\n' ';' <"$t30_log"), want -v;-k] "
  problems+="$(sudo_allowlist_problems "$t30_log")"
  expect_none "T30-ticket-windows int$SIGNAL_NOTE" "$problems"
fi
out="$(t30_run order)"
t30_log="$(sudo_log T30-order)"
t30_events="$(event_log T30-order)"
t30_k="$(first_line '^sudo -k$' "$t30_events")"
created="$(sed -n 's/^TMPDIR_CREATED //p' <<<"$out")"
problems=""
grep -qxF "rc=1" <<<"$out" || problems+="[want exit 1: $(tail -n2 <<<"$out" | tr '\n' ' ')] "
[[ -n "$t30_k" && "$(sed -n "$((t30_k - 1))p" "$t30_events")" == "marker present" ]] \
  || problems+="[the scratch dir was gone at cleanup's sudo -k (line ${t30_k:-none})] "
[[ -n "$created" && ! -e "$created" ]] || problems+="[temp dir '$created' left behind] "
[[ "$(tr '\n' ' ' <"$t30_log")" == "-v -k " ]] || problems+="[sudo log: $(tr '\n' ';' <"$t30_log"), want -v;-k] "
problems+="$(sudo_allowlist_problems "$t30_log")"
[[ -z "$problems" ]] || problems+="events: $(tr '\n' ';' <"$t30_events")"
expect_none "T30-ticket-windows order" "$problems"

# T31: the script takes at most one argument, and it is --help, -h, or --packages-only. Anything else (an
# unknown argument, the empty one, or a second argument beside --packages-only or --help) prints the error,
# which shows each argument as given (quoted, so an empty one shows as '' and a space inside one stays
# visible), and usage to stderr, and exits 1 before anything runs (nothing on stdout, and the recording
# sudo logs nothing). --help and -h alone print usage to stdout and exit 0, naming the mode flag, the
# Fedora tier row, what Mason installs and when (the first time nvim opens a file, a phrase the usage
# keeps on one line), and the pylsp stand-in.

# Prints a problem unless the script, run with the arguments after $2 in a recording sandbox named $1,
# exits 1 with nothing on stdout, no sudo call, and on stderr the usage and the error message $2 (as
# fixed text); the problem shows the first line of stderr, which is the error message
t31_rejection_problems() {
  local id="$1" want_message="$2" err out rc
  shift 2
  err="$TMP/$id.err"
  out="$( (
    recording_sandbox "$id"
    run_script_args "$@" 2>"$err"
  ) </dev/null)"
  rc=$?
  [[ $rc -eq 1 && -z "$out" && ! -s "$(sudo_log "$id")" ]] \
    && grep -qF -- "$want_message" "$err" && grep -qF 'Usage: nvim-install.sh' "$err" \
    || echo "[$id: rc=$rc stdout=$(tr '\n' ' ' <<<"$out") stderr=$(head -n1 "$err")] "
}
t31_fail=""
for args in "--bogus" "--packages-only extra" "--help extra"; do
  read -ra t31_argv <<<"$args"
  t31_want="unknown argument: $args"
  if [[ ${#t31_argv[@]} -gt 1 ]]; then
    t31_want="too many arguments: $args"
  fi
  t31_fail+="$(t31_rejection_problems "T31-${args// /_}" "$t31_want" "${t31_argv[@]}")"
done
# The cases the word-splitting loop cannot express: an empty argument, and one with a space inside
t31_fail+="$(t31_rejection_problems T31-empty "unknown argument: ''" "")"
t31_fail+="$(t31_rejection_problems T31-quoted 'too many arguments: a\ b c' "a b" c)"
for flag in --help -h; do
  t31_err="$TMP/T31$flag.err"
  out="$( (
    sandbox "T31$flag" ""
    run_script_args "$flag" 2>"$t31_err"
  ) </dev/null)"
  rc=$?
  absent=""
  for want in 'Usage: nvim-install.sh' '--packages-only' '^  Fedora +\(dnf\) +supported$' \
    'Mason installs the native language' 'the first time nvim opens a file;' \
    'On Fedora, python-lsp-server stands in for pyright\.'; do
    # -- : the second pattern starts with a dash, which grep would read as an option
    grep -qE -- "$want" <<<"$out" || absent+="[$want] "
  done
  [[ $rc -eq 0 && -z "$absent" && ! -s "$t31_err" ]] \
    || t31_fail+="[$flag: rc=$rc absent=$absent stderr=$(tr '\n' ' ' <"$t31_err")] "
done
expect_none T31-arguments "$t31_fail"

# T32: every go install is pinned: the script has no @latest, and each GO_TOOL_* constant is
# module/path@vX.Y.Z, the form go install resolves to one exact module version, which Go's checksum
# database then verifies; the script has as many GO_TOOL_* constants as GO_TOOLS has tools, and T17
# checks that each tool's own is the one it installs
t32_fail=""
t32_latest="$(grep -n '@latest' "$SCRIPT")"
t32_consts="$(grep -E '^readonly GO_TOOL_[A-Z_]+=' "$SCRIPT")"
t32_unpinned="$(grep -vE '^readonly GO_TOOL_[A-Z_]+="[a-z0-9./-]+@v[0-9]+\.[0-9]+\.[0-9]+"$' <<<"$t32_consts")"
[[ -z "$t32_latest" ]] || t32_fail+="[@latest: $(tr '\n' ' ' <<<"$t32_latest")] "
[[ "$(grep -c . <<<"$t32_consts")" -eq "$(wc -w <<<"$GO_TOOLS")" ]] \
  || t32_fail+="[GO_TOOL_* constants: $(grep -c . <<<"$t32_consts"), want $(wc -w <<<"$GO_TOOLS")] "
[[ -z "$t32_unpinned" ]] || t32_fail+="[unpinned: $(tr '\n' ' ' <<<"$t32_unpinned")] "
expect_none T32-go-tools-pinned "$t32_fail"

# T32b: the manual hints in install_go_tool (go missing, go env fails) carry GOTOOLCHAIN=local, so
# following one never triggers the toolchain download the script avoids. PATH has no go (EMPTY_BIN) or
# only T19's go stub, which answers GOBIN and so fails only when T19_GO_FAILS is set; nothing is
# installed.
t32b_fail=""
for id in go-missing go-env-fails; do
  case "$id" in
    go-missing) t32b_bin="$EMPTY_BIN" t32b_go_fails="" t32b_hint="install Go, then run:" ;;
    go-env-fails) t32b_bin="$T19_BIN" t32b_go_fails=1 t32b_hint="could not resolve Go's bin dir; run:" ;;
  esac
  out="$( (
    sandbox "T32b-$id" ""
    load_script
    PATH="$t32b_bin" T19_GOBIN=/x/bin T19_GO_FAILS="$t32b_go_fails" \
      install_go_tool lazygit "$GO_TOOL_LAZYGIT" >/dev/null
    want="lazygit: $t32b_hint GOTOOLCHAIN=local go install $GO_TOOL_LAZYGIT"
    [[ ${#WARNINGS[@]} -eq 1 && "${WARNINGS[0]}" == "$want" ]] \
      || { echo "${#WARNINGS[@]} warnings: ${WARNINGS[*]}; want one: $want"; exit 1; }
    echo DONE
  ) </dev/null 2>&1)"
  done_ok $? "$out" || t32b_fail+="[$id hint: $(tail -n2 <<<"$out" | tr '\n' ' ')] "
done
expect_none T32b-go-hints-local "$t32b_fail"

# T33 (RUN_FEDORA=1): the dnf path end to end in a fedora:44 container (tests/lib/fedora-container.sh:
# a --packages-only run, then a full run, then its checks that the full run installed no package again
# (Fedora 44's nodejs is a Provides of nodejs22), nvim came from dnf, the two servers are on PATH, weak
# dependencies stayed off (no npm), the two Go tools were built, and the full run's config check
# passed, meaning its first headless launch gave no error message). That covers errors raised
# while init.lua, lazy's setup (installs and builds), and the start plugins run, and errors those queue
# with vim.schedule, but not timers, plugins lazy loads later, or VimEnter. It pulls the image and
# installs packages inside the container, so it needs podman and network; without the variable or
# podman it is skipped. It passes only when the driver exits 0 and its output has the closing line. The
# driver runs without BASH_ENV, ENV, and CDPATH like the rest of the suite, but keeps the other
# variables hermetic_env drops (GIT_*, ZDOTDIR, the XDG_* dirs, GOTOOLCHAIN): podman reads its storage
# from XDG_DATA_HOME and its containers.conf and storage.conf from XDG_CONFIG_HOME (containers.conf(5),
# containers-storage.conf(5)), so the run uses the user's podman setup. T33 keeps only the last lines of
# the output; to see all of it, run bash tests/lib/fedora-container.sh "$PWD" from the repository root.
if [[ "${RUN_FEDORA:-0}" != 1 ]]; then
  echo "SKIP T33-fedora-container (set RUN_FEDORA=1 to run the dnf path in a fedora:44 container; needs podman and network)"
elif ! command -v podman >/dev/null 2>&1; then
  echo "SKIP T33-fedora-container (RUN_FEDORA=1, but podman is not installed)"
else
  out="$(env -u BASH_ENV -u ENV -u CDPATH bash "$LIB/fedora-container.sh" "$ROOT" 2>&1)"
  rc=$?
  t33_note=""
  if [[ $rc -eq 0 ]] && ! grep -qxF "### all steps passed" <<<"$out"; then
    rc=1
    t33_note=" (no closing line)"
  fi
  result T33-fedora-container $rc "last step: $(grep -E '^### ' <<<"$out" | tail -n1); $(tail -n3 <<<"$out" | tr '\n' ' ')$t33_note"
fi

# T34: the driver library's lists are current. run_main_stubbed stops a driver, before anything runs,
# when DRIVER_RUNS_REAL or DRIVER_STUBBED names a function main does not call (a step removed or renamed
# in main would otherwise leave its entry behind unnoticed), and the message names the list and the
# entry. Each case runs T23's driver against a copy of tests/lib whose library has one stale name
# appended to a list.
t34_fail=""
for list in DRIVER_RUNS_REAL DRIVER_STUBBED; do
  t34_id="T34-stale-$list"
  t34_lib="$TMP/lib-$t34_id"
  mkdir -p "$t34_lib"
  cp "$LIB/common.sh" "$LIB/driver-lib.sh" "$LIB/driver-T23.sh" "$t34_lib/"
  printf '%s+=(retired_step)\n' "$list" >>"$t34_lib/driver-lib.sh"
  out="$( (
    recording_sandbox "$t34_id"
    bash "$t34_lib/driver-T23.sh" "$SCRIPT"
    echo "driver rc=$?"
  ) </dev/null 2>&1)"
  grep -qxF "driver rc=1" <<<"$out" && grep -qF "$list lists retired_step" <<<"$out" \
    && [[ ! -s "$(event_log "$t34_id")" && ! -s "$(sudo_log "$t34_id")" ]] \
    || t34_fail+="[$list: $(tail -n2 <<<"$out" | tr '\n' ' ')] "
done
expect_none T34-driver-lists-current "$t34_fail"

# T35: verify_config warns when the config errors at startup, which Neovim's exit status does not show
# (it exits 0), and not when the config only prints. Each case runs the script's verify_config with the
# real nvim, on a sandbox HOME whose ~/.config/nvim/init.lua is the case's: one with only a comment
# (clean), one that prints with print and with vim.notify at INFO (messages: headless Neovim writes both
# to stderr, so a check that read stderr would fail it), one that calls error() (error), and one that
# calls error() from a vim.schedule callback (deferred: lazy.nvim reports a plugin config's error that
# way, so the launch must run the queued callbacks before it reads v:errmsg). The two that error must
# leave exactly verify_config's two warnings in WARNINGS (the list the summary repeats), in order, and
# no "Config loads cleanly" line; the other two must leave no warning and that line once. hermetic_env
# unsets XDG_CONFIG_HOME, XDG_DATA_HOME, XDG_STATE_HOME, and XDG_CACHE_HOME, so Neovim reads that config
# and writes its data and state under the sandbox HOME. It keeps XDG_CONFIG_DIRS and XDG_DATA_DIRS,
# which each case points at an empty scratch dir under $TMP, because T35 checks verify_config's
# detection on a config it writes and the host's sysinit.vim and plugins must not count
# (XDG_CONFIG_DIRS can list a dir under the real HOME, and Arch's /etc/xdg/nvim/sysinit.vim adds
# /usr/share/vim/vimfiles to the runtimepath): a host plugin that errors would fail clean and messages,
# and pass error and deferred for the wrong reason. Neovim still finds its own runtime ($VIMRUNTIME
# does not come from those dirs). TMPDIR is a scratch dir under $TMP too, and NVIM_APPNAME and VIMINIT
# (which would make Neovim read another config) and NVIM_LOG_FILE (which would put its log elsewhere)
# are unset. Without nvim on PATH, T35 fails and says so.
t35_fail=""
t35_loads="Config loads cleanly"
# verify_config's warnings for a config that errors, one per line
t35_error_warnings=$'Config reported errors at startup\nLaunch nvim to see them (lazy.nvim retries failed downloads, not failed builds)'
if ! type -P nvim >/dev/null; then
  t35_fail="[nvim not on PATH] "
else
  # Each case sets its init.lua, the warnings it wants (one per line), and how many "Config loads
  # cleanly" lines it wants
  for id in clean messages error deferred; do
    case "$id" in
      clean) t35_init='-- no settings' t35_want_warnings="" t35_want_loads_lines=1 ;;
      messages)
        t35_init=$'print("loading")\nvim.notify("loaded", vim.log.levels.INFO)'
        t35_want_warnings="" t35_want_loads_lines=1
        ;;
      error) t35_init='error("broken config")' t35_want_warnings="$t35_error_warnings" t35_want_loads_lines=0 ;;
      deferred)
        t35_init='vim.schedule(function() error("deferred") end)'
        t35_want_warnings="$t35_error_warnings" t35_want_loads_lines=0
        ;;
    esac
    t35_want="$t35_want_loads_lines '$t35_loads' line(s) and warnings '${t35_want_warnings//$'\n'/; }'"
    out="$( (
      sandbox "T35-$id" ""
      load_script
      unset NVIM_APPNAME VIMINIT NVIM_LOG_FILE
      TMPDIR="$TMP/T35-$id-tmp"
      XDG_CONFIG_DIRS="$TMP/T35-$id-system-dirs"
      XDG_DATA_DIRS="$TMP/T35-$id-system-dirs"
      export TMPDIR XDG_CONFIG_DIRS XDG_DATA_DIRS
      mkdir -p "$TMPDIR" "$XDG_CONFIG_DIRS" "$HOME/.config/nvim"
      printf '%s\n' "$t35_init" >"$HOME/.config/nvim/init.lua"
      verify_config
      for warning in "${WARNINGS[@]}"; do
        printf 'WARNING %s\n' "$warning"
      done
      echo DONE
    ) </dev/null 2>&1)"
    done_ok $? "$out" && [[ "$(sed -n 's/^WARNING //p' <<<"$out")" == "$t35_want_warnings" ]] \
      && [[ "$(grep -cF "$t35_loads" <<<"$out")" -eq "$t35_want_loads_lines" ]] \
      || t35_fail+="[$id: want $t35_want; got: $(tr '\n' ' ' <<<"$out")] "
  done
fi
expect_none T35-config-errors "$t35_fail"

# T36: on dnf, pkg_is_installed finds a package by what an installed package provides, as dnf install
# resolves a name, and not only by the installed package names. Fedora 44's nodejs is a Provides of
# nodejs22, so rpm -q nodejs fails with nodejs22 installed, and a check by name alone made every rerun
# install nodejs again. rpm is a stub (T36_BIN) that answers as Fedora's rpm does for nodejs22, which
# also provides nodejs, and ripgrep, which provides only itself; a name nothing provides stays missing.
t36_fail=""
for tc in nodejs:installed ripgrep:installed not-a-package:missing; do
  t36_name="${tc%%:*}" t36_want="${tc#*:}"
  out="$( (
    sandbox "T36-$t36_name" "$T36_BIN"
    load_script
    set_pkg_manager dnf
    T36_INSTALLED="nodejs22:nodejs ripgrep"
    export T36_INSTALLED
    if pkg_is_installed "$t36_name"; then
      echo "found installed"
    else
      echo "found missing"
    fi
    echo DONE
  ) </dev/null 2>&1)"
  done_ok $? "$out" && grep -qxF "found $t36_want" <<<"$out" \
    || t36_fail+="[$t36_name: want $t36_want, got: $(tail -n2 <<<"$out" | tr '\n' ' ')] "
done
expect_none T36-dnf-installed-by-provides "$t36_fail"

# T21 (last): no test reached a refusing DENY_BIN stub
if [[ -e "$TMP/refused.log" ]]; then
  result T21-no-refused-calls 1 "$(tr '\n' ';' <"$TMP/refused.log")"
else
  result T21-no-refused-calls 0
fi

echo "exit=$fail"
exit "$fail"
