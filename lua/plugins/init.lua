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
  }
}
