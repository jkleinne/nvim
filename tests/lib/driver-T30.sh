#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# T30's driver: runs main with install_neovim hooked, for case $T30_CASE. int: it takes a sudo ticket,
# and the recording sudo sends INT to this shell right after sudo -v (SUDO_INT_ON), standing in for an
# interrupt that lands while sudo -v caches the ticket. order: it creates the temp dir with a file
# "marker" in it, which the recording sudo checks on each call (SUDO_MARKER), takes a ticket, and fails,
# so cleanup has both a ticket to drop and a scratch dir to remove.
# shellcheck source=driver-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/driver-lib.sh" "$1"
must_override install_neovim
install_neovim() {
  log_step install_neovim
  case "${T30_CASE:?}" in
    int)
      ensure_sudo_ticket
      echo RESUMED
      ;;
    order)
      create_tmpdir
      SUDO_MARKER="$SCRIPT_TMPDIR/marker"
      export SUDO_MARKER
      : >"$SUDO_MARKER"
      echo "TMPDIR_CREATED $SCRIPT_TMPDIR"
      ensure_sudo_ticket
      exit 1
      ;;
  esac
}
run_main_stubbed install_neovim
