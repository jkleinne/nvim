#!/usr/bin/env bash
# Tests for nvim-install.sh: bash tests/install-script.test.sh
#
# Hermetic by default: every stub, fake HOME, and scratch file lives under one temp dir that is removed
# on exit. Sourced tests and direct script runs start with sandbox: a fake HOME, then hermetic_env, so
# inherited GIT_*, ZDOTDIR, and XDG_* variables are dropped and git ignores the system and global
# config, refuses every protocol but file (no clone reaches the network, however git is invoked), and
# never looks above $TMP for a repository. DENY_BIN, which sandbox puts on PATH, refuses sudo, curl,
# wget, go, and uv and logs each call to $TMP/refused.log; a test that needs one puts its stub ahead (a
# recording sudo that never runs its arguments, go and uv stubs that only log), and T21 fails when any
# test reached a refusing stub. So no test can install, upgrade, or download anything, and load_script
# sources the script only under a fake HOME, so NVIM_CONFIG_DIR never points at a real config.
# RUN_FULL=1 adds T4, an end-to-end run on this machine (see T4), which also reads the real
# ~/.config/nvim. The only real package manager queries are read-only: pacman -Q (T4's run and
# T20 (d)), pacman -Qlq (T20 (d)), and pacman -Si (T20 (b0)). REQUIRE_ALL=1 turns T3's skip (no way to
# fake root here) into a failure.
# shellcheck source-path=SCRIPTDIR/..
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/nvim-install.sh"
# Signal dispositions this suite inherited (one ignored at entry shows as trap -- '' SIGINT); see T9
INHERITED_TRAPS="$(trap -p INT TERM)"
TMP="$(mktemp -d)" || exit 1
trap 'rm -rf -- "${TMP:?}"' EXIT
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

# Drops the variables that point git or the shell at real config or repos, and makes git ignore the
# system and global config, refuse every protocol but file, and never look above $TMP for a repo
hermetic_env() {
  unset "${!GIT_@}" ZDOTDIR XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_ALLOW_PROTOCOL=file GIT_CEILING_DIRECTORIES="$TMP"
}

# Call first in each test's subshell, sourced or running the script: a fresh fake HOME, hermetic_env,
# and PATH with the given stub dirs ($2, colon-separated, may be empty) first, then DENY_BIN
sandbox() {
  hermetic_env
  HOME="$TMP/home-$1"
  export HOME
  mkdir -p "$HOME"
  PATH="${2:+$2:}$DENY_BIN:$PATH"
}

# Source the script under test (default $SCRIPT) into the calling subshell; sourcing never runs main.
# Fails the test instead when HOME is not a sandbox home, so NVIM_CONFIG_DIR can never be real.
load_script() {
  if [[ $HOME != "$TMP"/home-* ]]; then
    echo "load_script: HOME is $HOME, not a sandbox home under $TMP; not sourcing the script"
    exit 1
  fi
  # shellcheck source=nvim-install.sh
  source "${1:-$SCRIPT}"
  setup_colors
}

# Fails the calling test when the sourced script has no function $1, so a renamed function cannot
# slip past the stub meant to replace it and run for real
must_override() {
  if ! declare -F "$1" >/dev/null; then
    echo "nvim-install.sh has no function $1 to override"
    exit 1
  fi
}

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

# ---------------------------------------------------------------------------
# Stubs and fixtures
# ---------------------------------------------------------------------------

# Commands no test may run for real: each stub logs "<name> <args>" to $TMP/refused.log (T21 fails
# when that log exists) and exits 1
DENY_BIN="$TMP/bin-deny"
mkdir -p "$DENY_BIN"
for cmd in sudo curl wget go uv; do
  cat >"$DENY_BIN/$cmd" <<EOF
#!/bin/sh
printf '%s %s\n' "$cmd" "\$*" >>"$TMP/refused.log"
echo "STUB $cmd BLOCKED: \$*" >&2
exit 1
EOF
  chmod +x "$DENY_BIN/$cmd"
done

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

# git whose clone, offline, logs its arguments one per line to $CLONE_LOG (when set) and creates the
# target (last argument) as a repo with this repo's origin and a marker file "cloned"; everything
# else goes to the real git
CLONE_GIT_BIN="$TMP/bin-git-clone"
mkdir -p "$CLONE_GIT_BIN"
cat >"$CLONE_GIT_BIN/git" <<EOF
#!/bin/sh
if [ "\$1" = clone ]; then
  if [ -n "\${CLONE_LOG:-}" ]; then
    printf '%s\n' "\$@" >>"\$CLONE_LOG"
  fi
  for dest; do :; done
  mkdir -p "\$dest" && : >"\$dest/cloned" && "$REAL_GIT" init -q -b main "\$dest" \\
    && "$REAL_GIT" -C "\$dest" remote add origin "$REPO_URL_HTTPS"
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

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

# T1: syntax, and shellcheck on the script and on this file (following its source of the script)
if ! bash -n "$SCRIPT"; then
  result T1-static 1 "bash -n"
elif ! command -v shellcheck >/dev/null 2>&1; then
  echo "SKIP T1-static (shellcheck not installed; bash -n passed)"
else
  shellcheck "$SCRIPT" && shellcheck -x "${BASH_SOURCE[0]}"
  result T1-static $?
fi

# T2: the plan screen names the platform and, on pacman, the upfront system upgrade;
# "n" and end of input both cancel cleanly
host_mgr="$( (
  sandbox T2-detect ""
  load_script
  detect_pkg_manager
  printf '%s\n' "$PKG_MGR"
) </dev/null 2>/dev/null)"
if [[ "$host_mgr" != pacman ]]; then
  echo "SKIP T2-plan-screen (the script detects '${host_mgr:-nothing}' here, not pacman)"
else
  out="$( (
    sandbox T2 ""
    printf 'n\n' | "$SCRIPT"
  ) 2>&1)"
  rc=$?
  eof_out="$( (
    sandbox T2-eof ""
    "$SCRIPT"
  ) </dev/null 2>&1)"
  eof_rc=$?
  absent=""
  for want in 'OS: +linux' 'Architecture: +(x86_64|arm64)' 'Package manager: +pacman' 'Support tier: +first-class' \
    '0\. Upgrade the system first \(pacman -Syu' '1\. Install Neovim 0\.12\+' 'Cancelled\.'; do
    grep -qE "$want" <<<"$out" || absent+="[$want] "
  done
  [[ $rc -eq 0 && -z "$absent" && $eof_rc -eq 0 ]] && grep -qF 'Cancelled.' <<<"$eof_out" \
    && ! grep -qE 'STUB .* BLOCKED' <<<"$out$eof_out"
  result T2-plan-screen $? "rc=$rc eof_rc=$eof_rc absent=$absent; EOF run: $(tail -n2 <<<"$eof_out" | tr '\n' ' ')"
fi

# T3: root guard, under every wrapper that reports EUID 0 here: fakeroot, and unshare -r when this
# kernel lets an unprivileged user map itself to root in a user namespace. With REQUIRE_ALL=1, having
# neither fails instead of skipping.
t3_wrappers=()
if command -v fakeroot >/dev/null 2>&1; then
  t3_wrappers+=(fakeroot)
fi
if command -v unshare >/dev/null 2>&1 && unshare -r true >/dev/null 2>&1; then
  t3_wrappers+=("unshare -r")
fi
if [[ ${#t3_wrappers[@]} -gt 0 ]]; then
  t3_fail=""
  for wrapper in "${t3_wrappers[@]}"; do
    read -ra wrapper_cmd <<<"$wrapper"
    out="$( (
      sandbox T3 ""
      "${wrapper_cmd[@]}" "$SCRIPT"
    ) </dev/null 2>&1)"
    rc=$?
    [[ $rc -eq 1 ]] && grep -qF "Do not run this script as root" <<<"$out" \
      || t3_fail+="[$wrapper: rc=$rc $(tail -n2 <<<"$out" | tr '\n' ' ')] "
  done
  t3_ran="$(printf '%s, ' "${t3_wrappers[@]}")"
  expect_none "T3-root-guard (${t3_ran%, })" "$t3_fail"
elif [[ "${REQUIRE_ALL:-0}" == 1 ]]; then
  result T3-root-guard 1 "neither fakeroot nor unshare -r works here, and REQUIRE_ALL=1 forbids skipping"
else
  echo "SKIP T3-root-guard (neither fakeroot nor unshare -r works here)"
fi

# T4 (RUN_FULL=1, Arch only): runs the real script end to end on this machine. On a fully provisioned
# machine nothing is installed: sudo is a stub that allows only "sudo -k" (forget_sudo_credentials,
# which never prompts) and refuses and logs everything else, so any install, or the upfront upgrade,
# fails the test. HOME stays real, because the run must find the real checkout, so T4 runs only when
# ~/.config/nvim is a clone of this repo (setup_config then leaves it in place). The verification
# launch needs network: lazy.nvim bootstraps itself and installs every plugin, running their build
# steps, into scratch XDG dirs whose config is a copy of this checkout, so the real checkout, its
# plugins, and lazy-lock.json are never written. That is why T4 skips hermetic_env: it keeps the real
# PATH and git config, and the suite never sets GIT_ALLOW_PROTOCOL for it, since lazy.nvim clones over
# https (a value the caller set, to fence a run offline, passes through). It drops only the other
# inherited GIT_* variables (a hook's GIT_DIR, for example) and ZDOTDIR.
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
    unset ZDOTDIR
  }
  live_config="$HOME/.config/nvim"
  t4_git() { (
    t4_env
    GIT_OPTIONAL_LOCKS=0 git -C "$live_config" "$@"
  ); }
  live_remote="$(t4_git remote get-url origin 2>/dev/null || true)"
  if ! (
    sandbox T4-guard ""
    load_script
    is_config_repo_url "$live_remote"
  ) </dev/null >/dev/null 2>&1; then
    result T4-idempotent-run 1 "origin of $live_config is '$live_remote', not this repo; refusing a full run"
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

# T5: no invocation of a language package manager or an AUR helper, and no AUR URL; the only match is
# the hadolint warn line, which names an AUR helper as a manual step
matches="$(grep -nE '\b(npm|npx|pnpm|yarn|bun|corepack|pip[0-9.]*|pipx|easy_install|yay|paru|pikaur|trizen|aura|makepkg)\b|aur\.archlinux\.org' "$SCRIPT")"
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
  PKG_MGR=pacman
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
    PKG_MGR="" PKG_TIER=""
    PATH="$PKG_BIN" detect_pkg_manager
    [[ "$PKG_MGR $PKG_TIER" == "${tc#*:}" ]] \
      || { echo "os-release '$OSR_MGR': want '${tc#*:}', got '$PKG_MGR $PKG_TIER'"; exit 1; }
  done
  echo DONE
) </dev/null 2>&1)"
done_ok $? "$out" && ! grep -nE 'OS_RELEASE_FILE|NVIM_INSTALL_OS_RELEASE' "$SCRIPT"
result T8-detection $? "$(tail -n3 <<<"$out")"

# T9: sourcing sets no traps; main sets them, and INT or TERM then runs the EXIT cleanup (removing the
# temp dir and the clone staging dir) and kills the script with the same signal instead of resuming,
# so a calling shell or loop sees the interrupt. A driver runs main as its own process with a real
# signal. python3 starts it with INT and TERM reset to their defaults (a shell started with a signal
# ignored, as a background job of a script is, can neither trap nor reset it, and lists it as a trap)
# and reports how it ended (death by signal N is return code -N; exit 130 or 143 would look like an
# ordinary failure), so this checks the behavior (no resume, scratch dirs removed, signal death), not
# just the trap text. Without python3 the driver inherits this suite's dispositions, so T9 is skipped
# when the suite started with INT or TERM ignored or trapped.
cat >"$TMP/T9-driver.sh" <<'EOF'
# Sources the script under test ($1) and runs main; its first step creates the temp dir and a clone
# staging dir and sends $T9_SIG to the shell, standing in for work in progress when the signal arrives
source "$1"
if [[ -n "$(trap -p EXIT INT TERM)" ]]; then
  echo "sourcing set traps: $(trap -p EXIT INT TERM)"
  exit 1
fi
if ! declare -F require_non_root >/dev/null; then
  echo "nvim-install.sh has no function require_non_root to override"
  exit 1
fi
require_non_root() {
  create_tmpdir
  CLONE_STAGING="$(mktemp -d)"
  echo "TMPDIR_CREATED $SCRIPT_TMPDIR"
  echo "STAGING_CREATED $CLONE_STAGING"
  kill -s "$T9_SIG" "$BASHPID"
  echo RESUMED
}
main
EOF
t9_launcher='import signal, subprocess, sys
def default_signals():
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    signal.signal(signal.SIGTERM, signal.SIG_DFL)
r = subprocess.run(sys.argv[1:], stdin=subprocess.DEVNULL, preexec_fn=default_signals)
sys.stdout.write("rc=%d\n" % r.returncode)'
t9_signal() {
  local sig="$1"
  (
    sandbox "T9-$sig" ""
    TMPDIR="$TMP/T9-$sig-tmp" T9_SIG="$sig"
    export TMPDIR T9_SIG
    mkdir -p "$TMPDIR"
    if command -v python3 >/dev/null 2>&1; then
      python3 -I -c "$t9_launcher" bash "$TMP/T9-driver.sh" "$SCRIPT"
    else
      bash "$TMP/T9-driver.sh" "$SCRIPT"
      echo "rc=$?"
    fi
  ) </dev/null 2>&1
}
t9_cases=() t9_note=""
if command -v python3 >/dev/null 2>&1; then
  t9_cases=(INT:-2 TERM:-15)
elif [[ -z "$INHERITED_TRAPS" ]]; then
  t9_cases=(INT:130 TERM:143) t9_note=" (signal death not checked: python3 missing)"
fi
if [[ ${#t9_cases[@]} -eq 0 ]]; then
  echo "SKIP T9-signal-traps (python3 missing, and this suite inherited signal dispositions: $INHERITED_TRAPS)"
else
  t9_fail=""
  for tc in "${t9_cases[@]}"; do
    out="$(t9_signal "${tc%%:*}")"
    got="$(sed -n 's/^rc=//p' <<<"$out" | tail -n1)"
    created="$(sed -n 's/^TMPDIR_CREATED //p' <<<"$out")"
    staging="$(sed -n 's/^STAGING_CREATED //p' <<<"$out")"
    [[ "$got" == "${tc#*:}" && -n "$created" && ! -e "$created" && -n "$staging" && ! -e "$staging" ]] \
      && ! grep -qxF RESUMED <<<"$out" \
      || t9_fail+="[${tc%%:*}: rc=${got:-none} created='$created' staging='$staging' $(tail -n2 <<<"$out" | tr '\n' ' ')] "
  done
  expect_none "T9-signal-traps$t9_note" "$t9_fail"
fi

# T10: is_config_repo_url accepts this repo's HTTPS URL (with or without .git, with a trailing slash),
# SCP-style SSH, and ssh:// forms, and nothing else (the URL spellings stay literal on purpose)
out="$( (
  sandbox T10-urls ""
  load_script
  for url in https://github.com/jkleinne/nvim https://github.com/jkleinne/nvim.git \
    https://github.com/jkleinne/nvim/ https://github.com/jkleinne/nvim.git/ \
    git@github.com:jkleinne/nvim git@github.com:jkleinne/nvim.git \
    ssh://git@github.com/jkleinne/nvim ssh://git@github.com/jkleinne/nvim.git; do
    is_config_repo_url "$url" || echo "BAD rejected '$url'"
  done
  for url in https://github.com/jkleinne/nvim-fork https://github.com/someone/nvim \
    http://github.com/jkleinne/nvim.git git@github.com:jkleinne/nvim/extra ""; do
    ! is_config_repo_url "$url" || echo "BAD accepted '$url'"
  done
  echo DONE
) </dev/null 2>&1)"
done_ok $? "$out" && ! grep -q '^BAD' <<<"$out"
result T10-repo-url-forms $? "$(grep '^BAD' <<<"$out" | tr '\n' ' ')$(tail -n1 <<<"$out")"

# An SSH origin counts as this repo, so setup_config leaves the checkout in place
out="$( (
  sandbox T10 "$GIT_BIN"
  git init -q -b main "$HOME/.config/nvim"
  git -C "$HOME/.config/nvim" remote add origin git@github.com:jkleinne/nvim.git
  printf 'local work\n' >"$HOME/.config/nvim/untracked.lua"
  load_script
  [[ $NVIM_CONFIG_DIR == "$TMP"/* ]] || { echo "NVIM_CONFIG_DIR=$NVIM_CONFIG_DIR"; exit 1; }
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
  sandbox T11 "$GIT_BIN"
  foreign_config_fixture "$HOME/.config/nvim"
  git init -q -b main "$HOME/src/nvim"
  git -C "$HOME/src/nvim" remote add origin "$REPO_URL_HTTPS"
  cp "$SCRIPT" "$HOME/src/nvim/nvim-install.sh"
  load_script "$HOME/src/nvim/nvim-install.sh"
  [[ $NVIM_CONFIG_DIR == "$TMP"/* && "$SCRIPT_DIR" == "$HOME/src/nvim" ]] \
    || { echo "NVIM_CONFIG_DIR=$NVIM_CONFIG_DIR SCRIPT_DIR=$SCRIPT_DIR"; exit 1; }
  printf 'y\n' | setup_config
  echo DONE
) </dev/null 2>&1)"
rc=$?
t11_config="$TMP/home-T11/.config/nvim"
backups="$(compgen -G "$t11_config.bak.*" || true)"
problems="$(foreign_config_intact "$t11_config")"
done_ok $rc "$out" && grep -qF "Skipping automatic config setup" <<<"$out" && [[ -z "$problems" && -z "$backups" ]]
result T11-no-move-from-foreign-clone $? "rc=$rc backups=[$backups] $problems; $(tail -n4 <<<"$out" | tr '\n' ' ')"

# T12: the first real install checks sudo once and runs pacman -Syu once, before any pacman -S;
# installing Neovim goes through the same path, apt-get refreshes once (also across a whole
# install_deps), nothing missing means no sudo, and a missing sudo binary stops the first install.
# $1 = case id, $2 = package manager, $3 = steps: pkgs, neovim, or deps with every package missing,
# or installed-pkgs (pkgs with every package already installed)
t12_case() {
  (
    sandbox "T12-$1" "$RECORD_BIN"
    SUDO_LOG="$TMP/T12-$1-sudo.log"
    export SUDO_LOG
    : >"$SUDO_LOG"
    load_script
    PKG_MGR="$2"
    must_override pkg_is_installed
    if [[ "$3" == installed-pkgs ]]; then
      pkg_is_installed() { return 0; }
    else
      pkg_is_installed() { return 1; }
    fi
    # No-ops, so no go install or uv tool install can run; package installs only reach the stub
    must_override install_python_tool
    must_override install_go_tool
    install_python_tool() { :; }
    install_go_tool() { :; }
    case "$3" in
      pkgs | installed-pkgs) install_pkgs optional "group one" a b && install_pkgs optional "group two" c ;;
      neovim) pkg_install neovim && install_pkgs optional "group" d ;;
      deps) install_deps ;;
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
for tc in "pacman-pkgs:pacman:pkgs:pacman -Syu:pacman -S --noconfirm" \
  "pacman-neovim:pacman:neovim:pacman -Syu:pacman -S --noconfirm neovim" \
  "apt-neovim:apt-get:neovim:apt-get update -qq:apt-get install -y neovim" \
  "apt-deps:apt-get:deps:apt-get update -qq:apt-get install -y"; do
  IFS=: read -r id mgr steps refresh install <<<"$tc"
  out="$(t12_case "$id" "$mgr" "$steps")"
  rc=$?
  log="$TMP/T12-$id-sudo.log"
  problems="$(t12_check_log "$log" "$refresh" "$install" | tr '\n' ' ')"
  done_ok $rc "$out" && [[ -z "$problems" ]] \
    || t12_fail+="[$id: rc=$rc $problems log: $(tr '\n' ';' <"$log")] "
done
out="$(t12_case all-installed pacman installed-pkgs)"
rc=$?
done_ok $rc "$out" && [[ ! -s "$TMP/T12-all-installed-sudo.log" ]] \
  || t12_fail+="[all-installed: rc=$rc sudo log: $(tr '\n' ';' <"$TMP/T12-all-installed-sudo.log")] "
# No sudo binary: the first install stops with a clear error. PATH is an empty dir; the guard,
# require_sudo, and error use only builtins.
mkdir -p "$TMP/empty-bin"
out="$( (
  sandbox T12-no-sudo ""
  load_script
  PKG_MGR=pacman
  PATH="$TMP/empty-bin" run_errexit pkg_ready_once
  echo "inner rc=$RC"
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
  must_override pkg_is_installed
  # shellcheck disable=SC2329  # install_pkgs calls it, through run_errexit
  pkg_is_installed() { return 1; }
  run_errexit install_pkgs optional grp pkg
  echo "inner rc=$RC"
  echo DONE
) </dev/null 2>&1)"
rc=$?
done_ok $rc "$out" && grep -qxF "inner rc=1" <<<"$out" && grep -qF "partial upgrade" <<<"$out" \
  && ! grep -qF -- "-S --noconfirm" "$TMP/T13-sudo.log"
result T13-upgrade-declined $? "rc=$rc; sudo log: $(tr '\n' ';' <"$TMP/T13-sudo.log" 2>/dev/null); $(tail -n4 <<<"$out" | tr '\n' ' ')"

# T13b: a failed apt-get update or apk update is best effort: it warns (the warning reaches the
# summary) and the install still runs, from the existing package lists or index
for tc in "apt-get:apt-get update -qq:apt-get install -y pkg:apt-get update failed" \
  "apk:apk update:apk add pkg:apk update failed"; do
  IFS=: read -r mgr refresh install warning <<<"$tc"
  log="$TMP/T13b-$mgr-sudo.log"
  out="$( (
    sandbox "T13b-$mgr" "$RECORD_BIN"
    SUDO_LOG="$log" SUDO_FAIL_ON="$refresh"
    export SUDO_LOG SUDO_FAIL_ON
    : >"$SUDO_LOG"
    load_script
    PKG_MGR="$mgr"
    must_override pkg_is_installed
    pkg_is_installed() { return 1; }
    # A plain statement, so it runs under the errexit sourcing turned on, and WARNINGS stays readable
    install_pkgs optional grp pkg >/dev/null
    [[ "${WARNINGS[*]}" == *"$warning"* ]] || { echo "WARNINGS: ${WARNINGS[*]}"; exit 1; }
    echo DONE
  ) </dev/null 2>&1)"
  rc=$?
  t13b_update="$(grep -nxF -- "$refresh" "$log" | head -n1 | cut -d: -f1)"
  t13b_install="$(grep -nxF -- "$install" "$log" | head -n1 | cut -d: -f1)"
  done_ok $rc "$out" && [[ -n "$t13b_update" && -n "$t13b_install" ]] && ((t13b_update < t13b_install))
  result "T13b-refresh-warns $mgr" $? "rc=$rc; sudo log: $(tr '\n' ';' <"$log" 2>/dev/null); $(tail -n2 <<<"$out" | tr '\n' ' ')"
done

# T13c: a failed sudo -v (wrong password, or no sudo rights) stops the run before any package command
out="$( (
  sandbox T13c "$RECORD_BIN"
  SUDO_LOG="$TMP/T13c-sudo.log" SUDO_FAIL_ON="-v"
  export SUDO_LOG SUDO_FAIL_ON
  : >"$SUDO_LOG"
  load_script
  PKG_MGR=pacman
  must_override pkg_is_installed
  # shellcheck disable=SC2329  # install_pkgs calls it, through run_errexit
  pkg_is_installed() { return 1; }
  run_errexit install_pkgs optional grp pkg
  echo "inner rc=$RC"
  echo DONE
) </dev/null 2>&1)"
rc=$?
done_ok $rc "$out" && grep -qxF "inner rc=1" <<<"$out" && grep -qF "sudo authentication failed" <<<"$out" \
  && ! grep -qF pacman "$TMP/T13c-sudo.log"
result T13c-sudo-v-fails $? "rc=$rc; sudo log: $(tr '\n' ';' <"$TMP/T13c-sudo.log" 2>/dev/null); $(tail -n3 <<<"$out" | tr '\n' ' ')"

# T14: confirm treats only y or Y as yes; end of input, an empty answer, n, and anything else are no.
# Every prompt in the script goes through it.
out="$( (
  sandbox T14 ""
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
    sandbox "T15-${tc%%:*}" ""
    load_script
    USER_SHELL="${tc%%:*}"
    warn_if_not_on_path /nonexistent/bin
    echo DONE
  ) </dev/null 2>&1)"
  done_ok $? "$out" && grep -qF -- "${tc#*:}" <<<"$out"
  result "T15-path-hint-appends ${tc%%:*}" $? "$(head -n1 <<<"$out")"
done

# setup_path (tarball installs) writes fish's appending line into config.fish, once
out="$( (
  sandbox T15-setup-path-fish ""
  load_script
  # shellcheck disable=SC2034  # setup_path, in the sourced script, reads both
  NEED_PATH_SETUP=true USER_SHELL=fish
  rc_file="$HOME/.config/fish/config.fish"
  mkdir -p "${rc_file%/*}"
  printf '# existing\n' >"$rc_file"
  for run in 1 2; do
    setup_path >/dev/null
    count="$(grep -cxF "fish_add_path --append --path /opt/nvim/bin" "$rc_file" || true)"
    [[ $count -eq 1 ]] || { echo "run $run: $count matching lines; config.fish: $(tr '\n' ';' <"$rc_file")"; exit 1; }
  done
  echo DONE
) </dev/null 2>&1)"
done_ok $? "$out"
result "T15-path-hint-appends setup-path-fish" $? "$(tail -n2 <<<"$out" | tr '\n' ' ')"

# T16: declining the config move (n, or end of input) leaves the foreign config untouched and
# returns, so the run goes on to the summary with the warning in it. The script runs from a plain
# directory, not a clone of this repo, so setup_config reaches the prompt; the git stub refuses clone.
t16_case() {
  local answer="$1"
  (
    sandbox "T16-$answer" "$GIT_BIN"
    foreign_config_fixture "$HOME/.config/nvim"
    mkdir -p "$HOME/plain"
    cp "$SCRIPT" "$HOME/plain/nvim-install.sh"
    load_script "$HOME/plain/nvim-install.sh"
    [[ $NVIM_CONFIG_DIR == "$TMP"/* && "$SCRIPT_DIR" == "$HOME/plain" ]] \
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
  problems="$(foreign_config_intact "$t16_config")"
  done_ok $rc "$out" && grep -qF "Left $t16_config in place; move it aside yourself" <<<"$out" \
    && [[ -z "$problems" && -z "$backups" ]] \
    && ! grep -qF "STUB GIT CLONE BLOCKED" <<<"$out" \
    || t16_fail+="[$answer: rc=$rc backups=[$backups] $problems $(tail -n3 <<<"$out" | tr '\n' ' ')] "
done
expect_none T16-decline-move-continues "$t16_fail"

# T17: install_deps runs every package install first, then drops the sudo ticket once, then the
# go install and uv tool install user tools, none of them under sudo. One event log records the sudo,
# go, and uv calls in order; go and uv are stubs whose installs only log, so nothing real is
# installed. During install_deps, PATH is three stub dirs and nothing else (T17_BIN: go and uv;
# RECORD_BIN: sudo; DENY_BIN: curl and wget, and refusals the others shadow), so no user tool name
# resolves and install_soft skips none of them; nothing else on that code path runs an external
# command. Run for every best-effort package manager.
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
t17_case() {
  local mgr="$1"
  (
    sandbox "T17-$mgr" "$T17_BIN:$RECORD_BIN"
    SUDO_LOG="$TMP/T17-$mgr-sudo.log" EVENT_LOG="$TMP/T17-$mgr-events.log"
    export SUDO_LOG EVENT_LOG
    : >"$EVENT_LOG"
    load_script
    PKG_MGR="$mgr" PKG_TIER=best-effort
    must_override pkg_is_installed
    pkg_is_installed() { return 1; }
    PATH="$T17_BIN:$RECORD_BIN:$DENY_BIN" install_deps >/dev/null
    echo DONE
  ) </dev/null 2>&1
}
# Prints the problems with a T17 event log ($1)
t17_check_events() {
  local log="$1" k_line after before tool
  [[ "$(grep -cxF 'sudo -v' "$log")" -eq 1 ]] || echo "[sudo -v count $(grep -cxF 'sudo -v' "$log")]"
  [[ "$(grep -cxF 'sudo -k' "$log")" -eq 1 ]] || echo "[sudo -k count $(grep -cxF 'sudo -k' "$log")]"
  k_line="$(grep -nxF 'sudo -k' "$log" | head -n1 | cut -d: -f1)"
  if [[ -n "$k_line" ]]; then
    after="$(tail -n +"$((k_line + 1))" "$log" | grep -E '^sudo ' | grep -vxF 'sudo -k')"
    [[ -z "$after" ]] || echo "[sudo after the first sudo -k: $(tr '\n' ';' <<<"$after")]"
    before="$(head -n "$k_line" "$log" | grep -E '^(go install|uv tool install) ')"
    [[ -z "$before" ]] || echo "[user tool installs before sudo -k: $(tr '\n' ';' <<<"$before")]"
  fi
  ! grep -qE '^sudo (go|uv)( |$)' "$log" || echo "[go or uv ran under sudo]"
  for tool in black yamllint ruff; do
    [[ "$(grep -cxF "uv tool install $tool" "$log")" -eq 1 ]] || echo "[want one 'uv tool install $tool']"
  done
  for tool in shfmt goimports golangci-lint lazygit lazydocker; do
    [[ "$(grep -cE "^go install [^ ]*/$tool@latest\$" "$log")" -eq 1 ]] || echo "[want one 'go install .../$tool@latest']"
  done
}
for mgr in apt-get dnf apk; do
  out="$(t17_case "$mgr")"
  rc=$?
  events="$TMP/T17-$mgr-events.log"
  problems=""
  done_ok $rc "$out" || problems+="[rc=$rc $(tail -n2 <<<"$out" | tr '\n' ' ')] "
  problems+="$(t17_check_events "$events" | tr '\n' ' ')"
  [[ -z "$problems" ]] || problems+="events: $(tr '\n' ';' <"$events")"
  expect_none "T17-sudo-dropped $mgr" "$problems"
done

# T18: answering y moves a foreign config aside only after the clone succeeds. The script runs from a
# plain directory, as in T16, so setup_config reaches the prompt, and setup_config runs under errexit,
# as in main. The clone stub logs its arguments: the URL must be the script's $NVIM_REPO. Cases:
#   success: the clone replaces the config, and the old one sits in one backup
#   fresh: no ~/.config at all; the clone lands without a prompt or a backup
#   clone-failure: nothing moves
#   backup-move-fails, final-move-fails: the run stops with the foreign config in place and no backup
#   restore-fails: the clone's move and the move back both fail; the run stops and names the backup,
#     which holds the foreign config
# No case leaves anything in ~/.config but nvim and at most one nvim.bak.* (no staging dir).
# $1 = case id, $2 = git stub dir, $3 = the moves to fail, space-separated (backup: the config's move
# aside; final: the clone's move into place; restore: the backup's move back)
t18_case() {
  local id="$1" git_bin="$2" fail_mv="${3:-}"
  (
    sandbox "T18-$id" "$git_bin"
    CLONE_LOG="$TMP/T18-$id-clone.log"
    export CLONE_LOG
    if [[ "$id" != fresh ]]; then
      foreign_config_fixture "$HOME/.config/nvim"
    fi
    mkdir -p "$HOME/plain"
    cp "$SCRIPT" "$HOME/plain/nvim-install.sh"
    load_script "$HOME/plain/nvim-install.sh"
    [[ $NVIM_CONFIG_DIR == "$TMP"/* && "$SCRIPT_DIR" == "$HOME/plain" ]] \
      || { echo "NVIM_CONFIG_DIR=$NVIM_CONFIG_DIR SCRIPT_DIR=$SCRIPT_DIR"; exit 1; }
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
for id in success fresh clone-failure backup-move-fails final-move-fails restore-fails; do
  case "$id" in
    success | fresh) out="$(t18_case "$id" "$CLONE_GIT_BIN")" ;;
    clone-failure) out="$(t18_case "$id" "$GIT_BIN")" ;;
    backup-move-fails) out="$(t18_case "$id" "$CLONE_GIT_BIN" backup)" ;;
    final-move-fails) out="$(t18_case "$id" "$CLONE_GIT_BIN" final)" ;;
    restore-fails) out="$(t18_case "$id" "$CLONE_GIT_BIN" "final restore")" ;;
  esac
  rc=$?
  t18_dir="$TMP/home-T18-$id/.config"
  backups="$(compgen -G "$t18_dir/nvim.bak.*" || true)"
  others="$(find "$t18_dir" -mindepth 1 -maxdepth 1 ! -name nvim ! -name 'nvim.bak.*' 2>/dev/null)"
  problems=""
  done_ok $rc "$out" || problems+="[rc=$rc] "
  [[ -z "$others" ]] || problems+="[left in $t18_dir: $(tr '\n' ' ' <<<"$others")] "
  [[ -z "$backups" || "$(wc -l <<<"$backups")" -eq 1 ]] || problems+="[several backups: $(tr '\n' ' ' <<<"$backups")] "
  if [[ "$id" != clone-failure ]]; then
    want_url="$(sed -n 's/^NVIM_REPO=//p' <<<"$out")"
    clone_argv=()
    if [[ -f "$TMP/T18-$id-clone.log" ]]; then
      mapfile -t clone_argv <"$TMP/T18-$id-clone.log"
    fi
    [[ -n "$want_url" && ${#clone_argv[@]} -eq 3 && "${clone_argv[1]}" == "$want_url" ]] \
      || problems+="[clone arguments '${clone_argv[*]}', want 'clone $want_url <dir>'] "
  fi
  case "$id" in
    success | fresh)
      grep -qxF "setup_config rc=0" <<<"$out" || problems+="[setup_config failed] "
      [[ -f "$t18_dir/nvim/cloned" ]] || problems+="[no clone at $t18_dir/nvim] "
      ;;
    *)
      grep -qxF "setup_config rc=1" <<<"$out" || problems+="[setup_config did not exit 1] "
      ;;
  esac
  case "$id" in
    success)
      if [[ -n "$backups" ]]; then problems+="$(foreign_config_intact "$backups")"; else problems+="[no backup] "; fi
      ;;
    fresh)
      [[ -z "$backups" ]] || problems+="[backup made: $backups] "
      ;;
    restore-fails)
      if [[ -n "$backups" ]]; then
        problems+="$(foreign_config_intact "$backups")"
        grep -qF "your existing config is at $backups" <<<"$out" || problems+="[message does not name $backups] "
      else
        problems+="[no backup] "
      fi
      ;;
    *)
      case "$id" in
        clone-failure) message="was not changed" ;;
        backup-move-fails) message="Failed to back up" ;;
        final-move-fails) message="back in place" ;;
      esac
      grep -qF "$message" <<<"$out" || problems+="[no '$message' message] "
      problems+="$(foreign_config_intact "$t18_dir/nvim")"
      [[ -z "$backups" ]] || problems+="[backup made: $backups] "
      ;;
  esac
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
# installs every package of that list, and on an Arch host (b0) every package of that list exists in
# the sync databases (pacman -Si), and (d) with all of them installed, they ship /usr/bin/<binary> for
# every server (pacman -Qlq). Both pacman queries are read-only and need no root.
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
  echo "SKIP T20-server-list-sync (b0) and (d) (not an Arch host)"
else
  problems=""
  for pkg in "${pacman_pkgs[@]}"; do
    pacman -Si "$pkg" >/dev/null 2>&1 || problems+="[pacman -Si $pkg: not in the sync databases] "
  done
  expect_none "T20-server-list-sync (b0)" "$problems"
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

# T22: main forgets cached sudo credentials after install_deps and before setup_config, which clones
# the config ahead of Neovim's first launch in verify_install. A driver runs main with every step
# stubbed to log its name (install_deps also marks a sudo ticket taken by the script), while the real
# forget_sudo_credentials and cleanup run against the recording sudo, which logs to the same file.
cat >"$TMP/T22-driver.sh" <<'EOF'
# Sources the script under test ($1), stubs main's steps to log their names to $EVENT_LOG, runs main
source "$1"
for step in detect_os detect_arch detect_pkg_manager detect_shell confirm_proceed install_neovim \
  install_deps setup_config setup_path verify_install print_summary; do
  if ! declare -F "$step" >/dev/null; then
    echo "nvim-install.sh has no function $step to override"
    exit 1
  fi
done
log_step() { printf '%s\n' "$1" >>"$EVENT_LOG"; }
detect_os() { log_step detect_os; }
detect_arch() { log_step detect_arch; }
detect_pkg_manager() { log_step detect_pkg_manager; }
detect_shell() { log_step detect_shell; }
confirm_proceed() { log_step confirm_proceed; }
install_neovim() { log_step install_neovim; }
install_deps() { log_step install_deps; SUDO_USED=true; }
setup_config() { log_step setup_config; }
setup_path() { log_step setup_path; }
verify_install() { log_step verify_install; }
print_summary() { log_step print_summary; }
main
EOF
t22_events="$TMP/T22-events.log"
out="$( (
  sandbox T22 "$RECORD_BIN"
  SUDO_LOG="$TMP/T22-sudo.log" EVENT_LOG="$t22_events"
  export SUDO_LOG EVENT_LOG
  : >"$EVENT_LOG"
  bash "$TMP/T22-driver.sh" "$SCRIPT"
  echo "driver rc=$?"
) </dev/null 2>&1)"
t22_line() { grep -nxF -- "$1" "$t22_events" | head -n1 | cut -d: -f1; }
t22_deps="$(t22_line install_deps)"
t22_k="$(t22_line 'sudo -k')"
t22_config="$(t22_line setup_config)"
t22_verify="$(t22_line verify_install)"
t22_other_sudo="$(grep -E '^sudo ' "$t22_events" | grep -vxF 'sudo -k')"
problems=""
grep -qxF "driver rc=0" <<<"$out" || problems+="[$(tail -n2 <<<"$out" | tr '\n' ' ')] "
[[ -n "$t22_deps" && -n "$t22_k" && -n "$t22_config" && -n "$t22_verify" ]] \
  && ((t22_deps < t22_k && t22_k < t22_config && t22_config < t22_verify)) \
  || problems+="[order: install_deps=${t22_deps:-none} first sudo -k=${t22_k:-none} setup_config=${t22_config:-none} verify_install=${t22_verify:-none}] "
[[ -z "$t22_other_sudo" ]] || problems+="[sudo other than -k: $(tr '\n' ';' <<<"$t22_other_sudo")] "
[[ -z "$problems" ]] || problems+="events: $(tr '\n' ';' <"$t22_events")"
expect_none T22-main-order "$problems"

# T23: a run that stops on an error after pkg_ready_once took the sudo ticket (here a failed required
# install) still drops it: a driver with main's EXIT trap runs the install against the recording sudo,
# and cleanup's sudo -k is the last sudo call
cat >"$TMP/T23-driver.sh" <<'EOF'
# Sources the script under test ($1), sets main's EXIT trap, and runs a required install that fails
source "$1"
setup_colors
if ! declare -F pkg_is_installed >/dev/null; then
  echo "nvim-install.sh has no function pkg_is_installed to override"
  exit 1
fi
pkg_is_installed() { return 1; }
PKG_MGR=apt-get
trap cleanup EXIT
install_pkgs required "build tools" pkg
echo "NOT REACHED"
EOF
t23_log="$TMP/T23-sudo.log"
out="$( (
  sandbox T23 "$RECORD_BIN"
  SUDO_LOG="$t23_log" SUDO_FAIL_ON="apt-get install -y pkg"
  export SUDO_LOG SUDO_FAIL_ON
  : >"$SUDO_LOG"
  bash "$TMP/T23-driver.sh" "$SCRIPT"
  echo "driver rc=$?"
) </dev/null 2>&1)"
problems=""
grep -qxF "driver rc=1" <<<"$out" && grep -qF "Cannot continue" <<<"$out" && ! grep -qxF "NOT REACHED" <<<"$out" \
  || problems+="[$(tail -n3 <<<"$out" | tr '\n' ' ')] "
[[ "$(head -n1 "$t23_log")" == "-v" && "$(tail -n1 "$t23_log")" == "-k" && "$(grep -cxF -- -k "$t23_log")" -eq 1 ]] \
  || problems+="[want -v first and one -k, last; sudo log: $(tr '\n' ';' <"$t23_log")] "
expect_none T23-cleanup-drops-ticket "$problems"

# T21 (last): no test reached a refusing DENY_BIN stub
if [[ -e "$TMP/refused.log" ]]; then
  result T21-no-refused-calls 1 "$(tr '\n' ';' <"$TMP/refused.log")"
else
  result T21-no-refused-calls 0
fi

echo "exit=$fail"
exit "$fail"
