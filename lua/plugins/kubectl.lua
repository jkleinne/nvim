return {
  "ramilito/kubectl.nvim",
  lazy = true,
  config = function()
    require("kubectl").setup()
  end,
}
