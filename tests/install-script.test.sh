#!/usr/bin/env bash
# Tests for nvim-install.sh: bash tests/install-script.test.sh
#
# Hermetic: every stub, fake HOME, and scratch file lives under one temp dir that is removed on exit.
# sudo is always a stub (one refuses, the other records its arguments without running them), and
# git clone, go, and uv are stubs wherever a test reaches them, so no test can install, upgrade, or
# download a package; sourced tests export a fake HOME before sourcing, so NVIM_CONFIG_DIR never
# points at a real config. RUN_FULL=1 adds T4, an end-to-end run on this machine (see T4), which
# also reads the real ~/.config/nvim. T4 and T20 (d) are the only parts that query the real package
# manager, both read-only (pacman -Q, pacman -Qlq).
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

# sudo that appends its arguments to $SUDO_LOG (and "sudo <args>" to $EVENT_LOG when set, a log
# other stubs share) and never runs them; it fails only when its arguments equal $SUDO_FAIL_ON
RECORD_BIN="$TMP/bin-record"
mkdir -p "$RECORD_BIN"
cat >"$RECORD_BIN/sudo" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"${SUDO_LOG:?}"
if [ -n "${EVENT_LOG:-}" ]; then
  printf 'sudo %s\n' "$*" >>"$EVENT_LOG"
fi
if [ "$*" = "${SUDO_FAIL_ON:-}" ]; then
  echo "STUB SUDO: failing $*" >&2
  exit 1
fi
exit 0
EOF
chmod +x "$RECORD_BIN/sudo"

# git that refuses to clone (no network) and passes everything else to the real git
REAL_GIT="$(command -v git)"
GIT_BIN="$TMP/bin-git"
mkdir -p "$GIT_BIN"
cat >"$GIT_BIN/git" <<EOF
#!/bin/sh
if [ "\$1" = clone ]; then
  echo "STUB GIT CLONE BLOCKED: \$*" >&2
  exit 1
fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$GIT_BIN/git"

# git whose clone, offline, creates the target (last argument) as a repo with this repo's origin and
# a marker file "cloned"; everything else goes to the real git
CLONE_GIT_BIN="$TMP/bin-git-clone"
mkdir -p "$CLONE_GIT_BIN"
cat >"$CLONE_GIT_BIN/git" <<EOF
#!/bin/sh
if [ "\$1" = clone ]; then
  for dest; do :; done
  mkdir -p "\$dest" && : >"\$dest/cloned" && "$REAL_GIT" init -q -b main "\$dest" \\
    && "$REAL_GIT" -C "\$dest" remote add origin https://github.com/jkleinne/nvim.git
  exit \$?
fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$CLONE_GIT_BIN/git"

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

# T3: root guard, under every wrapper that reports EUID 0 here: fakeroot, and unshare -r when this
# kernel lets an unprivileged user map itself to root in a user namespace
t3_wrappers=()
if command -v fakeroot >/dev/null 2>&1; then
  t3_wrappers+=(fakeroot)
fi
if command -v unshare >/dev/null 2>&1 && unshare -r true >/dev/null 2>&1; then
  t3_wrappers+=("unshare -r")
fi
if [[ ${#t3_wrappers[@]} -eq 0 ]]; then
  echo "SKIP T3-root-guard (neither fakeroot nor unshare -r works here)"
else
  t3_fail=""
  for wrapper in "${t3_wrappers[@]}"; do
    read -ra wrapper_cmd <<<"$wrapper"
    out="$(HOME="$TMP/home-T3" PATH="$REFUSE_BIN:$PATH" "${wrapper_cmd[@]}" "$SCRIPT" </dev/null 2>&1)"
    rc=$?
    [[ $rc -eq 1 ]] && grep -qF "Do not run this script as root" <<<"$out" \
      || t3_fail+="[$wrapper: rc=$rc $(tail -n2 <<<"$out" | tr '\n' ' ')] "
  done
  t3_ran="$(printf '%s, ' "${t3_wrappers[@]}")"
  expect_none "T3-root-guard (${t3_ran%, })" "$t3_fail"
fi

# T4 (RUN_FULL=1, Arch only): runs the real script end to end on this machine. On a fully provisioned
# machine nothing is installed: sudo is a refusing stub, so any install, or the upfront upgrade, fails
# the test. HOME stays real, because the run must find the real checkout, so T4 runs only when
# ~/.config/nvim is a clone of this repo (setup_config then leaves it in place). The verification
# launch needs network: lazy.nvim bootstraps itself and installs every plugin, running their build
# steps, into scratch XDG dirs whose config is a copy of this checkout, so the real checkout, its
# plugins, and lazy-lock.json are never written.
if [[ "${RUN_FULL:-0}" != 1 ]]; then
  echo "SKIP T4 (set RUN_FULL=1 on a fully provisioned Arch machine)"
elif [[ "$host_mgr" != pacman ]]; then
  echo "SKIP T4 (not an Arch host)"
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

# T9: sourcing sets no traps; main sets them, and INT or TERM then runs the EXIT cleanup and kills the
# script with the same signal instead of resuming, so a calling shell or loop sees the interrupt. A
# driver runs main as its own process with a real signal, and python3 reports how it ended (death by
# signal N is return code -N; exit 130 or 143 would look like an ordinary failure), so this checks the
# behavior (no resume, temp dir removed, signal death), not just the trap text.
cat >"$TMP/T9-driver.sh" <<'EOF'
# Sources the script under test ($1) and runs main; its first step creates the temp dir and sends
# $T9_SIG to the shell, standing in for work in progress when the signal arrives
source "$1"
if [[ -n "$(trap -p EXIT INT TERM)" ]]; then
  echo "sourcing set traps: $(trap -p EXIT INT TERM)"
  exit 1
fi
require_non_root() {
  create_tmpdir
  echo "TMPDIR_CREATED $SCRIPT_TMPDIR"
  kill -s "$T9_SIG" "$BASHPID"
  echo RESUMED
}
main
EOF
t9_signal() {
  local sig="$1"
  (
    sandbox "T9-$sig" "$REFUSE_BIN"
    TMPDIR="$TMP/T9-$sig-tmp" T9_SIG="$sig"
    export TMPDIR T9_SIG
    mkdir -p "$TMPDIR"
    if command -v python3 >/dev/null 2>&1; then
      python3 -I -c 'import subprocess,sys; r=subprocess.run(sys.argv[1:], stdin=subprocess.DEVNULL); sys.stdout.write("rc=%d\n" % r.returncode)' bash "$TMP/T9-driver.sh" "$SCRIPT"
    else
      bash "$TMP/T9-driver.sh" "$SCRIPT"
      echo "rc=$?"
    fi
  ) </dev/null 2>&1
}
if command -v python3 >/dev/null 2>&1; then
  t9_cases=(INT:-2 TERM:-15) t9_note=""
else
  t9_cases=(INT:130 TERM:143) t9_note=" (signal death not checked: python3 missing)"
fi
t9_fail=""
for tc in "${t9_cases[@]}"; do
  out="$(t9_signal "${tc%%:*}")"
  got="$(sed -n 's/^rc=//p' <<<"$out" | tail -n1)"
  created="$(sed -n 's/^TMPDIR_CREATED //p' <<<"$out")"
  [[ "$got" == "${tc#*:}" && -n "$created" && ! -e "$created" ]] && ! grep -qxF RESUMED <<<"$out" \
    || t9_fail+="[${tc%%:*}: rc=${got:-none} created='$created' $(tail -n2 <<<"$out" | tr '\n' ' ')] "
done
expect_none "T9-signal-traps$t9_note" "$t9_fail"

# T10: an SSH origin counts as this repo, so setup_config leaves the checkout in place
out="$( (
  sandbox T10 "$GIT_BIN:$REFUSE_BIN"
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
# installing Neovim goes through the same path, apt-get refreshes once (also across a whole
# install_deps), nothing missing means no sudo, and a missing sudo binary stops the first install.
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
      neovim) pkg_install neovim && install_pkgs optional "group" d ;;
      deps)
        # No-ops, so no go install or uv tool install can run; package installs only reach the stub
        install_python_tool() { :; }
        install_go_tool() { :; }
        install_deps
        ;;
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
  "apt-neovim:apt-get:0:neovim:apt-get update -qq:apt-get install -y neovim" \
  "apt-deps:apt-get:0:deps:apt-get update -qq:apt-get install -y"; do
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
# No sudo binary: the first install stops with a clear error. PATH is an empty dir; the guard,
# require_sudo, and error use only builtins.
mkdir -p "$TMP/empty-bin"
out="$( (
  sandbox T12-no-sudo "$REFUSE_BIN"
  load_script
  rc=0
  # shellcheck disable=SC2123  # replacing PATH is the point: no sudo binary can be found
  (PATH="$TMP/empty-bin"; PKG_MGR=pacman; pkg_ready_once) || rc=$?
  echo "inner rc=$rc"
  echo DONE
) </dev/null 2>&1)"
rc=$?
done_ok $rc "$out" && grep -qxF "inner rc=1" <<<"$out" && grep -qF "sudo is required" <<<"$out" \
  || t12_fail+="[no-sudo: rc=$rc $(tail -n3 <<<"$out" | tr '\n' ' ')] "
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
# Every read builtin call on a non-comment line sits inside confirm(), and there is exactly one. A
# read from a here-string (version_gte) parses a string, not the terminal, so it does not count.
reads="$(awk '
  /^confirm\(\) \{/ { inside = 1 }
  !/^[[:space:]]*#/ && /(^|[;&|({[:space:]])read([[:space:]]|$)/ && !/<<</ {
    print (inside ? "inside" : "outside") " confirm, line " NR ": " $0
  }
  inside && /^\}/ { inside = 0 }
' "$SCRIPT")"
done_ok $rc "$out" && [[ "$(wc -l <<<"$reads")" -eq 1 && "$reads" == "inside confirm"* ]]
result T14-confirm-eof $? "rc=$rc reads: $(tr '\n' ';' <<<"$reads"); $(tail -n2 <<<"$out" | tr '\n' ' ')"

# T15: the PATH hint appends, like setup_path, so user dirs never shadow system binaries; fish gets
# its own line, which needs --path to append
for tc in "bash:export PATH=\"\$PATH:/nonexistent/bin\"" "fish:fish_add_path --append --path /nonexistent/bin"; do
  out="$( (
    sandbox "T15-${tc%%:*}" "$REFUSE_BIN"
    load_script
    USER_SHELL="${tc%%:*}"
    warn_if_not_on_path /nonexistent/bin
    echo DONE
  ) </dev/null 2>&1)"
  done_ok $? "$out" && grep -qF -- "${tc#*:}" <<<"$out"
  result "T15-path-hint-appends ${tc%%:*}" $? "$(head -n1 <<<"$out")"
done

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

# T17: once package installs are done, the cached sudo ticket is dropped before go install or
# uv tool install runs, and neither ever runs under sudo. One event log records the sudo, go, and uv
# calls in order; go and uv are stubs whose installs only log, so nothing real is installed.
T17_BIN="$TMP/bin-T17"
mkdir -p "$T17_BIN"
cat >"$T17_BIN/go" <<EOF
#!/bin/sh
printf 'go %s\n' "\$*" >>"\${EVENT_LOG:?}"
case "\$*" in
  "env GOBIN") printf '%s\n' "$TMP/T17-gobin" ;;
  "install "*) ;;
  *) echo "STUB GO: refusing \$*" >&2; exit 1 ;;
esac
EOF
cat >"$T17_BIN/uv" <<EOF
#!/bin/sh
printf 'uv %s\n' "\$*" >>"\${EVENT_LOG:?}"
case "\$*" in
  "tool dir --bin") printf '%s\n' "$TMP/T17-uvbin" ;;
  "tool install "*) ;;
  *) echo "STUB UV: refusing \$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$T17_BIN/go" "$T17_BIN/uv"
t17_events="$TMP/T17-events.log"
out="$( (
  sandbox T17 "$T17_BIN:$RECORD_BIN"
  SUDO_LOG="$TMP/T17-sudo.log" EVENT_LOG="$t17_events"
  export SUDO_LOG EVENT_LOG
  : >"$EVENT_LOG"
  load_script
  PKG_MGR=apt-get
  pkg_is_installed() { return 1; }
  # Names on no real PATH, so install_soft does not skip them
  install_pkgs optional grp p1
  install_go_tool t17-fake-go example.invalid/fake@latest
  install_python_tool t17-fake-py
  echo DONE
) </dev/null 2>&1)"
rc=$?
t17_line() { grep -nE -- "$1" "$t17_events" | head -n1 | cut -d: -f1; }
apt_install="$(t17_line '^sudo apt-get install ')"
first_k="$(t17_line '^sudo -k$')"
go_install="$(t17_line '^go install ')"
uv_install="$(t17_line '^uv tool install ')"
problems=""
done_ok $rc "$out" || problems+="[rc=$rc $(tail -n2 <<<"$out" | tr '\n' ' ')] "
[[ -n "$apt_install" && -n "$first_k" && -n "$go_install" && -n "$uv_install" ]] \
  && ((apt_install < first_k && first_k < go_install && first_k < uv_install)) \
  || problems+="[order: apt-get install=${apt_install:-none} first sudo -k=${first_k:-none} go install=${go_install:-none} uv tool install=${uv_install:-none}] "
! grep -qE '^sudo (go|uv)( |$)' "$t17_events" || problems+="[go or uv ran under sudo] "
[[ -z "$problems" ]] || problems+="events: $(tr '\n' ';' <"$t17_events")"
expect_none T17-sudo-dropped "$problems"

# T18: answering y moves a foreign config aside only after the clone succeeds. The script runs from a
# plain directory, as in T16, so setup_config reaches the prompt. On success the clone replaces the
# config and the old one sits in one backup; on a failed clone nothing moves. Neither leaves a
# staging dir. $1 = case id, $2 = git stub dir
t18_case() {
  local id="$1" git_bin="$2"
  (
    sandbox "T18-$id" "$git_bin:$REFUSE_BIN"
    git init -q -b main "$HOME/.config/nvim"
    git -C "$HOME/.config/nvim" remote add origin https://github.com/someone/else
    printf 'local work\n' >"$HOME/.config/nvim/untracked.lua"
    mkdir -p "$HOME/plain"
    cp "$SCRIPT" "$HOME/plain/nvim-install.sh"
    load_script "$HOME/plain/nvim-install.sh"
    [[ "$NVIM_CONFIG_DIR" == "$HOME/.config/nvim" && "$SCRIPT_DIR" == "$HOME/plain" ]] \
      || { echo "NVIM_CONFIG_DIR=$NVIM_CONFIG_DIR SCRIPT_DIR=$SCRIPT_DIR"; exit 1; }
    rc=0
    (setup_config <<<y) || rc=$?
    echo "setup_config rc=$rc"
    echo DONE
  ) </dev/null 2>&1
}
for id in success clone-failure; do
  if [[ "$id" == success ]]; then
    out="$(t18_case "$id" "$CLONE_GIT_BIN")"
  else
    out="$(t18_case "$id" "$GIT_BIN")"
  fi
  rc=$?
  t18_dir="$TMP/home-T18-$id/.config"
  backups="$(compgen -G "$t18_dir/nvim.bak.*" || true)"
  staging="$(compgen -G "$t18_dir/.nvim-clone.*" || true)"
  problems=""
  done_ok $rc "$out" || problems+="[rc=$rc] "
  [[ -z "$staging" ]] || problems+="[staging left: $staging] "
  if [[ "$id" == success ]]; then
    grep -qxF "setup_config rc=0" <<<"$out" || problems+="[setup_config failed] "
    [[ -f "$t18_dir/nvim/cloned" ]] || problems+="[no clone at $t18_dir/nvim] "
    [[ -n "$backups" && "$(wc -l <<<"$backups")" -eq 1 && -f "$backups/untracked.lua" ]] \
      || problems+="[want one backup holding untracked.lua, got: $(tr '\n' ' ' <<<"$backups")] "
  else
    grep -qxF "setup_config rc=1" <<<"$out" || problems+="[setup_config did not exit 1] "
    grep -qF "was not changed" <<<"$out" || problems+="[no 'was not changed' message] "
    [[ -f "$t18_dir/nvim/untracked.lua" ]] || problems+="[untracked.lua moved] "
    [[ "$(git -C "$t18_dir/nvim" remote get-url origin 2>/dev/null)" == https://github.com/someone/else ]] \
      || problems+="[foreign origin gone] "
    [[ -z "$backups" ]] || problems+="[backup made: $(tr '\n' ' ' <<<"$backups")] "
  fi
  [[ -z "$problems" ]] || problems+="; $(tail -n4 <<<"$out" | tr '\n' ' ')"
  expect_none "T18-config-move-yes $id" "$problems"
done

# T19: go_bin_dir prints GOBIN, else the first GOPATH entry's bin dir, and fails when both are empty
# or go env fails. go is a stub answering go env from T19_* variables.
T19_BIN="$TMP/bin-T19"
mkdir -p "$T19_BIN"
cat >"$T19_BIN/go" <<'EOF'
#!/bin/sh
if [ -n "${T19_GO_FAILS:-}" ] || [ "$1" != env ]; then
  echo "STUB GO: failing $*" >&2
  exit 1
fi
case "$2" in
  GOBIN) printf '%s\n' "${T19_GOBIN:-}" ;;
  GOPATH) printf '%s\n' "${T19_GOPATH:-}" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$T19_BIN/go"
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

# T20: the system servers in lua/plugins/lsp.lua (first string of each system_servers entry), the
# installer, and the README agree: (a) the best-effort warn_manual list names the same binaries,
# (b) the pacman list has one package per server, (c) the README's pacman command under Requirements
# installs every package of that list, and (d) on an Arch host with all of them installed, they ship
# /usr/bin/<binary> for every server (pacman -Qlq, read-only)
mapfile -t lsp_bins < <(sed -n '/local system_servers = {/,/^[[:space:]]*}/p' "$ROOT/lua/plugins/lsp.lua" \
  | sed -n 's/^[^"]*"\([^"]*\)".*/\1/p' | sort)
# install_language_servers with its continuation lines joined
ls_fn="$(awk '/^install_language_servers\(\) \{/, /^\}/ { if (sub(/\\$/, "")) printf "%s", $0; else print }' "$SCRIPT")"
# Prints the words after $1 at the start of a line of ls_fn, one per line
t20_args() { sed -n "s/^[[:space:]]*$1[[:space:]]//p" <<<"$ls_fn" | tr -s '[:space:]' '\n' | sed '/^$/d'; }
mapfile -t manual_bins < <(t20_args 'warn_manual' | sort)
mapfile -t pacman_pkgs < <(t20_args 'install_pkgs optional "language servers"')
readme_cmd="$(sed -n '/^## Requirements/,/^## Installation/p' "$ROOT/README.md" \
  | awk '/^sudo pacman -S --needed/ { on = 1 } on { cont = sub(/\\$/, ""); printf "%s ", $0; if (!cont) exit }' \
  | tr -s '[:space:]' '\n')"
problems=""
[[ ${#lsp_bins[@]} -gt 0 ]] || problems+="[no system_servers found in lua/plugins/lsp.lua] "
[[ "${manual_bins[*]}" == "${lsp_bins[*]}" ]] \
  || problems+="[(a) warn_manual: ${manual_bins[*]}; system_servers: ${lsp_bins[*]}] "
[[ ${#pacman_pkgs[@]} -eq ${#lsp_bins[@]} ]] \
  || problems+="[(b) ${#pacman_pkgs[@]} pacman packages (${pacman_pkgs[*]}) for ${#lsp_bins[@]} servers] "
[[ -n "$readme_cmd" ]] || problems+="[(c) no 'sudo pacman -S --needed' command under Requirements in README.md] "
for pkg in "${pacman_pkgs[@]}"; do
  grep -qxF -- "$pkg" <<<"$readme_cmd" || problems+="[(c) README pacman command lacks $pkg] "
done
expect_none T20-server-list-sync "$problems"
if [[ "$host_mgr" != pacman ]] || ! command -v pacman >/dev/null 2>&1; then
  echo "SKIP T20-server-list-sync (d) (not an Arch host)"
else
  t20_missing=""
  for pkg in "${pacman_pkgs[@]}"; do
    pacman -Q "$pkg" >/dev/null 2>&1 || t20_missing+="$pkg "
  done
  if [[ -n "$t20_missing" ]]; then
    echo "SKIP T20-server-list-sync (d) (not installed here: ${t20_missing% })"
  else
    t20_files="$(pacman -Qlq "${pacman_pkgs[@]}")"
    problems=""
    for bin in "${lsp_bins[@]}"; do
      grep -qxF "/usr/bin/$bin" <<<"$t20_files" || problems+="[no package ships /usr/bin/$bin] "
    done
    expect_none "T20-server-list-sync (d)" "$problems"
  fi
fi

echo "exit=$fail"
exit "$fail"
