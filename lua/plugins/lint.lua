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
    }

    -- tflint runs plugins named in a repo's .tflint.hcl, so it only runs in directories trusted
    -- through Neovim's trust database (:help vim.secure.read()). Asked at most once per directory
    -- per session; without a UI the directory counts as untrusted.
    local trusted_dirs = {}
    local function cwd_trusted()
      local cwd = vim.fn.getcwd()
      if trusted_dirs[cwd] == nil then
        trusted_dirs[cwd] = #vim.api.nvim_list_uis() > 0 and vim.secure.read(cwd) == true
      end
      return trusted_dirs[cwd]
    end

    vim.api.nvim_create_autocmd({ "BufWritePost", "BufReadPost", "InsertLeave" }, {
      callback = function()
        -- Linters that fail to start (for example, not installed) stay quiet; see README Requirements
        lint.try_lint(nil, { ignore_errors = true })
        if vim.bo.filetype == "terraform" and cwd_trusted() then
          lint.try_lint("tflint", { ignore_errors = true })
        end
      end,
    })
  end,
}
