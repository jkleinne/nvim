return {
  "lukas-reineke/indent-blankline.nvim",
  main = "ibl",
  opts = {
    indent = { char = "│", highlight = "IblIndent", smart_indent_cap = true },
    scope = { char = "│", highlight = "IblScope" },
  },
  config = function(_, opts)
    require("ibl").setup(opts)
  end
}
