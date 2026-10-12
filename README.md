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
- **Language Support**: LSP configuration with `nvim-lspconfig` for Go, TypeScript, Python, Shell, JSON, YAML, Docker, Terraform, SQL, and Lua. Mason installs the native servers; the Node-based ones come from the system package manager (no npm needed).
- **Formatting and Linting**: `conform.nvim` for formatters with LSP fallback and format-on-save, `nvim-lint` for additional linting (hadolint, shellcheck, yamllint, golangci-lint, ruff, tflint).
- **File Management**: `Neo-tree` as the file explorer and `Telescope` with fzf-native for fuzzy finding.
- **Syntax Highlighting**: Built-in Neovim 0.12 treesitter highlighting via `vim.treesitter.start()`.
- **Navigation**: `flash.nvim` for labeled jump navigation, `nvim-surround` for surround operations.
- **DevOps Tools**: TUI access to Docker via `lazydocker`.
- **Modern UI**: Catppuccin theme, `lualine`, `trouble.nvim` for diagnostics, and a modernized command palette/messaging system with `noice.nvim`.
- **Session Management**: `auto-session` persists sessions on exit; restore from the alpha dashboard's `l` button (no auto-restore on startup so the dashboard always shows first).

## Requirements

This configuration targets **Arch Linux**. Other Linux distributions work on a best-effort basis through the [bootstrap script](#method-b-bootstrap-script-recommended), which lists anything it cannot install. macOS and Windows are not supported.

### Arch Linux

Everything except `hadolint` is in the official repositories:

```bash
sudo pacman -S --needed neovim git ripgrep base-devel curl unzip wl-clipboard nodejs go \
  bash-language-server vscode-json-languageserver pyright typescript-language-server yaml-language-server \
  stylua shfmt prettier python-black go-tools terraform \
  selene shellcheck yamllint tflint golangci-lint ruff \
  lazygit lazydocker fortune-mod ttf-jetbrains-mono-nerd
```

On an X11 session, install `xclip` instead of `wl-clipboard`.

`hadolint` (Dockerfile linter) is only in the AUR. Review the PKGBUILD, then install it with your AUR helper, or let Mason install it from inside Neovim with `:MasonInstall hadolint`:

```bash
yay -S hadolint-bin
```

### What each package is for

- **Core:** Neovim 0.12+, Git, and ripgrep (Telescope live grep).
- **Build tools:** `base-devel` provides the C compiler and `make` that telescope-fzf-native and LuaSnip compile with. Mason downloads with `curl` and extracts with `unzip`.
- **Clipboard:** `wl-clipboard` (Wayland) or `xclip` (X11). Without one, yanks do not reach the system clipboard.
- **Runtimes:** Node.js runs the Node-based language servers (npm is not needed). Mason uses Go to build `gopls` and `sqls`.
- **Language servers:** Mason installs the native servers (`docker_language_server`, `gopls`, `lua_ls`, `sqls`, `terraformls`) on first launch. The Node-based servers (`bashls`, `jsonls`, `pyright`, `ts_ls`, `yamlls`) come from the system packages above and are enabled only when installed.
- **Formatters** (`conform.nvim`): stylua, shfmt, prettier, black, goimports (`go-tools`), and `terraform fmt`.
- **Linters** (`nvim-lint`): selene, shellcheck, yamllint, tflint, golangci-lint, ruff, and hadolint.
- **TUI tools:** lazygit (`<leader>gtt`) and lazydocker (`<leader>dc`). `fortune` puts a random quote on the dashboard.
- **Nerd Font:** icons need a [Nerd Font](https://www.nerdfonts.com/). JetBrainsMono Nerd Font is recommended; set it as your terminal's font.

Missing formatters, linters, and Node-based servers are skipped quietly inside Neovim, so you can install only what your work needs.

### Upgrading from an older version of this config

Older versions installed `ansible-language-server`, `dockerfile-language-server`, `docker-compose-language-service`, and `sqlls` through Mason. Mason still enables anything it has installed, so remove them:

```
:MasonUninstall ansible-language-server dockerfile-language-server docker-compose-language-service sqlls
```

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

1.  Install Neovim 0.12+ (`sudo pacman -S neovim` on Arch, or your distribution's package manager).
2.  Clone the repository directly into your Neovim configuration directory:
    ```bash
    git clone https://github.com/jkleinne/nvim ~/.config/nvim
    ```

#### Method B: Bootstrap Script (Recommended)

The `nvim-install.sh` script detects your package manager and installs Neovim, build tools, a clipboard tool, runtimes (Node, Go), language servers, formatters, linters, TUI tools, and clones the configuration. Run it as your normal user; it calls `sudo` when it needs to.

**Supported platforms:** Arch Linux (pacman, first-class); Debian/Ubuntu (apt), Fedora/RHEL (dnf), Alpine (apk) (best-effort).

```bash
git clone https://github.com/jkleinne/nvim ~/.config/nvim
cd ~/.config/nvim
./nvim-install.sh
```

The script will:
- Install Neovim 0.12+ (prefers your system package manager, falls back to the GitHub release tarball)
- Install build dependencies, a clipboard tool, runtimes, language servers, formatters, linters, and TUI tools
- Detect your shell and update PATH if needed (bash, zsh, fish)
- Skip anything already installed
- List anything it could not install in the summary at the end (best-effort platforms get manual steps there)

Run `./nvim-install.sh --help` for details.

### 3. First Launch and Verification

Open Neovim. The `lazy.nvim` plugin manager will automatically start installing the plugins, including compiling telescope-fzf-native and LuaSnip components.

```bash
nvim
```

After the plugins are installed, run `:checkhealth` to ensure all dependencies are met and identify any issues.

```
:checkhealth
```

## Configuration

The configuration files are organized as follows:

```
~/.config/nvim/
├── lua/                   # Lua configuration directory
│   ├── plugins/           # Individual plugin configurations
│   │   ├── lsp.lua
│   │   ├── telescope.lua
│   │   └── ... (additional plugins)
│   ├── mappings.lua        # Key mappings and shortcuts
│   ├── settings.lua        # General settings and options
├── init.lua                # Main entry point
├── lazy-lock.json          # Lock file for lazy.nvim
├── nvim-install.sh         # Bootstrap script (Arch Linux; other distros best-effort)
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
  - **[kubectl.nvim](https://github.com/Ramilito/kubectl.nvim)**: Kubernetes integration (disabled; set `enabled = true` in `lua/plugins/kubectl.lua` to restore it and `<leader>k`; lazy.nvim reinstalls it at the locked commit on the next start).
  - **[lazydev.nvim](https://github.com/folke/lazydev.nvim)**: Lazy-loaded Neovim API type information and completions for `lua_ls`.
  - **[mason.nvim](https://github.com/mason-org/mason.nvim)**: Installs the native language servers, plus anything you add with `:Mason`.
  - **[neo-tree.nvim](https://github.com/nvim-neo-tree/neo-tree.nvim)**: File explorer.
  - **[noice.nvim](https://github.com/folke/noice.nvim)**: Modernizes the UI for messages, cmdline, and popups.
  - **[nvim-lint](https://github.com/mfussenegger/nvim-lint)**: Async linting for Dockerfile, shell, YAML, Go, Python, Terraform.
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
  - **Language Servers**: Configure additional LSPs or change settings in `lua/plugins/lsp.lua`, or install interactively using `:Mason`.
  - **Formatters**: Configure formatters per filetype in `lua/plugins/conform.lua`.
  - **Linters**: Configure linters per filetype in `lua/plugins/lint.lua`.

## License

This project is licensed under the [MIT License](LICENSE)
