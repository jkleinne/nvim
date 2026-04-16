return {
  "s1n7ax/nvim-window-picker",
  name = "window-picker",
  version = "2.*",
  event = "VeryLazy",
  config = function()
    local palette = require("catppuccin.palettes").get_palette()
    require("window-picker").setup {
      selection_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ",
      filter_rules = {
        hint = "statusline",
        include_current_win = false,
        autoselect_one = true,
        bo = {
          filetype = { "neo-tree", "neo-tree-popup", "notify" },
          buftype = { "terminal", "quickfix" },
        },
      },
      highlights = {
        statusline = {
          focused = { fg = palette.base, bg = palette.green, bold = true },
          unfocused = { fg = palette.text, bg = palette.surface0, bold = true },
        },
        winbar = {
          focused = { fg = palette.base, bg = palette.green, bold = true },
          unfocused = { fg = palette.text, bg = palette.surface0, bold = true },
        },
      },
    }
  end,
}
