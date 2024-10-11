return {
  "nvim-telescope/telescope.nvim",
  dependencies = {
    "nvim-lua/plenary.nvim",  -- Required dependency for Telescope
    "L3MON4D3/LuaSnip",
    "benfowler/telescope-luasnip.nvim"
  },
  cmd = "Telescope",  -- Lazy-load Telescope when the :Telescope command is used
  config = function()
    require("telescope").setup({
      defaults = {
        vimgrep_arguments = {
          'rg', -- Use ripgrep for searching (needs to be installed, e.g., brew install ripgrep)
          '--color=never',
          '--no-heading',
          '--with-filename',
          '--line-number',
          '--column',
          '--smart-case',
        },
        prompt_prefix = "🔍 ",  -- Icon for the search prompt
        selection_caret = " ", -- Icon for the selected item
        path_display = { "smart" }, -- Smart path display
        file_ignore_patterns = { "node_modules", ".git/" }, -- Ignore certain directories
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
  end,
}
