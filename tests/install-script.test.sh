#!/usr/bin/env bash
# Tests for nvim-install.sh: bash tests/install-script.test.sh
#
# Hermetic: every stub, fake HOME, and scratch file lives under one temp dir that is removed on exit.
# sudo is always a stub (one refuses, the other records its arguments without running them), so no
# test can install or upgrade anything, and sourced tests export a fake HOME before sourcing, so
# NVIM_CONFIG_DIR never points at a real config. RUN_FULL=1 adds T4, an end-to-end run on this
# machine that must find everything already installed; it is the only test that queries the real
# package manager (pacman -Q, read-only) and reads the real ~/.config/nvim.
# shellcheck source-path=SCRIPTDIR/..
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/nvim-install.sh"
TMP="$(mktemp -d)" || exit 1
trap 'rm -rf -- "${TMP:?}"' EXIT
fail=0

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

# Call first in each sourced test's subshell: a fresh fake HOME, the given stub dirs first on PATH,
# and git never looks above $TMP for a repository.
sandbox() {
  HOME="$TMP/home-$1"
  export HOME
  mkdir -p "$HOME"
  PATH="$2:$PATH"
  GIT_CEILING_DIRECTORIES="$TMP"
  export GIT_CEILING_DIRECTORIES
}

# Source the script under test (default $SCRIPT) into the calling subshell; sourcing never runs main
load_script() {
  # shellcheck source=nvim-install.sh
  source "${1:-$SCRIPT}"
  setup_colors
}

# ---------------------------------------------------------------------------
# Stubs
# ---------------------------------------------------------------------------

# sudo that refuses and logs its arguments, so an unexpected privileged call fails loudly
write_refusing_sudo() {
  local dir="$1" log="$2"
  mkdir -p "$dir"
  cat >"$dir/sudo" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$log"
echo "STUB SUDO BLOCKED: \$*" >&2
exit 1
EOF
  chmod +x "$dir/sudo"
}
REFUSE_BIN="$TMP/bin-refuse"
write_refusing_sudo "$REFUSE_BIN" "$TMP/refused-sudo.log"

# sudo that appends its arguments to $SUDO_LOG and never runs them; it fails only when its
# arguments equal $SUDO_FAIL_ON
RECORD_BIN="$TMP/bin-record"
mkdir -p "$RECORD_BIN"
cat >"$RECORD_BIN/sudo" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"${SUDO_LOG:?}"
if [ "$*" = "${SUDO_FAIL_ON:-}" ]; then
  echo "STUB SUDO: failing $*" >&2
  exit 1
fi
exit 0
EOF
chmod +x "$RECORD_BIN/sudo"

# git that refuses to clone (no network) and passes everything else to the real git
GIT_BIN="$TMP/bin-git"
mkdir -p "$GIT_BIN"
cat >"$GIT_BIN/git" <<EOF
#!/bin/sh
if [ "\$1" = clone ]; then
  echo "STUB GIT CLONE BLOCKED: \$*" >&2
  exit 1
fi
exec "$(command -v git)" "\$@"
EOF
chmod +x "$GIT_BIN/git"

# Package manager binaries for detection tests; they refuse to run
PKG_BIN="$TMP/bin-pkgmgr"
mkdir -p "$PKG_BIN"
for mgr in pacman apt-get; do
  printf '#!/bin/sh\necho "STUB %s BLOCKED" >&2\nexit 1\n' "$mgr" >"$PKG_BIN/$mgr"
  chmod +x "$PKG_BIN/$mgr"
done

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

# T1: syntax and shellcheck
if ! bash -n "$SCRIPT"; then
  result T1-static 1 "bash -n"
elif ! command -v shellcheck >/dev/null 2>&1; then
  echo "SKIP T1-static (shellcheck not installed; bash -n passed)"
else
  shellcheck "$SCRIPT"
  result T1-static $?
fi

# T2: the plan screen names the platform and, on pacman, the upfront system upgrade;
# "n" and end of input both cancel cleanly
host_mgr="$( (
  sandbox T2-detect "$REFUSE_BIN"
  load_script
  detect_pkg_manager
  printf '%s\n' "$PKG_MGR"
) </dev/null 2>/dev/null)"
if [[ "$host_mgr" != pacman ]]; then
  echo "SKIP T2-plan-screen (the script detects '${host_mgr:-nothing}' here, not pacman)"
else
  mkdir -p "$TMP/home-T2"
  out="$(printf 'n\n' | HOME="$TMP/home-T2" PATH="$REFUSE_BIN:$PATH" "$SCRIPT" 2>&1)"
  rc=$?
  eof_out="$(HOME="$TMP/home-T2" PATH="$REFUSE_BIN:$PATH" "$SCRIPT" </dev/null 2>&1)"
  eof_rc=$?
  absent=""
  for want in 'OS: +linux' 'Architecture: +(x86_64|arm64)' 'Package manager: +pacman' 'Support tier: +first-class' \
    '0\. Upgrade the system first \(pacman -Syu' '1\. Install Neovim 0\.12\+' 'Cancelled\.'; do
    grep -qE "$want" <<<"$out" || absent+="[$want] "
  done
  [[ $rc -eq 0 && -z "$absent" && $eof_rc -eq 0 ]] && grep -qF 'Cancelled.' <<<"$eof_out" \
    && ! grep -qF 'STUB SUDO' <<<"$out$eof_out"
  result T2-plan-screen $? "rc=$rc eof_rc=$eof_rc absent=$absent; EOF run: $(tail -n2 <<<"$eof_out" | tr '\n' ' ')"
fi

# T3: root guard (fakeroot reports EUID 0)
if ! command -v fakeroot >/dev/null 2>&1; then
  echo "SKIP T3-root-guard (fakeroot not installed)"
else
  out="$(HOME="$TMP/home-T3" PATH="$REFUSE_BIN:$PATH" fakeroot "$SCRIPT" </dev/null 2>&1)"
  rc=$?
  [[ $rc -eq 1 ]] && grep -qF "Do not run this script as root" <<<"$out"
  result T3-root-guard $? "rc=$rc"
fi

# T4 (RUN_FULL=1 only): end-to-end run on a fully provisioned Arch machine. Nothing may be installed,
# so sudo is a refusing stub and the upfront upgrade must never run. HOME stays real, because the
# run must find the real checkout, so T4 runs only when ~/.config/nvim is a clone of this repo
# (setup_config then leaves it in place). The verification launch uses scratch XDG dirs and a copy
# of this checkout as its config, so the real checkout, plugins, and lazy-lock.json are never written.
if [[ "${RUN_FULL:-0}" != 1 ]]; then
  echo "SKIP T4 (set RUN_FULL=1 on a fully provisioned Arch machine)"
else
  live_config="$HOME/.config/nvim"
  live_remote="$(git -C "$live_config" remote get-url origin 2>/dev/null || true)"
  if ! (
    sandbox T4-guard "$REFUSE_BIN"
    load_script
    is_config_repo_url "$live_remote"
  ) </dev/null >/dev/null 2>&1; then
    result T4-idempotent-run 1 "origin of $live_config is '$live_remote', not this repo; refusing a full run"
  else
    xdg="$TMP/T4-xdg"
    mkdir -p "$xdg/config/nvim" "$xdg/data" "$xdg/state" "$xdg/cache" "$TMP/T4-tmp"
    tar -C "$ROOT" --exclude=./.git -cf - . | tar -C "$xdg/config/nvim" -xf -
    write_refusing_sudo "$TMP/bin-T4" "$TMP/T4-sudo.log"
    status_before="$(GIT_OPTIONAL_LOCKS=0 git -C "$live_config" status --porcelain --untracked-files=all)"
    out="$(printf 'y\n' | PATH="$TMP/bin-T4:$PATH" TMPDIR="$TMP/T4-tmp" XDG_CONFIG_HOME="$xdg/config" \
      XDG_DATA_HOME="$xdg/data" XDG_STATE_HOME="$xdg/state" XDG_CACHE_HOME="$xdg/cache" "$SCRIPT" 2>&1)"
    rc=$?
    status_after="$(GIT_OPTIONAL_LOCKS=0 git -C "$live_config" status --porcelain --untracked-files=all)"
    problems=""
    [[ $rc -eq 0 ]] || problems+="[rc=$rc] "
    [[ ! -s "$TMP/T4-sudo.log" ]] || problems+="[sudo called: $(tr '\n' ';' <"$TMP/T4-sudo.log")] "
    ! grep -qE '==> .*(Installing|Upgrading)' <<<"$out" || problems+="[installed or upgraded something] "
    grep -qF "Config already present at $live_config" <<<"$out" || problems+="[config not found in place] "
    grep -qF "Neovim Bootstrap Complete" <<<"$out" || problems+="[no summary] "
    if ! command -v hadolint >/dev/null 2>&1; then
      grep -qF "hadolint: not in the official repos" <<<"$out" || problems+="[no hadolint hint] "
    fi
    [[ "$status_before" == "$status_after" ]] || problems+="[the run changed $live_config] "
    [[ -z "$problems" ]] || problems+="; last lines: $(tail -n8 <<<"$out" | tr '\n' ' ')"
    expect_none T4-idempotent-run "$problems"
  fi
fi

# T5: no npm/pip/yay/paru invocations; the only match is the hadolint warn string
matches="$(grep -nE '\b(npm|pip|pipx|yay|paru)\b' "$SCRIPT")"
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
  sandbox T7 "$REFUSE_BIN"
  load_script
  PKG_MGR=pacman
  CALLS=0
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
  rc=0; (install_pkgs required grp bad) >/dev/null 2>&1 || rc=$?
  [[ $rc -eq 1 ]] || { echo "required rc=$rc"; exit 1; }
  rc=0; (install_pkgs typo grp good) >/dev/null 2>&1 || rc=$?
  [[ $rc -eq 1 ]] || { echo "typo mode rc=$rc"; exit 1; }
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
  sandbox T8 "$REFUSE_BIN"
  load_script
  for tc in debian:apt-get mint:apt-get endeavouros:pacman fedora:dnf rocky:dnf alpine:apk void: absent:; do
    got="$(os_release_pkg_mgr "$osr/${tc%%:*}")"
    [[ "$got" == "${tc#*:}" ]] || { echo "os_release_pkg_mgr ${tc%%:*}: want '${tc#*:}', got '$got'"; exit 1; }
  done
  [[ "$(os_release_pkg_mgr)" == "$(os_release_pkg_mgr /etc/os-release)" ]] \
    || { echo "no argument does not read /etc/os-release"; exit 1; }
  # Detection sees only the stub pacman and apt-get; os_release_pkg_mgr stands in for the file
  for tc in "apt-get:apt-get best-effort" "pacman:pacman first-class" ":pacman first-class" \
    "dnf:pacman first-class"; do
    OSR_MGR="${tc%%:*}"
    os_release_pkg_mgr() { printf '%s\n' "$OSR_MGR"; }
    PKG_MGR="" PKG_TIER=""
    PATH="$PKG_BIN" detect_pkg_manager
    [[ "$PKG_MGR $PKG_TIER" == "${tc#*:}" ]] \
      || { echo "os-release '$OSR_MGR': want '${tc#*:}', got '$PKG_MGR $PKG_TIER'"; exit 1; }
  done
  echo DONE
) </dev/null 2>&1)"
done_ok $? "$out" && ! grep -nE 'OS_RELEASE_FILE|NVIM_INSTALL_OS_RELEASE' "$SCRIPT"
result T8-detection $? "$(tail -n3 <<<"$out")"

# T9: sourcing sets no traps; main sets them, and INT or TERM then exits 130 or 143 after cleanup
# instead of resuming. This drives main and a real signal rather than grepping main's source, so it
# checks the behavior (no resume, temp dir removed, exit status), not just the trap text.
t9_signal() {
  local sig="$1"
  (
    sandbox "T9-$sig" "$REFUSE_BIN"
    TMPDIR="$TMP/T9-$sig-tmp"
    export TMPDIR
    mkdir -p "$TMPDIR"
    # trap -p in a subshell still lists this file's EXIT trap until the subshell sets its own
    trap - EXIT INT TERM
    load_script
    if [[ -n "$(trap -p EXIT INT TERM)" ]]; then
      echo "sourcing set traps: $(trap -p EXIT INT TERM)"
      exit 1
    fi
    # The first step after main sets its traps; stands in for work in progress when the signal arrives
    require_non_root() {
      create_tmpdir
      echo "TMPDIR_CREATED $SCRIPT_TMPDIR"
      kill -s "$sig" "$BASHPID"
      echo RESUMED
    }
    main
  ) </dev/null 2>&1
}
t9_fail=""
for tc in INT:130 TERM:143; do
  out="$(t9_signal "${tc%%:*}")"
  rc=$?
  created="$(sed -n 's/^TMPDIR_CREATED //p' <<<"$out")"
  [[ $rc -eq ${tc#*:} && -n "$created" && ! -e "$created" ]] && ! grep -qxF RESUMED <<<"$out" \
    || t9_fail+="[${tc%%:*}: rc=$rc created='$created' $(tail -n2 <<<"$out" | tr '\n' ' ')] "
done
expect_none T9-signal-traps "$t9_fail"

# T10: an SSH origin counts as this repo, so setup_config leaves the checkout in place
out="$( (
  sandbox T10 "$REFUSE_BIN"
  git init -q -b main "$HOME/.config/nvim"
  git -C "$HOME/.config/nvim" remote add origin git@github.com:jkleinne/nvim.git
  printf 'local work\n' >"$HOME/.config/nvim/untracked.lua"
  load_script
  [[ "$NVIM_CONFIG_DIR" == "$TMP/home-T10/.config/nvim" ]] || { echo "NVIM_CONFIG_DIR=$NVIM_CONFIG_DIR"; exit 1; }
  setup_config
  echo DONE
) </dev/null 2>&1)"
rc=$?
backups="$(compgen -G "$TMP/home-T10/.config/nvim.bak.*" || true)"
done_ok $rc "$out" && grep -qF "Config already present" <<<"$out" \
  && [[ -f "$TMP/home-T10/.config/nvim/untracked.lua" && -z "$backups" ]]
result T10-ssh-remote $? "rc=$rc backups=[$backups]; $(tail -n3 <<<"$out" | tr '\n' ' ')"

# T11: run from a clone of the repo elsewhere, setup_config skips before any prompt or move, even when told y.
# A copy of the script in a scratch clone makes SCRIPT_DIR that clone; the git stub refuses clone.
out="$( (
  sandbox T11 "$GIT_BIN:$REFUSE_BIN"
  git init -q -b main "$HOME/.config/nvim"
  git -C "$HOME/.config/nvim" remote add origin https://github.com/someone/else
  printf 'local work\n' >"$HOME/.config/nvim/untracked.lua"
  git init -q -b main "$HOME/src/nvim"
  git -C "$HOME/src/nvim" remote add origin https://github.com/jkleinne/nvim
  cp "$SCRIPT" "$HOME/src/nvim/nvim-install.sh"
  load_script "$HOME/src/nvim/nvim-install.sh"
  [[ "$NVIM_CONFIG_DIR" == "$HOME/.config/nvim" && "$SCRIPT_DIR" == "$HOME/src/nvim" ]] \
    || { echo "NVIM_CONFIG_DIR=$NVIM_CONFIG_DIR SCRIPT_DIR=$SCRIPT_DIR"; exit 1; }
  printf 'y\n' | setup_config
  echo DONE
) </dev/null 2>&1)"
rc=$?
t11_config="$TMP/home-T11/.config/nvim"
backups="$(compgen -G "$t11_config.bak.*" || true)"
done_ok $rc "$out" && grep -qF "Skipping automatic config setup" <<<"$out" \
  && [[ -f "$t11_config/untracked.lua" && -z "$backups" ]] \
  && [[ "$(git -C "$t11_config" remote get-url origin)" == https://github.com/someone/else ]]
result T11-no-move-from-foreign-clone $? "rc=$rc backups=[$backups]; $(tail -n4 <<<"$out" | tr '\n' ' ')"

# T12: the first real install checks sudo once and runs pacman -Syu once, before any pacman -S;
# the Neovim install path does the same, apt-get refreshes once, and nothing missing means no sudo.
# $1 = case id, $2 = package manager, $3 = 1 when every package counts as installed, $4 = steps to run
t12_case() {
  (
    sandbox "T12-$1" "$RECORD_BIN"
    SUDO_LOG="$TMP/T12-$1-sudo.log"
    export SUDO_LOG
    : >"$SUDO_LOG"
    load_script
    PKG_MGR="$2"
    if [[ "$3" == 1 ]]; then
      pkg_is_installed() { return 0; }
    else
      pkg_is_installed() { return 1; }
    fi
    case "$4" in
      pkgs) install_pkgs optional "group one" a b && install_pkgs optional "group two" c ;;
      neovim) pkg_install_neovim && install_pkgs optional "group" d ;;
    esac >/dev/null
    echo DONE
  ) </dev/null 2>&1
}
# Prints the problems with a sudo log: $1 = log, $2 = refresh command, $3 = install command prefix
t12_check_log() {
  local log="$1" refresh="$2" install="$3" first_refresh first_install
  first_refresh="$(grep -nxF -- "$refresh" "$log" | head -n1 | cut -d: -f1)"
  first_install="$(grep -nF -- "$install" "$log" | head -n1 | cut -d: -f1)"
  [[ "$(head -n1 "$log")" == "-v" ]] || echo "[first sudo call is not -v]"
  [[ "$(grep -cxF -- "-v" "$log")" -eq 1 ]] || echo "[-v count $(grep -cxF -- "-v" "$log")]"
  [[ "$(grep -cxF -- "$refresh" "$log")" -eq 1 ]] || echo "[$refresh count $(grep -cxF -- "$refresh" "$log")]"
  [[ -n "$first_refresh" && -n "$first_install" && $first_refresh -lt $first_install ]] \
    || echo "[$refresh (line ${first_refresh:-none}) not before $install (line ${first_install:-none})]"
}
t12_fail=""
for tc in "pacman-pkgs:pacman:0:pkgs:pacman -Syu:pacman -S --noconfirm" \
  "pacman-neovim:pacman:0:neovim:pacman -Syu:pacman -S --noconfirm neovim" \
  "apt-neovim:apt-get:0:neovim:apt-get update -qq:apt-get install -y neovim"; do
  IFS=: read -r id mgr all_installed steps refresh install <<<"$tc"
  out="$(t12_case "$id" "$mgr" "$all_installed" "$steps")"
  rc=$?
  log="$TMP/T12-$id-sudo.log"
  problems="$(t12_check_log "$log" "$refresh" "$install" | tr '\n' ' ')"
  done_ok $rc "$out" && [[ -z "$problems" ]] \
    || t12_fail+="[$id: rc=$rc $problems log: $(tr '\n' ';' <"$log")] "
done
out="$(t12_case all-installed pacman 1 pkgs)"
rc=$?
done_ok $rc "$out" && [[ ! -s "$TMP/T12-all-installed-sudo.log" ]] \
  || t12_fail+="[all-installed: rc=$rc sudo log: $(tr '\n' ';' <"$TMP/T12-all-installed-sudo.log")] "
# install_deps no longer refreshes apt itself; the refresh lives only in pkg_ready_once
[[ "$(grep -c 'apt-get update' "$SCRIPT")" -eq 1 ]] || t12_fail+="[apt-get update appears more than once] "
expect_none T12-refresh-once "$t12_fail"

# T13: a declined or failed pacman -Syu stops the run before any install (no partial upgrade)
out="$( (
  sandbox T13 "$RECORD_BIN"
  SUDO_LOG="$TMP/T13-sudo.log" SUDO_FAIL_ON="pacman -Syu"
  export SUDO_LOG SUDO_FAIL_ON
  load_script
  PKG_MGR=pacman
  pkg_is_installed() { return 1; }
  rc=0
  (install_pkgs optional grp pkg) || rc=$?
  echo "inner rc=$rc"
  echo DONE
) </dev/null 2>&1)"
rc=$?
done_ok $rc "$out" && grep -qxF "inner rc=1" <<<"$out" && grep -qF "partial upgrade" <<<"$out" \
  && ! grep -qF -- "-S --noconfirm" "$TMP/T13-sudo.log"
result T13-upgrade-declined $? "rc=$rc; sudo log: $(tr '\n' ';' <"$TMP/T13-sudo.log" 2>/dev/null); $(tail -n4 <<<"$out" | tr '\n' ' ')"

# T14: confirm treats only y or Y as yes; end of input, an empty answer, n, and anything else are no.
# Every prompt in the script goes through it.
out="$( (
  sandbox T14 "$REFUSE_BIN"
  load_script
  if confirm "q" </dev/null; then echo "end of input counted as yes"; exit 1; fi
  printf 'y\n' | confirm "q" || { echo "y counted as no"; exit 1; }
  printf 'Y\n' | confirm "q" || { echo "Y counted as no"; exit 1; }
  for answer in n '' yes; do
    if printf '%s\n' "$answer" | confirm "q"; then echo "'$answer' counted as yes"; exit 1; fi
  done
  echo DONE
) </dev/null 2>&1)"
rc=$?
reads="$(grep -c 'read -rp' "$SCRIPT")"
done_ok $rc "$out" && [[ "$reads" -eq 1 ]]
result T14-confirm-eof $? "rc=$rc read -rp count=$reads; $(tail -n2 <<<"$out" | tr '\n' ' ')"

# T15: the PATH hint appends, like setup_path, so user dirs never shadow system binaries
want="export PATH=\"\$PATH:/nonexistent/bin\""
out="$( (
  sandbox T15 "$REFUSE_BIN"
  load_script
  warn_if_not_on_path /nonexistent/bin
  echo DONE
) </dev/null 2>&1)"
done_ok $? "$out" && grep -qF -- "$want" <<<"$out"
result T15-path-hint-appends $? "$(head -n1 <<<"$out")"

# T16: declining the config move (n, or end of input) leaves the foreign config untouched and
# returns, so the run goes on to the summary with the warning in it. The script runs from a plain
# directory, not a clone of this repo, so setup_config reaches the prompt; the git stub refuses clone.
t16_case() {
  local answer="$1"
  (
    sandbox "T16-$answer" "$GIT_BIN:$REFUSE_BIN"
    git init -q -b main "$HOME/.config/nvim"
    git -C "$HOME/.config/nvim" remote add origin https://github.com/someone/else
    printf 'local work\n' >"$HOME/.config/nvim/untracked.lua"
    mkdir -p "$HOME/plain"
    cp "$SCRIPT" "$HOME/plain/nvim-install.sh"
    load_script "$HOME/plain/nvim-install.sh"
    [[ "$NVIM_CONFIG_DIR" == "$HOME/.config/nvim" && "$SCRIPT_DIR" == "$HOME/plain" ]] \
      || { echo "NVIM_CONFIG_DIR=$NVIM_CONFIG_DIR SCRIPT_DIR=$SCRIPT_DIR"; exit 1; }
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
  t16_config="$TMP/home-T16-$answer/.config/nvim"
  backups="$(compgen -G "$t16_config.bak.*" || true)"
  done_ok $rc "$out" && grep -qF "Left $t16_config in place; move it aside yourself" <<<"$out" \
    && [[ -f "$t16_config/untracked.lua" && -z "$backups" ]] \
    && [[ "$(git -C "$t16_config" remote get-url origin)" == https://github.com/someone/else ]] \
    && ! grep -qF "STUB GIT CLONE BLOCKED" <<<"$out" \
    || t16_fail+="[$answer: rc=$rc backups=[$backups] $(tail -n3 <<<"$out" | tr '\n' ' ')] "
done
expect_none T16-decline-move-continues "$t16_fail"

echo "exit=$fail"
exit "$fail"
