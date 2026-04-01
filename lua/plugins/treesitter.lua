return {
  "nvim-treesitter/nvim-treesitter",
  enabled = false, -- query_predicates conflict with Neovim 0.12 built-in treesitter
  build = ":TSUpdate",
  event = "BufRead",
  config = function()
    require("nvim-treesitter.configs").setup({
      ensure_installed = {
        "bash", "c", "cpp", "css", "dockerfile", "go", "hcl", "html", "javascript",
        "json", "lua", "markdown", "markdown_inline", "python", "rust", "typescript", "yaml",
      },
      auto_install = true,
      highlight = { enable = false },
      indent = { enable = false },
    })
  end,
}
