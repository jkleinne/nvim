return {
  "nvim-neo-tree/neo-tree.nvim",
  branch = "v3.x",
  dependencies = {
    "nvim-lua/plenary.nvim",
    "nvim-tree/nvim-web-devicons",
    "MunifTanjim/nui.nvim",
  },
  lazy = false,
  config = function()
    require("neo-tree").setup({
      filesystem = {
        follow_current_file = {
          enabled = true,
        },
        hijack_netrw_behavior = "open_default",
        bind_to_cwd = false,
        respect_buf_cwd = true,
        filtered_items = {
          hide_dotfiles = false,
        },
      },
      window = {
        position = "left",
        line_numbers = false,
      },
    })
  end,
}
