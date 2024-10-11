return {
  "lewis6991/gitsigns.nvim",
  event = "VeryLazy",
  config = function ()
    require('gitsigns').setup({
      current_line_blame = true,
      current_line_blame_formatter = "<author> • <author_time:%a %b %d %Y - %I:%M:%S %p> • [<abbrev_sha>] <summary>",
      current_line_blame_opts = {
        delay = 0
      }
    })
  end
}
