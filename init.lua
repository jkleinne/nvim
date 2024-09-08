local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.loop.fs_stat(lazypath) then
  vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git",
    "--branch=stable",
    lazypath,
  })
end
vim.opt.rtp:prepend(lazypath)

require("lazy").setup({
  {
    "sheerun/vim-polyglot"
  },
  {
    "folke/tokyonight.nvim"
  },
  {
    "MunifTanjim/nui.nvim"
  },
  {
    "nvim-lua/plenary.nvim"
  },
  {
   "nvim-tree/nvim-web-devicons" 
  },
  -- Autocompletion with nvim-cmp
  {
    "hrsh7th/nvim-cmp",
    event = "InsertEnter",
    dependencies = {
      "hrsh7th/cmp-nvim-lsp", 
      "hrsh7th/cmp-buffer",   
      "hrsh7th/cmp-path",     
      "hrsh7th/cmp-cmdline",  
      "saadparwaiz1/cmp_luasnip", 
      "L3MON4D3/LuaSnip",     
    },
    config = function()
      local cmp = require("cmp")
      cmp.setup({
        snippet = {
          expand = function(args)
            require("luasnip").lsp_expand(args.body)
          end,
        },
        mapping = cmp.mapping.preset.insert({
          ["<C-d>"] = cmp.mapping.scroll_docs(-4),
          ["<C-f>"] = cmp.mapping.scroll_docs(4),
          ["<C-Space>"] = cmp.mapping.complete(),
          ["<CR>"] = cmp.mapping.confirm({ select = true }),
        }),
        sources = cmp.config.sources({
          { name = "nvim_lsp" },
          { name = "buffer" },
          { name = "path" },
        }),
      })
    end,
  },

  {
    "neovim/nvim-lspconfig",
    config = function()
      local lspconfig = require("lspconfig")

      local servers = {
        "terraformls",
        "ansiblels", 
        "tsserver", 
        "yamlls",
        "pyright"
      }

      -- Default setup for most LSPs, e.g. lspconfig.terraformls.setup{}
      for _, server in ipairs(servers) do
        lspconfig[server].setup {}
      end

       -- YAML LSP
      lspconfig.yamlls.setup {
        settings = {
          yaml = {
            -- Enable schema store, which automatically detects schema based on file contents
            schemaStore = {
              enable = true,
              url = "https://www.schemastore.org/api/json/catalog.json",
            },
          },
        },
      }

      local lspconfig = require('lspconfig')

    end,
  },

  -- Treesitter for better syntax highlighting
  {
    "nvim-treesitter/nvim-treesitter",
    run = ":TSUpdate",
    config = function()
      require("nvim-treesitter.configs").setup({
        highlight = { enable = true },
        indent = { enable = true },
        ensure_installed = { "bash", "yaml", "json", "lua", "typescript", "javascript", "terraform" },
      })
    end,
  },

  -- Autopairs for auto-closing brackets and quotes
  {
    "windwp/nvim-autopairs",
    event = "InsertEnter",
    config = function()
      require("nvim-autopairs").setup {}
    end,
  },

  {
    "numToStr/Comment.nvim",
    config = function()
      require("Comment").setup()
    end,
  },

  {
    "nvim-neo-tree/neo-tree.nvim",
    branch = "v2.x",
    requires = {
      "nvim-lua/plenary.nvim",
      "nvim-tree/nvim-web-devicons",  
      "MunifTanjim/nui.nvim",
    },
    config = function()
      require("neo-tree").setup({
        filesystem = {
          follow_current_file = true, 
          hijack_netrw_behavior = "open_default",  
          bind_to_cwd = false,
          respect_buf_cwd = true,
          filtered_items = {
            hide_dotfiles = false,  
          },
        },
      })
    end,
  },

  -- Lualine for status line
  {
    "nvim-lualine/lualine.nvim",
    requires = { "nvim-tree/nvim-web-devicons", opt = true },
    config = function()
      require("lualine").setup({
        options = { theme = "auto" },
      })
    end,
  },
})

-- Automatically change the local working directory to the current file's directory
vim.cmd([[
  autocmd BufEnter * silent! lcd %:p:h
]])

-- Automatically reveal Neo-tree at the current file's directory, and force the cwd change
vim.cmd([[
  augroup OpenNeoTree
    autocmd!
    autocmd VimEnter * Neotree source=filesystem reveal=true reveal_force_cwd=true
  augroup END
]])


-- Automatically close Neovim when Neo-tree is the last window
vim.cmd([[
  autocmd BufEnter * ++nested if winnr('$') == 1 && &filetype == 'neo-tree' | quit | endif
]])

vim.cmd([[colorscheme tokyonight]])

vim.cmd([[syntax on]])
vim.cmd([[filetype plugin indent on]])

vim.opt.number = true        
vim.opt.expandtab = true     
vim.opt.smartindent = true   

vim.g.mapleader = " "

vim.api.nvim_set_keymap('n', '<leader>p', ':Neotree change_root_up<CR>', { noremap = true, silent = true })
