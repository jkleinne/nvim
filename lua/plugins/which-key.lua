return {
  "folke/which-key.nvim",
  event = "VeryLazy",
  config = function()
    local wk = require "which-key"
    wk.setup()
    wk.add {
      { "<leader>c", group = "Code" },
      { "<leader>g", group = "Git" },
      { "<leader>t", group = "Telescope" },
      { "<leader>w", group = "Workspace" },
      { "<leader>x", group = "Trouble" },
    }
  end,
}
