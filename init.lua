-- Path to lazy.nvim plugin manager
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
-- Clones lazy.nvim from the repository if not already installed
if not vim.loop.fs_stat(lazypath) then
  vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none", -- Only fetch essential blobs
    "https://github.com/folke/lazy.nvim.git",
    "--branch=stable",
    lazypath,
  })
end
-- Add lazy.nvim to runtime path
vim.opt.rtp:prepend(lazypath)

-- Setup lazy.nvim to manage plugins
require("lazy").setup({
  -- Language pack plugin for better language support
  {
    "sheerun/vim-polyglot"
  },
  -- Tokyo Night theme for Neovim
  {
    "folke/tokyonight.nvim"
  },
  -- UI component library for Neovim plugins
  {
    "MunifTanjim/nui.nvim"
  },
  -- Utility functions required by various plugins
  {
    "nvim-lua/plenary.nvim"
  },
  -- File icons for Neovim (used by several plugins)
  {
   "nvim-tree/nvim-web-devicons" 
  },
  
  -- Autocompletion plugin with several dependencies
  {
    "hrsh7th/nvim-cmp",
    event = "InsertEnter", -- Load plugin when entering Insert mode
    dependencies = {
      "hrsh7th/cmp-nvim-lsp", -- LSP source for nvim-cmp
      "hrsh7th/cmp-buffer",   -- Buffer source for nvim-cmp
      "hrsh7th/cmp-path",     -- File path completion
      "hrsh7th/cmp-cmdline",  -- Command line completion
      "saadparwaiz1/cmp_luasnip", -- Snippet completion
      "L3MON4D3/LuaSnip",     -- Snippet engine
    },
    config = function()
      local cmp = require("cmp")
      -- Configuration for nvim-cmp
      cmp.setup({
        snippet = {
          expand = function(args)
            require("luasnip").lsp_expand(args.body) -- Use LuaSnip to expand snippets
          end,
        },
        -- Key mappings for completion actions
        mapping = cmp.mapping.preset.insert({
          ["<C-d>"] = cmp.mapping.scroll_docs(-4),
          ["<C-f>"] = cmp.mapping.scroll_docs(4),
          ["<C-Space>"] = cmp.mapping.complete(),
          ["<CR>"] = cmp.mapping.confirm({ select = true }),
        }),
        -- Define completion sources
        sources = cmp.config.sources({
          { name = "nvim_lsp" }, -- LSP-based completions
          { name = "buffer" },   -- Buffer-based completions
          { name = "path" },     -- File path completions
        }),
      })
    end,
  },

  -- LSP configuration for several languages
  {
    "neovim/nvim-lspconfig",
    config = function()
      local lspconfig = require("lspconfig")

      -- List of LSP servers to setup
      local servers = {
        "terraformls", -- Terraform language server
        "ansiblels",   -- Ansible language server
        "ts_ls",       -- TypeScript language server
        "yamlls",      -- YAML language server
        "pyright"      -- Python language server
      }

      -- Setup LSP servers with default configurations
      for _, server in ipairs(servers) do
        lspconfig[server].setup {}
      end

      -- Custom YAML LSP configuration with schema store
      lspconfig.yamlls.setup {
        settings = {
          yaml = {
            schemaStore = {
              enable = true, -- Enable schema store
              url = "https://www.schemastore.org/api/json/catalog.json", 
            },
          },
        },
      }
    end,
  },

  -- Treesitter for better syntax highlighting and code parsing
  {
    "nvim-treesitter/nvim-treesitter",
    run = ":TSUpdate",
    config = function()
      require("nvim-treesitter.configs").setup({
        highlight = { enable = true }, -- Enable syntax highlighting
        indent = { enable = true },    -- Enable automatic indentation
        ensure_installed = { "bash", "yaml", "json", "lua", "typescript", "javascript", "terraform" }, 
      })
    end,
  },

  -- Automatically close brackets and quotes
  {
    "windwp/nvim-autopairs",
    event = "InsertEnter", -- Load when entering Insert mode
    config = function()
      require("nvim-autopairs").setup {} 
    end,
  },

  -- Plugin for easy commenting
  {
    "numToStr/Comment.nvim",
    config = function()
      require("Comment").setup()
    end,
  },

  -- Neo-tree file explorer plugin
  {
    "nvim-neo-tree/neo-tree.nvim",
    branch = "v2.x",
    requires = {
      "nvim-lua/plenary.nvim",         -- Required utility library
      "nvim-tree/nvim-web-devicons",   -- Required for file icons
      "MunifTanjim/nui.nvim",          -- Required for UI components
    },
    config = function()
      -- Neo-tree setup with custom configurations
      require("neo-tree").setup({
        filesystem = {
          follow_current_file = true, -- Automatically reveal the current file
          hijack_netrw_behavior = "open_default",  -- Replace netrw with Neo-tree
          bind_to_cwd = false,        -- Do not change to current directory
          respect_buf_cwd = true,     -- Respect buffer's working directory
          filtered_items = {
            hide_dotfiles = false, -- Show hidden files (dotfiles)
          },
        },
      })
    end,
  },
  
  -- Lualine status line plugin for Neovim
  {
    "nvim-lualine/lualine.nvim",
    requires = { "nvim-tree/nvim-web-devicons", opt = true }, -- File icons
    config = function()
      -- Automatically choose theme for Lualine
      require("lualine").setup({
        options = { theme = "auto" },
      })
    end,
  },

  -- Telescope fuzzy finder for searching files, buffers, and more
  {
    "nvim-telescope/telescope.nvim",
    requires = { {"nvim-lua/plenary.nvim"} },  -- Required utility library
    config = function()
      local telescope = require("telescope")
      -- Telescope setup with custom configurations
      telescope.setup({
        defaults = {
          vimgrep_arguments = {
            'rg', -- Use ripgrep for searching (needs to be installed, e.g. brew install ripgrep)
            '--color=never',
            '--no-heading',
            '--with-filename',
            '--line-number',
            '--column',
            '--smart-case'
          },
          prompt_prefix = "🔍 ",  -- Icon for the search prompt
          selection_caret = " ", -- Icon for the selected item
          path_display = { "smart" }, -- Smart path display
          file_ignore_patterns = {"node_modules", ".git/"}, -- Ignore certain directories
          mappings = {
            i = {
              ["<C-n>"] = require("telescope.actions").move_selection_next, -- Move to next item
              ["<C-p>"] = require("telescope.actions").move_selection_previous, -- Move to previous item
            },
          },
        },
      })
    end
  },
})

-- Automatically set the local working directory to the current file's directory
vim.cmd([[
  autocmd BufEnter * silent! lcd %:p:h
]])

-- Automatically reveal the current file in Neo-tree and force a change to its directory
vim.cmd([[
  augroup OpenNeoTree
    autocmd!
    autocmd VimEnter * Neotree source=filesystem reveal=true reveal_force_cwd=true
  augroup END
]])

-- Automatically close Neovim if Neo-tree is the last open window
vim.cmd([[
  autocmd BufEnter * ++nested if winnr('$') == 1 && &filetype == 'neo-tree' | quit | endif
]])

-- Set the colorscheme to Tokyo Night
vim.cmd([[colorscheme tokyonight]])

-- Enable syntax highlighting and filetype-based settings
vim.cmd([[syntax on]])
vim.cmd([[filetype plugin indent on]])

-- Set general Neovim options
vim.opt.number = true        -- Enable line numbers
vim.opt.expandtab = true     -- Use spaces instead of tabs
vim.opt.smartindent = true   -- Enable smart indentation

-- Set the leader key to space
vim.g.mapleader = " "

-- Keybinding to change the root directory in Neo-tree
vim.api.nvim_set_keymap('n', '<leader>p', ':Neotree change_root_up<CR>', { noremap = true, silent = true })

-- Keybindings for Telescope fuzzy finder
vim.api.nvim_set_keymap('n', '<leader>ff', '<cmd>Telescope find_files<cr>', { noremap = true, silent = true })
vim.api.nvim_set_keymap('n', '<leader>fg', '<cmd>Telescope live_grep<cr>', { noremap = true, silent = true })
vim.api.nvim_set_keymap('n', '<leader>fb', '<cmd>Telescope buffers<cr>', { noremap = true, silent = true })
vim.api.nvim_set_keymap('n', '<leader>fh', '<cmd>Telescope help_tags<cr>', { noremap = true, silent = true })
