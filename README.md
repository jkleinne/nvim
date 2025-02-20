![Neovim](https://img.shields.io/badge/Neovim-v0.10.0-blue.svg)
![License](https://img.shields.io/badge/license-MIT-green.svg)

My personal Neovim configuration setup for DevOps & Coding

<p>
  <img src="https://github.com/user-attachments/assets/e557869c-8d8d-43fd-978f-aac7ea44ef08" width="49%" style="margin-right: 2%;" />
  <img src="https://github.com/user-attachments/assets/17a71244-67b3-446e-af00-fcfa8fd7651e" width="49%" />
</p>



## Table of Contents

- [Features](#features)
- [Installation](#installation)
- [Requirements](#requirements)
- [Usage](#usage)
- [Plugins](#plugins)
- [Configuration](#configuration)
- [License](#license)

## Features

- **Easily Extendable and Configurable**: Modular and simple directory structure
- **Intelligent Autocompletion**: Powered by `nvim-cmp`
- **Git Integration**: Visualize git changes with `gitsigns` and TUI with `lazygit`
- **Language Support**: LSP configuration with `mason` and `nvim-lspconfig`
- **File Management**: `Neo-tree` as the file explorer and `window-picker` for easier navigation
- **Syntax Highlighting**: Treesitter integration for better syntax awareness
- **Additional Utilities**: Autopairs, indent guides, and more

## Installation

### Prerequisites

- [Neovim](https://neovim.io/) (version 0.10 or higher)
    - `nvim-install.sh` installs the latest Neovim version (Run as `. nvim-install.sh` so that it's sourced in the current shell and not a subshell)
- [Git](https://git-scm.com/)

### Dependencies

- [Node.js](https://nodejs.org/) for certain plugins
- [ripgrep](https://github.com/BurntSushi/ripgrep) for Telescope

### Additional System Dependencies

- **fortune**: Displays random quotes on the dashboard
  - **Installation via Homebrew**:
    ```bash
    brew install fortune
    ```
  - **Manual Installation**:
    - Refer to the [Fortune Installation Guide](https://invisible-island.net/fortune/) for other package managers
- **Nerd Fonts**: Required for displaying icons in Neovim
  - **Download and Installation**:
    - Visit the [Nerd Fonts](https://www.nerdfonts.com/) website and download the font
    - *I'm using the JetBrainsMono Nerd Font*
    - **macOS**:
      - Double-click the downloaded `.zip` file
      - Open the font files and click "Install"

### Optional

- [lazygit](https://github.com/jesseduffield/lazygit) Git in a TUI
- [lazydocker](https://github.com/jesseduffield/lazydocker) Docker in a TUI
- [lazysql](https://github.com/jorgerojas26/lazysql) SQL client in a TUI

*Run `:checkhealth` to see what is missing if you get any errors/warnings when opening `neovim`*

## Usage

After installation, simply open Neovim:

```bash
nvim
```

## Plugins

Here is a list of some of the key plugins included in this configuration:

- **[alpha.lua](https://github.com/goolord/alpha-nvim)**: Startup screen for Neovim
- **[bufferline.lua](https://github.com/akinsho/bufferline.nvim)**: Manage open buffers as tabs
- **[cmp.lua](https://github.com/hrsh7th/nvim-cmp)**: Autocompletion engine
- **[kubectl.lua](https://github.com/Ramilito/kubectl.nvim)**: Kubernetes integration
- **[mason.lua](https://github.com/williamboman/mason.nvim)**: Manage language servers, linters, and formatters
- **[neotree.lua](https://github.com/nvim-neo-tree/neo-tree.nvim)**: File explorer for Neovim
- **[scope.lua](https://github.com/tiagovla/scope.nvim)**: Manage buffers between tabs and windows
- **[telescope.lua](https://github.com/nvim-telescope/telescope.nvim)**: Fuzzy finder for files and commands
- **[treesitter.lua](https://github.com/nvim-treesitter/nvim-treesitter)**: Enhanced syntax highlighting

*For a complete list, refer to the `lua/plugins` folder in the repository.*

## Configuration

The configuration files are organized as follows:

```
~/.config/nvim/
├── lua/                   # Lua configuration directory
│   ├── plugins/           # Individual plugin configurations
│   │   ├── alpha.lua
│   │   ├── autopairs.lua
│   │   ├── bufferline.lua
│   │   ├── ... (additional plugins)
│   ├── mappings.lua        # Key mappings and shortcuts
│   ├── settings.lua        # General settings and options
├── init.lua                # Main entry point for the Neovim configuration
├── lazy-lock.json          # Lock file for lazy.nvim (plugin management state)
├── nvim-install.sh         # Installation script for setting up Neovim
└── ... (etc)
```

### Example: `settings.lua`

```lua
-- General Settings
vim.opt.number = true
vim.opt.expandtab = true
vim.opt.smartindent = true
vim.opt.tabstop = 2
vim.opt.shiftwidth = 2
vim.opt.termguicolors = true
```

### Example: `mappings.lua`

```lua
-- Keybindings for Telescope fuzzy finder
map('n', '<leader>tf', '<cmd>Telescope find_files cwd=' .. initial_cwd .. '<cr>', default_opts)
map('n', '<leader>tg', '<cmd>Telescope live_grep  cwd=' .. initial_cwd .. '<cr>', default_opts)
map('n', '<leader>tb', '<cmd>Telescope buffers<cr>', default_opts)
map('n', '<leader>th', '<cmd>Telescope help_tags<cr>', default_opts)
map('n', '<leader>ts', '<cmd>Telescope luasnip<cr>', default_opts)

-- Neotree keybindings
map('n', '<C-e>', ':Neotree toggle reveal=true reveal_force_cwd=true<CR>', default_opts)

-- Bufferline mappings
map('n', '<TAB>', ':BufferLineCycleNext<CR>', default_opts)
map('n', '<S-TAB>', ':BufferLineCyclePrev<CR>', default_opts)

-- Scope mappings / tab management
map('n', '<C-w>t', ':tabnew<CR>', default_opts)

-- Terminal splits mappings
map('n', '<leader>h', ':belowright 20split | terminal<CR>', default_opts)
map('n', '<leader>v', ':vsplit | wincmd l | terminal<CR>', default_opts)
```

## Customization

- **Themes**: Change the colorscheme by modifying the `colorscheme.lua` file
- **Keybindings**: Update or add new keybindings in the `mappings.lua` file
- **Plugins**: Add or remove plugins in the `lua/plugins/` folder to install with `lazy.nvim`
- **Language Servers**: Configure additional language servers in the `lsp.lua` file or install with `:Mason`

## License

This project is licensed under the [MIT License](LICENSE)
