return {
  "windwp/nvim-autopairs",
  event = "InsertEnter", -- Load when entering Insert mode
  config = function()
    require("nvim-autopairs").setup {
      fast_wrap = {},
    }
  end,
}
