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
- **Language Support**: Extensive LSP configuration with `mason` and `nvim-lspconfig` (Go, TypeScript, Python, YAML, Docker, Terraform, etc.).
- **Formatting and Linting**: `conform.nvim` for formatters with LSP fallback, `nvim-lint` for additional linting (hadolint, shellcheck, yamllint, golangci-lint, ruff, tflint).
- **File Management**: `Neo-tree` as the file explorer and `Telescope` with fzf-native for fuzzy finding.
- **Syntax Highlighting**: Built-in Neovim 0.12 treesitter highlighting via `vim.treesitter.start()`.
- **Navigation**: `flash.nvim` for labeled jump navigation, `nvim-surround` for surround operations.
- **DevOps Tools**: Kubernetes integration via `kubectl.nvim` and TUI access to Docker (`lazydocker`), SQL (`lazysql`), and API clients (`posting`).
- **Modern UI**: Catppuccin theme, `lualine`, `trouble.nvim` for diagnostics, and a modernized command palette/messaging system with `noice.nvim`.

## Requirements

To use this configuration, you must have the following installed.

### Core Dependencies

- [Neovim](https://neovim.io/) (version 0.12 or higher)
- [Git](https://git-scm.com/)

### System Tools and Build Essentials

Required for fuzzy finding, installation, and compiling plugins (telescope-fzf-native and LuaSnip components).

- [ripgrep](https://github.com/BurntSushi/ripgrep) (`rg`): Required by Telescope for live grep.
- **C Compiler** (`gcc` or `clang`)
- **`make`**
- **`curl`**, **`tar`**, **`gzip`**

Installation examples:

```bash
# Debian/Ubuntu
sudo apt install build-essential curl tar gzip ripgrep

# macOS (requires Homebrew)
xcode-select --install # Installs git, gcc/clang, make
brew install ripgrep curl
```

### Runtimes and LSPs

Required for Language Server Protocols managed by Mason.

  - [Node.js](https://nodejs.org/) and `npm` (for `ts_ls`, `jsonls`, `yamlls`, etc.)
  - [Go](https://go.dev/) (for `gopls`)

### Formatters and Linters

Managed by `conform.nvim` and `nvim-lint`. Install the ones relevant to your workflow:

```bash
# Formatters
brew install stylua shfmt
npm install -g prettier
pip install black

# Linters
brew install selene hadolint shellcheck yamllint tflint golangci-lint
pip install ruff
```

### Visuals and UI

  - **[Nerd Fonts](https://www.nerdfonts.com/)**: Required for displaying icons.
      - *Recommended: JetBrainsMono Nerd Font.*
      - Download and install the font on your system, then configure your terminal emulator to use it.
  - **fortune**: Displays random quotes on the dashboard (`alpha.nvim`).
    ```bash
    # macOS/Linux via Homebrew
    brew install fortune
    # Debian/Ubuntu
    sudo apt install fortune-mod
    ```

### Optional TUI Tools

These tools are integrated via key mappings but are not strictly required for Neovim to function.

  - [lazygit](https://github.com/jesseduffield/lazygit): Git TUI (`<leader>gtt`).
  - [lazydocker](https://github.com/jesseduffield/lazydocker): Docker TUI (`<leader>dc`).
  - [lazysql](https://github.com/jorgerojas26/lazysql): SQL client TUI (`<leader>sq`).
  - [posting](https://github.com/darrenburns/posting): API development/testing TUI (`<leader>po`).

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

1.  Install Neovim 0.12+ (e.g., `brew install neovim` or via your OS package manager).
2.  Clone the repository directly into your Neovim configuration directory:
    ```bash
    git clone https://github.com/jkleinne/nvim ~/.config/nvim
    ```

#### Method B: Bootstrap Script (Recommended)

The `nvim-install.sh` script detects your platform and installs Neovim, build tools, runtimes (Node, Go), formatters, linters, TUI tools, and clones the configuration.

**Supported platforms:** macOS (Homebrew), Debian/Ubuntu (apt), Fedora/RHEL (dnf), Arch Linux (pacman), Alpine (apk).

```bash
git clone https://github.com/jkleinne/nvim ~/.config/nvim
cd ~/.config/nvim
./nvim-install.sh
```

The script will:
- Install Neovim 0.12+ (prefers your system package manager, falls back to the GitHub release tarball)
- Install build dependencies, runtimes, formatters, linters, and TUI tools
- Detect your shell and update PATH if needed (bash, zsh, fish)
- Skip anything already installed

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
│   │   ├── ... (additional plugins)
│   │   └── init.lua       # Plugin loader initialization
│   ├── mappings.lua        # Key mappings and shortcuts
│   ├── settings.lua        # General settings and options
├── init.lua                # Main entry point
├── lazy-lock.json          # Lock file for lazy.nvim
├── nvim-install.sh         # Installation script (Linux)
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
| `<leader>x` | Close the current buffer (Bdelete) |
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
| `<leader>ta` | Open a new empty buffer (`:enew`) |
| `<leader>h` | Open a terminal in a horizontal split below |
| `<leader>v` | Open a terminal in a vertical split to the right |
| `<Esc><Esc>` | Exit terminal mode (double-tap; single Esc preserved for TUIs) |

### TUI & Tool Integrations

| Keybinding | Description |
| :--- | :--- |
| `<leader>k` | Toggle Kubectl context viewer |
| `<leader>gtt`| Open LazyGit in a terminal buffer |
| `<leader>dc` | Open LazyDocker in a terminal buffer |
| `<leader>sq` | Open LazySQL in a terminal buffer |
| `<leader>po` | Open Posting (API tester) in a terminal buffer |

### LSP (Language Server Protocol)

These are active when an LSP server is attached to a buffer.

| Keybinding | Description |
| :--- | :--- |
| `gd` | Go to definition |
| `K` | Hover documentation |
| `gi` | Go to implementation |
| `gr` | Go to references |
| `<C-k>` | Signature help |
| `<leader>rn` | Rename symbol |
| `<leader>ca` | Code actions |
| `<leader>f` | Format buffer (conform.nvim with LSP fallback) |
| `gl` | Open floating diagnostics |
| `[d` | Go to previous diagnostic |
| `]d` | Go to next diagnostic |

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
  - **[bufferline.nvim](https://github.com/akinsho/bufferline.nvim)**: Manage open buffers as tabs.
  - **[catppuccin/nvim](https://github.com/catppuccin/nvim)**: Soothing pastel theme (Mocha flavor).
  - **[conform.nvim](https://github.com/stevearc/conform.nvim)**: Formatter runner with LSP fallback.
  - **[flash.nvim](https://github.com/folke/flash.nvim)**: Labeled jump navigation.
  - **[gitsigns.nvim](https://github.com/lewis6991/gitsigns.nvim)**: Git decorations in the gutter.
  - **[kubectl.nvim](https://github.com/Ramilito/kubectl.nvim)**: Kubernetes integration.
  - **[mason.nvim](https://github.com/mason-org/mason.nvim)**: Manage LSPs, linters, and formatters.
  - **[neo-tree.nvim](https://github.com/nvim-neo-tree/neo-tree.nvim)**: File explorer.
  - **[noice.nvim](https://github.com/folke/noice.nvim)**: Modernizes the UI for messages, cmdline, and popups.
  - **[blink.cmp](https://github.com/saghen/blink.cmp)**: Autocompletion engine with Rust fuzzy matcher.
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
