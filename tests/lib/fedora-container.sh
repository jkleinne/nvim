#!/usr/bin/env bash
# T33's end-to-end run (RUN_FEDORA=1 in tests/install-script.test.sh): provisions a fedora:44 container
# and runs the script in it as a user with passwordless sudo, first with --packages-only and then in
# full. What it proves: the dnf package names resolve on a real Fedora 44 (neither run prints the
# "install failed, skipping" warning an optional package gets); Neovim 0.12 comes from dnf (the
# --packages-only run reports "installed via dnf", rpm knows the neovim package, and the user's nvim is
# /usr/bin/nvim, so a tarball fallback linked into /usr/local/bin fails); --packages-only stops where it
# says (it builds no Go tool and runs no config check); the full run finds every package the
# --packages-only run installed and installs none again (it prints no "Installing" step), though
# nodejs is a Provides of nodejs22 on Fedora 44; with dnf set to install weak dependencies, as a
# default host has it, the script's own --setopt=install_weak_deps=False still keeps npm out (no
# nodejs*npm* package, no npm on PATH); pylsp and bash-language-server land on PATH; the Go tools build
# into ~/go/bin (T32 owns the pins, and --version shows "unversioned"); and the full run's config check
# passes (the "Config loads cleanly" line, not verify_config's warning), which means Neovim's first
# headless launch of this checkout's config gave no error message (verify_config's v:errmsg check).
# That covers errors raised while init.lua, lazy's setup (its plugin installs and builds), and the start
# plugins run, and errors those queue with vim.schedule. It does not cover timers, the plugins lazy
# loads later, or VimEnter.
# $1 is the repository root: a directory that holds nvim-install.sh and has no ':' in its resolved path.
# podman reads a -v source that does not start with . or / as a named volume (created, and not removed
# by --rm), and a ':' would split the spec (podman-run(1)). So each refusal says what was attempted and
# exits 1 before podman runs, as does a syntax error in the script that goes into the container. The
# root is mounted read-only at /src and copied, without .git, to the test user's ~/.config/nvim, so the
# script runs from the config directory and setup_config takes its "Running from $NVIM_CONFIG_DIR, no
# clone needed" path: the checkout under test is what loads, and nothing is cloned from GitHub.
# Cost and prerequisites: rootless podman needs subuid and subgid ranges for the user (podman(1)), and
# the run needs network (dnf, the Go module proxy, and lazy.nvim's bootstrap clone when the config
# loads). The image is pulled when it is missing (the --pull default of podman run is missing) and
# stays in podman's storage until `podman rmi docker.io/library/fedora:44`. A run takes several minutes
# and a few hundred MB of downloads (dnf packages, Go modules, plugins). Ctrl-C may not stop dnf or nvim
# inside, because bash is the container's PID 1: stop a stuck run with `podman ps` and `podman stop <id>`.
# SELinux separation is off for this throwaway container (podman-run(1), "Labeling Volume Mounts"): the
# alternative, :z or :Z, would relabel the checkout. Every step prints "### <name>" first, so a failure
# (set -e inside the container) names it. Exit status: 2 for a usage error, 1 for a refused root or a
# syntax error in the container script, and otherwise podman's, which is non-zero when a step fails.
set -euo pipefail

readonly IMAGE="docker.io/library/fedora:44"

# Prints the absolute, symlink-free path of the repository root $1, or says what is wrong with it and
# fails, so nothing odd reaches podman's -v spec
resolve_root() {
  local requested="$1" resolved
  if ! resolved="$(CDPATH='' cd -- "$requested" 2>/dev/null && pwd -P)"; then
    printf 'fedora-container.sh: cannot enter the repository root "%s"\n' "$requested" >&2
    return 1
  fi
  if [[ "$resolved" == *:* ]]; then
    printf 'fedora-container.sh: the repository root "%s" has a ":" in its path, which would split the podman volume spec\n' "$resolved" >&2
    return 1
  fi
  if [[ ! -x "$resolved/nvim-install.sh" ]]; then
    printf 'fedora-container.sh: "%s" holds no executable nvim-install.sh, so it is not the repository root\n' "$resolved" >&2
    return 1
  fi
  printf '%s\n' "$resolved"
}

if [[ $# -ne 1 ]]; then
  echo "usage: fedora-container.sh <repository root>" >&2
  exit 2
fi
root="$(resolve_root "$1")"

# Runs inside the container as root
inner="$(cat <<'EOF'
set -euo pipefail
user=dev
skipped_package_pattern=': install failed, skipping'
step() { printf '\n### %s\n' "$1"; }
# Fail with the pattern that was missing (or the lines that matched), which then show in the last lines
# of the output
require_match() {
  grep -qE "$1" <<<"$2" || { printf 'expected output matching: %s\n' "$1"; exit 1; }
}
# grep exits 1 when nothing matches and 2 on its own error (a bad pattern), which is not a pass
require_no_match() {
  local matches grep_status=0
  matches="$(grep -E "$1" <<<"$2")" || grep_status=$?
  case "$grep_status" in
    0)
      printf 'unexpected output matching %s:\n%s\n' "$1" "$matches"
      exit 1
      ;;
    1) ;;
    *)
      printf 'grep failed (exit %s) on the pattern: %s\n' "$grep_status" "$1"
      exit 1
      ;;
  esac
}

step "provision: sudo, tar, and user $user with passwordless sudo"
dnf install -y sudo util-linux shadow-utils tar
useradd -m "$user"
printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$user" >"/etc/sudoers.d/$user"
chmod 0440 "/etc/sudoers.d/$user"

step "dnf installs weak dependencies, as it does on a default host"
# The fedora:44 image has this on already; stating it keeps a changed image default from hiding the
# script's option. /etc/dnf/dnf.conf loads after every drop-in directory, so this line wins.
printf '\ninstall_weak_deps=True\n' >>/etc/dnf/dnf.conf
weak_deps_setting="$(dnf --dump-main-config | grep -E '^install_weak_deps')"
printf '%s\n' "$weak_deps_setting"
require_match '^install_weak_deps = (1|True)$' "$weak_deps_setting"

step "copy the checkout (without .git) to /home/$user/.config/nvim"
mkdir -p "/home/$user/.config/nvim"
tar -C /src --exclude=.git -cf - . | tar -C "/home/$user/.config/nvim" -xf -
chown -R "$user:$user" "/home/$user/.config"

step "packages-only run"
packages_out="$(su - "$user" -c 'cd ~/.config/nvim && printf "y\n" | ./nvim-install.sh --packages-only' 2>&1 | tee /dev/stderr)"
require_match 'Neovim .* installed via dnf' "$packages_out"
require_no_match "$skipped_package_pattern" "$packages_out"
require_no_match 'Config loads cleanly|Config reported errors' "$packages_out"
for go_tool in lazygit lazydocker; do
  if [[ -e "/home/$user/go/bin/$go_tool" ]]; then
    echo "the packages-only run built $go_tool"
    exit 1
  fi
done

step "full run"
full_out="$(su - "$user" -c 'cd ~/.config/nvim && printf "y\n" | ./nvim-install.sh' 2>&1 | tee /dev/stderr)"
require_match 'Config loads cleanly' "$full_out"
require_no_match "$skipped_package_pattern" "$full_out"
require_no_match '==>.*Installing ' "$full_out"

step "check: nvim 0.12+ from dnf"
rpm -q neovim
nvim_path="$(su - "$user" -c 'command -v nvim')"
printf '%s\n' "$nvim_path"
[[ "$nvim_path" == /usr/bin/nvim ]]
nvim_version="$(su - "$user" -c 'nvim --version')"
nvim_version="${nvim_version%%$'\n'*}"
printf '%s\n' "$nvim_version"
[[ "$nvim_version" =~ ^NVIM\ v(0\.(1[2-9]|[2-9][0-9])|[1-9][0-9]*)\. ]]

step "check: language servers on PATH"
su - "$user" -c 'pylsp --version && bash-language-server --version'

step "check: weak dependencies stayed off (no npm)"
npm_packages="$(rpm -qa 'nodejs*npm*')"
npm_path="$(su - "$user" -c 'command -v npm || true')"
printf 'npm packages: [%s]\nnpm on the PATH of %s: [%s]\n' "$npm_packages" "$user" "$npm_path"
[[ -z "$npm_packages" && -z "$npm_path" ]]

step "check: Go tools built into ~/go/bin"
su - "$user" -c '~/go/bin/lazygit --version && ~/go/bin/lazydocker --version'

printf '\n### all steps passed\n'
EOF
)"

if ! bash -n <<<"$inner"; then
  echo "fedora-container.sh: the script for the container has a syntax error (bash -n, above), so podman was not run" >&2
  exit 1
fi

podman run --rm --security-opt label=disable -v "$root:/src:ro" "$IMAGE" bash -c "$inner"
