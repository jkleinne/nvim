-- The language servers this config sets up. Data only: read by lua/plugins/lsp.lua, and by
-- tests/install-script.test.sh T20 through `nvim --clean -l tests/lib/system-servers.lua`. Keep in
-- sync: `system` with install_language_servers in nvim-install.sh, the README's pacman command, and
-- T20; every list with the independent copy in tests/editor-config.test.lua (checked by L1b).
return {
  -- Installed by Mason (native binaries, no npm)
  mason = {
    "gopls",
    "lua_ls",
    "sqls",
    "terraformls",
  },

  -- Installed by the system package manager (server = command it runs). These are Node programs;
  -- the Arch packages depend on nodejs, not npm. The commands are bare names, so each runs the first
  -- match on PATH.
  system = {
    bashls = { "bash-language-server", "start" },
    dockerls = { "docker-langserver", "--stdio" },
    jsonls = { "vscode-json-language-server", "--stdio" },
    pyright = { "pyright-langserver", "--stdio" },
    ts_ls = { "typescript-language-server", "--stdio" },
    yamlls = { "yaml-language-server", "--stdio" },
  },

  -- No longer used by this config (docker_language_server: see README). A leftover Mason copy from
  -- an older version must never start.
  retired = { "ansiblels", "docker_compose_language_service", "docker_language_server", "sqlls" },

  -- The known lspconfig servers that run repo-supplied code with tools this config installs or
  -- trusts: tflint plugins named in a repo's .tflint.hcl (tflint), a repo's .golangci.yml
  -- (golangci_lint_ls), terraform providers (terraform_lsp, tofu_ls), and a repo's Python modules
  -- through `python -m` from the repo directory (esbonio, tvm_ffi_navigator; Python comes with this
  -- config's linters). They never start, not even with a bare :lsp enable.
  never = { "esbonio", "golangci_lint_ls", "terraform_lsp", "tflint", "tofu_ls", "tvm_ffi_navigator" },
}
