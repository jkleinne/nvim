return {
  {
    "stevearc/conform.nvim",
    -- event = 'BufWritePre', -- uncomment for format on save
    opts = require "configs.conform",
  },

  {
    "neovim/nvim-lspconfig",
    config = function()
      require "configs.lspconfig"
    end,
  },

  {
    'f-person/git-blame.nvim',
    event = "VeryLazy",
    opts = {
      enabled = true,
      message_template = "<author> • <date> • [<sha>] <summary>"
    }
  },

  {
    "ramilito/kubectl.nvim",
    config = function()
      require("kubectl").setup()
    end,
  },

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
  }
}
