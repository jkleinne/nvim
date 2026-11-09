#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# T22's driver: runs main with install_neovim taking a sudo ticket when T22_TICKET is 1 (so its root
# commands must come before the forget), install_deps logging its name, and the steps T22_RUN_AS_IS
# names logging their names and then running as they are, so a root command in them reaches the
# recording sudo; every other step is stubbed. main gets the words of T22_ARGS as its arguments (empty
# by default; T22e passes --packages-only).
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
# The steps that log their names and then run as they are. Both calls below take this one list: a step
# that log_then_run wraps but run_main_stubbed was not given would be stubbed over, and stop running
T22_RUN_AS_IS=(put_install_dir_first_on_path setup_path verify_nvim verify_config print_summary)
log_then_run "${T22_RUN_AS_IS[@]}"
read -ra DRIVER_MAIN_ARGS <<<"${T22_ARGS:-}"
run_main_stubbed install_neovim install_deps "${T22_RUN_AS_IS[@]}"
