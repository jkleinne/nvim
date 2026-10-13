#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# T17's driver: runs main with install_deps and install_user_tools as they are, for package manager
# $T17_MGR with every package missing (or every one installed when T17_PKGS is all-installed), and with
# PATH set to $T17_PATH (stub dirs only) from here on. The TypeScript check, which would read the host's
# Arch TypeScript path and run readlink, is stubbed: T24 covers it.
# shellcheck source=driver-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/driver-lib.sh" "$1"
must_override pkg_is_installed
must_override has_system_typescript
set_pkg_manager "${T17_MGR:?}"
pkg_is_installed() { [[ "${T17_PKGS:?}" == all-installed ]]; }
has_system_typescript() { return 0; }
PATH="${T17_PATH:?}"
run_main_stubbed install_deps install_user_tools
