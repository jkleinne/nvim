#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# T17's driver: runs main with install_deps and install_user_tools as they are, for package manager
# $T17_MGR with every package missing (or every one installed when T17_PKGS is all-installed), and with
# PATH set to $T17_PATH (stub dirs only) from here on. The TypeScript check, which would read the host's
# Arch TypeScript path and run readlink, is stubbed: T24 covers it. setup_config, the config clone that
# runs after the user tools, is stubbed to log the GOTOOLCHAIN it sees: install_go_tool sets it for its
# own go calls only, so the caller's value (unset, unless T17 exports one) must come back unchanged.
# shellcheck source=driver-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/driver-lib.sh" "$1"
must_override pkg_is_installed
must_override has_system_typescript
must_override setup_config
set_pkg_manager "${T17_MGR:?}"
pkg_is_installed() { [[ "${T17_PKGS:?}" == all-installed ]]; }
has_system_typescript() { return 0; }
setup_config() { log_step "setup_config GOTOOLCHAIN=${GOTOOLCHAIN-unset}"; }
PATH="${T17_PATH:?}"
run_main_stubbed install_deps install_user_tools setup_config
