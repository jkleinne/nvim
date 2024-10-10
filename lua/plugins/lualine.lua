return {
  "nvim-lualine/lualine.nvim",
  dependencies = { "nvim-tree/nvim-web-devicons" },
  event = "VeryLazy",
  config = function()
    -- Automatically choose theme for Lualine
    require("lualine").setup({
      options = {
        theme = "auto",
        icons_enabled = true
      },
    })
  end,
}
