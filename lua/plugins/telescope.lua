return {
  "nvim-telescope/telescope.nvim",
  dependencies = {
    "nvim-lua/plenary.nvim",
    "L3MON4D3/LuaSnip",
    "benfowler/telescope-luasnip.nvim",
    { "nvim-telescope/telescope-fzf-native.nvim", build = "make" },
  },
  cmd = "Telescope",
  config = function()
    local telescope = require("telescope")
    telescope.setup({
      defaults = {
        vimgrep_arguments = {
          "rg",
          "--color=never",
          "--no-heading",
          "--with-filename",
          "--line-number",
          "--column",
          "--smart-case",
        },
        prompt_prefix = "🔍 ",
        selection_caret = " ",
        path_display = { "smart" },
        file_ignore_patterns = { "node_modules", ".git/" },
      },
      pickers = {
        find_files = {
          hidden = true,
        },
        live_grep = {
          only_sort_text = true,
        },
      },
    })
    telescope.load_extension("fzf")
    telescope.load_extension("luasnip")
  end,
}
