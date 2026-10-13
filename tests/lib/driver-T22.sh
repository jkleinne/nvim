#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# T22's driver: runs main with every step stubbed; install_deps takes a sudo ticket when T22_TICKET is 1
# shellcheck source=driver-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/driver-lib.sh" "$1"
must_override install_deps
install_deps() {
  log_step install_deps
  if [[ "${T22_TICKET:?}" == 1 ]]; then
    ensure_sudo_ticket
  fi
}
run_main_stubbed install_deps
