return {
  "mfussenegger/nvim-lint",
  event = { "BufReadPre", "BufNewFile" },
  config = function()
    local lint = require "lint"
    lint.linters_by_ft = {
      dockerfile = { "hadolint" },
      lua = { "selene" },
      sh = { "shellcheck" },
      yaml = { "yamllint" },
      go = { "golangcilint" },
      python = { "ruff" },
      terraform = { "tflint" },
    }
    vim.api.nvim_create_autocmd({ "BufWritePost", "BufReadPost", "InsertLeave" }, {
      callback = function()
        -- Missing linters stay quiet; nvim-install.sh reports them
        lint.try_lint(nil, { ignore_errors = true })
      end,
    })
  end,
}
