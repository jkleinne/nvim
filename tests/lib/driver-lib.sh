# shellcheck shell=bash
# shellcheck source-path=SCRIPTDIR/../..
# The library the main drivers in this directory share (tests/install-script.test.sh runs them). Each
# driver is a bash script, run as its own process inside a sandbox with the script under test as $1,
# that starts with
#   source "$(dirname "${BASH_SOURCE[0]}")/driver-lib.sh" "$1"
# The library sources common.sh (must_override among its helpers), refuses to run unless HOME is a
# sandbox home under SUITE_TMP (the suite's temp dir, which the suite exports), sources the script
# (which turns errexit on, as for real), refuses a script that defines a function whose name is not an
# identifier (main_steps could not see it) and a PATH on which sudo, curl, wget, go, or uv resolves
# outside SUITE_TMP (to anything but a stub), calls setup_colors, and defines log_step (appends its
# argument to $EVENT_LOG) and run_main_stubbed.

# shellcheck source=tests/lib/common.sh
source "${BASH_SOURCE[0]%/*}/common.sh"
require_sandbox_home "${SUITE_TMP:?}" driver-lib.sh
# shellcheck source=nvim-install.sh
source "$1"
if [[ $- != *e* ]]; then
  echo "errexit is off after sourcing the script; main would not run as it does for real"
  exit 1
fi
while read -r _ _ fn; do
  if [[ ! $fn =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "driver-lib.sh: the script defines function '$fn', whose name is not an identifier, so" \
      "main_steps cannot see it in main; not running main"
    exit 1
  fi
done < <(declare -F)
for cmd in sudo curl wget go uv; do
  if [[ "$(type -P "$cmd")" != "$SUITE_TMP"/* ]]; then
    echo "driver-lib.sh: $cmd resolves to '$(type -P "$cmd")', not a stub under $SUITE_TMP; not running main"
    exit 1
  fi
done
setup_colors

log_step() { printf '%s\n' "$1" >>"${EVENT_LOG:?}"; }

# What run_main_stubbed does with each function main calls. Run as they are: setup_colors (it only sets
# the output variables), forget_sudo_credentials (under test, against the recording sudo), and two
# helpers main uses itself, cleanup (its EXIT trap, under test) and info. Stubbed by a function that
# logs the step's name, unless the driver handles the step: the rest.
DRIVER_RUNS_REAL=(setup_colors forget_sudo_credentials cleanup info)
DRIVER_STUBBED=(
  usage require_non_root detect_os detect_arch detect_pkg_manager detect_shell confirm_proceed
  install_neovim install_deps install_user_tools setup_config setup_path verify_install print_summary
)

# Succeeds when $1 is one of the remaining arguments
is_one_of() {
  local want="$1" item
  shift
  for item in "$@"; do
    if [[ "$item" == "$want" ]]; then
      return 0
    fi
  done
  return 1
}

# Prints each function main calls, once, in order of first appearance: the words of main's body (as
# declare -f prints it) that name a function the script defines. Builtins only, so a driver may run
# main with any PATH.
main_steps() {
  local body word seen=" " re='[A-Za-z_][A-Za-z0-9_]*'
  body="$(declare -f main)"
  body="${body#*\{}"
  while [[ $body =~ $re ]]; do
    word="${BASH_REMATCH[0]}"
    body="${body#*"$word"}"
    if [[ "$seen" != *" $word "* ]] && declare -F "$word" >/dev/null; then
      seen+="$word "
      printf '%s\n' "$word"
    fi
  done
}

# Runs main with each of its steps stubbed, except the ones in DRIVER_RUNS_REAL and the ones the driver
# handles (its arguments: steps it overrode, or lets run as they are). The steps come from main itself,
# so a step added to main never runs for real by accident: one this library does not know stops the
# driver, and so does a handled step that main no longer calls.
run_main_stubbed() {
  local step steps=()
  mapfile -t steps < <(main_steps)
  for step in "$@"; do
    if ! is_one_of "$step" "${steps[@]}"; then
      echo "run_main_stubbed: the driver handles $step, but main does not call it"
      exit 1
    fi
  done
  for step in "${steps[@]}"; do
    if is_one_of "$step" "$@" || is_one_of "$step" "${DRIVER_RUNS_REAL[@]}"; then
      continue
    fi
    if ! is_one_of "$step" "${DRIVER_STUBBED[@]}"; then
      echo "run_main_stubbed: main calls $step, which driver-lib.sh neither stubs nor runs as it is;" \
        "add it to DRIVER_STUBBED or DRIVER_RUNS_REAL. Does it run before or after forget_sudo_credentials?" \
        "Put it in T22's chain on that side (tests/lib/driver-T22.sh and T22 in the suite)"
      exit 1
    fi
    eval "$step() { log_step $step; }"
  done
  main
}
