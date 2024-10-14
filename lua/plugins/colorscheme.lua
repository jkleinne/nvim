-- return {
--   "folke/tokyonight.nvim",
--   priority = 1000,
--   config = function()
--     require("tokyonight").setup({
--       style = "night",
--       transparent = false,
--       terminal_colors = false,
--       styles = {
--         comments = { italic = true },
--         keywords = { italic = false },
--         functions = {},
--         variables = {},
--       },
--     })
--     -- Apply the colorscheme after setup
--     vim.cmd("colorscheme tokyonight")
--   end,
-- }

return {
  "catppuccin/nvim",
  name = "catppuccin",
  priority = 1000,
  config = function()
    require("catppuccin").setup({
      flavour = "mocha", -- latte, frappe, macchiato, mocha
      background = {
        light = "latte",
        dark = "mocha",
      },
      integrations = {
        indent_blankline = {
          enabled = true,
          scope_color = 'lavender',
          colored_indent_levels = false,
        },
        neotree = true,
        window_picker = true,
        which_key = true
      }
    })

    vim.cmd.colorscheme "catppuccin"
  end
}
