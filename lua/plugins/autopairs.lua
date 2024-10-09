return {
  "windwp/nvim-autopairs",
  event = "InsertEnter", -- Load when entering Insert mode
  dependencies = {
    "nvim-lua/plenary.nvim",
    "MunifTanjim/nui.nvim"
  },
  config = function()
    require("nvim-autopairs").setup {} 
  end,
}
