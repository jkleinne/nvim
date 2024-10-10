return {
  "ramilito/kubectl.nvim",
  event = "VeryLazy",
  config = function()
    require("kubectl").setup()
  end,
}
