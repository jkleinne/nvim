return {
  's1n7ax/nvim-window-picker',
  name = 'window-picker',
  version = '2.*',
  event = "VeryLazy",
  config = function()
    require("window-picker").setup({
      selection_chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ',
      filter_rules = {
        hint = "statusline",
        include_current_win = false,
        autoselect_one = true,
          -- filter using buffer options
          bo = {
            -- if the file type is one of following, the window will be ignored
            filetype = { 'neo-tree', "neo-tree-popup", "notify" },
            -- if the buffer type is one of following, the window will be ignored
            buftype = { 'terminal', "quickfix" },
          },
      },
      highlights = {
        statusline = {
          focused = {
            fg = '#ededed',
            bg = '#9AAB99',
            bold = true,
          },
          unfocused = {
            fg = '#ededed',
            bg = '#1b1b1b',
            bold = true,
          },
        },
        winbar = {
          focused = {
            fg = '#ededed',
            bg = '#9AAB99',
            bold = true,
          },
          unfocused = {
            fg = '#ededed',
            bg = '#1b1b1b',
            bold = true,
          },
        },
      },
    })
  end,
}
