![Neovim](https://img.shields.io/badge/Neovim-v0.12.0-blue.svg)
![License](https://img.shields.io/badge/license-MIT-green.svg)

My personal Neovim configuration

<p>
  <img src="https://github.com/user-attachments/assets/e557869c-8d8d-43fd-978f-aac7ea44ef08" width="49%" style="margin-right: 2%;" />
  <img src="https://github.com/user-attachments/assets/17a71244-67b3-446e-af00-fcfa8fd7651e" width="49%" />
</p>

## Table of Contents

- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Configuration](#configuration)
- [Keybindings](#keybindings)
- [Plugins](#plugins)
- [Customization](#customization)
- [License](#license)

## Features

- **Easily Extendable and Configurable**: Modular and simple directory structure.
- **Intelligent Autocompletion**: Powered by `blink.cmp` (Rust fuzzy matching) and `LuaSnip`.
- **Git Integration**: Visualize git changes with `gitsigns` and TUI access via `lazygit`.
- **Language Support**: LSP configuration with `nvim-lspconfig` for Go, TypeScript, Python, Shell, JSON, YAML, Docker (Dockerfiles through dockerfile-language-server, compose files through yamlls), Terraform, SQL, and Lua. Mason installs the native servers; the Node-based ones come from the system package manager (on Arch, no npm needed).
- **Formatting and Linting**: `conform.nvim` for formatters with LSP fallback and format-on-save, `nvim-lint` for additional linting (selene, hadolint, shellcheck, yamllint, golangci-lint, ruff, tflint).
- **File Management**: `Neo-tree` as the file explorer and `Telescope` with fzf-native for fuzzy finding.
- **Syntax Highlighting**: Built-in Neovim 0.12 treesitter highlighting via `vim.treesitter.start()`.
- **Navigation**: `flash.nvim` for labeled jump navigation, `nvim-surround` for surround operations.
- **DevOps Tools**: TUI access to Docker via `lazydocker`.
- **Modern UI**: Catppuccin theme, `lualine`, `trouble.nvim` for diagnostics, and a modernized command palette/messaging system with `noice.nvim`.
- **Session Management**: `auto-session` persists sessions on exit; restore from the alpha dashboard's `l` button (no auto-restore on startup so the dashboard always shows first).

## Requirements

This configuration targets **Arch Linux**. Fedora is supported through the [bootstrap script](#method-b-bootstrap-script-recommended), which installs everything Fedora packages and lists the rest; other Linux distributions are best-effort through the same script. macOS and Windows are not supported.

### Arch Linux

One pacman command installs everything except `hadolint` (see below). The bootstrap script ([Method B](#method-b-bootstrap-script-recommended)) installs the same packages for you, except the Nerd Font, and picks the clipboard tool from your session; if you install manually ([Method A](#method-a-manual-installation)), run the command yourself. On an X11 session, replace `wl-clipboard` with `xclip` in the command:

```bash
sudo pacman -S --needed neovim git ripgrep base-devel curl unzip wl-clipboard nodejs go \
  bash-language-server dockerfile-language-server vscode-json-languageserver pyright \
  typescript-language-server yaml-language-server \
  stylua shfmt prettier python-black go-tools terraform \
  selene shellcheck yamllint tflint golangci-lint ruff \
  lazygit lazydocker fortune-mod ttf-jetbrains-mono-nerd
```

Run `sudo -k` afterwards, so the cached sudo credentials do not reach the plugin builds on Neovim's first launch (the bootstrap script does this itself).

`hadolint` (Dockerfile linter) is only in the AUR. Review the PKGBUILD, then install it with your AUR helper, or let Mason install it from inside Neovim with `:MasonInstall hadolint`:

```bash
yay -S hadolint-bin
```

### Fedora

One dnf command installs everything Fedora packages. Fedora 44 and newer package Neovim 0.12, while Fedora 43's is 0.11.6, so there the bootstrap script ([Method B](#method-b-bootstrap-script-recommended)) installs Neovim from the official release tarball; if you install by hand, leave `neovim` out of the dnf command on Fedora 43 (it would still install 0.11.6) and get Neovim 0.12 from the [Neovim releases](https://github.com/neovim/neovim/releases) instead. The script installs the same packages for you and picks the clipboard tool from your session; on an X11 session, replace `wl-clipboard` with `xclip`:

```bash
sudo dnf install --setopt=install_weak_deps=False neovim git ripgrep gcc make curl tar gzip unzip \
  wl-clipboard nodejs golang nodejs-bash-language-server python3-lsp-server \
  shfmt black golang-x-tools-goimports ShellCheck yamllint ruff golangci-lint hadolint fortune-mod
```

The option keeps dnf from also installing recommended packages, `npm` among them through Fedora's `nodejs`; the script does the same.

Run `sudo -k` afterwards, so the cached sudo credentials do not reach the plugin builds on Neovim's first launch (the bootstrap script does this itself).

Fedora has no package for `lazygit` or `lazydocker`: the script installs both with `go install` at pinned versions into Go's bin directory (`~/go/bin` by default), and tells you when that directory is not on your `PATH`. It lists `stylua`, `selene`, `prettier`, `tflint` and `terraform` as manual steps. Of the Node-based language servers Fedora packages only `bash-language-server`, so `dockerls`, `jsonls`, `ts_ls` and `yamlls` stay off unless you install their commands yourself (`ts_ls` also needs a system TypeScript; the script says so in a warning), and `python-lsp-server` (`pylsp`) stands in for `pyright` (see [Language servers](#what-each-package-is-for)). Install a [Nerd Font](https://www.nerdfonts.com/) yourself.

### What each package is for

- **Core:** Neovim 0.12+, Git, and ripgrep (Telescope live grep).
- **Build tools:** `base-devel` provides the C compiler and `make` that telescope-fzf-native and LuaSnip compile with. Mason downloads with `curl` and extracts with `unzip`.
- **Clipboard:** `wl-clipboard` (Wayland) or `xclip` (X11). Without one, yanks do not reach the system clipboard.
- **Runtimes:** Node.js runs the Node-based language servers (npm is not needed). Mason uses Go to build `gopls` and `sqls`.
- **Language servers:**
  - **Sources:** Mason installs the native servers (`gopls`, `lua_ls`, `sqls`, `terraformls`) the first time you open a file. The Node-based servers (`bashls`, `dockerls`, `jsonls`, `pyright`, `ts_ls`, `yamlls`) come from the system packages above and are enabled only when installed. On Fedora, which packages no pyright, `python-lsp-server` (`pylsp`) stands in for it, enabled only when `pylsp` is installed and `pyright-langserver` is not. "System" means the first matching binary on Neovim's `PATH`, whatever installed it. Mason copies of these servers are never enabled automatically: `lsp.lua`'s checks decide, though a Mason copy still runs if it is the one on `PATH` (see [Upgrading](#upgrading-from-an-older-version-of-this-config)). docker-language-server is not used: it sends telemetry, crash reports, and Dockerfile image names to Docker by default.
  - **`:lsp enable`:** a repo's `node_modules` copies of the Node-based servers are never used, not even when you run `:lsp enable <name>` for one of them yourself. A bare `:lsp enable` (no name) enables every lspconfig server for the buffer's filetype, and some of those prefer a repo's `node_modules/.bin`. The known lspconfig servers that would run a repo's code with tools this config installs never start, not even then: `tflint` (plugins named in a repo's `.tflint.hcl`), `golangci_lint_ls` (a repo's `.golangci.yml`), `terraform_lsp` and `tofu_ls` (Terraform providers), and `esbonio` and `tvm_ffi_navigator` (a repo's Python modules through `python -m`).
  - **`ts_ls`:** enabled only with a real TypeScript package: Arch's `typescript` (a dependency of `typescript-language-server`), or the package your `tsserver` belongs to; a version manager's shim does not count. The package is checked again each time a buffer needs `ts_ls`, so once it is removed, `ts_ls` starts for no further buffers. Its automatic type acquisition is off, so tsserver never runs npm to download `@types` packages.
  - **`pylsp`:** like the system servers' commands, `pylsp` is resolved on `PATH`, so a pylsp installed in an active venv runs from there, as that venv's black and ruff do. jedi, its completion engine, starts a Python interpreter as a subprocess and imports the modules its `auto_import_modules` list names instead of analyzing them. This config pins that interpreter to `/usr/bin/python3`, so an active `VIRTUAL_ENV` or `CONDA_PREFIX` never makes jedi run a project's interpreter (and that interpreter's site hooks). It also empties the list, whose default imports `numpy`. Because of the pin, packages installed only in a project's venv get no completion. pylsp's startup preloading of libraries (numpy and pandas among them) is off, and so are its bundled linters and formatters (pycodestyle, pyflakes, mccabe, autopep8, yapf) and two of the add-ons Fedora packages, python-lsp-ruff and python-lsp-black; ruff and black do that work. What remains: pylsp enables any other add-on installed beside it; pylsp's own process honors an inherited `PYTHONPATH`, even one that reaches the project directory (pylsp drops it only for jedi's interpreter); and jedi still imports the compiled modules it meets while inferring, though only from that interpreter's own module path, not from the project directory.
  - **`lua_ls`:** declines its workspace plugin prompts, so a repo's `.luarc.json` plugin never loads. That answer also declines its auto-require prompts: accepting a completion for a module the file does not require yet inserts only the name, without a `require` line. Its plugin approvals live in `lua_ls/trusted` under Neovim's log directory (`~/.local/state/nvim`), which starts empty and which this config never adds to.
  - **terraform-ls:** when the `terraform` CLI is installed, terraform-ls stays off until you allow its directory, because it runs provider binaries from `.terraform` directories. Neovim never prompts for this: run `:TerraformTrust` from a file buffer under the directory (a new file must be saved first). The directory is the nearest ancestor with `.terraform` (else `.git`, else the file's own directory), and trusting it covers the `.terraform` directories below it. `:TerraformTrust` refuses `/`, your home directory and its parents, world-writable directories, and directories owned by another user. terraform-ls starts only in directories you own that are not world-writable, so `:TerraformTrust!` overrides a refusal only for those (your home directory, for example), and trusting such a directory covers every project below it. A file whose path has a `$NAME` that Neovim would expand (a directory literally named `$HOME`, for example) never starts terraform-ls. To revoke, run `:trust ++remove <directory>`, then `:lsp stop terraformls`.
- **No phoning home:** terraform's update check is off (`CHECKPOINT_DISABLE`), and yamlls and jsonls never download schemas, so SchemaStore and remote `$schema` URLs give no completion or validation (local schema files still work). terraform-ls may still look up public module metadata on registry.terraform.io for registry `module` sources; this config has no switch for that.
- **Formatters** (`conform.nvim`): stylua, shfmt, prettier, black, goimports (`go-tools`), gofmt (ships with `go`), and `terraform fmt`. prettier always runs the system binary, but it still reads a repo's prettier config, and a JavaScript config or a plugin listed in it can run code.
- **Linters** (`nvim-lint`): selene, shellcheck, yamllint, tflint, golangci-lint, ruff, and hadolint. Run through nvim-lint, tflint and golangci-lint never run plugins a repo names: tflint uses this config's `tflint.hcl` and plugins from `tflint-plugins/` in Neovim's data directory (`~/.local/share/nvim`), never a repo's (see `tflint.hcl` for installing one), and golangci-lint runs with `--no-config`, so repos' `.golangci.yml` files are ignored. Their language servers (`tflint`, `golangci_lint_ls`) never start.
- **TUI tools:** lazygit (`<leader>gtt`) and lazydocker (`<leader>dc`). `fortune` puts a random quote on the dashboard.
- **Nerd Font:** icons need a [Nerd Font](https://www.nerdfonts.com/). JetBrainsMono Nerd Font is recommended; set it as your terminal's font.

Missing formatters, linters, and Node-based servers are skipped quietly inside Neovim, so you can install only what your work needs. One deliberate exception: terraform-ls warns when the `terraform` CLI is missing.

### Upgrading from an older version of this config

Older versions installed `ansible-language-server`, `docker-language-server`, `dockerfile-language-server`, `docker-compose-language-service`, and `sqlls` through Mason. `lsp.lua` keeps Mason from enabling any of them, but they still take disk space, and a Mason `dockerfile-language-server` comes first on Neovim's `PATH`, so it runs instead of the pacman one. Remove them: `:MasonUninstall` errors on a package that is not installed, so run this inside Neovim instead; it removes only the ones that are present (restart Neovim afterwards):

```
:lua for _, n in ipairs { "ansible-language-server", "docker-language-server", "dockerfile-language-server", "docker-compose-language-service", "sqlls" } do local p = require("mason-registry").get_package(n) if p:is_installed() then p:uninstall() end end
```

If an older install also put `bash-language-server`, `json-lsp`, `pyright`, `typescript-language-server`, or `yaml-language-server` in Mason, those copies come first on Neovim's `PATH`, so `lsp.lua` runs them instead of the pacman packages. Remove them from `:Mason` to use the system ones.

Older versions let `lua_ls` keep its plugin approvals in Mason's `lua-language-server/libexec/log/trusted` (under `~/.local/share/nvim/mason/packages/`). This config no longer reads that file; delete it if you like.

## Installation

### 1. Backup Existing Configuration

Before proceeding, back up your existing Neovim configuration:

```bash
mv ~/.config/nvim ~/.config/nvim_backup
mv ~/.local/share/nvim ~/.local/share/nvim_backup
mv ~/.local/state/nvim ~/.local/state/nvim_backup
mv ~/.cache/nvim ~/.cache/nvim_backup
```

### 2. Setup the Configuration

#### Method A: Manual Installation

1.  Install the packages under [Requirements](#requirements). On Arch, the pacman command there includes Neovim 0.12+; elsewhere, use your distribution's package manager.
2.  Clone the repository directly into your Neovim configuration directory:
    ```bash
    git clone https://github.com/jkleinne/nvim ~/.config/nvim
    ```

#### Method B: Bootstrap Script (Recommended)

The `nvim-install.sh` script detects your distribution and installs Neovim, build tools, a clipboard tool, runtimes (Node, Go), the language servers its repos package (on Arch the Node-based servers; on Fedora `bash-language-server` and `python-lsp-server`), formatters, linters, TUI tools, and clones the configuration. On Arch it installs the same packages as the command under [Requirements](#requirements), except the Nerd Font (install it with `sudo pacman -S ttf-jetbrains-mono-nerd`); on Fedora, the same as the dnf command there, plus `lazygit` and `lazydocker` with `go install`. Run it as your normal user; it calls `sudo` when it needs to. It asks before it changes anything, so it needs a terminal to answer from: piped into `bash` (as in `curl ... | bash`), it stops at the first question.

**Supported platforms:** Arch Linux (pacman) is first-class and Fedora (dnf) is supported. Debian/Ubuntu (apt) and Alpine (apk) are best-effort. RHEL and RHEL-like distributions (CentOS, Rocky Linux, AlmaLinux) take the same dnf path and the same supported tier, but their repos may lack some of the packages the script installs.

```bash
git clone https://github.com/jkleinne/nvim ~/.config/nvim
cd ~/.config/nvim
./nvim-install.sh
```

Pass `--packages-only` to install the system packages and stop, for setups that provision system packages apart from the user's home. Then run the script again without it where Neovim will run. With every package already present and Neovim 0.12 or newer on `PATH`, or in a tarball install it can reuse (see below), that run installs no system package again and runs nothing as root; it goes on to the user-level tools, the config and the checks.

The script will:
- On Arch, upgrade the system first (`pacman -Syu`, with pacman's own confirmation) when anything needs installing, since installing against a newer package database without upgrading is a partial upgrade
- Install Neovim 0.12+ (prefers your system package manager, falls back to the GitHub release tarball in `/opt/nvim`). A later run that does not find that tarball's nvim on `PATH` reuses it instead of installing again, but only when root owns everything in `/opt/nvim` and nothing there is writable by group or others; the full run then adds `/opt/nvim/bin` to your shell config and stops at its Neovim check, so open a new terminal and run it again
- Ask before moving an existing config that is not this repo aside, and move it only after the clone succeeds
- Install build dependencies, a clipboard tool, runtimes, formatters, linters, TUI tools, and the language servers the distro packages (on Arch the Node-based servers; on Fedora `bash-language-server` and `python-lsp-server`)
- Forget cached sudo credentials, including ones from before the run (such as a `sudo pacman -S` you just ran), before it clones the config and launches Neovim, which installs plugins and runs their build steps; with passwordless sudo (`NOPASSWD`), forgetting the ticket protects nothing
- After forgetting them, install the user-level tools the distro's repos lack: on Fedora, `lazygit` and `lazydocker` with `go install`; on best-effort platforms, also `shfmt`, `goimports` and `golangci-lint` with `go install`, and `black`, `ruff` and `yamllint` with `uv tool install` (at the latest release). On both, `stylua`, `prettier`, `terraform`, `selene` and `tflint` stay manual steps, and on best-effort platforms `hadolint` does too
- Pin each of its `go install`s to an exact release and run it with `GOTOOLCHAIN=local`, so the script never downloads a Go toolchain: a tool that needs a newer Go than the distro ships is skipped with a warning. Every pinned tool but lazydocker needs Go 1.26 or newer. Fedora 43 and 44 ship 1.26; Debian 13 ships 1.24, so install Go 1.26 or newer there first, for example from trixie-backports
- Check the config through the headless Neovim launch it runs after the clone: when that launch reports an error message, the script warns "Config reported errors at startup". Launch nvim to see the errors; on the next launch lazy.nvim retries failed plugin downloads, but not failed builds
- Detect your shell and update PATH if needed (bash, zsh, fish)
- Skip anything already installed
- Stop if a required package (build tools, core tools, runtimes) fails, and list optional tools it could not install in the summary at the end (Fedora and the best-effort platforms get manual steps there)
- End by asking you to open a file in nvim once: Mason installs the native language servers then, not during the run. mason.nvim cancels installs still running when Neovim exits, so leave nvim open until they finish (`:Mason` shows their status)

Run `./nvim-install.sh --help` for details.

The installer's tests run with `bash tests/install-script.test.sh` (the scripts that run the installer's `main` for them, their shared helpers and stub commands, and the reader that gets the server list through `nvim --clean`, are in `tests/lib/`; the suite refuses to run when its temp dir is on a `noexec` mount, so point `TMPDIR` elsewhere then); set `RUN_FULL=1` on a fully provisioned Arch machine to include an end-to-end run (it runs `sudo -k` itself first, so no cached sudo ticket reaches the run, and it needs network: Neovim's first launch installs the plugins into scratch directories), and `REQUIRE_ALL=1` to fail instead of skipping when the tests that need a fake root cannot run (the root-guard test and the checks on root-owned install trees; they need `fakeroot` or `unshare -r`). The LSP and linter settings that keep repo code from running and tools from downloading anything are tested with `nvim --clean --headless -l tests/editor-config.test.lua` (no plugins or network needed).

`RUN_FEDORA=1` adds to the installer's tests an end-to-end run of the dnf path in a throwaway `fedora:44` container (`tests/lib/fedora-container.sh`): a `--packages-only` run, then a full run that must install nothing again, with checks that every package name resolves, Neovim comes from dnf, the language servers land on `PATH` without npm, the Go tools build, and the config check passes. Packages are installed only inside the container. It needs rootless podman with subuid and subgid ranges for your user, and network; the image stays in podman's storage until `podman rmi docker.io/library/fedora:44`.

### 3. First Launch and Verification

Open Neovim. After a manual installation (Method A), the `lazy.nvim` plugin manager starts installing the plugins on this first launch, including compiling telescope-fzf-native and LuaSnip components; after the bootstrap script (Method B), the script's own launch has already done this. Mason installs the native language servers the first time you open a file.

```bash
nvim
```

Once the plugins are installed, run `:checkhealth` to check the dependencies and find any issues.

```
:checkhealth
```

## Configuration

The configuration files are organized as follows:

```
~/.config/nvim/
├── lua/                   # Lua configuration directory
│   ├── lsp_gates/         # Server list, TypeScript and terraform-ls trust checks used by plugins/lsp.lua
│   ├── plugins/           # Individual plugin configurations
│   │   ├── lsp.lua
│   │   ├── telescope.lua
│   │   └── ... (additional plugins)
│   ├── mappings.lua        # Key mappings and shortcuts
│   └── settings.lua        # General settings and options
├── init.lua                # Main entry point
├── lazy-lock.json          # Lock file for lazy.nvim
├── nvim-install.sh         # Bootstrap script (Arch first-class, Fedora supported; other distros best-effort)
├── tests/                  # Installer and editor config tests
├── tflint.hcl              # tflint config used instead of repos' own
└── ...
```

## Keybindings

The leader key is set to `Space`.

### General Navigation

| Keybinding | Description |
| :--- | :--- |
| `<C-e>` | Toggle Neo-tree file explorer |
| `<TAB>` | Cycle to the next buffer |
| `<S-TAB>` | Cycle to the previous buffer |
| `<leader>bd` | Close the current buffer (Bdelete) |
| `s` | Flash jump (labeled jump to any visible location) |
| `S` | Flash treesitter jump (select treesitter nodes) |

### Search (Telescope)

| Keybinding | Description |
| :--- | :--- |
| `<leader>tf` | Find files in the current working directory |
| `<leader>tg` | Live grep (search text) in the current working directory |
| `<leader>tb` | List open buffers |
| `<leader>th` | Search help tags |
| `<leader>ts` | Search LuaSnip snippets |

### Tabs and Terminals

| Keybinding | Description |
| :--- | :--- |
| `<C-w>t` | Open a new tab |
| `<leader>bn` | Open a new empty buffer (`:enew`) |
| `<leader>h` | Open a terminal in a horizontal split below |
| `<leader>v` | Open a terminal in a vertical split to the right |
| `<Esc><Esc>` | Exit terminal mode (double-tap; single Esc preserved for TUIs) |
| `<C-h>` / `<C-j>` / `<C-k>` / `<C-l>` | From terminal mode, jump to the left/lower/upper/right window |

### TUI & Tool Integrations

| Keybinding | Description |
| :--- | :--- |
| `<leader>gtt`| Open LazyGit in a terminal buffer |
| `<leader>dc` | Open LazyDocker in a terminal buffer |

### LSP (Language Server Protocol)

These are active when an LSP server is attached to a buffer.

| Keybinding | Description |
| :--- | :--- |
| `gd` | Go to definition |
| `K` | Hover documentation |
| `gi` | Go to implementation |
| `gr` | Go to references |
| `<C-k>` | Signature help |
| `<leader>D` | Go to type definition |
| `<leader>rn` | Rename symbol |
| `<leader>ca` | Code actions |
| `<leader>f` | Format buffer (conform.nvim with LSP fallback) |
| `gl` | Open floating diagnostics |
| `[d` | Go to previous diagnostic |
| `]d` | Go to next diagnostic |
| `<leader>q` | Send diagnostics to location list |
| `<leader>wa` | Add workspace folder |
| `<leader>wr` | Remove workspace folder |
| `<leader>wl` | List workspace folders |

### Diagnostics (Trouble)

| Keybinding | Description |
| :--- | :--- |
| `<leader>xx` | Toggle workspace diagnostics |
| `<leader>xd` | Toggle buffer diagnostics |
| `<leader>xl` | Toggle location list |
| `<leader>xq` | Toggle quickfix list |

### Editing

| Keybinding | Description |
| :--- | :--- |
| `gcc` | Toggle line comment (built-in) |
| `gc` | Toggle comment (visual mode, built-in) |
| `cs"'` | Change surrounding `"` to `'` (nvim-surround) |
| `ds(` | Delete surrounding `(` (nvim-surround) |
| `ysiw]` | Add `[]` around word (nvim-surround) |

## Plugins

Here is a list of the key plugins included in this configuration:

  - **[alpha-nvim](https://github.com/goolord/alpha-nvim)**: Startup screen.
  - **[auto-session](https://github.com/rmagatti/auto-session)**: Saves sessions on exit; restore on demand from the alpha dashboard (`l`).
  - **[blink.cmp](https://github.com/saghen/blink.cmp)**: Autocompletion engine with Rust fuzzy matcher.
  - **[bufferline.nvim](https://github.com/akinsho/bufferline.nvim)**: Manage open buffers as tabs.
  - **[catppuccin/nvim](https://github.com/catppuccin/nvim)**: Soothing pastel theme (Mocha flavor).
  - **[conform.nvim](https://github.com/stevearc/conform.nvim)**: Formatter runner with LSP fallback and format-on-save.
  - **[flash.nvim](https://github.com/folke/flash.nvim)**: Labeled jump navigation.
  - **[gitsigns.nvim](https://github.com/lewis6991/gitsigns.nvim)**: Git decorations in the gutter.
  - **[kubectl.nvim](https://github.com/Ramilito/kubectl.nvim)**: Kubernetes integration. Disabled: set `enabled = true` in `lua/plugins/kubectl.lua` to restore it and `<leader>k` (lazy.nvim reinstalls it at the locked commit on the next start).
  - **[lazydev.nvim](https://github.com/folke/lazydev.nvim)**: Lazy-loaded Neovim API type information and completions for `lua_ls`.
  - **[mason.nvim](https://github.com/mason-org/mason.nvim)**: Installs the native language servers, plus anything you add with `:Mason`.
  - **[neo-tree.nvim](https://github.com/nvim-neo-tree/neo-tree.nvim)**: File explorer.
  - **[noice.nvim](https://github.com/folke/noice.nvim)**: Modernizes the UI for messages, cmdline, and popups.
  - **[nvim-lint](https://github.com/mfussenegger/nvim-lint)**: Async linting for Lua, Dockerfile, shell, YAML, Go, Python, Terraform.
  - **[nvim-surround](https://github.com/kylechui/nvim-surround)**: Surround operations (change, delete, add).
  - **[telescope.nvim](https://github.com/nvim-telescope/telescope.nvim)**: Fuzzy finder with fzf-native sorting.
  - **[todo-comments.nvim](https://github.com/folke/todo-comments.nvim)**: Highlight and search TODO/FIXME/HACK comments.
  - **[trouble.nvim](https://github.com/folke/trouble.nvim)**: Diagnostics and quickfix UI.
  - **[which-key.nvim](https://github.com/folke/which-key.nvim)**: Displays a popup with possible keybindings.

*For a complete list, refer to the `lua/plugins` folder in the repository.*

## Customization

  - **Themes**: Change the colorscheme or flavor by modifying the `lua/plugins/colorscheme.lua` file.
  - **Keybindings**: Update or add new keybindings in the `lua/mappings.lua` file.
  - **Plugins**: Add or remove plugins in the `lua/plugins/` directory. `lazy.nvim` will manage them automatically upon restart.
  - **Language Servers**: Change the server lists in `lua/lsp_gates/servers.lua` and server settings in `lua/plugins/lsp.lua`, or install interactively using `:Mason`.
  - **Formatters**: Configure formatters per filetype in `lua/plugins/conform.lua`.
  - **Linters**: Configure linters per filetype in `lua/plugins/lint.lua`.

## License

This project is licensed under the [MIT License](LICENSE)
