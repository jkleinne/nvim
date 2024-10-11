return {
  'akinsho/bufferline.nvim',
  version = "*",
  dependencies = 'nvim-tree/nvim-web-devicons',
  config = function()
    require("bufferline").setup{
      options = {
        themable = true,
        separator_style = "padded_slope",
      }
    }
  end,
}
