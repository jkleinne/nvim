return {
  "ramilito/kubectl.nvim",
  enabled = false, -- parked: no current Kubernetes work; set to true to restore it and <leader>k
  lazy = true,
  keys = {
    {
      "<leader>k",
      function()
        require("kubectl").toggle()
      end,
      desc = "Toggle kubectl",
    },
  },
  config = function()
    require("kubectl").setup()
  end,
}
