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
      git_status = {
        symbols = {
          added     = "✚",
          deleted   = "✖",
          modified  = "",
          renamed   = "󰁕",
          untracked = "",
          ignored   = "",
          unstaged  = "󰄱",
          staged    = "",
          conflict  = "",
        },
        align = "right",
      },
      window = {
        mappings = {
          ["<cr>"] = "open_with_window_picker",
          ["<2-LeftMouse>"] = "open_with_window_picker"
        }
      }
    })
  end,
}
