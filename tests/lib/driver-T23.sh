#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# T23's driver: runs main with every step stubbed but install_deps, which takes a sudo ticket and then
# runs a required install that fails
# shellcheck source=driver-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/driver-lib.sh" "$1"
must_override install_deps
must_override pkg_is_installed
pkg_is_installed() { return 1; }
install_deps() {
  log_step install_deps
  set_pkg_manager apt-get
  ensure_sudo_ticket
  install_pkgs required "build tools" pkg
  echo "NOT REACHED"
}
run_main_stubbed install_deps
