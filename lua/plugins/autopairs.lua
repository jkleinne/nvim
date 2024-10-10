return {
  "windwp/nvim-autopairs",
  event = "InsertEnter", -- Load when entering Insert mode
  dependencies = {
    "nvim-lua/plenary.nvim",
    "MunifTanjim/nui.nvim"
  },
  opts = {
    fast_wrap = {}
  },
  config = function()
    require("nvim-autopairs").setup {}
  end,
}
