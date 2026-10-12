return {
  "stevearc/conform.nvim",
  event = "BufWritePre",
  cmd = "ConformInfo",
  keys = {
    {
      "<leader>f",
      function()
        if not require("conform").format { async = true, lsp_format = "fallback" } then
          vim.notify("No formatter available for " .. vim.bo.filetype .. " (see :ConformInfo)", vim.log.levels.WARN)
        end
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
    -- System prettier only, never a repo's node_modules copy (its config can still run code; see README)
    formatters = { prettier = { command = "prettier" } },
    format_on_save = {
      timeout_ms = 500,
      lsp_format = "fallback",
    },
    -- Format-on-save stays quiet about missing formatters (README Requirements; :ConformInfo lists them)
    notify_no_formatters = false,
  },
}
