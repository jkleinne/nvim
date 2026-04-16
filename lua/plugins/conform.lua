return {
  "stevearc/conform.nvim",
  event = "BufWritePre",
  cmd = "ConformInfo",
  keys = {
    {
      "<leader>f",
      function()
        require("conform").format { async = true, lsp_fallback = true }
      end,
      desc = "Format buffer",
    },
  },
  opts = {
    formatters_by_ft = {
      go = { "goimports", "gofmt" },
      javascript = { "prettier" },
      typescript = { "prettier" },
      json = { "prettier" },
      yaml = { "prettier" },
      markdown = { "prettier" },
      css = { "prettier" },
      html = { "prettier" },
      python = { "black" },
      lua = { "stylua" },
      terraform = { "terraform_fmt" },
      hcl = { "terraform_fmt" },
      sh = { "shfmt" },
    },
  },
}
