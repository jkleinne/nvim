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

    -- Linters must never run code a repo supplies. tflint loads plugins named in any .tflint.hcl
    -- under the cwd (it runs --recursive), so --config pins it to this config's tflint.hcl. That is
    -- not enough: with only --config, tflint still runs plugin binaries from a repo's
    -- .tflint.d/plugins (tflint 0.64.0), so TFLINT_PLUGIN_DIR points plugin discovery at a dir under
    -- Neovim's data dir. golangci-lint can load a native plugin named in a repo's .golangci.yml;
    -- --no-config ignores repo configs.
    local tflint_plugins = vim.fn.stdpath "data" .. "/tflint-plugins"
    vim.fn.mkdir(tflint_plugins, "p")
    lint.linters.tflint = function()
      local linter = vim.deepcopy(require "lint.linters.tflint")
      table.insert(linter.args, "--config=" .. vim.fn.stdpath "config" .. "/tflint.hcl")
      linter.env = vim.tbl_extend("force", vim.fn.environ(), { TFLINT_PLUGIN_DIR = tflint_plugins })
      return linter
    end
    lint.linters.golangcilint = function()
      local linter = vim.deepcopy(require "lint.linters.golangcilint")
      -- args is nil when `golangci-lint version` failed (not installed); then nothing loads a config
      if linter.args then
        -- Right after "run"; without one, at the end (golangci-lint takes flags after the package path)
        local position = #linter.args + 1
        for i, arg in ipairs(linter.args) do
          if arg == "run" then
            position = i + 1
            break
          end
        end
        table.insert(linter.args, position, "--no-config")
      end
      return linter
    end

    vim.api.nvim_create_autocmd({ "BufWritePost", "BufReadPost", "InsertLeave" }, {
      callback = function()
        -- Linters that fail to start (for example, not installed) stay quiet; see README Requirements
        lint.try_lint(nil, { ignore_errors = true })
      end,
    })
  end,
}
