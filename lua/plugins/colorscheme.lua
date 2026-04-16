return {
  "catppuccin/nvim",
  name = "catppuccin",
  priority = 1000,
  config = function()
    require("catppuccin").setup {
      flavour = "mocha", -- latte, frappe, macchiato, mocha
      background = {
        light = "latte",
        dark = "mocha",
      },
      integrations = {
        alpha = true,
        bufferline = true,
        flash = true,
        gitsigns = true,
        indent_blankline = {
          enabled = true,
          scope_color = "lavender",
          colored_indent_levels = false,
        },
        lsp_trouble = true,
        mason = true,
        neotree = true,
        noice = true,
        telescope = { enabled = true },
        which_key = true,
        window_picker = true,
      },
    }

    vim.cmd.colorscheme "catppuccin"
  end,
}
