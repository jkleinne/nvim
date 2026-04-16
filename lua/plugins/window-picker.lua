return {
  "s1n7ax/nvim-window-picker",
  name = "window-picker",
  version = "2.*",
  event = "VeryLazy",
  config = function()
    local palette = require("catppuccin.palettes").get_palette()
    local focused_fg = palette.base
    local focused_bg = palette.green
    local unfocused_fg = palette.text
    local unfocused_bg = palette.surface0
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
          focused = { fg = focused_fg, bg = focused_bg, bold = true },
          unfocused = { fg = unfocused_fg, bg = unfocused_bg, bold = true },
        },
        winbar = {
          focused = { fg = focused_fg, bg = focused_bg, bold = true },
          unfocused = { fg = unfocused_fg, bg = unfocused_bg, bold = true },
        },
      },
    }
  end,
}
