return {
  "mfussenegger/nvim-lint",
  event = { "BufReadPre", "BufNewFile" },
  config = function()
    local lint = require "lint"
    lint.linters_by_ft = {
      dockerfile = { "hadolint" },
      sh = { "shellcheck" },
      yaml = { "yamllint" },
      go = { "golangcilint" },
      python = { "ruff" },
      terraform = { "tflint" },
    }
    vim.api.nvim_create_autocmd({ "BufWritePost", "BufReadPost", "InsertLeave" }, {
      callback = function()
        lint.try_lint()
      end,
    })
  end,
}
