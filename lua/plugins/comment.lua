return {
  "numToStr/Comment.nvim",
  event = "VeryLazy",
  config = function()
    require("Comment").setup({
      toggler = {
        line = "gcc",  -- Line-comment toggle keymap
        block = "gbc", -- Block-comment toggle keymap
      },
      -- Extra mappings
      extra = {
        above = "gcO", -- Add comment on the line above
        below = "gco", -- Add comment on the line below
        eol = "gcA",   -- Add comment at the end of line
      },
      -- Enable sticky comments (cursor stays in place)
      sticky = true,
      mappings = {
        basic = true,
        extra = true,
      },
    })
  end,
}