#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# T9's driver: runs main with install_neovim hooked: it takes a sudo ticket, creates the temp dir and a
# clone staging dir, and sends $T9_SIG to the shell, standing in for work in progress when the signal
# arrives
# shellcheck source=driver-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/driver-lib.sh" "$1"
if [[ -n "$(trap -p EXIT INT TERM)" ]]; then
  echo "sourcing set traps: $(trap -p EXIT INT TERM)"
  exit 1
fi
must_override install_neovim
install_neovim() {
  ensure_sudo_ticket
  create_tmpdir
  CLONE_STAGING="$(mktemp -d)"
  echo "TMPDIR_CREATED $SCRIPT_TMPDIR"
  echo "STAGING_CREATED $CLONE_STAGING"
  kill -s "${T9_SIG:?}" "$BASHPID"
  echo RESUMED
}
run_main_stubbed install_neovim
