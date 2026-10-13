# shellcheck shell=bash
# Helpers that tests/install-script.test.sh and tests/lib/driver-lib.sh share. Paths of a test's files
# sit under the suite's temp dir, which the suite exports as SUITE_TMP.

# Fails the caller (exits its shell) when the sourced script has no function $1, so a renamed function
# cannot slip past the stub meant to replace it and run for real
must_override() {
  if ! declare -F "$1" >/dev/null; then
    echo "nvim-install.sh has no function $1 to override"
    exit 1
  fi
}

# Fails the caller (exits its shell) unless HOME is a sandbox home under $1 (the suite's temp dir), so
# NVIM_CONFIG_DIR can never be real; $2 names the caller in the message
require_sandbox_home() {
  if [[ $HOME != "${1:?}"/home-* ]]; then
    echo "$2: HOME is $HOME, not a sandbox home under $1; not running the script"
    exit 1
  fi
}

# The fake HOME, the recording sudo's log, and the event log of test $1
sandbox_home() { printf '%s\n' "${SUITE_TMP:?}/home-$1"; }
sudo_log() { printf '%s\n' "${SUITE_TMP:?}/$1-sudo.log"; }
event_log() { printf '%s\n' "${SUITE_TMP:?}/$1-events.log"; }
