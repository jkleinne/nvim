#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# T22's driver: runs main with install_neovim taking a sudo ticket when T22_TICKET is 1 (so its root
# commands must come before the forget), install_deps logging its name, and setup_path, verify_install,
# and print_summary logging their names and then running as they are, so a root command in them reaches
# the recording sudo; every other step is stubbed
# shellcheck source=driver-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/driver-lib.sh" "$1"
must_override install_neovim
must_override install_deps
install_neovim() {
  log_step install_neovim
  if [[ "${T22_TICKET:?}" == 1 ]]; then
    ensure_sudo_ticket
  fi
}
install_deps() { log_step install_deps; }
# Makes each function named log its name and then run as it is (its body, copied under real_<name>)
log_then_run() {
  local fn
  for fn in "$@"; do
    must_override "$fn"
    eval "real_$(declare -f "$fn")"
    eval "$fn() { log_step $fn; real_$fn \"\$@\"; }"
  done
}
log_then_run setup_path verify_install print_summary
run_main_stubbed install_neovim install_deps setup_path verify_install print_summary
