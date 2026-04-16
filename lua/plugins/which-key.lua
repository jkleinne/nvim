return {
  "folke/which-key.nvim",
  event = "VeryLazy",
  config = function()
    local wk = require "which-key"
    wk.setup()
    wk.add {
      { "<leader>b", group = "Buffer" },
      { "<leader>c", group = "Code" },
      { "<leader>d", group = "Docker" },
      { "<leader>g", group = "Git" },
      { "<leader>p", group = "HTTP Client" },
      { "<leader>r", group = "Refactor" },
      { "<leader>s", group = "SQL" },
      { "<leader>t", group = "Telescope" },
      { "<leader>w", group = "Workspace" },
      { "<leader>x", group = "Trouble" },
    }
  end,
}
